# 11 — Extract GeoJSON bằng Execute SQL Task

## 1. Phương án đã thống nhất

Không dùng `Script Component`, không tạo Data Flow cho GeoJSON.

Package `11_Extract_GeoJSON.dtsx` chỉ có **một Execute SQL Task**. Task gọi stored procedure để SQL Server:

1. Đọc trực tiếp hai file GeoJSON bằng `OPENROWSET(BULK...)`.
2. Bung mảng `features[]` bằng `OPENJSON`.
3. Nạp dữ liệu RAW vào database Staging.
4. Ghi và cập nhật `etl.LoadFile`.
5. Kiểm tra đúng số dòng.

```text
01_roads.geojson ─┐
                  ├─ SQL - Extract GeoJSON to STG
04_poi.geojson  ──┘
```

Đầu ra:

| File | Bảng RAW | Expected |
|---|---|---:|
| `01_roads.geojson` | `DanangSmartParkingSTG.extract.RoadRaw` | 30 |
| `04_poi.geojson` | `DanangSmartParkingSTG.extract.POIRaw` | 50 |

Đây là Extract RAW nên:

- Không làm sạch dữ liệu.
- Không deduplicate.
- Thuộc tính số vẫn được lưu vào cột `*Raw` dạng chuỗi.
- `geometry` được giữ trong `GeometryJson`.
- Thiếu thuộc tính thì giữ `NULL`; kiểm tra nghiệp vụ thực hiện ở Transform.
- File JSON không hợp lệ hoặc sai số dòng sẽ làm task thất bại.

## 2. Điều kiện quan trọng: SQL Server phải đọc được thư mục RAW

Khác với Flat File Source, `OPENROWSET` đọc file bằng **tài khoản dịch vụ SQL Server**, không phải tài khoản đang mở SSMS.

Thư mục hiện tại:

```text
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d
```

Hai file phải tồn tại:

```text
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\01_roads.geojson
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\04_poi.geojson
```

## 3. SSMS — kiểm tra `OPENJSON`

Mở SSMS → **New Query**, chọn database `DanangSmartParkingDW`, chạy:

```sql
SELECT name, compatibility_level
FROM sys.databases
WHERE name IN (N'DanangSmartParkingDW', N'DanangSmartParkingSTG');
```

`compatibility_level` phải từ `130` trở lên. Với SQL Server 2019 nên là `150`.

Nếu database nào nhỏ hơn `130`, chạy:

```sql
ALTER DATABASE DanangSmartParkingDW SET COMPATIBILITY_LEVEL = 150;
ALTER DATABASE DanangSmartParkingSTG SET COMPATIBILITY_LEVEL = 150;
```

## 4. SSMS — kiểm tra quyền đọc file

Chạy riêng truy vấn sau:

```sql
DECLARE @Utf8Json nvarchar(max);

SELECT @Utf8Json = CONVERT
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
    BULK 'C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\01_roads.geojson',
    SINGLE_BLOB
) AS SourceFile;

SELECT
    DATALENGTH(@Utf8Json) AS JsonBytes,
    JSON_VALUE(@Utf8Json, '$.features[0].properties.road_name')
        AS FirstRoadName,
    JSON_VALUE(@Utf8Json, '$.features[0].properties.analysis_zone')
        AS FirstAnalysisZone;
```

Kết quả đúng:

- Có một dòng.
- `JsonBytes > 0`.
- `FirstRoadName = Trần Phú`.
- `FirstAnalysisZone = Hải Châu core`.
- Không được xuất hiện dạng `Tráº§n`, `Háº£i` hoặc `ChÃ¢u`.

`SINGLE_BLOB` giữ nguyên byte nguồn. Biểu thức `COALESCE(BulkColumn, '' COLLATE ..._UTF8)` buộc phép chuyển từ byte sang `varchar` xảy ra ngay trong code page UTF-8; sau đó `CONVERT(nvarchar(max), ...)` mới tạo Unicode UTF-16. Không chuyển `BulkColumn` sang `varchar` trước khi áp dụng `_UTF8`, vì khi đó chuỗi đã bị mojibake và không thể khôi phục bằng một `COLLATE` gắn sau.

### 4.1. Nếu báo `Operating system error code 5 (Access is denied)`

Tài khoản SQL Server chưa có quyền đọc thư mục.

#### Xác định tài khoản dịch vụ

1. Mở **SQL Server Configuration Manager** trên Windows.
2. Chọn **SQL Server Services**.
3. Tìm dòng `SQL Server (NEW_PROJECT)`.
4. Xem cột **Log On As**.
5. Ghi lại chính xác tên tài khoản.

Với named instance `NEW_PROJECT`, tài khoản thường là:

```text
NT SERVICE\MSSQL$NEW_PROJECT
```

Nhưng phải dùng đúng giá trị hiển thị trong **Log On As**.

#### Cấp quyền thư mục

1. Mở Windows Explorer.
2. Nhấp phải thư mục `danang_smart_parking_raw_7d` → **Properties**.
3. Chọn tab **Security** → **Edit** → **Add**.
4. Nhập tài khoản dịch vụ vừa tìm được.
5. Bấm **Check Names** → **OK**.
6. Cho phép:
   - `Read & execute`.
   - `List folder contents`.
   - `Read`.
7. Bấm **Apply** → **OK**.
8. Chạy lại truy vấn kiểm tra `OPENROWSET`.

Không cần cấp `Write` và không cần bật `Ad Hoc Distributed Queries` chỉ để dùng `OPENROWSET(BULK...)`.

### 4.2. Nếu vẫn không cấp được quyền Desktop

Phương án dự phòng:

1. Tạo thư mục dễ quản lý, ví dụ:

```text
C:\SQLData\danang_smart_parking_raw_7d
```

2. Copy toàn bộ file RAW vào đó.
3. Cấp quyền Read cho tài khoản dịch vụ SQL Server.
4. Đổi project parameter `pRawRoot` sang đường dẫn mới.
5. Chạy lại truy vấn kiểm tra.

Chỉ tiếp tục khi truy vấn `OPENROWSET` trả về nội dung file.

## 5. SSMS — tạo stored procedure Extract GeoJSON

Script đã được chuẩn bị tại:

[`../../sql/18_extract_geojson_execute_sql.sql`](../../sql/18_extract_geojson_execute_sql.sql)

Thao tác:

1. Mở file `sql/18_extract_geojson_execute_sql.sql` trong VS Code.
2. Copy toàn bộ nội dung.
3. Trong SSMS bấm **New Query**.
4. Dán toàn bộ nội dung.
5. Bấm **Execute** hoặc nhấn `F5`.
6. Kết quả phải là `Commands completed successfully`.

Script tạo procedure:

```text
DanangSmartParkingDW.etl.usp_ExtractGeoJSONToStaging
```

### 5.1. Kiểm tra procedure đã tồn tại

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
WHERE name = N'usp_ExtractGeoJSONToStaging';
```

Expected: đúng một dòng, schema `etl`.

Trong Object Explorer cũng có thể kiểm tra:

```text
Databases
  → DanangSmartParkingDW
    → Programmability
      → Stored Procedures
        → etl.usp_ExtractGeoJSONToStaging
```

Nếu chưa thấy, nhấp phải **Stored Procedures** → **Refresh**.

## 6. Stored procedure đang thực hiện những gì

Procedure nhận hai đầu vào:

```text
@LoadBatchKey
@RawRoot
```

Sau đó thực hiện:

```text
Đăng ký LoadFile 01
  → OPENROWSET đọc 01_roads.geojson
  → OPENJSON bung 30 features
  → INSERT extract.RoadRaw
  → kiểm tra count=30
  → LoadFile 01 = COMPLETED
  → đăng ký LoadFile 04
  → OPENROWSET đọc 04_poi.geojson
  → OPENJSON bung 50 features
  → INSERT extract.POIRaw
  → kiểm tra count=50
  → LoadFile 04 = COMPLETED
```

Nếu xảy ra lỗi:

- File đang xử lý được đánh dấu `FAILED`.
- Batch được đánh dấu `FAILED`.
- SQL Server trả lỗi cho SSIS.
- Không chạy lại cùng `LoadBatchKey`; sửa lỗi rồi chạy Master để tạo batch mới.

## 7. Tạo package `11_Extract_GeoJSON.dtsx`

Nếu chưa có package:

1. Trong Visual Studio/SSDT, nhấp phải **SSIS Packages**.
2. Chọn **New SSIS Package**.
3. Nhấn `F2`, đổi tên thành `11_Extract_GeoJSON.dtsx`.
4. Mở package → bấm vùng trống Control Flow → nhấn `F4`.
5. Đổi thuộc tính `Name` thành:

```text
P11_Extract_GeoJSON
```

Nếu đã tạo package theo hướng Script Component cũ:

1. Mở `11_Extract_GeoJSON.dtsx`.
2. Trong Control Flow nhấn `Ctrl+A` để chọn các task cũ.
3. Nhấn `Delete`.
4. Không cần giữ các Script Component/Data Flow cũ.
5. Nếu đã tạo variables `RoadsFilePath`, `POIFilePath`, `LoadFileKey`, có thể xóa vì phương án mới không dùng.

## 8. Tạo package parameter `pLoadBatchKey`

1. Mở tab **Parameters** của `11_Extract_GeoJSON.dtsx`.
2. Nếu chưa có, bấm **Add Parameter**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

Nếu parameter đã có đúng cấu hình thì giữ nguyên.

Không tạo package parameter `pRawRoot` mới. Package dùng project parameter đã có:

```text
$Project::pRawRoot
```

## 9. Tạo Execute SQL Task duy nhất

1. Quay lại tab **Control Flow**.
2. Trong **SSIS Toolbox**, kéo **Execute SQL Task** vào vùng thiết kế.
3. Nhấn `F2`, đổi tên:

```text
SQL - Extract GeoJSON to STG
```

4. Nhấp đúp task.
5. Trang **General** cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `None` |
| BypassPrepare | `True` |

6. Bấm `...` tại **SQLStatement**.
7. Dán:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);
DECLARE @RawRoot nvarchar(4000) = CONVERT(nvarchar(4000), ?);

EXEC etl.usp_ExtractGeoJSONToStaging
    @LoadBatchKey = @LoadBatchKey,
    @RawRoot = @RawRoot;
```

8. Bấm **OK** để đóng cửa sổ nhập SQL.

## 10. Parameter Mapping của Execute SQL Task

Trong **Execute SQL Task Editor**:

1. Chọn trang **Parameter Mapping**.
2. Bấm **Add** hai lần.
3. Cấu hình đúng thứ tự:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `$Package::pLoadBatchKey` | Input | `LONG` | `0` | `-1` |
| `$Project::pRawRoot` | Input | `NVARCHAR` | `1` | `4000` |

Giải thích:

- Dấu `?` thứ nhất nhận ordinal `0`.
- Dấu `?` thứ hai nhận ordinal `1`.
- Không nhập tên `@LoadBatchKey` hoặc `@RawRoot` vào cột Parameter Name.
- `BIGINT` trong SQL tương ứng `LONG` trong Execute SQL Task dùng OLE DB.

4. Không thêm **Result Set**.
5. Bấm **OK**.
6. Nhấn `Ctrl+S`.

Package 11 hoàn chỉnh chỉ cần:

```text
┌──────────────────────────────┐
│ SQL - Extract GeoJSON to STG │
└──────────────────────────────┘
```

## 11. Gắn package 11 vào `00_Master.dtsx`

1. Mở `00_Master.dtsx` → **Control Flow**.
2. Chọn task `PKG - Extract Master CSV`.
3. Nhấn `Ctrl+C`, `Ctrl+V`.
4. Đổi tên bản sao:

```text
PKG - Extract GeoJSON
```

5. Đặt task mới dưới `PKG - Extract Master CSV`.
6. Xóa precedence constraint thừa nếu bản sao mang theo đường nối sai.
7. Nối mũi tên xanh:

```text
PKG - Extract Master CSV → PKG - Extract GeoJSON
```

8. Nhấp đúp `PKG - Extract GeoJSON`.
9. Trang **Package**:
   - `ReferenceType = Project Reference`.
   - `PackageNameFromProjectReference = 11_Extract_GeoJSON.dtsx`.
10. Trang **Parameter Bindings**:

| Child parameter | Master value |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

11. Bấm **OK**.
12. `SQL - Complete Batch` vẫn phải có `Disabled=True`.
13. Lưu toàn bộ solution bằng `Ctrl+Shift+S`.

Master tại checkpoint này:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON

SQL - Complete Batch [Disabled]
```

## 12. Chạy debug

Không chạy trực tiếp package 11 vì `pLoadBatchKey=0` không có batch cha.

1. Mở `00_Master.dtsx`.
2. Kiểm tra `SQL - Complete Batch` đang disabled.
3. Nhấn `F5` hoặc **Start**.
4. Theo dõi thứ tự:
   - `SQL - Start Batch` xanh.
   - `PKG - Extract Master CSV` xanh.
   - `PKG - Extract GeoJSON` xanh.
5. Trong package 11 chỉ có một Execute SQL Task và task phải chuyển màu xanh.

Nếu task đỏ:

1. Mở tab **Progress/Execution Results**.
2. Tìm thông báo lỗi màu đỏ đầu tiên.
3. Nếu là `Access is denied`, quay lại mục 4.
4. Nếu batch đã bị đánh dấu `FAILED`, sửa lỗi rồi chạy lại từ Master để tạo batch mới.

## 13. Đối soát trên SSMS

Mở **New Query** và chạy toàn bộ block sau. Không đặt `GO` sau dòng `DECLARE`.

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'04_poi.geojson'
    ORDER BY LoadFileKey DESC
);

-- 1. Batch vẫn STARTED vì toàn ETL chưa hoàn thành.
SELECT
    LoadBatchKey,
    BatchID,
    SourceFolder,
    LoadStatus,
    StartedAt,
    CompletedAt,
    ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Tại checkpoint này phải có đủ file 01, 02, 03, 04, 05.
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

-- 3. Đếm Road và POI của đúng batch.
SELECT
    'RoadRaw' AS ObjectName,
    COUNT_BIG(*) AS ActualRows,
    30 AS ExpectedRows,
    MIN(SourceRowNumber) AS MinRow,
    MAX(SourceRowNumber) AS MaxRow,
    SUM(CASE WHEN ISJSON(GeometryJson) = 1 THEN 1 ELSE 0 END)
        AS ValidGeometryRows
FROM DanangSmartParkingSTG.extract.RoadRaw
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'POIRaw',
    COUNT_BIG(*),
    50,
    MIN(SourceRowNumber),
    MAX(SourceRowNumber),
    SUM(CASE WHEN ISJSON(GeometryJson) = 1 THEN 1 ELSE 0 END)
FROM DanangSmartParkingSTG.extract.POIRaw
WHERE LoadBatchKey = @LoadBatchKey;

-- 4. Xem mẫu Road.
SELECT TOP (5)
    SourceRowNumber,
    RoadID,
    RoadName,
    AnalysisZone,
    LanesRaw,
    SpeedLimitKmhRaw,
    GeometryJson
FROM DanangSmartParkingSTG.extract.RoadRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;

-- 5. Xem mẫu POI.
SELECT TOP (5)
    SourceRowNumber,
    POIID,
    POIName,
    CategoryCode,
    LongitudeRaw,
    LatitudeRaw,
    GeometryJson
FROM DanangSmartParkingSTG.extract.POIRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
```

Kết quả đúng:

| Kiểm tra | Kết quả |
|---|---|
| Batch | `STARTED`, `ErrorMessage=NULL` |
| File 01 | `30 / 30 / 0 / COMPLETED` |
| File 04 | `50 / 50 / 0 / COMPLETED` |
| RoadRaw | 30 dòng, MinRow=1, MaxRow=30, ValidGeometryRows=30 |
| POIRaw | 50 dòng, MinRow=1, MaxRow=50, ValidGeometryRows=50 |

### 13.1. Kiểm tra riêng Unicode tiếng Việt

Ngoài row count, chạy thêm:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'04_poi.geojson'
    ORDER BY LoadFileKey DESC
);

SELECT TOP (10) RoadID, RoadName, AnalysisZone
FROM DanangSmartParkingSTG.extract.RoadRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;

SELECT TOP (10) POIID, POIName
FROM DanangSmartParkingSTG.extract.POIRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
```

Chạy toàn bộ block từ `DECLARE` đến câu `SELECT` cuối cùng. Không chỉ bôi đen hai câu `SELECT`, và không thêm `GO` sau `DECLARE`, vì `GO` sẽ kết thúc phạm vi của biến.

Tên phải hiển thị đúng, ví dụ `Trần Phú`, `Hải Châu`, `Nguyễn Văn Linh`. Nếu thấy `Tráº§n PhÃº` hoặc `Háº£i ChÃ¢u`, dữ liệu của batch đó đã được nạp bằng phiên bản cũ. Chạy lại script 18 đã sửa, sau đó dùng script reload Unicode ở mục 13.2.

### 13.2. Reload hai file nếu đã nạp bằng phiên bản lỗi font

Script sửa dữ liệu đã được chuẩn bị tại:

[`../../sql/19_reload_geojson_utf8.sql`](../../sql/19_reload_geojson_utf8.sql)

Thứ tự bắt buộc:

1. Chạy lại toàn bộ [`../../sql/18_extract_geojson_execute_sql.sql`](../../sql/18_extract_geojson_execute_sql.sql) để cập nhật procedure.
2. Mở `sql/19_reload_geojson_utf8.sql`.
3. Kiểm tra giá trị `@RawRoot` đúng với máy Windows.
4. Chạy toàn bộ script 19 một lần.
5. Chạy lại truy vấn đối soát Unicode ở trên.

Script 19 chỉ xóa và nạp lại file `01`/`04` của batch GeoJSON mới nhất. Ba file CSV `02`/`03`/`05` trong cùng batch được giữ nguyên.

## 14. Vì sao không tạo `etl.RejectedRow` ở bước này

Với cách Execute SQL:

- JSON sai cấu trúc làm toàn file thất bại.
- File thiếu feature làm count khác expected và task thất bại.
- Thuộc tính thiếu trong một feature được giữ `NULL` ở RAW.
- Kiểm tra giá trị, kiểu dữ liệu và quy tắc nghiệp vụ nằm ở phase Transform.

Vì vậy Extract GeoJSON không cần xây một error output theo từng row. Trạng thái file/batch đã cung cấp checkpoint đủ rõ cho công đoạn RAW ingestion.

## 15. Checklist hoàn thành

- [ ] SQL Server service account đọc được thư mục RAW.
- [ ] `OPENROWSET` đọc được `01_roads.geojson` trên SSMS.
- [ ] Đã chạy `sql/18_extract_geojson_execute_sql.sql`.
- [ ] Procedure `etl.usp_ExtractGeoJSONToStaging` đã tồn tại.
- [ ] Package 11 có parameter `pLoadBatchKey` kiểu `Int64`.
- [ ] Package 11 chỉ có một Execute SQL Task.
- [ ] Task dùng `(project) CM_DanangDW`.
- [ ] Parameter Mapping có ordinal `0` và `1` đúng kiểu.
- [ ] Package 11 đã được gắn sau package 10 trong Master.
- [ ] RoadRaw có 30 dòng và POIRaw có 50 dòng.
- [ ] GeometryJson hợp lệ 30/30 và 50/50.
- [ ] LoadFile 01 và 04 đều `COMPLETED`.
- [ ] Batch vẫn `STARTED`; Complete Batch vẫn disabled.

Hoàn thành checklist này thì chuyển sang [`12_EXTRACT_JSONL.md`](12_EXTRACT_JSONL.md).
