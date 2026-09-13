# 22 — Transform Aggregates bằng một Execute SQL Task

## 1. Mục tiêu và output

Package `22_Transform_Aggregates.dtsx` chỉ có **một Execute SQL Task**. Task gọi một stored procedure set-based để tổng hợp output package 21 thành hai bảng QA:

| Nguồn Clean | Grain bảng tổng hợp | Bảng đích | Expected |
|---|---|---|---:|
| `transform.TrafficObservationClean` | ngày × giờ × đường | `transform.TrafficHourlySummary` | 4.200 |
| `transform.ParkingEventClean` | ngày × đường × loại xe | `transform.ParkingDailySummary` | 513 |

```text
TrafficObservationClean (16.800)
  → GROUP BY date, hour, road
  → TrafficHourlySummary (4.200)

ParkingEventClean (4.283)
  → GROUP BY date, road, vehicle type
  → ParkingDailySummary (513)
```

Hai bảng này phục vụ QA/reconciliation, không thay thế Fact nguyên tử:

- Package 23 kiểm tra toàn bộ Silver rồi mới đổi batch sang `SILVER_VALIDATED`.
- Package 30/40 vẫn load Dimension và Fact bằng **Data Flow Task**.
- Package 22 không load dữ liệu vào `DanangSmartParkingDW.dwh`.

## 2. Thiết kế nhanh đã thống nhất

Package 22 áp dụng đầy đủ các góp ý từ package 20 và 21:

1. Chỉ một Execute SQL Task, không kéo nhiều task Delete/Insert/Validate.
2. Toàn bộ delete, aggregate và kiểm tra nằm trong một stored procedure.
3. Parameter Mapping của OLE DB dùng `LONG`.
4. Câu SQL trong task dùng `CONVERT(bigint, ?)`.
5. Khi debug, `pLoadBatchKey` chỉ nhận giá trị số.
6. Có script nghiệm thu read-only riêng, result đầu tiên trả `PASS/FAIL`.
7. Nghiệm thu so sánh lại **từng group và từng measure** với bảng Clean, không chỉ đếm dòng.
8. Unicode `Trần Phú / Hải Châu core` được hiển thị trực tiếp.

Procedure chạy idempotent: nếu chạy lại cùng batch, nó xóa rồi tạo lại đúng hai aggregate của batch đó.

## 3. Điều kiện bắt buộc trước package 22

Package 21 phải chạy xanh và script nghiệm thu package 21 phải trả `PASS`.

### 3.1. Xác nhận package 21

1. Mở SSMS.
2. Chọn **New Query**.
3. Dán và chạy:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT LoadBatchKey, LoadStatus, RowsRejected, ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

SELECT 'TrafficObservationClean' AS ObjectName,
       COUNT_BIG(*) AS ActualRows, 16800 AS ExpectedRows
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
UNION ALL
SELECT 'ParkingEventClean', COUNT_BIG(*), 4283
FROM transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1 AND DuplicateRank = 1
UNION ALL
SELECT 'WeatherHourlyClean', COUNT_BIG(*), 168
FROM transform.WeatherHourlyClean
WHERE LoadBatchKey = @LoadBatchKey AND IsValid = 1;
```

Điều kiện:

- `LoadStatus = BRONZE_LOADED`.
- `ErrorMessage = NULL`.
- Row count lần lượt là `16.800/4.283/168`.

Nếu ba bảng Clean bằng `0`, chưa được làm package 22. Quay lại [`21_TRANSFORM_EVENTS.md`](21_TRANSFORM_EVENTS.md), tạo procedure và chạy package 21 trước.

### 3.2. Ghi lại batch key

Chạy:

```sql
SELECT TOP (1) LoadBatchKey, LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'BRONZE_LOADED'
ORDER BY LoadBatchKey DESC;
```

Ghi lại giá trị số, ví dụ `11`. Package 22 phải dùng cùng batch với package 21.

## 4. Công thức tổng hợp

### 4.1. TrafficHourlySummary

Đây là phần **giải thích công thức**, chưa phải bước cần chạy trên SSMS. Đoạn dưới chỉ là mệnh đề lọc nằm bên trong procedure; không chạy riêng một dòng `WHERE`:

```sql
WHERE IsValid = 1 AND DuplicateRank = 1
```

Nếu muốn kiểm tra nguồn hợp lệ trên SSMS, phải chạy câu lệnh đầy đủ:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT TOP (100) *
FROM DanangSmartParkingSTG.transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1
ORDER BY EventDate, HourNumber, RoadID, EventTimestamp;
```

Group key:

```text
LoadBatchKey + EventDate + HourNumber + RoadID
```

Measure:

| Cột đích | Công thức |
|---|---|
| `VehicleVolume` | `SUM(VehicleCount)` |
| `AvgSpeedKmh` | `AVG(AvgSpeedKmh)`; SQL bỏ qua speed null |
| `AvgCongestionIndex` | `AVG(CongestionIndex)` |
| `IllegalParkingObserved` | `SUM(IllegalParkingCount)` |

Dataset có 7 ngày × 24 giờ × 25 đường = `4.200` group. Mỗi group nhận bốn quan sát 15 phút.

#### 4.1.1. Vì sao nguồn Clean vẫn có `AvgSpeedKmh = NULL`?

Tên bảng `TrafficObservationClean` không có nghĩa là mọi cột đều bắt buộc khác
`NULL`. Việc làm sạch trường tốc độ đã được thực hiện ở **package 21 - Transform
Events** theo quy tắc chất lượng dữ liệu sau:

- chuỗi rỗng được chuẩn hóa thành `NULL`;
- tốc độ có giá trị phải chuyển được sang số và nằm trong khoảng `0..250`;
- tốc độ bị thiếu được giữ là `NULL` và gắn `SpeedMissingFlag = 1`;
- không thay tốc độ thiếu bằng `0`, vì `0 km/h` mang nghĩa xe đứng yên và sẽ làm
  sai kết quả trung bình;
- dòng vẫn có thể có `IsValid = 1` nếu các trường bắt buộc khác hợp lệ.

Dataset này dự kiến có đúng `161` dòng thiếu tốc độ sau khi khử trùng. Chạy câu
đầy đủ sau trên SSMS để đối soát:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT
    COUNT_BIG(*) AS TotalCleanRows,
    SUM(CASE WHEN AvgSpeedKmh IS NULL THEN 1 ELSE 0 END) AS NullSpeedRows,
    SUM(CASE WHEN SpeedMissingFlag = 1 THEN 1 ELSE 0 END) AS MissingFlagRows,
    SUM(CASE
            WHEN (AvgSpeedKmh IS NULL AND SpeedMissingFlag <> 1)
              OR (AvgSpeedKmh IS NOT NULL AND SpeedMissingFlag <> 0)
            THEN 1 ELSE 0
        END) AS FlagMismatchRows
FROM transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1;
```

Expected:

```text
TotalCleanRows = 16800
NullSpeedRows  = 161
MissingFlagRows = 161
FlagMismatchRows = 0
```

Ở package 22, `AVG(AvgSpeedKmh)` tự bỏ qua các dòng có tốc độ `NULL`. Ví dụ một
nhóm giờ có bốn quan sát nhưng một quan sát thiếu tốc độ thì trung bình được tính
từ ba giá trị còn lại. Kiểm tra xem có nhóm giờ nào thiếu cả bốn tốc độ hay không:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT
    EventDate,
    HourNumber,
    RoadID,
    COUNT_BIG(*) AS ObservationRows,
    COUNT(AvgSpeedKmh) AS SpeedAvailableRows
FROM DanangSmartParkingSTG.transform.TrafficObservationClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1
GROUP BY EventDate, HourNumber, RoadID
HAVING COUNT(AvgSpeedKmh) = 0;
```

Nếu truy vấn cuối không trả dòng nào thì cả `4.200` nhóm đều vẫn tính được tốc
độ trung bình. Nếu có kết quả, `TrafficHourlySummary.AvgSpeedKmh` của đúng nhóm
đó phải tiếp tục để `NULL`; không tự bịa hoặc điền `0`.

### 4.2. ParkingDailySummary

Phần này cũng chỉ giải thích điều kiện lọc trong procedure, không chạy riêng mệnh đề `WHERE`:

```sql
WHERE IsValid = 1 AND DuplicateRank = 1
```

Nếu muốn kiểm tra trên SSMS, chạy câu đầy đủ:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    ORDER BY LoadBatchKey DESC
);

SELECT TOP (100) *
FROM DanangSmartParkingSTG.transform.ParkingEventClean
WHERE LoadBatchKey = @LoadBatchKey
  AND IsValid = 1
  AND DuplicateRank = 1
ORDER BY EventDate, RoadID, VehicleTypeCode, StartTimestamp;
```

Group key:

```text
LoadBatchKey + EventDate + RoadID + VehicleTypeCode
```

Measure:

| Cột đích | Công thức |
|---|---|
| `ParkingEventCount` | `COUNT_BIG(*)` |
| `IllegalEventCount` | đếm `IsLegalParking = 0` |
| `AvgDurationMin` | `AVG(ParkingDurationMin)` |
| `OpenEventCount` | `SUM(IsOpenEvent)` |

Chỉ những tổ hợp thật sự xuất hiện mới được tạo, nên kết quả là `513`, không phải phép nhân đầy đủ 7 × 20 × 4.

## 5. SSMS — tạo stored procedure

SQL đã chuẩn bị tại:

[`../../sql/24_transform_aggregates.sql`](../../sql/24_transform_aggregates.sql)

### 5.1. Chạy file SQL

1. Mở `sql/24_transform_aggregates.sql` trong VS Code.
2. Nhấn `Ctrl+A`, rồi `Ctrl+C`.
3. Mở SSMS → **New Query**.
4. Dán toàn bộ file.
5. Nhấn `F5`.

Expected:

```text
Commands completed successfully.
```

Chạy file này chỉ tạo/cập nhật procedure; chưa tạo aggregate cho đến khi procedure được gọi.

### 5.2. Kiểm tra procedure bắt buộc

Chạy:

```sql
USE DanangSmartParkingSTG;
GO

SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ProcedureName
FROM sys.procedures
WHERE name = N'usp_TransformAggregates';
```

Expected:

```text
dbo | usp_TransformAggregates
```

Hoặc kiểm tra Object Explorer:

```text
DanangSmartParkingSTG
└── Programmability
    └── Stored Procedures
        └── dbo.usp_TransformAggregates
```

Nếu chưa thấy, nhấp phải **Stored Procedures → Refresh**. Không tạo SSIS task trước khi query trên trả đúng một dòng.

## 6. SSIS — tạo package 22 nhanh

### 6.1. Cách nhanh: sao chép package 21

1. Trong **Solution Explorer**, mở `SSIS Packages`.
2. Nhấp phải `21_Transform_Events.dtsx` → **Copy**.
3. Nhấp phải `SSIS Packages` → **Paste**.
4. Nhấp phải package bản sao → **Rename**.
5. Đặt tên:

```text
22_Transform_Aggregates.dtsx
```

6. Mở package mới và nhấn `Ctrl+S`.

Bản sao đã có sẵn:

- package parameter `pLoadBatchKey` kiểu `Int64`;
- hai project Connection Manager;
- một Execute SQL Task và Parameter Mapping `LONG`.

Chỉ chỉnh tên task và SQLStatement ở mục 7.

### 6.2. Nếu không copy được package

1. Nhấp phải `SSIS Packages` → **New SSIS Package**.
2. Đổi tên thành `22_Transform_Aggregates.dtsx`.
3. Mở tab **Parameters**.
4. Tạo:

| Name | Data type | Value | Required |
|---|---|---:|---|
| `pLoadBatchKey` | `Int64` | `0` | `True` |

5. Quay về **Control Flow**.
6. Kéo một **Execute SQL Task** từ SSIS Toolbox vào canvas.

### 6.3. Kiểm tra Connection Manager

Ở cuối package phải nhìn thấy:

```text
(project) CM_DanangDW
(project) CM_DanangSTG
```

Thấy cả hai là đúng; không xóa cái nào. Task package 22 phải chọn `(project) CM_DanangSTG` vì procedure và bảng aggregate nằm trong `DanangSmartParkingSTG`.

## 7. SSIS — cấu hình Execute SQL Task

### 7.1. Đổi tên task

1. Mở tab **Control Flow**.
2. Chọn task đã copy hoặc task mới.
3. Nhấn `F2` hoặc nhấp phải → **Rename**.
4. Đặt tên:

```text
SQL - Transform Aggregates
```

Control Flow chỉ có một task này.

### 7.2. Cấu hình General

1. Nhấp đúp task.
2. Chọn trang **General**.
3. Cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Transform Aggregates` |
| ResultSet | `None` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangSTG` |
| SQLSourceType | `Direct input` |
| BypassPrepare | `True` |

4. Tại `SQLStatement`, bấm `...`.
5. Xóa SQL cũ của package 21 và dán:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC dbo.usp_TransformAggregates
    @LoadBatchKey = @LoadBatchKey;
```

6. Bấm **OK**.

Dấu `?` là positional parameter của OLE DB. Không thay bằng `$Package::pLoadBatchKey` trong SQLStatement.

### 7.3. Kiểm tra Parameter Mapping

Mở **Parameter Mapping**. Phải có đúng một dòng:

| Cột | Giá trị |
|---|---|
| Variable Name | `$Package::pLoadBatchKey` |
| Direction | `Input` |
| Data Type | `LONG` |
| Parameter Name | `0` |
| Parameter Size | `-1` |

Nếu copy package 21, chỉ cần kiểm tra lại. Nếu tạo task mới:

1. Bấm **Add** đúng một lần.
2. Điền các giá trị trên.
3. Bấm **OK**.
4. Nhấn `Ctrl+S`.

Giao diện OLE DB không có `I8`, `Int64` hoặc `bigint`, nên dùng `LONG`. SQLStatement đã ép `?` sang SQL Server `bigint`.

## 8. Debug package 22 độc lập

### 8.1. Gán batch key thật

1. Mở `22_Transform_Aggregates.dtsx`.
2. Chọn tab **Parameters**.
3. Tại `pLoadBatchKey`, nhập đúng số đã ghi ở mục 3, ví dụ:

```text
11
```

Không nhập `LoadBatchKey`, `@LoadBatchKey`, `'11'` hoặc `LoadBatchKey = 11`.

4. Nhấn `Enter`, rồi `Ctrl+S`.

### 8.2. Execute Package

1. Trong Solution Explorer, nhấp phải `22_Transform_Aggregates.dtsx`.
2. Chọn **Execute Package**.
3. Chờ task kết thúc.

Expected:

- `SQL - Transform Aggregates` có tick xanh.
- `Package execution completed successfully`.
- Không có dấu X đỏ.

Nếu task đỏ, mở **Progress/Execution Results** và đọc dòng lỗi đỏ đầu tiên. Không tự sửa `LoadStatus` trong SSMS.

## 9. SSMS — kiểm tra nhanh output

Sau khi package xanh, thay `11` bằng batch thật rồi chạy:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint = 11;

SELECT 'TrafficHourlySummary' AS ObjectName,
       COUNT_BIG(*) AS ActualRows, 4200 AS ExpectedRows
FROM transform.TrafficHourlySummary
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT 'ParkingDailySummary', COUNT_BIG(*), 513
FROM transform.ParkingDailySummary
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    SUM(VehicleVolume) AS VehicleVolume,
    SUM(IllegalParkingObserved) AS IllegalParkingObserved
FROM transform.TrafficHourlySummary
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    SUM(ParkingEventCount) AS ParkingEventCount,
    SUM(IllegalEventCount) AS IllegalEventCount,
    SUM(OpenEventCount) AS OpenEventCount
FROM transform.ParkingDailySummary
WHERE LoadBatchKey = @LoadBatchKey;
```

Expected:

```text
TrafficHourlySummary = 4200
ParkingDailySummary  = 513
VehicleVolume        = 6596879
IllegalParkingObserved = 9100
ParkingEventCount    = 4283
IllegalEventCount    = 1571
OpenEventCount       = 64
```

### 9.1. Xem detail do procedure trả về

Procedure chạy lại an toàn cho cùng batch:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint = 11;

EXEC dbo.usp_TransformAggregates
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;
```

Result Unicode cuối phải hiển thị:

```text
RD001 | Trần Phú | Hải Châu core | 1 | Trần Phú / Hải Châu core
```

## 10. Gắn package 22 vào `00_Master.dtsx`

Chỉ làm sau khi package 22 chạy độc lập thành công.

1. Mở `00_Master.dtsx` → **Control Flow**.
2. Copy task `PKG - Transform Events` rồi paste.
3. Đổi tên task bản sao:

```text
PKG - Transform Aggregates
```

4. Nhấp đúp task.
5. Chọn:
   - `ReferenceType`: `Project Reference`.
   - `PackageNameFromProjectReference`: `22_Transform_Aggregates.dtsx`.
6. Mở **Parameter Bindings**.
7. Xác nhận:

| Child package parameter | Parent package variable |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

8. Bấm **OK**.
9. Xóa connector cũ của bản sao nếu nối sai.
10. Nối mũi tên xanh:

```text
PKG - Transform Events
  → PKG - Transform Aggregates
```

Master tại checkpoint này:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
  → PKG - Validate Extract
  → PKG - Transform Master Data
  → PKG - Transform Events
  → PKG - Transform Aggregates

SQL - Complete Batch [Disabled]
```

### 10.1. Lưu project và chọn `00_Master.dtsx` làm Startup Object

1. Nhấn **Ctrl+Shift+S** hoặc chọn **File → Save All**.
2. Trong **Solution Explorer**, mở node **SSIS Packages**.
3. Nhấp phải `00_Master.dtsx`.
4. Chọn **Set as StartUp Object**.
5. Nhấp đúp `00_Master.dtsx` để mở package và chọn tab **Control Flow**.

Nếu menu không có **Set as StartUp Object**:

1. Đảm bảo bạn đang nhấp phải đúng file `00_Master.dtsx`, không nhấp vào tên
   project hoặc vùng trống.
2. Nhấp đúp mở `00_Master.dtsx` và để tab này là tab đang được chọn.
3. Khi chạy, kiểm tra trên thanh công cụ rằng package được khởi động là
   `00_Master.dtsx`, không phải `22_Transform_Aggregates.dtsx`.

### 10.2. Kiểm tra lần cuối trước khi chạy toàn bộ Master

Trong `00_Master.dtsx`, xác nhận:

- chuỗi task nối liên tục từ `SQL - Start Batch` đến
  `PKG - Transform Aggregates`;
- connector giữa các task đều là mũi tên xanh **Success**;
- task `PKG - Transform Aggregates` tham chiếu đúng
  `22_Transform_Aggregates.dtsx`;
- Parameter Binding của task là
  `pLoadBatchKey → User::LoadBatchKey`;
- `SQL - Complete Batch` vẫn **Disabled** ở checkpoint hiện tại;
- không có task nào khác ngoài `SQL - Complete Batch` đang bị Disabled.

### 10.3. Chạy toàn bộ luồng bằng `00_Master.dtsx`

1. Đóng các cửa sổ cấu hình task còn đang mở bằng **OK**.
2. Nhấn **Ctrl+Shift+S** để lưu lần cuối.
3. Chọn tab `00_Master.dtsx [Design]`.
4. Nhấn nút tam giác xanh **Start** trên thanh công cụ hoặc nhấn `F5`.
5. Chờ toàn bộ chuỗi chạy xong; không nhấn Start lần thứ hai khi package còn
   đang chạy.
6. Khi kết thúc, mở tab **Progress** hoặc **Execution Results** để xem kết quả.
7. Nếu Visual Studio vẫn ở chế độ debug, chọn **Debug → Stop Debugging** hoặc
   nhấn `Shift+F5` sau khi package đã kết thúc.

Lần chạy này sẽ tạo một `LoadBatchKey` mới rồi truyền cùng key đó qua tất cả
package con. Không nhập tay batch key cho từng package khi chạy từ Master.

Kết quả đúng:

- `SQL - Start Batch` màu xanh;
- các package Extract và Validate Extract màu xanh;
- `PKG - Transform Master Data` màu xanh;
- `PKG - Transform Events` màu xanh;
- `PKG - Transform Aggregates` màu xanh;
- dòng cuối hiển thị `Package execution completed successfully`;
- `SQL - Complete Batch` vẫn màu xám vì đang Disabled.

Nếu có task màu đỏ, chưa chạy validation package 22. Mở **Progress/Execution
Results**, tìm task đỏ đầu tiên và đọc thông báo lỗi đầu tiên của task đó. Một task
phía sau màu đỏ có thể chỉ là hậu quả của task phía trước thất bại.

#### 10.3.1. Lỗi `Failed to locate the specified package in the project`

Nếu output có chuỗi:

```text
Task failed: PKG - Transform Events
Failed to locate the specified package in the project.
DTS_W_MAXIMUMERRORCOUNTREACHED
```

thì `DTS_W_MAXIMUMERRORCOUNTREACHED` chỉ là cảnh báo tổng kết: lỗi gốc đã làm số
lỗi đạt `MaximumErrorCount = 1`. **Không tăng MaximumErrorCount** để che lỗi.

Sửa Project Reference như sau:

1. Nhấn `Shift+F5` để chắc chắn đã thoát debug.
2. Trong **Solution Explorer → SSIS Packages**, xác nhận có đúng file:

   ```text
   21_Transform_Events.dtsx
   ```

3. Nếu không có file đó:
   - tìm package 21 đang mang tên khác và đổi đúng tên; hoặc
   - nhấp phải **SSIS Packages → Add Existing Package/Add Existing Item** rồi
     thêm `21_Transform_Events.dtsx` vào project.
4. Mở `00_Master.dtsx` → **Control Flow**.
5. Nhấp đúp task `PKG - Transform Events`.
6. Trong **Package**, cấu hình lại bằng cách chọn từ dropdown, không gõ phỏng
   đoán:
   - `ReferenceType`: `Project Reference`;
   - `PackageNameFromProjectReference`: `21_Transform_Events.dtsx`.
7. Mở **Parameter Bindings** và xác nhận:

   | Child parameter | Parent variable |
   |---|---|
   | `pLoadBatchKey` | `User::LoadBatchKey` |

8. Bấm **OK** và nhấn `Ctrl+Shift+S` (**Save All**).
9. Nhấp phải project `DanangSmartParkingETL` → **Rebuild**.
10. Kiểm tra **Error List**: phải không còn lỗi validation.
11. Đặt lại `00_Master.dtsx` làm Startup Object và nhấn `F5`.

Nếu dropdown `PackageNameFromProjectReference` không liệt kê package 21 dù file
đang hiện trong Solution Explorer:

1. đóng task editor bằng **Cancel**;
2. nhấp phải package 21 và kiểm tra package không bị **Excluded From Project**;
3. `Save All` và đóng/mở lại solution;
4. nếu reference vẫn hỏng, xóa riêng task `PKG - Transform Events` rồi kéo một
   **Execute Package Task mới** từ SSIS Toolbox; không copy task cũ vì bản copy
   có thể mang theo project reference cũ;
5. tạo lại Parameter Binding và connector xanh từ package 20 sang package 21.

##### Dropdown đã đúng nhưng runtime vẫn báo `Failed to locate`

Trường hợp này thường xuất hiện sau khi package 21 bị đổi tên trong lúc solution
đang mở. Designer đã hiện tên mới nhưng metadata của task hoặc project sinh trong
`obj/bin` vẫn có thể giữ reference cũ.

Thực hiện đúng thứ tự sau:

1. Nhấn `Shift+F5` để thoát debug hoàn toàn.
2. Trong **Execute Package Task Editor**, mở trang **Expressions**:
   - bảo đảm không có expression cho `PackageNameFromProjectReference`;
   - nếu có, xóa dòng đó vì expression sẽ ghi đè package đã chọn ở trang
     **Package** khi chạy.
3. Quay lại **Package**, chọn `21_Transform_Events.dtsx`, rồi bấm **OK**.
   Chỉ chọn trong dropdown nhưng chưa bấm **OK** thì thay đổi chưa được ghi vào
   `00_Master.dtsx`.
4. Kiểm tra tab `00_Master.dtsx [Design]*` có dấu `*`, nhấn `Ctrl+S` và xác nhận
   dấu `*` biến mất.
5. Xóa riêng control-flow task `PKG - Transform Events` trong Master. Không xóa
   file `21_Transform_Events.dtsx` trong Solution Explorer.
6. Kéo một **Execute Package Task mới hoàn toàn** từ SSIS Toolbox vào Master và
   cấu hình:
   - `Name`: `PKG - Transform Events`;
   - `ReferenceType`: `Project Reference`;
   - `PackageNameFromProjectReference`: `21_Transform_Events.dtsx`;
   - Parameter Binding `pLoadBatchKey`: `User::LoadBatchKey`.
7. Nối lại các mũi tên xanh:

   ```text
   PKG - Transform Master Data
      -> PKG - Transform Events
      -> PKG - Transform Aggregates
   ```

8. Nhấn `Ctrl+Shift+S`. Project SSIS SQL Server 2019 có thể không hiển thị
   **Clean Solution**; trường hợp đó bỏ qua Clean và thực hiện xóa `bin/obj` ở
   bước dưới.
9. Đóng Visual Studio hoàn toàn.
10. Trong File Explorer, mở thư mục project:

    ```text
    C:\Users\Administrator\Desktop\DE_PROJECT\DanangSmartParkingETL
    ```

11. Chỉ xóa hai thư mục sinh tự động `bin` và `obj` nếu có. Không xóa file
    `.dtsx`, `.dtproj` hoặc `.sln`.
12. Mở lại solution, chọn **Build → Rebuild Solution** và kiểm tra build không
    còn lỗi.
13. Đặt `00_Master.dtsx` làm **Startup Object** rồi nhấn `F5`.

Nếu đã tạo task mới và xóa cache mà vẫn lỗi, kiểm tra project manifest trước khi
chạy tiếp:

1. Đóng Visual Studio.
2. Mở `DanangSmartParkingETL.dtproj` bằng Notepad và tìm
   `21_Transform_Events.dtsx`.
3. Tên hiện tại phải xuất hiện đúng một lần dưới dạng package item; tên package
   cũ không được còn trong project file.
4. Chưa sửa XML bằng tay. Chụp lại kết quả tìm kiếm để chẩn đoán; package item
   sai nên được sửa bằng thao tác remove/re-add trong Solution Explorer.

##### Phương án cuối: xóa và tạo lại package 21–22

Xóa hai file thiết kế SSIS không xóa stored procedure hay dữ liệu trong SQL
Server. Hai procedure hiện tại cũng hỗ trợ chạy lặp an toàn theo batch:

- package 21 chỉ thay thế ba bảng event Clean và audit `TRN_*` của đúng
  `LoadBatchKey` được truyền vào;
- package 22 chỉ thay thế hai bảng Summary của đúng `LoadBatchKey` đó;
- RAW, master Clean và dữ liệu của batch khác không bị xóa.

Thực hiện như sau:

1. Nhấn `Shift+F5`, rồi `Ctrl+Shift+S`.
2. Trong `00_Master.dtsx`, xóa riêng hai control-flow task:
   - `PKG - Transform Events`;
   - `PKG - Transform Aggregates`.
3. Trong File Explorer, sao lưu hai file `.dtsx` hiện tại sang một thư mục
   backup ngoài project.
4. Trong **Solution Explorer → SSIS Packages**, xóa package
   `21_Transform_Events.dtsx` và `22_Transform_Aggregates.dtsx` khỏi project.
   Đây chỉ là file thiết kế; không chạy câu lệnh SQL nào ở bước này.
5. Nhấn `Ctrl+Shift+S`, đóng Visual Studio, xóa `bin` và `obj` nếu có, rồi mở
   lại solution.
6. Nhấp phải **SSIS Packages → New SSIS Package** hai lần và đổi đúng tên:

   ```text
   21_Transform_Events.dtsx
   22_Transform_Aggregates.dtsx
   ```

   Nếu đổi tên báo `HRESULT E_FAIL`, không thử rename liên tục. Đây thường là
   dấu hiệu file cùng tên vẫn còn trong thư mục project:

   1. bấm **OK**, nhấn `Esc` để hủy ô rename rồi đóng Visual Studio;
   2. mở
      `C:\Users\Administrator\Desktop\DE_PROJECT\DanangSmartParkingETL`;
   3. tìm file vật lý `21_Transform_Events.dtsx` hoặc
      `22_Transform_Aggregates.dtsx` đang gây trùng tên;
   4. chuyển file cũ sang thư mục backup **nằm ngoài thư mục project**; không
      ghi đè và không xóa database;
   5. mở lại solution rồi đổi tên package mới;
   6. nếu không cần giữ tên chuẩn, có thể dùng tên mới như
      `22_Transform_Aggregates_v2.dtsx`, nhưng task trong Master phải chọn đúng
      chính tên này từ dropdown.

   Nếu File Explorer xác nhận **không còn** file đích nhưng Visual Studio vẫn
   báo `HRESULT E_FAIL`, dùng cách bỏ qua chức năng Rename của Visual Studio:

   1. đóng Visual Studio hoàn toàn;
   2. trong File Explorer bật **View → File name extensions**;
   3. đổi tên file package mới, ví dụ `Package1.dtsx`, thành
      `22_Transform_Aggregates_v2.dtsx` ngay trong File Explorer;
   4. mở lại solution; item `Package1.dtsx` trong Solution Explorer có thể bị
      missing vì project vẫn giữ tên cũ;
   5. nhấp phải item `Package1.dtsx` → **Remove**. Không chọn xóa file
      `22_Transform_Aggregates_v2.dtsx` vừa đổi tên;
   6. nhấp phải **SSIS Packages → Add Existing Package/Add Existing Item** và
      thêm file `22_Transform_Aggregates_v2.dtsx` từ thư mục project;
   7. `Save All`, **Rebuild Solution**, rồi chọn đúng tên `_v2` trong Execute
      Package Task của Master.

7. Trong mỗi package tạo package parameter:

   | Name | Data type | Required | Value test |
   |---|---|---:|---:|
   | `pLoadBatchKey` | `Int64` | `True` | `0` |

8. Package 21: kéo một **Execute SQL Task**, đặt tên
   `SQL - Transform Events`, dùng `(project) CM_DanangSTG`, `ResultSet = None`
   và SQL:

   ```sql
   DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

   EXEC dbo.usp_TransformAggregates
      @LoadBatchKey = @LoadBatchKey;
   ```

9. Parameter Mapping package 21:

   | Variable Name | Direction | Data Type | Parameter Name | Size |
   |---|---|---|---:|---:|
   | `$Package::pLoadBatchKey` | Input | `LONG` | `0` | `-1` |

10. Package 22: tạo `SQL - Transform Aggregates` tương tự với SQL:

    ```sql
      DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

      EXEC dbo.usp_TransformAggregates
         @LoadBatchKey = @LoadBatchKey;
    ```

    Parameter Mapping cũng là `$Package::pLoadBatchKey`, `Input`, `LONG`, `0`,
    `-1`.
11. Trong Master, kéo **hai Execute Package Task mới**, chọn package 21 và 22
    từ dropdown Project Reference. Với cả hai task, bind:

    ```text
    pLoadBatchKey → User::LoadBatchKey
    ```

12. Nối lại connector xanh `package 20 → package 21 → package 22`, lưu và chọn
    **Build → Rebuild Solution**.
13. Trước khi chạy Master, có thể kiểm thử riêng từng package với một batch
    `BRONZE_LOADED`. Không nhập chữ `LoadBatchKey`; phải nhập giá trị số thật.

Kiểm tra batch dùng để test trên SSMS:

```sql
SELECT TOP (10)
    LoadBatchKey, LoadStatus, ErrorMessage
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

- Nếu status là `BRONZE_LOADED`, có thể dùng key đó để chạy riêng package 21 rồi
  package 22. Việc chạy lại không tạo dòng trùng vì procedure xóa/nạp lại đúng
  batch.
- Nếu status là `FAILED`, không sửa status bằng tay. Chạy lại Master từ đầu để
  tạo một batch mới hoặc chọn một batch `BRONZE_LOADED` khác để kiểm thử.
- Khi chạy Master từ đầu, một `LoadBatchKey` mới được tạo; dữ liệu batch cũ vẫn
  còn để audit cho tới bước cleanup. Đây không phải dữ liệu trùng trong cùng
  batch.

##### Kiểm thử riêng package mới với batch `BRONZE_LOADED`

Ví dụ truy vấn trên trả về batch mới nhất là `16 / BRONZE_LOADED`:

1. Trên SSMS, xác nhận batch 16 có đủ đầu vào cho package 21:

   ```sql
   DECLARE @LoadBatchKey bigint = 16;

   SELECT 'TrafficEventRaw' AS ObjectName, COUNT_BIG(*) AS ActualRows, 16884 AS ExpectedRows
   FROM DanangSmartParkingSTG.extract.TrafficEventRaw WHERE LoadBatchKey = @LoadBatchKey
   UNION ALL
   SELECT 'ParkingEventRaw', COUNT_BIG(*), 4300
   FROM DanangSmartParkingSTG.extract.ParkingEventRaw WHERE LoadBatchKey = @LoadBatchKey
   UNION ALL
   SELECT 'WeatherEventRaw', COUNT_BIG(*), 168
   FROM DanangSmartParkingSTG.extract.WeatherEventRaw WHERE LoadBatchKey = @LoadBatchKey
   UNION ALL
   SELECT 'RoadClean', COUNT_BIG(*), 30
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

2. Chỉ tiếp tục nếu sáu dòng đều có `ActualRows = ExpectedRows`.
3. Mở package `21_Transform_Events.dtsx` → tab **Parameters** → nhập giá trị số
   `16` vào cột **Value** của `pLoadBatchKey`.
4. Nhấp phải package 21 trong Solution Explorer → **Set as Startup Object** →
   nhấn `F5`.
5. Package 21 phải xanh và kết thúc `Package execution completed successfully`.
6. Chạy toàn bộ `sql/23_validate_transform_events.sql`; kết quả cuối phải là
   `PASS`, `LoadBatchKey = 16`.
7. Mở package 22 (kể cả khi file đang tên `Package1.dtsx` hoặc `_v2`) → tab
   **Parameters** → đặt `pLoadBatchKey = 16`.
8. Đặt package 22 làm **Startup Object** rồi nhấn `F5`.
9. Package 22 phải xanh. Chạy `sql/24_validate_transform_aggregates.sql`; kết
   quả đầu phải là `PASS`, `LoadBatchKey = 16`.
10. Sau khi hai package chạy riêng đều PASS, đặt Value của `pLoadBatchKey` trong
    hai package về `0`. Master sẽ truyền key thật qua Parameter Binding.
11. Khi đó mới tạo/chọn lại hai Execute Package Task trong Master, bind
    `pLoadBatchKey → User::LoadBatchKey`, Rebuild và chạy toàn luồng.

#### 10.3.2. Phân biệt package đang chạy với Break/Pause mode

Nếu nút **Pause** đang sáng còn **Continue** bị mờ, SSIS vẫn đang chạy; riêng
dấu hiệu đó không phải breakpoint. Hãy chờ kết quả hoặc xem
**Progress/Execution Results**.

Chỉ xử lý theo hướng Break/Pause mode khi Visual Studio có các dấu hiệu sau:

- nút **Continue** sáng và có thể bấm;
- có process `DtsDebugHost.exe`;
- cửa sổ **Autos**, **Locals** hoặc **Call Stack** tự mở;
- package 21 đứng yên nhưng chưa hiện dấu X đỏ;

thì SSIS đang ở **Break/Pause mode**, không phải stored procedure bị treo.

Xử lý ngay:

1. Không bấm Start thêm lần nữa.
2. Nhấn nút tam giác **Continue** hoặc nhấn `F5` một lần.
3. Chờ package chạy tiếp.
4. Nếu nó lại dừng đúng package 21, nhấn `Shift+F5` để **Stop Debugging**.
5. Trong `21_Transform_Events.dtsx`, nhấp phải task
   `SQL - Transform Events` → **Edit Breakpoints**.
6. Bỏ chọn toàn bộ breakpoint, đặc biệt `OnPreExecute`, `OnPostExecute` và
   `OnTaskFailed`, rồi bấm **OK**.
7. Mở **Debug → Windows → Breakpoints** hoặc nhấn `Ctrl+Alt+B`.
8. Chọn **Delete All Breakpoints** nếu cửa sổ còn breakpoint khác.
9. `Save All`, chọn lại `00_Master.dtsx` làm Startup Object và nhấn `F5`.

Chỉ kiểm tra SQL blocking nếu task `SQL - Transform Events` thực sự đang chạy
liên tục, Visual Studio không ở Break mode và thanh công cụ không hiện
**Continue**. Khi đó mở một cửa sổ SSMS mới và chạy:

```sql
SELECT
    r.session_id,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time,
    r.blocking_session_id,
    DB_NAME(r.database_id) AS DatabaseName,
    t.text AS RunningSql
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.database_id IN
(
    DB_ID(N'DanangSmartParkingSTG'),
    DB_ID(N'DanangSmartParkingDW')
)
ORDER BY r.session_id;
```

- `blocking_session_id = 0`: không bị session khác khóa.
- `blocking_session_id > 0`: ghi lại cả `session_id`, `blocking_session_id` và
  `wait_type`; không dùng `KILL` trước khi xác định session nào đang giữ lock.

### 10.4. Xác nhận đúng batch vừa chạy trên SSMS

Sau khi Master chạy xanh, mở SSMS và chạy:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage,
    StartedAt,
    CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Ở checkpoint package 22:

- `LoadStatus` dự kiến là `BRONZE_LOADED`;
- `RowsRejected = 0`;
- `ErrorMessage = NULL`;
- `CompletedAt = NULL`, vì bước Complete Batch vẫn chưa được bật;
- ghi lại `LoadBatchKey` để đối chiếu nếu cần.

## 11. Nghiệm thu tự động package 22

Script read-only:

[`../../sql/24_validate_transform_aggregates.sql`](../../sql/24_validate_transform_aggregates.sql)

### 11.1. Chọn batch cần nghiệm thu

Đầu script có:

```sql
DECLARE @RequestedLoadBatchKey bigint = NULL;
```

- Giữ `NULL`: kiểm tra batch mới nhất.
- Hoặc đổi thành số package vừa chạy, ví dụ `11`, để chắc chắn kiểm tra đúng batch:

```sql
DECLARE @RequestedLoadBatchKey bigint = 11;
```

Chỉ nhập số, không nhập chữ `LoadBatchKey`.

### 11.2. Chạy validation

1. Copy toàn bộ `sql/24_validate_transform_aggregates.sql`.
2. Mở SSMS → **New Query**.
3. Dán toàn bộ và nhấn `F5`.
4. Xem result set đầu tiên.

Kết quả đạt:

```text
AcceptanceStatus | LoadBatchKey | Message
PASS             | <batch key> | PACKAGE 22 ACCEPTED - ready for package 23
```

Script tự kiểm tra:

- procedure tồn tại;
- batch vẫn `BRONZE_LOADED` và không có ErrorMessage;
- package 21 có đúng `16.800/4.283` input event;
- aggregate đúng `4.200/513` dòng;
- không thiếu hoặc thừa bất kỳ group nào;
- toàn bộ measure từng group bằng kết quả tính lại từ Clean;
- Traffic tổng `6.596.879` vehicle và `9.100` illegal observation;
- Parking tổng `4.283` event, `1.571` illegal và `64` open;
- coverage Traffic `7 ngày/24 giờ/25 đường`;
- coverage Parking `7 ngày/20 đường/4 loại xe`;
- Unicode `Trần Phú / Hải Châu core` đúng.

Nếu thất bại, result đầu là `FAIL`; result kế tiếp có:

```text
CheckName | ActualValue | ExpectedValue
```

`Procedure exists = NOT FOUND` nghĩa là bạn chưa chạy toàn bộ `sql/24_transform_aggregates.sql`. Aggregate bằng `0` nghĩa là package 22 chưa chạy hoặc đang dùng sai batch key.

## 12. Tiêu chí hoàn thành

- `dbo.usp_TransformAggregates` tồn tại trong `DanangSmartParkingSTG`.
- Package 22 chỉ có một Execute SQL Task.
- Task dùng `(project) CM_DanangSTG`.
- SQLStatement có `CONVERT(bigint, ?)`.
- Parameter Mapping dùng `LONG`, ordinal `0`.
- Debug package xanh.
- `TrafficHourlySummary = 4.200`.
- `ParkingDailySummary = 513`.
- Script nghiệm thu trả `PASS`.
- Package 22 đã nối sau package 21 trong Master.
- `SQL - Complete Batch` vẫn disabled.

## 13. Bước tiếp theo

Sau khi package 22 trả `PASS`, chuyển sang:

[`23_VALIDATE_TRANSFORM.md`](23_VALIDATE_TRANSFORM.md)

Package 23 sẽ kiểm tra toàn bộ master/event/aggregate và chỉ khi đạt mới đổi batch sang `SILVER_VALIDATED`.
