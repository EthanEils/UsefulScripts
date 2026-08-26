SET DATEFIRST 1, LANGUAGE us_english;

-- ===================================================================
-- Declare Initial Parameters
-- ===================================================================
BEGIN
    DECLARE
        @RefDate   DATE
      , @StartDate DATE
      , @Years     INT;
END;

-- ===================================================================
-- Parameters to Set for Testing
-- ===================================================================
BEGIN
    SET @RefDate = '04/01/2019';
    SET @StartDate = '3/29/2010';
    SET @Years = 50;

--SET @RefDate = '04/01/2019';
--SET @StartDate = '3/30/2020';
--SET @Years = 5;

--SET @Direction = 'FWD';
--SET @WeekStart = '3/21/2022';
END;

BEGIN
    IF OBJECT_ID(N'tempdb..#Dates', N'U') IS NOT NULL
        BEGIN
            DROP TABLE [#Dates];
        END;
END;

-- ===================================================================
-- Build Initial Date Range and Declare Global Variables
-- ===================================================================
BEGIN
    DECLARE
        @EndDate    DATE = DATEADD(YEAR, @Years, @StartDate)
      , @FiscalYear INT
      , @WeekEnd    DATE;

    DECLARE @Dates TABLE
    (
        [Counter]           INT
      , [Date]              DATE
      , [Day]               INT
      , [DayName]           NVARCHAR (25)
      , [Week]              INT
      , [ISOWeek]           INT
      , [DayOfWeek]         INT
      , [Month]             INT
      , [MonthName]         NVARCHAR (25)
      , [Quarter]           INT
      , [Year]              INT
      , [FirstOfMonth]      DATE
      , [LastOfYear]        DATE
      , [DayOfYear]         INT
    );

    WHILE @StartDate < @EndDate
        BEGIN
            INSERT INTO @Dates
            SELECT
                -DATEDIFF(DAY, @StartDate, @RefDate)                  AS [Counter]
              , @StartDate                                            AS [Date]
              , DATEPART(DAY, @StartDate)                             AS [Day]
              , DATENAME(WEEKDAY, @StartDate)                         AS [DayName]
              , DATEPART(WEEK, @StartDate)                            AS [Week]
              , DATEPART(ISO_WEEK, @StartDate)                        AS [ISOWeek]
              , DATEPART(WEEKDAY, @StartDate)                         AS [DayOfWeek]
              , DATEPART(MONTH, @StartDate)                           AS [Month]
              , DATENAME(MONTH, @StartDate)                           AS [MonthName]
              , DATEPART(QUARTER, @StartDate)                         AS [Quarter]
              , DATEPART(YEAR, @StartDate)                            AS [Year]
              , DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1) AS [FirstOfMonth]
              , DATEFROMPARTS(YEAR(@StartDate), 12, 31)               AS [LastOfYear]
              , DATEPART(DAYOFYEAR, @StartDate)                       AS [DayOfYear];

            SET @StartDate = DATEADD(DAY, 1, @StartDate);
        END;
END;

CREATE TABLE [#Dates]
(
    [Date]             DATE          NOT NULL PRIMARY KEY
  , [Day]              INT           NULL
  , [DaySuffix]        CHAR (2)      NULL
  , [DayName]          NVARCHAR (25) NULL
  , [DayOfWeek]        INT           NULL
  , [DayOfWeekInMonth] TINYINT       NULL
  , [DayOfYear]        INT           NULL
  , [IsWeekend]        BIT           NULL
  , [Week]             INT           NULL
  , [ISOWeek]          INT           NULL
  , [FirstOfWeek]      DATE          NULL
  , [LastOfWeek]       DATE          NULL
  , [WeekOfMonth]      TINYINT       NULL
  , [Month]            INT           NULL
  , [MonthName]        NVARCHAR (25) NULL
  , [FirstOfMonth]     DATE          NULL
  , [LastOfMonth]      DATE          NULL
  , [FirstOfNextMonth] DATE          NULL
  , [LastOfNextMonth]  DATE          NULL
  , [Quarter]          INT           NULL
  , [FirstOfQuarter]   DATE          NULL
  , [LastOfQuarter]    DATE          NULL
  , [Year]             INT           NULL
  , [ISOYear]          INT           NULL
  , [FirstOfYear]      DATE          NULL
  , [LastOfYear]       DATE          NULL
  , [IsLeapYear]       BIT           NULL
  , [Has53Weeks]       BIT           NULL
  , [Has53ISOWeeks]    BIT           NULL
);

-- ===================================================================
-- Add Additional Date Features
-- ===================================================================
BEGIN
    INSERT INTO [#Dates]
    (
        [Date]
      , [Day]
      , [DaySuffix]
      , [DayName]
      , [DayOfWeek]
      , [DayOfWeekInMonth]
      , [DayOfYear]
      , [IsWeekend]
      , [Week]
      , [ISOWeek]
      , [FirstOfWeek]
      , [LastOfWeek]
      , [WeekOfMonth]
      , [Month]
      , [MonthName]
      , [FirstOfMonth]
      , [LastOfMonth]
      , [FirstOfNextMonth]
      , [LastOfNextMonth]
      , [Quarter]
      , [FirstOfQuarter]
      , [LastOfQuarter]
      , [Year]
      , [ISOYear]
      , [FirstOfYear]
      , [LastOfYear]
      , [IsLeapYear]
      , [Has53Weeks]
      , [Has53ISOWeeks]
    )
    SELECT
        [Main].[Date]                                                        AS [Date]
      , [Main].[Day]                                                         AS [Day]
      , CONVERT(   CHAR (2)
                 , CASE
                        WHEN [Main].[Day] / 10 = 1
                             THEN 'th'
                        ELSE CASE RIGHT([Main].[Day], 1)
                                  WHEN '1'
                                       THEN 'st'
                                  WHEN '2'
                                       THEN 'nd'
                                  WHEN '3'
                                       THEN 'rd'
                                  ELSE 'th'
                             END
                   END
               )                                                             AS [DaySuffix]
      , [Main].[DayName]                                                     AS [DayName]
      , [Main].[DayOfWeek]                                                   AS [DayOfWeek]
      , CONVERT(   TINYINT
                 , ROW_NUMBER() OVER (PARTITION BY
                                          [Main].[FirstOfMonth]
                                        , [Main].[DayOfWeek]
                                      ORDER BY
                                          [Main].[Date]
                                     )
               )                                                             AS [DayOfWeekInMonth]
      , [Main].[DayOfYear]
      , CASE
             WHEN [Main].[DayOfWeek] IN
                 (   CASE @@DATEFIRST
                          WHEN 1
                               THEN 6
                          WHEN 7
                               THEN 1
                          ELSE 1
                     END, 7
                 )
                  THEN 1
             ELSE 0
        END                                                                  AS [IsWeekend]
      , [Main].[Week]
      , [Main].[ISOWeek]
      , DATEADD(DAY, 1 - [Main].[DayOfWeek], [Main].[Date])                  AS [FirstOfWeek]
      , DATEADD(DAY, 6, DATEADD(DAY, 1 - [Main].[DayOfWeek], [Main].[Date])) AS [LastOfWeek]
      , CONVERT(   TINYINT
                 , DENSE_RANK() OVER (PARTITION BY
                                          [Main].[Year]
                                        , [Main].[Month]
                                      ORDER BY
                                          [Main].[Week]
                                     )
               )                                                             AS [WeekOfMonth]
      , [Main].[Month]
      , [Main].[MonthName]
      , [Main].[FirstOfMonth]
      , MAX([Main].[Date]) OVER (PARTITION BY
                                     [Main].[Year]
                                   , [Main].[Month]
                                )                                            AS [LastOfMonth]
      , DATEADD(MONTH, 1, [Main].[FirstOfMonth])                             AS [FirstOfNextMonth]
      , DATEADD(DAY, -1, DATEADD(MONTH, 2, [Main].[FirstOfMonth]))           AS [LastOfNextMonth]
      , [Main].[Quarter]
      , MIN([Main].[Date]) OVER (PARTITION BY
                                     [Main].[Year]
                                   , [Main].[Quarter]
                                )                                            AS [FirstOfQuarter]
      , MAX([Main].[Date]) OVER (PARTITION BY
                                     [Main].[Year]
                                   , [Main].[Quarter]
                                )                                            AS [LastOfQuarter]
      , [Main].[Year]
      , [Main].[Year] - CASE
                             WHEN [Main].[Month] = 1
                                  AND [Main].[ISOWeek] > 51
                                  THEN 1
                             WHEN [Main].[Month] = 12
                                  AND [Main].[ISOWeek] = 1
                                  THEN -1
                             ELSE 0
                        END                                                  AS [ISOYear]
      , DATEFROMPARTS([Main].[Year], 1, 1)                                   AS [FirstOfYear]
      , [Main].[LastOfYear]
      , CONVERT(   BIT
                 , CASE
                        WHEN [Main].[Year] % 400 = 0
                             OR [Main].[Year] % 4 = 0
                                AND [Main].[Year] % 100 <> 0
                             THEN 1
                        ELSE 0
                   END
               )                                                             AS [IsLeapYear]
      , CASE
             WHEN DATEPART(WEEK, [Main].[LastOfYear]) = 53
                  THEN 1
             ELSE 0
        END                                                                  AS [Has53Weeks]
      , CASE
             WHEN DATEPART(ISO_WEEK, [Main].[LastOfYear]) = 53
                  THEN 1
             ELSE 0
        END                                                                  AS [Has53ISOWeeks]
    FROM
        @Dates AS [Main]
    ORDER BY
        [Date] ASC;
END;

-- ===================================================================
-- Final Select
-- ===================================================================
BEGIN
    SELECT
        *
    FROM
        [#Dates]
    ORDER BY
        [Date] ASC;
END;

IF OBJECT_ID(N'tempdb..#Dates', N'U') IS NOT NULL
    BEGIN
        DROP TABLE [#Dates];
    END;