# 12 — Extract JSONL bằng Execute SQL Task

## 1. Mục tiêu và phương án nhanh

Không dùng `Script Component`, không tạo ba Data Flow cho JSONL.

Package `12_Extract_JSONL.dtsx` chỉ có **một Execute SQL Task**. Task gọi một stored procedure để SQL Server:

1. Đọc ba file JSONL trực tiếp bằng `OPENROWSET(BULK...)`.
2. Giải mã file UTF-8 thành Unicode đúng tiếng Việt.
3. Chuyển mỗi dòng vật lý thành một JSON object theo đúng thứ tự.
4. Dùng `OPENJSON` lấy thuộc tính và nạp vào database Staging.
5. Ghi audit `etl.LoadFile` và kiểm tra đúng số dòng.

```text
06_traffic_events.jsonl ─┐
07_parking_events.jsonl ─┼─ SQL - Extract JSONL to STG
08_weather_events.jsonl ─┘
```

Đầu ra:

| SourceID | File | Bảng RAW | Expected |
|---|---|---|---:|
| `06` | `06_traffic_events.jsonl` | `DanangSmartParkingSTG.extract.TrafficEventRaw` | 16.884 |
| `07` | `07_parking_events.jsonl` | `DanangSmartParkingSTG.extract.ParkingEventRaw` | 4.300 |
| `08` | `08_weather_events.jsonl` | `DanangSmartParkingSTG.extract.WeatherEventRaw` | 168 |

Tổng cộng phải nạp **21.352 dòng RAW**.

Đây vẫn là Extract RAW:

- Không làm sạch và không deduplicate.
- `SourceRowNumber` bắt đầu từ `1`, đúng số dòng vật lý trong file.
- Thuộc tính số, ngày giờ và boolean vẫn được lưu vào cột `*Raw` dạng chuỗi.
- Mỗi JSON object gốc được giữ trong cột `RawJson`.
- Chuyển kiểu dữ liệu, kiểm tra nghiệp vụ và deduplicate để phase Transform xử lý.

## 2. Điều kiện trước khi làm

Package 10 và 11 đã hoàn thành. Trong `00_Master.dtsx` hiện có:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
```

`SQL - Complete Batch` vẫn phải **Disabled** vì toàn bộ ETL chưa hoàn thành.

Project đã có:

| Đối tượng | Giá trị cần dùng |
|---|---|
| Project parameter | `$Project::pRawRoot` |
| Raw root | `C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d` |
| DW connection | `(project) CM_DanangDW` |
| STG connection | `(project) CM_DanangSTG` |

Do package 11 đã đọc được GeoJSON bằng `OPENROWSET`, tài khoản dịch vụ SQL Server đã có quyền đọc thư mục RAW. Không cần cấp lại quyền cho ba file JSONL nếu chúng nằm cùng thư mục.

## 3. SSMS — kiểm tra nhanh file JSONL và Unicode

### 3.1. Mở cửa sổ query

1. Mở SSMS.
2. Bấm **New Query**.
3. Chọn database `DanangSmartParkingDW` trên combobox database.
4. Dán và chạy toàn bộ truy vấn dưới đây.

```sql
DECLARE @JsonLines nvarchar(max);
DECLARE @FirstLine nvarchar(max);

SELECT @JsonLines = CONVERT
(
    nvarchar(max),
    COALESCE
    (
        BulkColumn,
        '' COLLATE Latin1_General_100_CI_AS_SC_UTF8
    )
)
FROM OPENROWSET
(
    BULK 'C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\06_traffic_events.jsonl',
    SINGLE_BLOB
) AS SourceFile;

SET @JsonLines = REPLACE(@JsonLines, NCHAR(13) + NCHAR(10), NCHAR(10));
SET @JsonLines = REPLACE(@JsonLines, NCHAR(13), NCHAR(10));

SET @FirstLine = LEFT
(
    @JsonLines,
    CHARINDEX(NCHAR(10), @JsonLines + NCHAR(10)) - 1
);

SELECT
    DATALENGTH(@JsonLines) AS JsonlBytes,
    ISJSON(@FirstLine) AS FirstLineIsJson,
    JSON_VALUE(@FirstLine, '$.road_name') AS FirstRoadName,
    JSON_VALUE(@FirstLine, '$.analysis_zone') AS FirstAnalysisZone;
```

Kết quả đúng:

| Cột | Expected |
|---|---|
| `JsonlBytes` | lớn hơn `0` |
| `FirstLineIsJson` | `1` |
| `FirstRoadName` | `Lê Duẩn` |
| `FirstAnalysisZone` | `Hải Châu core` |

Không tiếp tục nếu tên hiển thị thành `LÃª`, `Háº£i` hoặc dạng lỗi font tương tự. Cách đọc UTF-8 ở đây giống package 11 đã kiểm chứng.

### 3.2. Nếu báo không tìm thấy file hoặc Access denied

Kiểm tra ba file tồn tại đúng đường dẫn:

```text
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\06_traffic_events.jsonl
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\07_parking_events.jsonl
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\08_weather_events.jsonl
```

Nếu `Operating system error code 5`, thực hiện lại phần cấp quyền thư mục tại mục 4.1 của [`11_EXTRACT_GEOJSON.md`](11_EXTRACT_GEOJSON.md).

## 4. SSMS — tạo stored procedure Extract JSONL

Script đã được chuẩn bị tại:

[`../../sql/20_extract_jsonl_execute_sql.sql`](../../sql/20_extract_jsonl_execute_sql.sql)

Thao tác:

1. Mở file `sql/20_extract_jsonl_execute_sql.sql` trong VS Code.
2. Nhấn `Ctrl+A`, sau đó `Ctrl+C`.
3. Trong SSMS bấm **New Query**.
4. Dán toàn bộ script bằng `Ctrl+V`.
5. Bấm **Execute** hoặc nhấn `F5`.
6. Tab **Messages** phải hiển thị `Commands completed successfully`.

Script tạo procedure:

```text
DanangSmartParkingDW.etl.usp_ExtractJSONLToStaging
```

### 4.1. Kiểm tra procedure đã tồn tại

Chạy:

```sql
USE DanangSmartParkingDW;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName,
    create_date,
    modify_date
FROM sys.procedures
WHERE name = N'usp_ExtractJSONLToStaging';
```

Expected: đúng một dòng, `SchemaName = etl`.

Trong Object Explorer có thể kiểm tra tại:

```text
Databases
  → DanangSmartParkingDW
    → Programmability
      → Stored Procedures
        → etl.usp_ExtractJSONLToStaging
```

Nếu chưa thấy, nhấp phải **Stored Procedures** → **Refresh**.

## 5. Stored procedure sẽ làm gì

Procedure nhận:

```text
@LoadBatchKey
@RawRoot
```

Luồng thực thi:

```text
Đăng ký LoadFile 06
  → đọc UTF-8 file traffic
  → xác thực 16.884 JSON object
  → INSERT extract.TrafficEventRaw
  → LoadFile 06 = COMPLETED

Đăng ký LoadFile 07
  → đọc UTF-8 file parking
  → xác thực 4.300 JSON object
  → INSERT extract.ParkingEventRaw
  → LoadFile 07 = COMPLETED

Đăng ký LoadFile 08
  → đọc UTF-8 file weather
  → xác thực 168 JSON object
  → INSERT extract.WeatherEventRaw
  → LoadFile 08 = COMPLETED
```

Nếu có lỗi:

- File đang xử lý được đánh dấu `FAILED`.
- Batch được đánh dấu `FAILED`.
- Lỗi được trả về SSIS và task chuyển màu đỏ.
- Sau khi sửa nguyên nhân, chạy lại `00_Master.dtsx` để tạo batch mới; không chạy lại trên batch `FAILED`.

## 6. SSIS — tạo package `12_Extract_JSONL.dtsx`

### 6.1. Tạo package

1. Mở solution `DanangSmartParkingETL` trong Visual Studio/SSDT.
2. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Package mới thường có tên `Package1.dtsx`.
5. Chọn package đó, nhấn `F2`.
6. Đổi tên thành:

```text
12_Extract_JSONL.dtsx
```

7. Nhấp đúp package vừa tạo.
8. Chọn tab **Control Flow**.
9. Bấm vào vùng trống trên canvas, nhấn `F4` để mở **Properties**.
10. Đổi thuộc tính `Name` thành:

```text
P12_Extract_JSONL
```

### 6.2. Tạo package parameter

1. Trong package `12_Extract_JSONL.dtsx`, chọn tab **Parameters**.
2. Bấm nút **Add Parameter**.
3. Nhập đúng:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Chỉ nhập tên là `pLoadBatchKey`. Không nhập `$Package::pLoadBatchKey` vào cột Name; `$Package::...` là cú pháp tham chiếu do SSIS tự hiển thị ở nơi mapping.

## 7. SSIS — tạo một Execute SQL Task duy nhất

### 7.1. Thả task lên Control Flow

1. Quay lại tab **Control Flow**.
2. Trong **SSIS Toolbox**, tìm `Execute SQL Task`.
3. Kéo thả task vào canvas.
4. Nhấp phải task → **Rename**.
5. Đổi tên thành:

```text
SQL - Extract JSONL to STG
```

### 7.2. Cấu hình General

1. Nhấp đúp task `SQL - Extract JSONL to STG`.
2. Chọn trang **General**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Extract JSONL to STG` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `None` |
| BypassPrepare | `True` |

4. Ở ô **SQLStatement**, bấm nút `...`.
5. Dán đúng đoạn sau:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);
DECLARE @RawRoot nvarchar(4000) = CONVERT(nvarchar(4000), ?);

EXEC etl.usp_ExtractJSONLToStaging
    @LoadBatchKey = @LoadBatchKey,
    @RawRoot = @RawRoot;
```

6. Bấm **OK** để lưu SQL.

Lưu ý: task phải dùng `CM_DanangDW`, vì procedure nằm trong `DanangSmartParkingDW`. Procedure tự ghi sang các bảng ba phần tên `DanangSmartParkingSTG.extract.*Raw`.

### 7.3. Cấu hình Parameter Mapping

1. Trong cửa sổ **Execute SQL Task Editor**, chọn **Parameter Mapping** bên trái.
2. Bấm **Add** hai lần.
3. Cấu hình đúng thứ tự dấu `?`:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `$Package::pLoadBatchKey` | `Input` | `LONG` | `0` | `-1` |
| `$Project::pRawRoot` | `Input` | `NVARCHAR` | `1` | `4000` |

Giải thích:

- `Parameter Name = 0` ứng với dấu `?` thứ nhất là `LoadBatchKey`.
- `Parameter Name = 1` ứng với dấu `?` thứ hai là `RawRoot`.
- Với OLE DB, SSIS gọi kiểu `BIGINT` là `LONG`.
- Chọn `$Project::pRawRoot` từ dropdown; không tạo lại nó trong package 12.

4. Bấm **OK** đóng editor.
5. Nhấn `Ctrl+S` lưu package.

Control Flow đúng chỉ có:

```text
[SQL - Extract JSONL to STG]
```

Không cần Flat File Connection Manager, Data Flow Task, Script Component, Derived Column hoặc OLE DB Destination trong package 12.

## 8. SSIS — gắn package 12 vào `00_Master.dtsx`

### 8.1. Tạo Execute Package Task bằng cách copy nhanh

1. Mở `00_Master.dtsx`.
2. Chọn tab **Control Flow**.
3. Chọn task `PKG - Extract GeoJSON`.
4. Nhấn `Ctrl+C`, rồi `Ctrl+V`.
5. Kéo bản sao xuống phía dưới `PKG - Extract GeoJSON`.
6. Nhấp phải bản sao → **Rename**.
7. Đổi tên thành:

```text
PKG - Extract JSONL
```

### 8.2. Chọn package 12

1. Nhấp đúp `PKG - Extract JSONL`.
2. Ở trang **Package**, giữ:

```text
ReferenceType = Project Reference
```

3. Tại ô package, chọn:

```text
12_Extract_JSONL.dtsx
```

4. Chuyển sang trang **Parameter Bindings**.
5. Kiểm tra binding:

| Child package parameter | Giá trị từ Master |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

Vì task được copy từ package 11 nên binding thường đã có. Nếu chưa có, bấm **Add** và chọn lại.

6. Bấm **OK**.

### 8.3. Nối luồng Success

1. Chọn `PKG - Extract GeoJSON`.
2. Kéo mũi tên xanh từ task này xuống `PKG - Extract JSONL`.
3. Nhấp đúp mũi tên, kiểm tra:

```text
Evaluation operation = Constraint
Value = Success
```

4. Bấm **OK**.
5. Nhấn `Ctrl+S`.

Master lúc này phải là:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
```

`SQL - Complete Batch` vẫn Disabled và chưa nối vào cuối JSONL.

## 9. Chạy debug đúng cách

Không chạy riêng package 12 với `pLoadBatchKey = 0`, vì package cần batch thật do Master tạo.

### 9.1. Chọn Master làm startup object

1. Trong **Solution Explorer**, nhấp phải `00_Master.dtsx`.
2. Chọn **Set as StartUp Object** nếu menu có lựa chọn này.
3. Mở `00_Master.dtsx`.

### 9.2. Chạy

1. Kiểm tra `SQL - Complete Batch` vẫn Disabled.
2. Bấm **Start** hoặc nhấn `F5`.
3. Chờ task chạy; file traffic lớn nên package 12 có thể lâu hơn package 11.
4. Kết quả đúng: toàn bộ task từ Start Batch đến `PKG - Extract JSONL` đều màu xanh.
5. Chọn menu **Debug → Stop Debugging** hoặc nhấn `Shift+F5` để trở lại Design.

## 10. SSMS — đối soát package 12

Mở **New Query** trong SSMS và chạy **toàn bộ** block sau. Dòng `DECLARE` đầu tiên bắt buộc phải chạy cùng các câu phía dưới.

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'08_weather_events.jsonl'
    ORDER BY LoadFileKey DESC
);

IF @LoadBatchKey IS NULL
    THROW 51450, 'Không tìm thấy batch JSONL mới nhất.', 1;

-- 1. Batch vẫn STARTED vì toàn ETL chưa hoàn thành.
SELECT
    LoadBatchKey,
    BatchID,
    SourceFolder,
    DatasetPeriodStart,
    DatasetPeriodEnd,
    LoadStatus,
    StartedAt,
    CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Batch phải có đủ tám source file 01..08 và đều COMPLETED.
SELECT
    LoadFileKey,
    SourceID,
    FileName,
    ExpectedRowCount,
    ActualRowCount,
    AcceptedRowCount,
    RejectedRowCount,
    LoadStatus
FROM DanangSmartParkingDW.etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceID;

-- 3. Riêng ba file JSONL phải là 16.884 / 4.300 / 168.
SELECT
    'TrafficEventRaw' AS ObjectName,
    COUNT_BIG(*) AS ActualRows,
    CONVERT(bigint, 16884) AS ExpectedRows,
    MIN(SourceRowNumber) AS MinRow,
    MAX(SourceRowNumber) AS MaxRow,
    SUM(CASE WHEN ISJSON(RawJson) = 1 THEN 1 ELSE 0 END) AS ValidJsonRows
FROM DanangSmartParkingSTG.extract.TrafficEventRaw
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'ParkingEventRaw',
    COUNT_BIG(*),
    CONVERT(bigint, 4300),
    MIN(SourceRowNumber),
    MAX(SourceRowNumber),
    SUM(CASE WHEN ISJSON(RawJson) = 1 THEN 1 ELSE 0 END)
FROM DanangSmartParkingSTG.extract.ParkingEventRaw
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'WeatherEventRaw',
    COUNT_BIG(*),
    CONVERT(bigint, 168),
    MIN(SourceRowNumber),
    MAX(SourceRowNumber),
    SUM(CASE WHEN ISJSON(RawJson) = 1 THEN 1 ELSE 0 END)
FROM DanangSmartParkingSTG.extract.WeatherEventRaw
WHERE LoadBatchKey = @LoadBatchKey;

-- 4. Không có reject trong toàn bộ tám source file của batch.
SELECT COUNT_BIG(*) AS RejectedRows
FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
  ON LoadFile.LoadFileKey = Rejected.LoadFileKey
WHERE LoadFile.LoadBatchKey = @LoadBatchKey;

-- 5. Xem mẫu traffic; tiếng Việt phải hiển thị đúng.
SELECT TOP (5)
    SourceRowNumber,
    EventID,
    EventTimestampRaw,
    RoadID,
    RoadName,
    AnalysisZone,
    VehicleCountRaw,
    AvgSpeedKmhRaw
FROM DanangSmartParkingSTG.extract.TrafficEventRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;

-- 6. Xem mẫu parking; boolean RAW phải là true/false.
SELECT TOP (5)
    SourceRowNumber,
    EventID,
    VehicleID,
    RoadName,
    StartTimeRaw,
    EndTimeRaw,
    LegalParkingRaw,
    ActiveRestrictionID
FROM DanangSmartParkingSTG.extract.ParkingEventRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;

-- 7. Xem mẫu weather.
SELECT TOP (5)
    SourceRowNumber,
    WeatherTimestampRaw,
    TemperatureCRaw,
    RainMmRaw,
    HumidityPctRaw,
    SourceReference
FROM DanangSmartParkingSTG.extract.WeatherEventRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
```

## 11. Bảng kết quả nghiệm thu

### 11.1. Audit

- `LoadBatch.LoadStatus = STARTED` là đúng tại checkpoint này.
- `CompletedAt` của batch vẫn `NULL`.
- Có đủ tám dòng `LoadFile`, SourceID từ `01` đến `08`.
- Cả tám `LoadFile.LoadStatus = COMPLETED`.
- Ba file JSONL có `RejectedRowCount = 0`.

### 11.2. Row count JSONL

| ObjectName | ActualRows | ExpectedRows | MinRow | MaxRow | ValidJsonRows |
|---|---:|---:|---:|---:|---:|
| `TrafficEventRaw` | 16.884 | 16.884 | 1 | 16.884 | 16.884 |
| `ParkingEventRaw` | 4.300 | 4.300 | 1 | 4.300 | 4.300 |
| `WeatherEventRaw` | 168 | 168 | 1 | 168 | 168 |

`RejectedRows` phải bằng `0`.

Dòng traffic đầu phải có:

```text
RoadName     = Lê Duẩn
AnalysisZone = Hải Châu core
```

Nếu toàn bộ điều kiện trên đạt, package `12_Extract_JSONL.dtsx` đã hoàn thành.

## 12. Xử lý lỗi thường gặp

### 12.1. Task đỏ ngay khi chạy

1. Nhấp tab **Progress** hoặc **Execution Results**.
2. Mở dòng lỗi màu đỏ đầu tiên.
3. Kiểm tra trước:
   - Task dùng `(project) CM_DanangDW`.
   - `BypassPrepare = True`.
   - Parameter `0 = $Package::pLoadBatchKey`, kiểu `LONG`.
   - Parameter `1 = $Project::pRawRoot`, kiểu `NVARCHAR`, size `4000`.
   - Hai dòng mapping không bị đảo thứ tự.

### 12.2. `LoadBatchKey does not exist or is not STARTED`

Nguyên nhân thường là chạy riêng package 12 với giá trị mặc định `0`. Hãy chạy `00_Master.dtsx`, không chạy riêng package 12.

### 12.3. `JSONL files were already registered for this batch`

Package 12 đang bị chạy lại trên cùng một batch. Chạy lại Master để tạo batch mới.

### 12.4. `Access is denied` hoặc `cannot bulk load`

SQL Server service account không đọc được file. Kiểm tra lại quyền thư mục theo package 11 và chạy lại truy vấn mục 3.

### 12.5. Lỗi 51405 / 51412 / 51419

File chứa JSON không hợp lệ, dòng trống hoặc một JSON object bị ngắt thành nhiều dòng. Không sửa file bằng Excel. So sánh lại file RAW gốc hoặc giải nén lại bộ dữ liệu.

### 12.6. Lỗi Unicode 51408 / 51415

Chạy lại truy vấn mục 3. Kết quả phải là `Lê Duẩn` và `Hải Châu core`. Đảm bảo procedure được tạo từ phiên bản mới nhất của `sql/20_extract_jsonl_execute_sql.sql`.

### 12.7. Batch bị FAILED

Không xóa dữ liệu thủ công và không đổi trạng thái batch cũ. Sửa nguyên nhân, sau đó chạy lại `00_Master.dtsx` để tạo một batch mới có audit độc lập.

## 13. Checklist hoàn thành

- [ ] Preflight đọc được traffic JSONL và tiếng Việt đúng.
- [ ] Đã chạy `sql/20_extract_jsonl_execute_sql.sql` trong SSMS.
- [ ] Procedure `etl.usp_ExtractJSONLToStaging` tồn tại.
- [ ] Package `12_Extract_JSONL.dtsx` có parameter `pLoadBatchKey` Int64.
- [ ] Package 12 chỉ có một task `SQL - Extract JSONL to STG`.
- [ ] Task dùng `(project) CM_DanangDW` và `BypassPrepare = True`.
- [ ] Hai parameter mapping đúng thứ tự `0` và `1`.
- [ ] Master có `PKG - Extract JSONL` sau GeoJSON.
- [ ] Debug Master thành công đến hết package 12.
- [ ] `TrafficEventRaw = 16.884`.
- [ ] `ParkingEventRaw = 4.300`.
- [ ] `WeatherEventRaw = 168`.
- [ ] Tất cả `RawJson` hợp lệ.
- [ ] `RejectedRows = 0`.
- [ ] Tiếng Việt trong `RoadName` và `AnalysisZone` hiển thị đúng.

## Bước kế tiếp

Sau khi checklist đạt, chuyển sang [`13_VALIDATE_EXTRACT.md`](13_VALIDATE_EXTRACT.md) để xác nhận toàn bộ tám nguồn RAW trước khi Transform.

