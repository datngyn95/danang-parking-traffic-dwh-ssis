# 50 — Final DWH Validation

## 1. Mục tiêu và checkpoint đầu vào

Package `50_Final_DWH_Validation.dtsx` là structural gate sau khi nạp Dimension và
Fact. Package không di chuyển dữ liệu và không thay đổi trạng thái batch; nó gọi một
stored procedure trên `DanangSmartParkingDW`, nhận một result row và làm package fail
ngay khi cấu trúc DWH không đạt baseline.

Chỉ bắt đầu bước 50 khi:

- `30_Load_Dimensions.dtsx` đã PASS;
- `40_Load_Facts.dtsx` đã PASS trên cùng `LoadBatchKey`;
- batch vẫn có `LoadStatus = SILVER_VALIDATED`;
- acceptance của package 40 có đủ `20/30/168/16800/4283` Fact rows;
- `(project) CM_DanangDW` kết nối đúng database `DanangSmartParkingDW`.

Các file dùng trong bước này:

| File | Vai trò |
|---|---|
| `50_Final_DWH_Validation.dtsx` | Một Execute SQL Task gọi final structural gate |
| [`28_prepare_final_dwh_validation.sql`](../../sql/28_prepare_final_dwh_validation.sql) | Cài `etl.usp_ValidateFinalDWH` |
| [`28_validate_final_dwh.sql`](../../sql/28_validate_final_dwh.sql) | Acceptance read-only chạy độc lập trên SSMS |

Khi bước này PASS, chuyển sang `80_Reconcile.dtsx`. Không cleanup staging và không
chuyển batch thành `COMPLETED` ở package 50.

## 2. Phân biệt package 40, 50 và 80

| Package | Câu hỏi cần trả lời | Phạm vi |
|---|---|---|
| 40 — Load Facts | Data Flow vừa nạp đủ từng Fact chưa? | Source, lookup, insert, duplicate/reject của Fact |
| 50 — Final DWH Validation | Toàn bộ mô hình DWH có đúng cấu trúc và quan hệ không? | 14 Dimension, 5 Fact, grain, hierarchy, FK, nullable exception |
| 80 — Reconciliation | Số liệu nghiệp vụ có khớp baseline không? | Volume, illegal parking, capacity, rain và KPI tổng hợp |

Package 50 không thay package 80. Structural count đúng vẫn có thể chứa KPI sai; vì
vậy chỉ package 80 PASS mới cho phép package 90 cleanup.

## 3. Kết quả cần đạt

Stored procedure trả đúng một result row, đúng thứ tự năm cột:

| Ordinal | Column | Kiểu SQL | Expected |
|---:|---|---|---|
| 0 | `AcceptanceStatus` | `varchar(10)` | `PASS` |
| 1 | `ValidationMessage` | `nvarchar(2000)` | `FINAL_DWH_VALIDATION_PASS` |
| 2 | `DimensionTables` | `int` | `14` |
| 3 | `FactTables` | `int` | `5` |
| 4 | `FactRows` | `bigint` | `21301` |

### 3.1. Baseline Dimension

| Dimension | Expected |
|---|---:|
| `DimDate` | 7 |
| `DimTime` | 1.440 |
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

SCD2 có thể có nhiều version lịch sử trong lần mở rộng sau này, nên procedure kiểm
tra số row `IsCurrent=1`, không ép tổng vật lý của bảng SCD2 luôn bằng baseline.

### 3.2. Baseline Fact

| Fact | Expected |
|---|---:|
| `FactParkingCapacitySnapshot` | 20 |
| `FactRoadSurveySnapshot` | 30 |
| `FactWeatherHourly` | 168 |
| `FactTrafficObservation` | 16.800 |
| `FactParkingEvent` | 4.283 |
| **Tổng** | **21.301** |

## 4. Quy tắc validation

Procedure kiểm tra tuần tự:

1. Batch tồn tại và đang là `SILVER_VALIDATED`.
2. Đủ 14 bảng Dimension và 5 bảng Fact.
3. Dimension count/current count khớp baseline.
4. Có Unknown member đã thiết kế trong `DimRoadSide` và `DimVehicleType`.
5. Không có hai current version cho cùng business key SCD2.
6. Không có orphan trong hierarchy Dimension.
7. Ngoại lệ `R003.RoadKey = NULL` vẫn đúng và là restriction current duy nhất thiếu
   RoadKey.
8. Fact count và business grain khớp.
9. Không có orphan foreign key bắt buộc hoặc optional key đã có giá trị nhưng không
   resolve được.
10. Các ngoại lệ nullable đã biết vẫn đúng.
11. Mọi `LoadFileKey` trong Fact thuộc đúng batch đang validation.

Mỗi vi phạm phát sinh `THROW 529xx`; Execute SQL Task chuyển đỏ và master dừng trước
package 80/90.

### 4.1. Các `NULL` hợp lệ

| Ngoại lệ | Expected | Ý nghĩa |
|---|---:|---|
| `DimParkingRestriction.RoadKey` null | 1 current (`R003`) | Chủ đích của dữ liệu nguồn |
| Traffic `AvgSpeedKmh` null với `SpeedMissingFlag=1` | 161 | Speed thiếu, không đổi thành `0` |
| Survey `RoadWidthRawM` null với `WidthImputedFlag=1` | 3 | Dùng `RoadWidthResolvedM` |
| Parking open event có End fields null | 64 | Event chưa có thời điểm kết thúc thực |
| Parking `RestrictionKey` null | Hợp lệ khi không có active restriction | Quan hệ optional |
| Survey `SourceSurveyDateKey` null | Hợp lệ | RAW không có ngày khảo sát thực địa |

Procedure chỉ coi optional key là orphan khi key khác null nhưng không tìm thấy row
Dimension. Không tự thay `NULL` bằng `0`.

## 5. Đối chiếu package tham chiếu

Package được cung cấp đã có:

- một task `SQL - Validate Final DWH`;
- `FailPackageOnFailure = True` và `FailParentOnFailure = True`;
- SQL `EXEC etl.usp_ValidateFinalDWH;`;
- `ResultSet = Single row`;
- năm Result Binding theo ordinal `0..4`.

Ba điều chỉnh cần thực hiện để package dùng được ổn định trong master:

1. Repository ban đầu chưa có `etl.usp_ValidateFinalDWH`; phải chạy script cài đặt ở
   mục 6 trước khi debug package.
2. Thêm `pLoadBatchKey` và truyền batch rõ ràng vào procedure, thay vì ngầm chọn batch
   mới nhất.
3. Variable `User::FactRows` trong file tham chiếu đang là `UInt64`; đổi thành
   `Int64` để khớp `COUNT_BIG`/`bigint` của SQL Server.

Các điều chỉnh này là yêu cầu triển khai của tài liệu, không phải chỉ dẫn nằm trong
file package tham chiếu.

## 6. Cài stored procedure trên SSMS

### 6.1. Chạy script cài đặt

1. Mở SSMS và kết nối SQL Server của dự án.
2. Chọn database `DanangSmartParkingDW` trên dropdown.
3. Chọn **File → Open → File...**.
4. Mở [`28_prepare_final_dwh_validation.sql`](../../sql/28_prepare_final_dwh_validation.sql).
5. Không sửa tên database, schema hoặc procedure.
6. Chọn/chạy **toàn bộ file** bằng `Execute` hoặc `F5`.
7. Result set cuối phải có:

```text
SchemaName    = etl
ProcedureName = usp_ValidateFinalDWH
InstallStatus = PASS
```

Script chỉ `CREATE OR ALTER PROCEDURE`; nó không insert, update hoặc delete dữ liệu
Dimension/Fact.

### 6.2. Refresh và kiểm tra object

Trong Object Explorer:

1. Mở `Databases → DanangSmartParkingDW → Programmability`.
2. Nhấp phải **Stored Procedures** → **Refresh**.
3. Phải thấy `etl.usp_ValidateFinalDWH`.
4. Chạy truy vấn đầy đủ sau:

```sql
USE DanangSmartParkingDW;
GO

SELECT
    OBJECT_SCHEMA_NAME(OBJECT_ID(N'etl.usp_ValidateFinalDWH')) AS SchemaName,
    OBJECT_NAME(OBJECT_ID(N'etl.usp_ValidateFinalDWH')) AS ProcedureName;
GO
```

Không tạo Execute SQL Task trước khi object này xuất hiện.

## 7. Lấy batch dùng để debug

Chạy toàn bộ đoạn sau trên SSMS:

```sql
USE DanangSmartParkingDW;
GO

SELECT TOP (10)
    LoadBatchKey, LoadStatus, RowsRead, RowsAccepted,
    RowsRejected, ErrorMessage, CompletedAt
FROM etl.LoadBatch
ORDER BY LoadBatchKey DESC;
GO
```

Chọn batch mới nhất có:

```text
LoadStatus   = SILVER_VALIDATED
RowsRead     = 21500
RowsAccepted = 21500
RowsRejected = 0
ErrorMessage = NULL
CompletedAt  = NULL
```

Checkpoint lịch sử là batch `18`; nếu môi trường hiện tại có batch mới hơn thì dùng
số mới hơn. Không nhập chữ `LoadBatchKey` vào parameter.

## 8. Tạo hoặc sửa package

### 8.1. Thêm package vào project

Nếu `50_Final_DWH_Validation.dtsx` là file rời:

1. Trong **Solution Explorer**, nhấp phải **SSIS Packages**.
2. Chọn **Add Existing Package...** hoặc **Add → Existing Item...**.
3. Chọn `50_Final_DWH_Validation.dtsx`.
4. Mở package và nhấn **Save All**.

Nếu tự tạo mới:

1. Nhấp phải **SSIS Packages → New SSIS Package**.
2. Rename thành `50_Final_DWH_Validation.dtsx`.
3. Không đổi tên bằng Windows Explorer khi Visual Studio đang mở.

### 8.2. Tạo package parameter

Trong tab **Parameters**, tạo:

| Thuộc tính | Giá trị |
|---|---|
| Name | `pLoadBatchKey` |
| Data type | `Int64` |
| Value | `0` |
| Sensitive | `False` |
| Required | `True` |
| Description | `Batch key nhận từ 00_Master` |

### 8.3. Tạo variable batch

Trong **Control Flow**, bấm vùng trống rồi mở **SSIS → Variables**. Tạo:

| Name | Scope | Data type | Value |
|---|---|---|---:|
| `LoadBatchKey` | `50_Final_DWH_Validation` | `Int64` | `0` |

Chọn `User::LoadBatchKey`, nhấn `F4`, đặt:

```text
EvaluateAsExpression = True
Expression = @[$Package::pLoadBatchKey]
```

Nhấn **Evaluate Expression**; lúc thiết kế kết quả là `0`.

### 8.4. Tạo năm output variables

Tạo ở package scope:

| Name | Data type | Value |
|---|---|---|
| `AcceptanceStatus` | `String` | chuỗi rỗng |
| `ValidationMessage` | `String` | chuỗi rỗng |
| `DimensionTables` | `Int32` | `0` |
| `FactTables` | `Int32` | `0` |
| `FactRows` | `Int64` | `0` |

Không dùng `UInt64` cho `FactRows`. Procedure trả SQL `bigint`, tương ứng SSIS
`Int64`.

## 9. Cấu hình `SQL - Validate Final DWH`

### 9.1. General

1. Kéo **Execute SQL Task** từ SSIS Toolbox vào Control Flow.
2. Đổi tên `SQL - Validate Final DWH`.
3. Mở task và cấu hình:

| Thuộc tính | Giá trị |
|---|---|
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `Single row` |
| BypassPrepare | `True` |
| FailPackageOnFailure | `True` |
| FailParentOnFailure | `True` |

Nhấp phải `(project) CM_DanangDW` ở đáy package → **Edit... → Test Connection**.
Database trong connection string phải là `DanangSmartParkingDW`.

### 9.2. SQLStatement

Nhấn nút `...` ở `SQLStatement` và nhập toàn bộ:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

EXEC etl.usp_ValidateFinalDWH
    @LoadBatchKey = @LoadBatchKey;
```

Đây là SQL có thể chạy trong Execute SQL Task. Không chạy nguyên đoạn này trên SSMS,
vì dấu `?` là positional parameter của OLE DB, không phải cú pháp parameter SSMS.

### 9.3. Parameter Mapping

Mở trang **Parameter Mapping → Add**:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `User::LoadBatchKey` | Input | `LONG` | `0` | `-1` |

Trong provider OLE DB hiện tại, chọn `LONG`; SQL đã `CONVERT` sang `bigint`. Ordinal
bắt đầu từ `0`, không nhập `@LoadBatchKey` vào cột Parameter Name.

### 9.4. Result Set

Mở trang **Result Set**, thêm đúng năm dòng:

| Result Name | Variable Name |
|---:|---|
| `0` | `User::AcceptanceStatus` |
| `1` | `User::ValidationMessage` |
| `2` | `User::DimensionTables` |
| `3` | `User::FactTables` |
| `4` | `User::FactRows` |

Vì connection type là OLE DB, Result Name dùng ordinal số. Không nhập tên column SQL
vào Result Name và không đảo `DimensionTables` với `FactTables`.

Task không cần trang Expressions và không cần precedence constraint nội bộ vì package
chỉ có một task.

## 10. Debug package độc lập

1. Nhấp phải `50_Final_DWH_Validation.dtsx` trong Solution Explorer.
2. Chọn **Set as Startup Object**.
3. Mở package, gán `pLoadBatchKey` bằng số batch thật, ví dụ `18`.
4. Đặt breakpoint `OnPostExecute` trên task nếu muốn xem output variables:
   - nhấp phải task → **Edit Breakpoints...**;
   - tick `Break when the container receives the OnPostExecute event`.
5. Nhấn **Start/F5**.
6. Task `SQL - Validate Final DWH` phải chuyển màu xanh.
7. Tại breakpoint, mở **Debug → Windows → Locals** hoặc **Watch** và kiểm tra:

```text
User::AcceptanceStatus = PASS
User::ValidationMessage = FINAL_DWH_VALIDATION_PASS
User::DimensionTables = 14
User::FactTables = 5
User::FactRows = 21301
```

Nếu không dùng breakpoint, package xanh và acceptance SQL ở mục 11 PASS là đủ bằng
chứng nghiệm thu.

### 10.1. Lỗi thường gặp

| Lỗi | Nguyên nhân/khắc phục |
|---|---|
| Could not find stored procedure | Chưa chạy script 28 hoặc connection đang trỏ sai database |
| Parameter name is unrecognized | SQL không có `?`, mapping sai ordinal hoặc còn SQL cũ của package tham chiếu |
| Result binding type mismatch | `FactRows` đang là `UInt64`; đổi sang `Int64` |
| No SILVER_VALIDATED batch | `pLoadBatchKey=0`, sai batch hoặc package 23 chưa PASS |
| Dimension count mismatch | Package 30 chưa chạy đủ hoặc current SCD2 bị thiếu/trùng |
| Fact count mismatch | Package 40 chưa chạy hoặc orphan path làm thiếu Fact |
| Load-file provenance mismatch | Fact và parameter thuộc hai batch khác nhau |
| Package 50 xanh nhưng biến vẫn 0 | Sai ResultSet (`None`) hoặc thiếu Result Binding |

## 11. Acceptance độc lập trên SSMS

1. Mở [`28_validate_final_dwh.sql`](../../sql/28_validate_final_dwh.sql).
2. Chọn database `DanangSmartParkingDW`.
3. Giữ `@RequestedLoadBatchKey = NULL` để dùng batch mới nhất hoặc thay bằng số batch
   thật, ví dụ `18`.
4. Chạy **toàn bộ file** bằng `Execute/F5`.
5. Kết quả phải là một row:

```text
AcceptanceStatus  ValidationMessage          DimensionTables  FactTables  FactRows
PASS              FINAL_DWH_VALIDATION_PASS  14               5           21301
```

Nếu procedure `THROW`, đọc chính xác error number `52900–52912`; sửa package 30/40
hoặc dữ liệu liên quan rồi chạy lại. Không chạy cleanup để che lỗi.

## 12. Gắn package 50 vào `00_Master.dtsx`

1. Mở `00_Master.dtsx` → **Control Flow**.
2. Copy một Execute Package Task gần nhất bằng `Ctrl+C/Ctrl+V`, hoặc kéo task mới.
3. Đổi tên `EPT - 50 Final DWH Validation`.
4. Mở task → trang **Package**:
   - `ReferenceType = Project Reference`;
   - `PackageNameFromProjectReference = 50_Final_DWH_Validation.dtsx`.
5. Mở **Parameter Bindings** và bind:

```text
Child parameter: pLoadBatchKey
Parent variable: User::LoadBatchKey
```

6. Nối precedence constraint màu xanh:

```text
EPT - 40 Load Facts
    → EPT - 50 Final DWH Validation
    → EPT - 80 Reconciliation
```

7. `90_Cleanup` và `SQL - Complete Batch` vẫn để disabled.
8. Nhấn **Save All**.
9. Nhấp phải `00_Master.dtsx` → **Set as Startup Object**.
10. Mở master và nhấn **Start/F5**.

Sau full run đến package 50:

- Extract, Transform, Dimension, Fact và Final DWH Validation phải xanh;
- package 80/90 vẫn chưa được coi là hoàn thành;
- batch vẫn là `SILVER_VALIDATED`;
- `CompletedAt` vẫn null.

Chạy lại acceptance ở mục 11 sau full run, không chỉ dựa vào màu xanh trên SSIS.

## 13. Checklist và checkpoint bàn giao

- [ ] Package 30 và 40 đã PASS trên cùng batch.
- [ ] Đã chạy `28_prepare_final_dwh_validation.sql` và nhận `InstallStatus=PASS`.
- [ ] Object `etl.usp_ValidateFinalDWH` xuất hiện trong Stored Procedures.
- [ ] Package có `pLoadBatchKey` và `User::LoadBatchKey` kiểu `Int64`.
- [ ] `FactRows` là `Int64`, không phải `UInt64`.
- [ ] Execute SQL Task dùng `CM_DanangDW`, `Single row`, `BypassPrepare=True`.
- [ ] SQL có đúng một dấu `?` và Parameter Mapping ordinal `0`, kiểu `LONG`.
- [ ] Năm Result Binding map đúng ordinal `0..4`.
- [ ] Debug trả `PASS / 14 / 5 / 21301`.
- [ ] `28_validate_final_dwh.sql` PASS.
- [ ] Package 50 đã nằm giữa package 40 và 80 trong master.
- [ ] Batch vẫn `SILVER_VALIDATED`; chưa cleanup và chưa complete.

Checkpoint sau bước 50: DWH đã vượt structural gate với 14 Dimension, 5 Fact và
21.301 Fact rows; grain, hierarchy, foreign key, provenance và các ngoại lệ nullable
đều hợp lệ. Bước kế tiếp chính xác là `80_Reconcile.dtsx` để đối chiếu KPI nghiệp vụ.
