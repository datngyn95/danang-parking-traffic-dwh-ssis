/*
    Da Nang Smart Parking
    Acceptance test for package 22 - Transform Aggregates.

    Read-only script:
      - does not rerun dbo.usp_TransformAggregates;
      - does not change persistent data;
      - recomputes every aggregate group from package-21 Clean rows;
      - returns PASS only when every package-22 check succeeds.
*/

USE DanangSmartParkingSTG;
GO

SET NOCOUNT ON;

/*
    Optional manual override:
      - keep NULL to validate the newest batch;
      - replace NULL with the numeric package batch key, for example 11.
*/
DECLARE @RequestedLoadBatchKey bigint = NULL;

DECLARE @LoadBatchKey bigint = COALESCE
(
    @RequestedLoadBatchKey,
    (
        SELECT TOP (1) LoadBatchKey
        FROM DanangSmartParkingDW.etl.LoadBatch
        ORDER BY LoadBatchKey DESC
    )
);

IF @LoadBatchKey IS NULL
    THROW 52100, 'No LoadBatch row was found.', 1;

DECLARE @Failures TABLE
(
    CheckName nvarchar(200) NOT NULL,
    ActualValue nvarchar(200) NULL,
    ExpectedValue nvarchar(200) NOT NULL
);

DECLARE @ExpectedTraffic TABLE
(
    LoadBatchKey bigint NOT NULL,
    EventDate date NOT NULL,
    HourNumber tinyint NOT NULL,
    RoadID varchar(10) NOT NULL,
    VehicleVolume bigint NOT NULL,
    AvgSpeedKmh decimal(12,4) NULL,
    AvgCongestionIndex decimal(12,6) NULL,
    IllegalParkingObserved bigint NOT NULL,
    PRIMARY KEY (LoadBatchKey, EventDate, HourNumber, RoadID)
);

DECLARE @ExpectedParking TABLE
(
    LoadBatchKey bigint NOT NULL,
    EventDate date NOT NULL,
    RoadID varchar(10) NOT NULL,
    VehicleTypeCode varchar(30) NOT NULL,
    ParkingEventCount bigint NOT NULL,
    IllegalEventCount bigint NOT NULL,
    AvgDurationMin decimal(12,4) NULL,
    OpenEventCount bigint NOT NULL,
    PRIMARY KEY (LoadBatchKey, EventDate, RoadID, VehicleTypeCode)
);

INSERT @ExpectedTraffic
(
    LoadBatchKey, EventDate, HourNumber, RoadID,
    VehicleVolume, AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
)
SELECT
    LoadBatchKey,
    EventDate,
    HourNumber,
    RoadID,
    SUM(CONVERT(bigint, VehicleCount)),
    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), AvgSpeedKmh))),
    CONVERT(decimal(12,6), AVG(CONVERT(decimal(18,6), CongestionIndex))),
    SUM(CONVERT(bigint, IllegalParkingCount))
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1
GROUP BY LoadBatchKey, EventDate, HourNumber, RoadID;

INSERT @ExpectedParking
(
    LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
    ParkingEventCount, IllegalEventCount, AvgDurationMin, OpenEventCount
)
SELECT
    LoadBatchKey,
    EventDate,
    RoadID,
    VehicleTypeCode,
    COUNT_BIG(*),
    SUM
    (
        CASE WHEN IsLegalParking = 0
             THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END
    ),
    CONVERT(decimal(12,4), AVG(CONVERT(decimal(18,6), ParkingDurationMin))),
    SUM(CONVERT(bigint, IsOpenEvent))
FROM transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1
GROUP BY LoadBatchKey, EventDate, RoadID, VehicleTypeCode;

DECLARE @BatchStatus varchar(20);
DECLARE @BatchError nvarchar(2000);
DECLARE @BatchRowsRejected bigint;

SELECT
    @BatchStatus = LoadStatus,
    @BatchError = ErrorMessage,
    @BatchRowsRejected = RowsRejected
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

IF OBJECT_ID(N'dbo.usp_TransformAggregates', N'P') IS NULL
    INSERT @Failures VALUES
        (N'Procedure exists', N'NOT FOUND', N'dbo.usp_TransformAggregates');

IF ISNULL(@BatchStatus, '') <> 'BRONZE_LOADED'
    INSERT @Failures VALUES
        (N'Batch status after package 22', COALESCE(@BatchStatus, N'NULL'), N'BRONZE_LOADED');

IF @BatchError IS NOT NULL
    INSERT @Failures VALUES
        (N'Batch ErrorMessage', LEFT(@BatchError, 200), N'NULL');

IF ISNULL(@BatchRowsRejected, -1) <> 0
    INSERT @Failures VALUES
        (N'Batch extract RowsRejected', CONVERT(nvarchar(30), @BatchRowsRejected), N'0');

DECLARE @TrafficCleanRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.TrafficObservationClean
    WHERE LoadBatchKey = @LoadBatchKey
      AND IsValid = 1
      AND DuplicateRank = 1
);

DECLARE @ParkingCleanRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.ParkingEventClean
    WHERE LoadBatchKey = @LoadBatchKey
      AND IsValid = 1
      AND DuplicateRank = 1
);

IF @TrafficCleanRows <> 16800
    INSERT @Failures VALUES
        (N'Package 21 Traffic Clean input', CONVERT(nvarchar(30), @TrafficCleanRows), N'16800');

IF @ParkingCleanRows <> 4283
    INSERT @Failures VALUES
        (N'Package 21 Parking Clean input', CONVERT(nvarchar(30), @ParkingCleanRows), N'4283');

DECLARE @TrafficSummaryRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.TrafficHourlySummary
    WHERE LoadBatchKey = @LoadBatchKey
);

DECLARE @ParkingSummaryRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.ParkingDailySummary
    WHERE LoadBatchKey = @LoadBatchKey
);

IF @TrafficSummaryRows <> 4200
    INSERT @Failures VALUES
        (N'TrafficHourlySummary rows', CONVERT(nvarchar(30), @TrafficSummaryRows), N'4200');

IF @ParkingSummaryRows <> 513
    INSERT @Failures VALUES
        (N'ParkingDailySummary rows', CONVERT(nvarchar(30), @ParkingSummaryRows), N'513');

DECLARE @ExpectedTrafficMissing bigint =
(
    SELECT COUNT_BIG(*)
    FROM
    (
        SELECT
            LoadBatchKey, EventDate, HourNumber, RoadID,
            VehicleVolume, AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
        FROM @ExpectedTraffic
        EXCEPT
        SELECT
            LoadBatchKey, EventDate, HourNumber, RoadID,
            VehicleVolume, AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
        FROM transform.TrafficHourlySummary
        WHERE LoadBatchKey = @LoadBatchKey
    ) AS MissingRows
);

DECLARE @UnexpectedTrafficRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM
    (
        SELECT
            LoadBatchKey, EventDate, HourNumber, RoadID,
            VehicleVolume, AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
        FROM transform.TrafficHourlySummary
        WHERE LoadBatchKey = @LoadBatchKey
        EXCEPT
        SELECT
            LoadBatchKey, EventDate, HourNumber, RoadID,
            VehicleVolume, AvgSpeedKmh, AvgCongestionIndex, IllegalParkingObserved
        FROM @ExpectedTraffic
    ) AS UnexpectedRows
);

DECLARE @TrafficGroupMismatches bigint =
    @ExpectedTrafficMissing + @UnexpectedTrafficRows;

IF @TrafficGroupMismatches <> 0
    INSERT @Failures VALUES
        (N'Traffic aggregate group/value mismatches',
         CONVERT(nvarchar(30), @TrafficGroupMismatches), N'0');

DECLARE @ExpectedParkingMissing bigint =
(
    SELECT COUNT_BIG(*)
    FROM
    (
        SELECT
            LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
            ParkingEventCount, IllegalEventCount, AvgDurationMin, OpenEventCount
        FROM @ExpectedParking
        EXCEPT
        SELECT
            LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
            ParkingEventCount, IllegalEventCount, AvgDurationMin, OpenEventCount
        FROM transform.ParkingDailySummary
        WHERE LoadBatchKey = @LoadBatchKey
    ) AS MissingRows
);

DECLARE @UnexpectedParkingRows bigint =
(
    SELECT COUNT_BIG(*)
    FROM
    (
        SELECT
            LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
            ParkingEventCount, IllegalEventCount, AvgDurationMin, OpenEventCount
        FROM transform.ParkingDailySummary
        WHERE LoadBatchKey = @LoadBatchKey
        EXCEPT
        SELECT
            LoadBatchKey, EventDate, RoadID, VehicleTypeCode,
            ParkingEventCount, IllegalEventCount, AvgDurationMin, OpenEventCount
        FROM @ExpectedParking
    ) AS UnexpectedRows
);

DECLARE @ParkingGroupMismatches bigint =
    @ExpectedParkingMissing + @UnexpectedParkingRows;

IF @ParkingGroupMismatches <> 0
    INSERT @Failures VALUES
        (N'Parking aggregate group/value mismatches',
         CONVERT(nvarchar(30), @ParkingGroupMismatches), N'0');

DECLARE @VehicleVolume bigint;
DECLARE @TrafficIllegal bigint;
DECLARE @ParkingEvents bigint;
DECLARE @ParkingIllegal bigint;
DECLARE @ParkingOpen bigint;

SELECT
    @VehicleVolume = COALESCE(SUM(VehicleVolume), 0),
    @TrafficIllegal = COALESCE(SUM(IllegalParkingObserved), 0)
FROM transform.TrafficHourlySummary
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    @ParkingEvents = COALESCE(SUM(ParkingEventCount), 0),
    @ParkingIllegal = COALESCE(SUM(IllegalEventCount), 0),
    @ParkingOpen = COALESCE(SUM(OpenEventCount), 0)
FROM transform.ParkingDailySummary
WHERE LoadBatchKey = @LoadBatchKey;

IF @VehicleVolume <> 6596879
    INSERT @Failures VALUES
        (N'Traffic summary vehicle volume', CONVERT(nvarchar(30), @VehicleVolume), N'6596879');

IF @TrafficIllegal <> 9100
    INSERT @Failures VALUES
        (N'Traffic summary illegal observations', CONVERT(nvarchar(30), @TrafficIllegal), N'9100');

IF @ParkingEvents <> 4283
    INSERT @Failures VALUES
        (N'Parking summary event count', CONVERT(nvarchar(30), @ParkingEvents), N'4283');

IF @ParkingIllegal <> 1571
    INSERT @Failures VALUES
        (N'Parking summary illegal count', CONVERT(nvarchar(30), @ParkingIllegal), N'1571');

IF @ParkingOpen <> 64
    INSERT @Failures VALUES
        (N'Parking summary open count', CONVERT(nvarchar(30), @ParkingOpen), N'64');

DECLARE @TrafficDateCount int;
DECLARE @TrafficHourCount int;
DECLARE @TrafficRoadCount int;
DECLARE @ParkingDateCount int;
DECLARE @ParkingRoadCount int;
DECLARE @ParkingVehicleTypeCount int;

SELECT
    @TrafficDateCount = COUNT(DISTINCT EventDate),
    @TrafficHourCount = COUNT(DISTINCT HourNumber),
    @TrafficRoadCount = COUNT(DISTINCT RoadID)
FROM transform.TrafficHourlySummary
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    @ParkingDateCount = COUNT(DISTINCT EventDate),
    @ParkingRoadCount = COUNT(DISTINCT RoadID),
    @ParkingVehicleTypeCount = COUNT(DISTINCT VehicleTypeCode)
FROM transform.ParkingDailySummary
WHERE LoadBatchKey = @LoadBatchKey;

IF @TrafficDateCount <> 7 OR @TrafficHourCount <> 24 OR @TrafficRoadCount <> 25
    INSERT @Failures VALUES
    (
        N'Traffic aggregate dimensional coverage',
        CONCAT(@TrafficDateCount, N' dates/', @TrafficHourCount, N' hours/',
               @TrafficRoadCount, N' roads'),
        N'7 dates/24 hours/25 roads'
    );

IF @ParkingDateCount <> 7 OR @ParkingRoadCount <> 20 OR @ParkingVehicleTypeCount <> 4
    INSERT @Failures VALUES
    (
        N'Parking aggregate dimensional coverage',
        CONCAT(@ParkingDateCount, N' dates/', @ParkingRoadCount, N' roads/',
               @ParkingVehicleTypeCount, N' vehicle types'),
        N'7 dates/20 roads/4 vehicle types'
    );

DECLARE @UnicodeRoadName nvarchar(150);
DECLARE @UnicodeZone nvarchar(100);

SELECT TOP (1)
    @UnicodeRoadName = Road.RoadName,
    @UnicodeZone = Road.AnalysisZone
FROM transform.TrafficHourlySummary AS SummaryRow
JOIN transform.RoadClean AS Road
  ON Road.LoadBatchKey = SummaryRow.LoadBatchKey
 AND Road.RoadID = SummaryRow.RoadID
 AND Road.IsValid = 1
WHERE SummaryRow.LoadBatchKey = @LoadBatchKey
  AND SummaryRow.RoadID = 'RD001'
ORDER BY SummaryRow.EventDate, SummaryRow.HourNumber;

IF @UnicodeRoadName IS NULL
   OR @UnicodeZone IS NULL
   OR @UnicodeRoadName <> N'Trần Phú'
   OR @UnicodeZone <> N'Hải Châu core'
    INSERT @Failures VALUES
    (
        N'Aggregate Unicode checkpoint',
        CONCAT(COALESCE(@UnicodeRoadName, N'NULL'), N' / ', COALESCE(@UnicodeZone, N'NULL')),
        N'Trần Phú / Hải Châu core'
    );

/* Put the overall result and any failures first so they are easy to find in SSMS. */
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM @Failures) THEN 'FAIL' ELSE 'PASS' END
        AS AcceptanceStatus,
    @LoadBatchKey AS LoadBatchKey,
    CASE WHEN EXISTS (SELECT 1 FROM @Failures)
         THEN 'PACKAGE 22 ACCEPTANCE FAILED - review the next result set'
         ELSE 'PACKAGE 22 ACCEPTED - ready for package 23' END AS Message;

IF EXISTS (SELECT 1 FROM @Failures)
BEGIN
    SELECT CheckName, ActualValue, ExpectedValue
    FROM @Failures
    ORDER BY CheckName;
END;

/* Evidence result sets. */
SELECT
    @BatchStatus AS LoadStatus,
    @BatchRowsRejected AS ExtractRejectedRows,
    @BatchError AS ErrorMessage,
    @TrafficCleanRows AS TrafficCleanRows,
    @ParkingCleanRows AS ParkingCleanRows;

SELECT
    @TrafficSummaryRows AS TrafficSummaryRows,
    CONVERT(bigint, 4200) AS ExpectedTrafficSummaryRows,
    @TrafficGroupMismatches AS TrafficGroupMismatches,
    @VehicleVolume AS VehicleVolume,
    @TrafficIllegal AS IllegalParkingObserved,
    @TrafficDateCount AS DateCount,
    @TrafficHourCount AS HourCount,
    @TrafficRoadCount AS RoadCount;

SELECT
    @ParkingSummaryRows AS ParkingSummaryRows,
    CONVERT(bigint, 513) AS ExpectedParkingSummaryRows,
    @ParkingGroupMismatches AS ParkingGroupMismatches,
    @ParkingEvents AS ParkingEventCount,
    @ParkingIllegal AS IllegalEventCount,
    @ParkingOpen AS OpenEventCount,
    @ParkingDateCount AS DateCount,
    @ParkingRoadCount AS RoadCount,
    @ParkingVehicleTypeCount AS VehicleTypeCount;

SELECT
    'RD001' AS RoadID,
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
    THROW 52199, 'PACKAGE 22 ACCEPTANCE FAILED. Review the Failures result set.', 1;
GO

