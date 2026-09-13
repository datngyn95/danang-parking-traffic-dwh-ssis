/*
    Read-only acceptance for package 50 - Final DWH Validation.
    Keep @RequestedLoadBatchKey NULL to use the newest SILVER_VALIDATED batch,
    or replace NULL with a numeric batch key such as 18.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;

DECLARE @RequestedLoadBatchKey bigint = NULL;

IF OBJECT_ID(N'etl.usp_ValidateFinalDWH', N'P') IS NULL
    THROW 52950, 'Validation procedure is missing. Run sql/28_prepare_final_dwh_validation.sql first.', 1;

EXEC etl.usp_ValidateFinalDWH
    @LoadBatchKey = @RequestedLoadBatchKey;
GO
