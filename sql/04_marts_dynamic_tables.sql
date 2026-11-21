/* =============================================================================
   04_marts_dynamic_tables.sql   (MARTS layer)
   -----------------------------------------------------------------------------
   Declarative pipelines with DYNAMIC TABLES: Snowflake keeps them fresh within
   TARGET_LAG and refreshes incrementally where the query allows.
   An intermediate DT uses TARGET_LAG = DOWNSTREAM (refreshes only when a
   consumer needs it).
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_TRANSFORM_WH;
USE SCHEMA DASHCART.MARTS;

-- ---------------------------------------------------------------------------
-- Intermediate: order-level enriched fact (joins the star once for everyone)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DT_ORDERS_ENRICHED
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = DASHCART_TRANSFORM_WH
  -- REFRESH_MODE defaults to AUTO (incremental when the query allows it)
AS
SELECT f.order_id, f.order_ts, f.order_date, f.order_hour, f.store_id, f.city, s.zone,
       f.customer_id, f.customer_sk, c.membership_tier, c.acquisition_channel, c.signup_date,
       f.platform, f.payment_method, f.coupon_code, f.order_status,
       f.line_count, f.units, f.gross_item_value, f.discount_amount, f.delivery_fee,
       f.net_revenue, f.cogs, f.contribution_margin,
       f.promised_minutes, f.delivery_minutes, f.pack_minutes, f.ride_minutes, f.is_on_time,
       f.weather, f.vehicle_type, f.distance_km,
       d.is_weekend, d.is_festival_window, d.is_monsoon, d.month_start, d.week_start, d.day_name
FROM DASHCART.CORE.FACT_ORDERS f
JOIN DASHCART.CORE.DIM_DATE d       ON d.date_key = f.date_key
LEFT JOIN DASHCART.CORE.DIM_STORE s ON s.store_id = f.store_id
LEFT JOIN DASHCART.CORE.DIM_CUSTOMER c ON c.customer_sk = f.customer_sk;

-- ---------------------------------------------------------------------------
-- Daily KPIs per city  (main executive mart)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DT_DAILY_CITY_KPIS
  TARGET_LAG = '1 hour'
  WAREHOUSE  = DASHCART_TRANSFORM_WH
AS
SELECT order_date, city,
       COUNT(*)                                               AS orders,
       COUNT_IF(order_status = 'DELIVERED')                   AS delivered_orders,
       COUNT_IF(order_status = 'CANCELLED')                   AS cancelled_orders,
       COUNT(DISTINCT customer_id)                            AS active_customers,
       SUM(gross_item_value)                                  AS gmv,
       SUM(net_revenue)                                       AS net_revenue,
       SUM(contribution_margin)                               AS contribution_margin,
       SUM(discount_amount)                                   AS discounts,
       SUM(IFF(order_status = 'DELIVERED', gross_item_value, 0))
         / NULLIF(COUNT_IF(order_status = 'DELIVERED'), 0)    AS aov,
       COUNT_IF(is_on_time) / NULLIF(COUNT_IF(delivery_minutes IS NOT NULL), 0) AS on_time_rate,
       AVG(delivery_minutes)                                  AS avg_delivery_minutes,
       APPROX_PERCENTILE(delivery_minutes, 0.9)               AS p90_delivery_minutes,
       ANY_VALUE(is_festival_window)                          AS is_festival_window,
       ANY_VALUE(is_weekend)                                  AS is_weekend
FROM DT_ORDERS_ENRICHED
GROUP BY order_date, city;

-- ---------------------------------------------------------------------------
-- Store x hour load vs capacity  (ops staffing)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DT_STORE_HOURLY_LOAD
  TARGET_LAG = '1 hour'
  WAREHOUSE  = DASHCART_TRANSFORM_WH
AS
SELECT o.store_id, o.city, o.order_date, o.order_hour,
       COUNT(*)                                               AS orders,
       MAX(s.capacity_orders_per_hour)                        AS capacity_per_hour,
       COUNT(*) / NULLIF(MAX(s.capacity_orders_per_hour), 0)  AS utilization,
       AVG(o.pack_minutes)                                    AS avg_pack_minutes,
       AVG(o.delivery_minutes)                                AS avg_delivery_minutes
FROM DT_ORDERS_ENRICHED o
JOIN DASHCART.CORE.DIM_STORE s ON s.store_id = o.store_id
GROUP BY o.store_id, o.city, o.order_date, o.order_hour;

-- ---------------------------------------------------------------------------
-- Customer 360 aggregates (recency computed in a view against data "as-of" date)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DT_CUSTOMER_360
  TARGET_LAG = '1 hour'
  WAREHOUSE  = DASHCART_TRANSFORM_WH
AS
SELECT customer_id,
       MIN(order_date)                                        AS first_order_date,
       MAX(order_date)                                        AS last_order_date,
       COUNT(*)                                               AS total_orders,
       COUNT_IF(order_status = 'DELIVERED')                   AS delivered_orders,
       COUNT_IF(order_status = 'CANCELLED')                   AS cancelled_orders,
       SUM(net_revenue)                                       AS lifetime_net_revenue,
       SUM(contribution_margin)                               AS lifetime_margin,
       SUM(discount_amount)                                   AS lifetime_discounts,
       AVG(IFF(order_status = 'DELIVERED', gross_item_value, NULL)) AS avg_basket_value,
       COUNT(DISTINCT store_id)                               AS stores_used,
       COUNT_IF(coupon_code IS NOT NULL) / COUNT(*)           AS coupon_usage_rate,
       COUNT_IF(is_on_time = FALSE) / NULLIF(COUNT_IF(delivery_minutes IS NOT NULL), 0) AS late_delivery_rate
FROM DT_ORDERS_ENRICHED
GROUP BY customer_id;

CREATE OR REPLACE VIEW V_CUSTOMER_360 AS
WITH as_of AS (SELECT MAX(order_date) AS as_of_date FROM DASHCART.CORE.FACT_ORDERS)
SELECT c.customer_id, d.full_name, d.email, d.phone, d.city, d.membership_tier, d.acquisition_channel,
       d.signup_date, c.*  EXCLUDE (customer_id),
       DATEDIFF(DAY, c.last_order_date, a.as_of_date)         AS days_since_last_order,
       DATEDIFF(DAY, c.first_order_date, a.as_of_date)        AS tenure_days,
       c.total_orders / GREATEST(DATEDIFF(MONTH, c.first_order_date, a.as_of_date), 1) AS orders_per_month,
       DATEDIFF(DAY, c.last_order_date, a.as_of_date) > 45    AS is_churned_45d
FROM DT_CUSTOMER_360 c
CROSS JOIN as_of a
JOIN DASHCART.CORE.DIM_CUSTOMER d ON d.customer_id = c.customer_id AND d.is_current;

-- ---------------------------------------------------------------------------
-- Product performance per day
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DT_PRODUCT_DAILY
  TARGET_LAG = '1 hour'
  WAREHOUSE  = DASHCART_TRANSFORM_WH
AS
SELECT i.order_date, p.product_id, p.product_name, p.category, p.sub_category, p.brand, p.is_private_label,
       SUM(i.quantity)                                        AS units,
       SUM(i.line_amount)                                     AS revenue,
       SUM(i.line_amount - i.line_cogs)                       AS gross_margin,
       COUNT(DISTINCT i.order_id)                             AS orders
FROM DASHCART.CORE.FACT_ORDER_ITEMS i
JOIN DASHCART.CORE.DIM_PRODUCT p ON p.product_id = i.product_id
GROUP BY i.order_date, p.product_id, p.product_name, p.category, p.sub_category, p.brand, p.is_private_label;

-- ---------------------------------------------------------------------------
-- Observe dynamic tables
-- ---------------------------------------------------------------------------
SHOW DYNAMIC TABLES IN SCHEMA DASHCART.MARTS;

SELECT name, state, refresh_action, refresh_trigger, data_timestamp,
       DATEDIFF('second', refresh_start_time, refresh_end_time) AS refresh_seconds
FROM TABLE(DASHCART.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
ORDER BY data_timestamp DESC
LIMIT 20;

-- Force a refresh (e.g. right after the first backfill)
ALTER DYNAMIC TABLE DT_DAILY_CITY_KPIS   REFRESH;
ALTER DYNAMIC TABLE DT_STORE_HOURLY_LOAD REFRESH;
ALTER DYNAMIC TABLE DT_CUSTOMER_360      REFRESH;
ALTER DYNAMIC TABLE DT_PRODUCT_DAILY     REFRESH;
