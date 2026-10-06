--Queries running more than "N" seconds (Type the number of seconds)

\if :postgres_dba_interactive_mode
  \prompt 'Queries Running More Than "N" Seconds: ' postgres_number_seconds
\else
  \set postgres_number_seconds 0
\endif

-- An empty answer means zero seconds; anything else must be a plain number.
select
  coalesce(nullif(trim(:'postgres_number_seconds'), ''), '0') as postgres_number_seconds,
  coalesce(nullif(trim(:'postgres_number_seconds'), ''), '0') ~ '^[0-9]+(\.[0-9]+)?$' as postgres_dba_valid_seconds
\gset

\if :postgres_dba_valid_seconds
SELECT pid, usename, datname, state, application_name, client_addr,
  clock_timestamp() - query_start AS duration,
  substring(query,1,40) as query
FROM pg_stat_activity
WHERE state <> 'idle'
AND query NOT ILIKE '%pg_stat_activity%'
AND query NOT ILIKE '%START_REPLICATION%'
AND query != 'IDLE'
AND clock_timestamp() - query_start > :'postgres_number_seconds'::numeric * interval '1 second'
ORDER BY duration DESC;
\else
  \echo 'Invalid number of seconds:' :'postgres_number_seconds'
\endif

\unset postgres_number_seconds
\unset postgres_dba_valid_seconds
