/*
Project : Da Nang Smart Parking & Traffic Analytics
Package : 50_FINAL_DWH_VALIDATION
Purpose : Kiểm tra cuối toàn bộ DWH trước reporting / Complete Batch.

Acceptance:
- 14 Dimension tables
- 5 Fact tables
- Fact counts: 20 / 30 / 168 / 16,800 / 4,283
- Total Fact rows = 21,301
- Duplicate Fact = 0
- Mandatory FK orphan = 0
- Date/Time inconsistency = 0
- Duplicate current business key của Dimension SCD2 = 0
- Final status: FINAL DWH ACCEPTED - READY FOR REPORTING
*/
USE DanangSmartParkingDW;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE
    @ExpectedDimensionTables bigint = 14,
    @ExpectedFactTables      bigint = 5,
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

-- A. REQUIRED TABLES
DECLARE @DimensionTableCount bigint =
(
    SELECT COUNT_BIG(*)
    FROM (VALUES
        (N'DimDate'), (N'DimTime'), (N'DimCity'), (N'DimRoadSide'),
        (N'DimVehicleType'), (N'DimPOICategory'), (N'DimWeatherSource'),
        (N'DimAnalysisZone'), (N'DimRoad'), (N'DimParkingFacility'),
        (N'DimPOI'), (N'DimRoadSegment'), (N'DimParkingRestriction'),
        (N'DimCamera')
    ) V(TableName)
    WHERE OBJECT_ID(N'dwh.' + V.TableName, N'U') IS NOT NULL
);

DECLARE @FactTableCount bigint =
(
    SELECT COUNT_BIG(*)
    FROM (VALUES
        (N'FactParkingCapacitySnapshot'),
        (N'FactRoadSurveySnapshot'),
        (N'FactWeatherHourly'),
        (N'FactTrafficObservation'),
        (N'FactParkingEvent')
    ) V(TableName)
    WHERE OBJECT_ID(N'dwh.' + V.TableName, N'U') IS NOT NULL
);

INSERT INTO @Check
VALUES (N'SCHEMA', N'Required Dimension tables', @DimensionTableCount, @ExpectedDimensionTables,
        CASE WHEN @DimensionTableCount=@ExpectedDimensionTables THEN 'PASS' ELSE 'FAIL' END,
        N'Expected 14 Dimension tables');

INSERT INTO @Check
VALUES (N'SCHEMA', N'Required Fact tables', @FactTableCount, @ExpectedFactTables,
        CASE WHEN @FactTableCount=@ExpectedFactTables THEN 'PASS' ELSE 'FAIL' END,
        N'Expected 5 Fact tables');

-- B. FACT COUNTS
INSERT INTO @Check
SELECT N'FACT COUNT', N'FactParkingCapacitySnapshot', COUNT_BIG(*), @ExpectedParkingCapacity,
       CASE WHEN COUNT_BIG(*)=@ExpectedParkingCapacity THEN 'PASS' ELSE 'FAIL' END, N'Expected 20'
FROM dwh.FactParkingCapacitySnapshot;

INSERT INTO @Check
SELECT N'FACT COUNT', N'FactRoadSurveySnapshot', COUNT_BIG(*), @ExpectedRoadSurvey,
       CASE WHEN COUNT_BIG(*)=@ExpectedRoadSurvey THEN 'PASS' ELSE 'FAIL' END, N'Expected 30'
FROM dwh.FactRoadSurveySnapshot;

INSERT INTO @Check
SELECT N'FACT COUNT', N'FactWeatherHourly', COUNT_BIG(*), @ExpectedWeather,
       CASE WHEN COUNT_BIG(*)=@ExpectedWeather THEN 'PASS' ELSE 'FAIL' END, N'Expected 168'
FROM dwh.FactWeatherHourly;

INSERT INTO @Check
SELECT N'FACT COUNT', N'FactTrafficObservation', COUNT_BIG(*), @ExpectedTraffic,
       CASE WHEN COUNT_BIG(*)=@ExpectedTraffic THEN 'PASS' ELSE 'FAIL' END, N'Expected 16,800'
FROM dwh.FactTrafficObservation;

INSERT INTO @Check
SELECT N'FACT COUNT', N'FactParkingEvent', COUNT_BIG(*), @ExpectedParkingEvent,
       CASE WHEN COUNT_BIG(*)=@ExpectedParkingEvent THEN 'PASS' ELSE 'FAIL' END, N'Expected 4,283'
FROM dwh.FactParkingEvent;

DECLARE @ActualTotalFact bigint =
      (SELECT COUNT_BIG(*) FROM dwh.FactParkingCapacitySnapshot)
    + (SELECT COUNT_BIG(*) FROM dwh.FactRoadSurveySnapshot)
    + (SELECT COUNT_BIG(*) FROM dwh.FactWeatherHourly)
    + (SELECT COUNT_BIG(*) FROM dwh.FactTrafficObservation)
    + (SELECT COUNT_BIG(*) FROM dwh.FactParkingEvent);

INSERT INTO @Check
VALUES (N'FACT COUNT', N'Total Fact rows', @ActualTotalFact, @ExpectedTotalFact,
        CASE WHEN @ActualTotalFact=@ExpectedTotalFact THEN 'PASS' ELSE 'FAIL' END,
        N'Expected final total = 21,301');

-- C. DUPLICATE FACT
INSERT INTO @Check
SELECT N'DUPLICATE', N'ParkingCapacity duplicate grain', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'SnapshotDateKey + ParkingFacilityKey'
FROM (
    SELECT SnapshotDateKey, ParkingFacilityKey
    FROM dwh.FactParkingCapacitySnapshot
    GROUP BY SnapshotDateKey, ParkingFacilityKey
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'RoadSurvey duplicate grain', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'SnapshotDateKey + SegmentKey'
FROM (
    SELECT SnapshotDateKey, SegmentKey
    FROM dwh.FactRoadSurveySnapshot
    GROUP BY SnapshotDateKey, SegmentKey
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'Weather duplicate timestamp', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'WeatherTimestamp'
FROM (
    SELECT WeatherTimestamp
    FROM dwh.FactWeatherHourly
    GROUP BY WeatherTimestamp
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'Traffic duplicate EventID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'EventID'
FROM (
    SELECT EventID
    FROM dwh.FactTrafficObservation
    GROUP BY EventID
    HAVING COUNT_BIG(*)>1
) X;

INSERT INTO @Check
SELECT N'DUPLICATE', N'ParkingEvent duplicate EventID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'EventID'
FROM (
    SELECT EventID
    FROM dwh.FactParkingEvent
    GROUP BY EventID
    HAVING COUNT_BIG(*)>1
) X;

-- D. FACT -> DIMENSION ORPHAN
INSERT INTO @Check
SELECT N'ORPHAN FK', N'ParkingCapacity mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'DimDate / DimParkingFacility'
FROM dwh.FactParkingCapacitySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SnapshotDateKey
LEFT JOIN dwh.DimParkingFacility PF ON PF.ParkingFacilityKey=F.ParkingFacilityKey
WHERE F.SnapshotDateKey IS NULL OR DD.DateKey IS NULL
   OR F.ParkingFacilityKey IS NULL OR PF.ParkingFacilityKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'RoadSurvey mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'DimDate / DimRoadSegment'
FROM dwh.FactRoadSurveySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SnapshotDateKey
LEFT JOIN dwh.DimRoadSegment S ON S.SegmentKey=F.SegmentKey
WHERE F.SnapshotDateKey IS NULL OR DD.DateKey IS NULL
   OR F.SegmentKey IS NULL OR S.SegmentKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'RoadSurvey optional SourceSurveyDateKey orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'Only when SourceSurveyDateKey is non-NULL'
FROM dwh.FactRoadSurveySnapshot F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.SourceSurveyDateKey
WHERE F.SourceSurveyDateKey IS NOT NULL AND DD.DateKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'Weather mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'DimDate / DimTime / DimWeatherSource'
FROM dwh.FactWeatherHourly F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.DateKey
LEFT JOIN dwh.DimTime DT ON DT.TimeKey=F.TimeKey
LEFT JOIN dwh.DimWeatherSource WS ON WS.WeatherSourceKey=F.WeatherSourceKey
WHERE F.DateKey IS NULL OR DD.DateKey IS NULL
   OR F.TimeKey IS NULL OR DT.TimeKey IS NULL
   OR F.WeatherSourceKey IS NULL OR WS.WeatherSourceKey IS NULL;

INSERT INTO @Check
SELECT N'ORPHAN FK', N'Traffic mandatory FK orphan', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'Date / Time / HourTime / Segment / Camera'
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
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'StartDate / StartTime / Segment / VehicleType / RoadSide'
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
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'EndDate / EndTime / Restriction only when non-NULL'
FROM dwh.FactParkingEvent F
LEFT JOIN dwh.DimDate ED ON ED.DateKey=F.EndDateKey
LEFT JOIN dwh.DimTime ET ON ET.TimeKey=F.EndTimeKey
LEFT JOIN dwh.DimParkingRestriction R ON R.RestrictionKey=F.RestrictionKey
WHERE (F.EndDateKey IS NOT NULL AND ED.DateKey IS NULL)
   OR (F.EndTimeKey IS NOT NULL AND ET.TimeKey IS NULL)
   OR (F.RestrictionKey IS NOT NULL AND R.RestrictionKey IS NULL);

-- E. DATE / TIME CONSISTENCY
INSERT INTO @Check
SELECT N'DATE/TIME', N'Weather DateKey/TimeKey consistency', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'WeatherTimestamp vs DimDate + DimTime'
FROM dwh.FactWeatherHourly F
JOIN dwh.DimDate DD ON DD.DateKey=F.DateKey
JOIN dwh.DimTime DT ON DT.TimeKey=F.TimeKey
WHERE DD.DateValue<>CAST(F.WeatherTimestamp AS date)
   OR DT.Hour24<>DATEPART(HOUR,F.WeatherTimestamp)
   OR DT.MinuteNumber<>DATEPART(MINUTE,F.WeatherTimestamp);

INSERT INTO @Check
SELECT N'DATE/TIME', N'Traffic DateKey/TimeKey/HourTimeKey consistency', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'EventTimestamp vs date/time keys'
FROM dwh.FactTrafficObservation F
JOIN dwh.DimDate DD ON DD.DateKey=F.DateKey
JOIN dwh.DimTime DT ON DT.TimeKey=F.TimeKey
JOIN dwh.DimTime HT ON HT.TimeKey=F.HourTimeKey
WHERE DD.DateValue<>CAST(F.EventTimestamp AS date)
   OR DT.Hour24<>DATEPART(HOUR,F.EventTimestamp)
   OR DT.MinuteNumber<>DATEPART(MINUTE,F.EventTimestamp)
   OR HT.Hour24<>DATEPART(HOUR,F.EventTimestamp)
   OR HT.MinuteNumber<>0;

INSERT INTO @Check
SELECT N'DATE/TIME', N'ParkingEvent start Date/Time consistency', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'StartTimestamp vs StartDateKey + StartTimeKey'
FROM dwh.FactParkingEvent F
JOIN dwh.DimDate DD ON DD.DateKey=F.StartDateKey
JOIN dwh.DimTime DT ON DT.TimeKey=F.StartTimeKey
WHERE DD.DateValue<>CAST(F.StartTimestamp AS date)
   OR DT.Hour24<>DATEPART(HOUR,F.StartTimestamp)
   OR DT.MinuteNumber<>DATEPART(MINUTE,F.StartTimestamp);

INSERT INTO @Check
SELECT N'DATE/TIME', N'ParkingEvent end Date/Time consistency', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'Open event may have NULL end keys; closed event must match timestamp'
FROM dwh.FactParkingEvent F
LEFT JOIN dwh.DimDate DD ON DD.DateKey=F.EndDateKey
LEFT JOIN dwh.DimTime DT ON DT.TimeKey=F.EndTimeKey
WHERE (F.EndTimestamp IS NULL AND (F.EndDateKey IS NOT NULL OR F.EndTimeKey IS NOT NULL))
   OR (F.EndTimestamp IS NOT NULL AND (
          F.EndDateKey IS NULL OR F.EndTimeKey IS NULL
       OR DD.DateKey IS NULL OR DT.TimeKey IS NULL
       OR DD.DateValue<>CAST(F.EndTimestamp AS date)
       OR DT.Hour24<>DATEPART(HOUR,F.EndTimestamp)
       OR DT.MinuteNumber<>DATEPART(MINUTE,F.EndTimestamp)
   ));

-- F. DIMENSION SCD2 - DUPLICATE CURRENT BUSINESS KEY
INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimRoad duplicate current RoadID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per RoadID'
FROM (SELECT RoadID FROM dwh.DimRoad WHERE IsCurrent=1 GROUP BY RoadID HAVING COUNT_BIG(*)>1) X;

INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimParkingFacility duplicate current ParkingID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per ParkingID'
FROM (SELECT ParkingID FROM dwh.DimParkingFacility WHERE IsCurrent=1 GROUP BY ParkingID HAVING COUNT_BIG(*)>1) X;

INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimPOI duplicate current POIID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per POIID'
FROM (SELECT POIID FROM dwh.DimPOI WHERE IsCurrent=1 GROUP BY POIID HAVING COUNT_BIG(*)>1) X;

INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimRoadSegment duplicate current SegmentID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per SegmentID'
FROM (SELECT SegmentID FROM dwh.DimRoadSegment WHERE IsCurrent=1 GROUP BY SegmentID HAVING COUNT_BIG(*)>1) X;

INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimParkingRestriction duplicate current RestrictionID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per RestrictionID'
FROM (SELECT RestrictionID FROM dwh.DimParkingRestriction WHERE IsCurrent=1 GROUP BY RestrictionID HAVING COUNT_BIG(*)>1) X;

INSERT INTO @Check
SELECT N'DIM CURRENT', N'DimCamera duplicate current CameraID', COUNT_BIG(*), 0,
       CASE WHEN COUNT_BIG(*)=0 THEN 'PASS' ELSE 'FAIL' END, N'One current version per CameraID'
FROM (SELECT CameraID FROM dwh.DimCamera WHERE IsCurrent=1 GROUP BY CameraID HAVING COUNT_BIG(*)>1) X;

-- G. FINAL RESULT
SELECT CheckOrder, CheckGroup, CheckName, ActualValue, ExpectedValue, [Status], Details
FROM @Check
ORDER BY CheckOrder;

DECLARE @FailureCount int = (SELECT COUNT(*) FROM @Check WHERE [Status]='FAIL');

SELECT
    @DimensionTableCount AS DimensionTables,
    @FactTableCount AS FactTables,
    @ActualTotalFact AS FactRows,
    @FailureCount AS FailureCount,
    CASE WHEN @FailureCount=0
         THEN N'FINAL DWH ACCEPTED - READY FOR REPORTING'
         ELSE N'FINAL DWH VALIDATION FAILED - DO NOT COMPLETE BATCH'
    END AS FinalStatus;

IF @FailureCount>0
    THROW 55050, 'FINAL DWH VALIDATION FAILED. Review failed checks before Complete Batch.', 1;
GO
