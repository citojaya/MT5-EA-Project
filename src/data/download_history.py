import argparse
import json
from datetime import datetime, timedelta, timezone

import MetaTrader5 as mt5
import pandas as pd


# -----------------------------
# USER SETTINGS
# -----------------------------
with open("config/mt5_config_FXV.json", "r", encoding="utf-8") as f:
    cfg = json.load(f)

ACCOUNT = int(cfg["login"])
SERVER = str(cfg["server"])
PASSWORD = str(cfg["password"])

TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}

DATE_FROM = datetime(2025, 1, 1, tzinfo=timezone.utc)
DATE_TO = datetime(2026, 12, 31, tzinfo=timezone.utc)


# =========================================================
# MT5 HELPERS
# =========================================================
def connect_mt5():
    if not mt5.initialize(login=ACCOUNT, server=SERVER, password=PASSWORD):
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


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=str, help="Trading symbol, e.g. XAUUSD")
    parser.add_argument("timeframe", type=str, help="Timeframe, e.g. M1 or M5")
    return parser.parse_args()


def main():
    args = parse_args()
    symbol = args.symbol
    timeframe_name = args.timeframe.upper()

    if timeframe_name not in TIMEFRAME_MAP:
        valid_timeframes = ", ".join(TIMEFRAME_MAP)
        raise ValueError(f"Unsupported timeframe '{args.timeframe}'. Use one of: {valid_timeframes}")

    out_csv = (
        f"data/raw/{symbol}_bidask_{timeframe_name}_"
        f"{DATE_FROM:%Y%m%d}_{DATE_TO:%Y%m%d}.csv"
    )

    connect_mt5()
    try:
        df = fetch_history_chunked(symbol, TIMEFRAME_MAP[timeframe_name], DATE_FROM, DATE_TO)

        if df.empty:
            print("No data returned.")
            return

        df.to_csv(out_csv, index=False)

        print(f"\nSaved: {out_csv}")
        print(df[["time", "bid", "ask", "spread"]].head(3))
        print(df[["time", "bid", "ask", "spread"]].tail(3))

    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
