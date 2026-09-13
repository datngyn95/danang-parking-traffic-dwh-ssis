/*
    Da Nang Smart Parking - Staging database
    Phase 1: extract tables keep source-aligned strings.
    Phase 2: transform tables keep typed, validated and deduplicated rows.
*/

IF DB_ID(N'DanangSmartParkingSTG') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE DanangSmartParkingSTG;');
END;
GO

USE DanangSmartParkingSTG;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'extract')
    EXEC(N'CREATE SCHEMA extract AUTHORIZATION dbo;');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'transform')
    EXEC(N'CREATE SCHEMA transform AUTHORIZATION dbo;');
GO

/* =========================================================
   EXTRACT: source-aligned, no business conversion
   ========================================================= */

CREATE TABLE extract.RoadRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    RoadID nvarchar(50) NULL,
    RoadName nvarchar(200) NULL,
    AnalysisZone nvarchar(150) NULL,
    RoadClass nvarchar(50) NULL,
    LanesRaw nvarchar(30) NULL,
    SpeedLimitKmhRaw nvarchar(30) NULL,
    RoadWidthMRaw nvarchar(30) NULL,
    LengthKmRaw nvarchar(30) NULL,
    CityPopulationReferenceRaw nvarchar(30) NULL,
    NameStatus nvarchar(80) NULL,
    GeometryStatus nvarchar(80) NULL,
    WidthStatus nvarchar(80) NULL,
    SourceNote nvarchar(2000) NULL,
    GeometryJson nvarchar(max) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractRoad_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractRoad_Row CHECK (SourceRowNumber > 0)
);
GO

CREATE TABLE extract.ParkingLocationRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    ParkingID nvarchar(50) NULL,
    ParkingName nvarchar(250) NULL,
    AddressOrCorridor nvarchar(250) NULL,
    AnalysisZone nvarchar(150) NULL,
    CapacitySpacesRaw nvarchar(30) NULL,
    ParkingType nvarchar(100) NULL,
    FacilityStatus nvarchar(100) NULL,
    CapacityStatus nvarchar(100) NULL,
    CoordinateStatus nvarchar(200) NULL,
    LatitudeRaw nvarchar(50) NULL,
    LongitudeRaw nvarchar(50) NULL,
    SourceURL nvarchar(1000) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractParkingLocation_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractParkingLocation_Row CHECK (SourceRowNumber >= 2)
);
GO

CREATE TABLE extract.ParkingRestrictionRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    RestrictionID nvarchar(50) NULL,
    RoadID nvarchar(50) NULL,
    RoadName nvarchar(200) NULL,
    RestrictionType nvarchar(100) NULL,
    StartTimeRaw nvarchar(30) NULL,
    EndTimeRaw nvarchar(30) NULL,
    SideCode nvarchar(30) NULL,
    VehicleScope nvarchar(50) NULL,
    DataStatus nvarchar(100) NULL,
    SourceURL nvarchar(1000) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractRestriction_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractRestriction_Row CHECK (SourceRowNumber >= 2)
);
GO

CREATE TABLE extract.POIRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    POIID nvarchar(50) NULL,
    POIName nvarchar(250) NULL,
    CategoryCode nvarchar(100) NULL,
    AnalysisZone nvarchar(150) NULL,
    ParkingDemandWeightRaw nvarchar(30) NULL,
    DataStatus nvarchar(100) NULL,
    LatitudeRaw nvarchar(50) NULL,
    LongitudeRaw nvarchar(50) NULL,
    GeometryJson nvarchar(max) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractPOI_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractPOI_Row CHECK (SourceRowNumber > 0)
);
GO

CREATE TABLE extract.RoadSurveyRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    SegmentID nvarchar(50) NULL,
    RoadID nvarchar(50) NULL,
    RoadName nvarchar(200) NULL,
    AnalysisZone nvarchar(150) NULL,
    RoadWidthMRaw nvarchar(30) NULL,
    LaneCountRaw nvarchar(30) NULL,
    SidewalkWidthMRaw nvarchar(30) NULL,
    ShoulderWidthMRaw nvarchar(30) NULL,
    ObservedParkingSides nvarchar(30) NULL,
    DataStatus nvarchar(100) NULL,
    QualityConfidenceRaw nvarchar(30) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractRoadSurvey_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractRoadSurvey_Row CHECK (SourceRowNumber >= 2)
);
GO

CREATE TABLE extract.TrafficEventRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    EventID nvarchar(80) NULL,
    EventTimestampRaw nvarchar(50) NULL,
    EventDateRaw nvarchar(30) NULL,
    HourRaw nvarchar(30) NULL,
    CameraID nvarchar(50) NULL,
    SegmentID nvarchar(50) NULL,
    RoadID nvarchar(50) NULL,
    RoadName nvarchar(200) NULL,
    AnalysisZone nvarchar(150) NULL,
    VehicleCountRaw nvarchar(30) NULL,
    MotorbikeCountRaw nvarchar(30) NULL,
    CarCountRaw nvarchar(30) NULL,
    BusCountRaw nvarchar(30) NULL,
    TruckCountRaw nvarchar(30) NULL,
    AvgSpeedKmhRaw nvarchar(30) NULL,
    ParkedVehicleCountRaw nvarchar(30) NULL,
    IllegalParkingCountRaw nvarchar(30) NULL,
    RoadWidthMRaw nvarchar(30) NULL,
    ParkingOccupiedWidthMRaw nvarchar(30) NULL,
    EffectiveWidthMRaw nvarchar(30) NULL,
    WidthLossPctRaw nvarchar(30) NULL,
    CongestionIndexRaw nvarchar(30) NULL,
    RainMmRaw nvarchar(30) NULL,
    CityPopulationReferenceRaw nvarchar(30) NULL,
    DataStatus nvarchar(100) NULL,
    GeneratorSeedRaw nvarchar(30) NULL,
    RawJson nvarchar(max) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractTraffic_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractTraffic_Row CHECK (SourceRowNumber > 0)
);
GO

CREATE TABLE extract.ParkingEventRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    EventID nvarchar(80) NULL,
    VehicleID nvarchar(80) NULL,
    RoadID nvarchar(50) NULL,
    RoadName nvarchar(200) NULL,
    SegmentID nvarchar(50) NULL,
    StartTimeRaw nvarchar(50) NULL,
    EndTimeRaw nvarchar(50) NULL,
    EventDateRaw nvarchar(30) NULL,
    VehicleTypeCode nvarchar(50) NULL,
    SideCode nvarchar(30) NULL,
    ParkingDurationMinRaw nvarchar(30) NULL,
    OccupiedWidthMRaw nvarchar(30) NULL,
    LegalParkingRaw nvarchar(20) NULL,
    ActiveRestrictionID nvarchar(50) NULL,
    AnalysisZone nvarchar(150) NULL,
    DataStatus nvarchar(100) NULL,
    CityPopulationReferenceRaw nvarchar(30) NULL,
    RawJson nvarchar(max) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractParkingEvent_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractParkingEvent_Row CHECK (SourceRowNumber > 0)
);
GO

CREATE TABLE extract.WeatherEventRaw
(
    StageRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    WeatherTimestampRaw nvarchar(50) NULL,
    EventDateRaw nvarchar(30) NULL,
    HourRaw nvarchar(30) NULL,
    TemperatureCRaw nvarchar(30) NULL,
    DailyMinCActualRaw nvarchar(30) NULL,
    DailyMaxCActualRaw nvarchar(30) NULL,
    DailyReferenceCActualRaw nvarchar(30) NULL,
    RainMmRaw nvarchar(30) NULL,
    HumidityPctRaw nvarchar(30) NULL,
    VisibilityKmRaw nvarchar(30) NULL,
    WindKmhRaw nvarchar(30) NULL,
    TemperatureStatus nvarchar(100) NULL,
    PrecipitationStatus nvarchar(100) NULL,
    SourceReference nvarchar(500) NULL,
    RawJson nvarchar(max) NULL,
    RecordHashSHA256 binary(32) NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractWeather_FileRow UNIQUE (LoadFileKey, SourceRowNumber),
    CONSTRAINT CK_ExtractWeather_Row CHECK (SourceRowNumber > 0)
);
GO

/* =========================================================
   TRANSFORM: typed, validated, deduplicated
   ========================================================= */

CREATE TABLE transform.RoadClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    RoadID varchar(10) NULL,
    RoadName nvarchar(150) NULL,
    AnalysisZone nvarchar(100) NULL,
    RoadClass varchar(30) NULL,
    LaneCount tinyint NULL,
    SpeedLimitKmh smallint NULL,
    RoadWidthM decimal(6,2) NULL,
    LengthKm decimal(8,3) NULL,
    NameStatus varchar(40) NULL,
    GeometryStatus varchar(50) NULL,
    WidthStatus varchar(50) NULL,
    SourceNote nvarchar(1000) NULL,
    GeometryJson nvarchar(max) NULL,
    AttributeHash binary(32) NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE transform.ParkingFacilityClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    ParkingID varchar(20) NULL,
    ParkingName nvarchar(200) NULL,
    AddressOrCorridor nvarchar(250) NULL,
    AnalysisZone nvarchar(100) NULL,
    CapacitySpaces int NULL,
    ParkingType varchar(60) NULL,
    FacilityStatus varchar(50) NULL,
    CapacityStatus varchar(60) NULL,
    CoordinateStatus nvarchar(100) NULL,
    Latitude decimal(9,6) NULL,
    Longitude decimal(9,6) NULL,
    SourceURL nvarchar(500) NULL,
    IsReferenceCapacity bit NULL,
    AttributeHash binary(32) NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE transform.ParkingRestrictionClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    RestrictionID varchar(20) NULL,
    RoadID varchar(10) NULL,
    RoadName nvarchar(150) NULL,
    RestrictionType varchar(40) NULL,
    StartTime time(0) NULL,
    EndTime time(0) NULL,
    SideCode varchar(10) NULL,
    VehicleScope varchar(30) NULL,
    DataStatus varchar(50) NULL,
    SourceURL nvarchar(500) NULL,
    AttributeHash binary(32) NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE transform.POIClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    POIID varchar(20) NULL,
    POIName nvarchar(200) NULL,
    CategoryCode varchar(50) NULL,
    AnalysisZone nvarchar(100) NULL,
    ParkingDemandWeight decimal(6,3) NULL,
    DataStatus varchar(50) NULL,
    Latitude decimal(9,6) NULL,
    Longitude decimal(9,6) NULL,
    AttributeHash binary(32) NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE transform.RoadSurveyClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    SegmentID varchar(20) NULL,
    RoadID varchar(10) NULL,
    RoadName nvarchar(150) NULL,
    AnalysisZone nvarchar(100) NULL,
    RoadWidthRawM decimal(6,2) NULL,
    RoadWidthResolvedM decimal(6,2) NULL,
    LaneCount tinyint NULL,
    SidewalkWidthM decimal(6,2) NULL,
    ShoulderWidthM decimal(6,2) NULL,
    ObservedParkingSides varchar(10) NULL,
    DataStatus varchar(50) NULL,
    QualityConfidence decimal(5,4) NULL,
    WidthImputedFlag bit NOT NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE transform.TrafficObservationClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    EventID varchar(50) NULL,
    EventTimestamp datetime2(0) NULL,
    EventDate date NULL,
    HourNumber tinyint NULL,
    CameraID varchar(20) NULL,
    SegmentID varchar(20) NULL,
    RoadID varchar(10) NULL,
    RoadName nvarchar(150) NULL,
    AnalysisZone nvarchar(100) NULL,
    VehicleCount int NULL,
    MotorbikeCount int NULL,
    CarCount int NULL,
    BusCount int NULL,
    TruckCount int NULL,
    AvgSpeedKmh decimal(6,2) NULL,
    ParkedVehicleCount smallint NULL,
    IllegalParkingCount smallint NULL,
    RoadWidthM decimal(6,2) NULL,
    ParkingOccupiedWidthM decimal(6,2) NULL,
    EffectiveWidthM decimal(6,2) NULL,
    WidthLossPct decimal(6,2) NULL,
    CongestionIndex decimal(7,4) NULL,
    RainMm decimal(7,2) NULL,
    DuplicateRank int NOT NULL,
    SpeedMissingFlag bit NOT NULL,
    VehicleMixValidFlag bit NOT NULL,
    ParkingCountValidFlag bit NOT NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    RecordHashSHA256 binary(32) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_TransformTraffic_BatchEvent
    ON transform.TrafficObservationClean(LoadBatchKey, EventID, DuplicateRank);
GO

CREATE TABLE transform.ParkingEventClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    EventID varchar(30) NULL,
    VehicleID varchar(30) NULL,
    RoadID varchar(10) NULL,
    RoadName nvarchar(150) NULL,
    SegmentID varchar(20) NULL,
    StartTimestamp datetime2(6) NULL,
    EndTimestamp datetime2(6) NULL,
    EventDate date NULL,
    VehicleTypeCode varchar(30) NULL,
    SideCode varchar(10) NULL,
    ParkingDurationMin smallint NULL,
    OccupiedWidthM decimal(5,2) NULL,
    IsLegalParking bit NULL,
    ActiveRestrictionID varchar(20) NULL,
    AnalysisZone nvarchar(100) NULL,
    DuplicateRank int NOT NULL,
    IsOpenEvent bit NOT NULL,
    IsDurationEstimated bit NOT NULL,
    RestrictionLinkMissingFlag bit NOT NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    RecordHashSHA256 binary(32) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_TransformParking_BatchEvent
    ON transform.ParkingEventClean(LoadBatchKey, EventID, DuplicateRank);
GO

CREATE TABLE transform.WeatherHourlyClean
(
    TransformRowKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    LoadBatchKey bigint NOT NULL,
    LoadFileKey bigint NOT NULL,
    SourceRowNumber bigint NOT NULL,
    WeatherTimestamp datetime2(0) NULL,
    EventDate date NULL,
    HourNumber tinyint NULL,
    TemperatureC decimal(5,2) NULL,
    DailyMinCActual decimal(5,2) NULL,
    DailyMaxCActual decimal(5,2) NULL,
    DailyReferenceCActual decimal(5,2) NULL,
    RainMm decimal(7,2) NULL,
    HumidityPct decimal(5,2) NULL,
    VisibilityKm decimal(6,2) NULL,
    WindKmh decimal(6,2) NULL,
    TemperatureStatus varchar(80) NULL,
    PrecipitationStatus varchar(40) NULL,
    SourceReference nvarchar(300) NULL,
    IsRainyHour bit NOT NULL,
    IsValid bit NOT NULL,
    RejectReason nvarchar(1000) NULL,
    RecordHashSHA256 binary(32) NULL,
    TransformedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Transform aggregates are QA/summary inputs; core DW facts keep atomic grain. */
CREATE TABLE transform.TrafficHourlySummary
(
    LoadBatchKey bigint NOT NULL,
    EventDate date NOT NULL,
    HourNumber tinyint NOT NULL,
    RoadID varchar(10) NOT NULL,
    VehicleVolume bigint NOT NULL,
    AvgSpeedKmh decimal(12,4) NULL,
    AvgCongestionIndex decimal(12,6) NULL,
    IllegalParkingObserved bigint NOT NULL,
    CONSTRAINT PK_TransformTrafficHourlySummary
        PRIMARY KEY (LoadBatchKey, EventDate, HourNumber, RoadID)
);
GO

CREATE TABLE transform.ParkingDailySummary
(
    LoadBatchKey bigint NOT NULL,
    EventDate date NOT NULL,
    RoadID varchar(10) NOT NULL,
    VehicleTypeCode varchar(30) NOT NULL,
    ParkingEventCount bigint NOT NULL,
    IllegalEventCount bigint NOT NULL,
    AvgDurationMin decimal(12,4) NULL,
    OpenEventCount bigint NOT NULL,
    CONSTRAINT PK_TransformParkingDailySummary
        PRIMARY KEY (LoadBatchKey, EventDate, RoadID, VehicleTypeCode)
);
GO
