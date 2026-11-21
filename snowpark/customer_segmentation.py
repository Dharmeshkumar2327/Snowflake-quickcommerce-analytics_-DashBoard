"""
Snowpark Python: behavioural customer segmentation that runs INSIDE Snowflake.

* store_weekly_metrics()  - Snowpark DataFrame API; everything is pushed down as SQL
* segment_customers()     - stored-procedure handler: scikit-learn KMeans on
                            customer features, auto-picks k by silhouette score,
                            names clusters from their centroids and writes
                            DASHCART.ML.CUSTOMER_SEGMENTS
* haversine_km()          - vectorized (pandas) UDF: rider distance store -> point

Deployed by snowpark/deploy.py.
"""
from __future__ import annotations

import json

import numpy as np
import pandas as pd
from snowflake.snowpark import Session
from snowflake.snowpark import functions as F
from snowflake.snowpark.window import Window

FEATURES = [
    "TOTAL_ORDERS", "ORDERS_PER_MONTH", "AVG_BASKET_VALUE", "LIFETIME_NET_REVENUE",
    "DAYS_SINCE_LAST_ORDER", "COUPON_USAGE_RATE", "LATE_DELIVERY_RATE", "TENURE_DAYS",
]


# ---------------------------------------------------------------------------
# 1. DataFrame API example (lazy, executed as a single SQL query in Snowflake)
# ---------------------------------------------------------------------------
def store_weekly_metrics(session: Session):
    o = session.table("DASHCART.MARTS.DT_ORDERS_ENRICHED")
    weekly = (
        o.filter(F.col("ORDER_STATUS") == "DELIVERED")
         .group_by("STORE_ID", "CITY", F.date_trunc("week", F.col("ORDER_DATE")).alias("WEEK"))
         .agg(F.count("ORDER_ID").alias("ORDERS"),
              F.sum("NET_REVENUE").alias("NET_REVENUE"),
              F.avg(F.iff(F.col("IS_ON_TIME"), F.lit(1), F.lit(0))).alias("ON_TIME_RATE"))
    )
    w = Window.partition_by("STORE_ID").order_by("WEEK")
    return weekly.with_column("REVENUE_WOW_PCT",
                              (F.col("NET_REVENUE") / F.lag("NET_REVENUE", 1).over(w) - 1) * 100)


# ---------------------------------------------------------------------------
# 2. Stored procedure handler
# ---------------------------------------------------------------------------
def _name_cluster(c: pd.Series, overall: pd.Series) -> str:
    """Human-readable label from a centroid (in original units) vs the population median."""
    if c["DAYS_SINCE_LAST_ORDER"] > 2.5 * overall["DAYS_SINCE_LAST_ORDER"]:
        return "Lapsed"
    if c["ORDERS_PER_MONTH"] > 2.0 * overall["ORDERS_PER_MONTH"] and c["LIFETIME_NET_REVENUE"] > 2 * overall["LIFETIME_NET_REVENUE"]:
        return "Power Shoppers"
    if c["COUPON_USAGE_RATE"] > 1.4 * max(overall["COUPON_USAGE_RATE"], 0.01):
        return "Deal Seekers"
    if c["AVG_BASKET_VALUE"] > 1.3 * overall["AVG_BASKET_VALUE"]:
        return "Big-Basket Planners"
    if c["LATE_DELIVERY_RATE"] > 1.5 * max(overall["LATE_DELIVERY_RATE"], 0.01):
        return "SLA-Burned"
    if c["TENURE_DAYS"] < 0.6 * overall["TENURE_DAYS"]:
        return "New & Exploring"
    return "Steady Regulars"


def segment_customers(session: Session, min_k: int = 3, max_k: int = 7) -> str:
    from sklearn.cluster import KMeans
    from sklearn.metrics import silhouette_score
    from sklearn.preprocessing import StandardScaler

    session.query_tag = json.dumps({"project": "dashcart", "module": "snowpark_segmentation"})
    pdf = session.table("DASHCART.MARTS.V_CUSTOMER_360").select(["CUSTOMER_ID", "MEMBERSHIP_TIER", "CITY", *FEATURES]).to_pandas()
    pdf[FEATURES] = pdf[FEATURES].astype(float).fillna(0.0)

    # log-transform heavy-tailed money/count features before scaling
    X = pdf[FEATURES].copy()
    for col in ["TOTAL_ORDERS", "LIFETIME_NET_REVENUE", "AVG_BASKET_VALUE", "ORDERS_PER_MONTH"]:
        X[col] = np.log1p(X[col].clip(lower=0))
    Xs = StandardScaler().fit_transform(X)

    sample = np.random.default_rng(7).choice(len(Xs), size=min(len(Xs), 5000), replace=False)
    best = None
    for k in range(min_k, max_k + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(Xs)
        score = silhouette_score(Xs[sample], km.labels_[sample])
        if best is None or score > best[1]:
            best = (k, score, km)
    k, score, km = best

    pdf["CLUSTER_ID"] = km.labels_
    overall = pdf[FEATURES].median()
    centroids = pdf.groupby("CLUSTER_ID")[FEATURES].median()
    names, used = {}, set()
    for cid, row in centroids.iterrows():
        n = _name_cluster(row, overall)
        names[cid] = n if n not in used else f"{n} {cid}"
        used.add(n)
    pdf["SEGMENT"] = pdf["CLUSTER_ID"].map(names)
    pdf["MODEL_K"] = k
    pdf["SILHOUETTE"] = round(float(score), 4)
    pdf["SCORED_AT"] = pd.Timestamp.utcnow().tz_localize(None)

    session.write_pandas(pdf, "CUSTOMER_SEGMENTS", database="DASHCART", schema="ML",
                         auto_create_table=True, overwrite=True, quote_identifiers=False)

    summary = (pdf.groupby("SEGMENT")
                  .agg(customers=("CUSTOMER_ID", "count"),
                       revenue=("LIFETIME_NET_REVENUE", "sum"),
                       orders_per_month=("ORDERS_PER_MONTH", "median"),
                       pct_plus=("MEMBERSHIP_TIER", lambda s: round(100 * (s == "Plus").mean(), 1)))
                  .round(2).reset_index().to_dict(orient="records"))
    return json.dumps({"k": k, "silhouette": round(float(score), 4), "segments": summary}, default=str)


# ---------------------------------------------------------------------------
# 3. Vectorized UDF handler
# ---------------------------------------------------------------------------
def haversine_km(lat1: pd.Series, lon1: pd.Series, lat2: pd.Series, lon2: pd.Series) -> pd.Series:
    r = 6371.0
    p1, p2 = np.radians(lat1.astype(float)), np.radians(lat2.astype(float))
    dphi = p2 - p1
    dlmb = np.radians(lon2.astype(float) - lon1.astype(float))
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dlmb / 2) ** 2
    return pd.Series(2 * r * np.arcsin(np.sqrt(a)))
