/*
    Da Nang Smart Parking
    Package 21 - Transform traffic, parking and weather events.

    Input status : BRONZE_LOADED
    Output       : three typed/deduplicated transform.*Clean tables
    Status after success remains BRONZE_LOADED. Package 23 owns SILVER_VALIDATED.

    Dedup policy:
      - keep the smallest SourceRowNumber for each event/timestamp;
      - keep every physical source row in extract.*Raw;
      - record discarded duplicates in DW.etl.RejectedRow as WARNING.
*/

USE DanangSmartParkingSTG;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TransformEvents
    @LoadBatchKey bigint,
    @ReturnDetail bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LoadBatchKey IS NULL OR @LoadBatchKey <= 0
        THROW 51800, 'LoadBatchKey must be a positive value.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
    )
        THROW 51801, 'LoadBatchKey does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DanangSmartParkingDW.etl.LoadBatch
        WHERE LoadBatchKey = @LoadBatchKey
          AND LoadStatus = 'BRONZE_LOADED'
    )
        THROW 51802, 'Event transform requires a BRONZE_LOADED batch.', 1;

    BEGIN TRY
        /* Fail before deleting a previously successful transform result. */
        IF (SELECT COUNT_BIG(*) FROM extract.TrafficEventRaw
            WHERE LoadBatchKey = @LoadBatchKey) <> 16884
           OR (SELECT COUNT_BIG(*) FROM extract.ParkingEventRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 4300
           OR (SELECT COUNT_BIG(*) FROM extract.WeatherEventRaw
               WHERE LoadBatchKey = @LoadBatchKey) <> 168
            THROW 51803, 'One or more event RAW tables differ from the expected row count.', 1;

        /* Package 20 must have succeeded for this same batch. */
        IF (SELECT COUNT_BIG(*) FROM transform.RoadClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 30
           OR (SELECT COUNT_BIG(*) FROM transform.RoadSurveyClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 30
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingRestrictionClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 18
            THROW 51804, 'Package 20 master output is missing or invalid for this batch.', 1;

        BEGIN TRANSACTION;

        /* Idempotent rerun for package 21 and this batch only. */
        DELETE Rejected
        FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
        JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
          ON LoadFile.LoadFileKey = Rejected.LoadFileKey
        WHERE LoadFile.LoadBatchKey = @LoadBatchKey
          AND Rejected.RuleCode IN
          (
              'TRN_TRAFFIC_DUPLICATE',
              'TRN_TRAFFIC_INVALID',
              'TRN_PARKING_DUPLICATE',
              'TRN_PARKING_INVALID',
              'TRN_WEATHER_DUPLICATE',
              'TRN_WEATHER_INVALID'
          );

        DELETE FROM transform.WeatherHourlyClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.ParkingEventClean
        WHERE LoadBatchKey = @LoadBatchKey;

        DELETE FROM transform.TrafficObservationClean
        WHERE LoadBatchKey = @LoadBatchKey;

        /* =============================================================
           1. WEATHER HOURLY
           Weather is transformed first so traffic rain can be reconciled.
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.StageRowKey,
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.WeatherTimestampRaw)), N'') AS TimestampText,
                NULLIF(LTRIM(RTRIM(Raw.EventDateRaw)), N'') AS EventDateText,
                NULLIF(LTRIM(RTRIM(Raw.HourRaw)), N'') AS HourText,
                NULLIF(LTRIM(RTRIM(Raw.TemperatureCRaw)), N'') AS TemperatureText,
                NULLIF(LTRIM(RTRIM(Raw.DailyMinCActualRaw)), N'') AS DailyMinText,
                NULLIF(LTRIM(RTRIM(Raw.DailyMaxCActualRaw)), N'') AS DailyMaxText,
                NULLIF(LTRIM(RTRIM(Raw.DailyReferenceCActualRaw)), N'') AS DailyReferenceText,
                NULLIF(LTRIM(RTRIM(Raw.RainMmRaw)), N'') AS RainText,
                NULLIF(LTRIM(RTRIM(Raw.HumidityPctRaw)), N'') AS HumidityText,
                NULLIF(LTRIM(RTRIM(Raw.VisibilityKmRaw)), N'') AS VisibilityText,
                NULLIF(LTRIM(RTRIM(Raw.WindKmhRaw)), N'') AS WindText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.TemperatureStatus))), N'') AS TemperatureStatusText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.PrecipitationStatus))), N'') AS PrecipitationStatusText,
                NULLIF(LTRIM(RTRIM(Raw.SourceReference)), N'') AS SourceReferenceText,
                Raw.RawJson,
                Raw.RecordHashSHA256,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.WeatherTimestampRaw)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.WeatherEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(datetime2(0), TimestampText, 126) AS TimestampValue,
                TRY_CONVERT(date, EventDateText, 23) AS EventDateValue,
                TRY_CONVERT(tinyint, HourText) AS HourValue,
                TRY_CONVERT(decimal(5,2), TemperatureText) AS TemperatureValue,
                TRY_CONVERT(decimal(5,2), DailyMinText) AS DailyMinValue,
                TRY_CONVERT(decimal(5,2), DailyMaxText) AS DailyMaxValue,
                TRY_CONVERT(decimal(5,2), DailyReferenceText) AS DailyReferenceValue,
                TRY_CONVERT(decimal(7,2), RainText) AS RainValue,
                TRY_CONVERT(decimal(5,2), HumidityText) AS HumidityValue,
                TRY_CONVERT(decimal(6,2), VisibilityText) AS VisibilityValue,
                TRY_CONVERT(decimal(6,2), WindText) AS WindValue
            FROM Normalized
        ),
        Ruled AS
        (
            SELECT
                Typed.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN TimestampValue IS NULL THEN N'WeatherTimestamp is invalid' END,
                    CASE WHEN EventDateValue IS NULL THEN N'EventDate is invalid' END,
                    CASE WHEN HourValue IS NULL OR HourValue NOT BETWEEN 0 AND 23
                         THEN N'HourNumber is invalid' END,
                    CASE WHEN TimestampValue IS NOT NULL AND EventDateValue IS NOT NULL
                                   AND CONVERT(date, TimestampValue) <> EventDateValue
                         THEN N'EventDate does not match WeatherTimestamp' END,
                    CASE WHEN TimestampValue IS NOT NULL AND HourValue IS NOT NULL
                                   AND DATEPART(hour, TimestampValue) <> HourValue
                         THEN N'HourNumber does not match WeatherTimestamp' END,
                    CASE WHEN TemperatureValue IS NULL OR TemperatureValue NOT BETWEEN -50 AND 60
                         THEN N'TemperatureC is invalid' END,
                    CASE WHEN DailyMinValue IS NULL OR DailyMinValue NOT BETWEEN -50 AND 60
                         THEN N'DailyMinCActual is invalid' END,
                    CASE WHEN DailyMaxValue IS NULL OR DailyMaxValue NOT BETWEEN -50 AND 60
                         THEN N'DailyMaxCActual is invalid' END,
                    CASE WHEN DailyMinValue IS NOT NULL AND DailyMaxValue IS NOT NULL
                                   AND DailyMinValue > DailyMaxValue
                         THEN N'Daily minimum exceeds daily maximum' END,
                    CASE WHEN DailyReferenceValue IS NULL OR DailyReferenceValue NOT BETWEEN -50 AND 60
                         THEN N'DailyReferenceCActual is invalid' END,
                    CASE WHEN RainValue IS NULL OR RainValue < 0 THEN N'RainMm is invalid' END,
                    CASE WHEN HumidityValue IS NULL OR HumidityValue NOT BETWEEN 0 AND 100
                         THEN N'HumidityPct is invalid' END,
                    CASE WHEN VisibilityValue IS NULL OR VisibilityValue < 0
                         THEN N'VisibilityKm is invalid' END,
                    CASE WHEN WindValue IS NULL OR WindValue < 0 THEN N'WindKmh is invalid' END,
                    CASE WHEN TemperatureStatusText IS NULL OR LEN(TemperatureStatusText) > 80
                         THEN N'TemperatureStatus is invalid' END,
                    CASE WHEN PrecipitationStatusText IS NULL OR LEN(PrecipitationStatusText) > 40
                         THEN N'PrecipitationStatus is invalid' END,
                    CASE WHEN SourceReferenceText IS NULL OR LEN(SourceReferenceText) > 300
                         THEN N'SourceReference is invalid' END
                ), N'') AS RejectReasonValue
            FROM Typed
        )
        INSERT transform.WeatherHourlyClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            WeatherTimestamp, EventDate, HourNumber,
            TemperatureC, DailyMinCActual, DailyMaxCActual,
            DailyReferenceCActual, RainMm, HumidityPct,
            VisibilityKm, WindKmh, TemperatureStatus,
            PrecipitationStatus, SourceReference, IsRainyHour,
            IsValid, RejectReason, RecordHashSHA256
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            TimestampValue,
            EventDateValue,
            HourValue,
            TemperatureValue,
            DailyMinValue,
            DailyMaxValue,
            DailyReferenceValue,
            RainValue,
            HumidityValue,
            VisibilityValue,
            WindValue,
            CONVERT(varchar(80), LEFT(TemperatureStatusText, 80)),
            CONVERT(varchar(40), LEFT(PrecipitationStatusText, 40)),
            LEFT(SourceReferenceText, 300),
            CONVERT(bit, CASE WHEN RainValue > 0 THEN 1 ELSE 0 END),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000),
            COALESCE
            (
                RecordHashSHA256,
                HASHBYTES('SHA2_256', CONVERT(varbinary(max), RawJson))
            )
        FROM Ruled
        WHERE DuplicateRankValue = 1;

        ;WITH Ranked AS
        (
            SELECT
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                Raw.WeatherTimestampRaw,
                Raw.RawJson,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.WeatherTimestampRaw)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.WeatherEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        )
        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            LoadFileKey,
            SourceRowNumber,
            WeatherTimestampRaw,
            'TRN_WEATHER_DUPLICATE',
            'WARNING',
            N'Duplicate weather timestamp; the smallest SourceRowNumber was retained.',
            RawJson
        FROM Ranked
        WHERE DuplicateRankValue > 1;

        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            Clean.LoadFileKey,
            Clean.SourceRowNumber,
            CONVERT(nvarchar(30), Clean.WeatherTimestamp, 126),
            'TRN_WEATHER_INVALID',
            'ERROR',
            Clean.RejectReason,
            Raw.RawJson
        FROM transform.WeatherHourlyClean AS Clean
        JOIN extract.WeatherEventRaw AS Raw
          ON Raw.LoadFileKey = Clean.LoadFileKey
         AND Raw.SourceRowNumber = Clean.SourceRowNumber
        WHERE Clean.LoadBatchKey = @LoadBatchKey
          AND Clean.IsValid = 0;

        /* =============================================================
           2. TRAFFIC OBSERVATIONS
           DQ inconsistencies are preserved and expressed as flags.
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.StageRowKey,
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.EventID)), N'') AS EventIDText,
                NULLIF(LTRIM(RTRIM(Raw.EventTimestampRaw)), N'') AS TimestampText,
                NULLIF(LTRIM(RTRIM(Raw.EventDateRaw)), N'') AS EventDateText,
                NULLIF(LTRIM(RTRIM(Raw.HourRaw)), N'') AS HourText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.CameraID))), N'') AS CameraIDText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.SegmentID))), N'') AS SegmentIDText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.RoadID))), N'') AS RoadIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadName)), N'') AS RoadNameText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                NULLIF(LTRIM(RTRIM(Raw.VehicleCountRaw)), N'') AS VehicleCountText,
                NULLIF(LTRIM(RTRIM(Raw.MotorbikeCountRaw)), N'') AS MotorbikeCountText,
                NULLIF(LTRIM(RTRIM(Raw.CarCountRaw)), N'') AS CarCountText,
                NULLIF(LTRIM(RTRIM(Raw.BusCountRaw)), N'') AS BusCountText,
                NULLIF(LTRIM(RTRIM(Raw.TruckCountRaw)), N'') AS TruckCountText,
                NULLIF(LTRIM(RTRIM(Raw.AvgSpeedKmhRaw)), N'') AS AvgSpeedText,
                NULLIF(LTRIM(RTRIM(Raw.ParkedVehicleCountRaw)), N'') AS ParkedCountText,
                NULLIF(LTRIM(RTRIM(Raw.IllegalParkingCountRaw)), N'') AS IllegalCountText,
                NULLIF(LTRIM(RTRIM(Raw.RoadWidthMRaw)), N'') AS RoadWidthText,
                NULLIF(LTRIM(RTRIM(Raw.ParkingOccupiedWidthMRaw)), N'') AS OccupiedWidthText,
                NULLIF(LTRIM(RTRIM(Raw.EffectiveWidthMRaw)), N'') AS EffectiveWidthText,
                NULLIF(LTRIM(RTRIM(Raw.WidthLossPctRaw)), N'') AS WidthLossText,
                NULLIF(LTRIM(RTRIM(Raw.CongestionIndexRaw)), N'') AS CongestionText,
                NULLIF(LTRIM(RTRIM(Raw.RainMmRaw)), N'') AS RainText,
                Raw.RawJson,
                Raw.RecordHashSHA256,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.EventID)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.TrafficEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(datetime2(0), TimestampText, 126) AS TimestampValue,
                TRY_CONVERT(date, EventDateText, 23) AS EventDateValue,
                TRY_CONVERT(tinyint, HourText) AS HourValue,
                TRY_CONVERT(int, VehicleCountText) AS VehicleCountValue,
                TRY_CONVERT(int, MotorbikeCountText) AS MotorbikeCountValue,
                TRY_CONVERT(int, CarCountText) AS CarCountValue,
                TRY_CONVERT(int, BusCountText) AS BusCountValue,
                TRY_CONVERT(int, TruckCountText) AS TruckCountValue,
                TRY_CONVERT(decimal(6,2), AvgSpeedText) AS AvgSpeedValue,
                TRY_CONVERT(smallint, ParkedCountText) AS ParkedCountValue,
                TRY_CONVERT(smallint, IllegalCountText) AS IllegalCountValue,
                TRY_CONVERT(decimal(6,2), RoadWidthText) AS RoadWidthValue,
                TRY_CONVERT(decimal(6,2), OccupiedWidthText) AS OccupiedWidthValue,
                TRY_CONVERT(decimal(6,2), EffectiveWidthText) AS EffectiveWidthValue,
                TRY_CONVERT(decimal(6,2), WidthLossText) AS WidthLossValue,
                TRY_CONVERT(decimal(7,4), CongestionText) AS CongestionValue,
                TRY_CONVERT(decimal(7,2), RainText) AS RainValue
            FROM Normalized
        ),
        Referenced AS
        (
            SELECT
                Typed.*,
                MasterRoad.RoadID AS MatchedRoadID,
                MasterRoad.RoadName AS MasterRoadName,
                MasterRoad.AnalysisZone AS MasterAnalysisZone,
                MasterRoad.RoadWidthM AS MasterRoadWidthM,
                MasterSegment.SegmentID AS MatchedSegmentID,
                MasterSegment.RoadID AS SegmentRoadID,
                Weather.WeatherTimestamp AS MatchedWeatherTimestamp,
                Weather.RainMm AS WeatherRainMm
            FROM Typed
            LEFT JOIN transform.RoadClean AS MasterRoad
              ON MasterRoad.LoadBatchKey = @LoadBatchKey
             AND MasterRoad.IsValid = 1
             AND MasterRoad.RoadID = Typed.RoadIDText
            LEFT JOIN transform.RoadSurveyClean AS MasterSegment
              ON MasterSegment.LoadBatchKey = @LoadBatchKey
             AND MasterSegment.IsValid = 1
             AND MasterSegment.SegmentID = Typed.SegmentIDText
            LEFT JOIN transform.WeatherHourlyClean AS Weather
              ON Weather.LoadBatchKey = @LoadBatchKey
             AND Weather.IsValid = 1
             AND Weather.EventDate = Typed.EventDateValue
             AND Weather.HourNumber = Typed.HourValue
        ),
        Ruled AS
        (
            SELECT
                Referenced.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN EventIDText IS NULL OR LEN(EventIDText) > 50
                         THEN N'EventID is invalid' END,
                    CASE WHEN TimestampValue IS NULL THEN N'EventTimestamp is invalid' END,
                    CASE WHEN EventDateValue IS NULL THEN N'EventDate is invalid' END,
                    CASE WHEN HourValue IS NULL OR HourValue NOT BETWEEN 0 AND 23
                         THEN N'HourNumber is invalid' END,
                    CASE WHEN TimestampValue IS NOT NULL AND EventDateValue IS NOT NULL
                                   AND CONVERT(date, TimestampValue) <> EventDateValue
                         THEN N'EventDate does not match EventTimestamp' END,
                    CASE WHEN TimestampValue IS NOT NULL AND HourValue IS NOT NULL
                                   AND DATEPART(hour, TimestampValue) <> HourValue
                         THEN N'HourNumber does not match EventTimestamp' END,
                    CASE WHEN CameraIDText IS NULL OR LEN(CameraIDText) > 20
                         THEN N'CameraID is invalid' END,
                    CASE WHEN SegmentIDText IS NULL OR LEN(SegmentIDText) > 20
                         THEN N'SegmentID is invalid' END,
                    CASE WHEN RoadIDText IS NULL OR LEN(RoadIDText) > 10
                         THEN N'RoadID is invalid' END,
                    CASE WHEN MatchedRoadID IS NULL THEN N'RoadID does not resolve to RoadClean' END,
                    CASE WHEN MatchedSegmentID IS NULL
                         THEN N'SegmentID does not resolve to RoadSurveyClean' END,
                    CASE WHEN MatchedSegmentID IS NOT NULL AND SegmentRoadID <> RoadIDText
                         THEN N'SegmentID resolves to a different RoadID' END,
                    CASE WHEN MatchedRoadID IS NOT NULL AND RoadNameText <> MasterRoadName
                         THEN N'RoadName does not match Road master' END,
                    CASE WHEN MatchedRoadID IS NOT NULL AND AnalysisZoneText <> MasterAnalysisZone
                         THEN N'AnalysisZone does not match Road master' END,
                    CASE WHEN VehicleCountValue IS NULL OR VehicleCountValue < 0
                         THEN N'VehicleCount is invalid' END,
                    CASE WHEN MotorbikeCountValue IS NULL OR MotorbikeCountValue < 0
                         THEN N'MotorbikeCount is invalid' END,
                    CASE WHEN CarCountValue IS NULL OR CarCountValue < 0
                         THEN N'CarCount is invalid' END,
                    CASE WHEN BusCountValue IS NULL OR BusCountValue < 0
                         THEN N'BusCount is invalid' END,
                    CASE WHEN TruckCountValue IS NULL OR TruckCountValue < 0
                         THEN N'TruckCount is invalid' END,
                    CASE WHEN AvgSpeedText IS NOT NULL
                                   AND (AvgSpeedValue IS NULL OR AvgSpeedValue NOT BETWEEN 0 AND 250)
                         THEN N'AvgSpeedKmh is invalid' END,
                    CASE WHEN ParkedCountValue IS NULL OR ParkedCountValue < 0
                         THEN N'ParkedVehicleCount is invalid' END,
                    CASE WHEN IllegalCountValue IS NULL OR IllegalCountValue < 0
                         THEN N'IllegalParkingCount is invalid' END,
                    CASE WHEN RoadWidthValue IS NULL OR RoadWidthValue <= 0
                         THEN N'RoadWidthM is invalid' END,
                    CASE WHEN MatchedRoadID IS NOT NULL AND RoadWidthValue <> MasterRoadWidthM
                         THEN N'RoadWidthM does not match Road master' END,
                    CASE WHEN OccupiedWidthValue IS NULL OR OccupiedWidthValue < 0
                         THEN N'ParkingOccupiedWidthM is invalid' END,
                    CASE WHEN EffectiveWidthValue IS NULL OR EffectiveWidthValue <= 0
                         THEN N'EffectiveWidthM is invalid' END,
                    CASE WHEN WidthLossValue IS NULL OR WidthLossValue NOT BETWEEN 0 AND 100
                         THEN N'WidthLossPct is invalid' END,
                    CASE WHEN CongestionValue IS NULL OR CongestionValue NOT BETWEEN 0 AND 1
                         THEN N'CongestionIndex is invalid' END,
                    CASE WHEN RainValue IS NULL OR RainValue < 0 THEN N'RainMm is invalid' END,
                    CASE WHEN MatchedWeatherTimestamp IS NULL
                         THEN N'Weather hour does not resolve' END,
                    CASE WHEN MatchedWeatherTimestamp IS NOT NULL AND RainValue <> WeatherRainMm
                         THEN N'RainMm does not match hourly weather' END
                ), N'') AS RejectReasonValue
            FROM Referenced
        )
        INSERT transform.TrafficObservationClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            EventID, EventTimestamp, EventDate, HourNumber,
            CameraID, SegmentID, RoadID, RoadName, AnalysisZone,
            VehicleCount, MotorbikeCount, CarCount, BusCount, TruckCount,
            AvgSpeedKmh, ParkedVehicleCount, IllegalParkingCount,
            RoadWidthM, ParkingOccupiedWidthM, EffectiveWidthM,
            WidthLossPct, CongestionIndex, RainMm, DuplicateRank,
            SpeedMissingFlag, VehicleMixValidFlag, ParkingCountValidFlag,
            IsValid, RejectReason, RecordHashSHA256
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(50), LEFT(EventIDText, 50)),
            TimestampValue,
            EventDateValue,
            HourValue,
            CONVERT(varchar(20), LEFT(CameraIDText, 20)),
            CONVERT(varchar(20), LEFT(SegmentIDText, 20)),
            CONVERT(varchar(10), LEFT(RoadIDText, 10)),
            LEFT(RoadNameText, 150),
            LEFT(AnalysisZoneText, 100),
            VehicleCountValue,
            MotorbikeCountValue,
            CarCountValue,
            BusCountValue,
            TruckCountValue,
            AvgSpeedValue,
            ParkedCountValue,
            IllegalCountValue,
            RoadWidthValue,
            OccupiedWidthValue,
            EffectiveWidthValue,
            WidthLossValue,
            CongestionValue,
            RainValue,
            CONVERT(int, DuplicateRankValue),
            CONVERT(bit, CASE WHEN AvgSpeedValue IS NULL THEN 1 ELSE 0 END),
            CONVERT
            (
                bit,
                CASE WHEN VehicleCountValue =
                               COALESCE(MotorbikeCountValue, 0)
                             + COALESCE(CarCountValue, 0)
                             + COALESCE(BusCountValue, 0)
                             + COALESCE(TruckCountValue, 0)
                     THEN 1 ELSE 0 END
            ),
            CONVERT
            (
                bit,
                CASE WHEN IllegalCountValue <= ParkedCountValue THEN 1 ELSE 0 END
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000),
            COALESCE
            (
                RecordHashSHA256,
                HASHBYTES('SHA2_256', CONVERT(varbinary(max), RawJson))
            )
        FROM Ruled
        WHERE DuplicateRankValue = 1;

        ;WITH Ranked AS
        (
            SELECT
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                Raw.EventID,
                Raw.RawJson,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.EventID)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.TrafficEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        )
        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            LoadFileKey,
            SourceRowNumber,
            EventID,
            'TRN_TRAFFIC_DUPLICATE',
            'WARNING',
            N'Duplicate EventID; the smallest SourceRowNumber was retained.',
            RawJson
        FROM Ranked
        WHERE DuplicateRankValue > 1;

        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            Clean.LoadFileKey,
            Clean.SourceRowNumber,
            Clean.EventID,
            'TRN_TRAFFIC_INVALID',
            'ERROR',
            Clean.RejectReason,
            Raw.RawJson
        FROM transform.TrafficObservationClean AS Clean
        JOIN extract.TrafficEventRaw AS Raw
          ON Raw.LoadFileKey = Clean.LoadFileKey
         AND Raw.SourceRowNumber = Clean.SourceRowNumber
        WHERE Clean.LoadBatchKey = @LoadBatchKey
          AND Clean.IsValid = 0;

        /* =============================================================
           3. PARKING EVENTS
           Open events retain the source duration as estimated/last-known.
           ============================================================= */
        ;WITH Normalized AS
        (
            SELECT
                Raw.StageRowKey,
                Raw.LoadBatchKey,
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                NULLIF(LTRIM(RTRIM(Raw.EventID)), N'') AS EventIDText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.VehicleID))), N'') AS VehicleIDText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.RoadID))), N'') AS RoadIDText,
                NULLIF(LTRIM(RTRIM(Raw.RoadName)), N'') AS RoadNameText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.SegmentID))), N'') AS SegmentIDText,
                NULLIF(LTRIM(RTRIM(Raw.StartTimeRaw)), N'') AS StartTimeText,
                NULLIF(LTRIM(RTRIM(Raw.EndTimeRaw)), N'') AS EndTimeText,
                NULLIF(LTRIM(RTRIM(Raw.EventDateRaw)), N'') AS EventDateText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.VehicleTypeCode))), N'') AS VehicleTypeText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.SideCode))), N'') AS SideText,
                NULLIF(LTRIM(RTRIM(Raw.ParkingDurationMinRaw)), N'') AS DurationText,
                NULLIF(LTRIM(RTRIM(Raw.OccupiedWidthMRaw)), N'') AS OccupiedWidthText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.LegalParkingRaw))), N'') AS LegalParkingText,
                NULLIF(UPPER(LTRIM(RTRIM(Raw.ActiveRestrictionID))), N'') AS RestrictionIDText,
                NULLIF(LTRIM(RTRIM(Raw.AnalysisZone)), N'') AS AnalysisZoneText,
                Raw.RawJson,
                Raw.RecordHashSHA256,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.EventID)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.ParkingEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        ),
        Typed AS
        (
            SELECT
                Normalized.*,
                TRY_CONVERT(datetime2(6), StartTimeText, 126) AS StartTimeValue,
                TRY_CONVERT(datetime2(6), EndTimeText, 126) AS EndTimeValue,
                TRY_CONVERT(date, EventDateText, 23) AS EventDateValue,
                TRY_CONVERT(smallint, DurationText) AS DurationValue,
                TRY_CONVERT(decimal(5,2), OccupiedWidthText) AS OccupiedWidthValue,
                CONVERT
                (
                    bit,
                    CASE WHEN LegalParkingText IN (N'TRUE', N'1') THEN 1
                         WHEN LegalParkingText IN (N'FALSE', N'0') THEN 0
                         ELSE NULL END
                ) AS IsLegalValue
            FROM Normalized
        ),
        Referenced AS
        (
            SELECT
                Typed.*,
                MasterRoad.RoadID AS MatchedRoadID,
                MasterRoad.RoadName AS MasterRoadName,
                MasterRoad.AnalysisZone AS MasterAnalysisZone,
                MasterSegment.SegmentID AS MatchedSegmentID,
                MasterSegment.RoadID AS SegmentRoadID,
                MasterRestriction.RestrictionID AS MatchedRestrictionID
            FROM Typed
            LEFT JOIN transform.RoadClean AS MasterRoad
              ON MasterRoad.LoadBatchKey = @LoadBatchKey
             AND MasterRoad.IsValid = 1
             AND MasterRoad.RoadID = Typed.RoadIDText
            LEFT JOIN transform.RoadSurveyClean AS MasterSegment
              ON MasterSegment.LoadBatchKey = @LoadBatchKey
             AND MasterSegment.IsValid = 1
             AND MasterSegment.SegmentID = Typed.SegmentIDText
            LEFT JOIN transform.ParkingRestrictionClean AS MasterRestriction
              ON MasterRestriction.LoadBatchKey = @LoadBatchKey
             AND MasterRestriction.IsValid = 1
             AND MasterRestriction.RestrictionID = Typed.RestrictionIDText
        ),
        Ruled AS
        (
            SELECT
                Referenced.*,
                NULLIF(CONCAT_WS
                (
                    N'; ',
                    CASE WHEN EventIDText IS NULL OR LEN(EventIDText) > 30
                         THEN N'EventID is invalid' END,
                    CASE WHEN VehicleIDText IS NULL OR LEN(VehicleIDText) > 30
                         THEN N'VehicleID is invalid' END,
                    CASE WHEN RoadIDText IS NULL OR LEN(RoadIDText) > 10
                         THEN N'RoadID is invalid' END,
                    CASE WHEN SegmentIDText IS NULL OR LEN(SegmentIDText) > 20
                         THEN N'SegmentID is invalid' END,
                    CASE WHEN MatchedRoadID IS NULL THEN N'RoadID does not resolve to RoadClean' END,
                    CASE WHEN MatchedSegmentID IS NULL
                         THEN N'SegmentID does not resolve to RoadSurveyClean' END,
                    CASE WHEN MatchedSegmentID IS NOT NULL AND SegmentRoadID <> RoadIDText
                         THEN N'SegmentID resolves to a different RoadID' END,
                    CASE WHEN MatchedRoadID IS NOT NULL AND RoadNameText <> MasterRoadName
                         THEN N'RoadName does not match Road master' END,
                    CASE WHEN MatchedRoadID IS NOT NULL AND AnalysisZoneText <> MasterAnalysisZone
                         THEN N'AnalysisZone does not match Road master' END,
                    CASE WHEN StartTimeValue IS NULL THEN N'StartTimestamp is invalid' END,
                    CASE WHEN EndTimeText IS NOT NULL AND EndTimeValue IS NULL
                         THEN N'EndTimestamp is invalid' END,
                    CASE WHEN EndTimeValue IS NOT NULL AND StartTimeValue IS NOT NULL
                                   AND EndTimeValue < StartTimeValue
                         THEN N'EndTimestamp precedes StartTimestamp' END,
                    CASE WHEN EventDateValue IS NULL THEN N'EventDate is invalid' END,
                    CASE WHEN StartTimeValue IS NOT NULL AND EventDateValue IS NOT NULL
                                   AND CONVERT(date, StartTimeValue) <> EventDateValue
                         THEN N'EventDate does not match StartTimestamp' END,
                    CASE WHEN VehicleTypeText IS NULL OR LEN(VehicleTypeText) > 30
                         THEN N'VehicleTypeCode is invalid' END,
                    CASE WHEN SideText IS NULL OR SideText NOT IN (N'LEFT', N'RIGHT')
                         THEN N'SideCode is invalid' END,
                    CASE WHEN DurationValue IS NULL OR DurationValue <= 0
                         THEN N'ParkingDurationMin is invalid' END,
                    CASE WHEN OccupiedWidthValue IS NULL OR OccupiedWidthValue <= 0
                         THEN N'OccupiedWidthM is invalid' END,
                    CASE WHEN IsLegalValue IS NULL THEN N'LegalParking is invalid' END,
                    CASE WHEN LEN(RestrictionIDText) > 20
                         THEN N'ActiveRestrictionID exceeds 20 characters' END,
                    CASE WHEN RestrictionIDText IS NOT NULL AND MatchedRestrictionID IS NULL
                         THEN N'ActiveRestrictionID does not resolve to ParkingRestrictionClean' END
                ), N'') AS RejectReasonValue
            FROM Referenced
        )
        INSERT transform.ParkingEventClean
        (
            LoadBatchKey, LoadFileKey, SourceRowNumber,
            EventID, VehicleID, RoadID, RoadName, SegmentID,
            StartTimestamp, EndTimestamp, EventDate,
            VehicleTypeCode, SideCode, ParkingDurationMin,
            OccupiedWidthM, IsLegalParking, ActiveRestrictionID,
            AnalysisZone, DuplicateRank, IsOpenEvent,
            IsDurationEstimated, RestrictionLinkMissingFlag,
            IsValid, RejectReason, RecordHashSHA256
        )
        SELECT
            LoadBatchKey,
            LoadFileKey,
            SourceRowNumber,
            CONVERT(varchar(30), LEFT(EventIDText, 30)),
            CONVERT(varchar(30), LEFT(VehicleIDText, 30)),
            CONVERT(varchar(10), LEFT(RoadIDText, 10)),
            LEFT(RoadNameText, 150),
            CONVERT(varchar(20), LEFT(SegmentIDText, 20)),
            StartTimeValue,
            EndTimeValue,
            EventDateValue,
            CONVERT(varchar(30), LEFT(VehicleTypeText, 30)),
            CONVERT(varchar(10), LEFT(SideText, 10)),
            DurationValue,
            OccupiedWidthValue,
            IsLegalValue,
            CONVERT(varchar(20), LEFT(RestrictionIDText, 20)),
            LEFT(AnalysisZoneText, 100),
            CONVERT(int, DuplicateRankValue),
            CONVERT(bit, CASE WHEN EndTimeValue IS NULL THEN 1 ELSE 0 END),
            CONVERT(bit, CASE WHEN EndTimeValue IS NULL THEN 1 ELSE 0 END),
            CONVERT
            (
                bit,
                CASE WHEN IsLegalValue = 0 AND MatchedRestrictionID IS NULL
                     THEN 1 ELSE 0 END
            ),
            CONVERT(bit, CASE WHEN RejectReasonValue IS NULL THEN 1 ELSE 0 END),
            LEFT(RejectReasonValue, 1000),
            COALESCE
            (
                RecordHashSHA256,
                HASHBYTES('SHA2_256', CONVERT(varbinary(max), RawJson))
            )
        FROM Ruled
        WHERE DuplicateRankValue = 1;

        ;WITH Ranked AS
        (
            SELECT
                Raw.LoadFileKey,
                Raw.SourceRowNumber,
                Raw.EventID,
                Raw.RawJson,
                ROW_NUMBER() OVER
                (
                    PARTITION BY NULLIF(LTRIM(RTRIM(Raw.EventID)), N'')
                    ORDER BY Raw.SourceRowNumber, Raw.StageRowKey
                ) AS DuplicateRankValue
            FROM extract.ParkingEventRaw AS Raw
            WHERE Raw.LoadBatchKey = @LoadBatchKey
        )
        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            LoadFileKey,
            SourceRowNumber,
            EventID,
            'TRN_PARKING_DUPLICATE',
            'WARNING',
            N'Duplicate EventID; the smallest SourceRowNumber was retained.',
            RawJson
        FROM Ranked
        WHERE DuplicateRankValue > 1;

        INSERT DanangSmartParkingDW.etl.RejectedRow
        (
            LoadFileKey, SourceRowNumber, BusinessKeyText,
            RuleCode, Severity, Reason, RawPayload
        )
        SELECT
            Clean.LoadFileKey,
            Clean.SourceRowNumber,
            Clean.EventID,
            'TRN_PARKING_INVALID',
            'ERROR',
            Clean.RejectReason,
            Raw.RawJson
        FROM transform.ParkingEventClean AS Clean
        JOIN extract.ParkingEventRaw AS Raw
          ON Raw.LoadFileKey = Clean.LoadFileKey
         AND Raw.SourceRowNumber = Clean.SourceRowNumber
        WHERE Clean.LoadBatchKey = @LoadBatchKey
          AND Clean.IsValid = 0;

        COMMIT TRANSACTION;

        /*
            Validate after COMMIT so a failed batch retains Clean/reject evidence
            for debugging, following the package-20 convention.
        */
        IF (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey) <> 16800
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 4283
           OR (SELECT COUNT_BIG(*) FROM transform.WeatherHourlyClean
               WHERE LoadBatchKey = @LoadBatchKey) <> 168
            THROW 51810, 'Event transform dedup row counts are incorrect.', 1;

        IF (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 16800
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 4283
           OR (SELECT COUNT_BIG(*) FROM transform.WeatherHourlyClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 168
            THROW 51811, 'One or more deduplicated event rows are invalid.', 1;

        IF (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey AND SpeedMissingFlag = 1) <> 161
           OR (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
               WHERE LoadBatchKey = @LoadBatchKey AND VehicleMixValidFlag = 0) <> 3838
           OR (SELECT COUNT_BIG(*) FROM transform.TrafficObservationClean
               WHERE LoadBatchKey = @LoadBatchKey AND ParkingCountValidFlag = 0) <> 781
            THROW 51812, 'Traffic data-quality flag reconciliation failed.', 1;

        IF (SELECT COALESCE(SUM(CONVERT(bigint, VehicleCount)), 0)
            FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 6596879
            THROW 51813, 'Traffic vehicle-volume reconciliation failed.', 1;

        IF (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsLegalParking = 0) <> 1571
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsOpenEvent = 1) <> 64
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsDurationEstimated = 1) <> 64
           OR (SELECT COUNT_BIG(*) FROM transform.ParkingEventClean
               WHERE LoadBatchKey = @LoadBatchKey AND RestrictionLinkMissingFlag = 1) <> 607
            THROW 51814, 'Parking event flag reconciliation failed.', 1;

        IF (SELECT COALESCE(SUM(RainMm), 0)
            FROM transform.WeatherHourlyClean
            WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1) <> 47.50
           OR (SELECT COUNT_BIG(*) FROM transform.WeatherHourlyClean
               WHERE LoadBatchKey = @LoadBatchKey AND IsRainyHour = 1) <> 11
            THROW 51815, 'Weather reconciliation failed.', 1;

        IF
        (
            SELECT COUNT_BIG(*)
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode IN
              (
                  'TRN_TRAFFIC_INVALID',
                  'TRN_PARKING_INVALID',
                  'TRN_WEATHER_INVALID'
              )
        ) <> 0
            THROW 51816, 'The event transform produced invalid rows.', 1;

        IF
        (
            SELECT COUNT_BIG(*)
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode = 'TRN_TRAFFIC_DUPLICATE'
        ) <> 84
           OR
        (
            SELECT COUNT_BIG(*)
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode = 'TRN_PARKING_DUPLICATE'
        ) <> 17
           OR
        (
            SELECT COUNT_BIG(*)
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode = 'TRN_WEATHER_DUPLICATE'
        ) <> 0
            THROW 51817, 'Duplicate audit reconciliation failed.', 1;

        IF @ReturnDetail = 1
        BEGIN
            SELECT
                ObjectName,
                ActualRows,
                ValidRows,
                InvalidRows,
                ExpectedRows,
                CONVERT
                (
                    bit,
                    CASE WHEN ActualRows = ExpectedRows
                                   AND ValidRows = ExpectedRows
                                   AND InvalidRows = 0
                         THEN 1 ELSE 0 END
                ) AS IsMatched
            FROM
            (
                SELECT
                    'transform.TrafficObservationClean' AS ObjectName,
                    COUNT_BIG(*) AS ActualRows,
                    COALESCE(SUM(CONVERT(bigint, IsValid)), 0) AS ValidRows,
                    COALESCE(SUM(CONVERT(bigint, 1 - IsValid)), 0) AS InvalidRows,
                    CONVERT(bigint, 16800) AS ExpectedRows
                FROM transform.TrafficObservationClean
                WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT
                    'transform.ParkingEventClean', COUNT_BIG(*),
                    COALESCE(SUM(CONVERT(bigint, IsValid)), 0),
                    COALESCE(SUM(CONVERT(bigint, 1 - IsValid)), 0), 4283
                FROM transform.ParkingEventClean
                WHERE LoadBatchKey = @LoadBatchKey
                UNION ALL
                SELECT
                    'transform.WeatherHourlyClean', COUNT_BIG(*),
                    COALESCE(SUM(CONVERT(bigint, IsValid)), 0),
                    COALESCE(SUM(CONVERT(bigint, 1 - IsValid)), 0), 168
                FROM transform.WeatherHourlyClean
                WHERE LoadBatchKey = @LoadBatchKey
            ) AS Summary
            ORDER BY ObjectName;

            SELECT
                COUNT_BIG(*) AS TrafficRows,
                SUM(CONVERT(bigint, VehicleCount)) AS VehicleVolume,
                AVG(CONVERT(decimal(18,6), AvgSpeedKmh)) AS AvgSpeedKmh,
                AVG(CONVERT(decimal(18,6), CongestionIndex)) AS AvgCongestion,
                SUM(CONVERT(int, SpeedMissingFlag)) AS MissingSpeedRows,
                SUM(CASE WHEN VehicleMixValidFlag = 0 THEN 1 ELSE 0 END) AS InvalidMixRows,
                SUM(CASE WHEN ParkingCountValidFlag = 0 THEN 1 ELSE 0 END)
                    AS InvalidParkingCountRows
            FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey;

            SELECT
                COUNT_BIG(*) AS ParkingRows,
                SUM(CASE WHEN IsLegalParking = 0 THEN 1 ELSE 0 END) AS IllegalEvents,
                CAST
                (
                    1.0 * SUM(CASE WHEN IsLegalParking = 0 THEN 1 ELSE 0 END)
                    / NULLIF(COUNT_BIG(*), 0)
                    AS decimal(9,6)
                ) AS IllegalRate,
                AVG(CONVERT(decimal(18,6), ParkingDurationMin)) AS AvgDurationMin,
                SUM(CONVERT(int, IsOpenEvent)) AS OpenEvents,
                SUM(CONVERT(int, IsDurationEstimated)) AS EstimatedDurationEvents,
                SUM(CONVERT(int, RestrictionLinkMissingFlag))
                    AS IllegalWithoutRestrictionLink
            FROM transform.ParkingEventClean
            WHERE LoadBatchKey = @LoadBatchKey;

            SELECT
                COUNT_BIG(*) AS WeatherRows,
                SUM(RainMm) AS TotalRainMm,
                SUM(CONVERT(int, IsRainyHour)) AS RainyHours
            FROM transform.WeatherHourlyClean
            WHERE LoadBatchKey = @LoadBatchKey;

            SELECT
                RuleCode,
                COUNT_BIG(*) AS AuditRows
            FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
            JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
              ON LoadFile.LoadFileKey = Rejected.LoadFileKey
            WHERE LoadFile.LoadBatchKey = @LoadBatchKey
              AND Rejected.RuleCode IN
              (
                  'TRN_TRAFFIC_DUPLICATE',
                  'TRN_TRAFFIC_INVALID',
                  'TRN_PARKING_DUPLICATE',
                  'TRN_PARKING_INVALID',
                  'TRN_WEATHER_DUPLICATE',
                  'TRN_WEATHER_INVALID'
              )
            GROUP BY RuleCode
            ORDER BY RuleCode;

            /* Visible Unicode checkpoint requested during package 20 review. */
            SELECT TOP (1)
                RoadID,
                RoadName,
                AnalysisZone,
                CONVERT
                (
                    bit,
                    CASE WHEN RoadName = N'Trần Phú'
                                   AND AnalysisZone = N'Hải Châu core'
                         THEN 1 ELSE 0 END
                ) AS UnicodeMatched,
                N'Trần Phú / Hải Châu core' AS ExpectedUnicodeValue
            FROM transform.TrafficObservationClean
            WHERE LoadBatchKey = @LoadBatchKey
              AND RoadID = 'RD001'
            ORDER BY SourceRowNumber;
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
