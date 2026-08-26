WITH
    [CatalogWithXml] AS
        (
            SELECT
                [ItemID]
              , [Path]
              , [Name]
              , [ParentID]
              , [Type]
              , [Content]
              , [Intermediate]
              , [SnapshotDataID]
              , [LinkSourceID]
              , [Property]
              , [Description]
              , [Hidden]
              , [CreatedByID]
              , [CreationDate]
              , [ModifiedByID]
              , [ModifiedDate]
              , [MimeType]
              , [SnapshotLimit]
              , [Parameter]
              , [PolicyID]
              , [PolicyRoot]
              , [ExecutionFlag]
              , [ExecutionTime]
              , [SubType]
              , [ComponentID]
              , [ContentSize]
              , (CONVERT(XML, CONVERT(VARBINARY (MAX), [Content]))) AS [ContentXml]
            FROM
                [dbo].[Catalog]
        )
  ,
    [SharedDataSources] AS
        (
            SELECT
                [ds].[ItemID]
              , [c].[Name]                                                                                AS [SharedDataSourceName]
              , [ds].[Name]                                                                               AS [LocalDataSourceName]
              , [c].[ContentXml].[value]('(/*:DataSourceDefinition/*:Extension)[1]', 'NVARCHAR(260)')     AS [DataProvider]
              , [c].[ContentXml].[value]('(/*:DataSourceDefinition/*:ConnectString)[1]', 'NVARCHAR(MAX)') AS [ConnectionString]
            FROM
                [dbo].[DataSource]    AS [ds]
                JOIN [CatalogWithXml] AS [c]
                     ON [ds].[Link] = [c].[ItemID]
        )
  ,
    [AllDataSources] AS
        (
            SELECT
                [r].[ItemID]
              , [r].[LocalDataSourceName]
              , [sds].[SharedDataSourceName]
              , CAST((CASE
                           WHEN [sds].[SharedDataSourceName] IS NOT NULL
                                THEN 1
                           ELSE 0
                      END
                     ) AS BIT)                                           AS [SharedDataSource]
              , ISNULL([r].[DataProvider], [sds].[DataProvider])         AS [DataProvider]
              , ISNULL([r].[ConnectionString], [sds].[ConnectionString]) AS [ConnectionString]
            FROM (
                     SELECT
                         [c].[ItemID]
                       , [c].[Path]
                       , [c].[Name]
                       , [c].[ParentID]
                       , [c].[Type]
                       , [c].[Content]
                       , [c].[Intermediate]
                       , [c].[SnapshotDataID]
                       , [c].[LinkSourceID]
                       , [c].[Property]
                       , [c].[Description]
                       , [c].[Hidden]
                       , [c].[CreatedByID]
                       , [c].[CreationDate]
                       , [c].[ModifiedByID]
                       , [c].[ModifiedDate]
                       , [c].[MimeType]
                       , [c].[SnapshotLimit]
                       , [c].[Parameter]
                       , [c].[PolicyID]
                       , [c].[PolicyRoot]
                       , [c].[ExecutionFlag]
                       , [c].[ExecutionTime]
                       , [c].[SubType]
                       , [c].[ComponentID]
                       , [c].[ContentSize]
                       , [c].[ContentXml]
                       , [DataSourceXml].[value]('@Name', 'NVARCHAR(260)')                                       AS [LocalDataSourceName]
                       , [DataSourceXml].[value]('(*:ConnectionProperties/*:DataProvider)[1]', 'NVARCHAR(260)')  AS [DataProvider]
                       , [DataSourceXml].[value]('(*:ConnectionProperties/*:ConnectString)[1]', 'NVARCHAR(MAX)') AS [ConnectionString]
                     FROM
                         [CatalogWithXml]                                                         AS [c]
                         CROSS APPLY [ContentXml].[nodes]('/*:Report/*:DataSources/*:DataSource') AS [DataSource]([DataSourceXml])
                     WHERE
                         [c].[Type] = 2
                 )                             AS [r]
                 LEFT JOIN [SharedDataSources] AS [sds]
                           ON [r].[ItemID] = [sds].[ItemID]
                              AND [r].[LocalDataSourceName] = [sds].[LocalDataSourceName]
        )
  ,
    [DataSets] AS
        (
            SELECT
                [CatalogWithXml].[ItemID]
              , [QueryXml].[value]('@Name', 'NVARCHAR(256)')                         AS [DataSetName]
              , [QueryXml].[value]('(*:Query/*:DataSourceName)[1]', 'NVARCHAR(260)') AS [DataSourceName]
              , [QueryXml].[value]('(*:Query/*:CommandType)[1]', 'NVARCHAR(15)')     AS [CommandType]
              , [QueryXml].[value]('(*:Query/*:CommandText)[1]', 'NVARCHAR(MAX)')    AS [CommandText]
            FROM
                [CatalogWithXml]
                CROSS APPLY [ContentXml].[nodes]('/*:Report/*:DataSets/*:DataSet') AS [QueryData]([QueryXml])
        )
  ,
    [Data] AS
        (
            SELECT
                [ds].[ItemID]
              , [c].[Name]
              , [c].[Path]
              , [src].[LocalDataSourceName]
              , [src].[SharedDataSource]
              , [src].[SharedDataSourceName]
              , [src].[DataProvider]
              , [src].[ConnectionString]
              , [ds].[DataSetName]
              , ISNULL([ds].[CommandType], 'Text')                                                        AS [CommandType]
              , REPLACE(REPLACE(REPLACE([ds].[CommandText], CHAR(10), ' '), CHAR(13), ' '), CHAR(9), ' ') AS [CommandText]
            FROM
                [DataSets]            AS [ds]
                JOIN [AllDataSources] AS [src]
                     ON [src].[ItemID] = [ds].[ItemID]
                        AND [src].[LocalDataSourceName] = [ds].[DataSourceName]
                JOIN [dbo].[Catalog]  AS [c]
                     ON [ds].[ItemID] = [c].[ItemID]
        )
SELECT
    [Data].[ItemID]
  , [Data].[Name]
  , [Data].[Path]
  , [Data].[LocalDataSourceName]
  , [Data].[SharedDataSource]
  , [Data].[SharedDataSourceName]
  , [Data].[DataProvider]
  , [Data].[ConnectionString]
  , [Data].[DataSetName]
  , [Data].[CommandType]
  , [Data].[CommandText]
FROM
    [Data];