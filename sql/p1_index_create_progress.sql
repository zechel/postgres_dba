--Index (re)creation progress (CREATE INDEX / REINDEX)

-- Based on: https://postgres.ai/blog/20220114-progress-bar-for-postgres-queries-lets-dive-deeper
-- Uses pg_stat_progress_create_index, available on every supported version.

select
  now(),
  activity.query_start as started_at,
  (now() - activity.query_start)::interval(0) as duration,
  format('[%s] %s', activity.pid, left(activity.query, 200))
    as pid_and_query,
  progress.index_relid::regclass as index_name,
  progress.relid::regclass as table_name,
  pg_size_pretty(pg_relation_size(progress.relid)) as table_size,
  case
    when activity.wait_event_type is not null
      then format('%s:%s', activity.wait_event_type, activity.wait_event)
    else 'CPU*'
  end as wait,
  progress.phase,
  format(
    '%s (%s of %s)',
    coalesce(
      round(
        100 * progress.blocks_done::numeric
          / nullif(progress.blocks_total, 0),
        2
      )::text || '%',
      'N/A'
    ),
    coalesce(progress.blocks_done::text, '?'),
    coalesce(progress.blocks_total::text, '?')
  ) as blocks_progress,
  format(
    '%s (%s of %s)',
    coalesce(
      round(
        100 * progress.tuples_done::numeric
          / nullif(progress.tuples_total, 0),
        2
      )::text || '%',
      'N/A'
    ),
    coalesce(progress.tuples_done::text, '?'),
    coalesce(progress.tuples_total::text, '?')
  ) as tuples_progress,
  progress.current_locker_pid,
  (
    select left(locker.query, 150)
    from pg_stat_activity as locker
    where locker.pid = progress.current_locker_pid
  ) as current_locker_query,
  format(
    '%s (%s of %s)',
    coalesce(
      round(
        100 * progress.lockers_done::numeric
          / nullif(progress.lockers_total, 0),
        2
      )::text || '%',
      'N/A'
    ),
    coalesce(progress.lockers_done::text, '?'),
    coalesce(progress.lockers_total::text, '?')
  ) as lockers_progress,
  format(
    '%s (%s of %s)',
    coalesce(
      round(
        100 * progress.partitions_done::numeric
          / nullif(progress.partitions_total, 0),
        2
      )::text || '%',
      'N/A'
    ),
    coalesce(progress.partitions_done::text, '?'),
    coalesce(progress.partitions_total::text, '?')
  ) as partitions_progress
from pg_stat_progress_create_index as progress
left join pg_stat_activity as activity
  on activity.pid = progress.pid
order by progress.index_relid;
