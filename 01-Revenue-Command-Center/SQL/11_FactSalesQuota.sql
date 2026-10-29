/* ============================================================
   11_FactSalesQuota.sql
   Grain  : One sales rep per quota date (roughly one per quarter).
   Source : Sales.SalesPersonQuotaHistory
   Use    : Quota attainment = rep NetRevenue (FactSales) / SalesQuota
            for the same period, joined through DimDate.
   Caveat : QuotaDate is not always the first day of a calendar quarter.
            Assign it to a quarter through DimDate and document the rule.
   Needs  : 01b, 02, 06 loaded first.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.fact_sales_quota') IS NOT NULL DROP TABLE dw.fact_sales_quota;
GO

IF OBJECT_ID('dw.FactSalesQuota') IS NULL
CREATE TABLE dw.FactSalesQuota (
    SalesPersonKey  INT           NOT NULL,
    QuotaDateKey    INT           NOT NULL,
    SalesQuota       DECIMAL(19,4) NOT NULL,
    CONSTRAINT PK_FactSalesQuota PRIMARY KEY (SalesPersonKey, QuotaDateKey)
);
GO

DELETE FROM dw.FactSalesQuota;
GO

DECLARE @DateOffsetYears INT =
    (SELECT CAST(ConfigValue AS INT) FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears');

INSERT INTO dw.FactSalesQuota (SalesPersonKey, QuotaDateKey, SalesQuota)
SELECT
    ds.SalesPersonKey,
    dd.DateKey,
    q.SalesQuota
FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory AS q
JOIN dw.DimSalesPerson AS ds ON ds.SalesPersonID = q.BusinessEntityID
JOIN dw.DimDate         AS dd ON dd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(q.QuotaDate AS DATE));
GO

-- ===== Validation =====
-- V1. Row count: fact vs source (must match)
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory) AS SourceRows,
       COUNT(*) AS FactRows
FROM dw.FactSalesQuota;

-- V2. Quota total reconciles (difference must be 0)
SELECT SUM(SalesQuota) - (SELECT SUM(SalesQuota) FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory) AS QuotaDiff
FROM dw.FactSalesQuota;

-- V3. Yearly quota per rep (preview of the quota-attainment query)
SELECT ds.FullName, dd.CalendarYear, COUNT(*) AS QuotaPeriods, SUM(q.SalesQuota) AS YearlyQuota
FROM dw.FactSalesQuota q
JOIN dw.DimSalesPerson ds ON ds.SalesPersonKey = q.SalesPersonKey
JOIN dw.DimDate dd         ON dd.DateKey = q.QuotaDateKey
GROUP BY ds.FullName, dd.CalendarYear
ORDER BY ds.FullName, dd.CalendarYear;
