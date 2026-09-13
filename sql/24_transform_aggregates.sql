/*
    Da Nang Smart Parking
    Package 22 - Build QA aggregates from the package-21 Clean event tables.

    Input status : BRONZE_LOADED
    Output       : transform.TrafficHourlySummary (4,200 rows)
                   transform.ParkingDailySummary (513 rows)

    These aggregates support QA/reconciliation only. They do not replace the
    atomic-grain Fact tables loaded later by Data Flow Task.
*/

USE DanangSmartParkingSTG;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TransformAggregates
    @LoadBatchKey bigint,
    @ReturnDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 52000, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 52001, 'LoadBatchKey does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'BRONZE_LOADED'
    )
        THROW 52002, 'Aggregate transform requires a BRONZE_LOADED batch.', 1;

    BEGIN TRY
        /* Package 21 must be complete for this same batch. */
        IF (SELECT COUNT_BIG(*)
            FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND IsValid = 1
              AND DuplicateRank = 1) <> 16800
           OR (SELECT COUNT_BIG(*)
               FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey
                 AND IsValid = 1
                 AND DuplicateRank = 1) <> 4283
           OR (SELECT COUNT_BIG(*)
               FROM transform.WeatherHourlyClean
               WHERE LoadBatchKey = @LoadBatchKey
                 AND IsValid = 1) <> 168
            THROW 52003, 'Package 21 Clean event output is missing or invalid.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND (IsValid = 0 OR DuplicateRank <> 1)
        )
           OR EXISTS
        (
            SELECT 1
            FROM transform.ParkingEventClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND (IsValid = 0 OR DuplicateRank <> 1)
        )
           OR EXISTS
        (
            SELECT 1
            FROM transform.WeatherHourlyClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND IsValid = 0
        )
            THROW 52004, 'Package 21 contains invalid or non-retained Clean rows.', 1;

        BEGIN TRANSACTION;

        /* Idempotent rerun: replace only this batch's aggregate rows. */
        DELETE FROM transform.ParkingDailySummary
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.TrafficHourlySummary
        WHERE LoadBatchKey = @LoadBatchKey;

        /* Grain: one date x hour x road. */
        INSERT transform.TrafficHourlySummary
        (
            LoadBatchKey,
            EventDate,
            HourNumber,
            RoadID,
            VehicleVolume,
            AvgSpeedKmh,
            AvgCongestionIndex,
            IllegalParkingObserved
        )
        SELECT
            LoadBatchKey,
            EventDate,
            HourNumber,
            RoadID,
            SUM(CONVERT(bigint, VehicleCount)) AS VehicleVolume,
            CONVERT
            (
                decimal(12,4),
                AVG(CONVERT(decimal(18,6), AvgSpeedKmh))
            ) AS AvgSpeedKmh,
            CONVERT
            (
                decimal(12,6),
                AVG(CONVERT(decimal(18,6), CongestionIndex))
            ) AS AvgCongestionIndex,
            SUM(CONVERT(bigint, IllegalParkingCount)) AS IllegalParkingObserved
        FROM transform.TrafficObservationClean
        WHERE LoadBatchKey = @LoadBatchKey
          AND IsValid = 1
          AND DuplicateRank = 1
        GROUP BY
            LoadBatchKey,
            EventDate,
            HourNumber,
            RoadID;

        /* Grain: one date x road x vehicle type. */
        INSERT transform.ParkingDailySummary
        (
            LoadBatchKey,
            EventDate,
            RoadID,
            VehicleTypeCode,
            ParkingEventCount,
            IllegalEventCount,
            AvgDurationMin,
            OpenEventCount
        )
        SELECT
            LoadBatchKey,
            EventDate,
            RoadID,
            VehicleTypeCode,
            COUNT_BIG(*) AS ParkingEventCount,
            SUM
            (
                CASE WHEN IsLegalParking = 0
                     THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END
            ) AS IllegalEventCount,
            CONVERT
            (
                decimal(12,4),
                AVG(CONVERT(decimal(18,6), ParkingDurationMin))
            ) AS AvgDurationMin,
            SUM(CONVERT(bigint, IsOpenEvent)) AS OpenEventCount
        FROM transform.ParkingEventClean
        WHERE LoadBatchKey = @LoadBatchKey
          AND IsValid = 1
          AND DuplicateRank = 1
        GROUP BY
            LoadBatchKey,
            EventDate,
            RoadID,
            VehicleTypeCode;

        IF (SELECT COUNT_BIG(*)
            FROM transform.TrafficHourlySummary
            WHERE LoadBatchKey = @LoadBatchKey) <> 4200
            THROW 52005, 'TrafficHourlySummary row count is not 4,200.', 1;

        IF (SELECT COUNT_BIG(*)
            FROM transform.ParkingDailySummary
            WHERE LoadBatchKey = @LoadBatchKey) <> 513
            THROW 52006, 'ParkingDailySummary row count is not 513.', 1;

        /* Additive reconciliation back to the atomic Clean rows. */
        IF (SELECT SUM(VehicleVolume)
            FROM transform.TrafficHourlySummary
            WHERE LoadBatchKey = @LoadBatchKey) <> 6596879
           OR (SELECT SUM(IllegalParkingObserved)
               FROM transform.TrafficHourlySummary
               WHERE LoadBatchKey = @LoadBatchKey) <> 9100
            THROW 52007, 'Traffic aggregate additive reconciliation failed.', 1;

        IF (SELECT SUM(ParkingEventCount)
            FROM transform.ParkingDailySummary
            WHERE LoadBatchKey = @LoadBatchKey) <> 4283
           OR (SELECT SUM(IllegalEventCount)
               FROM transform.ParkingDailySummary
               WHERE LoadBatchKey = @LoadBatchKey) <> 1571
           OR (SELECT SUM(OpenEventCount)
               FROM transform.ParkingDailySummary
               WHERE LoadBatchKey = @LoadBatchKey) <> 64
            THROW 52008, 'Parking aggregate additive reconciliation failed.', 1;

        COMMIT TRANSACTION;

        IF @ReturnDetail = 1
        BEGIN
            SELECT
                'transform.TrafficHourlySummary' AS ObjectName,
                COUNT_BIG(*) AS ActualRows,
                CONVERT(bigint, 4200) AS ExpectedRows,
                CONVERT(bit, CASE WHEN COUNT_BIG(*) = 4200 THEN 1 ELSE 0 END)
                    AS IsMatched
            FROM transform.TrafficHourlySummary
            WHERE LoadBatchKey = @LoadBatchKey
            UNION ALL
            SELECT
                'transform.ParkingDailySummary',
                COUNT_BIG(*),
                CONVERT(bigint, 513),
                CONVERT(bit, CASE WHEN COUNT_BIG(*) = 513 THEN 1 ELSE 0 END)
            FROM transform.ParkingDailySummary
            WHERE LoadBatchKey = @LoadBatchKey;

            SELECT
                COUNT_BIG(*) AS TrafficSummaryRows,
                SUM(VehicleVolume) AS VehicleVolume,
                SUM(IllegalParkingObserved) AS IllegalParkingObserved,
                COUNT(DISTINCT EventDate) AS DateCount,
                COUNT(DISTINCT HourNumber) AS HourCount,
                COUNT(DISTINCT RoadID) AS RoadCount
            FROM transform.TrafficHourlySummary
            WHERE LoadBatchKey = @LoadBatchKey;

            SELECT
                COUNT_BIG(*) AS ParkingSummaryRows,
                SUM(ParkingEventCount) AS ParkingEventCount,
                SUM(IllegalEventCount) AS IllegalEventCount,
                SUM(OpenEventCount) AS OpenEventCount,
                COUNT(DISTINCT EventDate) AS DateCount,
                COUNT(DISTINCT RoadID) AS RoadCount,
                COUNT(DISTINCT VehicleTypeCode) AS VehicleTypeCount
            FROM transform.ParkingDailySummary
            WHERE LoadBatchKey = @LoadBatchKey;

            /* Visible Unicode checkpoint through the conformed Road master. */
            SELECT TOP (1)
                SummaryRow.RoadID,
                Road.RoadName,
                Road.AnalysisZone,
                CONVERT
                (
                    bit,
                    CASE WHEN Road.RoadName = N'Trần Phú'
                                   AND Road.AnalysisZone = N'Hải Châu core'
                         THEN 1 ELSE 0 END
                ) AS UnicodeMatched,
                N'Trần Phú / Hải Châu core' AS ExpectedUnicodeValue
            FROM transform.TrafficHourlySummary AS SummaryRow
            JOIN transform.RoadClean AS Road
              ON Road.LoadBatchKey = SummaryRow.LoadBatchKey
             AND Road.RoadID = SummaryRow.RoadID
             AND Road.IsValid = 1
            WHERE SummaryRow.LoadBatchKey = @LoadBatchKey
              AND SummaryRow.RoadID = 'RD001'
            ORDER BY SummaryRow.EventDate, SummaryRow.HourNumber;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        UPDATE DanangSmartParkingDW.etl.LoadBatch
        SET LoadStatus = 'FAILED',
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'BRONZE_LOADED';

        THROW;
    END CATCH;
END;
GO

