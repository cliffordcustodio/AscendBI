/* ============================================================
   09_FactSales.sql
   Grain  : One row per sales order line (SalesOrderDetailID).
   Source : SalesOrderDetail + SalesOrderHeader, looked up against
            the dimensions and stg.ProductCostRange.
   Needs  : 01b, 02, 04-08 loaded first.
   Measures
     GrossSales     = qty * unit price
     DiscountAmount = qty * unit price * discount %
     NetRevenue     = LineTotal  (reconciles to source)
     COGS            = qty * unit cost in effect on the order date
     GrossProfit    = NetRevenue - COGS
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.fact_sales') IS NOT NULL DROP TABLE dw.fact_sales;
GO

IF OBJECT_ID('dw.FactSales') IS NULL
CREATE TABLE dw.FactSales (
    SalesOrderDetailID  INT           NOT NULL PRIMARY KEY,
    SalesOrderID         INT           NOT NULL,
    OrderDateKey         INT           NOT NULL,
    ShipDateKey          INT           NULL,
    ProductKey            INT           NOT NULL,
    CustomerKey           INT           NOT NULL,
    TerritoryKey          INT           NOT NULL,
    SalesPersonKey       INT           NOT NULL,
    PromotionKey          INT           NOT NULL,
    OnlineOrderFlag      BIT           NOT NULL,
    OrderQty              SMALLINT      NOT NULL,
    UnitPrice             DECIMAL(19,4) NOT NULL,
    UnitPriceDiscount    DECIMAL(19,4) NOT NULL,
    UnitCost              DECIMAL(19,4) NOT NULL,
    CostSource            VARCHAR(10)   NOT NULL,        -- History / Current / Missing
    GrossSales            DECIMAL(38,6) NOT NULL,
    DiscountAmount        DECIMAL(38,6) NOT NULL,
    NetRevenue            DECIMAL(38,6) NOT NULL,
    COGS                   DECIMAL(38,6) NOT NULL,
    GrossProfit           DECIMAL(38,6) NOT NULL
);
GO

-- Indexes for the joins dashboards use most
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactSalesOrderDate' AND ObjectID = OBJECT_ID('dw.FactSales'))
    CREATE INDEX IX_FactSalesOrderDate ON dw.FactSales (OrderDateKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactSalesProduct' AND ObjectID = OBJECT_ID('dw.FactSales'))
    CREATE INDEX IX_FactSalesProduct ON dw.FactSales (ProductKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactSalesCustomer' AND ObjectID = OBJECT_ID('dw.FactSales'))
    CREATE INDEX IX_FactSalesCustomer ON dw.FactSales (CustomerKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactSalesTerritory' AND ObjectID = OBJECT_ID('dw.FactSales'))
    CREATE INDEX IX_FactSalesTerritory ON dw.FactSales (TerritoryKey);
GO

DELETE FROM dw.FactSales;
GO

DECLARE @DateOffsetYears INT =
    (SELECT CAST(ConfigValue AS INT) FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears');

INSERT INTO dw.FactSales (
    SalesOrderDetailID, SalesOrderID, OrderDateKey, ShipDateKey,
    ProductKey, CustomerKey, TerritoryKey, SalesPersonKey, PromotionKey,
    OnlineOrderFlag, OrderQty, UnitPrice, UnitPriceDiscount,
    UnitCost, CostSource,
    GrossSales, DiscountAmount, NetRevenue, COGS, GrossProfit)
SELECT
    d.SalesOrderDetailID,
    d.SalesOrderID,
    od.DateKey,
    sd.DateKey,
    COALESCE(dp.ProductKey,      -1),
    COALESCE(dc.CustomerKey,     -1),
    COALESCE(dt.TerritoryKey,    -1),
    COALESCE(ds.SalesPersonKey, -1),
    COALESCE(dpr.PromotionKey,   -1),
    h.OnlineOrderFlag,
    d.OrderQty,
    d.UnitPrice,
    d.UnitPriceDiscount,
    cost.UnitCost,
    cost.CostSource,
    d.OrderQty * d.UnitPrice,
    d.OrderQty * d.UnitPrice * d.UnitPriceDiscount,
    d.LineTotal,
    d.OrderQty * cost.UnitCost,
    d.LineTotal - d.OrderQty * cost.UnitCost
FROM AdventureWorks2022.Sales.SalesOrderDetail AS d
JOIN AdventureWorks2022.Sales.SalesOrderHeader AS h
  ON h.SalesOrderID = d.SalesOrderID
-- Dates (shifted by the configured offset). INNER JOIN on order date: a missing
-- calendar row drops the line, which the row-count check below will expose.
JOIN dw.DimDate AS od
  ON od.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.OrderDate AS DATE))
LEFT JOIN dw.DimDate AS sd
  ON sd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.ShipDate AS DATE))
-- Dimension lookups (natural key -> surrogate key; -1 when no match)
LEFT JOIN dw.DimProduct      AS dp  ON dp.ProductID         = d.ProductID
LEFT JOIN dw.DimCustomer     AS dc  ON dc.CustomerID        = h.CustomerID
LEFT JOIN dw.DimTerritory    AS dt  ON dt.TerritoryID       = h.TerritoryID
LEFT JOIN dw.DimSalesPerson AS ds  ON ds.SalesPersonID    = h.SalesPersonID
LEFT JOIN dw.DimPromotion    AS dpr ON dpr.SpecialOfferID  = d.SpecialOfferID
-- Cost in effect on the order date (TOP 1 guards against overlapping ranges)
OUTER APPLY (
    SELECT TOP (1) pc.StandardCost
    FROM stg.ProductCostRange AS pc
    WHERE pc.ProductID = d.ProductID
      AND CAST(h.OrderDate AS DATE) BETWEEN pc.StartDate AND pc.EndDate
    ORDER BY pc.StartDate DESC
) AS hist
-- Fall back to today's cost when no history row covers the date
CROSS APPLY (
    SELECT
        COALESCE(hist.StandardCost, dp.CurrentStandardCost, 0) AS UnitCost,
        CASE WHEN hist.StandardCost IS NOT NULL THEN 'History'
             WHEN dp.CurrentStandardCost IS NOT NULL THEN 'Current'
             ELSE 'Missing' END AS CostSource
) AS cost;
GO

-- ===== Validation =====
-- V1. Row count: fact vs source (must match)
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail) AS SourceRows,
       COUNT(*) AS FactRows
FROM dw.FactSales;

-- V2. Revenue reconciliation: difference must be 0
SELECT (SELECT SUM(LineTotal) FROM AdventureWorks2022.Sales.SalesOrderDetail) AS SourceRevenue,
       SUM(NetRevenue) AS FactRevenue,
       SUM(NetRevenue) - (SELECT SUM(LineTotal) FROM AdventureWorks2022.Sales.SalesOrderDetail) AS Difference
FROM dw.FactSales;

-- V3. Unmatched dimension keys (all should be 0 except SalesPerson = online orders)
SELECT
    SUM(CASE WHEN ProductKey      = -1 THEN 1 ELSE 0 END) AS UnknownProduct,
    SUM(CASE WHEN CustomerKey     = -1 THEN 1 ELSE 0 END) AS UnknownCustomer,
    SUM(CASE WHEN TerritoryKey    = -1 THEN 1 ELSE 0 END) AS UnknownTerritory,
    SUM(CASE WHEN SalesPersonKey = -1 THEN 1 ELSE 0 END) AS NoSalesRepLines,
    SUM(CASE WHEN PromotionKey    = -1 THEN 1 ELSE 0 END) AS UnknownPromotion,
    SUM(CASE WHEN ShipDateKey IS NULL THEN 1 ELSE 0 END) AS NoShipDate
FROM dw.FactSales;

-- V4. Where did unit cost come from?
SELECT CostSource, COUNT(*) AS Lines, SUM(NetRevenue) AS Revenue
FROM dw.FactSales GROUP BY CostSource;

-- V5. Profit by category (sanity check on margins)
SELECT p.CategoryName,
       SUM(f.NetRevenue)  AS Revenue,
       SUM(f.GrossProfit) AS Profit,
       SUM(f.GrossProfit) / NULLIF(SUM(f.NetRevenue), 0) AS MarginPct
FROM dw.FactSales f
JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY p.CategoryName ORDER BY Revenue DESC;

-- V6. Lines selling below cost (investigate, do not delete)
SELECT COUNT(*) AS NegativeProfitLines FROM dw.FactSales WHERE GrossProfit < 0;
