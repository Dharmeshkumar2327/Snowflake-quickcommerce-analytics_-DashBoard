/* =============================================================================
   10_streamlit_app.sql  -  deploy the Streamlit in Snowflake dashboard
   Upload the app files first (SnowSQL / Snow CLI):
     PUT file://./streamlit/streamlit_app.py  @DASHCART.MARTS.STREAMLIT_STAGE/dashcart AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
     PUT file://./streamlit/environment.yml   @DASHCART.MARTS.STREAMLIT_STAGE/dashcart AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   Or simply: snow streamlit deploy --replace   (uses snowflake.yml in the repo root)
============================================================================= */

USE ROLE DASHCART_ENGINEER;
USE SCHEMA DASHCART.MARTS;

CREATE STAGE IF NOT EXISTS STREAMLIT_STAGE DIRECTORY = (ENABLE = TRUE);

CREATE OR REPLACE STREAMLIT DASHCART_COMMAND_CENTER
  ROOT_LOCATION   = '@DASHCART.MARTS.STREAMLIT_STAGE/dashcart'
  MAIN_FILE       = 'streamlit_app.py'
  QUERY_WAREHOUSE = DASHCART_BI_WH
  TITLE           = 'DashCart Command Center'
  COMMENT         = 'Ops & growth dashboard on Dynamic Tables + Cortex ML';

USE ROLE DASHCART_ADMIN;     -- managed-access schema: only the schema owner grants
GRANT USAGE ON STREAMLIT DASHCART.MARTS.DASHCART_COMMAND_CENTER TO ROLE DASHCART_ANALYST;

SHOW STREAMLITS;   -- open from Snowsight > Projects > Streamlit
