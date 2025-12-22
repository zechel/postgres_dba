--Duplicate indexes

SELECT current_database() as "Database",
pg_size_pretty(SUM(pg_relation_size(idx))::BIGINT) AS "Size",
       (array_agg(idx))[1] AS "Index 1", 
       (array_agg(idx))[2] AS "Index 2",
       (array_agg(idx))[3] AS idx3, 
       (array_agg(idx))[4] AS idx4
FROM (
    SELECT indexrelid::regclass AS idx, (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
                                         COALESCE(indexprs::text,'')||E'\n' || COALESCE(indpred::text,'')) AS KEY
    FROM pg_index) sub
GROUP BY KEY HAVING COUNT(*)>1
ORDER BY SUM(pg_relation_size(idx)) DESC;