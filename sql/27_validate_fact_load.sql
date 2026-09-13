/*
    Read-only acceptance for package 40 - Load Facts.
    Keep @RequestedLoadBatchKey NULL to validate the newest SILVER_VALIDATED batch,
    or replace NULL with a numeric batch key such as 18.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;

DECLARE @RequestedLoadBatchKey bigint = NULL;
DECLARE @LoadBatchKey bigint = COALESCE
(
    @RequestedLoadBatchKey,
    (
        SELECT TOP (1) LoadBatchKey
        FROM etl.LoadBatch
        WHERE LoadStatus = 'SILVER_VALIDATED'
        ORDER BY LoadBatchKey DESC
    )
);

IF @LoadBatchKey IS NULL
    THROW 52850, 'No SILVER_VALIDATED batch was found.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus = 'SILVER_VALIDATED'
)
    THROW 52851, 'Requested batch is not SILVER_VALIDATED.', 1;

DECLARE @FactCount TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @FactCount (ObjectName, ActualRows, ExpectedRows)
SELECT N'FactParkingCapacitySnapshot', COUNT_BIG(*), 20
FROM dwh.FactParkingCapacitySnapshot
UNION ALL
SELECT N'FactRoadSurveySnapshot', COUNT_BIG(*), 30
FROM dwh.FactRoadSurveySnapshot
UNION ALL
SELECT N'FactWeatherHourly', COUNT_BIG(*), 168
FROM dwh.FactWeatherHourly
UNION ALL
SELECT N'FactTrafficObservation', COUNT_BIG(*), 16800
FROM dwh.FactTrafficObservation
UNION ALL
SELECT N'FactParkingEvent', COUNT_BIG(*), 4283
FROM dwh.FactParkingEvent;

SELECT
    ObjectName, ActualRows, ExpectedRows,
    CONVERT(bit, CASE WHEN ActualRows = ExpectedRows THEN 1 ELSE 0 END) AS IsMatched
FROM @FactCount
ORDER BY ObjectName;

IF EXISTS (SELECT 1 FROM @FactCount WHERE ActualRows <> ExpectedRows)
    THROW 52852, 'Fact row counts do not match the baseline.', 1;

IF EXISTS
(
    SELECT EventID FROM dwh.FactTrafficObservation
    GROUP BY EventID HAVING COUNT_BIG(*) > 1
)
    THROW 52853, 'Duplicate Traffic EventID was found.', 1;

IF EXISTS
(
    SELECT EventID FROM dwh.FactParkingEvent
    GROUP BY EventID HAVING COUNT_BIG(*) > 1
)
    THROW 52854, 'Duplicate Parking EventID was found.', 1;

IF EXISTS
(
    SELECT WeatherTimestamp FROM dwh.FactWeatherHourly
    GROUP BY WeatherTimestamp HAVING COUNT_BIG(*) > 1
)
    THROW 52855, 'Duplicate WeatherTimestamp was found.', 1;

IF EXISTS
(
    SELECT SnapshotDateKey, ParkingFacilityKey
    FROM dwh.FactParkingCapacitySnapshot
    GROUP BY SnapshotDateKey, ParkingFacilityKey
    HAVING COUNT_BIG(*) > 1
)
    THROW 52856, 'Duplicate Parking Capacity grain was found.', 1;

IF EXISTS
(
    SELECT SnapshotDateKey, SegmentKey
    FROM dwh.FactRoadSurveySnapshot
    GROUP BY SnapshotDateKey, SegmentKey
    HAVING COUNT_BIG(*) > 1
)
    THROW 52857, 'Duplicate Road Survey grain was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM dwh.FactTrafficObservation AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.DateKey
    LEFT JOIN dwh.DimTime AS T ON T.TimeKey = F.TimeKey
    LEFT JOIN dwh.DimTime AS H ON H.TimeKey = F.HourTimeKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    LEFT JOIN dwh.DimCamera AS C ON C.CameraKey = F.CameraKey
    WHERE D.DateKey IS NULL OR T.TimeKey IS NULL OR H.TimeKey IS NULL
       OR S.SegmentKey IS NULL OR C.CameraKey IS NULL
)
    THROW 52858, 'Traffic mandatory orphan was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM dwh.FactParkingEvent AS F
    LEFT JOIN dwh.DimDate AS SD ON SD.DateKey = F.StartDateKey
    LEFT JOIN dwh.DimTime AS ST ON ST.TimeKey = F.StartTimeKey
    LEFT JOIN dwh.DimDate AS ED ON ED.DateKey = F.EndDateKey
    LEFT JOIN dwh.DimTime AS ET ON ET.TimeKey = F.EndTimeKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    LEFT JOIN dwh.DimVehicleType AS V ON V.VehicleTypeKey = F.VehicleTypeKey
    LEFT JOIN dwh.DimRoadSide AS R ON R.RoadSideKey = F.RoadSideKey
    LEFT JOIN dwh.DimParkingRestriction AS P ON P.RestrictionKey = F.RestrictionKey
    WHERE SD.DateKey IS NULL OR ST.TimeKey IS NULL OR S.SegmentKey IS NULL
       OR V.VehicleTypeKey IS NULL OR R.RoadSideKey IS NULL
       OR (F.EndDateKey IS NOT NULL AND ED.DateKey IS NULL)
       OR (F.EndTimeKey IS NOT NULL AND ET.TimeKey IS NULL)
       OR (F.RestrictionKey IS NOT NULL AND P.RestrictionKey IS NULL)
)
    THROW 52859, 'Parking mandatory or populated optional orphan was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM dwh.FactWeatherHourly AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.DateKey
    LEFT JOIN dwh.DimTime AS T ON T.TimeKey = F.TimeKey
    LEFT JOIN dwh.DimWeatherSource AS W
      ON W.WeatherSourceKey = F.WeatherSourceKey
    WHERE D.DateKey IS NULL OR T.TimeKey IS NULL OR W.WeatherSourceKey IS NULL
)
    THROW 52860, 'Weather mandatory orphan was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM dwh.FactParkingCapacitySnapshot AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
    LEFT JOIN dwh.DimParkingFacility AS P
      ON P.ParkingFacilityKey = F.ParkingFacilityKey
    WHERE D.DateKey IS NULL OR P.ParkingFacilityKey IS NULL
)
    THROW 52861, 'Parking Capacity mandatory orphan was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM dwh.FactRoadSurveySnapshot AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
    LEFT JOIN dwh.DimDate AS SD ON SD.DateKey = F.SourceSurveyDateKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    WHERE D.DateKey IS NULL OR S.SegmentKey IS NULL
       OR (F.SourceSurveyDateKey IS NOT NULL AND SD.DateKey IS NULL)
)
    THROW 52862, 'Road Survey mandatory or populated optional orphan was found.', 1;

IF EXISTS
(
    SELECT 1
    FROM etl.RejectedRow AS R
    INNER JOIN etl.LoadFile AS F ON F.LoadFileKey = R.LoadFileKey
    WHERE F.LoadBatchKey = @LoadBatchKey
      AND R.Severity = 'ERROR'
      AND R.RuleCode IN
          ('FACT_CAPACITY_ORPHAN', 'FACT_SURVEY_ORPHAN', 'FACT_WEATHER_ORPHAN',
           'FACT_TRAFFIC_ORPHAN', 'FACT_PARKING_ORPHAN')
)
    THROW 52863, 'Fact-load ERROR rejects exist for the requested batch.', 1;

DECLARE
    @VehicleVolume bigint,
    @MissingSpeed bigint,
    @InvalidMix bigint,
    @InvalidParkingCount bigint,
    @IllegalEvents bigint,
    @OpenEvents bigint,
    @MissingRestriction bigint,
    @Capacity int,
    @ReferenceCapacity int,
    @Rain decimal(18,2),
    @RainyHours int,
    @ImputedWidth int;

SELECT
    @VehicleVolume = SUM(CONVERT(bigint, VehicleCount)),
    @MissingSpeed = SUM(CONVERT(bigint, SpeedMissingFlag)),
    @InvalidMix = SUM(CASE WHEN VehicleMixValidFlag = 0 THEN 1 ELSE 0 END),
    @InvalidParkingCount = SUM(CASE WHEN ParkingCountValidFlag = 0 THEN 1 ELSE 0 END)
FROM dwh.FactTrafficObservation;

SELECT
    @IllegalEvents = SUM(CASE WHEN IsLegalParking = 0 THEN 1 ELSE 0 END),
    @OpenEvents = SUM(CONVERT(bigint, IsOpenEvent)),
    @MissingRestriction = SUM(CASE WHEN RestrictionLinkMissingFlag = 1 THEN 1 ELSE 0 END)
FROM dwh.FactParkingEvent;

SELECT
    @Capacity = SUM(CapacitySpaces),
    @ReferenceCapacity = SUM(CASE WHEN IsReferenceCapacity = 1
                                  THEN CapacitySpaces ELSE 0 END)
FROM dwh.FactParkingCapacitySnapshot
WHERE SnapshotDateKey = 20260805;

SELECT
    @Rain = SUM(RainMm),
    @RainyHours = SUM(CONVERT(int, IsRainyHour))
FROM dwh.FactWeatherHourly;

SELECT @ImputedWidth = SUM(CONVERT(int, WidthImputedFlag))
FROM dwh.FactRoadSurveySnapshot;

IF @VehicleVolume <> 6596879 OR @MissingSpeed <> 161
   OR @InvalidMix <> 3838 OR @InvalidParkingCount <> 781
    THROW 52864, 'Traffic KPI baseline mismatch.', 1;

IF @IllegalEvents <> 1571 OR @OpenEvents <> 64 OR @MissingRestriction <> 607
    THROW 52865, 'Parking KPI baseline mismatch.', 1;

IF @Capacity <> 2267 OR @ReferenceCapacity <> 397
    THROW 52866, 'Capacity KPI baseline mismatch.', 1;

IF @Rain <> CONVERT(decimal(18,2), 47.50) OR @RainyHours <> 11
    THROW 52867, 'Weather KPI baseline mismatch.', 1;

IF @ImputedWidth <> 3
    THROW 52868, 'Road Survey imputation baseline mismatch.', 1;

SELECT
    @LoadBatchKey AS LoadBatchKey,
    (SELECT SUM(ActualRows) FROM @FactCount) AS TotalFactRows,
    @VehicleVolume AS VehicleVolume,
    @IllegalEvents AS IllegalParkingEvents,
    @Capacity AS TotalCapacity,
    @Rain AS TotalRainMm,
    CAST('PASS' AS varchar(10)) AS AcceptanceStatus;
GO
