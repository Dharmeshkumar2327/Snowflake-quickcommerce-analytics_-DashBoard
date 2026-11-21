/* =============================================================================
   08_data_quality_alerts.sql
   -----------------------------------------------------------------------------
   * Native DATA METRIC FUNCTIONS (system + custom) scheduled on tables
   * A rule-based DQ procedure (reconciliation, referential integrity, business
     rules) writing to a results table
   * FINALIZE task on the pipeline DAG that always runs the checks
   * ALERT that emails the team when a check fails
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_TRANSFORM_WH;
USE SCHEMA DASHCART.UTIL;

-- ===========================================================================
-- 1. Data Metric Functions (Enterprise edition)
-- ===========================================================================
-- Custom DMF: orders whose money doesn't add up
CREATE OR REPLACE DATA METRIC FUNCTION DMF_NEGATIVE_MARGIN_DELIVERED(
  t TABLE(order_status STRING, net_revenue NUMBER, gross_item_value NUMBER))
RETURNS NUMBER AS
$$
  SELECT COUNT(*) FROM t
  WHERE order_status = 'DELIVERED' AND (net_revenue < 0 OR gross_item_value <= 0)
$$;

ALTER TABLE DASHCART.CORE.FACT_ORDERS SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE DASHCART.CORE.FACT_ORDERS ADD DATA METRIC FUNCTION
  SNOWFLAKE.CORE.NULL_COUNT      ON (customer_sk),
  SNOWFLAKE.CORE.NULL_COUNT      ON (store_id),
  SNOWFLAKE.CORE.DUPLICATE_COUNT ON (order_id),
  SNOWFLAKE.CORE.FRESHNESS       ON (_updated_at),
  DASHCART.UTIL.DMF_NEGATIVE_MARGIN_DELIVERED ON (order_status, net_revenue, gross_item_value);

ALTER TABLE DASHCART.CORE.DIM_CUSTOMER SET DATA_METRIC_SCHEDULE = '60 MINUTE';
ALTER TABLE DASHCART.CORE.DIM_CUSTOMER ADD DATA METRIC FUNCTION
  SNOWFLAKE.CORE.NULL_COUNT ON (email);

-- Results land in the account-level event table view
SELECT measurement_time, table_name, metric_name, argument_names, value
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_database = 'DASHCART'
ORDER BY measurement_time DESC
LIMIT 50;

-- ===========================================================================
-- 2. Rule-based checks with a results history
-- ===========================================================================
CREATE TABLE IF NOT EXISTS DQ_RESULTS (
  run_id        STRING,
  run_ts        TIMESTAMP_LTZ,
  check_name    STRING,
  severity      STRING,          -- ERROR blocks / alerts, WARN informs
  failed_rows   NUMBER,
  passed        BOOLEAN,
  details       STRING
);

CREATE OR REPLACE PROCEDURE SP_RUN_DQ_CHECKS()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  run_id STRING DEFAULT UUID_STRING();
  n_fail INTEGER;
BEGIN
  INSERT INTO DASHCART.UTIL.DQ_RESULTS (run_id, run_ts, check_name, severity, failed_rows, passed, details)
  SELECT :run_id, CURRENT_TIMESTAMP(), check_name, severity, GREATEST(failed_rows, 0),
         failed_rows <= 0, details
  FROM (
    -- reconciliation: every staged order made it to the fact
    SELECT 'orders_reconciliation' AS check_name, 'ERROR' AS severity,
           (SELECT COUNT(*) FROM DASHCART.STAGING.STG_ORDERS) - (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDERS) AS failed_rows,
           'stg_orders minus fact_orders' AS details
    UNION ALL
    -- referential integrity
    SELECT 'fact_orders_orphan_customer', 'ERROR',
           (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDERS WHERE customer_sk IS NULL),
           'orders with no point-in-time customer version'
    UNION ALL
    SELECT 'fact_items_orphan_product', 'ERROR',
           (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDER_ITEMS i
             LEFT JOIN DASHCART.CORE.DIM_PRODUCT p ON p.product_id = i.product_id WHERE p.product_id IS NULL),
           'items whose product is missing from DIM_PRODUCT'
    UNION ALL
    -- SCD2 integrity: exactly one current row per customer, no overlapping windows
    SELECT 'scd2_single_current_version', 'ERROR',
           (SELECT COUNT(*) FROM (SELECT customer_id FROM DASHCART.CORE.DIM_CUSTOMER
                                  WHERE is_current GROUP BY 1 HAVING COUNT(*) <> 1)),
           'customers with 0 or >1 current versions'
    UNION ALL
    SELECT 'scd2_no_overlaps', 'ERROR',
           (SELECT COUNT(*) FROM (
              SELECT valid_to, LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS next_from
              FROM DASHCART.CORE.DIM_CUSTOMER) WHERE next_from IS NOT NULL AND next_from <> valid_to),
           'gaps/overlaps between consecutive versions'
    UNION ALL
    -- business rules
    SELECT 'delivered_without_delivery_time', 'WARN',
           (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDERS
             WHERE order_status = 'DELIVERED' AND delivery_minutes IS NULL),
           'delivered orders missing delivery milestones (late-arriving docs?)'
    UNION ALL
    SELECT 'implausible_delivery_minutes', 'WARN',
           (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDERS WHERE delivery_minutes < 1 OR delivery_minutes > 180),
           'delivery time outside 1-180 minutes'
    UNION ALL
    SELECT 'discount_exceeds_gmv', 'ERROR',
           (SELECT COUNT(*) FROM DASHCART.CORE.FACT_ORDERS WHERE discount_amount > gross_item_value),
           'discount larger than basket value'
    UNION ALL
    -- freshness: data should not be older than 2 days relative to load time
    SELECT 'raw_orders_freshness_hours', 'WARN',
           (SELECT DATEDIFF(HOUR, MAX(_loaded_at), CURRENT_TIMESTAMP()) FROM DASHCART.RAW.RAW_ORDERS) - 48,
           'hours beyond the 48h freshness SLA (<=0 is fine)'
  ) checks;

  SELECT COUNT(*) INTO :n_fail FROM DASHCART.UTIL.DQ_RESULTS
   WHERE run_id = :run_id AND NOT passed AND severity = 'ERROR';

  RETURN OBJECT_CONSTRUCT('run_id', run_id, 'error_checks_failed', n_fail);
END;
$$;

CALL SP_RUN_DQ_CHECKS();
SELECT * FROM DQ_RESULTS QUALIFY run_ts = MAX(run_ts) OVER () ORDER BY passed, severity;

-- ===========================================================================
-- 3. FINALIZE task: runs after every DAG run, even if a child task failed
-- ===========================================================================
ALTER TASK DASHCART.UTIL.T00_ROOT SUSPEND;

CREATE OR REPLACE TASK DASHCART.UTIL.T99_FINALIZE_DQ
  WAREHOUSE = DASHCART_TRANSFORM_WH
  FINALIZE  = DASHCART.UTIL.T00_ROOT
AS CALL DASHCART.UTIL.SP_RUN_DQ_CHECKS();

ALTER TASK DASHCART.UTIL.T99_FINALIZE_DQ RESUME;
ALTER TASK DASHCART.UTIL.T00_ROOT RESUME;

-- ===========================================================================
-- 4. Alert -> email when an ERROR-level check fails
--    (one-time, as ACCOUNTADMIN:
--     CREATE NOTIFICATION INTEGRATION DASHCART_EMAIL_INT TYPE = EMAIL ENABLED = TRUE
--       ALLOWED_RECIPIENTS = ('you@example.com');
--     GRANT USAGE ON INTEGRATION DASHCART_EMAIL_INT TO ROLE DASHCART_ENGINEER; )
-- ===========================================================================
CREATE OR REPLACE ALERT DASHCART.UTIL.ALRT_DQ_FAILURE
  WAREHOUSE = DASHCART_TRANSFORM_WH
  SCHEDULE  = '60 MINUTE'
  IF (EXISTS (
        SELECT 1 FROM DASHCART.UTIL.DQ_RESULTS
        WHERE NOT passed AND severity = 'ERROR'
          AND run_ts BETWEEN SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
                         AND SNOWFLAKE.ALERT.SCHEDULED_TIME()))
  THEN
    CALL SYSTEM$SEND_EMAIL(
      'DASHCART_EMAIL_INT',
      'you@example.com',
      'DashCart DQ failure',
      'One or more ERROR-level data quality checks failed. Query DASHCART.UTIL.DQ_RESULTS for details.');

-- ALTER ALERT DASHCART.UTIL.ALRT_DQ_FAILURE RESUME;    -- after the integration exists

-- Second alert: ops anomaly - city delivery time > 2x its 28-day average today
CREATE OR REPLACE ALERT DASHCART.UTIL.ALRT_SLA_SPIKE
  WAREHOUSE = DASHCART_TRANSFORM_WH
  SCHEDULE  = 'USING CRON 0 * * * * Asia/Kolkata'
  IF (EXISTS (
        WITH t AS (
          SELECT city, order_date, avg_delivery_minutes,
                 AVG(avg_delivery_minutes) OVER (PARTITION BY city ORDER BY order_date
                                                 ROWS BETWEEN 28 PRECEDING AND 1 PRECEDING) AS baseline
          FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS)
        SELECT 1 FROM t
        WHERE order_date = (SELECT MAX(order_date) FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS)
          AND avg_delivery_minutes > 2 * baseline))
  THEN
    CALL SYSTEM$SEND_EMAIL('DASHCART_EMAIL_INT', 'you@example.com', 'DashCart SLA spike',
                           'Average delivery time in at least one city is more than 2x its 28-day baseline.');
