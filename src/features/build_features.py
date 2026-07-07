import argparse
import pandas as pd
from ta.trend import EMAIndicator, ADXIndicator
from ta.momentum import RSIIndicator
from ta.volatility import AverageTrueRange, BollingerBands


DATE_FROM = "20250101"
DATE_TO = "20261231"


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    df["time"] = pd.to_datetime(df["time"])
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

    df = df.dropna()

    return df

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    input_file = f"data/raw/{symbol}_bidask_{timeframe}_{DATE_FROM}_{DATE_TO}.csv"
    output_file = f"data/features/{symbol}_{timeframe}_features.csv"

    df = pd.read_csv(input_file)
    features = build_features(df)
    features.to_csv(output_file, index=False)
    print(f"Saved features to {output_file}")
    print(features.tail())


if __name__ == "__main__":
    main()
