--Replication status for primary or replica

\if :postgres_dba_is_replica
  \echo 'Replica receive/replay status'
  select
    :postgres_dba_last_wal_receive_lsn() as receive_lsn,
    :postgres_dba_last_wal_replay_lsn() as replay_lsn,
    case
      when :postgres_dba_last_wal_receive_lsn() is null then null
      else pg_size_pretty(
        pg_wal_lsn_diff(
          :postgres_dba_last_wal_receive_lsn(),
          :postgres_dba_last_wal_replay_lsn()
        )::bigint
      )
    end as receive_replay_gap,
    pg_last_xact_replay_timestamp() as last_applied_at,
    case
      when :postgres_dba_last_wal_receive_lsn()
        = :postgres_dba_last_wal_replay_lsn() then interval '0'
      else clock_timestamp() - pg_last_xact_replay_timestamp()
    end as replay_time_lag,
    :postgres_dba_is_wal_replay_paused() as replay_paused;
\else
  \echo 'Primary streaming replication status'
  select
    pid,
    usename as username,
    application_name,
    client_addr,
    state,
    sync_state,
    reply_time,
    write_lag,
    flush_lag,
    replay_lag,
    pg_size_pretty(
      pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)::bigint
    ) as pending_wal,
    pg_size_pretty(
      pg_wal_lsn_diff(sent_lsn, write_lsn)::bigint
    ) as write_gap,
    pg_size_pretty(
      pg_wal_lsn_diff(write_lsn, flush_lsn)::bigint
    ) as flush_gap,
    pg_size_pretty(
      pg_wal_lsn_diff(flush_lsn, replay_lsn)::bigint
    ) as replay_gap,
    pg_size_pretty(
      pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint
    ) as total_lag
  from pg_stat_replication
  order by application_name, client_addr;
\endif
