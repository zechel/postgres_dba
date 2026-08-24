--Storage parameters explicitly set on relations

-- Inventory only: values are reported as configured and are not tuning advice.
with relations_with_options as (
  select
    namespace.nspname as schema_name,
    relation.relname as object_name,
    format('%I.%I', namespace.nspname, relation.relname)
      as object_identity,
    case relation.relkind
      when 'r' then 'table'
      when 'i' then 'index'
      when 'm' then 'materialized view'
      when 'p' then 'partitioned table'
      when 'I' then 'partitioned index'
    end as object_type,
    pg_size_pretty(pg_relation_size(relation.oid)) as size,
    pg_relation_size(relation.oid) as size_bytes,
    relation.reloptions,
    relation.relispartition,
    parent.object_identity as parent_object
  from pg_class as relation
  inner join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  left join lateral (
    select format(
      '%I.%I',
      parent_namespace.nspname,
      parent_relation.relname
    ) as object_identity
    from pg_inherits as inheritance
    inner join pg_class as parent_relation
      on parent_relation.oid = inheritance.inhparent
    inner join pg_namespace as parent_namespace
      on parent_namespace.oid = parent_relation.relnamespace
    where inheritance.inhrelid = relation.oid
    order by inheritance.inhseqno
    limit 1
  ) as parent on true
  where
    relation.reloptions is not null
    and relation.relkind in ('r', 'i', 'm', 'p', 'I')
    and namespace.nspname not in ('pg_catalog', 'information_schema')
    and namespace.nspname !~ '^pg_toast'
    and namespace.nspname !~ '^pg_temp_'
), options as (
  select
    relations_with_options.*,
    option
  from relations_with_options
  cross join lateral unnest(reloptions) as configured(option)
)
select
  object_identity as "Object",
  object_type as "Type",
  case
    when relispartition then 'partition of ' || parent_object
    else null
  end as "Partition",
  size as "Size",
  split_part(option, '=', 1) as "Parameter",
  nullif(substring(option from position('=' in option) + 1), '')
    as "Configured value"
from options
order by
  parent_object nulls first,
  size_bytes desc,
  object_type,
  schema_name,
  object_name,
  option;
