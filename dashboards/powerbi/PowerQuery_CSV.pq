// =============================================================================
// DashCart - Power Query (M) for the CSV extracts in dashboards/data/
// Power BI Desktop -> Home -> Transform data -> New Source -> Blank Query ->
// Advanced Editor. Create ONE blank query per block below and name it exactly
// as the comment says. Then set the DataFolder parameter to your local path.
// =============================================================================

// ---- Query name: DataFolder   (Manage Parameters -> New, Type = Text) -------
"C:\DashCart\dashboards\data\" meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]

// ---- Helper  (Query name: fnCsv)  -------------------------------------------
(file as text) as table =>
let
    Source   = Csv.Document(File.Contents(DataFolder & file), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true])
in
    Promoted

// ---- Query name: FactOrders  ------------------------------------------------
let
    Source = fnCsv("fact_orders.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"order_ts", type datetime}, {"order_date", type date}, {"date_key", Int64.Type}, {"order_hour", Int64.Type},
        {"has_coupon", Int64.Type}, {"is_delivered", Int64.Type}, {"is_cancelled", Int64.Type},
        {"line_count", Int64.Type}, {"units", Int64.Type},
        {"gross_item_value", Currency.Type}, {"discount_amount", Currency.Type}, {"delivery_fee", Currency.Type},
        {"net_revenue", Currency.Type}, {"cogs", Currency.Type}, {"contribution_margin", Currency.Type},
        {"promised_minutes", Int64.Type}, {"delivery_minutes", type number}, {"pack_minutes", type number},
        {"ride_minutes", type number}, {"is_on_time", Int64.Type}, {"distance_km", type number}}, "en-US"),
    Blank  = Table.ReplaceValue(Typed, "", null, Replacer.ReplaceValue, {"coupon_code"})
in
    Blank

// ---- Query name: FactOrderItems  --------------------------------------------
let
    Source = fnCsv("fact_order_items.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"line_no", Int64.Type}, {"order_date", type date}, {"quantity", Int64.Type},
        {"unit_price", Currency.Type}, {"line_amount", Currency.Type}, {"unit_cost", Currency.Type}, {"line_cogs", Currency.Type}}, "en-US")
in
    Typed

// ---- Query name: DimDate  ---------------------------------------------------
let
    Source = fnCsv("dim_date.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"date", type date}, {"date_key", Int64.Type}, {"year", Int64.Type}, {"quarter", Int64.Type}, {"month", Int64.Type},
        {"month_start", type date}, {"week_start", type date}, {"iso_day_of_week", Int64.Type},
        {"is_weekend", type logical}, {"is_monsoon", type logical}, {"is_festival_window", type logical}, {"fiscal_year", Int64.Type}}, "en-US")
in
    Typed

// ---- Query name: DimStore  --------------------------------------------------
let
    Source = fnCsv("dim_store.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"latitude", type number}, {"longitude", type number}, {"opened_date", type date}, {"capacity_orders_per_hour", Int64.Type}}, "en-US")
in
    Typed

// ---- Query name: DimProduct  ------------------------------------------------
let
    Source = fnCsv("dim_product.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"mrp", Currency.Type}, {"cost_price", Currency.Type}, {"gross_margin_pct_at_mrp", type number}}, "en-US"),
    Bool   = Table.TransformColumns(Typed, {{"is_perishable", each _ = "True", type logical}})
in
    Bool

// ---- Query name: DimCustomer  (PII-free: no name / email / phone) ----------
let
    Source = fnCsv("dim_customer.csv"),
    Typed  = Table.TransformColumnTypes(Source, {{"signup_date", type date}, {"birth_year", Int64.Type}}, "en-US")
in
    Typed

// ---- Query name: Customer360  -----------------------------------------------
let
    Source = fnCsv("mart_customer_360.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"first_order_date", type date}, {"last_order_date", type date}, {"total_orders", Int64.Type}, {"delivered_orders", Int64.Type},
        {"lifetime_net_revenue", Currency.Type}, {"lifetime_margin", Currency.Type}, {"lifetime_discounts", Currency.Type},
        {"avg_basket_value", Currency.Type}, {"coupon_usage_rate", type number}, {"late_delivery_rate", type number},
        {"days_since_last_order", Int64.Type}, {"orders_per_month", type number}, {"is_churned_45d", Int64.Type},
        {"r_score", Int64.Type}, {"f_score", Int64.Type}, {"m_score", Int64.Type}}, "en-US"),
    // the customer's city/tier live on DimCustomer; drop duplicates to keep one path in the model
    Slim   = Table.RemoveColumns(Typed, {"city", "membership_tier", "acquisition_channel"})
in
    Slim

// ---- Query name: Reviews  ---------------------------------------------------
let
    Source = fnCsv("fact_reviews.csv"),
    Typed  = Table.TransformColumnTypes(Source, {{"rating", Int64.Type}, {"review_ts", type datetime}, {"review_date", type date}}, "en-US")
in
    Typed

// ---- Query name: StoreHourly  -----------------------------------------------
let
    Source = fnCsv("mart_store_hourly.csv"),
    Typed  = Table.TransformColumnTypes(Source, {
        {"order_hour", Int64.Type}, {"orders", Int64.Type}, {"days", Int64.Type}, {"avg_pack_minutes", type number},
        {"avg_delivery_minutes", type number}, {"on_time_rate", type number}, {"capacity_orders_per_hour", Int64.Type},
        {"avg_orders_per_hour", type number}, {"utilization", type number}}, "en-US"),
    NoCity = Table.RemoveColumns(Typed, {"city", "store_name", "capacity_orders_per_hour"})
in
    NoCity

// ---- Query name: CohortRetention  -------------------------------------------
let
    Source = fnCsv("mart_cohort_retention.csv"),
    Typed  = Table.TransformColumnTypes(Source, {{"m", Int64.Type}, {"customers", Int64.Type}, {"cohort_size", Int64.Type}, {"retention", type number}}, "en-US")
in
    Typed

// ---- Query name: HourAxis  (disconnected helper for the SLA heatmap) -------
let
    Source = Table.FromList({0..23}, Splitter.SplitByNothing(), {"order_hour"}),
    Typed  = Table.TransformColumnTypes(Source, {{"order_hour", Int64.Type}})
in
    Typed
