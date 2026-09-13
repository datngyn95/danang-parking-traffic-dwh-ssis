# 21 — Transform Events bằng một Execute SQL Task

## 1. Mục tiêu và output

Package `21_Transform_Events.dtsx` chỉ có **một Execute SQL Task**. Task gọi một stored procedure set-based để chuyển ba nguồn event từ Extract Staging sang Transform Staging:

| Nguồn RAW | RAW rows | Bảng đích Clean | Clean rows sau dedup |
|---|---:|---|---:|
| `extract.TrafficEventRaw` | 16.884 | `transform.TrafficObservationClean` | 16.800 |
| `extract.ParkingEventRaw` | 4.300 | `transform.ParkingEventClean` | 4.283 |
| `extract.WeatherEventRaw` | 168 | `transform.WeatherHourlyClean` | 168 |

```text
3 bảng extract.*Raw (21.352 physical rows)
                 ↓
SQL - Transform Events
                 ↓
3 bảng transform.*Clean (21.251 typed, valid, deduplicated rows)
```

Không tạo ba Data Flow Task và không tạo ba Execute SQL Task riêng. Procedure xử lý cả Traffic, Parking và Weather trong một transaction, chỉ tác động tới `LoadBatchKey` hiện tại.

Package 21 không tạo aggregate và không load DW:

- Package 22 mới tạo `TrafficHourlySummary` và `ParkingDailySummary`.
- Package 23 mới đổi batch sang `SILVER_VALIDATED`.
- Load Dimension/Fact ở package 30/40 vẫn dùng **Data Flow Task** đúng quy trình đã thống nhất.

## 2. Những góp ý từ package 20 đã áp dụng

Hướng dẫn này đã đưa trực tiếp các điểm vừa chốt khi làm package 20:

1. Package chỉ có một Execute SQL Task để giảm thao tác kéo thả.
2. Parameter Mapping của OLE DB dùng `LONG`, vì giao diện hiện tại không có `I8`, `Int64` hoặc `bigint`.
3. SQL trong task nhận dấu `?`, sau đó `CONVERT(bigint, ?)` trước khi gọi procedure.
4. Khi debug độc lập, ô parameter chỉ nhập **giá trị số** của batch, không nhập chữ `LoadBatchKey`.
5. Có một script nghiệm thu read-only riêng, tự trả `PASS/FAIL`.
6. Unicode không chỉ được kiểm tra ngầm; script xuất trực tiếp dòng `Trần Phú / Hải Châu core` để nhìn thấy trên SSMS.

## 3. Điều kiện trước khi thực hiện

Package 20 phải hoàn thành và nghiệm thu `PASS` trên cùng batch.

### 3.1. Lấy batch key đang làm

1. Mở SSMS.
2. Bấm **New Query**.
3. Chọn database `DanangSmartParkingDW`.
4. Chạy:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Kết quả bắt buộc:

- `LoadStatus = BRONZE_LOADED`.
- `RowsRead = 21500`.
- `RowsAccepted = 21500`.
- `RowsRejected = 0`.
- `ErrorMessage = NULL`.

Ghi lại giá trị số ở cột `LoadBatchKey`.

### 3.2. Xác nhận output package 20 cùng batch

Thay số `11` bên dưới bằng batch key vừa lấy, rồi chạy:

```sql
DECLARE @LoadBatchKey bigint = 11;

SELECT 'RoadClean' AS ObjectName, COUNT_BIG(*) AS ValidRows, 30 AS ExpectedRows
FROM DanangSmartParkingSTG.transform.RoadClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
UNION ALL
SELECT 'RoadSurveyClean', COUNT_BIG(*), 30
FROM DanangSmartParkingSTG.transform.RoadSurveyClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1
UNION ALL
SELECT 'ParkingRestrictionClean', COUNT_BIG(*), 18
FROM DanangSmartParkingSTG.transform.ParkingRestrictionClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1;
```

Expected: `30/30/18` đều bằng ExpectedRows.

Nếu package 20 chưa đạt, quay lại [`20_TRANSFORM_MASTER_DATA.md`](20_TRANSFORM_MASTER_DATA.md). Không chạy package 21 trên batch `FAILED`.

## 4. Procedure thực hiện những gì

Procedure `DanangSmartParkingSTG.dbo.usp_TransformEvents` thực hiện tuần tự:

1. Chỉ nhận batch có status `BRONZE_LOADED`.
2. Kiểm tra RAW đủ `16.884/4.300/168` dòng.
3. Kiểm tra output package 20 đủ Road, Segment và Restriction hợp lệ.
4. Xóa kết quả package 21 cũ của đúng batch để hỗ trợ chạy lại idempotent.
5. Chuyển Weather trước để Traffic có thể đối chiếu `RainMm` theo ngày/giờ.
6. Trim chuỗi, chuẩn hóa code, dùng `TRY_CONVERT` cho timestamp, ngày, giờ, số và boolean.
7. Kiểm tra timestamp/date/hour và liên kết Road/Segment/Restriction/Weather.
8. Dedup Traffic và Parking theo `EventID`; Weather theo timestamp.
9. Chỉ giữ `DuplicateRank = 1` trong Clean; dòng duplicate vật lý vẫn còn nguyên trong RAW.
10. Ghi duplicate bị loại vào `etl.RejectedRow` với `Severity = WARNING`.
11. Ghi lỗi conversion/business rule vào `etl.RejectedRow` với `Severity = ERROR`.
12. Đối soát KPI và các cờ DQ trước khi trả thành công.

### 4.1. Quy tắc dedup

Traffic/Parking dùng:

```sql
ROW_NUMBER() OVER
(
    PARTITION BY EventID
    ORDER BY SourceRowNumber, StageRowKey
) AS DuplicateRank
```

- Traffic: giữ 16.800 dòng, audit 84 duplicate.
- Parking: giữ 4.283 dòng, audit 17 duplicate.
- Weather: không có duplicate.
- Mọi dòng Clean được giữ có `DuplicateRank = 1`.

Lưu ý sửa so với mô tả cũ: duplicate **không lưu thêm trong Clean**, vì bảng Clean và Fact cần đúng grain duy nhất. Bằng chứng duplicate được giữ ở `extract.*Raw` và `etl.RejectedRow`.

### 4.2. Traffic — giữ dữ liệu bất thường bằng cờ DQ

Ba bất thường đã biết không bị sửa và không bị loại:

| Cờ | Điều kiện | Expected |
|---|---|---:|
| `SpeedMissingFlag` | `AvgSpeedKmh IS NULL` | 161 |
| `VehicleMixValidFlag = 0` | total khác tổng motorbike/car/bus/truck | 3.838 |
| `ParkingCountValidFlag = 0` | illegal count lớn hơn parked count | 781 |

KPI đối soát sau dedup:

- Vehicle volume: `6.596.879`.
- Parked observations: `30.480`.
- Illegal-parking observations: `9.100`.
- Average speed: khoảng `40,885997` km/h.
- Average congestion: khoảng `0,252761`.

Không điền tốc độ thiếu bằng `0`; không tự sửa total vehicle; không ép illegal count về parked count.

### 4.3. Parking — open event và restriction link

- `IsOpenEvent = 1` khi `EndTimestamp IS NULL`: expected 64.
- `IsDurationEstimated = 1` cho đúng 64 open event.
- Duration của open event là planned/last-known; không coi là thời lượng hoàn tất.
- `RestrictionLinkMissingFlag = 1` khi event illegal nhưng không resolve được restriction: expected 607.
- Có 964 event mang restriction ID; toàn bộ ID có giá trị phải resolve được master.

KPI sau dedup:

- 4.283 event.
- 1.571 illegal event.
- Illegal rate `0,366799`.
- Average duration khoảng `45,813449` phút.

### 4.4. Weather

- Đúng 168 giờ.
- Tổng mưa `47,50 mm`.
- Có 11 giờ mưa (`IsRainyHour = 1`).
- Rain của Traffic phải khớp Weather theo `EventDate + HourNumber`.

## 5. SSMS — tạo procedure cho package 21

SQL đã được chuẩn bị tại:

[`../../sql/23_transform_events.sql`](../../sql/23_transform_events.sql)

Thao tác:

1. Mở file `sql/23_transform_events.sql` trong VS Code.
2. Nhấn `Ctrl+A`, rồi `Ctrl+C`.
3. Mở SSMS.
4. Bấm **New Query**.
5. Dán toàn bộ script.
6. Bấm **Execute** hoặc nhấn `F5`.
7. Mở tab **Messages**.

Expected:

```text
Commands completed successfully.
```

Script này chỉ tạo/cập nhật procedure; chưa Transform dữ liệu.

### 5.1. Kiểm tra procedure tồn tại

Chạy:

```sql
USE DanangSmartParkingSTG;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName,
    create_date,
    modify_date
FROM sys.procedures
WHERE name = N'usp_TransformEvents';
```

Expected đúng một dòng:

```text
dbo | usp_TransformEvents
```

Không bấm **Execute Procedure** trong Object Explorer. SSIS sẽ gọi procedure.

## 6. SSIS — tạo package `21_Transform_Events.dtsx`

### 6.1. Tạo package

1. Mở solution `DanangSmartParkingETL` trong Visual Studio/SSDT.
2. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Chọn package mới, nhấn `F2`.
5. Đổi tên:

```text
21_Transform_Events.dtsx
```

6. Nhấp đúp package vừa tạo.
7. Chọn tab **Control Flow**.
8. Bấm vùng trống trên canvas, nhấn `F4`.
9. Trong **Properties**, đổi `Name` thành:

```text
P21_Transform_Events
```

### 6.2. Tạo package parameter

1. Chọn tab **Parameters** phía trên canvas.
2. Bấm **Add Parameter**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Chỉ nhập `pLoadBatchKey` ở cột Name; không nhập `$Package::pLoadBatchKey`.

### 6.3. Kiểm tra Connection Manager

1. Quay lại **Control Flow**.
2. Ở khung **Connection Managers** phía dưới phải thấy:

```text
(project) CM_DanangSTG
```

3. Connection phải trỏ tới `DanangSmartParkingSTG`.

Nếu không thấy, kiểm tra project node **Connection Managers** có `CM_DanangSTG.conmgr`, sau đó đóng/mở lại package.

## 7. SSIS — tạo Execute SQL Task duy nhất

### 7.1. Thả task

1. Trong **SSIS Toolbox**, tìm `Execute SQL Task`.
2. Kéo task vào canvas **Control Flow**.
3. Nhấp phải task → **Rename**.
4. Đặt tên:

```text
SQL - Transform Events
```

### 7.2. Cấu hình General

1. Nhấp đúp task.
2. Chọn **General** bên trái.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Transform Events` |
| ResultSet | `None` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangSTG` |
| SQLSourceType | `Direct input` |
| BypassPrepare | `True` |

4. Ở `SQLStatement`, bấm nút `...`.
5. Dán đúng đoạn sau:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC dbo.usp_TransformEvents
    @LoadBatchKey = @LoadBatchKey;
```

6. Bấm **OK**.

Dấu `?` là positional parameter của OLE DB. Không thay bằng `$Package::pLoadBatchKey` trong câu SQL.

### 7.3. Cấu hình Parameter Mapping

1. Trong **Execute SQL Task Editor**, chọn **Parameter Mapping**.
2. Bấm **Add** đúng một lần.
3. Cấu hình:

| Cột | Giá trị |
|---|---|
| Variable Name | `$Package::pLoadBatchKey` |
| Direction | `Input` |
| Data Type | `LONG` |
| Parameter Name | `0` |
| Parameter Size | `-1` |

Giao diện OLE DB của project không có `I8`, `Int64` hoặc `bigint`, nên chọn `LONG`. Package parameter vẫn là `Int64`; SQL đã chuyển `?` sang `bigint` trước khi gọi procedure.

4. Không thêm mapping thứ hai.
5. Bấm **OK**.
6. Nhấn `Ctrl+S`.

Control Flow cuối cùng chỉ có:

```text
[SQL - Transform Events]
```

Package 21 không cần Data Flow Task.

## 8. Debug package 21 độc lập

### 8.1. Lấy batch key thật trên SSMS

Chạy:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'BRONZE_LOADED'
ORDER BY LoadBatchKey DESC;
```

Ví dụ kết quả:

```text
LoadBatchKey | LoadStatus
11           | BRONZE_LOADED
```

Giá trị cần nhập là số `11`.

### 8.2. Gán parameter trong Visual Studio

1. Mở `21_Transform_Events.dtsx`.
2. Chọn tab **Parameters**.
3. Tại `pLoadBatchKey`, bấm ô **Value** đang là `0`.
4. Nhập đúng số lấy từ SSMS, ví dụ `11`.
5. Nhấn `Enter`, rồi `Ctrl+S`.

Không nhập:

```text
LoadBatchKey
@LoadBatchKey
LoadBatchKey = 11
'11'
```

Parameter `Int64` chỉ nhận số. Nếu SSMS không trả dòng `BRONZE_LOADED`, không chạy package 21.

### 8.3. Execute package

1. Trong **Solution Explorer**, nhấp phải `21_Transform_Events.dtsx`.
2. Chọn **Execute Package**.
3. Chờ package kết thúc.

Expected:

- `SQL - Transform Events` có tick xanh.
- `Package execution completed successfully`.
- Không có dấu X đỏ.

Nếu task lỗi, mở tab **Progress/Execution Results**, kéo xuống dòng lỗi đỏ đầu tiên. Procedure sẽ đổi batch thành `FAILED` và giữ Clean/reject để debug; không tự sửa status bằng tay.

## 9. SSMS — xem chi tiết output package 21

Sau khi package xanh, chạy toàn bộ block:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

-- Status vẫn BRONZE_LOADED; package 23 mới đổi SILVER_VALIDATED.
SELECT LoadBatchKey, LoadStatus, ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- Procedure chạy lại idempotent và xuất các bảng đối soát chi tiết.
EXEC DanangSmartParkingSTG.dbo.usp_TransformEvents
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;
```

Lệnh `EXEC` chạy lại procedure một lần. Việc này an toàn vì procedure xóa/tạo lại đúng output package 21 của batch hiện tại.

### 9.1. Expected result sets

Result count:

| ObjectName | ActualRows | ValidRows | InvalidRows | ExpectedRows | IsMatched |
|---|---:|---:|---:|---:|---:|
| `transform.TrafficObservationClean` | 16.800 | 16.800 | 0 | 16.800 | 1 |
| `transform.ParkingEventClean` | 4.283 | 4.283 | 0 | 4.283 | 1 |
| `transform.WeatherHourlyClean` | 168 | 168 | 0 | 168 | 1 |

Traffic result:

```text
TrafficRows=16800; VehicleVolume=6596879;
AvgSpeedKmh≈40.885997; AvgCongestion≈0.252761;
MissingSpeedRows=161; InvalidMixRows=3838; InvalidParkingCountRows=781
```

Parking result:

```text
ParkingRows=4283; IllegalEvents=1571; IllegalRate=0.366799;
AvgDurationMin≈45.813449; OpenEvents=64;
EstimatedDurationEvents=64; IllegalWithoutRestrictionLink=607
```

Weather result:

```text
WeatherRows=168; TotalRainMm=47.50; RainyHours=11
```

Duplicate audit phải có:

```text
TRN_TRAFFIC_DUPLICATE | 84
TRN_PARKING_DUPLICATE | 17
```

Không có `TRN_*_INVALID`. Weather duplicate bằng 0 nên có thể không xuất thành một dòng.

Result Unicode cuối phải nhìn thấy:

```text
RoadID | RoadName | AnalysisZone  | UnicodeMatched | ExpectedUnicodeValue
RD001  | Trần Phú  | Hải Châu core | 1              | Trần Phú / Hải Châu core
```

## 10. Gắn package 21 vào `00_Master.dtsx`

Chỉ làm sau khi package 21 chạy độc lập thành công.

> Sau khi gắn, phải chọn `PackageNameFromProjectReference` trực tiếp từ dropdown
> là `21_Transform_Events.dtsx`. Đổi mỗi tên hiển thị của Execute Package Task
> không làm thay đổi package con mà task tham chiếu. Nếu copy task package 20 mà
> bỏ qua trường này, Master sẽ báo `Failed to locate the specified package in the
> project` hoặc tiếp tục gọi nhầm package 20.

1. Mở `00_Master.dtsx` → **Control Flow**.
2. Copy task `PKG - Transform Master Data` rồi paste để tái sử dụng cấu hình.
3. Đổi tên bản sao:

```text
PKG - Transform Events
```

4. Nhấp đúp task.
5. Chọn:
   - `ReferenceType`: `Project Reference`.
   - `PackageNameFromProjectReference`: `21_Transform_Events.dtsx`.
6. Mở **Parameter Bindings**.
7. Xác nhận:

| Child package parameter | Parent package variable |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

8. Bấm **OK**.
9. Xóa connector cũ của bản sao nếu nó nối sai.
10. Nối mũi tên xanh:

```text
PKG - Transform Master Data
  → PKG - Transform Events
```

11. Không nối vào `SQL - Complete Batch`.

Sơ đồ Master tại checkpoint này:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
  → PKG - Validate Extract
  → PKG - Transform Master Data
  → PKG - Transform Events

SQL - Complete Batch [Disabled]
```

## 11. Nghiệm thu tự động package 21

Script read-only đã được chuẩn bị tại:

[`../../sql/23_validate_transform_events.sql`](../../sql/23_validate_transform_events.sql)

### 11.1. Chạy trên SSMS

1. Mở `sql/23_validate_transform_events.sql` trong VS Code.
2. Nhấn `Ctrl+A`, rồi `Ctrl+C`.
3. Mở SSMS → **New Query**.
4. Dán toàn bộ script.
5. Nhấn `F5`.
6. Xem result Unicode và result cuối.

Khi mọi kiểm tra đạt, result cuối là:

```text
AcceptanceStatus | LoadBatchKey | Message
PASS             | <batch key> | PACKAGE 21 ACCEPTED - ready for package 22
```

Script tự động kiểm tra:

- Batch vẫn `BRONZE_LOADED`, error null và Extract reject bằng 0.
- Ba bảng Clean đúng `16.800/4.283/168`, toàn bộ valid.
- Tổng Clean `21.251` dòng.
- Clean row trace được về đúng RAW row.
- Không thiếu event hash, không còn duplicate business key và mọi DuplicateRank bằng 1.
- RAW duplicate `84/17/0` khớp WARNING audit `84/17/0`.
- Không có ERROR audit từ Transform Events.
- Toàn bộ KPI và cờ Traffic/Parking/Weather khớp baseline.
- Road/Segment/Restriction/Weather lookup không có mismatch.
- Unicode `Trần Phú / Hải Châu core` hiển thị và `UnicodeMatched = 1`.

`etl.RejectedRow` có 101 WARNING duplicate là đúng. `LoadBatch.RowsRejected` vẫn bằng 0 vì cột này là reject ở bước Extract, không cộng các duplicate đã xử lý ở Silver.

Nếu có lỗi, script xuất `CheckName / ActualValue / ExpectedValue`, sau đó báo:

```text
PACKAGE 21 ACCEPTANCE FAILED. Review the Failures result set.
```

Không chuyển package 22 khi còn lỗi.

### 11.2. Kiểm tra trực quan SSIS

SQL không đọc file `.dtsx` trên máy Windows, nên kiểm tra thêm:

- Package 21 chỉ có một Execute SQL Task.
- Task dùng `(project) CM_DanangSTG`.
- Parameter mapping dùng `LONG`, ordinal `0`.
- SQL task có `CONVERT(bigint, ?)`.
- Package debug xanh.

## 12. Bước tiếp theo

Sau khi script trả `PASS`, chuyển sang:

[`22_TRANSFORM_AGGREGATES.md`](22_TRANSFORM_AGGREGATES.md)

Package 22 sẽ tạo hai bảng QA summary từ ba bảng Clean; package 23 mới đóng cổng Silver.
