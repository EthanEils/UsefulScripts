-- =============================================
-- Author:		<Creating User (Ex: Ethan Eils)>
-- Create date:	MMM DD, YYYY (Ex: Jan 01, 2023)
-- Description:	Automatically update Owner ID 
--				to the Service Account
-- =============================================

CREATE TRIGGER [dbo].[UpdateOwnerID]
ON [dbo].[Subscriptions]
AFTER INSERT
AS
    BEGIN
        SET NOCOUNT ON;

        DECLARE @ServiceAccountOwnerID UNIQUEIDENTIFIER = '<Service Account ID from Users table>';

        IF (ROWCOUNT_BIG() = 0)
            BEGIN
                RETURN;
            END;

        UPDATE
            [dbo].[Subscriptions]
        SET
            [OwnerID] = @ServiceAccountOwnerID
        FROM
            [dbo].[Subscriptions] AS [s] WITH (NOLOCK)
            INNER JOIN [Inserted] AS [i]
                       ON [i].[SubscriptionID] = [s].[SubscriptionID];
    END;
GO