/* =============================================================================
   01_ingestion_raw.sql   (BRONZE layer)
   -----------------------------------------------------------------------------
   * Reusable FILE FORMATs (gzip CSV + NDJSON)
   * Loading from the internal stage (created in 00) with directory table
   * RAW tables carrying load lineage (file name, row number, load time)
   * COPY INTO with VALIDATION_MODE dry-run, ON_ERROR handling, load-history audit
   * Semi-structured JSON landed into VARIANT
   * Snowpipe auto-ingest template for S3 (production path)
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_LOAD_WH;
USE SCHEMA DASHCART.RAW;

-- ---------------------------------------------------------------------------
-- 1. File formats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_CSV_GZ
  TYPE = CSV
  COMPRESSION = GZIP
  PARSE_HEADER = FALSE
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE;

CREATE OR REPLACE FILE FORMAT FF_JSON_GZ
  TYPE = JSON
  COMPRESSION = GZIP
  STRIP_OUTER_ARRAY = FALSE      -- files are NDJSON (one document per line)
  IGNORE_UTF8_ERRORS = TRUE;

-- ---------------------------------------------------------------------------
-- 2. Internal stage LANDING is created in 00_setup_account.sql so files can be
--    uploaded before this script runs.  Upload with SnowSQL / Snow CLI:
--      PUT file://./data/*.gz @DASHCART.RAW.LANDING/dashcart/ AUTO_COMPRESS=FALSE;
--      snow stage copy data/ @DASHCART.RAW.LANDING/dashcart/
--    or Snowsight: Data > DASHCART > RAW > Stages > LANDING > + Files
-- ---------------------------------------------------------------------------
-- After the PUT:  LIST @LANDING;   SELECT * FROM DIRECTORY(@LANDING);

-- Peek at files BEFORE loading (schema-on-read straight from the stage)
-- SELECT $1, $2, $3, METADATA$FILENAME FROM @LANDING/dashcart/orders.csv.gz (FILE_FORMAT => 'FF_CSV_GZ') LIMIT 5;
-- SELECT $1:order_id::STRING, $1:rider.vehicle::STRING FROM @LANDING/dashcart/delivery_events.json.gz (FILE_FORMAT => 'FF_JSON_GZ') LIMIT 5;

-- ---------------------------------------------------------------------------
-- 3. RAW tables  (all strings for CSV -> nothing fails on load; typing happens in STAGING)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_DARK_STORES (
  store_id STRING, store_name STRING, city STRING, zone STRING, latitude STRING, longitude STRING,
  opened_date STRING, capacity_orders_per_hour STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE TABLE RAW_PRODUCTS (
  product_id STRING, sku STRING, product_name STRING, category STRING, sub_category STRING,
  brand STRING, mrp STRING, cost_price STRING, is_perishable STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- Customers is append-only: the initial snapshot AND later change files land here.
-- A STREAM on this table feeds the SCD Type 2 dimension (see 03_core_model.sql).
CREATE OR REPLACE TABLE RAW_CUSTOMERS (
  customer_id STRING, full_name STRING, email STRING, phone STRING, city STRING, signup_date STRING,
  acquisition_channel STRING, membership_tier STRING, birth_year STRING, updated_at STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())
  CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE RAW_ORDERS (
  order_id STRING, customer_id STRING, store_id STRING, order_ts STRING, platform STRING,
  payment_method STRING, coupon_code STRING, discount_amount STRING, delivery_fee STRING, order_status STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())
  CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE RAW_ORDER_ITEMS (
  order_id STRING, line_no STRING, product_id STRING, quantity STRING, unit_price STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())
  CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE RAW_REVIEWS (
  review_id STRING, order_id STRING, customer_id STRING, rating STRING, review_text STRING, review_ts STRING,
  _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- Semi-structured: one VARIANT column per document
CREATE OR REPLACE TABLE RAW_DELIVERY_EVENTS (
  doc VARIANT, _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())
  CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE RAW_APP_EVENTS (
  doc VARIANT, _file STRING, _row NUMBER, _loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- ---------------------------------------------------------------------------
-- 4. Dry run: validate a file without loading it
-- ---------------------------------------------------------------------------
COPY INTO RAW_ORDERS (order_id, customer_id, store_id, order_ts, platform, payment_method,
                      coupon_code, discount_amount, delivery_fee, order_status)
  FROM @LANDING/dashcart/orders.csv.gz
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ')
  VALIDATION_MODE = RETURN_ERRORS;          -- empty result = file is clean

-- ---------------------------------------------------------------------------
-- 5. Load. COPY with a transformation SELECT captures lineage columns;
--    _loaded_at is filled by its column DEFAULT.
--    COPY is idempotent: files already loaded (64-day load metadata) are skipped.
-- ---------------------------------------------------------------------------
COPY INTO RAW_DARK_STORES (store_id, store_name, city, zone, latitude, longitude, opened_date, capacity_orders_per_hour, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/dark_stores.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ') ON_ERROR = ABORT_STATEMENT;

COPY INTO RAW_PRODUCTS (product_id, sku, product_name, category, sub_category, brand, mrp, cost_price, is_perishable, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/products.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ') ON_ERROR = ABORT_STATEMENT;

-- Initial customer snapshot only (the updates file is loaded later to trigger SCD2)
COPY INTO RAW_CUSTOMERS (customer_id, full_name, email, phone, city, signup_date, acquisition_channel, membership_tier, birth_year, updated_at, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/customers.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ') ON_ERROR = ABORT_STATEMENT;

COPY INTO RAW_ORDERS (order_id, customer_id, store_id, order_ts, platform, payment_method, coupon_code, discount_amount, delivery_fee, order_status, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/orders.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ')
  ON_ERROR = 'SKIP_FILE_1%';                -- tolerate <1% bad rows, otherwise skip the file

COPY INTO RAW_ORDER_ITEMS (order_id, line_no, product_id, quantity, unit_price, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/order_items.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ') ON_ERROR = 'SKIP_FILE_1%';

COPY INTO RAW_REVIEWS (review_id, order_id, customer_id, rating, review_text, review_ts, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/reviews.csv.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_CSV_GZ') ON_ERROR = CONTINUE;

COPY INTO RAW_DELIVERY_EVENTS (doc, _file, _row)
  FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/delivery_events.json.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_JSON_GZ') ON_ERROR = CONTINUE;

COPY INTO RAW_APP_EVENTS (doc, _file, _row)
  FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @LANDING/dashcart/app_events.json.gz)
  FILE_FORMAT = (FORMAT_NAME = 'FF_JSON_GZ') ON_ERROR = CONTINUE;

-- ---------------------------------------------------------------------------
-- 6. Load audit (last 24h) - rows parsed vs loaded, first error per file
-- ---------------------------------------------------------------------------
SELECT table_name, file_name, status, row_parsed, row_count AS rows_loaded,
       error_count, first_error_message, last_load_time
FROM TABLE(DASHCART.INFORMATION_SCHEMA.COPY_HISTORY(
       TABLE_NAME => 'DASHCART.RAW.RAW_ORDERS',
       START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())))
UNION ALL
SELECT table_name, file_name, status, row_parsed, row_count, error_count, first_error_message, last_load_time
FROM TABLE(DASHCART.INFORMATION_SCHEMA.COPY_HISTORY(
       TABLE_NAME => 'DASHCART.RAW.RAW_DELIVERY_EVENTS',
       START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())));

SELECT 'stores' t, COUNT(*) n FROM RAW_DARK_STORES UNION ALL
SELECT 'products', COUNT(*) FROM RAW_PRODUCTS      UNION ALL
SELECT 'customers', COUNT(*) FROM RAW_CUSTOMERS    UNION ALL
SELECT 'orders', COUNT(*) FROM RAW_ORDERS          UNION ALL
SELECT 'order_items', COUNT(*) FROM RAW_ORDER_ITEMS UNION ALL
SELECT 'reviews', COUNT(*) FROM RAW_REVIEWS        UNION ALL
SELECT 'delivery_events', COUNT(*) FROM RAW_DELIVERY_EVENTS UNION ALL
SELECT 'app_events', COUNT(*) FROM RAW_APP_EVENTS;

/* ---------------------------------------------------------------------------
   7. PRODUCTION PATH: Snowpipe auto-ingest from S3   (template - needs ACCOUNTADMIN
      for the storage integration and an AWS IAM role; not required for the demo)
------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE STORAGE INTEGRATION S3_DASHCART_INT
  TYPE = EXTERNAL_STAGE STORAGE_PROVIDER = 'S3' ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<account_id>:role/snowflake-dashcart'
  STORAGE_ALLOWED_LOCATIONS = ('s3://dashcart-landing/');
DESC INTEGRATION S3_DASHCART_INT;   -- copy STORAGE_AWS_IAM_USER_ARN + EXTERNAL_ID into the IAM trust policy
GRANT USAGE ON INTEGRATION S3_DASHCART_INT TO ROLE DASHCART_ENGINEER;

USE ROLE DASHCART_ENGINEER;
CREATE OR REPLACE STAGE DASHCART.RAW.S3_LANDING
  URL = 's3://dashcart-landing/' STORAGE_INTEGRATION = S3_DASHCART_INT
  FILE_FORMAT = DASHCART.RAW.FF_CSV_GZ;

CREATE OR REPLACE PIPE DASHCART.RAW.PIPE_ORDERS AUTO_INGEST = TRUE AS
  COPY INTO DASHCART.RAW.RAW_ORDERS (order_id, customer_id, store_id, order_ts, platform, payment_method, coupon_code, discount_amount, delivery_fee, order_status, _file, _row)
  FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @DASHCART.RAW.S3_LANDING/orders/)
  FILE_FORMAT = (FORMAT_NAME = 'DASHCART.RAW.FF_CSV_GZ') ON_ERROR = CONTINUE;

CREATE OR REPLACE PIPE DASHCART.RAW.PIPE_DELIVERY_EVENTS AUTO_INGEST = TRUE AS
  COPY INTO DASHCART.RAW.RAW_DELIVERY_EVENTS (doc, _file, _row)
  FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
        FROM @DASHCART.RAW.S3_LANDING/delivery_events/)
  FILE_FORMAT = (FORMAT_NAME = 'DASHCART.RAW.FF_JSON_GZ');

SHOW PIPES;                                   -- notification_channel = SQS ARN for the S3 event notification
SELECT SYSTEM$PIPE_STATUS('DASHCART.RAW.PIPE_ORDERS');
--------------------------------------------------------------------------- */
