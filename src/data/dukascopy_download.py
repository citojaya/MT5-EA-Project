import argparse
from pathlib import Path
import sys

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import load_config, raw_dir_for_config, raw_history_path


DEFAULT_RAW_DIR = Path("data/raw/Dukascopy")
DEFAULT_CONFIG_FILE = Path("config/mt5_config_ICM_DEMO.json")
DEFAULT_SYMBOL = "XAUUSD"
DEFAULT_TIMEFRAME = "M1"
DEFAULT_START = "2026.01.01"
DEFAULT_END = "2026.06.30"
DEFAULT_TIMEZONE = "Europe/Helsinki"

DUKASCOPY_TIMEFRAMES = {
    "M1": "1 Min",
    "M5": "5 Mins",
    "M15": "15 Mins",
    "M30": "30 Mins",
    "H1": "1 Hour",
    "H4": "4 Hours",
    "D1": "1 Day",
}

# IC Markets symbol point sizes used to express spread in MT5 points.
# Override with --point if the target account's symbol specification differs.
DEFAULT_POINT_BY_SYMBOL = {
    "XAUUSD": 0.01,
    "US30": 0.01,
    "GBPJPY": 0.001,
    "USDJPY": 0.001,
    "EURUSD": 0.00001,
    "GBPUSD": 0.00001,
    "AUDUSD": 0.00001,
    "NZDUSD": 0.00001,
    "USDCAD": 0.00001,
}


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

    unmatched_bid = len(bid) - len(merged)
    unmatched_ask = len(ask) - len(merged)
    if unmatched_bid or unmatched_ask:
        print(
            "Warning: inner timestamp join discarded "
            f"{unmatched_bid:,} Bid rows and {unmatched_ask:,} Ask rows"
        )

    negative_spread = merged["ask_close"] < merged["bid_close"]
    if negative_spread.any():
        first_bad_time = merged.loc[negative_spread, "time"].iloc[0]
        raise ValueError(
            f"Ask close is below Bid close in {negative_spread.sum():,} rows; "
            f"first occurrence: {first_bad_time}"
        )

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
        description=(
            "Convert Dukascopy EET Bid/Ask candle CSV files into the same UTC "
            "raw-history format used by the IC Markets MT5 pipeline."
        )
    )
    parser.add_argument("--symbol", default=DEFAULT_SYMBOL)
    parser.add_argument("--timeframe", default=DEFAULT_TIMEFRAME)
    parser.add_argument(
        "--dukascopy-timeframe",
        help="Text used in Dukascopy filenames; inferred from --timeframe when omitted",
    )
    parser.add_argument("--start", default=DEFAULT_START)
    parser.add_argument("--end", default=DEFAULT_END)
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    parser.add_argument("--ask-file", type=Path)
    parser.add_argument("--bid-file", type=Path)
    parser.add_argument("--output-file", type=Path)
    parser.add_argument(
        "--config-file",
        type=Path,
        default=DEFAULT_CONFIG_FILE,
        help="IC Markets MT5 config used to choose the broker-specific output directory",
    )
    parser.add_argument(
        "--timezone",
        default=DEFAULT_TIMEZONE,
        help="Timezone of the Dukascopy timestamp column before converting to UTC",
    )
    parser.add_argument(
        "--point",
        type=float,
        help=(
            "IC Markets symbol point size used to convert ask-bid spread into MT5 points; "
            "inferred for supported symbols when omitted"
        ),
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol.upper()
    timeframe = args.timeframe.upper()
    dukascopy_timeframe = args.dukascopy_timeframe or DUKASCOPY_TIMEFRAMES.get(timeframe)
    if dukascopy_timeframe is None:
        valid = ", ".join(DUKASCOPY_TIMEFRAMES)
        raise ValueError(f"Unsupported timeframe '{timeframe}'. Use one of: {valid}")

    point = args.point or DEFAULT_POINT_BY_SYMBOL.get(symbol)
    if point is None or point <= 0:
        raise ValueError(
            f"No valid IC Markets point size configured for {symbol}; pass --point explicitly"
        )

    ask_file = args.ask_file or default_dukascopy_file(
        args.raw_dir,
        symbol,
        dukascopy_timeframe,
        "Ask",
        args.start,
        args.end,
    )
    bid_file = args.bid_file or default_dukascopy_file(
        args.raw_dir,
        symbol,
        dukascopy_timeframe,
        "Bid",
        args.start,
        args.end,
    )
    cfg = load_config(args.config_file)
    ic_markets_raw_dir = raw_dir_for_config(args.config_file, cfg)
    output_file = args.output_file or raw_history_path(
        ic_markets_raw_dir,
        symbol,
        timeframe,
        date_token(args.start),
        date_token(args.end),
    )

    ask = load_dukascopy_file(ask_file, "ask", args.timezone)
    bid = load_dukascopy_file(bid_file, "bid", args.timezone)
    combined = combine_bid_ask(bid, ask, point)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    combined.to_csv(output_file, index=False)

    print(f"Ask file: {ask_file}")
    print(f"Bid file: {bid_file}")
    print(f"Source timezone: {args.timezone} -> UTC")
    print(f"IC Markets point size: {point}")
    print(f"Saved: {output_file}")
    print(f"Rows: {len(combined):,}")
    print(f"Time range: {combined['time'].min()} to {combined['time'].max()}")
    print()
    print(combined.head(3))
    print(combined.tail(3))


if __name__ == "__main__":
    main()
