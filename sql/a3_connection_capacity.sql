--Connection capacity: usage, remaining slots and reserved slots

with settings as (
  select
    current_setting('max_connections')::integer as max_connections,
    current_setting('superuser_reserved_connections')::integer
      as superuser_reserved_connections,
    coalesce(
      nullif(current_setting('reserved_connections', true), ''),
      '0'
    )::integer as reserved_connections
), usage as (
  select count(*)::integer as used_connections
  from pg_stat_activity
  where backend_type = 'client backend'
)
select
  case
    when 100.0 * used_connections / max_connections >= 90 then 'CRITICAL'
    when 100.0 * used_connections / max_connections >= 80 then 'WARNING'
    else 'OK'
  end as status,
  used_connections,
  max_connections,
  max_connections - used_connections as remaining_connections,
  round(100.0 * used_connections / max_connections, 1) as used_percent,
  reserved_connections,
  superuser_reserved_connections,
  max_connections - reserved_connections - superuser_reserved_connections
    as regular_connection_limit
from settings
cross join usage;
