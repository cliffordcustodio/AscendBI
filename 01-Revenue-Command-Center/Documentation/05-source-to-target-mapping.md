# 05 - Source-to-Target Mapping

> **Project 01: Revenue Command Center** | `AdventureWorks2022` (source) to `RevenueDW` (target)

Column-level mapping for the three fact loads. Use it with [`04-fact-table-load-requirements.md`](04-fact-table-load-requirements.md), which defines the rules and acceptance checks.

**Conventions**

| Term | Meaning |
|---|---|
| **Direct** | Copied from the source column with no change |
| **Lookup** | Natural key from the source is joined to a dimension to return its surrogate key (`-1` if no match) |
| **Derived** | Calculated from one or more columns |
| **Offset date** | Source date shifted by `DateOffsetYears` (from `dw.EtlConfig`) before the `DimDate` lookup |

## Contents

1. [FactSales](#1-factsales)
2. [FactOrder](#2-factorder)
3. [FactSalesQuota](#3-factsalesquota)
4. [Supporting mapping: StgProductCost](#4-supporting-mapping-stgproductcost)
5. [Dimension lookup reference](#5-dimension-lookup-reference)
6. [Source columns intentionally not loaded](#6-source-columns-intentionally-not-loaded)

---

## 1. FactSales

**Target:** `dw.FactSales` | **Grain:** one row per order line
**Driving source:** `Sales.SalesOrderDetail` (alias **D**), joined to `Sales.SalesOrderHeader` (alias **H**) on `SalesOrderID`

| # | Target column | Target type | Source table | Source column | Source type | Mapping type | Transformation / rule |
|---|---|---|---|---|---|---|---|
| 1 | `SalesOrderDetailID` | INT, PK | `Sales.SalesOrderDetail` (D) | `SalesOrderDetailID` | int | Direct | |
| 2 | `SalesOrderID` | INT | `Sales.SalesOrderDetail` (D) | `SalesOrderID` | int | Direct | |
| 3 | `OrderDateKey` | INT | `Sales.SalesOrderHeader` (H) | `OrderDate` | datetime | Lookup | Convert to `DATE`, apply offset, match `DimDate.FullDate`, return `DimDate.DateKey`. **Inner join** |
| 4 | `ShipDateKey` | INT, NULL | `Sales.SalesOrderHeader` (H) | `ShipDate` | datetime, NULL | Lookup | Same as above. **Left join**; NULL if no ship date |
| 5 | `ProductKey` | INT | `Sales.SalesOrderDetail` (D) | `ProductID` | int | Lookup | `DimProduct.ProductID` = D.`ProductID`, return `ProductKey`; `-1` if none |
| 6 | `CustomerKey` | INT | `Sales.SalesOrderHeader` (H) | `CustomerID` | int | Lookup | `DimCustomer.CustomerID` = H.`CustomerID`, return `CustomerKey`; `-1` if none |
| 7 | `TerritoryKey` | INT | `Sales.SalesOrderHeader` (H) | `TerritoryID` | int, NULL | Lookup | `DimTerritory.TerritoryID` = H.`TerritoryID`, return `TerritoryKey`; `-1` if none |
| 8 | `SalesPersonKey` | INT | `Sales.SalesOrderHeader` (H) | `SalesPersonID` | int, NULL | Lookup | `DimSalesPerson.SalesPersonID` = H.`SalesPersonID`, return `SalesPersonKey`; `-1` for online orders |
| 9 | `PromotionKey` | INT | `Sales.SalesOrderDetail` (D) | `SpecialOfferID` | int | Lookup | `DimPromotion.SpecialOfferID` = D.`SpecialOfferID`, return `PromotionKey`; `-1` if none |
| 10 | `OnlineOrderFlag` | BIT | `Sales.SalesOrderHeader` (H) | `OnlineOrderFlag` | bit (Flag) | Direct | |
| 11 | `OrderQty` | SMALLINT | `Sales.SalesOrderDetail` (D) | `OrderQty` | smallint | Direct | |
| 12 | `UnitPrice` | DECIMAL(19,4) | `Sales.SalesOrderDetail` (D) | `UnitPrice` | money | Direct | |
| 13 | `UnitPriceDiscount` | DECIMAL(19,4) | `Sales.SalesOrderDetail` (D) | `UnitPriceDiscount` | money | Direct | Stored as a fraction (e.g. 0.02) |
| 14 | `UnitCost` | DECIMAL(19,4) | `stg.ProductCostRange`, then `dw.DimProduct` | `StandardCost`, then `CurrentStandardCost` | decimal | Derived | Range cost where `ProductID` matches and **source** `OrderDate` is between `StartDate` and `EndDate` (most recent start if several); else `DimProduct.CurrentStandardCost`; else 0 |
| 15 | `CostSource` | VARCHAR(10) | n/a | n/a | n/a | Derived | `History` if range cost used, `Current` if fallback used, `Missing` if neither |
| 16 | `GrossSales` | DECIMAL(38,6) | `Sales.SalesOrderDetail` (D) | `OrderQty`, `UnitPrice` | smallint, money | Derived | `OrderQty * UnitPrice` |
| 17 | `DiscountAmount` | DECIMAL(38,6) | `Sales.SalesOrderDetail` (D) | `OrderQty`, `UnitPrice`, `UnitPriceDiscount` | smallint, money, money | Derived | `OrderQty * UnitPrice * UnitPriceDiscount` |
| 18 | `NetRevenue` | DECIMAL(38,6) | `Sales.SalesOrderDetail` (D) | `LineTotal` | numeric(38,6), computed | Direct | Source computed column; reconciles to source exactly |
| 19 | `COGS` | DECIMAL(38,6) | n/a | `OrderQty` (D), `UnitCost` (row 14) | smallint, decimal | Derived | `OrderQty * UnitCost` |
| 20 | `GrossProfit` | DECIMAL(38,6) | n/a | `NetRevenue` (row 18), `COGS` (row 19) | decimal | Derived | `NetRevenue - COGS` |

---

## 2. FactOrder

**Target:** `dw.FactOrder` | **Grain:** one row per order
**Driving source:** `Sales.SalesOrderHeader` (alias **H**)

| # | Target column | Target type | Source table | Source column | Source type | Mapping type | Transformation / rule |
|---|---|---|---|---|---|---|---|
| 1 | `SalesOrderID` | INT, PK | `Sales.SalesOrderHeader` (H) | `SalesOrderID` | int | Direct | |
| 2 | `OrderDateKey` | INT | `Sales.SalesOrderHeader` (H) | `OrderDate` | datetime | Lookup | `DATE`, apply offset, match `DimDate.FullDate`, return `DateKey`. **Inner join** |
| 3 | `ShipDateKey` | INT, NULL | `Sales.SalesOrderHeader` (H) | `ShipDate` | datetime, NULL | Lookup | Same; **left join**; NULL if no ship date |
| 4 | `DueDateKey` | INT, NULL | `Sales.SalesOrderHeader` (H) | `DueDate` | datetime | Lookup | Same; **left join** |
| 5 | `CustomerKey` | INT | `Sales.SalesOrderHeader` (H) | `CustomerID` | int | Lookup | `DimCustomer.CustomerID`; `-1` if none |
| 6 | `SalesPersonKey` | INT | `Sales.SalesOrderHeader` (H) | `SalesPersonID` | int, NULL | Lookup | `DimSalesPerson.SalesPersonID`; `-1` if none |
| 7 | `TerritoryKey` | INT | `Sales.SalesOrderHeader` (H) | `TerritoryID` | int, NULL | Lookup | `DimTerritory.TerritoryID`; `-1` if none |
| 8 | `ShipMethodName` | NVARCHAR(50) | `Purchasing.ShipMethod` (S) | `Name` | nvarchar(50) | Lookup | S.`ShipMethodID` = H.`ShipMethodID`; `Unknown` if none. **Left join** |
| 9 | `OnlineOrderFlag` | BIT | `Sales.SalesOrderHeader` (H) | `OnlineOrderFlag` | bit (Flag) | Direct | |
| 10 | `SubTotal` | DECIMAL(19,4) | `Sales.SalesOrderHeader` (H) | `SubTotal` | money | Direct | |
| 11 | `TaxAmt` | DECIMAL(19,4) | `Sales.SalesOrderHeader` (H) | `TaxAmt` | money | Direct | |
| 12 | `Freight` | DECIMAL(19,4) | `Sales.SalesOrderHeader` (H) | `Freight` | money | Direct | |
| 13 | `TotalDue` | DECIMAL(19,4) | `Sales.SalesOrderHeader` (H) | `TotalDue` | money, computed | Direct | |
| 14 | `FulfilmentDays` | INT, NULL | `Sales.SalesOrderHeader` (H) | `OrderDate`, `ShipDate` | datetime, datetime NULL | Derived | Days from **source** `OrderDate` to **source** `ShipDate`; NULL if not shipped |

---

## 3. FactSalesQuota

**Target:** `dw.FactSalesQuota` | **Grain:** one row per sales rep per quota date
**Driving source:** `Sales.SalesPersonQuotaHistory` (alias **Q**)

| # | Target column | Target type | Source table | Source column | Source type | Mapping type | Transformation / rule |
|---|---|---|---|---|---|---|---|
| 1 | `SalesPersonKey` | INT, PK (part) | `Sales.SalesPersonQuotaHistory` (Q) | `BusinessEntityID` | int | Lookup | `DimSalesPerson.SalesPersonID` = Q.`BusinessEntityID`, return `SalesPersonKey`. **Inner join** |
| 2 | `QuotaDateKey` | INT, PK (part) | `Sales.SalesPersonQuotaHistory` (Q) | `QuotaDate` | datetime | Lookup | `DATE`, apply offset, match `DimDate.FullDate`, return `DateKey`. **Inner join** |
| 3 | `SalesQuota` | DECIMAL(19,4) | `Sales.SalesPersonQuotaHistory` (Q) | `SalesQuota` | money | Direct | |

---

## 4. Supporting mapping: StgProductCost

Feeds `FactSales.UnitCost` (row 14 above). Loaded by script `08_StgProductCost.sql` before the facts.

| # | Target column | Target type | Source table | Source column | Mapping type | Transformation / rule |
|---|---|---|---|---|---|---|
| 1 | `stg.ProductCostRange.ProductID` | INT, PK (part) | `Production.ProductCostHistory` | `ProductID` | Direct | |
| 2 | `stg.ProductCostRange.StartDate` | DATE, PK (part) | `Production.ProductCostHistory` | `StartDate` | Derived | Cast to `DATE`. **Not offset** (compared with source `OrderDate`) |
| 3 | `stg.ProductCostRange.EndDate` | DATE | `Production.ProductCostHistory` | `EndDate` | Derived | Cast to `DATE`; NULL becomes `9999-12-31` (current cost row) |
| 4 | `stg.ProductCostRange.StandardCost` | DECIMAL(19,4) | `Production.ProductCostHistory` | `StandardCost` | Direct | |

Fallback cost: `dw.DimProduct.CurrentStandardCost` is loaded from `Production.Product.StandardCost`.

---

## 5. Dimension lookup reference

Which dimension supplies each surrogate key, and which columns are matched.

| Fact column | Dimension table | Dimension natural key | Dimension surrogate key returned | Fact source column matched | Join type |
|---|---|---|---|---|---|
| `OrderDateKey` (all facts: quota uses `QuotaDateKey`) | `dw.DimDate` | `FullDate` | `DateKey` | Offset date from source | Inner (order, quota); left (ship, due) |
| `ProductKey` | `dw.DimProduct` | `ProductID` | `ProductKey` | `SalesOrderDetail.ProductID` | Left, `-1` if none |
| `CustomerKey` | `dw.DimCustomer` | `CustomerID` | `CustomerKey` | `SalesOrderHeader.CustomerID` | Left, `-1` if none |
| `TerritoryKey` | `dw.DimTerritory` | `TerritoryID` | `TerritoryKey` | `SalesOrderHeader.TerritoryID` | Left, `-1` if none |
| `SalesPersonKey` | `dw.DimSalesPerson` | `SalesPersonID` | `SalesPersonKey` | `SalesOrderHeader.SalesPersonID` (facts), `SalesPersonQuotaHistory.BusinessEntityID` (quota) | Left, `-1` if none (facts); inner (quota) |
| `PromotionKey` | `dw.DimPromotion` | `SpecialOfferID` | `PromotionKey` | `SalesOrderDetail.SpecialOfferID` | Left, `-1` if none |

---

## 6. Source columns intentionally not loaded

Documented so that omissions are visible decisions, not oversights.

| Source table | Columns not loaded | Reason |
|---|---|---|
| `Sales.SalesOrderDetail` | `CarrierTrackingNumber`, `rowguid`, `ModifiedDate` | No analytical use in this project |
| `Sales.SalesOrderHeader` | `RevisionNumber`, `Status`, `PurchaseOrderNumber`, `AccountNumber`, `BillToAddressID`, `ShipToAddressID`, `CreditCardID`, `CreditCardApprovalCode`, `CurrencyRateID`, `Comment`, `rowguid`, `ModifiedDate` | Out of scope for v1 (address, payment, and currency analysis); no status filter is applied, so all orders are loaded |
| `Sales.SalesPersonQuotaHistory` | `rowguid`, `ModifiedDate` | Technical columns |

> [!NOTE]
> Candidates to add later: `BillToAddressID` / `ShipToAddressID` for a geography dimension, and `CurrencyRateID` for multi-currency reporting.
