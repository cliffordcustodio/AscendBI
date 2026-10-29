/* ============================================================
   01_CreateWarehouse.sql
   Purpose : Create the RevenueDW database, schemas, and log tables.
   Naming  : PascalCase everywhere.
   Safe to re-run (idempotent).
   ============================================================ */
USE master;
GO
IF DB_ID('RevenueDW') IS NULL
    CREATE DATABASE RevenueDW;
GO

USE RevenueDW;
GO

-- Schemas: stg = staging, dw = dimensions and facts, ds = data science outputs
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('ds')  IS NULL EXEC('CREATE SCHEMA ds');
GO

-- Remove the earlier snake_case version (safe if absent)
IF OBJECT_ID('dw.etl_run_log') IS NOT NULL DROP TABLE dw.etl_run_log;
IF OBJECT_ID('dw.data_quality_log') IS NOT NULL DROP TABLE dw.data_quality_log;
GO

-- ETL run log: one row per procedure execution
IF OBJECT_ID('dw.EtlRunLog') IS NULL
CREATE TABLE dw.EtlRunLog (
    RunID         INT IDENTITY(1,1) PRIMARY KEY,
    ProcedureName SYSNAME        NOT NULL,
    StartTime     DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    EndTime       DATETIME2(0)   NULL,
    RowsLoaded    INT            NULL,
    Status         VARCHAR(20)    NOT NULL DEFAULT 'Running',   -- Running / Succeeded / Failed
    ErrorMessage  NVARCHAR(4000) NULL
);
GO

-- Data quality results: one row per check per run
IF OBJECT_ID('dw.DataQualityLog') IS NULL
CREATE TABLE dw.DataQualityLog (
    CheckID   INT IDENTITY(1,1) PRIMARY KEY,
    CheckName VARCHAR(100)  NOT NULL,
    Severity   VARCHAR(10)   NOT NULL,   -- Critical / Warning
    Passed     BIT           NOT NULL,
    Detail     NVARCHAR(500) NULL,
    CheckedAt DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO
