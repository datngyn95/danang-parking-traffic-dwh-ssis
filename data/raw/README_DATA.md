# Da Nang Smart Parking & Traffic Analytics — RAW dataset (7 days)

**Period:** 2026-08-05 → 2026-08-11 (Asia/Ho_Chi_Minh)

## Grounding
- Current Da Nang post-2025 merger population reference: **3,065,628** people.
- Current city area reference: **11,859.59 km²**.
- Former Da Nang population reference used to explain the urban-core scope: **1,318,481** people.
- The dataset models a **sample of the former Da Nang urban core**, not the entire new 11,859.59 km² city.

## 8 RAW sources
1. `01_roads.geojson` — real road names; geometry/width/lane attributes are plausible approximations.
2. `02_parking_locations.csv` — includes real reference capacities for 166 Hải Phòng and 255 Phan Châu Trinh; other capacities/coordinates are marked synthetic/approximate.
3. `03_parking_restrictions.csv` — includes 3 open-data reference records; remaining restrictions are synthetic for ETL practice.
4. `04_poi.geojson` — 24 real POI names with approximate coordinates plus 26 synthetic POIs.
5. `05_road_survey.csv` — synthetic field-survey dataset with a few null widths for Silver cleaning.
6. `06_traffic_events.jsonl` — 15-minute synthetic sensor observations calibrated by population, road type, peak hours, parking pressure, and weather.
7. `07_parking_events.jsonl` — synthetic roadside parking events linked to roads and restrictions.
8. `08_weather_events.jsonl` — hourly synthetic weather calibrated to actual daily temperature ranges for the 7 days.

## Important real references
- Da Nang overview/population: https://danang.gov.vn/w/tong-quan-ve-thanh-pho-da-nang
- Merger population context: https://www.danang.gov.vn/vi/w/ban-chap-hanh-dang-bo-thanh-pho-a-nang-thong-nhat-e-an-hop-nhat-voi-tinh-quang-nam-va-thanh-pho-a-nang
- Da Nang parking portal: https://doxe.danang.gov.vn/
- Open parking restrictions: https://opendata.danang.gov.vn/dulieuchitiet/1480973
- 166 Hải Phòng / 255 Phan Châu Trinh capacities: https://baodanang.vn/day-nhanh-tien-do-dua-vao-khai-thac-cac-bai-do-xe-thong-minh-3183877.html
- City parking supply context: https://baodanang.vn/su-dung-cac-bai-dat-trong-lam-bai-do-xe-3184313.html

## Data-quality issues intentionally included
- ~1% `avg_speed_kmh = null` in traffic logs.
- ~0.5% duplicate traffic records.
- 3 missing `road_width_m` values in road survey.
- ~1.5% parking events with `end_time = null` (ongoing/unclosed event).
- ~0.4% duplicate parking events.

These are useful for Bronze → Silver cleaning/deduplication exercises.

## Policy-use warning
This is a portfolio dataset. Fields marked `SYNTHETIC`, `SYNTHETIC_PLAUSIBLE`, `APPROX`, or similar are **not official measurements**.
