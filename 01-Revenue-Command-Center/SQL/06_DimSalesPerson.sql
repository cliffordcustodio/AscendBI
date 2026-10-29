/* ============================================================
   06_DimSalesPerson.sql
   Grain  : One row per sales rep (+ Unknown, used for online orders).
   Source : Sales.SalesPerson, Person.Person, HumanResources.Employee,
            Sales.SalesTerritory
   Note   : Quotas change over time, so they live in FactSalesQuota.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.dim_sales_person') IS NOT NULL DROP TABLE dw.dim_sales_person;
GO

IF OBJECT_ID('dw.DimSalesPerson') IS NULL
CREATE TABLE dw.DimSalesPerson (
    SalesPersonKey  INT           NOT NULL PRIMARY KEY,   -- surrogate; -1 = Unknown
    SalesPersonID   INT           NOT NULL UNIQUE,        -- natural key (BusinessEntityID)
    FullName         NVARCHAR(101) NOT NULL,
    JobTitle         NVARCHAR(50)  NOT NULL,
    TerritoryName    NVARCHAR(50)  NOT NULL,               -- current assignment
    CommissionPct    DECIMAL(9,4)  NOT NULL,
    bonus             DECIMAL(19,4) NOT NULL
);
GO

DELETE FROM dw.DimSalesPerson;
GO

INSERT INTO dw.DimSalesPerson
VALUES (-1, -1, N'Unknown', N'N/A', N'Unknown', 0, 0);
GO

INSERT INTO dw.DimSalesPerson
SELECT
    ROW_NUMBER() OVER (ORDER BY sp.BusinessEntityID),
    sp.BusinessEntityID,
    CONCAT(p.FirstName, N' ', p.LastName),
    COALESCE(e.JobTitle, N'N/A'),
    COALESCE(t.Name, N'No Territory'),
    sp.CommissionPct,
    sp.Bonus
FROM AdventureWorks2022.Sales.SalesPerson AS sp
JOIN AdventureWorks2022.Person.Person AS p
  ON p.BusinessEntityID = sp.BusinessEntityID
LEFT JOIN AdventureWorks2022.HumanResources.Employee AS e
  ON e.BusinessEntityID = sp.BusinessEntityID
LEFT JOIN AdventureWorks2022.Sales.SalesTerritory AS t
  ON t.TerritoryID = sp.TerritoryID;
GO

-- ===== Validation =====
-- V1. Expect source rows + 1
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesPerson) + 1 AS ExpectedRows,
       COUNT(*) AS ActualRows
FROM dw.DimSalesPerson;

-- V2. Eyeball everything (it is small)
SELECT * FROM dw.DimSalesPerson ORDER BY SalesPersonKey;
