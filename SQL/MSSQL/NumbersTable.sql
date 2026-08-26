DECLARE @UpperBound INT = 1000000000;

IF OBJECT_ID(N'[dbo].[Numbers]', N'U') IS NULL
    BEGIN
        CREATE TABLE [dbo].[Numbers]
        (
            [Number] INT NOT NULL
        );
    END;

WITH
    [cteN] ([Number]) AS
        (
            SELECT
                ROW_NUMBER() OVER (ORDER BY
                                       [s1].[object_id]
                                  ) - 1
            FROM
                [sys].[all_columns]            AS [s1]
                CROSS JOIN [sys].[all_columns] AS [s2]
        )
INSERT INTO [dbo].[Numbers]
(
    [Number]
)
SELECT
    [cteN].[Number]
FROM
    [cteN]
WHERE
    [cteN].[Number] <= @UpperBound;

CREATE UNIQUE CLUSTERED INDEX [CIX_Number]
    ON [dbo].[Numbers] ([Number])
    WITH (   FILLFACTOR = 100       -- in the event server default has been changed
           , DATA_COMPRESSION = ROW -- if Enterprise & table large enough to matter
         );