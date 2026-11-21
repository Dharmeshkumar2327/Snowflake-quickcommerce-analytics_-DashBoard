"""
DashCart Ops & Growth Command Center - Streamlit in Snowflake
Runs inside Snowflake (no credentials, no data egress) via get_active_session().
Deploy: see sql/10_streamlit_app.sql  (or `snow streamlit deploy` with snowflake.yml)
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="DashCart Command Center", layout="wide")
session = get_active_session()
try:
    session.query_tag = '{"project":"dashcart","module":"streamlit"}'   # cost attribution (sql/09)
except Exception:
    pass


@st.cache_data(ttl=900, show_spinner=False)
def q(sql: str) -> pd.DataFrame:
    df = session.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


def inr(x: float) -> str:
    if x >= 1e7:
        return f"₹{x / 1e7:,.2f} Cr"
    if x >= 1e5:
        return f"₹{x / 1e5:,.2f} L"
    return f"₹{x:,.0f}"


# ---------------- sidebar filters ----------------
bounds = q("SELECT MIN(order_date) AS lo, MAX(order_date) AS hi FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS")
lo, hi = pd.to_datetime(bounds.lo[0]).date(), pd.to_datetime(bounds.hi[0]).date()
cities = q("SELECT DISTINCT city FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS ORDER BY 1").city.tolist()

st.sidebar.title("DashCart")
sel_cities = st.sidebar.multiselect("City", cities, default=cities)
date_range = st.sidebar.date_input("Date range", (max(lo, hi - pd.Timedelta(days=90)), hi), min_value=lo, max_value=hi)
if not sel_cities or len(date_range) != 2:
    st.stop()
d0, d1 = date_range
city_list = ", ".join("'" + c.replace("'", "''") + "'" for c in sel_cities)
where = f"order_date BETWEEN '{d0}' AND '{d1}' AND city IN ({city_list})"

tab_exec, tab_ops, tab_cust, tab_ml, tab_voice = st.tabs(
    ["📈 Executive", "🛵 Delivery SLA", "👥 Customers", "🔮 Forecast & Anomalies", "💬 Voice of Customer"])

# ---------------- Executive ----------------
with tab_exec:
    k = q(f"""SELECT SUM(orders) orders, SUM(gmv) gmv, SUM(net_revenue) net_rev, SUM(contribution_margin) cm,
                     SUM(gmv) / NULLIF(SUM(delivered_orders), 0) aov,
                     SUM(cancelled_orders) / NULLIF(SUM(orders), 0) cancel_rate,
                     SUM(on_time_rate * delivered_orders) / NULLIF(SUM(delivered_orders), 0) on_time
              FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS WHERE {where}""").iloc[0]
    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Orders", f"{int(k.orders or 0):,}")
    c2.metric("GMV", inr(float(k.gmv or 0)))
    c3.metric("Contribution margin", inr(float(k.cm or 0)), f"{100 * float(k.cm or 0) / max(float(k.gmv or 1), 1):.1f}% of GMV")
    c4.metric("AOV", f"₹{float(k.aov or 0):,.0f}")
    c5.metric("On-time (SLA)", f"{100 * float(k.on_time or 0):.1f}%", f"{100 * float(k.cancel_rate or 0):.1f}% cancelled", delta_color="off")

    daily = q(f"""SELECT order_date, city, SUM(gmv) gmv FROM DASHCART.MARTS.DT_DAILY_CITY_KPIS
                  WHERE {where} GROUP BY 1, 2 ORDER BY 1""")
    st.subheader("Daily GMV by city")
    st.altair_chart(alt.Chart(daily).mark_area(opacity=0.85).encode(
        x=alt.X("order_date:T", title=None), y=alt.Y("gmv:Q", stack=True, title="GMV (₹)"),
        color=alt.Color("city:N", legend=alt.Legend(orient="bottom")),
        tooltip=["order_date:T", "city:N", alt.Tooltip("gmv:Q", format=",.0f")]).properties(height=320),
        use_container_width=True)

    cat = q(f"""SELECT category, SUM(revenue) revenue, SUM(gross_margin) / NULLIF(SUM(revenue), 0) margin_pct
                FROM DASHCART.MARTS.DT_PRODUCT_DAILY WHERE order_date BETWEEN '{d0}' AND '{d1}'
                GROUP BY 1 ORDER BY 2 DESC""")
    st.subheader("Category revenue & gross margin")
    st.altair_chart(alt.Chart(cat).mark_bar().encode(
        x=alt.X("revenue:Q", title="Revenue (₹)"), y=alt.Y("category:N", sort="-x", title=None),
        color=alt.Color("margin_pct:Q", title="Margin %", scale=alt.Scale(scheme="tealblues")),
        tooltip=["category", alt.Tooltip("revenue:Q", format=",.0f"), alt.Tooltip("margin_pct:Q", format=".1%")]
    ).properties(height=260), use_container_width=True)

# ---------------- Delivery SLA ----------------
with tab_ops:
    heat = q(f"""SELECT city, order_hour, AVG(IFF(is_on_time, 1, 0)) on_time, COUNT(*) n
                 FROM DASHCART.MARTS.DT_ORDERS_ENRICHED
                 WHERE {where} AND order_status = 'DELIVERED' GROUP BY 1, 2""")
    st.subheader("On-time rate: city × hour of day")
    st.altair_chart(alt.Chart(heat).mark_rect().encode(
        x=alt.X("order_hour:O", title="Hour"), y=alt.Y("city:N", title=None),
        color=alt.Color("on_time:Q", title="On-time", scale=alt.Scale(scheme="redyellowgreen", domain=[0.4, 1])),
        tooltip=["city", "order_hour", alt.Tooltip("on_time:Q", format=".1%"), "n"]).properties(height=260),
        use_container_width=True)

    load = q(f"""SELECT store_id, city, order_hour, AVG(utilization) util, AVG(avg_pack_minutes) pack
                 FROM DASHCART.MARTS.DT_STORE_HOURLY_LOAD WHERE {where} GROUP BY 1, 2, 3""")
    st.subheader("Busiest store-hours (avg utilisation of capacity)")
    st.dataframe(load.sort_values("util", ascending=False).head(15)
                 .style.format({"util": "{:.1%}", "pack": "{:.1f} min"}), use_container_width=True)

    wx = q(f"""SELECT weather, COUNT(*) n, AVG(delivery_minutes) mins, AVG(IFF(is_on_time,1,0)) on_time
               FROM DASHCART.MARTS.DT_ORDERS_ENRICHED WHERE {where} AND order_status = 'DELIVERED'
               GROUP BY 1 ORDER BY 3 DESC""")
    st.subheader("Weather impact")
    st.dataframe(wx.style.format({"mins": "{:.1f}", "on_time": "{:.1%}"}), use_container_width=True)

# ---------------- Customers ----------------
with tab_cust:
    coh = q("""WITH f AS (SELECT customer_id, DATE_TRUNC('MONTH', MIN(order_date)) cohort
                          FROM DASHCART.MARTS.DT_ORDERS_ENRICHED GROUP BY 1),
                   a AS (SELECT DISTINCT o.customer_id, f.cohort,
                                DATEDIFF(MONTH, f.cohort, DATE_TRUNC('MONTH', o.order_date)) m
                         FROM DASHCART.MARTS.DT_ORDERS_ENRICHED o JOIN f USING (customer_id))
               SELECT cohort, m, COUNT(*) / MAX(COUNT(*)) OVER (PARTITION BY cohort) retention
               FROM a WHERE m <= 9 GROUP BY 1, 2""")
    st.subheader("Monthly cohort retention")
    st.altair_chart(alt.Chart(coh).mark_rect().encode(
        x=alt.X("m:O", title="Months since first order"), y=alt.Y("yearmonth(cohort):O", title="Cohort"),
        color=alt.Color("retention:Q", scale=alt.Scale(scheme="blues"), title="Retention"),
        tooltip=[alt.Tooltip("yearmonth(cohort):O", title="cohort"), "m", alt.Tooltip("retention:Q", format=".1%")]
    ).properties(height=420), use_container_width=True)

    left, right = st.columns(2)
    with left:
        st.subheader("Plus vs Standard")
        st.dataframe(q("""SELECT membership_tier, COUNT(*) customers, AVG(orders_per_month) orders_pm,
                                 AVG(lifetime_net_revenue) ltv, AVG(IFF(is_churned_45d,1,0)) churned
                          FROM DASHCART.MARTS.V_CUSTOMER_360 GROUP BY 1""")
                     .style.format({"orders_pm": "{:.2f}", "ltv": "₹{:,.0f}", "churned": "{:.1%}"}),
                     use_container_width=True)
    with right:
        st.subheader("Behavioural segments (Snowpark KMeans)")
        try:
            st.dataframe(q("""SELECT segment, COUNT(*) customers, MEDIAN(orders_per_month) orders_pm,
                                     SUM(lifetime_net_revenue) revenue
                              FROM DASHCART.ML.CUSTOMER_SEGMENTS GROUP BY 1 ORDER BY revenue DESC""")
                         .style.format({"orders_pm": "{:.2f}", "revenue": "₹{:,.0f}"}), use_container_width=True)
        except Exception:
            st.info("Run CALL DASHCART.ML.SP_SEGMENT_CUSTOMERS(3, 7) to populate segments.")

    try:
        risk = q("""SELECT risk_band, COUNT(*) customers, SUM(revenue_total) revenue_at_risk
                    FROM DASHCART.ML.CHURN_SCORES GROUP BY 1 ORDER BY 1""")
        st.subheader("Churn risk (Cortex ML classification)")
        st.bar_chart(risk.set_index("risk_band")["customers"])
    except Exception:
        st.info("Run sql/06_cortex_ml_ai.sql section C to score churn.")

# ---------------- Forecast & anomalies ----------------
with tab_ml:
    try:
        fc = q(f"SELECT * FROM DASHCART.ML.V_FORECAST_VS_ACTUAL WHERE city IN ({city_list}) ORDER BY d")
        city = st.selectbox("City", sel_cities)
        f1 = fc[fc.city == city]
        base = alt.Chart(f1).encode(x=alt.X("d:T", title=None))
        band = base.mark_area(opacity=0.2).encode(y="lower_90:Q", y2="upper_90:Q")
        actual = base.mark_line().encode(y=alt.Y("actual:Q", title="Orders / day"))
        fcl = base.mark_line(strokeDash=[5, 3]).encode(y="forecast:Q")
        st.subheader(f"30-day order forecast – {city} (90% interval)")
        st.altair_chart((band + actual + fcl).properties(height=320), use_container_width=True)
    except Exception:
        st.info("Run sql/06_cortex_ml_ai.sql section A to create the forecast.")

    try:
        an = q("""SELECT city, anomaly_date, ROUND(avg_delivery_minutes,1) actual_min,
                         ROUND(expected_minutes,1) expected_min, ROUND(distance,2) severity
                  FROM DASHCART.ML.OPS_ANOMALIES WHERE is_anomaly ORDER BY distance DESC LIMIT 20""")
        st.subheader("Detected operational anomalies")
        st.dataframe(an, use_container_width=True)
    except Exception:
        st.info("Run sql/06_cortex_ml_ai.sql section B for anomaly detection.")

# ---------------- Voice of customer ----------------
with tab_voice:
    try:
        rv = q(f"""SELECT complaint_theme, COUNT(*) n, AVG(sentiment_score) sentiment, AVG(rating) rating
                   FROM DASHCART.ML.REVIEWS_ENRICHED
                   WHERE city IN ({city_list}) AND review_ts::DATE BETWEEN '{d0}' AND '{d1}'
                   GROUP BY 1 ORDER BY n DESC""")
        st.subheader("Review themes (Cortex CLASSIFY_TEXT + SENTIMENT)")
        st.altair_chart(alt.Chart(rv).mark_bar().encode(
            x=alt.X("n:Q", title="Reviews"), y=alt.Y("complaint_theme:N", sort="-x", title=None),
            color=alt.Color("sentiment:Q", scale=alt.Scale(scheme="redyellowgreen", domain=[-1, 1])),
            tooltip=["complaint_theme", "n", alt.Tooltip("sentiment:Q", format=".2f"), alt.Tooltip("rating:Q", format=".2f")]
        ).properties(height=260), use_container_width=True)

        st.subheader("AI briefs for store managers (Cortex COMPLETE)")
        briefs = q(f"SELECT store_id, city, n_negative, manager_brief FROM DASHCART.ML.STORE_REVIEW_BRIEFS "
                   f"WHERE city IN ({city_list}) ORDER BY n_negative DESC LIMIT 5")
        for r in briefs.itertuples():
            with st.expander(f"{r.store_id} · {r.city} · {r.n_negative} negative reviews"):
                st.write(r.manager_brief)
    except Exception:
        st.info("Run sql/06_cortex_ml_ai.sql section D for Cortex review enrichment.")

st.caption("Data: synthetic DashCart dataset · Built on Snowflake (Dynamic Tables, Streams & Tasks, Cortex, Snowpark)")
