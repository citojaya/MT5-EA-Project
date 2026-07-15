import argparse
import json
from pathlib import Path
import sys

import joblib
import pandas as pd
from sklearn.metrics import classification_report, confusion_matrix
from xgboost import XGBClassifier

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import labels_dir_for_config, models_dir_for_config
from src.models.train_stage1_regime import NORMALIZED_FEATURE_COLUMNS


SYMBOL = "BTCUSD"
TIMEFRAME = "M5"

TARGET_COLUMN = "trade_label"
STAGE2_FEATURE_COLUMNS = NORMALIZED_FEATURE_COLUMNS + [
    "regime",
    "order_direction",
]
EXCLUDED_COLUMNS = {
    "time",
    "trade_label",
    "trade_label_name",
    "regime_name",
    "entry_price",
    "future_close_5",
    "future_return_5",
    "directional_return_5",
}
TEST_SIZE = 0.20
RANDOM_STATE = 42


def load_dataset(input_file: Path) -> pd.DataFrame:
    df = pd.read_csv(input_file)
    if TARGET_COLUMN not in df.columns:
        raise ValueError(f"Missing target column: {TARGET_COLUMN}")
    return df.sort_values("time").reset_index(drop=True)


def select_feature_columns(df: pd.DataFrame) -> list[str]:
    missing_columns = [
        column for column in STAGE2_FEATURE_COLUMNS if column not in df.columns
    ]
    if missing_columns:
        missing_text = ", ".join(missing_columns)
        raise ValueError(
            "Missing stage 2 feature columns. Rebuild trade labels first: "
            f"{missing_text}"
        )

    numeric_columns = df[STAGE2_FEATURE_COLUMNS].select_dtypes(include="number").columns
    non_numeric_columns = [
        column for column in STAGE2_FEATURE_COLUMNS if column not in numeric_columns
    ]
    if non_numeric_columns:
        non_numeric_text = ", ".join(non_numeric_columns)
        raise ValueError(f"Stage 2 feature columns must be numeric: {non_numeric_text}")

    return STAGE2_FEATURE_COLUMNS.copy()


def chronological_split(
    features: pd.DataFrame,
    target: pd.Series,
    test_size: float = TEST_SIZE,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.Series, pd.Series]:
    if not 0 < test_size < 1:
        raise ValueError("test_size must be between 0 and 1")

    split_index = int(len(features) * (1 - test_size))
    if split_index <= 0 or split_index >= len(features):
        raise ValueError("Not enough rows for chronological train/test split")

    x_train = features.iloc[:split_index]
    x_test = features.iloc[split_index:]
    y_train = target.iloc[:split_index]
    y_test = target.iloc[split_index:]
    return x_train, x_test, y_train, y_test


def train_model(x_train: pd.DataFrame, y_train: pd.Series) -> XGBClassifier:
    model = XGBClassifier(
        n_estimators=300,
        max_depth=5,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        objective="binary:logistic",
        eval_metric="logloss",
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )
    model.fit(x_train, y_train)
    return model


def save_artifacts(
    model: XGBClassifier,
    feature_columns: list[str],
    model_dir: Path,
    model_file: Path,
    feature_columns_file: Path,
    metadata_file: Path,
) -> None:
    model_dir.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, model_file)
    feature_columns_file.write_text(json.dumps(feature_columns, indent=2), encoding="utf-8")
    metadata_file.write_text(
        json.dumps(
            {
                "target_column": TARGET_COLUMN,
                "target_meaning": {
                    "0": "next 5 completed candles were not favorable",
                    "1": "next 5 completed candles were favorable",
                },
                "eligible_regimes": [0, 2],
                "order_direction": {
                    "1": "buy-style setup from regime 0",
                    "-1": "sell-style setup from regime 2",
                },
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", nargs="?", default=SYMBOL, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", nargs="?", default=TIMEFRAME, help="Timeframe, e.g. M5")
    parser.add_argument(
        "--config-file",
        default="config/mt5_config_ICM_DEMO.json",
        help="MT5 config file. Broker/server in this file controls the data subdirectory.",
    )
    parser.add_argument(
        "mode",
        nargs="?",
        default="live",
        choices=["backtest", "live"],
        help="Artifact prefix: use 'backtest' for backtest models or 'live' for live models",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    mode = args.mode.lower()
    input_file = labels_dir_for_config(args.config_file) / f"{symbol}_{timeframe}_trade_labels.csv"
    model_dir = models_dir_for_config(args.config_file) / f"stage2_trade_{symbol}_{timeframe}"
    model_file = model_dir / f"{mode}_trade_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"{mode}_feature_columns_{symbol}_{timeframe}.json"
    metadata_file = model_dir / f"{mode}_metadata_{symbol}_{timeframe}.json"

    df = load_dataset(input_file)
    feature_columns = select_feature_columns(df)

    if not feature_columns:
        raise ValueError("No numeric feature columns found")

    model_data = df[feature_columns + [TARGET_COLUMN]].dropna()
    x = model_data[feature_columns]
    y = model_data[TARGET_COLUMN].astype(int)

    labels = sorted(y.unique())
    if labels != [0, 1]:
        raise ValueError(f"Stage 2 target must contain binary labels [0, 1], found: {labels}")

    x_train, x_test, y_train, y_test = chronological_split(x, y)

    print(f"Rows: {len(model_data)}")
    print(f"Train rows: {len(x_train)}")
    print(f"Test rows: {len(x_test)}")
    print(f"Feature count: {len(feature_columns)}")
    print("Trade label distribution:")
    print(y.value_counts().sort_index())
    print("Training stage 2 favorable-direction classifier without shuffling time series data...")

    model = train_model(x_train, y_train)
    predictions = model.predict(x_test)

    print()
    print("Classification report:")
    print(
        classification_report(
            y_test,
            predictions,
            labels=[0, 1],
            target_names=["Unfavorable", "Favorable"],
            zero_division=0,
        )
    )

    print("Confusion matrix:")
    print(confusion_matrix(y_test, predictions, labels=[0, 1]))

    save_artifacts(
        model,
        feature_columns,
        model_dir,
        model_file,
        feature_columns_file,
        metadata_file,
    )
    print()
    print(f"Saved model to: {model_file}")
    print(f"Saved feature columns to: {feature_columns_file}")
    print(f"Saved metadata to: {metadata_file}")


if __name__ == "__main__":
    main()
