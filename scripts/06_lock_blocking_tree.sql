-- =====================================================================
--  The Slow Postgres Playbook  ·  06  ·  Who is blocking whom
-- ---------------------------------------------------------------------
--  Answers : Queries are hanging. Which session is holding the lock,
--            and which one is the ROOT of the queue?
--  Needs   : Nothing extra. pg_monitor role to see other users' queries.
--  Safe    : Read-only. Runs in milliseconds.
--  Tested  : PostgreSQL 14, 15, 16, 17, 18
--  Guide   : The Slow Postgres Playbook, Chapter 6 (link in README)
--
--  Empty result = nobody is blocked right now. Good news.
--  Fix the ROOT BLOCKER. Killing sessions further down the queue does
--  nothing; the next one in line just takes its place.
-- =====================================================================
WITH RECURSIVE /* slow_postgres_playbook */ waits AS (
  SELECT a.pid AS blocked_pid, unnest(pg_blocking_pids(a.pid)) AS blocker_pid
  FROM pg_stat_activity a
  WHERE cardinality(pg_blocking_pids(a.pid)) > 0
),
chain AS (                      -- everyone stuck behind a blocker, directly or not
  SELECT blocker_pid AS head, blocked_pid FROM waits
  UNION
  SELECT c.head, w.blocked_pid FROM chain c JOIN waits w ON w.blocker_pid = c.blocked_pid
),
victims AS (
  SELECT head AS blocker_pid, count(DISTINCT blocked_pid) AS sessions_blocked
  FROM chain GROUP BY head
)
SELECT
  w.blocker_pid,
  CASE WHEN cardinality(pg_blocking_pids(w.blocker_pid)) = 0
       THEN 'ROOT BLOCKER' ELSE 'also waiting' END            AS blocker_role,
  v.sessions_blocked                                          AS sessions_stuck_behind,
  b.state                                                     AS blocker_state,
  date_trunc('second', now() - b.xact_start)                  AS blocker_txn_age,
  left(regexp_replace(b.query, '\s+', ' ', 'g'), 90)          AS blocker_query,
  w.blocked_pid,
  date_trunc('second', now() - x.query_start)                 AS blocked_waiting_for,
  left(regexp_replace(x.query, '\s+', ' ', 'g'), 90)          AS blocked_query,
  CASE WHEN cardinality(pg_blocking_pids(w.blocker_pid)) = 0
       THEN CASE WHEN b.state LIKE 'idle in transaction%'
                 THEN 'SELECT pg_terminate_backend(' || w.blocker_pid || ');'
                 ELSE 'SELECT pg_cancel_backend(' || w.blocker_pid || ');' END
  END                                                         AS root_stop_command
FROM waits w
JOIN pg_stat_activity b ON b.pid = w.blocker_pid
JOIN pg_stat_activity x ON x.pid = w.blocked_pid
JOIN victims v          ON v.blocker_pid = w.blocker_pid
ORDER BY (cardinality(pg_blocking_pids(w.blocker_pid)) = 0) DESC,
         v.sessions_blocked DESC, blocked_waiting_for DESC;
