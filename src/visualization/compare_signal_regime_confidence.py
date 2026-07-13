import argparse
from pathlib import Path

import pandas as pd


REQUIRED_COLUMNS = {"time", "regime", "confidence"}


def load_signal_file(path: Path, label: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    missing_columns = REQUIRED_COLUMNS - set(df.columns)
    if missing_columns:
        raise ValueError(f"{label} missing columns: {sorted(missing_columns)}")

    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True, errors="coerce")
    df["regime"] = pd.to_numeric(df["regime"], errors="coerce")
    df["confidence"] = pd.to_numeric(df["confidence"], errors="coerce")

    return (
        df.dropna(subset=["time"])
        .drop_duplicates("time", keep="last")
        .sort_values("time")
        .reset_index(drop=True)
    )


def compare_files(
    left_path: Path,
    right_path: Path,
    confidence_tolerance: float,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    left = load_signal_file(left_path, "left")
    right = load_signal_file(right_path, "right")

    merged = left[["time", "regime", "confidence"]].merge(
        right[["time", "regime", "confidence"]],
        on="time",
        how="inner",
        suffixes=("_left", "_right"),
    )
    merged = merged.sort_values("time").reset_index(drop=True)

    if merged.empty:
        return left, right, merged, merged

    merged["regime_match"] = (
        merged["regime_left"].astype("Int64")
        == merged["regime_right"].astype("Int64")
    )
    merged["confidence_diff"] = (
        merged["confidence_left"] - merged["confidence_right"]
    ).abs()
    merged["confidence_match"] = merged["confidence_diff"] <= confidence_tolerance

    mismatches = merged[
        (~merged["regime_match"]) | (~merged["confidence_match"])
    ].copy()

    return left, right, merged, mismatches


def print_report(
    left_path: Path,
    right_path: Path,
    left: pd.DataFrame,
    right: pd.DataFrame,
    merged: pd.DataFrame,
    mismatches: pd.DataFrame,
    confidence_tolerance: float,
    max_rows: int,
) -> None:
    print("Signal comparison report")
    print("=" * 80)
    print(f"Left file:  {left_path}")
    print(f"Right file: {right_path}")
    print(f"Confidence tolerance: {confidence_tolerance:g}")
    print()
    print(f"Left rows: {len(left):,}")
    print(f"Right rows: {len(right):,}")
    print(f"Common timestamps: {len(merged):,}")

    if merged.empty:
        print("No common timestamps found.")
        return

    regime_mismatches = int((~merged["regime_match"]).sum())
    confidence_mismatches = int((~merged["confidence_match"]).sum())
    max_confidence_diff = merged["confidence_diff"].max()

    print(f"Common time range: {merged['time'].min()} to {merged['time'].max()}")
    print(f"Regime mismatches: {regime_mismatches:,}")
    print(f"Confidence mismatches: {confidence_mismatches:,}")
    print(f"Max confidence diff: {max_confidence_diff}")
    print()

    if mismatches.empty:
        print("All common timestamps match for regime and confidence.")
        return

    print(f"Mismatched rows shown: {min(len(mismatches), max_rows):,} of {len(mismatches):,}")
    columns = [
        "time",
        "regime_left",
        "regime_right",
        "confidence_left",
        "confidence_right",
        "confidence_diff",
    ]
    print(mismatches[columns].head(max_rows).to_string(index=False))


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare regime and confidence columns for common timestamps."
    )
    parser.add_argument("left_file", type=Path)
    parser.add_argument("right_file", type=Path)
    parser.add_argument(
        "--confidence-tolerance",
        type=float,
        default=1e-6,
        help="Maximum absolute confidence difference treated as a match",
    )
    parser.add_argument(
        "--max-rows",
        type=int,
        default=200,
        help="Maximum mismatch rows to print",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    left, right, merged, mismatches = compare_files(
        args.left_file,
        args.right_file,
        args.confidence_tolerance,
    )
    print_report(
        args.left_file,
        args.right_file,
        left,
        right,
        merged,
        mismatches,
        args.confidence_tolerance,
        args.max_rows,
    )


if __name__ == "__main__":
    main()
