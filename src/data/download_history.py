import os
from datetime import datetime, timedelta, timezone

import MetaTrader5 as mt5
import pandas as pd
import json


# -----------------------------
# USER SETTINGS
# -----------------------------
with open("config/mt5_config.json", "r", encoding="utf-8") as f:
    cfg = json.load(f)

ACCOUNT  = int(cfg["login"])
SERVER   = str(cfg["server"])
PASSWORD = str(cfg["password"])

SYMBOL    = "BTCUSD.a"
TIMEFRAME = mt5.TIMEFRAME_M5

DATE_FROM = datetime(2026, 1, 1, tzinfo=timezone.utc)
DATE_TO   = datetime(2026, 12, 31, tzinfo=timezone.utc)

OUT_CSV   = f"data/raw/{SYMBOL[:6]}_bidask_M5_{DATE_FROM:%Y%m%d}_{DATE_TO:%Y%m%d}.csv"


# =========================================================
# MT5 HELPERS
# =========================================================
def connect_mt5():
    if not mt5.initialize(login=ACCOUNT, server=SERVER, password=PASSWORD):
        raise RuntimeError(f"MT5 init failed: {mt5.last_error()}")
    print("Connected:", mt5.version())


def fetch_m1_history_chunked(
    date_from_utc: datetime,
    date_to_utc: datetime,
    chunk_days: int = 30
) -> pd.DataFrame:
    """
    Downloads M1 bars in chunks.
    Adds reconstructed bid / ask prices.
    """

    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None:
        raise RuntimeError(f"Symbol info not found: {SYMBOL}")

    point = symbol_info.point

    all_parts = []
    cur_from = date_from_utc

    while cur_from < date_to_utc:
        cur_to = min(cur_from + timedelta(days=chunk_days), date_to_utc)

        rates = mt5.copy_rates_range(SYMBOL, TIMEFRAME, cur_from, cur_to)
        if rates is None:
            raise RuntimeError(f"copy_rates_range returned None: {mt5.last_error()}")

        if len(rates) > 0:
            part = pd.DataFrame(rates)

            # Convert MT5 time (UTC seconds) → UTC datetime
            part["time"] = pd.to_datetime(part["time"], unit="s", utc=True)

            # -----------------------------
            # BID / ASK reconstruction
            # -----------------------------
            part["bid"] = part["close"]
            part["ask"] = part["close"] + part["spread"] * point

            all_parts.append(part)
            print(f"{SYMBOL} {cur_from.date()} → {cur_to.date()} : {len(part):,} bars")
        else:
            print(f"{SYMBOL} {cur_from.date()} → {cur_to.date()} : 0 bars")

        cur_from = cur_to

    if not all_parts:
        return pd.DataFrame()

    df = pd.concat(all_parts, ignore_index=True)

    # De-duplicate overlapping chunks
    df = (
        df.drop_duplicates(subset=["time"])
          .sort_values("time")
          .reset_index(drop=True)
    )

    return df


def main():
    connect_mt5()
    try:
        df = fetch_m1_history_chunked(DATE_FROM, DATE_TO)

        if df.empty:
            print("No data returned.")
            return

        df.to_csv(OUT_CSV, index=False)

        print(f"\nSaved: {OUT_CSV}")
        print(df[["time", "bid", "ask", "spread"]].head(3))
        print(df[["time", "bid", "ask", "spread"]].tail(3))

    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
