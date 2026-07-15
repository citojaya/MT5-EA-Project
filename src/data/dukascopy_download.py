import argparse
from pathlib import Path

import pandas as pd


DEFAULT_RAW_DIR = Path("data/raw/Dukascopy")
DEFAULT_SYMBOL = "XAUUSD"
DEFAULT_TIMEFRAME = "M1"
DEFAULT_DUKASCOPY_TIMEFRAME = "1 Min"
DEFAULT_START = "2026.01.01"
DEFAULT_END = "2026.06.30"
DEFAULT_TIMEZONE = "Europe/Helsinki"
DEFAULT_POINT = 0.01


DUKASCOPY_COLUMNS = {
    "Time (EET)": "time",
    "Open": "open",
    "High": "high",
    "Low": "low",
    "Close": "close",
    "Volume ": "volume",
    "Volume": "volume",
}


def default_dukascopy_file(
    raw_dir: Path,
    symbol: str,
    dukascopy_timeframe: str,
    side: str,
    start: str,
    end: str,
) -> Path:
    return raw_dir / f"{symbol}_{dukascopy_timeframe}_{side}_{start}_{end}.csv"


def date_token(value: str) -> str:
    return value.replace(".", "").replace("-", "")


def load_dukascopy_file(path: Path, side: str, timezone_name: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df = df.rename(columns={column: column.strip() for column in df.columns})
    df = df.rename(columns=DUKASCOPY_COLUMNS)

    required_columns = {"time", "open", "high", "low", "close", "volume"}
    missing_columns = required_columns - set(df.columns)
    if missing_columns:
        raise ValueError(f"{path} missing columns: {sorted(missing_columns)}")

    df = df[list(required_columns)].copy()
    df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M:%S")
    df["time"] = (
        df["time"]
        .dt.tz_localize(timezone_name, ambiguous="infer", nonexistent="shift_forward")
        .dt.tz_convert("UTC")
    )

    price_columns = ["open", "high", "low", "close", "volume"]
    for column in price_columns:
        df[column] = pd.to_numeric(df[column], errors="coerce")

    df = (
        df.dropna(subset=["time", "open", "high", "low", "close"])
        .drop_duplicates("time", keep="last")
        .sort_values("time")
        .reset_index(drop=True)
    )

    return df.rename(
        columns={
            "open": f"{side}_open",
            "high": f"{side}_high",
            "low": f"{side}_low",
            "close": f"{side}_close",
            "volume": f"{side}_volume",
        }
    )


def combine_bid_ask(
    bid: pd.DataFrame,
    ask: pd.DataFrame,
    point: float,
) -> pd.DataFrame:
    merged = bid.merge(ask, on="time", how="inner").sort_values("time")
    if merged.empty:
        raise ValueError("No common timestamps found between bid and ask files")

    output = pd.DataFrame()
    output["time"] = merged["time"]
    output["open"] = merged["bid_open"]
    output["high"] = merged["bid_high"]
    output["low"] = merged["bid_low"]
    output["close"] = merged["bid_close"]
    output["tick_volume"] = merged["bid_volume"]
    output["spread"] = ((merged["ask_close"] - merged["bid_close"]) / point).round().astype(int)
    output["real_volume"] = 0
    output["bid"] = merged["bid_close"]
    output["ask"] = merged["ask_close"]

    return output.reset_index(drop=True)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Combine Dukascopy bid/ask CSV files into an ML-ready OHLC CSV."
    )
    parser.add_argument("--symbol", default=DEFAULT_SYMBOL)
    parser.add_argument("--timeframe", default=DEFAULT_TIMEFRAME)
    parser.add_argument("--dukascopy-timeframe", default=DEFAULT_DUKASCOPY_TIMEFRAME)
    parser.add_argument("--start", default=DEFAULT_START)
    parser.add_argument("--end", default=DEFAULT_END)
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    parser.add_argument("--ask-file", type=Path)
    parser.add_argument("--bid-file", type=Path)
    parser.add_argument("--output-file", type=Path)
    parser.add_argument(
        "--timezone",
        default=DEFAULT_TIMEZONE,
        help="Timezone of the Dukascopy timestamp column before converting to UTC",
    )
    parser.add_argument(
        "--point",
        type=float,
        default=DEFAULT_POINT,
        help="Symbol point size used to convert ask-bid price spread into spread points",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol.upper()
    timeframe = args.timeframe.upper()

    ask_file = args.ask_file or default_dukascopy_file(
        args.raw_dir,
        symbol,
        args.dukascopy_timeframe,
        "Ask",
        args.start,
        args.end,
    )
    bid_file = args.bid_file or default_dukascopy_file(
        args.raw_dir,
        symbol,
        args.dukascopy_timeframe,
        "Bid",
        args.start,
        args.end,
    )
    output_file = args.output_file or (
        args.raw_dir
        / f"{symbol}_bidask_{timeframe}_{date_token(args.start)}_{date_token(args.end)}.csv"
    )

    ask = load_dukascopy_file(ask_file, "ask", args.timezone)
    bid = load_dukascopy_file(bid_file, "bid", args.timezone)
    combined = combine_bid_ask(bid, ask, args.point)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    combined.to_csv(output_file, index=False)

    print(f"Ask file: {ask_file}")
    print(f"Bid file: {bid_file}")
    print(f"Saved: {output_file}")
    print(f"Rows: {len(combined):,}")
    print(f"Time range: {combined['time'].min()} to {combined['time'].max()}")
    print()
    print(combined.head(3))
    print(combined.tail(3))


if __name__ == "__main__":
    main()
