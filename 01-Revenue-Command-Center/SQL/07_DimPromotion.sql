/* ============================================================
   07_DimPromotion.sql
   Grain  : One row per special offer (+ Unknown).
   Source : Sales.SpecialOffer
   Note   : "No Discount" (SpecialOfferID 1) is a real offer, not null.
            Start/end dates use the same offset as DimDate.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.dim_promotion') IS NOT NULL DROP TABLE dw.dim_promotion;
GO

IF OBJECT_ID('dw.DimPromotion') IS NULL
CREATE TABLE dw.DimPromotion (
    PromotionKey     INT           NOT NULL PRIMARY KEY,   -- surrogate; -1 = Unknown
    SpecialOfferID  INT           NOT NULL UNIQUE,        -- natural key
    Description       NVARCHAR(255) NOT NULL,
    DiscountPct      DECIMAL(9,4)  NOT NULL,
    OfferType        NVARCHAR(50)  NOT NULL,
    Category          NVARCHAR(50)  NOT NULL,
    StartDate        DATE          NULL,
    EndDate          DATE          NULL,
    MinQty           INT           NOT NULL,
    MaxQty           INT           NULL
);
GO

DELETE FROM dw.DimPromotion;
GO

INSERT INTO dw.DimPromotion
VALUES (-1, -1, N'Unknown', 0, N'Unknown', N'Unknown', NULL, NULL, 0, NULL);
GO

DECLARE @DateOffsetYears INT =
    (SELECT CAST(ConfigValue AS INT) FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears');

INSERT INTO dw.DimPromotion
SELECT
    ROW_NUMBER() OVER (ORDER BY so.SpecialOfferID),
    so.SpecialOfferID,
    so.Description,
    so.DiscountPct,
    so.[Type],
    so.Category,
    DATEADD(YEAR, @DateOffsetYears, CAST(so.StartDate AS DATE)),
    DATEADD(YEAR, @DateOffsetYears, CAST(so.EndDate   AS DATE)),
    so.MinQty,
    so.MaxQty
FROM AdventureWorks2022.Sales.SpecialOffer AS so;
GO

-- ===== Validation =====
-- V1. Expect source rows + 1
SELECT (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SpecialOffer) + 1 AS ExpectedRows,
       COUNT(*) AS ActualRows
FROM dw.DimPromotion;

-- V2. Eyeball everything (it is small)
SELECT * FROM dw.DimPromotion ORDER BY PromotionKey;

-- V3. Offers actually used on order lines
SELECT so.Description, COUNT(*) AS OrderLines
FROM AdventureWorks2022.Sales.SalesOrderDetail d
JOIN AdventureWorks2022.Sales.SpecialOffer so ON so.SpecialOfferID = d.SpecialOfferID
GROUP BY so.Description ORDER BY OrderLines DESC;
