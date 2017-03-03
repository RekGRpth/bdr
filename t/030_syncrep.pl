use strict;
use warnings;
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 27;
require "t/utils/common.pl";

#
# This test creates a 4-node group with two mutual sync-rep pairs.
# 
#    A <===> B
#    ^\     /^
#    | \   / |
#    |   x   |
#    | /   \ |
#    v/     \v
#    C <===> D
#
# then upgrades it to 2-safe using Pg 9.6 features to do A <==> C
# and B <==> D too.
#

my $tempdir = TestLib::tempdir;

#-------------------------------------
# Setup and worker names
#-------------------------------------

my $node_a = get_new_node('node_a');
create_bdr_group($node_a);

my $node_b = get_new_node('node_b');
startandjoin_node($node_b, $node_a);

# application_name should be the same as the node name
is($node_a->safe_psql('postgres', q[SELECT application_name FROM pg_stat_activity WHERE application_name <> 'psql' AND application_name NOT LIKE '%init' ORDER BY application_name]),
q[bdr supervisor
node_a:perdb
node_b:apply
node_b:send],
'2-node application_name check');

# Create the other nodes
my $node_c = get_new_node('node_c');
startandjoin_node($node_c, $node_a);

my $node_d = get_new_node('node_d');
startandjoin_node($node_d, $node_c);

# other apply workers should be visible now
is($node_a->safe_psql('postgres', q[SELECT application_name FROM pg_stat_activity WHERE application_name <> 'psql' AND application_name NOT LIKE '%init' ORDER BY application_name]),
q[bdr supervisor
node_a:perdb
node_b:apply
node_b:send
node_c:apply
node_c:send
node_d:apply
node_d:send],
'4-node application_name check');

#-------------------------------------
# no sync rep
#-------------------------------------

# Everything working?
$node_a->safe_psql('bdr_test', q[SELECT bdr.bdr_replicate_ddl_command($DDL$CREATE TABLE public.t(x text)$DDL$)]);
# Make sure everything caught up by forcing another lock
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

my @nodes = ($node_a, $node_b, $node_c, $node_d);
for my $node (@nodes) {
  $node->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES (bdr.bdr_get_local_node_name())]);
}
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('0-0 B+')]), 0, 'A: async B-up');

# With a node down we should still be able to do work
$node_b->stop;
is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('0-0 B-')]), 0, 'A: async B-down');
$node_b->start;

#-------------------------------------
# Reconfigure to 1-safe 1-sync
#-------------------------------------

diag "reconfiguring into synchronous pairs A<=>B, C<=>D (1-safe 1-sync)";
$node_a->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_b:send"']);
$node_b->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_a:send"']);

$node_c->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_d:send"']);
$node_d->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_c:send"']);

for my $node (@nodes) {
  $node->safe_psql('bdr_test', q[ALTER SYSTEM SET bdr.synchronous_commit = on]);
  $node->restart;
}

# Everything should work while the system is all-up
is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 1-1 B+')]), 0, 'A: 1-safe 1-sync B-up');

# but with node B down, node A should refuse to confirm commit
diag "stopping B";
$node_b->stop;
my $timed_out;
diag "inserting on A when B is down; expect psql timeout in 10s";
$node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 1-1 B-')], timeout => 10, timed_out => \$timed_out);
ok($timed_out, 'A: 1-safe 1-sync B-down times out');

is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'A: 1-1 B-']), '', 'committed xact not visible on A yet');

is($node_c->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'A: 1-1 B-']), '1', 'committed xact visible on C');

# but commiting on C should become immediately visible on both A and D when B is down
# TODO: wait for sync-up better
is($node_c->psql('bdr_test', q[INSERT INTO t(x) VALUES ('C: 1-1 B-')]), 0, 'C: 1-safe 1-sync B-down');
sleep(2);
is($node_c->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'C: 1-1 B-']), '1', 'C xact visible on C');
is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'C: 1-1 B-']), '1', 'C xact visible on A');
is($node_d->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'C: 1-1 B-']), '1', 'C xact visible on D');

diag "starting B";
$node_b->start;

# Because Pg commits a txn in sync rep before checking sync, once B comes back up
# and catches up, we should see the txn from when it was down.
#
# FIXME: use slot catchup

sleep(10);
is($node_b->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'A: 1-1 B-']), '1', 'B received xact from A');
is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'A: 1-1 B-']), '1', 'committed xact visible on A after B confirms');

#-------------------------------------
# Reconfigure to 2-safe 2-sync
#-------------------------------------

diag "reconfiguring into 2-safe 2-sync A[B,C], B[A,D] C[A,D] D[B,C]";
$node_a->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '2 ("node_b:send", "node_c:send")']);
$node_b->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '2 ("node_a:send", "node_d:send")']);

$node_c->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '2 ("node_d:send", "node_a:send")']);
$node_d->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '2 ("node_c:send", "node_b:send")']);

for my $node (@nodes) {
  $node->restart;
}

# Everything should work while the system is all-up
is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 2-2 B+ C+')]), 0, 'A: 2-safe 2-sync B up C up');

# but with node B down, node A should refuse to confirm commit
diag "stopping B";
$node_b->stop;
diag "inserting on A when B is down; expect psql timeout in 10s";
$node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 2-2 B- C+')], timeout => 10, timed_out => \$timed_out);
ok($timed_out, '2-safe 2-sync on A times out if B is down');
diag "starting B";
$node_b->start;

# same with node-C since we're 2-safe
diag "stopping C";
$node_c->stop;
diag "inserting on A when C is down; expect psql timeout in 10s";
$node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 2-2 B+ C-')], timeout => 10, timed_out => \$timed_out);
ok($timed_out, '2-safe 2-sync on A times out if C is down');
diag "starting C";
$node_c->start;


#-------------------------------------
# Reconfigure to 2-safe 2-sync
#-------------------------------------
#
diag "reconfiguring into 1-safe 2-sync A[B,C], B[A,D] C[A,D] D[B,C]";

$node_a->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '1 ("node_b:send", "node_c:send")']);
$node_b->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '1 ("node_a:send", "node_d:send")']);

$node_c->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '1 ("node_d:send", "node_a:send")']);
$node_d->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '1 ("node_c:send", "node_b:send")']);

for my $node (@nodes) {
  $node->restart;
}

# Everything should work while the system is all-up
is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('a: 2-1 B+ C+')]), 0, '2-sync 1-safe B up C up');

# or when one, but not both, nodes are down
diag "stopping B";
$node_b->stop;
is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 2-1 B- C+')]), 0, '2-sync 1-safe B down C up');

diag "stopping C";
$node_c->stop;
$node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('nA: 2-1 B- C-')], timeout => 10, timed_out => \$timed_out);
ok($timed_out, '2-sync 1-safe B down C down times out');

diag "starting B";
$node_b->start;

is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('A: 2-1 B+ C-')]), 0,'2-sync 1-safe B up C down');

diag "starting C";
$node_c->start;

is($node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('a: 2-1 B+ C+ 2')]), 0, '2-sync 1-safe B up C up after');

#-------------------------------------
# Consistent?
#-------------------------------------

diag "taking final DDL lock";
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);
diag "done, checking final state";

my $expected = q[0-0 B-
0-0 B+
A: 1-1 B-
A: 1-1 B+
a: 2-1 B+ C+
A: 2-1 B- C+
A: 2-1 B+ C-
a: 2-1 B+ C+ 2
A: 2-2 B- C+
A: 2-2 B+ C-
A: 2-2 B+ C+
C: 1-1 B-
nA: 2-1 B- C-
node_a
node_b
node_c
node_d];

is($node_a->safe_psql('bdr_test', 'select x from t order by x;'), $expected, 'final results node A');
is($node_b->safe_psql('bdr_test', 'select x from t order by x;'), $expected, 'final results node B');
is($node_c->safe_psql('bdr_test', 'select x from t order by x;'), $expected, 'final results node C');
is($node_d->safe_psql('bdr_test', 'select x from t order by x;'), $expected, 'final results node D');