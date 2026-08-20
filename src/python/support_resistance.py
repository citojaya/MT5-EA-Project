"""Backtest the MT5 support_resistance.mq5 strategy on bid/ask M5 CSV data.

Signals are evaluated on completed M5 candles and executed at the following
M5 open. Daily S1, Pivot, and R1 use the previous completed UTC daily candle.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import pandas as pd


DEFAULT_INPUT = Path(
    "data/raw/ICMarketsAU-Demo/XAUUSD_bidask_M5_20260101_20261231.csv"
)
DEFAULT_OUTPUT_DIR = Path("reports/support_resistance")


@dataclass
class Position:
    entry_time: pd.Timestamp
    entry_price: float
    volume: float
    atr_at_entry: float
    support: float
    pivot: float
    resistance: float


def parse_date(value: str) -> pd.Timestamp:
    try:
        timestamp = pd.Timestamp(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Invalid date: {value}") from exc
    if timestamp.tzinfo is None:
        timestamp = timestamp.tz_localize("UTC")
    else:
        timestamp = timestamp.tz_convert("UTC")
    return timestamp.normalize()


def load_m5(path: Path) -> pd.DataFrame:
    required = {"time", "open", "high", "low", "close", "bid", "ask"}
    frame = pd.read_csv(path, usecols=lambda column: column in required)
    missing = required.difference(frame.columns)
    if missing:
        raise ValueError(f"Missing required CSV columns: {sorted(missing)}")

    frame["time"] = pd.to_datetime(frame["time"], utc=True, errors="raise")
    numeric = sorted(required.difference({"time"}))
    frame[numeric] = frame[numeric].apply(pd.to_numeric, errors="raise")
    frame = (
        frame.sort_values("time")
        .drop_duplicates("time", keep="last")
        .set_index("time")
    )
    if frame.empty:
        raise ValueError("The input CSV contains no price rows.")
    return frame


def prepare_prices(raw_m5: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    m5 = pd.DataFrame(index=raw_m5.index)
    m5["bid_open"] = raw_m5["open"]
    m5["bid_high"] = raw_m5["high"]
    m5["bid_low"] = raw_m5["low"]
    m5["bid_close"] = raw_m5["close"]
    # The export's bid/ask fields are closing quotes. Apply that observed
    # spread to the candle open to approximate the next-bar market ask.
    m5["ask_open"] = raw_m5["open"] + (raw_m5["ask"] - raw_m5["bid"])
    m5 = m5.dropna()

    daily = raw_m5.resample("1D", label="left", closed="left").agg(
        high=("high", "max"), low=("low", "min"), close=("close", "last")
    )
    daily = daily.dropna()
    daily["pivot"] = (daily["high"] + daily["low"] + daily["close"]) / 3.0
    daily["support"] = 2.0 * daily["pivot"] - daily["high"]
    daily["resistance"] = 2.0 * daily["pivot"] - daily["low"]
    # Today's M5 candles use yesterday's completed daily levels.
    levels = daily[["support", "pivot", "resistance"]].shift(1)
    return m5, levels


def add_indicators(m5: pd.DataFrame, daily_levels: pd.DataFrame, atr_period: int,
                   atr_multiplier: float) -> pd.DataFrame:
    out = m5.copy()
    previous_close = out["bid_close"].shift(1)
    true_range = pd.concat(
        [
            out["bid_high"] - out["bid_low"],
            (out["bid_high"] - previous_close).abs(),
            (out["bid_low"] - previous_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    # MetaTrader iATR uses Wilder smoothing.
    out["atr"] = true_range.ewm(
        alpha=1.0 / atr_period, adjust=False, min_periods=atr_period
    ).mean()

    atr_line = np.full(len(out), np.nan, dtype=float)
    closes = out["bid_close"].to_numpy(dtype=float)
    atr = out["atr"].to_numpy(dtype=float)
    previous_stop = np.nan
    for index in range(len(out)):
        if not np.isfinite(atr[index]) or atr[index] <= 0:
            continue
        loss = atr_multiplier * atr[index]
        if not np.isfinite(previous_stop):
            stop = closes[index] - loss
        elif closes[index] > previous_stop and closes[index - 1] > previous_stop:
            stop = max(previous_stop, closes[index] - loss)
        elif closes[index] < previous_stop and closes[index - 1] < previous_stop:
            stop = min(previous_stop, closes[index] + loss)
        else:
            stop = closes[index] - loss if closes[index] > previous_stop else closes[index] + loss
        atr_line[index] = stop
        previous_stop = stop
    out["atr_line"] = atr_line

    day_index = out.index.normalize()
    for column in ("support", "pivot", "resistance"):
        out[column] = daily_levels[column].reindex(day_index).to_numpy()
    return out


def close_all_buys(
    positions: list[Position], exit_time: pd.Timestamp, exit_price: float,
    reason: str, trades: list[dict],
) -> None:
    for position in positions:
        pnl_points = exit_price - position.entry_price
        trades.append(
            {
                **asdict(position),
                "exit_time": exit_time,
                "exit_price": exit_price,
                "exit_reason": reason,
                "pnl_points": pnl_points,
                "pnl_value": pnl_points * position.volume,
            }
        )
    positions.clear()


def backtest(
    bars: pd.DataFrame,
    start_date: pd.Timestamp,
    end_date: pd.Timestamp,
    proximity_atr: float,
    minimum_gap_atr: float,
    volume: float,
) -> tuple[pd.DataFrame, dict]:
    end_exclusive = end_date + pd.Timedelta(days=1)
    positions: list[Position] = []
    trades: list[dict] = []
    trade_possible = False
    armed_count = 0
    blocked_by_gap = 0
    entries = 0

    # Row i is the completed signal candle; orders execute at row i+1 open.
    for index in range(len(bars) - 1):
        row = bars.iloc[index]
        next_row = bars.iloc[index + 1]
        signal_time = bars.index[index]
        execution_time = bars.index[index + 1]
        if signal_time < start_date or signal_time >= end_exclusive:
            continue
        if execution_time >= end_exclusive:
            break
        required = (row["atr"], row["atr_line"], row["support"], row["pivot"], row["resistance"])
        if not all(np.isfinite(value) for value in required):
            continue

        # The EA checks resistance first and exits at the next available bid.
        if float(row["bid_high"]) >= float(row["resistance"]):
            if positions:
                close_all_buys(
                    positions, execution_time, float(next_row["bid_open"]),
                    "R1_resistance", trades,
                )
            trade_possible = False
            continue

        proximity = proximity_atr * float(row["atr"])
        support_touched = (
            float(row["bid_low"]) <= float(row["support"]) + proximity
            and float(row["bid_high"]) >= float(row["support"]) - proximity
        )
        was_trade_possible = trade_possible
        if not trade_possible and support_touched:
            trade_possible = True
            armed_count += 1

        if was_trade_possible and float(row["bid_close"]) > float(row["atr_line"]):
            entry_price = float(next_row["ask_open"])
            last_entry = positions[-1].entry_price if positions else None
            minimum_gap = minimum_gap_atr * float(row["atr"])
            if last_entry is not None and abs(entry_price - last_entry) < minimum_gap:
                blocked_by_gap += 1
                continue

            positions.append(
                Position(
                    entry_time=execution_time,
                    entry_price=entry_price,
                    volume=volume,
                    atr_at_entry=float(row["atr"]),
                    support=float(row["support"]),
                    pivot=float(row["pivot"]),
                    resistance=float(row["resistance"]),
                )
            )
            entries += 1
            trade_possible = False

    if positions:
        final_rows = bars[(bars.index >= start_date) & (bars.index < end_exclusive)]
        if not final_rows.empty:
            close_all_buys(
                positions, final_rows.index[-1], float(final_rows.iloc[-1]["bid_close"]),
                "end_of_test", trades,
            )

    trade_frame = pd.DataFrame(trades)
    total_pnl = float(trade_frame["pnl_points"].sum()) if not trade_frame.empty else 0.0
    wins = int((trade_frame["pnl_points"] > 0).sum()) if not trade_frame.empty else 0
    summary = {
        "start_date": start_date.date().isoformat(),
        "end_date": end_date.date().isoformat(),
        "entries": entries,
        "closed_trades": int(len(trade_frame)),
        "wins": wins,
        "losses": int((trade_frame["pnl_points"] < 0).sum()) if not trade_frame.empty else 0,
        "win_rate": wins / len(trade_frame) if len(trade_frame) else None,
        "total_pnl_points": total_pnl,
        "trade_possible_activations": armed_count,
        "signals_blocked_by_6_atr_gap": blocked_by_gap,
    }
    return trade_frame, summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start-date", required=True, type=parse_date)
    parser.add_argument("--end-date", required=True, type=parse_date)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--atr-period", type=int, default=14)
    parser.add_argument("--atr-multiplier", type=float, default=3.0)
    parser.add_argument("--support-proximity-atr", type=float, default=0.2)
    parser.add_argument("--minimum-buy-gap-atr", type=float, default=6.0)
    parser.add_argument("--volume", type=float, default=0.01)
    args = parser.parse_args()

    if args.end_date < args.start_date:
        parser.error("--end-date must be on or after --start-date")
    if args.atr_period < 1 or args.atr_multiplier <= 0 or args.volume <= 0:
        parser.error("ATR period, ATR multiplier, and volume must be positive")
    if args.support_proximity_atr < 0 or args.minimum_buy_gap_atr < 0:
        parser.error("ATR proximity and order gap cannot be negative")
    if not args.input.exists():
        parser.error(f"Input file does not exist: {args.input}")

    m5, daily_levels = prepare_prices(load_m5(args.input))
    bars = add_indicators(m5, daily_levels, args.atr_period, args.atr_multiplier)
    trades, summary = backtest(
        bars,
        args.start_date,
        args.end_date,
        args.support_proximity_atr,
        args.minimum_buy_gap_atr,
        args.volume,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    trades_path = args.output_dir / "trades.csv"
    summary_path = args.output_dir / "summary.json"
    trades.to_csv(trades_path, index=False)
    summary.update(
        {
            "input": str(args.input),
            "atr_period": args.atr_period,
            "atr_multiplier": args.atr_multiplier,
            "support_proximity_atr": args.support_proximity_atr,
            "minimum_buy_gap_atr": args.minimum_buy_gap_atr,
            "volume": args.volume,
        }
    )
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    print(f"Trades: {trades_path}")
    print(f"Summary: {summary_path}")


if __name__ == "__main__":
    main()
