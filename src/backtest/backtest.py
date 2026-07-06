import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import joblib
import pandas as pd


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


def add_missing_regime_rank_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    if "atr_pct_rank" not in df.columns:
        if "atr_pct" not in df.columns:
            raise ValueError("Cannot create atr_pct_rank because atr_pct is missing")

        df["atr_pct_rank"] = (
            df["atr_pct"]
            .rolling(window=500, min_periods=100)
            .rank(pct=True)
        )

    if "bb_width_rank" not in df.columns:
        if "bb_width" not in df.columns:
            raise ValueError("Cannot create bb_width_rank because bb_width is missing")

        df["bb_width_rank"] = (
            df["bb_width"]
            .rolling(window=500, min_periods=100)
            .rank(pct=True)
        )

    return df.dropna()


def generate_backtest_signals(
    features: pd.DataFrame,
    model,
    feature_columns: list[str],
    symbol: str,
    timeframe: str,
) -> pd.DataFrame:
    missing_cols = [col for col in feature_columns if col not in features.columns]
    if missing_cols:
        raise ValueError(f"Missing feature columns: {missing_cols}")

    x = features[feature_columns]
    predictions = model.predict(x)
    probabilities = model.predict_proba(x)
    classes = list(model.classes_)

    rows = []
    updated_utc = datetime.now(timezone.utc)

    for row_index, (_, row) in enumerate(features.iterrows()):
        regime = int(predictions[row_index])
        class_index = classes.index(regime)
        confidence = float(probabilities[row_index][class_index])

        rows.append(
            {
                "time": row["time"],
                "symbol": symbol,
                "timeframe": timeframe,
                "close": float(row["close"]),
                "regime": regime,
                "regime_name": REGIME_MAP.get(regime, "Unknown"),
                "confidence": round(confidence, 6),
                "updated_utc": updated_utc,
            }
        )

    return pd.DataFrame(rows)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start", type=str, help="Start datetime, e.g. 2026-01-01")
    parser.add_argument("end", type=str, help="End datetime, e.g. 2026-01-31 23:59")
    parser.add_argument(
        "--output",
        type=str,
        help="Optional output CSV path. Defaults to src/backtest/{symbol}_{timeframe}_backtest_signals.csv",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    input_file = Path(f"data/features/{symbol}_{timeframe}_features.csv")
    model_dir = Path(f"models/stage1_regime_{symbol}_{timeframe}")
    model_file = model_dir / f"regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"feature_columns_{symbol}_{timeframe}.json"
    output_file = (
        Path(args.output)
        if args.output
        else Path(f"src/backtest/{symbol}_{timeframe}_backtest_signals.csv")
    )

    features = pd.read_csv(input_file)
    features = add_missing_regime_rank_features(features)
    features = filter_date_range(features, args.start, args.end)

    if features.empty:
        raise RuntimeError("No feature rows found for the selected date range")

    model, feature_columns = load_model(model_file, feature_columns_file)
    signals = generate_backtest_signals(
        features=features,
        model=model,
        feature_columns=feature_columns,
        symbol=symbol,
        timeframe=timeframe,
    )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    signals.to_csv(output_file, index=False)

    print(f"Saved backtest signals to: {output_file}")
    print(f"Rows: {len(signals)}")
    print()
    print(signals["regime_name"].value_counts())
    print()
    print(signals.tail())


if __name__ == "__main__":
    main()
