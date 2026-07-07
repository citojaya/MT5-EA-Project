import argparse
import json
from pathlib import Path

import joblib
import pandas as pd
from sklearn.metrics import classification_report, confusion_matrix
from xgboost import XGBClassifier

TARGET_COLUMN = "regime"
EXCLUDED_COLUMNS = {"time", "regime", "regime_name"}
TEST_SIZE = 0.20
RANDOM_STATE = 42


def load_dataset(input_file: Path) -> pd.DataFrame:
    df = pd.read_csv(input_file)
    if TARGET_COLUMN not in df.columns:
        raise ValueError(f"Missing target column: {TARGET_COLUMN}")
    if "time" not in df.columns:
        raise ValueError("Missing required column: time")
    df["time"] = pd.to_datetime(df["time"], utc=True)
    return df.sort_values("time").reset_index(drop=True)


def filter_date_range(
    df: pd.DataFrame,
    start: str | None = None,
    end: str | None = None,
) -> pd.DataFrame:
    filtered = df

    if start:
        start_time = pd.to_datetime(start, utc=True)
        filtered = filtered[filtered["time"] >= start_time]

    if end:
        end_time = pd.to_datetime(end, utc=True)
        filtered = filtered[filtered["time"] <= end_time]

    return filtered.reset_index(drop=True)


def select_feature_columns(df: pd.DataFrame) -> list[str]:
    candidate_columns = [column for column in df.columns if column not in EXCLUDED_COLUMNS]
    numeric_columns = df[candidate_columns].select_dtypes(include="number").columns
    return list(numeric_columns)


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
        objective="multi:softprob",
        eval_metric="mlogloss",
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )
    model.fit(x_train, y_train)
    return model


def save_artifacts(
    model: XGBClassifier,
    feature_columns: list[str],
    model_file: Path,
    feature_columns_file: Path,
) -> None:
    model_file.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, model_file)
    feature_columns_file.write_text(json.dumps(feature_columns, indent=2), encoding="utf-8")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument(
        "mode",
        choices=["backtest", "live"],
        help="Artifact prefix: use 'backtest' for backtest models or 'live' for live models",
    )
    parser.add_argument("start", nargs="?", help="Optional inclusive start datetime")
    parser.add_argument("end", nargs="?", help="Optional inclusive end datetime")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    mode = args.mode.lower()

    input_file = Path(f"data/labels/{symbol}_{timeframe}_regime_labels.csv")
    model_dir = Path(f"data/models/stage1_regime_{symbol}_{timeframe}")
    model_file = model_dir / f"{mode}_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"{mode}_feature_columns_{symbol}_{timeframe}.json"

    df = load_dataset(input_file)
    df = filter_date_range(df, args.start, args.end)

    if df.empty:
        raise ValueError("No rows found for the selected training date range")

    feature_columns = select_feature_columns(df)

    if not feature_columns:
        raise ValueError("No numeric feature columns found")

    model_data = df[feature_columns + [TARGET_COLUMN]].dropna()
    x = model_data[feature_columns]
    y = model_data[TARGET_COLUMN].astype(int)

    x_train, x_test, y_train, y_test = chronological_split(x, y)

    print(f"Rows: {len(model_data)}")
    print(f"Date range: {df['time'].min()} to {df['time'].max()}")
    print(f"Train rows: {len(x_train)}")
    print(f"Test rows: {len(x_test)}")
    print(f"Feature count: {len(feature_columns)}")
    print("Training stage 1 regime classifier without shuffling time series data...")

    model = train_model(x_train, y_train)
    predictions = model.predict(x_test)

    labels = sorted(y.unique())
    print()
    print("Classification report:")
    print(classification_report(y_test, predictions, labels=labels, zero_division=0))

    print("Confusion matrix:")
    print(confusion_matrix(y_test, predictions, labels=labels))

    save_artifacts(model, feature_columns, model_file, feature_columns_file)
    print()
    print(f"Saved model to: {model_file}")
    print(f"Saved feature columns to: {feature_columns_file}")


if __name__ == "__main__":
    main()
