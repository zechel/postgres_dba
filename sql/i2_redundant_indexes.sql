--Redundant indexes

-- Use it to see redundant indexes list

-- This query doesn't need any additional extensions to be installed
-- (except plpgsql), and doesn't create anything (like views or something)
-- -- so feel free to use it in your clouds (Heroku, AWS RDS, etc)

-- (Keep in mind, that on replicas, the whole picture of index usage
-- is usually very different from master).

-- An index is reported as redundant to another index of the same table only
-- when the other index provides everything it provides:
--   * same access method, expressions and predicate;
--   * its key columns, operator classes, collations and ordering
--     (ASC/DESC, NULLS FIRST/LAST) are a prefix of the other index's keys
--     (btree only; other access methods need an exact match);
--   * its INCLUDE columns are present in the other index;
--   * if it is unique, the other index is an immediate unique index on exactly
--     the same key columns with the same NULLS [NOT] DISTINCT behaviour.
-- Primary keys and indexes that back a constraint are never reported.
-- Of two equivalent indexes, only the newer one is reported.
-- Always review the definitions before dropping anything.

with index_data as (
  select
    i.indexrelid,
    i.indrelid,
    am.amname,
    i.indnkeyatts,
    i.indisunique,
    i.indisprimary,
    i.indimmediate,
    coalesce((to_jsonb(i) ->> 'indnullsnotdistinct')::boolean, false) as nulls_not_distinct,
    exists (select from pg_constraint c where c.conindid = i.indexrelid) as backs_constraint,
    (i.indkey::int2[])[0:i.indnkeyatts - 1] as key_attnums,
    (i.indkey::int2[])[i.indnkeyatts:i.indnatts - 1] as include_attnums,
    i.indkey::int2[] as all_attnums,
    (i.indclass::oid[])[0:i.indnkeyatts - 1] as opclasses,
    (i.indcollation::oid[])[0:i.indnkeyatts - 1] as collations,
    (i.indoption::int2[])[0:i.indnkeyatts - 1] as options,
    pg_get_expr(i.indexprs, i.indrelid) as exprs,
    pg_get_expr(i.indpred, i.indrelid) as pred
  from pg_index i
  join pg_class ci on ci.oid = i.indexrelid
  join pg_namespace n on n.oid = ci.relnamespace
  join pg_am am on am.oid = ci.relam
  where
    i.indisvalid
    and i.indisready
    and n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_toast'
), redundant_pairs as (
  select
    b.indexrelid as index_id,
    a.indexrelid as reason_index_id
  from index_data as b
  join index_data as a on
    a.indrelid = b.indrelid -- same table
    and a.indexrelid <> b.indexrelid -- NOT same index
  where
    a.amname = b.amname
    and not b.indisprimary
    and not b.backs_constraint
    and b.indnkeyatts <= a.indnkeyatts
    and (b.amname = 'btree' or b.indnkeyatts = a.indnkeyatts)
    and b.key_attnums = a.key_attnums[1:b.indnkeyatts]
    and b.opclasses = a.opclasses[1:b.indnkeyatts]
    and b.collations = a.collations[1:b.indnkeyatts]
    and b.options = a.options[1:b.indnkeyatts]
    and b.include_attnums <@ a.all_attnums
    and b.exprs is not distinct from a.exprs
    and (b.exprs is null or b.key_attnums = a.key_attnums)
    and b.pred is not distinct from a.pred
    and (
      not b.indisunique
      or (
        a.indisunique
        and a.indimmediate
        and b.key_attnums = a.key_attnums
        and b.nulls_not_distinct = a.nulls_not_distinct
      )
    )
), redundant as (
  -- Equivalent indexes are redundant to each other: keep the older one.
  select p.*
  from redundant_pairs p
  where not exists (
    select
    from redundant_pairs r
    where
      r.index_id = p.reason_index_id
      and r.reason_index_id = p.index_id
      and p.index_id < p.reason_index_id
  )
)
select
  tnsp.nspname as schema_name,
  trel.relname as table_name,
  pg_relation_size(trel.oid) as table_size_bytes,
  irel.relname as index_name,
  b.amname as access_method,
  string_agg(r.reason_index_id::regclass::text, ', ' order by r.reason_index_id) as redundant_to,
  string_agg(pg_get_indexdef(r.reason_index_id), ', ' order by r.reason_index_id) as main_index_def,
  string_agg(pg_size_pretty(pg_relation_size(r.reason_index_id)), ', ' order by r.reason_index_id) as main_index_size,
  pg_get_indexdef(b.indexrelid) as index_def,
  pg_relation_size(b.indexrelid) as index_size_bytes,
  s.idx_scan as index_usage,
  exists (
    select
    from pg_constraint c
    where
      c.contype = 'f'
      and c.conrelid = b.indrelid
      and cardinality(c.conkey) <= b.indnkeyatts
      and c.conkey <@ b.key_attnums[1:cardinality(c.conkey)]
  ) as supports_fk
from redundant r
join index_data b on b.indexrelid = r.index_id
join pg_class irel on irel.oid = b.indexrelid
join pg_class trel on trel.oid = b.indrelid
join pg_namespace tnsp on tnsp.oid = trel.relnamespace
left join pg_stat_user_indexes s on s.indexrelid = b.indexrelid
group by
  b.indexrelid,
  b.indrelid,
  b.indnkeyatts,
  b.key_attnums,
  b.amname,
  tnsp.nspname,
  trel.oid,
  trel.relname,
  irel.relname,
  s.idx_scan
order by index_size_bytes desc, schema_name, table_name, index_name;
