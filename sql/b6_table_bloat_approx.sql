--Table bloat, approximate (requires pgstattuple; moderate cost)

--pgstattuple extension required
-- Uses pgstattuple_approx(), which consults the visibility map and skips
-- all-visible pages. On a vacuumed table this returns the same numbers as
-- pgstattuple() at a fraction of the cost, so this report sits between the
-- free estimates of "b1" and the full scans of "b3".
--
-- Caveats:
--   * a table that has never been vacuumed has an empty visibility map, so
--     nothing can be skipped and the cost approaches a full scan;
--   * free space of 15-25% is normal and healthy on tables with frequent
--     UPDATEs, because that space is reused. Look for the outliers;
--   * dead tuples awaiting VACUUM are not bloat. This report measures the
--     space that remains free after VACUUM has already run.
--
-- The size threshold keeps the scan away from the long tail of small
-- relations. Raise it on large databases.

select to_regprocedure('pgstattuple_approx(regclass)') is not null
  as postgres_dba_has_pgstattuple \gset

\if :postgres_dba_has_pgstattuple

\if :postgres_dba_interactive_mode
  \prompt 'Minimum table size to inspect, in MB [100]: ' postgres_dba_bloat_min_mb
\else
  \set postgres_dba_bloat_min_mb 100
\endif

with candidates as materialized (
  -- Materialized so the size filter is always applied before any relation is
  -- inspected. pgstattuple_approx() rejects views, partitioned tables and
  -- indexes, so only ordinary tables and materialized views are considered.
  select
    c.oid as relation_oid,
    nullif(c.reltoastrelid, 0) as toast_oid,
    n.nspname as schema_name,
    c.relname as table_name,
    pg_table_size(c.oid) as table_size
  from pg_class as c
  join pg_namespace as n on n.oid = c.relnamespace
  where
    c.relkind in ('r', 'm')
    and c.relpersistence in ('p', 'u')
    and n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_toast'
    and pg_table_size(c.oid) >= coalesce(
      nullif(:'postgres_dba_bloat_min_mb', '')::numeric,
      100
    ) * 1024 * 1024
), measured as (
  select
    candidates.*,
    heap.approx_free_space as heap_free_space,
    heap.approx_free_percent as heap_free_percent,
    heap.dead_tuple_count as dead_tuples,
    coalesce(toast.approx_free_space, 0) as toast_free_space
  from candidates
  cross join lateral pgstattuple_approx(candidates.relation_oid) as heap
  left join lateral pgstattuple_approx(candidates.toast_oid) as toast
    on candidates.toast_oid is not null
)
select
  coalesce(nullif(schema_name, 'public') || '.', '') || table_name as "Table",
  pg_size_pretty(table_size) as "Table size",
  round(heap_free_percent::numeric, 1) as "Heap waste, %",
  pg_size_pretty(heap_free_space::bigint) as "Heap waste",
  case
    when toast_oid is null then 'no toast'
    else pg_size_pretty(toast_free_space::bigint)
  end as "Toast waste",
  round(
    (100 * (heap_free_space + toast_free_space) / nullif(table_size, 0))::numeric,
    1
  ) as "Total waste, %",
  pg_size_pretty((heap_free_space + toast_free_space)::bigint) as "Total waste",
  dead_tuples as "Dead tuples"
from measured
order by (heap_free_space + toast_free_space) desc
limit 20;

\else
  \echo 'pgstattuple is not available in the current search_path.'
  \echo 'Install it in this database or add its schema to search_path.'
\endif
