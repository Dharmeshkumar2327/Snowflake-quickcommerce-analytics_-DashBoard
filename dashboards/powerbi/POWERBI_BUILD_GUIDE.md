# DashCart — Power BI Dashboard Build Guide

A 5-page **"Ops & Growth Command Center"** report on the DashCart quick-commerce star schema.
Build time: about 2–3 hours the first time.

| File | Purpose |
|---|---|
| `PowerQuery_CSV.pq` | M queries for the CSV extracts (`dashboards/data/`): works offline, no Snowflake needed |
| `PowerQuery_Snowflake.pq` | Same queries straight from Snowflake (`CORE`, `MARTS`, `ML` schemas). This is the production path |
| `DAX_Measures.dax` | ~70 measures, all checked against the README numbers |
| `DashCart_Theme.json` | Colour-blind-safe theme (6 city colours in a fixed order, status colours, light surfaces) |

---

## 1. Load the data

1. Run `python dashboards/build_bi_extracts.py` from the repo root. It writes 14 files to `dashboards/data/`.
2. Power BI Desktop → **Transform data** → **Manage Parameters → New** → `DataFolder` (Text), set to your full path ending in `\`.
3. Create one **Blank Query** for each block in `PowerQuery_CSV.pq` and name it as the comment says: `fnCsv`, `FactOrders`, `FactOrderItems`, `DimDate`, `DimStore`, `DimProduct`, `DimCustomer`, `Customer360`, `Reviews`, `StoreHourly`, `CohortRetention`, `HourAxis`.
4. **Close & Apply**. About 400k rows load in under a minute.
5. **View → Themes → Browse for themes** → `DashCart_Theme.json`.

> **Snowflake mode:** use `PowerQuery_Snowflake.pq` instead. Set `FactOrders` / `FactOrderItems` to **DirectQuery** and everything else to **Import**, which gives you a composite model. Connect with role `DASHCART_ANALYST`: PII arrives masked and the row access policy applies, so a city manager only sees their own city.

## 2. Model (star schema)

Model view → create these relationships. All are **many-to-one, single direction**:

| From (many) | To (one) | Notes |
|---|---|---|
| `FactOrders[order_date]` | `DimDate[date]` | Mark `DimDate` as the date table |
| `FactOrders[store_id]` | `DimStore[store_id]` | City slicer = `DimStore[city]` |
| `FactOrders[customer_id]` | `DimCustomer[customer_id]` | |
| `FactOrderItems[order_id]` | `FactOrders[order_id]` | Date and city filters reach items through orders |
| `FactOrderItems[product_id]` | `DimProduct[product_id]` | |
| `Customer360[customer_id]` | `DimCustomer[customer_id]` | 1:1 (set cardinality to *one-to-one*, single direction from DimCustomer) |
| `Reviews[store_id]` | `DimStore[store_id]` | |
| `Reviews[review_date]` | `DimDate[date]` | |
| `StoreHourly[store_id]` | `DimStore[store_id]` | |

`CohortRetention` and `HourAxis` stay disconnected.
**Do not** relate `FactOrderItems[order_date]` to `DimDate`: it would create an ambiguous path.

Hygiene: hide every key/ID column and the raw numeric columns from Report view, sort `DimDate[month_name]` by `DimDate[month]`, set `DimStore[city]` Data category = **City**, and set `latitude`/`longitude` to **Latitude/Longitude**.

## 3. Measures

Home → **Enter data** → an empty table named `_Measures`. Paste each measure from `DAX_Measures.dax` and apply the format string in its comment. Organise them into display folders: *Volume, Money, SLA, Time, Events, Customers, Category, VoC*.

Sanity check on a card with no filters applied:

| Measure | Expected |
|---|---|
| Orders | 89,797 |
| GMV (Cr) | ₹6.42 Cr |
| AOV | ₹715 |
| CM % of GMV | 4.5% |
| On-time Rate | 72.7% |
| Cancellation Rate | 2.6% |
| Plus Frequency Multiple | 2.0× |
| Churn Rate 45d (Plus / Standard) | 38.1% / 63.7% |

## 4. Report pages (16:9, 1280×720)

Every page shares a **top band** (y 0–56): logo text "DashCart", the `[Title Exec]` measure as the title, and three slicers in one row: **Date** (`DimDate[date]`, between), **City** (`DimStore[city]`, dropdown, multi-select), **Platform** (`FactOrders[platform]`). Sync the slicers across pages (View → Sync slicers).

### Page 1 · Executive Overview
| Zone | Visual | Fields |
|---|---|---|
| KPI row (6 cards) | Card (new) | `Orders`, `GMV (Cr)`, `AOV`, `CM % of GMV`, `On-time Rate`, `Cancellation Rate`. Reference label = `GMV MoM %` / `Orders YoY %` |
| Left 60% | Line chart | X `DimDate[month_start]`, Y `GMV`, Legend `DimStore[city]` |
| Right 40% | Waterfall | Category: GMV → −Discounts → +Delivery fee → −COGS → CM (build a 5-row `Bridge` table with SWITCH, or use 5 measures in a *Values* waterfall) |
| Bottom left | Clustered bar | `DimProduct[category]` × `Item Revenue`, tooltip `Item GM %` |
| Bottom right | Matrix | Rows `DimStore[city]`; values `Orders`, `GMV`, `AOV`, `CM % of GMV`, `On-time Rate` (background = `SLA Colour`) |

### Page 2 · Delivery SLA (Ops)
| Zone | Visual | Fields |
|---|---|---|
| KPI row | Cards | `On-time Rate`, `Avg Delivery Min`, `P90 Delivery Min`, `Avg Pack Min`, `Avg Ride Min` |
| Main | **Matrix heatmap** | Rows `DimStore[city]`, Columns `FactOrders[order_hour]`, Values `On-time Rate`. Conditional formatting → background → gradient #d03b3b (0.4) → #f0efec (0.7) → #2a78d6 (1.0). Values font colour = background so only colour shows; tooltip carries the value |
| Right | Clustered bar | `FactOrders[weather]` × `Avg Delivery Min`, tooltip `On-time Rate`, `Orders` |
| Bottom | Line chart | X `DimDate[date]`, Y `Avg Delivery Min` + `Delivery Anomaly` (markers only, red). Shows **Bengaluru 12 Mar 2026** (30 min, 35% cancelled) |
| Bottom right | Table | `DimStore[store_name]`, `Avg Utilisation`, `Peak Utilisation`, `Avg Pack Min`, sorted by Peak, top 10 |

Insight text box: *"Evening peak (18–21h) runs at 64.8% on-time vs ~77% at other hours."*

### Page 3 · Monsoon & Festivals (Events)
| Zone | Visual | Fields |
|---|---|---|
| Cards | Card | `Monsoon DiD (pp)` (≈ +34), `Festival Uplift %` |
| Left | Line chart | X `DimDate[month_start]`, Y `Late Rate`, Legend `DimStore[city]`. Add a shaded constant band Jun–Sep with an *Error bars* or background image, or simply a `DimDate[is_monsoon]` slicer |
| Right | Clustered column | X `DimDate[is_monsoon]`, Y `Late Rate`, small multiples `DimStore[city]` |
| Bottom | Line chart (daily) | X `DimDate[date]` filtered Oct–Nov 2025, Y `Orders`, `On-time Rate` in the tooltip. Annotate Diwali 20 Oct 2025 |

### Page 4 · Customers & Growth
| Zone | Visual | Fields |
|---|---|---|
| Cards | Card | `Customers`, `Avg LTV`, `Churn Rate 45d`, `Plus LTV Multiple`, `Revenue at Risk` |
| Left | Clustered bar | `DimCustomer[membership_tier]` × `Avg Orders / Month`, `Churn Rate 45d` (two visuals side by side, no dual axis) |
| Centre | **Cohort matrix** | `CohortRetention`: Rows `cohort`, Columns `m`, Values `retention` (Sum). Gradient #cde2fb → #104281 |
| Right | Donut → **use a bar instead** | `Customer360[rfm_segment]` × `Customers`, tooltip `Avg LTV` |
| Bottom | Scatter | X `Customer360[orders_per_month]`, Y `Customer360[lifetime_net_revenue]`, Details `customer_id`, Legend `rfm_segment` (cap at 3 legend values for colour safety, or use the segment slicer) |
| Bottom right | Clustered bar | `DimCustomer[acquisition_channel]` × `Avg LTV` |

### Page 5 · Voice of Customer
| Zone | Visual | Fields |
|---|---|---|
| Cards | Card | `Reviews #`, `Avg Rating`, `Negative Share` |
| Left | Bar | `Reviews[complaint_theme]` × `Reviews #` (exclude "Positive experience" with a visual filter) |
| Centre | Line | `DimDate[month_start]` × `Avg Rating` by `DimStore[city]` |
| Right | Table | `DimStore[store_name]`, `Negative Reviews`, `Avg Rating`, top N = 10 |
| Bottom | Table | `Reviews[review_text]`, `rating`, `review_date`, filtered to rating ≤ 2 |

In Snowflake mode, swap `complaint_theme` for the Cortex `CLASSIFY_TEXT` output in `ML.REVIEWS_ENRICHED` and add the `ML.STORE_REVIEW_BRIEFS` LLM summaries as a table.

## 5. Interactivity

- **Drill-through** page "Store detail": drill-through field `DimStore[store_id]`. Put a store card, hourly utilisation (`StoreHourly`), on-time trend and reviews on it.
- **Tooltip page** (Page size = Tooltip): mini line of `Orders` by month plus `On-time Rate`, assigned to the city matrix.
- **Bookmarks**: "Monsoon view" (Jun–Sep, Mumbai vs others) and "Diwali view". Add buttons in the top band.
- **Field parameter** (Modeling → New parameter → Fields): `GMV`, `Net Revenue`, `Contribution Margin`, `Orders`. Use it on the Executive trend so viewers can switch the metric.
- Turn on **Q&A** with synonyms: *sales = GMV, late = Late Rate, city = DimStore[city]*.

## 6. Publish & go "live"

1. **Publish** to the Power BI Service (a free account works for *My workspace*).
2. CSV mode: install the **on-premises data gateway (personal)** and schedule a daily refresh.
   Snowflake mode: no gateway needed (cloud source). Set the dataset credentials (OAuth or Basic), and DirectQuery tables are live on every interaction. The Dynamic Tables keep `MARTS` ≤ 1 h fresh.
3. For your portfolio: **File → Embed report → Publish to web (public)** gives you a public link and iframe for GitHub/LinkedIn. Use it only with this synthetic data.
4. Screenshot each page to `docs/powerbi/*.png` and link them in the README.

## 7. Colour rules used (keep them when you extend the report)

- Cities always take the same colour, in this order: Bengaluru `#2a78d6`, Chennai `#eb6834`, Delhi `#1baf7a`, Hyderabad `#eda100`, Mumbai `#e87ba4`, Pune `#008300`. The theme's `dataColors` follows this order, so keep the city legend sorted A→Z.
- Green, amber and red are **status only** (SLA Colour). Never use them as a series colour.
- One y-axis per chart. If you need two measures, use two visuals.
