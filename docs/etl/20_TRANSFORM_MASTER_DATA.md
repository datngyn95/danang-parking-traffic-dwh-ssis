# 20 — Transform Master Data bằng một Execute SQL Task

## 1. Mục tiêu và output

Package `20_Transform_MasterData.dtsx` chỉ có **một Execute SQL Task**. Task gọi một stored procedure set-based để chuyển toàn bộ 148 dòng master từ Extract Staging sang Transform Staging:

| Nguồn RAW | Bảng đích Clean | Expected valid |
|---|---|---:|
| `extract.RoadRaw` | `transform.RoadClean` | 30 |
| `extract.ParkingLocationRaw` | `transform.ParkingFacilityClean` | 20 |
| `extract.ParkingRestrictionRaw` | `transform.ParkingRestrictionClean` | 18 |
| `extract.POIRaw` | `transform.POIClean` | 50 |
| `extract.RoadSurveyRaw` | `transform.RoadSurveyClean` | 30 |

```text
5 bảng extract.*Raw (148 rows)
                 ↓
SQL - Transform Master Data
                 ↓
5 bảng transform.*Clean (148 valid, 0 invalid)
```

Không tạo năm Data Flow Task và không tạo chuỗi Execute SQL Task riêng cho từng bảng. Procedure xử lý cả năm subject trong một transaction và chỉ tác động đến `LoadBatchKey` hiện tại.

Package 20 **không** đổi batch sang `SILVER_VALIDATED`. Status chỉ được đổi ở package 23 sau khi master, event và aggregate đều đạt kiểm tra.

## 2. Điều kiện trước khi thực hiện

Package 13 phải hoàn thành trước package 20. Kiểm tra trên SSMS:

1. Mở SSMS.
2. Bấm **New Query**.
3. Chọn database `DanangSmartParkingDW`.
4. Chạy:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;
```

Kết quả bắt buộc:

- `LoadStatus = BRONZE_LOADED`.
- `RowsRead = 21500`.
- `RowsAccepted = 21500`.
- `RowsRejected = 0`.
- `ErrorMessage = NULL`.

Ghi lại `LoadBatchKey`, vì sẽ dùng nó khi debug package 20 độc lập.

Nếu status vẫn là `STARTED`, hoàn thành [`13_VALIDATE_EXTRACT.md`](13_VALIDATE_EXTRACT.md). Nếu status là `FAILED`, không biến nó lại thành `BRONZE_LOADED` bằng tay; tạo một batch mới và chạy lại từ Extract.

## 3. Procedure thực hiện những gì

Procedure `DanangSmartParkingSTG.dbo.usp_TransformMasterData` thực hiện tuần tự:

1. Chỉ chấp nhận batch có status `BRONZE_LOADED`.
2. Kiểm tra năm bảng RAW có đúng `30/20/18/50/30` dòng.
3. Xóa kết quả master transform cũ của đúng batch để hỗ trợ chạy lại idempotent.
4. Trim chuỗi; đổi code và status sang chữ hoa.
5. Dùng `TRY_CONVERT` để chuyển số, thời gian và tọa độ.
6. Kiểm tra business key bắt buộc và trùng key trong batch.
7. Kiểm tra GeoJSON của road là `LineString`, GeoJSON của POI là `Point`.
8. Tạo `AttributeHash` SHA2-256 cho Road, Facility, Restriction và POI.
9. Ghi `IsValid`, `RejectReason` và audit invalid vào `DanangSmartParkingDW.etl.RejectedRow`.
10. Chạy reconciliation nghiệp vụ trước khi trả thành công.

Hai ngoại lệ dữ liệu đã biết được xử lý có chủ đích:

- Restriction `R003` được phép có `RoadID = NULL`; dòng vẫn hợp lệ.
- Ba dòng Road Survey có `RoadWidthMRaw` trống; procedure lấy `RoadWidthM` từ `RoadClean`, đặt `WidthImputedFlag = 1` và vẫn giữ `RoadWidthRawM = NULL`.

Capacity của bãi đỗ được đối soát:

- Tổng capacity: `2267`.
- Reference capacity: `397`.
- Hai facility có reference capacity được xác định từ `CapacityStatus LIKE 'REAL_CAPACITY%'`.

Nếu validation nghiệp vụ thất bại, procedure giữ kết quả Clean và reject để debug, đổi batch thành `FAILED`, rồi làm task SSIS thất bại.

## 4. SSMS — tạo procedure cho package 20

SQL đã được chuẩn bị tại:

[`../../sql/22_transform_master_data.sql`](../../sql/22_transform_master_data.sql)

Thao tác:

1. Mở file `sql/22_transform_master_data.sql` trong VS Code.
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

Script này chỉ tạo hoặc cập nhật procedure; chưa Transform dữ liệu.

### 4.1. Kiểm tra procedure đã tồn tại

Chạy trên SSMS:

```sql
USE DanangSmartParkingSTG;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName,
    create_date,
    modify_date
FROM sys.procedures
WHERE name = N'usp_TransformMasterData';
```

Expected đúng một dòng:

```text
dbo | usp_TransformMasterData
```

Không bấm **Execute Procedure** trong Object Explorer ở bước này. Package SSIS sẽ gọi procedure.

## 5. SSIS — tạo package `20_Transform_MasterData.dtsx`

### 5.1. Tạo package

1. Mở solution `DanangSmartParkingETL` trong Visual Studio/SSDT.
2. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Chọn package mới, nhấn `F2`.
5. Đổi tên thành:

```text
20_Transform_MasterData.dtsx
```

6. Nhấp đúp package vừa tạo.
7. Chọn tab **Control Flow**.
8. Bấm vùng trống trên canvas, nhấn `F4` để mở **Properties**.
9. Đổi thuộc tính `Name` thành:

```text
P20_Transform_MasterData
```

### 5.2. Tạo package parameter

1. Trong package 20, chọn tab **Parameters** ở phía trên canvas.
2. Bấm **Add Parameter**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Chỉ nhập `pLoadBatchKey` vào cột Name, không nhập `$Package::pLoadBatchKey`.

### 5.3. Kiểm tra Connection Manager dùng chung

1. Quay lại tab **Control Flow**.
2. Nhìn khung **Connection Managers** phía dưới.
3. Phải thấy:

```text
(project) CM_DanangSTG
```

Connection này phải trỏ tới database `DanangSmartParkingSTG`.

Nếu không thấy:

1. Trong **Solution Explorer**, mở node **Connection Managers**.
2. Kiểm tra có `CM_DanangSTG.conmgr`.
3. Nếu đã có, đóng rồi mở lại package 20.
4. Nếu chưa có, tạo Project Connection Manager loại OLE DB trỏ tới `DanangSmartParkingSTG`; đặt tên `CM_DanangSTG`.

## 6. SSIS — tạo Execute SQL Task duy nhất

### 6.1. Thả task vào Control Flow

1. Trong **SSIS Toolbox**, tìm `Execute SQL Task`.
2. Kéo task vào vùng trống của **Control Flow**.
3. Nhấp phải task → **Rename**.
4. Đặt tên:

```text
SQL - Transform Master Data
```

### 6.2. Cấu hình trang General

1. Nhấp đúp task `SQL - Transform Master Data`.
2. Chọn trang **General** bên trái.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Transform Master Data` |
| ResultSet | `None` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangSTG` |
| SQLSourceType | `Direct input` |
| BypassPrepare | `True` |

4. Tại `SQLStatement`, bấm nút `...`.
5. Dán đúng câu lệnh:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC dbo.usp_TransformMasterData
    @LoadBatchKey = @LoadBatchKey;
```

6. Bấm **OK** để đóng cửa sổ nhập SQL.

Dấu `?` là positional parameter của OLE DB. Không thay nó bằng `$Package::pLoadBatchKey` trong câu SQL.

### 6.3. Cấu hình Parameter Mapping

1. Trong cửa sổ **Execute SQL Task Editor**, chọn **Parameter Mapping** bên trái.
2. Bấm **Add** đúng một lần.
3. Cấu hình dòng mới:

| Cột | Giá trị |
|---|---|
| Variable Name | `$Package::pLoadBatchKey` |
| Direction | `Input` |
| Data Type | `LONG` |
| Parameter Name | `0` |
| Parameter Size | `-1` |

Với OLE DB provider/UI hiện tại của project, danh sách Parameter Mapping không có `I8`, `Int64` hoặc `bigint`; hãy chọn `LONG`. Câu SQL ở mục 6.2 đã dùng `CONVERT(bigint, ?)` trước khi gọi procedure, nên `dbo.usp_TransformMasterData` vẫn nhận tham số SQL Server kiểu `bigint`.

Giữ package parameter `pLoadBatchKey` ở kiểu `Int64`; chỉ cột **Data Type** trong cửa sổ **Parameter Mapping** chọn `LONG`. Cách này giống các package 10–13 đã chạy thành công và an toàn với phạm vi batch key hiện tại của project.

4. Không tạo dòng mapping thứ hai.
5. Bấm **OK** để lưu task.
6. Nhấn `Ctrl+S` để lưu package.

Control Flow cuối cùng phải chỉ có:

```text
[SQL - Transform Master Data]
```

Không cần Data Flow Task trong package 20.

## 7. Debug package 20 độc lập

### 7.1. Gán batch key thật

Khi debug package độc lập, Master chưa truyền parameter xuống. Vì vậy:

1. Trước tiên mở SSMS và chạy truy vấn sau:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'BRONZE_LOADED'
ORDER BY LoadBatchKey DESC;
```

2. Nhìn cột `LoadBatchKey` trong kết quả và ghi lại **giá trị số**. Ví dụ kết quả là:

```text
LoadBatchKey | LoadStatus
12           | BRONZE_LOADED
```

Giá trị cần nhập là số `12`.

3. Quay lại Visual Studio và mở package 20.
4. Chọn tab **Parameters**.
5. Tại dòng `pLoadBatchKey`, nhấp vào ô **Value** đang chứa `0`.
6. Bôi đen số `0`, nhập đúng giá trị số lấy từ SSMS, rồi nhấn `Enter`.
7. Nhấn `Ctrl+S`.

Ví dụ nếu batch hiện tại là `12`, nhập số `12`, không nhập dấu nháy.

Không nhập các nội dung sau vào ô Value:

```text
LoadBatchKey
@LoadBatchKey
LoadBatchKey = 12
'12'
```

Ô Value của parameter `Int64` chỉ chấp nhận chữ số, ví dụ `7`, `12`, `25`. Nếu truy vấn SSMS không trả về dòng nào thì hiện chưa có batch `BRONZE_LOADED`; phải hoàn thành package 13 trước.

### 7.2. Chạy đúng package

1. Trong **Solution Explorer**, nhấp phải `20_Transform_MasterData.dtsx`.
2. Chọn **Execute Package**.
3. Chờ package kết thúc.

Expected:

- Task `SQL - Transform Master Data` có dấu tick xanh.
- Dòng cuối hiển thị `Package execution completed successfully`.
- Không có dấu X đỏ.

Nếu package báo `Master transform requires a BRONZE_LOADED batch`, kiểm tra lại status và `pLoadBatchKey`; không sửa status trực tiếp.

## 8. SSMS — đối soát output package 20

Sau khi package xanh, mở **New Query** trong SSMS và chạy toàn bộ block sau:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

-- 1. Status vẫn là BRONZE_LOADED; Package 23 mới đổi sang SILVER_VALIDATED.
SELECT
    LoadBatchKey,
    LoadStatus,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Năm bảng phải khớp 30/20/18/50/30 và không có invalid.
EXEC DanangSmartParkingSTG.dbo.usp_TransformMasterData
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;

-- 3. Ngoại lệ R003 phải được giữ đúng.
SELECT
    RestrictionID,
    RoadID,
    RoadName,
    IsValid,
    RejectReason
FROM DanangSmartParkingSTG.transform.ParkingRestrictionClean
WHERE LoadBatchKey = @LoadBatchKey
  AND RestrictionID = 'R003';

-- 4. Đúng ba độ rộng survey được impute từ Road master.
SELECT
    SegmentID,
    RoadID,
    RoadWidthRawM,
    RoadWidthResolvedM,
    WidthImputedFlag,
    IsValid
FROM DanangSmartParkingSTG.transform.RoadSurveyClean
WHERE LoadBatchKey = @LoadBatchKey
  AND WidthImputedFlag = 1
ORDER BY SegmentID;

-- 5. Không có reject Transform Master.
SELECT COUNT_BIG(*) AS MasterTransformRejectedRows
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

-- 6. Kiểm tra Unicode và kiểu dữ liệu đã chuyển.
SELECT TOP (5)
    RoadID,
    RoadName,
    AnalysisZone,
    LaneCount,
    RoadWidthM,
    IsValid
FROM DanangSmartParkingSTG.transform.RoadClean
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
```

Lưu ý: lệnh `EXEC ... @ReturnDetail = 1` chạy procedure lại một lần. Việc này an toàn vì procedure idempotent: nó xóa rồi tạo lại đúng kết quả của batch hiện tại.

### 8.1. Expected results

Result đầu của procedure:

| ObjectName | ActualRows | ValidRows | InvalidRows | ExpectedValidRows | IsMatched |
|---|---:|---:|---:|---:|---:|
| `transform.ParkingFacilityClean` | 20 | 20 | 0 | 20 | 1 |
| `transform.ParkingRestrictionClean` | 18 | 18 | 0 | 18 | 1 |
| `transform.POIClean` | 50 | 50 | 0 | 50 | 1 |
| `transform.RoadClean` | 30 | 30 | 0 | 30 | 1 |
| `transform.RoadSurveyClean` | 30 | 30 | 0 | 30 | 1 |

Các result tiếp theo:

- `TotalCapacity = 2267`.
- `ReferenceCapacity = 397`.
- `ReferenceFacilityCount = 2`.
- `BlankRawWidths = 3`.
- `ImputedWidths = 3`.
- `UnresolvedWidths = 0`.
- R003: `RoadID = NULL`, `IsValid = 1`, `RejectReason = NULL`.
- `MasterTransformRejectedRows = 0`.
- Road đầu tiên phải hiển thị đúng `Trần Phú`, `Hải Châu core`.

Nếu tất cả khớp, package 20 hoàn thành.

## 9. Gắn package 20 vào `00_Master.dtsx`

Chỉ làm phần này sau khi package 20 chạy độc lập thành công.

1. Mở `00_Master.dtsx` → tab **Control Flow**.
2. Kéo một **Execute Package Task** vào canvas.
3. Đổi tên task thành:

```text
PKG - Transform Master Data
```

4. Nhấp đúp task.
5. Chọn:
   - `ReferenceType`: `Project Reference`.
   - `PackageNameFromProjectReference`: `20_Transform_MasterData.dtsx`.
6. Mở trang **Parameter Bindings**.
7. Tạo binding:

| Child package parameter | Parent package variable |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

8. Bấm **OK**.
9. Nối mũi tên xanh từ `PKG - Validate Extract` tới `PKG - Transform Master Data`.
10. Chưa nối vào `SQL - Complete Batch`.

Sơ đồ Master tại checkpoint này:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
  → PKG - Validate Extract
  → PKG - Transform Master Data

SQL - Complete Batch [Disabled]
```

Khi chạy từ Master, binding sẽ ghi đè giá trị thiết kế của `pLoadBatchKey`. Không cần sửa parameter theo từng batch.

## 10. Tiêu chí nghiệm thu package 20

Script nghiệm thu tự động đã được chuẩn bị tại:

[`../../sql/22_validate_transform_master_data.sql`](../../sql/22_validate_transform_master_data.sql)

Script này **chỉ đọc dữ liệu**: không chạy lại Transform, không update status và không xóa dữ liệu.

### 10.1. Chạy nghiệm thu trên SSMS

1. Mở file `sql/22_validate_transform_master_data.sql` trong VS Code.
2. Nhấn `Ctrl+A`, rồi `Ctrl+C`.
3. Mở SSMS → **New Query**.
4. Dán toàn bộ script.
5. Bấm **Execute** hoặc nhấn `F5`.
6. Xem result set cuối cùng.

Khi toàn bộ kiểm tra đạt, result cuối phải là:

```text
AcceptanceStatus | LoadBatchKey | Message
PASS             | <batch key> | PACKAGE 20 ACCEPTED - ready for package 21
```

Script tự động kiểm tra:

- Batch mới nhất vẫn là `BRONZE_LOADED` và không có `ErrorMessage`.
- Năm bảng Clean có đúng `30/20/18/50/30` dòng hợp lệ.
- Tổng cộng `148` dòng và `148` valid.
- Mọi Clean row trace được về đúng RAW row bằng batch/file/source row.
- Không thiếu `AttributeHash` và không trùng business key.
- Không có invalid hoặc reject của Transform Master.
- `R003` hợp lệ với `RoadID = NULL`.
- Đúng ba survey width được impute và không còn width unresolved.
- Capacity đối soát `2267/397`, gồm hai reference facility.
- Unicode `Trần Phú / Hải Châu core` đúng.

Script luôn xuất một result set Unicode riêng. Expected:

```text
RoadID | RoadName | AnalysisZone  | UnicodeMatched | ExpectedUnicodeValue
RD001  | Trần Phú  | Hải Châu core | 1              | Trần Phú / Hải Châu core
```

Nếu có lỗi, script trả thêm result set `CheckName / ActualValue / ExpectedValue`, sau đó báo:

```text
PACKAGE 20 ACCEPTANCE FAILED. Review the Failures result set.
```

Không chuyển sang package 21 khi còn lỗi này.

### 10.2. Kiểm tra trực quan cấu hình SSIS

SQL không đọc được file thiết kế `.dtsx` trên máy Windows, vì vậy xác nhận thêm bốn cấu hình sau trên Visual Studio:

- Package 20 chỉ có một Execute SQL Task.
- Task dùng `(project) CM_DanangSTG`.
- Mapping `pLoadBatchKey` dùng `LONG`, parameter name `0`; SQL chuyển sang `bigint` trước khi gọi procedure.
- Package debug xanh.

Chỉ chuyển sang package 21 khi script trả `PASS` và các cấu hình trực quan trên đều đúng.

## 11. Bước tiếp theo

Sau khi package 20 đạt nghiệm thu, chuyển sang:

[`21_TRANSFORM_EVENTS.md`](21_TRANSFORM_EVENTS.md)

Package 21 cũng sẽ dùng hướng set-based để xử lý traffic, parking và weather event; package 23 mới là cổng đóng checkpoint Silver.
