# Postgres health checks: 3 free, tested diagnostic scripts

Three read-only SQL scripts that answer the questions you need answered when PostgreSQL misbehaves. Every row ends in a plain-English verdict: **OK**, **WATCH** or **ACT**.

| Script | Answers |
|---|---|
| `01_health_overview.sql` | Is anything on fire right now? Fifteen vital signs on one screen. |
| `06_lock_blocking_tree.sql` | Queries are hanging. Who is the **root** blocker, and how many sessions are stuck behind it? |
| `15_integer_overflow_risk.sql` | Which `serial` / `integer` ID columns are about to run out of numbers (and break every INSERT)? |

**Tested on PostgreSQL 14, 15, 16, 17 and 18**, as a superuser and as a restricted `pg_monitor` user (the kind of account you get on RDS and Cloud SQL).

## Run them

Download the scripts with the green **Code** button → **Download ZIP**, or:

```bash
git clone https://github.com/CosmicPotter/postgres-health-checks.git
cd postgres-health-checks
```

Then run any script:

```bash
psql "postgresql://USER@HOST:5432/DBNAME" -f scripts/15_integer_overflow_risk.sql
```

Or paste any script into pgAdmin, DBeaver, DataGrip, TablePlus, or your provider's SQL console. They only read Postgres's statistics and catalog views. They never change anything.

For full visibility, run them as a user with the built-in `pg_monitor` role:

```sql
GRANT pg_monitor TO your_user;
```

## Why the overflow check is different

Most overflow checks look at the **sequence**. This one checks the **column**. Databases that started on old Postgres versions often have a 64-bit sequence feeding a 32-bit `integer` column. A sequence-only check says "0% used", and the column overflows at 2,147,483,647 anyway.

It also refuses to guess. Without permission to read a sequence, Postgres shows a blank instead of raising an error. An early version of this script read that blank as zero and reported a column at 93% as "0%, OK". This version reports **UNKNOWN** and gives you the exact `GRANT` you need.

## Want the other 14 checks and what to do about each one?

These three scripts come from **[The Slow Postgres Playbook](https://cosmicpotter.gumroad.com/l/slow-postgres-playbook)** by Cosmic Potter: 17 tested diagnostic scripts, a one-command read-only report, and a 54-page guide that explains every verdict and how to fix it safely. It covers unused, duplicate and missing indexes, unindexed foreign keys, dead rows and bloat, stale statistics, what's blocking VACUUM, wraparound risk, disk-spilling queries, and config defaults that hurt.

## License

MIT. Use these three scripts however you like.
