-- =====================================================================
--  The Slow Postgres Playbook  ·  01  ·  Health overview
-- ---------------------------------------------------------------------
--  Answers : Is anything on fire right now? One screen, every vital sign.
--  Needs   : Nothing extra. Run as a role with pg_monitor for full detail.
--  Safe    : Read-only. Reads statistics views only. Runs in milliseconds.
--  Tested  : PostgreSQL 14, 15, 16, 17, 18
--  Guide   : The Slow Postgres Playbook, Chapter 1 (link in README)
--
--  verdict column:  OK = fine   WATCH = keep an eye on it   ACT = fix soon
-- =====================================================================
WITH /* slow_postgres_playbook */ db AS (
  SELECT * FROM pg_stat_database WHERE datname = current_database()
),
conn AS (
  SELECT count(*)                                                AS total,
         count(*) FILTER (WHERE state = 'active')               AS active,
         count(*) FILTER (WHERE state LIKE 'idle in transaction%'
                          AND now() - state_change > interval '5 minutes') AS idle_tx_stuck,
         max(now() - query_start) FILTER (WHERE state = 'active'
                          AND pid <> pg_backend_pid())          AS longest_active
  FROM pg_stat_activity
  WHERE backend_type = 'client backend'
),
lim AS (SELECT current_setting('max_connections')::int AS max_conn),
xid AS (
  SELECT max(age(datfrozenxid))::bigint AS oldest_xid_age FROM pg_database
)
SELECT check_name, value, verdict, what_it_means FROM (
  SELECT 1 AS ord, 'PostgreSQL version' AS check_name,
         current_setting('server_version') AS value,
         CASE WHEN current_setting('server_version_num')::int < 140000
              THEN 'WATCH' ELSE 'OK' END AS verdict,
         'Versions below 14 are out of community support.' AS what_it_means
  UNION ALL
  SELECT 2, 'Server uptime',
         date_trunc('second', now() - pg_postmaster_start_time())::text,
         'OK', 'Time since the last restart.'
  UNION ALL
  SELECT 3, 'Statistics collected since',
         coalesce(date_trunc('second', now() - db.stats_reset)::text || ' ago',
                  'server start (never reset)'),
         CASE WHEN db.stats_reset > now() - interval '1 day' THEN 'WATCH' ELSE 'OK' END,
         'Every number below covers this window. Under a day is too short to trust.'
  FROM db
  UNION ALL
  SELECT 4, 'Database size',
         pg_size_pretty(pg_database_size(current_database())), 'OK',
         'Total on-disk size of this database.'
  UNION ALL
  SELECT 5, 'Connections in use',
         conn.total || ' of ' || lim.max_conn || ' ('
           || round(100.0 * conn.total / lim.max_conn) || '%)',
         CASE WHEN conn.total >= 0.9 * lim.max_conn THEN 'ACT'
              WHEN conn.total >= 0.75 * lim.max_conn THEN 'WATCH' ELSE 'OK' END,
         'Near the limit, new connections fail. A pooler (PgBouncer) is the usual fix.'
  FROM conn, lim
  UNION ALL
  SELECT 6, 'Cache hit ratio',
         coalesce(round(100.0 * db.blks_hit / nullif(db.blks_hit + db.blks_read, 0), 2)::text || '%', 'n/a'),
         CASE WHEN db.blks_hit + db.blks_read = 0 THEN 'OK'
              WHEN 100.0 * db.blks_hit / (db.blks_hit + db.blks_read) < 95 THEN 'ACT'
              WHEN 100.0 * db.blks_hit / (db.blks_hit + db.blks_read) < 99 THEN 'WATCH'
              ELSE 'OK' END,
         'Share of reads served from memory. Busy OLTP apps should sit above 99%.'
  FROM db
  UNION ALL
  SELECT 7, 'Rollback ratio',
         coalesce(round(100.0 * db.xact_rollback / nullif(db.xact_commit + db.xact_rollback, 0), 2)::text || '%', 'n/a'),
         CASE WHEN db.xact_commit + db.xact_rollback = 0 THEN 'OK'
              WHEN 100.0 * db.xact_rollback / (db.xact_commit + db.xact_rollback) > 10 THEN 'ACT'
              WHEN 100.0 * db.xact_rollback / (db.xact_commit + db.xact_rollback) > 2 THEN 'WATCH'
              ELSE 'OK' END,
         'High rollbacks usually mean application errors being retried.'
  FROM db
  UNION ALL
  SELECT 8, 'Deadlocks', db.deadlocks::text,
         CASE WHEN db.deadlocks > 100 THEN 'ACT' WHEN db.deadlocks > 0 THEN 'WATCH' ELSE 'OK' END,
         'Two transactions waiting on each other. Postgres kills one; your app sees an error.'
  FROM db
  UNION ALL
  SELECT 9, 'Temp files written',
         db.temp_files || ' files, ' || pg_size_pretty(db.temp_bytes),
         CASE WHEN db.temp_bytes > 10::bigint * 1024 * 1024 * 1024 THEN 'ACT'
              WHEN db.temp_bytes > 0 THEN 'WATCH' ELSE 'OK' END,
         'Sorts and hashes that did not fit in work_mem and spilled to disk. See script 04.'
  FROM db
  UNION ALL
  SELECT 10, 'Stuck idle-in-transaction sessions', conn.idle_tx_stuck::text,
         CASE WHEN conn.idle_tx_stuck > 0 THEN 'ACT' ELSE 'OK' END,
         'Open transactions doing nothing for 5+ minutes. They hold locks and block VACUUM. See script 05.'
  FROM conn
  UNION ALL
  SELECT 11, 'Longest running query',
         coalesce(date_trunc('second', conn.longest_active)::text, 'none running right now'),
         CASE WHEN conn.longest_active > interval '30 minutes' THEN 'ACT'
              WHEN conn.longest_active > interval '5 minutes' THEN 'WATCH' ELSE 'OK' END,
         'Long queries hold resources and can block others. See scripts 05 and 06.'
  FROM conn
  UNION ALL
  SELECT 12, 'Transaction ID age (wraparound)',
         to_char(xid.oldest_xid_age, 'FM999,999,999,999') || ' ('
           || round(100.0 * xid.oldest_xid_age / 2147483648, 1) || '% of the hard limit)',
         CASE WHEN xid.oldest_xid_age > 1000000000 THEN 'ACT'
              WHEN xid.oldest_xid_age > 2 * current_setting('autovacuum_freeze_max_age')::bigint
                THEN 'WATCH' ELSE 'OK' END,
         'If this reaches the limit, Postgres stops accepting writes. See script 12.'
  FROM xid
  UNION ALL
  SELECT 13, 'Autovacuum',
         current_setting('autovacuum'),
         CASE WHEN current_setting('autovacuum') = 'off' THEN 'ACT' ELSE 'OK' END,
         'With autovacuum off, dead rows pile up and wraparound protection weakens.'
  UNION ALL
  SELECT 15, 'Running with monitoring rights',
         CASE WHEN (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN 'yes (superuser)'
              WHEN pg_has_role(current_user, 'pg_monitor', 'MEMBER') THEN 'yes (pg_monitor)'
              ELSE 'NO' END,
         CASE WHEN (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
                OR pg_has_role(current_user, 'pg_monitor', 'MEMBER') THEN 'OK' ELSE 'WATCH' END,
         'Without pg_monitor you only see your own sessions and queries. Ask an admin: GRANT pg_monitor TO ' || quote_ident(current_user) || ';'
  UNION ALL
  SELECT 14, 'pg_stat_statements installed',
         CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
              THEN 'yes' ELSE 'no' END,
         CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
              THEN 'OK' ELSE 'WATCH' END,
         'Scripts 02-04 need it. Without it you cannot see which queries are slow.'
) checks
ORDER BY ord;
