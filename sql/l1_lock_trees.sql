with recursive activity as (
  select
    pg_blocking_pids(pid) blocked_by, *, age(clock_timestamp(), xact_start)::interval(0) as tx_time,
    -- "pg_locks.waitstart" – PG14- only:
    -- age(clock_timestamp(), state_change) as wait_age
    -- "pg_locks.waitstart" – PG14+ only:
    age(clock_timestamp(), (select max(l.waitstart) from pg_locks l where a.pid = l.pid))::interval(0) as wait_time
  from pg_stat_activity a
  where state is distinct from 'idle'
), blockers as (
  select array_agg(distinct c order by c) as pids
  from (select unnest(blocked_by) from activity
  ) as dt(c)
), tree as (
  select activity.*, 1::int as level, activity.pid as top_blocker_pid, array[activity.pid] as path,
    array[activity.pid]::int[] as all_blockers_above
  from activity, blockers
  where
    array[pid] <@ blockers.pids
    and blocked_by = '{}'::int[]
  union all
  select activity.*, tree.level + 1 as level, tree.top_blocker_pid, path || array[activity.pid] as path,
    tree.all_blockers_above || array_agg(activity.pid) over () as all_blockers_above
  from activity, tree
  where
    not array[activity.pid] <@ tree.all_blockers_above
    and activity.blocked_by <> '{}'::int[]
    and activity.blocked_by <@ tree.all_blockers_above
)
select
  datname as database, usename as username, state, pid,
  case when wait_event_type <> 'Lock' then replace(state, 'idle in transaction', 'idletx') else 'waiting' end as tx_state,
  wait_event_type || ':' || wait_event as wait_event, wait_time, tx_time, 
  -- to_char(age(backend_xid), 'FM999,999,999,990') as xid_age,
  level as blk_level, path as block_chain,
  -- blocked_by, 
  (select count(distinct t1.pid) from tree t1 where array[tree.pid] <@ t1.path and t1.pid <> tree.pid) as qtd_blk,
  format('%s %s%s', lpad('[' || pid::text || ']', 9, ' '), repeat('.', level - 1) || case when level > 1 then ' ' end, left(query, 1000)) as query
from tree
order by top_blocker_pid, level, pid;
