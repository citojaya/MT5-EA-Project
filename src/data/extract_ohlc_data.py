import argparse
import json
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd


DEFAULT_SYMBOL = "XAUUSD"
DEFAULT_BARS = 2000
DEFAULT_CONFIG = "config/mt5_config_FXV.json"
OUTPUT_FILE = Path("data/raw/ohlc_data_XAUUSD.csv")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract the latest XAUUSD M5 OHLC bars from MetaTrader 5."
    )
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="Path to MT5 JSON config")
    parser.add_argument("--login", type=int, help="MT5 account login")
    parser.add_argument("--server", help="MT5 account server")
    parser.add_argument("--password", help="MT5 account password")
    parser.add_argument("--symbol", default=DEFAULT_SYMBOL, help="MT5 symbol to download")
    parser.add_argument("--bars", type=int, default=DEFAULT_BARS, help="Number of closed bars")
    parser.add_argument(
        "--include-current",
        action="store_true",
        help="Include the current unfinished candle instead of starting from the last closed candle",
    )
    return parser.parse_args()


def load_credentials(args):
    credentials = {}
    config_path = Path(args.config)

    if config_path.exists():
        with config_path.open("r", encoding="utf-8") as f:
            credentials = json.load(f)

    login = args.login if args.login is not None else credentials.get("login")
    server = args.server if args.server is not None else credentials.get("server")
    password = args.password if args.password is not None else credentials.get("password")

    if login is None or server is None or password is None:
        raise ValueError("MT5 login, server, and password are required")

    return int(login), str(server), str(password)


def connect_mt5(login: int, server: str, password: str):
    if not mt5.initialize(login=login, server=server, password=password):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")


def fetch_ohlc(symbol: str, bars: int, include_current: bool) -> pd.DataFrame:
    if bars <= 0:
        raise ValueError("bars must be greater than zero")

    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"Failed to select symbol {symbol}: {mt5.last_error()}")

    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        raise RuntimeError(f"Symbol info not found: {symbol}")

    start_pos = 0 if include_current else 1
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M5, start_pos, bars)
    if rates is None:
        raise RuntimeError(f"copy_rates_from_pos failed: {mt5.last_error()}")

    df = pd.DataFrame(rates)
    if df.empty:
        return df

    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df["bid"] = df["close"]
    df["ask"] = df["close"] + df["spread"] * symbol_info.point

    return df[
        [
            "time",
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
    ]


def main():
    args = parse_args()
    login, server, password = load_credentials(args)

    connect_mt5(login, server, password)
    try:
        df = fetch_ohlc(args.symbol, args.bars, args.include_current)
        if df.empty:
            print("No OHLC data returned.")
            return

        OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(OUTPUT_FILE, index=False)

        print(f"Saved {len(df):,} rows to {OUTPUT_FILE}")
        print(df.head(3))
        print(df.tail(3))
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
