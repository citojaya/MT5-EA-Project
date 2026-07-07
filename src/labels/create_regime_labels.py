import argparse
from pathlib import Path

import pandas as pd


REGIME_MAP = {
    0: "Strong Bull Trend",
    1: "Weak Bull Trend",
    2: "Strong Bear Trend",
    3: "Weak Bear Trend",
    4: "Range",
    5: "High Volatility",
    6: "Low Volatility",
    7: "Transition",
}


def create_regime_labels(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.sort_values("time")

    # ATR percentile over rolling window
    df["atr_pct_rank"] = (
        df["atr_pct"]
        .rolling(window=500, min_periods=100)
        .rank(pct=True)
    )

    # Bollinger Band width percentile
    df["bb_width_rank"] = (
        df["bb_width"]
        .rolling(window=500, min_periods=100)
        .rank(pct=True)
    )

    df["regime"] = 7  # default = Transition

    strong_bull = (
        (df["ema_50"] > df["ema_200"]) &
        (df["ema_50_slope"] > 0) &
        (df["adx_14"] > 25) &
        (df["di_plus"] > df["di_minus"])
    )

    weak_bull = (
        (df["ema_50"] > df["ema_200"]) &
        (df["adx_14"] >= 15) &
        (df["adx_14"] <= 25) &
        (df["di_plus"] > df["di_minus"])
    )

    strong_bear = (
        (df["ema_50"] < df["ema_200"]) &
        (df["ema_50_slope"] < 0) &
        (df["adx_14"] > 25) &
        (df["di_minus"] > df["di_plus"])
    )

    weak_bear = (
        (df["ema_50"] < df["ema_200"]) &
        (df["adx_14"] >= 15) &
        (df["adx_14"] <= 25) &
        (df["di_minus"] > df["di_plus"])
    )

    range_market = (
        (df["adx_14"] < 15) &
        (df["bb_width_rank"] < 0.40)
    )

    high_volatility = df["atr_pct_rank"] > 0.80
    low_volatility = df["atr_pct_rank"] < 0.20

    # Priority order matters
    df.loc[range_market, "regime"] = 4
    df.loc[weak_bull, "regime"] = 1
    df.loc[weak_bear, "regime"] = 3
    df.loc[strong_bull, "regime"] = 0
    df.loc[strong_bear, "regime"] = 2
    df.loc[high_volatility, "regime"] = 5
    df.loc[low_volatility, "regime"] = 6

    df["regime_name"] = df["regime"].map(REGIME_MAP)

    df = df.dropna()

    return df


def filter_date_range(
    df: pd.DataFrame,
    start: str | None,
    end: str | None,
) -> pd.DataFrame:
    if start is None and end is None:
        return df

    if start is None or end is None:
        raise ValueError("Both start and end must be provided when filtering by date")

    start_time = pd.to_datetime(start, utc=True)
    end_time = pd.to_datetime(end, utc=True)

    if start_time > end_time:
        raise ValueError("start must be before or equal to end")

    return df[(df["time"] >= start_time) & (df["time"] <= end_time)].copy()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start", nargs="?", help="Optional start datetime, e.g. 2025-01-01")
    parser.add_argument("end", nargs="?", help="Optional end datetime, e.g. 2025-06-30 23:59")
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    input_file = f"data/features/{symbol}_{timeframe}_features.csv"
    output_file = Path(f"data/labels/{symbol}_{timeframe}_regime_labels.csv")

    df = pd.read_csv(input_file)

    labelled = create_regime_labels(df)
    labelled = filter_date_range(labelled, args.start, args.end)

    if labelled.empty:
        raise RuntimeError("No regime label rows found for the selected date range")

    output_file.parent.mkdir(parents=True, exist_ok=True)
    labelled.to_csv(output_file, index=False)

    print(f"Saved regime labels to: {output_file}")
    if args.start and args.end:
        print(f"Date range: {args.start} to {args.end}")
    print()
    print(labelled["regime_name"].value_counts())
    print()
    print(labelled[["time", "close", "regime", "regime_name"]].tail())


if __name__ == "__main__":
    main()
