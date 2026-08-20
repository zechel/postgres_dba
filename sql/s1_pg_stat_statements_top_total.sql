--Slowest queries by total time (PG 9.6+; requires pg_stat_statements)

-- Aggregates duplicate entries with the same query text, database and user.
-- Timing column aliases are defined in warmup.psql so this query remains a
-- single implementation across PostgreSQL versions.

select to_regclass('pg_stat_statements') is not null
  as postgres_dba_has_pg_stat_statements \gset

\if :postgres_dba_has_pg_stat_statements
select
  sum(calls) as calls,
  round(sum(:postgres_dba_pgss_total_time)::numeric, 2) as total_exec_time_ms,
  round(
    (
      sum(:postgres_dba_pgss_mean_time * calls)
      / nullif(sum(calls), 0)
    )::numeric,
    2
  ) as mean_exec_time_ms,
  format(
    '%s–%s',
    round(min(:postgres_dba_pgss_min_time)::numeric, 2),
    round(max(:postgres_dba_pgss_max_time)::numeric, 2)
  ) as min_max_exec_time_ms,
\if :postgres_dba_pgvers_13plus
  round(sum(total_plan_time)::numeric, 2) as total_plan_time_ms,
  round(
    (sum(mean_plan_time * plans) / nullif(sum(plans), 0))::numeric,
    2
  ) as mean_plan_time_ms,
  format(
    '%s–%s',
    round(min(min_plan_time)::numeric, 2),
    round(max(max_plan_time)::numeric, 2)
  ) as min_max_plan_time_ms,
\endif
  sum(rows) as rows,
  pg_get_userbyid(userid) as usr,
  (select datname from pg_database where oid = dbid) as db,
  query,
  sum(shared_blks_hit) as shared_blks_hit,
  sum(shared_blks_read) as shared_blks_read,
  sum(shared_blks_dirtied) as shared_blks_dirtied,
  sum(shared_blks_written) as shared_blks_written,
  sum(local_blks_hit) as local_blks_hit,
  sum(local_blks_read) as local_blks_read,
  sum(local_blks_dirtied) as local_blks_dirtied,
  sum(local_blks_written) as local_blks_written,
  sum(temp_blks_read) as temp_blks_read,
  sum(temp_blks_written) as temp_blks_written,
  round(sum(:postgres_dba_pgss_read_time)::numeric, 2) as io_read_time_ms,
  round(sum(:postgres_dba_pgss_write_time)::numeric, 2) as io_write_time_ms,
  array_agg(distinct queryid) as queryids
from pg_stat_statements
group by userid, dbid, query
order by sum(:postgres_dba_pgss_total_time) desc
limit 50;
\else
  \echo 'pg_stat_statements is not available in the current search_path.'
  \echo 'Install it in this database or add its schema to search_path.'
\endif
