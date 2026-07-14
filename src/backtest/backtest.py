import argparse
from datetime import datetime
import json
from pathlib import Path
import sys

import joblib
import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.signals.regime_signals import generate_regime_signals
from src.data.history_paths import (
    features_dir_for_config,
    find_existing_history_file,
    models_dir_for_config,
    raw_dir_for_config,
)
from src.features.build_features import build_features


HISTORY_BARS = 1000
MT5_COMMON_FILES_DIR = Path.home() / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"


def output_symbol_for_config(symbol: str, config_file: str) -> str:
    config_name = Path(config_file).stem
    if (
        config_name.startswith("config_mt5_ICM")
        or config_name.startswith("mt5_config_ICM")
    ) and not symbol.endswith(".a"):
        return f"{symbol}.a"
    return symbol


def parse_raw_history_range(path: Path) -> tuple[datetime, datetime] | None:
    parts = path.stem.rsplit("_", maxsplit=2)
    if len(parts) != 3:
        return None

    try:
        start = datetime.strptime(parts[1], "%Y%m%d")
        end = datetime.strptime(parts[2], "%Y%m%d")
    except ValueError:
        return None

    return start, end


def find_raw_history_file_for_range(
    search_dirs: list[Path],
    symbol: str,
    timeframe: str,
    start: str,
    end: str,
) -> Path | None:
    start_time = pd.to_datetime(start, utc=True).tz_localize(None)
    end_time = pd.to_datetime(end, utc=True).tz_localize(None)
    pattern = f"{symbol}_bidask_{timeframe}_*.csv"
    containing_candidates = []
    overlapping_candidates = []

    for raw_dir in search_dirs:
        for path in raw_dir.glob(pattern):
            parsed_range = parse_raw_history_range(path)
            if parsed_range is None:
                continue

            file_start, file_end = parsed_range
            if file_start <= start_time and file_end >= end_time:
                containing_candidates.append(path)
            elif file_start <= end_time and file_end >= start_time:
                overlapping_candidates.append(path)

    if containing_candidates:
        return sorted(containing_candidates, key=lambda path: path.stat().st_mtime, reverse=True)[0]

    if overlapping_candidates:
        return sorted(overlapping_candidates, key=lambda path: path.stat().st_mtime, reverse=True)[0]

    return find_existing_history_file(search_dirs, symbol, timeframe)


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


def select_raw_history(
    df: pd.DataFrame,
    start: str,
    end: str,
    history_bars: int = HISTORY_BARS,
) -> pd.DataFrame:
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.sort_values("time").reset_index(drop=True)

    start_time = pd.to_datetime(start, utc=True)
    end_time = pd.to_datetime(end, utc=True)
    if start_time > end_time:
        raise ValueError("start must be before or equal to end")

    period_indexes = df.index[(df["time"] >= start_time) & (df["time"] <= end_time)]
    if period_indexes.empty:
        return df.iloc[0:0].copy()

    first_index = max(0, int(period_indexes[0]) - history_bars + 1)
    last_index = int(period_indexes[-1])
    return df.iloc[first_index:last_index + 1].copy()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start", type=str, help="Start datetime, e.g. 2026-01-01")
    parser.add_argument("end", type=str, help="End datetime, e.g. 2026-01-31 23:59")
    parser.add_argument(
        "--output",
        type=str,
        help="Optional output CSV path. Defaults to MT5 Common Files/{symbol}_{timeframe}_backtest_signals.csv",
    )
    parser.add_argument(
        "--rebuild-features",
        action="store_true",
        help="Rebuild and cache features from the raw OHLC CSV before backtesting",
    )
    parser.add_argument(
        "--config-file",
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the raw history subdirectory.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    output_symbol = output_symbol_for_config(symbol, args.config_file)
    timeframe = args.timeframe.upper()

    input_file = features_dir_for_config(args.config_file) / f"{symbol}_{timeframe}_features.csv"
    model_dir = models_dir_for_config(args.config_file) / f"stage1_regime_{symbol}_{timeframe}"
    model_file = model_dir / f"live_regime_model_{symbol}_{timeframe}.joblib"
    feature_columns_file = model_dir / f"live_feature_columns_{symbol}_{timeframe}.json"
    output_file = (
        Path(args.output)
        if args.output
        else MT5_COMMON_FILES_DIR / f"{symbol}_{timeframe}_backtest_signals.csv"
    )

    if args.rebuild_features:
        raw_file = find_raw_history_file_for_range(
            [raw_dir_for_config(args.config_file), Path("data/raw")],
            symbol,
            timeframe,
            args.start,
            args.end,
        )
        if raw_file is None:
            raise RuntimeError(f"No raw history file found for {symbol} {timeframe}")

        raw_data = pd.read_csv(raw_file)
        raw_data = select_raw_history(raw_data, args.start, args.end)
        if raw_data.empty:
            raise RuntimeError("No raw OHLC rows found for the selected date range")

        features = build_features(raw_data)
        input_file.parent.mkdir(parents=True, exist_ok=True)
        features.to_csv(input_file, index=False)
        print(f"Rebuilt features from: {raw_file} ({HISTORY_BARS}-bar history)")
        print(f"Cached features to: {input_file}")
    else:
        features = pd.read_csv(input_file)

    features = add_missing_regime_rank_features(features)
    features = filter_date_range(features, args.start, args.end)

    if features.empty:
        raise RuntimeError("No feature rows found for the selected date range")

    model, feature_columns = load_model(model_file, feature_columns_file)
    signals = generate_regime_signals(
        features=features,
        model=model,
        feature_columns=feature_columns,
        symbol=output_symbol,
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
