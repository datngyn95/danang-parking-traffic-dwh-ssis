/*
    Reload only GeoJSON files 01 and 04 for the newest GeoJSON batch.

    Use this once when the old SINGLE_CLOB version produced mojibake such as:
      Tráº§n PhÃº
      Háº£i ChÃ¢u

    Run sql/18_extract_geojson_execute_sql.sql first so the procedure uses
    SINGLE_BLOB + UTF8 collation decoding.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RawRoot nvarchar(4000) =
    N'C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d';

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM etl.LoadFile
    WHERE FileName = N'04_poi.geojson'
    ORDER BY LoadFileKey DESC
);

IF @LoadBatchKey IS NULL
    THROW 51300, 'No GeoJSON batch was found.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus IN ('STARTED', 'FAILED')
)
    THROW 51301, 'The newest GeoJSON batch is not STARTED/FAILED. Reload was stopped.', 1;

DECLARE @GeoFileKeys TABLE
(
    LoadFileKey bigint NOT NULL PRIMARY KEY
);

INSERT @GeoFileKeys (LoadFileKey)
SELECT LoadFileKey
FROM etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
  AND
  (
      (SourceID = '01' AND FileName = N'01_roads.geojson')
      OR
      (SourceID = '04' AND FileName = N'04_poi.geojson')
  );

IF (SELECT COUNT_BIG(*) FROM @GeoFileKeys) <> 2
    THROW 51302, 'Expected exactly two GeoJSON LoadFile rows in the newest batch.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    /* Delete only RAW rows that came from files 01 and 04 of this batch. */
    DELETE FROM DanangSmartParkingSTG.extract.RoadRaw
    WHERE LoadBatchKey = @LoadBatchKey;

    DELETE FROM DanangSmartParkingSTG.extract.POIRaw
    WHERE LoadBatchKey = @LoadBatchKey;

    /* Optional audit/archive children must be removed before LoadFile. */
    DELETE Rejected
    FROM etl.RejectedRow AS Rejected
    JOIN @GeoFileKeys AS FileKey
      ON FileKey.LoadFileKey = Rejected.LoadFileKey;

    DELETE RawRecord
    FROM bronze.RawRecord AS RawRecord
    JOIN @GeoFileKeys AS FileKey
      ON FileKey.LoadFileKey = RawRecord.LoadFileKey;

    DELETE LoadFile
    FROM etl.LoadFile AS LoadFile
    JOIN @GeoFileKeys AS FileKey
      ON FileKey.LoadFileKey = LoadFile.LoadFileKey;

    UPDATE etl.LoadBatch
    SET LoadStatus = 'STARTED',
        CompletedAt = NULL,
        ErrorMessage = NULL
    WHERE LoadBatchKey = @LoadBatchKey;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

/* Reload with the corrected UTF-8 procedure. */
EXEC etl.usp_ExtractGeoJSONToStaging
    @LoadBatchKey = @LoadBatchKey,
    @RawRoot = @RawRoot;

/* Reconciliation. */
SELECT
    LoadBatchKey,
    SourceID,
    FileName,
    ExpectedRowCount,
    ActualRowCount,
    AcceptedRowCount,
    RejectedRowCount,
    LoadStatus
FROM etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceID;

SELECT TOP (10)
    SourceRowNumber,
    RoadID,
    RoadName,
    AnalysisZone
FROM DanangSmartParkingSTG.extract.RoadRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;

SELECT TOP (10)
    SourceRowNumber,
    POIID,
    POIName,
    CategoryCode
FROM DanangSmartParkingSTG.extract.POIRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
