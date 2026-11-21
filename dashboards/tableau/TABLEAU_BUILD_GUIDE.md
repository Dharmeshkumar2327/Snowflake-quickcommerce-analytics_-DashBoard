# DashCart — Tableau Dashboard Build Guide

Four dashboards plus a story, built for **Tableau Public** (free) or Tableau Desktop/Cloud.

| File | Purpose |
|---|---|
| `../data/tableau_orders_wide.csv` | One denormalised order table (89,797 rows × 44 cols). The easiest source for Tableau Public |
| `../data/fact_order_items.csv` + `dim_product.csv` | Category / product sheets (relationship on `order_id` / `product_id`) |
| `../data/mart_customer_360.csv`, `mart_cohort_retention.csv`, `fact_reviews.csv`, `mart_store_hourly.csv` | Customer, cohort, review and capacity sheets |
| `calculated_fields.md` | Every calculated field to paste in, plus parameters and LODs |
| `Preferences.tps` | City / sequential / diverging / status palettes |

---

## 1. Data source (relationships, the "noodle" model)

1. Copy `Preferences.tps` into `My Tableau Repository/` and restart Tableau.
2. **Connect → Text file →** `tableau_orders_wide.csv`. Name the source **DashCart**.
3. Drag in more tables and create **relationships** (not joins):
   - `tableau_orders_wide.order_id` = `fact_order_items.order_id`
   - `fact_order_items.product_id` = `dim_product.product_id`
   - `tableau_orders_wide.customer_id` = `mart_customer_360.customer_id`
   - `tableau_orders_wide.order_id` = `fact_reviews.order_id`
   - `tableau_orders_wide.store_id` = `mart_store_hourly.store_id`
4. Add `mart_cohort_retention.csv` as a **separate data source** (it is pre-aggregated).
5. Types: `order_date` → Date, `order_ts` → Date & Time, `latitude`/`longitude` → geographic roles, `city` → Geographic role *City* (country = India), `is_on_time`, `is_delivered`, `is_cancelled`, `has_coupon` → Number (whole).
6. **Extract** (Data → Extract) so Tableau Public can save it. That's required for Public.

> **Snowflake live connection (Desktop/Cloud):** Connect → Snowflake. Server `<account>.snowflakecomputing.com`, role `DASHCART_ANALYST`, warehouse `DASHCART_BI_WH`, database `DASHCART`. Use `MARTS.DT_ORDERS_ENRICHED` in place of the wide CSV (same columns, plus `zone`, `is_monsoon`, etc.). Keep it **Live** for real-time numbers. Set the *Initial SQL* to `ALTER SESSION SET QUERY_TAG='{"project":"dashcart","module":"tableau"}'` so Tableau shows up in the cost-attribution query in `sql/09`.

## 2. Calculated fields

Create everything in `calculated_fields.md`, foldered as *KPIs, SLA, Events, Customers, Formatting*. Check against the README:

| Field | Expected (all data) |
|---|---|
| `Orders` | 89,797 |
| `GMV` | ₹6.42 Cr |
| `AOV` | ₹715 |
| `CM % of GMV` | 4.5% |
| `On-time Rate` | 72.7% |

## 3. Worksheets (build these 16 sheets)

| # | Sheet | Build |
|---|---|---|
| 1 | KPI Orders / GMV / AOV / CM% / On-time / Cancel | One sheet per KPI tile: Text mark, the measure + the `Δ vs prior period` calc underneath in secondary ink |
| 2 | GMV trend by city | Columns `MONTH(order_date)` (continuous), Rows `GMV`, Colour `city` (DashCart Cities), Line 2px |
| 3 | Unit-economics waterfall | Measure Names filtered to GMV, −Discounts, +Delivery fee, −COGS. Gantt bar with `Running sum`; size = `-[value]`. Final bar = `Contribution Margin` |
| 4 | Category revenue | `dim_product.category` × `Item Revenue`, bar; colour = `Item GM %` (DashCart Sequential Blue) |
| 5 | City scorecard | Text table: city × Orders, GMV, AOV, CM%, On-time Rate; On-time cell colour = `SLA Status` (DashCart Status) |
| 6 | **SLA heatmap** | Columns `order_hour` (discrete), Rows `city`, Square mark, Colour `On-time Rate` (DashCart SLA Diverging, centre 0.70, range 0.40–1.0) |
| 7 | Weather impact | `weather` × `Avg Delivery Min`, bar, tooltip On-time Rate + Orders |
| 8 | Daily delivery time + anomalies | `DAY(order_date)` continuous × `Avg Delivery Min` line; dual **mark** (same axis!) circle for `Anomaly Minutes`. Filter `city` = Bengaluru to show 12 Mar 2026 |
| 9 | Store map | Map: `longitude`/`latitude`, size = `Orders`, colour = `On-time Rate`, detail `store_name` |
| 10 | Monsoon late rate | Columns `MONTH(order_date)`, Rows `Late Rate`, colour `city`. Reference band Jun–Sep (Analytics → Reference band on a constant date range) |
| 11 | Monsoon DiD | Text: `Monsoon DiD (pp)` big number + caption "Mumbai vs Bengaluru & Delhi" |
| 12 | Diwali window | Daily orders Oct–Nov 2025, reference line at 20 Oct 2025, colour `Festival Window` |
| 13 | Cohort retention | (Cohort source) Rows `cohort`, Columns `m`, Square, Colour `retention` (Sequential Blue), label on |
| 14 | Plus vs Standard | `membership_tier` × `Avg Orders / Month` and `Churn Rate 45d`. Use **two separate sheets** side by side, not a dual axis |
| 15 | Segment bars | `rfm_segment` × `CNTD(customer_id)`, tooltip avg LTV, sorted desc |
| 16 | Review themes | `fact_reviews.complaint_theme` (exclude Positive) × count, colour `AVG(rating)` |

## 4. Dashboards (1366 × 768, Fixed, or *Automatic* for Public)

Layout grid: a 64 px top band (title + filters), a KPI row of 110 px, then two rows of charts. 16 px padding, white tiles on `#f9f9f7`.

**D1 · Executive Overview:** sheets 1 (×6 tiles), 2, 3, 4, 5.
**D2 · Delivery SLA:** sheets 6, 7, 8, 9 + the `SLA Target` parameter control.
**D3 · Monsoon & Festivals:** sheets 10, 11, 12.
**D4 · Customers & VoC:** sheets 13, 14, 15, 16.

Filters (apply to *All using this data source*): `order_date` (range slider), `city` (multi-value dropdown), `platform`, `membership_tier`. Put them in the top band in one row.

### Actions
- **Filter action**: click a city in the scorecard (D1) → filters every sheet on D1 and D2.
- **Highlight action**: hover a city on any line → highlights that city everywhere.
- **Go to Sheet**: click a store on the map (D2) → opens a *Store detail* dashboard filtered by `store_id`.
- **Parameter action**: click an hour column on the heatmap → sets `p_Hour` → sheet 7 shows weather impact for that hour only.

## 5. Story: "Why DashCart misses the 10-minute promise"

1. *We grew to ₹6.42 Cr GMV, but keep only 4.5% as margin* (D1)
2. *One in four orders is late, and the evening peak is worst* (sheet 6)
3. *Mumbai's monsoon doubles late deliveries: +34 pp DiD* (sheet 10–11)
4. *Diwali doubles demand and drops on-time to 51%* (sheet 12)
5. *Bengaluru 12 Mar 2026: a 30-minute day the anomaly model caught* (sheet 8)
6. *Plus members are worth 2.1× — fix SLA for them first* (sheet 14–15)

## 6. Publish & go "live"

- **Tableau Public:** File → Save to Tableau Public (the data must be an extract). Turn on *Show workbook sheets as tabs* off, *Allow download* on. Paste the public URL and embed code into your README / portfolio site.
- **Tableau Cloud + Snowflake live connection:** publish with *Embedded credentials*. The workbook then queries Snowflake on every view, so it's always current with the Dynamic Tables (`TARGET_LAG = 1 hour`).
- **Tableau Public + scheduled data:** put the CSVs in Google Drive / Google Sheets and connect through the Google Sheets connector. Tableau Public refreshes Google Sheets sources daily.

## 7. Colour rules

Cities take a fixed colour (Bengaluru blue, Chennai orange, Delhi aqua, Hyderabad yellow, Mumbai pink, Pune green). Assign them once with *Edit Colors → DashCart Cities → Assign Palette* and they stay correct when a filter removes a city. Green/amber/red are only for SLA status. One axis per chart.
