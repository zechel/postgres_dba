--Duplicate indexes

-- Indexes are duplicates only when they are fully identical: same table,
-- access method, key columns, operator classes, collations, ordering
-- (ASC/DESC, NULLS FIRST/LAST), INCLUDE columns, expressions, predicate,
-- uniqueness, deferrability and NULLS [NOT] DISTINCT behaviour.
-- For indexes covered by a wider index, see i2.

with index_data as (
  select
    i.indexrelid,
    i.indrelid,
    ci.relam,
    i.indisunique,
    i.indimmediate,
    coalesce((to_jsonb(i) ->> 'indnullsnotdistinct')::boolean, false) as nulls_not_distinct,
    (i.indkey::int2[])[0:i.indnkeyatts - 1] as key_attnums,
    (
      select coalesce(array_agg(x order by x), '{}')
      from unnest((i.indkey::int2[])[i.indnkeyatts:i.indnatts - 1]) x
    ) as include_attnums,
    (i.indclass::oid[])[0:i.indnkeyatts - 1] as opclasses,
    (i.indcollation::oid[])[0:i.indnkeyatts - 1] as collations,
    (i.indoption::int2[])[0:i.indnkeyatts - 1] as options,
    coalesce(pg_get_expr(i.indexprs, i.indrelid), '') as exprs,
    coalesce(pg_get_expr(i.indpred, i.indrelid), '') as pred
  from pg_index i
  join pg_class ci on ci.oid = i.indexrelid
  join pg_namespace n on n.oid = ci.relnamespace
  where
    n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_toast'
)
SELECT current_database() as "Database",
pg_size_pretty(SUM(pg_relation_size(indexrelid))::BIGINT) AS "Size",
       (array_agg(indexrelid::regclass order by indexrelid))[1] AS "Index 1",
       (array_agg(indexrelid::regclass order by indexrelid))[2] AS "Index 2",
       (array_agg(indexrelid::regclass order by indexrelid))[3] AS idx3,
       (array_agg(indexrelid::regclass order by indexrelid))[4] AS idx4
FROM index_data
GROUP BY
  indrelid, relam, indisunique, indimmediate, nulls_not_distinct,
  key_attnums, include_attnums, opclasses, collations, options, exprs, pred
HAVING COUNT(*)>1
ORDER BY SUM(pg_relation_size(indexrelid)) DESC;
