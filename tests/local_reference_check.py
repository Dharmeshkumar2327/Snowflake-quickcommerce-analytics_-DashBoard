"""
Offline reference check (no Snowflake account needed).

Re-implements the core of the pipeline in pandas - typed orders, delivery
milestones from the nested JSON, the order fact and Customer 360 - and prints
the headline numbers the Snowflake SQL should reproduce. It also runs the
Snowpark segmentation handler against a tiny fake Session.

    python tests/local_reference_check.py
"""
import gzip
import json
import os
import sys
from datetime import datetime

import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
sys.path.insert(0, os.path.join(ROOT, "snowpark"))


def load():
    rd = lambda n: pd.read_csv(os.path.join(DATA, f"{n}.csv.gz"))
    stores, products, customers = rd("dark_stores"), rd("products"), rd("customers")
    orders, items = rd("orders"), rd("order_items")
    rows = []
    with gzip.open(os.path.join(DATA, "delivery_events.json.gz"), "rt") as f:
        for line in f:
            d = json.loads(line)
            ev = {e["status"]: datetime.fromisoformat(e["ts"]) for e in d["events"]}  # LATERAL FLATTEN + pivot
            mins = (ev["DELIVERED"] - ev["PLACED"]).total_seconds() / 60 if "DELIVERED" in ev else np.nan
            rows.append({"order_id": d["order_id"], "promised_minutes": d["promised_minutes"],
                         "delivery_minutes": mins, "weather": d["conditions"]["weather"]})
    deliveries = pd.DataFrame(rows)
    return stores, products, customers, orders, items, deliveries


def build_fact(stores, products, customers, orders, items, deliveries):
    it = items.merge(products[["product_id", "cost_price"]], on="product_id")
    it["line_amount"] = it.quantity * it.unit_price
    it["line_cogs"] = it.quantity * it.cost_price
    agg = it.groupby("order_id").agg(gmv=("line_amount", "sum"), cogs=("line_cogs", "sum")).reset_index()
    f = (orders.merge(agg, on="order_id", how="left")
               .merge(stores[["store_id", "city"]], on="store_id", how="left")
               .merge(deliveries, on="order_id", how="left")
               .merge(customers[["customer_id", "membership_tier"]], on="customer_id", how="left"))
    f["order_ts"] = pd.to_datetime(f.order_ts)
    f["order_date"] = f.order_ts.dt.normalize()
    delivered = f.order_status == "DELIVERED"
    f["net_revenue"] = np.where(delivered, f.gmv - f.discount_amount + f.delivery_fee, 0)
    f["contribution_margin"] = np.where(delivered, f.net_revenue - f.cogs, 0)
    f["is_on_time"] = np.where(f.delivery_minutes.notna(), f.delivery_minutes <= f.promised_minutes, np.nan)
    return f


def customer_360(f, customers):
    as_of = f.order_date.max()
    g = f.groupby("customer_id")
    c = pd.DataFrame({
        "TOTAL_ORDERS": g.size(),
        "LIFETIME_NET_REVENUE": g.net_revenue.sum(),
        "AVG_BASKET_VALUE": f[f.order_status == "DELIVERED"].groupby("customer_id").gmv.mean(),
        "COUPON_USAGE_RATE": g.coupon_code.apply(lambda s: s.notna().mean()),
        "LATE_DELIVERY_RATE": g.is_on_time.apply(lambda s: 1 - s.dropna().astype(float).mean() if s.notna().any() else 0),
        "FIRST": g.order_date.min(), "LAST": g.order_date.max(),
    })
    c["DAYS_SINCE_LAST_ORDER"] = (as_of - c.LAST).dt.days
    c["TENURE_DAYS"] = (as_of - c.FIRST).dt.days
    months = ((as_of.year - c.FIRST.dt.year) * 12 + (as_of.month - c.FIRST.dt.month)).clip(lower=1)
    c["ORDERS_PER_MONTH"] = c.TOTAL_ORDERS / months
    c = c.reset_index().rename(columns={"customer_id": "CUSTOMER_ID"})
    c = c.merge(customers.rename(columns=str.upper)[["CUSTOMER_ID", "MEMBERSHIP_TIER", "CITY"]], on="CUSTOMER_ID")
    return c.drop(columns=["FIRST", "LAST"])


class FakeSession:
    """Just enough of snowflake.snowpark.Session for segment_customers()."""
    def __init__(self, pdf): self.pdf, self.written, self.query_tag = pdf, None, None
    def table(self, _):
        outer = self
        class T:
            def select(self, cols):
                class S:
                    def to_pandas(self_inner): return outer.pdf[cols].copy()
                return S()
        return T()
    def write_pandas(self, df, *a, **k): self.written = df


def main():
    stores, products, customers, orders, items, deliveries = load()
    f = build_fact(stores, products, customers, orders, items, deliveries)
    d = f[f.order_status == "DELIVERED"]

    print("=== Headline KPIs ===")
    print(f"orders              {len(f):,}")
    print(f"GMV                 ₹{f.gmv.sum() / 1e7:.2f} Cr")
    print(f"net revenue         ₹{f.net_revenue.sum() / 1e7:.2f} Cr")
    print(f"contribution margin {100 * f.contribution_margin.sum() / d.gmv.sum():.1f}% of delivered GMV")
    print(f"AOV                 ₹{d.gmv.mean():.0f}")
    print(f"on-time rate        {100 * d.is_on_time.astype(float).mean():.1f}%")
    print(f"cancellation rate   {100 * (f.order_status == 'CANCELLED').mean():.1f}%")

    print("\n=== Bengaluru rider-strike day (anomaly target) ===")
    b = f[f.city == "Bengaluru"].groupby("order_date").agg(
        orders=("order_id", "size"), avg_min=("delivery_minutes", "mean"),
        cancel=("order_status", lambda s: (s == "CANCELLED").mean()))
    print(b.loc["2026-03-10":"2026-03-14"].round(2))

    print("\n=== Mumbai monsoon DiD (late-rate, pct points) ===")
    m = d[d.city.isin(["Mumbai", "Bengaluru", "Delhi"])].copy()
    m["monsoon"] = m.order_date.dt.month.isin([6, 7, 8, 9])
    m["grp"] = np.where(m.city == "Mumbai", "Mumbai", "Other")
    late = 1 - m.groupby(["grp", "monsoon"]).is_on_time.apply(lambda s: s.astype(float).mean())
    did = (late["Mumbai", True] - late["Mumbai", False]) - (late["Other", True] - late["Other", False])
    print(late.round(3).to_dict(), "-> DiD =", round(100 * did, 1))

    print("\n=== Festival uplift (Diwali 2025-10-20 vs prior 4 Mondays) ===")
    daily = f.groupby("order_date").size()
    base = daily[[pd.Timestamp("2025-10-20") - pd.Timedelta(weeks=w) for w in range(1, 5)]].mean()
    print(f"Diwali orders {daily[pd.Timestamp('2025-10-20')]} vs baseline {base:.0f} -> +{100 * (daily[pd.Timestamp('2025-10-20')] / base - 1):.0f}%")

    c = customer_360(f, customers)
    print("\n=== Plus vs Standard ===")
    print(c.groupby("MEMBERSHIP_TIER").agg(customers=("CUSTOMER_ID", "count"),
                                           orders_pm=("ORDERS_PER_MONTH", "mean"),
                                           ltv=("LIFETIME_NET_REVENUE", "mean"),
                                           churned_45d=("DAYS_SINCE_LAST_ORDER", lambda s: (s > 45).mean())).round(3))

    rev = c.LIFETIME_NET_REVENUE.sort_values(ascending=False)
    share = rev.cumsum() / rev.sum()
    print(f"\nPareto: {100 * ((share < 0.8).sum() + 1) / len(rev):.1f}% of customers generate 80% of net revenue")

    print("\n=== Snowpark segmentation handler (fake session) ===")
    # snowflake-snowpark-python is not needed offline: stub the imports the module makes
    import types
    for name in ["snowflake", "snowflake.snowpark", "snowflake.snowpark.functions", "snowflake.snowpark.window"]:
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["snowflake.snowpark"].Session = object
    sys.modules["snowflake.snowpark.window"].Window = object
    sys.modules["snowflake.snowpark"].functions = sys.modules["snowflake.snowpark.functions"]
    import customer_segmentation as cs
    s = FakeSession(c)
    out = json.loads(cs.segment_customers(s, 3, 6))
    print("k =", out["k"], "silhouette =", out["silhouette"])
    for seg in out["segments"]:
        print("  ", seg)
    assert s.written is not None and len(s.written) == len(c)
    print("\nOK - reference check finished")


if __name__ == "__main__":
    main()
