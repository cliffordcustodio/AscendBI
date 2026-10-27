# 01 - Business Requirements

## 1. Purpose
Provide a single, trusted view of sales and profitability so leaders can monitor performance, find growth opportunities, and track sales operations.

## 2. Audience (personas)

| Persona | Needs | Primary pages |
|---|---|
| **CEO / Executive** | Is the business healthy? Headline KPIs in 10 seconds |
| **VP Sales** | Where to push growth; rep performance vs. quota |
| **Finance Lead** | Margin, discount leakage, forecast |
| **Operations Manager** | Fulfilment speed and shipping cost |

## 3. Business questions and where they are answered

| # | Question | Page |
|---|---|---|
| Q1 | Revenue, profit, margin trend vs. prior year | Executive Pulse |
| Q2 | Best and worst territories, categories, products | Growth Opportunities |
| Q3 | Impact of discounts and promotions on margin | Profitability |
| Q4 | Most valuable customer segments | Growth Opportunities |
| Q5 | Rep performance vs. quota | Operations |
| Q6 | Fulfilment time and freight cost | Operations |
| Q7 | Six-month outlook and anomalies | Forecast & Insights |

## 4. KPI dictionary

| KPI | Definition | Source |
|---|---|---|
| Net Revenue | `SUM(LineTotal)` (after line discounts; excludes tax and freight) | `SalesOrderDetail` |
| Gross Sales | `SUM(OrderQty * UnitPrice)` | `SalesOrderDetail` |
| Discount Amount | Gross Sales - Net Revenue | derived |
| Discount Rate | Discount Amount / Gross Sales | derived |
| COGS | `SUM(OrderQty * UnitCost)` where UnitCost is the standard cost effective on the order date | `ProductCostHistory` |
| Gross Profit | Net Revenue - COGS | derived |
| Gross Margin % | Gross Profit / Net Revenue | derived |
| Orders | `DISTINCT COUNT(SalesOrderID)` | `SalesOrderHeader` |
| Units Sold | `SUM(OrderQty)` | `SalesOrderDetail` |
| AOV | Net Revenue / Orders | derived |
| YoY Growth % | (Current period - same period last year) / same period last year | DAX / SQL |
| Fulfilment Days | `ShipDate - OrderDate` (average) | `SalesOrderHeader` |
| Freight % | `SUM(Freight) / SUM(SubTotal)` | `SalesOrderHeader` |
| Quota Attainment % | Rep Net Revenue / Quota for the period | `SalesPersonQuotaHistory` |
| Repeat Customer Rate | Customers with 2+ orders / customers with 1+ orders | derived |

## 5. Scope

**In scope:** Sales orders, products, customers, territories, sales reps, promotions, shipping.
**Out of scope (v1):** Purchasing/vendors, HR/payroll, manufacturing work orders, inventory. (Candidate topics for Projects 02 and 03.)

## 6. Success criteria

- Every KPI reconciles to source: total Net Revenue in the dashboard matches the source query within rounding.
- Executive Pulse loads and is understandable without explanation.
- Any KPI can be drilled to product / customer / order level.
- Warehouse can be rebuilt from scratch with one script run.
- Repo is understandable to a stranger in 5 minutes via the README.

## 7. Known data caveats

- AdventureWorks sales span roughly **mid-2011 to mid-2014**; "current period" means the latest data month, not today's date.
- The final period (2014) is partial; YoY comparisons must be like-for-like.
- Online orders have no sales rep (`SalesPersonID` is NULL), so rep analysis covers store (reseller) orders only.
