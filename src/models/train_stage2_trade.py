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


SYMBOL = "BTCUSD"
TIMEFRAME = "M5"

TARGET_COLUMN = "trade_label"
EXCLUDED_COLUMNS = {
    "time",
    "trade_label",
    "trade_label_name",
    "regime_name",
}
TEST_SIZE = 0.20
RANDOM_STATE = 42


def load_dataset(input_file: Path) -> pd.DataFrame:
    df = pd.read_csv(input_file)
    if TARGET_COLUMN not in df.columns:
        raise ValueError(f"Missing target column: {TARGET_COLUMN}")
    return df.sort_values("time").reset_index(drop=True)


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


def encode_labels(y: pd.Series) -> tuple[pd.Series, dict[int, int], dict[int, int]]:
    real_labels = [int(label) for label in sorted(y.astype(int).unique())]
    label_to_class = {label: class_id for class_id, label in enumerate(real_labels)}
    class_to_label = {class_id: label for label, class_id in label_to_class.items()}
    encoded = y.astype(int).map(label_to_class)
    return encoded, label_to_class, class_to_label


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
    label_to_class: dict[int, int],
    class_to_label: dict[int, int],
    model_dir: Path,
    model_file: Path,
    feature_columns_file: Path,
    label_map_file: Path,
) -> None:
    model_dir.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, model_file)
    feature_columns_file.write_text(json.dumps(feature_columns, indent=2), encoding="utf-8")
    label_map_file.write_text(
        json.dumps(
            {
                "label_to_class": label_to_class,
                "class_to_label": class_to_label,
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
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the data subdirectory.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    symbol = args.symbol
    timeframe = args.timeframe.upper()
    input_file = labels_dir_for_config(args.config_file) / f"{symbol}_{timeframe}_trade_labels.csv"
    model_dir = models_dir_for_config(args.config_file) / f"stage2_signal_{symbol}_{timeframe}"
    model_file = model_dir / f"trade_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"feature_columns_{symbol}_{timeframe}.json"
    label_map_file = model_dir / f"label_map_{symbol}_{timeframe}.json"

    df = load_dataset(input_file)
    feature_columns = select_feature_columns(df)

    if not feature_columns:
        raise ValueError("No numeric feature columns found")

    model_data = df[feature_columns + [TARGET_COLUMN]].dropna()
    x = model_data[feature_columns]
    y_real = model_data[TARGET_COLUMN].astype(int)
    y_encoded, label_to_class, class_to_label = encode_labels(y_real)

    x_train, x_test, y_train, y_test = chronological_split(x, y_encoded)

    print(f"Rows: {len(model_data)}")
    print(f"Train rows: {len(x_train)}")
    print(f"Test rows: {len(x_test)}")
    print(f"Feature count: {len(feature_columns)}")
    print("Real trade label distribution:")
    print(y_real.value_counts().sort_index())
    print("Training stage 2 trade classifier without shuffling time series data...")

    model = train_model(x_train, y_train)
    predictions = model.predict(x_test)

    encoded_labels = sorted(y_encoded.unique())
    target_names = [str(class_to_label[class_id]) for class_id in encoded_labels]

    print()
    print("Classification report:")
    print(
        classification_report(
            y_test,
            predictions,
            labels=encoded_labels,
            target_names=target_names,
            zero_division=0,
        )
    )

    print("Confusion matrix:")
    print(confusion_matrix(y_test, predictions, labels=encoded_labels))

    save_artifacts(
        model,
        feature_columns,
        label_to_class,
        class_to_label,
        model_dir,
        model_file,
        feature_columns_file,
        label_map_file,
    )
    print()
    print(f"Saved model to: {model_file}")
    print(f"Saved feature columns to: {feature_columns_file}")
    print(f"Saved label map to: {label_map_file}")


if __name__ == "__main__":
    main()
