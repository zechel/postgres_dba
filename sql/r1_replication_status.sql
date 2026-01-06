--Replication status

select pg_last_wal_receive_lsn() as "Receive",
pg_last_wal_replay_lsn() as "Replay", now(), 
pg_last_xact_replay_timestamp() "Last Applied Time",
now()-pg_last_xact_replay_timestamp() AS "Lag Time";