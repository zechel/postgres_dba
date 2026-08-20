--Risky sessions: blocked, active >30s, transaction >5m or idle-in-transaction >1m

select
  case
    when cardinality(pg_blocking_pids(pid)) > 0 then 'BLOCKED'
    when state like 'idle in transaction%' then 'IDLE IN TX'
    when xact_start < clock_timestamp() - interval '5 minutes' then 'LONG TX'
    else 'LONG QUERY'
  end as risk,
  pid,
  usename as username,
  datname as database,
  application_name,
  client_addr,
  state,
  clock_timestamp() - xact_start as transaction_age,
  clock_timestamp() - query_start as query_age,
  clock_timestamp() - state_change as state_age,
  wait_event_type,
  wait_event,
  pg_blocking_pids(pid) as blocked_by,
  age(backend_xmin) as xmin_age,
  left(regexp_replace(query, e'[\n\r\t ]+', ' ', 'g'), 500) as query
from pg_stat_activity
where pid <> pg_backend_pid()
  and backend_type = 'client backend'
  and (
    cardinality(pg_blocking_pids(pid)) > 0
    or (
      state like 'idle in transaction%'
      and state_change < clock_timestamp() - interval '1 minute'
    )
    or xact_start < clock_timestamp() - interval '5 minutes'
    or (
      state = 'active'
      and query_start < clock_timestamp() - interval '30 seconds'
    )
  )
order by
  cardinality(pg_blocking_pids(pid)) > 0 desc,
  xact_start nulls last,
  query_start nulls last
limit 50;
