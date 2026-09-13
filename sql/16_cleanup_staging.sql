USE DanangSmartParkingSTG;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CleanupStagingBatch
    @LoadBatchKey bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 50001, 'LoadBatchKey must be a positive value.', 1;

    BEGIN TRANSACTION;

    DELETE FROM transform.ParkingDailySummary       WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.TrafficHourlySummary      WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.WeatherHourlyClean        WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.ParkingEventClean         WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.TrafficObservationClean   WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.RoadSurveyClean           WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.POIClean                   WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.ParkingRestrictionClean   WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.ParkingFacilityClean      WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM transform.RoadClean                  WHERE LoadBatchKey = @LoadBatchKey;

    DELETE FROM extract.WeatherEventRaw              WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.ParkingEventRaw              WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.TrafficEventRaw              WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.RoadSurveyRaw                WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.POIRaw                       WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.ParkingRestrictionRaw        WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.ParkingLocationRaw           WHERE LoadBatchKey = @LoadBatchKey;
    DELETE FROM extract.RoadRaw                      WHERE LoadBatchKey = @LoadBatchKey;

    COMMIT TRANSACTION;
END;
GO

/*
Execute only after DW reconciliation succeeds:
EXEC DanangSmartParkingSTG.dbo.usp_CleanupStagingBatch @LoadBatchKey = ?;
*/

