/*
Purpose: export the current SQL Server/SSIS state before reconciling it with AWS.
Safety: read-only. This script contains SELECT statements only and does not create,
        update, delete, truncate, drop, or execute an ETL procedure.

Run the whole file in SSMS and send every result grid (or Save Results As CSV).
The script tolerates Dimension/Fact tables that have not been loaded yet.
*/

SET NOCOUNT ON;

IF DB_ID(N'DanangSmartParkingDW') IS NULL
    THROW 59001, 'DanangSmartParkingDW does not exist.', 1;

USE DanangSmartParkingDW;

SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    SYSUTCDATETIME() AS CollectedAtUtc,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition;

SELECT TOP (10)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    StartedAt,
    CompletedAt,
    ErrorMessage
FROM etl.LoadBatch
ORDER BY LoadBatchKey DESC;

/*
This is the newest accepted source candidate, not necessarily the batch that
currently owns the physical DWH Facts. Run sql/91_confirm_aws_baseline_batch.sql
to confirm Fact LoadFileKey lineage before adopting a DB batch for AWS.
*/
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM etl.LoadBatch
    WHERE LoadStatus IN ('SILVER_VALIDATED', 'COMPLETED', 'BRONZE_LOADED')
    ORDER BY LoadBatchKey DESC
);

SELECT
    @LoadBatchKey AS AwsCandidateLoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    StartedAt,
    CompletedAt,
    ErrorMessage
FROM etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    LoadFileKey,
    SourceID,
    FileName,
    FileFormat,
    ExpectedRowCount,
    ActualRowCount,
    AcceptedRowCount,
    RejectedRowCount,
    LoadStatus,
    StartedAt,
    CompletedAt
FROM etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY LoadFileKey;

DECLARE @DwhCountSql nvarchar(max) = N'';

SELECT @DwhCountSql = @DwhCountSql +
    CASE WHEN @DwhCountSql = N'' THEN N'' ELSE N' UNION ALL ' END +
    N'SELECT N''' + ObjectType + N''' AS ObjectType, N''' + ObjectName +
    N''' AS ObjectName, COUNT_BIG(*) AS PhysicalRows FROM dwh.' +
    QUOTENAME(ObjectName)
FROM
(
    VALUES
        (N'DIMENSION', N'DimDate'),
        (N'DIMENSION', N'DimTime'),
        (N'DIMENSION', N'DimCity'),
        (N'DIMENSION', N'DimRoadSide'),
        (N'DIMENSION', N'DimVehicleType'),
        (N'DIMENSION', N'DimPOICategory'),
        (N'DIMENSION', N'DimWeatherSource'),
        (N'DIMENSION', N'DimAnalysisZone'),
        (N'DIMENSION', N'DimRoad'),
        (N'DIMENSION', N'DimParkingFacility'),
        (N'DIMENSION', N'DimPOI'),
        (N'DIMENSION', N'DimRoadSegment'),
        (N'DIMENSION', N'DimParkingRestriction'),
        (N'DIMENSION', N'DimCamera'),
        (N'FACT', N'FactParkingCapacitySnapshot'),
        (N'FACT', N'FactRoadSurveySnapshot'),
        (N'FACT', N'FactWeatherHourly'),
        (N'FACT', N'FactTrafficObservation'),
        (N'FACT', N'FactParkingEvent')
) AS objects(ObjectType, ObjectName)
WHERE OBJECT_ID(N'dwh.' + ObjectName, N'U') IS NOT NULL;

IF @DwhCountSql = N''
    SELECT N'NO_DWH_TABLE_FOUND' AS ObjectType, CAST(NULL AS nvarchar(128)) AS ObjectName,
           CAST(NULL AS bigint) AS PhysicalRows;
ELSE
BEGIN
    SET @DwhCountSql = N'SELECT * FROM (' + @DwhCountSql +
        N') AS counts ORDER BY ObjectType, ObjectName;';
    EXEC sys.sp_executesql @DwhCountSql;
END;

IF DB_ID(N'DanangSmartParkingSTG') IS NULL
BEGIN
    SELECT N'DanangSmartParkingSTG does not exist.' AS StagingStatus;
END
ELSE
BEGIN
    DECLARE @StagingCountSql nvarchar(max) = N'';

    SELECT @StagingCountSql = @StagingCountSql +
        CASE WHEN @StagingCountSql = N'' THEN N'' ELSE N' UNION ALL ' END +
        N'SELECT N''' + PhaseName + N''' AS PhaseName, N''' + ObjectName +
        N''' AS ObjectName, COUNT_BIG(*) AS BatchRows ' +
        N'FROM DanangSmartParkingSTG.' + QUOTENAME(SchemaName) + N'.' +
        QUOTENAME(ObjectName) + N' WHERE LoadBatchKey = @BatchKey'
    FROM
    (
        VALUES
            (N'EXTRACT', N'extract', N'RoadRaw'),
            (N'EXTRACT', N'extract', N'ParkingLocationRaw'),
            (N'EXTRACT', N'extract', N'ParkingRestrictionRaw'),
            (N'EXTRACT', N'extract', N'POIRaw'),
            (N'EXTRACT', N'extract', N'RoadSurveyRaw'),
            (N'EXTRACT', N'extract', N'TrafficEventRaw'),
            (N'EXTRACT', N'extract', N'ParkingEventRaw'),
            (N'EXTRACT', N'extract', N'WeatherEventRaw'),
            (N'TRANSFORM', N'transform', N'RoadClean'),
            (N'TRANSFORM', N'transform', N'ParkingFacilityClean'),
            (N'TRANSFORM', N'transform', N'ParkingRestrictionClean'),
            (N'TRANSFORM', N'transform', N'POIClean'),
            (N'TRANSFORM', N'transform', N'RoadSurveyClean'),
            (N'TRANSFORM', N'transform', N'TrafficObservationClean'),
            (N'TRANSFORM', N'transform', N'ParkingEventClean'),
            (N'TRANSFORM', N'transform', N'WeatherHourlyClean'),
            (N'AGGREGATE', N'transform', N'TrafficHourlySummary'),
            (N'AGGREGATE', N'transform', N'ParkingDailySummary')
    ) AS objects(PhaseName, SchemaName, ObjectName)
    WHERE OBJECT_ID(
        N'DanangSmartParkingSTG.' + SchemaName + N'.' + ObjectName,
        N'U'
    ) IS NOT NULL;

    IF @StagingCountSql = N''
        SELECT N'NO_STAGING_TABLE_FOUND' AS PhaseName,
               CAST(NULL AS nvarchar(128)) AS ObjectName,
               CAST(NULL AS bigint) AS BatchRows;
    ELSE
    BEGIN
        SET @StagingCountSql = N'SELECT * FROM (' + @StagingCountSql +
            N') AS counts ORDER BY PhaseName, ObjectName;';
        EXEC sys.sp_executesql
            @StagingCountSql,
            N'@BatchKey bigint',
            @BatchKey = @LoadBatchKey;
    END;
END;

SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    c.column_id AS ColumnOrdinal,
    c.name AS ColumnName,
    ty.name AS DataType,
    c.max_length AS MaxLength,
    c.precision AS NumericPrecision,
    c.scale AS NumericScale,
    c.is_nullable AS IsNullable
FROM sys.tables AS t
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
JOIN sys.columns AS c
  ON c.object_id = t.object_id
JOIN sys.types AS ty
  ON ty.user_type_id = c.user_type_id
WHERE s.name IN (N'etl', N'dwh', N'rpt')
ORDER BY s.name, t.name, c.column_id;
