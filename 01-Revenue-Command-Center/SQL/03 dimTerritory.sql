/* ----------------------------------------------------------
03_dim_date.sql
Purpose : Build territory dimension
Param : 
IMPORTANT : use the same offset when loading the FactSales.
This query is safe to re-run
-------------------------------------------------------------- */

USE RevenueDW;
GO

IF OBJECT_ID('dw.DimTerritory') IS NULL
CREATE TABLE dw.DimTerritory (
	TerritoryKey		INT				NOT NULL PRIMARY KEY IDENTITY,	-- surrogate key; -1 = unknow
	TerritoryID			INT				UNIQUE,
	TerritoryName		NVARCHAR(20)	NOT NULL,
	CountryRegionCode	CHAR(2)			NOT NULL,
	CountryName			NVARCHAR(20)	NOT NULL,
	TerritoryGroup		NVARCHAR(20)	NOT NULL
);

--- Insert Unknown
SET IDENTITY_INSERT dw.DimTerritory ON;
INSERT INTO dw.DimTerritory (TerritoryKey, TerritoryID, TerritoryName, CountryRegionCode, CountryName, TerritoryGroup)
VALUES (-1,-1,'Unknown','NA','Unknown','Unknown');
SET IDENTITY_INSERT dw.DimTerritory OFF;

--- Insert Sales Territory
INSERT INTO dw.DimTerritory 
	(
		--TerritoryKey, 
		TerritoryID, 
		TerritoryName, 
		CountryRegionCode, 
		CountryName, 
		TerritoryGroup
	)
SELECT
		[TerritoryID],
		st.[Name] TerritoryName,
		st.[CountryRegionCode],
		st.[Name] CountryName,
		st.[Group] TerritoryGroup
FROM [AdventureWorks2022].[Sales].[SalesTerritory] st
JOIN [AdventureWorks2022].Person.CountryRegion cr on cr.CountryRegionCode = st.CountryRegionCode

------------ Validation
-- 01. The record count in this table should be 11 including the -1 Unknown data
SELECT count(*) FROM dw.DimTerritory;

-- 02. Compare the source data count is the same with the dimenstion table
SELECT
	(SELECT count(*) FROM dw.DimTerritory where TerritoryKey <> -1)  dimTerritory ,
	(SELECT count(*) from  [AdventureWorks2022].[Sales].[SalesTerritory]) SalesTerritory;


-- 03. Check if there are territory record having name of Unknown that do not have -1 territory key
SELECT * FROM dw.DimTerritory WHERE TerritoryName = 'Unknown' and TerritoryID <> -1;

-- 04.  Check the counts by Territory Group
SELECT TerritoryGroup, COUNT(*), Count(1) FROM dw.DimTerritory GROUP BY TerritoryGroup
