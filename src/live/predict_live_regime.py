import argparse
import csv
import json
import time
from datetime import datetime, timezone
from pathlib import Path
import sys

import joblib
import pandas as pd
import MetaTrader5 as mt5

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.features.build_features import build_features
from src.signals.regime_signals import generate_regime_signals


# -----------------------------
# SETTINGS
# -----------------------------
CONFIG_FILE = "config/mt5_config_FXV.json"


# FXView
MT5_FILES_DIR = Path(
    #"C:/Users/citoj/AppData/Roaming/MetaQuotes/Terminal/A1F51CBE722B627327055CCFE794EB41/MQL5/Files" # Desktop
    "C:/Users/ctj17/AppData/Roaming/MetaQuotes/Terminal/D544178D1D00BA11487CDDEC42EEF772/MQL5/Files" # Laptop

)

APPEND_SIGNAL_FILE = MT5_FILES_DIR / "append_signal.csv"

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


TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}


# -----------------------------
# LOAD CONFIG
# -----------------------------
def load_config(symbol: str, timeframe: str):
    with open(CONFIG_FILE, "r") as f:
        config = json.load(f)

    config["symbol"] = symbol
    config["timeframe"] = timeframe
    return config


# -----------------------------
# CONNECT MT5
# -----------------------------
def connect_mt5(config):
    if not mt5.initialize():
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    authorized = mt5.login(
        int(config["login"]),
        password=config["password"],
        server=config["server"],
    )

    if not authorized:
        raise RuntimeError(f"MT5 login failed: {mt5.last_error()}")

    print("MT5 connected successfully.")


# -----------------------------
# GET OHLC DATA
# -----------------------------
def get_mt5_ohlc(config):
    symbol = config["symbol"]
    timeframe_name = config.get("timeframe", "M5")
    timeframe = TIMEFRAME_MAP[timeframe_name]
    bars = int(config.get("bars", 1000))

    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"Could not select symbol: {symbol}")

    # Start at position 1 so inference only uses completed candles.
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 1, bars)

    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No MT5 data received for {symbol}")

    df = pd.DataFrame(rates)

    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)

    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        raise RuntimeError(f"Symbol info not found: {symbol}")

    # Match the historical downloader's per-candle bid/ask reconstruction.
    df["bid"] = df["close"]
    df["ask"] = df["close"] + df["spread"] * symbol_info.point

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
# WRITE OUTPUT FILE
# -----------------------------
def write_output_file(output_text: str, output_file: Path):
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temp_file = output_path.with_suffix(".tmp")

    with open(temp_file, "w") as f:
        f.write(output_text)

    temp_file.replace(output_path)


# -----------------------------
# APPEND SIGNAL CSV
# -----------------------------
def append_signal_line(signal: dict, signal_file: Path):
    signal_path = Path(signal_file)
    signal_path.parent.mkdir(parents=True, exist_ok=True)

    row = {column: signal.get(column, "") for column in SIGNAL_COLUMNS}

    if signal_path.exists() and signal_path.stat().st_size > 0:
        try:
            last_row = pd.read_csv(signal_path, usecols=["time", "symbol", "timeframe"]).tail(1)
            if not last_row.empty:
                latest = last_row.iloc[0]
                if (
                    str(latest["time"]) == str(row["time"])
                    and str(latest["symbol"]) == str(row["symbol"])
                    and str(latest["timeframe"]) == str(row["timeframe"])
                ):
                    return False
        except (ValueError, pd.errors.EmptyDataError):
            pass

    write_header = not signal_path.exists() or signal_path.stat().st_size == 0

    with open(signal_path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=SIGNAL_COLUMNS)
        if write_header:
            writer.writeheader()
        writer.writerow(row)

    return True


# -----------------------------
# PREDICT LIVE REGIME
# -----------------------------
def predict_live_regime(config, model, feature_columns):
    df = get_mt5_ohlc(config)
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
# WAIT UNTIL NEXT MINUTE
# -----------------------------
def wait_until_next_minute():
    now = datetime.now(timezone.utc)
    sleep_seconds = 60 - now.second - now.microsecond / 1_000_000

    if sleep_seconds < 1:
        sleep_seconds = 1

    time.sleep(sleep_seconds + 0.2)


# -----------------------------
# MAIN LOOP
# -----------------------------
def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    if timeframe not in TIMEFRAME_MAP:
        valid_timeframes = ", ".join(TIMEFRAME_MAP)
        raise ValueError(f"Unsupported timeframe '{args.timeframe}'. Use one of: {valid_timeframes}")

    model_dir = Path(f"data/models/stage1_regime_{symbol}_{timeframe}")
    model_file = model_dir / f"live_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"live_feature_columns_{symbol}_{timeframe}.json"
    output_file = MT5_FILES_DIR / f"latest_regime_{symbol}_{timeframe}.txt"
    append_signal_file = APPEND_SIGNAL_FILE

    config = load_config(symbol, timeframe)

    connect_mt5(config)

    model, feature_columns = load_model(model_file, feature_columns_file)

    print("Live regime prediction loop started.")
    print("Press CTRL + C to stop.")

    last_processed_time = None

    try:
        while True:
            try:
                latest_time, signal, output = predict_live_regime(
                    config=config,
                    model=model,
                    feature_columns=feature_columns,
                )

                if latest_time == last_processed_time:
                    print(f"No new candle. Last candle time: {latest_time}")
                else:
                    last_processed_time = latest_time
                    write_output_file(output, output_file)
                    print(f"Saved prediction to: {output_file}")

                    if append_signal_line(signal, append_signal_file):
                        print(f"Appended signal to: {append_signal_file}")
                    else:
                        print(f"Signal already logged in: {append_signal_file}")

            except Exception as e:
                print(f"Error during prediction: {e}")

            wait_until_next_minute()

    except KeyboardInterrupt:
        print("Stopped by user.")

    finally:
        mt5.shutdown()
        print("MT5 connection closed.")


if __name__ == "__main__":
    main()
