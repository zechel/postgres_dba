--Tables without primary keys, ordered by total size

select
  n.nspname as schema,
  c.relname as table_name,
  case c.relkind
    when 'p' then 'partitioned'
    else 'table'
  end as table_type,
  pg_size_pretty(pg_total_relation_size(c.oid)) as total_size,
  c.reltuples::bigint as estimated_rows,
  coalesce(s.seq_scan, 0) as seq_scans,
  coalesce(s.n_tup_ins, 0) as inserted,
  coalesce(s.n_tup_upd, 0) as updated,
  coalesce(s.n_tup_del, 0) as deleted
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where c.relkind in ('r', 'p')
  and n.nspname not in ('pg_catalog', 'information_schema')
  and not exists (
    select 1
    from pg_index i
    where i.indrelid = c.oid
      and i.indisprimary
  )
order by pg_total_relation_size(c.oid) desc
limit 50;
