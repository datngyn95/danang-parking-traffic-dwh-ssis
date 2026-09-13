/*
Project : Da Nang Smart Parking & Traffic Analytics
Package : 40_DATA_FLOW_FACTS / 40_LOAD_FACTS
Purpose : Nghiệm thu 5 Fact sau khi SSIS load xong.
Expected: 20 + 30 + 168 + 16,800 + 4,283 = 21,301 Fact rows.
*/
USE DanangSmartParkingDW;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE
    @ExpectedParkingCapacity bigint = 20,
    @ExpectedRoadSurvey      bigint = 30,
    @ExpectedWeather         bigint = 168,
    @ExpectedTraffic         bigint = 16800,
    @ExpectedParkingEvent    bigint = 4283,
    @ExpectedTotalFact       bigint = 21301;

DECLARE @Check TABLE
(
    CheckOrder    int IDENTITY(1,1),
    CheckGroup    nvarchar(100),
    CheckName     nvarchar(250),
    ActualValue   bigint,
    ExpectedValue bigint,
    [Status]      varchar(10),
    Details       nvarchar(500)
);

-- A. ROW COUNT
INSERT INTO @Check
SELECT N'ROW COUNT', N'FactParkingCapacitySnapshot', COUNT_BIG(*), @ExpectedParkingCapacity,
       CASE WHEN COUNT_BIG(*)=@ExpectedParkingCapacity THEN 'PASS' ELSE 'FAIL' END,
       N'Grain: SnapshotDateKey + ParkingFacilityKey'
FROM dwh.FactParkingCapacitySnapshot;

INSERT INTO @Check
SELECT N'ROW COUNT', N'FactRoadSurveySnapshot', COUNT_BIG(*), @ExpectedRoadSurvey,
       CASE WHEN COUNT_BIG(*)=@ExpectedRoadSurvey THEN 'PASS' ELSE 'FAIL' END,
       N'Grain: SnapshotDateKey + SegmentKey'
FROM dwh.FactRoadSurveySnapshot;

INSERT INTO @Check
SELECT N'ROW COUNT', N'FactWeatherHourly', COUNT_BIG(*), @ExpectedWeather,
       CASE WHEN COUNT_BIG(*)=@ExpectedWeather THEN 'PASS' ELSE 'FAIL' END,
       N'Hourly weather'
FROM dwh.FactWeatherHourly;

INSERT INTO @Check
SELECT N'ROW COUNT', N'FactTrafficObservation', COUNT_BIG(*), @ExpectedTraffic,
       CASE WHEN COUNT_BIG(*)=@ExpectedTraffic THEN 'PASS' ELSE 'FAIL' END,
       N'Business key: EventID'
FROM dwh.FactTrafficObservation;

INSERT INTO @Check
SELECT N'ROW COUNT', N'FactParkingEvent', COUNT_BIG(*), @ExpectedParkingEvent,
       CASE WHEN COUNT_BIG(*)=@ExpectedParkingEvent THEN 'PASS' ELSE 'FAIL' END,
       N'Business key: EventID'
FROM dwh.FactParkingEvent;

DECLARE @ActualTotalFact bigint =
      (SELECT COUNT_BIG(*) FROM dwh.FactParkingCapacitySnapshot)
    + (SELECT COUNT_BIG(*) FROM dwh.FactRoadSurveySnapshot)
    + (SELECT COUNT_BIG(*) FROM dwh.FactWeatherHourly)
    + (SELECT COUNT_BIG(*) FROM dwh.FactTrafficObservation)
    + (SELECT COUNT_BIG(*) FROM dwh.FactParkingEvent);

INSERT INTO @Check
VALUES (N'ROW COUNT', N'Total Fact Rows', @ActualTotalFact, @ExpectedTotalFact,
        CASE WHEN @ActualTotalFact=@ExpectedTotalFact THEN 'PASS' ELSE 'FAIL' END,
        N'Expected total for the 7-day project dataset');

-- B. DUPLICATE / IDEMPOTENCY
INSERT INTO @Check
SELECT N'DUPLICATE', N'FactParkingCapacitySnapshot duplicate grain', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'SnapshotDateKey + ParkingFacilityKey'
FROM (
    SELECT SnapshotDateKey, ParkingFacilityKey
    FROM dwh.FactParkingCapacitySnapshot
    GROUP BY SnapshotDateKey, ParkingFacilityKey
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'FactRoadSurveySnapshot duplicate grain', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'SnapshotDateKey + SegmentKey'
FROM (
    SELECT SnapshotDateKey, SegmentKey
    FROM dwh.FactRoadSurveySnapshot
    GROUP BY SnapshotDateKey, SegmentKey
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'FactWeatherHourly duplicate timestamp', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'WeatherTimestamp'
FROM (
    SELECT WeatherTimestamp
    FROM dwh.FactWeatherHourly
    GROUP BY WeatherTimestamp
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'FactTrafficObservation duplicate EventID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'EventID must be unique'
FROM (
    SELECT EventID
    FROM dwh.FactTrafficObservation
    GROUP BY EventID
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'FactParkingEvent duplicate EventID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'EventID must be unique'
FROM (
    SELECT EventID
    FROM dwh.FactParkingEvent
    GROUP BY EventID
    HAVING COUNT_BIG(*)>1
) X;

-- C. ORPHAN / MISSING DIMENSION KEY
INSERT INTO @Check
SELECT N'ORPHAN FK', N'ParkingCapacity mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'DimDate / DimParkingFacility'
FROM dwh.FactParkingCapacitySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SnapshotDateKey
LEFT JOIN dwh.DimParkingFacility PF ON PF.ParkingFacilityKey=F.ParkingFacilityKey
WHERE F.SnapshotDateKey IS NULL OR DD.DateKey IS NULL
   OR F.ParkingFacilityKey IS NULL OR PF.ParkingFacilityKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'RoadSurvey mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'DimDate / DimRoadSegment'
FROM dwh.FactRoadSurveySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SnapshotDateKey
LEFT JOIN dwh.DimRoadSegment S ON S.SegmentKey=F.SegmentKey
WHERE F.SnapshotDateKey IS NULL OR DD.DateKey IS NULL
   OR F.SegmentKey IS NULL OR S.SegmentKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'RoadSurvey SourceSurveyDateKey optional orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'Only non-NULL SourceSurveyDateKey is checked'
FROM dwh.FactRoadSurveySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SourceSurveyDateKey
WHERE F.SourceSurveyDateKey IS NOT NULL AND DD.DateKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'Weather mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'DimDate / DimTime / DimWeatherSource'
FROM dwh.FactWeatherHourly F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.DateKey
LEFT JOIN dwh.DimTime DT ON DT.TimeKey=F.TimeKey
LEFT JOIN dwh.DimWeatherSource WS ON WS.WeatherSourceKey=F.WeatherSourceKey
WHERE F.DateKey IS NULL OR DD.DateKey IS NULL
   OR F.TimeKey IS NULL OR DT.TimeKey IS NULL
   OR F.WeatherSourceKey IS NULL OR WS.WeatherSourceKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'Traffic mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'DimDate / DimTime / HourTime / Segment / Camera'
FROM dwh.FactTrafficObservation F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.DateKey
LEFT JOIN dwh.DimTime DT ON DT.TimeKey=F.TimeKey
LEFT JOIN dwh.DimTime HT ON HT.TimeKey=F.HourTimeKey
LEFT JOIN dwh.DimRoadSegment S ON S.SegmentKey=F.SegmentKey
LEFT JOIN dwh.DimCamera C ON C.CameraKey=F.CameraKey
WHERE F.DateKey IS NULL OR DD.DateKey IS NULL
   OR F.TimeKey IS NULL OR DT.TimeKey IS NULL
   OR F.HourTimeKey IS NULL OR HT.TimeKey IS NULL
   OR F.SegmentKey IS NULL OR S.SegmentKey IS NULL
   OR F.CameraKey IS NULL OR C.CameraKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'ParkingEvent mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'StartDate / StartTime / Segment / VehicleType / RoadSide'
FROM dwh.FactParkingEvent F
LEFT JOIN dwh.DimDate SD ON SD.DateKey=F.StartDateKey
LEFT JOIN dwh.DimTime ST ON ST.TimeKey=F.StartTimeKey
LEFT JOIN dwh.DimRoadSegment S ON S.SegmentKey=F.SegmentKey
LEFT JOIN dwh.DimVehicleType V ON V.VehicleTypeKey=F.VehicleTypeKey
LEFT JOIN dwh.DimRoadSide RS ON RS.RoadSideKey=F.RoadSideKey
WHERE F.StartDateKey IS NULL OR SD.DateKey IS NULL
   OR F.StartTimeKey IS NULL OR ST.TimeKey IS NULL
   OR F.SegmentKey IS NULL OR S.SegmentKey IS NULL
   OR F.VehicleTypeKey IS NULL OR V.VehicleTypeKey IS NULL
   OR F.RoadSideKey IS NULL OR RS.RoadSideKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'ParkingEvent optional FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END,
       N'EndDateKey / EndTimeKey / RestrictionKey only when non-NULL'
FROM dwh.FactParkingEvent F
LEFT JOIN dwh.DimDate ED ON ED.DateKey=F.EndDateKey
LEFT JOIN dwh.DimTime ET ON ET.TimeKey=F.EndTimeKey
LEFT JOIN dwh.DimParkingRestriction R ON R.RestrictionKey=F.RestrictionKey
WHERE (F.EndDateKey IS NOT NULL AND ED.DateKey IS NULL)
   OR (F.EndTimeKey IS NOT NULL AND ET.TimeKey IS NULL)
   OR (F.RestrictionKey IS NOT NULL AND R.RestrictionKey IS NULL);

-- D. RESULT
SELECT CheckOrder, CheckGroup, CheckName, ActualValue, ExpectedValue, [Status], Details
FROM @Check
ORDER BY CheckOrder;

DECLARE @FailureCount int = (SELECT COUNT(*) FROM @Check WHERE [Status]='FAIL');

SELECT CASE WHEN @FailureCount=0 THEN 'PASS' ELSE 'FAIL' END AS AcceptanceStatus,
       @FailureCount AS FailureCount,
       CASE WHEN @FailureCount=0
            THEN N'PACKAGE 40 FACTS ACCEPTED - ready for final DWH validation'
            ELSE N'PACKAGE 40 FACTS FAILED - review failed checks before package 50'
       END AS [Message];

IF @FailureCount>0
    THROW 54040, 'PACKAGE 40 FACT VALIDATION FAILED. Review result set for details.', 1;
GO
