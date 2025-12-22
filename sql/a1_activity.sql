--Current activity: count of current connections grouped by database, username, state
WITH 
activity AS (select
  CASE WHEN (usename IS NULL) AND (datname IS NULL) THEN '** No User **' 
        WHEN usename IS NULL THEN '** No User **' 
        ELSE usename END AS "User Name",
  CASE WHEN (usename IS NULL) AND (datname IS NULL) THEN '** No Database **' 
        WHEN datname IS NULL THEN '** No Database **' 
        ELSE datname END AS "Database",
  CASE WHEN state IS NULL THEN '** No State **' 
        ELSE state END AS "Current State",  
  count(*) as count,
  count(*) filter (where state_change < now() - interval '1 minute') as "State changed >1m ago",
  count(*) filter (where state_change < now() - interval '1 hour') as "State changed >1h ago"
from pg_stat_activity
group by datname, usename, state
order by
  usename is null desc,
  datname is null desc,
  2 asc,
  3 asc,
  count(*) desc
), 
totalsessions AS (
    SELECT SUM(a.count) AS total FROM activity a
)
select a.* from activity a 
UNION ALL
SELECT '--------------', 'TOTAL', '--------------', SUM(b.count), NULL, NULL FROM activity b
;