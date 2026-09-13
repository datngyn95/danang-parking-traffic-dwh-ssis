/*
    Da Nang Smart Parking
    Acceptance test for package 21 - Transform Events.

    Read-only script:
      - does not rerun dbo.usp_TransformEvents;
      - does not insert, update or delete persistent data;
      - returns PASS only when every package-21 check succeeds.
*/

USE DanangSmartParkingSTG;
GO

SET NOCOUNT ON;

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

IF @LoadBatchKey IS NULL
    THROW 51900, 'No LoadBatch row was found.', 1;

DECLARE @Failures TABLE
(
    CheckName nvarchar(200) NOT NULL,
    ActualValue nvarchar(200) NULL,
    ExpectedValue nvarchar(200) NOT NULL
);

DECLARE @TableChecks TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ValidRows bigint NOT NULL,
    InvalidRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @TableChecks
(
    ObjectName,
    ActualRows,
    ValidRows,
    InvalidRows,
    ExpectedRows
)
SELECT
    'transform.TrafficObservationClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    16800
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.ParkingEventClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    4283
FROM transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.WeatherHourlyClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    168
FROM transform.WeatherHourlyClean
WHERE LoadBatchKey = @LoadBatchKey;

DECLARE @BatchStatus varchar(20);
DECLARE @BatchError nvarchar(2000);
DECLARE @BatchRowsRejected bigint;

SELECT
    @BatchStatus = LoadStatus,
    @BatchError = ErrorMessage,
    @BatchRowsRejected = RowsRejected
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

IF OBJECT_ID(N'dbo.usp_TransformEvents', N'P') IS NULL
BEGIN
    INSERT @Failures VALUES
        (N'Procedure exists', N'NOT FOUND', N'dbo.usp_TransformEvents');
END;

IF ISNULL(@BatchStatus, '') <> 'BRONZE_LOADED'
BEGIN
    INSERT @Failures VALUES
        (N'Batch status after package 21', COALESCE(@BatchStatus, N'NULL'), N'BRONZE_LOADED');
END;

IF @BatchError IS NOT NULL
BEGIN
    INSERT @Failures VALUES
        (N'Batch ErrorMessage', LEFT(@BatchError, 200), N'NULL');
END;

IF ISNULL(@BatchRowsRejected, -1) <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Batch extract RowsRejected', CONVERT(nvarchar(30), @BatchRowsRejected), N'0');
END;

INSERT @Failures (CheckName, ActualValue, ExpectedValue)
SELECT
    CONCAT(ObjectName, N' row/valid/invalid counts'),
    CONCAT(ActualRows, N'/', ValidRows, N'/', InvalidRows),
    CONCAT(ExpectedRows, N'/', ExpectedRows, N'/0')
FROM @TableChecks
WHERE ActualRows <> ExpectedRows
   OR ValidRows <> ExpectedRows
   OR InvalidRows <> 0;

DECLARE @TotalEventRows bigint =
(
    SELECT SUM(ActualRows) FROM @TableChecks
);

IF @TotalEventRows <> 21251
BEGIN
    INSERT @Failures VALUES
        (N'Total deduplicated event rows', CONVERT(nvarchar(30), @TotalEventRows), N'21251');
END;

/* Every Clean row must trace to the retained RAW row. */
DECLARE @UntracedRows bigint =
      (SELECT COUNT_BIG(*)
       FROM transform.TrafficObservationClean AS Clean
       LEFT JOIN extract.TrafficEventRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.ParkingEventClean AS Clean
       LEFT JOIN extract.ParkingEventRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.WeatherHourlyClean AS Clean
       LEFT JOIN extract.WeatherEventRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL);

IF @UntracedRows <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Clean rows without matching retained RAW row',
         CONVERT(nvarchar(30), @UntracedRows), N'0');
END;

DECLARE @MissingHashes bigint =
      (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
       WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL)
    + (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
       WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL)
    + (SELECT COUNT_BIG(*) FROM transform.WeatherHourlyClean
       WHERE LoadBatchKey = @LoadBatchKey AND RecordHashSHA256 IS NULL);

IF @MissingHashes <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Missing event RecordHashSHA256 rows', CONVERT(nvarchar(30), @MissingHashes), N'0');
END;

DECLARE @DuplicateKeysInClean bigint =
      (SELECT COUNT_BIG(*) FROM
       (SELECT EventID FROM transform.TrafficObservationClean
        WHERE LoadBatchKey = @LoadBatchKey
        GROUP BY EventID HAVING COUNT_BIG(*) > 1) AS DuplicateTraffic)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT EventID FROM transform.ParkingEventClean
        WHERE LoadBatchKey = @LoadBatchKey
        GROUP BY EventID HAVING COUNT_BIG(*) > 1) AS DuplicateParking)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT WeatherTimestamp FROM transform.WeatherHourlyClean
        WHERE LoadBatchKey = @LoadBatchKey
        GROUP BY WeatherTimestamp HAVING COUNT_BIG(*) > 1) AS DuplicateWeather);

IF @DuplicateKeysInClean <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Duplicate business keys remaining in Clean',
         CONVERT(nvarchar(30), @DuplicateKeysInClean), N'0');
END;

DECLARE @NonFirstRanks bigint =
      (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
       WHERE LoadBatchKey = @LoadBatchKey AND DuplicateRank <> 1)
    + (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
       WHERE LoadBatchKey = @LoadBatchKey AND DuplicateRank <> 1);

IF @NonFirstRanks <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Clean event rows with DuplicateRank other than 1',
         CONVERT(nvarchar(30), @NonFirstRanks), N'0');
END;

DECLARE @RawTrafficDuplicates bigint =
    (SELECT COUNT_BIG(*) FROM extract.TrafficEventRaw
     WHERE LoadBatchKey = @LoadBatchKey)
  - (SELECT COUNT_BIG(*) FROM
     (SELECT EventID FROM extract.TrafficEventRaw
      WHERE LoadBatchKey = @LoadBatchKey GROUP BY EventID) AS DistinctTraffic);

DECLARE @RawParkingDuplicates bigint =
    (SELECT COUNT_BIG(*) FROM extract.ParkingEventRaw
     WHERE LoadBatchKey = @LoadBatchKey)
  - (SELECT COUNT_BIG(*) FROM
     (SELECT EventID FROM extract.ParkingEventRaw
      WHERE LoadBatchKey = @LoadBatchKey GROUP BY EventID) AS DistinctParking);

DECLARE @RawWeatherDuplicates bigint =
    (SELECT COUNT_BIG(*) FROM extract.WeatherEventRaw
     WHERE LoadBatchKey = @LoadBatchKey)
  - (SELECT COUNT_BIG(*) FROM
     (SELECT WeatherTimestampRaw FROM extract.WeatherEventRaw
      WHERE LoadBatchKey = @LoadBatchKey GROUP BY WeatherTimestampRaw) AS DistinctWeather);

IF @RawTrafficDuplicates <> 84
    INSERT @Failures VALUES
        (N'RAW traffic duplicate surplus', CONVERT(nvarchar(30), @RawTrafficDuplicates), N'84');

IF @RawParkingDuplicates <> 17
    INSERT @Failures VALUES
        (N'RAW parking duplicate surplus', CONVERT(nvarchar(30), @RawParkingDuplicates), N'17');

IF @RawWeatherDuplicates <> 0
    INSERT @Failures VALUES
        (N'RAW weather duplicate surplus', CONVERT(nvarchar(30), @RawWeatherDuplicates), N'0');

DECLARE @TrafficDuplicateAudit bigint;
DECLARE @ParkingDuplicateAudit bigint;
DECLARE @WeatherDuplicateAudit bigint;
DECLARE @InvalidEventAudit bigint;

SELECT
    @TrafficDuplicateAudit = COALESCE
    (
        SUM(CASE WHEN Rejected.RuleCode = 'TRN_TRAFFIC_DUPLICATE' THEN 1 ELSE 0 END), 0
    ),
    @ParkingDuplicateAudit = COALESCE
    (
        SUM(CASE WHEN Rejected.RuleCode = 'TRN_PARKING_DUPLICATE' THEN 1 ELSE 0 END), 0
    ),
    @WeatherDuplicateAudit = COALESCE
    (
        SUM(CASE WHEN Rejected.RuleCode = 'TRN_WEATHER_DUPLICATE' THEN 1 ELSE 0 END), 0
    ),
    @InvalidEventAudit = COALESCE
    (
        SUM(CASE WHEN Rejected.RuleCode IN
                      ('TRN_TRAFFIC_INVALID', 'TRN_PARKING_INVALID', 'TRN_WEATHER_INVALID')
                 THEN 1 ELSE 0 END), 0
    )
FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
  ON LoadFile.LoadFileKey = Rejected.LoadFileKey
WHERE LoadFile.LoadBatchKey = @LoadBatchKey
  AND Rejected.RuleCode LIKE 'TRN_%';

IF @TrafficDuplicateAudit <> 84
    INSERT @Failures VALUES
        (N'Traffic duplicate WARNING audit rows',
         CONVERT(nvarchar(30), @TrafficDuplicateAudit), N'84');

IF @ParkingDuplicateAudit <> 17
    INSERT @Failures VALUES
        (N'Parking duplicate WARNING audit rows',
         CONVERT(nvarchar(30), @ParkingDuplicateAudit), N'17');

IF @WeatherDuplicateAudit <> 0
    INSERT @Failures VALUES
        (N'Weather duplicate WARNING audit rows',
         CONVERT(nvarchar(30), @WeatherDuplicateAudit), N'0');

IF @InvalidEventAudit <> 0
    INSERT @Failures VALUES
        (N'Invalid event ERROR audit rows', CONVERT(nvarchar(30), @InvalidEventAudit), N'0');

/* Traffic reconciliation. */
DECLARE @TrafficRows bigint;
DECLARE @VehicleVolume bigint;
DECLARE @ParkedObservations bigint;
DECLARE @IllegalParkingObservations bigint;
DECLARE @AvgSpeedKmh decimal(18,6);
DECLARE @AvgCongestion decimal(18,6);
DECLARE @MissingSpeedRows bigint;
DECLARE @InvalidMixRows bigint;
DECLARE @InvalidParkingCountRows bigint;

SELECT
    @TrafficRows = COUNT_BIG(*),
    @VehicleVolume = COALESCE(SUM(CONVERT(bigint, VehicleCount)), 0),
    @ParkedObservations = COALESCE(SUM(CONVERT(bigint, ParkedVehicleCount)), 0),
    @IllegalParkingObservations = COALESCE(SUM(CONVERT(bigint, IllegalParkingCount)), 0),
    @AvgSpeedKmh = AVG(CONVERT(decimal(18,6), AvgSpeedKmh)),
    @AvgCongestion = AVG(CONVERT(decimal(18,6), CongestionIndex)),
    @MissingSpeedRows = COALESCE(SUM(CONVERT(bigint, SpeedMissingFlag)), 0),
    @InvalidMixRows = COALESCE
    (
        SUM(CASE WHEN VehicleMixValidFlag = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0
    ),
    @InvalidParkingCountRows = COALESCE
    (
        SUM(CASE WHEN ParkingCountValidFlag = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0
    )
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey;

IF @TrafficRows <> 16800
    INSERT @Failures VALUES
        (N'Traffic rows after dedup', CONVERT(nvarchar(30), @TrafficRows), N'16800');
IF @VehicleVolume <> 6596879
    INSERT @Failures VALUES
        (N'Traffic vehicle volume', CONVERT(nvarchar(30), @VehicleVolume), N'6596879');
IF @ParkedObservations <> 30480
    INSERT @Failures VALUES
        (N'Traffic parked observations', CONVERT(nvarchar(30), @ParkedObservations), N'30480');
IF @IllegalParkingObservations <> 9100
    INSERT @Failures VALUES
        (N'Traffic illegal-parking observations',
         CONVERT(nvarchar(30), @IllegalParkingObservations), N'9100');
IF @AvgSpeedKmh IS NULL OR ABS(@AvgSpeedKmh - 40.885997) > 0.000010
    INSERT @Failures VALUES
        (N'Traffic average speed', CONVERT(nvarchar(30), @AvgSpeedKmh), N'40.885997 +/- 0.000010');
IF @AvgCongestion IS NULL OR ABS(@AvgCongestion - 0.252761) > 0.000010
    INSERT @Failures VALUES
        (N'Traffic average congestion',
         CONVERT(nvarchar(30), @AvgCongestion), N'0.252761 +/- 0.000010');
IF @MissingSpeedRows <> 161
    INSERT @Failures VALUES
        (N'Traffic SpeedMissingFlag rows', CONVERT(nvarchar(30), @MissingSpeedRows), N'161');
IF @InvalidMixRows <> 3838
    INSERT @Failures VALUES
        (N'Traffic VehicleMixValidFlag=0 rows', CONVERT(nvarchar(30), @InvalidMixRows), N'3838');
IF @InvalidParkingCountRows <> 781
    INSERT @Failures VALUES
        (N'Traffic ParkingCountValidFlag=0 rows',
         CONVERT(nvarchar(30), @InvalidParkingCountRows), N'781');

/* Parking reconciliation. */
DECLARE @ParkingRows bigint;
DECLARE @IllegalEvents bigint;
DECLARE @IllegalRate decimal(9,6);
DECLARE @AvgDurationMin decimal(18,6);
DECLARE @OpenEvents bigint;
DECLARE @EstimatedDurationEvents bigint;
DECLARE @RestrictionLinkMissingEvents bigint;
DECLARE @LinkedRestrictionEvents bigint;

SELECT
    @ParkingRows = COUNT_BIG(*),
    @IllegalEvents = COALESCE
    (
        SUM(CASE WHEN IsLegalParking = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0
    ),
    @IllegalRate = CAST
    (
        1.0 * SUM(CASE WHEN IsLegalParking = 0 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0)
        AS decimal(9,6)
    ),
    @AvgDurationMin = AVG(CONVERT(decimal(18,6), ParkingDurationMin)),
    @OpenEvents = COALESCE(SUM(CONVERT(bigint, IsOpenEvent)), 0),
    @EstimatedDurationEvents = COALESCE(SUM(CONVERT(bigint, IsDurationEstimated)), 0),
    @RestrictionLinkMissingEvents = COALESCE
    (
        SUM(CONVERT(bigint, RestrictionLinkMissingFlag)), 0
    ),
    @LinkedRestrictionEvents = COALESCE
    (
        SUM(CASE WHEN ActiveRestrictionID IS NOT NULL THEN CONVERT(bigint, 1) ELSE 0 END), 0
    )
FROM transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey;

IF @ParkingRows <> 4283
    INSERT @Failures VALUES
        (N'Parking rows after dedup', CONVERT(nvarchar(30), @ParkingRows), N'4283');
IF @IllegalEvents <> 1571
    INSERT @Failures VALUES
        (N'Illegal parking events', CONVERT(nvarchar(30), @IllegalEvents), N'1571');
IF @IllegalRate IS NULL OR ABS(@IllegalRate - 0.366799) > 0.000001
    INSERT @Failures VALUES
        (N'Illegal parking rate', CONVERT(nvarchar(30), @IllegalRate), N'0.366799');
IF @AvgDurationMin IS NULL OR ABS(@AvgDurationMin - 45.813449) > 0.000010
    INSERT @Failures VALUES
        (N'Average parking duration',
         CONVERT(nvarchar(30), @AvgDurationMin), N'45.813449 +/- 0.000010');
IF @OpenEvents <> 64
    INSERT @Failures VALUES
        (N'Open parking events', CONVERT(nvarchar(30), @OpenEvents), N'64');
IF @EstimatedDurationEvents <> 64
    INSERT @Failures VALUES
        (N'Estimated/last-known duration events',
         CONVERT(nvarchar(30), @EstimatedDurationEvents), N'64');
IF @RestrictionLinkMissingEvents <> 607
    INSERT @Failures VALUES
        (N'Illegal events without restriction link',
         CONVERT(nvarchar(30), @RestrictionLinkMissingEvents), N'607');
IF @LinkedRestrictionEvents <> 964
    INSERT @Failures VALUES
        (N'Parking events with restriction ID',
         CONVERT(nvarchar(30), @LinkedRestrictionEvents), N'964');

/* Weather reconciliation. */
DECLARE @WeatherRows bigint;
DECLARE @TotalRainMm decimal(18,2);
DECLARE @RainyHours bigint;

SELECT
    @WeatherRows = COUNT_BIG(*),
    @TotalRainMm = COALESCE(SUM(RainMm), 0),
    @RainyHours = COALESCE(SUM(CONVERT(bigint, IsRainyHour)), 0)
FROM transform.WeatherHourlyClean
WHERE LoadBatchKey = @LoadBatchKey;

IF @WeatherRows <> 168
    INSERT @Failures VALUES
        (N'Weather hourly rows', CONVERT(nvarchar(30), @WeatherRows), N'168');
IF @TotalRainMm <> 47.50
    INSERT @Failures VALUES
        (N'Total weather rain', CONVERT(nvarchar(30), @TotalRainMm), N'47.50');
IF @RainyHours <> 11
    INSERT @Failures VALUES
        (N'Rainy weather hours', CONVERT(nvarchar(30), @RainyHours), N'11');

/* Referential and cross-source checks used by later dimension/fact lookup. */
DECLARE @ReferenceMismatchRows bigint =
      (SELECT COUNT_BIG(*)
       FROM transform.TrafficObservationClean AS EventRow
       LEFT JOIN transform.RoadClean AS Road
         ON Road.LoadBatchKey = EventRow.LoadBatchKey
        AND Road.RoadID = EventRow.RoadID
        AND Road.IsValid = 1
       LEFT JOIN transform.RoadSurveyClean AS Segment
         ON Segment.LoadBatchKey = EventRow.LoadBatchKey
        AND Segment.SegmentID = EventRow.SegmentID
        AND Segment.IsValid = 1
       LEFT JOIN transform.WeatherHourlyClean AS Weather
         ON Weather.LoadBatchKey = EventRow.LoadBatchKey
        AND Weather.EventDate = EventRow.EventDate
        AND Weather.HourNumber = EventRow.HourNumber
        AND Weather.IsValid = 1
       WHERE EventRow.LoadBatchKey = @LoadBatchKey
         AND
         (
             Road.TransformRowKey IS NULL
             OR Segment.TransformRowKey IS NULL
             OR Segment.RoadID <> EventRow.RoadID
             OR Weather.TransformRowKey IS NULL
             OR Weather.RainMm <> EventRow.RainMm
         ))
    + (SELECT COUNT_BIG(*)
       FROM transform.ParkingEventClean AS EventRow
       LEFT JOIN transform.RoadClean AS Road
         ON Road.LoadBatchKey = EventRow.LoadBatchKey
        AND Road.RoadID = EventRow.RoadID
        AND Road.IsValid = 1
       LEFT JOIN transform.RoadSurveyClean AS Segment
         ON Segment.LoadBatchKey = EventRow.LoadBatchKey
        AND Segment.SegmentID = EventRow.SegmentID
        AND Segment.IsValid = 1
       LEFT JOIN transform.ParkingRestrictionClean AS Restriction
         ON Restriction.LoadBatchKey = EventRow.LoadBatchKey
        AND Restriction.RestrictionID = EventRow.ActiveRestrictionID
        AND Restriction.IsValid = 1
       WHERE EventRow.LoadBatchKey = @LoadBatchKey
         AND
         (
             Road.TransformRowKey IS NULL
             OR Segment.TransformRowKey IS NULL
             OR Segment.RoadID <> EventRow.RoadID
             OR (EventRow.ActiveRestrictionID IS NOT NULL
                 AND Restriction.TransformRowKey IS NULL)
         ));

IF @ReferenceMismatchRows <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Event rows with master/weather reference mismatch',
         CONVERT(nvarchar(30), @ReferenceMismatchRows), N'0');
END;

/* Visible Unicode checkpoint: this result set must be readable in SSMS. */
DECLARE @UnicodeRoadID varchar(10);
DECLARE @UnicodeRoadName nvarchar(150);
DECLARE @UnicodeZone nvarchar(100);

SELECT TOP (1)
    @UnicodeRoadID = RoadID,
    @UnicodeRoadName = RoadName,
    @UnicodeZone = AnalysisZone
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
  AND RoadID = 'RD001'
ORDER BY SourceRowNumber;

IF @UnicodeRoadName IS NULL
   OR @UnicodeZone IS NULL
   OR @UnicodeRoadName <> N'Trần Phú'
   OR @UnicodeZone <> N'Hải Châu core'
BEGIN
    INSERT @Failures VALUES
    (
        N'Traffic Unicode checkpoint',
        CONCAT(COALESCE(@UnicodeRoadName, N'NULL'), N' / ', COALESCE(@UnicodeZone, N'NULL')),
        N'Trần Phú / Hải Châu core'
    );
END;

/* Evidence result sets. */
SELECT
    @LoadBatchKey AS LoadBatchKey,
    @BatchStatus AS LoadStatus,
    @BatchRowsRejected AS ExtractRejectedRows,
    @BatchError AS ErrorMessage;

SELECT
    ObjectName,
    ActualRows,
    ValidRows,
    InvalidRows,
    ExpectedRows,
    CONVERT
    (
        bit,
        CASE WHEN ActualRows = ExpectedRows
                   AND ValidRows = ExpectedRows
                   AND InvalidRows = 0
             THEN 1 ELSE 0 END
    ) AS IsMatched
FROM @TableChecks
ORDER BY ObjectName;

SELECT
    @TrafficRows AS TrafficRows,
    @VehicleVolume AS VehicleVolume,
    @ParkedObservations AS ParkedObservations,
    @IllegalParkingObservations AS IllegalParkingObservations,
    @AvgSpeedKmh AS AvgSpeedKmh,
    @AvgCongestion AS AvgCongestion,
    @MissingSpeedRows AS MissingSpeedRows,
    @InvalidMixRows AS InvalidMixRows,
    @InvalidParkingCountRows AS InvalidParkingCountRows;

SELECT
    @ParkingRows AS ParkingRows,
    @IllegalEvents AS IllegalEvents,
    @IllegalRate AS IllegalRate,
    @AvgDurationMin AS AvgDurationMin,
    @OpenEvents AS OpenEvents,
    @EstimatedDurationEvents AS EstimatedDurationEvents,
    @RestrictionLinkMissingEvents AS IllegalWithoutRestrictionLink,
    @LinkedRestrictionEvents AS LinkedRestrictionEvents;

SELECT
    @WeatherRows AS WeatherRows,
    @TotalRainMm AS TotalRainMm,
    @RainyHours AS RainyHours,
    @ReferenceMismatchRows AS CrossSourceMismatchRows;

SELECT
    @RawTrafficDuplicates AS RawTrafficDuplicates,
    @TrafficDuplicateAudit AS TrafficDuplicateAudit,
    @RawParkingDuplicates AS RawParkingDuplicates,
    @ParkingDuplicateAudit AS ParkingDuplicateAudit,
    @RawWeatherDuplicates AS RawWeatherDuplicates,
    @WeatherDuplicateAudit AS WeatherDuplicateAudit,
    @InvalidEventAudit AS InvalidEventAudit;

SELECT
    @UnicodeRoadID AS RoadID,
    @UnicodeRoadName AS RoadName,
    @UnicodeZone AS AnalysisZone,
    CONVERT
    (
        bit,
        CASE WHEN @UnicodeRoadName = N'Trần Phú'
                   AND @UnicodeZone = N'Hải Châu core'
             THEN 1 ELSE 0 END
    ) AS UnicodeMatched,
    N'Trần Phú / Hải Châu core' AS ExpectedUnicodeValue;

IF EXISTS (SELECT 1 FROM @Failures)
BEGIN
    SELECT
        CheckName,
        ActualValue,
        ExpectedValue
    FROM @Failures
    ORDER BY CheckName;

    THROW 51999, 'PACKAGE 21 ACCEPTANCE FAILED. Review the Failures result set.', 1;
END;

SELECT
    'PASS' AS AcceptanceStatus,
    @LoadBatchKey AS LoadBatchKey,
    'PACKAGE 21 ACCEPTED - ready for package 22' AS Message;
GO
