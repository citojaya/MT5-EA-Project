from datetime import datetime, timezone

import pandas as pd


REGIME_MAP = {
    0: "Choppy",
    1: "Uncertain",
    2: "Trending",
}

PROBABILITY_COLUMNS = {
    0: "choppy_probability",
    1: "uncertain_probability",
    2: "trending_probability",
}


def generate_regime_signals(
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

        class_probabilities = {
            PROBABILITY_COLUMNS[class_id]: float(
                probabilities[row_index][classes.index(class_id)]
            )
            for class_id in REGIME_MAP
        }

        rows.append(
            {
                "time": row["time"],
                "symbol": symbol,
                "timeframe": timeframe,
                "close": float(row["close"]),
                "regime": regime,
                "regime_name": REGIME_MAP.get(regime, "Unknown"),
                "confidence": round(confidence, 6),
                **{
                    name: round(value, 6)
                    for name, value in class_probabilities.items()
                },
                "updated_utc": updated_utc,
            }
        )

    return pd.DataFrame(rows)
