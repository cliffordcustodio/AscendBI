/*
Business Question:
What is the total revenue generated?

Business Value:
Provides a high-level performance indicator.
*/

SELECT
    SUM(SalesAmount) AS TotalRevenue
FROM FactInternetSales;
