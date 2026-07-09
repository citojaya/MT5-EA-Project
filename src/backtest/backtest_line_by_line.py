import argparse
import csv
import json
from pathlib import Path
import sys

import joblib
import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.features.build_features import build_features
from src.signals.regime_signals import generate_regime_signals


# -----------------------------
# SETTINGS
# -----------------------------
INPUT_FILE = ROOT_DIR / "data/raw/ohlc_data_XAUUSD.csv"
OUTPUT_FILE = ROOT_DIR / "data/backtest/backtest_line_by_line_XAUUSD.csv"

SIGNAL_COLUMNS = [
    "time",
    "symbol",
    "timeframe",
    "close",
    "regime",
    "regime_name",
    "confidence",
    "updated_utc",
]


# -----------------------------
# LOAD CONFIG
# -----------------------------
def load_config(symbol: str, timeframe: str):
    config = {
        "symbol": symbol,
        "timeframe": timeframe,
        "bars": 1000,
    }
    return config


# -----------------------------
# GET OHLC DATA
# -----------------------------
def get_csv_ohlc(data: pd.DataFrame, row_index: int, bars: int) -> pd.DataFrame:
    start_index = max(0, row_index - bars + 1)
    df = data.iloc[start_index : row_index + 1].copy()
    return df


# -----------------------------
# LOAD MODEL
# -----------------------------
def load_model(model_file: Path, feature_columns_file: Path):
    model = joblib.load(model_file)

    with open(feature_columns_file, "r") as f:
        feature_columns = json.load(f)

    print("Model loaded successfully.")
    return model, feature_columns


# -----------------------------
# APPEND SIGNAL CSV
# -----------------------------
def append_signal_line(signal: dict, signal_file: Path):
    signal_path = Path(signal_file)
    signal_path.parent.mkdir(parents=True, exist_ok=True)

    row = {column: signal.get(column, "") for column in SIGNAL_COLUMNS}

    write_header = not signal_path.exists() or signal_path.stat().st_size == 0

    with open(signal_path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=SIGNAL_COLUMNS)
        if write_header:
            writer.writeheader()
        writer.writerow(row)

    return True


def resolve_project_path(path: Path) -> Path:
    if path.is_absolute():
        return path
    return ROOT_DIR / path


# -----------------------------
# PREDICT REGIME
# -----------------------------
def predict_regime(config, model, feature_columns, data: pd.DataFrame, row_index: int):
    df = get_csv_ohlc(data, row_index, int(config.get("bars", 1000)))
    features = build_features(df)

    if features.empty:
        raise RuntimeError("Feature dataframe is empty after indicator calculation.")

    latest_row = features.tail(1).copy()
    signals = generate_regime_signals(
        features=latest_row,
        model=model,
        feature_columns=feature_columns,
        symbol=config["symbol"],
        timeframe=config.get("timeframe", "M5"),
    )
    signal = signals.iloc[-1].to_dict()

    time_value = signal["time"]

    output = (
        f"time={time_value}\n"
        f"symbol={signal['symbol']}\n"
        f"timeframe={signal['timeframe']}\n"
        f"close={signal['close']}\n"
        f"regime={signal['regime']}\n"
        f"regime_name={signal['regime_name']}\n"
        f"confidence={signal['confidence']:.4f}\n"
        f"updated_utc={signal['updated_utc']}\n"
    )

    print(output)

    return time_value, signal, output


# -----------------------------
# MAIN LOOP
# -----------------------------
def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M5")
    parser.add_argument("--input-file", type=Path, default=INPUT_FILE)
    parser.add_argument("--output-file", type=Path, default=OUTPUT_FILE)
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    input_file = resolve_project_path(args.input_file)
    output_file = resolve_project_path(args.output_file)

    model_dir = ROOT_DIR / f"data/models/stage1_regime_{symbol}_{timeframe}"
    model_file = model_dir / f"live_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"live_feature_columns_{symbol}_{timeframe}.json"

    config = load_config(symbol, timeframe)
    model, feature_columns = load_model(model_file, feature_columns_file)

    data = pd.read_csv(input_file)
    data["time"] = pd.to_datetime(data["time"], utc=True)

    print("Line-by-line backtest prediction loop started.")
    print(f"Input: {input_file}")
    print(f"Output: {output_file}")

    bars = int(config.get("bars", 1000))
    if len(data) < bars:
        raise RuntimeError(f"Input file has {len(data)} rows, but {bars} rows are required")

    for row_index in range(bars - 1, len(data)):
        try:
            latest_time, signal, _ = predict_regime(
                config=config,
                model=model,
                feature_columns=feature_columns,
                data=data,
                row_index=row_index,
            )

            append_signal_line(signal, output_file)
            print(f"Appended signal for candle: {latest_time}")

        except Exception as e:
            print(f"Error during prediction at row {row_index}: {e}")

    print("Line-by-line backtest finished.")


if __name__ == "__main__":
    main()
