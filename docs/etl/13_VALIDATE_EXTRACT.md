# 13 — Validate Extract và đóng checkpoint Bronze

## 1. Mục tiêu

Package `13_Validate_Extract.dtsx` là cổng kiểm soát giữa Extract và Transform.

Package chỉ có **một Execute SQL Task**. Task sẽ:

1. Kiểm tra batch có đúng tám `LoadFile` từ SourceID `01` đến `08`.
2. Kiểm tra tất cả file `COMPLETED`, row count đúng và reject bằng `0`.
3. Kiểm tra row count của tám bảng `extract.*Raw`.
4. Kiểm tra `SourceRowNumber` liên tục và đúng phạm vi.
5. Kiểm tra toàn bộ 21.352 dòng JSONL có `RawJson` hợp lệ.
6. Kiểm tra checkpoint Unicode tiếng Việt.
7. Tính tổng audit toàn Extract là 21.500 dòng.
8. Chỉ khi tất cả đạt mới đổi batch từ `STARTED` sang `BRONZE_LOADED`.

```text
8 source files + 8 extract tables
              ↓
SQL - Validate Extract and Mark Bronze
              ↓
LoadBatch.LoadStatus = BRONZE_LOADED
```

Không sử dụng Data Flow Task ở bước validation.

## 2. Kết quả bắt buộc trước khi bắt đầu

Package 10, 11 và 12 phải nạp thành công trong **cùng một `LoadBatchKey`**:

| SourceID | File | RAW rows |
|---|---|---:|
| `01` | `01_roads.geojson` | 30 |
| `02` | `02_parking_locations.csv` | 20 |
| `03` | `03_parking_restrictions.csv` | 18 |
| `04` | `04_poi.geojson` | 50 |
| `05` | `05_road_survey.csv` | 30 |
| `06` | `06_traffic_events.jsonl` | 16.884 |
| `07` | `07_parking_events.jsonl` | 4.300 |
| `08` | `08_weather_events.jsonl` | 168 |

Tổng RAW data rows:

```text
30 + 20 + 18 + 50 + 30 + 16.884 + 4.300 + 168 = 21.500
```

`SQL - Complete Batch` trong Master vẫn phải **Disabled**.

## 3. SSMS — xác định batch hiện tại

### 3.1. Mở query

1. Mở SSMS.
2. Bấm **New Query**.
3. Chọn database `DanangSmartParkingDW`.
4. Chạy toàn bộ block:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'08_weather_events.jsonl'
    ORDER BY LoadFileKey DESC
);

SELECT @LoadBatchKey AS CurrentLoadBatchKey;

SELECT
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    StartedAt,
    CompletedAt,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
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
```

Kết quả trước validation:

- `CurrentLoadBatchKey` phải khác `NULL`; ghi lại số này.
- `LoadBatch.LoadStatus = STARTED`.
- Có đúng tám `LoadFile`.
- Tám file đều `COMPLETED`.
- Expected/Actual/Accepted khớp bảng tại mục 2.
- Mọi `RejectedRowCount = 0`.

Nếu chưa đủ tám file, quay lại hoàn thành [`12_EXTRACT_JSONL.md`](12_EXTRACT_JSONL.md). Không tạo package 13 để bỏ qua lỗi Extract.

## 4. SSMS — kiểm tra procedure nền của Staging

Procedure `dbo.usp_ValidateStagingBatch` đã được tạo khi chạy `sql/17_validate_staging.sql`. Kiểm tra:

```sql
USE DanangSmartParkingSTG;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName
FROM sys.procedures
WHERE name = N'usp_ValidateStagingBatch';
```

Expected: đúng một dòng:

```text
dbo | usp_ValidateStagingBatch
```

Nếu không có kết quả:

1. Mở [`../../sql/17_validate_staging.sql`](../../sql/17_validate_staging.sql).
2. Copy toàn bộ nội dung.
3. Dán vào SSMS và bấm **Execute**.
4. Chạy lại truy vấn kiểm tra.

## 5. SSMS — chạy validation read-only trước

Thay số `0` bằng `CurrentLoadBatchKey` đã ghi ở mục 3, rồi chạy:

```sql
DECLARE @LoadBatchKey bigint = 0; -- thay 0 bằng batch key hiện tại

EXEC DanangSmartParkingSTG.dbo.usp_ValidateStagingBatch
    @LoadBatchKey = @LoadBatchKey,
    @Phase = 'EXTRACT',
    @ReturnDetail = 1;
```

Phải có tám dòng và toàn bộ `IsMatched = 1`:

| ObjectName | ExpectedRows |
|---|---:|
| `extract.RoadRaw` | 30 |
| `extract.ParkingLocationRaw` | 20 |
| `extract.ParkingRestrictionRaw` | 18 |
| `extract.POIRaw` | 50 |
| `extract.RoadSurveyRaw` | 30 |
| `extract.TrafficEventRaw` | 16.884 |
| `extract.ParkingEventRaw` | 4.300 |
| `extract.WeatherEventRaw` | 168 |

Truy vấn này chỉ đọc dữ liệu, chưa đổi status batch.

## 6. SSMS — tạo procedure validation gate

Script đã được chuẩn bị tại:

[`../../sql/21_validate_extract_and_mark_bronze.sql`](../../sql/21_validate_extract_and_mark_bronze.sql)

Thao tác:

1. Mở file `sql/21_validate_extract_and_mark_bronze.sql` trong VS Code.
2. Nhấn `Ctrl+A`, sau đó `Ctrl+C`.
3. Trong SSMS bấm **New Query**.
4. Dán toàn bộ script.
5. Bấm **Execute** hoặc nhấn `F5`.
6. Tab **Messages** phải hiển thị `Commands completed successfully`.

Script tạo:

```text
DanangSmartParkingDW.etl.usp_ValidateExtractAndMarkBronze
```

### 6.1. Kiểm tra procedure

```sql
USE DanangSmartParkingDW;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName,
    create_date,
    modify_date
FROM sys.procedures
WHERE name = N'usp_ValidateExtractAndMarkBronze';
```

Expected: một dòng, schema `etl`.

Không gọi procedure này thủ công ở thời điểm này, vì package 13 sẽ gọi nó và chuyển batch sang `BRONZE_LOADED`.

## 7. SSIS — tạo package `13_Validate_Extract.dtsx`

### 7.1. Tạo package

1. Mở solution `DanangSmartParkingETL` trong Visual Studio/SSDT.
2. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Chọn package mới và nhấn `F2`.
5. Đổi tên thành:

```text
13_Validate_Extract.dtsx
```

6. Nhấp đúp package mới.
7. Chọn tab **Control Flow**.
8. Bấm vùng trống trên canvas và nhấn `F4`.
9. Đổi thuộc tính `Name` thành:

```text
P13_Validate_Extract
```

### 7.2. Tạo package parameter

1. Chọn tab **Parameters**.
2. Bấm **Add Parameter**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Chỉ nhập tên `pLoadBatchKey`, không nhập `$Package::pLoadBatchKey` vào cột Name.

## 8. SSIS — tạo Execute SQL Task duy nhất

### 8.1. Thả task

1. Quay lại tab **Control Flow**.
2. Trong **SSIS Toolbox**, tìm `Execute SQL Task`.
3. Kéo task vào canvas.
4. Nhấp phải task → **Rename**.
5. Đổi tên:

```text
SQL - Validate Extract and Mark Bronze
```

### 8.2. Cấu hình General

1. Nhấp đúp task.
2. Chọn trang **General**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Validate Extract and Mark Bronze` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `None` |
| BypassPrepare | `True` |

4. Tại **SQLStatement**, bấm `...`.
5. Dán:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC etl.usp_ValidateExtractAndMarkBronze
    @LoadBatchKey = @LoadBatchKey;
```

6. Bấm **OK** lưu SQL.

Task dùng `CM_DanangDW` vì procedure gate và bảng audit `etl.LoadBatch` nằm trong `DanangSmartParkingDW`. Procedure tự gọi validation tại database Staging.

### 8.3. Cấu hình Parameter Mapping

1. Chọn **Parameter Mapping** bên trái.
2. Bấm **Add** một lần.
3. Cấu hình:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `$Package::pLoadBatchKey` | `Input` | `LONG` | `0` | `-1` |

Với OLE DB, kiểu SSIS tương ứng SQL Server `BIGINT` là `LONG`.

4. Bấm **OK**.
5. Nhấn `Ctrl+S`.

Control Flow đúng chỉ có:

```text
[SQL - Validate Extract and Mark Bronze]
```

## 9. SSIS — gắn package 13 vào Master

### 9.1. Copy Execute Package Task

1. Mở `00_Master.dtsx` → **Control Flow**.
2. Chọn task `PKG - Extract JSONL`.
3. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
4. Kéo bản sao xuống dưới package JSONL.
5. Nhấp phải bản sao → **Rename**.
6. Đổi tên:

```text
PKG - Validate Extract
```

### 9.2. Chọn package và parameter binding

1. Nhấp đúp `PKG - Validate Extract`.
2. Giữ `ReferenceType = Project Reference`.
3. Chọn package:

```text
13_Validate_Extract.dtsx
```

4. Chọn trang **Parameter Bindings**.
5. Kiểm tra:

| Child package parameter | Master value |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

6. Bấm **OK**.

### 9.3. Nối Success constraint

1. Chọn `PKG - Extract JSONL`.
2. Kéo mũi tên xanh xuống `PKG - Validate Extract`.
3. Nhấp đúp mũi tên và kiểm tra:

```text
Evaluation operation = Constraint
Value = Success
```

4. Bấm **OK**.
5. Nhấn `Ctrl+S`.

Master tạm thời:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
  → PKG - Validate Extract

SQL - Complete Batch [Disabled]
```

Không nối package 13 trực tiếp vào `SQL - Complete Batch`.

## 10. Chạy debug

Có hai cách. Với người mới, nên dùng cách A để kiểm tra toàn luồng.

### Cách A — chạy toàn Master

1. Nhấp phải `00_Master.dtsx` → **Set as StartUp Object** nếu có.
2. Mở `00_Master.dtsx`.
3. Kiểm tra `SQL - Complete Batch` vẫn Disabled.
4. Nhấn `F5`.
5. Master tạo batch mới, chạy lại 10 → 11 → 12 → 13.
6. Kết quả đúng: toàn bộ task đến `PKG - Validate Extract` đều màu xanh.
7. Nhấn `Shift+F5` trở về Design.

### Cách B — test nhanh package 13 trên batch hiện tại

Dùng khi batch hiện tại vẫn `STARTED` và tám file đã `COMPLETED`:

1. Mở package `13_Validate_Extract.dtsx` → tab **Parameters**.
2. Tạm đổi `Value` của `pLoadBatchKey` từ `0` thành `CurrentLoadBatchKey` ở mục 3.
3. Trong Solution Explorer, nhấp phải `13_Validate_Extract.dtsx` → **Set as StartUp Object**.
4. Nhấn `F5`.
5. Task phải chuyển màu xanh.
6. Nhấn `Shift+F5`.
7. Có thể trả Value về `0`; khi chạy Master, binding `User::LoadBatchKey` luôn ghi đè giá trị này.

Chỉ chạy cách B một lần trên một batch. Sau lần thành công, batch đã là `BRONZE_LOADED`, nên chạy lại cùng batch sẽ bị chặn.

## 11. SSMS — nghiệm thu sau package 13

Chạy toàn bộ block:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'08_weather_events.jsonl'
    ORDER BY LoadFileKey DESC
);

IF @LoadBatchKey IS NULL
    THROW 51550, 'Không tìm thấy batch JSONL mới nhất.', 1;

-- 1. Batch phải BRONZE_LOADED; chưa được COMPLETED.
SELECT
    LoadBatchKey,
    BatchID,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    StartedAt,
    CompletedAt,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Tám file phải COMPLETED và khớp baseline.
SELECT
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

-- 3. Procedure nền vẫn phải trả tám IsMatched = 1.
EXEC DanangSmartParkingSTG.dbo.usp_ValidateStagingBatch
    @LoadBatchKey = @LoadBatchKey,
    @Phase = 'EXTRACT',
    @ReturnDetail = 1;

-- 4. Không có reject.
SELECT COUNT_BIG(*) AS RejectedRows
FROM DanangSmartParkingDW.etl.RejectedRow AS Rejected
JOIN DanangSmartParkingDW.etl.LoadFile AS LoadFile
  ON LoadFile.LoadFileKey = Rejected.LoadFileKey
WHERE LoadFile.LoadBatchKey = @LoadBatchKey;
```

Kết quả đúng:

| Kiểm tra | Expected |
|---|---|
| `LoadStatus` | `BRONZE_LOADED` |
| `RowsRead` | 21.500 |
| `RowsAccepted` | 21.500 |
| `RowsRejected` | 0 |
| `CompletedAt` | `NULL` |
| `ErrorMessage` | `NULL` |
| Số `LoadFile` | 8 |
| Tất cả `LoadFile.LoadStatus` | `COMPLETED` |
| Tất cả `IsMatched` | 1 |
| `RejectedRows` | 0 |

`CompletedAt = NULL` là đúng vì đây mới là checkpoint Bronze, chưa phải cuối ETL.

## 12. Nếu validation thất bại

Khi bất kỳ check nào sai:

- Execute SQL Task chuyển màu đỏ.
- Batch đang kiểm tra được đánh dấu `FAILED`.
- `LoadBatch.ErrorMessage` lưu nguyên nhân.
- Transform không được chạy.

Xem lỗi:

```sql
SELECT TOP (10)
    LoadBatchKey,
    LoadStatus,
    ErrorMessage,
    StartedAt
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Không đổi thủ công batch `FAILED` về `STARTED`. Sửa nguyên nhân tại package Extract tương ứng, sau đó chạy lại Master để tạo batch mới.

### Một số mã lỗi chính

| Mã | Ý nghĩa |
|---:|---|
| `51503` | Không có đúng tám `LoadFile` |
| `51504` | Audit file thiếu, sai count hoặc chưa COMPLETED |
| `51506` | Có rejected row |
| `50013` | Row count của một bảng Extract sai baseline |
| `51507` | `SourceRowNumber` sai phạm vi hoặc không liên tục |
| `51508`–`51510` | `RawJson` JSONL không hợp lệ |
| `51511`–`51512` | Checkpoint Unicode không đúng |
| `51513` | Tổng audit khác 21.500/21.500/0 |

## 13. Checklist hoàn thành

- [ ] Batch trước validation là `STARTED`.
- [ ] Có đủ tám file `COMPLETED` trong cùng batch.
- [ ] Manual validation trả tám `IsMatched = 1`.
- [ ] Đã chạy `sql/21_validate_extract_and_mark_bronze.sql`.
- [ ] Procedure `etl.usp_ValidateExtractAndMarkBronze` tồn tại.
- [ ] Package `13_Validate_Extract.dtsx` có parameter `pLoadBatchKey` Int64.
- [ ] Package 13 chỉ có một Execute SQL Task.
- [ ] Task dùng `(project) CM_DanangDW`.
- [ ] Parameter mapping là ordinal `0`, kiểu `LONG`.
- [ ] Master có `PKG - Validate Extract` sau JSONL.
- [ ] Debug thành công.
- [ ] Batch chuyển thành `BRONZE_LOADED`.
- [ ] `RowsRead = RowsAccepted = 21.500`.
- [ ] `RowsRejected = 0`.
- [ ] `CompletedAt` vẫn `NULL`.

## Bước kế tiếp

Sau khi checklist đạt, chuyển sang [`20_TRANSFORM_MASTER_DATA.md`](20_TRANSFORM_MASTER_DATA.md). Transform chỉ được chạy với batch đang ở trạng thái `BRONZE_LOADED`.
