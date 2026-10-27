/* ============================================================
   00_explore_source.sql
   Purpose : Profile AdventureWorks2022 before designing the ETL.
   Run     : Section by section in SSMS. Note what you find.
   ============================================================ */
USE AdventureWorks2022;
GO

-- 1. Date range and headline totals
SELECT
    MIN(OrderDate)  AS FirstOrder,
    MAX(OrderDate)  AS LastOrder,
    MAX(DueDate)    AS LastDueDate,
    COUNT(*)        AS Orders,
    SUM(SubTotal)   AS SubTotal,
    SUM(TotalDue)   AS TotalDue
FROM Sales.SalesOrderHeader;

-- 2. Orders and revenue by year (watch for partial first and last years)
SELECT
    YEAR(h.OrderDate)  AS OrderYear,
    COUNT(DISTINCT h.SalesOrderID) AS Orders,
    SUM(d.LineTotal)   AS NetRevenue
FROM Sales.SalesOrderHeader h
JOIN Sales.SalesOrderDetail d ON d.SalesOrderID = h.SalesOrderID
GROUP BY YEAR(h.OrderDate)
ORDER BY OrderYear;

-- 3. Row counts of the tables we will use
SELECT 'SalesOrderHeader' AS TableName, COUNT(*) AS Rows FROM Sales.SalesOrderHeader
UNION ALL SELECT 'SalesOrderDetail',  COUNT(*) FROM Sales.SalesOrderDetail
UNION ALL SELECT 'Product',           COUNT(*) FROM Production.Product
UNION ALL SELECT 'ProductCostHistory',COUNT(*) FROM Production.ProductCostHistory
UNION ALL SELECT 'Customer',          COUNT(*) FROM Sales.Customer
UNION ALL SELECT 'SalesTerritory',    COUNT(*) FROM Sales.SalesTerritory
UNION ALL SELECT 'SalesPerson',       COUNT(*) FROM Sales.SalesPerson
UNION ALL SELECT 'SpecialOffer',      COUNT(*) FROM Sales.SpecialOffer;

-- 4. Online vs store orders (online orders have no sales rep)
SELECT
    OnlineOrderFlag,
    COUNT(*)                                        AS Orders,
    SUM(CASE WHEN SalesPersonID IS NULL THEN 1 ELSE 0 END) AS OrdersWithoutRep
FROM Sales.SalesOrderHeader
GROUP BY OnlineOrderFlag;

-- 5. Customer types: individuals (PersonID) vs stores (StoreID)
SELECT
    CASE WHEN StoreID IS NULL THEN 'Individual' ELSE 'Store' END AS CustomerType,
    COUNT(*) AS Customers
FROM Sales.Customer
GROUP BY CASE WHEN StoreID IS NULL THEN 'Individual' ELSE 'Store' END;

-- 6. Does LineTotal equal OrderQty * UnitPrice * (1 - UnitPriceDiscount)?
SELECT TOP 10
    SalesOrderDetailID, OrderQty, UnitPrice, UnitPriceDiscount, LineTotal,
    OrderQty * UnitPrice * (1 - UnitPriceDiscount) AS Recalculated
FROM Sales.SalesOrderDetail
WHERE UnitPriceDiscount > 0;

-- 7. Products sold that have NO cost history row (decision D4 risk)
SELECT COUNT(DISTINCT d.ProductID) AS SoldProductsMissingCost
FROM Sales.SalesOrderDetail d
WHERE NOT EXISTS (
    SELECT 1 FROM Production.ProductCostHistory c
    WHERE c.ProductID = d.ProductID);

-- 8. Cost history coverage: does each sale date fall in a cost range?
SELECT COUNT(*) AS LinesWithoutMatchingCostRange
FROM Sales.SalesOrderDetail d
JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
WHERE NOT EXISTS (
    SELECT 1 FROM Production.ProductCostHistory c
    WHERE c.ProductID = d.ProductID
      AND h.OrderDate >= c.StartDate
      AND h.OrderDate <= ISNULL(c.EndDate, '9999-12-31'));

-- 9. Shipping sanity: any ship date before order date?
SELECT COUNT(*) AS BadShipDates
FROM Sales.SalesOrderHeader
WHERE ShipDate < OrderDate;

-- 10. Territories
SELECT TerritoryID, Name, CountryRegionCode, [Group] FROM Sales.SalesTerritory ORDER BY TerritoryID;
