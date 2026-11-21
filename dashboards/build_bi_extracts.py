"""
Build BI-ready extracts for Power BI, Tableau and the live dashboard.

Re-implements the Snowflake CORE (star schema) and MARTS (dynamic tables) logic in
pandas so the dashboards can run WITHOUT a Snowflake account. The numbers match
sql/03_core_model_cdc.sql + sql/04_marts_dynamic_tables.sql and
tests/local_reference_check.py.

    python dashboards/build_bi_extracts.py

Outputs (dashboards/data/):
  Star schema  -> fact_orders.csv, fact_order_items.csv, dim_date.csv, dim_store.csv,
                  dim_product.csv, dim_customer.csv, fact_reviews.csv
  Marts        -> mart_daily_city_kpis.csv, mart_store_hourly.csv, mart_customer_360.csv,
                  mart_product_monthly.csv, mart_cohort_retention.csv
  Tableau      -> tableau_orders_wide.csv  (one denormalised table, easiest for Tableau Public)
  Live         -> dashboard_data.json      (compact aggregates for the HTML live dashboard)
"""
import gzip
import json
import os
from datetime import datetime

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "data")
OUT = os.path.join(HERE, "data")
os.makedirs(OUT, exist_ok=True)

FESTIVALS = {
    "2025-03-14": "Holi", "2025-08-15": "Independence Day", "2025-10-20": "Diwali",
    "2025-12-25": "Christmas", "2025-12-31": "New Year's Eve",
    "2026-03-04": "Holi", "2026-08-15": "Independence Day", "2026-11-08": "Diwali",
}
THEMES = {  # same label set as Cortex CLASSIFY_TEXT in sql/06 (rule-based offline stand-in)
    "leaking": "Packaging / damage", "melted": "Packaging / damage", "late": "Late delivery", "took a bit longer": "Late delivery", "cancelled": "Late delivery",
    "not fresh": "Product quality / freshness",
    "missing": "Wrong or missing item", "wrong items": "Wrong or missing item",
    "app was slow": "App or payment issue",
}


def rd(name):
    return pd.read_csv(os.path.join(SRC, f"{name}.csv.gz"))


def load_deliveries():
    rows = []
    with gzip.open(os.path.join(SRC, "delivery_events.json.gz"), "rt") as f:
        for line in f:
            d = json.loads(line)
            ev = {}
            for e in d["events"]:  # LATERAL FLATTEN + pivot (MIN per status)
                ts = datetime.fromisoformat(e["ts"])
                ev[e["status"]] = min(ev.get(e["status"], ts), ts)
            mins = lambda a, b: (ev[b] - ev[a]).total_seconds() / 60 if a in ev and b in ev else np.nan
            rows.append({
                "order_id": d["order_id"], "promised_minutes": d["promised_minutes"],
                "rider_id": d["rider"]["rider_id"], "vehicle_type": d["rider"]["vehicle"],
                "weather": d["conditions"]["weather"], "distance_km": d["conditions"]["distance_km"],
                "pack_minutes": mins("PLACED", "PACKED"), "ride_minutes": mins("PICKED_UP", "DELIVERED"),
                "delivery_minutes": mins("PLACED", "DELIVERED"),
            })
    dl = pd.DataFrame(rows).drop_duplicates("order_id", keep="last")
    dl["is_on_time"] = np.where(dl.delivery_minutes.notna(), dl.delivery_minutes <= dl.promised_minutes, np.nan)
    return dl


def dim_date(lo, hi):
    d = pd.DataFrame({"date": pd.date_range(lo, hi, freq="D")})
    fest = pd.to_datetime(pd.Series(list(FESTIVALS.keys())))
    d["date_key"] = d.date.dt.strftime("%Y%m%d").astype(int)
    d["year"], d["quarter"], d["month"] = d.date.dt.year, d.date.dt.quarter, d.date.dt.month
    d["month_name"] = d.date.dt.strftime("%b")
    d["year_month"] = d.date.dt.strftime("%Y-%m")
    d["month_start"] = d.date.dt.to_period("M").dt.start_time
    d["week_start"] = d.date - pd.to_timedelta(d.date.dt.weekday, unit="D")
    d["iso_day_of_week"] = d.date.dt.weekday + 1
    d["day_name"] = d.date.dt.strftime("%a")
    d["is_weekend"] = d.iso_day_of_week >= 6
    d["is_monsoon"] = d.month.between(6, 9)
    d["festival_name"] = d.date.dt.strftime("%Y-%m-%d").map(FESTIVALS)
    d["is_festival_window"] = d.date.apply(lambda x: bool((abs((fest - x).dt.days) <= 2).any()))
    d["fiscal_year"] = np.where(d.month >= 4, d.year, d.year - 1)
    d["fiscal_year_label"] = "FY" + (d.fiscal_year + 1).astype(str).str[-2:]
    return d


def theme(text):
    t = str(text).lower()
    for k, v in THEMES.items():
        if k in t:
            return v
    return "Positive experience" if any(w in t for w in ["fast", "fresh", "polite", "happy", "loved", "great", "amazing"]) else "Other / neutral"


def main():
    stores, products, customers, orders, items = rd("dark_stores"), rd("products"), rd("customers"), rd("orders"), rd("order_items")
    reviews = rd("reviews")
    dl = load_deliveries()

    # ---------------- FACT_ORDER_ITEMS ----------------
    it = items.merge(products[["product_id", "cost_price"]], on="product_id", how="left")
    it["line_amount"] = (it.quantity * it.unit_price).round(2)
    it["line_cogs"] = (it.quantity * it.cost_price).round(2)
    it = it.rename(columns={"cost_price": "unit_cost"})

    # ---------------- FACT_ORDERS ----------------
    agg = it.groupby("order_id").agg(line_count=("line_no", "size"), units=("quantity", "sum"),
                                     gross_item_value=("line_amount", "sum"), cogs=("line_cogs", "sum")).reset_index()
    f = (orders.merge(agg, on="order_id", how="left")
               .merge(stores[["store_id", "city", "zone"]], on="store_id", how="left")
               .merge(dl, on="order_id", how="left")
               .merge(customers[["customer_id", "membership_tier", "acquisition_channel"]], on="customer_id", how="left"))
    f["platform"] = f.platform.str.lower()
    f["order_status"] = f.order_status.str.upper()
    f["discount_amount"] = f.discount_amount.fillna(0)
    f["delivery_fee"] = f.delivery_fee.fillna(0)
    f["order_ts"] = pd.to_datetime(f.order_ts)
    f["order_date"] = f.order_ts.dt.normalize()
    f["date_key"] = f.order_date.dt.strftime("%Y%m%d").astype(int)
    f["order_hour"] = f.order_ts.dt.hour
    delivered = f.order_status == "DELIVERED"
    f["is_delivered"] = delivered.astype(int)
    f["is_cancelled"] = (f.order_status == "CANCELLED").astype(int)
    f["net_revenue"] = np.where(delivered, f.gross_item_value - f.discount_amount + f.delivery_fee, 0).round(2)
    f["contribution_margin"] = np.where(delivered, f.net_revenue - f.cogs, 0).round(2)
    f["has_coupon"] = f.coupon_code.notna().astype(int)
    f["hour_band"] = pd.cut(f.order_hour, [-1, 6, 11, 17, 21, 23],
                            labels=["Late night (0-6)", "Morning (7-11)", "Afternoon (12-17)", "Evening peak (18-21)", "Night (22-23)"]).astype(str)
    it = it.merge(f[["order_id", "order_date"]], on="order_id", how="left")

    dd = dim_date(f.order_date.min().replace(month=1, day=1), pd.Timestamp("2026-12-31"))
    f = f.merge(dd[["date", "is_monsoon", "is_festival_window", "is_weekend"]].rename(columns={"date": "order_date"}),
                on="order_date", how="left")

    fact_cols = ["order_id", "order_ts", "order_date", "date_key", "order_hour", "hour_band", "customer_id", "store_id",
                 "city", "platform", "payment_method", "coupon_code", "has_coupon", "order_status", "is_delivered",
                 "is_cancelled", "line_count", "units", "gross_item_value", "discount_amount", "delivery_fee",
                 "net_revenue", "cogs", "contribution_margin", "promised_minutes", "delivery_minutes", "pack_minutes",
                 "ride_minutes", "is_on_time", "rider_id", "vehicle_type", "weather", "distance_km"]
    fo = f[fact_cols].copy()
    fo["is_on_time"] = fo.is_on_time.astype("Int64")
    fo["order_date"] = fo.order_date.dt.strftime("%Y-%m-%d")
    for c in ["delivery_minutes", "pack_minutes", "ride_minutes"]:
        fo[c] = fo[c].round(2)
    fo.to_csv(os.path.join(OUT, "fact_orders.csv"), index=False, date_format="%Y-%m-%d %H:%M:%S")
    it[["order_id", "line_no", "product_id", "order_date", "quantity", "unit_price", "line_amount", "unit_cost", "line_cogs"]] \
        .to_csv(os.path.join(OUT, "fact_order_items.csv"), index=False, date_format="%Y-%m-%d")

    # ---------------- Dimensions ----------------
    dd.to_csv(os.path.join(OUT, "dim_date.csv"), index=False, date_format="%Y-%m-%d")
    stores.to_csv(os.path.join(OUT, "dim_store.csv"), index=False)
    p = products.copy()
    p["gross_margin_pct_at_mrp"] = ((p.mrp - p.cost_price) / p.mrp).round(4)
    p.to_csv(os.path.join(OUT, "dim_product.csv"), index=False)
    # PII-free customer dimension (mirrors masking policy in sql/07: analysts never see name/email/phone)
    cust = customers[["customer_id", "city", "signup_date", "acquisition_channel", "membership_tier", "birth_year"]].copy()
    cust["age_band"] = pd.cut(2026 - cust.birth_year, [0, 24, 34, 44, 54, 120], labels=["18-24", "25-34", "35-44", "45-54", "55+"]).astype(str)
    cust.to_csv(os.path.join(OUT, "dim_customer.csv"), index=False)

    # ---------------- Reviews ----------------
    rv = reviews.merge(f[["order_id", "store_id", "city"]], on="order_id", how="left")
    rv["review_date"] = pd.to_datetime(rv.review_ts).dt.normalize()
    rv["complaint_theme"] = rv.review_text.map(theme)
    rv["sentiment"] = np.select([rv.rating >= 4, rv.rating == 3], ["Positive", "Neutral"], "Negative")
    rv.to_csv(os.path.join(OUT, "fact_reviews.csv"), index=False, date_format="%Y-%m-%d")

    # ---------------- MARTS ----------------
    g = f.groupby(["order_date", "city"])
    daily = pd.DataFrame({
        "orders": g.size(), "delivered_orders": g.is_delivered.sum(), "cancelled_orders": g.is_cancelled.sum(),
        "active_customers": g.customer_id.nunique(), "gmv": g.gross_item_value.sum(), "net_revenue": g.net_revenue.sum(),
        "contribution_margin": g.contribution_margin.sum(), "discounts": g.discount_amount.sum(),
        "on_time_orders": g.is_on_time.apply(lambda s: (s == True).sum()),
        "timed_orders": g.delivery_minutes.count(), "avg_delivery_minutes": g.delivery_minutes.mean(),
        "p90_delivery_minutes": g.delivery_minutes.quantile(0.9),
    }).reset_index()
    daily["on_time_rate"] = daily.on_time_orders / daily.timed_orders.replace(0, np.nan)
    daily.round(4).assign(order_date=daily.order_date.dt.strftime("%Y-%m-%d")).to_csv(os.path.join(OUT, "mart_daily_city_kpis.csv"), index=False, date_format="%Y-%m-%d")

    sh = f.groupby(["store_id", "city", "order_hour"]).agg(
        orders=("order_id", "size"), days=("order_date", "nunique"),
        avg_pack_minutes=("pack_minutes", "mean"), avg_delivery_minutes=("delivery_minutes", "mean"),
        on_time_rate=("is_on_time", lambda s: s.dropna().astype(float).mean())).reset_index()
    sh = sh.merge(stores[["store_id", "store_name", "capacity_orders_per_hour"]], on="store_id")
    sh["avg_orders_per_hour"] = sh.orders / sh.days
    sh["utilization"] = sh.avg_orders_per_hour / sh.capacity_orders_per_hour
    sh.round(4).to_csv(os.path.join(OUT, "mart_store_hourly.csv"), index=False)

    as_of = f.order_date.max()
    gc = f.groupby("customer_id")
    c360 = pd.DataFrame({
        "first_order_date": gc.order_date.min(), "last_order_date": gc.order_date.max(),
        "total_orders": gc.size(), "delivered_orders": gc.is_delivered.sum(), "lifetime_net_revenue": gc.net_revenue.sum(),
        "lifetime_margin": gc.contribution_margin.sum(), "lifetime_discounts": gc.discount_amount.sum(),
        "avg_basket_value": f[delivered].groupby("customer_id").gross_item_value.mean(),
        "coupon_usage_rate": gc.has_coupon.mean(),
        "late_delivery_rate": gc.is_on_time.apply(lambda s: 1 - s.dropna().astype(float).mean() if s.notna().any() else 0),
    }).reset_index()
    c360 = c360.merge(cust[["customer_id", "city", "membership_tier", "acquisition_channel"]], on="customer_id", how="left")
    c360["days_since_last_order"] = (as_of - c360.last_order_date).dt.days
    months = ((as_of.year - c360.first_order_date.dt.year) * 12 + (as_of.month - c360.first_order_date.dt.month)).clip(lower=1)
    c360["orders_per_month"] = c360.total_orders / months
    c360["is_churned_45d"] = (c360.days_since_last_order > 45).astype(int)
    # RFM (NTILE 5 like sql/05) + simple named segments
    c360["r_score"] = pd.qcut(-c360.days_since_last_order.rank(method="first"), 5, labels=[1, 2, 3, 4, 5]).astype(int)
    c360["f_score"] = pd.qcut(c360.total_orders.rank(method="first"), 5, labels=[1, 2, 3, 4, 5]).astype(int)
    c360["m_score"] = pd.qcut(c360.lifetime_net_revenue.rank(method="first"), 5, labels=[1, 2, 3, 4, 5]).astype(int)
    c360["rfm_segment"] = np.select(
        [(c360.r_score >= 4) & (c360.f_score >= 4), (c360.r_score >= 3) & (c360.f_score >= 3),
         (c360.late_delivery_rate >= 0.4) & (c360.total_orders >= 3), c360.r_score <= 2, c360.total_orders <= 2],
        ["Power Shoppers", "Steady Regulars", "SLA-Burned", "Lapsed", "New & Exploring"], "Occasional")
    c360.round(4).to_csv(os.path.join(OUT, "mart_customer_360.csv"), index=False, date_format="%Y-%m-%d")

    pm = it.merge(products[["product_id", "product_name", "category", "sub_category", "brand"]], on="product_id")
    pm["month_start"] = pd.to_datetime(pm.order_date).dt.to_period("M").dt.start_time
    pmo = pm.groupby(["month_start", "product_id", "product_name", "category", "sub_category", "brand"]).agg(
        units=("quantity", "sum"), revenue=("line_amount", "sum"), cogs=("line_cogs", "sum"),
        orders=("order_id", "nunique")).reset_index()
    pmo["gross_margin"] = pmo.revenue - pmo.cogs
    pmo.round(2).to_csv(os.path.join(OUT, "mart_product_monthly.csv"), index=False, date_format="%Y-%m-%d")

    first = f.groupby("customer_id").order_date.min().dt.to_period("M").rename("cohort")
    a = f[["customer_id", "order_date"]].join(first, on="customer_id")
    a["m"] = (a.order_date.dt.to_period("M") - a.cohort).apply(lambda x: x.n)
    coh = a.drop_duplicates(["customer_id", "m"]).groupby(["cohort", "m"]).customer_id.nunique().reset_index(name="customers")
    coh["cohort_size"] = coh.groupby("cohort").customers.transform("max")
    coh["retention"] = (coh.customers / coh.cohort_size).round(4)
    coh["cohort"] = coh.cohort.astype(str)
    coh[coh.m <= 12].to_csv(os.path.join(OUT, "mart_cohort_retention.csv"), index=False)

    # ---------------- Tableau wide table ----------------
    wide = fo.merge(cust[["customer_id", "age_band"]], on="customer_id", how="left") \
             .merge(f[["order_id", "zone", "membership_tier", "acquisition_channel", "is_monsoon", "is_festival_window", "is_weekend"]], on="order_id") \
             .merge(stores[["store_id", "store_name", "latitude", "longitude", "capacity_orders_per_hour"]], on="store_id")
    wide.to_csv(os.path.join(OUT, "tableau_orders_wide.csv"), index=False, date_format="%Y-%m-%d %H:%M:%S")

    # ---------------- Live dashboard JSON (compact) ----------------
    fd = f.copy()
    fd["month"] = fd.order_date.dt.strftime("%Y-%m")
    mc = fd.groupby(["month", "city"]).agg(
        o=("order_id", "size"), dv=("is_delivered", "sum"), cx=("is_cancelled", "sum"),
        gmv=("gross_item_value", "sum"), dgmv=("gross_item_value", lambda s: s[fd.loc[s.index, "is_delivered"] == 1].sum()),
        nr=("net_revenue", "sum"), cm=("contribution_margin", "sum"), disc=("discount_amount", "sum"),
        ot=("is_on_time", lambda s: (s == True).sum()), tm=("delivery_minutes", "count"),
        dm=("delivery_minutes", "sum")).reset_index()
    hc = fd[fd.delivery_minutes.notna()].groupby(["month", "city", "order_hour"]).agg(
        n=("order_id", "size"), ot=("is_on_time", lambda s: (s == True).sum())).reset_index()
    cat = pm.copy()
    cat["month"] = pd.to_datetime(cat.order_date).dt.strftime("%Y-%m")
    cat = cat.merge(fd[["order_id", "city"]], on="order_id")
    cc = cat.groupby(["month", "city", "category"]).agg(rev=("line_amount", "sum"), cogs=("line_cogs", "sum")).reset_index()
    wx = fd[fd.delivery_minutes.notna()].groupby(["month", "city", "weather"]).agg(
        n=("order_id", "size"), ot=("is_on_time", lambda s: (s == True).sum()), dm=("delivery_minutes", "sum")).reset_index()
    dly = daily.copy()
    dly["d"] = dly.order_date.dt.strftime("%Y-%m-%d")
    st = fd.groupby(["month", "store_id", "city"]).agg(
        o=("order_id", "size"), nr=("net_revenue", "sum"), ot=("is_on_time", lambda s: (s == True).sum()),
        tm=("delivery_minutes", "count"), cx=("is_cancelled", "sum")).reset_index()
    tiers = c360.groupby("membership_tier").agg(
        customers=("customer_id", "size"), orders_pm=("orders_per_month", "mean"),
        ltv=("lifetime_net_revenue", "mean"), churn=("is_churned_45d", "mean")).reset_index()
    segs = c360.groupby("rfm_segment").agg(customers=("customer_id", "size"), revenue=("lifetime_net_revenue", "sum"),
                                           orders_pm=("orders_per_month", "median")).reset_index()
    rvt = rv.groupby("complaint_theme").agg(n=("review_id", "size"), rating=("rating", "mean")).reset_index()

    def rec(df, cols, rnd=2):
        def cell(v):
            if isinstance(v, (float, np.floating)):
                return None if not np.isfinite(v) else round(float(v), rnd)  # JSON has no NaN
            return int(v) if isinstance(v, np.integer) else v
        return [[cell(v) for v in row] for row in df[cols].itertuples(index=False)]

    payload = {
        "generated": datetime.now().strftime("%Y-%m-%d %H:%M"), "as_of": as_of.strftime("%Y-%m-%d"),
        "cities": sorted(f.city.unique().tolist()),
        "months": sorted(fd.month.unique().tolist()),
        "festivals": FESTIVALS,
        "mc_cols": ["month", "city", "o", "dv", "cx", "gmv", "dgmv", "nr", "cm", "disc", "ot", "tm", "dm"],
        "mc": rec(mc, ["month", "city", "o", "dv", "cx", "gmv", "dgmv", "nr", "cm", "disc", "ot", "tm", "dm"], 0),
        "hc": rec(hc, ["month", "city", "order_hour", "n", "ot"]),
        "cc": rec(cc, ["month", "city", "category", "rev", "cogs"], 0),
        "wx": rec(wx, ["month", "city", "weather", "n", "ot", "dm"], 0),
        "daily": rec(dly, ["d", "city", "orders", "cancelled_orders", "avg_delivery_minutes", "on_time_rate"], 3),
        "stores": rec(st, ["month", "store_id", "city", "o", "nr", "ot", "tm", "cx"], 0),
        "tiers": rec(tiers, ["membership_tier", "customers", "orders_pm", "ltv", "churn"], 3),
        "segments": rec(segs, ["rfm_segment", "customers", "revenue", "orders_pm"], 2),
        "review_themes": rec(rvt, ["complaint_theme", "n", "rating"], 2),
        "cohort": rec(coh[coh.m <= 9], ["cohort", "m", "retention"], 3),
    }
    with open(os.path.join(OUT, "dashboard_data.json"), "w") as fh:
        json.dump(payload, fh, separators=(",", ":"), allow_nan=False)

    # ---------------- Headline check ----------------
    d = f[delivered]
    print(f"orders {len(f):,} | GMV ₹{f.gross_item_value.sum() / 1e7:.2f} Cr | AOV ₹{d.gross_item_value.mean():.0f} | "
          f"CM {100 * f.contribution_margin.sum() / d.gross_item_value.sum():.1f}% | "
          f"on-time {100 * d.is_on_time.astype(float).mean():.1f}% | cancel {100 * f.is_cancelled.mean():.1f}%")
    print(tiers.round(3).to_string(index=False))
    for n in sorted(os.listdir(OUT)):
        print(f"  {n:32s} {os.path.getsize(os.path.join(OUT, n)) / 1e6:7.2f} MB")


if __name__ == "__main__":
    main()
