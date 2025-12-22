--Cancel Statement (pg_cancel_backend)

\prompt 'PID to Cancel: ' postgres_pid

SELECT pg_cancel_backend(:postgres_pid);

\unset postgres_pid