import argparse
import re
from pathlib import Path

import pandas as pd


RAW_DIR = Path("data/raw")
OUTPUT_DIR = Path("data/correlation")
RAW_FILE_PATTERN = re.compile(
    r"^(?P<symbol>[A-Z0-9]+)_bidask_(?P<timeframe>[A-Z0-9]+)_(?P<start>\d{8})_(?P<end>\d{8})\.csv$"
)


def parse_raw_file_name(path: Path) -> dict[str, str] | None:
    match = RAW_FILE_PATTERN.match(path.name)
    if match is None:
        return None
    return match.groupdict()


def find_raw_files(raw_dir: Path, timeframe: str | None) -> list[Path]:
    files = []
    for path in raw_dir.glob("*.csv"):
        parsed = parse_raw_file_name(path)
        if parsed is None:
            continue
        if timeframe and parsed["timeframe"] != timeframe:
            continue
        files.append(path)

    return sorted(files)


def load_close_series(path: Path) -> pd.Series:
    parsed = parse_raw_file_name(path)
    if parsed is None:
        raise ValueError(f"Unsupported raw file name: {path.name}")

    df = pd.read_csv(path, usecols=["time", "close"])
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.drop_duplicates("time", keep="last").sort_values("time")

    series = pd.Series(
        data=pd.to_numeric(df["close"], errors="coerce").values,
        index=df["time"],
        name=parsed["symbol"],
    )
    return series.dropna()


def build_aligned_close_frame(files: list[Path]) -> pd.DataFrame:
    series_list = [load_close_series(path) for path in files]
    if not series_list:
        raise ValueError("No valid raw CSV files found")

    close_frame = pd.concat(series_list, axis=1, join="inner")
    close_frame = close_frame.sort_index()

    if close_frame.empty:
        raise ValueError("No overlapping timestamps found across raw files")

    return close_frame


def calculate_correlation(close_frame: pd.DataFrame, mode: str) -> pd.DataFrame:
    if mode == "close":
        return close_frame.corr()

    if mode == "return":
        returns = close_frame.pct_change().dropna()
        if returns.empty:
            raise ValueError("Not enough rows to calculate return correlation")
        return returns.corr()

    raise ValueError(f"Unsupported correlation mode: {mode}")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare correlation among raw forex pair CSV files."
    )
    parser.add_argument("--raw-dir", type=Path, default=RAW_DIR)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT_DIR)
    parser.add_argument("--timeframe", default="M5", help="Filter raw files by timeframe")
    parser.add_argument(
        "--mode",
        choices=["return", "close"],
        default="return",
        help="Use percentage returns or raw close values for correlation",
    )
    parser.add_argument(
        "--min-abs-correlation",
        type=float,
        default=0.0,
        help="Print pair list with absolute correlation greater than or equal to this value",
    )
    return parser.parse_args()


def print_pair_correlations(correlation: pd.DataFrame, min_abs_correlation: float):
    rows = []
    symbols = list(correlation.columns)

    for left_index, left_symbol in enumerate(symbols):
        for right_symbol in symbols[left_index + 1:]:
            value = correlation.loc[left_symbol, right_symbol]
            if abs(value) >= min_abs_correlation:
                rows.append(
                    {
                        "pair_1": left_symbol,
                        "pair_2": right_symbol,
                        "correlation": value,
                    }
                )

    if not rows:
        print("No pair correlations matched the selected threshold.")
        return

    pair_frame = pd.DataFrame(rows).sort_values(
        "correlation",
        key=lambda column: column.abs(),
        ascending=False,
    )
    print()
    print("Pair correlations:")
    print(pair_frame.to_string(index=False))


def main():
    args = parse_args()
    timeframe = args.timeframe.upper() if args.timeframe else None

    files = find_raw_files(args.raw_dir, timeframe)
    if not files:
        raise RuntimeError(f"No raw CSV files found in {args.raw_dir}")

    close_frame = build_aligned_close_frame(files)
    correlation = calculate_correlation(close_frame, args.mode)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    output_file = args.output_dir / f"pair_correlation_{timeframe}_{args.mode}.csv"
    correlation.to_csv(output_file)

    print(f"Files used: {len(files)}")
    for path in files:
        print(f"- {path.name}")
    print()
    print(f"Aligned rows: {len(close_frame):,}")
    print(f"Time range: {close_frame.index.min()} to {close_frame.index.max()}")
    print()
    print("Correlation matrix:")
    print(correlation.round(4).to_string())
    print()
    print(f"Saved correlation matrix to: {output_file}")

    print_pair_correlations(correlation, args.min_abs_correlation)


if __name__ == "__main__":
    main()
