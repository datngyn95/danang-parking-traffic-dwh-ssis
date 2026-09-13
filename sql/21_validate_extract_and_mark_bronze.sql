/*
    Da Nang Smart Parking
    Validate the complete Extract phase and mark the batch BRONZE_LOADED.

    Prerequisite:
      - DanangSmartParkingSTG.dbo.usp_ValidateStagingBatch exists
        (created by sql/17_validate_staging.sql).
      - All packages 10, 11 and 12 completed for the same STARTED batch.
*/

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateExtractAndMarkBronze
    @LoadBatchKey bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 51500, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 51501, 'LoadBatchKey does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'STARTED'
    )
        THROW 51502, 'Extract validation requires a STARTED batch.', 1;

    BEGIN TRY
        DECLARE @ExpectedFiles TABLE
        (
            SourceID char(2) NOT NULL PRIMARY KEY,
            FileName nvarchar(260) NOT NULL,
            ExpectedRows bigint NOT NULL
        );

        INSERT @ExpectedFiles (SourceID, FileName, ExpectedRows)
        VALUES
            ('01', N'01_roads.geojson', 30),
            ('02', N'02_parking_locations.csv', 20),
            ('03', N'03_parking_restrictions.csv', 18),
            ('04', N'04_poi.geojson', 50),
            ('05', N'05_road_survey.csv', 30),
            ('06', N'06_traffic_events.jsonl', 16884),
            ('07', N'07_parking_events.jsonl', 4300),
            ('08', N'08_weather_events.jsonl', 168);

        /* The batch must contain exactly the eight expected files. */
        IF
        (
            SELECT COUNT_BIG(*)
            FROM etl.LoadFile
            WHERE LoadBatchKey = @LoadBatchKey
        ) <> 8
            THROW 51503, 'The batch does not contain exactly eight LoadFile rows.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM @ExpectedFiles AS Expected
            LEFT JOIN etl.LoadFile AS Actual
              ON Actual.LoadBatchKey = @LoadBatchKey
             AND Actual.SourceID = Expected.SourceID
             AND Actual.FileName = Expected.FileName
            WHERE Actual.LoadFileKey IS NULL
               OR Actual.FileFormat <> CASE
                    WHEN RIGHT(Expected.FileName, 4) = N'.csv' THEN 'CSV'
                    WHEN RIGHT(Expected.FileName, 8) = N'.geojson' THEN 'GEOJSON'
                    ELSE 'JSONL'
                  END
               OR Actual.ExpectedRowCount <> Expected.ExpectedRows
               OR Actual.ActualRowCount <> Expected.ExpectedRows
               OR Actual.AcceptedRowCount <> Expected.ExpectedRows
               OR ISNULL(Actual.RejectedRowCount, -1) <> 0
               OR Actual.LoadStatus <> 'COMPLETED'
        )
            THROW 51504, 'One or more LoadFile audit rows are missing, failed or different from the baseline.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM etl.LoadFile AS Actual
            LEFT JOIN @ExpectedFiles AS Expected
              ON Expected.SourceID = Actual.SourceID
             AND Expected.FileName = Actual.FileName
            WHERE Actual.LoadBatchKey = @LoadBatchKey
              AND Expected.SourceID IS NULL
        )
            THROW 51505, 'The batch contains an unexpected source file.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM etl.RejectedRow AS Rejected
            JOIN etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
        )
            THROW 51506, 'The batch contains one or more rejected rows.', 1;

        /* Existing staging procedure validates all eight table row counts. */
        EXEC DanangSmartParkingSTG.dbo.usp_ValidateStagingBatch
            @LoadBatchKey = @LoadBatchKey,
            @Phase = 'EXTRACT',
            @ReturnDetail = 0;

        /* Verify physical source-row boundaries for every format. */
        DECLARE @Sequences TABLE
        (
            ObjectName sysname NOT NULL,
            ActualRows bigint NOT NULL,
            DistinctRows bigint NOT NULL,
            MinRow bigint NULL,
            MaxRow bigint NULL,
            ExpectedRows bigint NOT NULL,
            ExpectedMinRow bigint NOT NULL,
            ExpectedMaxRow bigint NOT NULL
        );

        INSERT @Sequences
        (
            ObjectName,
            ActualRows,
            DistinctRows,
            MinRow,
            MaxRow,
            ExpectedRows,
            ExpectedMinRow,
            ExpectedMaxRow
        )
        SELECT 'extract.RoadRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 30, 1, 30
        FROM DanangSmartParkingSTG.extract.RoadRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.ParkingLocationRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 20, 2, 21
        FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.ParkingRestrictionRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 18, 2, 19
        FROM DanangSmartParkingSTG.extract.ParkingRestrictionRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.POIRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 50, 1, 50
        FROM DanangSmartParkingSTG.extract.POIRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.RoadSurveyRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 30, 2, 31
        FROM DanangSmartParkingSTG.extract.RoadSurveyRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.TrafficEventRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 16884, 1, 16884
        FROM DanangSmartParkingSTG.extract.TrafficEventRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.ParkingEventRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 4300, 1, 4300
        FROM DanangSmartParkingSTG.extract.ParkingEventRaw
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL
        SELECT 'extract.WeatherEventRaw', COUNT_BIG(*), COUNT(DISTINCT SourceRowNumber),
               MIN(SourceRowNumber), MAX(SourceRowNumber), 168, 1, 168
        FROM DanangSmartParkingSTG.extract.WeatherEventRaw
        WHERE LoadBatchKey = @LoadBatchKey;

        IF EXISTS
        (
            SELECT 1
            FROM @Sequences
            WHERE ActualRows <> ExpectedRows
               OR DistinctRows <> ExpectedRows
               OR MinRow <> ExpectedMinRow
               OR MaxRow <> ExpectedMaxRow
        )
            THROW 51507, 'One or more extract tables have an invalid SourceRowNumber sequence.', 1;

        /* JSONL RawJson must remain valid JSON for all 21,352 rows. */
        IF EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingSTG.extract.TrafficEventRaw
            WHERE LoadBatchKey = @LoadBatchKey
              AND ISNULL(ISJSON(RawJson), 0) <> 1
        )
            THROW 51508, 'TrafficEventRaw contains invalid RawJson.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingSTG.extract.ParkingEventRaw
            WHERE LoadBatchKey = @LoadBatchKey
              AND ISNULL(ISJSON(RawJson), 0) <> 1
        )
            THROW 51509, 'ParkingEventRaw contains invalid RawJson.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingSTG.extract.WeatherEventRaw
            WHERE LoadBatchKey = @LoadBatchKey
              AND ISNULL(ISJSON(RawJson), 0) <> 1
        )
            THROW 51510, 'WeatherEventRaw contains invalid RawJson.', 1;

        /* Known UTF-8 values protect the pipeline against mojibake. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingSTG.extract.RoadRaw
            WHERE LoadBatchKey = @LoadBatchKey
              AND SourceRowNumber = 1
              AND RoadName = N'Trần Phú'
              AND AnalysisZone = N'Hải Châu core'
        )
            THROW 51511, 'RoadRaw UTF-8 checkpoint failed.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingSTG.extract.TrafficEventRaw
            WHERE LoadBatchKey = @LoadBatchKey
              AND SourceRowNumber = 1
              AND RoadName = N'Lê Duẩn'
              AND AnalysisZone = N'Hải Châu core'
        )
            THROW 51512, 'TrafficEventRaw UTF-8 checkpoint failed.', 1;

        DECLARE @RowsRead bigint;
        DECLARE @RowsAccepted bigint;
        DECLARE @RowsRejected bigint;

        SELECT
            @RowsRead = COALESCE(SUM(ActualRowCount), 0),
            @RowsAccepted = COALESCE(SUM(AcceptedRowCount), 0),
            @RowsRejected = COALESCE(SUM(RejectedRowCount), 0)
        FROM etl.LoadFile
        WHERE LoadBatchKey = @LoadBatchKey;

        IF @RowsRead <> 21500
           OR @RowsAccepted <> 21500
           OR @RowsRejected <> 0
            THROW 51513, 'Batch audit totals must be 21500 read, 21500 accepted and 0 rejected.', 1;

        UPDATE etl.LoadBatch
        SET LoadStatus = 'BRONZE_LOADED',
            RowsRead = @RowsRead,
            RowsAccepted = @RowsAccepted,
            RowsRejected = @RowsRejected,
            ErrorMessage = NULL
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'STARTED';

        IF @@ROWCOUNT <> 1
            THROW 51514, 'The batch status could not be changed to BRONZE_LOADED.', 1;
    END TRY
    BEGIN CATCH
        UPDATE etl.LoadBatch
        SET LoadStatus = 'FAILED',
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'STARTED';

        THROW;
    END CATCH;
END;
GO
