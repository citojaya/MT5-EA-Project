import argparse
import json
from pathlib import Path
import sys

import joblib
import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.signals.regime_signals import generate_regime_signals
from src.data.history_paths import (
    load_config,
    models_dir_for_config,
    raw_dir_for_config,
)
from src.features.build_features import build_features


HISTORY_BARS = 1000
MT5_COMMON_FILES_DIR = Path.home() / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"


def output_symbol_for_config(symbol: str, config_file: str) -> str:
    config_name = Path(config_file).stem
    if (
        config_name.startswith("config_mt5_ICM")
        or config_name.startswith("mt5_config_ICM")
    ) and not symbol.endswith(".a"):
        return f"{symbol}.a"
    return symbol


def load_model(model_file: Path, feature_columns_file: Path):
    model = joblib.load(model_file)

    with open(feature_columns_file, "r", encoding="utf-8") as f:
        feature_columns = json.load(f)

    return model, feature_columns


def filter_date_range(
    df: pd.DataFrame,
    start: str,
    end: str,
) -> pd.DataFrame:
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)

    start_time = pd.to_datetime(start, utc=True)
    end_time = pd.to_datetime(end, utc=True)

    if start_time > end_time:
        raise ValueError("start must be before or equal to end")

    return df[(df["time"] >= start_time) & (df["time"] <= end_time)].copy()


def select_raw_history(
    df: pd.DataFrame,
    start: str,
    end: str,
    history_bars: int = HISTORY_BARS,
) -> pd.DataFrame:
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.sort_values("time").reset_index(drop=True)

    start_time = pd.to_datetime(start, utc=True)
    end_time = pd.to_datetime(end, utc=True)
    if start_time > end_time:
        raise ValueError("start must be before or equal to end")

    period_indexes = df.index[(df["time"] >= start_time) & (df["time"] <= end_time)]
    if period_indexes.empty:
        return df.iloc[0:0].copy()

    first_index = max(0, int(period_indexes[0]) - history_bars + 1)
    last_index = int(period_indexes[-1])
    return df.iloc[first_index:last_index + 1].copy()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start", type=str, help="Start datetime, e.g. 2026-01-01")
    parser.add_argument("end", type=str, help="End datetime, e.g. 2026-01-31 23:59")
    parser.add_argument(
        "--output",
        type=str,
        help="Optional output CSV path. Defaults to MT5 Common Files/{symbol}_{timeframe}_backtest_signals.csv",
    )
    parser.add_argument(
        "--input-file",
        type=Path,
        required=True,
        help="IC Markets raw OHLC CSV used to build features in memory",
    )
    parser.add_argument(
        "--config-file",
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the raw history subdirectory.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    output_symbol = output_symbol_for_config(symbol, args.config_file)
    timeframe = args.timeframe.upper()

    cfg = load_config(args.config_file)
    broker_raw_dir = raw_dir_for_config(args.config_file, cfg).resolve()
    if "ICMarkets" not in broker_raw_dir.name:
        raise ValueError(
            f"Backtest requires an IC Markets config; resolved broker directory: {broker_raw_dir}"
        )

    raw_file = args.input_file
    if not raw_file.is_absolute():
        raw_file = ROOT_DIR / raw_file
    raw_file = raw_file.resolve()
    if not raw_file.is_relative_to(broker_raw_dir):
        raise ValueError(
            f"Input must be inside the IC Markets raw-data directory: {broker_raw_dir}"
        )
    if not raw_file.is_file():
        raise FileNotFoundError(f"Raw history file not found: {raw_file}")

    model_dir = models_dir_for_config(args.config_file) / f"stage1_regime_{symbol}_{timeframe}"
    model_file = model_dir / f"backtest_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"backtest_feature_columns_{symbol}_{timeframe}.json"
    output_file = (
        Path(args.output)
        if args.output
        else MT5_COMMON_FILES_DIR / f"{symbol}_{timeframe}_backtest_signals.csv"
    )

    raw_data = pd.read_csv(raw_file)
    raw_data = select_raw_history(raw_data, args.start, args.end)
    if raw_data.empty:
        raise RuntimeError("No raw IC Markets OHLC rows found for the selected date range")

    features = build_features(raw_data)
    features = filter_date_range(features, args.start, args.end)

    if features.empty:
        raise RuntimeError("No feature rows found for the selected date range")

    model, feature_columns = load_model(model_file, feature_columns_file)
    signals = generate_regime_signals(
        features=features,
        model=model,
        feature_columns=feature_columns,
        symbol=output_symbol,
        timeframe=timeframe,
    )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    signals.to_csv(output_file, index=False)

    print(f"Raw IC Markets input: {raw_file}")
    print("Features built in memory; no feature cache read or written.")
    print("Stage 2 disabled; output contains Stage 1 regime predictions only.")
    print(f"Saved backtest signals to: {output_file}")
    print(f"Rows: {len(signals)}")
    print()
    print(signals["regime_name"].value_counts())
    print()
    print(signals.tail())


if __name__ == "__main__":
    main()
