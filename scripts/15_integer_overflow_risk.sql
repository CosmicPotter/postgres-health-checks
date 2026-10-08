-- =====================================================================
--  The Slow Postgres Playbook  ·  15  ·  ID columns about to overflow
-- ---------------------------------------------------------------------
--  Answers : Which auto-incrementing ID columns are running out of
--            numbers? A 32-bit "integer" / "serial" column stops at
--            2,147,483,647. When it hits that, every INSERT fails.
--            This takes down production apps with no warning.
--  Needs   : Nothing extra.
--  Safe    : Read-only. Runs in milliseconds.
--  Tested  : PostgreSQL 14, 15, 16, 17, 18
--  Guide   : The Slow Postgres Playbook, Chapter 15 (link in README)
--
--  Checks the COLUMN type, not just the sequence. A bigint sequence
--  feeding an integer column (common after old upgrades) still
--  overflows at 2.1 billion. Run this monthly. If a row shows WATCH,
--  run it again in a week to see how fast it's growing.
-- =====================================================================
WITH /* slow_postgres_playbook */ col_seq AS (
  -- serial / identity columns and the sequence that feeds them
  SELECT
    tn.nspname || '.' || t.relname || '.' || a.attname   AS id_column,
    format_type(a.atttypid, a.atttypmod)                 AS column_type,
    sn.nspname || '.' || s.relname                       AS sequence_name,
    ps.last_value,
    CASE a.atttypid
      WHEN 'int2'::regtype THEN 32767
      WHEN 'int4'::regtype THEN 2147483647
      WHEN 'int8'::regtype THEN 9223372036854775807
    END::numeric                                          AS column_max,
    ps.max_value::numeric                                 AS sequence_max,
    -- pg_sequences shows NULL both for "never used" and for "no permission".
    -- Telling them apart matters: a hidden value must never read as "OK".
    (has_sequence_privilege(s.oid, 'SELECT') OR has_sequence_privilege(s.oid, 'USAGE')) AS can_read
  FROM pg_depend d
  JOIN pg_class s       ON s.oid = d.objid    AND s.relkind = 'S'
  JOIN pg_namespace sn  ON sn.oid = s.relnamespace
  JOIN pg_class t       ON t.oid = d.refobjid
  JOIN pg_namespace tn  ON tn.oid = t.relnamespace
  JOIN pg_attribute a   ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
  JOIN pg_sequences ps  ON ps.schemaname = sn.nspname AND ps.sequencename = s.relname
  WHERE d.classid = 'pg_class'::regclass
    AND d.refclassid = 'pg_class'::regclass
    AND d.deptype IN ('a', 'i')             -- a = serial-owned, i = identity
)
SELECT
  id_column,
  column_type,
  to_char(last_value, 'FM9,999,999,999,999,999,999')                       AS current_value,
  to_char(least(column_max, sequence_max), 'FM9,999,999,999,999,999,999')  AS limit_value,
  CASE WHEN can_read
       THEN round(100.0 * coalesce(last_value, 0) / least(column_max, sequence_max), 2) END AS pct_used,
  CASE
    WHEN NOT can_read
      THEN 'UNKNOWN: no permission to read this sequence (see note)'
    WHEN 100.0 * coalesce(last_value, 0) / least(column_max, sequence_max) >= 75 THEN 'ACT: plan the migration now'
    WHEN 100.0 * coalesce(last_value, 0) / least(column_max, sequence_max) >= 50 THEN 'WATCH'
    ELSE 'OK'
  END                                                                      AS verdict,
  CASE WHEN NOT can_read
       THEN 'Run as the table owner, or: GRANT SELECT ON SEQUENCE ' || sequence_name || ' TO ' || quote_ident(current_user) || ';'
       WHEN sequence_max > column_max
       THEN 'sequence is bigger than the column: the COLUMN overflows first' END AS note,
  sequence_name
FROM col_seq
WHERE column_max IS NOT NULL
ORDER BY can_read ASC,   -- unreadable rows first: they could be the dangerous ones
         coalesce(last_value, 0) / least(column_max, sequence_max) DESC
LIMIT 25;
