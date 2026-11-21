/* =============================================================================
   05_advanced_analytics.sql
   -----------------------------------------------------------------------------
   Business questions answered with advanced Snowflake SQL.
   Each block is standalone - run them one at a time.

   Q1  Monthly cohort retention matrix                       (cohorts, PIVOT)
   Q2  RFM segmentation                                      (NTILE, CASE scoring)
   Q3  Market basket analysis - support / confidence / lift (self-join, lift)
   Q4  App funnel + MATCH_RECOGNIZE pattern mining           (row pattern matching)
   Q5  Delivery SLA heatmap: city x hour, p50/p90            (PERCENTILE_CONT)
   Q6  Festival uplift vs same-weekday baseline              (window frames)
   Q7  Rolling 7-day GMV, WoW growth, running total          (RANGE BETWEEN)
   Q8  Unit economics waterfall per order                    (UNPIVOT)
   Q9  Coupon effectiveness: margin per coupon & repeat rate (LEAD)
   Q10 Plus vs Standard membership value                     (conditional aggregates)
   Q11 Monsoon impact on Mumbai SLA                          (difference-in-differences)
   Q12 Customer journey: time between orders, gap-filled     (LAG, GENERATOR)
   Q13 Pareto: what % of customers drive 80% of revenue?    (cumulative distribution)
   Q14 SCD2 point-in-time: revenue by tier AT order time vs NOW
============================================================================= */

USE ROLE DASHCART_ANALYST;
USE WAREHOUSE DASHCART_BI_WH;
USE SCHEMA DASHCART.MARTS;
ALTER SESSION SET QUERY_TAG = '{"project":"dashcart","module":"advanced_analytics"}';

-- ---------------------------------------------------------------------------
-- Q1  Cohort retention: % of each signup-month cohort ordering in month N
-- ---------------------------------------------------------------------------
WITH firsts AS (
  SELECT customer_id, DATE_TRUNC('MONTH', MIN(order_date)) AS cohort_month
  FROM DT_ORDERS_ENRICHED GROUP BY customer_id
), activity AS (
  SELECT DISTINCT o.customer_id, f.cohort_month,
         DATEDIFF(MONTH, f.cohort_month, DATE_TRUNC('MONTH', o.order_date)) AS month_n
  FROM DT_ORDERS_ENRICHED o JOIN firsts f USING (customer_id)
), sized AS (
  SELECT cohort_month, month_n, COUNT(*) AS active,
         FIRST_VALUE(COUNT(*)) OVER (PARTITION BY cohort_month ORDER BY month_n) AS cohort_size
  FROM activity GROUP BY cohort_month, month_n
)
SELECT *
FROM (SELECT cohort_month, cohort_size, month_n, ROUND(100 * active / cohort_size, 1) AS retention_pct
      FROM sized WHERE month_n <= 6)
PIVOT (MAX(retention_pct) FOR month_n IN (0, 1, 2, 3, 4, 5, 6))
  AS p (cohort_month, cohort_size, m0, m1, m2, m3, m4, m5, m6)
ORDER BY cohort_month;

-- ---------------------------------------------------------------------------
-- Q2  RFM segmentation (scores 1-5) and segment economics
-- ---------------------------------------------------------------------------
WITH base AS (
  SELECT customer_id, membership_tier, days_since_last_order AS recency,
         total_orders AS frequency, lifetime_net_revenue AS monetary
  FROM V_CUSTOMER_360 WHERE delivered_orders > 0
), scored AS (
  SELECT *,
         6 - NTILE(5) OVER (ORDER BY recency)      AS r,     -- recent = 5
         NTILE(5) OVER (ORDER BY frequency)        AS f,
         NTILE(5) OVER (ORDER BY monetary)         AS m
  FROM base
), rfm_scored AS (
SELECT *, r || f || m AS rfm_code,
       CASE
         WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Champions'
         WHEN r >= 3 AND f >= 3              THEN 'Loyal'
         WHEN r >= 4 AND f <= 2              THEN 'New / Promising'
         WHEN r = 3  AND f <= 2              THEN 'Needs Attention'
         WHEN r <= 2 AND f >= 4              THEN 'Can''t Lose Them'
         WHEN r <= 2 AND f >= 2              THEN 'At Risk'
         ELSE 'Hibernating'
       END AS segment
FROM scored
), rfm AS (SELECT * FROM rfm_scored)
SELECT segment,
       COUNT(*)                                       AS customers,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1)          AS pct_customers,
       ROUND(SUM(monetary))                           AS revenue,
       ROUND(100 * RATIO_TO_REPORT(SUM(monetary)) OVER (), 1)     AS pct_revenue,
       ROUND(AVG(recency))                            AS avg_recency_days,
       ROUND(AVG(frequency), 1)                       AS avg_orders,
       ROUND(100 * AVG(IFF(membership_tier = 'Plus', 1, 0)), 1) AS pct_plus
FROM rfm GROUP BY segment ORDER BY revenue DESC;

-- ---------------------------------------------------------------------------
-- Q3  Market basket analysis at sub-category level
--     support(A,B) = P(A and B);  confidence(A->B) = P(B|A);  lift = conf / P(B)
-- ---------------------------------------------------------------------------
WITH baskets AS (
  SELECT DISTINCT i.order_id, p.sub_category
  FROM DASHCART.CORE.FACT_ORDER_ITEMS i
  JOIN DASHCART.CORE.DIM_PRODUCT p USING (product_id)
), n AS (SELECT COUNT(DISTINCT order_id) AS total FROM baskets),
item AS (SELECT sub_category, COUNT(*) AS cnt FROM baskets GROUP BY 1),
pairs AS (
  SELECT a.sub_category AS antecedent, b.sub_category AS consequent, COUNT(*) AS together
  FROM baskets a JOIN baskets b ON a.order_id = b.order_id AND a.sub_category <> b.sub_category
  GROUP BY 1, 2
)
SELECT p.antecedent, p.consequent, p.together,
       ROUND(p.together / n.total, 4)                           AS support,
       ROUND(p.together / ia.cnt, 3)                            AS confidence,
       ROUND((p.together / ia.cnt) / (ib.cnt / n.total), 2)    AS lift
FROM pairs p
JOIN item ia ON ia.sub_category = p.antecedent
JOIN item ib ON ib.sub_category = p.consequent
CROSS JOIN n
WHERE p.together >= 200
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAST(p.antecedent, p.consequent), GREATEST(p.antecedent, p.consequent)
                           ORDER BY confidence DESC) = 1          -- keep stronger direction of each pair
ORDER BY lift DESC
LIMIT 15;

-- ---------------------------------------------------------------------------
-- Q4a  Funnel: sessions reaching each step (strict order not required)
-- ---------------------------------------------------------------------------
WITH s AS (
  SELECT session_id, device_os,
         MAX(IFF(event_type = 'app_open', 1, 0))     AS s1_open,
         MAX(IFF(event_type = 'search', 1, 0))       AS s2_search,
         MAX(IFF(event_type = 'view_product', 1, 0)) AS s3_view,
         MAX(IFF(event_type = 'add_to_cart', 1, 0))  AS s4_cart,
         MAX(IFF(event_type = 'checkout', 1, 0))     AS s5_checkout,
         MAX(IFF(event_type = 'purchase', 1, 0))     AS s6_purchase
  FROM DASHCART.STAGING.STG_APP_EVENTS GROUP BY session_id, device_os
)
SELECT device_os, COUNT(*) AS sessions,
       ROUND(100 * SUM(s2_search)   / SUM(s1_open), 1)     AS open_to_search_pct,
       ROUND(100 * SUM(s3_view)     / SUM(s2_search), 1)   AS search_to_view_pct,
       ROUND(100 * SUM(s4_cart)     / SUM(s3_view), 1)     AS view_to_cart_pct,
       ROUND(100 * SUM(s5_checkout) / SUM(s4_cart), 1)     AS cart_to_checkout_pct,
       ROUND(100 * SUM(s6_purchase) / SUM(s5_checkout), 1) AS checkout_to_purchase_pct,
       ROUND(100 * SUM(s6_purchase) / SUM(s1_open), 2)     AS overall_conversion_pct
FROM s GROUP BY ROLLUP (device_os) ORDER BY sessions DESC;

-- ---------------------------------------------------------------------------
-- Q4b  MATCH_RECOGNIZE: sessions that searched, added to cart, then ABANDONED
--      (no purchase afterwards) - the remarketing audience, with time-to-drop
-- ---------------------------------------------------------------------------
SELECT device_os, COUNT(*) AS abandoned_sessions,
       ROUND(AVG(seconds_in_session)) AS avg_seconds_before_drop
FROM DASHCART.STAGING.STG_APP_EVENTS
  MATCH_RECOGNIZE (
    PARTITION BY session_id
    ORDER BY event_ts
    MEASURES FIRST(device_os) AS device_os,
             DATEDIFF('second', FIRST(event_ts), LAST(event_ts)) AS seconds_in_session,
             MATCH_NUMBER() AS match_no
    ONE ROW PER MATCH
    PATTERN (^ s_open s_search+ s_view* s_cart+ s_checkout* $)        -- session ENDS without a purchase
    DEFINE s_open     AS event_type = 'app_open',
           s_search   AS event_type = 'search',
           s_view     AS event_type = 'view_product',
           s_cart     AS event_type = 'add_to_cart',
           s_checkout AS event_type = 'checkout'
  )
GROUP BY ROLLUP (device_os);

-- ---------------------------------------------------------------------------
-- Q5  Delivery SLA heatmap: city x hour-of-day
-- ---------------------------------------------------------------------------
SELECT city, order_hour,
       COUNT(*)                                                           AS delivered,
       ROUND(100 * AVG(IFF(is_on_time, 1, 0)), 1)                         AS on_time_pct,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_minutes), 1) AS p50_min,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delivery_minutes), 1) AS p90_min
FROM DT_ORDERS_ENRICHED
WHERE order_status = 'DELIVERED'
GROUP BY city, order_hour
HAVING COUNT(*) >= 100
ORDER BY on_time_pct ASC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- Q6  Festival uplift: festival-window day vs avg of previous 4 same weekdays
-- ---------------------------------------------------------------------------
WITH daily AS (
  SELECT k.order_date, d.day_name, d.festival_name, d.is_festival_window,
         SUM(k.orders) AS orders, SUM(k.gmv) AS gmv, AVG(k.on_time_rate) AS on_time_rate
  FROM DT_DAILY_CITY_KPIS k JOIN DASHCART.CORE.DIM_DATE d ON d.date_day = k.order_date
  GROUP BY ALL
), baseline AS (
  SELECT *,
         AVG(orders) OVER (PARTITION BY day_name ORDER BY order_date
                           ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS baseline_orders
  FROM daily
)
SELECT order_date, day_name, festival_name, orders, ROUND(baseline_orders) AS baseline_orders,
       ROUND(100 * (orders / baseline_orders - 1), 1) AS uplift_pct,
       ROUND(100 * on_time_rate, 1)                   AS on_time_pct
FROM baseline
WHERE festival_name IS NOT NULL AND baseline_orders IS NOT NULL
ORDER BY uplift_pct DESC;

-- ---------------------------------------------------------------------------
-- Q7  Rolling 7-day GMV (calendar-aware RANGE frame), WoW growth, running total
-- ---------------------------------------------------------------------------
WITH d AS (
  SELECT order_date, SUM(gmv) AS gmv FROM DT_DAILY_CITY_KPIS GROUP BY order_date
), r AS (
  SELECT order_date, gmv,
         SUM(gmv) OVER (ORDER BY order_date RANGE BETWEEN INTERVAL '6 DAYS' PRECEDING AND CURRENT ROW) AS gmv_7d,
         SUM(gmv) OVER (PARTITION BY YEAR(order_date) ORDER BY order_date)                          AS ytd_gmv
  FROM d
)
SELECT order_date, gmv, gmv_7d,
       ROUND(100 * (gmv_7d / NULLIF(LAG(gmv_7d, 7) OVER (ORDER BY order_date), 0) - 1), 1) AS wow_growth_pct,
       ytd_gmv
FROM r
ORDER BY order_date DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- Q8  Unit economics waterfall per delivered order (UNPIVOT for charting)
-- ---------------------------------------------------------------------------
WITH per_order AS (
  SELECT AVG(gross_item_value)::FLOAT     AS gmv,             -- UNPIVOT needs one data type
         (-AVG(discount_amount))::FLOAT  AS discount,
         AVG(delivery_fee)::FLOAT         AS delivery_fee,
         (-AVG(cogs))::FLOAT              AS cogs,
         AVG(contribution_margin)::FLOAT  AS contribution_margin
  FROM DT_ORDERS_ENRICHED WHERE order_status = 'DELIVERED'
)
SELECT component, ROUND(value_inr, 2) AS inr_per_order
FROM per_order
UNPIVOT (value_inr FOR component IN (gmv, discount, delivery_fee, cogs, contribution_margin));

-- ---------------------------------------------------------------------------
-- Q9  Coupon effectiveness: margin and does the customer come back within 30 days?
-- ---------------------------------------------------------------------------
WITH seq AS (
  SELECT customer_id, order_date, coupon_code, contribution_margin, order_status,
         LEAD(order_date) OVER (PARTITION BY customer_id ORDER BY order_ts) AS next_order_date
  FROM DT_ORDERS_ENRICHED
)
SELECT COALESCE(coupon_code, '(none)')                            AS coupon,
       COUNT(*)                                                   AS orders,
       ROUND(AVG(contribution_margin), 1)                         AS avg_margin_inr,
       ROUND(100 * AVG(IFF(DATEDIFF(DAY, order_date, next_order_date) <= 30, 1, 0)), 1) AS repeat_30d_pct
FROM seq WHERE order_status = 'DELIVERED'
GROUP BY 1 ORDER BY orders DESC;

-- ---------------------------------------------------------------------------
-- Q10 Membership value: Plus vs Standard
-- ---------------------------------------------------------------------------
SELECT membership_tier,
       COUNT(*)                                     AS customers,
       ROUND(AVG(orders_per_month), 2)              AS orders_per_month,
       ROUND(AVG(avg_basket_value))                 AS avg_basket,
       ROUND(AVG(lifetime_net_revenue))             AS avg_ltv_revenue,
       ROUND(AVG(lifetime_margin))                  AS avg_ltv_margin,
       ROUND(100 * AVG(IFF(is_churned_45d, 1, 0)), 1) AS churned_45d_pct
FROM V_CUSTOMER_360
GROUP BY membership_tier;

-- ---------------------------------------------------------------------------
-- Q11 Monsoon impact on Mumbai: difference-in-differences vs other metros
--     (Mumbai monsoon late-rate change) - (other metros' monsoon change)
-- ---------------------------------------------------------------------------
WITH g AS (
  SELECT IFF(city = 'Mumbai', 'Mumbai', 'Other metros') AS grp, is_monsoon,
         AVG(IFF(is_on_time, 0, 1)) AS late_rate
  FROM DT_ORDERS_ENRICHED
  WHERE order_status = 'DELIVERED' AND city IN ('Mumbai', 'Bengaluru', 'Delhi')
  GROUP BY 1, 2
), p AS (
  SELECT MAX(IFF(grp = 'Mumbai' AND is_monsoon, late_rate, NULL))           AS mm,
         MAX(IFF(grp = 'Mumbai' AND NOT is_monsoon, late_rate, NULL))       AS md,
         MAX(IFF(grp <> 'Mumbai' AND is_monsoon, late_rate, NULL))          AS om,
         MAX(IFF(grp <> 'Mumbai' AND NOT is_monsoon, late_rate, NULL))      AS od
  FROM g
)
SELECT ROUND(100 * mm, 1) AS mumbai_monsoon_late_pct, ROUND(100 * md, 1) AS mumbai_dry_late_pct,
       ROUND(100 * om, 1) AS others_monsoon_late_pct, ROUND(100 * od, 1) AS others_dry_late_pct,
       ROUND(100 * ((mm - md) - (om - od)), 1) AS did_effect_pct_points
FROM p;

-- ---------------------------------------------------------------------------
-- Q12 Inter-purchase time distribution + gap-filled daily series for one city
-- ---------------------------------------------------------------------------
WITH gaps AS (
  SELECT membership_tier,
         DATEDIFF(DAY, LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_ts), order_date) AS gap_days
  FROM DT_ORDERS_ENRICHED
)
SELECT membership_tier,
       ROUND(MEDIAN(gap_days), 1)                                   AS median_days_between_orders,
       ROUND(APPROX_PERCENTILE(gap_days, 0.9), 1)                   AS p90_days
FROM gaps WHERE gap_days IS NOT NULL GROUP BY 1;

-- gap-fill: every calendar day appears even with zero orders
WITH cal AS (
  SELECT DATEADD(DAY, SEQ4(), '2025-01-01'::DATE) AS d FROM TABLE(GENERATOR(ROWCOUNT => 669))
)
SELECT cal.d AS order_date, COALESCE(k.orders, 0) AS chennai_orders
FROM cal LEFT JOIN DT_DAILY_CITY_KPIS k ON k.order_date = cal.d AND k.city = 'Chennai'
ORDER BY cal.d
LIMIT 31;

-- ---------------------------------------------------------------------------
-- Q13 Pareto: share of customers generating 80% of net revenue
-- ---------------------------------------------------------------------------
WITH r AS (
  SELECT customer_id, lifetime_net_revenue AS rev,
         SUM(lifetime_net_revenue) OVER (ORDER BY lifetime_net_revenue DESC
                                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(lifetime_net_revenue) OVER () AS cum_share,
         ROW_NUMBER() OVER (ORDER BY lifetime_net_revenue DESC) / COUNT(*) OVER () AS cust_share
  FROM DT_CUSTOMER_360
)
SELECT ROUND(100 * MIN(cust_share), 1) AS pct_customers_for_80pct_revenue
FROM r WHERE cum_share >= 0.8;

-- ---------------------------------------------------------------------------
-- Q14 SCD2 point-in-time vs current attribution (run after the SCD2 demo in 03)
--     Revenue by membership tier as it was WHEN the order happened vs tier TODAY
-- ---------------------------------------------------------------------------
SELECT pit.membership_tier                       AS tier_at_order_time,
       cur.membership_tier                       AS tier_now,
       COUNT(*)                                  AS orders,
       ROUND(SUM(f.net_revenue))                 AS net_revenue
FROM DASHCART.CORE.FACT_ORDERS f
JOIN DASHCART.CORE.DIM_CUSTOMER pit ON pit.customer_sk = f.customer_sk
JOIN DASHCART.CORE.DIM_CUSTOMER cur ON cur.customer_id = f.customer_id AND cur.is_current
GROUP BY 1, 2 ORDER BY 1, 2;

ALTER SESSION UNSET QUERY_TAG;
