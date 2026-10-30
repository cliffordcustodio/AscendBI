/* ============================================================
   13_EtlProcedures.sql   (REFERENCE VERSION)
   Purpose : Turn the load scripts (02-11) into stored procedures and
             add one master procedure that rebuilds the warehouse.

   Structure
     Helpers : dw.EtlLogStart, dw.EtlLogEnd, dw.EtlGetDateOffset
     Loaders : dw.LoadDimDate, LoadDimTerritory, LoadDimProduct,
               LoadDimCustomer, LoadDimSalesPerson, LoadDimPromotion,
               LoadStgProductCost, LoadFactSales, LoadFactOrder,
               LoadFactSalesQuota
     Post    : dw.UpdateDimDateLatestMonth
     Master  : dw.LoadWarehouse   <-- the one command you run

   Pattern every loader follows
     1. Log start (dw.EtlRunLog, status Running)
     2. BEGIN TRY / BEGIN TRANSACTION
     3. DELETE the table, INSERT the Unknown member, INSERT real rows
     4. COMMIT, log Succeeded with the row count
     5. CATCH: ROLLBACK (the table keeps its previous data),
        log Failed with the error text, re-throw

   Needs   : Tables already exist (DDL stays in scripts 01-11) and
             dw.EtlConfig has DateOffsetYears (01b).
   Quality : The master calls dw.RunDataQualityChecks if it exists.
             Pass @RunQualityChecks = 0 to skip it.
   Safe to re-run.
   ============================================================ */
USE RevenueDW;
GO

/* ============================================================
   HELPERS
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.EtlLogStart
    @ProcedureName SYSNAME,
    @RunID         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dw.EtlRunLog (ProcedureName) VALUES (@ProcedureName);
    SET @RunID = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE dw.EtlLogEnd
    @RunID        INT,
    @Status       VARCHAR(20),               -- Succeeded / Failed
    @RowsLoaded   INT            = NULL,
    @ErrorMessage NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dw.EtlRunLog
    SET EndTime      = SYSDATETIME(),
        RowsLoaded   = @RowsLoaded,
        Status       = @Status,
        ErrorMessage = @ErrorMessage
    WHERE RunID = @RunID;
END;
GO

-- Reads the date offset and FAILS LOUDLY if it is missing (a NULL offset would
-- otherwise load zero fact rows with no error).
CREATE OR ALTER PROCEDURE dw.EtlGetDateOffset
    @DateOffsetYears INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @DateOffsetYears = TRY_CAST(ConfigValue AS INT)
    FROM dw.EtlConfig
    WHERE ConfigKey = 'DateOffsetYears';

    IF @DateOffsetYears IS NULL
        THROW 50001, N'DateOffsetYears is missing or not a number in dw.EtlConfig. Run 01b_EtlConfig.sql first.', 1;
END;
GO

/* ============================================================
   DIMENSIONS
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.LoadDimDate
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);
    DECLARE @DateOffsetYears INT, @StartDate DATE, @EndDate DATE;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimDate', @RunID = @RunID OUTPUT;

    BEGIN TRY
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        SELECT
            @StartDate = DATEADD(YEAR, @DateOffsetYears, DATEFROMPARTS(YEAR(MIN(OrderDate)), 1, 1)),
            @EndDate   = DATEADD(YEAR, @DateOffsetYears, DATEFROMPARTS(YEAR(MAX(DueDate)), 12, 31))
        FROM AdventureWorks2022.Sales.SalesOrderHeader;

        BEGIN TRANSACTION;

        DELETE FROM dw.DimDate;

        ;WITH Dates AS (
            SELECT @StartDate AS d
            UNION ALL
            SELECT DATEADD(DAY, 1, d) FROM Dates WHERE d < @EndDate
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
            (DATEDIFF(DAY, '19000101', d) % 7) + 1,      -- 1900-01-01 was a Monday
            DATENAME(WEEKDAY, d),
            CASE WHEN (DATEDIFF(DAY, '19000101', d) % 7) + 1 IN (6, 7) THEN 1 ELSE 0 END
        FROM Dates
        OPTION (MAXRECURSION 0);

        SELECT @Rows = COUNT(*) FROM dw.DimDate;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadDimTerritory
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimTerritory', @RunID = @RunID OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.DimTerritory;

        INSERT INTO dw.DimTerritory
            (TerritoryKey, TerritoryID, TerritoryName, CountryRegionCode, CountryName, TerritoryGroup)
        VALUES (-1, -1, N'Unknown', N'N/A', N'Unknown', N'Unknown');

        INSERT INTO dw.DimTerritory
            (TerritoryKey, TerritoryID, TerritoryName, CountryRegionCode, CountryName, TerritoryGroup)
        SELECT
            ROW_NUMBER() OVER (ORDER BY t.TerritoryID),
            t.TerritoryID,
            t.Name,
            t.CountryRegionCode,
            COALESCE(c.Name, N'Unknown'),
            t.[Group]
        FROM AdventureWorks2022.Sales.SalesTerritory AS t
        LEFT JOIN AdventureWorks2022.Person.CountryRegion AS c
               ON c.CountryRegionCode = t.CountryRegionCode;

        SELECT @Rows = COUNT(*) FROM dw.DimTerritory;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadDimProduct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimProduct', @RunID = @RunID OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.DimProduct;

        INSERT INTO dw.DimProduct
            (ProductKey, ProductID, ProductName, ProductNumber, CategoryName, SubcategoryName,
             Color, Size, ProductLine, ProductClass, ProductStyle, ListPrice,
             CurrentStandardCost, IsManufactured)
        VALUES (-1, -1, N'Unknown', N'N/A', N'Unknown', N'Unknown',
                N'N/A', N'N/A', N'N/A', N'N/A', N'N/A', 0, 0, 0);

        INSERT INTO dw.DimProduct
            (ProductKey, ProductID, ProductName, ProductNumber, CategoryName, SubcategoryName,
             Color, Size, ProductLine, ProductClass, ProductStyle, ListPrice,
             CurrentStandardCost, IsManufactured)
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

        SELECT @Rows = COUNT(*) FROM dw.DimProduct;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadDimCustomer
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimCustomer', @RunID = @RunID OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.DimCustomer;

        INSERT INTO dw.DimCustomer
            (CustomerKey, CustomerID, CustomerType, CustomerName, StoreName, AccountNumber)
        VALUES (-1, -1, N'Unknown', N'Unknown', N'N/A', 'N/A');

        INSERT INTO dw.DimCustomer
            (CustomerKey, CustomerID, CustomerType, CustomerName, StoreName, AccountNumber)
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

        SELECT @Rows = COUNT(*) FROM dw.DimCustomer;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadDimSalesPerson
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimSalesPerson', @RunID = @RunID OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.DimSalesPerson;

        INSERT INTO dw.DimSalesPerson
            (SalesPersonKey, SalesPersonID, FullName, JobTitle, TerritoryName, CommissionPct, Bonus)
        VALUES (-1, -1, N'Unknown', N'N/A', N'Unknown', 0, 0);

        INSERT INTO dw.DimSalesPerson
            (SalesPersonKey, SalesPersonID, FullName, JobTitle, TerritoryName, CommissionPct, Bonus)
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

        SELECT @Rows = COUNT(*) FROM dw.DimSalesPerson;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadDimPromotion
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000), @DateOffsetYears INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadDimPromotion', @RunID = @RunID OUTPUT;

    BEGIN TRY
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        BEGIN TRANSACTION;

        DELETE FROM dw.DimPromotion;

        INSERT INTO dw.DimPromotion
            (PromotionKey, SpecialOfferID, Description, DiscountPct, OfferType, Category,
             StartDate, EndDate, MinQty, MaxQty)
        VALUES (-1, -1, N'Unknown', 0, N'Unknown', N'Unknown', NULL, NULL, 0, NULL);

        INSERT INTO dw.DimPromotion
            (PromotionKey, SpecialOfferID, Description, DiscountPct, OfferType, Category,
             StartDate, EndDate, MinQty, MaxQty)
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

        SELECT @Rows = COUNT(*) FROM dw.DimPromotion;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

/* ============================================================
   STAGING
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.LoadStgProductCost
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000);

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadStgProductCost', @RunID = @RunID OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM stg.ProductCostRange;

        -- Dates stay as SOURCE dates (not offset): FactSales compares them with the source OrderDate
        INSERT INTO stg.ProductCostRange (ProductID, StartDate, EndDate, StandardCost)
        SELECT
            ProductID,
            CAST(StartDate AS DATE),
            COALESCE(CAST(EndDate AS DATE), '9999-12-31'),
            StandardCost
        FROM AdventureWorks2022.Production.ProductCostHistory;

        SELECT @Rows = COUNT(*) FROM stg.ProductCostRange;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

/* ============================================================
   FACTS
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.LoadFactSales
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000), @DateOffsetYears INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadFactSales', @RunID = @RunID OUTPUT;

    BEGIN TRY
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        BEGIN TRANSACTION;

        DELETE FROM dw.FactSales;

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
            COALESCE(dp.ProductKey,     -1),
            COALESCE(dc.CustomerKey,    -1),
            COALESCE(dt.TerritoryKey,   -1),
            COALESCE(ds.SalesPersonKey, -1),
            COALESCE(dpr.PromotionKey,  -1),
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
        -- INNER JOIN on order date: a missing calendar row drops the line,
        -- which the row-count quality check will expose.
        JOIN dw.DimDate AS od
          ON od.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.OrderDate AS DATE))
        LEFT JOIN dw.DimDate AS sd
          ON sd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.ShipDate AS DATE))
        LEFT JOIN dw.DimProduct     AS dp  ON dp.ProductID        = d.ProductID
        LEFT JOIN dw.DimCustomer    AS dc  ON dc.CustomerID       = h.CustomerID
        LEFT JOIN dw.DimTerritory   AS dt  ON dt.TerritoryID      = h.TerritoryID
        LEFT JOIN dw.DimSalesPerson AS ds  ON ds.SalesPersonID    = h.SalesPersonID
        LEFT JOIN dw.DimPromotion   AS dpr ON dpr.SpecialOfferID  = d.SpecialOfferID
        -- Cost in effect on the SOURCE order date (TOP 1 guards against overlapping ranges)
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

        SELECT @Rows = COUNT(*) FROM dw.FactSales;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadFactOrder
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000), @DateOffsetYears INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadFactOrder', @RunID = @RunID OUTPUT;

    BEGIN TRY
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        BEGIN TRANSACTION;

        DELETE FROM dw.FactOrder;

        INSERT INTO dw.FactOrder (
            SalesOrderID, OrderDateKey, ShipDateKey, DueDateKey,
            CustomerKey, SalesPersonKey, TerritoryKey, ShipMethodName,
            OnlineOrderFlag, SubTotal, TaxAmt, Freight, TotalDue, FulfilmentDays)
        SELECT
            h.SalesOrderID,
            od.DateKey,
            sd.DateKey,
            dd.DateKey,
            COALESCE(dc.CustomerKey,    -1),
            COALESCE(ds.SalesPersonKey, -1),
            COALESCE(dt.TerritoryKey,   -1),
            COALESCE(sm.Name, N'Unknown'),
            h.OnlineOrderFlag,
            h.SubTotal,
            h.TaxAmt,
            h.Freight,
            h.TotalDue,
            DATEDIFF(DAY, h.OrderDate, h.ShipDate)       -- source dates; NULL if not shipped
        FROM AdventureWorks2022.Sales.SalesOrderHeader AS h
        JOIN dw.DimDate AS od
          ON od.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.OrderDate AS DATE))
        LEFT JOIN dw.DimDate AS sd
          ON sd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.ShipDate AS DATE))
        LEFT JOIN dw.DimDate AS dd
          ON dd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(h.DueDate AS DATE))
        LEFT JOIN dw.DimCustomer    AS dc ON dc.CustomerID     = h.CustomerID
        LEFT JOIN dw.DimSalesPerson AS ds ON ds.SalesPersonID  = h.SalesPersonID
        LEFT JOIN dw.DimTerritory   AS dt ON dt.TerritoryID    = h.TerritoryID
        LEFT JOIN AdventureWorks2022.Purchasing.ShipMethod AS sm
               ON sm.ShipMethodID = h.ShipMethodID;

        SELECT @Rows = COUNT(*) FROM dw.FactOrder;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dw.LoadFactSalesQuota
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Rows INT, @Err NVARCHAR(4000), @DateOffsetYears INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadFactSalesQuota', @RunID = @RunID OUTPUT;

    BEGIN TRY
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        BEGIN TRANSACTION;

        DELETE FROM dw.FactSalesQuota;

        INSERT INTO dw.FactSalesQuota (SalesPersonKey, QuotaDateKey, SalesQuota)
        SELECT
            ds.SalesPersonKey,
            dd.DateKey,
            q.SalesQuota
        FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory AS q
        JOIN dw.DimSalesPerson AS ds ON ds.SalesPersonID = q.BusinessEntityID
        JOIN dw.DimDate        AS dd ON dd.FullDate = DATEADD(YEAR, @DateOffsetYears, CAST(q.QuotaDate AS DATE));

        SELECT @Rows = COUNT(*) FROM dw.FactSalesQuota;
        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = @Rows;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

/* ============================================================
   POST-LOAD: mark the latest month that has sales
   (the dashboard's "current month" KPIs depend on this flag)
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.UpdateDimDateLatestMonth
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunID INT, @Err NVARCHAR(4000), @LatestYearMonthKey INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.UpdateDimDateLatestMonth', @RunID = @RunID OUTPUT;

    BEGIN TRY
        SELECT @LatestYearMonthKey = MAX(d.YearMonthKey)
        FROM dw.FactSales AS f
        JOIN dw.DimDate   AS d ON d.DateKey = f.OrderDateKey;

        BEGIN TRANSACTION;

        UPDATE dw.DimDate SET IsLatestMonth = 0;
        UPDATE dw.DimDate SET IsLatestMonth = 1 WHERE YearMonthKey = @LatestYearMonthKey;

        COMMIT TRANSACTION;

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded', @RowsLoaded = NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

/* ============================================================
   MASTER: rebuild the whole warehouse with one command
   Order matters: calendar and dimensions first, then staging,
   then facts, then the latest-month flag, then quality checks.
   ============================================================ */

CREATE OR ALTER PROCEDURE dw.LoadWarehouse
    @RunQualityChecks BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunID INT, @Err NVARCHAR(4000), @Msg NVARCHAR(2048);
    DECLARE @StartTime DATETIME2(0) = SYSDATETIME();
    DECLARE @DateOffsetYears INT, @CriticalFailures INT;

    EXEC dw.EtlLogStart @ProcedureName = N'dw.LoadWarehouse', @RunID = @RunID OUTPUT;

    BEGIN TRY
        -- Fail fast if the configuration is missing
        EXEC dw.EtlGetDateOffset @DateOffsetYears = @DateOffsetYears OUTPUT;

        -- 1. Calendar and dimensions
        EXEC dw.LoadDimDate;
        EXEC dw.LoadDimTerritory;
        EXEC dw.LoadDimProduct;
        EXEC dw.LoadDimCustomer;
        EXEC dw.LoadDimSalesPerson;
        EXEC dw.LoadDimPromotion;

        -- 2. Staging
        EXEC dw.LoadStgProductCost;

        -- 3. Facts (FactSales before FactOrder)
        EXEC dw.LoadFactSales;
        EXEC dw.LoadFactOrder;
        EXEC dw.LoadFactSalesQuota;

        -- 4. Post-load
        EXEC dw.UpdateDimDateLatestMonth;

        -- 5. Quality gate: any Critical failure fails the whole run.
        --    Works with any implementation of dw.RunDataQualityChecks that
        --    writes to dw.DataQualityLog (it does not rely on an OUTPUT parameter).
        IF @RunQualityChecks = 1
        BEGIN
            EXEC dw.RunDataQualityChecks;

            SELECT @CriticalFailures = COUNT(*)
            FROM dw.DataQualityLog
            WHERE CheckedAt >= @StartTime
              AND Severity = 'Critical'
              AND Passed = 0;

            IF @CriticalFailures > 0
            BEGIN
                SET @Msg = CONCAT('Data quality gate failed: ', @CriticalFailures,
                                  ' critical check(s) failed. See dw.DataQualityLog.');
                THROW 50002, @Msg, 1;
            END
        END

        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Succeeded';

        -- Summary of this run
        SELECT ProcedureName, Status, RowsLoaded,
               DATEDIFF(SECOND, StartTime, EndTime) AS Seconds
        FROM dw.EtlRunLog
        WHERE StartTime >= @StartTime
        ORDER BY RunID;
    END TRY
    BEGIN CATCH
        SET @Err = LEFT(CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        EXEC dw.EtlLogEnd @RunID = @RunID, @Status = 'Failed', @ErrorMessage = @Err;
        THROW;
    END CATCH
END;
GO

/* ============================================================
   RUN IT
   ============================================================ */
-- EXEC dw.LoadWarehouse;                         -- full rebuild with quality gate
-- EXEC dw.LoadWarehouse @RunQualityChecks = 0;   -- rebuild, skip the quality gate

-- Review recent runs:
-- SELECT TOP 50 * FROM dw.EtlRunLog ORDER BY RunID DESC;
-- SELECT * FROM dw.EtlRunLog WHERE Status = 'Failed' ORDER BY RunID DESC;
