SELECT
    [s].[SubscriptionID]              -- Subscription ID 
  , [s].[OwnerID]                     -- Report Owner 
  , [s].[Report_OID]                  -- Report ID
  , [c].[Path]                        -- Report Path 
  , [rs].[ScheduleID] AS [SQLJobName] -- Name of Job on SQL Server
  , [s].[Description]                 -- Description of the report subscription 
  , [s].[LastStatus]                  -- Status of last subscription execution. 
  , [s].[EventType]                   -- Subscription type 
  , [s].[LastRunTime]                 -- Last time subscription executed 
  , [s].[Parameters]                  -- Parameters used for subscription 
  , [s].[DeliveryExtension]           -- How to deliver the subscription 
FROM
    [ReportServer].[dbo].[Subscriptions] AS [s]
    LEFT JOIN [dbo].[Catalog]            AS [c]
              ON [c].[ItemID] = [s].[Report_OID]
    LEFT JOIN [dbo].[ReportSchedule]     AS [rs]
              ON [rs].[ReportID] = [s].[Report_OID]
WHERE
    1 = 1
    --AND [c].[Path] IN
    --        ( '' )
ORDER BY
    [c].[Path];