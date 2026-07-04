import pandas as pd
from ta.trend import EMAIndicator, ADXIndicator
from ta.momentum import RSIIndicator
from ta.volatility import AverageTrueRange, BollingerBands


INPUT_FILE = "data/raw/BTCUSD_bidask_M5_20260101_20261231.csv"
OUTPUT_FILE = "data/features/BTCUSD_M5_features.csv"


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


def main():
    df = pd.read_csv(INPUT_FILE)
    features = build_features(df)
    features.to_csv(OUTPUT_FILE, index=False)
    print(f"Saved features to {OUTPUT_FILE}")
    print(features.tail())


if __name__ == "__main__":
    main()