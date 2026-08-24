--Lock trees, detailed (based on pg_blocking_pids())

-- Based on: https://gitlab.com/-/snippets/1890428
-- See also: https://postgres.ai/blog/20211018-postgresql-lock-trees
-- PostgreSQL 14+ is required for pg_locks.waitstart.

begin;

set local lock_timeout to '50ms';
set local statement_timeout to '100ms';

with recursive activity as (
  select
    pg_blocking_pids(pid) as blocked_by,
    *,
    age(clock_timestamp(), xact_start)::interval(0) as tx_time,
    age(
      clock_timestamp(),
      (
        select max(lck.waitstart)
        from pg_locks as lck
        where activity_source.pid = lck.pid
      )
    )::interval(0) as wait_time
  from pg_stat_activity as activity_source
  where state is distinct from 'idle'
), blockers as (
  select array_agg(distinct blocker_pid order by blocker_pid) as pids
  from (
    select unnest(blocked_by)
    from activity
  ) as blocker_list(blocker_pid)
), tree as (
  select
    activity.*,
    1 as level,
    activity.pid as top_blocker_pid,
    array[activity.pid] as path,
    array[activity.pid]::int[] as all_blockers_above
  from activity
  cross join blockers
  where
    array[pid] <@ blockers.pids
    and blocked_by = '{}'::int[]
  union all
  select
    activity.*,
    tree.level + 1 as level,
    tree.top_blocker_pid,
    path || array[activity.pid] as path,
    tree.all_blockers_above || array_agg(activity.pid) over ()
      as all_blockers_above
  from tree
  inner join activity
    on activity.blocked_by <> '{}'::int[]
    and activity.blocked_by <@ tree.all_blockers_above
    and not array[activity.pid] <@ tree.all_blockers_above
)
select
  pid,
  datname as database,
  usename as username,
  state,
  case
    when wait_event_type = 'Lock' then 'waiting'
    else replace(state, 'idle in transaction', 'idletx')
  end as tx_state,
  case
    when wait_event_type is not null
      then format('%s:%s', wait_event_type, wait_event)
    else 'CPU*'
  end as wait_event,
  wait_time,
  tx_time,
  backend_xid as xid,
  backend_xmin as xmin,
  to_char(age(backend_xid), 'FM999,999,999,990') as xid_age,
  to_char(2147483647 - age(backend_xmin), 'FM999,999,999,990') as xmin_ttf,
  level as blk_level,
  path as block_chain,
  blocked_by,
  (
    select count(distinct blocked_tree.pid)
    from tree as blocked_tree
    where
      array[tree.pid] <@ blocked_tree.path
      and blocked_tree.pid <> tree.pid
  ) as qtd_blk,
  format(
    '%s %s%s',
    lpad('[' || pid::text || ']', 9, ' '),
    repeat('.', level - 1) || case when level > 1 then ' ' end,
    left(query, 1000)
  ) as query
from tree
order by top_blocker_pid, level, pid;

commit;
