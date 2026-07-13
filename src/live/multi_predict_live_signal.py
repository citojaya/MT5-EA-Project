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
from src.data.history_paths import models_dir_for_config
from src.signals.regime_signals import generate_regime_signals


# -----------------------------
# SETTINGS
# -----------------------------
CONFIG_FILE = "config/mt5_config_ICM_DEMO.json"


MT5_FILES_DIR = Path(
    Path.home() / "AppData/Roaming/MetaQuotes/Terminal/B898126C2AE145320BC9BDE8A1047D6F/MQL5/Files"
    #Path.home() / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"
)

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
def resolve_mt5_symbol(symbol: str, config_file: str) -> str:
    if Path(config_file).name == "mt5_config.json" and not symbol.endswith(".a"):
        return f"{symbol}.a"
    return symbol


def load_config(symbol: str, timeframe: str, config_file: str):
    with open(config_file, "r", encoding="utf-8") as f:
        config = json.load(f)

    config["symbol"] = symbol
    config["mt5_symbol"] = resolve_mt5_symbol(symbol, config_file)
    config["timeframe"] = timeframe
    return config


# -----------------------------
# CONNECT MT5
# -----------------------------
def connect_mt5(config):
    terminal_path = config.get("terminal_path")
    if terminal_path:
        initialized = mt5.initialize(path=terminal_path)
    else:
        initialized = mt5.initialize()

    if not initialized:
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
    symbol = config.get("mt5_symbol", config["symbol"])
    timeframe_name = config.get("timeframe", "M5")
    timeframe = TIMEFRAME_MAP[timeframe_name]
    bars = int(config.get("bars", 1000))

    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"Could not select symbol: {symbol}")

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 1, bars)

    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No MT5 data received for {symbol}")

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)

    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        raise RuntimeError(f"Symbol info not found: {symbol}")

    df["bid"] = df["close"]
    df["ask"] = df["close"] + df["spread"] * symbol_info.point

    return df


# -----------------------------
# LOAD MODEL
# -----------------------------
def load_model(model_file: Path, feature_columns_file: Path):
    model = joblib.load(model_file)

    with open(feature_columns_file, "r", encoding="utf-8") as f:
        feature_columns = json.load(f)

    print(f"Model loaded successfully: {model_file}")
    return model, feature_columns


def load_symbol_runtime(
    symbol: str,
    timeframe: str,
    config_file: str,
    mt5_files_dir: Path,
) -> dict:
    model_dir = models_dir_for_config(config_file) / f"stage1_regime_{symbol}_{timeframe}"
    model_file = model_dir / f"live_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"live_feature_columns_{symbol}_{timeframe}.json"
    model, feature_columns = load_model(model_file, feature_columns_file)

    return {
        "symbol": symbol,
        "config": load_config(symbol, timeframe, config_file),
        "model": model,
        "feature_columns": feature_columns,
        "output_file": mt5_files_dir / f"latest_regime_{symbol}_{timeframe}.txt",
        "append_signal_file": mt5_files_dir / f"append_signal_{symbol}_{timeframe}.csv",
        "last_processed_time": None,
    }


# -----------------------------
# WRITE OUTPUT FILE
# -----------------------------
def write_output_file(output_text: str, output_file: Path):
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temp_file = output_path.with_suffix(".tmp")

    with open(temp_file, "w", encoding="utf-8") as f:
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


def parse_symbols(symbols_text: str) -> list[str]:
    symbols = [
        symbol.strip().upper()
        for symbol in symbols_text.split(",")
        if symbol.strip()
    ]
    if not symbols:
        raise ValueError("At least one symbol is required")
    return symbols


# -----------------------------
# MAIN LOOP
# -----------------------------
def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "symbols",
        type=str,
        help="Comma-separated trading symbols, e.g. XAUUSD,BTCUSD,US30",
    )
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument(
        "--config-file",
        default=CONFIG_FILE,
        help="MT5 config file used for login and symbol suffix behavior",
    )
    parser.add_argument(
        "--mt5-files-dir",
        type=Path,
        default=MT5_FILES_DIR,
        help="Directory where latest_regime and append_signal files are written",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbols = parse_symbols(args.symbols)
    timeframe = args.timeframe.upper()
    mt5_files_dir = args.mt5_files_dir

    if timeframe not in TIMEFRAME_MAP:
        valid_timeframes = ", ".join(TIMEFRAME_MAP)
        raise ValueError(f"Unsupported timeframe '{args.timeframe}'. Use one of: {valid_timeframes}")

    first_config = load_config(symbols[0], timeframe, args.config_file)
    connect_mt5(first_config)

    runtimes = [
        load_symbol_runtime(symbol, timeframe, args.config_file, mt5_files_dir)
        for symbol in symbols
    ]

    print("Multi-symbol live regime prediction loop started.")
    print(f"Symbols: {', '.join(symbols)}")
    print(f"Output directory: {mt5_files_dir}")
    print("Press CTRL + C to stop.")

    try:
        while True:
            for runtime in runtimes:
                symbol = runtime["symbol"]
                try:
                    latest_time, signal, output = predict_live_regime(
                        config=runtime["config"],
                        model=runtime["model"],
                        feature_columns=runtime["feature_columns"],
                    )

                    if latest_time == runtime["last_processed_time"]:
                        print(f"{symbol}: No new candle. Last candle time: {latest_time}")
                    else:
                        runtime["last_processed_time"] = latest_time
                        write_output_file(output, runtime["output_file"])
                        print(f"{symbol}: Saved prediction to: {runtime['output_file']}")

                        if append_signal_line(signal, runtime["append_signal_file"]):
                            print(f"{symbol}: Appended signal to: {runtime['append_signal_file']}")
                        else:
                            print(f"{symbol}: Signal already logged in: {runtime['append_signal_file']}")

                except Exception as e:
                    print(f"{symbol}: Error during prediction: {e}")

            wait_until_next_minute()

    except KeyboardInterrupt:
        print("Stopped by user.")

    finally:
        mt5.shutdown()
        print("MT5 connection closed.")


if __name__ == "__main__":
    main()
