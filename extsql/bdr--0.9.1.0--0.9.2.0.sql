SET LOCAL search_path = bdr;
SET bdr.permit_unsafe_ddl_commands = true;
SET bdr.skip_ddl_replication = true;

DO
LANGUAGE plpgsql
$$
BEGIN
    IF (current_setting('server_version_num')::int / 100) <> 904 THEN
        RAISE EXCEPTION 'This extension script version only supports postgres-bdr 9.4';
    END IF;
END;
$$;

--
-- This is the same file as extsql/bdr--0.10.0.5--0.10.0.6.sql
-- in 0.10.0. It's safe to run twice.
--
DO $$
BEGIN
  IF bdr.bdr_variant() = 'BDR' THEN
    CREATE OR REPLACE FUNCTION bdr.bdr_internal_sequence_reset_cache(seq regclass)
    RETURNS void LANGUAGE c AS 'MODULE_PATHNAME' STRICT;
  END IF;
END$$;

RESET bdr.permit_unsafe_ddl_commands;
RESET bdr.skip_ddl_replication;
RESET search_path;
