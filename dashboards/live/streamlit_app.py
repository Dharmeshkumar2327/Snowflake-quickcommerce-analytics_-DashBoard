"""
DashCart Live Command Center - deployable to Streamlit Community Cloud (free public URL).

Two data modes, chosen automatically:
  * LIVE  - if .streamlit/secrets.toml has a [connections.snowflake] block, every query hits
            DASHCART.MARTS (Dynamic Tables, target lag 1 h). Cache TTL 10 min + a Refresh button.
  * DEMO  - otherwise reads the CSV extracts in dashboards/data/ (run build_bi_extracts.py first).

Run locally:   streamlit run dashboards/live/streamlit_app.py
Deploy:        share.streamlit.io -> New app -> this repo -> main file = dashboards/live/streamlit_app.py
               (add the Snowflake secrets in the app's Settings -> Secrets for live mode)
"""
import os
from datetime import datetime

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="DashCart Live Command Center", page_icon="🛵", layout="wide")

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
CITIES = ["Bengaluru", "Chennai", "Delhi", "Hyderabad", "Mumbai", "Pune"]
CITY_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]  # fixed order, CVD-checked
CITY_SCALE = alt.Scale(domain=CITIES, range=CITY_COLORS)
TTL = 600  # seconds


def live_mode() -> bool:
    try:
        return "snowflake" in st.secrets.get("connections", {})
    except Exception:
        return False


LIVE = live_mode()


# ------------------------------------------------------------------ data access
@st.cache_data(ttl=TTL, show_spinner="Loading orders…")
def load_orders() -> pd.DataFrame:
    if LIVE:
        conn = st.connection("snowflake")
        df = conn.query("""
            SELECT order_id, order_date, order_hour, city, store_id, customer_id, platform, order_status,
                   gross_item_value, discount_amount, delivery_fee, net_revenue, cogs, contribution_margin,
                   delivery_minutes, pack_minutes, is_on_time::INT AS is_on_time, weather, membership_tier
            FROM DASHCART.MARTS.DT_ORDERS_ENRICHED""", ttl=TTL)
        df.columns = [c.lower() for c in df.columns]
    else:
        df = pd.read_csv(os.path.join(DATA, "fact_orders.csv"))
    df["order_date"] = pd.to_datetime(df["order_date"])
    df["is_delivered"] = (df["order_status"] == "DELIVERED").astype(int)
    df["is_cancelled"] = (df["order_status"] == "CANCELLED").astype(int)
    return df


@st.cache_data(ttl=TTL, show_spinner=False)
def load_customers() -> pd.DataFrame:
    if LIVE:
        df = st.connection("snowflake").query(
            "SELECT customer_id, city, membership_tier, orders_per_month, lifetime_net_revenue, "
            "is_churned_45d::INT AS is_churned_45d FROM DASHCART.MARTS.V_CUSTOMER_360", ttl=TTL)
        df.columns = [c.lower() for c in df.columns]
        return df
    return pd.read_csv(os.path.join(DATA, "mart_customer_360.csv"))


@st.cache_data(ttl=TTL, show_spinner=False)
def load_reviews() -> pd.DataFrame:
    if LIVE:
        try:
            df = st.connection("snowflake").query(
                "SELECT city, review_ts::DATE AS review_date, rating, complaint_theme FROM DASHCART.ML.REVIEWS_ENRICHED", ttl=TTL)
            df.columns = [c.lower() for c in df.columns]
        except Exception:
            return pd.DataFrame(columns=["city", "review_date", "rating", "complaint_theme"])
    else:
        df = pd.read_csv(os.path.join(DATA, "fact_reviews.csv"))
    df["review_date"] = pd.to_datetime(df["review_date"])
    return df


def inr(x: float) -> str:
    if abs(x) >= 1e7:
        return f"₹{x / 1e7:,.2f} Cr"
    if abs(x) >= 1e5:
        return f"₹{x / 1e5:,.2f} L"
    return f"₹{x:,.0f}"


def kpis(d: pd.DataFrame) -> dict:
    dv = d[d.is_delivered == 1]
    timed = d.delivery_minutes.notna().sum()
    return {
        "orders": len(d), "gmv": d.gross_item_value.sum(),
        "aov": dv.gross_item_value.mean() if len(dv) else 0,
        "cm": d.contribution_margin.sum() / dv.gross_item_value.sum() if len(dv) else 0,
        "ot": (d.is_on_time == 1).sum() / timed if timed else 0,
        "cx": d.is_cancelled.mean() if len(d) else 0,
    }


# ------------------------------------------------------------------ sidebar
orders = load_orders()
lo, hi = orders.order_date.min().date(), orders.order_date.max().date()

st.sidebar.title("🛵 DashCart")
st.sidebar.caption(("🟢 LIVE · Snowflake DASHCART.MARTS" if LIVE else "🟡 DEMO · CSV extracts") +
                   f" · refreshed {datetime.now():%d %b %H:%M}")
if st.sidebar.button("↻ Refresh now", use_container_width=True):
    st.cache_data.clear()
    st.rerun()
sel_cities = st.sidebar.multiselect("City", CITIES, default=CITIES)
rng = st.sidebar.date_input("Date range", (max(lo, hi - pd.Timedelta(days=180)), hi), min_value=lo, max_value=hi)
platforms = sorted(orders.platform.dropna().unique())
sel_plat = st.sidebar.multiselect("Platform", platforms, default=platforms)
if not sel_cities or not isinstance(rng, tuple) or len(rng) != 2 or not sel_plat:
    st.info("Pick at least one city, a platform and a full date range.")
    st.stop()

d0, d1 = pd.Timestamp(rng[0]), pd.Timestamp(rng[1])
mask = orders.city.isin(sel_cities) & orders.platform.isin(sel_plat)
cur = orders[mask & orders.order_date.between(d0, d1)]
span = d1 - d0 + pd.Timedelta(days=1)
prev = orders[mask & orders.order_date.between(d0 - span, d0 - pd.Timedelta(days=1))]

k, kp = kpis(cur), kpis(prev) if len(prev) else None

# ------------------------------------------------------------------ header + KPIs
st.title(f"{inr(k['gmv'])} GMV · {100 * (1 - k['ot']):.0f}% of orders late")
st.caption(f"{d0:%d %b %Y} – {d1:%d %b %Y} · {', '.join(sel_cities) if len(sel_cities) < 6 else 'all cities'} · "
           "delta vs the previous period of equal length")


def delta(key, pp=False, fmt="{:+.1f}"):
    if not kp or not kp[key]:
        return None
    return (fmt.format((k[key] - kp[key]) * 100) + " pp") if pp else (fmt.format((k[key] / kp[key] - 1) * 100) + "%")


c = st.columns(6)
c[0].metric("Orders", f"{k['orders']:,}", delta("orders"))
c[1].metric("GMV", inr(k["gmv"]), delta("gmv"))
c[2].metric("AOV", f"₹{k['aov']:,.0f}", delta("aov"))
c[3].metric("Contribution margin", f"{100 * k['cm']:.1f}%", delta("cm", pp=True))
c[4].metric("On-time (SLA)", f"{100 * k['ot']:.1f}%", delta("ot", pp=True))
c[5].metric("Cancelled", f"{100 * k['cx']:.1f}%", delta("cx", pp=True), delta_color="inverse")

tab_exec, tab_ops, tab_cust = st.tabs(["📈 Executive", "🛵 Delivery SLA", "👥 Customers & VoC"])

# ------------------------------------------------------------------ Executive
with tab_exec:
    metric = st.radio("Metric", ["GMV", "Orders", "On-time %"], horizontal=True)
    wk = cur.assign(week=cur.order_date.dt.to_period("W").dt.start_time).groupby(["week", "city"])
    t = pd.DataFrame({"GMV": wk.gross_item_value.sum(), "Orders": wk.size(),
                      "On-time %": wk.is_on_time.apply(lambda s: (s == 1).sum() / max(s.notna().sum(), 1))}).reset_index()
    st.altair_chart(alt.Chart(t).mark_line(strokeWidth=2).encode(
        x=alt.X("week:T", title=None),
        y=alt.Y(f"{metric}:Q", title=metric, axis=alt.Axis(format="%" if metric == "On-time %" else ",.0f")),
        color=alt.Color("city:N", scale=CITY_SCALE, legend=alt.Legend(orient="bottom", title=None)),
        tooltip=["week:T", "city:N", alt.Tooltip(f"{metric}:Q", format=".1%" if metric == "On-time %" else ",.0f")]
    ).properties(height=340, title=f"Weekly {metric} by city"), use_container_width=True)

    l, r = st.columns(2)
    dv = cur[cur.is_delivered == 1]
    bridge = pd.DataFrame({"step": ["Delivered GMV", "− Discounts", "+ Delivery fees", "− COGS", "= Contribution margin"],
                           "value": [dv.gross_item_value.sum(), dv.discount_amount.sum(), dv.delivery_fee.sum(),
                                     dv.cogs.sum(), cur.contribution_margin.sum()],
                           "kind": ["base", "cost", "add", "cost", "result"]})
    l.altair_chart(alt.Chart(bridge).mark_bar(cornerRadiusEnd=4).encode(
        y=alt.Y("step:N", sort=None, title=None), x=alt.X("value:Q", title="₹"),
        color=alt.Color("kind:N", legend=None, scale=alt.Scale(domain=["base", "add", "cost", "result"],
                                                               range=["#2a78d6", "#2a78d6", "#d03b3b", "#e0115f"])),
        tooltip=["step", alt.Tooltip("value:Q", format=",.0f")]).properties(height=260, title="Where the GMV goes"),
        use_container_width=True)
    city_tbl = cur.groupby("city").apply(lambda g: pd.Series(kpis(g))).reset_index()
    r.dataframe(city_tbl.rename(columns={"orders": "Orders", "gmv": "GMV", "aov": "AOV", "cm": "CM %", "ot": "On-time", "cx": "Cancelled"})
                .style.format({"GMV": inr, "AOV": "₹{:,.0f}", "CM %": "{:.1%}", "On-time": "{:.1%}", "Cancelled": "{:.1%}", "Orders": "{:,.0f}"}),
                use_container_width=True, hide_index=True)

# ------------------------------------------------------------------ SLA
with tab_ops:
    timed = cur[cur.delivery_minutes.notna()]
    heat = timed.groupby(["city", "order_hour"]).agg(on_time=("is_on_time", "mean"), n=("order_id", "size")).reset_index()
    st.altair_chart(alt.Chart(heat).mark_rect(cornerRadius=3).encode(
        x=alt.X("order_hour:O", title="Hour of day"), y=alt.Y("city:N", title=None),
        color=alt.Color("on_time:Q", title="On-time", scale=alt.Scale(domain=[0.45, 0.7, 0.95], range=["#d03b3b", "#f0efec", "#2a78d6"], clamp=True)),
        tooltip=["city", "order_hour", alt.Tooltip("on_time:Q", format=".1%"), "n"]
    ).properties(height=280, title="On-time rate · city × hour"), use_container_width=True)

    l, r = st.columns([3, 2])
    city = l.selectbox("City for daily view", sel_cities)
    daily = timed[timed.city == city].groupby("order_date").agg(
        mins=("delivery_minutes", "mean"), orders=("order_id", "size")).reset_index().sort_values("order_date")
    daily["baseline"] = daily.mins.shift(1).rolling(28, min_periods=7).mean()
    daily["anomaly"] = daily.mins > 2 * daily.baseline
    base = alt.Chart(daily).encode(x=alt.X("order_date:T", title=None))
    l.altair_chart((base.mark_line(strokeWidth=1.5, color=CITY_COLORS[CITIES.index(city)]).encode(
        y=alt.Y("mins:Q", title="Avg delivery min"), tooltip=["order_date:T", alt.Tooltip("mins:Q", format=".1f"), "orders"])
        + base.transform_filter("datum.anomaly").mark_point(filled=True, size=90, color="#e0115f").encode(y="mins:Q")
    ).properties(height=280, title=f"{city}: daily delivery time (pink = anomaly > 2× 28-day mean)"), use_container_width=True)
    an = daily[daily.anomaly]
    if len(an):
        l.warning(f"⚠️ {len(an)} anomalous day(s). Worst: {an.loc[an.mins.idxmax(), 'order_date']:%d %b %Y} "
                  f"at {an.mins.max():.1f} min.")
    wx = timed.groupby("weather").agg(mins=("delivery_minutes", "mean"), on_time=("is_on_time", "mean")).reset_index()
    r.altair_chart(alt.Chart(wx).mark_bar(cornerRadiusEnd=4, color="#2a78d6").encode(
        y=alt.Y("weather:N", sort="-x", title=None), x=alt.X("mins:Q", title="Avg delivery min"),
        tooltip=["weather", alt.Tooltip("mins:Q", format=".1f"), alt.Tooltip("on_time:Q", format=".1%")]
    ).properties(height=280, title="Weather impact"), use_container_width=True)

    st.subheader("Store league table")
    stl = cur.groupby(["store_id", "city"]).apply(lambda g: pd.Series(kpis(g))).reset_index().sort_values("ot")
    stl["status"] = pd.cut(stl.ot, [-1, 0.65, 0.8, 2], labels=["🔴 Breaching", "🟠 At risk", "🟢 On track"])
    st.dataframe(stl[["store_id", "city", "orders", "gmv", "ot", "cx", "status"]]
                 .style.format({"gmv": inr, "ot": "{:.1%}", "cx": "{:.1%}", "orders": "{:,.0f}"}),
                 use_container_width=True, hide_index=True)

# ------------------------------------------------------------------ Customers
with tab_cust:
    cust = load_customers()
    cust = cust[cust.city.isin(sel_cities)]
    l, r = st.columns(2)
    tiers = cust.groupby("membership_tier").agg(customers=("customer_id", "size"), orders_pm=("orders_per_month", "mean"),
                                                ltv=("lifetime_net_revenue", "mean"), churned=("is_churned_45d", "mean")).reset_index()
    l.subheader("Plus vs Standard")
    l.dataframe(tiers.style.format({"orders_pm": "{:.2f}", "ltv": "₹{:,.0f}", "churned": "{:.1%}", "customers": "{:,}"}),
                use_container_width=True, hide_index=True)
    if "rfm_segment" in cust.columns:
        seg = cust.groupby("rfm_segment").agg(customers=("customer_id", "size"), revenue=("lifetime_net_revenue", "sum")).reset_index()
        l.altair_chart(alt.Chart(seg).mark_bar(cornerRadiusEnd=4, color="#2a78d6").encode(
            y=alt.Y("rfm_segment:N", sort="-x", title=None), x=alt.X("revenue:Q", title="Lifetime net revenue (₹)"),
            tooltip=["rfm_segment", "customers", alt.Tooltip("revenue:Q", format=",.0f")]).properties(height=240, title="Segments"),
            use_container_width=True)
    rv = load_reviews()
    rv = rv[rv.city.isin(sel_cities) & rv.review_date.between(d0, d1) & (rv.complaint_theme != "Positive experience")]
    th = rv.groupby("complaint_theme").agg(n=("rating", "size"), rating=("rating", "mean")).reset_index()
    r.subheader("Voice of customer")
    r.altair_chart(alt.Chart(th).mark_bar(cornerRadiusEnd=4, color="#d03b3b").encode(
        y=alt.Y("complaint_theme:N", sort="-x", title=None), x=alt.X("n:Q", title="Reviews"),
        tooltip=["complaint_theme", "n", alt.Tooltip("rating:Q", format=".2f")]).properties(height=260), use_container_width=True)

st.caption("DashCart is fictional; data is synthetic. Built on Snowflake: Streams & Tasks, Dynamic Tables, Cortex, Snowpark.")
 