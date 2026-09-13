# 23 — Validate toàn bộ Transform và đóng cổng Silver

## 1. Mục tiêu và output

Package SSIS cần tạo:

```text
23_Validate_Transform.dtsx
```

Package này **không clean và không tổng hợp lại dữ liệu**. Nó là cổng kiểm soát
cuối tầng Transform:

```text
20 Transform Master Data
        ↓
21 Transform Events
        ↓
22 Transform Aggregates
        ↓
23 Validate Transform
        ├─ sai: THROW, batch vẫn BRONZE_LOADED, không Load Dimension
        └─ đúng: batch → SILVER_VALIDATED
```

Output cần đạt:

- tất cả kiểm tra Transform trả `IsMatched = 1`;
- batch hiện tại đổi từ `BRONZE_LOADED` thành `SILVER_VALIDATED`;
- `ErrorMessage = NULL`;
- `CompletedAt` vẫn `NULL`, vì ETL chưa Load Dimension, Fact và chưa Complete;
- sẵn sàng chuyển sang [`30_DATA_FLOW_DIMENSIONS.md`](30_DATA_FLOW_DIMENSIONS.md).

Package 23 chỉ cần **một Execute SQL Task**. Không dùng Data Flow Task ở bước
này vì dữ liệu không được di chuyển; SQL chỉ đối soát và cập nhật trạng thái
điều khiển.

---

## 2. Checkpoint bắt buộc trước khi làm

Package 20, 21 và 22 phải chạy thành công trên **cùng một `LoadBatchKey`**.

Theo checkpoint gần nhất của project, batch mới nhất là:

```text
LoadBatchKey = 16
LoadStatus   = BRONZE_LOADED
ErrorMessage = NULL
```

Không nhập cứng số `16` vào thiết kế dùng lâu dài. Đây chỉ là số dùng để debug
độc lập ở checkpoint hiện tại; mỗi lần chạy `00_Master.dtsx` sẽ sinh batch mới.

### 2.1. Các bảng đầu vào phải có

| Nhóm | Bảng | Số dòng expected |
|---|---|---:|
| Master | `transform.RoadClean` | 30 |
| Master | `transform.ParkingFacilityClean` | 20 |
| Master | `transform.ParkingRestrictionClean` | 18 |
| Master | `transform.POIClean` | 50 |
| Master | `transform.RoadSurveyClean` | 30 |
| Event | `transform.TrafficObservationClean` | 16.800 |
| Event | `transform.ParkingEventClean` | 4.283 |
| Event | `transform.WeatherHourlyClean` | 168 |
| Aggregate | `transform.TrafficHourlySummary` | 4.200 |
| Aggregate | `transform.ParkingDailySummary` | 513 |

### 2.2. Kiểm tra nhanh batch trên SSMS

Mở SSMS → **New Query**, dán và chạy **toàn bộ** đoạn sau:

```sql
USE DanangSmartParkingDW;
GO

SELECT TOP (10)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage,
    CompletedAt
FROM etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Chỉ tiếp tục nếu dòng mới nhất có:

```text
LoadStatus    = BRONZE_LOADED
RowsRead      = 21500
RowsAccepted  = 21500
RowsRejected  = 0
ErrorMessage  = NULL
```

Nếu package 20, 21 hoặc 22 chưa đạt `PASS`, quay lại nghiệm thu package tương
ứng. Không tự `UPDATE` trạng thái batch để bỏ qua kiểm tra.

---

## 3. Package 23 kiểm tra những gì?

Script tổng hợp không chỉ đếm số dòng. Nó kiểm tra:

1. trạng thái và audit của batch;
2. row count, `IsValid` và `DuplicateRank` của 8 bảng Clean;
3. mỗi dòng Clean truy vết được về đúng dòng RAW;
4. hash của các bản ghi Transform;
5. business key không còn trùng sau dedup;
6. capacity, reference capacity và 3 road width đã nội suy;
7. KPI Traffic, Parking và Weather;
8. 84 duplicate Traffic và 17 duplicate Parking có audit cảnh báo;
9. liên kết Event → Road/Segment/Weather/Restriction không bị orphan;
10. tính lại từng nhóm aggregate rồi so sánh hai chiều bằng `EXCEPT`;
11. Unicode còn đúng: `Trần Phú / Hải Châu core`.

### 3.1. Vì sao dữ liệu Clean vẫn có `NULL`?

`Clean` nghĩa là giá trị đã được parse, kiểm tra và gắn quy tắc chất lượng; không
có nghĩa mọi cột bắt buộc khác `NULL`.

Các ngoại lệ đã biết và được package 23 kiểm tra:

| Dữ liệu | Ý nghĩa | Cách xử lý |
|---|---|---|
| 161 `AvgSpeedKmh = NULL` | nguồn thiếu tốc độ | giữ `NULL`, `SpeedMissingFlag=1`; `AVG` tự bỏ qua `NULL` |
| 3.838 dòng vehicle mix lệch | tổng thành phần xe không khớp tuyệt đối | giữ dòng, `VehicleMixValidFlag=0` |
| 781 parking count lệch | count đỗ xe không hoàn toàn nhất quán | giữ dòng, `ParkingCountValidFlag=0` |
| 64 parking event chưa đóng | thiếu thời điểm kết thúc | dùng duration ước tính/last-known, gắn hai cờ open/estimated |
| 607 illegal event thiếu restriction link | nguồn không cung cấp liên kết restriction | giữ sự kiện, `RestrictionLinkMissingFlag=1` |

Không thay `NULL` speed bằng `0`: `0 km/h` là xe đứng yên, còn `NULL` là không có
phép đo. Hai ý nghĩa này khác nhau.

---

## 4. Cài bộ SQL của package 23 trên SSMS

File cần chạy:

```text
sql/25_validate_transform_and_mark_silver.sql
```

Script tạo hai stored procedure:

| Database | Stored procedure | Chức năng |
|---|---|---|
| `DanangSmartParkingSTG` | `dbo.usp_ValidateTransformBatch` | read-only, kiểm tra toàn bộ Transform |
| `DanangSmartParkingDW` | `etl.usp_ValidateTransformAndMarkSilver` | gọi validator rồi đổi batch sang Silver |

### 4.1. Chạy script tạo procedure

1. Mở file [`../../sql/25_validate_transform_and_mark_silver.sql`](../../sql/25_validate_transform_and_mark_silver.sql).
2. Copy **toàn bộ nội dung file**.
3. Trong SSMS chọn **New Query**.
4. Dropdown database có thể chọn `DanangSmartParkingDW`; script đã có các câu
   `USE` nên sẽ tự chuyển đúng database.
5. Dán toàn bộ script.
6. Nhấn `Ctrl+A` để chắc chắn chọn toàn bộ.
7. Nhấn **Execute** hoặc `F5`.

Expected ở tab **Messages**:

```text
Commands completed successfully.
```

### 4.2. Refresh và kiểm tra object

Trong Object Explorer:

1. Mở `Databases → DanangSmartParkingSTG → Programmability`.
2. Nhấp phải **Stored Procedures** → **Refresh**.
3. Phải thấy `dbo.usp_ValidateTransformBatch`.
4. Mở `Databases → DanangSmartParkingDW → Programmability`.
5. Nhấp phải **Stored Procedures** → **Refresh**.
6. Phải thấy `etl.usp_ValidateTransformAndMarkSilver`.

Có thể kiểm tra bằng SQL đầy đủ sau:

```sql
SELECT
    OBJECT_ID(N'DanangSmartParkingSTG.dbo.usp_ValidateTransformBatch')
        AS ReadOnlyValidatorObjectID,
    OBJECT_ID(N'DanangSmartParkingDW.etl.usp_ValidateTransformAndMarkSilver')
        AS SilverGateObjectID;
```

Hai cột `ObjectID` phải là số, không được `NULL`.

---

## 5. Preflight read-only trên SSMS

Bước này kiểm tra toàn bộ Transform nhưng **chưa đổi trạng thái batch**.

1. Trong SSMS chọn **New Query**.
2. Copy và chạy **toàn bộ** đoạn dưới đây, từ `USE` đến `EXEC`:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    WHERE LoadStatus = 'BRONZE_LOADED'
    ORDER BY LoadBatchKey DESC
);

SELECT @LoadBatchKey AS BatchBeingValidated;

EXEC dbo.usp_ValidateTransformBatch
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 1;
```

Expected:

- `BatchBeingValidated = 16` tại checkpoint hiện tại;
- tất cả dòng kết quả có `IsMatched = 1`;
- không có thông báo `TRANSFORM VALIDATION FAILED`;
- batch vẫn là `BRONZE_LOADED` vì đây là kiểm tra read-only.

Nếu có `IsMatched = 0`, tên `CheckName` cho biết chính xác nhóm lỗi. Dừng tại
đây, không tạo Silver giả bằng câu `UPDATE`.

---

## 6. Tạo `23_Validate_Transform.dtsx` trên SSIS

### 6.1. Dừng Debug trước khi sửa package

Nếu Visual Studio đang chạy package:

1. Chọn menu **Debug → Stop Debugging**; hoặc nhấn `Shift+F5`.
2. Chờ thanh công cụ trở lại trạng thái thiết kế.

### 6.2. Tạo package mới

1. Trong **Solution Explorer**, tìm project `DanangSmartParkingETL`.
2. Nhấp phải thư mục **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Một package như `Package1.dtsx` xuất hiện.
5. Nhấp phải package đó → **Rename**, hoặc chọn nó rồi nhấn `F2`.
6. Đổi chính xác thành:

   ```text
   23_Validate_Transform.dtsx
   ```

7. Nhấp đúp để mở package.
8. Bấm vào vùng trống của tab **Control Flow**, nhấn `F4` mở Properties.
9. Đặt thuộc tính `Name` của package là:

   ```text
   P23_Validate_Transform
   ```

Không đổi tên file package sau khi đã gắn vào `00_Master.dtsx`; việc đổi tên dễ
làm Execute Package Task giữ project reference cũ.

### 6.3. Tạo package parameter

1. Trong package, mở tab **Parameters** ở phía trên designer.
2. Nhấn nút **Add Parameter**.
3. Điền đúng:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |

`0` chỉ là default an toàn. Khi chạy độc lập ta nhập một **con số batch thật**;
khi chạy từ Master, parent sẽ truyền `User::LoadBatchKey` vào parameter này.

### 6.4. Kiểm tra Connection Manager dùng chung

Ở đáy package phải thấy:

```text
(project) CM_DanangDW
(project) CM_DanangSTG
```

Task package 23 sẽ dùng `(project) CM_DanangDW`, vì procedure đóng cổng Silver
nằm tại `DanangSmartParkingDW.etl`.

Để Test Connection:

1. Trong Solution Explorer mở **Connection Managers**.
2. Nhấp đúp `CM_DanangDW.conmgr`.
3. Kiểm tra database là `DanangSmartParkingDW`.
4. Nhấn **Test Connection**.
5. Phải nhận `Test connection succeeded`.
6. Nhấn **OK**.

---

## 7. Tạo một Execute SQL Task

### 7.1. Kéo task vào Control Flow

1. Quay lại tab **Control Flow** của `23_Validate_Transform.dtsx`.
2. Trong **SSIS Toolbox**, tìm **Execute SQL Task**.
3. Kéo nó vào vùng thiết kế.
4. Nhấp phải task → **Rename**.
5. Đặt tên:

   ```text
   SQL - Validate Transform and Mark Silver
   ```

### 7.2. Cấu hình tab General

Nhấp đúp task và điền:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Validate Transform and Mark Silver` |
| ResultSet | `None` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| BypassPrepare | `True` |

Nhấn nút `...` ở `SQLStatement`, dán **toàn bộ** câu sau:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC etl.usp_ValidateTransformAndMarkSilver
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 0;
```

Không chỉ dán riêng dòng `EXEC`. Dấu `?` là positional parameter của OLE DB và
cần câu `CONVERT(bigint, ?)` ở trên.

### 7.3. Cấu hình Parameter Mapping

Trong **Execute SQL Task Editor**:

1. Chọn **Parameter Mapping** ở cột trái.
2. Nhấn **Add**.
3. Điền đúng một dòng:

| Cột | Giá trị |
|---|---|
| Variable Name | `$Package::pLoadBatchKey` |
| Direction | `Input` |
| Data Type | `LONG` |
| Parameter Name | `0` |
| Parameter Size | `-1` |

UI OLE DB không hiện `BIGINT` hoặc `Int64` trong danh sách này. Với project hiện
tại chọn `LONG`; câu SQL sẽ `CONVERT` nó sang `bigint`.

Không nhập `NewParameterName` và không nhập `@LoadBatchKey` vào cột Parameter
Name. OLE DB dùng ordinal nên phải là số `0`.

### 7.4. Các tab còn lại

- **Result Set**: để trống vì `ResultSet = None`.
- **Expressions**: để trống.

Nhấn **OK**, sau đó nhấn `Ctrl+Shift+S` để **Save All**.

Control Flow hoàn chỉnh chỉ có:

```text
[SQL - Validate Transform and Mark Silver]
```

---

## 8. Debug package 23 độc lập

### 8.1. Lấy batch key thật

Trong SSMS chạy toàn bộ:

```sql
USE DanangSmartParkingDW;
GO

SELECT TOP (1)
    LoadBatchKey,
    LoadStatus,
    ErrorMessage
FROM etl.LoadBatch
WHERE LoadStatus = 'BRONZE_LOADED'
ORDER BY LoadBatchKey DESC;
```

Checkpoint hiện tại expected là `16`. Hãy dùng đúng số SSMS trả về nếu khác.

### 8.2. Gán giá trị để debug riêng

1. Mở `23_Validate_Transform.dtsx`.
2. Chọn tab **Parameters**.
3. Tại parameter `pLoadBatchKey`, cột **Value**, nhập số batch thật, ví dụ:

   ```text
   16
   ```

4. Không nhập chữ `LoadBatchKey`, không nhập `@LoadBatchKey`, không nhập
   `User::LoadBatchKey` vì `Int64` chỉ nhận số.
5. `Ctrl+Shift+S` để Save All.

### 8.3. Chạy package riêng

1. Trong Solution Explorer nhấp phải `23_Validate_Transform.dtsx`.
2. Chọn **Set as StartUp Object**.
3. Mở package đó.
4. Nhấn **Start** hoặc `F5`.
5. Task `SQL - Validate Transform and Mark Silver` phải chuyển màu xanh.
6. Dòng cuối phải báo package finished successfully.
7. Chọn **Debug → Stop Debugging** hoặc `Shift+F5` để về Design Mode.

Nếu validation fail, procedure sẽ `THROW` và task đỏ. Vì trạng thái chỉ được
cập nhật **sau khi** validator pass nên batch vẫn `BRONZE_LOADED`; các bảng
Clean/Summary không bị xóa hoặc sửa.

Package 23 có thể chạy lại trên batch đã `SILVER_VALIDATED` để xác nhận lại. Tuy
nhiên không chạy lại package 20/21/22 trên batch Silver, vì các package Transform
đó yêu cầu đầu vào `BRONZE_LOADED`.

---

## 9. Nghiệm thu tự động trên SSMS

File nghiệm thu read-only:

```text
sql/25_accept_transform_silver.sql
```

Thao tác:

1. Mở [`../../sql/25_accept_transform_silver.sql`](../../sql/25_accept_transform_silver.sql).
2. Copy toàn bộ file vào **New Query** trong SSMS.
3. Chọn database `DanangSmartParkingDW`.
4. Nhấn `Ctrl+A` rồi `F5`.

Expected:

- bảng chi tiết của validator: mọi `IsMatched = 1`;
- result set cuối:

```text
AcceptanceStatus = PASS
LoadBatchKey     = 16                 -- tại checkpoint hiện tại
LoadStatus       = SILVER_VALIDATED
RowsRead         = 21500
RowsAccepted     = 21500
RowsRejected     = 0
CompletedAt      = NULL
Message          = PACKAGE 23 ACCEPTED - ready for package 30 dimensions
```

Nếu script `THROW`, đọc dòng có `IsMatched = 0` trước khi sửa. Không chạy riêng
một mệnh đề `WHERE` hoặc một đoạn giữa file; phải chạy toàn bộ script.

---

## 10. Gắn package 23 vào `00_Master.dtsx`

Chỉ làm bước này sau khi debug package 23 độc lập và script nghiệm thu đều đạt.

### 10.1. Đưa parameter về default cho parent binding

1. Mở `23_Validate_Transform.dtsx` → tab **Parameters**.
2. Đưa `pLoadBatchKey` từ số debug như `16` về `0`.
3. Save All.

Parent binding mới là giá trị thật khi chạy `00_Master.dtsx`; không phụ thuộc
default `0` của child.

### 10.2. Tạo Execute Package Task mới

Vì project trước đây từng lỗi reference sau khi đổi tên package 21/22, nên ở
bước này nên kéo **task mới**, không copy một task đang giữ reference cũ.

1. Mở `00_Master.dtsx` → tab **Control Flow**.
2. Trong SSIS Toolbox kéo **Execute Package Task** vào dưới
   `PKG - Transform Aggregates`.
3. Đổi tên task mới thành:

   ```text
   PKG - Validate Transform
   ```

4. Nhấp đúp task.
5. Tab **Package**:
   - `ReferenceType`: `Project Reference`;
   - `PackageNameFromProjectReference`: chọn đúng
     `23_Validate_Transform.dtsx` từ dropdown;
   - không gõ tay tên package.
6. Tab **Parameter bindings**:
   - Add child parameter `pLoadBatchKey`;
   - bind với parent variable `User::LoadBatchKey`.
7. Nhấn **OK**.

### 10.3. Nối thứ tự

Kéo mũi tên xanh **Success**:

```text
PKG - Transform Aggregates
            ↓
PKG - Validate Transform
```

Không nối song song package 23 với package 20/21/22.

### 10.4. Save và build

1. Nhấn `Ctrl+Shift+S` để **Save All**.
2. Menu **Build → Rebuild Solution**.
3. Mở **View → Output**, chọn `Build` và bảo đảm không có error.

Nếu Visual Studio của bạn không có `Clean Solution`, chỉ cần **Rebuild
Solution**; Rebuild đã thực hiện clean/build cần thiết.

### 10.5. Chạy toàn bộ luồng bằng Master

Lưu ý: chạy Master sẽ tạo **một batch mới**, không sử dụng lại batch debug 16.

1. Trong Solution Explorer nhấp phải `00_Master.dtsx`.
2. Chọn **Set as StartUp Object**.
3. Mở `00_Master.dtsx`.
4. Nhấn **Start** hoặc `F5`.
5. Các task từ Start Batch đến `PKG - Validate Transform` phải xanh theo thứ tự.
6. Các package Dimension/Fact chưa tạo thì chưa xuất hiện trong Master.
7. `SQL - Complete Batch` vẫn phải Disabled ở checkpoint này.

Sau khi chạy, kiểm tra batch mới nhất bằng SSMS:

```sql
USE DanangSmartParkingDW;
GO

SELECT TOP (1)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage,
    CompletedAt
FROM etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Expected batch mới nhất:

```text
LoadStatus   = SILVER_VALIDATED
RowsRead     = 21500
RowsAccepted = 21500
RowsRejected = 0
ErrorMessage = NULL
CompletedAt  = NULL
```

Sau đó chạy lại `sql/25_accept_transform_silver.sql` để nghiệm thu batch mới
do Master vừa tạo.

---

## 11. Lỗi thường gặp

### 11.1. `Could not find stored procedure`

Nguyên nhân:

- chưa chạy `sql/25_validate_transform_and_mark_silver.sql`; hoặc
- Execute SQL Task dùng sai Connection Manager.

Cách sửa:

- kiểm tra hai procedure ở mục 4.2;
- task phải dùng `(project) CM_DanangDW`;
- SQLStatement gọi `etl.usp_ValidateTransformAndMarkSilver`.

### 11.2. `LoadBatchKey must be a positive value`

Khi chạy độc lập, `pLoadBatchKey` vẫn bằng `0`. Lấy batch thật ở SSMS và nhập
**số** vào package parameter như mục 8.

Khi chạy từ Master, kiểm tra tab **Parameter bindings**:

```text
pLoadBatchKey → User::LoadBatchKey
```

### 11.3. Parameter Mapping không có `BIGINT`

Đây là giao diện OLE DB bình thường. Chọn:

```text
Data Type = LONG
Parameter Name = 0
```

và giữ câu `CONVERT(bigint, ?)` trong SQLStatement.

### 11.4. `Silver validation requires a BRONZE_LOADED... batch`

Batch đang ở `STARTED`, `FAILED` hoặc `COMPLETED`. Package 23 chỉ chấp nhận:

```text
BRONZE_LOADED
SILVER_VALIDATED
```

Không sửa tay trạng thái. Kiểm tra lại package Extract/Transform gây ra trạng
thái sai.

### 11.5. Có `IsMatched = 0`

| Check lỗi | Quay lại |
|---|---|
| master Clean/capacity/width/Unicode | package 20 và `sql/22_validate_transform_master_data.sql` |
| Traffic/Parking/Weather/dedup/link | package 21 và `sql/23_validate_transform_events.sql` |
| Summary/aggregate mismatch | package 22 và `sql/24_validate_transform_aggregates.sql` |

Không thay dữ liệu expected chỉ để test pass. Các con số expected đã được đối
soát từ RAW của bộ dữ liệu 7 ngày.

### 11.6. `Failed to locate the specified package in the project`

1. Dừng Debug (`Shift+F5`).
2. Xóa riêng Execute Package Task bị hỏng trong Master; không xóa database.
3. Kéo một Execute Package Task mới.
4. Chọn package từ dropdown **Project Reference**.
5. Bind lại parameter.
6. Save All → Rebuild Solution.

Không đổi tên file package sau khi đã chọn trong Master.

### 11.7. Package chạy lâu

Validator tính lại toàn bộ aggregate và so sánh hai chiều nên có thể chậm hơn
một câu `COUNT(*)`. Trong Properties của Execute SQL Task, để `TimeOut = 0`
(không giới hạn) nếu môi trường đặt timeout ngắn. Chỉ kết luận treo sau khi kiểm
tra tab **Progress/Execution Results** và SQL Server không còn truy vấn chạy.

---

## 12. Checklist nghiệm thu

- [ ] Đã chạy `sql/25_validate_transform_and_mark_silver.sql`.
- [ ] Hai stored procedure mới tồn tại đúng database.
- [ ] Preflight read-only trả toàn bộ `IsMatched = 1`.
- [ ] Đã tạo đúng `23_Validate_Transform.dtsx`.
- [ ] `pLoadBatchKey` là `Int64`, default `0`, Required `True`.
- [ ] Execute SQL Task dùng `(project) CM_DanangDW`.
- [ ] SQLStatement có `CONVERT(bigint, ?)`.
- [ ] Parameter Mapping dùng `$Package::pLoadBatchKey`, `LONG`, ordinal `0`.
- [ ] Debug package riêng chuyển task sang xanh.
- [ ] `sql/25_accept_transform_silver.sql` trả `PASS`.
- [ ] Batch là `SILVER_VALIDATED`, `CompletedAt = NULL`.
- [ ] Đã gắn package 23 sau package 22 trong Master.
- [ ] Đã bind `pLoadBatchKey → User::LoadBatchKey`.
- [ ] Đã Save All, Rebuild, Set Master as Startup Object và chạy F5.
- [ ] Batch mới do Master tạo cũng đạt `SILVER_VALIDATED`.

## 13. Checkpoint sau package 23

Đã có:

- RAW Extract đầy đủ;
- Master/Event Clean đã validate;
- hai bảng Summary đã được tính lại và đối soát;
- batch đạt `SILVER_VALIDATED`;
- tầng Transform đã nghiệm thu xong.

Chưa có ở checkpoint này:

- Dimension của batch mới trong DWH;
- Fact của batch mới trong DWH;
- reconciliation cuối;
- cleanup staging;
- trạng thái `COMPLETED`.

Bước tiếp theo chính xác:

```text
docs/etl/30_DATA_FLOW_DIMENSIONS.md
```

Từ package 30, theo quy trình đã thống nhất, việc Load Dimension phải dùng
**Data Flow Task** và tải đúng thứ tự phân cấp trước khi Load Fact.
