# 40 — Load Facts bằng SSIS Data Flow

## 1. Mục tiêu và checkpoint đầu vào

Package này nạp năm Fact từ tầng Silver của `DanangSmartParkingSTG` sang
`DanangSmartParkingDW.dwh`. Toàn bộ thao tác di chuyển dữ liệu phải nằm trong
**Data Flow Task**; `Execute SQL Task` chỉ dùng để kiểm tra.

Chỉ bắt đầu package 40 khi:

- package `23_Validate_Transform.dtsx` đã `PASS` và batch có
  `LoadStatus = SILVER_VALIDATED`;
- package `30_Load_Dimensions.dtsx` đã `PASS` trên cùng `LoadBatchKey`;
- các Dimension bắt buộc đã có đủ surrogate key;
- hai project connection manager `(project) CM_DanangSTG` và
  `(project) CM_DanangDW` đều kết nối thành công.

Các file dùng trong bước này:

| File | Vai trò |
|---|---|
| `40_Load_Facts.dtsx` | Bốn Data Flow nạp năm Fact và một postcheck |
| [`sql/27_precheck_fact_load.sql`](../../sql/27_precheck_fact_load.sql) | Kiểm tra read-only trước khi chạy package |
| [`sql/27_validate_fact_load.sql`](../../sql/27_validate_fact_load.sql) | Nghiệm thu read-only sau khi chạy package |

Checkpoint lịch sử gần nhất là batch `18`, nhưng không được hard-code `18` trong
package. Khi chạy độc lập, lấy batch mới nhất có trạng thái `SILVER_VALIDATED` và gán
**giá trị số** đó vào parameter `pLoadBatchKey`.

## 2. Kết quả cần đạt

| Fact | Grain chống trùng | Expected |
|---|---|---:|
| `FactParkingCapacitySnapshot` | `SnapshotDateKey + ParkingFacilityKey` | 20 |
| `FactRoadSurveySnapshot` | `SnapshotDateKey + SegmentKey` | 30 |
| `FactWeatherHourly` | `WeatherTimestamp` | 168 |
| `FactTrafficObservation` | `EventID` | 16.800 |
| `FactParkingEvent` | `EventID` | 4.283 |
| **Tổng** |  | **21.301** |

Thứ tự nạp đã thống nhất:

1. Parking Capacity Snapshot và Road Survey Snapshot.
2. Weather Hourly.
3. Traffic Observation.
4. Parking Event.

Thứ tự này giúp kiểm tra lần lượt từ Fact nhỏ đến Fact lớn. Các Dimension phải được
nạp trước toàn bộ Fact.

## 3. Grain và quy tắc chất lượng dữ liệu

### 3.1. Quy tắc chung

- Source luôn là `(project) CM_DanangSTG` và chỉ đọc `transform.*Clean`.
- Lookup và destination luôn là `(project) CM_DanangDW`.
- Mọi source lọc `LoadBatchKey = ? AND IsValid = 1`.
- Traffic và Parking Event lọc thêm `DuplicateRank = 1`.
- Lookup SCD2 phải dùng business key tại effective event time, không chỉ lấy
  `IsCurrent = 1`.
- Quan hệ bắt buộc không match phải đi vào `etl.RejectedRow`; không tự đổi thành key
  `0` nếu chưa có quy tắc Unknown member tương ứng.
- Dòng đã tồn tại theo Fact business key đi vào nhánh `Existing` và không insert lại.
  Đây là skip idempotent, không phải lỗi dữ liệu.
- OLE DB Destination dùng `Table or view - fast load`, bật
  `TABLOCK,CHECK_CONSTRAINTS`.

Luồng chuẩn:

```text
OLE DB Source: transform.*Clean
  → Lookup Date/Time
  → Lookup các business Dimension
  → Lookup Fact business key
  → Conditional Split
       ├─ OrphanOrInvalid → Derived Column reject → etl.RejectedRow
       ├─ Existing        → Row Count hoặc bỏ qua có chủ đích
       └─ ValidNew        → OLE DB Destination Fast Load: dwh.Fact*
```

### 3.2. `NULL` hợp lệ và `NULL` gây reject

`Clean` không có nghĩa mọi cột đều khác `NULL`.

| Trường hợp | Xử lý |
|---|---|
| `FactTrafficObservation.AvgSpeedKmh` null | Hợp lệ khi `SpeedMissingFlag = 1`; không thay bằng `0` |
| `FactRoadSurveySnapshot.RoadWidthRawM` null | Hợp lệ cho 3 dòng imputed; dùng `RoadWidthResolvedM`, giữ `WidthImputedFlag = 1` |
| Parking `EndTimestamp`, `EndDateKey`, `EndTimeKey` null | Hợp lệ cho 64 open event; `IsOpenEvent = 1`, `IsDurationEstimated = 1` |
| Parking `RestrictionKey` null | Hợp lệ khi source không có active restriction; không dùng key `0` |
| Thiếu Date/Time hoặc Dimension bắt buộc | Reject với `Severity = ERROR` |

`RestrictionLinkMissingFlag = 1` là cờ DQ có chủ đích. Không tự loại toàn bộ các dòng
này; KPI vẫn giữ Parking Event, còn báo cáo có thể lọc theo cờ.

## 4. Đối chiếu hai package tham chiếu

Hai package được cung cấp là nguồn tham chiếu triển khai, không thay thế yêu cầu của
tài liệu này.

### 4.1. Phần đã đúng trong `40_Load_Facts.dtsx`

- Có parameter `pLoadBatchKey` kiểu `Int64`, `Required = True`, mặc định `0`.
- Có variable `User::LoadBatchKey` kiểu `Int64`, expression
  `@[$Package::pLoadBatchKey]`.
- Có đúng bốn Data Flow Task theo thứ tự ở mục 2.
- Mỗi Fact có Lookup business key để chống insert lặp.
- Traffic và Parking lookup `DimRoadSegment`/`DimCamera` theo
  `EventTimestamp` trong khoảng `ValidFrom/ValidTo`.
- Parking lookup `DimRoadSegment`/`DimParkingRestriction` theo `StartTimestamp`.
- Các destination dùng fast load và kiểm tra constraint.

### 4.2. Hai sửa đổi bắt buộc trước nghiệm thu

1. Trong file tham chiếu, các output `OrphanOrInvalid` của năm Conditional Split chưa
   được nối. Phải nối chúng vào `etl.RejectedRow` theo mục 11. Không được để orphan bị
   loại âm thầm.
2. Task `SQL - Validate Fact Load` đang có một Parameter Mapping tới
   `$Package::pLoadBatchKey`, nhưng SQL nhúng không có dấu `?`. Xóa mapping thừa, hoặc
   thay SQL bằng câu có `CONVERT(bigint, ?)` như mục 12.2. Tài liệu này chọn phương án
   thứ hai để validation kiểm tra đúng batch.

Ngoài ra, `50_Final_DWH_Validation.dtsx` gọi `etl.usp_ValidateFinalDWH` và nhận năm
output variables. Đó là final structural gate, không thay cho acceptance của package
40. Procedure đó phải được cài trước khi chạy package 50; xem
[`50_FINAL_DWH_VALIDATION.md`](50_FINAL_DWH_VALIDATION.md).

## 5. Precheck trên SSMS

### 5.1. Lấy `LoadBatchKey`

1. Mở SSMS và kết nối SQL Server của dự án.
2. Chọn database `DanangSmartParkingDW` trên dropdown.
3. Mở New Query, chạy toàn bộ:

```sql
USE DanangSmartParkingDW;
GO

SELECT TOP (10)
    LoadBatchKey, LoadStatus, RowsRead, RowsAccepted,
    RowsRejected, ErrorMessage, CompletedAt
FROM etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Chọn dòng mới nhất có `LoadStatus = SILVER_VALIDATED`. Với checkpoint hiện tại, các
giá trị nguồn là `RowsRead / RowsAccepted / RowsRejected = 21500 / 21500 / 0`.

### 5.2. Chạy file precheck

1. Chọn **File → Open → File...**.
2. Mở [`27_precheck_fact_load.sql`](../../sql/27_precheck_fact_load.sql).
3. Giữ `@RequestedLoadBatchKey = NULL` để tự chọn batch mới nhất, hoặc thay `NULL`
   bằng một số như `18`.
4. Chạy **toàn bộ file** bằng `Execute`/`F5`.
5. Result set cuối phải có `PrecheckStatus = PASS`.

Precheck sẽ `THROW` nếu batch không phải `SILVER_VALIDATED`, source count sai, Dimension
thiếu, hoặc business key bắt buộc không resolve được. Không chạy package 40 khi chưa
có `PASS`.

Expected source:

| Source Clean | Bộ lọc | Rows |
|---|---|---:|
| `ParkingFacilityClean` | `IsValid=1` | 20 |
| `RoadSurveyClean` | `IsValid=1` | 30 |
| `WeatherHourlyClean` | `IsValid=1` | 168 |
| `TrafficObservationClean` | `IsValid=1 AND DuplicateRank=1` | 16.800 |
| `ParkingEventClean` | `IsValid=1 AND DuplicateRank=1` | 4.283 |

## 6. Tạo hoặc đưa package vào project

Nếu package `40_Load_Facts.dtsx` đã có trong project, mở nó và thực hiện checklist ở
mục 4.2. Nếu chỉ có file rời:

1. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
2. Chọn **Add Existing Package...** hoặc **Add → Existing Item...** tùy phiên bản SSDT.
3. Chọn file `40_Load_Facts.dtsx`.
4. Bảo đảm package xuất hiện dưới node **SSIS Packages**.
5. Mở package, kiểm tra hai connection manager project ở đáy designer.
6. Nhấp phải từng connection → **Edit... → Test Connection**.
7. Nhấn **Save All**.

Nếu tự tạo package mới, đặt tên chính xác `40_Load_Facts.dtsx` rồi tạo các thành phần
theo mục 7–10.

### 6.1. Parameter và variable

Trong tab **Parameters**, tạo:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Trong **SSIS → Variables**, bấm vùng trống Control Flow để lấy package scope rồi tạo:

| Thuộc tính | Giá trị |
|---|---|
| Name | `LoadBatchKey` |
| Namespace | `User` |
| Scope | `40_Load_Facts` |
| Data type | `Int64` |
| Value | `0` |
| EvaluateAsExpression | `True` |
| Expression | `@[$Package::pLoadBatchKey]` |

Trong OLE DB Source, dấu `?` được map bằng **Parameters... → Param_0 →
User::LoadBatchKey**. Không gõ `@LoadBatchKey` trực tiếp vào source SQL.

## 7. Control Flow

Control Flow cuối cùng:

```text
DFT - L0 Snapshot Facts
    ↓ Success
DFT - L1 Weather Hourly
    ↓ Success
DFT - L2 Traffic Observation
    ↓ Success
DFT - L3 Parking Event
    ↓ Success
SQL - Validate Fact Load
```

Tạo bốn Data Flow Task và một Execute SQL Task từ **SSIS Toolbox**, đổi tên đúng như
sơ đồ, rồi nối bằng precedence constraint màu xanh `Success`. Hai pipeline snapshot
nằm chung trong L0 và có thể chạy song song.

### 7.1. Cấu hình chung cho Source, Lookup và Destination

Với mỗi **OLE DB Source**:

1. Mở **OLE DB Source Editor → Connection Manager**.
2. Chọn `(project) CM_DanangSTG`.
3. Chọn `Data access mode = SQL command` và dán nguyên câu SQL tương ứng.
4. Nhấn **Parameters...**, map `Param_0 → User::LoadBatchKey`.
5. Mở **Columns**, kiểm tra metadata rồi mới nhấn **OK**.

Với mỗi **Lookup** trong thiết kế dùng Conditional Split tập trung:

1. Mở **Lookup Transformation Editor → General**.
2. Chọn `Full cache`.
3. Ở xử lý dòng không match, chọn **Ignore failure**. Khi đó dòng tiếp tục trên
   `Lookup Match Output`, còn cột surrogate output là `NULL` để Conditional Split bắt
   được. Không chọn `Redirect rows to no match output` nếu chưa nối riêng output đó.
4. Mở **Connection**, chọn `(project) CM_DanangDW` và `Use results of an SQL query`.
5. Mở **Columns**, kéo business key bên trái sang reference key bên phải và tick
   surrogate key cần đưa ra pipeline.

`Ignore failure` ở đây không có nghĩa bỏ qua orphan. Nó chỉ trì hoãn phân loại đến
Conditional Split; output `OrphanOrInvalid` vẫn bắt buộc ghi `etl.RejectedRow`.

Với mỗi **OLE DB Destination**:

1. Chọn `(project) CM_DanangDW`.
2. Chọn `Table or view - fast load` và đúng bảng `dwh.Fact*`.
3. Trong fast-load options, dùng `TABLOCK,CHECK_CONSTRAINTS`; không bật
   `Keep identity`.
4. Mở **Mappings**, map theo danh sách của từng Fact và bỏ identity key.
5. Để error disposition là `Fail component`, vì lỗi constraint/type là lỗi kỹ thuật
   cần làm package đỏ, không phải orphan nghiệp vụ.

## 8. DFT L0 — Snapshot Facts

### 8.1. Parking Capacity Snapshot

Pipeline:

```text
SRC - ParkingCapacitySnapshot
  → LKP - Capacity Snapshot Date
  → LKP - ParkingFacility Effective
  → LKP - Existing ParkingCapacitySnapshot
  → SPL - ParkingCapacitySnapshot Route
       ├─ OrphanOrInvalid → reject
       ├─ Existing        → skip
       └─ ValidNew        → DST - FactParkingCapacitySnapshot
```

Source dùng `(project) CM_DanangSTG`, `Data access mode = SQL command`:

```sql
SELECT
    LoadFileKey, SourceRowNumber, ParkingID,
    CapacitySpaces, IsReferenceCapacity,
    AttributeHash AS RecordHashSHA256,
    CONVERT(date, '2026-08-05') AS SnapshotDate,
    CONVERT(datetime2(3), SYSDATETIME()) AS LoadedAt
FROM transform.ParkingFacilityClean
WHERE LoadBatchKey = ?
  AND IsValid = 1;
```

`2026-08-05` là effective snapshot date đã thống nhất cho dataset này, không phải
technical load time. Khi dataset mới có snapshot date khác, phải đưa ngày này thành
metadata/parameter; không tiếp tục hard-code ngày cũ.

Lookup:

| Lookup | Query/reference | Join | Output |
|---|---|---|---|
| Capacity Snapshot Date | `DimDate(DateKey, DateValue)` | `SnapshotDate → DateValue` | `SnapshotDateKey` |
| ParkingFacility Effective | version có hiệu lực tại snapshot | `ParkingID → ParkingID` | `ParkingFacilityKey` |
| Existing Fact | `FactParkingCapacitySnapshot` | `SnapshotDateKey + ParkingFacilityKey` | `ExistingFactKey` |

Với lookup facility, query của dataset hiện tại:

```sql
SELECT ParkingFacilityKey, ParkingID
FROM dwh.DimParkingFacility
WHERE ValidFrom <= CONVERT(datetime2(3), '2026-08-05T00:00:00')
  AND (ValidTo IS NULL
       OR ValidTo > CONVERT(datetime2(3), '2026-08-05T00:00:00'));
```

Conditional Split theo đúng thứ tự:

```text
OrphanOrInvalid: ISNULL(SnapshotDateKey) || ISNULL(ParkingFacilityKey)
Existing:        !ISNULL(ExistingFactKey)
ValidNew:        Default output
```

Mapping destination:

```text
SnapshotDateKey, ParkingFacilityKey, CapacitySpaces, IsReferenceCapacity,
LoadFileKey, SourceRowNumber, RecordHashSHA256, LoadedAt
```

Không map identity `ParkingCapacityFactKey`.

### 8.2. Road Survey Snapshot

Pipeline:

```text
SRC - RoadSurveySnapshot
  → LKP - RoadSurvey Snapshot Date
  → LKP - Road Effective
  → LKP - Existing RoadSurveySnapshot
  → SPL - RoadSurveySnapshot Route
       └─ ValidNew → DC - RoadSurvey Hash → DST - FactRoadSurveySnapshot
```

Source đọc `transform.RoadSurveyClean`, lọc `LoadBatchKey = ? AND IsValid = 1`, tạo:

- `SnapshotDate = 2026-08-05`;
- `RecordHashSHA256 = CAST(HASHBYTES('SHA2_256', CONCAT(...)) AS binary(32))`;
- `LoadedAt = CONVERT(datetime2(3), SYSDATETIME())`.

Giữ `RoadWidthRawM = NULL` cho ba dòng imputed. Các cột
`RoadWidthResolvedM`, `LaneCount`, `SidewalkWidthM`, `ShoulderWidthM`,
`QualityConfidence` và hash là bắt buộc.

Lookup:

| Lookup | Join | Output |
|---|---|---|
| Snapshot Date | `SnapshotDate → DimDate.DateValue` | `SnapshotDateKey` |
| Road Effective | `SegmentID → DimRoadSegment.SegmentID` tại snapshot | `SegmentKey` |
| Existing Fact | `SnapshotDateKey + SegmentKey` | `ExistingFactKey` |

Conditional Split:

```text
OrphanOrInvalid:
    ISNULL(SnapshotDateKey) || ISNULL(SegmentKey)
    || ISNULL(RoadWidthResolvedM) || ISNULL(LaneCount)
    || ISNULL(SidewalkWidthM) || ISNULL(ShoulderWidthM)
    || ISNULL(QualityConfidence) || ISNULL(RecordHashSHA256)
Existing: !ISNULL(ExistingFactKey)
ValidNew: Default output
```

Nếu provider trả hash dưới dạng `DT_BYTES` length 8000, thêm Data Conversion sau
`ValidNew`, đổi `RecordHashSHA256` thành `RecordHash32` kiểu `DT_BYTES`, length `32`,
rồi map `RecordHash32 → RecordHashSHA256`.

`SourceSurveyDateKey` không map và giữ `NULL`, vì RAW không có ngày khảo sát thực địa.

## 9. DFT L1 — Weather Hourly

Pipeline:

```text
SRC - WeatherHourly
  → LKP - Weather Date
  → LKP - Weather Time
  → LKP - WeatherSource
  → LKP - Existing WeatherHourly
  → SPL - WeatherHourly Route
       ├─ OrphanOrInvalid → reject
       ├─ Existing        → skip
       └─ ValidNew        → DST - FactWeatherHourly
```

Source query:

```sql
SELECT
    LoadFileKey, SourceRowNumber,
    WeatherTimestamp, EventDate, HourNumber,
    TemperatureC, DailyMinCActual, DailyMaxCActual,
    DailyReferenceCActual, RainMm, HumidityPct,
    VisibilityKm, WindKmh,
    TemperatureStatus, PrecipitationStatus, SourceReference,
    IsRainyHour, RecordHashSHA256,
    CONVERT(datetime2(3), SYSDATETIME()) AS LoadedAt
FROM transform.WeatherHourlyClean
WHERE LoadBatchKey = ?
  AND IsValid = 1;
```

Lookup:

| Lookup | Join | Output |
|---|---|---|
| Weather Date | `EventDate → DimDate.DateValue` | `DateKey` |
| Weather Time | `HourNumber → DimTime.Hour24`, reference lọc `MinuteNumber=0` | `TimeKey` |
| WeatherSource | ba cột provenance cùng tên | `WeatherSourceKey` |
| Existing Fact | `WeatherTimestamp → WeatherTimestamp` | `ExistingFactKey` |

Ba cột provenance là `TemperatureStatus`, `PrecipitationStatus` và
`SourceReference`; phải nối đủ cả ba.

Conditional Split bắt buộc Date, Time, WeatherSource, timestamp, toàn bộ measure thời
tiết và hash; `Existing` dùng `!ISNULL(ExistingFactKey)`; `ValidNew` là default.

Destination map:

```text
DateKey, TimeKey, WeatherSourceKey, WeatherTimestamp,
TemperatureC, DailyMinCActual, DailyMaxCActual, DailyReferenceCActual,
RainMm, HumidityPct, VisibilityKm, WindKmh, IsRainyHour,
LoadFileKey, SourceRowNumber, RecordHashSHA256, LoadedAt
```

## 10. DFT L2 và L3 — Event Facts

### 10.1. Traffic Observation

Source phải lọc cả valid và dedup:

```sql
SELECT
    LoadFileKey, SourceRowNumber,
    EventID, EventTimestamp, EventDate,
    CONVERT(time(0), DATEADD(MINUTE,
        DATEDIFF(MINUTE, 0, EventTimestamp), 0)) AS EventMinuteTime,
    CONVERT(time(0), DATEADD(HOUR,
        DATEDIFF(HOUR, 0, EventTimestamp), 0)) AS HourTimeValue,
    CameraID, SegmentID,
    VehicleCount, MotorbikeCount, CarCount, BusCount, TruckCount,
    AvgSpeedKmh, ParkedVehicleCount, IllegalParkingCount,
    RoadWidthM, ParkingOccupiedWidthM, EffectiveWidthM,
    WidthLossPct, CongestionIndex, RainMm,
    SpeedMissingFlag, VehicleMixValidFlag, ParkingCountValidFlag,
    RecordHashSHA256,
    CONVERT(datetime2(3), SYSDATETIME()) AS LoadedAt
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = ?
  AND IsValid = 1
  AND DuplicateRank = 1;
```

Lookup order và join:

| Thứ tự | Lookup | Join | Output |
|---:|---|---|---|
| 1 | Traffic Date | `EventDate → DateValue` | `DateKey` |
| 2 | Traffic Time | `EventMinuteTime → TimeValue` | `TimeKey` |
| 3 | Traffic Hour Time | `HourTimeValue → TimeValue`, chỉ phút `00` | `HourTimeKey` |
| 4 | RoadSegment Effective | `EventID → EventID` trong reference query SCD2 | `SegmentKey` |
| 5 | Camera Effective | `EventID → EventID` trong reference query SCD2 | `CameraKey` |
| 6 | Existing Traffic | `EventID → EventID` | `ExistingFactKey` |

Hai lookup SCD2 dùng reference query join source Clean với Dimension:

```sql
SELECT DISTINCT T.EventID, S.SegmentKey
FROM DanangSmartParkingSTG.transform.TrafficObservationClean AS T
JOIN dwh.DimRoadSegment AS S
  ON S.SegmentID = T.SegmentID
 AND T.EventTimestamp >= S.ValidFrom
 AND (T.EventTimestamp < S.ValidTo OR S.ValidTo IS NULL)
WHERE T.IsValid = 1 AND T.DuplicateRank = 1;
```

Lookup Camera dùng cùng mẫu với `DimCamera(CameraID, CameraKey)`. Đây là lookup theo
effective event time; không thay bằng `WHERE IsCurrent=1`.

`AvgSpeedKmh` không nằm trong biểu thức `OrphanOrInvalid`, vì null được phép khi
`SpeedMissingFlag=1`. Các khóa bắt buộc, count, width, rate, timestamp và hash phải
khác null.

Destination map toàn bộ cột của `FactTrafficObservation` trừ identity
`TrafficFactKey`.

### 10.2. Parking Event

Source query:

```sql
SELECT
    LoadFileKey, SourceRowNumber, EventID, VehicleID,
    SegmentID, VehicleTypeCode, SideCode, ActiveRestrictionID,
    StartTimestamp, EndTimestamp,
    CONVERT(date, StartTimestamp) AS StartDate,
    CONVERT(time(0), DATEADD(MINUTE,
        DATEDIFF(MINUTE, 0, StartTimestamp), 0)) AS StartMinuteTime,
    CONVERT(date, EndTimestamp) AS EndDate,
    CASE WHEN EndTimestamp IS NULL THEN NULL
         ELSE CONVERT(time(0), DATEADD(MINUTE,
              DATEDIFF(MINUTE, 0, EndTimestamp), 0)) END AS EndMinuteTime,
    ParkingDurationMin, OccupiedWidthM, IsLegalParking,
    IsOpenEvent, IsDurationEstimated, RestrictionLinkMissingFlag,
    RecordHashSHA256,
    CONVERT(datetime2(3), SYSDATETIME()) AS LoadedAt
FROM transform.ParkingEventClean
WHERE LoadBatchKey = ?
  AND IsValid = 1
  AND DuplicateRank = 1;
```

Lookup order:

| Thứ tự | Lookup | Join/output | Bắt buộc |
|---:|---|---|---|
| 1 | Start Date | `StartDate → DateValue`, `StartDateKey` | Có |
| 2 | Start Time | `StartMinuteTime → TimeValue`, `StartTimeKey` | Có |
| 3 | End Date | `EndDate → DateValue`, `EndDateKey` | Không với open event |
| 4 | End Time | `EndMinuteTime → TimeValue`, `EndTimeKey` | Không với open event |
| 5 | Segment Effective | SCD2 theo `EventID/StartTimestamp`, `SegmentKey` | Có |
| 6 | VehicleType | `VehicleTypeCode`, `VehicleTypeKey` | Có |
| 7 | RoadSide | `SideCode`, `RoadSideKey` | Có |
| 8 | Restriction Effective | SCD2 theo `EventID/StartTimestamp`, `RestrictionKey` | Không |
| 9 | Existing Parking | `EventID`, `ExistingFactKey` | Chống trùng |

Các Lookup optional phải chọn cách xử lý no match để dòng tiếp tục với output key
`NULL`. Conditional Split chỉ coi các khóa Start, Segment, VehicleType và RoadSide là
bắt buộc. Với event đóng, postcheck sẽ xác nhận End keys không null; với 64 open event,
End keys phải null.

Destination map toàn bộ cột của `FactParkingEvent` trừ identity
`ParkingEventFactKey`.

## 11. Ghi `OrphanOrInvalid` vào `etl.RejectedRow`

Thực hiện cho từng Conditional Split:

1. Kéo **Derived Column** vào Data Flow, đặt tên ví dụ
   `DRV - Reject TrafficObservation`.
2. Nối output `OrphanOrInvalid` vào Derived Column.
3. Tạo các cột mới:

| Cột | Kiểu SSIS | Giá trị mẫu |
|---|---|---|
| `BusinessKeyText` | `DT_WSTR(200)` | cast từ `EventID`, `ParkingID` hoặc `SegmentID` |
| `RuleCode` | `DT_STR(50), 1252` | `FACT_TRAFFIC_ORPHAN`, tương ứng từng Fact |
| `Severity` | `DT_STR(10), 1252` | `ERROR` |
| `Reason` | `DT_WSTR(1000)` | mô tả thiếu Dimension/field bắt buộc |
| `RawPayload` | `DT_WSTR(4000)` | tùy chọn, ghép các business key nguồn |

4. Kéo **OLE DB Destination**, đặt tên `DST - Reject <FactName>`.
5. Connection: `(project) CM_DanangDW`.
6. Data access mode: `Table or view - fast load`.
7. Table: `[etl].[RejectedRow]`.
8. Map:

```text
LoadFileKey     → LoadFileKey
SourceRowNumber → SourceRowNumber
BusinessKeyText → BusinessKeyText
RuleCode        → RuleCode
Severity        → Severity
Reason          → Reason
RawPayload      → RawPayload
```

Không map `RejectedRowKey`, `RawRecordKey`, `RejectedAt`. `RawRecordKey` được phép
null và `RejectedAt` dùng default của SQL Server.

Rule code khuyến nghị:

| Fact | RuleCode |
|---|---|
| Capacity | `FACT_CAPACITY_ORPHAN` |
| Road Survey | `FACT_SURVEY_ORPHAN` |
| Weather | `FACT_WEATHER_ORPHAN` |
| Traffic | `FACT_TRAFFIC_ORPHAN` |
| Parking | `FACT_PARKING_ORPHAN` |

Không ghi nhánh `Existing` thành ERROR. Có thể nối nó vào **Row Count** để quan sát số
dòng skip khi debug, hoặc để output không nối nhưng phải thêm annotation
`Existing = idempotent skip` trên canvas.

Expected của batch chuẩn là `0` dòng orphan mới. Nếu có orphan, package có thể hoàn
thành Data Flow nhưng acceptance phải fail; sửa Dimension/source rồi chạy lại.

## 12. Task `SQL - Validate Fact Load`

### 12.1. Cấu hình

Kéo **Execute SQL Task** vào Control Flow, đặt tên `SQL - Validate Fact Load`:

| Thuộc tính | Giá trị |
|---|---|
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `None` |
| BypassPrepare | `True` |
| FailPackageOnFailure | `True` |
| FailParentOnFailure | `True` |

### 12.2. SQL và parameter

Dùng SQL ngắn sau trong task; file acceptance đầy đủ vẫn chạy riêng trên SSMS:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

IF NOT EXISTS
(
    SELECT 1
    FROM etl.LoadBatch
    WHERE LoadBatchKey = @LoadBatchKey
      AND LoadStatus = 'SILVER_VALIDATED'
)
    THROW 52800, 'Fact validation failed: batch is not SILVER_VALIDATED.', 1;

IF (SELECT COUNT_BIG(*) FROM dwh.FactParkingCapacitySnapshot) <> 20
    THROW 52801, 'FactParkingCapacitySnapshot count is not 20.', 1;
IF (SELECT COUNT_BIG(*) FROM dwh.FactRoadSurveySnapshot) <> 30
    THROW 52802, 'FactRoadSurveySnapshot count is not 30.', 1;
IF (SELECT COUNT_BIG(*) FROM dwh.FactWeatherHourly) <> 168
    THROW 52803, 'FactWeatherHourly count is not 168.', 1;
IF (SELECT COUNT_BIG(*) FROM dwh.FactTrafficObservation) <> 16800
    THROW 52804, 'FactTrafficObservation count is not 16800.', 1;
IF (SELECT COUNT_BIG(*) FROM dwh.FactParkingEvent) <> 4283
    THROW 52805, 'FactParkingEvent count is not 4283.', 1;
```

Trong **Parameter Mapping → Add**:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `User::LoadBatchKey` | Input | `LONG` | `0` | `-1` |

OLE DB hiện tại hiển thị `LONG`; câu SQL chuyển rõ sang `bigint`. Nếu giữ nguyên SQL
nhúng của package tham chiếu không có `?`, phải xóa hoàn toàn Parameter Mapping.

Các số expected ở task này là baseline của dataset đầu. File acceptance ở mục 14 kiểm
tra thêm grain, orphan và KPI.

## 13. Debug package độc lập

1. Trên SSMS, lấy `LoadBatchKey` thật theo mục 5.1.
2. Trong Visual Studio, nhấp phải `40_Load_Facts.dtsx` → **Set as Startup Object**.
3. Mở package → tab **Parameters**.
4. Khi chạy/debug, gán `pLoadBatchKey` bằng số, ví dụ `18`; không nhập chữ
   `LoadBatchKey` và không để `0`.
5. Nhấn **Start** hoặc `F5`.
6. Bốn DFT và task validation phải chuyển màu xanh.
7. Nhấn `Shift+F5` nếu cần dừng debugger sau khi hoàn tất.

Chạy lại package với cùng batch để kiểm tra retry:

- source vẫn đọc đủ 21.301 dòng;
- lookup Existing nhận toàn bộ business key đã nạp;
- destination không tạo thêm dòng;
- tổng Fact vẫn là 21.301;
- unique grain vẫn không trùng.

Lỗi thường gặp:

| Triệu chứng | Nguyên nhân/khắc phục |
|---|---|
| Source trả 0 dòng | `pLoadBatchKey=0`, sai batch hoặc dùng sai STG connection |
| Lookup Date/Time no match | package 30 chưa nạp đủ `DimDate`/`DimTime` |
| Segment/Camera no match | lookup SCD2 chỉ lấy current thay vì effective event time |
| Hash destination lỗi length | thêm Data Conversion `DT_BYTES(32)` |
| Validation báo parameter | SQL không có `?` nhưng vẫn còn Parameter Mapping |
| Unique constraint fail khi retry | thiếu hoặc nối sai Lookup Existing |
| Package xanh nhưng thiếu Fact | output orphan đang bị bỏ không nối; bổ sung mục 11 |

## 14. Nghiệm thu trên SSMS

1. Mở [`27_validate_fact_load.sql`](../../sql/27_validate_fact_load.sql).
2. Giữ `@RequestedLoadBatchKey = NULL` hoặc nhập đúng số batch.
3. Chạy toàn bộ file bằng `F5`.
4. Result set cuối phải có `AcceptanceStatus = PASS`.

Các baseline bắt buộc:

| Chỉ số | Expected |
|---|---:|
| Total Fact rows | 21.301 |
| Traffic vehicle volume | 6.596.879 |
| Traffic missing speed rows | 161 |
| Traffic invalid vehicle mix rows | 3.838 |
| Traffic invalid parking count rows | 781 |
| Parking illegal events | 1.571 |
| Parking open events | 64 |
| Parking illegal without restriction link | 607 |
| Capacity total | 2.267 |
| Reference capacity | 397 |
| Weather rain total | 47,5 mm |
| Rainy hours | 11 |
| Road width imputed rows | 3 |
| Mandatory orphan | 0 |
| Fact-load ERROR reject của batch | 0 |

Average speed khoảng `40,886`, congestion khoảng `0,252761`, parking illegal rate
khoảng `36,6799%` và average duration khoảng `45,81345` được in ra để đối chiếu; file
validation dùng tolerance cho số thập phân.

## 15. Gắn vào `00_Master.dtsx`

1. Mở `00_Master.dtsx` ở **Control Flow**.
2. Copy một Execute Package Task gần nhất hoặc kéo task mới từ SSIS Toolbox.
3. Đổi tên `EPT - 40 Load Facts`.
4. Mở task → **Package**:
   - ReferenceType: `Project Reference`;
   - PackageNameFromProjectReference: `40_Load_Facts.dtsx`.
5. Mở **Parameter Bindings** và bind:

```text
Child parameter: pLoadBatchKey
Parent variable: User::LoadBatchKey
```

6. Nối mũi tên xanh:

```text
EPT - 30 Load Dimensions
    → EPT - 40 Load Facts
    → EPT - 50 Final DWH Validation
    → EPT - 80 Reconciliation
```

7. `90_Cleanup` và `Complete Batch` vẫn để disabled cho đến khi package 80 PASS.
8. Nhấn **Save All**.
9. Nhấp phải `00_Master.dtsx` → **Set as Startup Object**.
10. Mở master và nhấn `Start/F5`.

Sau full run, các task từ Extract đến package 40 phải xanh. Batch vẫn giữ trạng thái
`SILVER_VALIDATED` ở checkpoint này; chỉ package 90/Complete Batch mới chuyển nó sang
`COMPLETED`.

## 16. Checklist và checkpoint bàn giao

- [ ] Package 23 PASS và batch là `SILVER_VALIDATED`.
- [ ] Package 30 PASS trên cùng batch.
- [ ] Precheck Fact trả `PASS`.
- [ ] `pLoadBatchKey` và `User::LoadBatchKey` đều là `Int64`.
- [ ] Bốn DFT nối tuần tự đúng thứ tự.
- [ ] Tất cả source lọc `LoadBatchKey=? AND IsValid=1`.
- [ ] Hai Event Fact lọc thêm `DuplicateRank=1`.
- [ ] Lookup SCD2 dùng effective event/snapshot time.
- [ ] Năm nhánh `OrphanOrInvalid` ghi vào `etl.RejectedRow`.
- [ ] Nhánh `Existing` không insert lại và không bị ghi ERROR.
- [ ] Destination dùng `CM_DanangDW`, fast load và không map identity.
- [ ] Task validation không có parameter mapping thừa.
- [ ] Package chạy lần đầu đủ `20/30/168/16800/4283`.
- [ ] Chạy retry không tăng row count.
- [ ] `27_validate_fact_load.sql` trả `AcceptanceStatus = PASS`.
- [ ] Package 40 đã được bind parameter và nối vào `00_Master.dtsx`.

Checkpoint sau bước 40: đã có đủ 21.301 Fact rows, không duplicate grain, không orphan
bắt buộc và KPI khớp baseline. Chưa cleanup staging và chưa chuyển batch sang
`COMPLETED`. Bước kế tiếp là package 50 Final DWH Validation; chỉ chuyển sang package
80 sau khi structural gate này PASS.
