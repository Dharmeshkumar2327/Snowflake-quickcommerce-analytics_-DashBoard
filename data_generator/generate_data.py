"""
DashCart synthetic data generator
=================================
Generates realistic, reproducible data for a fictional Indian quick-commerce
company ("DashCart": 10-minute grocery delivery from dark stores).

Outputs (gzip-compressed, Snowflake reads .gz natively):
    data/dark_stores.csv.gz
    data/customers.csv.gz
    data/customer_updates.csv.gz      <- changes used to demo SCD Type 2 via Streams + MERGE
    data/products.csv.gz
    data/orders.csv.gz
    data/order_items.csv.gz
    data/reviews.csv.gz               <- free text, scored by Snowflake Cortex SENTIMENT
    data/delivery_events.json.gz      <- nested NDJSON (VARIANT + LATERAL FLATTEN demo)
    data/app_events.json.gz           <- nested NDJSON clickstream (funnel / sessions demo)

Built-in patterns the analysis should recover:
    * evening (18-22h) and weekend demand peaks
    * festival spikes (Holi, Diwali, Christmas/New Year) and a Diwali-week SLA squeeze
    * Mumbai monsoon (Jun-Sep) delivery delays
    * a Bengaluru rider-strike day (2026-03-12): 3.5x delivery time + cancellations -> anomaly detection flags it
    * DashCart Plus members order more often and churn less
    * review sentiment tracks rating and delivery delay

Usage:
    python generate_data.py --orders 90000 --seed 42 --out ../data
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
from datetime import datetime, timedelta

import numpy as np
import pandas as pd

START = datetime(2025, 1, 1)
END = datetime(2026, 10, 31, 23, 59, 59)

CITIES = {
    # city: (lat, lon, weight, n_stores)
    "Bengaluru": (12.9716, 77.5946, 0.24, 6),
    "Mumbai": (19.0760, 72.8777, 0.22, 5),
    "Delhi": (28.6139, 77.2090, 0.20, 5),
    "Hyderabad": (17.3850, 78.4867, 0.13, 3),
    "Pune": (18.5204, 73.8567, 0.11, 3),
    "Chennai": (13.0827, 80.2707, 0.10, 2),
}
CITY_CODES = {"Bengaluru": "BLR", "Mumbai": "BOM", "Delhi": "DEL", "Hyderabad": "HYD", "Pune": "PNQ", "Chennai": "MAA"}
ZONES = ["North", "South", "East", "West", "Central", "Outer"]

FESTIVALS = {  # date -> demand multiplier (applied to +/- 2 days window, peak on day)
    "2025-03-14": 1.6,  # Holi
    "2025-08-15": 1.3,  # Independence Day
    "2025-10-20": 2.2,  # Diwali
    "2025-12-25": 1.4,
    "2025-12-31": 1.9,
    "2026-03-04": 1.6,  # Holi
    "2026-08-15": 1.3,
}
INCIDENT_CITY, INCIDENT_DAY = "Bengaluru", "2026-03-12"  # rider strike

CATALOG = {
    # category: [(sub_category, [brands], mrp_range, perishable)]
    "Fruits & Vegetables": [("Fresh Fruits", ["FarmFresh", "DashCart Fresh"], (30, 250), True),
                            ("Fresh Vegetables", ["FarmFresh", "DashCart Fresh"], (15, 120), True)],
    "Dairy & Bakery": [("Milk", ["Amul", "Nandini", "Mother Dairy"], (28, 75), True),
                       ("Bread & Eggs", ["Britannia", "Modern", "DashCart Fresh"], (35, 120), True),
                       ("Paneer & Curd", ["Amul", "Milky Mist"], (40, 180), True)],
    "Staples": [("Atta & Rice", ["Aashirvaad", "India Gate", "Fortune"], (90, 650), False),
                ("Dal & Pulses", ["Tata Sampann", "DashCart Select"], (80, 260), False),
                ("Oils & Ghee", ["Fortune", "Saffola", "Amul"], (140, 750), False)],
    "Snacks & Beverages": [("Chips & Namkeen", ["Haldiram's", "Lay's", "Bingo"], (10, 120), False),
                           ("Soft Drinks", ["Coca-Cola", "Pepsi", "Paper Boat"], (20, 110), False),
                           ("Tea & Coffee", ["Tata Tea", "Bru", "Nescafe"], (60, 520), False)],
    "Personal Care": [("Bath & Body", ["Dove", "Lux", "Mamaearth"], (45, 420), False),
                      ("Oral Care", ["Colgate", "Sensodyne"], (40, 220), False)],
    "Household": [("Cleaning", ["Vim", "Surf Excel", "Harpic"], (35, 480), False),
                  ("Kitchen Needs", ["Scotch-Brite", "DashCart Home"], (50, 350), False)],
    "Frozen & Instant": [("Instant Food", ["Maggi", "Yippee", "MTR"], (14, 180), False),
                         ("Ice Cream", ["Kwality Walls", "Amul", "Havmor"], (30, 350), True)],
}
CATEGORY_WEIGHTS = {"Fruits & Vegetables": 0.22, "Dairy & Bakery": 0.20, "Staples": 0.12,
                    "Snacks & Beverages": 0.20, "Personal Care": 0.08, "Household": 0.08,
                    "Frozen & Instant": 0.10}

FIRST = ["Aarav", "Vivaan", "Aditya", "Ananya", "Diya", "Ishaan", "Kavya", "Rohan", "Priya", "Arjun",
         "Sneha", "Rahul", "Neha", "Karthik", "Meera", "Siddharth", "Pooja", "Vikram", "Riya", "Aman",
         "Lakshmi", "Harsh", "Divya", "Nikhil", "Tanvi", "Suresh", "Fatima", "Imran", "Gurpreet", "Joseph"]
LAST = ["Sharma", "Verma", "Iyer", "Reddy", "Patel", "Nair", "Gupta", "Singh", "Rao", "Kumar",
        "Menon", "Joshi", "Das", "Khan", "Mehta", "Pillai", "Banerjee", "Chopra", "Shetty", "D'Souza"]

POS_REVIEWS = ["Delivered super fast, everything fresh. Loved it!", "Great service, rider was polite and quick.",
               "Fresh vegetables and on-time delivery. Will order again.", "Amazing, arrived in under 10 minutes!",
               "Good packaging and correct items. Happy with DashCart."]
NEU_REVIEWS = ["Order was okay, one item was missing but refunded.", "Delivery took a bit longer than promised.",
               "Average experience, nothing special.", "Products fine, app was slow during checkout."]
NEG_REVIEWS = ["Very late delivery, ice cream had melted. Terrible.", "Wrong items delivered and support was unhelpful.",
               "Milk packet was leaking and the order came 40 minutes late.", "Worst experience, order cancelled after waiting.",
               "Vegetables were not fresh at all. Disappointed."]


def build_stores(rng):
    rows = []
    for city, (lat, lon, _, n) in CITIES.items():
        code = CITY_CODES[city]
        for i in range(1, n + 1):
            rows.append({
                "store_id": f"STR-{code}-{i:02d}",
                "store_name": f"DashCart {city} {ZONES[(i - 1) % len(ZONES)]} Hub",
                "city": city,
                "zone": ZONES[(i - 1) % len(ZONES)],
                "latitude": round(lat + rng.normal(0, 0.05), 5),
                "longitude": round(lon + rng.normal(0, 0.05), 5),
                "opened_date": (START - timedelta(days=int(rng.integers(30, 400)))).date().isoformat(),
                "capacity_orders_per_hour": int(rng.choice([60, 80, 100, 120])),
            })
    return pd.DataFrame(rows)


def build_products(rng):
    rows, pid = [], 1
    for cat, subs in CATALOG.items():
        for sub, brands, (lo, hi), perishable in subs:
            for brand in brands:
                for v in range(int(rng.integers(5, 10))):
                    mrp = float(round(rng.uniform(lo, hi), 0))
                    margin = rng.uniform(0.12, 0.35) if "DashCart" in brand else rng.uniform(0.06, 0.2)
                    rows.append({
                        "product_id": f"P{pid:05d}",
                        "sku": f"SKU-{cat[:2].upper()}{pid:05d}",
                        "product_name": f"{brand} {sub} Pack {v + 1}",
                        "category": cat, "sub_category": sub, "brand": brand,
                        "mrp": mrp, "cost_price": round(mrp * (1 - margin), 2),
                        "is_perishable": perishable,
                    })
                    pid += 1
    return pd.DataFrame(rows)


def build_customers(rng, n):
    cities = list(CITIES)
    w = np.array([CITIES[c][2] for c in cities]); w /= w.sum()
    span = (END - timedelta(days=60) - START).days
    # more signups later (growth curve)
    signup_offsets = (np.sqrt(rng.uniform(0, 1, n)) * span).astype(int)
    first = rng.choice(FIRST, n); last = rng.choice(LAST, n)
    df = pd.DataFrame({
        "customer_id": [f"C{i:06d}" for i in range(1, n + 1)],
        "full_name": [f"{a} {b}" for a, b in zip(first, last)],
        "email": [f"{a.lower()}.{b.lower().replace(chr(39), '')}{i}@example.com" for i, (a, b) in enumerate(zip(first, last), 1)],
        "phone": [f"+91-9{rng.integers(100000000, 999999999)}" for _ in range(n)],
        "city": rng.choice(cities, n, p=w),
        "signup_date": [(START + timedelta(days=int(o))).date().isoformat() for o in signup_offsets],
        "acquisition_channel": rng.choice(["Organic", "Referral", "Google Ads", "Instagram", "Influencer", "Offline"],
                                          n, p=[0.30, 0.15, 0.20, 0.18, 0.10, 0.07]),
        "membership_tier": rng.choice(["Standard", "Plus"], n, p=[0.78, 0.22]),
        "birth_year": rng.integers(1960, 2006, n),
    })
    df["updated_at"] = pd.to_datetime(df["signup_date"]).dt.strftime("%Y-%m-%d 09:00:00")
    return df


def build_customer_updates(rng, customers):
    """~6% of customers change city or tier -> SCD2 history."""
    upd = customers.sample(frac=0.06, random_state=7).copy()
    cities = list(CITIES)
    move = rng.uniform(0, 1, len(upd)) < 0.5
    upd.loc[move, "city"] = [rng.choice([c for c in cities if c != old]) for old in upd.loc[move, "city"]]
    upd.loc[~move, "membership_tier"] = np.where(upd.loc[~move, "membership_tier"] == "Plus", "Standard", "Plus")
    upd["updated_at"] = "2026-11-01 02:00:00"
    return upd


def demand_multiplier(day: pd.Timestamp) -> float:
    m = 1.0 + 0.25 * (day.dayofweek >= 5)
    # business growth ~ +55% across the period
    m *= 1 + 0.55 * (day - pd.Timestamp(START)).days / (pd.Timestamp(END) - pd.Timestamp(START)).days
    for d, f in FESTIVALS.items():
        gap = abs((day - pd.Timestamp(d)).days)
        if gap <= 2:
            m *= 1 + (f - 1) * (1 - gap / 3)
    return m


def build_orders(rng, n_orders, customers, stores, products):
    days = pd.date_range(START.date(), END.date(), freq="D")
    mult = np.array([demand_multiplier(d) for d in days])
    per_day = rng.multinomial(n_orders, mult / mult.sum())

    hour_w = np.array([1, .5, .3, .2, .2, .4, 1.2, 2.5, 3.2, 2.8, 2.4, 2.4, 2.8, 2.6, 2.2, 2.2,
                       2.6, 3.4, 4.6, 5.2, 5.0, 4.2, 3.0, 1.8]); hour_w /= hour_w.sum()

    cust = customers.copy()
    cust["signup_dt"] = pd.to_datetime(cust["signup_date"])
    # propensity: Plus members ~2.3x, plus long-tail heterogeneity
    cust["prop"] = rng.gamma(0.9, 1.0, len(cust)) * np.where(cust["membership_tier"] == "Plus", 2.3, 1.0)
    stores_by_city = stores.groupby("city")["store_id"].apply(list).to_dict()

    prod_ids = products["product_id"].to_numpy()
    prod_mrp = products["mrp"].to_numpy()
    pw = products["category"].map(CATEGORY_WEIGHTS).to_numpy() / products.groupby("category")["product_id"].transform("count").to_numpy()
    pw = pw / pw.sum()

    orders, items, deliveries = [], [], []
    oid = 1
    cust_sorted = cust.sort_values("signup_dt").reset_index(drop=True)
    signup_np = cust_sorted["signup_dt"].to_numpy()
    for day, k in zip(days, per_day):
        if k == 0:
            continue
        eligible = np.searchsorted(signup_np, np.datetime64(day), side="right")
        if eligible == 0:
            continue
        pool = cust_sorted.iloc[:eligible]
        # recency decay: older customers slowly churn (cohort retention curve)
        age = (day - pool["signup_dt"]).dt.days.to_numpy()
        churn_rate = np.where(pool["membership_tier"].to_numpy() == "Plus", 1 / 900, 1 / 360)
        p = pool["prop"].to_numpy() * np.exp(-age * churn_rate) * (1 + 1.5 * (age < 30))
        p = p / p.sum()
        chosen = rng.choice(eligible, k, p=p)
        hours = rng.choice(24, k, p=hour_w)
        mumbai_monsoon = day.month in (6, 7, 8, 9)
        diwali_week = abs((day - pd.Timestamp("2025-10-20")).days) <= 3
        for ci, hr in zip(chosen, hours):
            c = pool.iloc[ci]
            store = rng.choice(stores_by_city[c["city"]])
            ts = datetime(day.year, day.month, day.day, int(hr), int(rng.integers(0, 60)), int(rng.integers(0, 60)))
            order_id = f"ORD{oid:08d}"; oid += 1

            n_lines = int(min(12, 1 + rng.poisson(2.4)))
            picks = rng.choice(len(prod_ids), n_lines, replace=False, p=pw)
            subtotal = 0.0
            for ln, pi in enumerate(picks, 1):
                qty = int(1 + rng.poisson(0.5))
                unit = float(round(prod_mrp[pi] * rng.uniform(0.88, 1.0), 2))
                items.append({"order_id": order_id, "line_no": ln, "product_id": prod_ids[pi],
                              "quantity": qty, "unit_price": unit})
                subtotal += qty * unit

            coupon = rng.choice(["", "", "", "FIRST50", "DASH20", "FESTIVE100", "PLUSFREE"])
            discount = {"": 0, "FIRST50": min(50, subtotal * .5), "DASH20": subtotal * .2 if subtotal > 199 else 0,
                        "FESTIVE100": 100 if subtotal > 499 else 0, "PLUSFREE": 0}[coupon]
            delivery_fee = 0 if (c["membership_tier"] == "Plus" or subtotal >= 199) else 25

            # --- delivery timing ---
            promised = 10 if c["city"] in ("Bengaluru", "Mumbai", "Delhi") else 15
            base = rng.gamma(6, 1.4)  # ~8.4 min mean
            if 18 <= hr <= 21: base *= 1.18
            if c["city"] == "Mumbai" and mumbai_monsoon: base *= 1.45
            if diwali_week: base *= 1.35
            outage = (c["city"] == INCIDENT_CITY and str(day.date()) == INCIDENT_DAY)
            if outage: base *= 3.5
            actual = round(float(base), 1)

            r = rng.uniform()
            cancel_p = 0.025 + (0.35 if outage else 0) + (0.02 if actual > promised * 2 else 0)
            status = "CANCELLED" if r < cancel_p else ("RETURNED" if r < cancel_p + 0.012 else "DELIVERED")

            orders.append({
                "order_id": order_id, "customer_id": c["customer_id"], "store_id": store,
                "order_ts": ts.strftime("%Y-%m-%d %H:%M:%S"),
                "platform": rng.choice(["android", "ios", "web"], p=[0.62, 0.31, 0.07]),
                "payment_method": rng.choice(["UPI", "Card", "COD", "Wallet"], p=[0.68, 0.14, 0.10, 0.08]),
                "coupon_code": coupon, "discount_amount": round(float(discount), 2),
                "delivery_fee": delivery_fee, "order_status": status,
            })

            # nested delivery event document
            t0 = ts
            ev = [{"status": "PLACED", "ts": t0.isoformat()}]
            if status != "CANCELLED":
                pack = max(1.0, actual * 0.3)
                ev += [{"status": "PACKED", "ts": (t0 + timedelta(minutes=pack)).isoformat()},
                       {"status": "PICKED_UP", "ts": (t0 + timedelta(minutes=pack + 0.8)).isoformat()},
                       {"status": "DELIVERED", "ts": (t0 + timedelta(minutes=actual)).isoformat()}]
            else:
                ev.append({"status": "CANCELLED", "ts": (t0 + timedelta(minutes=float(rng.uniform(2, 25)))).isoformat()})
            deliveries.append({
                "order_id": order_id,
                "store_id": store,
                "promised_minutes": promised,
                "rider": {"rider_id": f"R{rng.integers(1, 900):04d}",
                          "vehicle": str(rng.choice(["EV-Scooter", "Bike", "Bicycle"], p=[.55, .40, .05]))},
                "conditions": {"weather": "Heavy Rain" if (c["city"] == "Mumbai" and mumbai_monsoon and rng.uniform() < .6)
                               else str(rng.choice(["Clear", "Cloudy", "Light Rain"], p=[.7, .2, .1])),
                               "distance_km": round(float(rng.uniform(0.4, 3.5)), 2)},
                "events": ev,
            })
    return pd.DataFrame(orders), pd.DataFrame(items), deliveries


def build_reviews(rng, orders, deliveries):
    delay = {d["order_id"]: d for d in deliveries}
    delivered = orders[orders["order_status"] != "CANCELLED"].sample(frac=0.12, random_state=3)
    rows = []
    for i, o in enumerate(delivered.itertuples(), 1):
        d = delay[o.order_id]
        ts = [e for e in d["events"] if e["status"] == "DELIVERED"]
        mins = (datetime.fromisoformat(ts[0]["ts"]) - datetime.fromisoformat(d["events"][0]["ts"])).total_seconds() / 60 if ts else 30
        late = mins / d["promised_minutes"]
        mu = 4.6 - 1.4 * max(0, late - 1) - (1.5 if o.order_status == "RETURNED" else 0)
        rating = int(np.clip(round(rng.normal(mu, 0.8)), 1, 5))
        text = rng.choice(POS_REVIEWS if rating >= 4 else NEU_REVIEWS if rating == 3 else NEG_REVIEWS)
        rts = datetime.fromisoformat(o.order_ts) + timedelta(hours=float(rng.uniform(1, 48)))
        rows.append({"review_id": f"RV{i:07d}", "order_id": o.order_id, "customer_id": o.customer_id,
                     "rating": rating, "review_text": text, "review_ts": rts.strftime("%Y-%m-%d %H:%M:%S")})
    return pd.DataFrame(rows)


def build_app_events(rng, orders, customers, products, n_sessions):
    """Clickstream sessions: app_open -> search -> view_product -> add_to_cart -> checkout -> purchase."""
    purchases = orders.sample(n=min(n_sessions // 3, len(orders)), random_state=11)
    prod_ids = products["product_id"].to_numpy()
    queries = ["milk", "atta", "maggi", "eggs", "bread", "chips", "coke", "onion", "banana", "detergent", "ice cream", "paneer"]
    out, eid = [], 1

    def emit(sid, cust, t, etype, os_, ver, props):
        nonlocal eid
        out.append({"event_id": f"E{eid:09d}", "session_id": sid, "customer_id": cust, "event_type": etype,
                    "event_ts": t.isoformat(), "device": {"os": os_, "app_version": ver}, "properties": props})
        eid += 1

    def session(sid, cust, start, converts, platform):
        os_ = {"android": "Android", "ios": "iOS", "web": "Web"}[platform]
        ver = str(rng.choice(["5.2.0", "5.3.1", "5.4.0"]))
        t = start
        emit(sid, cust, t, "app_open", os_, ver, {})
        steps = ["search", "view_product", "add_to_cart", "checkout", "purchase"]
        drop = [0.15, 0.25, 0.30, 0.20, 0.12]
        for s, dp in zip(steps, drop):
            if not converts and rng.uniform() < dp:
                return
            t += timedelta(seconds=float(rng.uniform(5, 90)))
            props = {"query": str(rng.choice(queries))} if s == "search" else \
                    {"product_id": str(rng.choice(prod_ids))} if s in ("view_product", "add_to_cart") else {}
            if s == "purchase" and not converts:
                return
            emit(sid, cust, t, s, os_, ver, props)

    sid = 1
    for o in purchases.itertuples():
        start = datetime.fromisoformat(o.order_ts) - timedelta(minutes=float(rng.uniform(1, 6)))
        session(f"S{sid:08d}", o.customer_id, start, True, o.platform); sid += 1
    cust_ids = customers["customer_id"].to_numpy()
    span = int((END - START).total_seconds())
    for _ in range(n_sessions - len(purchases)):
        start = START + timedelta(seconds=int(rng.integers(0, span)))
        session(f"S{sid:08d}", str(rng.choice(cust_ids)), start, False, str(rng.choice(["android", "ios", "web"], p=[.62, .31, .07])))
        sid += 1
    return out


def write_csv(df, path):
    df.to_csv(path, index=False, compression="gzip")


def write_ndjson(docs, path):
    with gzip.open(path, "wt", encoding="utf-8") as f:
        for d in docs:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orders", type=int, default=90000)
    ap.add_argument("--customers", type=int, default=12000)
    ap.add_argument("--sessions", type=int, default=60000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data"))
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    os.makedirs(a.out, exist_ok=True)

    stores = build_stores(rng)
    products = build_products(rng)
    customers = build_customers(rng, a.customers)
    updates = build_customer_updates(rng, customers)
    orders, items, deliveries = build_orders(rng, a.orders, customers, stores, products)
    reviews = build_reviews(rng, orders, deliveries)
    events = build_app_events(rng, orders, customers, products, a.sessions)

    for name, df in [("dark_stores", stores), ("products", products), ("customers", customers),
                     ("customer_updates", updates), ("orders", orders), ("order_items", items), ("reviews", reviews)]:
        write_csv(df, os.path.join(a.out, f"{name}.csv.gz"))
        print(f"{name:<18} {len(df):>9,} rows")
    write_ndjson(deliveries, os.path.join(a.out, "delivery_events.json.gz")); print(f"{'delivery_events':<18} {len(deliveries):>9,} docs")
    write_ndjson(events, os.path.join(a.out, "app_events.json.gz")); print(f"{'app_events':<18} {len(events):>9,} docs")


if __name__ == "__main__":
    main()
