/*
    Da Nang Smart Parking
    Package 30 support objects - Load Dimensions by SSIS Data Flow Tasks.

    Run this file once on SQL Server before building 30_Load_Dimensions.dtsx.
    The views expose SSIS-friendly, typed dimension sources. The procedures are
    pre/post checks only; they do not load dimension rows.
*/

USE DanangSmartParkingSTG;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'publish')
    EXEC(N'CREATE SCHEMA publish AUTHORIZATION dbo;');
GO

CREATE OR ALTER VIEW publish.vDimDateSource
AS
WITH SourceDate AS
(
    SELECT LoadBatchKey, EventDate AS DateValue
    FROM transform.TrafficObservationClean
    WHERE IsValid = 1 AND DuplicateRank = 1

    UNION

    SELECT LoadBatchKey, EventDate
    FROM transform.ParkingEventClean
    WHERE IsValid = 1 AND DuplicateRank = 1

    UNION

    SELECT LoadBatchKey, EventDate
    FROM transform.WeatherHourlyClean
    WHERE IsValid = 1
)
SELECT
    LoadBatchKey,
    CONVERT(int, CONVERT(char(8), DateValue, 112)) AS DateKey,
    DateValue,
    CONVERT(smallint, YEAR(DateValue)) AS CalendarYear,
    CONVERT(tinyint, DATEPART(quarter, DateValue)) AS CalendarQuarter,
    CONVERT(tinyint, MONTH(DateValue)) AS MonthNumber,
    CONVERT(nvarchar(20), DATENAME(month, DateValue)) AS MonthName,
    CONVERT(tinyint, DAY(DateValue)) AS DayOfMonth,
    CONVERT(tinyint, DATEPART(iso_week, DateValue)) AS ISOWeekNumber,
    CONVERT(tinyint, (DATEDIFF(day, CONVERT(date, '19000101'), DateValue) % 7) + 1)
        AS ISOWeekdayNumber,
    CONVERT(nvarchar(20), DATENAME(weekday, DateValue)) AS DayName,
    CONVERT(bit,
        CASE WHEN (DATEDIFF(day, CONVERT(date, '19000101'), DateValue) % 7) + 1
                       IN (6, 7)
             THEN 1 ELSE 0 END) AS IsWeekend
FROM SourceDate;
GO

CREATE OR ALTER VIEW publish.vDimTimeSource
AS
WITH Digit AS
(
    SELECT n
    FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS D(n)
),
MinuteSeries AS
(
    SELECT Ones.n + Tens.n * 10 + Hundreds.n * 100 + Thousands.n * 1000 AS n
    FROM Digit AS Ones
    CROSS JOIN Digit AS Tens
    CROSS JOIN Digit AS Hundreds
    CROSS JOIN Digit AS Thousands
)
SELECT
    CONVERT(smallint, (n / 60) * 100 + (n % 60)) AS TimeKey,
    TIMEFROMPARTS(n / 60, n % 60, 0, 0, 0) AS TimeValue,
    CONVERT(tinyint, n / 60) AS Hour24,
    CONVERT(tinyint, n % 60) AS MinuteNumber,
    CONVERT(smallint, n) AS MinuteOfDay,
    CONVERT(tinyint, ((n % 60) / 15) + 1) AS QuarterOfHour,
    CONVERT(nvarchar(30),
        CASE
            WHEN n < 360 THEN N'Đêm'
            WHEN n < 660 THEN N'Sáng'
            WHEN n < 840 THEN N'Trưa'
            WHEN n < 960 THEN N'Chiều'
            WHEN n < 1140 THEN N'Cao điểm chiều'
            ELSE N'Tối'
        END) AS TimeBand,
    CONVERT(bit, CASE WHEN n BETWEEN 420 AND 539 OR n BETWEEN 960 AND 1139
                      THEN 1 ELSE 0 END) AS IsConfiguredPeak
FROM MinuteSeries
WHERE n BETWEEN 0 AND 1439;
GO

CREATE OR ALTER VIEW publish.vDimCitySource
AS
WITH SourceValue AS
(
    SELECT
        CONVERT(varchar(20), 'DANANG') AS CityCode,
        CONVERT(nvarchar(100), N'Đà Nẵng') AS CityName,
        CONVERT(int, 3065628) AS PopulationReference,
        CONVERT(decimal(12,2), 11859.59) AS AreaKm2Reference,
        CONVERT(int, 1318481) AS FormerPopulationReference,
        CONVERT(nvarchar(1000),
            N'Bộ dữ liệu 7 ngày chỉ mô phỏng một phần mạng lưới đường và đỗ xe đô thị.')
            AS ScopeNote,
        CONVERT(nvarchar(1000),
            N'Các số liệu dân số/diện tích chỉ là metadata tham chiếu, không phải số đo từ event RAW.')
            AS DataWarning
)
SELECT
    SourceValue.*,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        CityCode, N'|', CityName, N'|', PopulationReference, N'|',
        AreaKm2Reference, N'|', FormerPopulationReference, N'|',
        ScopeNote, N'|', DataWarning)), 2) AS SourceHashHex
FROM SourceValue;
GO

CREATE OR ALTER VIEW publish.vDimRoadSideSource
AS
SELECT
    CONVERT(tinyint, RoadSideKey) AS RoadSideKey,
    CONVERT(varchar(10), SideCode) AS SideCode,
    CONVERT(nvarchar(30), SideName) AS SideName
FROM (VALUES
    (0, 'UNKNOWN', N'Không xác định'),
    (1, 'LEFT',    N'Bên trái'),
    (2, 'RIGHT',   N'Bên phải'),
    (3, 'BOTH',    N'Cả hai bên'),
    (4, 'NONE',    N'Không quan sát đỗ')
) AS S(RoadSideKey, SideCode, SideName);
GO

CREATE OR ALTER VIEW publish.vDimVehicleTypeSource
AS
SELECT
    CONVERT(smallint, VehicleTypeKey) AS VehicleTypeKey,
    CONVERT(varchar(30), VehicleTypeCode) AS VehicleTypeCode,
    CONVERT(nvarchar(50), VehicleTypeName) AS VehicleTypeName,
    CONVERT(varchar(30), VehicleGroup) AS VehicleGroup
FROM (VALUES
    (0, 'UNKNOWN',     N'Không xác định', 'UNKNOWN'),
    (1, 'CAR',         N'Ô tô con',        'PASSENGER'),
    (2, 'SUV',         N'SUV',              'PASSENGER'),
    (3, 'VAN',         N'Xe van',           'LIGHT_COMMERCIAL'),
    (4, 'LIGHT_TRUCK', N'Xe tải nhẹ',       'LIGHT_COMMERCIAL')
) AS V(VehicleTypeKey, VehicleTypeCode, VehicleTypeName, VehicleGroup);
GO

CREATE OR ALTER VIEW publish.vDimPOICategorySource
AS
WITH SourceValue AS
(
    SELECT DISTINCT
        LoadBatchKey,
        CategoryCode,
        CONVERT(nvarchar(100), REPLACE(CategoryCode, '_', ' ')) AS CategoryName
    FROM transform.POIClean
    WHERE IsValid = 1
)
SELECT
    SourceValue.*,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        CategoryCode, N'|', CategoryName)), 2) AS SourceHashHex
FROM SourceValue;
GO

CREATE OR ALTER VIEW publish.vDimWeatherSourceSource
AS
SELECT DISTINCT
    LoadBatchKey,
    TemperatureStatus,
    PrecipitationStatus,
    SourceReference
FROM transform.WeatherHourlyClean
WHERE IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimAnalysisZoneSource
AS
WITH ZoneValue AS
(
    SELECT LoadBatchKey, LTRIM(RTRIM(AnalysisZone)) AS ZoneBusinessKey
    FROM transform.RoadClean WHERE IsValid = 1

    UNION

    SELECT LoadBatchKey, LTRIM(RTRIM(AnalysisZone))
    FROM transform.ParkingFacilityClean WHERE IsValid = 1

    UNION

    SELECT LoadBatchKey, LTRIM(RTRIM(AnalysisZone))
    FROM transform.POIClean WHERE IsValid = 1
)
, SourceValue AS
(
    SELECT
        ZoneValue.LoadBatchKey,
        ZoneValue.ZoneBusinessKey,
        CONVERT(nvarchar(100), ZoneValue.ZoneBusinessKey) AS ZoneName,
        CONVERT(varchar(30),
            CASE
                WHEN LOWER(ZoneValue.ZoneBusinessKey) LIKE N'%coast%'
                    THEN 'COASTAL_CORRIDOR'
                WHEN LOWER(ZoneValue.ZoneBusinessKey) LIKE N'%core'
                    THEN 'CORE'
                ELSE 'CROSS_DISTRICT'
            END) AS ZoneType,
        CONVERT(bit, CASE WHEN LOWER(ZoneValue.ZoneBusinessKey) LIKE N'%coast%'
                          THEN 1 ELSE 0 END) AS IsCoastal,
        City.CityKey
    FROM ZoneValue
    LEFT JOIN DanangSmartParkingDW.dwh.DimCity AS City
      ON City.CityCode = 'DANANG'
)
SELECT
    SourceValue.*,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        ZoneBusinessKey, N'|', ZoneName, N'|', ZoneType, N'|',
        IsCoastal, N'|', COALESCE(CONVERT(varchar(20), CityKey), '<NULL>'))), 2)
        AS SourceHashHex
FROM SourceValue;
GO

CREATE OR ALTER VIEW publish.vDimRoadSource
AS
SELECT
    Source.LoadBatchKey,
    Source.RoadID,
    Source.RoadName,
    Zone.ZoneKey,
    Source.RoadClass,
    Source.LaneCount,
    Source.SpeedLimitKmh,
    Source.RoadWidthM AS MasterRoadWidthM,
    Source.LengthKm,
    Source.NameStatus,
    Source.GeometryStatus,
    Source.WidthStatus,
    Source.SourceNote,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM transform.RoadClean AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimAnalysisZone AS Zone
  ON Zone.ZoneBusinessKey = Source.AnalysisZone
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.RoadID, N'|', Source.RoadName, N'|',
        COALESCE(CONVERT(varchar(20), Zone.ZoneKey), '<NULL>'), N'|',
        Source.RoadClass, N'|', Source.LaneCount, N'|',
        Source.SpeedLimitKmh, N'|', Source.RoadWidthM, N'|',
        Source.LengthKm, N'|', Source.NameStatus, N'|',
        Source.GeometryStatus, N'|', Source.WidthStatus, N'|',
        COALESCE(Source.SourceNote, N'<NULL>')))) AS AttributeHash
) AS HashValue
WHERE Source.IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimParkingFacilitySource
AS
SELECT
    Source.LoadBatchKey,
    Source.ParkingID,
    Source.ParkingName,
    Source.AddressOrCorridor,
    Zone.ZoneKey,
    Source.ParkingType,
    Source.FacilityStatus,
    Source.CapacityStatus,
    Source.CoordinateStatus,
    Source.Latitude,
    Source.Longitude,
    Source.SourceURL,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM transform.ParkingFacilityClean AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimAnalysisZone AS Zone
  ON Zone.ZoneBusinessKey = Source.AnalysisZone
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.ParkingID, N'|', Source.ParkingName, N'|',
        Source.AddressOrCorridor, N'|',
        COALESCE(CONVERT(varchar(20), Zone.ZoneKey), '<NULL>'), N'|',
        Source.ParkingType, N'|', Source.FacilityStatus, N'|',
        Source.CapacityStatus, N'|', Source.CoordinateStatus, N'|',
        Source.Latitude, N'|', Source.Longitude, N'|',
        COALESCE(Source.SourceURL, N'<NULL>')))) AS AttributeHash
) AS HashValue
WHERE Source.IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimPOISource
AS
SELECT
    Source.LoadBatchKey,
    Source.POIID,
    Source.POIName,
    Category.POICategoryKey,
    Zone.ZoneKey,
    Source.ParkingDemandWeight,
    Source.Latitude,
    Source.Longitude,
    Source.DataStatus,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM transform.POIClean AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimPOICategory AS Category
  ON Category.CategoryCode = Source.CategoryCode
LEFT JOIN DanangSmartParkingDW.dwh.DimAnalysisZone AS Zone
  ON Zone.ZoneBusinessKey = Source.AnalysisZone
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.POIID, N'|', Source.POIName, N'|',
        COALESCE(CONVERT(varchar(20), Category.POICategoryKey), '<NULL>'), N'|',
        COALESCE(CONVERT(varchar(20), Zone.ZoneKey), '<NULL>'), N'|',
        Source.ParkingDemandWeight, N'|', Source.Latitude, N'|',
        Source.Longitude, N'|', Source.DataStatus))) AS AttributeHash
) AS HashValue
WHERE Source.IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimRoadSegmentSource
AS
SELECT
    Source.LoadBatchKey,
    Source.SegmentID,
    Road.RoadKey,
    Source.RoadName AS SourceRoadName,
    SideValue.RoadSideKey AS ObservedRoadSideKey,
    Source.DataStatus AS SurveyDataStatus,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM transform.RoadSurveyClean AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimRoad AS Road
  ON Road.RoadID = Source.RoadID AND Road.IsCurrent = 1
LEFT JOIN DanangSmartParkingDW.dwh.DimRoadSide AS SideValue
  ON SideValue.SideCode = Source.ObservedParkingSides
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.SegmentID, '|', COALESCE(CONVERT(varchar(20), Road.RoadKey), '<NULL>'),
        '|', Source.RoadName, '|',
        COALESCE(CONVERT(varchar(10), SideValue.RoadSideKey), '<NULL>'),
        '|', Source.DataStatus))) AS AttributeHash
) AS HashValue
WHERE Source.IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimParkingRestrictionSource
AS
SELECT
    Source.LoadBatchKey,
    Source.RestrictionID,
    Source.RoadID,
    Road.RoadKey,
    Source.RoadName AS SourceRoadName,
    Source.RestrictionType,
    Source.StartTime,
    Source.EndTime,
    SideValue.RoadSideKey,
    Source.VehicleScope,
    Source.DataStatus,
    Source.SourceURL,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM transform.ParkingRestrictionClean AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimRoad AS Road
  ON Road.RoadID = Source.RoadID AND Road.IsCurrent = 1
LEFT JOIN DanangSmartParkingDW.dwh.DimRoadSide AS SideValue
  ON SideValue.SideCode = Source.SideCode
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.RestrictionID, '|',
        COALESCE(CONVERT(varchar(20), Road.RoadKey), '<NULL>'), '|',
        Source.RoadName, '|', Source.RestrictionType, '|',
        CONVERT(char(8), Source.StartTime, 108), '|',
        CONVERT(char(8), Source.EndTime, 108), '|',
        COALESCE(CONVERT(varchar(10), SideValue.RoadSideKey), '<NULL>'), '|',
        Source.VehicleScope, '|', Source.DataStatus, '|',
        COALESCE(Source.SourceURL, N'<NULL>')))) AS AttributeHash
) AS HashValue
WHERE Source.IsValid = 1;
GO

CREATE OR ALTER VIEW publish.vDimCameraSource
AS
WITH CameraValue AS
(
    SELECT DISTINCT LoadBatchKey, CameraID, SegmentID
    FROM transform.TrafficObservationClean
    WHERE IsValid = 1 AND DuplicateRank = 1
)
SELECT
    Source.LoadBatchKey,
    Source.CameraID,
    Segment.SegmentKey,
    CONVERT(varchar(30), 'ACTIVE') AS CameraStatus,
    CONVERT(datetime2(3), SYSUTCDATETIME()) AS ValidFrom,
    CONVERT(datetime2(3), NULL) AS ValidTo,
    CONVERT(bit, 1) AS IsCurrent,
    HashValue.AttributeHash,
    CONVERT(char(64), HashValue.AttributeHash, 2) AS SourceHashHex
FROM CameraValue AS Source
LEFT JOIN DanangSmartParkingDW.dwh.DimRoadSegment AS Segment
  ON Segment.SegmentID = Source.SegmentID AND Segment.IsCurrent = 1
CROSS APPLY
(
    SELECT CONVERT(binary(32), HASHBYTES('SHA2_256', CONCAT(
        Source.CameraID, '|',
        COALESCE(CONVERT(varchar(20), Segment.SegmentKey), '<NULL>'),
        '|ACTIVE'))) AS AttributeHash
) AS HashValue;
GO

USE DanangSmartParkingDW;
GO

CREATE OR ALTER PROCEDURE etl.usp_PrecheckDimensionLoad
    @LoadBatchKey bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 52600, 'Package 30 requires a positive LoadBatchKey.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'SILVER_VALIDATED'
          AND ErrorMessage IS NULL
          AND CompletedAt IS NULL
    )
        THROW 52601, 'Package 30 requires a SILVER_VALIDATED, open batch.', 1;

    IF OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimDateSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimTimeSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimCitySource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimRoadSideSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimVehicleTypeSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimPOICategorySource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimWeatherSourceSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimAnalysisZoneSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimRoadSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimParkingFacilitySource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimPOISource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimRoadSegmentSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimParkingRestrictionSource', N'V') IS NULL
       OR OBJECT_ID(N'DanangSmartParkingSTG.publish.vDimCameraSource', N'V') IS NULL
        THROW 52602, 'Dimension source views are missing. Run sql/26_prepare_dimension_data_flow.sql.', 1;

    IF OBJECT_ID(N'dwh.DimDate', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimTime', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimCity', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimRoadSide', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimVehicleType', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimPOICategory', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimWeatherSource', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimAnalysisZone', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimRoad', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimRoadSegment', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimCamera', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimParkingRestriction', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimParkingFacility', N'U') IS NULL
       OR OBJECT_ID(N'dwh.DimPOI', N'U') IS NULL
        THROW 52603, 'One or more DWH dimension tables are missing.', 1;

    EXEC DanangSmartParkingSTG.dbo.usp_ValidateTransformBatch
        @LoadBatchKey = @LoadBatchKey,
        @ReturnDetail = 0;

    /*
        Fail before the first Data Flow writes to the DWH when a publish view
        does not expose the complete Silver input. Child views are allowed to
        contain NULL surrogate keys here because their parents are loaded by
        earlier Data Flow levels; the postcheck validates those relationships.
    */
    DECLARE @SourceChecks TABLE
    (
        CheckOrder int NOT NULL,
        SourceObject sysname NOT NULL,
        ActualRows bigint NOT NULL,
        ExpectedRows bigint NOT NULL
    );

    INSERT @SourceChecks
        (CheckOrder, SourceObject, ActualRows, ExpectedRows)
    VALUES
        (1, N'publish.vDimDateSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimDateSource
          WHERE LoadBatchKey = @LoadBatchKey), 7),
        (2, N'publish.vDimTimeSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimTimeSource), 1440),
        (3, N'publish.vDimCitySource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimCitySource), 1),
        (4, N'publish.vDimRoadSideSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimRoadSideSource), 5),
        (5, N'publish.vDimVehicleTypeSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimVehicleTypeSource), 5),
        (6, N'publish.vDimPOICategorySource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimPOICategorySource
          WHERE LoadBatchKey = @LoadBatchKey), 18),
        (7, N'publish.vDimWeatherSourceSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimWeatherSourceSource
          WHERE LoadBatchKey = @LoadBatchKey), 1),
        (8, N'publish.vDimAnalysisZoneSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource
          WHERE LoadBatchKey = @LoadBatchKey), 10),
        (9, N'publish.vDimRoadSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimRoadSource
          WHERE LoadBatchKey = @LoadBatchKey), 30),
        (10, N'publish.vDimParkingFacilitySource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimParkingFacilitySource
          WHERE LoadBatchKey = @LoadBatchKey), 20),
        (11, N'publish.vDimPOISource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimPOISource
          WHERE LoadBatchKey = @LoadBatchKey), 50),
        (12, N'publish.vDimRoadSegmentSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimRoadSegmentSource
          WHERE LoadBatchKey = @LoadBatchKey), 30),
        (13, N'publish.vDimParkingRestrictionSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimParkingRestrictionSource
          WHERE LoadBatchKey = @LoadBatchKey), 18),
        (14, N'publish.vDimCameraSource',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimCameraSource
          WHERE LoadBatchKey = @LoadBatchKey), 25);

    SELECT
        CheckOrder,
        SourceObject,
        ActualRows,
        ExpectedRows,
        CONVERT(bit, CASE WHEN ActualRows = ExpectedRows THEN 1 ELSE 0 END)
            AS IsMatched
    FROM @SourceChecks
    ORDER BY CheckOrder;

    IF EXISTS
    (
        SELECT 1
        FROM @SourceChecks
        WHERE ActualRows <> ExpectedRows
    )
        THROW 52604, 'Dimension source row counts are invalid. Review the precheck result set.', 1;

    SELECT
        'PASS' AS PrecheckStatus,
        @LoadBatchKey AS LoadBatchKey,
        'SILVER_VALIDATED input is ready for dimension Data Flows' AS Message;
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_ValidateDimensionLoad
    @LoadBatchKey bigint,
    @ReturnDetail bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 52610, 'Package 30 validation requires a positive LoadBatchKey.', 1;

    DECLARE @Failures TABLE
    (
        CheckName nvarchar(200) NOT NULL,
        ActualValue nvarchar(200) NULL,
        ExpectedValue nvarchar(200) NOT NULL
    );

    DECLARE @Checks TABLE
    (
        CheckOrder int NOT NULL,
        CheckName nvarchar(200) NOT NULL,
        ActualValue bigint NOT NULL,
        ExpectedValue bigint NOT NULL
    );

    INSERT @Checks VALUES
        (1, N'DimDate members from Silver batch',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimDateSource AS S
          JOIN dwh.DimDate AS D ON D.DateKey = S.DateKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 7),
        (2, N'DimTime full minute members',
         (SELECT COUNT_BIG(*) FROM dwh.DimTime), 1440),
        (3, N'DimCity Type 1 values',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimCitySource AS S
          JOIN dwh.DimCity AS D
            ON D.CityCode = S.CityCode
           AND D.CityName = S.CityName
           AND (D.PopulationReference = S.PopulationReference
                OR (D.PopulationReference IS NULL AND S.PopulationReference IS NULL))
           AND (D.AreaKm2Reference = S.AreaKm2Reference
                OR (D.AreaKm2Reference IS NULL AND S.AreaKm2Reference IS NULL))
           AND (D.FormerPopulationReference = S.FormerPopulationReference
                OR (D.FormerPopulationReference IS NULL AND S.FormerPopulationReference IS NULL))
           AND (D.ScopeNote = S.ScopeNote OR (D.ScopeNote IS NULL AND S.ScopeNote IS NULL))
           AND (D.DataWarning = S.DataWarning OR (D.DataWarning IS NULL AND S.DataWarning IS NULL))), 1),
        (4, N'DimRoadSide members',
         (SELECT COUNT_BIG(*) FROM dwh.DimRoadSide), 5),
        (5, N'DimVehicleType members',
         (SELECT COUNT_BIG(*) FROM dwh.DimVehicleType), 5),
        (6, N'DimPOICategory source coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimPOICategorySource AS S
          JOIN dwh.DimPOICategory AS D
            ON D.CategoryCode = S.CategoryCode
           AND D.CategoryName = S.CategoryName
          WHERE S.LoadBatchKey = @LoadBatchKey), 18),
        (7, N'DimWeatherSource source coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimWeatherSourceSource AS S
          JOIN dwh.DimWeatherSource AS D
            ON D.TemperatureStatus = S.TemperatureStatus
           AND D.PrecipitationStatus = S.PrecipitationStatus
           AND D.SourceReference = S.SourceReference
          WHERE S.LoadBatchKey = @LoadBatchKey), 1),
        (8, N'DimAnalysisZone source coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource AS S
          JOIN dwh.DimAnalysisZone AS D
            ON D.ZoneBusinessKey = S.ZoneBusinessKey
           AND D.ZoneName = S.ZoneName
           AND D.ZoneType = S.ZoneType
           AND D.IsCoastal = S.IsCoastal
           AND D.CityKey = S.CityKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 10),
        (9, N'DimRoad current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimRoadSource AS S
          JOIN dwh.DimRoad AS D
            ON D.RoadID = S.RoadID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND D.ZoneKey = S.ZoneKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 30),
        (10, N'DimParkingFacility current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimParkingFacilitySource AS S
          JOIN dwh.DimParkingFacility AS D
            ON D.ParkingID = S.ParkingID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND D.ZoneKey = S.ZoneKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 20),
        (11, N'DimPOI current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimPOISource AS S
          JOIN dwh.DimPOI AS D
            ON D.POIID = S.POIID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND D.ZoneKey = S.ZoneKey
           AND D.POICategoryKey = S.POICategoryKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 50),
        (12, N'DimRoadSegment current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimRoadSegmentSource AS S
          JOIN dwh.DimRoadSegment AS D
            ON D.SegmentID = S.SegmentID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND D.RoadKey = S.RoadKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 30),
        (13, N'DimParkingRestriction current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimParkingRestrictionSource AS S
          JOIN dwh.DimParkingRestriction AS D
            ON D.RestrictionID = S.RestrictionID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND (D.RoadKey = S.RoadKey OR (D.RoadKey IS NULL AND S.RoadKey IS NULL))
          WHERE S.LoadBatchKey = @LoadBatchKey), 18),
        (14, N'DimCamera current/hash coverage',
         (SELECT COUNT_BIG(*)
          FROM DanangSmartParkingSTG.publish.vDimCameraSource AS S
          JOIN dwh.DimCamera AS D
            ON D.CameraID = S.CameraID AND D.IsCurrent = 1
           AND D.AttributeHash = S.AttributeHash
           AND D.SegmentKey = S.SegmentKey
          WHERE S.LoadBatchKey = @LoadBatchKey), 25),
        (15, N'DimRoad current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimRoad WHERE IsCurrent = 1), 30),
        (16, N'DimParkingFacility current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimParkingFacility WHERE IsCurrent = 1), 20),
        (17, N'DimPOI current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimPOI WHERE IsCurrent = 1), 50),
        (18, N'DimRoadSegment current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimRoadSegment WHERE IsCurrent = 1), 30),
        (19, N'DimParkingRestriction current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimParkingRestriction WHERE IsCurrent = 1), 18),
        (20, N'DimCamera current total',
         (SELECT COUNT_BIG(*) FROM dwh.DimCamera WHERE IsCurrent = 1), 25);

    INSERT @Failures (CheckName, ActualValue, ExpectedValue)
    SELECT CheckName, CONVERT(nvarchar(30), ActualValue), CONVERT(nvarchar(30), ExpectedValue)
    FROM @Checks
    WHERE ActualValue <> ExpectedValue;

    DECLARE @DuplicateCurrent bigint =
          (SELECT COUNT_BIG(*) FROM
           (SELECT RoadID FROM dwh.DimRoad WHERE IsCurrent = 1
            GROUP BY RoadID HAVING COUNT_BIG(*) > 1) AS D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT SegmentID FROM dwh.DimRoadSegment WHERE IsCurrent = 1
            GROUP BY SegmentID HAVING COUNT_BIG(*) > 1) AS D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT CameraID FROM dwh.DimCamera WHERE IsCurrent = 1
            GROUP BY CameraID HAVING COUNT_BIG(*) > 1) AS D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT RestrictionID FROM dwh.DimParkingRestriction WHERE IsCurrent = 1
            GROUP BY RestrictionID HAVING COUNT_BIG(*) > 1) AS D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT ParkingID FROM dwh.DimParkingFacility WHERE IsCurrent = 1
            GROUP BY ParkingID HAVING COUNT_BIG(*) > 1) AS D)
        + (SELECT COUNT_BIG(*) FROM
           (SELECT POIID FROM dwh.DimPOI WHERE IsCurrent = 1
            GROUP BY POIID HAVING COUNT_BIG(*) > 1) AS D);

    IF @DuplicateCurrent <> 0
        INSERT @Failures VALUES
            (N'Duplicate current SCD business keys', CONVERT(nvarchar(30), @DuplicateCurrent), N'0');

    DECLARE @Orphans bigint =
          (SELECT COUNT_BIG(*) FROM dwh.DimAnalysisZone AS C
           LEFT JOIN dwh.DimCity AS P ON P.CityKey = C.CityKey WHERE P.CityKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimRoad AS C
           LEFT JOIN dwh.DimAnalysisZone AS P ON P.ZoneKey = C.ZoneKey WHERE P.ZoneKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimParkingFacility AS C
           LEFT JOIN dwh.DimAnalysisZone AS P ON P.ZoneKey = C.ZoneKey WHERE P.ZoneKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimPOI AS C
           LEFT JOIN dwh.DimAnalysisZone AS Z ON Z.ZoneKey = C.ZoneKey
           LEFT JOIN dwh.DimPOICategory AS K ON K.POICategoryKey = C.POICategoryKey
           WHERE Z.ZoneKey IS NULL OR K.POICategoryKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimRoadSegment AS C
           LEFT JOIN dwh.DimRoad AS R ON R.RoadKey = C.RoadKey
           LEFT JOIN dwh.DimRoadSide AS S ON S.RoadSideKey = C.ObservedRoadSideKey
           WHERE R.RoadKey IS NULL OR S.RoadSideKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimParkingRestriction AS C
           LEFT JOIN dwh.DimRoad AS R ON R.RoadKey = C.RoadKey
           LEFT JOIN dwh.DimRoadSide AS S ON S.RoadSideKey = C.RoadSideKey
           WHERE (C.RoadKey IS NOT NULL AND R.RoadKey IS NULL) OR S.RoadSideKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dwh.DimCamera AS C
           LEFT JOIN dwh.DimRoadSegment AS P ON P.SegmentKey = C.SegmentKey
           WHERE P.SegmentKey IS NULL);

    IF @Orphans <> 0
        INSERT @Failures VALUES
            (N'Dimension foreign-key orphans', CONVERT(nvarchar(30), @Orphans), N'0');

    DECLARE @R003NullRoad bigint =
    (
        SELECT COUNT_BIG(*)
        FROM dwh.DimParkingRestriction
        WHERE RestrictionID = 'R003' AND IsCurrent = 1 AND RoadKey IS NULL
    );

    IF @R003NullRoad <> 1
        INSERT @Failures VALUES
            (N'R003 intentional NULL RoadKey', CONVERT(nvarchar(30), @R003NullRoad), N'1');

    DECLARE @RoadName nvarchar(150);
    DECLARE @ZoneName nvarchar(100);

    SELECT
        @RoadName = Road.RoadName,
        @ZoneName = Zone.ZoneName
    FROM dwh.DimRoad AS Road
    JOIN dwh.DimAnalysisZone AS Zone ON Zone.ZoneKey = Road.ZoneKey
    WHERE Road.RoadID = 'RD001' AND Road.IsCurrent = 1;

    IF @RoadName IS NULL
       OR @ZoneName IS NULL
       OR @RoadName <> N'Trần Phú'
       OR @ZoneName <> N'Hải Châu core'
        INSERT @Failures VALUES
        (
            N'Dimension Unicode checkpoint',
            CONCAT(COALESCE(@RoadName, N'NULL'), N' / ', COALESCE(@ZoneName, N'NULL')),
            N'Trần Phú / Hải Châu core'
        );

    IF @ReturnDetail = 1
    BEGIN
        SELECT
            CheckOrder,
            CheckName,
            ActualValue,
            ExpectedValue,
            CONVERT(bit, CASE WHEN ActualValue = ExpectedValue THEN 1 ELSE 0 END) AS IsMatched
        FROM @Checks
        ORDER BY CheckOrder;

        SELECT
            @DuplicateCurrent AS DuplicateCurrentBusinessKeys,
            @Orphans AS ForeignKeyOrphans,
            @R003NullRoad AS R003IntentionalNullRoad,
            @RoadName AS UnicodeRoadName,
            @ZoneName AS UnicodeZoneName;
    END;

    IF EXISTS (SELECT 1 FROM @Failures)
    BEGIN
        SELECT CheckName, ActualValue, ExpectedValue
        FROM @Failures
        ORDER BY CheckName;

        THROW 52699, 'PACKAGE 30 DIMENSION VALIDATION FAILED. Review the Failures result set.', 1;
    END;

    SELECT
        'PASS' AS AcceptanceStatus,
        @LoadBatchKey AS LoadBatchKey,
        'PACKAGE 30 DIMENSIONS ACCEPTED - ready for package 40 facts' AS Message;
END;
GO

SELECT
    'PASS' AS InstallStatus,
    'Package 30 source views and validation procedures are ready' AS Message;
GO
