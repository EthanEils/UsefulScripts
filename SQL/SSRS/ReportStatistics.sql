SELECT
    UPPER(@@SERVERNAME)                        AS [ServerName]
  , DB_NAME()                                  AS [DatabaseName]
  , [c].[Name]                                 AS [ReportName]
  , [c].[Path]                                 AS [ReportPath]
  , COUNT(*)                                   AS [TimesRun]
  , MAX([l].[TimeStart])                       AS [LastRun]
  , ISNULL([SubscriptionCounts].[Total], 0)    AS [SubscriptionCount]
  , ISNULL([SubscriptionCounts].[Active], 0)   AS [ActiveSubscriptionCount]
  , ISNULL([SubscriptionCounts].[InActive], 0) AS [InactiveSubscriptionCount]
FROM
    [ReportServer].[dbo].[ExecutionLog]       AS [l] (NOLOCK)
    INNER JOIN [ReportServer].[dbo].[Catalog] AS [c] (NOLOCK)
               ON [l].[ReportID] = [c].[ItemID]
    OUTER APPLY (
                    SELECT
                        SUM(1) AS [Total]
                      , SUM(   CASE
                                    WHEN [s].[InactiveFlags] = 0
                                         THEN 1
                                    ELSE 0
                               END
                           )   AS [Active]
                      , SUM(   CASE
                                    WHEN [s].[InactiveFlags] = 128
                                         THEN 1
                                    ELSE 0
                               END
                           )   AS [InActive]
                    FROM
                        [ReportServer].[dbo].[Subscriptions] AS [s] WITH (NOLOCK)
                    WHERE
                        1 = 1
                        AND [s].[Report_OID] = [c].[ItemID]
                )                             AS [SubscriptionCounts]
WHERE
    [c].[Type] = 2 -- Only show reports 1=folder, 2=Report, 3=Resource, 4=Linked Report, 5=Data Source
GROUP BY
    [l].[ReportID]
  , [c].[Name]
  , [c].[Path]
  , [SubscriptionCounts].[Total]
  , [SubscriptionCounts].[Active]
  , [SubscriptionCounts].[InActive]
ORDER BY
    [c].[Path];