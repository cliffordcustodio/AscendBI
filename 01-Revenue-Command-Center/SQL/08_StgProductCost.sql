/* ============================================================
   08_StgProductCost.sql
   Purpose : Cost lookup so FactSales can use the cost IN EFFECT on the
             order date (decision D4), not today's cost.
   Grain   : One row per product per cost date range.
   Source  : Production.ProductCostHistory
   Note    : Dates here are SOURCE dates (not offset) because FactSales
             compares them with the source OrderDate.
             Current cost row has EndDate NULL, replaced with 9999-12-31.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('stg.product_cost_range') IS NOT NULL DROP TABLE stg.product_cost_range;
GO

IF OBJECT_ID('stg.ProductCostRange') IS NULL
CREATE TABLE stg.ProductCostRange (
    ProductID     INT           NOT NULL,
    StartDate     DATE          NOT NULL,
    EndDate       DATE          NOT NULL,
    StandardCost  DECIMAL(19,4) NOT NULL,
    CONSTRAINT PK_ProductCostRange PRIMARY KEY (ProductID, StartDate)
);
GO

DELETE FROM stg.ProductCostRange;
GO

INSERT INTO stg.ProductCostRange (ProductID, StartDate, EndDate, StandardCost)
SELECT
    ProductID,
    CAST(StartDate AS DATE),
    COALESCE(CAST(EndDate AS DATE), '9999-12-31'),
    StandardCost
FROM AdventureWorks2022.Production.ProductCostHistory;
GO

-- ===== Validation =====
-- V1. Row count matches source
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Production.ProductCostHistory) AS SourceRows,
       COUNT(*) AS LoadedRows
FROM stg.ProductCostRange;

-- V2. Overlapping ranges for the same product (expect 0 rows)
SELECT a.ProductID, a.StartDate, a.EndDate, b.StartDate AS OtherStart
FROM stg.ProductCostRange a
JOIN stg.ProductCostRange b
  ON a.ProductID = b.ProductID
 AND a.StartDate < b.StartDate
 AND a.EndDate  >= b.StartDate;

-- V3. How many sold order lines have NO matching cost range?
--     These fall back to DimProduct.CurrentStandardCost (CostSource = 'Current')
SELECT COUNT(*) AS LinesWithoutHistory
FROM AdventureWorks2022.Sales.SalesOrderDetail d
JOIN AdventureWorks2022.Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
WHERE NOT EXISTS (
    SELECT 1 FROM stg.ProductCostRange c
    WHERE c.ProductID = d.ProductID
      AND CAST(h.OrderDate AS DATE) BETWEEN c.StartDate AND c.EndDate);
