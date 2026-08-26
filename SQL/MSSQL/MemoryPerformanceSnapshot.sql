/*
<documentation>
<summary>Get SQL Server memory detailed information.</summary>
<returns>3 row sets: 1 - countes info; 2 - min, max, target memory info; 3 - detailed tree memory info.</returns>
<created>?</created>
<modified>2020-02-04 by Konstantin Taranov</modified>
<version>1.0</version>
<sourceLink>https://github.com/ktaranov/sqlserver-kit/blob/master/Scripts/SQLServer_Memory_Information.sql</sourceLink>
</documentation>
*/

SET NOCOUNT ON;

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SET LOCK_TIMEOUT 10000;

DECLARE @ServiceName NVARCHAR (100);

SET @ServiceName = CASE
                        WHEN @@SERVICENAME = 'MSSQLSERVER'
                             THEN 'SQLServer:'
                        ELSE 'MSSQL$' + @@SERVICENAME + ':'
                   END;

DECLARE @Perf TABLE
(
    [object_name]     NVARCHAR (20)   NULL
  , [counter_name]    NVARCHAR (128)  NULL
  , [instance_name]   NVARCHAR (128)  NULL
  , [cntr_value]      BIGINT          NULL
  , [formatted_value] NUMERIC (20, 2) NULL
  , [shortname]       NVARCHAR (20)   NULL
);

INSERT INTO @Perf
(
    [object_name]
  , [counter_name]
  , [instance_name]
  , [cntr_value]
  , [formatted_value]
  , [shortname]
)
SELECT
    CASE
         WHEN CHARINDEX('Memory Manager', [object_name]) > 0
              THEN 'Memory Manager'
         WHEN CHARINDEX('Buffer Manager', [object_name]) > 0
              THEN 'Buffer Manager'
         WHEN CHARINDEX('Plan Cache', [object_name]) > 0
              THEN 'Plan Cache'
         WHEN CHARINDEX('Buffer Node', [object_name]) > 0
              THEN 'Buffer Node' -- 2008
         WHEN CHARINDEX('Memory Node', [object_name]) > 0
              THEN 'Memory Node' -- 2012
         WHEN CHARINDEX('Cursor', [object_name]) > 0
              THEN 'Cursor'
         ELSE NULL
    END                                                           AS [object_name]
  , CAST(RTRIM([counter_name]) AS NVARCHAR (100))                 AS [counter_name]
  , RTRIM([instance_name])                                        AS [instance_name]
  , [cntr_value]
  , CAST(NULL AS DECIMAL (20, 2))                                 AS [formatted_value]
  , SUBSTRING([counter_name], 1, PATINDEX('% %', [counter_name])) AS [shortname]
FROM
    [sys].[dm_os_performance_counters]
WHERE
    (
        [object_name] LIKE @ServiceName + 'Buffer Node%' -- LIKE is faster than =. I have no idea why
        OR [object_name] LIKE @ServiceName + 'Buffer Manager%'
        OR [object_name] LIKE @ServiceName + 'Memory Node%'
        OR [object_name] LIKE @ServiceName + 'Plan Cache%'
    )
    AND (
            [counter_name] LIKE '%pages %'
            OR [counter_name] LIKE '%Node Memory (KB)%'
            OR [counter_name] = 'Page life expectancy'
        )
    OR (
           [object_name] = @ServiceName + 'Memory Manager'
           AND [counter_name] IN
                   (   'Granted Workspace Memory (KB)', 'Maximum Workspace Memory (KB)', 'Memory Grants Outstanding'
                     , 'Memory Grants Pending', 'Target Server Memory (KB)', 'Total Server Memory (KB)'
                     , 'Connection Memory (KB)', 'Lock Memory (KB)', 'Optimizer Memory (KB)', 'SQL Cache Memory (KB)'
                     -- for 2012
                     , 'Free Memory (KB)', 'Reserved Server Memory (KB)', 'Database Cache Memory (KB)'
                     , 'Stolen Server Memory (KB)'
                   )
       )
    OR (
           [object_name] LIKE @ServiceName + 'Cursor Manager by Type%'
           AND [counter_name] = 'Cursor memory usage'
           AND [instance_name] = '_Total'
       );

-- Add unit to 'Cursor memory usage'
UPDATE
    @Perf
SET
    [counter_name] = [counter_name] + ' (KB)'
WHERE
    [counter_name] = 'Cursor memory usage';

-- Convert values from pages and KB to MB and rename counters accordingly
UPDATE
    @Perf
SET
    [counter_name] = REPLACE(REPLACE(REPLACE([counter_name], ' pages', ''), ' (KB)', ''), ' (MB)', '')
  , [formatted_value] = CASE
                             WHEN [counter_name] LIKE '%pages'
                                  THEN [cntr_value] / 128.
                             WHEN [counter_name] LIKE '%(KB)'
                                  THEN [cntr_value] / 1024.
                             ELSE [cntr_value]
                        END;

-- Delete some pre 2012 counters for 2012 in order to remove duplicates
DELETE
[P2008]
FROM
    @Perf            AS [P2008]
    INNER JOIN @Perf AS [P2012]
               ON REPLACE([P2008].[object_name], 'Buffer', 'Memory') = [P2012].[object_name]
                  AND [P2008].[shortname] = [P2012].[shortname]
WHERE
    [P2008].[object_name] IN
        ( 'Buffer Manager', 'Buffer Node' );

-- Update counter/object names so they look like in 2012
UPDATE
    [PC]
SET
    [PC].[object_name] = REPLACE([PC].[object_name], 'Buffer', 'Memory')
  , [PC].[counter_name] = ISNULL([M].[NewName], [PC].[counter_name])
FROM
    @Perf       AS [PC]
    LEFT JOIN (
                  SELECT
                      'Free'        AS [OldName]
                    , 'Free Memory' AS [NewName]
                  UNION ALL
                  SELECT
                      'Database'
                    , 'Database Cache Memory'
                  UNION ALL
                  SELECT
                      'Stolen'
                    , 'Stolen Server Memory'
                  UNION ALL
                  SELECT
                      'Reserved'
                    , 'Reserved Server Memory'
                  UNION ALL
                  SELECT
                      'Foreign'
                    , 'Foreign Node Memory'
              ) AS [M]
              ON [M].[OldName] = [PC].[counter_name]
                 AND [M].[NewName] NOT IN
                     (
                         SELECT
                             [counter_name]
                         FROM
                             @Perf
                         WHERE
                             [object_name] = 'Memory Manager'
                     )
WHERE
    [PC].[object_name] IN
        ( 'Buffer Manager', 'Buffer Node' );

-- Build Memory Tree
DECLARE @MemTree TABLE
(
    [Id]              INT             NULL
  , [ParentId]        INT             NULL
  , [counter_name]    NVARCHAR (128)  NULL
  , [formatted_value] NUMERIC (20, 2) NULL
  , [shortname]       NVARCHAR (20)   NULL
);

-- Level 5
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    1226            AS [Id]
  , 1225            AS [ParentId]
  , [instance_name] AS [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Plan Cache'
    AND [counter_name] IN
            ( 'Cache' )
    AND [instance_name] <> '_Total';

-- Level 4
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    1225                     AS [Id]
  , 1220                     AS [ParentId]
  , 'Plan ' + [counter_name] AS [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Plan Cache'
    AND [counter_name] IN
            ( 'Cache' )
    AND [instance_name] = '_Total'
UNION ALL
SELECT
    1222 AS [Id]
  , 1220 AS [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Cursor'
    OR (
           [object_name] = 'Memory Manager'
           AND [shortname] IN
                   ( 'Connection', 'Lock', 'Optimizer', 'SQL' )
       )
UNION ALL
SELECT
    1112 AS [Id]
  , 1110 AS [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Memory Manager'
    AND [shortname] IN
            ( 'Reserved' )
UNION ALL
SELECT
    [P].[ParentID] + 1                  AS [Id]
  , [P].[ParentID]                      AS [ParentID]
  , 'Used Workspace Memory'             AS [counter_name]
  , SUM([QRS].[used_memory_kb]) / 1024. AS [formatted_value]
  , NULL                                AS [shortname]
FROM
    [sys].[dm_exec_query_resource_semaphores] AS [QRS]
    CROSS JOIN (
                   SELECT
                       1220 AS [ParentID]
                   UNION ALL
                   SELECT
                       1110
               )                              AS [P]
GROUP BY
    [P].[ParentID];

-- Level 3
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    CASE [counter_name]
         WHEN 'Granted Workspace Memory'
              THEN 1110
         WHEN 'Stolen Server Memory'
              THEN 1220
         ELSE 1210
    END AS [Id]
  , CASE [counter_name]
         WHEN 'Granted Workspace Memory'
              THEN 1100
         ELSE 1200
    END AS [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Memory Manager'
    AND [counter_name] IN
            ( 'Stolen Server Memory', 'Database Cache Memory', 'Free Memory', 'Granted Workspace Memory' );

-- Level 2
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    CASE
         WHEN [counter_name] = 'Maximum Workspace Memory'
              THEN 1100
         ELSE 1200
    END  AS [Id]
  , 1000 AS [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Memory Manager'
    AND [counter_name] IN
            ( 'Total Server Memory', 'Maximum Workspace Memory' );

-- Level 1
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    1000 AS [Id]
  , NULL AS [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
FROM
    @Perf
WHERE
    [object_name] = 'Memory Manager'
    AND [counter_name] IN
            ( 'Target Server Memory' );

-- Level 4 -- 'Other Stolen Server Memory' = 'Stolen Server Memory' - SUM(Children of 'Stolen Server Memory')
INSERT @MemTree
(
    [Id]
  , [ParentId]
  , [counter_name]
  , [formatted_value]
  , [shortname]
)
SELECT
    1222                       AS [Id]
  , 1220                       AS [ParentId]
  , '<Other Memory Clerks>'    AS [counter_name]
  , (
        SELECT
            SUM([SSM].[formatted_value])
        FROM
            @MemTree AS [SSM]
        WHERE
            [SSM].[Id] = 1220
    ) - SUM([formatted_value]) AS [formatted_value]
  , 'Other Stolen'             AS [shortname]
FROM
    @MemTree
WHERE
    [ParentId] = 1220;

-- Results:

-- PLE and Memory Grants
SELECT
    [P].[counter_name] + ISNULL(' (Node: ' + NULLIF([P].[instance_name], '') + ')', '') AS [Counter Name]
  , [P].[cntr_value]                                                                    AS [Value]
  , CASE
         WHEN [P].[counter_name] = 'Page life expectancy'
              AND [R].[Value] <= 300 -- no less than 300
              THEN 300
         WHEN [P].[counter_name] = 'Page life expectancy'
              AND [R].[Value] > 300
              THEN [R].[Value]
         ELSE NULL
    END                                                                                 AS [RecommendedMinimum]
FROM
    @Perf AS [P]
    LEFT JOIN -- Recommended PLE calculations
    (
        SELECT
            [PD].[object_name]
          , [PD].[counter_name]
          , [PD].[instance_name]
          , CEILING([PD].[formatted_value] / 4096. * 5) * 60 AS [Value] -- 300 per every 4GB of Buffer Pool memory or around 60 seconds (1 minute) per every 819MB
        FROM
            @Perf AS [PD]
        WHERE
            [PD].[counter_name] = 'Database Cache Memory'
    )     AS [R]
    ON [R].[object_name] = [P].[object_name]
       AND [R].[instance_name] = [P].[instance_name]
WHERE
    (
        [P].[object_name] = 'Memory Manager'
        AND [P].[counter_name] IN
                ( 'Memory Grants Outstanding', 'Memory Grants Pending', 'Page life expectancy' )
    )
    OR -- For NUMA
    (
        [P].[object_name] = 'Memory Node'
        AND [P].[counter_name] = 'Page life expectancy'
        AND (
                SELECT
                    COUNT(DISTINCT [instance_name])
                FROM
                    @Perf
                WHERE
                    [object_name] = 'Memory Node'
            ) > 1
    )
ORDER BY
    [P].[counter_name] DESC
  , [P].[instance_name];

-- Get physical memory
-- You can also extract this information from sys.dm_os_sys_info but the column names have changed starting from 2012
IF OBJECT_ID('tempdb..#msver') IS NOT NULL
    DROP TABLE [#msver];

CREATE TABLE [#msver]
(
    [ID]             INT NULL
  , [Name]           sysname NULL
  , [Internal_Value] INT NULL
  , [Value]          NVARCHAR (512) NULL
);

INSERT INTO [#msver] ([ID], [Name], [Internal_Value], [Value])
EXEC [master].[dbo].[xp_msver] @ServiceName = 'PhysicalMemory';

-- Physical memory, config parameters and Target memory
SELECT (
           SELECT
               SUM(CAST([value_in_use] AS DECIMAL (20, 2)))
           FROM
               [sys].[configurations]
           WHERE
               [name] = 'min server memory (MB)'
       )                                         AS [min_server_mb]
     , (
           SELECT
               SUM(CAST([value_in_use] AS DECIMAL (20, 2)))
           FROM
               [sys].[configurations]
           WHERE
               [name] = 'max server memory (MB)'
       )                                         AS [max_server_mb]
     , (
           SELECT
               SUM([formatted_value])
           FROM
               @Perf
           WHERE
               [object_name] = 'Memory Manager'
               AND [counter_name] IN
                       ( 'Target Server Memory' )
       )                                         AS [target_mb]
     , CAST([Internal_Value] AS DECIMAL (20, 2)) AS [physical_mb]
FROM
    [#msver];

-- Memory tree
;

WITH
    [CTE] AS
        (
            SELECT
                0                             AS [lvl]
              , [counter_name]
              , [formatted_value]
              , [Id]
              , NULL                          AS [ParentId]
              , [shortname]
              , [formatted_value]             AS [TargetServerMemory]
              , CAST(NULL AS DECIMAL (20, 4)) AS [Perc]
              , CAST(NULL AS DECIMAL (20, 4)) AS [PercOfTarget]
            FROM
                @MemTree
            WHERE
                [ParentId] IS NULL
            UNION ALL
            SELECT
                [CTE].[lvl] + 1
              , CAST(REPLICATE(' ', 6 * ([CTE].[lvl])) + NCHAR(124) + REPLICATE(NCHAR(183), 3) + [MT].[counter_name] AS NVARCHAR (128))
              , [MT].[formatted_value]
              , [MT].[Id]
              , [MT].[ParentId]
              , [MT].[shortname]
              , [CTE].[TargetServerMemory]
              , CAST(ISNULL(1.0 * [MT].[formatted_value] / NULLIF([CTE].[formatted_value], 0), 0) AS DECIMAL (20, 4))    AS [Perc]
              , CAST(ISNULL(1.0 * [MT].[formatted_value] / NULLIF([CTE].[TargetServerMemory], 0), 0) AS DECIMAL (20, 4)) AS [PercOfTarget]
            FROM
                @MemTree AS [MT]
                INNER JOIN [CTE]
                           ON [MT].[ParentId] = [CTE].[Id]
        )
SELECT
    [CTE].[counter_name] AS [Counter Name]
  , CASE
         WHEN [CTE].[formatted_value] > 0
              THEN [CTE].[formatted_value]
         ELSE NULL
    END                  AS [Memory MB]
  , [CTE].[Perc]         AS [% of Parent]
  , CASE
         WHEN [CTE].[lvl] >= 2
              THEN [CTE].[PercOfTarget]
         ELSE NULL
    END                  AS [% of Target]
FROM
    [CTE]
ORDER BY
    ISNULL([CTE].[Id], 10000)
  , [CTE].[formatted_value] DESC;