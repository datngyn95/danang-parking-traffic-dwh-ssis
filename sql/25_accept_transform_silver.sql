/*
    Da Nang Smart Parking
    Read-only acceptance test after package 23.

    It validates the newest batch again and returns PASS only when the batch is
    SILVER_VALIDATED. It never changes persistent data.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;

/*
    Optional manual override:
      - keep NULL to validate the newest batch;
      - replace NULL with a numeric batch key, for example 16.
*/
DECLARE @RequestedLoadBatchKey bigint = NULL;

DECLARE @LoadBatchKey bigint = COALESCE
(
    @RequestedLoadBatchKey,
    (
        SELECT TOP (1) LoadBatchKey
        FROM etl.LoadBatch
        ORDER BY LoadBatchKey DESC
    )
);

IF @LoadBatchKey IS NULL
    THROW 52400, 'No LoadBatch row was found.', 1;

/* Re-run every Transform check without changing data or status. */
EXEC DanangSmartParkingSTG.dbo.usp_ValidateTransformBatch
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;

IF NOT EXISTS
(
    SELECT 1
    FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus = 'SILVER_VALIDATED'
      AND RowsRead = 21500
      AND RowsAccepted = 21500
      AND RowsRejected = 0
      AND ErrorMessage IS NULL
      AND CompletedAt IS NULL
)
    THROW 52401, 'PACKAGE 23 FAILED: batch status/audit is not SILVER_VALIDATED.', 1;

SELECT
    'PASS' AS AcceptanceStatus,
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    CompletedAt,
    'PACKAGE 23 ACCEPTED - ready for package 30 dimensions' AS Message
FROM etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;
GO
