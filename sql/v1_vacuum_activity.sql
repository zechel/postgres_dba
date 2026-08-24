--Vacuum: running operations (detailed progress)

-- Based on: https://github.com/lesovsky/uber-scripts/blob/master/postgresql/sql/vacuum_activity.sql
-- PostgreSQL 17 changed dead-tuple counters from tuple counts to item IDs
-- and byte-based memory accounting.

\if :postgres_dba_pgvers_17plus
with data as (
  select
    p.pid,
    (select spcname from pg_tablespace where oid = reltablespace) as tblspace,
    p.datname as database,
    nspname as schema_name,
    relname as table_name,
    now() - activity.xact_start as duration,
    case
      when wait_event_type is not null
        then format('%s:%s', wait_event_type, wait_event)
      else 'CPU*'
    end as waiting,
    case
      when activity.query ~* '^autovacuum.*to prevent wraparound'
        then 'wraparound'
      when activity.query ~* '^vacuum' then 'user'
      else 'auto'
    end as mode,
    p.phase,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_size_pretty(
      pg_total_relation_size(relid) - pg_indexes_size(relid)
    ) as table_size,
    pg_size_pretty(pg_indexes_size(relid)) as index_size,
    pg_size_pretty(
      p.heap_blks_scanned * current_setting('block_size')::int
    ) as scanned,
    pg_size_pretty(
      p.heap_blks_vacuumed * current_setting('block_size')::int
    ) as vacuumed,
    round(
      100.0 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0),
      2
    ) as scanned_pct,
    round(
      100.0 * p.heap_blks_vacuumed / nullif(p.heap_blks_total, 0),
      2
    ) as vacuumed_pct,
    p.index_vacuum_count,
    p.num_dead_item_ids as dead_items,
    p.dead_tuple_bytes as dead_bytes,
    p.max_dead_tuple_bytes as max_dead_bytes,
    null::numeric as dead_pct,
    null::bigint as max_dead_items
  from pg_stat_progress_vacuum as p
  left join pg_stat_activity as activity using (pid)
  left join pg_class as relation on relation.oid = p.relid
  left join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
)
\else
with data as (
  select
    p.pid,
    (select spcname from pg_tablespace where oid = reltablespace) as tblspace,
    p.datname as database,
    nspname as schema_name,
    relname as table_name,
    now() - activity.xact_start as duration,
    case
      when wait_event_type is not null
        then format('%s:%s', wait_event_type, wait_event)
      else 'CPU*'
    end as waiting,
    case
      when activity.query ~* '^autovacuum.*to prevent wraparound'
        then 'wraparound'
      when activity.query ~* '^vacuum' then 'user'
      else 'auto'
    end as mode,
    p.phase,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_size_pretty(
      pg_total_relation_size(relid) - pg_indexes_size(relid)
    ) as table_size,
    pg_size_pretty(pg_indexes_size(relid)) as index_size,
    pg_size_pretty(
      p.heap_blks_scanned * current_setting('block_size')::int
    ) as scanned,
    pg_size_pretty(
      p.heap_blks_vacuumed * current_setting('block_size')::int
    ) as vacuumed,
    round(
      100.0 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0),
      2
    ) as scanned_pct,
    round(
      100.0 * p.heap_blks_vacuumed / nullif(p.heap_blks_total, 0),
      2
    ) as vacuumed_pct,
    p.index_vacuum_count,
    p.num_dead_tuples as dead_items,
    null::bigint as dead_bytes,
    null::bigint as max_dead_bytes,
    round(
      100.0 * p.num_dead_tuples / nullif(p.max_dead_tuples, 0),
      2
    ) as dead_pct,
    p.max_dead_tuples as max_dead_items
  from pg_stat_progress_vacuum as p
  left join pg_stat_activity as activity using (pid)
  left join pg_class as relation on relation.oid = p.relid
  left join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
)
\endif
select
  pid as "PID",
  duration::interval(0)::text as "Duration",
  mode as "Mode",
  database || coalesce(
    e'\n' || coalesce(nullif(schema_name, 'public') || '.', '')
      || table_name || coalesce(' [' || tblspace || ']', ''),
    ''
  ) as "DB & Table",
  table_size as "Table",
  index_size as "Indexes",
  waiting as "Wait",
  phase as "Phase",
  scanned || ' (' || coalesce(scanned_pct::text, 'n/a') || '%)'
    || e' scanned\n' || vacuumed || ' ('
    || coalesce(vacuumed_pct::text, 'n/a') || '%) vacuumed'
    as "Heap Vacuuming",
  coalesce(index_vacuum_count::text, 'n/a') || ' completed cycles,'
    || e'\n'
    || coalesce(
      case
        when dead_items > 10^12
          then round(dead_items::numeric / 10^12::numeric, 0)::text || 'T'
        when dead_items > 10^9
          then round(dead_items::numeric / 10^9::numeric, 0)::text || 'B'
        when dead_items > 10^6
          then round(dead_items::numeric / 10^6::numeric, 0)::text || 'M'
        when dead_items > 10^3
          then round(dead_items::numeric / 10^3::numeric, 0)::text || 'k'
        else dead_items::text
      end,
      'n/a'
    )
\if :postgres_dba_pgvers_17plus
    || e' dead item IDs collected\n'
    || coalesce(pg_size_pretty(dead_bytes), 'n/a') || ' of '
    || coalesce(pg_size_pretty(max_dead_bytes), 'n/a')
    || ' dead tuple memory'
\else
    || ' (' || coalesce(dead_pct::text, 'n/a')
    || e'%) dead tuples\nof max ~'
    || coalesce(
      case
        when max_dead_items > 10^12
          then round(max_dead_items::numeric / 10^12::numeric, 0)::text || 'T'
        when max_dead_items > 10^9
          then round(max_dead_items::numeric / 10^9::numeric, 0)::text || 'B'
        when max_dead_items > 10^6
          then round(max_dead_items::numeric / 10^6::numeric, 0)::text || 'M'
        when max_dead_items > 10^3
          then round(max_dead_items::numeric / 10^3::numeric, 0)::text || 'k'
        else max_dead_items::text
      end,
      'n/a'
    )
    || ' collected now'
\endif
    as "Index Vacuuming"
from data
order by duration desc;
