/* ============================================================
   01b_EtlConfig.sql
   Purpose : One place for settings every load script reads.
   Run     : After 01, BEFORE 02.
   DateOffsetYears: years added to every source date.
        0  = original dates (2011-2014)
        12 = demo mode (data appears to end around 2026)
   If you change it after loading, re-run: 02, 07, 09, 10, 11.
   ============================================================ */
USE RevenueDW;
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.etl_config') IS NOT NULL DROP TABLE dw.etl_config;
GO

IF OBJECT_ID('dw.EtlConfig') IS NULL
CREATE TABLE dw.EtlConfig (
    ConfigKey   VARCHAR(50)   NOT NULL PRIMARY KEY,
    ConfigValue VARCHAR(100)  NOT NULL,
    Description  NVARCHAR(200) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM dw.EtlConfig WHERE ConfigKey = 'DateOffsetYears')
    INSERT INTO dw.EtlConfig (ConfigKey, ConfigValue, Description)
    VALUES ('DateOffsetYears', '0', N'Years added to every source date (0 = original dates)');
GO

SELECT * FROM dw.EtlConfig;
