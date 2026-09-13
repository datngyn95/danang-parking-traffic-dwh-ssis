# 80 — Reconciliation

## Mục tiêu

Xác nhận ETL không mất, nhân đôi hoặc làm sai KPI trước khi cleanup/publish.

Chỉ bắt đầu khi `50_Final_DWH_Validation.dtsx` đã PASS trên cùng batch. Package 50
kiểm tra cấu trúc, grain và foreign key; package 80 kiểm tra các tổng/KPI nghiệp vụ.

## SSIS

Package `80_Reconcile.dtsx` gồm Execute SQL Tasks trên `CM_DanangDW`:

1. Fact row counts.
2. Traffic KPI totals.
3. Parking KPI totals.
4. Orphan foreign keys.
5. Capacity and Weather totals.

Mỗi task phải THROW khi lệch baseline. Dùng Script 14 trong `Agent.md` làm nguồn kiểm tra.

## Nghiệm thu

- Fact counts đúng expected.
- Traffic vehicle volume 6.596.879.
- Parking illegal events 1.571 trên 4.283.
- Orphan bắt buộc bằng 0.
- Capacity 2.267, reference 397.
- Weather 168 rows, 47,5 mm, 11 rainy hours.

Nếu fail: batch FAILED, giữ staging, không chạy Cleanup.
