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

HORIZON_BARS = 12
TAKE_PROFIT_PCT = 0.002
STOP_LOSS_PCT = 0.001

TRADE_LABEL_MAP = {
    1: "Buy",
    -1: "Sell",
    0: "No Trade",
}


def create_trade_labels(
    df: pd.DataFrame,
    horizon_bars: int = HORIZON_BARS,
    take_profit_pct: float = TAKE_PROFIT_PCT,
    stop_loss_pct: float = STOP_LOSS_PCT,
) -> pd.DataFrame:
    df = df.copy()
    df = df.sort_values("time").reset_index(drop=True)

    required_columns = {"time", "high", "low", "close"}
    missing_columns = required_columns - set(df.columns)
    if missing_columns:
        raise ValueError(f"Missing required columns: {sorted(missing_columns)}")

    if horizon_bars <= 0:
        raise ValueError("horizon_bars must be positive")
    if take_profit_pct <= 0:
        raise ValueError("take_profit_pct must be positive")
    if stop_loss_pct <= 0:
        raise ValueError("stop_loss_pct must be positive")

    df["trade_label"] = 0
    df["trade_label_name"] = TRADE_LABEL_MAP[0]

    for i in range(len(df) - horizon_bars):
        entry_price = df.loc[i, "close"]
        future = df.iloc[i + 1:i + horizon_bars + 1]

        buy_take_profit = entry_price * (1 + take_profit_pct)
        buy_stop_loss = entry_price * (1 - stop_loss_pct)
        sell_take_profit = entry_price * (1 - take_profit_pct)
        sell_stop_loss = entry_price * (1 + stop_loss_pct)

        buy_tp_step = first_hit_index(future["high"] >= buy_take_profit)
        buy_sl_step = first_hit_index(future["low"] <= buy_stop_loss)
        sell_tp_step = first_hit_index(future["low"] <= sell_take_profit)
        sell_sl_step = first_hit_index(future["high"] >= sell_stop_loss)

        buy_wins = buy_tp_step is not None and (
            buy_sl_step is None or buy_tp_step < buy_sl_step
        )
        sell_wins = sell_tp_step is not None and (
            sell_sl_step is None or sell_tp_step < sell_sl_step
        )

        if buy_wins and sell_wins:
            df.loc[i, "trade_label"] = 1 if buy_tp_step < sell_tp_step else -1
        elif buy_wins:
            df.loc[i, "trade_label"] = 1
        elif sell_wins:
            df.loc[i, "trade_label"] = -1

    df["trade_label_name"] = df["trade_label"].map(TRADE_LABEL_MAP)
    return df


def first_hit_index(hit_series: pd.Series) -> int | None:
    hit_positions = hit_series[hit_series].index
    if len(hit_positions) == 0:
        return None
    return int(hit_positions[0])


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", nargs="?", default=SYMBOL, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", nargs="?", default=TIMEFRAME, help="Timeframe, e.g. M5")
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
    labels_dir = labels_dir_for_config(args.config_file)
    input_file = labels_dir / f"{symbol}_{timeframe}_regime_labels.csv"
    output_file = labels_dir / f"{symbol}_{timeframe}_trade_labels.csv"

    df = pd.read_csv(input_file)

    labelled = create_trade_labels(df)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    labelled.to_csv(output_file, index=False)

    print(f"Saved trade labels to: {output_file}")
    print()
    print("Trade label distribution:")
    print(labelled["trade_label_name"].value_counts())
    print()
    print(labelled[["time", "close", "regime", "regime_name", "trade_label", "trade_label_name"]].tail())


if __name__ == "__main__":
    main()
