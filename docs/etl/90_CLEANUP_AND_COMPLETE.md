# 90 — Cleanup Staging và Complete Batch

## Điều kiện đầu vào

Chỉ chạy khi `80_Reconcile.dtsx` thành công.

## Cleanup trên SSIS

Execute SQL Task, connection `CM_DanangSTG`:

```sql
EXEC dbo.usp_CleanupStagingBatch
    @LoadBatchKey = CONVERT(bigint, ?);
```

Map `User::LoadBatchKey`, Input, ordinal 0. Không dùng TRUNCATE; procedure chỉ DELETE batch hiện tại.

## Complete Batch

Sau Cleanup thành công mới enable/nối `SQL - Complete Batch` trong Master. Task cập nhật:

- LoadStatus=`COMPLETED`.
- CompletedAt.
- RowsRead/Accepted/Rejected từ `etl.LoadFile`.

## Kiểm tra SSMS

```sql
SELECT TOP (1) *
FROM DanangSmartParkingDW.etl.LoadBatch
ORDER BY LoadBatchKey DESC;

-- Hai kết quả phải bằng 0 cho batch đã cleanup.
SELECT COUNT_BIG(*)
FROM DanangSmartParkingSTG.extract.ParkingLocationRaw
WHERE LoadBatchKey = <batch_key>;

SELECT COUNT_BIG(*)
FROM DanangSmartParkingSTG.transform.ParkingFacilityClean
WHERE LoadBatchKey = <batch_key>;
```

Không cleanup batch FAILED; dữ liệu phải được giữ để phân tích lỗi.

