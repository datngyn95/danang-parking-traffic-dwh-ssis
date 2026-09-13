# 30 — Load Dimensions bằng SSIS Data Flow

## 1. Mục tiêu và checkpoint đầu vào

Package này nạp các bảng Dimension từ tầng Silver trong
`DanangSmartParkingSTG` sang `DanangSmartParkingDW.dwh`.

Quy tắc đã thống nhất:

- phần nạp Dimension bắt buộc dùng **Data Flow Task**;
- `Execute SQL Task` chỉ dùng để kiểm tra trước và nghiệm thu sau khi nạp;
- nạp Dimension cha trước Dimension con;
- chạy lại cùng một batch không được tạo thêm bản ghi current trùng lặp;
- bảng SCD Type 2 phải đóng version cũ rồi mới chèn version mới.

Checkpoint đã đạt trước package 30:

| Hạng mục | Giá trị |
|---|---:|
| Batch đã nghiệm thu Silver | batch mới nhất có `LoadStatus = SILVER_VALIDATED` |
| Batch gần nhất đã kiểm tra | `18` |
| `RowsRead / RowsAccepted / RowsRejected` | `21500 / 21500 / 0` |
| `ErrorMessage` | `NULL` |
| `CompletedAt` | `NULL` |

Nếu batch mới nhất của bạn không còn là `18`, luôn dùng số batch mới nhất có trạng thái
`SILVER_VALIDATED`. Không cố định số `18` trong package chính.

## 2. Kết quả cần đạt

Sau khi hoàn thành, batch hiện tại phải có đủ:

| Dimension | Số thành viên cần có |
|---|---:|
| `DimDate` | 7 ngày của batch |
| `DimTime` | 1.440 phút |
| `DimCity` | 1 |
| `DimRoadSide` | 5 |
| `DimVehicleType` | 5 |
| `DimPOICategory` | 18 |
| `DimWeatherSource` | 1 |
| `DimAnalysisZone` | 10 |
| `DimRoad` | 30 current |
| `DimParkingFacility` | 20 current |
| `DimPOI` | 50 current |
| `DimRoadSegment` | 30 current |
| `DimParkingRestriction` | 18 current |
| `DimCamera` | 25 current |

`R003` trong `DimParkingRestriction` có `RoadKey = NULL` là chủ đích của dữ liệu,
không phải lỗi ETL. `BridgeRoadPOI` chưa nạp trong package này; bridge sẽ được xử lý
sau khi Dimension đã ổn định.

## 3. Sơ đồ package

Tạo package tên chính xác:

```text
30_Load_Dimensions.dtsx
```

Control Flow cuối cùng:

```text
SQL - Precheck Dimension Load
    ↓ Success
DFT - L0 Reference Dimensions
    ↓ Success
DFT - L1 Analysis Zone
    ↓ Success
DFT - L2 Road Facility POI
    ↓ Success
DFT - L3 Segment Restriction
    ↓ Success
DFT - L4 Camera
    ↓ Success
SQL - Validate Dimension Load
```

Ta dùng 5 Data Flow Task thay vì 14 task để Control Flow gọn hơn. Mỗi Data Flow Task
có nhiều pipeline độc lập chạy song song, nhưng các level vẫn chạy tuần tự để bảo đảm
khóa ngoại cha đã tồn tại.

## 4. Chuẩn bị SQL trên SSMS

### 4.1. Cài source views và thủ tục kiểm tra

1. Mở SSMS.
2. Chọn **File → Open → File...**.
3. Mở file [26_prepare_dimension_data_flow.sql](../../sql/26_prepare_dimension_data_flow.sql).
4. Nhấn **Execute** hoặc `F5`.
5. Kết quả cuối phải có `InstallStatus = PASS`.

Script này chỉ tạo:

- 14 view nguồn typed trong `DanangSmartParkingSTG.publish`;
- `etl.usp_PrecheckDimensionLoad` trong DW;
- `etl.usp_ValidateDimensionLoad` trong DW.

Script không nạp dữ liệu Dimension, vì thao tác load phải do SSIS Data Flow thực hiện.

### 4.2. Kiểm tra batch sẽ dùng

Chạy trong SSMS:

```sql
SELECT TOP (10)
    LoadBatchKey, LoadStatus, RowsRead, RowsAccepted,
    RowsRejected, ErrorMessage, CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Chọn dòng mới nhất có:

```text
LoadStatus   = SILVER_VALIDATED
RowsRead     = 21500
RowsAccepted = 21500
RowsRejected = 0
ErrorMessage = NULL
CompletedAt  = NULL
```

Ghi lại `LoadBatchKey`. Trong ví dụ hiện tại là `18`.

### 4.3. Chạy precheck thủ công

Thay `18` nếu batch hiện tại khác:

```sql
EXEC DanangSmartParkingDW.etl.usp_PrecheckDimensionLoad
    @LoadBatchKey = 18;
```

Precheck trả hai result set. Result set đầu phải có đủ 14 dòng nguồn và tất cả:

```text
ActualRows = ExpectedRows
IsMatched  = 1
```

Result set cuối phải là:

```text
PrecheckStatus = PASS
```

Không được chuyển sang SSIS nếu thiếu result set `PASS`, có `IsMatched = 0`, hoặc lệnh
phát sinh `THROW`. Việc kiểm tra này giúp package dừng trước khi một Data Flow ghi dở
dang vào DWH.

## 5. Tạo package và parameter trên SSIS

### 5.1. Tạo package

1. Mở solution `DanangSmartParkingETL` trong Visual Studio.
2. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
3. Chọn **New SSIS Package**.
4. Nhấp phải package mới → **Rename**.
5. Đặt tên `30_Load_Dimensions.dtsx`.
6. Nhấp đúp package để mở.
7. Nhấn `Ctrl+Shift+S` hoặc **File → Save All**.

Không đổi tên package trong Windows Explorer khi Visual Studio đang mở. Việc đó có thể
làm hỏng project reference giống lỗi đã gặp ở package 21/22.

### 5.2. Tạo package parameter

1. Trong package 30, chọn tab **Parameters**.
2. Nhấn nút **Add Parameter**.
3. Điền:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |
| Description | `Batch key nhận từ 00_Master` |

Chỉ nhập tên `pLoadBatchKey`, không nhập `$Package::pLoadBatchKey` vào cột Name.

### 5.3. Tạo biến package

1. Chuyển sang tab **Control Flow**.
2. Bấm vào vùng trống của Control Flow để scope là toàn package.
3. Mở **SSIS → Variables** hoặc nhấp phải vùng trống → **Variables**.
4. Nhấn **Add Variable**.
5. Điền:

| Thuộc tính | Giá trị |
|---|---|
| Name | `LoadBatchKey` |
| Scope | `30_Load_Dimensions` hoặc tên package hiện tại |
| Data type | `Int64` |
| Value | `0` |

6. Chọn biến `User::LoadBatchKey`.
7. Nhấn `F4` để mở **Properties**.
8. Đặt `EvaluateAsExpression = True`.
9. Ở `Expression`, nhấn nút `...` và nhập:

```text
@[$Package::pLoadBatchKey]
```

10. Nhấn **Evaluate Expression**; kết quả lúc thiết kế phải là `0`.
11. Nhấn **OK** rồi **Save All**.

Không gõ chữ `LoadBatchKey` vào ô Value của `Int64`. Ô Value chỉ nhận số.

### 5.4. Kiểm tra Connection Manager dùng chung

Ở đáy package phải nhìn thấy:

```text
(project) CM_DanangDW
(project) CM_DanangSTG
```

Nếu không thấy cả hai:

1. kiểm tra chúng có trong node **Connection Managers** của project;
2. mở lại package;
3. không tạo thêm connection local trùng tên.

## 6. Tạo hai Execute SQL Task kiểm tra

### 6.1. Task precheck

1. Kéo **Execute SQL Task** từ SSIS Toolbox vào Control Flow.
2. Đổi tên thành `SQL - Precheck Dimension Load`.
3. Nhấp đúp task và cấu hình tab **General**:

| Thuộc tính | Giá trị |
|---|---|
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `None` |
| BypassPrepare | `True` |

4. Nhấn nút `...` ở `SQLStatement` và nhập toàn bộ:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC etl.usp_PrecheckDimensionLoad
    @LoadBatchKey = @LoadBatchKey;
```

5. Mở trang **Parameter Mapping** → **Add**.
6. Điền:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `User::LoadBatchKey` | `Input` | `LONG` | `0` | `-1` |

Trong OLE DB, `LONG` là lựa chọn tương thích với parameter dấu `?`; SQL đã chuyển rõ
sang `bigint`. Không nhập `BIGINT`, vì dropdown SSIS không có tên kiểu đó.

### 6.2. Task postcheck

1. Copy task precheck bằng `Ctrl+C`, `Ctrl+V`.
2. Đổi tên bản sao thành `SQL - Validate Dimension Load`.
3. Giữ nguyên connection và Parameter Mapping.
4. Thay `SQLStatement` bằng:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC etl.usp_ValidateDimensionLoad
    @LoadBatchKey = @LoadBatchKey,
    @ReturnDetail = 0;
```

Task này sẽ làm package fail nếu một Dimension thiếu dòng, sai hash, có current trùng,
hoặc có orphan key.

## 7. Ba mẫu pipeline cần dùng

Trước khi tạo 14 pipeline, cần hiểu ba mẫu sau.

### 7.1. Mẫu A — Dimension insert-only/Type 0

```text
OLE DB Source (STG view)
    → Lookup current target bằng business key
        ├─ Match: bỏ qua, không nối tiếp
        └─ No Match: OLE DB Destination
```

Áp dụng cho:

- `DimDate`;
- `DimTime`;
- `DimRoadSide`;
- `DimVehicleType`;
- `DimWeatherSource`.

### 7.2. Mẫu B — Dimension Type 1

```text
OLE DB Source
    → Lookup target bằng business key
        ├─ No Match → OLE DB Destination
        └─ Match → Conditional Split Changed/Unchanged
                     └─ Changed → OLE DB Command UPDATE
```

Áp dụng cho `DimCity`, `DimPOICategory`, `DimAnalysisZone`. Package này phải cấu hình
đủ cả nhánh `No Match` và `Changed`; không chỉ làm nhánh insert của lần chạy đầu.
Dimension Type 1 cập nhật trực tiếp thuộc tính của cùng surrogate key, không tạo version
lịch sử và không xóa rồi insert lại.

### 7.3. Mẫu C — Dimension SCD Type 2

```text
OLE DB Source
    → Lookup target current bằng business key
        ├─ No Match ───────────────────────────────┐
        └─ Match → Conditional Split               │
                     ├─ Unchanged: bỏ qua          │
                     └─ Changed → OLE DB Command   │
                                  đóng current cũ  │
                                  ↓                │
                              Union All ←──────────┘
                                  ↓
                           OLE DB Destination
```

Áp dụng cho:

- `DimRoad`;
- `DimParkingFacility`;
- `DimPOI`;
- `DimRoadSegment`;
- `DimParkingRestriction`;
- `DimCamera`.

Lookup phải chỉ lấy dòng `IsCurrent = 1`. So sánh hash dưới dạng chuỗi hex để tránh
SSIS so sánh trực tiếp kiểu binary:

```text
SourceHashHex != CurrentHashHex
```

## 8. Cách tạo một pipeline Data Flow chuẩn

Phần này làm mẫu với `DimDate`. Các pipeline còn lại làm tương tự theo bảng cấu hình ở
mục 9–13.

### 8.1. Tạo Data Flow Task level 0

1. Quay lại **Control Flow**.
2. Kéo **Data Flow Task** vào canvas.
3. Đổi tên `DFT - L0 Reference Dimensions`.
4. Kéo mũi tên xanh từ `SQL - Precheck Dimension Load` sang task này.
5. Nhấp đúp task để vào tab **Data Flow**.

### 8.2. Tạo OLE DB Source cho DimDate

1. Kéo **OLE DB Source** vào Data Flow.
2. Đổi tên `SRC - DimDate`.
3. Nhấp đúp source.
4. Chọn connection `(project) CM_DanangSTG`.
5. Chọn **Data access mode = SQL command**.
6. Nhập:

```sql
SELECT
    DateKey, DateValue, CalendarYear, CalendarQuarter,
    MonthNumber, MonthName, DayOfMonth, ISOWeekNumber,
    ISOWeekdayNumber, DayName, IsWeekend
FROM publish.vDimDateSource
WHERE LoadBatchKey = ?;
```

7. Nhấn **Parameters...**.
8. Map `Param_0` với `User::LoadBatchKey`.
9. Nhấn **Columns** để chắc chắn thấy đủ 11 cột.
10. Nhấn **OK**.

### 8.3. Tạo Lookup cho DimDate

1. Kéo **Lookup** vào Data Flow và đổi tên `LKP - DimDate Current`.
2. Nối mũi tên xanh từ source vào Lookup.
3. Nhấp đúp Lookup.
4. Trang **General**:
   - Cache mode: `Full cache`;
   - Specify how to handle rows with no matching entries: `Redirect rows to no match output`.
5. Trang **Connection**:
   - OLE DB connection: `(project) CM_DanangDW`;
   - Use results of an SQL query;
   - query:

```sql
SELECT DateKey
FROM dwh.DimDate;
```

6. Trang **Columns**: kéo `DateKey` nguồn sang `DateKey` lookup.
7. Không cần tick thêm output column cho mẫu insert-only.
8. Nhấn **OK**.

### 8.4. Tạo destination

1. Kéo **OLE DB Destination** vào Data Flow.
2. Đổi tên `DST - DimDate New`.
3. Chọn component `LKP - DimDate Current`.
4. Ở cạnh dưới Lookup sẽ có đầu nối dữ liệu thông thường và đầu nối lỗi:
   - đầu nối/mũi tên **màu xanh** chứa các output dữ liệu của Lookup;
   - đầu nối/mũi tên **màu đỏ** là `Lookup Error Output`.
5. Kéo **đầu nối màu xanh**, không kéo đầu nối đỏ, sang
   `DST - DimDate New`.
6. Khi hộp **Input Output Selection** xuất hiện, ở **Output** chọn chính xác:

```text
Lookup No Match Output
```

7. Ở **Input** giữ `OLE DB Destination Input`, sau đó nhấn **OK**.
8. Nhấp đúp destination.
9. Chọn `(project) CM_DanangDW`.
10. Data access mode: `Table or view - fast load`.
11. Name of table: `[dwh].[DimDate]`.
12. Mở **Mappings** và kiểm tra 11 cột cùng tên được map đúng.
13. Nhấn **OK**.

> **Lưu ý quan trọng:** `Lookup No Match Output` không phải là Error Output, mặc dù
> nó chứa các dòng không tìm thấy trong bảng đích. Đây vẫn là một output dữ liệu bình
> thường nên phải lấy từ đầu nối màu xanh. Đầu nối đỏ chỉ dùng cho lỗi kỹ thuật như
> lỗi chuyển đổi dữ liệu và không được dùng để chèn thành viên Dimension mới.

Nếu xuất hiện popup:

```text
This error output cannot receive any error rows...
Do you still want to connect this error output?
```

thì bạn đã kéo nhầm `Lookup Error Output`. Thực hiện như sau:

1. Nhấn **Cancel**, không nhấn **OK**.
2. Nhấp đúp Lookup và kiểm tra tại trang **General** rằng tùy chọn xử lý dòng không
   khớp đang là `Redirect rows to no match output`.
3. Nhấn **OK** để đóng Lookup Editor.
4. Chọn lại Lookup, kéo đầu nối dữ liệu màu xanh sang destination.
5. Trong **Input Output Selection**, chọn `Lookup No Match Output`.

Nếu trước đó đã nhấn **OK** và tạo nhầm đường Error Output:

1. Chọn đường nối sai giữa Lookup và destination.
2. Nhấn `Delete` rồi xác nhận xóa đường nối; không xóa hai component.
3. Nối lại bằng đầu nối màu xanh theo các bước trên.

Nhánh Lookup Match không cần nối vì dòng đã tồn tại sẽ được bỏ qua.

## 9. Data Flow level 0 — Reference Dimensions

Trong `DFT - L0 Reference Dimensions`, tạo 7 pipeline độc lập. Có thể copy pipeline
`DimDate`, sau đó thay source/lookup/destination để tiết kiệm thời gian. Sau khi copy,
phải mở lại từng component để sửa metadata; không chỉ đổi tên trên canvas.

### 9.1. Cấu hình nguồn và business key

| Pipeline | Source query | Lookup business key | Destination |
|---|---|---|---|
| Date | `vDimDateSource WHERE LoadBatchKey=?` | `DateKey` | `dwh.DimDate` |
| Time | `vDimTimeSource` | `TimeKey` | `dwh.DimTime` |
| City | `vDimCitySource` | `CityCode` | `dwh.DimCity` |
| RoadSide | `vDimRoadSideSource` | `RoadSideKey` | `dwh.DimRoadSide` |
| VehicleType | `vDimVehicleTypeSource` | `VehicleTypeKey` | `dwh.DimVehicleType` |
| POICategory | `vDimPOICategorySource WHERE LoadBatchKey=?` | `CategoryCode` | `dwh.DimPOICategory` |
| WeatherSource | `vDimWeatherSourceSource WHERE LoadBatchKey=?` | bộ 3 cột provenance | `dwh.DimWeatherSource` |

Các source query chi tiết:

```sql
-- DimTime: không có parameter
SELECT TimeKey, TimeValue, Hour24, MinuteNumber, MinuteOfDay,
       QuarterOfHour, TimeBand, IsConfiguredPeak
FROM publish.vDimTimeSource;

-- DimCity: không có parameter
SELECT CityCode, CityName, PopulationReference, AreaKm2Reference,
       FormerPopulationReference, ScopeNote, DataWarning, SourceHashHex
FROM publish.vDimCitySource;

-- DimRoadSide: không có parameter
SELECT RoadSideKey, SideCode, SideName
FROM publish.vDimRoadSideSource;

-- DimVehicleType: không có parameter
SELECT VehicleTypeKey, VehicleTypeCode, VehicleTypeName, VehicleGroup
FROM publish.vDimVehicleTypeSource;

-- DimPOICategory
SELECT CategoryCode, CategoryName, SourceHashHex
FROM publish.vDimPOICategorySource
WHERE LoadBatchKey = ?;

-- DimWeatherSource
SELECT TemperatureStatus, PrecipitationStatus, SourceReference
FROM publish.vDimWeatherSourceSource
WHERE LoadBatchKey = ?;
```

Lookup WeatherSource phải nối cả ba cột:

```text
TemperatureStatus
PrecipitationStatus
SourceReference
```

Không map các cột identity vào destination:

```text
CityKey
POICategoryKey
WeatherSourceKey
```

SQL Server sẽ tự sinh chúng.

### 9.1.1. Mapping chính xác cho năm pipeline insert-only

Trong mỗi OLE DB Destination, mở trang **Mappings**. Chỉ nối các cột dưới đây; nếu
SSIS tự nối nhầm cột thì xóa đường nối đó và kéo lại bằng chuột.

| Destination | Input column → Destination column |
|---|---|
| `dwh.DimDate` | `DateKey→DateKey`, `DateValue→DateValue`, `CalendarYear→CalendarYear`, `CalendarQuarter→CalendarQuarter`, `MonthNumber→MonthNumber`, `MonthName→MonthName`, `DayOfMonth→DayOfMonth`, `ISOWeekNumber→ISOWeekNumber`, `ISOWeekdayNumber→ISOWeekdayNumber`, `DayName→DayName`, `IsWeekend→IsWeekend` |
| `dwh.DimTime` | `TimeKey→TimeKey`, `TimeValue→TimeValue`, `Hour24→Hour24`, `MinuteNumber→MinuteNumber`, `MinuteOfDay→MinuteOfDay`, `QuarterOfHour→QuarterOfHour`, `TimeBand→TimeBand`, `IsConfiguredPeak→IsConfiguredPeak` |
| `dwh.DimRoadSide` | `RoadSideKey→RoadSideKey`, `SideCode→SideCode`, `SideName→SideName` |
| `dwh.DimVehicleType` | `VehicleTypeKey→VehicleTypeKey`, `VehicleTypeCode→VehicleTypeCode`, `VehicleTypeName→VehicleTypeName`, `VehicleGroup→VehicleGroup` |
| `dwh.DimWeatherSource` | `TemperatureStatus→TemperatureStatus`, `PrecipitationStatus→PrecipitationStatus`, `SourceReference→SourceReference` |

Không map các cột điều khiển như `LoadBatchKey`. Với `DimWeatherSource`, không map
`WeatherSourceKey` vì đây là identity. `DimCity` và `DimPOICategory` không nằm trong
bảng trên vì chúng phải làm đầy đủ Type 1 ở mục 9.7–9.8.

### 9.2. Quy trình copy pipeline `DimDate` an toàn

Bạn đã hoàn thành `DimDate`. Pipeline tiếp theo nên làm là `DimTime`. Với mỗi
dimension còn lại, chỉ copy ba component sau:

```text
SRC - DimDate
    ↓
LKP - DimDate Current
    ↓ Lookup No Match Output
DST - DimDate New
```

Thao tác trên SSIS:

1. Trong `DFT - L0 Reference Dimensions`, giữ `Ctrl` rồi lần lượt chọn ba component
   `SRC`, `LKP`, `DST` của `DimDate`.
2. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
3. Kéo cụm vừa copy sang bên phải để không đè lên pipeline cũ.
4. Đổi tên ba component theo dimension mới, ví dụ:
   - `SRC - DimTime`;
   - `LKP - DimTime Current`;
   - `DST - DimTime New`.
5. Sửa component theo đúng thứ tự `Source → Lookup → Destination`. Không sửa
   destination trước source vì metadata đầu vào vẫn còn là metadata của `DimDate`.
6. Nếu đường nối của bản copy có dấu X đỏ, xóa **đường nối** rồi nối lại sau khi đã
   sửa xong Source và Lookup. Không cần xóa component ngay.

Quy tắc chọn đầu ra của Lookup:

1. Chọn Lookup.
2. Kéo **đầu nối dữ liệu màu xanh** sang destination.
3. Hộp `Input Output Selection` xuất hiện.
4. Chọn `Lookup No Match Output` rồi nhấn `OK`.

Không kéo đầu nối Error Output màu đỏ. Nếu hộp thoại nói `This error output cannot
receive any error rows`, nhấn `Cancel`: bạn đang kéo nhầm đầu nối error.

Sau khi copy, bắt buộc mở lại cả ba component. Đổi tên trên canvas không làm thay
đổi SQL, bảng đích hoặc metadata bên trong.

### 9.3. Pipeline thứ hai — `DimTime`

Đây là pipeline bạn nên làm ngay sau `DimDate`.

#### 9.3.1. Cấu hình `SRC - DimTime`

1. Nhấp đúp `SRC - DimTime`.
2. Ở `OLE DB connection manager`, chọn `(project) CM_DanangSTG`.
3. `Data access mode` chọn `SQL command`.
4. Xóa SQL cũ của `DimDate` và dán nguyên khối:

```sql
SELECT TimeKey, TimeValue, Hour24, MinuteNumber, MinuteOfDay,
       QuarterOfHour, TimeBand, IsConfiguredPeak
FROM publish.vDimTimeSource;
```

5. Không bấm `Parameters...` vì query này không có dấu `?`.
6. Chọn trang `Columns`. Phải nhìn thấy đúng 8 cột trong câu SELECT.
7. Quay lại trang `Connection Manager`, nhấn `Preview`.
8. Preview phải có dữ liệu thời gian từ `00:00` đến `23:59`; tổng nguồn dự kiến là
   `1,440` dòng.
9. Nhấn `OK`.

Nếu SSIS hỏi có cập nhật metadata mới không, chọn `Yes`.

#### 9.3.2. Cấu hình `LKP - DimTime Current`

1. Nhấp đúp `LKP - DimTime Current`.
2. Trang `General`:
   - chọn `Full cache`;
   - chọn `Redirect rows to no match output`.
3. Trang `Connection`:
   - chọn `(project) CM_DanangDW`;
   - chọn `Use results of an SQL query`;
   - nhập:

```sql
SELECT TimeKey
FROM dwh.DimTime;
```

4. Trang `Columns`:
   - kéo `TimeKey` bên trái sang `TimeKey` bên phải;
   - không tick thêm output column nào.
5. Nhấn `OK`.
6. Nếu đường nối từ Source sang Lookup có dấu X đỏ, xóa đường đó rồi kéo lại đầu
   nối xanh từ `SRC - DimTime` sang `LKP - DimTime Current`.

Lookup này dùng `TimeKey` để phân loại:

- đã tồn tại → Match Output, không cần xử lý;
- chưa tồn tại → No Match Output, đưa sang destination để insert.

#### 9.3.3. Cấu hình `DST - DimTime New`

1. Nếu đường nối Lookup → Destination đang là đường copy cũ, xóa đường nối đó.
2. Kéo đầu nối xanh từ Lookup sang destination.
3. Chọn `Lookup No Match Output`, nhấn `OK`.
4. Nhấp đúp `DST - DimTime New`.
5. Chọn `(project) CM_DanangDW`.
6. `Data access mode`: chọn `Table or view - fast load`.
7. `Name of the table or the view`: chọn `[dwh].[DimTime]`.
8. Mở trang `Mappings`, nối đúng:

| Input column | Destination column |
|---|---|
| `TimeKey` | `TimeKey` |
| `TimeValue` | `TimeValue` |
| `Hour24` | `Hour24` |
| `MinuteNumber` | `MinuteNumber` |
| `MinuteOfDay` | `MinuteOfDay` |
| `QuarterOfHour` | `QuarterOfHour` |
| `TimeBand` | `TimeBand` |
| `IsConfiguredPeak` | `IsConfiguredPeak` |

9. Không còn mapping nào của `DimDate` như `DateKey`, `MonthName`.
10. Nhấn `OK`. Cả ba component phải hết dấu X đỏ.

### 9.4. Pipeline thứ ba — `DimRoadSide`

Copy lại pipeline `DimDate` hoặc pipeline `DimTime` vừa hoàn tất, rồi đổi tên thành:

```text
SRC - DimRoadSide
LKP - DimRoadSide Current
DST - DimRoadSide New
```

#### 9.4.1. Source

Connection: `(project) CM_DanangSTG`. Dùng SQL command:

```sql
SELECT RoadSideKey, SideCode, SideName
FROM publish.vDimRoadSideSource;
```

Không có parameter. Trang `Columns` phải có 3 cột. `Preview` dự kiến có 5 dòng.

#### 9.4.2. Lookup

1. `General`: `Full cache` và `Redirect rows to no match output`.
2. Connection: `(project) CM_DanangDW`.
3. Query:

```sql
SELECT RoadSideKey
FROM dwh.DimRoadSide;
```

4. Trang `Columns`: nối `RoadSideKey → RoadSideKey`.
5. Không tick output column.

#### 9.4.3. Destination

1. Nối bằng `Lookup No Match Output`.
2. Connection: `(project) CM_DanangDW`.
3. Chọn `[dwh].[DimRoadSide]`, chế độ `Table or view - fast load`.
4. Mappings:

```text
RoadSideKey → RoadSideKey
SideCode    → SideCode
SideName    → SideName
```

### 9.5. Pipeline thứ tư — `DimVehicleType`

Copy một pipeline insert-only đã hoàn tất và đổi tên:

```text
SRC - DimVehicleType
LKP - DimVehicleType Current
DST - DimVehicleType New
```

#### 9.5.1. Source

Connection `(project) CM_DanangSTG`, SQL command:

```sql
SELECT VehicleTypeKey, VehicleTypeCode, VehicleTypeName, VehicleGroup
FROM publish.vDimVehicleTypeSource;
```

Không có parameter. Preview dự kiến 5 dòng.

#### 9.5.2. Lookup

Connection `(project) CM_DanangDW`, `Full cache`, redirect no match, query:

```sql
SELECT VehicleTypeKey
FROM dwh.DimVehicleType;
```

Trang `Columns`: nối `VehicleTypeKey → VehicleTypeKey`, không tick output.

#### 9.5.3. Destination

Nối bằng `Lookup No Match Output`, chọn `[dwh].[DimVehicleType]` và map:

```text
VehicleTypeKey  → VehicleTypeKey
VehicleTypeCode → VehicleTypeCode
VehicleTypeName → VehicleTypeName
VehicleGroup    → VehicleGroup
```

### 9.6. Pipeline thứ năm — `DimWeatherSource`

Đổi tên ba component:

```text
SRC - DimWeatherSource
LKP - DimWeatherSource Current
DST - DimWeatherSource New
```

#### 9.6.1. Source có parameter batch

1. Chọn `(project) CM_DanangSTG` và `SQL command`.
2. Nhập:

```sql
SELECT TemperatureStatus, PrecipitationStatus, SourceReference
FROM publish.vDimWeatherSourceSource
WHERE LoadBatchKey = ?;
```

3. Nhấn `Parameters...`.
4. Tại `Param_0`, chọn variable `User::LoadBatchKey`.
5. Nhấn `OK`, mở `Columns`, kiểm tra có đúng 3 cột.
6. Preview dự kiến 1 dòng.

`Preview` chỉ trả dữ liệu khi `User::LoadBatchKey` đang mang batch
`SILVER_VALIDATED` thật. Nếu variable vẫn là `0`, tạm nhập số batch mới nhất (ví dụ
`18`) vào variable để Preview; sau khi kiểm tra xong phải trả lại cấu hình nhận giá
trị từ `pLoadBatchKey`, không để cố định số batch.

Nếu `Parameters...` không cho chọn `User::LoadBatchKey`, kiểm tra package
`30_Load_Dimensions.dtsx` đã có variable `LoadBatchKey` kiểu `Int64`, scope là toàn
package.

#### 9.6.2. Lookup bằng bộ khóa ba cột

Connection `(project) CM_DanangDW`, query:

```sql
SELECT TemperatureStatus, PrecipitationStatus, SourceReference
FROM dwh.DimWeatherSource;
```

Trang `General`: `Full cache` và `Redirect rows to no match output`.

Trang `Columns`, tạo đủ **ba** đường nối:

```text
TemperatureStatus   → TemperatureStatus
PrecipitationStatus → PrecipitationStatus
SourceReference     → SourceReference
```

Không chỉ nối một cột vì ba cột cùng nhau tạo business key.

#### 9.6.3. Destination

1. Nối bằng `Lookup No Match Output`.
2. Chọn `[dwh].[DimWeatherSource]`.
3. Map ba cột cùng tên ở trên.
4. Không map `WeatherSourceKey`; đây là cột identity do SQL Server sinh.

### 9.7. Pipeline thứ sáu — `DimCity` Type 1

`DimCity` khác bốn pipeline vừa làm: ngoài insert bản ghi mới, nó còn update thuộc
tính khi `CityCode` cũ có nội dung thay đổi.

#### 9.7.1. Tạo Source

Bạn có thể copy Source cũ nhưng nên tạo Lookup, Conditional Split và OLE DB Command
theo đúng các bước dưới đây.

Tên Source: `SRC - DimCity`. Connection `(project) CM_DanangSTG`, SQL command:

```sql
SELECT CityCode, CityName, PopulationReference, AreaKm2Reference,
       FormerPopulationReference, ScopeNote, DataWarning, SourceHashHex
FROM publish.vDimCitySource;
```

Không có parameter. `Columns` phải có 8 cột; Preview dự kiến 1 dòng.

#### 9.7.2. Tạo Lookup

1. Đổi tên Lookup thành `LKP - DimCity Current`.
2. `General`: chọn `Full cache` và `Redirect rows to no match output`.
3. `Connection`: chọn `(project) CM_DanangDW`, dùng query:

```sql
SELECT
    CityKey AS CurrentKey,
    CityCode,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        CityCode, N'|', CityName, N'|', PopulationReference, N'|',
        AreaKm2Reference, N'|', FormerPopulationReference, N'|',
        ScopeNote, N'|', DataWarning)), 2) AS CurrentHashHex
FROM dwh.DimCity;
```

4. `Columns`: nối `CityCode` bên trái với `CityCode` bên phải.
5. Tick hai output `CurrentKey` và `CurrentHashHex`.
6. Nhấn `OK`.

#### 9.7.3. Nhánh No Match — insert City mới

1. Kéo đầu nối xanh từ Lookup tới OLE DB Destination.
2. Chọn `Lookup No Match Output`.
3. Đổi tên destination thành `DST - DimCity New`.
4. Connection `(project) CM_DanangDW`, bảng `[dwh].[DimCity]`.
5. Map:

```text
CityCode                  → CityCode
CityName                  → CityName
PopulationReference       → PopulationReference
AreaKm2Reference          → AreaKm2Reference
FormerPopulationReference → FormerPopulationReference
ScopeNote                 → ScopeNote
DataWarning               → DataWarning
```

Không map `CityKey`, `SourceHashHex`, `CurrentKey`, `CurrentHashHex`.

#### 9.7.4. Nhánh Match — tìm dòng thay đổi

1. Kéo `Conditional Split` từ Toolbox vào canvas, đổi tên
   `SPL - DimCity Changed`.
2. Kéo đầu nối xanh từ Lookup sang Conditional Split.
3. Trong `Input Output Selection`, chọn `Lookup Match Output`.
4. Nhấp đúp Conditional Split.
5. Ở khung phía trên bên trái, bấm dấu `+` trước nhóm `Columns`.
6. Kiểm tra danh sách có đủ hai cột:

   - `SourceHashHex`: hash thuộc tính từ `publish.vDimCitySource`;
   - `CurrentHashHex`: hash hiện tại lấy từ `dwh.DimCity` qua Lookup.

7. Trong bảng phía dưới, bấm vào ô `Output Name` và nhập `Changed`.
8. Bấm đúp đúng ô trống thuộc cột `Condition`, nằm cùng hàng với
   `Changed`. Nếu chưa xuất hiện con trỏ nhập liệu, nhấn `F2`.
9. Cách nhập an toàn nhất là không gõ tên cột bằng tay:

   1. Kéo `SourceHashHex` từ nhóm `Columns` thả vào ô `Condition`.
   2. Gõ ` != `.
   3. Kéo `CurrentHashHex` từ nhóm `Columns` thả tiếp vào ô đó.

   Expression hoàn chỉnh trong SSIS phải là:

```text
[SourceHashHex] != [CurrentHashHex]
```

   Conditional Split dùng cú pháp SSIS `!=`, không dùng cú pháp SQL `<>`.
   Sau khi nhập xong, nhấn `Enter` hoặc `Tab` để SSIS xác nhận expression.

10. Đổi `Default output name` thành `Unchanged` rồi nhấn `OK`.
11. Không nối nhánh `Unchanged`.

Nếu không thấy `SourceHashHex` hoặc `CurrentHashHex` trong nhóm `Columns`:

1. Nhấn `Cancel` để thoát Conditional Split.
2. Mở `SRC - DimCity`, vào trang `Columns`, kiểm tra source đang xuất cột
   `SourceHashHex`.
3. Mở `LKP - DimCity Current`, vào trang `Columns`, kiểm tra:

   - `CityCode` nguồn đã nối với `CityCode` tham chiếu;
   - đã đánh dấu lấy thêm `CurrentKey`;
   - đã đánh dấu lấy thêm `CurrentHashHex`.

4. Lookup phải sử dụng truy vấn:

```sql
SELECT
    CityKey AS CurrentKey,
    CityCode,
    CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimCity;
```

5. Nếu vừa sửa metadata, xóa riêng đường nối từ Lookup tới Conditional Split,
   nối lại bằng `Lookup Match Output`, rồi mở lại Conditional Split.

Nếu SSIS báo hai cột không cùng kiểu dữ liệu, dùng expression ép cả hai về
`DT_STR(64)`:

```text
(DT_STR,64,1252)[SourceHashHex] != (DT_STR,64,1252)[CurrentHashHex]
```

#### 9.7.5. Update City thay đổi

1. Kéo `OLE DB Command` vào canvas, đổi tên `CMD - Update DimCity`.
2. Kéo đầu nối xanh từ Conditional Split sang Command, chọn output `Changed`.
3. Nhấp đúp Command, chọn `(project) CM_DanangDW`.
4. SQLCommand:

```sql
UPDATE dwh.DimCity
SET CityName = ?,
    PopulationReference = ?,
    AreaKm2Reference = ?,
    FormerPopulationReference = ?,
    ScopeNote = ?,
    DataWarning = ?
WHERE CityKey = CONVERT(smallint, ?);
```

5. `Column Mappings`:

| Input column | Parameter |
|---|---|
| `CityName` | `Param_0` |
| `PopulationReference` | `Param_1` |
| `AreaKm2Reference` | `Param_2` |
| `FormerPopulationReference` | `Param_3` |
| `ScopeNote` | `Param_4` |
| `DataWarning` | `Param_5` |
| `CurrentKey` | `Param_6` |

6. Nhấn `OK`. OLE DB Command là điểm cuối của nhánh update.

Sơ đồ hoàn chỉnh:

```text
SRC - DimCity → LKP - DimCity Current
                   ├─ No Match → DST - DimCity New
                   └─ Match → SPL - DimCity Changed
                                  └─ Changed → CMD - Update DimCity
```

### 9.8. Pipeline thứ bảy — `DimPOICategory` Type 1

#### 9.8.1. Source

Tên `SRC - DimPOICategory`, connection `(project) CM_DanangSTG`:

```sql
SELECT CategoryCode, CategoryName, SourceHashHex
FROM publish.vDimPOICategorySource
WHERE LoadBatchKey = ?;
```

Nhấn `Parameters...`, map `Param_0 = User::LoadBatchKey`. Preview dự kiến 18 dòng.

##### Nếu Preview trả 0 dòng

Trong lúc thiết kế, `30_Load_Dimensions.dtsx` chưa được `00_Master.dtsx` truyền
batch key. Vì vậy `User::LoadBatchKey` có thể đang nhận giá trị thiết kế là `0` và
truy vấn vẫn đúng cột nhưng không trả dòng nào. Thực hiện tuần tự như sau.

**Bước A — tìm batch `SILVER_VALIDATED` trên SSMS**

1. Mở SSMS và chọn database `DanangSmartParkingDW`.
2. Mở **New Query**.
3. Chạy toàn bộ truy vấn sau:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus,
    RowsRead,
    RowsAccepted,
    RowsRejected,
    ErrorMessage,
    CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'SILVER_VALIDATED'
  AND ErrorMessage IS NULL
  AND CompletedAt IS NULL
ORDER BY LoadBatchKey DESC;
```

Ghi lại giá trị `LoadBatchKey`. Ví dụ, nếu SSMS trả về `18` thì số dùng để thử ở
các bước dưới là `18`; không mặc định mọi lần chạy đều là batch `18`.

**Bước B — xác nhận view nguồn thật sự có dữ liệu**

Thay số `18` trong truy vấn dưới bằng batch key vừa tìm được rồi chạy trên SSMS:

```sql
DECLARE @LoadBatchKey bigint = 18;

SELECT COUNT_BIG(*) AS CategoryRows
FROM DanangSmartParkingSTG.publish.vDimPOICategorySource
WHERE LoadBatchKey = @LoadBatchKey;

SELECT CategoryCode, CategoryName, SourceHashHex
FROM DanangSmartParkingSTG.publish.vDimPOICategorySource
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY CategoryCode;
```

Kết quả đúng của bộ dữ liệu hiện tại là `CategoryRows = 18`. Nếu SSMS cũng trả
`0`, chưa sửa SSIS; cần kiểm tra lại batch key hoặc việc chạy
`sql/26_prepare_dimension_data_flow.sql`.

**Bước C — tạm gán batch key thật cho biến SSIS để Preview**

1. Đóng cửa sổ **Preview Query Results** và **OLE DB Source Editor**.
2. Chuyển sang tab **Control Flow** của `30_Load_Dimensions.dtsx`.
3. Mở menu **SSIS > Variables**. Nếu không thấy menu này, nhấp chuột phải vùng
   trống trên Control Flow và chọn **Variables**.
4. Chọn biến `User::LoadBatchKey`. Kiểm tra:
   - `Data type = Int64`;
   - `Scope` là package `30_Load_Dimensions`, không phải một task con khác.
5. Nhấn `F4` để mở cửa sổ **Properties** của biến.
6. Ghi nhớ cấu hình chạy thật phải là:
   - `EvaluateAsExpression = True`;
   - `Expression = @[$Package::pLoadBatchKey]`.
7. Chỉ để thử Preview, đổi `EvaluateAsExpression` thành `False`.
8. Quay lại cửa sổ **Variables**, nhập số batch thật vào cột `Value`, ví dụ
   `18`. Chỉ nhập số, không nhập chữ `LoadBatchKey` và không nhập dấu ngoặc.

Khi `EvaluateAsExpression = True`, cột `Value` có thể không cho sửa. Phải thực
hiện bước 7 trước rồi mới nhập được số ở bước 8.

**Bước D — Preview lại source**

1. Quay lại **Data Flow** và mở `SRC - DimPOICategory`.
2. Kiểm tra connection là `(project) CM_DanangSTG`.
3. SQL command vẫn phải là:

```sql
SELECT CategoryCode, CategoryName, SourceHashHex
FROM publish.vDimPOICategorySource
WHERE LoadBatchKey = ?;
```

4. Nhấn **Parameters...** và kiểm tra đúng một mapping:
   `Param_0 = User::LoadBatchKey`.
5. Nhấn **Preview...**. Kết quả dự kiến là 18 dòng dữ liệu, không chỉ có tên cột.

**Bước E — bắt buộc khôi phục cấu hình động ngay sau Preview**

1. Đóng **Preview Query Results** và **OLE DB Source Editor**.
2. Mở lại cửa sổ **Variables** và chọn `User::LoadBatchKey`.
3. Trong **Properties**, khôi phục:
   - `EvaluateAsExpression = True`;
   - `Expression = @[$Package::pLoadBatchKey]`.
4. Nếu cần, đặt `Value` thiết kế về `0` trước khi bật lại
   `EvaluateAsExpression`. Khi chạy thật, expression sẽ lấy batch từ package
   parameter thay vì dùng số cố định.
5. Chọn **File > Save All** hoặc nhấn `Ctrl+Shift+S`.

Không để `User::LoadBatchKey = 18` theo kiểu cố định. Batch key thay đổi sau mỗi
lần chạy `00_Master.dtsx`; package 30 phải tiếp tục nhận batch từ
`pLoadBatchKey`.

Nếu đã gán đúng batch mà Preview vẫn là 0 dòng, kiểm tra lần lượt:

1. `CM_DanangSTG` đang trỏ tới database `DanangSmartParkingSTG`.
2. Source SQL chỉ có đúng một dấu `?`.
3. **Parameters...** đang map `Param_0` với `User::LoadBatchKey`.
4. Biến được chọn có đúng scope package `30_Load_Dimensions`.
5. Đóng rồi mở lại OLE DB Source Editor sau khi đổi giá trị biến để tránh dùng
   giá trị Preview đã được cache.

#### 9.8.2. Lookup

Tên `LKP - DimPOICategory Current`, connection `(project) CM_DanangDW`:

```sql
SELECT
    POICategoryKey AS CurrentKey,
    CategoryCode,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        CategoryCode, N'|', CategoryName)), 2) AS CurrentHashHex
FROM dwh.DimPOICategory;
```

1. `General`: Full cache và redirect no match.
2. `Columns`: nối `CategoryCode → CategoryCode`.
3. Tick output `CurrentKey`, `CurrentHashHex`.

##### 9.8.2.1. Hai nhánh insert và update nằm ở đâu?

Hai nhánh này **không phải hai task có sẵn trong Toolbox**. Chúng là hai đường dữ
liệu màu xanh đi ra từ `LKP - DimPOICategory Current` ngay trong Data Flow hiện tại:

```text
SRC - DimPOICategory
        |
        v
LKP - DimPOICategory Current
        |
        |-- Lookup No Match Output --> DST - DimPOICategory New
        |                              (nhánh INSERT)
        |
        `-- Lookup Match Output -----> SPL - DimPOICategory Changed
                                             |
                                             |-- Changed --> CMD - Update DimPOICategory
                                             |                (nhánh UPDATE)
                                             |
                                             `-- Unchanged --> không nối
```

Ý nghĩa:

- `Lookup No Match Output`: `CategoryCode` chưa tồn tại trong
  `dwh.DimPOICategory`, nên phải insert bằng **OLE DB Destination**.
- `Lookup Match Output`: `CategoryCode` đã tồn tại. Dòng này đi qua
  **Conditional Split** để so sánh hash; chỉ dòng thật sự thay đổi mới được update
  bằng **OLE DB Command**.

Đối chiếu đúng với ảnh hiện tại của bạn:

- Pipeline `DimCity` ở giữa màn hình đã có đủ cả hai nhánh và là mẫu trực quan để
  làm theo.
- Component nằm ngay dưới `LKP - DimPOICategory Current` đang nhận đường có nhãn
  `Lookup No Match Output`. Vì vậy nó chính là **nhánh insert**.
- Component đó đang bị đặt nhầm tên là `CMD - Update DimPOICategory`. Biểu tượng
  hình trụ với mũi tên xanh hướng vào cho biết nó là **OLE DB Destination**, không
  phải OLE DB Command. Hãy đổi tên nó thành `DST - DimPOICategory New`.
- Nhánh update của `DimPOICategory` hiện chưa có. Bạn cần tạo thêm Conditional
  Split và OLE DB Command ở bên phải Lookup.

#### 9.8.3. Nhánh insert

Trong ảnh, đây là đường thẳng đi xuống từ `LKP - DimPOICategory Current`, có nhãn
`Lookup No Match Output`.

Thực hiện như sau:

1. Bấm component đang có tên `CMD - Update DimPOICategory` ngay dưới Lookup.
2. Nhấn `F2`, hoặc chuột phải → **Rename**.
3. Đổi tên thành `DST - DimPOICategory New`.
4. Nhấp đúp `DST - DimPOICategory New`.
5. Trong **OLE DB Destination Editor**, cấu hình:
   - `OLE DB connection manager`: `(project) CM_DanangDW`.
   - `Data access mode`: `Table or view - fast load`.
   - `Name of the table or the view`: `[dwh].[DimPOICategory]`.
6. Chọn trang **Mappings** và map:

```text
CategoryCode → CategoryCode
CategoryName → CategoryName
```

7. Không map `POICategoryKey` vì đây là cột identity. Không map `SourceHashHex`,
   `CurrentHashHex` hoặc `CurrentKey`.
8. Bấm **OK**.

Nếu đường nối xuống component này không có nhãn `Lookup No Match Output`:

1. Xóa **chỉ đường nối sai**, không xóa component.
2. Kéo mũi tên xanh thường từ `LKP - DimPOICategory Current` xuống destination.
3. Trong hộp **Input Output Selection**, chọn:
   - `Output`: `Lookup No Match Output`;
   - `Input`: `OLE DB Destination Input`.
4. Không kéo mũi tên màu đỏ/cam vì đó là error output.

#### 9.8.4. Nhánh update

Nhánh này phải nằm **bên phải** `LKP - DimPOICategory Current`, tương tự cặp
`SPL - DimCity Changed` và `CMD - Update DimCity` đang có ở giữa ảnh.

Cách nhanh nhất là tái sử dụng hai component của `DimCity`:

1. Giữ `Ctrl`, bấm chọn cả:
   - `SPL - DimCity Changed`;
   - `CMD - Update DimCity`.
2. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
3. Kéo hai bản sao sang bên phải pipeline `DimPOICategory`.
4. Đổi tên bản sao thành:
   - `SPL - DimPOICategory Changed`;
   - `CMD - Update DimPOICategory`.
5. Xóa các đường nối mà bản sao còn giữ sai nguồn, nếu có.
6. Kéo **mũi tên xanh thường** từ `LKP - DimPOICategory Current` sang
   `SPL - DimPOICategory Changed`.
7. Trong **Input Output Selection**, chọn `Lookup Match Output`. Đây mới là đầu
   vào của nhánh update.
8. Nhấp đúp `SPL - DimPOICategory Changed`.
9. Tạo hoặc sửa output name thành `Changed` và nhập expression:

```text
[SourceHashHex] != [CurrentHashHex]
```

10. Có thể giữ `Conditional Split Default Output` làm nhánh `Unchanged`, nhưng
    **không nối nhánh này tới component nào**.
11. Bấm **OK**.
12. Kéo mũi tên xanh từ `SPL - DimPOICategory Changed` xuống
    `CMD - Update DimPOICategory`.
13. Khi được hỏi output, chọn `Changed`.
14. Nhấp đúp `CMD - Update DimPOICategory` và chọn connection
    `(project) CM_DanangDW`.
15. Nhập `SQLCommand`:

```sql
UPDATE dwh.DimPOICategory
SET CategoryName = ?
WHERE POICategoryKey = CONVERT(smallint, ?);
```

16. Mở **Column Mappings** và map đúng thứ tự dấu `?`:

```text
CategoryName → Param_0
CurrentKey   → Param_1
```

17. Bấm **OK** và lưu package bằng `Ctrl+S`.

Nếu không nhập được expression hoặc không nhìn thấy một trong hai cột hash, quay
lại kiểm tra:

- Source phải xuất cột `SourceHashHex`.
- Lookup phải tick đưa `CurrentHashHex` ra output trong trang **Columns**.
- Đường từ Lookup sang Conditional Split phải là `Lookup Match Output`.

Kết quả đúng của pipeline `DimPOICategory` phải có đủ hai đường:

```text
No Match → DST - DimPOICategory New
Match → SPL - DimPOICategory Changed → Changed → CMD - Update DimPOICategory
```

### 9.9. Kiểm tra toàn bộ `DFT - L0 Reference Dimensions`

Trên canvas phải có 7 pipeline độc lập:

```text
DimDate
DimTime
DimCity
DimRoadSide
DimVehicleType
DimPOICategory
DimWeatherSource
```

Trước khi chạy, kiểm tra:

- tất cả Source dùng `(project) CM_DanangSTG`;
- tất cả Lookup/Destination/OLE DB Command dùng `(project) CM_DanangDW`;
- `DimDate`, `DimPOICategory`, `DimWeatherSource` đã map
  `Param_0 = User::LoadBatchKey`;
- bốn query không có dấu `?` không được cấu hình Parameters;
- đường tới destination mang nhãn `Lookup No Match Output`;
- không component hoặc đường nối nào có dấu X đỏ.

### 9.10. Debug riêng level 0

Chưa chạy toàn bộ `00_Master.dtsx` ở đây vì các level dimension sau chưa hoàn tất.
Hãy chạy riêng task level 0:

1. Mở package `30_Load_Dimensions.dtsx`.
2. Mở tab `Parameters` và lấy tên parameter batch của package, thông thường là
   `pLoadBatchKey` kiểu `Int64`.
3. Trong SSMS lấy batch Silver mới nhất:

```sql
SELECT TOP (1) LoadBatchKey, LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'SILVER_VALIDATED'
ORDER BY LoadBatchKey DESC;
```

4. Quay lại SSIS, nhập **chỉ con số** vừa nhận vào Value của `pLoadBatchKey`, ví dụ
   `18`; không nhập chữ `LoadBatchKey`.
5. Nếu Data Flow đang dùng variable `User::LoadBatchKey`, kiểm tra variable này có
   expression hoặc task gán giá trị từ parameter. Nếu tài liệu mục 5 đã cấu hình
   sẵn thì không sửa lại.
6. Mở `Control Flow`, nhấp phải `DFT - L0 Reference Dimensions` và chọn
   `Execute Task`.
7. Chờ cả 7 pipeline xanh. Lần chạy đầu số dòng ở destination dự kiến:

| Dimension | Số dòng nguồn |
|---|---:|
| `DimDate` | 7 |
| `DimTime` | 1,440 |
| `DimCity` | 1 |
| `DimRoadSide` | 5 |
| `DimVehicleType` | 5 |
| `DimPOICategory` | 18 |
| `DimWeatherSource` | 1 |

Nếu bảng đích đã có dữ liệu từ lần chạy trước thì Lookup sẽ chuyển các dòng sang
Match và destination có thể hiện `0 rows`; đó là hành vi idempotent hợp lệ.

8. Chọn `Debug → Stop Debugging` nếu Visual Studio chưa tự thoát chế độ debug.
9. Sau khi debug riêng thành công, trả Value của `pLoadBatchKey` về `0`. Khi chạy
   từ Master, giá trị thật phải được truyền qua `Parameter Bindings`.

### 9.11. Đối soát level 0 trong SSMS

Chạy:

```sql
SELECT 'DimDate' AS DimensionName, COUNT_BIG(*) AS ActualRows, 7 AS ExpectedRows
FROM DanangSmartParkingDW.dwh.DimDate
UNION ALL
SELECT 'DimTime', COUNT_BIG(*), 1440
FROM DanangSmartParkingDW.dwh.DimTime
UNION ALL
SELECT 'DimCity', COUNT_BIG(*), 1
FROM DanangSmartParkingDW.dwh.DimCity
UNION ALL
SELECT 'DimRoadSide', COUNT_BIG(*), 5
FROM DanangSmartParkingDW.dwh.DimRoadSide
UNION ALL
SELECT 'DimVehicleType', COUNT_BIG(*), 5
FROM DanangSmartParkingDW.dwh.DimVehicleType
UNION ALL
SELECT 'DimPOICategory', COUNT_BIG(*), 18
FROM DanangSmartParkingDW.dwh.DimPOICategory
UNION ALL
SELECT 'DimWeatherSource', COUNT_BIG(*), 1
FROM DanangSmartParkingDW.dwh.DimWeatherSource;
```

Mỗi `ActualRows` phải bằng `ExpectedRows`. Sau đó kiểm tra nhanh Unicode:

```sql
SELECT CityCode, CityName, ScopeNote, DataWarning
FROM DanangSmartParkingDW.dwh.DimCity;

SELECT TOP (20) POICategoryKey, CategoryCode, CategoryName
FROM DanangSmartParkingDW.dwh.DimPOICategory
ORDER BY CategoryCode;
```

Nếu level 0 đạt, lưu package bằng `Ctrl+S` rồi mới chuyển sang level 1 tại mục 10.

### 9.12. Xử lý lỗi metadata thường gặp sau khi copy

Nếu Source/Lookup/Destination vẫn mang cột của `DimDate`:

1. Xóa hai đường nối quanh component bị lỗi.
2. Mở Source, dán đúng query mới, mở `Columns`, nhấn `OK`.
3. Mở Lookup, thay query, mở `Columns`, tạo lại join, nhấn `OK`.
4. Nối lại Source → Lookup.
5. Mở Destination, chọn lại bảng đích, mở `Mappings`, xóa mapping cũ và map lại.
6. Nối Lookup No Match Output → Destination.

Nếu vẫn không hết dấu X đỏ, xóa riêng Lookup hoặc Destination của **bản copy** và
kéo component mới từ Toolbox. Không xóa pipeline `DimDate` đã hoàn thành.

### 9.13. Thứ tự làm khuyến nghị

Làm và kiểm tra từng pipeline theo thứ tự sau, không copy sáu pipeline cùng lúc:

```text
DimTime → DimRoadSide → DimVehicleType → DimWeatherSource
        → DimCity → DimPOICategory → debug toàn level 0
```

Ba pipeline đầu giúp bạn quen thao tác insert-only; hai pipeline Type 1 để sau vì có
thêm nhánh update.

## 10. Data Flow level 1 — Analysis Zone

### 10.1. Tạo task

1. Quay lại Control Flow.
2. Tạo Data Flow Task `DFT - L1 Analysis Zone`.
3. Nối success từ `DFT - L0 Reference Dimensions`.
4. Mở Data Flow của task.

### 10.2. Pipeline

`DimAnalysisZone` phụ thuộc `DimCity`, vì vậy task level 1 chỉ được chạy sau khi
`DFT - L0 Reference Dimensions` đã thành công. Pipeline cần tạo có hình dạng:

```text
SRC - DimAnalysisZone
        |
        v
LKP - DimAnalysisZone Current
        | No Match                         | Match
        v                                  v
DST - DimAnalysisZone New       SPL - DimAnalysisZone Changed
                                           | Changed
                                           v
                                CMD - Update DimAnalysisZone

                                Unchanged: không nối đi đâu
```

Trong sơ đồ trên:

- nhánh **No Match** là nhánh **insert**;
- nhánh **Match → Changed** là nhánh **update**;
- dòng Match nhưng hash không đổi đi vào `Unchanged` và kết thúc, không ghi lại DB.

#### 10.2.1. Sao chép pipeline Type 1 từ level 0

Nên sao chép pipeline `DimCity` vì nó đã có đủ cả insert và update. Không sao chép
`DimDate`, vì `DimDate` chỉ có nhánh insert.

1. Trong tab `30_Load_Dimensions.dtsx`, mở tab **Data Flow**.
2. Ở combobox **Data Flow Task** phía trên canvas, chọn
   `DFT - L0 Reference Dimensions`.
3. Giữ `Ctrl`, bấm chọn đúng 5 component của pipeline City:
   - `SRC - DimCity`;
   - `LKP - DimCity Current`;
   - `DST - DimCity New`;
   - `SPL - DimCity Changed`;
   - `CMD - Update DimCity`.
4. Nhấn `Ctrl+C`.
5. Ở combobox **Data Flow Task**, chuyển sang `DFT - L1 Analysis Zone`.
6. Nhấn `Ctrl+V`, rồi kéo cả nhóm sang vị trí dễ nhìn.
7. Đổi tên lần lượt thành:
   - `SRC - DimAnalysisZone`;
   - `LKP - DimAnalysisZone Current`;
   - `DST - DimAnalysisZone New`;
   - `SPL - DimAnalysisZone Changed`;
   - `CMD - Update DimAnalysisZone`.

Chỉ đổi tên trên canvas **không thay đổi metadata**. Phải mở và cấu hình lại từng
component theo các bước dưới đây.

Để tránh các đường nối vẫn giữ metadata cũ của `DimCity`, trong bản sao level 1 hãy
bấm từng đường nối và nhấn `Delete` để xóa bốn đường sau:

1. Source → Lookup.
2. Lookup No Match → Destination.
3. Lookup Match → Conditional Split.
4. Conditional Split Changed → OLE DB Command.

Không xóa component. Ta sẽ nối lại sau khi từng component đã được cấu hình đúng.

#### 10.2.2. Cấu hình Source `SRC - DimAnalysisZone`

1. Nhấp đúp `SRC - DimAnalysisZone`.
2. Tại **OLE DB connection manager**, chọn `(project) CM_DanangSTG`.
3. Tại **Data access mode**, chọn `SQL command`.
4. Xóa SQL của `DimCity` và dán toàn bộ truy vấn sau:

```sql
SELECT
    ZoneBusinessKey,
    ZoneName,
    ZoneType,
    IsCoastal,
    CityKey,
    SourceHashHex
FROM publish.vDimAnalysisZoneSource
WHERE LoadBatchKey = ?;
```

5. Bấm **Parameters...**.
6. Ở dòng `Param_0`, chọn biến `User::LoadBatchKey` rồi bấm **OK**.
7. Mở trang **Columns** và kiểm tra đủ 6 cột:
   `ZoneBusinessKey`, `ZoneName`, `ZoneType`, `IsCoastal`, `CityKey`,
   `SourceHashHex`.
8. Quay lại **Connection Manager**, bấm **Preview...**.

Kết quả đúng của bộ dữ liệu hiện tại là **10 dòng** và không có `CityKey` null.

Nếu Preview trả 0 dòng, kiểm tra batch trên SSMS trước:

```sql
SELECT TOP (1)
    LoadBatchKey,
    LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadStatus = 'SILVER_VALIDATED'
ORDER BY LoadBatchKey DESC;
```

Sau đó quay lại SSIS:

1. Mở tab **Parameters** của `30_Load_Dimensions.dtsx`.
2. Ghi nhớ giá trị hiện tại của `pLoadBatchKey`.
3. Tạm nhập vào cột **Value** đúng số `LoadBatchKey` vừa lấy từ SSMS, ví dụ `18`.
4. Mở lại Source và bấm **Preview...**.
5. Sau khi debug riêng package 30 xong, phải trả `pLoadBatchKey` về `0`; khi chạy
   từ `00_Master.dtsx`, master sẽ truyền batch key thật vào package con.

Có thể kiểm tra trực tiếp nguồn trên SSMS bằng số batch vừa tìm được:

```sql
DECLARE @LoadBatchKey bigint = 18; -- thay bằng batch SILVER_VALIDATED thực tế

SELECT
    COUNT_BIG(*) AS SourceRows,
    SUM(CASE WHEN CityKey IS NULL THEN CONVERT(bigint, 1) ELSE 0 END)
        AS NullCityKeyRows
FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource
WHERE LoadBatchKey = @LoadBatchKey;
```

Kết quả mong đợi: `SourceRows = 10`, `NullCityKeyRows = 0`.

#### 10.2.3. Cấu hình Lookup `LKP - DimAnalysisZone Current`

1. Kéo mũi tên xanh từ `SRC - DimAnalysisZone` sang
   `LKP - DimAnalysisZone Current`.
2. Nhấp đúp Lookup.
3. Trang **General**:
   - chọn `Full cache`;
   - chọn `Redirect rows to no match output`.
4. Trang **Connection**:
   - chọn `(project) CM_DanangDW`;
   - chọn `Use results of an SQL query`;
   - dán SQL sau:

```sql
SELECT
    ZoneKey AS CurrentKey,
    ZoneBusinessKey,
    CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
        ZoneBusinessKey, N'|', ZoneName, N'|', ZoneType, N'|',
        IsCoastal, N'|',
        COALESCE(CONVERT(varchar(20), CityKey), '<NULL>')
    )), 2) AS CurrentHashHex
FROM dwh.DimAnalysisZone;
```

5. Bấm **Preview...** nếu muốn kiểm tra các dòng hiện có trong target, rồi đóng
   cửa sổ Preview.
6. Mở trang **Columns**.
7. Kéo cột `ZoneBusinessKey` ở bảng bên trái sang `ZoneBusinessKey` ở bảng bên
   phải để tạo đường join.
8. Ở danh sách output phía dưới, tick:
   - `CurrentKey`;
   - `CurrentHashHex`.
9. Không tick thêm `ZoneBusinessKey` ở output vì cột nguồn đã có cùng tên.
10. Bấm **OK**.

#### 10.2.4. Tạo nhánh insert — Lookup No Match

Đây chính là “nhánh insert”; nó nằm trên canvas, đi từ Lookup đến OLE DB
Destination.

1. Kéo mũi tên xanh từ `LKP - DimAnalysisZone Current` sang
   `DST - DimAnalysisZone New`.
2. Khi cửa sổ **Input Output Selection** xuất hiện, tại **Output** chọn
   `Lookup No Match Output`, rồi bấm **OK**.
3. Nhấp đúp `DST - DimAnalysisZone New`.
4. Chọn `(project) CM_DanangDW`.
5. **Data access mode**: chọn `Table or view - fast load`.
6. **Name of the table or the view**: chọn `[dwh].[DimAnalysisZone]`.
7. Mở trang **Mappings** và map đúng:

| Available Input Column | Available Destination Column |
|---|---|
| `ZoneBusinessKey` | `ZoneBusinessKey` |
| `ZoneName` | `ZoneName` |
| `ZoneType` | `ZoneType` |
| `IsCoastal` | `IsCoastal` |
| `CityKey` | `CityKey` |

Không map `ZoneKey` vì đây là cột identity. Cũng không map `SourceHashHex`,
`CurrentKey` hoặc `CurrentHashHex` vì chúng chỉ phục vụ điều khiển luồng.

8. Bấm **OK**. Đường nối phải có nhãn `Lookup No Match Output`.

#### 10.2.5. Tạo nhánh update — Lookup Match

Đây chính là “nhánh update”; nó đi từ Lookup qua Conditional Split rồi đến OLE DB
Command.

1. Kéo mũi tên xanh của Lookup một lần nữa sang
   `SPL - DimAnalysisZone Changed`.
2. Trong **Input Output Selection**, chọn `Lookup Match Output` rồi bấm **OK**.
3. Nhấp đúp `SPL - DimAnalysisZone Changed`.
4. Tạo một output có tên `Changed`.
5. Bấm vào ô **Condition** của dòng `Changed` rồi nhập:

```text
[SourceHashHex] != [CurrentHashHex]
```

Nếu không paste được vào ô Condition:

1. Bấm một lần vào ô Condition để ô chuyển sang trạng thái nhập liệu; có thể nhấn
   `F2`.
2. Mở thư mục **Columns** ở khung trên bên trái.
3. Nhấp đúp `SourceHashHex` để SSIS chèn `[SourceHashHex]`.
4. Gõ ` != `.
5. Nhấp đúp `CurrentHashHex` để chèn `[CurrentHashHex]`.

6. Ở dưới cùng, đổi **Default output name** thành `Unchanged`.
7. Bấm **OK**. Không nối output `Unchanged` đi đâu cả.
8. Kéo mũi tên xanh từ Conditional Split sang `CMD - Update DimAnalysisZone`.
9. Khi được hỏi output nào, chọn `Changed`.
10. Nhấp đúp `CMD - Update DimAnalysisZone`.
11. Tại **Connection Manager**, chọn `(project) CM_DanangDW`.
12. Tại **SQLCommand**, dán:

```sql
UPDATE dwh.DimAnalysisZone
SET ZoneName = ?,
    ZoneType = ?,
    IsCoastal = ?,
    CityKey = CONVERT(smallint, ?)
WHERE ZoneKey = CONVERT(int, ?);
```

13. Mở **Column Mappings** và map theo đúng thứ tự dấu `?`:

| Input column | Destination parameter |
|---|---|
| `ZoneName` | `Param_0` |
| `ZoneType` | `Param_1` |
| `IsCoastal` | `Param_2` |
| `CityKey` | `Param_3` |
| `CurrentKey` | `Param_4` |

14. Bấm **OK**.

#### 10.2.6. Kiểm tra hình dạng pipeline trước khi chạy

Trên canvas phải có đúng bốn đường dữ liệu:

1. `SRC - DimAnalysisZone` → `LKP - DimAnalysisZone Current`.
2. `Lookup No Match Output` → `DST - DimAnalysisZone New`.
3. `Lookup Match Output` → `SPL - DimAnalysisZone Changed`.
4. `Changed` → `CMD - Update DimAnalysisZone`.

Không được còn dấu X đỏ trên component hoặc đường nối. Nếu component được copy vẫn
hiển thị cột của `DimCity`, xóa riêng component đó và tạo lại component cùng loại sẽ
nhanh và an toàn hơn cố sửa metadata hỏng.

#### 10.2.7. Debug riêng level 1

Không chạy toàn bộ `00_Master.dtsx` ở bước này.

1. Nhấn `Ctrl+S` để lưu package.
2. Đảm bảo `pLoadBatchKey` đang tạm mang số batch `SILVER_VALIDATED` thật.
3. Quay lại tab **Control Flow** của `30_Load_Dimensions.dtsx`.
4. Bấm phải `DFT - L1 Analysis Zone` → chọn **Execute Task**.
5. Chờ task chuyển sang màu xanh.

Ở lần chạy đầu tiên khi `dwh.DimAnalysisZone` còn trống, kết quả dự kiến:

- Source: 10 dòng;
- Lookup No Match: 10 dòng;
- Destination insert: 10 dòng;
- nhánh Changed/update: 0 dòng.

Chạy riêng task thêm lần thứ hai để kiểm tra idempotent:

- Source vẫn 10 dòng;
- target vẫn chỉ 10 dòng;
- No Match = 0;
- Changed = 0 vì dữ liệu không đổi.

Sau khi debug xong, quay lại **Parameters** và trả `pLoadBatchKey` về `0` để master
truyền giá trị thật khi chạy toàn luồng.

#### 10.2.8. Đối soát level 1 trên SSMS

Mở **New Query** trong SSMS và chạy toàn bộ khối sau:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    WHERE LoadStatus = 'SILVER_VALIDATED'
    ORDER BY LoadBatchKey DESC
);

-- 1. Nguồn level 1 phải có 10 dòng và đã lookup được CityKey.
SELECT
    COUNT_BIG(*) AS SourceRows,
    SUM(CASE WHEN CityKey IS NULL THEN CONVERT(bigint, 1) ELSE 0 END)
        AS NullCityKeyRows
FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Target phải có đúng 10 analysis zone.
SELECT COUNT_BIG(*) AS TargetRows
FROM DanangSmartParkingDW.dwh.DimAnalysisZone;

-- 3. Mọi business key ở source phải có trong target.
SELECT COUNT_BIG(*) AS MissingTargetRows
FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource AS SourceRow
LEFT JOIN DanangSmartParkingDW.dwh.DimAnalysisZone AS TargetRow
  ON TargetRow.ZoneBusinessKey = SourceRow.ZoneBusinessKey
WHERE SourceRow.LoadBatchKey = @LoadBatchKey
  AND TargetRow.ZoneKey IS NULL;

-- 4. Không được có CityKey mồ côi.
SELECT COUNT_BIG(*) AS OrphanCityRows
FROM DanangSmartParkingDW.dwh.DimAnalysisZone AS Zone
LEFT JOIN DanangSmartParkingDW.dwh.DimCity AS City
  ON City.CityKey = Zone.CityKey
WHERE City.CityKey IS NULL;

-- 5. Không được trùng business key.
SELECT COUNT_BIG(*) AS DuplicateBusinessKeys
FROM
(
    SELECT ZoneBusinessKey
    FROM DanangSmartParkingDW.dwh.DimAnalysisZone
    GROUP BY ZoneBusinessKey
    HAVING COUNT_BIG(*) > 1
) AS DuplicateRows;

-- 6. Hash source và target phải giống nhau sau insert/update.
SELECT COUNT_BIG(*) AS HashMismatchRows
FROM DanangSmartParkingSTG.publish.vDimAnalysisZoneSource AS SourceRow
JOIN DanangSmartParkingDW.dwh.DimAnalysisZone AS TargetRow
  ON TargetRow.ZoneBusinessKey = SourceRow.ZoneBusinessKey
WHERE SourceRow.LoadBatchKey = @LoadBatchKey
  AND SourceRow.SourceHashHex <>
      CONVERT(char(64), HASHBYTES('SHA2_256', CONCAT(
          TargetRow.ZoneBusinessKey, N'|', TargetRow.ZoneName, N'|',
          TargetRow.ZoneType, N'|', TargetRow.IsCoastal, N'|',
          COALESCE(CONVERT(varchar(20), TargetRow.CityKey), '<NULL>')
      )), 2);

-- 7. Xem dữ liệu đã nạp và quan hệ City.
SELECT
    Zone.ZoneKey,
    Zone.ZoneBusinessKey,
    Zone.ZoneName,
    Zone.ZoneType,
    Zone.IsCoastal,
    City.CityKey,
    City.CityName
FROM DanangSmartParkingDW.dwh.DimAnalysisZone AS Zone
JOIN DanangSmartParkingDW.dwh.DimCity AS City
  ON City.CityKey = Zone.CityKey
ORDER BY Zone.ZoneBusinessKey;
```

Các kết quả đạt yêu cầu:

| Chỉ tiêu | Giá trị |
|---|---:|
| `SourceRows` | 10 |
| `NullCityKeyRows` | 0 |
| `TargetRows` | 10 |
| `MissingTargetRows` | 0 |
| `OrphanCityRows` | 0 |
| `DuplicateBusinessKeys` | 0 |
| `HashMismatchRows` | 0 |

Chỉ chuyển sang level 2 khi tất cả kiểm tra trên đạt. Sau khi hoàn thành, level 0 có
hai pipeline Type 1 hoàn chỉnh (`DimCity`, `DimPOICategory`) và level 1 có một
pipeline Type 1 hoàn chỉnh (`DimAnalysisZone`).

## 11. Data Flow level 2 — Road, Facility, POI

### 11.1. Tạo task

Level 2 nạp ba dimension SCD2:

- `dwh.DimRoad`;
- `dwh.DimParkingFacility`;
- `dwh.DimPOI`.

Mỗi pipeline phải xử lý đủ ba trường hợp:

1. business key chưa tồn tại: insert phiên bản đầu tiên;
2. business key đã tồn tại và dữ liệu không đổi: bỏ qua;
3. business key đã tồn tại nhưng thuộc tính thay đổi: đóng phiên bản hiện tại rồi
   insert phiên bản mới.

#### 11.1.1. Kiểm tra nguồn level 2 trên SSMS

Trước khi thiết kế Data Flow, mở **SSMS** → **New Query**, dán và chạy toàn bộ
đoạn sau:

```sql
USE DanangSmartParkingSTG;
GO

DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadBatch
    WHERE LoadStatus = 'SILVER_VALIDATED'
    ORDER BY LoadBatchKey DESC
);

SELECT @LoadBatchKey AS LoadBatchKey;

SELECT
    'publish.vDimRoadSource' AS ObjectName,
    COUNT_BIG(*) AS ActualRows,
    CONVERT(bigint, 30) AS ExpectedRows
FROM publish.vDimRoadSource
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'publish.vDimParkingFacilitySource', COUNT_BIG(*), CONVERT(bigint, 20)
FROM publish.vDimParkingFacilitySource
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT
    'publish.vDimPOISource', COUNT_BIG(*), CONVERT(bigint, 50)
FROM publish.vDimPOISource
WHERE LoadBatchKey = @LoadBatchKey;
```

Kết quả đúng:

| Source | ActualRows |
|---|---:|
| `publish.vDimRoadSource` | 30 |
| `publish.vDimParkingFacilitySource` | 20 |
| `publish.vDimPOISource` | 50 |

Nếu `@LoadBatchKey` là `NULL` hoặc cả ba source trả `0`, chưa tạo Data Flow vội.
Kiểm tra lại package 23 và chỉ tiếp tục khi batch có trạng thái
`SILVER_VALIDATED`.

#### 11.1.2. Tạo Data Flow Task ở Control Flow

Thao tác trong **Visual Studio/SSDT**:

1. Mở package `30_Load_Dimensions.dtsx`.
2. Chọn tab **Control Flow**.
3. Trong **SSIS Toolbox**, kéo một **Data Flow Task** xuống dưới
   `DFT - L1 Analysis Zone`.
4. Chọn task vừa tạo, nhấn `F2`, đổi tên thành:

   ```text
   DFT - L2 Road Facility POI
   ```

5. Bấm một lần vào `DFT - L1 Analysis Zone`.
6. Kéo **mũi tên xanh** từ level 1 xuống
   `DFT - L2 Road Facility POI`.
7. Nhấp đúp mũi tên vừa nối và kiểm tra:

   - **Evaluation operation**: `Constraint`;
   - **Value**: `Success`;
   - đường nối phải có màu xanh.

8. Nhấn `Ctrl+Shift+S` để lưu toàn bộ solution.

Không nối level 1 và level 2 bằng mũi tên đỏ. Mũi tên đỏ trong Control Flow có
nghĩa là chỉ chạy level 2 khi level 1 thất bại.

#### 11.1.3. Mở Data Flow và hiểu cấu trúc một pipeline SCD2

1. Nhấp đúp `DFT - L2 Road Facility POI`.
2. Visual Studio chuyển sang tab **Data Flow**.
3. Trong Data Flow này sẽ có ba pipeline đứng độc lập, không nối chéo dữ liệu với
   nhau.

Cấu trúc của mỗi pipeline:

```text
SRC ──> LKP
        ├─ Lookup No Match Output ────────────────────────┐
        │                                                 v
        └─ Lookup Match Output ─> SPL ─> Changed ─> CMD ─> UNI ─> DST
                                  └─ Default/Unchanged: không nối
```

Ý nghĩa:

- `SRC`: đọc dữ liệu Silver cần nạp;
- `LKP`: tìm phiên bản hiện tại trong dimension theo business key;
- `Lookup No Match Output`: dòng hoàn toàn mới, đi thẳng tới `UNI` để insert;
- `Lookup Match Output`: business key đã tồn tại, chuyển sang `SPL` để so sánh
  hash;
- `SPL`: chỉ cho dòng có hash thay đổi đi tiếp;
- `CMD`: đóng phiên bản hiện tại bằng `IsCurrent = 0`;
- `UNI`: gom dòng hoàn toàn mới và dòng vừa đóng phiên bản cũ;
- `DST`: insert phiên bản mới vào dimension.

Các đường nối trên sơ đồ này là **mũi tên xanh của Data Flow**. Không dùng mũi
tên đỏ error output của component.

### 11.2. Pipeline `DimRoad` — hoàn thiện theo đúng 6 component

Hãy làm xong toàn bộ pipeline `DimRoad` trước khi copy sang dimension khác. Pipeline
hoàn chỉnh phải có đúng sáu component sau:

| Thứ tự | Loại component | Tên trên canvas |
|---:|---|---|
| 1 | OLE DB Source | `SRC - DimRoad` |
| 2 | Lookup | `LKP - DimRoad Current` |
| 3 | Conditional Split | `SPL - DimRoad Changed` |
| 4 | OLE DB Command | `CMD - Close Current DimRoad` |
| 5 | Union All | `UNI - DimRoad New Version` |
| 6 | OLE DB Destination | `DST - DimRoad New Version` |

Luồng dữ liệu phải có hai nhánh:

```text
SRC - DimRoad
    |
LKP - DimRoad Current
    |-- Lookup No Match Output ----------------------\
    |                                                |
    \-- Lookup Match Output                          |
              |                                      |
       SPL - DimRoad Changed                         |
              | Changed                              |
       CMD - Close Current DimRoad                   |
              |                                      |
              \--------------------------------------/
                         |
                UNI - DimRoad New Version
                         |
                DST - DimRoad New Version
```

- `No Match` là business key chưa tồn tại: đưa thẳng sang `Union All` để insert.
- `Match + Changed` là business key đã tồn tại nhưng thuộc tính thay đổi: đóng bản ghi
  hiện tại bằng `OLE DB Command`, rồi đưa sang `Union All` để insert phiên bản mới.
- `Match + Unchanged` là bản ghi không đổi: bỏ qua, không insert và không update.

#### 11.2.1. Component 1 — OLE DB Source `SRC - DimRoad`

Mục tiêu của component này là lấy đúng 30 dòng nguồn Road đã được chuẩn hóa tại tầng
`publish` của database staging.

1. Trong tab `Data Flow` của `DFT - L2 Road Facility POI`, kéo `OLE DB Source` từ
   `SSIS Toolbox` vào canvas.
2. Đổi tên component thành `SRC - DimRoad`.
3. Nhấp đúp `SRC - DimRoad`.
4. Trong `OLE DB Source Editor` cấu hình:

   - `OLE DB connection manager`: chọn `(project) CM_DanangSTG`.
   - `Data access mode`: chọn `SQL command`.
   - `SQL command text`: dán toàn bộ câu SQL sau:

```sql
SELECT
    RoadID,
    RoadName,
    ZoneKey,
    RoadClass,
    LaneCount,
    SpeedLimitKmh,
    MasterRoadWidthM,
    LengthKm,
    NameStatus,
    GeometryStatus,
    WidthStatus,
    SourceNote,
    ValidFrom,
    ValidTo,
    IsCurrent,
    AttributeHash,
    SourceHashHex
FROM publish.vDimRoadSource
WHERE LoadBatchKey = ?;
```

5. Bấm `Parameters...`.
6. Trong cửa sổ `Set Query Parameters`, cấu hình:

| Parameters | Variables |
|---|---|
| `Param_0` | `User::LoadBatchKey` |

7. Bấm `OK` để đóng cửa sổ parameter.
8. Bấm `Parse Query`. Phải không có lỗi.
9. Bấm `Preview...`. Với batch `SILVER_VALIDATED` đúng, phải có `30` dòng.
10. Đóng Preview, mở trang `Columns` và xác nhận các cột trong câu `SELECT` đều xuất
    hiện.
11. Bấm `OK`.

Nếu Preview trả `0` dòng, không sửa câu SQL ngay. Chạy trên SSMS:

```sql
SELECT TOP (10)
    LoadBatchKey,
    LoadStatus
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;
```

Lấy `LoadBatchKey` mới nhất có `LoadStatus = 'SILVER_VALIDATED'`. Khi debug riêng
package 30, có thể tạm nhập con số đó vào Value của package parameter
`pLoadBatchKey`. Sau khi thử xong phải trả Value về `0` để `00_Master.dtsx` truyền
batch key động vào package.

Điểm hoàn thành component 1:

- `SRC - DimRoad` không còn dấu X đỏ.
- Preview có 30 dòng.
- Parameter `Param_0` đang gắn với `User::LoadBatchKey`, không hard-code trong SQL.

#### 11.2.2. Component 2 — Lookup `LKP - DimRoad Current`

Mục tiêu của Lookup là chia dữ liệu thành hai nhóm: Road chưa tồn tại và Road đã có
bản ghi hiện tại.

1. Kéo `Lookup` vào canvas, đặt dưới `SRC - DimRoad`.
2. Đổi tên thành `LKP - DimRoad Current`.
3. Kéo mũi tên xanh từ `SRC - DimRoad` vào Lookup.
4. Nhấp đúp Lookup.
5. Trang `General`:

   - `Cache mode`: chọn `Full cache`.
   - `Specify how to handle rows with no matching entries`:
     chọn `Redirect rows to no match output`.

6. Trang `Connection`:

   - Chọn `(project) CM_DanangDW`.
   - Chọn `Use results of an SQL query`.
   - Dán câu SQL:

```sql
SELECT
    RoadKey AS CurrentKey,
    RoadID,
    CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimRoad
WHERE IsCurrent = 1;
```

7. Bấm `Preview...` nếu cần:

   - Lần chạy DW đầu tiên có thể trả 0 dòng; đây là bình thường.
   - Sau khi đã load Road, Preview sẽ thấy các bản ghi `IsCurrent = 1`.

8. Sang trang `Columns`.
9. Kéo `RoadID` ở bảng `Available Input Columns` sang `RoadID` ở bảng
   `Available Lookup Columns`.
10. Trong bảng lookup bên phải, đánh dấu hai cột output:

    - `CurrentKey`;
    - `CurrentHashHex`.

11. Giữ tên output đúng là `CurrentKey` và `CurrentHashHex`.
12. Bấm `OK`.

Sau khi Lookup được cấu hình, nó có hai output dữ liệu cần dùng:

- `Lookup No Match Output`: dùng để insert Road mới;
- `Lookup Match Output`: dùng để kiểm tra hash và phát hiện Road thay đổi.

Lưu ý: mũi tên `Lookup No Match Output` là output dữ liệu màu xanh sau khi đã chọn
`Redirect rows to no match output`. Không dùng mũi tên đỏ vì đó là error output.

Điểm hoàn thành component 2:

- Join là `RoadID -> RoadID`.
- Có hai cột mới `CurrentKey` và `CurrentHashHex`.
- Lookup được cấu hình Redirect cho dòng không match.

#### 11.2.3. Component 3 — Conditional Split `SPL - DimRoad Changed`

Component này chỉ nhận nhánh `Lookup Match Output` và giữ lại những Road có hash
thay đổi.

1. Kéo `Conditional Split` vào canvas.
2. Đổi tên thành `SPL - DimRoad Changed`.
3. Kéo mũi tên xanh từ `LKP - DimRoad Current` sang Conditional Split.
4. Khi cửa sổ `Input Output Selection` xuất hiện, chọn:

   - `Output`: `Lookup Match Output`;
   - bấm `OK`.

5. Nhấp đúp `SPL - DimRoad Changed`.
6. Tạo một dòng output:

   - `Output Name`: `Changed`;
   - `Condition`:

```text
[SourceHashHex] != [CurrentHashHex]
```

7. Đổi `Default output name` thành `Unchanged` để dễ hiểu.
8. Bấm `OK`.

Nếu không paste được expression:

1. Nhấp đúng vào ô trống của cột `Condition` trên dòng `Changed`.
2. Mở cây `Columns` phía trên.
3. Nhấp đúp hoặc kéo `SourceHashHex` vào ô expression.
4. Gõ ` != `.
5. Nhấp đúp hoặc kéo `CurrentHashHex` vào sau toán tử.
6. Expression cuối cùng phải đúng dấu ngoặc vuông như sau:

```text
[SourceHashHex] != [CurrentHashHex]
```

Không đặt tên cột trong dấu nháy. Nếu không thấy `CurrentHashHex` trong cây Columns,
quay lại component Lookup, trang `Columns` và đánh dấu output `CurrentHashHex`.

Nhánh `Unchanged` cố ý không nối đi đâu. Những dòng này không cần ghi lại DW.

Điểm hoàn thành component 3:

- Input của Split là `Lookup Match Output`.
- Có output `Changed` với biểu thức so sánh hash.
- Default output là `Unchanged` và được bỏ qua.

#### 11.2.4. Component 4 — OLE DB Command `CMD - Close Current DimRoad`

Component này đóng phiên bản Road hiện tại trước khi phiên bản mới được insert.

1. Kéo `OLE DB Command` vào canvas.
2. Đổi tên thành `CMD - Close Current DimRoad`.
3. Kéo output `Changed` của `SPL - DimRoad Changed` vào OLE DB Command.
4. Nhấp đúp `CMD - Close Current DimRoad`.
5. Trong `Connection Managers` chọn `(project) CM_DanangDW`.
6. Tại `SQLCommand` dán:

```sql
UPDATE dwh.DimRoad
SET
    ValidTo = ?,
    IsCurrent = 0
WHERE RoadKey = CONVERT(int, ?)
  AND IsCurrent = 1;
```

7. Mở trang `Column Mappings`.
8. Mapping đúng thứ tự dấu `?`:

| Input Column | Destination Column |
|---|---|
| `ValidFrom` | `Param_0` |
| `CurrentKey` | `Param_1` |

9. Bấm `OK`.

Ý nghĩa:

- `Param_0` nhận `ValidFrom` của phiên bản mới và dùng làm `ValidTo` của phiên bản cũ.
- `Param_1` nhận surrogate key của phiên bản hiện tại cần đóng.

Không đảo thứ tự hai parameter. OLE DB Command xác định parameter hoàn toàn theo thứ
tự dấu `?` trong câu SQL.

Điểm hoàn thành component 4:

- Kết nối vào command là output `Changed`.
- `ValidFrom -> Param_0`.
- `CurrentKey -> Param_1`.

#### 11.2.5. Component 5 — Union All `UNI - DimRoad New Version`

Union All hợp nhất Road hoàn toàn mới và phiên bản mới của Road đã thay đổi.

1. Kéo `Union All` vào canvas.
2. Đổi tên thành `UNI - DimRoad New Version`.
3. Từ `LKP - DimRoad Current`, kéo output không match vào Union All.
4. Trong `Input Output Selection` chọn `Lookup No Match Output`.
5. Kéo mũi tên xanh normal output từ `CMD - Close Current DimRoad` vào cùng Union All.
6. Nhấp đúp `UNI - DimRoad New Version`.
7. Kiểm tra hai input đã xuất hiện.
8. Các cột nghiệp vụ phải được ghép theo cùng tên, ví dụ:

   - `RoadID` với `RoadID`;
   - `RoadName` với `RoadName`;
   - `ZoneKey` với `ZoneKey`;
   - `ValidFrom` với `ValidFrom`;
   - `AttributeHash` với `AttributeHash`.

9. Các cột hỗ trợ `CurrentKey`, `CurrentHashHex` và `SourceHashHex` có thể còn trong
   metadata của Union; không sao, vì chúng sẽ không được map vào destination.
10. Bấm `OK`.

Nếu kéo nhầm mũi tên đỏ và SSIS hỏi về error rows, bấm `Cancel`, xóa đường nối đó và
kéo lại output dữ liệu. Đường `Lookup No Match Output` đúng sẽ có nhãn đúng tên này,
không phải `Lookup Error Output`.

Điểm hoàn thành component 5:

- Union có đúng hai input.
- Input 1 là `Lookup No Match Output`.
- Input 2 là normal output sau `CMD - Close Current DimRoad`.

#### 11.2.6. Component 6 — OLE DB Destination `DST - DimRoad New Version`

Component cuối insert dòng mới hoặc phiên bản Road mới vào `dwh.DimRoad`.

1. Kéo `OLE DB Destination` vào canvas.
2. Đổi tên thành `DST - DimRoad New Version`.
3. Kéo mũi tên xanh từ `UNI - DimRoad New Version` vào destination.
4. Nhấp đúp destination.
5. Cấu hình:

   - `OLE DB connection manager`: `(project) CM_DanangDW`;
   - `Data access mode`: `Table or view - fast load`;
   - `Name of the table or the view`: `[dwh].[DimRoad]`.

6. Sang trang `Mappings`.
7. Mapping các cột sau:

| Input Column | Destination Column |
|---|---|
| `RoadID` | `RoadID` |
| `RoadName` | `RoadName` |
| `ZoneKey` | `ZoneKey` |
| `RoadClass` | `RoadClass` |
| `LaneCount` | `LaneCount` |
| `SpeedLimitKmh` | `SpeedLimitKmh` |
| `MasterRoadWidthM` | `MasterRoadWidthM` |
| `LengthKm` | `LengthKm` |
| `NameStatus` | `NameStatus` |
| `GeometryStatus` | `GeometryStatus` |
| `WidthStatus` | `WidthStatus` |
| `SourceNote` | `SourceNote` |
| `ValidFrom` | `ValidFrom` |
| `ValidTo` | `ValidTo` |
| `IsCurrent` | `IsCurrent` |
| `AttributeHash` | `AttributeHash` |

8. Không map:

   - `RoadKey` vì đây là cột identity;
   - `RoadGeography` trong baseline Data Flow này;
   - `SourceHashHex`, `CurrentKey`, `CurrentHashHex` vì chỉ là cột kỹ thuật.

9. Bấm `OK`.

Điểm hoàn thành component 6:

- Destination là `[dwh].[DimRoad]`.
- Không map surrogate key.
- Không còn dấu X đỏ trên destination.

#### 11.2.7. Kiểm tra pipeline `DimRoad` trước khi copy

Trên canvas, kiểm tra đủ sáu component và đúng đường nối:

1. `SRC - DimRoad -> LKP - DimRoad Current`.
2. `Lookup No Match Output -> UNI - DimRoad New Version`.
3. `Lookup Match Output -> SPL - DimRoad Changed`.
4. `Changed -> CMD - Close Current DimRoad`.
5. `CMD - Close Current DimRoad -> UNI - DimRoad New Version`.
6. `UNI - DimRoad New Version -> DST - DimRoad New Version`.

Không copy pipeline này sang Facility hoặc POI khi còn bất kỳ dấu X đỏ nào.

### 11.3. Pipeline `DimParkingFacility` — copy và cấu hình đủ 6 component

Sau khi `DimRoad` hoàn chỉnh, tái sử dụng cả pipeline để giảm thao tác.

#### 11.3.1. Copy bộ sáu component

1. Giữ phím `Ctrl` và lần lượt chọn đủ sáu component của pipeline `DimRoad`.
2. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
3. Kéo cả nhóm bản sao sang một vùng trống trên canvas.
4. Xóa toàn bộ data path giữa sáu component bản sao.
5. Không xóa data path của pipeline `DimRoad` gốc.
6. Đổi tên sáu component bản sao:

| Thứ tự | Tên mới |
|---:|---|
| 1 | `SRC - DimParkingFacility` |
| 2 | `LKP - DimParkingFacility Current` |
| 3 | `SPL - DimParkingFacility Changed` |
| 4 | `CMD - Close Current DimParkingFacility` |
| 5 | `UNI - DimParkingFacility New Version` |
| 6 | `DST - DimParkingFacility New Version` |

Phải mở và sửa lại metadata của từng component bên dưới. Đổi tên trên canvas không làm
thay đổi SQL, join hay destination.

#### 11.3.2. Component 1 — Source `SRC - DimParkingFacility`

1. Nhấp đúp source.
2. Connection: `(project) CM_DanangSTG`.
3. Thay toàn bộ SQL cũ bằng:

```sql
SELECT
    ParkingID,
    ParkingName,
    AddressOrCorridor,
    ZoneKey,
    ParkingType,
    FacilityStatus,
    CapacityStatus,
    CoordinateStatus,
    Latitude,
    Longitude,
    SourceURL,
    ValidFrom,
    ValidTo,
    IsCurrent,
    AttributeHash,
    SourceHashHex
FROM publish.vDimParkingFacilitySource
WHERE LoadBatchKey = ?;
```

4. Bấm `Parameters...` và gán `Param_0 = User::LoadBatchKey`.
5. Bấm `Parse Query`.
6. Preview phải có `20` dòng.
7. Sang `Columns` để SSIS làm mới metadata.
8. Bấm `OK`.

Nếu SSIS báo cột Road cũ không còn tồn tại, đó là metadata từ bản copy. Mở lại
`Columns`, bỏ chọn metadata cũ nếu có, đóng editor và mở lại source.

#### 11.3.3. Component 2 — Lookup `LKP - DimParkingFacility Current`

1. General: chọn `Full cache` và `Redirect rows to no match output`.
2. Connection: `(project) CM_DanangDW`.
3. Thay query lookup bằng:

```sql
SELECT
    ParkingFacilityKey AS CurrentKey,
    ParkingID,
    CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimParkingFacility
WHERE IsCurrent = 1;
```

4. Trang `Columns`:

   - join `ParkingID -> ParkingID`;
   - chọn output `CurrentKey`;
   - chọn output `CurrentHashHex`.

5. Bấm `OK`.

Không giữ join `RoadID` của bản copy.

#### 11.3.4. Component 3 — Split `SPL - DimParkingFacility Changed`

1. Nối `Lookup Match Output` vào Split.
2. Mở Split.
3. Tạo output `Changed` với condition:

```text
[SourceHashHex] != [CurrentHashHex]
```

4. Đặt default output là `Unchanged`.
5. Bấm `OK`.

#### 11.3.5. Component 4 — Command `CMD - Close Current DimParkingFacility`

1. Nối output `Changed` vào command.
2. Connection: `(project) CM_DanangDW`.
3. SQLCommand:

```sql
UPDATE dwh.DimParkingFacility
SET
    ValidTo = ?,
    IsCurrent = 0
WHERE ParkingFacilityKey = CONVERT(int, ?)
  AND IsCurrent = 1;
```

4. Column Mappings:

| Input Column | Destination Column |
|---|---|
| `ValidFrom` | `Param_0` |
| `CurrentKey` | `Param_1` |

5. Bấm `OK`.

#### 11.3.6. Component 5 — Union `UNI - DimParkingFacility New Version`

1. Nối `Lookup No Match Output` vào Union.
2. Nối normal output của `CMD - Close Current DimParkingFacility` vào Union.
3. Mở Union và kiểm tra hai input được căn theo tên cột.
4. Bấm `OK`.

#### 11.3.7. Component 6 — Destination `DST - DimParkingFacility New Version`

1. Nối output Union vào destination.
2. Connection: `(project) CM_DanangDW`.
3. Data access mode: `Table or view - fast load`.
4. Destination: `[dwh].[DimParkingFacility]`.
5. Mapping:

| Input Column | Destination Column |
|---|---|
| `ParkingID` | `ParkingID` |
| `ParkingName` | `ParkingName` |
| `AddressOrCorridor` | `AddressOrCorridor` |
| `ZoneKey` | `ZoneKey` |
| `ParkingType` | `ParkingType` |
| `FacilityStatus` | `FacilityStatus` |
| `CapacityStatus` | `CapacityStatus` |
| `CoordinateStatus` | `CoordinateStatus` |
| `Latitude` | `Latitude` |
| `Longitude` | `Longitude` |
| `SourceURL` | `SourceURL` |
| `ValidFrom` | `ValidFrom` |
| `ValidTo` | `ValidTo` |
| `IsCurrent` | `IsCurrent` |
| `AttributeHash` | `AttributeHash` |

6. Không map `ParkingFacilityKey`, `FacilityPoint`, `SourceHashHex`,
   `CurrentKey` hoặc `CurrentHashHex`.
7. Bấm `OK`.

Nếu destination bản copy vẫn giữ external metadata của `DimRoad`, xóa riêng
destination bản copy, kéo một `OLE DB Destination` mới và cấu hình lại theo các bước
trên. Không cần xóa năm component còn lại.

#### 11.3.8. Kiểm tra pipeline Facility

Pipeline phải có đủ sáu đường nối tương tự `DimRoad`. Lần load đầu tiên dự kiến insert
`20` dòng vào `dwh.DimParkingFacility`.

### 11.4. Pipeline `DimPOI` — copy và cấu hình đủ 6 component

Copy pipeline `DimParkingFacility` đã hoàn chỉnh để tạo pipeline POI.

#### 11.4.1. Copy bộ sáu component

1. Chọn đủ sáu component của pipeline `DimParkingFacility`.
2. Nhấn `Ctrl+C` rồi `Ctrl+V`.
3. Di chuyển nhóm bản sao sang vùng trống.
4. Xóa các data path bên trong nhóm bản sao.
5. Đổi tên:

| Thứ tự | Tên mới |
|---:|---|
| 1 | `SRC - DimPOI` |
| 2 | `LKP - DimPOI Current` |
| 3 | `SPL - DimPOI Changed` |
| 4 | `CMD - Close Current DimPOI` |
| 5 | `UNI - DimPOI New Version` |
| 6 | `DST - DimPOI New Version` |

#### 11.4.2. Component 1 — Source `SRC - DimPOI`

1. Connection: `(project) CM_DanangSTG`.
2. SQL command:

```sql
SELECT
    POIID,
    POIName,
    POICategoryKey,
    ZoneKey,
    ParkingDemandWeight,
    Latitude,
    Longitude,
    DataStatus,
    ValidFrom,
    ValidTo,
    IsCurrent,
    AttributeHash,
    SourceHashHex
FROM publish.vDimPOISource
WHERE LoadBatchKey = ?;
```

3. `Parameters...`: `Param_0 = User::LoadBatchKey`.
4. Parse Query.
5. Preview phải có `50` dòng.
6. Mở `Columns` để làm mới metadata rồi bấm `OK`.

#### 11.4.3. Component 2 — Lookup `LKP - DimPOI Current`

1. General: `Full cache` và `Redirect rows to no match output`.
2. Connection: `(project) CM_DanangDW`.
3. Query:

```sql
SELECT
    POIKey AS CurrentKey,
    POIID,
    CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimPOI
WHERE IsCurrent = 1;
```

4. Trang `Columns`:

   - join `POIID -> POIID`;
   - chọn output `CurrentKey`;
   - chọn output `CurrentHashHex`.

5. Bấm `OK`.

#### 11.4.4. Component 3 — Split `SPL - DimPOI Changed`

1. Nối `Lookup Match Output` vào Split.
2. Output `Changed`:

```text
[SourceHashHex] != [CurrentHashHex]
```

3. Default output: `Unchanged`.
4. Bấm `OK`.

#### 11.4.5. Component 4 — Command `CMD - Close Current DimPOI`

1. Nối output `Changed` vào command.
2. Connection: `(project) CM_DanangDW`.
3. SQLCommand:

```sql
UPDATE dwh.DimPOI
SET
    ValidTo = ?,
    IsCurrent = 0
WHERE POIKey = CONVERT(int, ?)
  AND IsCurrent = 1;
```

4. Column Mappings:

| Input Column | Destination Column |
|---|---|
| `ValidFrom` | `Param_0` |
| `CurrentKey` | `Param_1` |

5. Bấm `OK`.

#### 11.4.6. Component 5 — Union `UNI - DimPOI New Version`

1. Nối `Lookup No Match Output` vào Union.
2. Nối normal output của `CMD - Close Current DimPOI` vào Union.
3. Mở Union và kiểm tra có đúng hai input.
4. Bấm `OK`.

#### 11.4.7. Component 6 — Destination `DST - DimPOI New Version`

1. Nối output Union vào destination.
2. Connection: `(project) CM_DanangDW`.
3. Data access mode: `Table or view - fast load`.
4. Destination: `[dwh].[DimPOI]`.
5. Mapping:

| Input Column | Destination Column |
|---|---|
| `POIID` | `POIID` |
| `POIName` | `POIName` |
| `POICategoryKey` | `POICategoryKey` |
| `ZoneKey` | `ZoneKey` |
| `ParkingDemandWeight` | `ParkingDemandWeight` |
| `Latitude` | `Latitude` |
| `Longitude` | `Longitude` |
| `DataStatus` | `DataStatus` |
| `ValidFrom` | `ValidFrom` |
| `ValidTo` | `ValidTo` |
| `IsCurrent` | `IsCurrent` |
| `AttributeHash` | `AttributeHash` |

6. Không map `POIKey`, `POIPoint`, `SourceHashHex`, `CurrentKey` hoặc
   `CurrentHashHex`.
7. Bấm `OK`.

#### 11.4.8. Kiểm tra pipeline POI

Lần load đầu tiên dự kiến insert `50` dòng vào `dwh.DimPOI`. Pipeline phải có đủ sáu
component và sáu đường nối giống cấu trúc `DimRoad`.

### 11.5. Nghiệm thu toàn bộ level 2

Trước khi sang level 3, kiểm tra trên canvas:

- có đúng 3 pipeline độc lập;
- mỗi pipeline có đúng 6 component;
- tổng cộng level 2 có 18 component;
- không component nào còn dấu X đỏ;
- nhánh `Unchanged` của mỗi Conditional Split không nối vào destination;
- không dùng mũi tên đỏ error output thay cho `Lookup No Match Output`.

Chạy package 30 riêng lần đầu, sau đó kiểm tra trên SSMS:

```sql
USE DanangSmartParkingDW;
GO

SELECT
    'DimRoad' AS ObjectName,
    COUNT_BIG(*) AS TotalRows,
    SUM(CASE WHEN IsCurrent = 1 THEN 1 ELSE 0 END) AS CurrentRows
FROM dwh.DimRoad
UNION ALL
SELECT
    'DimParkingFacility',
    COUNT_BIG(*),
    SUM(CASE WHEN IsCurrent = 1 THEN 1 ELSE 0 END)
FROM dwh.DimParkingFacility
UNION ALL
SELECT
    'DimPOI',
    COUNT_BIG(*),
    SUM(CASE WHEN IsCurrent = 1 THEN 1 ELSE 0 END)
FROM dwh.DimPOI;
```

Kỳ vọng lần load đầu:

| ObjectName | TotalRows | CurrentRows |
|---|---:|---:|
| DimRoad | 30 | 30 |
| DimParkingFacility | 20 | 20 |
| DimPOI | 50 | 50 |

Kiểm tra không có nhiều hơn một dòng current cho cùng business key:

```sql
SELECT
    'DimRoad' AS ObjectName,
    RoadID AS BusinessKey,
    COUNT_BIG(*) AS CurrentRows
FROM dwh.DimRoad
WHERE IsCurrent = 1
GROUP BY RoadID
HAVING COUNT_BIG(*) > 1

UNION ALL

SELECT
    'DimParkingFacility',
    ParkingID,
    COUNT_BIG(*)
FROM dwh.DimParkingFacility
WHERE IsCurrent = 1
GROUP BY ParkingID
HAVING COUNT_BIG(*) > 1

UNION ALL

SELECT
    'DimPOI',
    POIID,
    COUNT_BIG(*)
FROM dwh.DimPOI
WHERE IsCurrent = 1
GROUP BY POIID
HAVING COUNT_BIG(*) > 1;
```

Truy vấn trên phải trả `0 dòng`.

Chạy lại package 30 với cùng batch và dữ liệu không đổi. `TotalRows` không được tăng.
Nếu tăng, kiểm tra lại:

1. `SourceHashHex` và `CurrentHashHex` có cùng kiểu `char(64)`;
2. Conditional Split có dùng đúng
   `[SourceHashHex] != [CurrentHashHex]`;
3. Lookup có join đúng business key;
4. nhánh `Lookup Match Output` có đi qua Split, không đi thẳng vào Union.

Các cột spatial `RoadGeography`, `FacilityPoint` và `POIPoint` chưa được map trong
baseline package này. Thông tin tọa độ và geometry nguồn vẫn được giữ qua các cột
Latitude, Longitude và trạng thái dữ liệu; có thể bổ sung bước spatial sau khi toàn
bộ dimension/fact đã nghiệm thu ổn định.
## 12. Data Flow level 3 — Segment và Restriction

### 12.1. Tạo task

1. Tạo `DFT - L3 Segment Restriction`.
2. Nối success từ level 2.
3. Mở Data Flow.
4. Tạo hai pipeline SCD2.

### 12.2. RoadSegment

Source:

```sql
SELECT SegmentID, RoadKey, SourceRoadName, ObservedRoadSideKey,
       SurveyDataStatus, ValidFrom, ValidTo, IsCurrent,
       AttributeHash, SourceHashHex
FROM publish.vDimRoadSegmentSource
WHERE LoadBatchKey = ?;
```

Lookup:

```sql
SELECT SegmentKey AS CurrentKey, SegmentID,
       CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimRoadSegment
WHERE IsCurrent = 1;
```

Close command:

```sql
UPDATE dwh.DimRoadSegment
SET ValidTo = ?, IsCurrent = 0
WHERE SegmentKey = CONVERT(int, ?) AND IsCurrent = 1;
```

Destination: `[dwh].[DimRoadSegment]`. Không map `SegmentKey`, `SourceHashHex`,
`CurrentKey`, `CurrentHashHex`.

Pipeline phải làm đủ chuỗi `Source → Lookup → Match/No Match → Split Changed → Close
Current → Union All → Destination` như mục 11.3–11.5. Destination map:

```text
SegmentID→SegmentID
RoadKey→RoadKey
SourceRoadName→SourceRoadName
ObservedRoadSideKey→ObservedRoadSideKey
SurveyDataStatus→SurveyDataStatus
ValidFrom→ValidFrom
ValidTo→ValidTo
IsCurrent→IsCurrent
AttributeHash→AttributeHash
```

### 12.3. ParkingRestriction

Source:

```sql
SELECT RestrictionID, RoadKey, SourceRoadName, RestrictionType,
       StartTime, EndTime, RoadSideKey, VehicleScope, DataStatus, SourceURL,
       ValidFrom, ValidTo, IsCurrent, AttributeHash, SourceHashHex
FROM publish.vDimParkingRestrictionSource
WHERE LoadBatchKey = ?;
```

Lookup:

```sql
SELECT RestrictionKey AS CurrentKey, RestrictionID,
       CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimParkingRestriction
WHERE IsCurrent = 1;
```

Close command:

```sql
UPDATE dwh.DimParkingRestriction
SET ValidTo = ?, IsCurrent = 0
WHERE RestrictionKey = CONVERT(int, ?) AND IsCurrent = 1;
```

Destination: `[dwh].[DimParkingRestriction]`. `RoadKey` được phép null đối với R003.
Không dùng Conditional Split để loại R003.

Pipeline cũng phải làm đủ mẫu SCD2. Destination map:

```text
RestrictionID→RestrictionID
RoadKey→RoadKey
SourceRoadName→SourceRoadName
RestrictionType→RestrictionType
StartTime→StartTime
EndTime→EndTime
RoadSideKey→RoadSideKey
VehicleScope→VehicleScope
DataStatus→DataStatus
SourceURL→SourceURL
ValidFrom→ValidFrom
ValidTo→ValidTo
IsCurrent→IsCurrent
AttributeHash→AttributeHash
```

Không map cột `RoadID` phụ nếu source view đang hiển thị cột này; cột đó chỉ giúp dò
nguồn và không tồn tại trong destination.

## 13. Data Flow level 4 — Camera

### 13.1. Tạo task và pipeline

1. Tạo `DFT - L4 Camera`.
2. Nối success từ level 3.
3. Mở Data Flow.

Source:

```sql
   SELECT CameraID, SegmentKey, CameraStatus, ValidFrom, ValidTo,
         IsCurrent, AttributeHash, SourceHashHex
   FROM publish.vDimCameraSource
   WHERE LoadBatchKey = ?;
```   

Lookup:

```sql
SELECT CameraKey AS CurrentKey, CameraID,
       CONVERT(char(64), AttributeHash, 2) AS CurrentHashHex
FROM dwh.DimCamera
WHERE IsCurrent = 1;
```

Changed expression:

```text
SourceHashHex != CurrentHashHex
```

Close command:

```sql
UPDATE dwh.DimCamera
SET ValidTo = ?, IsCurrent = 0
WHERE CameraKey = CONVERT(int, ?) AND IsCurrent = 1;
```

Destination: `[dwh].[DimCamera]`; không map `CameraKey`, `SourceHashHex`,
`CurrentKey`, `CurrentHashHex`.

Thực hiện đủ mẫu SCD2 giống level 2. Destination map:

```text
CameraID→CameraID
SegmentKey→SegmentKey
CameraStatus→CameraStatus
ValidFrom→ValidFrom
ValidTo→ValidTo
IsCurrent→IsCurrent
AttributeHash→AttributeHash
```

Trước khi đóng task, mở source và chọn **Preview**: phải thấy 25 dòng, mọi
`SegmentKey` đều có giá trị. Nếu `SegmentKey` null, quay lại kiểm tra level 3 thay vì
cố chạy destination.

## 14. Hoàn thiện Control Flow

1. Quay lại **Control Flow**.
2. Nối success constraint đúng thứ tự:

```text
Precheck → L0 → L1 → L2 → L3 → L4 → Validate
```

3. Mỗi mũi tên phải màu xanh và có `Value = Success`.
4. Chọn package bằng cách bấm vùng trống, nhấn `F4`.
5. Đặt `MaximumErrorCount = 1`; không tăng số này để che lỗi.
6. **File → Save All**.

## 15. Debug riêng package 30

### 15.1. Gán batch key số để debug

1. Mở tab **Parameters** của package 30.
2. Ghi nhớ Value ban đầu là `0`.
3. Tạm đổi `pLoadBatchKey` thành số batch Silver, ví dụ `18`.
4. Nhấn Enter và **Save All**.
5. Trong Solution Explorer, nhấp phải `30_Load_Dimensions.dtsx`.
6. Chọn **Set as Startup Object**.
7. Nhấn **Start** hoặc `F5`.

Kết quả mong đợi:

- cả 7 task đều xanh;
- không có dấu X đỏ;
- package kết thúc `Success`;
- batch vẫn `SILVER_VALIDATED` vì package 30 chưa hoàn tất Fact và chưa complete batch.

### 15.2. Bắt buộc trả parameter về 0

Sau khi debug riêng thành công:

1. nhấn **Stop Debugging** nếu Visual Studio còn ở chế độ chạy;
2. mở tab **Parameters** của package 30;
3. đổi `pLoadBatchKey` từ `18` về `0`;
4. nhấn Enter;
5. **Save All**.

Không để số batch debug trong package. Khi chạy từ `00_Master.dtsx`, batch key phải
được truyền động từ biến của Master.

## 16. Nghiệm thu trên SSMS

1. Mở [26_validate_dimensions.sql](../../sql/26_validate_dimensions.sql) trong SSMS.
2. Mặc định `@RequestedLoadBatchKey = NULL`, script tự tìm batch Silver mới nhất.
3. Nếu muốn kiểm tra đúng batch `18`, sửa đúng một dòng:

```sql
DECLARE @RequestedLoadBatchKey bigint = 18;
```

4. Nhấn `F5`.

Kết quả bắt buộc:

```text
AcceptanceStatus = PASS
Message = PACKAGE 30 DIMENSIONS ACCEPTED - ready for package 40 facts
```

Các kiểm tra quan trọng đi kèm:

- đủ 14 Dimension;
- `Duplicate current business keys = 0`;
- `Dimension FK orphan rows = 0`;
- `R003 intentional null RoadKey = 1`;
- Unicode checkpoint = `Trần Phú / Hải Châu core`;
- hash source và current khớp cho 6 Dimension SCD2.

Nếu script trả `FAIL` hoặc `THROW 52699`, đọc result set `Failures` trước khi sửa.

## 17. Gắn package 30 vào `00_Master.dtsx`

Chỉ làm phần này sau khi debug riêng và script nghiệm thu đều PASS.

### 17.1. Tạo Execute Package Task

1. Mở `00_Master.dtsx`.
2. Stop Debugging nếu đang chạy.
3. Kéo **Execute Package Task** vào sau task `PKG - Validate Transform`.
4. Đổi tên `PKG - Load Dimensions`.
5. Nối mũi tên success từ `PKG - Validate Transform` sang task mới.
6. Nhấp đúp task mới.
7. Trang **Package**:
   - `ReferenceType = Project Reference`;
   - `PackageNameFromProjectReference = 30_Load_Dimensions.dtsx`.
8. Trang **Parameter bindings** → **Add**:

| Child package parameter | Bind to parameter or variable |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

9. Nhấn **OK**.
10. Đảm bảo `SQL - Complete Batch` vẫn disabled; chưa được complete batch trước khi
    load Fact và reconciliation.

### 17.2. Save, Rebuild và chạy Master

1. Chọn **File → Save All**.
2. Chọn **Build → Rebuild Solution**.
3. Kiểm tra cửa sổ Output có `Rebuild succeeded`.
4. Trong Solution Explorer, nhấp phải `00_Master.dtsx`.
5. Chọn **Set as Startup Object**.
6. Nhấn **Start** hoặc `F5`.
7. Quan sát luồng chạy tới `PKG - Load Dimensions` và task này phải xanh.

Nếu task báo `Failed to locate the specified package in the project`:

1. Stop Debugging;
2. mở lại Execute Package Task;
3. chọn lại `30_Load_Dimensions.dtsx` từ dropdown;
4. kiểm tra parameter binding;
5. Save All;
6. đóng tab `00_Master`, mở lại;
7. Rebuild Solution rồi F5 lại.

## 18. Lỗi thường gặp

### 18.1. `The parameter cannot be found` hoặc batch key bằng 0

- kiểm tra tên child parameter là `pLoadBatchKey`;
- kiểm tra Master bind tới `User::LoadBatchKey`;
- SQL Task Parameter Name phải là ordinal `0`, không phải `@LoadBatchKey`;
- Data type SQL Task dùng `LONG`;
- OLE DB Source `Param_0` phải map với `User::LoadBatchKey`.

### 18.2. Lookup báo metadata mismatch

Sau khi copy component, nguồn cũ vẫn còn metadata. Khắc phục:

1. mở source bản sao;
2. thay SQL;
3. nhấn **Columns**;
4. mở Lookup và làm lại trang Columns;
5. mở destination và làm lại Mappings.

### 18.3. FK violation ở child Dimension

- kiểm tra thứ tự level;
- source view child phải được đọc sau khi parent task đã kết thúc;
- chạy query source view và kiểm tra parent key có null hay không;
- ngoại lệ duy nhất được chấp nhận là `R003.RoadKey = NULL`.

### 18.4. Unique index current bị lỗi

Nguyên nhân thường là nối cả `No Match` và `Unchanged` vào destination. Nhánh
`Unchanged` phải bỏ qua. Chỉ `No Match` và `Changed sau khi đóng current cũ` được insert.

### 18.5. `ValidTo` vi phạm check constraint

OLE DB Command phải nhận:

```text
ValidFrom → Param_0
CurrentKey → Param_1
```

Không dùng timestamp cũ nhỏ hơn hoặc bằng `ValidFrom` của version hiện tại.

### 18.6. Geography/Point đang NULL

Đây là giới hạn chủ đích của baseline Data Flow. Các cột decimal Latitude/Longitude và
metadata geometry vẫn đầy đủ. Không coi spatial UDT null là lỗi package 30.

## 19. Checklist hoàn thành

- [ ] Đã chạy `sql/26_prepare_dimension_data_flow.sql` và nhận PASS.
- [ ] Precheck batch Silver chạy thành công.
- [ ] Đã tạo `30_Load_Dimensions.dtsx`.
- [ ] `pLoadBatchKey` là Int64, Required, giá trị mặc định 0.
- [ ] Có biến `User::LoadBatchKey` nhận expression từ parameter.
- [ ] Có đúng 5 Data Flow Task theo level.
- [ ] Các pipeline load thật dùng OLE DB Source/Lookup/Destination.
- [ ] 3 Dimension Type 1 có đủ nhánh New/Changed/Unchanged.
- [ ] 6 Dimension SCD2 có nhánh New/Changed/Unchanged.
- [ ] Debug riêng bằng batch số thành công.
- [ ] Đã trả `pLoadBatchKey` về 0 sau debug.
- [ ] `sql/26_validate_dimensions.sql` trả PASS.
- [ ] Đã gắn package 30 vào Master và bind batch key.
- [ ] Save All, Rebuild Solution, Set Master as Startup Object và F5 thành công.
- [ ] Batch vẫn `SILVER_VALIDATED`, `CompletedAt = NULL`.

Checkpoint tiếp theo sau khi tất cả mục trên đạt: package 40 — Load Facts bằng Data Flow.
