-- Note: querying sys.dm_os_buffer_descriptors
-- requires the VIEW_SERVER_STATE permission.
DECLARE @total_buffer INT;

SELECT
    @total_buffer = [cntr_value]
FROM
    [sys].[dm_os_performance_counters]
WHERE
    RTRIM([object_name]) LIKE '%Buffer Manager'
    AND [counter_name] = 'Database Pages';

;WITH
    [src] AS
        (
            SELECT
                [database_id]
              , COUNT_BIG(*) AS [db_buffer_pages]
            FROM
                [sys].[dm_os_buffer_descriptors]
            --WHERE database_id BETWEEN 5 AND 32766
            GROUP BY
                [database_id]
        )
SELECT
    CASE [src].[database_id]
         WHEN 32767
              THEN 'Resource DB'
         ELSE DB_NAME([src].[database_id])
    END                                                                      AS [db_name]
  , [src].[database_id]                                                      AS [db_id]
  , [src].[db_buffer_pages]
  , [src].[db_buffer_pages] / 128                                            AS [db_buffer_MB]
  , CONVERT(DECIMAL (6, 3), [src].[db_buffer_pages] * 100.0 / @total_buffer) AS [db_buffer_percent]
FROM
    [src]
ORDER BY
    [db_buffer_MB] DESC;
