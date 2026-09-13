/*
    Read-only precheck for package 40 - Load Facts.
    Keep @RequestedLoadBatchKey NULL to inspect the newest SILVER_VALIDATED batch,
    or replace NULL with a numeric batch key such as 18.
*/

USE DanangSmartParkingDW;
GO

SET NOCOUNT ON;

DECLARE @RequestedLoadBatchKey bigint = NULL;
DECLARE @SnapshotAt datetime2(3) = CONVERT(datetime2(3), '2026-08-05T00:00:00');

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
    THROW 52750, 'No SILVER_VALIDATED batch was found.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus = 'SILVER_VALIDATED'
)
    THROW 52751, 'Requested batch is not SILVER_VALIDATED.', 1;

DECLARE @SourceCount TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @SourceCount (ObjectName, ActualRows, ExpectedRows)
SELECT N'ParkingFacilityClean', COUNT_BIG(*), 20
FROM DanangSmartParkingSTG.transform.ParkingFacilityClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
UNION ALL
SELECT N'RoadSurveyClean', COUNT_BIG(*), 30
FROM DanangSmartParkingSTG.transform.RoadSurveyClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
UNION ALL
SELECT N'WeatherHourlyClean', COUNT_BIG(*), 168
FROM DanangSmartParkingSTG.transform.WeatherHourlyClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
UNION ALL
SELECT N'TrafficObservationClean', COUNT_BIG(*), 16800
FROM DanangSmartParkingSTG.transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
UNION ALL
SELECT N'ParkingEventClean', COUNT_BIG(*), 4283
FROM DanangSmartParkingSTG.transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1;

SELECT
    ObjectName, ActualRows, ExpectedRows,
    CONVERT(bit, CASE WHEN ActualRows = ExpectedRows THEN 1 ELSE 0 END) AS IsMatched
FROM @SourceCount
ORDER BY ObjectName;

IF EXISTS (SELECT 1 FROM @SourceCount WHERE ActualRows <> ExpectedRows)
    THROW 52752, 'Fact source counts do not match the baseline.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM dwh.DimDate
    WHERE DateValue = CONVERT(date, @SnapshotAt)
)
    THROW 52753, 'Snapshot date is missing from DimDate.', 1;

IF EXISTS
(
    SELECT 1
    FROM DanangSmartParkingSTG.transform.ParkingFacilityClean AS P
    WHERE P.LoadBatchKey = @LoadBatchKey
      AND P.IsValid = 1
      AND
      (
          SELECT COUNT_BIG(*)
          FROM dwh.DimParkingFacility AS D
          WHERE D.ParkingID = P.ParkingID
            AND @SnapshotAt >= D.ValidFrom
            AND (@SnapshotAt < D.ValidTo OR D.ValidTo IS NULL)
      ) <> 1
)
    THROW 52754, 'A ParkingFacility business key does not resolve to exactly one effective dimension row.', 1;

IF EXISTS
(
    SELECT 1
    FROM DanangSmartParkingSTG.transform.RoadSurveyClean AS R
    WHERE R.LoadBatchKey = @LoadBatchKey
      AND R.IsValid = 1
      AND
      (
          SELECT COUNT_BIG(*)
          FROM dwh.DimRoadSegment AS D
          WHERE D.SegmentID = R.SegmentID
            AND @SnapshotAt >= D.ValidFrom
            AND (@SnapshotAt < D.ValidTo OR D.ValidTo IS NULL)
      ) <> 1
)
    THROW 52755, 'A RoadSurvey SegmentID does not resolve to exactly one effective dimension row.', 1;

IF EXISTS
(
    SELECT 1
    FROM DanangSmartParkingSTG.transform.WeatherHourlyClean AS W
    WHERE W.LoadBatchKey = @LoadBatchKey
      AND W.IsValid = 1
      AND
      (
          NOT EXISTS (SELECT 1 FROM dwh.DimDate AS D WHERE D.DateValue = W.EventDate)
          OR NOT EXISTS
             (SELECT 1 FROM dwh.DimTime AS T
              WHERE T.Hour24 = W.HourNumber AND T.MinuteNumber = 0)
          OR (SELECT COUNT_BIG(*) FROM dwh.DimWeatherSource AS S
              WHERE S.TemperatureStatus = W.TemperatureStatus
                AND S.PrecipitationStatus = W.PrecipitationStatus
                AND S.SourceReference = W.SourceReference) <> 1
      )
)
    THROW 52756, 'A Weather row cannot resolve a required dimension.', 1;

IF EXISTS
(
    SELECT 1
    FROM DanangSmartParkingSTG.transform.TrafficObservationClean AS T
    WHERE T.LoadBatchKey = @LoadBatchKey
      AND T.IsValid = 1
      AND T.DuplicateRank = 1
      AND
      (
          NOT EXISTS (SELECT 1 FROM dwh.DimDate AS D WHERE D.DateValue = T.EventDate)
          OR NOT EXISTS
             (SELECT 1 FROM dwh.DimTime AS M
              WHERE M.TimeValue = CONVERT(time(0), DATEADD(MINUTE,
                    DATEDIFF(MINUTE, 0, T.EventTimestamp), 0)))
          OR (SELECT COUNT_BIG(*) FROM dwh.DimRoadSegment AS S
              WHERE S.SegmentID = T.SegmentID
                AND T.EventTimestamp >= S.ValidFrom
                AND (T.EventTimestamp < S.ValidTo OR S.ValidTo IS NULL)) <> 1
          OR (SELECT COUNT_BIG(*) FROM dwh.DimCamera AS C
              WHERE C.CameraID = T.CameraID
                AND T.EventTimestamp >= C.ValidFrom
                AND (T.EventTimestamp < C.ValidTo OR C.ValidTo IS NULL)) <> 1
      )
)
    THROW 52757, 'A Traffic row cannot resolve a required dimension.', 1;

IF EXISTS
(
    SELECT 1
    FROM DanangSmartParkingSTG.transform.ParkingEventClean AS P
    WHERE P.LoadBatchKey = @LoadBatchKey
      AND P.IsValid = 1
      AND P.DuplicateRank = 1
      AND
      (
          NOT EXISTS
             (SELECT 1 FROM dwh.DimDate AS D
              WHERE D.DateValue = CONVERT(date, P.StartTimestamp))
          OR NOT EXISTS
             (SELECT 1 FROM dwh.DimTime AS T
              WHERE T.TimeValue = CONVERT(time(0), DATEADD(MINUTE,
                    DATEDIFF(MINUTE, 0, P.StartTimestamp), 0)))
          OR (SELECT COUNT_BIG(*) FROM dwh.DimRoadSegment AS S
              WHERE S.SegmentID = P.SegmentID
                AND P.StartTimestamp >= S.ValidFrom
                AND (P.StartTimestamp < S.ValidTo OR S.ValidTo IS NULL)) <> 1
          OR NOT EXISTS
             (SELECT 1 FROM dwh.DimVehicleType AS V
              WHERE V.VehicleTypeCode = P.VehicleTypeCode)
          OR NOT EXISTS
             (SELECT 1 FROM dwh.DimRoadSide AS R
              WHERE R.SideCode = P.SideCode)
      )
)
    THROW 52758, 'A Parking row cannot resolve a required dimension.', 1;

SELECT
    @LoadBatchKey AS LoadBatchKey,
    CONVERT(varchar(10), @SnapshotAt, 23) AS SnapshotDate,
    CAST('PASS' AS varchar(10)) AS PrecheckStatus;
GO
