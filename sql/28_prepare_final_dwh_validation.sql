/*
    Install the final structural DWH gate used by 50_Final_DWH_Validation.dtsx.
    This procedure validates metadata, Dimension/Fact counts, grain and foreign keys.
    It does not load, update or delete business data.
*/

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateFinalDWH
    @LoadBatchKey bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ResolvedLoadBatchKey bigint = COALESCE
    (
        @LoadBatchKey,
        (
            SELECT TOP (1) LoadBatchKey
            FROM etl.LoadBatch
            WHERE LoadStatus = 'SILVER_VALIDATED'
            ORDER BY LoadBatchKey DESC
        )
    );

    IF @ResolvedLoadBatchKey IS NULL
        THROW 52900, 'FINAL DWH FAILED - no SILVER_VALIDATED batch was found.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @ResolvedLoadBatchKey
          AND LoadStatus = 'SILVER_VALIDATED'
    )
        THROW 52901, 'FINAL DWH FAILED - requested batch is not SILVER_VALIDATED.', 1;

    DECLARE @RequiredTable TABLE
    (
        SchemaName sysname NOT NULL,
        TableName sysname NOT NULL,
        ObjectRole varchar(20) NOT NULL
    );

    INSERT @RequiredTable (SchemaName, TableName, ObjectRole)
    VALUES
        (N'dwh', N'DimDate', N'DIMENSION'),
        (N'dwh', N'DimTime', N'DIMENSION'),
        (N'dwh', N'DimCity', N'DIMENSION'),
        (N'dwh', N'DimRoadSide', N'DIMENSION'),
        (N'dwh', N'DimVehicleType', N'DIMENSION'),
        (N'dwh', N'DimPOICategory', N'DIMENSION'),
        (N'dwh', N'DimWeatherSource', N'DIMENSION'),
        (N'dwh', N'DimAnalysisZone', N'DIMENSION'),
        (N'dwh', N'DimRoad', N'DIMENSION'),
        (N'dwh', N'DimParkingFacility', N'DIMENSION'),
        (N'dwh', N'DimPOI', N'DIMENSION'),
        (N'dwh', N'DimRoadSegment', N'DIMENSION'),
        (N'dwh', N'DimParkingRestriction', N'DIMENSION'),
        (N'dwh', N'DimCamera', N'DIMENSION'),
        (N'dwh', N'FactParkingCapacitySnapshot', N'FACT'),
        (N'dwh', N'FactRoadSurveySnapshot', N'FACT'),
        (N'dwh', N'FactWeatherHourly', N'FACT'),
        (N'dwh', N'FactTrafficObservation', N'FACT'),
        (N'dwh', N'FactParkingEvent', N'FACT');

    IF EXISTS
    (
        SELECT 1
        FROM @RequiredTable AS R
        WHERE OBJECT_ID(QUOTENAME(R.SchemaName) + N'.' + QUOTENAME(R.TableName), N'U')
              IS NULL
    )
        THROW 52902, 'FINAL DWH FAILED - one or more required tables are missing.', 1;

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

    IF EXISTS (SELECT 1 FROM @DimensionCount WHERE ActualRows <> ExpectedRows)
        THROW 52903, 'FINAL DWH FAILED - Dimension counts do not match the baseline.', 1;

    IF NOT EXISTS
       (SELECT 1 FROM dwh.DimRoadSide WHERE RoadSideKey = 0 AND SideCode = 'UNKNOWN')
       OR NOT EXISTS
       (SELECT 1 FROM dwh.DimVehicleType
        WHERE VehicleTypeKey = 0 AND VehicleTypeCode = 'UNKNOWN')
        THROW 52904, 'FINAL DWH FAILED - required reference Unknown members are missing.', 1;

    IF EXISTS
    (
        SELECT RoadID FROM dwh.DimRoad WHERE IsCurrent = 1
        GROUP BY RoadID HAVING COUNT_BIG(*) > 1
        UNION ALL
        SELECT ParkingID FROM dwh.DimParkingFacility WHERE IsCurrent = 1
        GROUP BY ParkingID HAVING COUNT_BIG(*) > 1
        UNION ALL
        SELECT POIID FROM dwh.DimPOI WHERE IsCurrent = 1
        GROUP BY POIID HAVING COUNT_BIG(*) > 1
        UNION ALL
        SELECT SegmentID FROM dwh.DimRoadSegment WHERE IsCurrent = 1
        GROUP BY SegmentID HAVING COUNT_BIG(*) > 1
        UNION ALL
        SELECT RestrictionID FROM dwh.DimParkingRestriction WHERE IsCurrent = 1
        GROUP BY RestrictionID HAVING COUNT_BIG(*) > 1
        UNION ALL
        SELECT CameraID FROM dwh.DimCamera WHERE IsCurrent = 1
        GROUP BY CameraID HAVING COUNT_BIG(*) > 1
    )
        THROW 52905, 'FINAL DWH FAILED - duplicate current SCD2 business key found.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dwh.DimAnalysisZone AS Z
        LEFT JOIN dwh.DimCity AS C ON C.CityKey = Z.CityKey
        WHERE C.CityKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimRoad AS R
        LEFT JOIN dwh.DimAnalysisZone AS Z ON Z.ZoneKey = R.ZoneKey
        WHERE Z.ZoneKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimParkingFacility AS P
        LEFT JOIN dwh.DimAnalysisZone AS Z ON Z.ZoneKey = P.ZoneKey
        WHERE Z.ZoneKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimPOI AS P
        LEFT JOIN dwh.DimPOICategory AS C ON C.POICategoryKey = P.POICategoryKey
        LEFT JOIN dwh.DimAnalysisZone AS Z ON Z.ZoneKey = P.ZoneKey
        WHERE C.POICategoryKey IS NULL OR Z.ZoneKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimRoadSegment AS S
        LEFT JOIN dwh.DimRoad AS R ON R.RoadKey = S.RoadKey
        LEFT JOIN dwh.DimRoadSide AS RS ON RS.RoadSideKey = S.ObservedRoadSideKey
        WHERE R.RoadKey IS NULL OR RS.RoadSideKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimCamera AS C
        LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = C.SegmentKey
        WHERE S.SegmentKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.DimParkingRestriction AS P
        LEFT JOIN dwh.DimRoadSide AS RS ON RS.RoadSideKey = P.RoadSideKey
        LEFT JOIN dwh.DimRoad AS R ON R.RoadKey = P.RoadKey
        WHERE RS.RoadSideKey IS NULL
           OR (P.RoadKey IS NOT NULL AND R.RoadKey IS NULL)
    )
        THROW 52906, 'FINAL DWH FAILED - a Dimension hierarchy orphan was found.', 1;

    IF (SELECT COUNT_BIG(*) FROM dwh.DimParkingRestriction
        WHERE IsCurrent = 1 AND RoadKey IS NULL) <> 1
       OR NOT EXISTS
          (SELECT 1 FROM dwh.DimParkingRestriction
           WHERE IsCurrent = 1 AND RestrictionID = 'R003' AND RoadKey IS NULL)
        THROW 52907, 'FINAL DWH FAILED - the intentional R003 null RoadKey exception changed.', 1;

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

    IF EXISTS (SELECT 1 FROM @FactCount WHERE ActualRows <> ExpectedRows)
        THROW 52908, 'FINAL DWH FAILED - Fact counts do not match the baseline.', 1;

    IF EXISTS
       (SELECT EventID FROM dwh.FactTrafficObservation
        GROUP BY EventID HAVING COUNT_BIG(*) > 1)
       OR EXISTS
       (SELECT EventID FROM dwh.FactParkingEvent
        GROUP BY EventID HAVING COUNT_BIG(*) > 1)
       OR EXISTS
       (SELECT WeatherTimestamp FROM dwh.FactWeatherHourly
        GROUP BY WeatherTimestamp HAVING COUNT_BIG(*) > 1)
       OR EXISTS
       (SELECT SnapshotDateKey, ParkingFacilityKey
        FROM dwh.FactParkingCapacitySnapshot
        GROUP BY SnapshotDateKey, ParkingFacilityKey HAVING COUNT_BIG(*) > 1)
       OR EXISTS
       (SELECT SnapshotDateKey, SegmentKey
        FROM dwh.FactRoadSurveySnapshot
        GROUP BY SnapshotDateKey, SegmentKey HAVING COUNT_BIG(*) > 1)
        THROW 52909, 'FINAL DWH FAILED - a duplicate Fact grain was found.', 1;

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
       OR EXISTS
    (
        SELECT 1
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
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.FactWeatherHourly AS F
        LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.DateKey
        LEFT JOIN dwh.DimTime AS T ON T.TimeKey = F.TimeKey
        LEFT JOIN dwh.DimWeatherSource AS W
          ON W.WeatherSourceKey = F.WeatherSourceKey
        WHERE D.DateKey IS NULL OR T.TimeKey IS NULL OR W.WeatherSourceKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.FactParkingCapacitySnapshot AS F
        LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
        LEFT JOIN dwh.DimParkingFacility AS P
          ON P.ParkingFacilityKey = F.ParkingFacilityKey
        WHERE D.DateKey IS NULL OR P.ParkingFacilityKey IS NULL
    )
       OR EXISTS
    (
        SELECT 1
        FROM dwh.FactRoadSurveySnapshot AS F
        LEFT JOIN dwh.DimDate AS D ON D.DateKey = F.SnapshotDateKey
        LEFT JOIN dwh.DimDate AS SD ON SD.DateKey = F.SourceSurveyDateKey
        LEFT JOIN dwh.DimRoadSegment AS S ON S.SegmentKey = F.SegmentKey
        WHERE D.DateKey IS NULL OR S.SegmentKey IS NULL
           OR (F.SourceSurveyDateKey IS NOT NULL AND SD.DateKey IS NULL)
    )
        THROW 52910, 'FINAL DWH FAILED - a Fact foreign-key orphan was found.', 1;

    IF (SELECT COUNT_BIG(*) FROM dwh.FactTrafficObservation
        WHERE AvgSpeedKmh IS NULL AND SpeedMissingFlag = 1) <> 161
       OR (SELECT COUNT_BIG(*) FROM dwh.FactRoadSurveySnapshot
           WHERE RoadWidthRawM IS NULL AND WidthImputedFlag = 1) <> 3
       OR (SELECT COUNT_BIG(*) FROM dwh.FactParkingEvent
           WHERE IsOpenEvent = 1 AND EndTimestamp IS NULL
             AND EndDateKey IS NULL AND EndTimeKey IS NULL) <> 64
        THROW 52911, 'FINAL DWH FAILED - a documented nullable-data exception changed.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM
        (
            SELECT LoadFileKey FROM dwh.FactTrafficObservation
            UNION ALL SELECT LoadFileKey FROM dwh.FactParkingEvent
            UNION ALL SELECT LoadFileKey FROM dwh.FactWeatherHourly
            UNION ALL SELECT LoadFileKey FROM dwh.FactParkingCapacitySnapshot
            UNION ALL SELECT LoadFileKey FROM dwh.FactRoadSurveySnapshot
        ) AS F
        LEFT JOIN etl.LoadFile AS L ON L.LoadFileKey = F.LoadFileKey
        WHERE L.LoadFileKey IS NULL OR L.LoadBatchKey <> @ResolvedLoadBatchKey
    )
        THROW 52912, 'FINAL DWH FAILED - Fact load-file provenance does not match the batch.', 1;

    DECLARE @DimensionTables int =
        (SELECT COUNT(*) FROM @RequiredTable WHERE ObjectRole = 'DIMENSION');
    DECLARE @FactTables int =
        (SELECT COUNT(*) FROM @RequiredTable WHERE ObjectRole = 'FACT');
    DECLARE @FactRows bigint =
        (SELECT SUM(ActualRows) FROM @FactCount);

    SELECT
        CAST('PASS' AS varchar(10)) AS AcceptanceStatus,
        CAST(N'FINAL_DWH_VALIDATION_PASS' AS nvarchar(2000)) AS ValidationMessage,
        @DimensionTables AS DimensionTables,
        @FactTables AS FactTables,
        @FactRows AS FactRows;
END;
GO

SELECT
    OBJECT_SCHEMA_NAME(OBJECT_ID(N'etl.usp_ValidateFinalDWH')) AS SchemaName,
    OBJECT_NAME(OBJECT_ID(N'etl.usp_ValidateFinalDWH')) AS ProcedureName,
    CAST('PASS' AS varchar(10)) AS InstallStatus;
GO
