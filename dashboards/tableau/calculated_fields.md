# DashCart — Tableau calculated fields

Paste each into **Analysis → Create Calculated Field**. Field names are in bold.
Table prefixes assume the relationship model in the build guide (base table = `tableau_orders_wide`).

## Parameters
| Name | Type | Value |
|---|---|---|
| **p_SLA Target** | Float | 0.85 (range 0.6–1.0, step 0.01) |
| **p_Hour** | Integer | 18 (list 0–23). Set by the heatmap parameter action |
| **p_Metric** | String | list: GMV, Net Revenue, Contribution Margin, Orders |

## KPIs
```
// Orders
COUNTD([order_id])

// Delivered Orders
SUM([is_delivered])

// Cancellation Rate
SUM([is_cancelled]) / COUNTD([order_id])

// GMV
SUM([gross_item_value])

// Delivered GMV
SUM(IF [is_delivered] = 1 THEN [gross_item_value] END)

// Net Revenue
SUM([net_revenue])

// Contribution Margin
SUM([contribution_margin])

// CM % of GMV
[Contribution Margin] / [Delivered GMV]

// AOV
[Delivered GMV] / [Delivered Orders]

// Discount % of GMV
SUM([discount_amount]) / [GMV]

// Selected Metric        (drives the switchable trend chart)
CASE [p_Metric]
  WHEN "GMV" THEN [GMV]
  WHEN "Net Revenue" THEN [Net Revenue]
  WHEN "Contribution Margin" THEN [Contribution Margin]
  WHEN "Orders" THEN [Orders]
END
```

## SLA
```
// On-time Rate
SUM([is_on_time]) / COUNT([delivery_minutes])

// Late Rate
1 - [On-time Rate]

// Avg Delivery Min
AVG([delivery_minutes])

// P90 Delivery Min
PERCENTILE([delivery_minutes], 0.9)

// SLA Status            (colour with the DashCart Status palette)
IF [On-time Rate] >= 0.80 THEN "On track"
ELSEIF [On-time Rate] >= 0.65 THEN "At risk"
ELSE "Breaching" END

// SLA Gap (pp)
([On-time Rate] - [p_SLA Target]) * 100

// Is Selected Hour
[order_hour] = [p_Hour]

// Anomaly Minutes       (table calc: compute using order_date; partition by city)
IF [Avg Delivery Min] > 2 * WINDOW_AVG([Avg Delivery Min], -28, -1)
THEN [Avg Delivery Min] END
```

## Events
```
// Monsoon
IF [is_monsoon] = "True" OR [is_monsoon] = "1" THEN "Monsoon (Jun–Sep)" ELSE "Rest of year" END
// (If Tableau already typed it Boolean: IF [is_monsoon] THEN ... )

// Late Rate Monsoon
SUM(IF MONTH([order_date]) >= 6 AND MONTH([order_date]) <= 9 THEN 1 - [is_on_time] END)
/ SUM(IF MONTH([order_date]) >= 6 AND MONTH([order_date]) <= 9 AND NOT ISNULL([is_on_time]) THEN 1 END)

// Late Rate Dry
SUM(IF MONTH([order_date]) < 6 OR MONTH([order_date]) > 9 THEN 1 - [is_on_time] END)
/ SUM(IF (MONTH([order_date]) < 6 OR MONTH([order_date]) > 9) AND NOT ISNULL([is_on_time]) THEN 1 END)

// Monsoon Lift (pp)
([Late Rate Monsoon] - [Late Rate Dry]) * 100

// Monsoon DiD (pp)       (README: about +34 pp). Use FIXED so city filters don't break it
{ FIXED : SUM(IF [city]="Mumbai" AND MONTH([order_date])>=6 AND MONTH([order_date])<=9 THEN 1-[is_on_time] END)
        / SUM(IF [city]="Mumbai" AND MONTH([order_date])>=6 AND MONTH([order_date])<=9 AND NOT ISNULL([is_on_time]) THEN 1 END) }
- { FIXED : SUM(IF [city]="Mumbai" AND (MONTH([order_date])<6 OR MONTH([order_date])>9) THEN 1-[is_on_time] END)
          / SUM(IF [city]="Mumbai" AND (MONTH([order_date])<6 OR MONTH([order_date])>9) AND NOT ISNULL([is_on_time]) THEN 1 END) }
- ( { FIXED : SUM(IF [city] IN ("Bengaluru","Delhi") AND MONTH([order_date])>=6 AND MONTH([order_date])<=9 THEN 1-[is_on_time] END)
            / SUM(IF [city] IN ("Bengaluru","Delhi") AND MONTH([order_date])>=6 AND MONTH([order_date])<=9 AND NOT ISNULL([is_on_time]) THEN 1 END) }
  - { FIXED : SUM(IF [city] IN ("Bengaluru","Delhi") AND (MONTH([order_date])<6 OR MONTH([order_date])>9) THEN 1-[is_on_time] END)
            / SUM(IF [city] IN ("Bengaluru","Delhi") AND (MONTH([order_date])<6 OR MONTH([order_date])>9) AND NOT ISNULL([is_on_time]) THEN 1 END) } )

// Festival Window
IF [is_festival_window] = "True" OR [is_festival_window] = "1" THEN "Festival ±2 days" ELSE "Normal day" END

// Hour Band (already in the CSV as [hour_band]; this is the formula if you connect to Snowflake)
IF [order_hour] <= 6 THEN "Late night (0-6)"
ELSEIF [order_hour] <= 11 THEN "Morning (7-11)"
ELSEIF [order_hour] <= 17 THEN "Afternoon (12-17)"
ELSEIF [order_hour] <= 21 THEN "Evening peak (18-21)"
ELSE "Night (22-23)" END
```

## Customers (mart_customer_360)
```
// Avg Orders / Month
AVG([orders_per_month])

// Avg LTV
AVG([lifetime_net_revenue])

// Churn Rate 45d
AVG([is_churned_45d])

// Customer Revenue Rank  (table calc, compute using customer_id, sorted by SUM(lifetime_net_revenue) desc)
RUNNING_SUM(SUM([lifetime_net_revenue])) / TOTAL(SUM([lifetime_net_revenue]))
// → Pareto chart: X = INDEX()/SIZE(), Y = this field, reference line at 0.8 (README: 33% of customers)

// First Order Cohort (if building cohorts from the wide table instead of the mart)
{ FIXED [customer_id] : MIN(DATETRUNC('month', [order_date])) }

// Months Since First Order
DATEDIFF('month', [First Order Cohort], DATETRUNC('month', [order_date]))
```

## Category (fact_order_items + dim_product)
```
// Item Revenue
SUM([line_amount])

// Item GM %
(SUM([line_amount]) - SUM([line_cogs])) / SUM([line_amount])
```

## Formatting
```
// INR Short   (use as a label, e.g. KPI tile)
IF ABS([GMV]) >= 10000000 THEN "₹" + STR(ROUND([GMV]/10000000, 2)) + " Cr"
ELSEIF ABS([GMV]) >= 100000 THEN "₹" + STR(ROUND([GMV]/100000, 2)) + " L"
ELSE "₹" + STR(ROUND([GMV], 0)) END

// Δ GMV vs prior period (table calc along MONTH(order_date))
(ZN([GMV]) - LOOKUP(ZN([GMV]), -1)) / ABS(LOOKUP(ZN([GMV]), -1))
```
Number formats: currency → *Custom* `₹#,##0`, rates → *Percentage, 1 decimal*.
