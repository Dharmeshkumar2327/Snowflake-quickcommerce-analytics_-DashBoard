/* =============================================================================
   02_staging_views.sql   (SILVER layer)
   -----------------------------------------------------------------------------
   * Safe typing with TRY_TO_* (bad values become NULL instead of failing)
   * De-duplication with QUALIFY ROW_NUMBER()  (re-delivered files, replays)
   * Semi-structured JSON: dot-path extraction, LATERAL FLATTEN of arrays,
     pivoting an event array into one row per order with conditional aggregation
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_TRANSFORM_WH;
USE SCHEMA DASHCART.STAGING;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW STG_STORES AS
SELECT store_id,
       store_name,
       INITCAP(city)                                   AS city,
       zone,
       TRY_TO_DOUBLE(latitude)                         AS latitude,
       TRY_TO_DOUBLE(longitude)                        AS longitude,
       TRY_TO_DATE(opened_date)                        AS opened_date,
       TRY_TO_NUMBER(capacity_orders_per_hour)         AS capacity_orders_per_hour
FROM DASHCART.RAW.RAW_DARK_STORES
QUALIFY ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY _loaded_at DESC) = 1;

CREATE OR REPLACE VIEW STG_PRODUCTS AS
SELECT product_id, sku, product_name, category, sub_category, brand,
       TRY_TO_NUMBER(mrp, 10, 2)                       AS mrp,
       TRY_TO_NUMBER(cost_price, 10, 2)                AS cost_price,
       TRY_TO_BOOLEAN(is_perishable)                   AS is_perishable,
       IFF(brand ILIKE 'DashCart%', TRUE, FALSE)       AS is_private_label
FROM DASHCART.RAW.RAW_PRODUCTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY _loaded_at DESC) = 1;

-- Latest known version of each customer (the SCD2 dimension keeps full history)
CREATE OR REPLACE VIEW STG_CUSTOMERS AS
SELECT customer_id, full_name, LOWER(email) AS email, phone, INITCAP(city) AS city,
       TRY_TO_DATE(signup_date)                        AS signup_date,
       acquisition_channel, membership_tier,
       TRY_TO_NUMBER(birth_year)                       AS birth_year,
       TRY_TO_TIMESTAMP_NTZ(updated_at)                AS updated_at
FROM DASHCART.RAW.RAW_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id
                           ORDER BY TRY_TO_TIMESTAMP_NTZ(updated_at) DESC, _loaded_at DESC) = 1;

-- ---------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW STG_ORDERS AS
SELECT order_id, customer_id, store_id,
       TRY_TO_TIMESTAMP_NTZ(order_ts)                  AS order_ts,
       TO_DATE(TRY_TO_TIMESTAMP_NTZ(order_ts))         AS order_date,
       LOWER(platform)                                 AS platform,
       payment_method,
       NULLIF(coupon_code, '')                         AS coupon_code,
       COALESCE(TRY_TO_NUMBER(discount_amount, 10, 2), 0) AS discount_amount,
       COALESCE(TRY_TO_NUMBER(delivery_fee, 10, 2), 0)    AS delivery_fee,
       UPPER(order_status)                             AS order_status
FROM DASHCART.RAW.RAW_ORDERS
WHERE order_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY _loaded_at DESC, _row DESC) = 1;

CREATE OR REPLACE VIEW STG_ORDER_ITEMS AS
SELECT order_id,
       TRY_TO_NUMBER(line_no)                          AS line_no,
       product_id,
       TRY_TO_NUMBER(quantity)                         AS quantity,
       TRY_TO_NUMBER(unit_price, 10, 2)                AS unit_price,
       TRY_TO_NUMBER(quantity) * TRY_TO_NUMBER(unit_price, 10, 2) AS line_amount
FROM DASHCART.RAW.RAW_ORDER_ITEMS
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id, line_no ORDER BY _loaded_at DESC) = 1;

CREATE OR REPLACE VIEW STG_REVIEWS AS
SELECT review_id, order_id, customer_id,
       TRY_TO_NUMBER(rating)                           AS rating,
       TRIM(review_text)                               AS review_text,
       TRY_TO_TIMESTAMP_NTZ(review_ts)                 AS review_ts
FROM DASHCART.RAW.RAW_REVIEWS
QUALIFY ROW_NUMBER() OVER (PARTITION BY review_id ORDER BY _loaded_at DESC) = 1;

-- ---------------------------------------------------------------------------
-- Semi-structured: delivery documents
-- {order_id, store_id, promised_minutes, rider:{rider_id,vehicle},
--  conditions:{weather,distance_km}, events:[{status,ts},...]}
-- ---------------------------------------------------------------------------

-- (a) Event log: one row per status change  (LATERAL FLATTEN)
CREATE OR REPLACE VIEW STG_DELIVERY_EVENT_LOG AS
SELECT r.doc:order_id::STRING                          AS order_id,
       e.index                                         AS event_seq,
       e.value:status::STRING                          AS status,
       TRY_TO_TIMESTAMP_NTZ(e.value:ts::STRING)        AS event_ts
FROM DASHCART.RAW.RAW_DELIVERY_EVENTS r,
     LATERAL FLATTEN(INPUT => r.doc:events) e;

-- (b) One row per order: pivot the event array into milestone timestamps
CREATE OR REPLACE VIEW STG_DELIVERIES AS
WITH flat AS (
  SELECT r.doc:order_id::STRING                        AS order_id,
         r.doc:store_id::STRING                        AS store_id,
         r.doc:promised_minutes::NUMBER                AS promised_minutes,
         r.doc:rider.rider_id::STRING                  AS rider_id,
         r.doc:rider.vehicle::STRING                   AS vehicle_type,
         r.doc:conditions.weather::STRING              AS weather,
         r.doc:conditions.distance_km::FLOAT           AS distance_km,
         e.value:status::STRING                        AS status,
         TRY_TO_TIMESTAMP_NTZ(e.value:ts::STRING)      AS ts,
         r._loaded_at
  FROM DASHCART.RAW.RAW_DELIVERY_EVENTS r,
       LATERAL FLATTEN(INPUT => r.doc:events) e
), pivoted AS (
  SELECT order_id, store_id, promised_minutes, rider_id, vehicle_type, weather, distance_km,
         MIN(IFF(status = 'PLACED',    ts, NULL))      AS placed_at,
         MIN(IFF(status = 'PACKED',    ts, NULL))      AS packed_at,
         MIN(IFF(status = 'PICKED_UP', ts, NULL))      AS picked_up_at,
         MIN(IFF(status = 'DELIVERED', ts, NULL))      AS delivered_at,
         MIN(IFF(status = 'CANCELLED', ts, NULL))      AS cancelled_at,
         MAX(_loaded_at)                               AS _loaded_at
  FROM flat
  GROUP BY order_id, store_id, promised_minutes, rider_id, vehicle_type, weather, distance_km
)
SELECT p.*,
       DATEDIFF('second', placed_at, packed_at)    / 60.0 AS pack_minutes,
       DATEDIFF('second', picked_up_at, delivered_at) / 60.0 AS ride_minutes,
       DATEDIFF('second', placed_at, delivered_at) / 60.0 AS delivery_minutes,
       IFF(delivered_at IS NOT NULL,
           DATEDIFF('second', placed_at, delivered_at) / 60.0 <= promised_minutes, NULL) AS is_on_time
FROM pivoted p
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY _loaded_at DESC) = 1;

-- ---------------------------------------------------------------------------
-- Semi-structured: clickstream
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW STG_APP_EVENTS AS
SELECT doc:event_id::STRING                            AS event_id,
       doc:session_id::STRING                          AS session_id,
       doc:customer_id::STRING                         AS customer_id,
       doc:event_type::STRING                          AS event_type,
       TRY_TO_TIMESTAMP_NTZ(doc:event_ts::STRING)      AS event_ts,
       doc:device.os::STRING                           AS device_os,
       doc:device.app_version::STRING                  AS app_version,
       doc:properties.query::STRING                    AS search_query,
       doc:properties.product_id::STRING               AS product_id,
       doc:properties                                  AS properties_raw      -- keep VARIANT for schema drift
FROM DASHCART.RAW.RAW_APP_EVENTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY doc:event_id::STRING ORDER BY _loaded_at DESC) = 1;

-- Quick checks
SELECT * FROM STG_DELIVERIES LIMIT 10;
SELECT status, COUNT(*) FROM STG_DELIVERY_EVENT_LOG GROUP BY 1 ORDER BY 2 DESC;
SELECT event_type, COUNT(*) FROM STG_APP_EVENTS GROUP BY 1 ORDER BY 2 DESC;
