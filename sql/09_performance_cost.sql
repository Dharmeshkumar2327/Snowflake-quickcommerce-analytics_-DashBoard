/* =============================================================================
   09_performance_cost.sql
   -----------------------------------------------------------------------------
   * Pruning & clustering health, search optimization for point look-ups
   * Result cache demonstration
   * Credit consumption by warehouse, by query tag, per DashCart module
   * Most expensive queries and spilling (sizing signals)
   * Storage incl. Time Travel / fail-safe bytes
   ACCOUNT_USAGE views have up to ~3h latency; requires IMPORTED PRIVILEGES
   on the SNOWFLAKE database (granted to DASHCART_ADMIN in 00_setup).
============================================================================= */

USE ROLE DASHCART_ADMIN;
USE WAREHOUSE DASHCART_BI_WH;
USE DATABASE DASHCART;
ALTER SESSION SET QUERY_TAG = '{"project":"dashcart","module":"cost_monitoring"}';

-- ---------------------------------------------------------------------------
-- 1. Clustering health on the fact table (CLUSTER BY order_date, city)
-- ---------------------------------------------------------------------------
SELECT SYSTEM$CLUSTERING_INFORMATION('DASHCART.CORE.FACT_ORDERS', '(order_date, city)');
SELECT SYSTEM$CLUSTERING_DEPTH('DASHCART.CORE.FACT_ORDERS', '(order_date)');

-- Pruning check: compare "partitions scanned" vs "partitions total" in the query profile
SELECT city, SUM(net_revenue)
FROM DASHCART.CORE.FACT_ORDERS
WHERE order_date BETWEEN '2026-10-01' AND '2026-10-31' AND city = 'Pune'
GROUP BY city;

SELECT query_id, partitions_scanned, partitions_total,
       ROUND(100 * (1 - partitions_scanned / NULLIF(partitions_total, 0)), 1) AS pruned_pct,
       bytes_scanned, total_elapsed_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_text ILIKE '%FROM DASHCART.CORE.FACT_ORDERS%city = ''Pune''%'
ORDER BY start_time DESC LIMIT 1;

-- ---------------------------------------------------------------------------
-- 2. Search Optimization for needle-in-haystack look-ups (support desk: order_id)
-- ---------------------------------------------------------------------------
ALTER TABLE DASHCART.CORE.FACT_ORDERS ADD SEARCH OPTIMIZATION ON EQUALITY(order_id, customer_id);
SELECT * FROM DASHCART.CORE.FACT_ORDERS WHERE order_id = 'ORD00042424';
SHOW TABLES LIKE 'FACT_ORDERS' IN SCHEMA DASHCART.CORE;   -- search_optimization_progress column

-- ---------------------------------------------------------------------------
-- 3. Result cache: second identical run returns in ms with 0 bytes scanned
-- ---------------------------------------------------------------------------
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
SELECT city, COUNT(*), SUM(net_revenue) FROM DASHCART.CORE.FACT_ORDERS GROUP BY city;
SELECT city, COUNT(*), SUM(net_revenue) FROM DASHCART.CORE.FACT_ORDERS GROUP BY city;   -- cached

-- ---------------------------------------------------------------------------
-- 4. Credits by warehouse, last 30 days (+ approx INR at a configurable rate)
-- ---------------------------------------------------------------------------
SET usd_per_credit = 3.0;   -- set to your contract price
SET inr_per_usd    = 84.0;

SELECT warehouse_name,
       ROUND(SUM(credits_used), 3)                                   AS credits,
       ROUND(SUM(credits_used_compute), 3)                           AS compute_credits,
       ROUND(SUM(credits_used_cloud_services), 3)                    AS cloud_services_credits,
       ROUND(SUM(credits_used) * $usd_per_credit * $inr_per_usd)     AS approx_inr
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
  AND warehouse_name LIKE 'DASHCART%'
GROUP BY warehouse_name
ORDER BY credits DESC;

-- Serverless features (tasks, DMFs, search optimization, clustering, dynamic tables...)
SELECT service_type, ROUND(SUM(credits_used), 3) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
GROUP BY service_type ORDER BY credits DESC;

-- ---------------------------------------------------------------------------
-- 5. Cost attribution per module via QUERY_TAG (set in each script / Streamlit)
-- ---------------------------------------------------------------------------
SELECT TRY_PARSE_JSON(q.query_tag):module::STRING        AS module,
       COUNT(*)                                          AS queries,
       ROUND(SUM(a.credits_attributed_compute), 4)       AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q ON q.query_id = a.query_id
WHERE a.start_time >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
  AND TRY_PARSE_JSON(q.query_tag):project::STRING = 'dashcart'
GROUP BY 1 ORDER BY credits DESC;

-- ---------------------------------------------------------------------------
-- 6. Expensive & spilling queries -> right-size warehouses / rewrite SQL
-- ---------------------------------------------------------------------------
SELECT query_id, warehouse_name, warehouse_size, user_name,
       ROUND(total_elapsed_time / 1000, 1)                AS seconds,
       ROUND(bytes_scanned / POWER(1024, 3), 2)           AS gb_scanned,
       ROUND(bytes_spilled_to_local_storage  / POWER(1024, 3), 2) AS gb_spilled_local,
       ROUND(bytes_spilled_to_remote_storage / POWER(1024, 3), 2) AS gb_spilled_remote,
       ROUND(queued_overload_time / 1000, 1)              AS seconds_queued,
       LEFT(query_text, 120)                              AS query_preview
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
  AND warehouse_name LIKE 'DASHCART%'
ORDER BY total_elapsed_time DESC
LIMIT 20;
-- Rules of thumb: remote spilling -> size up; queued_overload -> multi-cluster (BI_WH has max 3);
-- low pruned_pct on big tables -> clustering key / better filters.

-- ---------------------------------------------------------------------------
-- 7. Storage including Time Travel and Fail-safe
-- ---------------------------------------------------------------------------
SELECT table_schema, table_name,
       ROUND(active_bytes      / POWER(1024, 2), 1) AS active_mb,
       ROUND(time_travel_bytes / POWER(1024, 2), 1) AS time_travel_mb,
       ROUND(failsafe_bytes    / POWER(1024, 2), 1) AS failsafe_mb,
       ROUND(retained_for_clone_bytes / POWER(1024, 2), 1) AS clone_retained_mb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE table_catalog = 'DASHCART' AND deleted = FALSE
ORDER BY active_bytes DESC;

-- ---------------------------------------------------------------------------
-- 8. Task & dynamic-table cost/health over the last 7 days
-- ---------------------------------------------------------------------------
SELECT name, state, COUNT(*) AS runs,
       ROUND(AVG(DATEDIFF('second', query_start_time, completed_time)), 1) AS avg_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE database_name = 'DASHCART' AND scheduled_time >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
GROUP BY name, state ORDER BY name;
