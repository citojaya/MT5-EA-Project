import json
from pathlib import Path

import joblib
import pandas as pd
from sklearn.metrics import classification_report, confusion_matrix
from xgboost import XGBClassifier


SYMBOL = "BTCUSD"
TIMEFRAME = "M5"

INPUT_FILE = Path(f"data/labels/{SYMBOL}_{TIMEFRAME}_trade_labels.csv")
MODEL_DIR = Path(f"models/stage2_signal_{SYMBOL}")
MODEL_FILE = MODEL_DIR / f"trade_model_{SYMBOL}.joblib"
FEATURE_COLUMNS_FILE = MODEL_DIR / f"feature_columns_{SYMBOL}.json"
LABEL_MAP_FILE = MODEL_DIR / f"label_map_{SYMBOL}.json"

TARGET_COLUMN = "trade_label"
EXCLUDED_COLUMNS = {
    "time",
    "trade_label",
    "trade_label_name",
    "regime_name",
}
TEST_SIZE = 0.20
RANDOM_STATE = 42


def load_dataset(input_file: Path = INPUT_FILE) -> pd.DataFrame:
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
) -> None:
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, MODEL_FILE)
    FEATURE_COLUMNS_FILE.write_text(json.dumps(feature_columns, indent=2), encoding="utf-8")
    LABEL_MAP_FILE.write_text(
        json.dumps(
            {
                "label_to_class": label_to_class,
                "class_to_label": class_to_label,
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def main() -> None:
    df = load_dataset()
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

    save_artifacts(model, feature_columns, label_to_class, class_to_label)
    print()
    print(f"Saved model to: {MODEL_FILE}")
    print(f"Saved feature columns to: {FEATURE_COLUMNS_FILE}")
    print(f"Saved label map to: {LABEL_MAP_FILE}")


if __name__ == "__main__":
    main()
