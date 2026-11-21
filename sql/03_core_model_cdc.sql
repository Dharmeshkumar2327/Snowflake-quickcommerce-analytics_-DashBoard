/* =============================================================================
   03_core_model_cdc.sql   (GOLD layer - conformed star schema)
   -----------------------------------------------------------------------------
   * DIM_DATE generated with GENERATOR() + festival calendar
   * DIM_STORE / DIM_PRODUCT  (Type 1 MERGE)
   * DIM_CUSTOMER             (Type 2 SCD: stream -> transactional stored procedure)
   * FACT_ORDERS, FACT_ORDER_ITEMS  (incremental MERGE from append-only STREAMS)
   * Late-arriving delivery documents patched into FACT_ORDERS from their own stream
   * A TASK DAG (root on CRON, child tasks with AFTER, FINALIZE task for DQ)
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_TRANSFORM_WH;
USE SCHEMA DASHCART.CORE;

-- ===========================================================================
-- 1. DIM_DATE  + festival calendar
-- ===========================================================================
CREATE OR REPLACE TABLE DIM_FESTIVAL (festival_date DATE, festival_name STRING);
INSERT INTO DIM_FESTIVAL VALUES
  ('2025-03-14','Holi'), ('2025-08-15','Independence Day'), ('2025-10-20','Diwali'),
  ('2025-12-25','Christmas'), ('2025-12-31','New Year''s Eve'),
  ('2026-03-04','Holi'), ('2026-08-15','Independence Day'), ('2026-11-08','Diwali');

CREATE OR REPLACE TABLE DIM_DATE AS
WITH d AS (
  SELECT DATEADD(DAY, SEQ4(), '2024-01-01'::DATE) AS date_day
  FROM TABLE(GENERATOR(ROWCOUNT => 1461))          -- 2024-01-01 .. 2027-12-31
)
SELECT TO_NUMBER(TO_CHAR(d.date_day, 'YYYYMMDD'))  AS date_key,
       d.date_day,
       YEAR(d.date_day)                            AS year,
       QUARTER(d.date_day)                         AS quarter,
       MONTH(d.date_day)                           AS month,
       MONTHNAME(d.date_day)                       AS month_name,
       DATE_TRUNC('MONTH', d.date_day)             AS month_start,
       DATE_TRUNC('WEEK', d.date_day)              AS week_start,
       DAYOFWEEKISO(d.date_day)                    AS iso_day_of_week,
       DAYNAME(d.date_day)                         AS day_name,
       DAYOFWEEKISO(d.date_day) IN (6, 7)          AS is_weekend,
       MONTH(d.date_day) BETWEEN 6 AND 9           AS is_monsoon,
       f.festival_name,
       -- within +/- 2 days of a festival
       EXISTS (SELECT 1 FROM DIM_FESTIVAL x
               WHERE ABS(DATEDIFF(DAY, x.festival_date, d.date_day)) <= 2) AS is_festival_window,
       -- Indian financial year (Apr-Mar)
       IFF(MONTH(d.date_day) >= 4, YEAR(d.date_day), YEAR(d.date_day) - 1) AS fiscal_year
FROM d
LEFT JOIN DIM_FESTIVAL f ON f.festival_date = d.date_day;

ALTER TABLE DIM_DATE ADD PRIMARY KEY (date_key);   -- informational (not enforced) - helps BI tools & join elimination

-- ===========================================================================
-- 2. Type 1 dimensions
-- ===========================================================================
CREATE OR REPLACE TABLE DIM_STORE (
  store_id STRING PRIMARY KEY, store_name STRING, city STRING, zone STRING,
  latitude FLOAT, longitude FLOAT, opened_date DATE, capacity_orders_per_hour NUMBER,
  _updated_at TIMESTAMP_LTZ);

CREATE OR REPLACE TABLE DIM_PRODUCT (
  product_id STRING PRIMARY KEY, sku STRING, product_name STRING, category STRING, sub_category STRING,
  brand STRING, mrp NUMBER(10,2), cost_price NUMBER(10,2), is_perishable BOOLEAN, is_private_label BOOLEAN,
  _updated_at TIMESTAMP_LTZ);

CREATE OR REPLACE PROCEDURE SP_LOAD_TYPE1_DIMS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  MERGE INTO DASHCART.CORE.DIM_STORE t
  USING DASHCART.STAGING.STG_STORES s ON t.store_id = s.store_id
  WHEN MATCHED AND HASH(t.store_name, t.city, t.zone, t.capacity_orders_per_hour)
                <> HASH(s.store_name, s.city, s.zone, s.capacity_orders_per_hour) THEN UPDATE SET
       store_name = s.store_name, city = s.city, zone = s.zone, latitude = s.latitude, longitude = s.longitude,
       opened_date = s.opened_date, capacity_orders_per_hour = s.capacity_orders_per_hour,
       _updated_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT VALUES (s.store_id, s.store_name, s.city, s.zone, s.latitude, s.longitude,
       s.opened_date, s.capacity_orders_per_hour, CURRENT_TIMESTAMP());

  MERGE INTO DASHCART.CORE.DIM_PRODUCT t
  USING DASHCART.STAGING.STG_PRODUCTS s ON t.product_id = s.product_id
  WHEN MATCHED AND HASH(t.product_name, t.mrp, t.cost_price, t.category)
                <> HASH(s.product_name, s.mrp, s.cost_price, s.category) THEN UPDATE SET
       sku = s.sku, product_name = s.product_name, category = s.category, sub_category = s.sub_category,
       brand = s.brand, mrp = s.mrp, cost_price = s.cost_price, is_perishable = s.is_perishable,
       is_private_label = s.is_private_label, _updated_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT VALUES (s.product_id, s.sku, s.product_name, s.category, s.sub_category, s.brand,
       s.mrp, s.cost_price, s.is_perishable, s.is_private_label, CURRENT_TIMESTAMP());
  RETURN 'type1 dims merged';
END;
$$;

-- ===========================================================================
-- 3. DIM_CUSTOMER - Slowly Changing Dimension Type 2
-- ===========================================================================
CREATE OR REPLACE SEQUENCE SEQ_CUSTOMER_SK START = 1 INCREMENT = 1;

CREATE OR REPLACE TABLE DIM_CUSTOMER (
  customer_sk         NUMBER DEFAULT DASHCART.CORE.SEQ_CUSTOMER_SK.NEXTVAL PRIMARY KEY,
  customer_id         STRING NOT NULL,
  full_name           STRING,
  email               STRING,
  phone               STRING,
  city                STRING,
  signup_date         DATE,
  acquisition_channel STRING,
  membership_tier     STRING,
  birth_year          NUMBER,
  row_hash            STRING,
  valid_from          TIMESTAMP_NTZ,
  valid_to            TIMESTAMP_NTZ,
  is_current          BOOLEAN,
  _loaded_at          TIMESTAMP_LTZ
);

-- Work table used inside the SCD2 transaction (DML-only, so the stream is consumed atomically)
CREATE OR REPLACE TABLE DASHCART.UTIL.WRK_CUSTOMER_CHANGES LIKE DIM_CUSTOMER;

-- Stream on the append-only raw table. SHOW_INITIAL_ROWS returns the rows that were
-- already loaded by 01_ingestion_raw.sql the first time the stream is consumed.
CREATE OR REPLACE STREAM DASHCART.RAW.STR_RAW_CUSTOMERS
  ON TABLE DASHCART.RAW.RAW_CUSTOMERS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;

CREATE OR REPLACE PROCEDURE SP_LOAD_DIM_CUSTOMER_SCD2()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  n_changes  INTEGER DEFAULT 0;
  n_expired  INTEGER DEFAULT 0;
  n_inserted INTEGER DEFAULT 0;
BEGIN
  BEGIN TRANSACTION;

  DELETE FROM DASHCART.UTIL.WRK_CUSTOMER_CHANGES;

  -- (1) latest change per customer from the stream, typed + hashed
  INSERT INTO DASHCART.UTIL.WRK_CUSTOMER_CHANGES
        (customer_sk, customer_id, full_name, email, phone, city, signup_date, acquisition_channel,
         membership_tier, birth_year, row_hash, valid_from, valid_to, is_current, _loaded_at)
  SELECT NULL, customer_id, full_name, LOWER(email), phone, INITCAP(city), TRY_TO_DATE(signup_date),
         acquisition_channel, membership_tier, TRY_TO_NUMBER(birth_year),
         SHA2(CONCAT_WS('|', COALESCE(full_name,''), COALESCE(LOWER(email),''), COALESCE(phone,''),
                        COALESCE(INITCAP(city),''), COALESCE(membership_tier,''), COALESCE(acquisition_channel,'')), 256),
         TRY_TO_TIMESTAMP_NTZ(updated_at), '9999-12-31'::TIMESTAMP_NTZ, TRUE, CURRENT_TIMESTAMP()
  FROM DASHCART.RAW.STR_RAW_CUSTOMERS
  WHERE METADATA$ACTION = 'INSERT'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id
                             ORDER BY TRY_TO_TIMESTAMP_NTZ(updated_at) DESC, _loaded_at DESC) = 1;
  n_changes := SQLROWCOUNT;

  -- (2) close the current version when tracked attributes changed
  UPDATE DASHCART.CORE.DIM_CUSTOMER d
     SET valid_to = w.valid_from, is_current = FALSE
    FROM DASHCART.UTIL.WRK_CUSTOMER_CHANGES w
   WHERE d.customer_id = w.customer_id
     AND d.is_current
     AND d.row_hash <> w.row_hash
     AND w.valid_from > d.valid_from;
  n_expired := SQLROWCOUNT;

  -- (3) insert a new current version for brand-new or just-expired customers.
  --     First version of a customer is valid from the signup date so that
  --     point-in-time joins cover every order.
  INSERT INTO DASHCART.CORE.DIM_CUSTOMER
        (customer_id, full_name, email, phone, city, signup_date, acquisition_channel,
         membership_tier, birth_year, row_hash, valid_from, valid_to, is_current, _loaded_at)
  SELECT w.customer_id, w.full_name, w.email, w.phone, w.city, w.signup_date, w.acquisition_channel,
         w.membership_tier, w.birth_year, w.row_hash,
         IFF(h.customer_id IS NULL, w.signup_date::TIMESTAMP_NTZ, w.valid_from),
         w.valid_to, TRUE, w._loaded_at
  FROM DASHCART.UTIL.WRK_CUSTOMER_CHANGES w
  LEFT JOIN DASHCART.CORE.DIM_CUSTOMER c                       -- still has a current row => unchanged
         ON c.customer_id = w.customer_id AND c.is_current
  LEFT JOIN (SELECT DISTINCT customer_id FROM DASHCART.CORE.DIM_CUSTOMER) h   -- any history at all
         ON h.customer_id = w.customer_id
  WHERE c.customer_id IS NULL;
  n_inserted := SQLROWCOUNT;

  COMMIT;
  RETURN OBJECT_CONSTRUCT('changes_in_stream', n_changes, 'versions_expired', n_expired,
                          'versions_inserted', n_inserted);
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;

-- ===========================================================================
-- 4. Facts
-- ===========================================================================
CREATE OR REPLACE TABLE FACT_ORDERS (
  order_id             STRING PRIMARY KEY,
  order_ts             TIMESTAMP_NTZ,
  order_date           DATE,
  date_key             NUMBER,
  order_hour           NUMBER,
  customer_id          STRING,
  customer_sk          NUMBER,          -- point-in-time SCD2 key
  store_id             STRING,
  city                 STRING,
  platform             STRING,
  payment_method       STRING,
  coupon_code          STRING,
  order_status         STRING,
  line_count           NUMBER,
  units                NUMBER,
  gross_item_value     NUMBER(12,2),    -- GMV (sum of line amounts)
  discount_amount      NUMBER(12,2),
  delivery_fee         NUMBER(12,2),
  net_revenue          NUMBER(12,2),    -- GMV - discount + delivery fee (0 if cancelled)
  cogs                 NUMBER(12,2),
  contribution_margin  NUMBER(12,2),
  promised_minutes     NUMBER,
  delivery_minutes     FLOAT,
  pack_minutes         FLOAT,
  ride_minutes         FLOAT,
  is_on_time           BOOLEAN,
  rider_id             STRING,
  vehicle_type         STRING,
  weather              STRING,
  distance_km          FLOAT,
  _inserted_at         TIMESTAMP_LTZ,
  _updated_at          TIMESTAMP_LTZ
)
CLUSTER BY (order_date, city);      -- prunes micro-partitions for date + city filters at scale

CREATE OR REPLACE TABLE FACT_ORDER_ITEMS (
  order_id STRING, line_no NUMBER, product_id STRING, order_date DATE,
  quantity NUMBER, unit_price NUMBER(10,2), line_amount NUMBER(12,2),
  unit_cost NUMBER(10,2), line_cogs NUMBER(12,2),
  _inserted_at TIMESTAMP_LTZ,
  PRIMARY KEY (order_id, line_no)
);

CREATE OR REPLACE STREAM DASHCART.RAW.STR_RAW_ORDERS
  ON TABLE DASHCART.RAW.RAW_ORDERS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE OR REPLACE STREAM DASHCART.RAW.STR_RAW_ORDER_ITEMS
  ON TABLE DASHCART.RAW.RAW_ORDER_ITEMS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE OR REPLACE STREAM DASHCART.RAW.STR_RAW_DELIVERY_EVENTS
  ON TABLE DASHCART.RAW.RAW_DELIVERY_EVENTS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;

-- 4a. Order items (incremental)
CREATE OR REPLACE PROCEDURE SP_LOAD_FACT_ORDER_ITEMS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  MERGE INTO DASHCART.CORE.FACT_ORDER_ITEMS t
  USING (
    SELECT s.order_id, TRY_TO_NUMBER(s.line_no) AS line_no, s.product_id,
           o.order_date,
           TRY_TO_NUMBER(s.quantity) AS quantity,
           TRY_TO_NUMBER(s.unit_price, 10, 2) AS unit_price,
           TRY_TO_NUMBER(s.quantity) * TRY_TO_NUMBER(s.unit_price, 10, 2) AS line_amount,
           p.cost_price AS unit_cost,
           TRY_TO_NUMBER(s.quantity) * p.cost_price AS line_cogs
    FROM DASHCART.RAW.STR_RAW_ORDER_ITEMS s
    LEFT JOIN DASHCART.STAGING.STG_ORDERS   o ON o.order_id = s.order_id
    LEFT JOIN DASHCART.CORE.DIM_PRODUCT     p ON p.product_id = s.product_id
    WHERE s.METADATA$ACTION = 'INSERT'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.order_id, s.line_no ORDER BY s._loaded_at DESC) = 1
  ) src
  ON t.order_id = src.order_id AND t.line_no = src.line_no
  WHEN MATCHED THEN UPDATE SET product_id = src.product_id, quantity = src.quantity, unit_price = src.unit_price,
       line_amount = src.line_amount, unit_cost = src.unit_cost, line_cogs = src.line_cogs
  WHEN NOT MATCHED THEN INSERT (order_id, line_no, product_id, order_date, quantity, unit_price, line_amount,
       unit_cost, line_cogs, _inserted_at)
       VALUES (src.order_id, src.line_no, src.product_id, src.order_date, src.quantity, src.unit_price,
       src.line_amount, src.unit_cost, src.line_cogs, CURRENT_TIMESTAMP());
  RETURN 'fact_order_items: ' || SQLROWCOUNT || ' rows merged';
END;
$$;

-- 4b. Orders (incremental, point-in-time customer key, enriched with delivery milestones)
CREATE OR REPLACE PROCEDURE SP_LOAD_FACT_ORDERS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  MERGE INTO DASHCART.CORE.FACT_ORDERS t
  USING (
    WITH new_orders AS (
      SELECT order_id, customer_id, store_id,
             TRY_TO_TIMESTAMP_NTZ(order_ts) AS order_ts, LOWER(platform) AS platform, payment_method,
             NULLIF(coupon_code, '') AS coupon_code,
             COALESCE(TRY_TO_NUMBER(discount_amount, 10, 2), 0) AS discount_amount,
             COALESCE(TRY_TO_NUMBER(delivery_fee, 10, 2), 0)    AS delivery_fee,
             UPPER(order_status) AS order_status
      FROM DASHCART.RAW.STR_RAW_ORDERS
      WHERE METADATA$ACTION = 'INSERT'
      QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY _loaded_at DESC, _row DESC) = 1
    ),
    items AS (
      SELECT i.order_id, COUNT(*) AS line_count, SUM(i.quantity) AS units,
             SUM(i.line_amount) AS gmv, SUM(i.quantity * p.cost_price) AS cogs
      FROM DASHCART.STAGING.STG_ORDER_ITEMS i
      JOIN DASHCART.CORE.DIM_PRODUCT p ON p.product_id = i.product_id
      WHERE i.order_id IN (SELECT order_id FROM new_orders)
      GROUP BY i.order_id
    )
    SELECT o.*, TO_DATE(o.order_ts) AS order_date,
           TO_NUMBER(TO_CHAR(o.order_ts, 'YYYYMMDD')) AS date_key, HOUR(o.order_ts) AS order_hour,
           c.customer_sk, st.city,
           i.line_count, i.units, i.gmv, i.cogs,
           IFF(o.order_status = 'DELIVERED', i.gmv - o.discount_amount + o.delivery_fee, 0) AS net_revenue,
           IFF(o.order_status = 'DELIVERED', i.gmv - o.discount_amount + o.delivery_fee - i.cogs, 0) AS contribution_margin,
           d.promised_minutes, d.delivery_minutes, d.pack_minutes, d.ride_minutes, d.is_on_time,
           d.rider_id, d.vehicle_type, d.weather, d.distance_km
    FROM new_orders o
    LEFT JOIN items i                         ON i.order_id = o.order_id
    LEFT JOIN DASHCART.CORE.DIM_STORE st      ON st.store_id = o.store_id
    LEFT JOIN DASHCART.STAGING.STG_DELIVERIES d ON d.order_id = o.order_id
    LEFT JOIN DASHCART.CORE.DIM_CUSTOMER c    -- SCD2 point-in-time lookup
           ON c.customer_id = o.customer_id
          AND o.order_ts >= c.valid_from AND o.order_ts < c.valid_to
  ) s
  ON t.order_id = s.order_id
  WHEN MATCHED THEN UPDATE SET
       order_status = s.order_status, discount_amount = s.discount_amount, delivery_fee = s.delivery_fee,
       line_count = s.line_count, units = s.units, gross_item_value = s.gmv, cogs = s.cogs,
       net_revenue = s.net_revenue, contribution_margin = s.contribution_margin,
       promised_minutes = s.promised_minutes, delivery_minutes = s.delivery_minutes,
       pack_minutes = s.pack_minutes, ride_minutes = s.ride_minutes, is_on_time = s.is_on_time,
       _updated_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
       order_id, order_ts, order_date, date_key, order_hour, customer_id, customer_sk, store_id, city,
       platform, payment_method, coupon_code, order_status, line_count, units, gross_item_value,
       discount_amount, delivery_fee, net_revenue, cogs, contribution_margin, promised_minutes,
       delivery_minutes, pack_minutes, ride_minutes, is_on_time, rider_id, vehicle_type, weather,
       distance_km, _inserted_at, _updated_at)
  VALUES (
       s.order_id, s.order_ts, s.order_date, s.date_key, s.order_hour, s.customer_id, s.customer_sk, s.store_id,
       s.city, s.platform, s.payment_method, s.coupon_code, s.order_status, s.line_count, s.units, s.gmv,
       s.discount_amount, s.delivery_fee, s.net_revenue, s.cogs, s.contribution_margin, s.promised_minutes,
       s.delivery_minutes, s.pack_minutes, s.ride_minutes, s.is_on_time, s.rider_id, s.vehicle_type, s.weather,
       s.distance_km, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
  RETURN 'fact_orders: ' || SQLROWCOUNT || ' rows merged';
END;
$$;

-- 4c. Late-arriving delivery documents: patch milestones onto orders already in the fact
CREATE OR REPLACE PROCEDURE SP_PATCH_LATE_DELIVERIES()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  UPDATE DASHCART.CORE.FACT_ORDERS f
     SET promised_minutes = d.promised_minutes,
         delivery_minutes = d.delivery_minutes,
         is_on_time       = d.delivery_minutes <= d.promised_minutes,
         rider_id = d.rider_id, vehicle_type = d.vehicle_type, weather = d.weather, distance_km = d.distance_km,
         _updated_at = CURRENT_TIMESTAMP()
    FROM (
      SELECT s.doc:order_id::STRING AS order_id,
             s.doc:promised_minutes::NUMBER AS promised_minutes,
             s.doc:rider.rider_id::STRING AS rider_id,
             s.doc:rider.vehicle::STRING AS vehicle_type,
             s.doc:conditions.weather::STRING AS weather,
             s.doc:conditions.distance_km::FLOAT AS distance_km,
             DATEDIFF('second',
                MIN(IFF(e.value:status::STRING = 'PLACED',    TRY_TO_TIMESTAMP_NTZ(e.value:ts::STRING), NULL)),
                MIN(IFF(e.value:status::STRING = 'DELIVERED', TRY_TO_TIMESTAMP_NTZ(e.value:ts::STRING), NULL))
             ) / 60.0 AS delivery_minutes
      FROM DASHCART.RAW.STR_RAW_DELIVERY_EVENTS s,
           LATERAL FLATTEN(INPUT => s.doc:events) e
      WHERE s.METADATA$ACTION = 'INSERT'
      GROUP BY 1, 2, 3, 4, 5, 6
    ) d
   WHERE f.order_id = d.order_id
     AND (f.delivery_minutes IS NULL OR f.delivery_minutes <> d.delivery_minutes);
  RETURN 'late deliveries patched: ' || SQLROWCOUNT;
END;
$$;

-- ===========================================================================
-- 5. Orchestration - Task DAG
--
--   T00_ROOT (hourly CRON, only when any stream has data)
--     ├── T10_TYPE1_DIMS
--     │     ├── T20_DIM_CUSTOMER_SCD2 ──┐
--     │     └── T30_FACT_ORDER_ITEMS ───┼── T40_FACT_ORDERS ── T50_PATCH_LATE_DELIVERIES
--     └─────────────────────────────────┘
--   T99_FINALIZE_DQ  (FINALIZE task: always runs after the graph, success or failure)
-- ===========================================================================
CREATE OR REPLACE TASK DASHCART.UTIL.T00_ROOT
  WAREHOUSE = DASHCART_TRANSFORM_WH
  SCHEDULE  = 'USING CRON 5 * * * * Asia/Kolkata'
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  USER_TASK_TIMEOUT_MS = 1800000
  COMMENT = 'DashCart hourly incremental pipeline'
  WHEN SYSTEM$STREAM_HAS_DATA('DASHCART.RAW.STR_RAW_ORDERS')
    OR SYSTEM$STREAM_HAS_DATA('DASHCART.RAW.STR_RAW_CUSTOMERS')
    OR SYSTEM$STREAM_HAS_DATA('DASHCART.RAW.STR_RAW_ORDER_ITEMS')
    OR SYSTEM$STREAM_HAS_DATA('DASHCART.RAW.STR_RAW_DELIVERY_EVENTS')
AS
  SELECT SYSTEM$SET_RETURN_VALUE('run started ' || CURRENT_TIMESTAMP()::STRING);

CREATE OR REPLACE TASK DASHCART.UTIL.T10_TYPE1_DIMS
  WAREHOUSE = DASHCART_TRANSFORM_WH AFTER DASHCART.UTIL.T00_ROOT
AS CALL DASHCART.CORE.SP_LOAD_TYPE1_DIMS();

CREATE OR REPLACE TASK DASHCART.UTIL.T20_DIM_CUSTOMER_SCD2
  WAREHOUSE = DASHCART_TRANSFORM_WH AFTER DASHCART.UTIL.T10_TYPE1_DIMS
AS CALL DASHCART.CORE.SP_LOAD_DIM_CUSTOMER_SCD2();

CREATE OR REPLACE TASK DASHCART.UTIL.T30_FACT_ORDER_ITEMS
  WAREHOUSE = DASHCART_TRANSFORM_WH AFTER DASHCART.UTIL.T10_TYPE1_DIMS
AS CALL DASHCART.CORE.SP_LOAD_FACT_ORDER_ITEMS();

CREATE OR REPLACE TASK DASHCART.UTIL.T40_FACT_ORDERS
  WAREHOUSE = DASHCART_TRANSFORM_WH
  AFTER DASHCART.UTIL.T20_DIM_CUSTOMER_SCD2, DASHCART.UTIL.T30_FACT_ORDER_ITEMS
AS CALL DASHCART.CORE.SP_LOAD_FACT_ORDERS();

CREATE OR REPLACE TASK DASHCART.UTIL.T50_PATCH_LATE_DELIVERIES
  WAREHOUSE = DASHCART_TRANSFORM_WH AFTER DASHCART.UTIL.T40_FACT_ORDERS
AS CALL DASHCART.CORE.SP_PATCH_LATE_DELIVERIES();

-- T99_FINALIZE_DQ is created in 08_data_quality.sql (needs the DQ procedure).

-- First backfill: run the steps synchronously BEFORE resuming the schedule
-- (alternative: resume first, then EXECUTE TASK and watch TASK_HISTORY):
--   EXECUTE TASK DASHCART.UTIL.T00_ROOT;
CALL DASHCART.CORE.SP_LOAD_TYPE1_DIMS();
CALL DASHCART.CORE.SP_LOAD_DIM_CUSTOMER_SCD2();
CALL DASHCART.CORE.SP_LOAD_FACT_ORDER_ITEMS();
CALL DASHCART.CORE.SP_LOAD_FACT_ORDERS();
CALL DASHCART.CORE.SP_PATCH_LATE_DELIVERIES();
SELECT COUNT(*) AS fact_orders FROM DASHCART.CORE.FACT_ORDERS;   -- expect 89,797


-- Resume children first, root last
ALTER TASK DASHCART.UTIL.T50_PATCH_LATE_DELIVERIES RESUME;
ALTER TASK DASHCART.UTIL.T40_FACT_ORDERS           RESUME;
ALTER TASK DASHCART.UTIL.T30_FACT_ORDER_ITEMS      RESUME;
ALTER TASK DASHCART.UTIL.T20_DIM_CUSTOMER_SCD2     RESUME;
ALTER TASK DASHCART.UTIL.T10_TYPE1_DIMS            RESUME;
ALTER TASK DASHCART.UTIL.T00_ROOT                  RESUME;

-- Monitor the graph
SELECT name, state, scheduled_time, completed_time, return_value, error_message
FROM TABLE(DASHCART.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -2, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

/* ---------------------------------------------------------------------------
   SCD2 DEMO - run after the first pipeline run has completed
------------------------------------------------------------------------------
-- 1. Land the change file (720 customers move city or switch tier)
COPY INTO DASHCART.RAW.RAW_CUSTOMERS (customer_id, full_name, email, phone, city, signup_date, acquisition_channel, membership_tier, birth_year, updated_at, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @DASHCART.RAW.LANDING/dashcart/customer_updates.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'DASHCART.RAW.FF_CSV_GZ');

-- 2. Trigger the DAG (or wait for the next hour)
EXECUTE TASK DASHCART.UTIL.T00_ROOT;

-- 3. Inspect history: customers with more than one version
SELECT customer_id, customer_sk, city, membership_tier, valid_from, valid_to, is_current
FROM DASHCART.CORE.DIM_CUSTOMER
QUALIFY COUNT(*) OVER (PARTITION BY customer_id) > 1
ORDER BY customer_id, valid_from
LIMIT 20;
--------------------------------------------------------------------------- */
