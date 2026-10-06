--Cancel Statement (pg_cancel_backend)

\prompt 'PID to Cancel: ' postgres_pid

select :'postgres_pid' ~ '^[0-9]+$' as postgres_dba_valid_pid \gset

\if :postgres_dba_valid_pid
  SELECT pg_cancel_backend(:'postgres_pid'::int);
\else
  \echo 'Invalid PID:' :'postgres_pid'
\endif

\unset postgres_pid
\unset postgres_dba_valid_pid
