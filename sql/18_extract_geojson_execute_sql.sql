/*
    Da Nang Smart Parking
    Extract 01_roads.geojson and 04_poi.geojson with SQL Server OPENROWSET/OPENJSON.

    Prerequisites:
      - SQL Server service account can read the RAW folder.
      - Database compatibility level >= 130 (OPENJSON).
      - DanangSmartParkingDW and DanangSmartParkingSTG already exist.
*/

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_ExtractGeoJSONToStaging
    @LoadBatchKey bigint,
    @RawRoot nvarchar(4000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RoadLoadFileKey bigint = NULL;
    DECLARE @POILoadFileKey bigint = NULL;
    DECLARE @ActiveLoadFileKey bigint = NULL;
    DECLARE @RoadPath nvarchar(4000);
    DECLARE @POIPath nvarchar(4000);
    DECLARE @SQL nvarchar(max);
    DECLARE @Accepted bigint;

    SET @RawRoot = NULLIF(LTRIM(RTRIM(@RawRoot)), N'');

    IF @RawRoot IS NULL
        THROW 51200, 'pRawRoot is empty.', 1;

    WHILE RIGHT(@RawRoot, 1) IN (N'\', N'/')
        SET @RawRoot = LEFT(@RawRoot, LEN(@RawRoot) - 1);

    SET @RoadPath = @RawRoot + N'\01_roads.geojson';
    SET @POIPath = @RawRoot + N'\04_poi.geojson';

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'STARTED'
    )
        THROW 51201, 'LoadBatchKey does not exist or is not STARTED.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM etl.LoadFile
        WHERE LoadBatchKey = @LoadBatchKey
          AND FileName IN (N'01_roads.geojson', N'04_poi.geojson')
    )
        THROW 51202, 'GeoJSON files were already registered for this batch. Run a new Master batch.', 1;

    BEGIN TRY
        /* =====================================================
           01 - Roads
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
            '01',
            N'01_roads.geojson',
            'GEOJSON',
            30,
            'STARTED'
        );

        SET @RoadLoadFileKey = CONVERT(bigint, SCOPE_IDENTITY());
        SET @ActiveLoadFileKey = @RoadLoadFileKey;

        SET @SQL = N'
DECLARE @Json nvarchar(max);

SELECT @Json = CONVERT
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
    BULK ''' + REPLACE(@RoadPath, N'''', N'''''') + N''',
    SINGLE_BLOB
) AS SourceFile;

IF ISJSON(@Json) <> 1
    THROW 51203, ''01_roads.geojson is not valid JSON.'', 1;

IF JSON_QUERY(@Json, ''$.features'') IS NULL
    THROW 51204, ''01_roads.geojson does not contain features[].'', 1;

IF JSON_VALUE(@Json, ''$.features[0].properties.road_name'') <> N''Trần Phú''
    THROW 51209, ''Road UTF-8 decoding validation failed. Expected Trần Phú.'', 1;

INSERT DanangSmartParkingSTG.extract.RoadRaw
(
    LoadBatchKey,
    LoadFileKey,
    SourceRowNumber,
    RoadID,
    RoadName,
    AnalysisZone,
    RoadClass,
    LanesRaw,
    SpeedLimitKmhRaw,
    RoadWidthMRaw,
    LengthKmRaw,
    CityPopulationReferenceRaw,
    NameStatus,
    GeometryStatus,
    WidthStatus,
    SourceNote,
    GeometryJson
)
SELECT
    @pLoadBatchKey,
    @pLoadFileKey,
    CONVERT(bigint, Feature.[key]) + 1,
    Parsed.RoadID,
    Parsed.RoadName,
    Parsed.AnalysisZone,
    Parsed.RoadClass,
    Parsed.LanesRaw,
    Parsed.SpeedLimitKmhRaw,
    Parsed.RoadWidthMRaw,
    Parsed.LengthKmRaw,
    Parsed.CityPopulationReferenceRaw,
    Parsed.NameStatus,
    Parsed.GeometryStatus,
    Parsed.WidthStatus,
    Parsed.SourceNote,
    Parsed.GeometryJson
FROM OPENJSON(@Json, ''$.features'') AS Feature
CROSS APPLY OPENJSON(Feature.[value])
WITH
(
    RoadID nvarchar(50) ''$.properties.road_id'',
    RoadName nvarchar(200) ''$.properties.road_name'',
    AnalysisZone nvarchar(150) ''$.properties.analysis_zone'',
    RoadClass nvarchar(50) ''$.properties.road_class'',
    LanesRaw nvarchar(30) ''$.properties.lanes'',
    SpeedLimitKmhRaw nvarchar(30) ''$.properties.speed_limit_kmh'',
    RoadWidthMRaw nvarchar(30) ''$.properties.road_width_m'',
    LengthKmRaw nvarchar(30) ''$.properties.length_km'',
    CityPopulationReferenceRaw nvarchar(30) ''$.properties.city_population_reference'',
    NameStatus nvarchar(80) ''$.properties.name_status'',
    GeometryStatus nvarchar(80) ''$.properties.geometry_status'',
    WidthStatus nvarchar(80) ''$.properties.width_status'',
    SourceNote nvarchar(2000) ''$.properties.source_note'',
    GeometryJson nvarchar(max) ''$.geometry'' AS JSON
) AS Parsed;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pLoadBatchKey bigint, @pLoadFileKey bigint',
            @pLoadBatchKey = @LoadBatchKey,
            @pLoadFileKey = @RoadLoadFileKey;

        SELECT @Accepted = COUNT_BIG(*)
        FROM DanangSmartParkingSTG.extract.RoadRaw
        WHERE LoadFileKey = @RoadLoadFileKey;

        IF @Accepted <> 30
            THROW 51205, 'RoadRaw row count is different from expected 30.', 1;

        UPDATE etl.LoadFile
        SET ActualRowCount = @Accepted,
            AcceptedRowCount = @Accepted,
            RejectedRowCount = 0,
            CompletedAt = SYSUTCDATETIME(),
            LoadStatus = 'COMPLETED'
        WHERE LoadFileKey = @RoadLoadFileKey;

        SET @ActiveLoadFileKey = NULL;

        /* =====================================================
           04 - POI
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
            '04',
            N'04_poi.geojson',
            'GEOJSON',
            50,
            'STARTED'
        );

        SET @POILoadFileKey = CONVERT(bigint, SCOPE_IDENTITY());
        SET @ActiveLoadFileKey = @POILoadFileKey;

        SET @SQL = N'
DECLARE @Json nvarchar(max);

SELECT @Json = CONVERT
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
    BULK ''' + REPLACE(@POIPath, N'''', N'''''') + N''',
    SINGLE_BLOB
) AS SourceFile;

IF ISJSON(@Json) <> 1
    THROW 51206, ''04_poi.geojson is not valid JSON.'', 1;

IF JSON_QUERY(@Json, ''$.features'') IS NULL
    THROW 51207, ''04_poi.geojson does not contain features[].'', 1;

IF JSON_VALUE(@Json, ''$.features[0].properties.poi_name'') <> N''Chợ Cồn''
    THROW 51210, ''POI UTF-8 decoding validation failed. Expected Chợ Cồn.'', 1;

INSERT DanangSmartParkingSTG.extract.POIRaw
(
    LoadBatchKey,
    LoadFileKey,
    SourceRowNumber,
    POIID,
    POIName,
    CategoryCode,
    AnalysisZone,
    ParkingDemandWeightRaw,
    DataStatus,
    LatitudeRaw,
    LongitudeRaw,
    GeometryJson
)
SELECT
    @pLoadBatchKey,
    @pLoadFileKey,
    CONVERT(bigint, Feature.[key]) + 1,
    Parsed.POIID,
    Parsed.POIName,
    Parsed.CategoryCode,
    Parsed.AnalysisZone,
    Parsed.ParkingDemandWeightRaw,
    Parsed.DataStatus,
    Parsed.LatitudeRaw,
    Parsed.LongitudeRaw,
    Parsed.GeometryJson
FROM OPENJSON(@Json, ''$.features'') AS Feature
CROSS APPLY OPENJSON(Feature.[value])
WITH
(
    POIID nvarchar(50) ''$.properties.poi_id'',
    POIName nvarchar(250) ''$.properties.poi_name'',
    CategoryCode nvarchar(100) ''$.properties.category'',
    AnalysisZone nvarchar(150) ''$.properties.analysis_zone'',
    ParkingDemandWeightRaw nvarchar(30) ''$.properties.parking_demand_weight'',
    DataStatus nvarchar(100) ''$.properties.data_status'',
    LongitudeRaw nvarchar(50) ''$.geometry.coordinates[0]'',
    LatitudeRaw nvarchar(50) ''$.geometry.coordinates[1]'',
    GeometryJson nvarchar(max) ''$.geometry'' AS JSON
) AS Parsed;';

        EXEC sys.sp_executesql
            @SQL,
            N'@pLoadBatchKey bigint, @pLoadFileKey bigint',
            @pLoadBatchKey = @LoadBatchKey,
            @pLoadFileKey = @POILoadFileKey;

        SELECT @Accepted = COUNT_BIG(*)
        FROM DanangSmartParkingSTG.extract.POIRaw
        WHERE LoadFileKey = @POILoadFileKey;

        IF @Accepted <> 50
            THROW 51208, 'POIRaw row count is different from expected 50.', 1;

        UPDATE etl.LoadFile
        SET ActualRowCount = @Accepted,
            AcceptedRowCount = @Accepted,
            RejectedRowCount = 0,
            CompletedAt = SYSUTCDATETIME(),
            LoadStatus = 'COMPLETED'
        WHERE LoadFileKey = @POILoadFileKey;

        SET @ActiveLoadFileKey = NULL;
    END TRY
    BEGIN CATCH
        IF @ActiveLoadFileKey IS NOT NULL
        BEGIN
            SET @Accepted =
                CASE
                    WHEN @ActiveLoadFileKey = @RoadLoadFileKey THEN
                        (SELECT COUNT_BIG(*)
                         FROM DanangSmartParkingSTG.extract.RoadRaw
                         WHERE LoadFileKey = @ActiveLoadFileKey)
                    WHEN @ActiveLoadFileKey = @POILoadFileKey THEN
                        (SELECT COUNT_BIG(*)
                         FROM DanangSmartParkingSTG.extract.POIRaw
                         WHERE LoadFileKey = @ActiveLoadFileKey)
                    ELSE 0
                END;

            UPDATE etl.LoadFile
            SET ActualRowCount = ISNULL(@Accepted, 0),
                AcceptedRowCount = ISNULL(@Accepted, 0),
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

/*
    Manual smoke-test example (do not run with an old batch that already has files 01/04):

    EXEC etl.usp_ExtractGeoJSONToStaging
        @LoadBatchKey = 123,
        @RawRoot = N'C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d';
*/
