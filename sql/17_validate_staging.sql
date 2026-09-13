USE DanangSmartParkingSTG;
GO

/*
    Creates the validation gate used by SSIS and manual debugging.
    The procedure returns every check and throws when any count differs.
*/
CREATE OR ALTER PROCEDURE dbo.usp_ValidateStagingBatch
    @LoadBatchKey bigint,
    @Phase varchar(10),
    @ReturnDetail bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 50011, 'LoadBatchKey must be a positive value.', 1;

    SET @Phase = UPPER(LTRIM(RTRIM(@Phase)));
    IF @Phase IS NULL OR @Phase NOT IN ('EXTRACT', 'TRANSFORM', 'ALL')
        THROW 50012, 'Phase must be EXTRACT, TRANSFORM or ALL.', 1;

    DECLARE @Checks TABLE
    (
        PhaseName varchar(10) NOT NULL,
        ObjectName sysname NOT NULL,
        ActualRows bigint NOT NULL,
        ExpectedRows bigint NOT NULL
    );

    IF @Phase IN ('EXTRACT', 'ALL')
    BEGIN
        INSERT @Checks (PhaseName, ObjectName, ActualRows, ExpectedRows)
        SELECT 'EXTRACT', 'extract.RoadRaw', COUNT_BIG(*), 30
        FROM extract.RoadRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.ParkingLocationRaw', COUNT_BIG(*), 20
        FROM extract.ParkingLocationRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.ParkingRestrictionRaw', COUNT_BIG(*), 18
        FROM extract.ParkingRestrictionRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.POIRaw', COUNT_BIG(*), 50
        FROM extract.POIRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.RoadSurveyRaw', COUNT_BIG(*), 30
        FROM extract.RoadSurveyRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.TrafficEventRaw', COUNT_BIG(*), 16884
        FROM extract.TrafficEventRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.ParkingEventRaw', COUNT_BIG(*), 4300
        FROM extract.ParkingEventRaw WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'EXTRACT', 'extract.WeatherEventRaw', COUNT_BIG(*), 168
        FROM extract.WeatherEventRaw WHERE LoadBatchKey = @LoadBatchKey;
    END;

    IF @Phase IN ('TRANSFORM', 'ALL')
    BEGIN
        INSERT @Checks (PhaseName, ObjectName, ActualRows, ExpectedRows)
        SELECT 'TRANSFORM', 'transform.RoadClean', COUNT_BIG(*), 30
        FROM transform.RoadClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.ParkingFacilityClean', COUNT_BIG(*), 20
        FROM transform.ParkingFacilityClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.ParkingRestrictionClean', COUNT_BIG(*), 18
        FROM transform.ParkingRestrictionClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.POIClean', COUNT_BIG(*), 50
        FROM transform.POIClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.RoadSurveyClean', COUNT_BIG(*), 30
        FROM transform.RoadSurveyClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.TrafficObservationClean', COUNT_BIG(*), 16800
        FROM transform.TrafficObservationClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.ParkingEventClean', COUNT_BIG(*), 4283
        FROM transform.ParkingEventClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.WeatherHourlyClean', COUNT_BIG(*), 168
        FROM transform.WeatherHourlyClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
        UNION ALL SELECT 'TRANSFORM', 'transform.TrafficHourlySummary', COUNT_BIG(*), 4200
        FROM transform.TrafficHourlySummary
        WHERE LoadBatchKey = @LoadBatchKey
        UNION ALL SELECT 'TRANSFORM', 'transform.ParkingDailySummary', COUNT_BIG(*), 513
        FROM transform.ParkingDailySummary
        WHERE LoadBatchKey = @LoadBatchKey;
    END;

    IF @ReturnDetail = 1
    BEGIN
        SELECT
            PhaseName,
            ObjectName,
            ActualRows,
            ExpectedRows,
            CONVERT(bit, CASE WHEN ActualRows = ExpectedRows THEN 1 ELSE 0 END) AS IsMatched
        FROM @Checks
        ORDER BY PhaseName, ObjectName;
    END;

    IF EXISTS (SELECT 1 FROM @Checks WHERE ActualRows <> ExpectedRows)
        THROW 50013, 'Staging validation failed: one or more row counts differ.', 1;
END;
GO

/* Manual debug examples. Replace 1 with the required LoadBatchKey. */
-- EXEC dbo.usp_ValidateStagingBatch @LoadBatchKey = 1, @Phase = 'EXTRACT';
-- EXEC dbo.usp_ValidateStagingBatch @LoadBatchKey = 1, @Phase = 'TRANSFORM';
-- EXEC dbo.usp_ValidateStagingBatch @LoadBatchKey = 1, @Phase = 'ALL';
