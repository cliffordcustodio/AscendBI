/* ============================================================
   04_DimProduct.sql
   Grain  : One row per product (+ Unknown).
   Source : Production.Product, ProductSubcategory, ProductCategory
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.dim_product') IS NOT NULL DROP TABLE dw.dim_product;
GO

IF OBJECT_ID('dw.DimProduct') IS NULL
CREATE TABLE dw.DimProduct (
    ProductKey           INT           NOT NULL PRIMARY KEY,   -- surrogate; -1 = Unknown
    ProductID            INT           NOT NULL UNIQUE,        -- natural key
    ProductName          NVARCHAR(50)  NOT NULL,
    ProductNumber        NVARCHAR(25)  NOT NULL,
    CategoryName         NVARCHAR(50)  NOT NULL,
    SubcategoryName      NVARCHAR(50)  NOT NULL,
    Color                 NVARCHAR(15)  NOT NULL,
    Size                  NVARCHAR(5)   NOT NULL,
    ProductLine          NVARCHAR(20)  NOT NULL,
    ProductClass         NVARCHAR(20)  NOT NULL,
    ProductStyle         NVARCHAR(20)  NOT NULL,
    ListPrice            DECIMAL(19,4) NOT NULL,
    CurrentStandardCost DECIMAL(19,4) NOT NULL,   -- today's cost; history lives in stg.ProductCostRange
    IsManufactured       BIT           NOT NULL
);
GO

DELETE FROM dw.DimProduct;
GO

INSERT INTO dw.DimProduct
VALUES (-1, -1, N'Unknown', N'N/A', N'Unknown', N'Unknown', N'N/A', N'N/A',
        N'N/A', N'N/A', N'N/A', 0, 0, 0);
GO

INSERT INTO dw.DimProduct
SELECT
    ROW_NUMBER() OVER (ORDER BY p.ProductID),
    p.ProductID,
    p.Name,
    p.ProductNumber,
    COALESCE(pc.Name, N'Uncategorized'),     -- components have no subcategory
    COALESCE(ps.Name, N'Uncategorized'),
    COALESCE(p.Color, N'N/A'),
    COALESCE(p.Size,  N'N/A'),
    CASE RTRIM(p.ProductLine) WHEN 'R' THEN N'Road' WHEN 'M' THEN N'Mountain'
                              WHEN 'T' THEN N'Touring' WHEN 'S' THEN N'Standard' ELSE N'N/A' END,
    CASE RTRIM(p.Class)       WHEN 'H' THEN N'High' WHEN 'M' THEN N'Medium'
                              WHEN 'L' THEN N'Low' ELSE N'N/A' END,
    CASE RTRIM(p.Style)       WHEN 'W' THEN N'Womens' WHEN 'M' THEN N'Mens'
                              WHEN 'U' THEN N'Universal' ELSE N'N/A' END,
    p.ListPrice,
    p.StandardCost,
    p.MakeFlag
FROM AdventureWorks2022.Production.Product AS p
LEFT JOIN AdventureWorks2022.Production.ProductSubcategory AS ps
       ON ps.ProductSubcategoryID = p.ProductSubcategoryID
LEFT JOIN AdventureWorks2022.Production.ProductCategory AS pc
       ON pc.ProductCategoryID = ps.ProductCategoryID;
GO

-- ===== Validation =====
-- V1. Expect source rows + 1
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Production.Product) + 1 AS ExpectedRows,
       COUNT(*) AS ActualRows
FROM dw.DimProduct;

-- V2. Category split (components fall under Uncategorized)
SELECT CategoryName, COUNT(*) AS Products
FROM dw.DimProduct GROUP BY CategoryName ORDER BY Products DESC;

-- V3. Products that are actually sold, by category
SELECT p.CategoryName, COUNT(DISTINCT d.ProductID) AS SoldProducts
FROM AdventureWorks2022.Sales.SalesOrderDetail d
JOIN dw.DimProduct p ON p.ProductID = d.ProductID
GROUP BY p.CategoryName ORDER BY SoldProducts DESC;

-- V4. Eyeball
SELECT TOP 20 * FROM dw.DimProduct WHERE ProductKey > 0 ORDER BY ProductKey;
