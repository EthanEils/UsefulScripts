SELECT 
	  OBJECT_SCHEMA_NAME([ips].object_id) AS schema_name
	, OBJECT_NAME([ips].object_id) AS        object_name
	, [i].[name] AS                          [index_name]
	, [i].[type_desc] AS                     [index_type]
	, [ips].[avg_fragmentation_in_percent]
	, [ips].[avg_page_space_used_in_percent]
	, [ips].[page_count]
	, [ips].[alloc_unit_type_desc]
	, CONCAT('ALTER INDEX [', [i].[name], '] ON [', OBJECT_SCHEMA_NAME([ips].object_id),'].[', OBJECT_NAME([ips].object_id), '] REORGANIZE WITH(LOB_COMPACTION = ON); ', CHAR(10), CHAR(13), ' GO')
FROM   
	[sys].[dm_db_index_physical_stats](DB_ID(), DEFAULT, DEFAULT, DEFAULT, 'SAMPLED') AS [ips]
	INNER JOIN [sys].[indexes] AS [i]
		  ON [ips].object_id = [i].object_id
			AND [ips].[index_id] = [i].[index_id]
WHERE  1 = 1
	  --AND [ips].[avg_fragmentation_in_percent] > 5
ORDER BY 
	    OBJECT_NAME([ips].object_id)
	  , [i].[name];

GO

--ALTER INDEX <IndexName>
--	  ON <Table> REORGANIZE WITH(LOB_COMPACTION = ON);
--GO