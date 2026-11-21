#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-command deploy of the DashCart project with the Snowflake CLI (`snow`).
#   pip install snowflake-cli
#   snow connection add          # name it "dashcart" (user must have ACCOUNTADMIN for step 0)
#   bash scripts/deploy.sh
# -----------------------------------------------------------------------------
set -euo pipefail
CONN="${SNOWFLAKE_CONNECTION:-dashcart}"
cd "$(dirname "$0")/.."

run() { echo -e "\n▶ $1"; snow sql -c "$CONN" -f "$1"; }

[ -f data/orders.csv.gz ] || python data_generator/generate_data.py

run sql/00_setup_account.sql

echo -e "\n▶ uploading data files to @DASHCART.RAW.LANDING"
snow stage copy "data/*.gz" @DASHCART.RAW.LANDING/dashcart/ -c "$CONN" --role DASHCART_ENGINEER --overwrite

run sql/01_ingestion_raw.sql
run sql/02_staging_views.sql
run sql/03_core_model_cdc.sql
run sql/04_marts_dynamic_tables.sql
run sql/06_cortex_ml_ai.sql
run sql/07_governance_security.sql
run sql/08_data_quality_alerts.sql

echo -e "\n▶ Snowpark objects"
SNOWFLAKE_CONNECTION="$CONN" python snowpark/deploy.py

echo -e "\n▶ Streamlit in Snowflake"
snow streamlit deploy --replace -c "$CONN" --role DASHCART_ENGINEER

echo -e "\n✅ Done. Open Snowsight → Projects → Streamlit → DashCart Command Center"
echo "   Analysis queries: sql/05_advanced_analytics.sql · Cost: sql/09_performance_cost.sql"
