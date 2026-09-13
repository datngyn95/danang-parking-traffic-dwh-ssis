/*
Purpose: final read-only confirmation that the DWH rows and KPI baseline belong
         to the same SQL Server/SSIS batch selected for the AWS implementation.

Safety: SELECT-only against persistent objects. The script creates table
        variables in the current session, but does not create, update, delete,
        truncate, drop, or execute a stored ETL procedure.

This file is pinned to batch 20 because the first execution against candidate
batch 22 proved that all 21,301 physical Fact rows trace to batch 20. Batch 20 is
therefore the DWH-published baseline; batch 22 is a newer SILVER batch that has
not been loaded into the current DWH Facts. Change the value only when
deliberately validating another DWH release.
*/

SET NOCOUNT ON;

IF DB_ID(N'DanangSmartParkingDW') IS NULL
    THROW 59101, 'DanangSmartParkingDW does not exist.', 1;

USE DanangSmartParkingDW;

DECLARE @LoadBatchKey bigint = 20;

IF NOT EXISTS
(
    SELECT 1
    FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
)
    THROW 59102, 'Requested LoadBatchKey does not exist.', 1;

DECLARE @Checks TABLE
(
    CheckOrder int IDENTITY(1, 1) NOT NULL,
    CheckScope varchar(30) NOT NULL,
    CheckName nvarchar(200) NOT NULL,
    ActualValue nvarchar(200) NOT NULL,
    ExpectedValue nvarchar(200) NOT NULL,
    GateStatus varchar(10) NOT NULL,
    Details nvarchar(1000) NULL
);

/* 1. Batch audit and exact eight-file contract. */
DECLARE
    @BatchStatus varchar(20),
    @RowsRead bigint,
    @RowsAccepted bigint,
    @RowsRejected bigint,
    @CompletedAt datetime2(3);

SELECT
    @BatchStatus = LoadStatus,
    @RowsRead = RowsRead,
    @RowsAccepted = RowsAccepted,
    @RowsRejected = RowsRejected,
    @CompletedAt = CompletedAt
FROM etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
(
    'AUDIT', N'Batch state and row totals',
    CONCAT(@BatchStatus, N'/', @RowsRead, N'/', @RowsAccepted, N'/', @RowsRejected),
    N'SILVER_VALIDATED or COMPLETED / 21500 / 21500 / 0',
    CASE WHEN @BatchStatus IN ('SILVER_VALIDATED', 'COMPLETED')
                   AND @RowsRead = 21500 AND @RowsAccepted = 21500
                   AND @RowsRejected = 0
         THEN 'PASS' ELSE 'FAIL' END,
    N'Batch must remain an accepted source for the fixed AWS baseline.'
),
(
    'AUDIT', N'LoadStatus and CompletedAt lifecycle consistency',
    CONCAT(@BatchStatus, N'/', COALESCE(CONVERT(nvarchar(30), @CompletedAt, 126), N'NULL')),
    N'COMPLETED/non-NULL or non-COMPLETED/NULL',
    CASE WHEN (@BatchStatus = 'COMPLETED' AND @CompletedAt IS NOT NULL)
                   OR (@BatchStatus <> 'COMPLETED' AND @CompletedAt IS NULL)
         THEN 'PASS' ELSE 'WARN' END,
    N'A warning does not invalidate data counts, but the SQL/SSIS audit lifecycle must be reconciled before declaring that pipeline complete.'
);

DECLARE @ExpectedFile TABLE
(
    SourceID char(2) NOT NULL PRIMARY KEY,
    ExpectedRows bigint NOT NULL
);

INSERT @ExpectedFile (SourceID, ExpectedRows)
VALUES
    ('01', 30), ('02', 20), ('03', 18), ('04', 50),
    ('05', 30), ('06', 16884), ('07', 4300), ('08', 168);

DECLARE @FileIssueCount bigint =
(
    SELECT COUNT_BIG(*)
    FROM
    (
        SELECT
            E.SourceID,
            COUNT(L.LoadFileKey) AS RegisteredFiles,
            MAX(CASE WHEN L.ExpectedRowCount = E.ExpectedRows
                          AND L.ActualRowCount = E.ExpectedRows
                          AND L.AcceptedRowCount = E.ExpectedRows
                          AND L.RejectedRowCount = 0
                          AND L.LoadStatus = 'COMPLETED'
                     THEN 1 ELSE 0 END) AS HasAcceptedFile
        FROM @ExpectedFile AS E
        LEFT JOIN etl.LoadFile AS L
          ON L.LoadBatchKey = @LoadBatchKey
         AND L.SourceID = E.SourceID
        GROUP BY E.SourceID
    ) AS F
    WHERE F.RegisteredFiles <> 1 OR F.HasAcceptedFile <> 1
);

SET @FileIssueCount +=
(
    SELECT COUNT_BIG(*)
    FROM etl.LoadFile AS L
    LEFT JOIN @ExpectedFile AS E ON E.SourceID = L.SourceID
    WHERE L.LoadBatchKey = @LoadBatchKey
      AND E.SourceID IS NULL
);

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
(
    'AUDIT', N'Eight source files accepted exactly once',
    CONVERT(nvarchar(30), @FileIssueCount), N'0',
    CASE WHEN @FileIssueCount = 0 THEN 'PASS' ELSE 'FAIL' END,
    N'Each source 01..08 must be COMPLETED with exact expected/actual/accepted counts and zero rejected rows.'
);

/* 2. Dimension and Fact counts. SCD2 dimensions are checked as current rows. */
DECLARE @DimensionCount TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @DimensionCount (ObjectName, ActualRows, ExpectedRows)
SELECT N'DimDate', COUNT_BIG(*), 7 FROM dwh.DimDate
UNION ALL SELECT N'DimTime', COUNT_BIG(*), 1440 FROM dwh.DimTime
UNION ALL SELECT N'DimCity', COUNT_BIG(*), 1 FROM dwh.DimCity
UNION ALL SELECT N'DimRoadSide', COUNT_BIG(*), 5 FROM dwh.DimRoadSide
UNION ALL SELECT N'DimVehicleType', COUNT_BIG(*), 5 FROM dwh.DimVehicleType
UNION ALL SELECT N'DimPOICategory', COUNT_BIG(*), 18 FROM dwh.DimPOICategory
UNION ALL SELECT N'DimWeatherSource', COUNT_BIG(*), 1 FROM dwh.DimWeatherSource
UNION ALL SELECT N'DimAnalysisZone', COUNT_BIG(*), 10 FROM dwh.DimAnalysisZone
UNION ALL SELECT N'DimRoad current', COUNT_BIG(*), 30
    FROM dwh.DimRoad WHERE IsCurrent = 1
UNION ALL SELECT N'DimParkingFacility current', COUNT_BIG(*), 20
    FROM dwh.DimParkingFacility WHERE IsCurrent = 1
UNION ALL SELECT N'DimPOI current', COUNT_BIG(*), 50
    FROM dwh.DimPOI WHERE IsCurrent = 1
UNION ALL SELECT N'DimRoadSegment current', COUNT_BIG(*), 30
    FROM dwh.DimRoadSegment WHERE IsCurrent = 1
UNION ALL SELECT N'DimParkingRestriction current', COUNT_BIG(*), 18
    FROM dwh.DimParkingRestriction WHERE IsCurrent = 1
UNION ALL SELECT N'DimCamera current', COUNT_BIG(*), 25
    FROM dwh.DimCamera WHERE IsCurrent = 1;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
SELECT
    'DWH_COUNT', ObjectName, CONVERT(nvarchar(30), ActualRows),
    CONVERT(nvarchar(30), ExpectedRows),
    CASE WHEN ActualRows = ExpectedRows THEN 'PASS' ELSE 'FAIL' END,
    N'Current-row count is used for SCD2 dimensions.'
FROM @DimensionCount;

DECLARE @FactCount TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @FactCount (ObjectName, ActualRows, ExpectedRows)
SELECT N'FactParkingCapacitySnapshot', COUNT_BIG(*), 20
FROM dwh.FactParkingCapacitySnapshot
UNION ALL SELECT N'FactRoadSurveySnapshot', COUNT_BIG(*), 30
FROM dwh.FactRoadSurveySnapshot
UNION ALL SELECT N'FactWeatherHourly', COUNT_BIG(*), 168
FROM dwh.FactWeatherHourly
UNION ALL SELECT N'FactTrafficObservation', COUNT_BIG(*), 16800
FROM dwh.FactTrafficObservation
UNION ALL SELECT N'FactParkingEvent', COUNT_BIG(*), 4283
FROM dwh.FactParkingEvent;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
SELECT
    'DWH_COUNT', ObjectName, CONVERT(nvarchar(30), ActualRows),
    CONVERT(nvarchar(30), ExpectedRows),
    CASE WHEN ActualRows = ExpectedRows THEN 'PASS' ELSE 'FAIL' END,
    N'Atomic Fact count from the SQL Server DWH.'
FROM @FactCount;

/* 3. Fact provenance must resolve to the selected batch and expected source. */
DECLARE @FactLineage TABLE
(
    ObjectName sysname NOT NULL,
    ExpectedSourceID char(2) NOT NULL,
    LoadFileKey bigint NULL
);

INSERT @FactLineage (ObjectName, ExpectedSourceID, LoadFileKey)
SELECT N'FactParkingCapacitySnapshot', '02', LoadFileKey
FROM dwh.FactParkingCapacitySnapshot
UNION ALL SELECT N'FactRoadSurveySnapshot', '05', LoadFileKey
FROM dwh.FactRoadSurveySnapshot
UNION ALL SELECT N'FactWeatherHourly', '08', LoadFileKey
FROM dwh.FactWeatherHourly
UNION ALL SELECT N'FactTrafficObservation', '06', LoadFileKey
FROM dwh.FactTrafficObservation
UNION ALL SELECT N'FactParkingEvent', '07', LoadFileKey
FROM dwh.FactParkingEvent;

DECLARE @FactLineageIssues bigint =
(
    SELECT COUNT_BIG(*)
    FROM @FactLineage AS F
    LEFT JOIN etl.LoadFile AS L ON L.LoadFileKey = F.LoadFileKey
    WHERE L.LoadFileKey IS NULL
       OR L.LoadBatchKey <> @LoadBatchKey
       OR L.SourceID <> F.ExpectedSourceID
       OR L.LoadStatus <> 'COMPLETED'
);

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
(
    'LINEAGE', N'Fact LoadFileKey provenance',
    CONVERT(nvarchar(30), @FactLineageIssues), N'0',
    CASE WHEN @FactLineageIssues = 0 THEN 'PASS' ELSE 'FAIL' END,
    CONCAT(N'Every Fact row must trace to the expected source file in LoadBatchKey ',
           @LoadBatchKey, N'.')
);

/* 4. Fact grain and mandatory/conditional foreign-key integrity. */
DECLARE @DuplicateFactGrains bigint = 0;

SELECT @DuplicateFactGrains = COALESCE(SUM(DuplicateGrains), 0)
FROM
(
    SELECT COUNT_BIG(*) AS DuplicateGrains FROM
    (
        SELECT SnapshotDateKey, ParkingFacilityKey
        FROM dwh.FactParkingCapacitySnapshot
        GROUP BY SnapshotDateKey, ParkingFacilityKey HAVING COUNT_BIG(*) > 1
    ) AS D1
    UNION ALL SELECT COUNT_BIG(*) FROM
    (
        SELECT SnapshotDateKey, SegmentKey
        FROM dwh.FactRoadSurveySnapshot
        GROUP BY SnapshotDateKey, SegmentKey HAVING COUNT_BIG(*) > 1
    ) AS D2
    UNION ALL SELECT COUNT_BIG(*) FROM
    (
        SELECT WeatherTimestamp
        FROM dwh.FactWeatherHourly
        GROUP BY WeatherTimestamp HAVING COUNT_BIG(*) > 1
    ) AS D3
    UNION ALL SELECT COUNT_BIG(*) FROM
    (
        SELECT EventID
        FROM dwh.FactTrafficObservation
        GROUP BY EventID HAVING COUNT_BIG(*) > 1
    ) AS D4
    UNION ALL SELECT COUNT_BIG(*) FROM
    (
        SELECT EventID
        FROM dwh.FactParkingEvent
        GROUP BY EventID HAVING COUNT_BIG(*) > 1
    ) AS D5
) AS DuplicateChecks;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
(
    'INTEGRITY', N'Duplicate Fact grains',
    CONVERT(nvarchar(30), @DuplicateFactGrains), N'0',
    CASE WHEN @DuplicateFactGrains = 0 THEN 'PASS' ELSE 'FAIL' END,
    N'Checks the five documented atomic grains.'
);

DECLARE @FactOrphans bigint = 0;

SELECT @FactOrphans = COALESCE(SUM(OrphanRows), 0)
FROM
(
    SELECT COUNT_BIG(*) AS OrphanRows
    FROM dwh.FactParkingCapacitySnapshot AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
    LEFT JOIN dwh.DimParkingFacility AS P
      ON P.ParkingFacilityKey = F.ParkingFacilityKey
    WHERE D.DateKey IS NULL OR P.ParkingFacilityKey IS NULL

    UNION ALL
    SELECT COUNT_BIG(*)
    FROM dwh.FactRoadSurveySnapshot AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
    LEFT JOIN dwh.DimDate AS SD ON SD.DateKey = F.SourceSurveyDateKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    WHERE D.DateKey IS NULL OR S.SegmentKey IS NULL
       OR (F.SourceSurveyDateKey IS NOT NULL AND SD.DateKey IS NULL)

    UNION ALL
    SELECT COUNT_BIG(*)
    FROM dwh.FactWeatherHourly AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.DateKey
    LEFT JOIN dwh.DimTime AS T ON T.TimeKey = F.TimeKey
    LEFT JOIN dwh.DimWeatherSource AS W
      ON W.WeatherSourceKey = F.WeatherSourceKey
    WHERE D.DateKey IS NULL OR T.TimeKey IS NULL OR W.WeatherSourceKey IS NULL

    UNION ALL
    SELECT COUNT_BIG(*)
    FROM dwh.FactTrafficObservation AS F
    LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.DateKey
    LEFT JOIN dwh.DimTime AS T ON T.TimeKey = F.TimeKey
    LEFT JOIN dwh.DimTime AS H ON H.TimeKey = F.HourTimeKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    LEFT JOIN dwh.DimCamera AS C ON C.CameraKey = F.CameraKey
    WHERE D.DateKey IS NULL OR T.TimeKey IS NULL OR H.TimeKey IS NULL
       OR S.SegmentKey IS NULL OR C.CameraKey IS NULL

    UNION ALL
    SELECT COUNT_BIG(*)
    FROM dwh.FactParkingEvent AS F
    LEFT JOIN dwh.DimDate AS SD ON SD.DateKey = F.StartDateKey
    LEFT JOIN dwh.DimTime AS ST ON ST.TimeKey = F.StartTimeKey
    LEFT JOIN dwh.DimDate AS ED ON ED.DateKey = F.EndDateKey
    LEFT JOIN dwh.DimTime AS ET ON ET.TimeKey = F.EndTimeKey
    LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
    LEFT JOIN dwh.DimVehicleType AS V ON V.VehicleTypeKey = F.VehicleTypeKey
    LEFT JOIN dwh.DimRoadSide AS RS ON RS.RoadSideKey = F.RoadSideKey
    LEFT JOIN dwh.DimParkingRestriction AS R ON R.RestrictionKey = F.RestrictionKey
    WHERE SD.DateKey IS NULL OR ST.TimeKey IS NULL OR S.SegmentKey IS NULL
       OR V.VehicleTypeKey IS NULL OR RS.RoadSideKey IS NULL
       OR (F.EndDateKey IS NOT NULL AND ED.DateKey IS NULL)
       OR (F.EndTimeKey IS NOT NULL AND ET.TimeKey IS NULL)
       OR (F.RestrictionKey IS NOT NULL AND R.RestrictionKey IS NULL)
) AS OrphanChecks;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
(
    'INTEGRITY', N'Fact foreign-key orphans',
    CONVERT(nvarchar(30), @FactOrphans), N'0',
    CASE WHEN @FactOrphans = 0 THEN 'PASS' ELSE 'FAIL' END,
    N'Optional keys are checked only when populated.'
);

/* 5. Business and documented data-quality KPI reconciliation. */
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
    @Rain decimal(18, 2),
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
    @ReferenceCapacity = SUM(CASE WHEN IsReferenceCapacity = 1 THEN CapacitySpaces ELSE 0 END)
FROM dwh.FactParkingCapacitySnapshot
WHERE SnapshotDateKey = 20260805;

SELECT
    @Rain = SUM(RainMm),
    @RainyHours = SUM(CONVERT(int, IsRainyHour))
FROM dwh.FactWeatherHourly;

SELECT @ImputedWidth = SUM(CONVERT(int, WidthImputedFlag))
FROM dwh.FactRoadSurveySnapshot;

INSERT @Checks
    (CheckScope, CheckName, ActualValue, ExpectedValue, GateStatus, Details)
VALUES
('KPI', N'Traffic vehicle volume', COALESCE(CONVERT(nvarchar(30), @VehicleVolume), N'NULL'), N'6596879',
 CASE WHEN @VehicleVolume = 6596879 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Traffic speed missing', COALESCE(CONVERT(nvarchar(30), @MissingSpeed), N'NULL'), N'161',
 CASE WHEN @MissingSpeed = 161 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Traffic vehicle mix warning', COALESCE(CONVERT(nvarchar(30), @InvalidMix), N'NULL'), N'3838',
 CASE WHEN @InvalidMix = 3838 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Traffic parking-count warning', COALESCE(CONVERT(nvarchar(30), @InvalidParkingCount), N'NULL'), N'781',
 CASE WHEN @InvalidParkingCount = 781 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Illegal parking events', COALESCE(CONVERT(nvarchar(30), @IllegalEvents), N'NULL'), N'1571',
 CASE WHEN @IllegalEvents = 1571 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Open parking events', COALESCE(CONVERT(nvarchar(30), @OpenEvents), N'NULL'), N'64',
 CASE WHEN @OpenEvents = 64 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Illegal parking without restriction', COALESCE(CONVERT(nvarchar(30), @MissingRestriction), N'NULL'), N'607',
 CASE WHEN @MissingRestriction = 607 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Total/reference parking capacity', CONCAT(@Capacity, N'/', @ReferenceCapacity), N'2267/397',
 CASE WHEN @Capacity = 2267 AND @ReferenceCapacity = 397 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Total rain/rainy hours', CONCAT(@Rain, N'/', @RainyHours), N'47.50/11',
 CASE WHEN @Rain = CONVERT(decimal(18, 2), 47.50) AND @RainyHours = 11 THEN 'PASS' ELSE 'FAIL' END, NULL),
('KPI', N'Road width imputed', COALESCE(CONVERT(nvarchar(30), @ImputedWidth), N'NULL'), N'3',
 CASE WHEN @ImputedWidth = 3 THEN 'PASS' ELSE 'FAIL' END, NULL);

/* Result grid 1: selected batch. */
SELECT
    LoadBatchKey, LoadStatus, RowsRead, RowsAccepted, RowsRejected,
    StartedAt, CompletedAt, ErrorMessage
FROM etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

/* Result grid 2: exact source-file audit. */
SELECT
    E.SourceID,
    E.ExpectedRows,
    L.LoadFileKey,
    L.FileName,
    L.ActualRowCount,
    L.AcceptedRowCount,
    L.RejectedRowCount,
    L.LoadStatus
FROM @ExpectedFile AS E
LEFT JOIN etl.LoadFile AS L
  ON L.LoadBatchKey = @LoadBatchKey
 AND L.SourceID = E.SourceID
ORDER BY E.SourceID, L.LoadFileKey;

/* Result grid 3: Fact lineage grouped by DWH table and audit file. */
SELECT
    F.ObjectName,
    F.ExpectedSourceID,
    F.LoadFileKey,
    L.LoadBatchKey,
    L.SourceID AS ActualSourceID,
    COUNT_BIG(*) AS FactRows,
    CASE WHEN L.LoadBatchKey = @LoadBatchKey
                   AND L.SourceID = F.ExpectedSourceID
                   AND L.LoadStatus = 'COMPLETED'
         THEN 'PASS' ELSE 'FAIL' END AS LineageStatus
FROM @FactLineage AS F
LEFT JOIN etl.LoadFile AS L ON L.LoadFileKey = F.LoadFileKey
GROUP BY
    F.ObjectName, F.ExpectedSourceID, F.LoadFileKey,
    L.LoadBatchKey, L.SourceID, L.LoadStatus
ORDER BY F.ObjectName, F.LoadFileKey;

/* Result grid 4: every acceptance check. */
SELECT
    CheckOrder, CheckScope, CheckName, ActualValue, ExpectedValue,
    GateStatus, Details
FROM @Checks
ORDER BY CheckOrder;

/* Result grid 5: authoritative result for adopting this DB baseline on AWS. */
DECLARE @FailureCount int =
    (SELECT COUNT(*) FROM @Checks WHERE GateStatus = 'FAIL');
DECLARE @WarningCount int =
    (SELECT COUNT(*) FROM @Checks WHERE GateStatus = 'WARN');

SELECT
    @LoadBatchKey AS LoadBatchKey,
    (SELECT SUM(ActualRows) FROM @FactCount) AS TotalFactRows,
    @FailureCount AS FailureCount,
    @WarningCount AS WarningCount,
    CASE
        WHEN @FailureCount > 0 THEN 'FAIL'
        WHEN @WarningCount > 0 THEN 'PASS_WITH_WARNING'
        ELSE 'PASS'
    END AS AwsBaselineStatus,
    CASE
        WHEN @FailureCount > 0
            THEN N'DO_NOT_ADOPT_AS_AWS_BASELINE'
        WHEN @WarningCount > 0
            THEN N'ADOPT_DATA_BASELINE; RECONCILE_SQL_AUDIT_LIFECYCLE'
        ELSE N'ADOPT_AS_AWS_BASELINE'
    END AS Decision;
