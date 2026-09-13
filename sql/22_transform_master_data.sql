/*
    Da Nang Smart Parking
    Package 20 - Transform all master data with one set-based procedure.

    Input status : BRONZE_LOADED
    Output       : five transform.*Clean tables for the current batch
    Status after success remains BRONZE_LOADED. Package 23 owns SILVER_VALIDATED.
*/

USE DanangSmartParkingSTG;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TransformMasterData
    @LoadBatchKey bigint,
    @ReturnDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 51600, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 51601, 'LoadBatchKey does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'BRONZE_LOADED'
    )
        THROW 51602, 'Master transform requires a BRONZE_LOADED batch.', 1;

    BEGIN TRY
        /* Fail before deleting a previously successful transform result. */
        IF (SELECT COUNT_BIG(*) FROM extract.RoadRaw
            WHERE LoadBatchKey = @LoadBatchKey) <> 30
           OR (SELECT COUNT_BIG(*) FROM extract.ParkingLocationRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 20
           OR (SELECT COUNT_BIG(*) FROM extract.ParkingRestrictionRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 18
           OR (SELECT COUNT_BIG(*) FROM extract.POIRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 50
           OR (SELECT COUNT_BIG(*) FROM extract.RoadSurveyRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 30
            THROW 51603, 'One or more master RAW tables differ from the expected row count.', 1;

        BEGIN TRANSACTION;

        /* Idempotent rerun for this batch only. */
        DELETE Rejected
        FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
        JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
          ON LoadFile.LoadFileKey = Rejected.LoadFileKey
        WHERE LoadFile.LoadBatchKey = @LoadBatchKey
          AND Rejected.RuleCode IN
          (
              'TRN_ROAD_INVALID',
              'TRN_FACILITY_INVALID',
              'TRN_RESTRICTION_INVALID',
              'TRN_POI_INVALID',
              'TRN_SURVEY_INVALID'
          );

        DELETE FROM transform.RoadSurveyClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.POIClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.ParkingRestrictionClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.ParkingFacilityClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.RoadClean
        WHERE LoadBatchKey = @LoadBatchKey;

        /* =============================================================
           1. ROAD MASTER
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.RoadID)), N'') AS RoadIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadName)), N'') AS RoadNameText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.RoadClass))), N'') AS RoadClassText,
                NULLIF(LTRIM(RTRIM(Raw.LanesRaw)), N'') AS LaneCountText,
                NULLIF(LTRIM(RTRIM(Raw.SpeedLimitKmhRaw)), N'') AS SpeedLimitText,
                NULLIF(LTRIM(RTRIM(Raw.RoadWidthMRaw)), N'') AS RoadWidthText,
                NULLIF(LTRIM(RTRIM(Raw.LengthKmRaw)), N'') AS LengthKmText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.NameStatus))), N'') AS NameStatusText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.GeometryStatus))), N'') AS GeometryStatusText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.WidthStatus))), N'') AS WidthStatusText,
                NULLIF(LTRIM(RTRIM(Raw.SourceNote)), N'') AS SourceNoteText,
                Raw.GeometryJson,
                COUNT_BIG(*) OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.RoadID)), N'')
                ) AS BusinessKeyCount
            FROM extract.RoadRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(tinyint, LaneCountText) AS LaneCountValue,
                TRY_CONVERT(smallint, SpeedLimitText) AS SpeedLimitValue,
                TRY_CONVERT(decimal(6,2), RoadWidthText) AS RoadWidthValue,
                TRY_CONVERT(decimal(8,3), LengthKmText) AS LengthKmValue
            FROM Normalized
        ),
        Ruled AS
        (
            SELECT
                Typed.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN RoadIDText IS NULL THEN N'RoadID is required' END,
                    CASE WHEN LEN(RoadIDText) > 10 THEN N'RoadID exceeds 10 characters' END,
                    CASE WHEN BusinessKeyCount <> 1 THEN N'RoadID is duplicated in the batch' END,
                    CASE WHEN RoadNameText IS NULL THEN N'RoadName is required' END,
                    CASE WHEN LEN(RoadNameText) > 150 THEN N'RoadName exceeds 150 characters' END,
                    CASE WHEN AnalysisZoneText IS NULL THEN N'AnalysisZone is required' END,
                    CASE WHEN LEN(AnalysisZoneText) > 100 THEN N'AnalysisZone exceeds 100 characters' END,
                    CASE WHEN RoadClassText IS NULL
                                   OR RoadClassText NOT IN (N'PRIMARY', N'SECONDARY')
                         THEN N'RoadClass is not supported' END,
                    CASE WHEN LaneCountValue IS NULL OR LaneCountValue NOT BETWEEN 1 AND 12
                         THEN N'LaneCount is invalid' END,
                    CASE WHEN SpeedLimitValue IS NULL OR SpeedLimitValue NOT BETWEEN 1 AND 200
                         THEN N'SpeedLimitKmh is invalid' END,
                    CASE WHEN RoadWidthValue IS NULL OR RoadWidthValue <= 0
                         THEN N'RoadWidthM is invalid' END,
                    CASE WHEN LengthKmValue IS NULL OR LengthKmValue <= 0
                         THEN N'LengthKm is invalid' END,
                    CASE WHEN NameStatusText IS NULL OR LEN(NameStatusText) > 40
                         THEN N'NameStatus is invalid' END,
                    CASE WHEN GeometryStatusText IS NULL OR LEN(GeometryStatusText) > 50
                         THEN N'GeometryStatus is invalid' END,
                    CASE WHEN WidthStatusText IS NULL OR LEN(WidthStatusText) > 50
                         THEN N'WidthStatus is invalid' END,
                    CASE WHEN LEN(SourceNoteText) > 1000
                         THEN N'SourceNote exceeds 1000 characters' END,
                    CASE WHEN ISNULL(ISJSON(GeometryJson), 0) <> 1
                              OR JSON_VALUE
                                 (
                                     CASE WHEN ISJSON(GeometryJson) = 1
                                          THEN GeometryJson ELSE N'{}' END,
                                     '$.type'
                                 ) <> N'LineString'
                         THEN N'GeometryJson is not a LineString' END
                ), N'') AS RejectReasonValue
            FROM Typed
        )
        INSERT transform.RoadClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            RoadID, RoadName, AnalysisZone, RoadClass,
            LaneCount, SpeedLimitKmh, RoadWidthM, LengthKm,
            NameStatus, GeometryStatus, WidthStatus, SourceNote,
            GeometryJson, AttributeHash, IsValid, RejectReason
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(10), LEFT(RoadIDText, 10)),
            LEFT(RoadNameText, 150),
            LEFT(AnalysisZoneText, 100),
            CONVERT(varchar(30), LEFT(RoadClassText, 30)),
            LaneCountValue,
            SpeedLimitValue,
            RoadWidthValue,
            LengthKmValue,
            CONVERT(varchar(40), LEFT(NameStatusText, 40)),
            CONVERT(varchar(50), LEFT(GeometryStatusText, 50)),
            CONVERT(varchar(50), LEFT(WidthStatusText, 50)),
            LEFT(SourceNoteText, 1000),
            GeometryJson,
            HASHBYTES
            (
                'SHA2_256',
                CONVERT(varbinary(max), CONCAT
                (
                    N'ROAD|', COALESCE(RoadIDText, N'<NULL>'),
                    N'|', COALESCE(RoadNameText, N'<NULL>'),
                    N'|', COALESCE(AnalysisZoneText, N'<NULL>'),
                    N'|', COALESCE(RoadClassText, N'<NULL>'),
                    N'|', COALESCE(LaneCountText, N'<NULL>'),
                    N'|', COALESCE(SpeedLimitText, N'<NULL>'),
                    N'|', COALESCE(RoadWidthText, N'<NULL>'),
                    N'|', COALESCE(LengthKmText, N'<NULL>'),
                    N'|', COALESCE(NameStatusText, N'<NULL>'),
                    N'|', COALESCE(GeometryStatusText, N'<NULL>'),
                    N'|', COALESCE(WidthStatusText, N'<NULL>'),
                    N'|', COALESCE(SourceNoteText, N'<NULL>'),
                    N'|', COALESCE(GeometryJson, N'<NULL>')
                ))
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000)
        FROM Ruled;

        /* =============================================================
           2. PARKING FACILITY MASTER
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.ParkingID)), N'') AS ParkingIDText,
                NULLIF(LTRIM(RTRIM(Raw.ParkingName)), N'') AS ParkingNameText,
                NULLIF(LTRIM(RTRIM(Raw.AddressOrCorridor)), N'') AS AddressText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                NULLIF(LTRIM(RTRIM(Raw.CapacitySpacesRaw)), N'') AS CapacityText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.ParkingType))), N'') AS ParkingTypeText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.FacilityStatus))), N'') AS FacilityStatusText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.CapacityStatus))), N'') AS CapacityStatusText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.CoordinateStatus))), N'') AS CoordinateStatusText,
                NULLIF(LTRIM(RTRIM(Raw.LatitudeRaw)), N'') AS LatitudeText,
                NULLIF(LTRIM(RTRIM(Raw.LongitudeRaw)), N'') AS LongitudeText,
                NULLIF(LTRIM(RTRIM(Raw.SourceURL)), N'') AS SourceURLText,
                COUNT_BIG(*) OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.ParkingID)), N'')
                ) AS BusinessKeyCount
            FROM extract.ParkingLocationRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(int, CapacityText) AS CapacityValue,
                TRY_CONVERT(decimal(9,6), LatitudeText) AS LatitudeValue,
                TRY_CONVERT(decimal(9,6), LongitudeText) AS LongitudeValue
            FROM Normalized
        ),
        Ruled AS
        (
            SELECT
                Typed.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN ParkingIDText IS NULL THEN N'ParkingID is required' END,
                    CASE WHEN LEN(ParkingIDText) > 20 THEN N'ParkingID exceeds 20 characters' END,
                    CASE WHEN BusinessKeyCount <> 1 THEN N'ParkingID is duplicated in the batch' END,
                    CASE WHEN ParkingNameText IS NULL THEN N'ParkingName is required' END,
                    CASE WHEN LEN(ParkingNameText) > 200 THEN N'ParkingName exceeds 200 characters' END,
                    CASE WHEN AddressText IS NULL OR LEN(AddressText) > 250
                         THEN N'AddressOrCorridor is invalid' END,
                    CASE WHEN AnalysisZoneText IS NULL OR LEN(AnalysisZoneText) > 100
                         THEN N'AnalysisZone is invalid' END,
                    CASE WHEN CapacityValue IS NULL OR CapacityValue <= 0
                         THEN N'CapacitySpaces is invalid' END,
                    CASE WHEN ParkingTypeText IS NULL OR LEN(ParkingTypeText) > 60
                         THEN N'ParkingType is invalid' END,
                    CASE WHEN FacilityStatusText IS NULL OR LEN(FacilityStatusText) > 50
                         THEN N'FacilityStatus is invalid' END,
                    CASE WHEN CapacityStatusText IS NULL OR LEN(CapacityStatusText) > 60
                         THEN N'CapacityStatus is invalid' END,
                    CASE WHEN CoordinateStatusText IS NULL OR LEN(CoordinateStatusText) > 100
                         THEN N'CoordinateStatus is invalid' END,
                    CASE WHEN LatitudeValue IS NULL OR LatitudeValue NOT BETWEEN -90 AND 90
                         THEN N'Latitude is invalid' END,
                    CASE WHEN LongitudeValue IS NULL OR LongitudeValue NOT BETWEEN -180 AND 180
                         THEN N'Longitude is invalid' END,
                    CASE WHEN LEN(SourceURLText) > 500
                         THEN N'SourceURL exceeds 500 characters' END
                ), N'') AS RejectReasonValue
            FROM Typed
        )
        INSERT transform.ParkingFacilityClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            ParkingID, ParkingName, AddressOrCorridor, AnalysisZone,
            CapacitySpaces, ParkingType, FacilityStatus, CapacityStatus,
            CoordinateStatus, Latitude, Longitude, SourceURL,
            IsReferenceCapacity, AttributeHash, IsValid, RejectReason
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(20), LEFT(ParkingIDText, 20)),
            LEFT(ParkingNameText, 200),
            LEFT(AddressText, 250),
            LEFT(AnalysisZoneText, 100),
            CapacityValue,
            CONVERT(varchar(60), LEFT(ParkingTypeText, 60)),
            CONVERT(varchar(50), LEFT(FacilityStatusText, 50)),
            CONVERT(varchar(60), LEFT(CapacityStatusText, 60)),
            LEFT(CoordinateStatusText, 100),
            LatitudeValue,
            LongitudeValue,
            LEFT(SourceURLText, 500),
            CONVERT(bit, CASE WHEN CapacityStatusText LIKE N'REAL_CAPACITY%' THEN 1 ELSE 0 END),
            HASHBYTES
            (
                'SHA2_256',
                CONVERT(varbinary(max), CONCAT
                (
                    N'FACILITY|', COALESCE(ParkingIDText, N'<NULL>'),
                    N'|', COALESCE(ParkingNameText, N'<NULL>'),
                    N'|', COALESCE(AddressText, N'<NULL>'),
                    N'|', COALESCE(AnalysisZoneText, N'<NULL>'),
                    N'|', COALESCE(CapacityText, N'<NULL>'),
                    N'|', COALESCE(ParkingTypeText, N'<NULL>'),
                    N'|', COALESCE(FacilityStatusText, N'<NULL>'),
                    N'|', COALESCE(CapacityStatusText, N'<NULL>'),
                    N'|', COALESCE(CoordinateStatusText, N'<NULL>'),
                    N'|', COALESCE(LatitudeText, N'<NULL>'),
                    N'|', COALESCE(LongitudeText, N'<NULL>'),
                    N'|', COALESCE(SourceURLText, N'<NULL>')
                ))
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000)
        FROM Ruled;

        /* =============================================================
           3. PARKING RESTRICTION MASTER
           A blank RoadID is allowed (known source row R003).
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.RestrictionID)), N'') AS RestrictionIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadID)), N'') AS RoadIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadName)), N'') AS RoadNameText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.RestrictionType))), N'') AS RestrictionTypeText,
                NULLIF(LTRIM(RTRIM(Raw.StartTimeRaw)), N'') AS StartTimeText,
                NULLIF(LTRIM(RTRIM(Raw.EndTimeRaw)), N'') AS EndTimeText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.SideCode))), N'') AS SideCodeText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.VehicleScope))), N'') AS VehicleScopeText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.DataStatus))), N'') AS DataStatusText,
                NULLIF(LTRIM(RTRIM(Raw.SourceURL)), N'') AS SourceURLText,
                COUNT_BIG(*) OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.RestrictionID)), N'')
                ) AS BusinessKeyCount
            FROM extract.ParkingRestrictionRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(time(0), StartTimeText) AS StartTimeValue,
                TRY_CONVERT(time(0), EndTimeText) AS EndTimeValue
            FROM Normalized
        ),
        Referenced AS
        (
            SELECT
                Typed.*,
                RoadReference.RoadMatchCount,
                RoadReference.MasterRoadName
            FROM Typed
            OUTER APPLY
            (
                SELECT
                    COUNT_BIG(*) AS RoadMatchCount,
                    MAX(Road.RoadName) AS MasterRoadName
                FROM transform.RoadClean AS Road
                WHERE Road.LoadBatchKey = @LoadBatchKey
                  AND Road.IsValid = 1
                  AND Road.RoadID = Typed.RoadIDText
            ) AS RoadReference
        ),
        Ruled AS
        (
            SELECT
                Referenced.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN RestrictionIDText IS NULL THEN N'RestrictionID is required' END,
                    CASE WHEN LEN(RestrictionIDText) > 20
                         THEN N'RestrictionID exceeds 20 characters' END,
                    CASE WHEN BusinessKeyCount <> 1
                         THEN N'RestrictionID is duplicated in the batch' END,
                    CASE WHEN LEN(RoadIDText) > 10 THEN N'RoadID exceeds 10 characters' END,
                    CASE WHEN RoadIDText IS NOT NULL AND RoadMatchCount <> 1
                         THEN N'RoadID does not resolve to one valid road' END,
                    CASE WHEN RoadIDText IS NOT NULL AND RoadMatchCount = 1
                                   AND RoadNameText <> MasterRoadName
                         THEN N'RoadName does not match Road master' END,
                    CASE WHEN RoadNameText IS NULL OR LEN(RoadNameText) > 150
                         THEN N'RoadName is invalid' END,
                    CASE WHEN RestrictionTypeText IS NULL
                                   OR RestrictionTypeText NOT IN
                              (N'NO_PARKING', N'NO_STOPPING', N'ODD_EVEN_NO_PARKING')
                         THEN N'RestrictionType is not supported' END,
                    CASE WHEN StartTimeValue IS NULL THEN N'StartTime is invalid' END,
                    CASE WHEN EndTimeValue IS NULL THEN N'EndTime is invalid' END,
                    CASE WHEN SideCodeText IS NULL
                                   OR SideCodeText NOT IN (N'LEFT', N'RIGHT', N'BOTH')
                         THEN N'SideCode is not supported' END,
                    CASE WHEN VehicleScopeText IS NULL OR LEN(VehicleScopeText) > 30
                         THEN N'VehicleScope is invalid' END,
                    CASE WHEN DataStatusText IS NULL OR LEN(DataStatusText) > 50
                         THEN N'DataStatus is invalid' END,
                    CASE WHEN LEN(SourceURLText) > 500
                         THEN N'SourceURL exceeds 500 characters' END
                ), N'') AS RejectReasonValue
            FROM Referenced
        )
        INSERT transform.ParkingRestrictionClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            RestrictionID, RoadID, RoadName, RestrictionType,
            StartTime, EndTime, SideCode, VehicleScope, DataStatus,
            SourceURL, AttributeHash, IsValid, RejectReason
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(20), LEFT(RestrictionIDText, 20)),
            CONVERT(varchar(10), LEFT(RoadIDText, 10)),
            LEFT(RoadNameText, 150),
            CONVERT(varchar(40), LEFT(RestrictionTypeText, 40)),
            StartTimeValue,
            EndTimeValue,
            CONVERT(varchar(10), LEFT(SideCodeText, 10)),
            CONVERT(varchar(30), LEFT(VehicleScopeText, 30)),
            CONVERT(varchar(50), LEFT(DataStatusText, 50)),
            LEFT(SourceURLText, 500),
            HASHBYTES
            (
                'SHA2_256',
                CONVERT(varbinary(max), CONCAT
                (
                    N'RESTRICTION|', COALESCE(RestrictionIDText, N'<NULL>'),
                    N'|', COALESCE(RoadIDText, N'<NULL>'),
                    N'|', COALESCE(RoadNameText, N'<NULL>'),
                    N'|', COALESCE(RestrictionTypeText, N'<NULL>'),
                    N'|', COALESCE(StartTimeText, N'<NULL>'),
                    N'|', COALESCE(EndTimeText, N'<NULL>'),
                    N'|', COALESCE(SideCodeText, N'<NULL>'),
                    N'|', COALESCE(VehicleScopeText, N'<NULL>'),
                    N'|', COALESCE(DataStatusText, N'<NULL>'),
                    N'|', COALESCE(SourceURLText, N'<NULL>')
                ))
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000)
        FROM Ruled;

        /* =============================================================
           4. POI MASTER
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.POIID)), N'') AS POIIDText,
                NULLIF(LTRIM(RTRIM(Raw.POIName)), N'') AS POINameText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.CategoryCode))), N'') AS CategoryCodeText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                NULLIF(LTRIM(RTRIM(Raw.ParkingDemandWeightRaw)), N'') AS DemandWeightText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.DataStatus))), N'') AS DataStatusText,
                NULLIF(LTRIM(RTRIM(Raw.LatitudeRaw)), N'') AS LatitudeText,
                NULLIF(LTRIM(RTRIM(Raw.LongitudeRaw)), N'') AS LongitudeText,
                Raw.GeometryJson,
                COUNT_BIG(*) OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.POIID)), N'')
                ) AS BusinessKeyCount
            FROM extract.POIRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(decimal(6,3), DemandWeightText) AS DemandWeightValue,
                TRY_CONVERT(decimal(9,6), LatitudeText) AS LatitudeValue,
                TRY_CONVERT(decimal(9,6), LongitudeText) AS LongitudeValue
            FROM Normalized
        ),
        Ruled AS
        (
            SELECT
                Typed.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN POIIDText IS NULL THEN N'POIID is required' END,
                    CASE WHEN LEN(POIIDText) > 20 THEN N'POIID exceeds 20 characters' END,
                    CASE WHEN BusinessKeyCount <> 1 THEN N'POIID is duplicated in the batch' END,
                    CASE WHEN POINameText IS NULL OR LEN(POINameText) > 200
                         THEN N'POIName is invalid' END,
                    CASE WHEN CategoryCodeText IS NULL OR LEN(CategoryCodeText) > 50
                         THEN N'CategoryCode is invalid' END,
                    CASE WHEN AnalysisZoneText IS NULL OR LEN(AnalysisZoneText) > 100
                         THEN N'AnalysisZone is invalid' END,
                    CASE WHEN DemandWeightValue IS NULL OR DemandWeightValue <= 0
                         THEN N'ParkingDemandWeight is invalid' END,
                    CASE WHEN DataStatusText IS NULL OR LEN(DataStatusText) > 50
                         THEN N'DataStatus is invalid' END,
                    CASE WHEN LatitudeValue IS NULL OR LatitudeValue NOT BETWEEN -90 AND 90
                         THEN N'Latitude is invalid' END,
                    CASE WHEN LongitudeValue IS NULL OR LongitudeValue NOT BETWEEN -180 AND 180
                         THEN N'Longitude is invalid' END,
                    CASE WHEN ISNULL(ISJSON(GeometryJson), 0) <> 1
                              OR JSON_VALUE
                                 (
                                     CASE WHEN ISJSON(GeometryJson) = 1
                                          THEN GeometryJson ELSE N'{}' END,
                                     '$.type'
                                 ) <> N'Point'
                         THEN N'GeometryJson is not a Point' END
                ), N'') AS RejectReasonValue
            FROM Typed
        )
        INSERT transform.POIClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            POIID, POIName, CategoryCode, AnalysisZone,
            ParkingDemandWeight, DataStatus, Latitude, Longitude,
            AttributeHash, IsValid, RejectReason
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(20), LEFT(POIIDText, 20)),
            LEFT(POINameText, 200),
            CONVERT(varchar(50), LEFT(CategoryCodeText, 50)),
            LEFT(AnalysisZoneText, 100),
            DemandWeightValue,
            CONVERT(varchar(50), LEFT(DataStatusText, 50)),
            LatitudeValue,
            LongitudeValue,
            HASHBYTES
            (
                'SHA2_256',
                CONVERT(varbinary(max), CONCAT
                (
                    N'POI|', COALESCE(POIIDText, N'<NULL>'),
                    N'|', COALESCE(POINameText, N'<NULL>'),
                    N'|', COALESCE(CategoryCodeText, N'<NULL>'),
                    N'|', COALESCE(AnalysisZoneText, N'<NULL>'),
                    N'|', COALESCE(DemandWeightText, N'<NULL>'),
                    N'|', COALESCE(DataStatusText, N'<NULL>'),
                    N'|', COALESCE(LatitudeText, N'<NULL>'),
                    N'|', COALESCE(LongitudeText, N'<NULL>')
                ))
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000)
        FROM Ruled;

        /* =============================================================
           5. ROAD SURVEY MASTER
           Blank road width is imputed from the valid Road master row.
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.SegmentID)), N'') AS SegmentIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadID)), N'') AS RoadIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadName)), N'') AS RoadNameText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                NULLIF(LTRIM(RTRIM(Raw.RoadWidthMRaw)), N'') AS RoadWidthText,
                NULLIF(LTRIM(RTRIM(Raw.LaneCountRaw)), N'') AS LaneCountText,
                NULLIF(LTRIM(RTRIM(Raw.SidewalkWidthMRaw)), N'') AS SidewalkWidthText,
                NULLIF(LTRIM(RTRIM(Raw.ShoulderWidthMRaw)), N'') AS ShoulderWidthText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.ObservedParkingSides))), N'')
                    AS ObservedParkingSidesText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.DataStatus))), N'') AS DataStatusText,
                NULLIF(LTRIM(RTRIM(Raw.QualityConfidenceRaw)), N'') AS QualityConfidenceText,
                COUNT_BIG(*) OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.SegmentID)), N'')
                ) AS BusinessKeyCount
            FROM extract.RoadSurveyRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(decimal(6,2), RoadWidthText) AS RoadWidthRawValue,
                TRY_CONVERT(tinyint, LaneCountText) AS LaneCountValue,
                TRY_CONVERT(decimal(6,2), SidewalkWidthText) AS SidewalkWidthValue,
                TRY_CONVERT(decimal(6,2), ShoulderWidthText) AS ShoulderWidthValue,
                TRY_CONVERT(decimal(5,4), QualityConfidenceText) AS QualityConfidenceValue
            FROM Normalized
        ),
        Referenced AS
        (
            SELECT
                Typed.*,
                RoadReference.RoadMatchCount,
                RoadReference.MasterRoadName,
                RoadReference.MasterAnalysisZone,
                RoadReference.MasterRoadWidth,
                RoadReference.MasterLaneCount,
                COALESCE(Typed.RoadWidthRawValue, RoadReference.MasterRoadWidth)
                    AS RoadWidthResolvedValue,
                CONVERT(bit, CASE
                    WHEN Typed.RoadWidthText IS NULL
                         AND RoadReference.MasterRoadWidth IS NOT NULL THEN 1
                    ELSE 0
                END) AS WidthImputedValue
            FROM Typed
            OUTER APPLY
            (
                SELECT
                    COUNT_BIG(*) AS RoadMatchCount,
                    MAX(Road.RoadName) AS MasterRoadName,
                    MAX(Road.AnalysisZone) AS MasterAnalysisZone,
                    MAX(Road.RoadWidthM) AS MasterRoadWidth,
                    MAX(Road.LaneCount) AS MasterLaneCount
                FROM transform.RoadClean AS Road
                WHERE Road.LoadBatchKey = @LoadBatchKey
                  AND Road.IsValid = 1
                  AND Road.RoadID = Typed.RoadIDText
            ) AS RoadReference
        ),
        Ruled AS
        (
            SELECT
                Referenced.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN SegmentIDText IS NULL THEN N'SegmentID is required' END,
                    CASE WHEN LEN(SegmentIDText) > 20 THEN N'SegmentID exceeds 20 characters' END,
                    CASE WHEN BusinessKeyCount <> 1 THEN N'SegmentID is duplicated in the batch' END,
                    CASE WHEN RoadIDText IS NULL OR LEN(RoadIDText) > 10
                         THEN N'RoadID is invalid' END,
                    CASE WHEN RoadMatchCount <> 1
                         THEN N'RoadID does not resolve to one valid road' END,
                    CASE WHEN RoadMatchCount = 1 AND RoadNameText <> MasterRoadName
                         THEN N'RoadName does not match Road master' END,
                    CASE WHEN RoadMatchCount = 1 AND AnalysisZoneText <> MasterAnalysisZone
                         THEN N'AnalysisZone does not match Road master' END,
                    CASE WHEN RoadNameText IS NULL OR LEN(RoadNameText) > 150
                         THEN N'RoadName is invalid' END,
                    CASE WHEN AnalysisZoneText IS NULL OR LEN(AnalysisZoneText) > 100
                         THEN N'AnalysisZone is invalid' END,
                    CASE WHEN RoadWidthText IS NOT NULL AND RoadWidthRawValue IS NULL
                         THEN N'RoadWidthM cannot be converted' END,
                    CASE WHEN RoadWidthResolvedValue IS NULL OR RoadWidthResolvedValue <= 0
                         THEN N'RoadWidthM cannot be resolved' END,
                    CASE WHEN LaneCountValue IS NULL OR LaneCountValue NOT BETWEEN 1 AND 12
                         THEN N'LaneCount is invalid' END,
                    CASE WHEN RoadMatchCount = 1 AND LaneCountValue <> MasterLaneCount
                         THEN N'LaneCount does not match Road master' END,
                    CASE WHEN SidewalkWidthValue IS NULL OR SidewalkWidthValue < 0
                         THEN N'SidewalkWidthM is invalid' END,
                    CASE WHEN ShoulderWidthValue IS NULL OR ShoulderWidthValue < 0
                         THEN N'ShoulderWidthM is invalid' END,
                    CASE WHEN ObservedParkingSidesText IS NULL
                                   OR ObservedParkingSidesText NOT IN
                              (N'LEFT', N'RIGHT', N'BOTH', N'NONE')
                         THEN N'ObservedParkingSides is not supported' END,
                    CASE WHEN DataStatusText IS NULL OR LEN(DataStatusText) > 50
                         THEN N'DataStatus is invalid' END,
                    CASE WHEN QualityConfidenceValue IS NULL
                                   OR QualityConfidenceValue NOT BETWEEN 0 AND 1
                         THEN N'QualityConfidence is invalid' END
                ), N'') AS RejectReasonValue
            FROM Referenced
        )
        INSERT transform.RoadSurveyClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            SegmentID, RoadID, RoadName, AnalysisZone,
            RoadWidthRawM, RoadWidthResolvedM, LaneCount,
            SidewalkWidthM, ShoulderWidthM, ObservedParkingSides,
            DataStatus, QualityConfidence, WidthImputedFlag,
            IsValid, RejectReason
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(20), LEFT(SegmentIDText, 20)),
            CONVERT(varchar(10), LEFT(RoadIDText, 10)),
            LEFT(RoadNameText, 150),
            LEFT(AnalysisZoneText, 100),
            RoadWidthRawValue,
            RoadWidthResolvedValue,
            LaneCountValue,
            SidewalkWidthValue,
            ShoulderWidthValue,
            CONVERT(varchar(10), LEFT(ObservedParkingSidesText, 10)),
            CONVERT(varchar(50), LEFT(DataStatusText, 50)),
            QualityConfidenceValue,
            WidthImputedValue,
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000)
        FROM Ruled;

        /* One audit row per invalid transformed master row. */
        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT LoadFileKey, SourceRowNumber, RoadID,
               'TRN_ROAD_INVALID', 'ERROR', RejectReason, NULL
        FROM transform.RoadClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 0
        UNION ALL
        SELECT LoadFileKey, SourceRowNumber, ParkingID,
               'TRN_FACILITY_INVALID', 'ERROR', RejectReason, NULL
        FROM transform.ParkingFacilityClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 0
        UNION ALL
        SELECT LoadFileKey, SourceRowNumber, RestrictionID,
               'TRN_RESTRICTION_INVALID', 'ERROR', RejectReason, NULL
        FROM transform.ParkingRestrictionClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 0
        UNION ALL
        SELECT LoadFileKey, SourceRowNumber, POIID,
               'TRN_POI_INVALID', 'ERROR', RejectReason, NULL
        FROM transform.POIClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 0
        UNION ALL
        SELECT LoadFileKey, SourceRowNumber, SegmentID,
               'TRN_SURVEY_INVALID', 'ERROR', RejectReason, NULL
        FROM transform.RoadSurveyClean
        WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 0;

        COMMIT TRANSACTION;

        /*
            Validation runs after COMMIT on purpose. If a quality rule fails,
            clean/reject rows remain available for debugging while the batch
            is marked FAILED in CATCH.
        */
        IF (SELECT COUNT_BIG(*) FROM transform.RoadClean
            WHERE LoadBatchKey = @LoadBatchKey) <> 30
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingFacilityClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 20
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingRestrictionClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 18
           OR (SELECT COUNT_BIG(*) FROM transform.POIClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 50
           OR (SELECT COUNT_BIG(*) FROM transform.RoadSurveyClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 30
            THROW 51610, 'Master transform did not preserve all 148 source rows.', 1;

        IF (SELECT COUNT_BIG(*) FROM transform.RoadClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 30
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingFacilityClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 20
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingRestrictionClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 18
           OR (SELECT COUNT_BIG(*) FROM transform.POIClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 50
           OR (SELECT COUNT_BIG(*) FROM transform.RoadSurveyClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 30
            THROW 51611, 'One or more master rows are invalid. Inspect RejectReason and etl.RejectedRow.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode IN
              (
                  'TRN_ROAD_INVALID',
                  'TRN_FACILITY_INVALID',
                  'TRN_RESTRICTION_INVALID',
                  'TRN_POI_INVALID',
                  'TRN_SURVEY_INVALID'
              )
        )
            THROW 51612, 'The master transform produced rejected rows.', 1;

        IF
        (
            SELECT COUNT_BIG(*)
            FROM transform.RoadSurveyClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND WidthImputedFlag = 1
              AND RoadWidthRawM IS NULL
              AND RoadWidthResolvedM IS NOT NULL
        ) <> 3
            THROW 51613, 'Road survey must contain exactly three successfully imputed widths.', 1;

        IF
        (
            SELECT COUNT_BIG(*)
            FROM transform.ParkingRestrictionClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND RestrictionID = 'R003'
              AND RoadID IS NULL
              AND IsValid = 1
        ) <> 1
            THROW 51614, 'Restriction R003 must remain valid with a NULL RoadID.', 1;

        IF
        (
            SELECT COALESCE(SUM(CapacitySpaces), 0)
            FROM transform.ParkingFacilityClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND IsValid = 1
        ) <> 2267
           OR
        (
            SELECT COALESCE(SUM(CASE WHEN IsReferenceCapacity = 1
                                     THEN CapacitySpaces ELSE 0 END), 0)
            FROM transform.ParkingFacilityClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND IsValid = 1
        ) <> 397
            THROW 51615, 'Parking capacity reconciliation failed.', 1;

        IF @ReturnDetail = 1
        BEGIN
            SELECT
                ObjectName,
                ActualRows,
                ValidRows,
                InvalidRows,
                ExpectedValidRows,
                CASE WHEN ValidRows = ExpectedValidRows AND InvalidRows = 0
                     THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END AS IsMatched
            FROM
            (
                SELECT 'transform.RoadClean' AS ObjectName,
                       COUNT_BIG(*) AS ActualRows,
                       SUM(CONVERT(bigint, IsValid)) AS ValidRows,
                       SUM(CONVERT(bigint, 1 - IsValid)) AS InvalidRows,
                       CONVERT(bigint, 30) AS ExpectedValidRows
                FROM transform.RoadClean WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT 'transform.ParkingFacilityClean', COUNT_BIG(*),
                       SUM(CONVERT(bigint, IsValid)), SUM(CONVERT(bigint, 1 - IsValid)), 20
                FROM transform.ParkingFacilityClean WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT 'transform.ParkingRestrictionClean', COUNT_BIG(*),
                       SUM(CONVERT(bigint, IsValid)), SUM(CONVERT(bigint, 1 - IsValid)), 18
                FROM transform.ParkingRestrictionClean WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT 'transform.POIClean', COUNT_BIG(*),
                       SUM(CONVERT(bigint, IsValid)), SUM(CONVERT(bigint, 1 - IsValid)), 50
                FROM transform.POIClean WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT 'transform.RoadSurveyClean', COUNT_BIG(*),
                       SUM(CONVERT(bigint, IsValid)), SUM(CONVERT(bigint, 1 - IsValid)), 30
                FROM transform.RoadSurveyClean WHERE LoadBatchKey = @LoadBatchKey
            ) AS Summary
            ORDER BY ObjectName;

            SELECT
                SUM(CapacitySpaces) AS TotalCapacity,
                SUM(CASE WHEN IsReferenceCapacity = 1 THEN CapacitySpaces ELSE 0 END)
                    AS ReferenceCapacity,
                SUM(CONVERT(int, IsReferenceCapacity)) AS ReferenceFacilityCount
            FROM transform.ParkingFacilityClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1;

            SELECT
                SUM(CASE WHEN RoadWidthRawM IS NULL THEN 1 ELSE 0 END) AS BlankRawWidths,
                SUM(CONVERT(int, WidthImputedFlag)) AS ImputedWidths,
                SUM(CASE WHEN RoadWidthResolvedM IS NULL THEN 1 ELSE 0 END)
                    AS UnresolvedWidths
            FROM transform.RoadSurveyClean
            WHERE LoadBatchKey = @LoadBatchKey;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        UPDATE DanangSmartParkingDW.etl.LoadBatch
        SET LoadStatus = 'FAILED',
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'BRONZE_LOADED';

        THROW;
    END CATCH;
END;
GO
