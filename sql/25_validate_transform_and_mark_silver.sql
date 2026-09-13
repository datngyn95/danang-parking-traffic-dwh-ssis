/*
    Da Nang Smart Parking
    Package 23 - Validate the complete Transform layer and close the Silver gate.

    This script creates two procedures:

      1. DanangSmartParkingSTG.dbo.usp_ValidateTransformBatch
         Read-only validation. It never changes persistent data.

      2. DanangSmartParkingDW.etl.usp_ValidateTransformAndMarkSilver
         Calls the read-only validator and changes only LoadBatch.LoadStatus:
             BRONZE_LOADED -> SILVER_VALIDATED

    The known data-quality flags are warnings, not rejected rows:
      - 161 traffic rows have missing speed;
      - 3,838 traffic rows have an inconsistent vehicle mix;
      - 781 traffic rows have an inconsistent parking count;
      - 64 parking events are open and use an estimated/last-known duration;
      - 607 illegal parking events have no source restriction link.
*/

USE DanangSmartParkingSTG;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidateTransformBatch
    @LoadBatchKey bigint,
    @ReturnDetail bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 52200, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 52201, 'LoadBatchKey does not exist.', 1;

    DECLARE @Checks TABLE
    (
        CheckOrder int IDENTITY(1,1) NOT NULL,
        CheckName nvarchar(200) NOT NULL,
        ActualValue nvarchar(200) NULL,
        ExpectedValue nvarchar(200) NOT NULL,
        IsMatched bit NOT NULL
    );

    DECLARE @BatchStatus varchar(20);
    DECLARE @BatchError nvarchar(2000);
    DECLARE @RowsRead bigint;
    DECLARE @RowsAccepted bigint;
    DECLARE @RowsRejected bigint;

    SELECT
        @BatchStatus = LoadStatus,
        @BatchError = ErrorMessage,
        @RowsRead = RowsRead,
        @RowsAccepted = RowsAccepted,
        @RowsRejected = RowsRejected
    FROM DanangSmartParkingDW.etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Batch status before/after Silver gate', @BatchStatus,
         N'BRONZE_LOADED or SILVER_VALIDATED',
         CASE WHEN @BatchStatus IN ('BRONZE_LOADED', 'SILVER_VALIDATED') THEN 1 ELSE 0 END),
        (N'Batch ErrorMessage', COALESCE(@BatchError, N'NULL'), N'NULL',
         CASE WHEN @BatchError IS NULL THEN 1 ELSE 0 END),
        (N'Extract audit totals',
         CONCAT(@RowsRead, N'/', @RowsAccepted, N'/', @RowsRejected),
         N'21500/21500/0',
         CASE WHEN @RowsRead = 21500 AND @RowsAccepted = 21500
                        AND @RowsRejected = 0 THEN 1 ELSE 0 END);

    /* The original staging gate provides the baseline row-count check. */
    IF OBJECT_ID(N'dbo.usp_ValidateStagingBatch', N'P') IS NULL
        INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
        VALUES (N'Base staging validation procedure', N'NOT FOUND',
                N'dbo.usp_ValidateStagingBatch', 0);
    ELSE
        EXEC dbo.usp_ValidateStagingBatch
            @LoadBatchKey = @LoadBatchKey,
            @Phase = 'TRANSFORM',
            @ReturnDetail = 0;

    DECLARE @ObjectChecks TABLE
    (
        ObjectName sysname NOT NULL,
        ActualRows bigint NOT NULL,
        ValidRows bigint NOT NULL,
        InvalidRows bigint NOT NULL,
        ExpectedRows bigint NOT NULL
    );

    INSERT @ObjectChecks
        (ObjectName, ActualRows, ValidRows, InvalidRows, ExpectedRows)
    SELECT 'transform.RoadClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 30
    FROM transform.RoadClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.ParkingFacilityClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 20
    FROM transform.ParkingFacilityClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.ParkingRestrictionClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 18
    FROM transform.ParkingRestrictionClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.POIClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 50
    FROM transform.POIClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.RoadSurveyClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 30
    FROM transform.RoadSurveyClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.TrafficObservationClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 AND DuplicateRank = 1
                             THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 OR DuplicateRank <> 1
                             THEN CONVERT(bigint, 1) ELSE 0 END), 0), 16800
    FROM transform.TrafficObservationClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.ParkingEventClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 AND DuplicateRank = 1
                             THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 OR DuplicateRank <> 1
                             THEN CONVERT(bigint, 1) ELSE 0 END), 0), 4283
    FROM transform.ParkingEventClean WHERE LoadBatchKey = @LoadBatchKey
    UNION ALL
    SELECT 'transform.WeatherHourlyClean', COUNT_BIG(*),
           COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0), 168
    FROM transform.WeatherHourlyClean WHERE LoadBatchKey = @LoadBatchKey;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    SELECT ObjectName,
           CONCAT(ActualRows, N'/', ValidRows, N'/', InvalidRows),
           CONCAT(ExpectedRows, N'/', ExpectedRows, N'/0'),
           CASE WHEN ActualRows = ExpectedRows AND ValidRows = ExpectedRows
                          AND InvalidRows = 0 THEN 1 ELSE 0 END
    FROM @ObjectChecks;

    /* Traceability, hashes and business-key uniqueness. */
    DECLARE @UntracedRows bigint =
          (SELECT COUNT_BIG(*)
           FROM transform.RoadClean AS C
           LEFT JOIN extract.RoadRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.ParkingFacilityClean AS C
           LEFT JOIN extract.ParkingLocationRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.ParkingRestrictionClean AS C
           LEFT JOIN extract.ParkingRestrictionRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.POIClean AS C
           LEFT JOIN extract.POIRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.RoadSurveyClean AS C
           LEFT JOIN extract.RoadSurveyRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.TrafficObservationClean AS C
           LEFT JOIN extract.TrafficEventRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.ParkingEventClean AS C
           LEFT JOIN extract.ParkingEventRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL)
        + (SELECT COUNT_BIG(*)
           FROM transform.WeatherHourlyClean AS C
           LEFT JOIN extract.WeatherEventRaw AS R
             ON R.LoadBatchKey = C.LoadBatchKey
            AND R.LoadFileKey = C.LoadFileKey
            AND R.SourceRowNumber = C.SourceRowNumber
           WHERE C.LoadBatchKey = @LoadBatchKey AND R.StageRowKey IS NULL);

    DECLARE @MissingHashes bigint =
          (SELECT COUNT_BIG(*) FROM transform.RoadClean
           WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.ParkingFacilityClean
           WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.ParkingRestrictionClean
           WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.POIClean
           WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
           WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
           WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL)
        + (SELECT COUNT_BIG(*) FROM transform.WeatherHourlyClean
           WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL);

    DECLARE @DuplicateBusinessKeys bigint =
          (SELECT COUNT_BIG(*) FROM
           (SELECT RoadID FROM transform.RoadClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY RoadID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT ParkingID FROM transform.ParkingFacilityClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY ParkingID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT RestrictionID FROM transform.ParkingRestrictionClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY RestrictionID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT POIID FROM transform.POIClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY POIID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT SegmentID FROM transform.RoadSurveyClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY SegmentID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT EventID FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY EventID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT EventID FROM transform.ParkingEventClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY EventID HAVING COUNT_BIG(*) > 1) D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT WeatherTimestamp FROM transform.WeatherHourlyClean
            WHERE LoadBatchKey = @LoadBatchKey GROUP BY WeatherTimestamp HAVING COUNT_BIG(*) > 1) D);

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Clean rows without matching RAW row', CONVERT(nvarchar(30), @UntracedRows),
         N'0', CASE WHEN @UntracedRows = 0 THEN 1 ELSE 0 END),
        (N'Missing transform hashes', CONVERT(nvarchar(30), @MissingHashes),
         N'0', CASE WHEN @MissingHashes = 0 THEN 1 ELSE 0 END),
        (N'Duplicate business keys in retained Clean rows',
         CONVERT(nvarchar(30), @DuplicateBusinessKeys), N'0',
         CASE WHEN @DuplicateBusinessKeys = 0 THEN 1 ELSE 0 END);

    /* Known master-data reconciliation. */
    DECLARE @TotalCapacity bigint;
    DECLARE @ReferenceCapacity bigint;
    DECLARE @ReferenceFacilityCount bigint;
    DECLARE @ImputedWidths bigint;

    SELECT
        @TotalCapacity = COALESCE(SUM(CONVERT(bigint, CapacitySpaces)), 0),
        @ReferenceCapacity = COALESCE
        (
            SUM(CASE WHEN IsReferenceCapacity = 1
                     THEN CONVERT(bigint, CapacitySpaces) ELSE 0 END), 0
        ),
        @ReferenceFacilityCount = COALESCE
        (
            SUM(CASE WHEN IsReferenceCapacity = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0
        )
    FROM transform.ParkingFacilityClean
    WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1;

    SELECT @ImputedWidths = COALESCE(SUM(CONVERT(bigint, WidthImputedFlag)), 0)
    FROM transform.RoadSurveyClean
    WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Master parking capacity', CONVERT(nvarchar(30), @TotalCapacity), N'2267',
         CASE WHEN @TotalCapacity = 2267 THEN 1 ELSE 0 END),
        (N'Master reference capacity/facilities',
         CONCAT(@ReferenceCapacity, N'/', @ReferenceFacilityCount), N'397/2',
         CASE WHEN @ReferenceCapacity = 397 AND @ReferenceFacilityCount = 2
              THEN 1 ELSE 0 END),
        (N'Master imputed road widths', CONVERT(nvarchar(30), @ImputedWidths), N'3',
         CASE WHEN @ImputedWidths = 3 THEN 1 ELSE 0 END);

    /* Event KPI and known warning flags. */
    DECLARE @VehicleVolume bigint;
    DECLARE @ParkedObservations bigint;
    DECLARE @TrafficIllegal bigint;
    DECLARE @AvgSpeed decimal(18,6);
    DECLARE @AvgCongestion decimal(18,6);
    DECLARE @MissingSpeed bigint;
    DECLARE @InvalidMix bigint;
    DECLARE @InvalidParkingCount bigint;

    SELECT
        @VehicleVolume = COALESCE(SUM(CONVERT(bigint, VehicleCount)), 0),
        @ParkedObservations = COALESCE(SUM(CONVERT(bigint, ParkedVehicleCount)), 0),
        @TrafficIllegal = COALESCE(SUM(CONVERT(bigint, IllegalParkingCount)), 0),
        @AvgSpeed = AVG(CONVERT(decimal(18,6), AvgSpeedKmh)),
        @AvgCongestion = AVG(CONVERT(decimal(18,6), CongestionIndex)),
        @MissingSpeed = COALESCE(SUM(CONVERT(bigint, SpeedMissingFlag)), 0),
        @InvalidMix = COALESCE
        (SUM(CASE WHEN VehicleMixValidFlag = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
        @InvalidParkingCount = COALESCE
        (SUM(CASE WHEN ParkingCountValidFlag = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0)
    FROM transform.TrafficObservationClean
    WHERE LoadBatchKey = @LoadBatchKey;

    DECLARE @ParkingRows bigint;
    DECLARE @IllegalEvents bigint;
    DECLARE @OpenEvents bigint;
    DECLARE @EstimatedDurations bigint;
    DECLARE @MissingRestrictionLinks bigint;
    DECLARE @LinkedRestrictions bigint;
    DECLARE @AvgDuration decimal(18,6);

    SELECT
        @ParkingRows = COUNT_BIG(*),
        @IllegalEvents = COALESCE
        (SUM(CASE WHEN IsLegalParking = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
        @OpenEvents = COALESCE(SUM(CONVERT(bigint, IsOpenEvent)), 0),
        @EstimatedDurations = COALESCE(SUM(CONVERT(bigint, IsDurationEstimated)), 0),
        @MissingRestrictionLinks = COALESCE
        (SUM(CONVERT(bigint, RestrictionLinkMissingFlag)), 0),
        @LinkedRestrictions = COALESCE
        (SUM(CASE WHEN ActiveRestrictionID IS NOT NULL THEN CONVERT(bigint, 1) ELSE 0 END), 0),
        @AvgDuration = AVG(CONVERT(decimal(18,6), ParkingDurationMin))
    FROM transform.ParkingEventClean
    WHERE LoadBatchKey = @LoadBatchKey;

    DECLARE @TotalRain decimal(18,2);
    DECLARE @RainyHours bigint;

    SELECT
        @TotalRain = COALESCE(SUM(RainMm), 0),
        @RainyHours = COALESCE(SUM(CONVERT(bigint, IsRainyHour)), 0)
    FROM transform.WeatherHourlyClean
    WHERE LoadBatchKey = @LoadBatchKey;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Traffic vehicle volume', CONVERT(nvarchar(30), @VehicleVolume), N'6596879',
         CASE WHEN @VehicleVolume = 6596879 THEN 1 ELSE 0 END),
        (N'Traffic parked/illegal observations',
         CONCAT(@ParkedObservations, N'/', @TrafficIllegal), N'30480/9100',
         CASE WHEN @ParkedObservations = 30480 AND @TrafficIllegal = 9100 THEN 1 ELSE 0 END),
        (N'Traffic average speed', CONVERT(nvarchar(30), @AvgSpeed),
         N'40.885997 +/- 0.000010',
         CASE WHEN @AvgSpeed IS NOT NULL AND ABS(@AvgSpeed - 40.885997) <= 0.000010
              THEN 1 ELSE 0 END),
        (N'Traffic average congestion', CONVERT(nvarchar(30), @AvgCongestion),
         N'0.252761 +/- 0.000010',
         CASE WHEN @AvgCongestion IS NOT NULL
                        AND ABS(@AvgCongestion - 0.252761) <= 0.000010 THEN 1 ELSE 0 END),
        (N'Traffic DQ warning flags',
         CONCAT(@MissingSpeed, N'/', @InvalidMix, N'/', @InvalidParkingCount),
         N'161/3838/781',
         CASE WHEN @MissingSpeed = 161 AND @InvalidMix = 3838
                        AND @InvalidParkingCount = 781 THEN 1 ELSE 0 END),
        (N'Parking rows/illegal events', CONCAT(@ParkingRows, N'/', @IllegalEvents),
         N'4283/1571', CASE WHEN @ParkingRows = 4283 AND @IllegalEvents = 1571
                            THEN 1 ELSE 0 END),
        (N'Parking average duration', CONVERT(nvarchar(30), @AvgDuration),
         N'45.813449 +/- 0.000010',
         CASE WHEN @AvgDuration IS NOT NULL AND ABS(@AvgDuration - 45.813449) <= 0.000010
              THEN 1 ELSE 0 END),
        (N'Parking open/estimated events', CONCAT(@OpenEvents, N'/', @EstimatedDurations),
         N'64/64', CASE WHEN @OpenEvents = 64 AND @EstimatedDurations = 64
                        THEN 1 ELSE 0 END),
        (N'Parking missing/linked restriction events',
         CONCAT(@MissingRestrictionLinks, N'/', @LinkedRestrictions), N'607/964',
         CASE WHEN @MissingRestrictionLinks = 607 AND @LinkedRestrictions = 964
              THEN 1 ELSE 0 END),
        (N'Weather rain/rainy hours', CONCAT(@TotalRain, N'/', @RainyHours), N'47.50/11',
         CASE WHEN @TotalRain = 47.50 AND @RainyHours = 11 THEN 1 ELSE 0 END);

    /* Duplicate audit must explain the 101 physical JSONL duplicates. */
    DECLARE @TrafficDuplicateAudit bigint;
    DECLARE @ParkingDuplicateAudit bigint;
    DECLARE @InvalidTransformAudit bigint;

    SELECT
        @TrafficDuplicateAudit = COALESCE
        (SUM(CASE WHEN R.RuleCode = 'TRN_TRAFFIC_DUPLICATE' THEN 1 ELSE 0 END), 0),
        @ParkingDuplicateAudit = COALESCE
        (SUM(CASE WHEN R.RuleCode = 'TRN_PARKING_DUPLICATE' THEN 1 ELSE 0 END), 0),
        @InvalidTransformAudit = COALESCE
        (SUM(CASE WHEN R.RuleCode IN
             ('TRN_ROAD_INVALID', 'TRN_FACILITY_INVALID', 'TRN_RESTRICTION_INVALID',
              'TRN_POI_INVALID', 'TRN_SURVEY_INVALID', 'TRN_TRAFFIC_INVALID',
              'TRN_PARKING_INVALID', 'TRN_WEATHER_INVALID') THEN 1 ELSE 0 END), 0)
    FROM DanangSmartParkingDW.etl.RejectedRow AS R
    JOIN DanangSmartParkingDW.etl.LoadFile AS F
      ON F.LoadFileKey = R.LoadFileKey
    WHERE F.LoadBatchKey = @LoadBatchKey;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Transform duplicate WARNING audit',
         CONCAT(@TrafficDuplicateAudit, N'/', @ParkingDuplicateAudit), N'84/17',
         CASE WHEN @TrafficDuplicateAudit = 84 AND @ParkingDuplicateAudit = 17
              THEN 1 ELSE 0 END),
        (N'Transform invalid ERROR audit', CONVERT(nvarchar(30), @InvalidTransformAudit),
         N'0', CASE WHEN @InvalidTransformAudit = 0 THEN 1 ELSE 0 END);

    /* Cross-source referential integrity needed by dimension/fact lookups. */
    DECLARE @ReferenceMismatches bigint =
          (SELECT COUNT_BIG(*)
           FROM transform.TrafficObservationClean AS E
           LEFT JOIN transform.RoadClean AS R
             ON R.LoadBatchKey = E.LoadBatchKey AND R.RoadID = E.RoadID AND R.IsValid = 1
           LEFT JOIN transform.RoadSurveyClean AS S
             ON S.LoadBatchKey = E.LoadBatchKey AND S.SegmentID = E.SegmentID AND S.IsValid = 1
           LEFT JOIN transform.WeatherHourlyClean AS W
             ON W.LoadBatchKey = E.LoadBatchKey AND W.EventDate = E.EventDate
            AND W.HourNumber = E.HourNumber AND W.IsValid = 1
           WHERE E.LoadBatchKey = @LoadBatchKey
             AND (R.TransformRowKey IS NULL OR S.TransformRowKey IS NULL
                  OR S.RoadID <> E.RoadID OR W.TransformRowKey IS NULL
                  OR W.RainMm <> E.RainMm))
        + (SELECT COUNT_BIG(*)
           FROM transform.ParkingEventClean AS E
           LEFT JOIN transform.RoadClean AS R
             ON R.LoadBatchKey = E.LoadBatchKey AND R.RoadID = E.RoadID AND R.IsValid = 1
           LEFT JOIN transform.RoadSurveyClean AS S
             ON S.LoadBatchKey = E.LoadBatchKey AND S.SegmentID = E.SegmentID AND S.IsValid = 1
           LEFT JOIN transform.ParkingRestrictionClean AS P
             ON P.LoadBatchKey = E.LoadBatchKey
            AND P.RestrictionID = E.ActiveRestrictionID AND P.IsValid = 1
           WHERE E.LoadBatchKey = @LoadBatchKey
             AND (R.TransformRowKey IS NULL OR S.TransformRowKey IS NULL
                  OR S.RoadID <> E.RoadID
                  OR (E.ActiveRestrictionID IS NOT NULL AND P.TransformRowKey IS NULL)));

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES (N'Cross-source reference mismatches', CONVERT(nvarchar(30), @ReferenceMismatches),
            N'0', CASE WHEN @ReferenceMismatches = 0 THEN 1 ELSE 0 END);

    /* Recompute both package-22 aggregates and compare every group/value. */
    DECLARE @TrafficAggregateMismatches bigint =
        (SELECT COUNT_BIG(*) FROM
         (
             SELECT LoadBatchKey, EventDate, HourNumber, RoadID,
                    SUM(CONVERT(bigint, VehicleCount)) AS VehicleVolume,
                    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), AvgSpeedKmh))) AS AvgSpeedKmh,
                    CONVERT(decimal(12,6), AVG(CONVERT(decimal(18,6), CongestionIndex))) AS AvgCongestionIndex,
                    SUM(CONVERT(bigint, IllegalParkingCount)) AS IllegalParkingObserved
             FROM transform.TrafficObservationClean
             WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
             GROUP BY LoadBatchKey, EventDate, HourNumber, RoadID
             EXCEPT
             SELECT LoadBatchKey, EventDate, HourNumber, RoadID, VehicleVolume,
                    AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
             FROM transform.TrafficHourlySummary
             WHERE LoadBatchKey = @LoadBatchKey
         ) Missing)
      + (SELECT COUNT_BIG(*) FROM
         (
             SELECT LoadBatchKey, EventDate, HourNumber, RoadID, VehicleVolume,
                    AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
             FROM transform.TrafficHourlySummary
             WHERE LoadBatchKey = @LoadBatchKey
             EXCEPT
             SELECT LoadBatchKey, EventDate, HourNumber, RoadID,
                    SUM(CONVERT(bigint, VehicleCount)),
                    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), AvgSpeedKmh))),
                    CONVERT(decimal(12,6), AVG(CONVERT(decimal(18,6), CongestionIndex))),
                    SUM(CONVERT(bigint, IllegalParkingCount))
             FROM transform.TrafficObservationClean
             WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
             GROUP BY LoadBatchKey, EventDate, HourNumber, RoadID
         ) Unexpected);

    DECLARE @ParkingAggregateMismatches bigint =
        (SELECT COUNT_BIG(*) FROM
         (
             SELECT LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
                    COUNT_BIG(*) AS ParkingEventCount,
                    SUM(CASE WHEN IsLegalParking = 0 THEN CONVERT(bigint, 1) ELSE 0 END) AS IllegalEventCount,
                    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), ParkingDurationMin))) AS AvgDurationMin,
                    SUM(CONVERT(bigint, IsOpenEvent)) AS OpenEventCount
             FROM transform.ParkingEventClean
             WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
             GROUP BY LoadBatchKey, EventDate, RoadID, VehicleTypeCode
             EXCEPT
             SELECT LoadBatchKey, EventDate, RoadID, VehicleTypeCode, ParkingEventCount,
                    IllegalEventCount, AvgDurationMin, OpenEventCount
             FROM transform.ParkingDailySummary
             WHERE LoadBatchKey = @LoadBatchKey
         ) Missing)
      + (SELECT COUNT_BIG(*) FROM
         (
             SELECT LoadBatchKey, EventDate, RoadID, VehicleTypeCode, ParkingEventCount,
                    IllegalEventCount, AvgDurationMin, OpenEventCount
             FROM transform.ParkingDailySummary
             WHERE LoadBatchKey = @LoadBatchKey
             EXCEPT
             SELECT LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
                    COUNT_BIG(*),
                    SUM(CASE WHEN IsLegalParking = 0 THEN CONVERT(bigint, 1) ELSE 0 END),
                    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), ParkingDurationMin))),
                    SUM(CONVERT(bigint, IsOpenEvent))
             FROM transform.ParkingEventClean
             WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
             GROUP BY LoadBatchKey, EventDate, RoadID, VehicleTypeCode
         ) Unexpected);

    DECLARE @TrafficSummaryRows bigint;
    DECLARE @ParkingSummaryRows bigint;
    DECLARE @SummaryVehicleVolume bigint;
    DECLARE @SummaryParkingEvents bigint;

    SELECT @TrafficSummaryRows = COUNT_BIG(*),
           @SummaryVehicleVolume = COALESCE(SUM(VehicleVolume), 0)
    FROM transform.TrafficHourlySummary WHERE LoadBatchKey = @LoadBatchKey;

    SELECT @ParkingSummaryRows = COUNT_BIG(*),
           @SummaryParkingEvents = COALESCE(SUM(ParkingEventCount), 0)
    FROM transform.ParkingDailySummary WHERE LoadBatchKey = @LoadBatchKey;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
        (N'Traffic summary rows/volume',
         CONCAT(@TrafficSummaryRows, N'/', @SummaryVehicleVolume), N'4200/6596879',
         CASE WHEN @TrafficSummaryRows = 4200 AND @SummaryVehicleVolume = 6596879
              THEN 1 ELSE 0 END),
        (N'Parking summary rows/events',
         CONCAT(@ParkingSummaryRows, N'/', @SummaryParkingEvents), N'513/4283',
         CASE WHEN @ParkingSummaryRows = 513 AND @SummaryParkingEvents = 4283
              THEN 1 ELSE 0 END),
        (N'Traffic aggregate group/value mismatches',
         CONVERT(nvarchar(30), @TrafficAggregateMismatches), N'0',
         CASE WHEN @TrafficAggregateMismatches = 0 THEN 1 ELSE 0 END),
        (N'Parking aggregate group/value mismatches',
         CONVERT(nvarchar(30), @ParkingAggregateMismatches), N'0',
         CASE WHEN @ParkingAggregateMismatches = 0 THEN 1 ELSE 0 END);

    /* Unicode must still be correct at the end of Transform. */
    DECLARE @UnicodeValue nvarchar(300);

    SELECT @UnicodeValue = CONCAT(RoadName, N' / ', AnalysisZone)
    FROM transform.RoadClean
    WHERE LoadBatchKey = @LoadBatchKey AND RoadID = 'RD001' AND IsValid = 1;

    INSERT @Checks (CheckName, ActualValue, ExpectedValue, IsMatched)
    VALUES
    (
        N'Transform Unicode checkpoint', COALESCE(@UnicodeValue, N'NULL'),
        N'Trần Phú / Hải Châu core',
        CASE WHEN @UnicodeValue = N'Trần Phú / Hải Châu core' THEN 1 ELSE 0 END
    );

    IF @ReturnDetail = 1
    BEGIN
        SELECT CheckOrder, CheckName, ActualValue, ExpectedValue, IsMatched
        FROM @Checks
        ORDER BY CheckOrder;
    END;

    IF EXISTS (SELECT 1 FROM @Checks WHERE IsMatched = 0)
        THROW 52299, 'TRANSFORM VALIDATION FAILED. Review the IsMatched=0 checks.', 1;
END;
GO

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateTransformAndMarkSilver
    @LoadBatchKey bigint,
    @ReturnDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 52300, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 52301, 'LoadBatchKey does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus IN ('BRONZE_LOADED', 'SILVER_VALIDATED')
    )
        THROW 52302, 'Silver validation requires a BRONZE_LOADED or SILVER_VALIDATED batch.', 1;

    /* This call is read-only and throws before any status update when a check fails. */
    EXEC DanangSmartParkingSTG.dbo.usp_ValidateTransformBatch
        @LoadBatchKey = @LoadBatchKey,
        @ReturnDetail = @ReturnDetail;

    BEGIN TRANSACTION;

    UPDATE etl.LoadBatch
    SET LoadStatus = 'SILVER_VALIDATED',
        ErrorMessage = NULL
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus = 'BRONZE_LOADED';

    IF @@ROWCOUNT = 0
       AND NOT EXISTS
       (
           SELECT 1 FROM etl.LoadBatch
           WHERE LoadBatchKey = @LoadBatchKey
             AND LoadStatus = 'SILVER_VALIDATED'
       )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 52303, 'The batch status could not be changed to SILVER_VALIDATED.', 1;
    END;

    COMMIT TRANSACTION;

    IF @ReturnDetail = 1
    BEGIN
        SELECT LoadBatchKey, LoadStatus, RowsRead, RowsAccepted, RowsRejected,
               StartedAt, CompletedAt, ErrorMessage
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey;
    END;
END;
GO

