/* ============================================================
   02_DimDate.sql
   Purpose : Build dw.DimDate covering every year in the source data.
   Grain   : One row per calendar day.
   Offset  : Reads DateOffsetYears from dw.EtlConfig (run 01b first).
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.dim_date') IS NOT NULL DROP TABLE dw.dim_date;
GO

-- Rebuild from scratch: earlier versions used different column names
IF OBJECT_ID('dw.DimDate') IS NOT NULL DROP TABLE dw.DimDate;
GO

IF OBJECT_ID('dw.DimDate') IS NULL
CREATE TABLE dw.DimDate (
    DateKey            INT         NOT NULL PRIMARY KEY,   -- yyyymmdd
    FullDate           DATE        NOT NULL UNIQUE,
    CalendarYear       SMALLINT    NOT NULL,
    QuarterNumber      TINYINT     NOT NULL,
    QuarterName        CHAR(2)     NOT NULL,                -- Q1..Q4
    MonthNumber        TINYINT     NOT NULL,
    MonthName          VARCHAR(10) NOT NULL,
    MonthShort         CHAR(3)     NOT NULL,
    YearMonth          CHAR(7)     NOT NULL,                -- 2014-06
    YearMonthKey      INT         NOT NULL,                -- 201406 (sortable)
    IsoWeek            TINYINT     NOT NULL,
    DayOfMonth        TINYINT     NOT NULL,
    DayOfWeekNumber  TINYINT     NOT NULL,                -- 1 = Monday
    DayName            VARCHAR(10) NOT NULL,
    IsWeekend          BIT         NOT NULL,
    IsLatestMonth     BIT         NOT NULL DEFAULT 0       -- set after fact load
);
GO

DECLARE @DateOffsetYears INT =
    (SELECT CAST(ConfigValue AS INT) FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears');

DECLARE @StartDate DATE, @EndDate DATE;

SELECT
    @StartDate = DATEADD(YEAR, @DateOffsetYears, DATEFROMPARTS(YEAR(MIN(OrderDate)), 1, 1)),
    @EndDate   = DATEADD(YEAR, @DateOffsetYears, DATEFROMPARTS(YEAR(MAX(DueDate)), 12, 31))
FROM AdventureWorks2022.Sales.SalesOrderHeader;

DELETE FROM dw.DimDate;   -- DELETE (not TRUNCATE) so future FKs do not block reloads

;WITH dates AS (
    SELECT @StartDate AS d
    UNION ALL
    SELECT DATEADD(DAY, 1, d) FROM dates WHERE d < @EndDate
)
INSERT INTO dw.DimDate (
    DateKey, FullDate, CalendarYear, QuarterNumber, QuarterName, MonthNumber,
    MonthName, MonthShort, YearMonth, YearMonthKey, IsoWeek, DayOfMonth,
    DayOfWeekNumber, DayName, IsWeekend)
SELECT
    YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d),
    d,
    YEAR(d),
    DATEPART(QUARTER, d),
    'Q' + CAST(DATEPART(QUARTER, d) AS CHAR(1)),
    MONTH(d),
    DATENAME(MONTH, d),
    LEFT(DATENAME(MONTH, d), 3),
    CONVERT(CHAR(7), d, 126),
    YEAR(d) * 100 + MONTH(d),
    DATEPART(ISO_WEEK, d),
    DAY(d),
    (DATEDIFF(DAY, '19000101', d) % 7) + 1,           -- 1900-01-01 was a Monday
    DATENAME(WEEKDAY, d),
    CASE WHEN (DATEDIFF(DAY, '19000101', d) % 7) + 1 IN (6, 7) THEN 1 ELSE 0 END
FROM dates
OPTION (MAXRECURSION 0);

-- Verify
SELECT MIN(FullDate) AS FirstDate, MAX(FullDate) AS LastDate, COUNT(*) AS DaysLoaded
FROM dw.DimDate;
GO
