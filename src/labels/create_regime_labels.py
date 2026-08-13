import argparse
from pathlib import Path
import sys

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import features_dir_for_config, labels_dir_for_config


REGIME_MAP = {
    0: "Trade Not Possible",
    1: "Trade Possible",
}

HORIZON_BARS = 12
TAKE_PROFIT_ATR_MULTIPLIER = 3.0
STOP_LOSS_ATR_MULTIPLIER = 3.0


def first_hit_step(condition: pd.Series) -> int | None:
    hits = condition.to_numpy().nonzero()[0]
    return int(hits[0]) if len(hits) else None


def target_wins_before_stop(
    target_step: int | None,
    stop_step: int | None,
) -> bool:
    # If TP and SL occur in the same OHLC candle, their ordering is unknowable.
    # Treat that collision as a loss to avoid optimistic labels.
    return target_step is not None and (
        stop_step is None or target_step < stop_step
    )


def create_regime_labels(
    df: pd.DataFrame,
    horizon_bars: int = HORIZON_BARS,
    take_profit_atr_multiplier: float = TAKE_PROFIT_ATR_MULTIPLIER,
    stop_loss_atr_multiplier: float = STOP_LOSS_ATR_MULTIPLIER,
) -> pd.DataFrame:
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.sort_values("time").reset_index(drop=True)

    required_columns = {"time", "high", "low", "close", "atr_14"}
    missing_columns = required_columns - set(df.columns)
    if missing_columns:
        raise ValueError(f"Missing required columns: {sorted(missing_columns)}")
    if horizon_bars <= 0:
        raise ValueError("horizon_bars must be positive")
    if take_profit_atr_multiplier <= 0:
        raise ValueError("take_profit_atr_multiplier must be positive")
    if stop_loss_atr_multiplier <= 0:
        raise ValueError("stop_loss_atr_multiplier must be positive")

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

    labels = pd.Series(pd.NA, index=df.index, dtype="Int64")
    last_label_index = len(df) - horizon_bars

    for index in range(max(0, last_label_index)):
        entry_price = float(df.at[index, "close"])
        atr = float(df.at[index, "atr_14"])
        if pd.isna(atr) or atr <= 0:
            continue

        future = df.iloc[index + 1:index + horizon_bars + 1]
        buy_tp = entry_price + take_profit_atr_multiplier * atr
        buy_sl = entry_price - stop_loss_atr_multiplier * atr
        sell_tp = entry_price - take_profit_atr_multiplier * atr
        sell_sl = entry_price + stop_loss_atr_multiplier * atr

        buy_wins = target_wins_before_stop(
            first_hit_step(future["high"] >= buy_tp),
            first_hit_step(future["low"] <= buy_sl),
        )
        sell_wins = target_wins_before_stop(
            first_hit_step(future["low"] <= sell_tp),
            first_hit_step(future["high"] >= sell_sl),
        )
        labels.at[index] = int(buy_wins or sell_wins)

    # Stage 1 predicts opportunity only. A downstream rule/model must choose
    # long or short direction after the binary filter passes.
    df["regime"] = labels

    df["regime_name"] = df["regime"].map(REGIME_MAP)

    df = df.dropna().copy()
    df["regime"] = df["regime"].astype(int)

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
    print(
        "Binary outcome: TP "
        f"{TAKE_PROFIT_ATR_MULTIPLIER:g}x ATR / SL "
        f"{STOP_LOSS_ATR_MULTIPLIER:g}x ATR / "
        f"{HORIZON_BARS} forward bars"
    )
    if args.start and args.end:
        print(f"Date range: {args.start} to {args.end}")
    print()
    print(labelled["regime_name"].value_counts())
    print()
    print(labelled[["time", "close", "regime", "regime_name"]].tail())


if __name__ == "__main__":
    main()
