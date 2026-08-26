SELECT
    'Event Table';

SELECT
    [e].[EventID]
  , [e].[EventType]
  , [e].[EventData]
  , [e].[TimeEntered]
  , [e].[ProcessStart]
  , [e].[ProcessHeartbeat]
  , [e].[BatchID]
FROM
    [dbo].[Event] AS [e] WITH (NOLOCK)
WHERE
    1 = 1;

SELECT
    'Notifications Table';

SELECT
    [n].[SubscriptionID]
  , [c].[Name]                AS [ReportName]
  , [c].[Path]                AS [ReportPath]
  , [u].[UserName]            AS [SubscriptionOwner]
  , [n].[ExtensionSettings]
  , [n].[NotificationEntered] AS [QueuedSinceTime]
  , [n].[ProcessAfter]
  , [n].[SubscriptionLastRunTime]
  , [n].[DeliveryExtension]
FROM
    [dbo].[Notifications]     AS [n] WITH (NOLOCK)
    LEFT JOIN [dbo].[Catalog] AS [c] WITH (NOLOCK)
              ON [n].[ReportID] = [c].[ItemID]
    LEFT JOIN [dbo].[Users]   AS [u] WITH (NOLOCK)
              ON [n].[SubscriptionOwnerID] = [u].[UserID]
ORDER BY
    [n].[NotificationEntered];