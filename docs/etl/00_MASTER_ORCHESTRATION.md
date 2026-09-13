# 00 — Master Orchestration

## Mục tiêu

`00_Master.dtsx` tạo một `LoadBatchKey`, truyền key đó cho từng package con, điều khiển thứ tự ETL và chỉ đặt `COMPLETED` sau reconciliation/cleanup thành công.

## Trạng thái đã xác nhận

- Có `SQL - Start Batch`.
- Có biến `User::LoadBatchKey` kiểu Int64.
- Smoke test tạo batch đã thành công.
- `SQL - Complete Batch` đang disabled để không hoàn thành batch quá sớm.
- Hai Project Connection Manager:
  - `(project) CM_DanangDW` → `DanangSmartParkingDW`.
  - `(project) CM_DanangSTG` → `DanangSmartParkingSTG`.

## Checkpoint Extract CSV đã hoàn thành

`10_Extract_MasterCSV.dtsx` đã nạp thành công ba file `02`, `03`, `05` trong cùng batch với số dòng `20`, `18`, `30` và reject bằng `0`.

## Checkpoint Extract GeoJSON đã hoàn thành

`11_Extract_GeoJSON.dtsx` đã nạp thành công `30` road và `50` POI; dữ liệu UTF-8 hiển thị đúng tiếng Việt.

## Checkpoint Extract JSONL

`12_Extract_JSONL.dtsx` phải nạp `16.884` traffic, `4.300` parking event và `168` weather trong cùng batch trước khi validation được phép chạy.

## Checkpoint Validate Extract

Thực hiện chi tiết theo [`13_VALIDATE_EXTRACT.md`](13_VALIDATE_EXTRACT.md). Bronze gate phải đổi batch sang `BRONZE_LOADED` trước khi package Transform được phép chạy.

Tóm tắt thao tác trong Master:

1. Mở `00_Master.dtsx` → Control Flow.
2. Giữ `SQL - Complete Batch` ở trạng thái Disabled.
3. Giữ các task Extract 10, 11 và 12 đã có.
4. Copy task `PKG - Extract JSONL` thành một Execute Package Task mới.
5. Đổi tên bản sao thành `PKG - Validate Extract`.
6. Mở task mới:
   - ReferenceType: `Project Reference`.
   - Package: `13_Validate_Extract.dtsx`.
   - Parameter Bindings: `pLoadBatchKey = User::LoadBatchKey`.
7. Nối mũi tên Success từ `PKG - Extract JSONL` tới `PKG - Validate Extract`.
8. Không nối vào `SQL - Complete Batch` ở giai đoạn này.

Sơ đồ tạm:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
  → PKG - Extract GeoJSON
  → PKG - Extract JSONL
  → PKG - Validate Extract

SQL - Complete Batch [Disabled]
```

## Checkpoint Transform Master Data

Package 20 đã được chuyển sang mô hình **một Execute SQL Task**. SQL set-based xử lý toàn bộ Road, Facility, Restriction, POI và Road Survey trong một lần gọi. Script nghiệm thu đã trả `PASS` cho batch 11 với 148 master row hợp lệ.

Thực hiện theo [`20_TRANSFORM_MASTER_DATA.md`](20_TRANSFORM_MASTER_DATA.md):

1. Chạy `sql/22_transform_master_data.sql` trên SSMS để tạo procedure.
2. Tạo `20_Transform_MasterData.dtsx` với một Execute SQL Task.
3. Debug độc lập bằng đúng `LoadBatchKey` có status `BRONZE_LOADED`.
4. Đối soát output `30/20/18/50/30`, reject `0`.
5. Gắn package 20 sau `PKG - Validate Extract` trong Master.

```text
PKG - Validate Extract
  → PKG - Transform Master Data

SQL - Complete Batch [Disabled]
```

## Checkpoint Transform Events

Thực hiện theo [`21_TRANSFORM_EVENTS.md`](21_TRANSFORM_EVENTS.md):

1. Chạy `sql/23_transform_events.sql` trên SSMS để tạo procedure.
2. Tạo `21_Transform_Events.dtsx` với một Execute SQL Task.
3. Mapping `pLoadBatchKey` bằng `LONG`, ordinal `0`; câu SQL chuyển `?` sang `bigint`.
4. Debug độc lập bằng đúng batch key đang `BRONZE_LOADED`.
5. Chạy `sql/23_validate_transform_events.sql`; chỉ tiếp tục khi result cuối là `PASS`.
6. Gắn package 21 sau package 20 trong Master.

Expected output:

- Traffic Clean: `16.800`, gồm 84 duplicate được loại và audit.
- Parking Clean: `4.283`, gồm 17 duplicate được loại và audit.
- Weather Clean: `168`.
- Toàn bộ Clean hợp lệ; Unicode `Trần Phú / Hải Châu core` hiển thị đúng.

```text
PKG - Transform Master Data
  → PKG - Transform Events

SQL - Complete Batch [Disabled]
```

## Checkpoint Transform Aggregates

Package 22 dùng **một Execute SQL Task** gọi procedure set-based. Chỉ thực hiện sau khi script nghiệm thu package 21 trả `PASS`.

Thực hiện theo [`22_TRANSFORM_AGGREGATES.md`](22_TRANSFORM_AGGREGATES.md):

1. Chạy `sql/24_transform_aggregates.sql` trên SSMS và kiểm tra procedure tồn tại.
2. Tạo `22_Transform_Aggregates.dtsx` bằng cách copy package 21.
3. Đổi SQLStatement sang `dbo.usp_TransformAggregates`; giữ mapping `LONG`, ordinal `0`.
4. Debug độc lập bằng cùng `LoadBatchKey` của package 21.
5. Chạy `sql/24_validate_transform_aggregates.sql`; chỉ tiếp tục khi result đầu là `PASS`.
6. Gắn package 22 sau package 21 trong Master.

Expected output:

- `transform.TrafficHourlySummary`: `4.200` dòng.
- `transform.ParkingDailySummary`: `513` dòng.
- Tổng Traffic `6.596.879` vehicle và `9.100` illegal observation.
- Tổng Parking `4.283` event, `1.571` illegal và `64` open.

```text
PKG - Transform Events
  → PKG - Transform Aggregates

SQL - Complete Batch [Disabled]
```

## Checkpoint Validate Transform / Silver gate

Thực hiện chi tiết theo [`23_VALIDATE_TRANSFORM.md`](23_VALIDATE_TRANSFORM.md).
Package 23 dùng một Execute SQL Task gọi
`DanangSmartParkingDW.etl.usp_ValidateTransformAndMarkSilver`.

Thứ tự bắt buộc:

1. Chạy `sql/25_validate_transform_and_mark_silver.sql` để cài hai procedure.
2. Chạy preflight read-only; mọi `IsMatched` phải bằng `1`.
3. Tạo và debug độc lập `23_Validate_Transform.dtsx`.
4. Chạy `sql/25_accept_transform_silver.sql`; kết quả phải là `PASS`.
5. Gắn package 23 ngay sau package 22 và bind
   `pLoadBatchKey = User::LoadBatchKey`.
6. Save All, Rebuild Solution, đặt `00_Master.dtsx` làm StartUp Object rồi F5.

Output checkpoint:

```text
LoadStatus    = SILVER_VALIDATED
RowsRead      = 21500
RowsAccepted  = 21500
RowsRejected  = 0
ErrorMessage  = NULL
CompletedAt   = NULL
```

```text
PKG - Transform Aggregates
  → PKG - Validate Transform

SQL - Complete Batch [Disabled]
```

Checkpoint thực tế đã nghiệm thu ngày 21/08/2026:

```text
LoadBatchKey  = 18
LoadStatus    = SILVER_VALIDATED
RowsRead      = 21500
RowsAccepted  = 21500
RowsRejected  = 0
ErrorMessage  = NULL
CompletedAt   = NULL
```

Package tiếp theo là `30_Load_Dimensions.dtsx`. Phần load dữ liệu nghiệp vụ của
package 30 bắt buộc dùng **Data Flow Task**; Execute SQL Task chỉ được dùng cho
precheck và post-load validation.

## Đích đến cuối cùng

```text
Start Batch
  → Extract packages
  → Validate Extract
  → Transform packages
  → Validate Transform
  → Dimension packages
  → Fact packages
  → Final DWH Validation
  → Reconcile
  → Cleanup
  → Complete Batch
```

Mọi failure path cập nhật batch `FAILED` và không được đi qua Cleanup.
