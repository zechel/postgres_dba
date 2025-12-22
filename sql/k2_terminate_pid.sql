--Terminate Session (pg_terminate_backend)

\prompt 'PID to terminate: ' postgres_pid

SELECT pg_terminate_backend(:postgres_pid);

\unset postgres_pid