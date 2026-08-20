--Transaction ID wraparound risk by database and table

\echo 'Database XID/MXID age versus forced-autovacuum limits'
with settings as (
  select
    current_setting('autovacuum_freeze_max_age')::numeric as xid_max_age,
    current_setting('autovacuum_multixact_freeze_max_age')::numeric
      as mxid_max_age
), databases as (
  select
    d.datname,
    age(d.datfrozenxid)::numeric as xid_age,
    mxid_age(d.datminmxid)::numeric as mxid_age,
    pg_database_size(d.datname) as database_size,
    s.xid_max_age,
    s.mxid_max_age
  from pg_database d
  cross join settings s
  where d.datallowconn
)
select
  case
    when greatest(xid_age / xid_max_age, mxid_age / mxid_max_age) >= 1
      then 'OVERDUE'
    when greatest(xid_age / xid_max_age, mxid_age / mxid_max_age) >= 0.85
      then 'CRITICAL'
    when greatest(xid_age / xid_max_age, mxid_age / mxid_max_age) >= 0.70
      then 'WARNING'
    else 'OK'
  end as status,
  datname as database,
  pg_size_pretty(database_size) as size,
  xid_age::bigint,
  round(100 * xid_age / xid_max_age, 1) as xid_limit_percent,
  (xid_max_age - xid_age)::bigint as xids_until_forced_autovacuum,
  mxid_age::bigint,
  round(100 * mxid_age / mxid_max_age, 1) as mxid_limit_percent
from databases
order by greatest(xid_age / xid_max_age, mxid_age / mxid_max_age) desc;

\echo 'Current database: tables closest to forced anti-wraparound autovacuum'
with settings as (
  select
    current_setting('autovacuum_freeze_max_age')::numeric as xid_max_age,
    current_setting('autovacuum_multixact_freeze_max_age')::numeric
      as mxid_max_age
), table_ages as (
  select
    c.oid,
    n.nspname,
    c.relname,
    greatest(
      age(c.relfrozenxid),
      coalesce(age(t.relfrozenxid), 0)
    )::numeric as xid_age,
    greatest(
      mxid_age(c.relminmxid),
      coalesce(mxid_age(t.relminmxid), 0)
    )::numeric as mxid_age,
    s.xid_max_age,
    s.mxid_max_age
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_class t on t.oid = c.reltoastrelid
  cross join settings s
  where c.relkind in ('r', 'm')
    and c.relfrozenxid <> '0'::xid
), ranked as (
  select
    a.*,
    greatest(a.xid_age / a.xid_max_age, a.mxid_age / a.mxid_max_age)
      as limit_ratio
  from table_ages a
)
select
  case
    when limit_ratio >= 1 then 'OVERDUE'
    when limit_ratio >= 0.85 then 'CRITICAL'
    when limit_ratio >= 0.70 then 'WARNING'
    else 'OK'
  end as status,
  format('%I.%I', nspname, relname) as table_name,
  pg_size_pretty(pg_total_relation_size(oid)) as total_size,
  xid_age::bigint,
  round(100 * xid_age / xid_max_age, 1) as xid_limit_percent,
  (xid_max_age - xid_age)::bigint as xids_until_forced_autovacuum,
  mxid_age::bigint,
  round(100 * mxid_age / mxid_max_age, 1) as mxid_limit_percent,
  pg_stat_get_last_autovacuum_time(oid) as last_autovacuum
from ranked
order by limit_ratio desc, pg_total_relation_size(oid) desc
limit 30;

\echo 'Oldest transaction horizons that can prevent VACUUM progress'
select source, oldest_xid_age
from (
  select
    'active sessions (backend_xmin)' as source,
    max(age(backend_xmin)) as oldest_xid_age
  from pg_stat_activity
  union all
  select
    'prepared transactions',
    max(age(transaction))
  from pg_prepared_xacts
  union all
  select
    'streaming replicas (backend_xmin)',
    max(age(backend_xmin))
  from pg_stat_replication
  union all
  select
    'replication slots (xmin/catalog_xmin)',
    max(greatest(age(xmin), age(catalog_xmin)))
  from pg_replication_slots
) horizons
where oldest_xid_age is not null
order by oldest_xid_age desc;
