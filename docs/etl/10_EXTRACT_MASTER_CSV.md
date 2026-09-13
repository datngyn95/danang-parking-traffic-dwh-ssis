# 10 — Extract Master CSV

## 1. Mục tiêu và checkpoint

Package: `10_Extract_MasterCSV.dtsx`  
Tên nội bộ: `P10_Extract_MasterCSV`

Checkpoint hiện tại đã có:

- Package parameter `pLoadBatchKey`, Int64.
- Variable `User::LoadFileKey`, Int64, giá trị đầu 0.
- `(project) CM_DanangDW` và `(project) CM_DanangSTG`.
- Luồng `02_parking_locations.csv` đã chạy thành công và được đối soát `20/20/0`.
- Batch vẫn `STARTED`, đúng với giai đoạn phát triển hiện tại.

Bước tiếp theo là nối thêm hai chuỗi task vào sau luồng Parking Locations:

```text
03_parking_restrictions.csv
  → 05_road_survey.csv
```

Output cuối của package:

- 20 dòng của `02_parking_locations.csv` trong `DanangSmartParkingSTG.extract.ParkingLocationRaw`.
- 18 dòng của `03_parking_restrictions.csv` trong `DanangSmartParkingSTG.extract.ParkingRestrictionRaw`.
- 30 dòng của `05_road_survey.csv` trong `DanangSmartParkingSTG.extract.RoadSurveyRaw`.
- Ba dòng `etl.LoadFile` cùng batch có status `COMPLETED` và không có reject.
- Batch vẫn `STARTED` vì toàn bộ ETL chưa hoàn thành.

### 1.1. Cách dùng tài liệu này nếu bạn mới học SSIS

Không làm toàn bộ một lần. Hãy làm và kiểm tra theo các chặng sau:

| Chặng | Nơi thao tác | Kết quả cần đạt |
|---|---|---|
| A | SSMS | Xác nhận bảng đích tồn tại và đang rỗng |
| B | SSIS — Parameters/Variables | Xác nhận đúng parameter và variable |
| C | SSIS — Control Flow | Hoàn thiện task đăng ký file |
| D | SSIS — Connection Managers | Đọc thử đúng file CSV và đúng tiếng Việt |
| E | SSIS — Data Flow | Nạp 20 dòng từ CSV sang Staging |
| F | SSIS — Control Flow | Cập nhật audit file thành `COMPLETED` |
| G | SSIS — Master + SSMS | Chạy từ Master và đối soát kết quả |

Sau mỗi chặng:

1. Nhấn `Ctrl+Shift+S` để **Save All**.
2. Không tiếp tục nếu component đang có dấu `X` đỏ.
3. Đối chiếu mục **Kết quả phải thấy** của chặng đó.

### 1.2. Nhận biết các vùng trên màn hình SSIS

- **Solution Explorer**: khung bên phải, chứa `Project.params`, Connection Managers và các package `.dtsx`.
- **SSIS Toolbox**: khung bên trái, nơi kéo `Data Flow Task`, `Execute SQL Task`, `Flat File Source`...
- **Control Flow**: tab thiết kế trình tự chạy task.
- **Data Flow**: tab thiết kế luồng dữ liệu giữa Source, Transformation và Destination.
- **Connection Managers**: khung dưới cùng của package designer.
- **Properties**: nhấn `F4`; dùng để sửa thuộc tính và Expression.
- **Variables**: menu `SSIS → Variables`; khác với tab `Parameters`.

Trong tài liệu này:

- `pLoadBatchKey` là **package parameter**, nhận giá trị từ Master.
- `User::LoadFileKey` là **package variable**, nhận kết quả từ task đăng ký file.
- Không tự gõ tiền tố `$Package::`, `$Project::` hoặc `User::` vào cột **Name** khi tạo mới. SSIS tự hiển thị các tiền tố này khi tham chiếu.

### 1.3. Việc bạn nên làm ngay tại checkpoint hiện tại

1. Không sửa luồng Parking Locations đã chạy đúng.
2. Đi thẳng tới mục 17 để đọc quy tắc copy/tái sử dụng.
3. Thực hiện đầy đủ mục 18 cho `03_parking_restrictions.csv` và chạy checkpoint.
4. Chỉ khi Restrictions đạt `18/18/0`, thực hiện mục 19 cho `05_road_survey.csv`.
5. Chạy kiểm thử cuối package tại mục 21 và đối soát SSMS tại mục 22.

Các mục 2–16 được giữ lại làm hướng dẫn/reference cho luồng Parking Locations và xử lý lỗi khi cần.

## 2. Kiểm tra trước trên SSMS

Đây là **Chặng A**. Mở SSMS và làm như sau:

1. Kết nối tới server `EC2AMAZ-8A1DACA\NEW_PROJECT`.
2. Bấm **New Query**.
3. Chọn database `master` hoặc bất kỳ database nào; câu lệnh dưới dùng tên ba phần nên vẫn chạy đúng.
4. Dán và chạy toàn bộ đoạn sau:

```sql
SELECT
    DB_ID(N'DanangSmartParkingDW') AS DWDatabaseID,
    DB_ID(N'DanangSmartParkingSTG') AS STGDatabaseID;

SELECT
    OBJECT_ID(N'DanangSmartParkingSTG.extract.ParkingLocationRaw', N'U')
        AS ParkingLocationRawObjectID;

SELECT COUNT_BIG(*) AS CurrentRows
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw;

SELECT TOP (5)
    LoadBatchKey, LoadFileKey, FileName, LoadStatus,
    ActualRowCount, AcceptedRowCount, RejectedRowCount
FROM DanangSmartParkingDW.etl.LoadFile
ORDER BY LoadFileKey DESC;
```

Kết quả phải thấy:

- `DWDatabaseID` và `STGDatabaseID` khác `NULL`.
- `ParkingLocationRawObjectID` khác `NULL`.
- `CurrentRows = 0` tại checkpoint hiện tại.
- Query chạy không có thông báo `Invalid object name`.

Staging bằng 0 là trạng thái đúng trước Extract. Không xóa bảng `DanangSmartParkingDW.stg.ParkingLocationRaw` legacy trong bước này; package mới phải nạp vào `DanangSmartParkingSTG.extract.ParkingLocationRaw`.

## 3. Kiểm tra Project Parameter trên SSIS

Đây là **Chặng B**.

### 3.1. Kiểm tra project parameter `pRawRoot`

1. Trong **Solution Explorer**, nhấp đúp `Project.params`.
2. Tìm dòng có Name là `pRawRoot`.
3. Kiểm tra:

```text
pRawRoot = C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d
```

- Data type: String.
- Không có dấu `\` ở cuối.
- Nên đặt Required=True.

Không nhập tên là `$Project::pRawRoot`. Tên thật chỉ là `pRawRoot`; `$Project::pRawRoot` chỉ là cú pháp dùng trong Expression.

### 3.2. Kiểm tra package parameter `pLoadBatchKey`

1. Trong **Solution Explorer → SSIS Packages**, nhấp đúp `10_Extract_MasterCSV.dtsx`.
2. Mở tab **Parameters** của package.
3. Kiểm tra đúng một dòng:

```text
pLoadBatchKey | Int64 | Required=True
```

Giá trị thiết kế có thể là `0`; khi chạy thật Master sẽ truyền một khóa batch hợp lệ xuống.

### 3.3. Kiểm tra variable `LoadFileKey`

1. Trở lại tab **Control Flow** của `10_Extract_MasterCSV.dtsx`.
2. Bấm vào vùng trống của mặt thiết kế để chọn scope package.
3. Vào menu **SSIS → Variables**.
4. Kiểm tra:

```text
Name: LoadFileKey
Scope: P10_Extract_MasterCSV
Data type: Int64
Value: 0
```

Nếu Scope hiện `Package1` nhưng package nội bộ chưa đổi tên, bấm vùng trống Control Flow, nhấn `F4`, đổi thuộc tính `Name` của package thành `P10_Extract_MasterCSV`, sau đó kiểm tra lại variable. Variable phải có scope ở package, không nằm trong riêng một task.

### 3.4. Chặng C — kiểm tra task `SQL - Register Parking File`

Task này phải nằm trong **Control Flow** của `10_Extract_MasterCSV.dtsx`. Nếu task đã có, nhấp đúp để kiểm tra; nếu chưa có, kéo **Execute SQL Task** từ SSIS Toolbox vào và đổi tên.

Trang **General**:

| Thuộc tính | Giá trị |
|---|---|
| Name | `SQL - Register Parking File` |
| ConnectionType | `OLE DB` |
| Connection | `(project) CM_DanangDW` |
| SQLSourceType | `Direct input` |
| ResultSet | `Single row` |
| BypassPrepare | `True` |

SQL Statement:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

INSERT etl.LoadFile
(
    LoadBatchKey,
    SourceID,
    FileName,
    FileFormat,
    ExpectedRowCount,
    LoadStatus
)
VALUES
(
    @LoadBatchKey,
    '02',
    N'02_parking_locations.csv',
    'CSV',
    20,
    'STARTED'
);

SELECT CONVERT(bigint, SCOPE_IDENTITY()) AS LoadFileKey;
```

Trang **Parameter Mapping**, bấm **Add** và cấu hình:

| Variable Name | Direction | Data Type | Parameter Name | Parameter Size |
|---|---|---|---:|---:|
| `$Package::pLoadBatchKey` | Input | `LONG` | `0` | `-1` |

Trong OLE DB, dấu `?` được ánh xạ theo thứ tự `0`, `1`, `2`..., không đặt Parameter Name là tên SQL như `@LoadBatchKey`.

Trang **Result Set**, bấm **Add** và cấu hình:

| Result Name | Variable Name |
|---:|---|
| `0` | `User::LoadFileKey` |

Kết quả phải thấy sau Chặng C:

- Task không còn dấu `X` đỏ.
- Parameter Mapping có một dòng ordinal `0`.
- Result Set có một dòng `0 → User::LoadFileKey`.
- Chưa bấm chạy riêng task này vì `pLoadBatchKey=0` không có bản ghi cha trong `etl.LoadBatch`.

## 4. Tạo Flat File Connection Manager

Đây là **Chặng D**. Trước khi làm, mở file bằng Notepad để chắc chắn file tồn tại tại:

```text
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\02_parking_locations.csv
```

Sau đó thao tác trong `10_Extract_MasterCSV.dtsx`:

1. Mở tab **Control Flow** của package.
2. Bấm phải vùng **Connection Managers** phía dưới.
3. Chọn **New Flat File Connection...**.
4. Nếu không thấy lựa chọn này, chọn **New Connection... → FLATFILE → Add**.
5. Trang **General**:
   - Connection manager name: `FF_ParkingLocations`.
   - File name: Browse tới `C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\02_parking_locations.csv`.
   - Format: `Delimited`.
   - Text qualifier: `"`.
   - Header row delimiter: `{CR}{LF}`.
   - Header rows to skip: `0`.
   - `Column names in the first data row`: checked.
   - Unicode: **không check** vì file là UTF-8, không phải UTF-16.
   - Code page: `65001 (UTF-8)`.
6. Trang **Columns**:
   - Row delimiter: `{CR}{LF}`.
   - Column delimiter: comma `{,}`.
   - Kiểm tra preview tách đúng 12 cột.
7. Trang **Advanced**: không dùng Suggest Types; giữ RAW là chuỗi và cấu hình:

| Source column | Data type | OutputColumnWidth |
|---|---|---:|
| `parking_id` | Unicode string `[DT_WSTR]` | 50 |
| `parking_name` | Unicode string `[DT_WSTR]` | 250 |
| `address_or_corridor` | Unicode string `[DT_WSTR]` | 250 |
| `analysis_zone` | Unicode string `[DT_WSTR]` | 150 |
| `capacity_spaces` | Unicode string `[DT_WSTR]` | 30 |
| `parking_type` | Unicode string `[DT_WSTR]` | 100 |
| `facility_status` | Unicode string `[DT_WSTR]` | 100 |
| `capacity_status` | Unicode string `[DT_WSTR]` | 100 |
| `coordinate_status` | Unicode string `[DT_WSTR]` | 200 |
| `latitude` | Unicode string `[DT_WSTR]` | 50 |
| `longitude` | Unicode string `[DT_WSTR]` | 50 |
| `source_url` | Unicode string `[DT_WSTR]` | 1000 |

Cách sửa từng cột ở trang **Advanced**:

1. Chọn tên cột ở danh sách bên trái.
2. Ở bảng thuộc tính bên phải, đặt `DataType = Unicode string [DT_WSTR]`.
3. Đặt `OutputColumnWidth` theo bảng trên.
4. Lặp lại đủ 12 cột.
5. Mở lại trang **Preview** trước khi bấm OK.

Trong Preview, hàng đầu tiên phải là dữ liệu `PK001...`, không phải tên header. Các giá trị như `Bãi đỗ xe 166 Hải Phòng` phải hiển thị đúng dấu.

Nếu cột đầu hiển thị BOM hoặc tên kiểu `ï»¿parking_id`, kiểm tra lại Code page 65001 rồi đổi OutputColumnName thủ công thành `parking_id`.

Sau khi tạo xong:

1. Chọn `FF_ParkingLocations` ở vùng Connection Managers.
2. Nhấn F4 mở Properties.
3. Tại `Expressions`, bấm `...`.
4. Property: `ConnectionString`.
5. Expression:

```text
@[$Project::pRawRoot] + "\\02_parking_locations.csv"
```

6. Evaluate Expression phải trả về đúng full path.

Nếu Expression Builder báo lỗi, kiểm tra chính xác:

- Có `@[$Project::pRawRoot]`.
- Giữa root và file có `"\\02_parking_locations.csv"`.
- Không đặt dấu `\` cuối giá trị `pRawRoot`.

Kết quả phải thấy sau Chặng D:

- Connection Manager có tên `FF_ParkingLocations`.
- Test/Preview đọc đủ 12 cột.
- Tiếng Việt không lỗi font.
- Khi chọn connection và nhấn `F4`, thuộc tính `Expressions` hiển thị `ConnectionString` đã được gán.

## 5. Tạo Data Flow Task

Đây là phần đầu của **Chặng E**. Trong tab **Control Flow** của `10_Extract_MasterCSV.dtsx`:

1. Trong **SSIS Toolbox**, tìm `Data Flow Task`.
2. Giữ chuột và kéo task vào vùng trống bên dưới `SQL - Register Parking File`.
3. Bấm một lần vào task mới, nhấn `F2`, đổi tên thành `DFT - Extract Parking Locations`.
4. Bấm `SQL - Register Parking File` để hiện mũi tên nối màu xanh.
5. Giữ đầu mũi tên xanh và kéo xuống `DFT - Extract Parking Locations`.
6. Mũi tên xanh nghĩa là Data Flow chỉ chạy khi Register thành công.
7. Nhấp đúp `DFT - Extract Parking Locations` để mở tab **Data Flow**.

Nếu SSIS hiện dòng chữ *No Data Flow tasks have been added...*, hãy quay lại Control Flow và chắc chắn bạn đã nhấp đúp đúng Data Flow Task.

Kết quả phải thấy:

```text
SQL - Register Parking File
          |
          | Success (màu xanh)
          v
DFT - Extract Parking Locations
```

## 6. Thêm Flat File Source

1. Đang ở tab **Data Flow**, tìm `Flat File Source` trong SSIS Toolbox.
2. Kéo vào mặt thiết kế.
3. Nhấn `F2`, đổi tên thành `SRC - Parking Locations CSV`.
4. Nhấp đúp source để mở **Flat File Source Editor**.
5. Trang **Connection Manager**:
   - Flat file connection manager: chọn `FF_ParkingLocations`.
   - Data rows to skip: `0`.
6. Trang **Columns**:
   - Phải thấy đủ 12 input column.
   - Check tất cả 12 cột.
7. Trang **Error Output**:
   - Chọn tất cả các dòng cột.
   - Cột `Error`: chọn `Redirect row`.
   - Cột `Truncation`: chọn `Redirect row`.
   - Nếu có nút **Set this value to selected cells**, dùng nút đó để áp dụng hàng loạt.
8. Bấm **OK**.

Luồng xanh là dữ liệu hợp lệ; luồng đỏ sẽ được ghi vào `etl.RejectedRow` ở mục 10.

Kết quả phải thấy: source không có dấu `X` đỏ. Nếu rê chuột lên source mà báo metadata lỗi, mở lại `FF_ParkingLocations → Preview` và kiểm tra đường dẫn/file.

## 7. Tạo SourceRowNumber bằng Script Component

Mục đích của component này là tạo số dòng gốc để truy vết lỗi về file CSV. Header nằm ở dòng 1, nên dữ liệu bắt đầu ở dòng 2.

1. Kéo **Script Component** từ SSIS Toolbox vào Data Flow.
2. Hộp **Select Script Component Type** xuất hiện, chọn `Transformation`, bấm **OK**.
3. Nhấn `F2`, đổi tên `SCR - Add Source Row Number`.
4. Từ `SRC - Parking Locations CSV`, kéo **mũi tên xanh** sang Script Component.
5. Nếu hộp **Input Output Selection** xuất hiện, chọn output dữ liệu hợp lệ, không chọn error output.
6. Nhấp đúp Script Component.
7. Trang **Input Columns**: giữ các cột input ở trạng thái read-only; không cần chọn thêm cột vì script chỉ sinh số thứ tự.
8. Trang **Inputs and Outputs**:
   - Mở `Output 0`.
   - Chọn `Output Columns`.
   - Bấm **Add Column**.
   - Đổi Name thành `SourceRowNumber`.
   - DataType chọn `eight-byte signed integer [DT_I8]`.
9. Trang **Script**:
   - ScriptLanguage: `Microsoft Visual C#`.
   - Bấm **Edit Script...** để mở cửa sổ VSTA.
10. Trong class `ScriptMain`, thêm biến sau ở cấp class, ngay trước method `Input0_ProcessInputRow`:

```csharp
private long sourceRowNumber = 1;
```

11. Tìm method có sẵn `Input0_ProcessInputRow(Input0Buffer Row)` và sửa phần thân method thành:

```csharp
public override void Input0_ProcessInputRow(Input0Buffer Row)
{
    sourceRowNumber++;
    Row.SourceRowNumber = sourceRowNumber;
}
```

Không dán một class `ScriptMain` thứ hai và không xóa các dòng `using`/code do SSIS sinh ra. Phần cốt lõi sau khi sửa phải chứa:

```csharp
private long sourceRowNumber = 1;

public override void Input0_ProcessInputRow(Input0Buffer Row)
{
    sourceRowNumber++;
    Row.SourceRowNumber = sourceRowNumber;
}
```

12. Trong VSTA, chọn **Build → Build Solution**.
13. Output phải báo build thành công, không có Error.
14. Đóng cửa sổ VSTA, bấm **OK** tại Script Transformation Editor.

Nếu code báo `Input0Buffer` không tồn tại, thường là chưa nối source vào Script Component trước khi bấm Edit Script. Đóng editor, nối mũi tên xanh rồi mở lại.

Nếu code báo `SourceRowNumber` không tồn tại, kiểm tra bạn đã tạo output column đúng tên và đúng chữ hoa/thường trước khi Edit Script.

CSV có header ở dòng 1 nên dòng dữ liệu đầu tiên nhận `SourceRowNumber=2`; dòng cuối nhận 21.

Thiết lập đầu ra cần đúng:

- Name: `SourceRowNumber`.
- DataType: eight-byte signed integer `[DT_I8]`.
- Không dùng Int32/`DT_I4` vì cột SQL đích là `bigint`.

> Lưu ý: SSIS Script Component chỉ sinh số thứ tự trong một lần chạy Data Flow. Khóa duy nhất của staging là cặp `LoadFileKey + SourceRowNumber`, nên số dòng không cần tăng xuyên suốt nhiều batch.

## 8. Thêm audit columns bằng Derived Column

1. Kéo **Derived Column** vào Data Flow.
2. Nhấn `F2`, đổi tên `DRV - Add Batch And File Keys`.
3. Kéo mũi tên xanh từ `SCR - Add Source Row Number` sang Derived Column.
4. Nhấp đúp Derived Column để mở editor.
5. Ở dòng trống đầu tiên, nhập `LoadBatchKey` tại cột **Derived Column Name**.
6. Cột **Derived Column** chọn `<add as new column>`.
7. Cột **Expression** mở danh sách Parameters and Variables và kéo `$Package::pLoadBatchKey` vào, hoặc nhập:

```text
@[$Package::pLoadBatchKey]
```

8. Ở dòng kế tiếp, nhập `LoadFileKey`, chọn `<add as new column>`, Expression:

```text
@[User::LoadFileKey]
```

9. Xem cột **Data Type** của cả hai dòng; phải là `eight-byte signed integer [DT_I8]`.
10. Bấm **OK**.

Hai dòng cấu hình hoàn chỉnh:

| Derived Column Name | Expression | Kiểu mong đợi |
|---|---|---|
| `LoadBatchKey` | `@[$Package::pLoadBatchKey]` | DT_I8 |
| `LoadFileKey` | `@[User::LoadFileKey]` | DT_I8 |

Chọn `Add as new column`, không thay thế business columns.

Nếu expression hiện màu đỏ:

- Với package parameter, chọn đúng `$Package::pLoadBatchKey`, không phải `$Project::pLoadBatchKey`.
- Với variable, chọn đúng `User::LoadFileKey`.
- Kiểm tra cả hai đều là Int64.

## 9. Tạo OLE DB Destination chính

1. Kéo **OLE DB Destination** từ SSIS Toolbox vào Data Flow.
2. Nhấn `F2`, đổi tên `DST - extract.ParkingLocationRaw`.
3. Kéo mũi tên xanh từ `DRV - Add Batch And File Keys` tới Destination.
4. Nhấp đúp Destination.
5. Trang **Connection Manager**:
   - OLE DB connection manager: `(project) CM_DanangSTG`.
   - Data access mode: `Table or view - fast load`.
   - Name of the table or the view: `[extract].[ParkingLocationRaw]`.
6. Nếu không thấy bảng:
   - Bấm **New...** là không cần thiết và dễ tạo sai bảng.
   - Hủy editor, kiểm tra `CM_DanangSTG` đang trỏ tới database `DanangSmartParkingSTG`.
   - Quay lại và mở danh sách bảng lần nữa.
7. Nếu trang **Connection Manager** có tùy chọn fast-load:
   - `Keep identity`: không check.
   - `Keep nulls`: **không check**. Bảng đích có `ExtractedAt NOT NULL DEFAULT SYSUTCDATETIME()`; bỏ chọn để SQL Server áp dụng giá trị DEFAULT cho cột không được map.
   - `Table lock`: có thể giữ check/default.
   - `Check constraints`: check.
   - `Rows per batch`: để trống hoặc `20`.
   - `Maximum insert commit size`: giữ mặc định; file chỉ có 20 dòng.
8. Chọn trang **Mappings**.
9. Kéo từng input column bên trái sang đúng destination column bên phải theo bảng dưới. SSIS có thể tự nối các cột trùng tên; vẫn phải kiểm tra thủ công tất cả đường nối.

| Input | Destination |
|---|---|
| `LoadBatchKey` | `LoadBatchKey` |
| `LoadFileKey` | `LoadFileKey` |
| `SourceRowNumber` | `SourceRowNumber` |
| `parking_id` | `ParkingID` |
| `parking_name` | `ParkingName` |
| `address_or_corridor` | `AddressOrCorridor` |
| `analysis_zone` | `AnalysisZone` |
| `capacity_spaces` | `CapacitySpacesRaw` |
| `parking_type` | `ParkingType` |
| `facility_status` | `FacilityStatus` |
| `capacity_status` | `CapacityStatus` |
| `coordinate_status` | `CoordinateStatus` |
| `latitude` | `LatitudeRaw` |
| `longitude` | `LongitudeRaw` |
| `source_url` | `SourceURL` |

Không map:

- `StageRowKey`: IDENTITY.
- `RecordHashSHA256`: tạm để null; Transform/audit sẽ bổ sung.
- `ExtractedAt`: DEFAULT của SQL Server.

Ba điều kiện này phải đồng thời đúng để `ExtractedAt` nhận được thời gian mặc định:

1. `ExtractedAt` không có đường mapping.
2. `Keep nulls` không được check.
3. Bảng SQL vẫn có default constraint trên `ExtractedAt`.

Tổng số mapping chính xác phải là **15**: 3 audit columns + 12 business columns. Không map `ErrorCode` hay `ErrorColumn` vào bảng raw.

Bấm **OK**. Destination phải hết dấu `X` đỏ.

## 10. Tạo error path vào RejectedRow

Thực hiện sau khi luồng xanh đã map xong:

1. Kéo **Derived Column** mới vào vùng trống, tên `DRV - Mark Parking File Error`.
2. Bấm `SRC - Parking Locations CSV`.
3. Kéo **mũi tên đỏ** từ source sang Derived Column mới.
4. Nếu hộp **Configure Error Output** xuất hiện, đặt Error và Truncation thành `Redirect row`, rồi chọn output lỗi.
5. Nhấp đúp Derived Column và thêm bốn cột mới:

| Column | Expression |
|---|---|
| `RejectLoadFileKey` | `@[User::LoadFileKey]` |
| `RuleCode` | `(DT_STR,50,1252)"FLAT_FILE_ERROR"` |
| `Severity` | `(DT_STR,10,1252)"ERROR"` |
| `Reason` | `(DT_WSTR,1000)"Flat File error/truncation: 02_parking_locations.csv"` |

6. Kéo OLE DB Destination, tên `DST - etl.RejectedRow`.
7. Nối mũi tên xanh từ `DRV - Mark Parking File Error` sang destination này.
8. Connection: `(project) CM_DanangDW`.
9. Data access mode: `Table or view - fast load`.
10. Table: `[etl].[RejectedRow]`.
11. `Keep nulls`: không check để `RejectedAt` dùng SQL DEFAULT.
12. Chỉ map các cột bắt buộc:

| Input | Destination |
|---|---|
| `RejectLoadFileKey` | `LoadFileKey` |
| `RuleCode` | `RuleCode` |
| `Severity` | `Severity` |
| `Reason` | `Reason` |

Các cột nullable và `RejectedAt` được để SQL Server xử lý.

`ErrorCode` và `ErrorColumn` do SSIS sinh ra hiện chưa map vì bảng audit đang dùng `RuleCode`/`Reason`. Khi cần điều tra sâu, có thể bổ sung chúng vào `Reason` ở vòng hoàn thiện sau; mục tiêu hiện tại là dựng được green path an toàn.

Kết quả phải thấy sau Chặng E: Data Flow có hai nhánh:

```text
SRC - Parking Locations CSV
   |
   +-- xanh --> SCR Row Number --> DRV Keys --> DST extract.ParkingLocationRaw
   |
   +-- đỏ ----> DRV Mark Error -------------> DST etl.RejectedRow
```

Không chạy Data Flow riêng bằng **Execute Task** vì lúc đó `LoadFileKey=0`. Luôn chạy từ Master ở mục 13.

## 11. Tạo task Complete Parking File

Đây là **Chặng F**. Quay lại tab **Control Flow** bằng cách bấm tên package rồi chọn tab Control Flow:

1. Kéo **Execute SQL Task** vào bên dưới Data Flow.
2. Nhấn `F2`, đổi tên `SQL - Complete Parking File`.
3. Kéo mũi tên xanh từ `DFT - Extract Parking Locations` tới task.
4. Nhấp đúp task, trang **General**:
   - Connection: `(project) CM_DanangDW`.
   - ResultSet: `None`.
   - SQLSourceType: `Direct input`.
   - BypassPrepare: `True`.
5. Bấm nút `...` ở SQLStatement, dán toàn bộ SQL sau:

```sql
DECLARE @LoadFileKey bigint = CONVERT(bigint, ?);
DECLARE @Accepted bigint;
DECLARE @Rejected bigint;
DECLARE @Actual bigint;

SELECT @Accepted = COUNT_BIG(*)
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
WHERE LoadFileKey = @LoadFileKey;

SELECT @Rejected = COUNT_BIG(*)
FROM etl.RejectedRow
WHERE LoadFileKey = @LoadFileKey;

SET @Actual = @Accepted + @Rejected;

IF @Actual <> 20 OR @Rejected > 0
BEGIN
    UPDATE etl.LoadFile
    SET ActualRowCount = @Actual,
        AcceptedRowCount = @Accepted,
        RejectedRowCount = @Rejected,
        CompletedAt = SYSUTCDATETIME(),
        LoadStatus = 'FAILED'
    WHERE LoadFileKey = @LoadFileKey;

    THROW 51010, 'Parking Locations extract failed count or reject validation.', 1;
END;

UPDATE etl.LoadFile
SET ActualRowCount = @Actual,
    AcceptedRowCount = @Accepted,
    RejectedRowCount = @Rejected,
    CompletedAt = SYSUTCDATETIME(),
    LoadStatus = 'COMPLETED'
WHERE LoadFileKey = @LoadFileKey;

IF @@ROWCOUNT <> 1
    THROW 51011, 'LoadFile audit row was not found.', 1;
```

6. Mở trang **Parameter Mapping**.
7. Bấm **Add** đúng một lần và cấu hình:

| Variable | Direction | Data Type | Parameter Name | Size |
|---|---|---|---:|---:|
| `User::LoadFileKey` | Input | `LONG` | `0` | `-1` |

8. Không thêm Result Set vì task này dùng `ResultSet=None`.
9. Bấm **OK**.

Kết quả Control Flow của package con phải là:

```text
SQL - Register Parking File
          |
          v
DFT - Extract Parking Locations
          |
          v
SQL - Complete Parking File
```

Ba đường nối đều màu xanh. Task Complete phải dùng `CM_DanangDW`, dù nó đếm staging bằng tên database đầy đủ trong SQL.

## 12. Nối package vào Master

Làm theo [`00_MASTER_ORCHESTRATION.md`](00_MASTER_ORCHESTRATION.md):

1. Trong Solution Explorer, nhấp đúp `00_Master.dtsx`.
2. Mở tab **Control Flow**.
3. Kéo **Execute Package Task** vào giữa `SQL - Start Batch` và task Complete đang Disabled.
4. Đổi tên `PKG - Extract Master CSV`.
5. Nhấp đúp task:
   - ReferenceType: `Project Reference`.
   - PackageNameFromProjectReference: `10_Extract_MasterCSV.dtsx`.
6. Mở trang **Parameter Bindings**.
7. Bấm **Add** và chọn:

| Child package parameter | Binding source |
|---|---|
| `pLoadBatchKey` | `User::LoadBatchKey` |

8. Bấm **OK**.
9. Xóa hoặc chỉnh đường nối cũ để luồng hiện tại là `SQL - Start Batch → PKG - Extract Master CSV`.
10. `SQL - Complete Batch` vẫn **Disabled** và chưa nối vào cuối flow.

Để kiểm tra task đang Disabled: chọn `SQL - Complete Batch`, nhấn `F4`; thuộc tính `Disable` phải là `True`. Không xóa task này vì sẽ dùng ở bước cuối của toàn bộ ETL.

Không debug trực tiếp package con với `pLoadBatchKey=0`; hãy chạy từ Master để có batch thật.

## 13. Debug trên SSIS

Đây là **Chặng G**.

### 13.1. Kiểm tra trước khi bấm Start

Trong `10_Extract_MasterCSV.dtsx`:

- Ba task Control Flow không có dấu `X` đỏ.
- Data Flow có đủ nhánh xanh và nhánh đỏ.
- `SQL - Register Parking File` dùng `CM_DanangDW`.
- Destination raw dùng `CM_DanangSTG`.
- Destination reject dùng `CM_DanangDW`.

Trong `00_Master.dtsx`:

- Start Batch đã trả kết quả vào `User::LoadBatchKey` Int64.
- Execute Package Task bind `pLoadBatchKey` từ `User::LoadBatchKey`.
- Complete Batch đang Disabled.

### 13.2. Chạy debug

1. Nhấn `Ctrl+Shift+S` để Save All.
2. Trong Solution Explorer, bấm phải `00_Master.dtsx`.
3. Chọn **Set as StartUp Object** nếu menu có mục này. Nếu không có, chỉ cần mở đúng `00_Master.dtsx` và chạy package đó.
4. Bấm nút tam giác xanh **Start** hoặc nhấn `F5`.
5. Chờ package kết thúc; không bấm Stop khi task đang màu vàng.
6. Kết quả đúng:
   - Start Batch xanh.
   - Register Parking File xanh.
   - Data Flow xanh, hiển thị 20 rows ở main path.
   - Complete Parking File xanh.
   - Execute Package Task xanh.
   - Complete Batch không chạy vì đang Disabled.
7. Khi debug kết thúc, chọn **Debug → Stop Debugging** hoặc nhấn `Shift+F5` nếu Visual Studio vẫn ở chế độ debug.

Màu trong lúc chạy:

- Vàng: đang chạy, hãy chờ.
- Xanh: thành công.
- Đỏ: thất bại; mở tab **Progress/Execution Results** và đọc dòng Error đầu tiên từ dưới lên.

Thông báo source đã *processed 21 rows* nhưng đường dữ liệu hiển thị `20 rows` là bình thường với file này: log source tính cả dòng header, còn pipeline chuyển 20 dòng dữ liệu.

Không bấm phải riêng `DFT - Extract Parking Locations → Execute Task`. Cách đó bỏ qua Register, khiến `LoadFileKey` vẫn bằng 0 và destination/reject audit có thể vi phạm khóa ngoại.

## 14. Kiểm tra sau chạy trên SSMS

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT MAX(LoadBatchKey)
    FROM DanangSmartParkingDW.etl.LoadBatch
);

SELECT
    LoadBatchKey, BatchID, SourceFolder, LoadStatus,
    StartedAt, CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    LoadFileKey, LoadBatchKey, SourceID, FileName,
    ExpectedRowCount, ActualRowCount,
    AcceptedRowCount, RejectedRowCount, LoadStatus
FROM DanangSmartParkingDW.etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    COUNT_BIG(*) AS StageRows,
    MIN(SourceRowNumber) AS MinSourceRowNumber,
    MAX(SourceRowNumber) AS MaxSourceRowNumber,
    COUNT(DISTINCT LoadFileKey) AS DistinctLoadFiles
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
WHERE LoadBatchKey = @LoadBatchKey;

SELECT TOP (20)
    SourceRowNumber, ParkingID, ParkingName,
    CapacitySpacesRaw, LatitudeRaw, LongitudeRaw
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceRowNumber;
```

Expected:

| Kiểm tra | Kết quả |
|---|---|
| Batch status | `STARTED` |
| LoadFile status | `COMPLETED` |
| Actual/Accepted/Rejected | `20 / 20 / 0` |
| StageRows | 20 |
| SourceRowNumber | min 2, max 21 |
| Dấu tiếng Việt | hiển thị đúng |

Không kiểm tra tổng toàn bảng không lọc batch vì mỗi lần chạy Master sẽ tạo một batch mới và thêm 20 dòng mới.

Chưa chạy `usp_ValidateStagingBatch @Phase='EXTRACT'`; gate này chỉ chạy khi đủ cả 8 nguồn.

## 15. Lỗi thường gặp

### Foreign key LoadBatchKey

Nguyên nhân: chạy package con trực tiếp với `pLoadBatchKey=0`.  
Khắc phục: chạy từ `00_Master` và kiểm tra Parameter Binding.

### Không thấy bảng đích

Kiểm tra Destination đang dùng `(project) CM_DanangSTG`, không phải DW. Chọn `[extract].[ParkingLocationRaw]`.

### Dữ liệu tiếng Việt bị lỗi

Kiểm tra Code page 65001, file không chọn Unicode UTF-16 và các output column là DT_WSTR.

### Vi phạm SourceRowNumber

Kiểm tra biến local trong Script Component bắt đầu bằng 1 rồi tăng trước khi gán; expected 2–21.

### Destination metadata đỏ

Mở OLE DB Destination → Mappings → refresh/reselect table sau khi đã tạo database STG.

### `Cannot insert the value NULL into column 'ExtractedAt'`

Nguyên nhân: OLE DB Destination đang bật `Keep nulls`, nên SQL Server không áp dụng `DEFAULT SYSUTCDATETIME()` cho cột `ExtractedAt` không được map.

Khắc phục:

1. Mở `DST - extract.ParkingLocationRaw`.
2. Trang Connection Manager, bỏ check `Keep nulls`.
3. Trang Mappings, đảm bảo `ExtractedAt` là `<ignore>`/không có đường nối.
4. Không tăng `MaximumErrorCount`; phải sửa nguyên nhân dữ liệu đích.
5. Save All và chạy lại từ `00_Master.dtsx`.

### Chạy lại cùng batch bị unique constraint

Không debug package con nhiều lần với cùng `LoadFileKey`. Dừng và chạy lại từ Master để tạo batch/file audit mới; cơ chế retry cùng batch sẽ được bổ sung sau khi green path đầu tiên đạt.

## 16. Checkpoint A đã hoàn thành — Parking Locations

Kết quả đã được xác nhận trên SSMS cho `LoadBatchKey=5`:

- [x] Flat File Connection đọc đúng 12 cột UTF-8.
- [x] Data Flow có Source → Row Number → Derived Keys → STG Destination.
- [x] Error path nối vào `etl.RejectedRow`.
- [x] Complete task cập nhật audit.
- [x] Master truyền đúng `LoadBatchKey`.
- [x] SSIS chạy xanh.
- [x] SSMS xác nhận 20/20/0 và `SourceRowNumber=2–21`.

Đây mới là checkpoint của CSV đầu tiên. Package `10_Extract_MasterCSV.dtsx` chỉ hoàn thành khi cùng một batch mới nạp đủ:

| SourceID | File | Bảng đích | Expected |
|---|---|---|---:|
| `02` | `02_parking_locations.csv` | `extract.ParkingLocationRaw` | 20 |
| `03` | `03_parking_restrictions.csv` | `extract.ParkingRestrictionRaw` | 18 |
| `05` | `05_road_survey.csv` | `extract.RoadSurveyRaw` | 30 |

## 17. Chiến lược sao chép để làm nhanh

Không tạo lại mọi component từ đầu. Luồng Parking Locations đã chạy đúng được dùng làm mẫu.

### 17.1. Thành phần được tái sử dụng

- Dùng lại package parameter `$Package::pLoadBatchKey`.
- Dùng lại variable `User::LoadFileKey`. Mỗi task Register mới sẽ ghi đè khóa file mới vào variable này.
- Dùng lại `(project) CM_DanangDW` và `(project) CM_DanangSTG`.
- Copy task Register rồi chỉ sửa tên, `SourceID`, tên file và expected count.
- Copy toàn bộ Data Flow Task rồi thay Flat File Connection, bảng đích và mapping.
- Giữ nguyên Script Component tạo `SourceRowNumber`.
- Giữ nguyên Derived Column tạo `LoadBatchKey` và `LoadFileKey`.
- Giữ nguyên destination `etl.RejectedRow`; chỉ sửa nội dung `Reason`.
- Copy task Complete rồi thay bảng đếm, expected count và thông báo lỗi.

### 17.2. Thành phần không được dùng nhầm

- Mỗi file phải có Flat File Connection Manager riêng.
- Không đổi `FF_ParkingLocations` sang file khác vì sẽ làm hỏng luồng đã hoàn thành.
- Mỗi main destination phải trỏ đúng bảng `extract.*Raw` tương ứng.
- Sau khi đổi source metadata, phải kiểm tra lại toàn bộ Mappings; không tin vào auto-map.
- `Keep nulls` phải bỏ check tại cả ba main destination để `ExtractedAt` dùng SQL DEFAULT.

### 17.3. Control Flow cuối cùng của package

```text
SQL - Register Parking File
  → DFT - Extract Parking Locations
  → SQL - Complete Parking File
  → SQL - Register Restriction File
  → DFT - Extract Parking Restrictions
  → SQL - Complete Restriction File
  → SQL - Register Road Survey File
  → DFT - Extract Road Survey
  → SQL - Complete Road Survey File
```

Tất cả đường nối trên là precedence constraint màu xanh `Success`. Làm lần lượt Restrictions trước, kiểm thử, rồi mới thêm Road Survey.

### 17.4. Khi Data Flow bản sao vẫn giữ cột của file cũ

Đây là lỗi metadata thường gặp sau khi copy. Chỉ thao tác bên trong **Data Flow bản sao**, không sửa Data Flow Parking Locations gốc:

1. Chọn đường xanh và đường đỏ đi ra từ Flat File Source cũ, nhấn Delete.
2. Xóa riêng Flat File Source cũ khỏi Data Flow bản sao.
3. Kéo một Flat File Source mới vào.
4. Chọn Connection Manager của file mới.
5. Đặt Error/Truncation thành `Redirect row`.
6. Nối mũi tên xanh tới Script Component `Add Source Row Number` đang được tái sử dụng.
7. Nối mũi tên đỏ tới Derived Column `Mark ... File Error`.
8. Mở lần lượt Script → Derived Keys → main destination → reject destination để refresh và kiểm tra mapping.

Cách này vẫn nhanh vì giữ được Script Component, hai Derived Column và hai Destination; chỉ source được tạo lại để metadata sạch.

## 18. Checkpoint B — Extract `03_parking_restrictions.csv`

### 18.1. Copy task Register

1. Nếu đang Debug, nhấn `Shift+F5`.
2. Mở `10_Extract_MasterCSV.dtsx → Control Flow`.
3. Chọn `SQL - Register Parking File`.
4. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
5. Kéo bản sao xuống dưới `SQL - Complete Parking File`.
6. Nhấn `F2`, đổi tên bản sao thành:

```text
SQL - Register Restriction File
```

7. Nối mũi tên xanh:

```text
SQL - Complete Parking File
  → SQL - Register Restriction File
```

8. Nhấp đúp task mới, giữ nguyên:
   - ConnectionType: `OLE DB`.
   - Connection: `(project) CM_DanangDW`.
   - SQLSourceType: `Direct input`.
   - ResultSet: `Single row`.
   - BypassPrepare: `True`.
9. Thay toàn bộ SQL Statement bằng:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

INSERT etl.LoadFile
(
    LoadBatchKey,
    SourceID,
    FileName,
    FileFormat,
    ExpectedRowCount,
    LoadStatus
)
VALUES
(
    @LoadBatchKey,
    '03',
    N'03_parking_restrictions.csv',
    'CSV',
    18,
    'STARTED'
);

SELECT CONVERT(bigint, SCOPE_IDENTITY()) AS LoadFileKey;
```

10. Trang **Parameter Mapping** phải còn đúng một dòng:

| Variable Name | Direction | Data Type | Parameter Name | Size |
|---|---|---|---:|---:|
| `$Package::pLoadBatchKey` | Input | `LONG` | `0` | `-1` |

11. Trang **Result Set** phải còn:

| Result Name | Variable Name |
|---:|---|
| `0` | `User::LoadFileKey` |

12. Bấm OK và Save All.

### 18.2. Tạo `FF_ParkingRestrictions`

Tạo Connection Manager trong chính package `10_Extract_MasterCSV.dtsx`:

1. Bấm phải vùng **Connection Managers** phía dưới.
2. Chọn **New Flat File Connection...**.
3. Nếu không thấy, chọn **New Connection... → FLATFILE → Add**.
4. Trang General:
   - Name: `FF_ParkingRestrictions`.
   - File: `C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\03_parking_restrictions.csv`.
   - Format: `Delimited`.
   - Text qualifier: `"`.
   - Header row delimiter: `{CR}{LF}`.
   - Header rows to skip: `0`.
   - `Column names in the first data row`: checked.
   - Unicode: không check.
   - Code page: `65001 (UTF-8)`.
5. Trang Columns:
   - Row delimiter: `{CR}{LF}`.
   - Column delimiter: comma `{,}`.
   - Preview phải có đúng 10 cột.
6. Trang Advanced, cấu hình tất cả dưới dạng Unicode string:

| Source column | Data type | Width |
|---|---|---:|
| `restriction_id` | DT_WSTR | 50 |
| `road_id` | DT_WSTR | 50 |
| `road_name` | DT_WSTR | 200 |
| `restriction_type` | DT_WSTR | 100 |
| `start_time` | DT_WSTR | 30 |
| `end_time` | DT_WSTR | 30 |
| `side` | DT_WSTR | 30 |
| `vehicle_scope` | DT_WSTR | 50 |
| `data_status` | DT_WSTR | 100 |
| `source_url` | DT_WSTR | 1000 |

7. Trang Preview:
   - Dòng dữ liệu đầu phải có `restriction_id=R001`.
   - `road_name=Trần Phú` phải đúng dấu.
   - Không được thấy header như một dòng dữ liệu.
8. Bấm OK.
9. Chọn `FF_ParkingRestrictions` ở vùng Connection Managers, nhấn `F4`.
10. Thuộc tính **Expressions → ConnectionString**:

```text
@[$Project::pRawRoot] + "\\03_parking_restrictions.csv"
```

11. Evaluate Expression phải trả về đúng full path trên Windows.

Lưu ý: `R003` có `road_id` trống và một số `source_url` trống. Đây là dữ liệu RAW hợp lệ, không đặt Flat File Source thành lỗi chỉ vì hai trường này rỗng.

### 18.3. Copy Data Flow Task Parking Locations

1. Trở lại Control Flow.
2. Chọn `DFT - Extract Parking Locations`.
3. Nhấn `Ctrl+C`, sau đó `Ctrl+V`.
4. Đổi tên bản sao:

```text
DFT - Extract Parking Restrictions
```

5. Kéo task xuống dưới `SQL - Register Restriction File`.
6. Nối mũi tên xanh:

```text
SQL - Register Restriction File
  → DFT - Extract Parking Restrictions
```

7. Nhấp đúp Data Flow bản sao.

### 18.4. Đổi Flat File Source trong Data Flow bản sao

1. Đổi tên source thành `SRC - Parking Restrictions CSV`.
2. Nhấp đúp source.
3. Flat file connection manager: đổi từ `FF_ParkingLocations` sang `FF_ParkingRestrictions`.
4. Nếu SSIS hỏi có thay metadata/columns hay không, chọn **Yes**.
5. Trang Columns phải thấy đúng 10 cột mới; chọn đủ 10.
6. Trang Error Output:
   - Error: `Redirect row`.
   - Truncation: `Redirect row`.
7. Bấm OK.

Sau khi đổi source, component phía sau có thể tạm thời hiện dấu `X` đỏ do lineage ID đã thay đổi. Sửa theo thứ tự từ trên xuống: Source → Script → Derived Column → Destination.

Nếu vẫn thấy các cột `parking_id`, `parking_name` của file cũ, thực hiện quy trình làm sạch metadata tại mục 17.4.

### 18.5. Kiểm tra Script và audit Derived Column

Mở `SCR - Add Source Row Number` trong Data Flow bản sao:

1. Inputs and Outputs phải còn output column `SourceRowNumber`, kiểu `DT_I8`.
2. Script vẫn dùng:

```csharp
private long sourceRowNumber = 1;

public override void Input0_ProcessInputRow(Input0Buffer Row)
{
    sourceRowNumber++;
    Row.SourceRowNumber = sourceRowNumber;
}
```

3. Nếu Script Component đỏ, mở Edit Script → Build → Build Solution → đóng VSTA → OK.

Mở `DRV - Add Batch And File Keys` và kiểm tra hai expression không thay đổi:

| Column | Expression |
|---|---|
| `LoadBatchKey` | `@[$Package::pLoadBatchKey]` |
| `LoadFileKey` | `@[User::LoadFileKey]` |

Cả hai phải là `DT_I8` và chọn `<add as new column>`.

### 18.6. Đổi main destination sang `ParkingRestrictionRaw`

1. Đổi tên destination:

```text
DST - extract.ParkingRestrictionRaw
```

2. Nhấp đúp destination.
3. Connection Manager: `(project) CM_DanangSTG`.
4. Data access mode: `Table or view - fast load`.
5. Table: `[extract].[ParkingRestrictionRaw]`.
6. Fast-load options:
   - Keep identity: không check.
   - Keep nulls: **không check**.
   - Check constraints: check.
7. Trang Mappings: xóa các đường mapping cũ không còn đúng và map lại đủ 13 cột:

| Input | Destination |
|---|---|
| `LoadBatchKey` | `LoadBatchKey` |
| `LoadFileKey` | `LoadFileKey` |
| `SourceRowNumber` | `SourceRowNumber` |
| `restriction_id` | `RestrictionID` |
| `road_id` | `RoadID` |
| `road_name` | `RoadName` |
| `restriction_type` | `RestrictionType` |
| `start_time` | `StartTimeRaw` |
| `end_time` | `EndTimeRaw` |
| `side` | `SideCode` |
| `vehicle_scope` | `VehicleScope` |
| `data_status` | `DataStatus` |
| `source_url` | `SourceURL` |

Không map `StageRowKey`, `RecordHashSHA256`, `ExtractedAt`. Kiểm tra `ExtractedAt` là `<ignore>` và `Keep nulls` đã bỏ check.

### 18.7. Sửa error path của Restrictions

1. Mở Derived Column trên nhánh đỏ, đổi tên:

```text
DRV - Mark Restriction File Error
```

2. Giữ nguyên:

| Column | Expression |
|---|---|
| `RejectLoadFileKey` | `@[User::LoadFileKey]` |
| `RuleCode` | `(DT_STR,50,1252)"FLAT_FILE_ERROR"` |
| `Severity` | `(DT_STR,10,1252)"ERROR"` |

3. Thay expression của `Reason` bằng:

```text
(DT_WSTR,1000)"Flat File error/truncation: 03_parking_restrictions.csv"
```

4. Destination nhánh đỏ vẫn là `(project) CM_DanangDW → [etl].[RejectedRow]`.
5. `Keep nulls` của reject destination cũng phải bỏ check để `RejectedAt` dùng DEFAULT.
6. Kiểm tra mapping vẫn đúng `RejectLoadFileKey`, `RuleCode`, `Severity`, `Reason`.

### 18.8. Copy và sửa task Complete Restrictions

1. Trở lại Control Flow.
2. Copy `SQL - Complete Parking File` bằng `Ctrl+C`, `Ctrl+V`.
3. Đổi tên:

```text
SQL - Complete Restriction File
```

4. Nối:

```text
DFT - Extract Parking Restrictions
  → SQL - Complete Restriction File
```

5. Giữ Connection `(project) CM_DanangDW`, ResultSet `None`, BypassPrepare `True`.
6. Thay SQL Statement:

```sql
DECLARE @LoadFileKey bigint = CONVERT(bigint, ?);
DECLARE @Accepted bigint;
DECLARE @Rejected bigint;
DECLARE @Actual bigint;

SELECT @Accepted = COUNT_BIG(*)
FROM DanangSmartParkingSTG.extract.ParkingRestrictionRaw
WHERE LoadFileKey = @LoadFileKey;

SELECT @Rejected = COUNT_BIG(*)
FROM etl.RejectedRow
WHERE LoadFileKey = @LoadFileKey;

SET @Actual = @Accepted + @Rejected;

IF @Actual <> 18 OR @Rejected > 0
BEGIN
    UPDATE etl.LoadFile
    SET ActualRowCount = @Actual,
        AcceptedRowCount = @Accepted,
        RejectedRowCount = @Rejected,
        CompletedAt = SYSUTCDATETIME(),
        LoadStatus = 'FAILED'
    WHERE LoadFileKey = @LoadFileKey;

    THROW 51020, 'Parking Restrictions extract failed count or reject validation.', 1;
END;

UPDATE etl.LoadFile
SET ActualRowCount = @Actual,
    AcceptedRowCount = @Accepted,
    RejectedRowCount = @Rejected,
    CompletedAt = SYSUTCDATETIME(),
    LoadStatus = 'COMPLETED'
WHERE LoadFileKey = @LoadFileKey;

IF @@ROWCOUNT <> 1
    THROW 51021, 'Parking Restrictions LoadFile audit row was not found.', 1;
```

7. Parameter Mapping giữ đúng:

| Variable | Direction | Data Type | Parameter Name | Size |
|---|---|---|---:|---:|
| `User::LoadFileKey` | Input | `LONG` | `0` | `-1` |

### 18.9. Debug checkpoint Restrictions

1. Save All.
2. Chạy từ `00_Master.dtsx`, không chạy riêng package con/Data Flow.
3. Package sẽ nạp lại Parking Locations vào batch mới, sau đó nạp Restrictions.
4. Kết quả đúng trên Data Flow Restrictions:
   - Main path: 18 rows.
   - Reject destination: 0 rows.
   - Tất cả component màu xanh.
5. Chạy SSMS:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'03_parking_restrictions.csv'
    ORDER BY LoadFileKey DESC
);

SELECT
    SourceID, FileName, ExpectedRowCount, ActualRowCount,
    AcceptedRowCount, RejectedRowCount, LoadStatus
FROM DanangSmartParkingDW.etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY LoadFileKey;

SELECT
    COUNT_BIG(*) AS StageRows,
    MIN(SourceRowNumber) AS MinSourceRowNumber,
    MAX(SourceRowNumber) AS MaxSourceRowNumber,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(RoadID)), N'') IS NULL THEN 1 ELSE 0 END)
        AS BlankRoadIDRows
FROM DanangSmartParkingSTG.extract.ParkingRestrictionRaw
WHERE LoadBatchKey = @LoadBatchKey;
```

Expected:

| Kiểm tra | Kết quả |
|---|---|
| LoadFile của `02` | `20/20/0`, COMPLETED |
| LoadFile của `03` | `18/18/0`, COMPLETED |
| Restriction StageRows | 18 |
| SourceRowNumber | 2–19 |
| BlankRoadIDRows | 1 (`R003`) |

Chỉ tiếp tục Road Survey sau khi checkpoint trên đạt.

## 19. Checkpoint C — Extract `05_road_survey.csv`

### 19.1. Copy task Register Road Survey

1. Trong Control Flow, copy `SQL - Register Restriction File`.
2. Đổi tên bản sao:

```text
SQL - Register Road Survey File
```

3. Nối:

```text
SQL - Complete Restriction File
  → SQL - Register Road Survey File
```

4. Giữ các thiết lập Connection, Parameter Mapping và Result Set.
5. Thay SQL Statement:

```sql
DECLARE @LoadBatchKey bigint = CONVERT(bigint, ?);

INSERT etl.LoadFile
(
    LoadBatchKey,
    SourceID,
    FileName,
    FileFormat,
    ExpectedRowCount,
    LoadStatus
)
VALUES
(
    @LoadBatchKey,
    '05',
    N'05_road_survey.csv',
    'CSV',
    30,
    'STARTED'
);

SELECT CONVERT(bigint, SCOPE_IDENTITY()) AS LoadFileKey;
```

6. Kiểm tra lại:
   - Parameter `0`: `$Package::pLoadBatchKey`, Input, LONG.
   - Result `0`: `User::LoadFileKey`.

### 19.2. Tạo `FF_RoadSurvey`

1. Bấm phải vùng Connection Managers → **New Flat File Connection...**.
2. Name: `FF_RoadSurvey`.
3. File:

```text
C:\Users\Administrator\Desktop\DE_PROJECT\danang_smart_parking_raw_7d\05_road_survey.csv
```

4. General:
   - Format: Delimited.
   - Text qualifier: `"`.
   - Header delimiter: `{CR}{LF}`.
   - Column names in first data row: checked.
   - Unicode: không check.
   - Code page: 65001.
5. Columns: comma delimiter, `{CR}{LF}`, preview đúng 11 cột.
6. Advanced:

| Source column | Data type | Width |
|---|---|---:|
| `segment_id` | DT_WSTR | 50 |
| `road_id` | DT_WSTR | 50 |
| `road_name` | DT_WSTR | 200 |
| `analysis_zone` | DT_WSTR | 150 |
| `road_width_m` | DT_WSTR | 30 |
| `lane_count` | DT_WSTR | 30 |
| `sidewalk_width_m` | DT_WSTR | 30 |
| `shoulder_width_m` | DT_WSTR | 30 |
| `observed_parking_sides` | DT_WSTR | 30 |
| `data_status` | DT_WSTR | 100 |
| `quality_confidence` | DT_WSTR | 30 |

7. Preview phải bắt đầu bằng `SEG_001`, `RD001`, `Trần Phú`.
8. Sau khi OK, chọn connection, nhấn F4 → Expressions → ConnectionString:

```text
@[$Project::pRawRoot] + "\\05_road_survey.csv"
```

9. Evaluate Expression phải trả đúng full path.

Ba dòng `SEG_009`, `SEG_018`, `SEG_027` có `road_width_m` trống. Extract vẫn nhận; việc bổ sung width và gắn `WidthImputedFlag` chỉ thực hiện ở Transform.

### 19.3. Copy Data Flow Restrictions

Copy luồng Restrictions vì nó đã sử dụng cùng mô hình 3 audit columns và error path mới nhất:

1. Chọn `DFT - Extract Parking Restrictions` → `Ctrl+C` → `Ctrl+V`.
2. Đổi tên:

```text
DFT - Extract Road Survey
```

3. Nối:

```text
SQL - Register Road Survey File
  → DFT - Extract Road Survey
```

4. Mở Data Flow bản sao.
5. Đổi source thành `SRC - Road Survey CSV`.
6. Source Connection Manager: `FF_RoadSurvey`.
7. Chấp nhận refresh metadata và xác nhận đủ 11 columns.
8. Error và Truncation: `Redirect row`.
9. Kiểm tra Script `SourceRowNumber` vẫn `DT_I8` và code không đổi.
10. Kiểm tra Derived Columns:
    - `LoadBatchKey = @[$Package::pLoadBatchKey]`.
    - `LoadFileKey = @[User::LoadFileKey]`.

Nếu source hoặc downstream vẫn hiện các cột `restriction_id` của file trước, thực hiện mục 17.4 rồi map lại từ đầu.

### 19.4. Đổi main destination sang `RoadSurveyRaw`

1. Đổi tên:

```text
DST - extract.RoadSurveyRaw
```

2. Connection: `(project) CM_DanangSTG`.
3. Mode: `Table or view - fast load`.
4. Table: `[extract].[RoadSurveyRaw]`.
5. `Keep identity`: không check; `Keep nulls`: **không check**; `Check constraints`: check.
6. Map đủ 14 cột:

| Input | Destination |
|---|---|
| `LoadBatchKey` | `LoadBatchKey` |
| `LoadFileKey` | `LoadFileKey` |
| `SourceRowNumber` | `SourceRowNumber` |
| `segment_id` | `SegmentID` |
| `road_id` | `RoadID` |
| `road_name` | `RoadName` |
| `analysis_zone` | `AnalysisZone` |
| `road_width_m` | `RoadWidthMRaw` |
| `lane_count` | `LaneCountRaw` |
| `sidewalk_width_m` | `SidewalkWidthMRaw` |
| `shoulder_width_m` | `ShoulderWidthMRaw` |
| `observed_parking_sides` | `ObservedParkingSides` |
| `data_status` | `DataStatus` |
| `quality_confidence` | `QualityConfidenceRaw` |

Không map `StageRowKey`, `RecordHashSHA256`, `ExtractedAt`.

### 19.5. Sửa error path Road Survey

1. Đổi Derived Column nhánh đỏ thành `DRV - Mark Road Survey File Error`.
2. Thay `Reason`:

```text
(DT_WSTR,1000)"Flat File error/truncation: 05_road_survey.csv"
```

3. Giữ `RejectLoadFileKey`, `RuleCode`, `Severity` như luồng trước.
4. Giữ destination `(project) CM_DanangDW → [etl].[RejectedRow]` và bốn mapping bắt buộc.
5. Bỏ check `Keep nulls` tại reject destination để `RejectedAt` dùng SQL DEFAULT.

### 19.6. Copy và sửa task Complete Road Survey

1. Copy `SQL - Complete Restriction File`.
2. Đổi tên:

```text
SQL - Complete Road Survey File
```

3. Nối:

```text
DFT - Extract Road Survey
  → SQL - Complete Road Survey File
```

4. Thay SQL Statement:

```sql
DECLARE @LoadFileKey bigint = CONVERT(bigint, ?);
DECLARE @Accepted bigint;
DECLARE @Rejected bigint;
DECLARE @Actual bigint;

SELECT @Accepted = COUNT_BIG(*)
FROM DanangSmartParkingSTG.extract.RoadSurveyRaw
WHERE LoadFileKey = @LoadFileKey;

SELECT @Rejected = COUNT_BIG(*)
FROM etl.RejectedRow
WHERE LoadFileKey = @LoadFileKey;

SET @Actual = @Accepted + @Rejected;

IF @Actual <> 30 OR @Rejected > 0
BEGIN
    UPDATE etl.LoadFile
    SET ActualRowCount = @Actual,
        AcceptedRowCount = @Accepted,
        RejectedRowCount = @Rejected,
        CompletedAt = SYSUTCDATETIME(),
        LoadStatus = 'FAILED'
    WHERE LoadFileKey = @LoadFileKey;

    THROW 51030, 'Road Survey extract failed count or reject validation.', 1;
END;

UPDATE etl.LoadFile
SET ActualRowCount = @Actual,
    AcceptedRowCount = @Accepted,
    RejectedRowCount = @Rejected,
    CompletedAt = SYSUTCDATETIME(),
    LoadStatus = 'COMPLETED'
WHERE LoadFileKey = @LoadFileKey;

IF @@ROWCOUNT <> 1
    THROW 51031, 'Road Survey LoadFile audit row was not found.', 1;
```

5. Parameter Mapping giữ `User::LoadFileKey`, Input, LONG, ordinal `0`, size `-1`.

## 20. Kiểm tra Control Flow trước khi hoàn thành package

### 20.1. Kiểm tra package con

Trong `10_Extract_MasterCSV.dtsx`, kiểm tra:

- Có 9 task theo đúng thứ tự tại mục 17.3.
- Có 8 đường nối xanh; không có task rời.
- Ba Register task dùng `CM_DanangDW`, ResultSet Single row.
- Ba Data Flow main destination dùng `CM_DanangSTG`.
- Ba reject destination dùng `CM_DanangDW`.
- Cả main destination và reject destination đều bỏ check `Keep nulls` cho các cột timestamp có DEFAULT.
- Ba Complete task dùng `CM_DanangDW`, ResultSet None.
- Không component nào có dấu `X` đỏ.
- Package chỉ có một parameter `pLoadBatchKey` và một variable dùng lại `User::LoadFileKey`.

### 20.2. Kiểm tra Master

Trong `00_Master.dtsx`:

```text
SQL - Start Batch
  → PKG - Extract Master CSV
```

- Execute Package Task dùng Project Reference tới `10_Extract_MasterCSV.dtsx`.
- Parameter Binding: child `pLoadBatchKey = User::LoadBatchKey` của Master.
- `SQL - Complete Batch` vẫn Disabled vì các package 11–90 chưa hoàn thành.

## 21. Debug hoàn chỉnh package `10_Extract_MasterCSV`

1. Nhấn `Ctrl+Shift+S`.
2. Mở `00_Master.dtsx`.
3. Nhấn F5/Start.
4. Chờ toàn bộ Execute Package Task kết thúc.
5. Kết quả đúng trong package con:

| Data Flow | Main rows | Reject rows |
|---|---:|---:|
| Parking Locations | 20 | 0 |
| Parking Restrictions | 18 | 0 |
| Road Survey | 30 | 0 |

6. Tất cả 9 task màu xanh.
7. Master Start Batch và Execute Package Task màu xanh.
8. Complete Batch không chạy vì Disabled.

Trong log Flat File Source có thể hiển thị 21, 19 và 31 dòng vì tính cả header. Số hiển thị trên main pipeline mới là số dữ liệu cần đối soát: 20, 18 và 30.

Nếu một luồng thất bại:

- Không tăng `MaximumErrorCount`.
- Mở Progress/Execution Results và sửa lỗi đầu tiên.
- Không chạy riêng Data Flow vì `LoadFileKey` có thể sai.
- Sau khi sửa, chạy lại từ Master để nhận batch mới.
- Dữ liệu/batch chạy thử cũ giữ nguyên để audit trong giai đoạn này; chưa chạy cleanup thủ công.

## 22. Đối soát cuối package trên SSMS

Chạy sau khi cả ba Data Flow xanh:

```sql
DECLARE @LoadBatchKey bigint =
(
    SELECT TOP (1) LoadBatchKey
    FROM DanangSmartParkingDW.etl.LoadFile
    WHERE FileName = N'05_road_survey.csv'
    ORDER BY LoadFileKey DESC
);

-- 1. Batch vẫn STARTED vì toàn ETL chưa hoàn thành.
SELECT
    LoadBatchKey, BatchID, SourceFolder,
    DatasetPeriodStart, DatasetPeriodEnd,
    LoadStatus, StartedAt, CompletedAt
FROM DanangSmartParkingDW.etl.LoadBatch
WHERE LoadBatchKey = @LoadBatchKey;

-- 2. Phải có đúng 3 file COMPLETED: 20, 18, 30.
SELECT
    LoadFileKey, SourceID, FileName,
    ExpectedRowCount, ActualRowCount,
    AcceptedRowCount, RejectedRowCount, LoadStatus
FROM DanangSmartParkingDW.etl.LoadFile
WHERE LoadBatchKey = @LoadBatchKey
ORDER BY SourceID;

-- 3. Row count staging của đúng batch mới nhất.
SELECT 'ParkingLocationRaw' AS ObjectName,
       COUNT_BIG(*) AS ActualRows, 20 AS ExpectedRows,
       MIN(SourceRowNumber) AS MinRow, MAX(SourceRowNumber) AS MaxRow
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT 'ParkingRestrictionRaw', COUNT_BIG(*), 18,
       MIN(SourceRowNumber), MAX(SourceRowNumber)
FROM DanangSmartParkingSTG.extract.ParkingRestrictionRaw
WHERE LoadBatchKey = @LoadBatchKey
UNION ALL
SELECT 'RoadSurveyRaw', COUNT_BIG(*), 30,
       MIN(SourceRowNumber), MAX(SourceRowNumber)
FROM DanangSmartParkingSTG.extract.RoadSurveyRaw
WHERE LoadBatchKey = @LoadBatchKey;

-- 4. Không có reject trong ba file của batch.
SELECT COUNT_BIG(*) AS RejectedRows
FROM DanangSmartParkingDW.etl.RejectedRow r
JOIN DanangSmartParkingDW.etl.LoadFile f
  ON f.LoadFileKey = r.LoadFileKey
WHERE f.LoadBatchKey = @LoadBatchKey;

-- 5. Hai null/blank chủ đích vẫn phải được giữ ở RAW.
SELECT
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(RoadID)), N'') IS NULL
             THEN 1 ELSE 0 END) AS RestrictionBlankRoadIDRows
FROM DanangSmartParkingSTG.extract.ParkingRestrictionRaw
WHERE LoadBatchKey = @LoadBatchKey;

SELECT
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(RoadWidthMRaw)), N'') IS NULL
             THEN 1 ELSE 0 END) AS SurveyBlankRoadWidthRows
FROM DanangSmartParkingSTG.extract.RoadSurveyRaw
WHERE LoadBatchKey = @LoadBatchKey;
```

Expected:

| Kiểm tra | Kết quả |
|---|---|
| Batch status | `STARTED` |
| Số LoadFile | 3 |
| Status của cả 3 file | `COMPLETED` |
| Actual/Accepted/Rejected | `20/20/0`, `18/18/0`, `30/30/0` |
| Parking Location row range | 2–21 |
| Parking Restriction row range | 2–19 |
| Road Survey row range | 2–31 |
| RejectedRows | 0 |
| RestrictionBlankRoadIDRows | 1 |
| SurveyBlankRoadWidthRows | 3 |

Không dùng `COUNT(*)` toàn bảng không lọc `LoadBatchKey`, vì các lần debug trước vẫn được lưu để audit.

## 23. Tiêu chí hoàn thành package 10

- [x] Có đủ ba Flat File Connection Managers với expression từ `pRawRoot`.
- [x] Có đủ 9 task theo đúng chuỗi tuần tự.
- [x] Cả ba source đọc đúng UTF-8 và đúng số cột.
- [x] Cả ba Data Flow có main path và error path.
- [x] Cả ba main destination và reject destination bỏ chọn `Keep nulls`.
- [x] Cả ba LoadFile có status `COMPLETED` trong cùng một LoadBatchKey.
- [x] SSMS trả đúng `20`, `18`, `30` và không có reject.
- [x] Giữ được 1 RoadID trống và 3 RoadWidth trống trong RAW.
- [x] Batch vẫn `STARTED`; Complete Batch vẫn Disabled.

Khi toàn bộ checklist này đạt, package `10_Extract_MasterCSV.dtsx` mới được coi là hoàn thành. Bước tiếp theo là [`11_EXTRACT_GEOJSON.md`](11_EXTRACT_GEOJSON.md), không phải Transform.

## 24. Tài liệu Microsoft dùng để đối chiếu

- [Flat File Connection Manager](https://learn.microsoft.com/en-us/sql/integration-services/connection-manager/flat-file-connection-manager?view=sql-server-ver17): encoding/code page, header, delimiter và cấu hình cột.
- [Creating a Synchronous Transformation with the Script Component](https://learn.microsoft.com/en-us/sql/integration-services/extending-packages-scripting/data-flow-script-component-types/creating-a-synchronous-transformation-with-the-script-component?view=sql-server-ver17): nối input, tạo transformation và mở VSTA bằng Edit Script.
- [OLE DB Destination](https://learn.microsoft.com/en-us/sql/integration-services/data-flow/ole-db-destination?view=sql-server-ver17): fast load và trang Mappings.
- [Execute Package Task](https://learn.microsoft.com/en-us/sql/integration-services/control-flow/execute-package-task?view=sql-server-ver17): Project Reference và Parameter Bindings cho package con.
