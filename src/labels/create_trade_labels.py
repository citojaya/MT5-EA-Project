import argparse
from pathlib import Path
import sys

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import labels_dir_for_config


SYMBOL = "BTCUSD"
TIMEFRAME = "M5"

HORIZON_BARS = 5
ELIGIBLE_REGIMES = (0, 2)

TRADE_LABEL_MAP = {
    1: "Favorable",
    0: "Unfavorable",
}


def create_trade_labels(
    df: pd.DataFrame,
    horizon_bars: int = HORIZON_BARS,
    eligible_regimes: tuple[int, ...] = ELIGIBLE_REGIMES,
) -> pd.DataFrame:
    df = df.copy()
    df = df.sort_values("time").reset_index(drop=True)

    required_columns = {"time", "close", "regime"}
    missing_columns = required_columns - set(df.columns)
    if missing_columns:
        raise ValueError(f"Missing required columns: {sorted(missing_columns)}")

    if horizon_bars <= 0:
        raise ValueError("horizon_bars must be positive")

    df["entry_price"] = df["close"]
    df["future_close_5"] = df["close"].shift(-horizon_bars)
    df["future_return_5"] = (df["future_close_5"] - df["entry_price"]) / df["entry_price"]

    df = df[df["regime"].isin(eligible_regimes)].copy().reset_index(drop=True)
    if df.empty:
        raise ValueError(f"No rows found for eligible regimes: {eligible_regimes}")

    df["order_direction"] = df["regime"].map({0: 1, 2: -1}).astype(int)
    df["directional_return_5"] = df["future_return_5"] * df["order_direction"]

    df = df.dropna(subset=["future_close_5", "future_return_5", "directional_return_5"])
    df["trade_label"] = (df["directional_return_5"] > 0).astype(int)

    df["trade_label_name"] = df["trade_label"].map(TRADE_LABEL_MAP)
    return df


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", nargs="?", default=SYMBOL, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", nargs="?", default=TIMEFRAME, help="Timeframe, e.g. M5")
    parser.add_argument(
        "--config-file",
        default="config/mt5_config_ICM_DEMO.json",
        help="MT5 config file. Broker/server in this file controls the data subdirectory.",
    )
    parser.add_argument(
        "--horizon-bars",
        type=int,
        default=HORIZON_BARS,
        help="Number of completed candles after entry used to label stage 2.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    labels_dir = labels_dir_for_config(args.config_file)
    input_file = labels_dir / f"{symbol}_{timeframe}_regime_labels.csv"
    output_file = labels_dir / f"{symbol}_{timeframe}_trade_labels.csv"

    df = pd.read_csv(input_file)

    labelled = create_trade_labels(df, horizon_bars=args.horizon_bars)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    labelled.to_csv(output_file, index=False)

    print(f"Saved trade labels to: {output_file}")
    print()
    print("Trade label distribution:")
    print(labelled["trade_label_name"].value_counts())
    print()
    print(
        labelled[
            [
                "time",
                "close",
                "future_close_5",
                "regime",
                "regime_name",
                "order_direction",
                "directional_return_5",
                "trade_label",
                "trade_label_name",
            ]
        ].tail()
    )


if __name__ == "__main__":
    main()
