--Replication slots: state, retained WAL and transaction horizons

with slots as (
  select
    s.*,
    case
      when restart_lsn is null then null
      else pg_wal_lsn_diff(:postgres_dba_current_wal_lsn(), restart_lsn)
    end as retained_wal_bytes
  from pg_replication_slots s
)
select
  case
    when wal_status = 'lost' then 'CRITICAL'
    when not active and wal_status in ('extended', 'unreserved') then 'WARNING'
    when not active then 'INACTIVE'
    else 'OK'
  end as status,
  slot_name,
  slot_type,
  database,
  active,
  active_pid,
  temporary,
  wal_status,
  case
    when retained_wal_bytes is null then null
    else pg_size_pretty(greatest(retained_wal_bytes, 0)::bigint)
  end as retained_wal,
  pg_size_pretty(safe_wal_size) as safe_wal_remaining,
  age(xmin) as xmin_age,
  age(catalog_xmin) as catalog_xmin_age,
  restart_lsn,
  confirmed_flush_lsn
from slots
order by retained_wal_bytes desc nulls last, slot_name;
