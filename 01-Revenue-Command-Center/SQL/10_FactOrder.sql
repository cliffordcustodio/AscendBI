/* ============================================================
   10_FactOrder.sql
   Grain  : One row per sales order.
   Source : Sales.SalesOrderHeader, Purchasing.ShipMethod
   Why    : Freight and tax are order-level. Keeping them out of
            FactSales prevents double counting (decision D5).
   RULE   : Never join FactOrder to FactSales and SUM Freight
            without aggregating one side first.
   Needs  : 01b, 02, 04-06 loaded first.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.fact_order') IS NOT NULL DROP TABLE dw.fact_order;
GO

IF OBJECT_ID('dw.FactOrder') IS NULL
CREATE TABLE dw.FactOrder (
    SalesOrderID     INT           NOT NULL PRIMARY KEY,
    OrderDateKey     INT           NOT NULL,
    ShipDateKey      INT           NULL,
    DueDateKey       INT           NULL,
    CustomerKey       INT           NOT NULL,
    SalesPersonKey   INT           NOT NULL,
    TerritoryKey      INT           NOT NULL,
    ShipMethodName   NVARCHAR(50)  NOT NULL,
    OnlineOrderFlag  BIT           NOT NULL,
    SubTotal          DECIMAL(19,4) NOT NULL,
    TaxAmt            DECIMAL(19,4) NOT NULL,
    Freight            DECIMAL(19,4) NOT NULL,
    TotalDue          DECIMAL(19,4) NOT NULL,
    FulfilmentDays    INT           NULL        -- ship date minus order date
);
GO

DELETE FROM dw.FactOrder;
GO

DECLARE @DateOffsetYears INT =
    (SELECT CAST(ConfigValue AS INT) FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears');

INSERT INTO dw.FactOrder (
    SalesOrderID, OrderDateKey, ShipDateKey, DueDateKey,
    CustomerKey, SalesPersonKey, TerritoryKey, ShipMethodName,
    OnlineOrderFlag, SubTotal, TaxAmt, Freight, TotalDue, FulfilmentDays)
SELECT
    h.SalesOrderID,
    od.DateKey,
    sd.DateKey,
    dd.DateKey,
    COALESCE(dc.CustomerKey,     -1),
    COALESCE(ds.SalesPersonKey, -1),
    COALESCE(dt.TerritoryKey,    -1),
    COALESCE(sm.Name, N'Unknown'),
    h.OnlineOrderFlag,
    h.SubTotal,
    h.TaxAmt,
    h.Freight,
    h.TotalDue,
    DATEDIFF(DAY, h.OrderDate, h.ShipDate)
FROM AdventureWorks2022.Sales.SalesOrderHeader AS h
JOIN dw.DimDate AS od
  ON od.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.OrderDate AS DATE))
LEFT JOIN dw.DimDate AS sd
  ON sd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.ShipDate AS DATE))
LEFT JOIN dw.DimDate AS dd
  ON dd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.DueDate AS DATE))
LEFT JOIN dw.DimCustomer     AS dc ON dc.CustomerID     = h.CustomerID
LEFT JOIN dw.DimSalesPerson AS ds ON ds.SalesPersonID = h.SalesPersonID
LEFT JOIN dw.DimTerritory    AS dt ON dt.TerritoryID    = h.TerritoryID
LEFT JOIN AdventureWorks2022.Purchasing.ShipMethod AS sm
       ON sm.ShipMethodID = h.ShipMethodID;
GO

-- ===== Validation =====
-- V1. Row count: fact vs source
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS SourceRows,
       COUNT(*) AS FactRows
FROM dw.FactOrder;

-- V2. Totals reconcile to source (differences must be 0)
SELECT SUM(SubTotal) - (SELECT SUM(SubTotal) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS SubTotalDiff,
       SUM(Freight)   - (SELECT SUM(Freight)  FROM AdventureWorks2022.Sales.SalesOrderHeader) AS FreightDiff,
       SUM(TotalDue) - (SELECT SUM(TotalDue) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS TotalDueDiff
FROM dw.FactOrder;

-- V3. Cross-check the two facts: order SubTotal vs sum of its lines (expect 0 rows)
SELECT TOP 20 o.SalesOrderID, o.SubTotal, l.LineTotal
FROM dw.FactOrder o
JOIN (SELECT SalesOrderID, SUM(NetRevenue) AS LineTotal
      FROM dw.FactSales GROUP BY SalesOrderID) l
  ON l.SalesOrderID = o.SalesOrderID
WHERE ABS(o.SubTotal - l.LineTotal) > 0.01;

-- V4. Fulfilment sanity: negative or very long values (expect none negative)
SELECT MIN(FulfilmentDays) AS MinDays, MAX(FulfilmentDays) AS MaxDays,
       AVG(CAST(FulfilmentDays AS DECIMAL(9,2))) AS AvgDays
FROM dw.FactOrder;

-- V5. Ship method mix
SELECT ShipMethodName, COUNT(*) AS Orders, SUM(Freight) AS Freight
FROM dw.FactOrder GROUP BY ShipMethodName ORDER BY Orders DESC;
