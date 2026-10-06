--Terminate Session (pg_terminate_backend)

\prompt 'PID to terminate: ' postgres_pid

select :'postgres_pid' ~ '^[0-9]+$' as postgres_dba_valid_pid \gset

\if :postgres_dba_valid_pid
  SELECT pg_terminate_backend(:'postgres_pid'::int);
\else
  \echo 'Invalid PID:' :'postgres_pid'
\endif

\unset postgres_pid
\unset postgres_dba_valid_pid
