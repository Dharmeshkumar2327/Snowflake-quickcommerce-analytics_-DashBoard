/* =============================================================================
   06_cortex_ml_ai.sql
   -----------------------------------------------------------------------------
   In-database ML & GenAI - no data leaves Snowflake.
   A. SNOWFLAKE.ML.FORECAST           30-day order forecast per city (multi-series)
   B. SNOWFLAKE.ML.ANOMALY_DETECTION  flags abnormal ops days (Bengaluru strike)
   C. SNOWFLAKE.ML.CLASSIFICATION     churn propensity model + feature importance
   D. Cortex AI SQL functions         sentiment, complaint classification,
                                      LLM-written weekly store summaries
   Requires a Cortex-enabled region (or cross-region inference enabled).
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE WAREHOUSE DASHCART_ML_WH;
USE SCHEMA DASHCART.ML;

-- ===========================================================================
-- A. Demand forecasting
-- ===========================================================================
CREATE OR REPLACE VIEW V_DAILY_ORDERS_CITY AS
SELECT city, order_date::TIMESTAMP_NTZ AS ts, orders::FLOAT AS orders
FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS;

CREATE OR REPLACE SNOWFLAKE.ML.FORECAST ORDERS_FORECAST_MODEL(
  INPUT_DATA        => TABLE(V_DAILY_ORDERS_CITY),
  SERIES_COLNAME    => 'CITY',
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME    => 'ORDERS',
  CONFIG_OBJECT     => {'on_error': 'skip'}
);

CALL ORDERS_FORECAST_MODEL!FORECAST(
  FORECASTING_PERIODS => 30,
  CONFIG_OBJECT       => {'prediction_interval': 0.9}
);
CREATE OR REPLACE TABLE ORDERS_FORECAST AS
SELECT REPLACE(series::STRING, '"', '') AS city, ts::DATE AS forecast_date,
       ROUND(forecast) AS forecast_orders, ROUND(lower_bound) AS lower_90, ROUND(upper_bound) AS upper_90,
       CURRENT_TIMESTAMP() AS generated_at
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

CALL ORDERS_FORECAST_MODEL!SHOW_EVALUATION_METRICS();     -- MAE / MAPE / SMAPE per series
CALL ORDERS_FORECAST_MODEL!EXPLAIN_FEATURE_IMPORTANCE();  -- trend vs weekly seasonality vs lags

-- Forecast vs actual-history in one series (for the Streamlit chart)
CREATE OR REPLACE VIEW V_FORECAST_VS_ACTUAL AS
SELECT city, ts::DATE AS d, orders AS actual, NULL AS forecast, NULL AS lower_90, NULL AS upper_90
FROM V_DAILY_ORDERS_CITY WHERE ts >= DATEADD(DAY, -90, (SELECT MAX(ts) FROM V_DAILY_ORDERS_CITY))
UNION ALL
SELECT city, forecast_date, NULL, forecast_orders, lower_90, upper_90 FROM ORDERS_FORECAST;

-- ===========================================================================
-- B. Operational anomaly detection (unsupervised)
--    Train on Jan-2025..Jan-2026, then score Feb-2026 onward.
-- ===========================================================================
CREATE OR REPLACE VIEW V_OPS_DAILY AS
SELECT city, order_date::TIMESTAMP_NTZ AS ts,
       avg_delivery_minutes::FLOAT AS avg_delivery_minutes
FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS;          -- extra columns would be treated as exogenous features

CREATE OR REPLACE VIEW V_OPS_TRAIN  AS SELECT * FROM V_OPS_DAILY WHERE ts <  '2026-02-01';
CREATE OR REPLACE VIEW V_OPS_SCORE  AS SELECT * FROM V_OPS_DAILY WHERE ts >= '2026-02-01';

CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION DELIVERY_TIME_ANOMALY_MODEL(
  INPUT_DATA        => TABLE(V_OPS_TRAIN),
  SERIES_COLNAME    => 'CITY',
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME    => 'AVG_DELIVERY_MINUTES',
  LABEL_COLNAME     => ''
);

CALL DELIVERY_TIME_ANOMALY_MODEL!DETECT_ANOMALIES(
  INPUT_DATA        => TABLE(V_OPS_SCORE),
  SERIES_COLNAME    => 'CITY',
  TIMESTAMP_COLNAME => 'TS',
  TARGET_COLNAME    => 'AVG_DELIVERY_MINUTES',
  CONFIG_OBJECT     => {'prediction_interval': 0.99}
);
CREATE OR REPLACE TABLE OPS_ANOMALIES AS
SELECT REPLACE(series::STRING, '"', '') AS city, ts::DATE AS anomaly_date, y AS avg_delivery_minutes,
       forecast AS expected_minutes, lower_bound, upper_bound, is_anomaly, percentile, distance,
       CURRENT_TIMESTAMP() AS detected_at
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Expect: Bengaluru 2026-03-12 (rider strike) at the top
SELECT city, anomaly_date, ROUND(avg_delivery_minutes, 1) AS actual_min,
       ROUND(expected_minutes, 1) AS expected_min, ROUND(distance, 2) AS distance
FROM OPS_ANOMALIES WHERE is_anomaly ORDER BY distance DESC LIMIT 10;

-- ===========================================================================
-- C. Churn propensity (supervised classification)
--    Label: customer active before the cut-off has NO order in the 60 days after it.
--    Features are computed strictly BEFORE the cut-off (no leakage).
-- ===========================================================================
SET cutoff = '2026-09-01'::DATE;

CREATE OR REPLACE TABLE CHURN_TRAINING AS
WITH hist AS (
  SELECT o.customer_id,
         ANY_VALUE(o.membership_tier)                                   AS membership_tier,
         ANY_VALUE(o.acquisition_channel)                               AS acquisition_channel,
         ANY_VALUE(o.city)                                              AS city,
         DATEDIFF(DAY, MAX(o.order_date), $cutoff)                      AS recency_days,
         DATEDIFF(DAY, MIN(o.order_date), $cutoff)                      AS tenure_days,
         COUNT(*)                                                       AS orders_total,
         COUNT_IF(o.order_date >= DATEADD(DAY, -30, $cutoff))           AS orders_last_30d,
         COUNT_IF(o.order_date >= DATEADD(DAY, -90, $cutoff))           AS orders_last_90d,
         AVG(o.gross_item_value)                                        AS avg_basket,
         SUM(o.net_revenue)                                             AS revenue_total,
         AVG(IFF(o.is_on_time, 0, 1))                                   AS late_rate,
         AVG(IFF(o.order_status = 'CANCELLED', 1, 0))                   AS cancel_rate,
         AVG(IFF(o.coupon_code IS NOT NULL, 1, 0))                      AS coupon_rate,
         MAX(o.delivery_minutes)                                        AS worst_delivery_minutes
  FROM DASHCART.MARTS.DT_ORDERS_ENRICHED o
  WHERE o.order_date < $cutoff
  GROUP BY o.customer_id
  HAVING DATEDIFF(DAY, MAX(o.order_date), $cutoff) <= 90         -- only customers still "in play"
), future AS (
  SELECT DISTINCT customer_id FROM DASHCART.MARTS.DT_ORDERS_ENRICHED
  WHERE order_date >= $cutoff AND order_date < DATEADD(DAY, 60, $cutoff)
)
SELECT h.*, IFF(f.customer_id IS NULL, 'churned', 'active') AS churn_label
FROM hist h LEFT JOIN future f USING (customer_id);

SELECT churn_label, COUNT(*) FROM CHURN_TRAINING GROUP BY 1;   -- class balance

CREATE OR REPLACE VIEW V_CHURN_TRAIN AS SELECT * EXCLUDE (customer_id) FROM CHURN_TRAINING;

CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION CHURN_MODEL(
  INPUT_DATA     => TABLE(V_CHURN_TRAIN),
  TARGET_COLNAME => 'CHURN_LABEL',
  CONFIG_OBJECT  => {'evaluate': TRUE, 'on_error': 'skip'}
);

CALL CHURN_MODEL!SHOW_EVALUATION_METRICS();         -- precision / recall / f1 per class
CALL CHURN_MODEL!SHOW_GLOBAL_EVALUATION_METRICS();  -- AUC, log loss
CALL CHURN_MODEL!SHOW_FEATURE_IMPORTANCE();         -- expect recency + orders_last_30d on top
CALL CHURN_MODEL!SHOW_CONFUSION_MATRIX();

-- Score today's active customers with features as of the latest data date
CREATE OR REPLACE TABLE CHURN_SCORES AS
WITH as_of AS (SELECT MAX(order_date) AS d FROM DASHCART.MARTS.DT_ORDERS_ENRICHED),
feat AS (
  SELECT o.customer_id,
         ANY_VALUE(o.membership_tier) AS membership_tier, ANY_VALUE(o.acquisition_channel) AS acquisition_channel,
         ANY_VALUE(o.city) AS city,
         DATEDIFF(DAY, MAX(o.order_date), ANY_VALUE(a.d)) AS recency_days,
         DATEDIFF(DAY, MIN(o.order_date), ANY_VALUE(a.d)) AS tenure_days,
         COUNT(*) AS orders_total,
         COUNT_IF(o.order_date >= DATEADD(DAY, -30, ANY_VALUE(a.d))) AS orders_last_30d,
         COUNT_IF(o.order_date >= DATEADD(DAY, -90, ANY_VALUE(a.d))) AS orders_last_90d,
         AVG(o.gross_item_value) AS avg_basket, SUM(o.net_revenue) AS revenue_total,
         AVG(IFF(o.is_on_time, 0, 1)) AS late_rate, AVG(IFF(o.order_status = 'CANCELLED', 1, 0)) AS cancel_rate,
         AVG(IFF(o.coupon_code IS NOT NULL, 1, 0)) AS coupon_rate, MAX(o.delivery_minutes) AS worst_delivery_minutes
  FROM DASHCART.MARTS.DT_ORDERS_ENRICHED o CROSS JOIN as_of a
  GROUP BY o.customer_id
  HAVING DATEDIFF(DAY, MAX(o.order_date), ANY_VALUE(a.d)) <= 90
)
SELECT customer_id, membership_tier, city, recency_days, orders_last_30d, revenue_total,
       pred:class::STRING = 'churned'                 AS predicted_churn,
       ROUND(pred:probability:churned::FLOAT, 4)      AS churn_probability,
       CASE WHEN pred:probability:churned::FLOAT >= 0.7 THEN 'High'
            WHEN pred:probability:churned::FLOAT >= 0.4 THEN 'Medium' ELSE 'Low' END AS risk_band
FROM (SELECT f.*, CHURN_MODEL!PREDICT(INPUT_DATA => OBJECT_DELETE(OBJECT_CONSTRUCT(*), 'CUSTOMER_ID')) AS pred
      FROM feat f);

-- Revenue at risk by band - the retention team's call list
SELECT risk_band, COUNT(*) AS customers, ROUND(SUM(revenue_total)) AS historical_revenue_at_risk
FROM CHURN_SCORES GROUP BY 1 ORDER BY 1;

-- ===========================================================================
-- D. Cortex AI on customer reviews
-- ===========================================================================
CREATE OR REPLACE TABLE REVIEWS_ENRICHED AS
SELECT r.review_id, r.order_id, r.customer_id, r.rating, r.review_text, r.review_ts,
       f.store_id, f.city, f.delivery_minutes, f.is_on_time,
       SNOWFLAKE.CORTEX.SENTIMENT(r.review_text)                         AS sentiment_score,   -- -1 .. 1
       SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
         r.review_text,
         ['Late delivery', 'Product quality / freshness', 'Wrong or missing item',
          'Packaging / damage', 'App or payment issue', 'Positive experience'])['label']::STRING AS complaint_theme
FROM DASHCART.STAGING.STG_REVIEWS r
LEFT JOIN DASHCART.CORE.FACT_ORDERS f ON f.order_id = r.order_id;

-- Does sentiment agree with the star rating? Does lateness hurt sentiment?
SELECT rating, COUNT(*) AS reviews, ROUND(AVG(sentiment_score), 3) AS avg_sentiment
FROM REVIEWS_ENRICHED GROUP BY rating ORDER BY rating;

SELECT is_on_time, ROUND(AVG(sentiment_score), 3) AS avg_sentiment, ROUND(AVG(rating), 2) AS avg_rating
FROM REVIEWS_ENRICHED WHERE is_on_time IS NOT NULL GROUP BY 1;

SELECT city, complaint_theme, COUNT(*) AS n,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY city), 1) AS pct_of_city
FROM REVIEWS_ENRICHED WHERE complaint_theme <> 'Positive experience'
GROUP BY 1, 2 QUALIFY ROW_NUMBER() OVER (PARTITION BY city ORDER BY n DESC) <= 2
ORDER BY city, n DESC;

-- LLM-written weekly brief for each store manager (last 4 weeks of negative reviews)
CREATE OR REPLACE TABLE STORE_REVIEW_BRIEFS AS
WITH neg AS (
  SELECT store_id, city,
         LISTAGG(review_text, ' | ') WITHIN GROUP (ORDER BY review_ts DESC) AS texts,
         COUNT(*) AS n_negative, ROUND(AVG(delivery_minutes), 1) AS avg_minutes
  FROM REVIEWS_ENRICHED
  WHERE sentiment_score < -0.2
    AND review_ts >= DATEADD(DAY, -28, (SELECT MAX(review_ts) FROM REVIEWS_ENRICHED))
  GROUP BY store_id, city
)
SELECT store_id, city, n_negative, avg_minutes,
       SNOWFLAKE.CORTEX.COMPLETE(
         'mistral-large2',
         'You are an operations analyst for a 10-minute grocery delivery company. '
         || 'Store ' || store_id || ' in ' || city || ' received ' || n_negative
         || ' negative reviews in the last 4 weeks (avg delivery ' || avg_minutes || ' min). '
         || 'In 3 bullet points: the main problems and one concrete action for the store manager. '
         || 'Reviews: ' || LEFT(texts, 6000)
       ) AS manager_brief
FROM neg;

SELECT * FROM STORE_REVIEW_BRIEFS ORDER BY n_negative DESC LIMIT 5;
