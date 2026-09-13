/*
    Read-only acceptance for package 30 - Load Dimensions.
    Keep @RequestedLoadBatchKey NULL to validate the newest SILVER_VALIDATED batch,
    or replace NULL with a numeric batch key such as 18.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;

DECLARE @RequestedLoadBatchKey bigint = NULL;

DECLARE @LoadBatchKey bigint = COALESCE
(
    @RequestedLoadBatchKey,
    (
        SELECT TOP (1) LoadBatchKey
        FROM etl.LoadBatch
        WHERE LoadStatus = 'SILVER_VALIDATED'
        ORDER BY LoadBatchKey DESC
    )
);

IF @LoadBatchKey IS NULL
    THROW 52700, 'No SILVER_VALIDATED batch was found.', 1;

IF OBJECT_ID(N'etl.usp_ValidateDimensionLoad', N'P') IS NULL
    THROW 52701, 'Validation procedure is missing. Run sql/26_prepare_dimension_data_flow.sql first.', 1;

EXEC etl.usp_ValidateDimensionLoad
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;
GO
