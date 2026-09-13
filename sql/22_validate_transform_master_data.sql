/*
    Da Nang Smart Parking
    Acceptance test for package 20 - Transform Master Data.

    Read-only script:
      - does not rerun dbo.usp_TransformMasterData;
      - does not insert, update or delete data;
      - returns PASS only when every package-20 data check succeeds.
*/

USE DanangSmartParkingSTG;
GO

SET NOCOUNT ON;

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

IF @LoadBatchKey IS NULL
    THROW 51700, 'No LoadBatch row was found.', 1;

DECLARE @Failures TABLE
(
    CheckName nvarchar(200) NOT NULL,
    ActualValue nvarchar(200) NULL,
    ExpectedValue nvarchar(200) NOT NULL
);

DECLARE @TableChecks TABLE
(
    ObjectName sysname NOT NULL,
    ActualRows bigint NOT NULL,
    ValidRows bigint NOT NULL,
    InvalidRows bigint NOT NULL,
    ExpectedRows bigint NOT NULL
);

INSERT @TableChecks
(
    ObjectName,
    ActualRows,
    ValidRows,
    InvalidRows,
    ExpectedRows
)
SELECT
    'transform.RoadClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    30
FROM transform.RoadClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.ParkingFacilityClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    20
FROM transform.ParkingFacilityClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.ParkingRestrictionClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    18
FROM transform.ParkingRestrictionClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.POIClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    50
FROM transform.POIClean
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'transform.RoadSurveyClean',
    COUNT_BIG(*),
    COALESCE(SUM(CASE WHEN IsValid = 1 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN IsValid = 0 THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    30
FROM transform.RoadSurveyClean
WHERE LoadBatchKey = @LoadBatchKey;

DECLARE @BatchStatus varchar(20);
DECLARE @BatchError nvarchar(2000);

SELECT
    @BatchStatus = LoadStatus,
    @BatchError = ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

IF OBJECT_ID(N'dbo.usp_TransformMasterData', N'P') IS NULL
BEGIN
    INSERT @Failures VALUES
        (N'Procedure exists', N'NOT FOUND', N'dbo.usp_TransformMasterData');
END;

IF ISNULL(@BatchStatus, '') <> 'BRONZE_LOADED'
BEGIN
    INSERT @Failures VALUES
        (N'Batch status after package 20', COALESCE(@BatchStatus, N'NULL'), N'BRONZE_LOADED');
END;

IF @BatchError IS NOT NULL
BEGIN
    INSERT @Failures VALUES
        (N'Batch ErrorMessage', LEFT(@BatchError, 200), N'NULL');
END;

INSERT @Failures (CheckName, ActualValue, ExpectedValue)
SELECT
    CONCAT(ObjectName, N' row/valid/invalid counts'),
    CONCAT(ActualRows, N'/', ValidRows, N'/', InvalidRows),
    CONCAT(ExpectedRows, N'/', ExpectedRows, N'/0')
FROM @TableChecks
WHERE ActualRows <> ExpectedRows
   OR ValidRows <> ExpectedRows
   OR InvalidRows <> 0;

DECLARE @TotalRows bigint =
(
    SELECT SUM(ActualRows) FROM @TableChecks
);

DECLARE @TotalValidRows bigint =
(
    SELECT SUM(ValidRows) FROM @TableChecks
);

IF @TotalRows <> 148 OR @TotalValidRows <> 148
BEGIN
    INSERT @Failures VALUES
    (
        N'Total master rows/valid rows',
        CONCAT(@TotalRows, N'/', @TotalValidRows),
        N'148/148'
    );
END;

/* Every Clean row must trace to one RAW row using batch, file and row number. */
DECLARE @UntracedRows bigint =
      (SELECT COUNT_BIG(*)
       FROM transform.RoadClean AS Clean
       LEFT JOIN extract.RoadRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.ParkingFacilityClean AS Clean
       LEFT JOIN extract.ParkingLocationRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.ParkingRestrictionClean AS Clean
       LEFT JOIN extract.ParkingRestrictionRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.POIClean AS Clean
       LEFT JOIN extract.POIRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL)
    + (SELECT COUNT_BIG(*)
       FROM transform.RoadSurveyClean AS Clean
       LEFT JOIN extract.RoadSurveyRaw AS Raw
         ON Raw.LoadBatchKey = Clean.LoadBatchKey
        AND Raw.LoadFileKey = Clean.LoadFileKey
        AND Raw.SourceRowNumber = Clean.SourceRowNumber
       WHERE Clean.LoadBatchKey = @LoadBatchKey
         AND Raw.StageRowKey IS NULL);

IF @UntracedRows <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Clean rows without matching RAW row', CONVERT(nvarchar(30), @UntracedRows), N'0');
END;

DECLARE @MissingHashes bigint =
      (SELECT COUNT_BIG(*) FROM transform.RoadClean
       WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
    + (SELECT COUNT_BIG(*) FROM transform.ParkingFacilityClean
       WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
    + (SELECT COUNT_BIG(*) FROM transform.ParkingRestrictionClean
       WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL)
    + (SELECT COUNT_BIG(*) FROM transform.POIClean
       WHERE LoadBatchKey = @LoadBatchKey AND AttributeHash IS NULL);

IF @MissingHashes <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Missing AttributeHash rows', CONVERT(nvarchar(30), @MissingHashes), N'0');
END;

DECLARE @DuplicateBusinessKeys bigint =
      (SELECT COUNT_BIG(*) FROM
       (SELECT RoadID FROM transform.RoadClean
        WHERE LoadBatchKey = @LoadBatchKey GROUP BY RoadID HAVING COUNT_BIG(*) > 1) AS D)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT ParkingID FROM transform.ParkingFacilityClean
        WHERE LoadBatchKey = @LoadBatchKey GROUP BY ParkingID HAVING COUNT_BIG(*) > 1) AS D)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT RestrictionID FROM transform.ParkingRestrictionClean
        WHERE LoadBatchKey = @LoadBatchKey GROUP BY RestrictionID HAVING COUNT_BIG(*) > 1) AS D)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT POIID FROM transform.POIClean
        WHERE LoadBatchKey = @LoadBatchKey GROUP BY POIID HAVING COUNT_BIG(*) > 1) AS D)
    + (SELECT COUNT_BIG(*) FROM
       (SELECT SegmentID FROM transform.RoadSurveyClean
        WHERE LoadBatchKey = @LoadBatchKey GROUP BY SegmentID HAVING COUNT_BIG(*) > 1) AS D);

IF @DuplicateBusinessKeys <> 0
BEGIN
    INSERT @Failures VALUES
        (N'Duplicate master business keys', CONVERT(nvarchar(30), @DuplicateBusinessKeys), N'0');
END;

DECLARE @TotalCapacity int;
DECLARE @ReferenceCapacity int;
DECLARE @ReferenceFacilityCount int;

SELECT
    @TotalCapacity = COALESCE(SUM(CapacitySpaces), 0),
    @ReferenceCapacity = COALESCE
    (
        SUM(CASE WHEN IsReferenceCapacity = 1 THEN CapacitySpaces ELSE 0 END),
        0
    ),
    @ReferenceFacilityCount = COALESCE
    (
        SUM(CASE WHEN IsReferenceCapacity = 1 THEN 1 ELSE 0 END),
        0
    )
FROM transform.ParkingFacilityClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1;

IF @TotalCapacity <> 2267
    INSERT @Failures VALUES
        (N'Total parking capacity', CONVERT(nvarchar(30), @TotalCapacity), N'2267');

IF @ReferenceCapacity <> 397
    INSERT @Failures VALUES
        (N'Reference parking capacity', CONVERT(nvarchar(30), @ReferenceCapacity), N'397');

IF @ReferenceFacilityCount <> 2
    INSERT @Failures VALUES
        (N'Reference facility count', CONVERT(nvarchar(30), @ReferenceFacilityCount), N'2');

DECLARE @ImputedWidths bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.RoadSurveyClean
    WHERE LoadBatchKey = @LoadBatchKey
      AND WidthImputedFlag = 1
      AND RoadWidthRawM IS NULL
      AND RoadWidthResolvedM IS NOT NULL
      AND SegmentID IN ('SEG_009', 'SEG_018', 'SEG_027')
);

DECLARE @UnexpectedWidthResults bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.RoadSurveyClean AS Survey
    LEFT JOIN transform.RoadClean AS Road
      ON Road.LoadBatchKey = Survey.LoadBatchKey
     AND Road.RoadID = Survey.RoadID
     AND Road.IsValid = 1
    WHERE Survey.LoadBatchKey = @LoadBatchKey
      AND
      (
          Survey.RoadWidthResolvedM IS NULL
          OR (Survey.WidthImputedFlag = 1
              AND Survey.RoadWidthResolvedM <> Road.RoadWidthM)
          OR (Survey.WidthImputedFlag = 1
              AND Survey.SegmentID NOT IN ('SEG_009', 'SEG_018', 'SEG_027'))
      )
);

IF @ImputedWidths <> 3
    INSERT @Failures VALUES
        (N'Expected imputed survey widths', CONVERT(nvarchar(30), @ImputedWidths), N'3');

IF @UnexpectedWidthResults <> 0
    INSERT @Failures VALUES
        (N'Unresolved or unexpected survey widths',
         CONVERT(nvarchar(30), @UnexpectedWidthResults), N'0');

DECLARE @ValidR003 bigint =
(
    SELECT COUNT_BIG(*)
    FROM transform.ParkingRestrictionClean
    WHERE LoadBatchKey = @LoadBatchKey
      AND RestrictionID = 'R003'
      AND RoadID IS NULL
      AND RoadName = N'Doãn Khuê'
      AND IsValid = 1
      AND RejectReason IS NULL
);

IF @ValidR003 <> 1
    INSERT @Failures VALUES
        (N'R003 valid with NULL RoadID', CONVERT(nvarchar(30), @ValidR003), N'1');

DECLARE @MasterTransformRejectedRows bigint =
(
    SELECT COUNT_BIG(*)
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
);

IF @MasterTransformRejectedRows <> 0
    INSERT @Failures VALUES
        (N'Master transform rejected rows',
         CONVERT(nvarchar(30), @MasterTransformRejectedRows), N'0');

DECLARE @UnicodeRoadName nvarchar(150);
DECLARE @UnicodeAnalysisZone nvarchar(100);
DECLARE @UnicodeMatched bit = 0;

SELECT
    @UnicodeRoadName = RoadName,
    @UnicodeAnalysisZone = AnalysisZone,
    @UnicodeMatched = CONVERT(bit, CASE
        WHEN RoadName = N'Trần Phú'
         AND AnalysisZone = N'Hải Châu core'
         AND IsValid = 1 THEN 1
        ELSE 0
    END)
FROM transform.RoadClean
WHERE LoadBatchKey = @LoadBatchKey
  AND SourceRowNumber = 1
  AND RoadID = 'RD001';

IF ISNULL(@UnicodeMatched, 0) <> 1
BEGIN
    INSERT @Failures VALUES
    (
        N'Road Unicode checkpoint',
        CONCAT(COALESCE(@UnicodeRoadName, N'NULL'), N' / ',
               COALESCE(@UnicodeAnalysisZone, N'NULL')),
        N'Trần Phú / Hải Châu core'
    );
END;

/* Always show evidence before returning PASS or THROW. */
SELECT
    @LoadBatchKey AS LoadBatchKey,
    @BatchStatus AS LoadStatus,
    @BatchError AS ErrorMessage;

SELECT
    ObjectName,
    ActualRows,
    ValidRows,
    InvalidRows,
    ExpectedRows,
    CASE WHEN ActualRows = ExpectedRows
                   AND ValidRows = ExpectedRows
                   AND InvalidRows = 0
         THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END AS IsMatched
FROM @TableChecks
ORDER BY ObjectName;

SELECT
    @TotalRows AS TotalMasterRows,
    @TotalValidRows AS TotalValidRows,
    @UntracedRows AS UntracedRows,
    @MissingHashes AS MissingHashes,
    @DuplicateBusinessKeys AS DuplicateBusinessKeys,
    @MasterTransformRejectedRows AS RejectedRows;

SELECT
    @TotalCapacity AS TotalCapacity,
    @ReferenceCapacity AS ReferenceCapacity,
    @ReferenceFacilityCount AS ReferenceFacilityCount,
    @ImputedWidths AS ImputedWidths,
    @UnexpectedWidthResults AS UnexpectedWidthResults,
    @ValidR003 AS ValidR003;

SELECT
    'RD001' AS RoadID,
    @UnicodeRoadName AS RoadName,
    @UnicodeAnalysisZone AS AnalysisZone,
    @UnicodeMatched AS UnicodeMatched,
    N'Trần Phú / Hải Châu core' AS ExpectedUnicodeValue;

IF EXISTS (SELECT 1 FROM @Failures)
BEGIN
    SELECT
        CheckName,
        ActualValue,
        ExpectedValue
    FROM @Failures
    ORDER BY CheckName;

    THROW 51799, 'PACKAGE 20 ACCEPTANCE FAILED. Review the Failures result set.', 1;
END;

SELECT
    'PASS' AS AcceptanceStatus,
    @LoadBatchKey AS LoadBatchKey,
    'PACKAGE 20 ACCEPTED - ready for package 21' AS Message;
GO
