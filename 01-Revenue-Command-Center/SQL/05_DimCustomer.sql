/* ============================================================
   05_DimCustomer.sql
   Grain  : One row per customer (+ Unknown).
   Source : Sales.Customer, Person.Person, Sales.Store
   Rule   : A customer is a Store if StoreID is set; otherwise an
            Individual if PersonID is set.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.dim_customer') IS NOT NULL DROP TABLE dw.dim_customer;
GO

IF OBJECT_ID('dw.DimCustomer') IS NULL
CREATE TABLE dw.DimCustomer (
    CustomerKey    INT           NOT NULL PRIMARY KEY,   -- surrogate; -1 = Unknown
    CustomerID     INT           NOT NULL UNIQUE,        -- natural key
    CustomerType   NVARCHAR(10)  NOT NULL,               -- Store / Individual / Unknown
    CustomerName   NVARCHAR(200) NOT NULL,
    StoreName      NVARCHAR(50)  NOT NULL,
    AccountNumber  VARCHAR(10)   NOT NULL
);
GO

DELETE FROM dw.DimCustomer;
GO

INSERT INTO dw.DimCustomer
VALUES (-1, -1, N'Unknown', N'Unknown', N'N/A', 'N/A');
GO

INSERT INTO dw.DimCustomer
SELECT
    ROW_NUMBER() OVER (ORDER BY c.CustomerID),
    c.CustomerID,
    CASE WHEN c.StoreID  IS NOT NULL THEN N'Store'
         WHEN c.PersonID IS NOT NULL THEN N'Individual'
         ELSE N'Unknown' END,
    CASE WHEN s.BusinessEntityID IS NOT NULL THEN s.Name
         WHEN p.BusinessEntityID IS NOT NULL THEN CONCAT(p.FirstName, N' ', p.LastName)
         ELSE N'Unknown' END,
    COALESCE(s.Name, N'N/A'),
    COALESCE(c.AccountNumber, 'N/A')
FROM AdventureWorks2022.Sales.Customer AS c
LEFT JOIN AdventureWorks2022.Person.Person AS p ON p.BusinessEntityID = c.PersonID
LEFT JOIN AdventureWorks2022.Sales.Store   AS s ON s.BusinessEntityID = c.StoreID;
GO

-- ===== Validation =====
-- V1. Expect source rows + 1
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.Customer) + 1 AS ExpectedRows,
       COUNT(*) AS ActualRows
FROM dw.DimCustomer;

-- V2. Type split
SELECT CustomerType, COUNT(*) AS Customers
FROM dw.DimCustomer GROUP BY CustomerType;

-- V3. Customers with no usable name (expect only the Unknown member)
SELECT * FROM dw.DimCustomer WHERE CustomerName = N'Unknown';

-- V4. Eyeball one of each type
SELECT TOP 5 * FROM dw.DimCustomer WHERE CustomerType = N'Store'      ORDER BY CustomerKey;
SELECT TOP 5 * FROM dw.DimCustomer WHERE CustomerType = N'Individual' ORDER BY CustomerKey;
