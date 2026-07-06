import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import joblib
import pandas as pd
import MetaTrader5 as mt5

from ta.trend import EMAIndicator, ADXIndicator
from ta.momentum import RSIIndicator
from ta.volatility import AverageTrueRange, BollingerBands


# -----------------------------
# SETTINGS
# -----------------------------
CONFIG_FILE = "config/mt5_config_FXV.json"

# FXView
MT5_FILES_DIR = Path(
    "C:/Users/ctj17/AppData/Roaming/MetaQuotes/Terminal/"
    "D544178D1D00BA11487CDDEC42EEF772/MQL5/Files"
)


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

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)

    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No MT5 data received for {symbol}")

    df = pd.DataFrame(rates)

    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)

    tick = mt5.symbol_info_tick(symbol)

    if tick is not None:
        df["bid"] = tick.bid
        df["ask"] = tick.ask
    else:
        df["bid"] = df["close"]
        df["ask"] = df["close"]

    return df


# -----------------------------
# BUILD FEATURES
# -----------------------------
def build_features(df):
    df = df.copy()
    df = df.sort_values("time")

    df["ema_9"] = EMAIndicator(df["close"], window=9).ema_indicator()
    df["ema_21"] = EMAIndicator(df["close"], window=21).ema_indicator()
    df["ema_50"] = EMAIndicator(df["close"], window=50).ema_indicator()
    df["ema_200"] = EMAIndicator(df["close"], window=200).ema_indicator()

    df["rsi_14"] = RSIIndicator(df["close"], window=14).rsi()

    adx = ADXIndicator(df["high"], df["low"], df["close"], window=14)
    df["adx_14"] = adx.adx()
    df["di_plus"] = adx.adx_pos()
    df["di_minus"] = adx.adx_neg()

    atr = AverageTrueRange(df["high"], df["low"], df["close"], window=14)
    df["atr_14"] = atr.average_true_range()
    df["atr_pct"] = df["atr_14"] / df["close"]

    bb = BollingerBands(df["close"], window=20, window_dev=2)
    df["bb_width"] = (
        bb.bollinger_hband() - bb.bollinger_lband()
    ) / df["close"]

    df["body_size"] = abs(df["close"] - df["open"])
    df["upper_wick"] = df["high"] - df[["open", "close"]].max(axis=1)
    df["lower_wick"] = df[["open", "close"]].min(axis=1) - df["low"]

    df["hour"] = df["time"].dt.hour
    df["day_of_week"] = df["time"].dt.dayofweek

    df["ema_9_slope"] = df["ema_9"].diff()
    df["ema_21_slope"] = df["ema_21"].diff()
    df["ema_50_slope"] = df["ema_50"].diff()

    df["atr_pct_rank"] = (
        df["atr_pct"]
        .rolling(window=500, min_periods=100)
        .rank(pct=True)
    )

    df["bb_width_rank"] = (
        df["bb_width"]
        .rolling(window=500, min_periods=100)
        .rank(pct=True)
    )

    df = df.dropna()

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
# PREDICT LIVE REGIME
# -----------------------------
def predict_live_regime(config, model, feature_columns, output_file: Path):
    df = get_mt5_ohlc(config)
    features = build_features(df)

    if features.empty:
        raise RuntimeError("Feature dataframe is empty after indicator calculation.")

    latest_row = features.tail(1).copy()

    missing_cols = [col for col in feature_columns if col not in latest_row.columns]
    if missing_cols:
        raise ValueError(f"Missing feature columns: {missing_cols}")

    X_live = latest_row[feature_columns]

    pred_regime = int(model.predict(X_live)[0])

    probabilities = model.predict_proba(X_live)[0]
    class_index = list(model.classes_).index(pred_regime)
    confidence = float(probabilities[class_index])

    regime_name = REGIME_MAP.get(pred_regime, "Unknown")

    time_value = latest_row["time"].iloc[0]
    close_value = float(latest_row["close"].iloc[0])

    output = (
        f"time={time_value}\n"
        f"symbol={config['symbol']}\n"
        f"timeframe={config.get('timeframe', 'M5')}\n"
        f"close={close_value}\n"
        f"regime={pred_regime}\n"
        f"regime_name={regime_name}\n"
        f"confidence={confidence:.4f}\n"
        f"updated_utc={datetime.now(timezone.utc)}\n"
    )

    write_output_file(output, output_file)

    print(output)
    print(f"Saved prediction to: {output_file}")

    return time_value


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

    model_dir = Path(f"models/stage1_regime_{symbol}_{timeframe}")
    model_file = model_dir / f"regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"feature_columns_{symbol}_{timeframe}.json"
    output_file = MT5_FILES_DIR / f"latest_regime_{symbol}_{timeframe}.txt"

    config = load_config(symbol, timeframe)

    connect_mt5(config)

    model, feature_columns = load_model(model_file, feature_columns_file)

    print("Live regime prediction loop started.")
    print("Press CTRL + C to stop.")

    last_processed_time = None

    try:
        while True:
            try:
                latest_time = predict_live_regime(
                    config=config,
                    model=model,
                    feature_columns=feature_columns,
                    output_file=output_file,
                )

                if latest_time == last_processed_time:
                    print(f"No new candle. Last candle time: {latest_time}")
                else:
                    last_processed_time = latest_time

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
