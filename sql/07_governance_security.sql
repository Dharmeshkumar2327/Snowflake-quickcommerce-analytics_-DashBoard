/* =============================================================================
   07_governance_security.sql
   -----------------------------------------------------------------------------
   * Object TAGS + ONE TAG-BASED MASKING policy (masking driven by tag value)
   * ROW ACCESS POLICY driven by a mapping table (city managers see only their city)
   * Secure view for an external partner + Secure Data Sharing (template)
   * Time Travel, UNDROP and zero-copy CLONE for a dev environment
   * Auditing with ACCOUNT_USAGE.ACCESS_HISTORY
============================================================================= */

USE ROLE DASHCART_ADMIN;
USE WAREHOUSE DASHCART_BI_WH;          -- usable by every role tested below
USE SCHEMA DASHCART.GOVERNANCE;

-- ===========================================================================
-- 1. Classification tags
-- ===========================================================================
CREATE OR REPLACE TAG PII_TYPE ALLOWED_VALUES 'EMAIL', 'PHONE', 'NAME'
  COMMENT = 'Personally identifiable information';
CREATE OR REPLACE TAG DATA_DOMAIN ALLOWED_VALUES 'SALES', 'OPERATIONS', 'CUSTOMER', 'PRODUCT';

-- ===========================================================================
-- 2. ONE tag-based masking policy for all PII
--    The policy is attached to the TAG, not to columns: any column (in any table
--    or schema) tagged PII_TYPE is masked automatically - including future ones.
--    The tag VALUE decides how the column is masked.
--
--    Engineers see clear text: the pipeline runs as DASHCART_ENGINEER and must
--    never persist masked values into CORE (a classic masking pitfall).
-- ===========================================================================
CREATE OR REPLACE MASKING POLICY MASK_PII_BY_TAG AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DASHCART_ENGINEER') THEN val            -- engineer + admin (role hierarchy)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('DASHCART.GOVERNANCE.PII_TYPE') = 'EMAIL'
         THEN REGEXP_REPLACE(val, '^[^@]+', '*****')                  -- *****@example.com
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('DASHCART.GOVERNANCE.PII_TYPE') = 'PHONE'
         THEN CONCAT('+91-XXXXXX', RIGHT(val, 4))                     -- last 4 for support look-ups
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('DASHCART.GOVERNANCE.PII_TYPE') = 'NAME'
         THEN SPLIT_PART(val, ' ', 1) || ' ' || LEFT(SPLIT_PART(val, ' ', 2), 1) || '.'   -- Priya S.
    ELSE '***MASKED***'
  END;

ALTER TAG PII_TYPE SET MASKING POLICY MASK_PII_BY_TAG;

-- Tag the columns - masking follows automatically
ALTER TABLE DASHCART.CORE.DIM_CUSTOMER MODIFY
  COLUMN email     SET TAG PII_TYPE = 'EMAIL',
  COLUMN phone     SET TAG PII_TYPE = 'PHONE',
  COLUMN full_name SET TAG PII_TYPE = 'NAME';

ALTER TABLE DASHCART.RAW.RAW_CUSTOMERS MODIFY
  COLUMN email     SET TAG PII_TYPE = 'EMAIL',
  COLUMN phone     SET TAG PII_TYPE = 'PHONE',
  COLUMN full_name SET TAG PII_TYPE = 'NAME';

ALTER TABLE DASHCART.CORE.DIM_CUSTOMER SET TAG DATA_DOMAIN = 'CUSTOMER';
ALTER TABLE DASHCART.CORE.FACT_ORDERS  SET TAG DATA_DOMAIN = 'SALES';

-- Verify as an analyst: names/emails/phones come back masked, everything else intact
USE ROLE DASHCART_ANALYST;
SELECT customer_id, full_name, email, phone, city FROM DASHCART.CORE.DIM_CUSTOMER LIMIT 5;
USE ROLE DASHCART_ADMIN;

-- Where is PII? (tag lineage, including views built on top)
SELECT * FROM TABLE(DASHCART.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('DASHCART.CORE.DIM_CUSTOMER', 'TABLE'));

-- ===========================================================================
-- 3. Row-level security for city managers
-- ===========================================================================
CREATE OR REPLACE TABLE CITY_ACCESS_MAP (role_name STRING, city STRING);
INSERT INTO CITY_ACCESS_MAP VALUES
  ('DASHCART_CITY_MANAGER_BLR', 'Bengaluru'),
  ('DASHCART_CITY_MANAGER_BOM', 'Mumbai'),
  ('DASHCART_CITY_MANAGER_DEL', 'Delhi');

CREATE OR REPLACE ROW ACCESS POLICY RAP_CITY AS (row_city STRING) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('DASHCART_ANALYST')                     -- analysts & above see every city
  OR EXISTS (SELECT 1 FROM DASHCART.GOVERNANCE.CITY_ACCESS_MAP m
             WHERE m.city = row_city AND IS_ROLE_IN_SESSION(m.role_name));

ALTER DYNAMIC TABLE DASHCART.MARTS.DT_DAILY_CITY_KPIS   ADD ROW ACCESS POLICY RAP_CITY ON (city);
ALTER DYNAMIC TABLE DASHCART.MARTS.DT_STORE_HOURLY_LOAD ADD ROW ACCESS POLICY RAP_CITY ON (city);

-- (per-city roles DASHCART_CITY_MANAGER_BLR/BOM/DEL are created in 00_setup_account.sql)

-- Test it: a Bengaluru manager only ever sees Bengaluru
USE ROLE DASHCART_CITY_MANAGER_BLR;
USE SECONDARY ROLES NONE;
SELECT city, COUNT(*) AS days, SUM(orders) AS orders FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS GROUP BY city;
USE ROLE DASHCART_ADMIN;
USE SECONDARY ROLES ALL;

-- ===========================================================================
-- 4. Partner sharing: aggregated, PII-free secure view + share (template)
-- ===========================================================================
CREATE OR REPLACE SECURE VIEW DASHCART.MARTS.SV_BRAND_SELL_THROUGH AS
SELECT DATE_TRUNC('WEEK', order_date) AS week, brand, category,
       SUM(units) AS units, SUM(revenue) AS revenue
FROM DASHCART.MARTS.DT_PRODUCT_DAILY
GROUP BY ALL;

/* Run as ACCOUNTADMIN:
CREATE SHARE DASHCART_BRAND_PARTNER_SHARE;
GRANT USAGE ON DATABASE DASHCART TO SHARE DASHCART_BRAND_PARTNER_SHARE;
GRANT USAGE ON SCHEMA DASHCART.MARTS TO SHARE DASHCART_BRAND_PARTNER_SHARE;
GRANT SELECT ON VIEW DASHCART.MARTS.SV_BRAND_SELL_THROUGH TO SHARE DASHCART_BRAND_PARTNER_SHARE;
ALTER SHARE DASHCART_BRAND_PARTNER_SHARE ADD ACCOUNTS = <partner_org>.<partner_account>;
*/

-- ===========================================================================
-- 5. Time Travel, UNDROP, zero-copy cloning
-- ===========================================================================
-- "Oops" - an analyst deletes Mumbai orders by mistake
SET before_delete = (SELECT CURRENT_TIMESTAMP());
DELETE FROM DASHCART.CORE.FACT_ORDERS WHERE city = 'Mumbai';

-- See the table as it was before the delete ...
SELECT COUNT(*) AS rows_before FROM DASHCART.CORE.FACT_ORDERS AT (TIMESTAMP => $before_delete::TIMESTAMP_LTZ);
SELECT COUNT(*) AS rows_now    FROM DASHCART.CORE.FACT_ORDERS;

-- ... and restore exactly the deleted rows
INSERT INTO DASHCART.CORE.FACT_ORDERS
SELECT * FROM DASHCART.CORE.FACT_ORDERS AT (TIMESTAMP => $before_delete::TIMESTAMP_LTZ)
WHERE city = 'Mumbai';

-- Dropped a table? UNDROP it.
DROP TABLE DASHCART.CORE.DIM_FESTIVAL;
UNDROP TABLE DASHCART.CORE.DIM_FESTIVAL;

-- Zero-copy clone: a full DEV copy of the database in seconds, no extra storage until changed
CREATE OR REPLACE DATABASE DASHCART_DEV CLONE DASHCART;
-- Clone as of a point in time (e.g. to debug yesterday's numbers)
-- CREATE TABLE DASHCART_DEV.CORE.FACT_ORDERS_YESTERDAY CLONE DASHCART.CORE.FACT_ORDERS AT (OFFSET => -86400);
ALTER TASK DASHCART_DEV.UTIL.T00_ROOT SUSPEND;   -- cloned tasks start suspended; keep them that way

-- ===========================================================================
-- 6. Audit: who read PII columns in the last 7 days? (ACCOUNT_USAGE ~2h latency)
-- ===========================================================================
SELECT ah.query_start_time, ah.user_name, obj.value:objectName::STRING AS object_name,
       col.value:columnName::STRING AS column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(ah.base_objects_accessed) obj,
     LATERAL FLATTEN(obj.value:columns) col
WHERE ah.query_start_time >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
  AND obj.value:objectName::STRING = 'DASHCART.CORE.DIM_CUSTOMER'
  AND col.value:columnName::STRING IN ('EMAIL', 'PHONE', 'FULL_NAME')
ORDER BY ah.query_start_time DESC;
