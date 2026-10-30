/* ============================================================
   12_DataQualityChecks.sql
   Purpose : One procedure that runs every data quality check and logs
             the results to dw.DataQualityLog.
   Run     : EXEC dw.RunDataQualityChecks;
   Output  : A result set of this run's checks (failures first) and
             @CriticalFailures, so the ETL master procedure can stop a load.
   Severity: Critical = the data is wrong, do not publish
             Warning  = unusual, investigate
             Info     = context for the dashboard footnotes
   Uniqueness of SalesOrderDetailID / SalesOrderID is enforced by the
   primary keys, so no duplicate check is needed here.
   ============================================================ */
USE RevenueDW;
GO

CREATE OR ALTER PROCEDURE dw.RunDataQualityChecks
    @CriticalFailures INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunTime     DATETIME2(0) = SYSDATETIME();
    DECLARE @SourceValue DECIMAL(38,6),
            @TargetValue DECIMAL(38,6),
            @Count       INT,
            @Share       DECIMAL(9,6);

    /* ---------- Calendar ---------- */

    -- 1. DimDate has no gaps
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    SELECT 'DimDate has no gaps', 'Critical',
           CASE WHEN x.DaysLoaded = x.DaysExpected THEN 1 ELSE 0 END,
           CONCAT('Loaded=', x.DaysLoaded, ' Expected=', x.DaysExpected),
           @RunTime
    FROM (SELECT COUNT(*) AS DaysLoaded,
                 DATEDIFF(DAY, MIN(FullDate), MAX(FullDate)) + 1 AS DaysExpected
          FROM dw.DimDate) AS x;

    /* ---------- Dimension row counts ---------- */

    -- 2. Each dimension = source rows + 1 Unknown member
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    SELECT CONCAT(t.TableName, ' row count = source + Unknown'), 'Critical',
           CASE WHEN t.SourceRows + 1 = t.DimRows THEN 1 ELSE 0 END,
           CONCAT('Source+1=', t.SourceRows + 1, ' Dim=', t.DimRows),
           @RunTime
    FROM (
        SELECT 'DimTerritory' AS TableName,
               (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesTerritory) AS SourceRows,
               (SELECT COUNT(*) FROM dw.DimTerritory) AS DimRows
        UNION ALL SELECT 'DimProduct',
               (SELECT COUNT(*) FROM AdventureWorks2022.Production.Product),
               (SELECT COUNT(*) FROM dw.DimProduct)
        UNION ALL SELECT 'DimCustomer',
               (SELECT COUNT(*) FROM AdventureWorks2022.Sales.Customer),
               (SELECT COUNT(*) FROM dw.DimCustomer)
        UNION ALL SELECT 'DimSalesPerson',
               (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesPerson),
               (SELECT COUNT(*) FROM dw.DimSalesPerson)
        UNION ALL SELECT 'DimPromotion',
               (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SpecialOffer),
               (SELECT COUNT(*) FROM dw.DimPromotion)
    ) AS t;

    /* ---------- FactSales ---------- */

    -- 3. Row count matches source order lines
    SELECT @SourceValue = COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail;
    SELECT @TargetValue = COUNT(*) FROM dw.FactSales;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales row count matches source', 'Critical',
            CASE WHEN @SourceValue = @TargetValue THEN 1 ELSE 0 END,
            CONCAT('Source=', @SourceValue, ' Fact=', @TargetValue), @RunTime);

    -- 4. Revenue reconciles to source LineTotal
    SELECT @SourceValue = SUM(LineTotal) FROM AdventureWorks2022.Sales.SalesOrderDetail;
    SELECT @TargetValue = SUM(NetRevenue) FROM dw.FactSales;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales revenue reconciles to source', 'Critical',
            CASE WHEN ABS(@SourceValue - @TargetValue) < 0.01 THEN 1 ELSE 0 END,
            CONCAT('Source=', @SourceValue, ' Fact=', @TargetValue), @RunTime);

    -- 5. No orphan keys (every key exists in its dimension)
    SELECT @Count = COUNT(*)
    FROM dw.FactSales AS f
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimDate        d WHERE d.DateKey        = f.OrderDateKey)
       OR NOT EXISTS (SELECT 1 FROM dw.DimProduct     p WHERE p.ProductKey     = f.ProductKey)
       OR NOT EXISTS (SELECT 1 FROM dw.DimCustomer    c WHERE c.CustomerKey    = f.CustomerKey)
       OR NOT EXISTS (SELECT 1 FROM dw.DimTerritory   t WHERE t.TerritoryKey   = f.TerritoryKey)
       OR NOT EXISTS (SELECT 1 FROM dw.DimSalesPerson s WHERE s.SalesPersonKey = f.SalesPersonKey)
       OR NOT EXISTS (SELECT 1 FROM dw.DimPromotion   m WHERE m.PromotionKey   = f.PromotionKey);
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales has no orphan dimension keys', 'Critical',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Orphan lines=', @Count), @RunTime);

    -- 6. No lines mapped to the Unknown member (product, customer, territory, promotion)
    SELECT @Count = COUNT(*)
    FROM dw.FactSales
    WHERE ProductKey = -1 OR CustomerKey = -1 OR TerritoryKey = -1 OR PromotionKey = -1;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales lines mapped to Unknown product/customer/territory/promotion', 'Critical',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Unknown-key lines=', @Count), @RunTime);

    -- 7. Store orders should have a sales rep (online orders legitimately do not)
    SELECT @Count = COUNT(*) FROM dw.FactSales WHERE OnlineOrderFlag = 0 AND SalesPersonKey = -1;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('Store order lines without a sales rep', 'Warning',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Lines=', @Count), @RunTime);

    -- 8. Gross sales - discount = net revenue (rounding tolerance)
    SELECT @Count = COUNT(*) FROM dw.FactSales
    WHERE ABS(GrossSales - DiscountAmount - NetRevenue) > 0.01;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales gross - discount = net revenue', 'Warning',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Lines off by > 0.01 = ', @Count), @RunTime);

    -- 9. No negative or zero quantities, no negative revenue
    SELECT @Count = COUNT(*) FROM dw.FactSales
    WHERE OrderQty <= 0 OR NetRevenue < 0 OR UnitPrice < 0;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales has no negative quantity or revenue', 'Warning',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Lines=', @Count), @RunTime);

    -- 10. Lines with no usable cost at all
    SELECT @Count = COUNT(*) FROM dw.FactSales WHERE CostSource = 'Missing';
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSales lines with missing cost', 'Warning',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Lines=', @Count), @RunTime);

    -- 11. INFO: how much revenue relies on the current-cost fallback
    SELECT @Share = SUM(CASE WHEN CostSource = 'Current' THEN NetRevenue ELSE 0 END)
                    / NULLIF(SUM(NetRevenue), 0)
    FROM dw.FactSales;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('Share of revenue costed with current-cost fallback', 'Info', 1,
            CONCAT(CAST(COALESCE(@Share, 0) * 100 AS DECIMAL(5,2)), '% of net revenue'), @RunTime);

    -- 12. INFO: lines sold below cost
    SELECT @Count = COUNT(*) FROM dw.FactSales WHERE GrossProfit < 0;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('Lines sold below cost', 'Info', 1, CONCAT('Lines=', @Count), @RunTime);

    /* ---------- FactOrder ---------- */

    -- 13. Row count matches source orders
    SELECT @SourceValue = COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderHeader;
    SELECT @TargetValue = COUNT(*) FROM dw.FactOrder;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactOrder row count matches source', 'Critical',
            CASE WHEN @SourceValue = @TargetValue THEN 1 ELSE 0 END,
            CONCAT('Source=', @SourceValue, ' Fact=', @TargetValue), @RunTime);

    -- 14. SubTotal, Freight and TotalDue reconcile to source
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    SELECT CONCAT('FactOrder ', t.Measure, ' reconciles to source'), 'Critical',
           CASE WHEN ABS(t.SourceValue - t.FactValue) < 0.01 THEN 1 ELSE 0 END,
           CONCAT('Source=', t.SourceValue, ' Fact=', t.FactValue),
           @RunTime
    FROM (
        SELECT 'SubTotal' AS Measure,
               (SELECT SUM(SubTotal) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS SourceValue,
               (SELECT SUM(SubTotal) FROM dw.FactOrder) AS FactValue
        UNION ALL SELECT 'Freight',
               (SELECT SUM(Freight)  FROM AdventureWorks2022.Sales.SalesOrderHeader),
               (SELECT SUM(Freight)  FROM dw.FactOrder)
        UNION ALL SELECT 'TotalDue',
               (SELECT SUM(TotalDue) FROM AdventureWorks2022.Sales.SalesOrderHeader),
               (SELECT SUM(TotalDue) FROM dw.FactOrder)
    ) AS t;

    -- 15. Each order's SubTotal equals the sum of its FactSales lines
    SELECT @Count = COUNT(*)
    FROM dw.FactOrder AS o
    JOIN (SELECT SalesOrderID, SUM(NetRevenue) AS LineRevenue
          FROM dw.FactSales GROUP BY SalesOrderID) AS l
      ON l.SalesOrderID = o.SalesOrderID
    WHERE ABS(o.SubTotal - l.LineRevenue) > 0.01;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactOrder SubTotal matches its FactSales lines', 'Critical',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Orders off = ', @Count), @RunTime);

    -- 16. Every order has at least one line
    SELECT @Count = COUNT(*)
    FROM dw.FactOrder AS o
    WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales f WHERE f.SalesOrderID = o.SalesOrderID);
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('Every FactOrder row has FactSales lines', 'Critical',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Orders without lines=', @Count), @RunTime);

    -- 17. Ship date is not before order date
    SELECT @Count = COUNT(*) FROM dw.FactOrder WHERE ShipDateKey < OrderDateKey;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactOrder ship date is not before order date', 'Warning',
            CASE WHEN @Count = 0 THEN 1 ELSE 0 END, CONCAT('Orders=', @Count), @RunTime);

    /* ---------- FactSalesQuota ---------- */

    -- 18. Row count and total match source
    SELECT @SourceValue = COUNT(*) FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory;
    SELECT @TargetValue = COUNT(*) FROM dw.FactSalesQuota;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSalesQuota row count matches source', 'Critical',
            CASE WHEN @SourceValue = @TargetValue THEN 1 ELSE 0 END,
            CONCAT('Source=', @SourceValue, ' Fact=', @TargetValue), @RunTime);

    SELECT @SourceValue = SUM(SalesQuota) FROM AdventureWorks2022.Sales.SalesPersonQuotaHistory;
    SELECT @TargetValue = SUM(SalesQuota) FROM dw.FactSalesQuota;
    INSERT INTO dw.DataQualityLog (CheckName, Severity, Passed, Detail, CheckedAt)
    VALUES ('FactSalesQuota total reconciles to source', 'Critical',
            CASE WHEN ABS(@SourceValue - @TargetValue) < 0.01 THEN 1 ELSE 0 END,
            CONCAT('Source=', @SourceValue, ' Fact=', @TargetValue), @RunTime);

    /* ---------- Summary ---------- */
    SELECT @CriticalFailures = COUNT(*)
    FROM dw.DataQualityLog
    WHERE CheckedAt = @RunTime AND Severity = 'Critical' AND Passed = 0;

    SELECT CheckName, Severity, Passed, Detail
    FROM dw.DataQualityLog
    WHERE CheckedAt = @RunTime
    ORDER BY Passed,
             CASE Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END,
             CheckID;
END;
GO

-- Run it:
DECLARE @Failures INT;
EXEC dw.RunDataQualityChecks @CriticalFailures = @Failures OUTPUT;
SELECT @Failures AS CriticalFailures;
GO
