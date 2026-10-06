#!/bin/bash
# Generate start.psql based on the contents of "sql" directory
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$( cd "$DIR/.." && pwd )"

# File names as referenced from the generated menu (relative to the repo root).
WARMUP="warmup.psql"
OUT="start.psql"

# Write to temporary files inside the repository and replace the outputs only
# after generation succeeds; files in the caller's directory are never touched.
WARMUP_TMP="$(mktemp "$ROOT/.$WARMUP.XXXXXX")"
OUT_TMP="$(mktemp "$ROOT/.$OUT.XXXXXX")"
trap 'rm -f "$WARMUP_TMP" "$OUT_TMP"' EXIT

cd "$ROOT"
cat > "$WARMUP_TMP" <<- VersCheck
-- check if "\if" is supported (psql 10+)
\if false
  \echo cannot work, you need psql version 10+ (Postgres server can be older)
  select 1/0;
\endif

select current_setting('server_version_num')::integer >= 170000 as postgres_dba_pgvers_17plus \gset

select current_setting('server_version_num')::integer >= 130000 as postgres_dba_pgvers_13plus \gset

-- Reports are interactive by default; automation overrides this with -v.
\if :{?postgres_dba_interactive_mode}
\else
  \set postgres_dba_interactive_mode true
\endif

-- Keep version-specific pg_stat_statements column names out of the reports.
-- PostgreSQL 13 renamed the execution-time columns and PostgreSQL 17 split
-- shared and local I/O timing.
\if :postgres_dba_pgvers_13plus
  \set postgres_dba_pgss_total_time total_exec_time
  \set postgres_dba_pgss_mean_time mean_exec_time
  \set postgres_dba_pgss_min_time min_exec_time
  \set postgres_dba_pgss_max_time max_exec_time
\else
  \set postgres_dba_pgss_total_time total_time
  \set postgres_dba_pgss_mean_time mean_time
  \set postgres_dba_pgss_min_time min_time
  \set postgres_dba_pgss_max_time max_time
\endif

\if :postgres_dba_pgvers_17plus
  \set postgres_dba_pgss_read_time 'shared_blk_read_time + local_blk_read_time'
  \set postgres_dba_pgss_write_time 'shared_blk_write_time + local_blk_write_time'
\else
  \set postgres_dba_pgss_read_time blk_read_time
  \set postgres_dba_pgss_write_time blk_write_time
\endif

select current_setting('server_version_num')::integer >= 100000 as postgres_dba_pgvers_10plus \gset
\if :postgres_dba_pgvers_10plus
  \set postgres_dba_last_wal_receive_lsn pg_last_wal_receive_lsn
  \set postgres_dba_last_wal_replay_lsn pg_last_wal_replay_lsn
  \set postgres_dba_is_wal_replay_paused pg_is_wal_replay_paused
\else
  \set postgres_dba_last_wal_receive_lsn pg_last_xlog_receive_location
  \set postgres_dba_last_wal_replay_lsn pg_last_xlog_replay_location
  \set postgres_dba_is_wal_replay_paused pg_is_xlog_replay_paused
\endif

select pg_is_in_recovery() as postgres_dba_is_replica \gset
\if :postgres_dba_is_replica
  \set postgres_dba_current_wal_lsn pg_last_wal_receive_lsn
\else
  \set postgres_dba_current_wal_lsn pg_current_wal_lsn
\endif

-- TODO: improve work with custom GUCs for Postgres 9.5 and older
select current_setting('server_version_num')::integer >= 90600 as postgres_dba_pgvers_96plus \gset
\if :postgres_dba_pgvers_96plus
  select coalesce(current_setting('postgres_dba.wide', true), 'off') = 'on' as postgres_dba_wide \gset
\else
  set client_min_messages to 'fatal';
  select :postgres_dba_wide as postgres_dba_wide \gset
  reset client_min_messages;
\endif
VersCheck

echo "\\ir $WARMUP" >> "$OUT_TMP"

echo "\\echo '\\033[1;35mMenu:\\033[0m'" >> "$OUT_TMP"
for f in ./sql/*.sql
do
  prefix=$(echo $f | sed -e 's/_.*$//g' -e 's/^.*\///g')
  desc=$(head -n1 $f | sed -e 's/^--//g')
  printf "%s '%4s – %s'\n" "\\echo" "$prefix" "$desc" >> "$OUT_TMP"
done
printf "%s '%4s – %s'\n" "\\echo" "q" "Quit" >> "$OUT_TMP"
echo "\\echo" >> "$OUT_TMP"
echo "\\echo Type your choice and press <Enter>:" >> "$OUT_TMP"
echo "\\prompt d_step_unq" >> "$OUT_TMP"
echo "select" >> "$OUT_TMP"

for f in ./sql/*.sql
do
  prefix=$(echo $f | sed -e 's/_.*$//g' -e 's/^.*\///g')
  echo ":'d_step_unq'::text = '$prefix' as d_step_is_$prefix," >> "$OUT_TMP"
done
echo ":'d_step_unq'::text = 'q' as d_step_is_q \\gset" >> "$OUT_TMP"

echo "\\if :d_step_is_q" >> "$OUT_TMP"
echo "  \\echo 'Bye!'" >> "$OUT_TMP"
echo "  \\echo" >> "$OUT_TMP"
for f in ./sql/*.sql
do
  prefix=$(echo $f | sed -e 's/_.*$//g' -e 's/^.*\///g')
  echo "\\elif :d_step_is_$prefix" >> "$OUT_TMP"
  echo "  \\ir $f" >> "$OUT_TMP"
  echo "  \\prompt 'Press <Enter> to continue…' d_dummy" >> "$OUT_TMP"
  echo "  \\ir ./$OUT" >> "$OUT_TMP"
done
echo "\\else" >> "$OUT_TMP"
echo "  \\echo" >> "$OUT_TMP"
echo "  \\echo '\\033[1;31mError:\\033[0m Unknown option! Try again.'" >> "$OUT_TMP"
echo "  \\echo" >> "$OUT_TMP"
echo "  \\ir ./$OUT" >> "$OUT_TMP"
echo "\\endif" >> "$OUT_TMP"

chmod 644 "$WARMUP_TMP" "$OUT_TMP"
mv -f "$WARMUP_TMP" "$ROOT/$WARMUP"
mv -f "$OUT_TMP" "$ROOT/$OUT"
trap - EXIT

echo "Done."
