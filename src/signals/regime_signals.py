from datetime import datetime, timezone

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
