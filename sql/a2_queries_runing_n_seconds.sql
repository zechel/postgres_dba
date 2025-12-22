--Queries running more than "N" seconds (Type the number of seconds)

\prompt 'Queries Running More Than "N" Seconds: ' postgres_number_seconds

SELECT pid, usename, datname, state, application_name, client_addr, age(query_start, clock_timestamp()), substring(query,1,40) as query
FROM pg_stat_activity 
WHERE state <> 'idle'
AND query NOT ILIKE '%pg_stat_activity%' 
AND query NOT ILIKE '%START_REPLICATION%'  
AND query != 'IDLE'
AND now() - query_start > concat(:postgres_number_seconds, ' seconds')::interval
ORDER BY age(query_start, clock_timestamp()) asc;

\unset postgres_number_seconds