/*
    Da Nang Smart Parking
    Extract JSONL files 06, 07 and 08 with SQL Server OPENROWSET/OPENJSON.

    Prerequisites:
      - SQL Server service account can read the RAW folder.
      - Database compatibility level >= 130 (OPENJSON).
      - DanangSmartParkingDW and DanangSmartParkingSTG already exist.

    Design:
      - Read each file as SINGLE_BLOB and decode bytes with a UTF-8 collation.
      - Convert JSON Lines to one JSON array while preserving physical line order.
      - Keep source values in RAW string columns; typed conversion belongs to Transform.
*/

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_ExtractJSONLToStaging
    @LoadBatchKey bigint,
    @RawRoot nvarchar(4000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TrafficLoadFileKey bigint = NULL;
    DECLARE @ParkingLoadFileKey bigint = NULL;
    DECLARE @WeatherLoadFileKey bigint = NULL;
    DECLARE @ActiveLoadFileKey bigint = NULL;
    DECLARE @TrafficPath nvarchar(4000);
    DECLARE @ParkingPath nvarchar(4000);
    DECLARE @WeatherPath nvarchar(4000);
    DECLARE @SQL nvarchar(max);
    DECLARE @Accepted bigint;

    SET @RawRoot = NULLIF(LTRIM(RTRIM(@RawRoot)), N'');

    IF @RawRoot IS NULL
        THROW 51400, 'pRawRoot is empty.', 1;

    WHILE RIGHT(@RawRoot, 1) IN (N'\', N'/')
        SET @RawRoot = LEFT(@RawRoot, LEN(@RawRoot) - 1);

    SET @TrafficPath = @RawRoot + N'\06_traffic_events.jsonl';
    SET @ParkingPath = @RawRoot + N'\07_parking_events.jsonl';
    SET @WeatherPath = @RawRoot + N'\08_weather_events.jsonl';

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'STARTED'
    )
        THROW 51401, 'LoadBatchKey does not exist or is not STARTED.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM etl.LoadFile
        WHERE LoadBatchKey = @LoadBatchKey
          AND FileName IN
          (
              N'06_traffic_events.jsonl',
              N'07_parking_events.jsonl',
              N'08_weather_events.jsonl'
          )
    )
        THROW 51402, 'JSONL files were already registered for this batch. Run a new Master batch.', 1;

    BEGIN TRY
        /* =====================================================
           06 - Traffic events: 16,884 physical JSON lines
           ===================================================== */
        INSERT etl.LoadFile
        (
            LoadBatchKey,
            SourceID,
            FileName,
            FileFormat,
            ExpectedRowCount,
            LoadStatus
        )
        VALUES
        (
            @LoadBatchKey,
            '06',
            N'06_traffic_events.jsonl',
            'JSONL',
            16884,
            'STARTED'
        );

        SET @TrafficLoadFileKey = CONVERT(bigint, SCOPE_IDENTITY());
        SET @ActiveLoadFileKey = @TrafficLoadFileKey;

        SET @SQL = N'
DECLARE @JsonLines nvarchar(max);
DECLARE @JsonArray nvarchar(max);

SELECT @JsonLines = CONVERT
(
    nvarchar(max),
    COALESCE
    (
        BulkColumn,
        '''' COLLATE Latin1_General_100_CI_AS_SC_UTF8
    )
)
FROM OPENROWSET
(
    BULK ''' + REPLACE(@TrafficPath, N'''', N'''''') + N''',
    SINGLE_BLOB
) AS SourceFile;

SET @JsonLines = REPLACE(@JsonLines, NCHAR(13) + NCHAR(10), NCHAR(10));
SET @JsonLines = REPLACE(@JsonLines, NCHAR(13), NCHAR(10));

WHILE RIGHT(@JsonLines, 1) = NCHAR(10)
    SET @JsonLines = LEFT(@JsonLines, LEN(@JsonLines) - 1);

IF NULLIF(@JsonLines, N'''') IS NULL
    THROW 51403, ''06_traffic_events.jsonl is empty.'', 1;

IF CHARINDEX(NCHAR(10) + NCHAR(10), @JsonLines) > 0
    THROW 51404, ''06_traffic_events.jsonl contains a blank physical line.'', 1;

SET @JsonArray = N''['' + REPLACE(@JsonLines, NCHAR(10), N'','') + N'']'';

IF ISJSON(@JsonArray) <> 1
    THROW 51405, ''06_traffic_events.jsonl contains invalid JSON or a broken line.'', 1;

IF EXISTS (SELECT 1 FROM OPENJSON(@JsonArray) WHERE [type] <> 5)
    THROW 51406, ''Each traffic JSONL line must contain one JSON object.'', 1;

IF (SELECT COUNT_BIG(*) FROM OPENJSON(@JsonArray)) <> 16884
    THROW 51407, ''Traffic JSONL line count is different from expected 16884.'', 1;

IF JSON_VALUE(@JsonArray, ''$[0].road_name'') <> N''Lê Duẩn''
   OR JSON_VALUE(@JsonArray, ''$[0].analysis_zone'') <> N''Hải Châu core''
    THROW 51408, ''Traffic UTF-8 decoding validation failed.'', 1;

INSERT DanangSmartParkingSTG.extract.TrafficEventRaw
(
    LoadBatchKey,
    LoadFileKey,
    SourceRowNumber,
    EventID,
    EventTimestampRaw,
    EventDateRaw,
    HourRaw,
    CameraID,
    SegmentID,
    RoadID,
    RoadName,
    AnalysisZone,
    VehicleCountRaw,
    MotorbikeCountRaw,
    CarCountRaw,
    BusCountRaw,
    TruckCountRaw,
    AvgSpeedKmhRaw,
    ParkedVehicleCountRaw,
    IllegalParkingCountRaw,
    RoadWidthMRaw,
    ParkingOccupiedWidthMRaw,
    EffectiveWidthMRaw,
    WidthLossPctRaw,
    CongestionIndexRaw,
    RainMmRaw,
    CityPopulationReferenceRaw,
    DataStatus,
    GeneratorSeedRaw,
    RawJson
)
SELECT
    @pLoadBatchKey,
    @pLoadFileKey,
    CONVERT(bigint, JsonLine.[key]) + 1,
    Parsed.EventID,
    Parsed.EventTimestampRaw,
    Parsed.EventDateRaw,
    Parsed.HourRaw,
    Parsed.CameraID,
    Parsed.SegmentID,
    Parsed.RoadID,
    Parsed.RoadName,
    Parsed.AnalysisZone,
    Parsed.VehicleCountRaw,
    Parsed.MotorbikeCountRaw,
    Parsed.CarCountRaw,
    Parsed.BusCountRaw,
    Parsed.TruckCountRaw,
    Parsed.AvgSpeedKmhRaw,
    Parsed.ParkedVehicleCountRaw,
    Parsed.IllegalParkingCountRaw,
    Parsed.RoadWidthMRaw,
    Parsed.ParkingOccupiedWidthMRaw,
    Parsed.EffectiveWidthMRaw,
    Parsed.WidthLossPctRaw,
    Parsed.CongestionIndexRaw,
    Parsed.RainMmRaw,
    Parsed.CityPopulationReferenceRaw,
    Parsed.DataStatus,
    Parsed.GeneratorSeedRaw,
    JsonLine.[value]
FROM OPENJSON(@JsonArray) AS JsonLine
CROSS APPLY OPENJSON(JsonLine.[value])
WITH
(
    EventID nvarchar(80) ''$.event_id'',
    EventTimestampRaw nvarchar(50) ''$.timestamp'',
    EventDateRaw nvarchar(30) ''$.event_date'',
    HourRaw nvarchar(30) ''$.hour'',
    CameraID nvarchar(50) ''$.camera_id'',
    SegmentID nvarchar(50) ''$.segment_id'',
    RoadID nvarchar(50) ''$.road_id'',
    RoadName nvarchar(200) ''$.road_name'',
    AnalysisZone nvarchar(150) ''$.analysis_zone'',
    VehicleCountRaw nvarchar(30) ''$.vehicle_count'',
    MotorbikeCountRaw nvarchar(30) ''$.motorbike_count'',
    CarCountRaw nvarchar(30) ''$.car_count'',
    BusCountRaw nvarchar(30) ''$.bus_count'',
    TruckCountRaw nvarchar(30) ''$.truck_count'',
    AvgSpeedKmhRaw nvarchar(30) ''$.avg_speed_kmh'',
    ParkedVehicleCountRaw nvarchar(30) ''$.parked_vehicle_count'',
    IllegalParkingCountRaw nvarchar(30) ''$.illegal_parking_count'',
    RoadWidthMRaw nvarchar(30) ''$.road_width_m'',
    ParkingOccupiedWidthMRaw nvarchar(30) ''$.parking_occupied_width_m'',
    EffectiveWidthMRaw nvarchar(30) ''$.effective_width_m'',
    WidthLossPctRaw nvarchar(30) ''$.width_loss_pct'',
    CongestionIndexRaw nvarchar(30) ''$.congestion_index'',
    RainMmRaw nvarchar(30) ''$.rain_mm'',
    CityPopulationReferenceRaw nvarchar(30) ''$.city_population_reference'',
    DataStatus nvarchar(100) ''$.data_status'',
    GeneratorSeedRaw nvarchar(30) ''$.generator_seed''
) AS Parsed;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pLoadBatchKey bigint, @pLoadFileKey bigint',
            @pLoadBatchKey = @LoadBatchKey,
            @pLoadFileKey = @TrafficLoadFileKey;

        SELECT @Accepted = COUNT_BIG(*)
        FROM DanangSmartParkingSTG.extract.TrafficEventRaw
        WHERE LoadFileKey = @TrafficLoadFileKey;

        IF @Accepted <> 16884
            THROW 51409, 'TrafficEventRaw row count is different from expected 16884.', 1;

        UPDATE etl.LoadFile
        SET ActualRowCount = @Accepted,
            AcceptedRowCount = @Accepted,
            RejectedRowCount = 0,
            CompletedAt = SYSUTCDATETIME(),
            LoadStatus = 'COMPLETED'
        WHERE LoadFileKey = @TrafficLoadFileKey;

        SET @ActiveLoadFileKey = NULL;

        /* =====================================================
           07 - Parking events: 4,300 physical JSON lines
           ===================================================== */
        INSERT etl.LoadFile
        (
            LoadBatchKey,
            SourceID,
            FileName,
            FileFormat,
            ExpectedRowCount,
            LoadStatus
        )
        VALUES
        (
            @LoadBatchKey,
            '07',
            N'07_parking_events.jsonl',
            'JSONL',
            4300,
            'STARTED'
        );

        SET @ParkingLoadFileKey = CONVERT(bigint, SCOPE_IDENTITY());
        SET @ActiveLoadFileKey = @ParkingLoadFileKey;

        SET @SQL = N'
DECLARE @JsonLines nvarchar(max);
DECLARE @JsonArray nvarchar(max);

SELECT @JsonLines = CONVERT
(
    nvarchar(max),
    COALESCE
    (
        BulkColumn,
        '''' COLLATE Latin1_General_100_CI_AS_SC_UTF8
    )
)
FROM OPENROWSET
(
    BULK ''' + REPLACE(@ParkingPath, N'''', N'''''') + N''',
    SINGLE_BLOB
) AS SourceFile;

SET @JsonLines = REPLACE(@JsonLines, NCHAR(13) + NCHAR(10), NCHAR(10));
SET @JsonLines = REPLACE(@JsonLines, NCHAR(13), NCHAR(10));

WHILE RIGHT(@JsonLines, 1) = NCHAR(10)
    SET @JsonLines = LEFT(@JsonLines, LEN(@JsonLines) - 1);

IF NULLIF(@JsonLines, N'''') IS NULL
    THROW 51410, ''07_parking_events.jsonl is empty.'', 1;

IF CHARINDEX(NCHAR(10) + NCHAR(10), @JsonLines) > 0
    THROW 51411, ''07_parking_events.jsonl contains a blank physical line.'', 1;

SET @JsonArray = N''['' + REPLACE(@JsonLines, NCHAR(10), N'','') + N'']'';

IF ISJSON(@JsonArray) <> 1
    THROW 51412, ''07_parking_events.jsonl contains invalid JSON or a broken line.'', 1;

IF EXISTS (SELECT 1 FROM OPENJSON(@JsonArray) WHERE [type] <> 5)
    THROW 51413, ''Each parking JSONL line must contain one JSON object.'', 1;

IF (SELECT COUNT_BIG(*) FROM OPENJSON(@JsonArray)) <> 4300
    THROW 51414, ''Parking JSONL line count is different from expected 4300.'', 1;

IF JSON_VALUE(@JsonArray, ''$[0].analysis_zone'') <> N''Hải Châu core''
    THROW 51415, ''Parking UTF-8 decoding validation failed.'', 1;

INSERT DanangSmartParkingSTG.extract.ParkingEventRaw
(
    LoadBatchKey,
    LoadFileKey,
    SourceRowNumber,
    EventID,
    VehicleID,
    RoadID,
    RoadName,
    SegmentID,
    StartTimeRaw,
    EndTimeRaw,
    EventDateRaw,
    VehicleTypeCode,
    SideCode,
    ParkingDurationMinRaw,
    OccupiedWidthMRaw,
    LegalParkingRaw,
    ActiveRestrictionID,
    AnalysisZone,
    DataStatus,
    CityPopulationReferenceRaw,
    RawJson
)
SELECT
    @pLoadBatchKey,
    @pLoadFileKey,
    CONVERT(bigint, JsonLine.[key]) + 1,
    Parsed.EventID,
    Parsed.VehicleID,
    Parsed.RoadID,
    Parsed.RoadName,
    Parsed.SegmentID,
    Parsed.StartTimeRaw,
    Parsed.EndTimeRaw,
    Parsed.EventDateRaw,
    Parsed.VehicleTypeCode,
    Parsed.SideCode,
    Parsed.ParkingDurationMinRaw,
    Parsed.OccupiedWidthMRaw,
    Parsed.LegalParkingRaw,
    Parsed.ActiveRestrictionID,
    Parsed.AnalysisZone,
    Parsed.DataStatus,
    Parsed.CityPopulationReferenceRaw,
    JsonLine.[value]
FROM OPENJSON(@JsonArray) AS JsonLine
CROSS APPLY OPENJSON(JsonLine.[value])
WITH
(
    EventID nvarchar(80) ''$.event_id'',
    VehicleID nvarchar(80) ''$.vehicle_id'',
    RoadID nvarchar(50) ''$.road_id'',
    RoadName nvarchar(200) ''$.road_name'',
    SegmentID nvarchar(50) ''$.segment_id'',
    StartTimeRaw nvarchar(50) ''$.start_time'',
    EndTimeRaw nvarchar(50) ''$.end_time'',
    EventDateRaw nvarchar(30) ''$.event_date'',
    VehicleTypeCode nvarchar(50) ''$.vehicle_type'',
    SideCode nvarchar(30) ''$.side'',
    ParkingDurationMinRaw nvarchar(30) ''$.parking_duration_min'',
    OccupiedWidthMRaw nvarchar(30) ''$.occupied_width_m'',
    LegalParkingRaw nvarchar(20) ''$.legal_parking'',
    ActiveRestrictionID nvarchar(50) ''$.active_restriction_id'',
    AnalysisZone nvarchar(150) ''$.analysis_zone'',
    DataStatus nvarchar(100) ''$.data_status'',
    CityPopulationReferenceRaw nvarchar(30) ''$.city_population_reference''
) AS Parsed;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pLoadBatchKey bigint, @pLoadFileKey bigint',
            @pLoadBatchKey = @LoadBatchKey,
            @pLoadFileKey = @ParkingLoadFileKey;

        SELECT @Accepted = COUNT_BIG(*)
        FROM DanangSmartParkingSTG.extract.ParkingEventRaw
        WHERE LoadFileKey = @ParkingLoadFileKey;

        IF @Accepted <> 4300
            THROW 51416, 'ParkingEventRaw row count is different from expected 4300.', 1;

        UPDATE etl.LoadFile
        SET ActualRowCount = @Accepted,
            AcceptedRowCount = @Accepted,
            RejectedRowCount = 0,
            CompletedAt = SYSUTCDATETIME(),
            LoadStatus = 'COMPLETED'
        WHERE LoadFileKey = @ParkingLoadFileKey;

        SET @ActiveLoadFileKey = NULL;

        /* =====================================================
           08 - Weather events: 168 physical JSON lines
           ===================================================== */
        INSERT etl.LoadFile
        (
            LoadBatchKey,
            SourceID,
            FileName,
            FileFormat,
            ExpectedRowCount,
            LoadStatus
        )
        VALUES
        (
            @LoadBatchKey,
            '08',
            N'08_weather_events.jsonl',
            'JSONL',
            168,
            'STARTED'
        );

        SET @WeatherLoadFileKey = CONVERT(bigint, SCOPE_IDENTITY());
        SET @ActiveLoadFileKey = @WeatherLoadFileKey;

        SET @SQL = N'
DECLARE @JsonLines nvarchar(max);
DECLARE @JsonArray nvarchar(max);

SELECT @JsonLines = CONVERT
(
    nvarchar(max),
    COALESCE
    (
        BulkColumn,
        '''' COLLATE Latin1_General_100_CI_AS_SC_UTF8
    )
)
FROM OPENROWSET
(
    BULK ''' + REPLACE(@WeatherPath, N'''', N'''''') + N''',
    SINGLE_BLOB
) AS SourceFile;

SET @JsonLines = REPLACE(@JsonLines, NCHAR(13) + NCHAR(10), NCHAR(10));
SET @JsonLines = REPLACE(@JsonLines, NCHAR(13), NCHAR(10));

WHILE RIGHT(@JsonLines, 1) = NCHAR(10)
    SET @JsonLines = LEFT(@JsonLines, LEN(@JsonLines) - 1);

IF NULLIF(@JsonLines, N'''') IS NULL
    THROW 51417, ''08_weather_events.jsonl is empty.'', 1;

IF CHARINDEX(NCHAR(10) + NCHAR(10), @JsonLines) > 0
    THROW 51418, ''08_weather_events.jsonl contains a blank physical line.'', 1;

SET @JsonArray = N''['' + REPLACE(@JsonLines, NCHAR(10), N'','') + N'']'';

IF ISJSON(@JsonArray) <> 1
    THROW 51419, ''08_weather_events.jsonl contains invalid JSON or a broken line.'', 1;

IF EXISTS (SELECT 1 FROM OPENJSON(@JsonArray) WHERE [type] <> 5)
    THROW 51420, ''Each weather JSONL line must contain one JSON object.'', 1;

IF (SELECT COUNT_BIG(*) FROM OPENJSON(@JsonArray)) <> 168
    THROW 51421, ''Weather JSONL line count is different from expected 168.'', 1;

INSERT DanangSmartParkingSTG.extract.WeatherEventRaw
(
    LoadBatchKey,
    LoadFileKey,
    SourceRowNumber,
    WeatherTimestampRaw,
    EventDateRaw,
    HourRaw,
    TemperatureCRaw,
    DailyMinCActualRaw,
    DailyMaxCActualRaw,
    DailyReferenceCActualRaw,
    RainMmRaw,
    HumidityPctRaw,
    VisibilityKmRaw,
    WindKmhRaw,
    TemperatureStatus,
    PrecipitationStatus,
    SourceReference,
    RawJson
)
SELECT
    @pLoadBatchKey,
    @pLoadFileKey,
    CONVERT(bigint, JsonLine.[key]) + 1,
    Parsed.WeatherTimestampRaw,
    Parsed.EventDateRaw,
    Parsed.HourRaw,
    Parsed.TemperatureCRaw,
    Parsed.DailyMinCActualRaw,
    Parsed.DailyMaxCActualRaw,
    Parsed.DailyReferenceCActualRaw,
    Parsed.RainMmRaw,
    Parsed.HumidityPctRaw,
    Parsed.VisibilityKmRaw,
    Parsed.WindKmhRaw,
    Parsed.TemperatureStatus,
    Parsed.PrecipitationStatus,
    Parsed.SourceReference,
    JsonLine.[value]
FROM OPENJSON(@JsonArray) AS JsonLine
CROSS APPLY OPENJSON(JsonLine.[value])
WITH
(
    WeatherTimestampRaw nvarchar(50) ''$.timestamp'',
    EventDateRaw nvarchar(30) ''$.event_date'',
    HourRaw nvarchar(30) ''$.hour'',
    TemperatureCRaw nvarchar(30) ''$.temperature_c'',
    DailyMinCActualRaw nvarchar(30) ''$.daily_min_c_actual'',
    DailyMaxCActualRaw nvarchar(30) ''$.daily_max_c_actual'',
    DailyReferenceCActualRaw nvarchar(30) ''$.daily_reference_c_actual'',
    RainMmRaw nvarchar(30) ''$.rain_mm'',
    HumidityPctRaw nvarchar(30) ''$.humidity_pct'',
    VisibilityKmRaw nvarchar(30) ''$.visibility_km'',
    WindKmhRaw nvarchar(30) ''$.wind_kmh'',
    TemperatureStatus nvarchar(100) ''$.temperature_status'',
    PrecipitationStatus nvarchar(100) ''$.precipitation_status'',
    SourceReference nvarchar(500) ''$.source_reference''
) AS Parsed;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pLoadBatchKey bigint, @pLoadFileKey bigint',
            @pLoadBatchKey = @LoadBatchKey,
            @pLoadFileKey = @WeatherLoadFileKey;

        SELECT @Accepted = COUNT_BIG(*)
        FROM DanangSmartParkingSTG.extract.WeatherEventRaw
        WHERE LoadFileKey = @WeatherLoadFileKey;

        IF @Accepted <> 168
            THROW 51422, 'WeatherEventRaw row count is different from expected 168.', 1;

        UPDATE etl.LoadFile
        SET ActualRowCount = @Accepted,
            AcceptedRowCount = @Accepted,
            RejectedRowCount = 0,
            CompletedAt = SYSUTCDATETIME(),
            LoadStatus = 'COMPLETED'
        WHERE LoadFileKey = @WeatherLoadFileKey;

        SET @ActiveLoadFileKey = NULL;
    END TRY
    BEGIN CATCH
        IF @ActiveLoadFileKey IS NOT NULL
        BEGIN
            SET @Accepted = 0;

            IF @ActiveLoadFileKey = @TrafficLoadFileKey
            BEGIN
                SELECT @Accepted = COUNT_BIG(*)
                FROM DanangSmartParkingSTG.extract.TrafficEventRaw
                WHERE LoadFileKey = @ActiveLoadFileKey;
            END
            ELSE IF @ActiveLoadFileKey = @ParkingLoadFileKey
            BEGIN
                SELECT @Accepted = COUNT_BIG(*)
                FROM DanangSmartParkingSTG.extract.ParkingEventRaw
                WHERE LoadFileKey = @ActiveLoadFileKey;
            END
            ELSE IF @ActiveLoadFileKey = @WeatherLoadFileKey
            BEGIN
                SELECT @Accepted = COUNT_BIG(*)
                FROM DanangSmartParkingSTG.extract.WeatherEventRaw
                WHERE LoadFileKey = @ActiveLoadFileKey;
            END;

            UPDATE etl.LoadFile
            SET ActualRowCount = @Accepted,
                AcceptedRowCount = @Accepted,
                RejectedRowCount = 0,
                CompletedAt = SYSUTCDATETIME(),
                LoadStatus = 'FAILED'
            WHERE LoadFileKey = @ActiveLoadFileKey;
        END;

        UPDATE etl.LoadBatch
        SET LoadStatus = 'FAILED',
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE LoadBatchKey = @LoadBatchKey;

        THROW;
    END CATCH;
END;
GO
