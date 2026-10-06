--Cleanup unused and redundant indexes – DO & UNDO migration DDL

-- Use it to generate a database migration (e.g. RoR's db:migrate or Sqitch)
-- to drop unused and redundant indexes.

-- This query generates a set of `DROP INDEX` statements, that
-- can be used in your migration script. Also, it generates
-- `CREATE INDEX`, put them to revert/rollback migration script.

-- It is also a good idea to manually double check all indexes being dropped.
-- WARNING here: when you are dropping an index B which is redundant to some index A,
-- check that you don't drop the A itself at the same time (it can be in "unused").
-- So if B is "redundant" to A and A is "unused", the script will suggest
-- dropping both. If so, it is probably better to drop B and leave A.
-- -- in this case there is a chance that A will be used. If it will still be unused,
-- you will drop it during the next cleanup routine procedure.

-- This query doesn't need any additional extensions to be installed
-- (except plpgsql), and doesn't create anything (like views or something)
-- -- so feel free to use it in your clouds (Heroku, AWS RDS, etc)

-- It also doesn't do anything except reading system catalogs and
-- printing NOTICEs, so you can easily run it on your
--  production *master* database.
-- (Keep in mind, that on replicas, the whole picture of index usage
-- is usually very different from master).

-- Redundancy uses the same rules as i2: an index is redundant only when
-- another index of the same table covers its keys, operator classes,
-- collations, ordering, INCLUDE columns, expressions, predicate and, for
-- unique indexes, the same uniqueness guarantee. Primary keys, unique indexes
-- without a unique equivalent and indexes backing constraints are never
-- suggested for removal.

with unused as (
  select
      format('unused (idx_scan: %s)', s.idx_scan)::text as reason,
      s.relid::regclass::text as table_name,
      s.indexrelid::regclass::text as index_name,
      pg_get_indexdef(s.indexrelid) as index_def,
      pg_size_pretty(pg_relation_size(s.indexrelid)) as index_size,
      s.indexrelid
  from pg_stat_user_indexes s
  join pg_stat_user_tables t on s.relid = t.relid
  join pg_index on pg_index.indexrelid = s.indexrelid
  where
      s.idx_scan = 0 /* < 10 or smth */
      and not pg_index.indisunique
      and not pg_index.indisprimary
      and not exists (select from pg_constraint c where c.conindid = s.indexrelid)
      and s.idx_scan::float/(coalesce(n_tup_ins,0)+coalesce(n_tup_upd,0)-coalesce(n_tup_hot_upd,0)+coalesce(n_tup_del,0)+1)::float<0.01
), index_data as (
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
    and b.include_attnums operator(pg_catalog.<@) a.all_attnums
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
), redundant_report as (
  select
    format('redundant to index: %s', r.reason_index_id::regclass)::text as reason,
    b.indrelid::regclass::text as table_name,
    b.indexrelid::regclass::text as index_name,
    pg_get_indexdef(b.indexrelid) as index_def,
    pg_size_pretty(pg_relation_size(b.indexrelid)) as index_size,
    b.indexrelid
  from redundant r
  join index_data b on b.indexrelid = r.index_id
  join pg_stat_user_indexes s on s.indexrelid = b.indexrelid
  where s.idx_scan = 0
), together as (
  select reason, table_name, index_name, index_size, index_def, indexrelid
  from unused
  union all
  select reason, table_name, index_name, index_size, index_def, indexrelid
  from redundant_report
), droplines as (
  select format('DROP INDEX CONCURRENTLY %s; -- %s, %s, table %s', index_name, max(index_size), string_agg(reason, ', ' order by reason), table_name) as line
  from together
  group by table_name, index_name
  order by table_name, index_name
), createlines as (
  select
    regexp_replace(
      format('%s; -- table %s', max(index_def), table_name),
      '^CREATE (UNIQUE )?INDEX ',
      'CREATE \1INDEX CONCURRENTLY '
    ) as line
  from together
  group by table_name, index_name
  order by table_name, index_name
)
select '-- DO migration: --' as run_in_separate_transactions
union all
select * from droplines
union all
select ''
union all
select '-- UNDO migration: --'
union all
select * from createlines;
