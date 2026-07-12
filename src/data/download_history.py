import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

import MetaTrader5 as mt5
import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.append(str(ROOT_DIR))

from src.data.history_paths import (
    RAW_DIR,
    find_existing_history_file,
    load_config,
    raw_dir_for_config,
    raw_history_path,
)

TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}

TIMEFRAME_DELTA_MAP = {
    "M1": timedelta(minutes=1),
    "M5": timedelta(minutes=5),
    "M15": timedelta(minutes=15),
    "M30": timedelta(minutes=30),
    "H1": timedelta(hours=1),
    "H4": timedelta(hours=4),
    "D1": timedelta(days=1),
}


def parse_utc_datetime(value: str) -> datetime:
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y%m%d"):
        try:
            parsed = datetime.strptime(value, fmt)
            return parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(
        f"Invalid date '{value}'. Use YYYY-MM-DD, YYYY-MM-DD HH:MM, or YYYYMMDD."
    )


def prepare_output_file(out_csv: Path, symbol: str, timeframe_name: str) -> Path:
    if out_csv.exists():
        return out_csv

    existing_csv = find_existing_history_file(
        [out_csv.parent, RAW_DIR],
        symbol,
        timeframe_name,
    )
    if existing_csv is None:
        return out_csv

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    existing_csv.rename(out_csv)
    print(f"Renamed existing history file: {existing_csv} -> {out_csv}")
    return out_csv


def resolve_mt5_symbol(symbol: str, config_file: Path) -> str:
    if config_file.name == "mt5_config.json" and not symbol.endswith(".a"):
        return f"{symbol}.a"
    return symbol


# =========================================================
# MT5 HELPERS
# =========================================================
def connect_mt5(account: int, server: str, password: str):
    if not mt5.initialize(login=account, server=server, password=password):
        raise RuntimeError(f"MT5 init failed: {mt5.last_error()}")
    print("Connected:", mt5.version())


def fetch_history_chunked(
    symbol: str,
    timeframe: int,
    date_from_utc: datetime,
    date_to_utc: datetime,
    chunk_days: int = 30,
) -> pd.DataFrame:
    """
    Downloads bars in chunks.
    Adds reconstructed bid / ask prices.
    """
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        raise RuntimeError(f"Symbol info not found: {symbol}")

    point = symbol_info.point

    all_parts = []
    cur_from = date_from_utc

    while cur_from < date_to_utc:
        cur_to = min(cur_from + timedelta(days=chunk_days), date_to_utc)

        rates = mt5.copy_rates_range(symbol, timeframe, cur_from, cur_to)
        if rates is None:
            raise RuntimeError(f"copy_rates_range returned None: {mt5.last_error()}")

        if len(rates) > 0:
            part = pd.DataFrame(rates)

            # Convert MT5 time in UTC seconds to UTC datetime.
            part["time"] = pd.to_datetime(part["time"], unit="s", utc=True)

            # Reconstruct bid / ask prices from close and spread.
            part["bid"] = part["close"]
            part["ask"] = part["close"] + part["spread"] * point

            all_parts.append(part)
            print(f"{symbol} {cur_from.date()} -> {cur_to.date()} : {len(part):,} bars")
        else:
            print(f"{symbol} {cur_from.date()} -> {cur_to.date()} : 0 bars")

        cur_from = cur_to

    if not all_parts:
        return pd.DataFrame()

    df = pd.concat(all_parts, ignore_index=True)

    return (
        df.drop_duplicates(subset=["time"])
        .sort_values("time")
        .reset_index(drop=True)
    )


def load_existing_history(path: Path) -> pd.DataFrame:
    if not path.exists() or path.stat().st_size == 0:
        return pd.DataFrame()

    df = pd.read_csv(path)
    if df.empty:
        return df
    if "time" not in df.columns:
        raise ValueError(f"Existing history file is missing time column: {path}")

    df["time"] = pd.to_datetime(df["time"], utc=True)
    return (
        df.drop_duplicates(subset=["time"])
        .sort_values("time")
        .reset_index(drop=True)
    )


def next_download_start(
    existing: pd.DataFrame,
    default_start: datetime,
    timeframe_name: str,
) -> datetime:
    if existing.empty:
        return default_start

    last_time = existing["time"].max()
    return last_time.to_pydatetime() + TIMEFRAME_DELTA_MAP[timeframe_name]


def merge_history(existing: pd.DataFrame, new_data: pd.DataFrame) -> pd.DataFrame:
    if existing.empty:
        merged = new_data
    elif new_data.empty:
        merged = existing
    else:
        merged = pd.concat([existing, new_data], ignore_index=True)

    if merged.empty:
        return merged

    merged["time"] = pd.to_datetime(merged["time"], utc=True)
    return (
        merged.drop_duplicates(subset=["time"], keep="last")
        .sort_values("time")
        .reset_index(drop=True)
    )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    parser.add_argument("start_date", type=str, help="Start date, e.g. 2025-01-01")
    parser.add_argument("end_date", type=str, help="End date, e.g. 2026-12-31")
    parser.add_argument(
        "--config-file",
        default="config/mt5_config.json",
        help="MT5 config file. Broker/server in this file controls the raw history subdirectory.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    config_file = Path(args.config_file)
    cfg = load_config(config_file)
    account = int(cfg["login"])
    server = str(cfg["server"])
    password = str(cfg["password"])
    mt5_symbol = resolve_mt5_symbol(symbol, config_file)
    timeframe_name = args.timeframe.upper()
    date_from = parse_utc_datetime(args.start_date)
    date_to = parse_utc_datetime(args.end_date)

    if date_from > date_to:
        raise ValueError("start_date must be earlier than or equal to end_date")

    if timeframe_name not in TIMEFRAME_MAP:
        valid_timeframes = ", ".join(TIMEFRAME_MAP)
        raise ValueError(f"Unsupported timeframe '{args.timeframe}'. Use one of: {valid_timeframes}")

    raw_dir = raw_dir_for_config(config_file=config_file, cfg=cfg)
    out_csv = raw_history_path(raw_dir, symbol, timeframe_name, date_from, date_to)
    out_csv = prepare_output_file(out_csv, symbol, timeframe_name)

    existing = load_existing_history(out_csv)
    download_from = next_download_start(existing, date_from, timeframe_name)

    if not existing.empty:
        print(f"Existing history rows: {len(existing):,}")
        print(f"Existing history last time: {existing['time'].max()}")
        print(f"Next download start: {download_from}")

    connect_mt5(account, server, password)
    try:
        if download_from > date_to:
            print("Existing history already reaches or exceeds end_date. Nothing to download.")
            return

        new_data = fetch_history_chunked(
            mt5_symbol,
            TIMEFRAME_MAP[timeframe_name],
            download_from,
            date_to,
        )

        if new_data.empty and existing.empty:
            print("No data returned.")
            return

        df = merge_history(existing, new_data)
        out_csv.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(out_csv, index=False)

        print(f"\nSaved: {out_csv}")
        print(f"Rows saved: {len(df):,}")
        print(f"New rows downloaded: {len(new_data):,}")
        print(df[["time", "bid", "ask", "spread"]].head(3))
        print(df[["time", "bid", "ask", "spread"]].tail(3))

    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
