// =============================================================================
// DashCart - Power Query (M) straight from Snowflake (the "real" production path)
// Use this instead of PowerQuery_CSV.pq once sql/00 -> sql/04 have been run.
//
// Get Data -> Snowflake  (or paste these into Blank Queries)
//   Server     : <account_identifier>.snowflakecomputing.com
//   Warehouse  : DASHCART_BI_WH            (multi-cluster BI warehouse from sql/00)
//   Role       : DASHCART_ANALYST          (sees MASKED PII - by design, sql/07)
//   Mode       : DirectQuery for FactOrders (fresh every refresh of the Dynamic Tables)
//                Import for the small dims and marts
// Query tag   : Power BI queries show up in sql/09 cost attribution if you add
//               QUERY_TAG to the connection's "Role" advanced options / ODBC string.
// =============================================================================

// ---- Parameters (Manage Parameters -> New, Type = Text) --------------------
// SnowflakeServer = "xy12345.ap-south-1.aws.snowflakecomputing.com"
// SnowflakeWarehouse = "DASHCART_BI_WH"

// ---- Helper  (Query name: fnSf) ---------------------------------------------
(schema as text, object as text) as table =>
let
    Source = Snowflake.Databases(SnowflakeServer, SnowflakeWarehouse, [Role = "DASHCART_ANALYST", Implementation = "2.0"]),
    Db     = Source{[Name = "DASHCART", Kind = "Database"]}[Data],
    Sch    = Db{[Name = schema, Kind = "Schema"]}[Data],
    Obj    = Sch{[Name = object]}[Data],
    Lower  = Table.TransformColumnNames(Obj, Text.Lower)
in
    Lower

// ---- Query names -> Snowflake objects (same names as the CSV version) -------
// FactOrders      = fnSf("CORE",  "FACT_ORDERS")          -- DirectQuery
// FactOrderItems  = fnSf("CORE",  "FACT_ORDER_ITEMS")     -- DirectQuery
// DimDate         = fnSf("CORE",  "DIM_DATE")             -- rename date_day -> date
// DimStore        = fnSf("CORE",  "DIM_STORE")
// DimProduct      = fnSf("CORE",  "DIM_PRODUCT")
// DimCustomer     = Table.SelectRows(fnSf("CORE", "DIM_CUSTOMER"), each [is_current] = true)
// Customer360     = fnSf("MARTS", "V_CUSTOMER_360")
// StoreHourly     = fnSf("MARTS", "DT_STORE_HOURLY_LOAD")
// DailyCityKpis   = fnSf("MARTS", "DT_DAILY_CITY_KPIS")   -- optional aggregation table
// Reviews         = fnSf("ML",    "REVIEWS_ENRICHED")     -- has Cortex sentiment + theme
// ChurnScores     = fnSf("ML",    "CHURN_SCORES")         -- optional page: churn risk
// Forecast        = fnSf("ML",    "V_FORECAST_VS_ACTUAL") -- optional page: forecast

// Example: FactOrders with the boolean cast so DAX measures stay identical
let
    Src   = fnSf("CORE", "FACT_ORDERS"),
    Flags = Table.AddColumn(
              Table.AddColumn(Src, "is_delivered", each if [order_status] = "DELIVERED" then 1 else 0, Int64.Type),
              "is_cancelled", each if [order_status] = "CANCELLED" then 1 else 0, Int64.Type),
    OnTime = Table.TransformColumns(Flags, {{"is_on_time", each if _ = null then null else if _ then 1 else 0, Int64.Type}})
in
    OnTime

// Note on SCD2: FACT_ORDERS.customer_sk is the POINT-IN-TIME key. For "tier at
// order time" analysis relate FactOrders[customer_sk] -> DIM_CUSTOMER (all rows)
// instead of the is_current filter above. Q14 in sql/05 shows the difference.
