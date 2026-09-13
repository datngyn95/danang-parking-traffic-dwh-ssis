# Bộ hướng dẫn triển khai ETL

Tài liệu gốc về dữ liệu và mô hình: [`../../Agent.md`](../../Agent.md)

Mỗi đầu việc/package có một file riêng. Chỉ chuyển sang file kế tiếp khi tiêu chí nghiệm thu của file hiện tại đã đạt.

## Trạng thái hiện tại

| Thứ tự | Tài liệu | Trạng thái |
|---:|---|---|
| 00 | [`00_MASTER_ORCHESTRATION.md`](00_MASTER_ORCHESTRATION.md) | Extract + Transform đã chạy đến package 23; Complete Batch vẫn disabled |
| 10 | [`10_EXTRACT_MASTER_CSV.md`](10_EXTRACT_MASTER_CSV.md) | **Đã hoàn thành — batch 7: 20/18/30, reject 0** |
| 11 | [`11_EXTRACT_GEOJSON.md`](11_EXTRACT_GEOJSON.md) | **Đã hoàn thành — 30 roads, 50 POI, UTF-8 đúng** |
| 12 | [`12_EXTRACT_JSONL.md`](12_EXTRACT_JSONL.md) | **Đã hoàn thành thiết kế nhanh — expected 16.884/4.300/168** |
| 13 | [`13_VALIDATE_EXTRACT.md`](13_VALIDATE_EXTRACT.md) | **Đã chuẩn bị Bronze gate — batch phải là BRONZE_LOADED trước Transform** |
| 20 | [`20_TRANSFORM_MASTER_DATA.md`](20_TRANSFORM_MASTER_DATA.md) | **Đã hoàn thành/nghiệm thu PASS — batch 11, 148 master Clean** |
| 21 | [`21_TRANSFORM_EVENTS.md`](21_TRANSFORM_EVENTS.md) | **Đã hoàn thành/nghiệm thu; output 16.800/4.283/168** |
| 22 | [`22_TRANSFORM_AGGREGATES.md`](22_TRANSFORM_AGGREGATES.md) | **Đã hoàn thành; output 4.200/513** |
| 23 | [`23_VALIDATE_TRANSFORM.md`](23_VALIDATE_TRANSFORM.md) | **Đã hoàn thành/nghiệm thu PASS — batch 18, SILVER_VALIDATED, 21.500/21.500/0** |
| 30 | [`30_DATA_FLOW_DIMENSIONS.md`](30_DATA_FLOW_DIMENSIONS.md) | **Đã chuẩn bị SQL + hướng dẫn Data Flow; chờ thực hiện trên SSMS/SSIS** |
| 40 | [`40_DATA_FLOW_FACTS.md`](40_DATA_FLOW_FACTS.md) | **Đã chuẩn bị hướng dẫn Data Flow + SQL precheck/acceptance; chờ sửa orphan path và chạy SSIS** |
| 50 | [`50_FINAL_DWH_VALIDATION.md`](50_FINAL_DWH_VALIDATION.md) | **Đã chuẩn bị stored procedure + hướng dẫn final structural gate; chờ chạy SSMS/SSIS** |
| 80 | [`80_RECONCILIATION.md`](80_RECONCILIATION.md) | Chưa thực hiện |
| 90 | [`90_CLEANUP_AND_COMPLETE.md`](90_CLEANUP_AND_COMPLETE.md) | Chưa thực hiện |

## Luồng tổng thể đã thống nhất

```text
00_Master
  → 10/11/12 Extract
  → 13 Validate Extract
  → 20/21/22 Transform
  → 23 Validate Transform
  → 30 Data Flow Dimensions theo phân cấp
  → 40 Data Flow Facts
  → 50 Final DWH Validation
  → 80 Reconciliation
  → 90 Cleanup
  → Complete Batch
```

Quy ước:

- Extract CSV dùng Data Flow Task.
- Extract GeoJSON và JSONL dùng Execute SQL Task gọi stored procedure; SQL Server đọc file bằng `OPENROWSET` và parse bằng `OPENJSON`.
- Transform chủ yếu dùng Execute SQL Task set-based.
- Load Dimension và Fact bắt buộc dùng Data Flow Task.
- Audit, validation, cập nhật trạng thái và cleanup dùng Execute SQL Task.
- Không query bảng staging để làm báo cáo chính thức.
- Không cleanup batch FAILED.

## Chuẩn bắt buộc cho các hướng dẫn từ package 23 trở đi

Người thực hiện đang học SSIS từ đầu, vì vậy mỗi tài liệu task/package tiếp theo
phải tự đủ thông tin để thao tác, không được chỉ nêu ý tưởng hoặc tiêu chí chung.

### 1. Mở đầu và checkpoint

Mỗi file phải ghi rõ:

- package trước nào phải `PASS`;
- database/bảng/trạng thái batch đầu vào cần có;
- package và file SQL nào sẽ được tạo;
- output cụ thể của task hiện tại;
- tiêu chí nào cho phép chuyển sang task kế tiếp.

### 2. Phân biệt SQL mô tả và SQL có thể chạy

- Mọi đoạn chỉ giải thích công thức phải ghi rõ **không chạy riêng trên SSMS**.
- Không để một mệnh đề rời như `WHERE`, `GROUP BY` hoặc một biểu thức khiến người
  mới hiểu nhầm là script hoàn chỉnh.
- Mọi bước yêu cầu chạy phải cung cấp câu SQL đầy đủ từ `USE`/`DECLARE` đến
  `SELECT`/`EXEC` và nói rõ chạy toàn bộ đoạn hay chỉ một phần.
- Stored procedure phải được cài trên SSMS trước khi tạo Execute SQL Task gọi nó.

### 3. Hướng dẫn SSMS từng bước

Phải nêu rõ:

1. mở file SQL nào;
2. chọn database nào trên dropdown;
3. sửa tham số nào và chỉ được nhập kiểu giá trị gì;
4. chọn/chạy toàn bộ file bằng `Execute` hoặc `F5`;
5. Refresh node nào trong Object Explorer;
6. object nào phải xuất hiện;
7. result set và giá trị expected;
8. truy vấn nghiệm thu tự động trả `PASS` hoặc `THROW` khi sai.

Không chỉ viết danh sách “tiêu chí nghiệm thu”; phải có file SQL read-only để
người dùng chạy và nhận kết quả rõ ràng.

### 4. Hướng dẫn SSIS từng bước

Phải nêu đúng vị trí và thao tác giao diện:

- tạo/đổi tên package trong **Solution Explorer → SSIS Packages**;
- tạo parameter/variable với tên, scope, data type, value và `Required` cụ thể;
- chọn Connection Manager nào và cách **Test Connection**;
- kéo task nào từ **SSIS Toolbox** vào **Control Flow/Data Flow**;
- cấu hình từng tab **General**, **Parameter Mapping**, **Result Set**,
  **Expressions** hoặc **Parameter Bindings**;
- dùng đúng kiểu dữ liệu thực sự có trong UI/provider. Với OLE DB hiện tại, batch
  key dùng `LONG` và SQL phải có `CONVERT(bigint, ?)`;
- tên task, SQLStatement, ordinal parameter và direction phải được ghi chính xác;
- nói rõ task/package nào có thể copy rồi sửa để tiết kiệm thời gian.

### 5. Debug package độc lập

Mỗi package phải có:

- cách lấy `LoadBatchKey` thật trên SSMS;
- cách gán **số** vào package parameter khi chạy riêng, không nhập chữ
  `LoadBatchKey`;
- cách chọn package đó làm Startup Object khi cần;
- thao tác `Start/F5` và dấu hiệu thành công;
- câu SQL kiểm tra output ngay sau debug;
- lỗi thường gặp như procedure chưa tồn tại, parameter bằng `0`, sai connection,
  sai database hoặc chạy validation trước khi chạy transform.

### 6. Gắn vào `00_Master.dtsx` và chạy toàn luồng

Không được kết thúc ở bước nối connector. Phải hướng dẫn tiếp:

1. tạo/copy **Execute Package Task**;
2. chọn đúng Project Reference và child package;
3. bind `pLoadBatchKey → User::LoadBatchKey`;
4. nối mũi tên xanh theo đúng thứ tự;
5. `Save All`;
6. nhấp phải `00_Master.dtsx` → **Set as StartUp Object**;
7. mở `00_Master.dtsx` → `Start/F5`;
8. mô tả task nào phải xanh, task nào còn Disabled;
9. kiểm tra batch mới nhất trên SSMS và ghi rõ trạng thái expected;
10. sau đó mới chạy acceptance SQL của package.

### 7. Giải thích quy tắc chất lượng dữ liệu

“Clean” không đồng nghĩa mọi cột đều khác `NULL`. Với mỗi ngoại lệ đã biết phải
nói rõ:

- `NULL` là hợp lệ, thiếu dữ liệu hay lỗi;
- được giữ, loại, nội suy hay chỉ gắn cờ ở package nào;
- cờ DQ tương ứng và expected count;
- KPI/tổng hợp xử lý `NULL` như thế nào;
- không tự dùng `0` thay dữ liệu thiếu nếu `0` có ý nghĩa nghiệp vụ khác.

### 8. Giữ phương án triển khai nhanh đã thống nhất

- Extract GeoJSON/JSONL và Transform: ưu tiên một Execute SQL Task gọi stored
  procedure set-based.
- Load Dimension và Load Fact: bắt buộc dùng Data Flow Task.
- Tận dụng copy package/task/component khi metadata tương thích, nhưng phải hướng
  dẫn toàn bộ chỗ cần đổi để không còn metadata hoặc connection cũ.
- Mỗi tài liệu kết thúc bằng checkpoint ngắn: **đã có gì, chưa có gì, bước kế
  tiếp chính xác là gì**.
