DECLARE @Prefix NVARCHAR (500);

--	Don't change the query, only change the @Prefix value
--	and run the query to find the name of the table to which
--	the prefix belongs.
--	Change the @Prefix value and click "Execute"
SET @Prefix = N'Customer';

SELECT
    [so].[name] AS [Name]
  , CASE [so].[xtype]
         WHEN 'U'
              THEN 'Table'
         WHEN 'V'
              THEN 'View'
         ELSE 'Unknown'
    END         AS [Type]
FROM
    [sys].[objects] AS [so]
WHERE
    [so].[xtype] IN
        ( 'U', 'V' )
    AND [so].[id] IN
        (
            SELECT
                [sc].[id]
            FROM
                [sys].[columns] AS [sc]
            WHERE
                [sc].[name] LIKE @Prefix + '%'
        )
ORDER BY
    [Name];

SELECT
    SCHEMA_NAME([o].[schema_id]) AS [Scehma]
  , [o].[name]
  , [o].[type]
  , [m].[definition]
FROM
    [sys].[sql_modules]        AS [m]
    INNER JOIN [sys].[objects] AS [o]
               ON [o].[object_id] = [m].[object_id]
WHERE
    [m].[definition] LIKE CONCAT('%', @Prefix, '%')
ORDER BY
    [o].[name];