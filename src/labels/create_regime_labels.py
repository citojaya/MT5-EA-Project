import argparse
from pathlib import Path
import sys

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import features_dir_for_config, labels_dir_for_config


REGIME_MAP = {
    0: "Choppy",
    1: "Uncertain",
    2: "Trending",
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

    required = {
        "efficiency_ratio_20",
        "candle_overlap_ratio_20",
        "ema_compression_atr",
    }
    missing = required - set(df.columns)
    if missing:
        raise ValueError(
            "Missing three-regime features; rebuild features first: "
            f"{sorted(missing)}"
        )

    # Default ambiguous/borderline observations to Uncertain. Requiring
    # agreement between independent measurements creates cleaner training
    # targets than forcing every candle into either chop or trend.
    df["regime"] = 1

    choppy_score = (
        (df["adx_14"] < 20).astype(int)
        + (df["efficiency_ratio_20"] < 0.30).astype(int)
        + (df["candle_overlap_ratio_20"] >= 0.65).astype(int)
        + (df["ema_compression_atr"] < 0.60).astype(int)
        + (df["bb_width_rank"] < 0.45).astype(int)
    )
    trending_score = (
        (df["adx_14"] >= 25).astype(int)
        + (df["efficiency_ratio_20"] >= 0.40).astype(int)
        + (df["candle_overlap_ratio_20"] < 0.55).astype(int)
        + (df["ema_compression_atr"] >= 0.90).astype(int)
        + ((df["di_plus"] - df["di_minus"]).abs() >= 10).astype(int)
    )

    df.loc[(choppy_score >= 3) & (choppy_score > trending_score), "regime"] = 0
    df.loc[(trending_score >= 3) & (trending_score > choppy_score), "regime"] = 2

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
    parser.add_argument(
        "--config-file",
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the data subdirectory.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    input_file = features_dir_for_config(args.config_file) / f"{symbol}_{timeframe}_features.csv"
    output_file = labels_dir_for_config(args.config_file) / f"{symbol}_{timeframe}_regime_labels.csv"

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
