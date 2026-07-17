import json
import pandas as pd
import numpy as np

PATH = "XAUUSD_M5_backtest_signals.csv"
df = pd.read_csv(PATH, parse_dates=["time", "updated_utc"])
df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
df["ret"] = df["close"].pct_change()
df["fwd_ret"] = df["close"].shift(-1) / df["close"] - 1
df["delta"] = df["close"].diff()
df["fwd_delta"] = df["close"].shift(-1) - df["close"]

basic = {
    "rows": len(df), "start": str(df.time.min()), "end": str(df.time.max()),
    "duplicates_removed": int(pd.read_csv(PATH).shape[0] - len(df)),
    "missing": df.isna().sum().to_dict(),
    "updated_min": str(df.updated_utc.min()), "updated_max": str(df.updated_utc.max()),
    "regimes": sorted(df.regime_name.dropna().unique().tolist()),
}

grp = df.groupby(["regime", "regime_name"], observed=True).agg(
    n=("fwd_ret", "count"), mean_fwd=("fwd_ret", "mean"), median_fwd=("fwd_ret", "median"),
    std_fwd=("fwd_ret", "std"), win=("fwd_ret", lambda x: (x > 0).mean()),
    mean_abs=("fwd_ret", lambda x: x.abs().mean()), confidence=("confidence", "mean")
).reset_index()
grp["tstat"] = grp.mean_fwd / (grp.std_fwd / np.sqrt(grp.n))

# Signal uses only information observable at bar t and trades t close to t+1 close.
mom = np.sign(df.close.pct_change(12)).fillna(0)
meanrev = -mom
signals = {"long": pd.Series(1.0, index=df.index), "short": pd.Series(-1.0, index=df.index),
           "mom12": mom, "mr12": meanrev}

def metrics(r, bars_per_year=252*24*12):
    r = r.dropna()
    eq = (1+r).cumprod()
    dd = eq/eq.cummax()-1
    sd = r.std()
    return {"n": int(r.size), "total": float(eq.iloc[-1]-1),
            "mean_bp": float(r.mean()*1e4), "sharpe": float(r.mean()/sd*np.sqrt(bars_per_year)) if sd else None,
            "max_dd": float(dd.min()), "win": float((r>0).mean())}

split = int(len(df)*0.7)
results=[]
for rid, rname in df[["regime","regime_name"]].drop_duplicates().itertuples(index=False):
    mask = df.regime.eq(rid)
    for sname, sig in signals.items():
        gross = sig * df.fwd_ret * mask
        # 5bp round-trip-equivalent charged whenever position changes; conservative proxy.
        pos = (sig*mask).fillna(0)
        cost = pos.diff().abs().fillna(pos.abs()) * 0.0005
        net = gross - cost
        results.append({"regime": int(rid), "name": rname, "rule": sname,
                        "train": metrics(net.iloc[:split]), "test": metrics(net.iloc[split:])})

# Transition matrix and persistence.
trans = pd.crosstab(df.regime_name, df.regime_name.shift(-1), normalize="index")
out={"basic": basic, "regime_stats": grp.to_dict("records"),
     "candidate_results": results, "transition": trans.round(5).to_dict()}

# Learn one direction per regime on the first 70%, then freeze it for the test set.
train = df.iloc[:split].copy()
direction = train.groupby("regime").fwd_ret.mean().apply(np.sign).to_dict()
raw_pos = df.regime.map(direction).fillna(0.0)

def portfolio_metrics(pos, cost_bp):
    turnover = pos.diff().abs().fillna(pos.abs())
    net = pos * df.fwd_ret - turnover * cost_bp / 1e4
    return {"train": metrics(net.iloc[:split]), "test": metrics(net.iloc[split:]),
            "test_turnover": float(turnover.iloc[split:].sum()),
            "test_trades_proxy": int((turnover.iloc[split:] > 0).sum())}

portfolios = {}
for lag in [0, 1]:
    # lag=1 is a stricter test: act one full bar after a regime label appears.
    pos = raw_pos.shift(lag).fillna(0)
    portfolios[f"learned_direction_lag{lag}"] = {str(bp): portfolio_metrics(pos, bp) for bp in [0,1,2,5]}

# Regime run lengths quantify whether switching costs can plausibly be controlled.
run_id = df.regime.ne(df.regime.shift()).cumsum()
runs = df.groupby(run_id).agg(regime_name=("regime_name","first"), bars=("regime","size")).reset_index(drop=True)
run_stats = runs.groupby("regime_name").bars.agg(["count","median","mean","max"]).reset_index().to_dict("records")
out["learned_directions"] = {str(k): int(v) for k,v in direction.items()}
out["portfolios"] = portfolios
out["run_stats"] = run_stats
with open("regime_analysis.json", "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, default=str)
print(json.dumps(basic, indent=2))
print(grp.to_string(index=False))
print("Top test candidates")
for x in sorted(results, key=lambda z: z["test"]["sharpe"] or -999, reverse=True)[:12]:
    print(x)
print("Learned directions", direction)
print(json.dumps(portfolios, indent=2))
print(pd.DataFrame(run_stats).to_string(index=False))
