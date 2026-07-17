import argparse
from pathlib import Path

import pandas as pd


COMPARE_COLUMNS = [
    "open",
    "high",
    "low",
    "close",
    "tick_volume",
    "spread",
    "real_volume",
    "bid",
    "ask",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare two OHLC CSV files at their common UTC timestamps."
    )
    parser.add_argument("file1", type=Path, help="Path to the first OHLC CSV")
    parser.add_argument("file2", type=Path, help="Path to the second OHLC CSV")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/comparison"),
        help="Directory for mismatch reports (default: data/comparison)",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=1e-12,
        help="Maximum numeric difference treated as equal (default: 1e-12)",
    )
    return parser.parse_args()


def load_csv(path: Path) -> pd.DataFrame:
    if not path.is_file():
        raise FileNotFoundError(f"CSV file not found: {path}")

    df = pd.read_csv(path)
    if "time" not in df.columns:
        raise ValueError(f"{path} has no 'time' column")

    df["time"] = pd.to_datetime(df["time"], utc=True, errors="raise")
    return df.sort_values("time").reset_index(drop=True)


def safe_stem(path: Path) -> str:
    return "".join(character if character.isalnum() else "_" for character in path.stem)


def main() -> None:
    args = parse_args()
    if args.tolerance < 0:
        raise ValueError("--tolerance must be zero or greater")

    first = load_csv(args.file1)
    second = load_csv(args.file2)

    first_times = set(first["time"])
    second_times = set(second["time"])
    common_times = first_times & second_times
    only_first = first_times - second_times
    only_second = second_times - first_times

    print(f"File 1:             {args.file1}")
    print(f"File 2:             {args.file2}")
    print(f"File 1 rows:        {len(first):,}")
    print(f"File 2 rows:        {len(second):,}")
    print(f"File 1 duplicates:  {first['time'].duplicated().sum():,}")
    print(f"File 2 duplicates:  {second['time'].duplicated().sum():,}")
    print(f"Common timestamps:  {len(common_times):,}")
    print(f"Only in File 1:     {len(only_first):,}")
    print(f"Only in File 2:     {len(only_second):,}")

    if common_times:
        print(f"First common time:  {min(common_times)}")
        print(f"Last common time:   {max(common_times)}")

    common_columns = [
        column
        for column in COMPARE_COLUMNS
        if column in first.columns and column in second.columns
    ]
    if not common_columns:
        raise ValueError("The files have no common OHLC/value columns to compare")

    merged = first.merge(second, on="time", how="inner", suffixes=("_file1", "_file2"))
    mismatch_mask = pd.Series(False, index=merged.index)

    print("\nColumn comparison:")
    for column in common_columns:
        first_values = pd.to_numeric(merged[f"{column}_file1"], errors="coerce")
        second_values = pd.to_numeric(merged[f"{column}_file2"], errors="coerce")
        valid = first_values.notna() & second_values.notna()
        difference = (first_values - second_values).abs()
        column_mismatch = valid & (difference > args.tolerance)
        mismatch_mask |= column_mismatch

        print(
            f"{column:12} "
            f"matches={(valid & ~column_mismatch).sum():,} "
            f"mismatches={column_mismatch.sum():,} "
            f"max_difference={difference[valid].max():.10f}"
        )

    mismatches = merged.loc[mismatch_mask].copy()
    print(f"\nRows with value differences: {len(mismatches):,}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"{safe_stem(args.file1)}_vs_{safe_stem(args.file2)}"

    if not mismatches.empty:
        mismatch_file = args.output_dir / f"{prefix}_mismatches.csv"
        mismatches.to_csv(mismatch_file, index=False)
        print(f"Mismatch details:   {mismatch_file}")

    if only_first:
        only_first_file = args.output_dir / f"{prefix}_only_file1.csv"
        pd.DataFrame({"time": sorted(only_first)}).to_csv(only_first_file, index=False)
        print(f"Only File 1 times:  {only_first_file}")

    if only_second:
        only_second_file = args.output_dir / f"{prefix}_only_file2.csv"
        pd.DataFrame({"time": sorted(only_second)}).to_csv(only_second_file, index=False)
        print(f"Only File 2 times:  {only_second_file}")


if __name__ == "__main__":
    main()
