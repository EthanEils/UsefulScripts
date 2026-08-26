;WITH
    [src] AS
        (
            SELECT
                [o].[name]               AS [Object]
              , [o].[type_desc]          AS [Type]
              , COALESCE([i].[name], '') AS [Index]
              , [i].[type_desc]          AS [Index_Type]
              , [p].[object_id]
              , [p].[index_id]
              , [au].[allocation_unit_id]
            FROM
                [sys].[partitions]                  AS [p]
                INNER JOIN [sys].[allocation_units] AS [au]
                           ON [p].[hobt_id] = [au].[container_id]
                INNER JOIN [sys].[objects]          AS [o]
                           ON [p].[object_id] = [o].[object_id]
                INNER JOIN [sys].[indexes]          AS [i]
                           ON [o].[object_id] = [i].[object_id]
                              AND [p].[index_id] = [i].[index_id]
            WHERE
                [au].[type] IN
                    ( 1, 2, 3 )
                AND [o].[is_ms_shipped] = 0
        )
SELECT
    [src].[Object]
  , [src].[Type]
  , [src].[Index]
  , [src].[Index_Type]
  , COUNT_BIG([b].[page_id])       AS [buffer_pages]
  , COUNT_BIG([b].[page_id]) / 128 AS [buffer_mb]
  , [src].[object_id]
FROM
    [src]
    INNER JOIN [sys].[dm_os_buffer_descriptors] AS [b]
               ON [src].[allocation_unit_id] = [b].[allocation_unit_id]
WHERE
    [b].[database_id] = DB_ID()
GROUP BY
    [src].[object_id]
  , [src].[Object]
  , [src].[Type]
  , [src].[Index]
  , [src].[Index_Type]
ORDER BY
    [buffer_pages] DESC;
