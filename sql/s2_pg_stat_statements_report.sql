--Slowest queries report (PG 9.6+; requires pg_stat_statements)

-- Based on Data Egret's query_stat_total.sql. Version-specific column names
-- are defined once in warmup.psql; the report logic below is shared by every
-- supported PostgreSQL version.

select to_regclass('pg_stat_statements') is not null
  as postgres_dba_has_pg_stat_statements \gset

\if :postgres_dba_has_pg_stat_statements
with pg_stat_statements_slice as (
  select *
  from pg_stat_statements
  -- From the postgres database report the whole cluster; from any other
  -- database report only statements executed in the current database.
  where current_database() = 'postgres'
    or dbid = (
      select oid
      from pg_database
      where datname = current_database()
    )
), pg_stat_statements_normalized as (
  select
    p.*,
    translate(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              query,
              e'\\?(::[a-zA-Z_]+)?( *, *\\?(::[a-zA-Z_]+)?)+',
              '?',
              'g'
            ),
            e'\\$[0-9]+(::[a-zA-Z_]+)?( *, *\\$[0-9]+(::[a-zA-Z_]+)?)*',
            '$N',
            'g'
          ),
          e'--.*$',
          '',
          'ng'
        ),
        e'/\\*.*?\\*/',
        '',
        'g'
      ),
      e'\r',
      ''
    ) as query_normalized
  from pg_stat_statements_slice p
), totals as (
  select
    sum(:postgres_dba_pgss_total_time)::numeric as total_time,
    sum(
      (:postgres_dba_pgss_read_time)
      + (:postgres_dba_pgss_write_time)
    )::numeric as io_time,
    greatest(
      sum(:postgres_dba_pgss_total_time)
      - sum(
        (:postgres_dba_pgss_read_time)
        + (:postgres_dba_pgss_write_time)
      ),
      0
    )::numeric as non_io_time,
    sum(calls)::numeric as ncalls,
    sum(rows)::numeric as total_rows
  from pg_stat_statements_slice
), statements_aggregated as (
  select
    (select datname from pg_database where oid = p.dbid) as database,
    pg_get_userbyid(p.userid) as username,
    -- Keep the shortest representative query and avoid email-footer parsing.
    substring(
      translate(
        replace(
          (array_agg(query order by length(query)))[1],
          e'-- \n',
          e'--\n'
        ),
        e'\r',
        ''
      ),
      1,
      8192
    ) as query,
    sum(:postgres_dba_pgss_total_time)::numeric as total_time,
    sum(
      (:postgres_dba_pgss_read_time)
      + (:postgres_dba_pgss_write_time)
    )::numeric as io_time,
    sum(calls)::numeric as calls,
    sum(rows)::numeric as rows
  from pg_stat_statements_normalized p
  group by dbid, userid, md5(query_normalized)
), totals_readable as (
  select
    to_char(interval '1 millisecond' * total_time, 'HH24:MI:SS') as total_time,
    coalesce(100 * io_time / nullif(total_time, 0), 0)::numeric(20, 2)
      as io_time_percent,
    to_char(ncalls, 'FM999,999,999,990') as total_queries,
    (
      select to_char(count(*), 'FM999,999,990')
      from statements_aggregated
    ) as unique_queries
  from totals
), statements as (
  select
    coalesce(100 * a.total_time / nullif(t.total_time, 0), 0)
      as time_percent,
    coalesce(100 * a.io_time / nullif(t.io_time, 0), 0)
      as io_time_percent,
    coalesce(
      100 * greatest(a.total_time - a.io_time, 0)
        / nullif(t.non_io_time, 0),
      0
    ) as non_io_time_percent,
    to_char(interval '1 millisecond' * a.total_time, 'HH24:MI:SS')
      as total_time,
    (a.total_time / nullif(a.calls, 0))::numeric(20, 2) as avg_time,
    (
      greatest(a.total_time - a.io_time, 0) / nullif(a.calls, 0)
    )::numeric(20, 2) as avg_non_io_time,
    (a.io_time / nullif(a.calls, 0))::numeric(20, 2) as avg_io_time,
    to_char(a.calls, 'FM999,999,999,990') as calls,
    (100 * a.calls / nullif(t.ncalls, 0))::numeric(20, 2)
      as calls_percent,
    to_char(a.rows, 'FM999,999,999,990') as rows,
    coalesce(100 * a.rows / nullif(t.total_rows, 0), 0)::numeric(20, 2)
      as row_percent,
    a.database,
    a.username,
    a.query
  from statements_aggregated a
  cross join totals t
  where coalesce(
      greatest(a.total_time - a.io_time, 0) / nullif(t.non_io_time, 0),
      0
    ) >= 0.01
    or coalesce(a.io_time / nullif(t.io_time, 0), 0) >= 0.01
    or coalesce(a.calls / nullif(t.ncalls, 0), 0) >= 0.02
    or coalesce(a.rows / nullif(t.total_rows, 0), 0) >= 0.02
  union all
  select
    coalesce(100 * sum(a.total_time) / nullif(t.total_time, 0), 0),
    coalesce(100 * sum(a.io_time) / nullif(t.io_time, 0), 0),
    coalesce(
      100 * sum(greatest(a.total_time - a.io_time, 0))
        / nullif(t.non_io_time, 0),
      0
    ),
    to_char(interval '1 millisecond' * sum(a.total_time), 'HH24:MI:SS'),
    (sum(a.total_time) / nullif(sum(a.calls), 0))::numeric(20, 2),
    (
      sum(greatest(a.total_time - a.io_time, 0))
      / nullif(sum(a.calls), 0)
    )::numeric(20, 2),
    (sum(a.io_time) / nullif(sum(a.calls), 0))::numeric(20, 2),
    to_char(sum(a.calls), 'FM999,999,999,990'),
    (100 * sum(a.calls) / nullif(t.ncalls, 0))::numeric(20, 2),
    to_char(sum(a.rows), 'FM999,999,999,990'),
    coalesce(
      100 * sum(a.rows) / nullif(t.total_rows, 0),
      0
    )::numeric(20, 2),
    'all',
    'all',
    'other'
  from statements_aggregated a
  cross join totals t
  where not (
    coalesce(
      greatest(a.total_time - a.io_time, 0) / nullif(t.non_io_time, 0),
      0
    ) >= 0.01
    or coalesce(a.io_time / nullif(t.io_time, 0), 0) >= 0.01
    or coalesce(a.calls / nullif(t.ncalls, 0), 0) >= 0.02
    or coalesce(a.rows / nullif(t.total_rows, 0), 0) >= 0.02
  )
  group by t.total_time, t.io_time, t.non_io_time, t.ncalls, t.total_rows
), statements_readable as (
  select
    row_number() over (order by time_percent desc) as pos,
    to_char(time_percent, 'FM990.0') || '%' as time_percent,
    to_char(io_time_percent, 'FM990.0') || '%' as io_time_percent,
    to_char(non_io_time_percent, 'FM990.0') || '%' as non_io_time_percent,
    to_char(
      avg_io_time * 100 / coalesce(nullif(avg_time, 0), 1),
      'FM990.0'
    ) || '%' as avg_io_time_percent,
    total_time,
    avg_time,
    avg_non_io_time,
    avg_io_time,
    calls,
    calls_percent,
    rows,
    row_percent,
    database,
    username,
    query
  from statements
  where calls is not null
)
select
  e'total time:\t' || total_time || ' (IO: ' || io_time_percent || E')\n'
  || e'total queries:\t' || total_queries || ' (unique: '
  || unique_queries || E')\n'
  || 'report for '
  || case
    when current_database() = 'postgres' then 'all databases'
    else current_database() || ' database'
  end
  || E', version b1.0 @ PostgreSQL '
  || current_setting('server_version')
  || E'\ntracking '
  || current_setting('pg_stat_statements.track') || ' '
  || current_setting('pg_stat_statements.max') || ' queries, utilities '
  || current_setting('pg_stat_statements.track_utility')
  || ', logging '
  || case
    when current_setting('log_min_duration_statement') = '0' then 'all'
    when current_setting('log_min_duration_statement') = '-1' then 'none'
    when current_setting('log_min_duration_statement')::int > 1000
      then (
        current_setting('log_min_duration_statement')::numeric / 1000
      )::numeric(20, 1) || 's+'
    else current_setting('log_min_duration_statement') || 'ms+'
  end
  || E' queries\n'
  || (
    select coalesce(
      string_agg(
        'WARNING: database ' || datname || ' must be vacuumed within '
        || to_char(
          2147483647 - age(datfrozenxid),
          'FM999,999,999,990'
        ) || ' transactions',
        E'\n'
        order by age(datfrozenxid) desc
      ) || E'\n',
      ''
    )
    from pg_database
    where 2147483647 - age(datfrozenxid) < 200000000
  ) || E'\n'
from totals_readable
union all
(
  select
    e'=============================================================================================================\n'
    || 'pos:' || pos || E'\t total time: ' || total_time || ' ('
    || time_percent || ', IO: ' || io_time_percent || ', Non-IO: '
    || non_io_time_percent || E')\t calls: ' || calls || ' ('
    || calls_percent || E'%)\t avg_time: ' || avg_time || 'ms (IO: '
    || avg_io_time_percent || E')\nuser: ' || username || E'\t db: '
    || database || E'\t rows: ' || rows || ' (' || row_percent
    || E'%)\t query:\n' || query || E'\n'
  from statements_readable
  order by pos
);
\else
  \echo 'pg_stat_statements is not available in the current search_path.'
  \echo 'Install it in this database or add its schema to search_path.'
\endif
