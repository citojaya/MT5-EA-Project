import argparse
from pathlib import Path
import sys

import pandas as pd
from ta.trend import EMAIndicator, ADXIndicator
from ta.momentum import RSIIndicator
from ta.volatility import AverageTrueRange, BollingerBands

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import (
    features_dir_for_config,
    raw_dir_for_config,
    raw_history_path,
)


def parse_date_token(value: str) -> str:
    parsed = pd.to_datetime(value, errors="raise")
    return parsed.strftime("%Y%m%d")


def safe_divide(numerator, denominator):
    return numerator / denominator.where(denominator != 0)


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    df["time"] = pd.to_datetime(df["time"])
    df = df.sort_values("time")
    close = df["close"]

    df["ema_9"] = EMAIndicator(close, window=9).ema_indicator()
    df["ema_21"] = EMAIndicator(close, window=21).ema_indicator()
    df["ema_50"] = EMAIndicator(close, window=50).ema_indicator()
    df["ema_200"] = EMAIndicator(close, window=200).ema_indicator()

    df["rsi_14"] = RSIIndicator(close, window=14).rsi()

    adx = ADXIndicator(df["high"], df["low"], close, window=14)
    df["adx_14"] = adx.adx()
    df["di_plus"] = adx.adx_pos()
    df["di_minus"] = adx.adx_neg()

    atr = AverageTrueRange(df["high"], df["low"], close, window=14)
    df["atr_14"] = atr.average_true_range()
    df["atr_pct"] = safe_divide(df["atr_14"], close)

    bb = BollingerBands(close, window=20, window_dev=2)
    df["bb_width"] = (
        bb.bollinger_hband() - bb.bollinger_lband()
    ) / close.where(close != 0)

    df["body_size"] = abs(df["close"] - df["open"])
    df["upper_wick"] = df["high"] - df[["open", "close"]].max(axis=1)
    df["lower_wick"] = df[["open", "close"]].min(axis=1) - df["low"]
    df["range_size"] = df["high"] - df["low"]

    df["return_1"] = close.pct_change()
    df["return_3"] = close.pct_change(3)
    df["return_6"] = close.pct_change(6)
    df["return_12"] = close.pct_change(12)

    df["range_pct"] = safe_divide(df["range_size"], close)
    df["body_pct"] = safe_divide(df["body_size"], close)
    df["upper_wick_pct"] = safe_divide(df["upper_wick"], close)
    df["lower_wick_pct"] = safe_divide(df["lower_wick"], close)
    df["open_close_pct"] = safe_divide(df["close"] - df["open"], close)
    df["high_close_pct"] = safe_divide(df["high"] - close, close)
    df["low_close_pct"] = safe_divide(close - df["low"], close)

    df["hour"] = df["time"].dt.hour
    df["day_of_week"] = df["time"].dt.dayofweek

    df["ema_9_slope"] = df["ema_9"].diff()
    df["ema_21_slope"] = df["ema_21"].diff()
    df["ema_50_slope"] = df["ema_50"].diff()

    df["ema_9_dist_pct"] = safe_divide(close - df["ema_9"], close)
    df["ema_21_dist_pct"] = safe_divide(close - df["ema_21"], close)
    df["ema_50_dist_pct"] = safe_divide(close - df["ema_50"], close)
    df["ema_200_dist_pct"] = safe_divide(close - df["ema_200"], close)
    df["ema_9_slope_pct"] = safe_divide(df["ema_9_slope"], close)
    df["ema_21_slope_pct"] = safe_divide(df["ema_21_slope"], close)
    df["ema_50_slope_pct"] = safe_divide(df["ema_50_slope"], close)

    if {"ask", "bid"}.issubset(df.columns):
        spread_price = df["ask"] - df["bid"]
    elif "ask" in df.columns:
        spread_price = df["ask"] - close
    else:
        spread_price = pd.Series(0, index=df.index)

    df["spread_pct"] = safe_divide(spread_price, close)
    df["tick_volume_ma_20"] = df["tick_volume"].rolling(window=20).mean()
    df["tick_volume_ratio_20"] = safe_divide(
        df["tick_volume"],
        df["tick_volume_ma_20"],
    )

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

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start_date", type=str, help="Start date, e.g. 2025-01-01")
    parser.add_argument("end_date", type=str, help="End date, e.g. 2026-12-31")
    parser.add_argument(
        "--config-file",
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the raw history subdirectory.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    date_from = parse_date_token(args.start_date)
    date_to = parse_date_token(args.end_date)

    raw_dir = raw_dir_for_config(args.config_file)
    features_dir = features_dir_for_config(args.config_file)
    input_file = raw_history_path(raw_dir, symbol, timeframe, date_from, date_to)
    output_file = features_dir / f"{symbol}_{timeframe}_features.csv"

    df = pd.read_csv(input_file)
    features = build_features(df)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    features.to_csv(output_file, index=False)
    print(f"Saved features to {output_file}")
    print(features.tail())


if __name__ == "__main__":
    main()
