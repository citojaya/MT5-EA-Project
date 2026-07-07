import argparse
import json
from pathlib import Path

import joblib
import pandas as pd


def load_feature_importance(symbol: str, timeframe: str) -> pd.DataFrame:
    model_dir = Path(f"models/stage1_regime_{symbol}_{timeframe}")
    model_file = model_dir / f"regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"feature_columns_{symbol}_{timeframe}.json"

    if not model_file.exists():
        raise FileNotFoundError(f"Model file not found: {model_file}")

    if not feature_columns_file.exists():
        raise FileNotFoundError(f"Feature columns file not found: {feature_columns_file}")

    model = joblib.load(model_file)

    with open(feature_columns_file, "r", encoding="utf-8") as f:
        feature_columns = json.load(f)

    if not hasattr(model, "feature_importances_"):
        raise ValueError("Loaded model does not expose feature_importances_")

    importance = model.feature_importances_

    if len(feature_columns) != len(importance):
        raise ValueError(
            "Feature column count does not match model importance count: "
            f"{len(feature_columns)} columns vs {len(importance)} importances"
        )

    return (
        pd.DataFrame(
            {
                "feature": feature_columns,
                "importance": importance,
            }
        )
        .sort_values("importance", ascending=False)
        .reset_index(drop=True)
    )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument(
        "--output",
        type=str,
        help="Optional CSV output path. Defaults to models/stage1_regime_{symbol}_{timeframe}/feature_importance_{symbol}_{timeframe}.csv",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()

    importance = load_feature_importance(symbol, timeframe)

    output_file = (
        Path(args.output)
        if args.output
        else Path(
            f"models/stage1_regime_{symbol}_{timeframe}/"
            f"feature_importance_{symbol}_{timeframe}.csv"
        )
    )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    importance.to_csv(output_file, index=False)

    print(importance.to_string(index=False))
    print()
    print(f"Saved feature importance to: {output_file}")


if __name__ == "__main__":
    main()
