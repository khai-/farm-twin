"""Fit the baseline climate of one container from its sensor log.

Usage: python3 fit.py <sensordata_export.json> [device] [out_dir]

Reads a DynamoDB export of sensor readings (temperature, humidity, CO2 every
~10 minutes), cleans it, and fits one small model per variable:

    x[t] = daily(hour) + d[t]         daily(hour): the room's usual level at that time of day
    d[t+1] = phi * d[t] + noise       d: how far the room is from usual; it fades at rate phi

It is fitted on the first 80% of the log and checked on the last 20% by
predicting 1 hour and 6 hours ahead from real starting points, against two
simple baselines (no change, and the usual level for that hour).

Actuator effects are NOT fitted: the control log holds bursts of manual switch
presses, not a record of what ran when. They are written to params.json as
assumed values, to be replaced by a step test at the farm.

Raw readings never leave this machine. Only the fitted numbers and one sample
day are written out.
"""
import json, math, sys, datetime as dt
from pathlib import Path
import numpy as np

SRC = Path(sys.argv[1])
DEVICE = sys.argv[2] if len(sys.argv) > 2 else "container2"
OUT = Path(sys.argv[3]) if len(sys.argv) > 3 else Path(__file__).parent / "data"
VARS = {"temperature": (10, 45), "humidity": (20, 100), "CO2": (300, 10000)}  # plausible ranges
STEP_MIN = 10
HARMONICS = 3


def load():
    rows = []
    for r in json.load(open(SRC))["Items"]:
        if r["deviceName"].get("S") != DEVICE:
            continue
        try:
            o = {"t": float(r["timestamp"]["N"]) / 1000}
            for v in VARS:
                o[v] = float(r[v]["N"])
        except (KeyError, ValueError):
            continue
        rows.append(o)
    rows.sort(key=lambda o: o["t"])
    raw = len(rows)
    rows = [o for o in rows if all(lo <= o[v] <= hi for v, (lo, hi) in VARS.items())]
    for o in rows:
        d = dt.datetime.fromtimestamp(o["t"])
        o["h"] = d.hour + d.minute / 60
    return rows, raw


def feats(h):
    f = [1.0]
    for n in range(1, HARMONICS + 1):
        w = 2 * math.pi * n * h / 24
        f += [math.sin(w), math.cos(w)]
    return f


def daily(coef, h):
    return sum(c * f for c, f in zip(coef, feats(h)))


def segments(rows):
    """Runs of readings spaced 8 to 12 minutes apart."""
    seg, out = [rows[0]], []
    for a, b in zip(rows, rows[1:]):
        if 8 * 60 <= b["t"] - a["t"] <= 12 * 60:
            seg.append(b)
        else:
            out.append(seg); seg = [b]
    out.append(seg)
    return out


def fit_var(segs, v):
    pts = [o for s in segs for o in s]
    X = np.array([feats(o["h"]) for o in pts]); y = np.array([o[v] for o in pts])
    coef, *_ = np.linalg.lstsq(X, y, rcond=None)
    # phi is chosen on the training data to predict well at both 1 hour and 6 hours.
    # (The one-step estimate alone overstates how long a disturbance lasts.)
    devs = [[o[v] - daily(coef, o["h"]) for o in s] for s in segs]

    def mae(phi, n):
        e = [abs(phi ** n * d[i] - d[i + n]) for d in devs for i in range(0, len(d) - n, n)]
        return sum(e) / len(e)

    base = {n: mae(1.0, n) for n in (6, 36)}
    grid = [0.90 + 0.004 * i for i in range(25)] + [0.997, 0.999]
    phi = min(grid, key=lambda f: mae(f, 6) / base[6] + mae(f, 36) / base[36])
    res = [b - phi * a for d in devs for a, b in zip(d, d[1:])]
    return {"daily_coef": [float(c) for c in coef], "harmonics": HARMONICS, "phi": float(phi),
            "noise_sd": float(np.std(res)), "pairs": len(res),
            "usual_min": float(min(daily(coef, h / 6) for h in range(144))),
            "usual_max": float(max(daily(coef, h / 6) for h in range(144)))}


def evaluate(test, params):
    res = {}
    for v in VARS:
        p = params[v]; row = {}
        for name, n in (("1h", 6), ("6h", 36)):
            em, ep, ec = [], [], []
            for s in test:
                for i in range(0, len(s) - n, n):
                    a, b = s[i], s[i + n]
                    usual = daily(p["daily_coef"], b["h"])
                    pred = usual + p["phi"] ** n * (a[v] - daily(p["daily_coef"], a["h"]))
                    em.append(abs(pred - b[v])); ep.append(abs(a[v] - b[v])); ec.append(abs(usual - b[v]))
            row[name] = {"windows": len(em), "model_mae": float(np.mean(em)), "no_change_mae": float(np.mean(ep)),
                         "usual_for_hour_mae": float(np.mean(ec))}
        res[v] = row
    return res


rows, raw = load()
segs = segments(rows)
cut = rows[int(len(rows) * 0.8)]["t"]
train = [s for s in segs if s[-1]["t"] <= cut and len(s) > 1]
test = [s for s in segs if s[0]["t"] > cut and len(s) > 36]
params = {v: fit_var(train, v) for v in VARS}
ev = evaluate(test, params)

# one whole held-out day (144 readings from midnight) for the replay view
sample = sample_date = None
for s in test:
    for i, o in enumerate(s):
        if o["h"] < 0.17 and len(s) - i >= 144:
            sample = [{"h": round(q["h"], 3), **{v: q[v] for v in VARS}} for q in s[i:i + 144]]
            sample_date = dt.datetime.fromtimestamp(o["t"]).strftime("%Y-%m-%d")
            break
    if sample:
        break

fmt = lambda t: dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d")
out = {
    "device": DEVICE, "step_minutes": STEP_MIN,
    "data": {"raw_readings": raw, "kept_after_cleaning": len(rows), "from": fmt(rows[0]["t"]), "to": fmt(rows[-1]["t"]),
             "train_until": fmt(cut), "clean_ranges": VARS},
    "climate": params, "check": ev,
    "actuators": {
        "source": "ASSUMED, not fitted. Replace with a step test: run each actuator alone for 30 minutes and log the sensors.",
        "response_rate_per_step": 0.4,
        "humidifier": {"humidity": 12.0, "temperature": -0.4},
        "spray": {"humidity": 6.0, "temperature": -0.2},
        "vent1": {"humidity": -6.0, "CO2_excess_fraction": -0.45},
        "vent2": {"humidity": -6.0, "CO2_excess_fraction": -0.45},
        "light": {"temperature": 0.4},
        "pump": {}, "fill": {},
        "outside_CO2": 420.0,
    },
}
(OUT / "params.json").write_text(json.dumps(out, indent=1))
if sample:
    (OUT / "sample_day.json").write_text(json.dumps({"device": DEVICE, "date": sample_date, "readings": sample}))

print(f"{DEVICE}: {raw} readings, {len(rows)} kept, {fmt(rows[0]['t'])} to {fmt(rows[-1]['t'])}; train until {fmt(cut)}")
print(f"segments: train {len(train)}, test {len(test)}; sample day: {sample_date}")
for v in VARS:
    p = params[v]
    print(f"{v:12s} usual {p['usual_min']:.1f}..{p['usual_max']:.1f}  phi={p['phi']:.4f}  noise_sd={p['noise_sd']:.2f}")
    for hz in ("1h", "6h"):
        e = ev[v][hz]
        print(f"   {hz} ahead, {e['windows']} windows: model {e['model_mae']:.2f} | no change {e['no_change_mae']:.2f} | usual for hour {e['usual_for_hour_mae']:.2f}")
