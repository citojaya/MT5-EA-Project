"""Examine the regime-confirmed breakout strategy described in the project PDF.

The supplied signal export contains close prices rather than OHLC prices.  When high,
low, and open are absent this program uses prior closes for breakout levels and the
mean absolute close change as an ATR proxy.  Such results are pattern diagnostics and
an end-of-bar approximation, not an execution-quality backtest.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


DEFAULT_INPUT = Path(
    "data/backtest/ICMarketsAU-Demo/XAUUSD/M5/XAUUSD_M5_backtest_signals.csv"
)
DEFAULT_OUTPUT = Path("reports/regime_change_strategy")


@dataclass
class Position:
    side: int
    entry_i: int
    entry_time: pd.Timestamp
    entry: float
    initial_stop: float
    stop: float
    target: float
    risk: float
    breakeven: bool = False


def load_data(path: Path) -> tuple[pd.DataFrame, bool]:
    df = pd.read_csv(path)
    required = {"time", "close", "regime"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    raw_rows = len(df)
    df["time"] = pd.to_datetime(df["time"], utc=True, errors="raise")
    df = df.sort_values("time").drop_duplicates("time", keep="last").reset_index(drop=True)
    for col in ("close", "regime"):
        df[col] = pd.to_numeric(df[col], errors="raise")
    if len(df) < 27:
        raise ValueError("At least 27 rows are required for 12-bar signals and ATR(14).")
    df.attrs["raw_rows"] = raw_rows
    return df, {"open", "high", "low", "close"}.issubset(df.columns)


def add_signals(df: pd.DataFrame, has_ohlc: bool) -> pd.DataFrame:
    out = df.copy()
    regimes = out["regime"]
    previous = regimes.shift(1)

    # Every rolling count and breakout level excludes the entry candle.
    out["bullish_history"] = previous.isin([0, 1]).rolling(12).sum()
    out["bearish_history"] = previous.isin([2, 5]).rolling(12).sum()
    out["no_trade_history"] = previous.isin([4, 6, 7]).rolling(12).sum()

    high_source = out["high"] if has_ohlc else out["close"]
    low_source = out["low"] if has_ohlc else out["close"]
    out["breakout_high"] = high_source.shift(1).rolling(12).max()
    out["breakout_low"] = low_source.shift(1).rolling(12).min()

    if has_ohlc:
        previous_close = out["close"].shift(1)
        true_range = pd.concat(
            [
                out["high"] - out["low"],
                (out["high"] - previous_close).abs(),
                (out["low"] - previous_close).abs(),
            ],
            axis=1,
        ).max(axis=1)
    else:
        true_range = out["close"].diff().abs()
    out["atr14"] = true_range.rolling(14).mean().shift(1)

    allowed = out["no_trade_history"] < 8
    out["buy_signal"] = (
        regimes.eq(0)
        & (out["bullish_history"] >= 8)
        & (out["close"] > out["breakout_high"])
        & ~previous.eq(5)
        & allowed
        & out["atr14"].gt(0)
    )
    out["sell_signal"] = (
        regimes.eq(2)
        & (out["bearish_history"] >= 8)
        & (out["close"] < out["breakout_low"])
        & allowed
        & out["atr14"].gt(0)
    )
    return out


def backtest(df: pd.DataFrame, has_ohlc: bool) -> pd.DataFrame:
    trades: list[dict] = []
    position: Position | None = None

    for i, row in df.iterrows():
        price = float(row["close"])
        if position is not None and i > position.entry_i:
            adverse = float(row["low"] if has_ohlc else price)
            favourable = float(row["high"] if has_ohlc else price)
            if position.side < 0:
                adverse, favourable = favourable, adverse

            exit_price: float | None = None
            reason = ""
            # Conservative same-bar ordering: stop is checked before target.
            if (position.side > 0 and adverse <= position.stop) or (
                position.side < 0 and adverse >= position.stop
            ):
                exit_price, reason = position.stop, "stop"
            elif (position.side > 0 and favourable >= position.target) or (
                position.side < 0 and favourable <= position.target
            ):
                exit_price, reason = position.target, "target"
            elif (position.side > 0 and row["regime"] in (2, 3, 4, 7)) or (
                position.side < 0 and row["regime"] in (0, 1, 4, 7)
            ):
                exit_price, reason = price, "regime_exit"

            if exit_price is not None:
                pnl = position.side * (exit_price - position.entry)
                trades.append(
                    {
                        "side": "buy" if position.side > 0 else "sell",
                        "entry_time": position.entry_time,
                        "exit_time": row["time"],
                        "entry": position.entry,
                        "exit": exit_price,
                        "initial_stop": position.initial_stop,
                        "target": position.target,
                        "bars_held": i - position.entry_i,
                        "exit_reason": reason,
                        "pnl_points": pnl,
                        "r_multiple": pnl / position.risk,
                    }
                )
                position = None
            elif not position.breakeven and (
                (position.side > 0 and favourable >= position.entry + position.risk)
                or (position.side < 0 and favourable <= position.entry - position.risk)
            ):
                position.stop = position.entry
                position.breakeven = True

        if position is None and (bool(row["buy_signal"]) or bool(row["sell_signal"])):
            side = 1 if row["buy_signal"] else -1
            risk = 1.5 * float(row["atr14"])
            position = Position(
                side=side,
                entry_i=i,
                entry_time=row["time"],
                entry=price,
                initial_stop=price - side * risk,
                stop=price - side * risk,
                target=price + side * 2 * risk,
                risk=risk,
            )

    if position is not None:
        row = df.iloc[-1]
        pnl = position.side * (float(row["close"]) - position.entry)
        trades.append(
            {
                "side": "buy" if position.side > 0 else "sell",
                "entry_time": position.entry_time,
                "exit_time": row["time"],
                "entry": position.entry,
                "exit": float(row["close"]),
                "initial_stop": position.initial_stop,
                "target": position.target,
                "bars_held": len(df) - 1 - position.entry_i,
                "exit_reason": "end_of_data",
                "pnl_points": pnl,
                "r_multiple": pnl / position.risk,
            }
        )
    return pd.DataFrame(trades)


def metrics(trades: pd.DataFrame) -> dict:
    if trades.empty:
        return {"trades": 0, "win_rate": None, "profit_factor": None, "expectancy_r": None,
                "total_r": 0.0, "max_drawdown_r": 0.0}
    r = trades["r_multiple"]
    gross_profit = r[r > 0].sum()
    gross_loss = -r[r < 0].sum()
    equity = r.cumsum()
    drawdown = equity - equity.cummax().clip(lower=0)
    return {
        "trades": int(len(trades)),
        "wins": int((r > 0).sum()),
        "losses": int((r < 0).sum()),
        "breakeven": int((r == 0).sum()),
        "win_rate": float((r > 0).mean()),
        "profit_factor": float(gross_profit / gross_loss) if gross_loss else None,
        "expectancy_r": float(r.mean()),
        "total_r": float(r.sum()),
        "max_drawdown_r": float(drawdown.min()),
        "average_bars_held": float(trades["bars_held"].mean()),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    df, has_ohlc = load_data(args.input)
    examined = add_signals(df, has_ohlc)
    trades = backtest(examined, has_ohlc)
    summary = {
        "input": str(args.input),
        "raw_rows": int(df.attrs["raw_rows"]),
        "rows_examined": int(len(df)),
        "start": df["time"].min().isoformat(),
        "end": df["time"].max().isoformat(),
        "price_mode": "OHLC" if has_ohlc else "close-only proxy",
        "limitations": [] if has_ohlc else [
            "Breakouts use the previous 12 closes because high/low columns are absent.",
            "ATR uses mean absolute close changes because high/low columns are absent.",
            "Stops, targets, and breakeven are evaluated at candle closes only.",
            "Spread, commission, slippage, and position sizing cannot be evaluated.",
        ],
        "raw_buy_signals": int(examined["buy_signal"].sum()),
        "raw_sell_signals": int(examined["sell_signal"].sum()),
        "all_trades": metrics(trades),
        "buy_trades": metrics(trades[trades["side"] == "buy"] if not trades.empty else trades),
        "sell_trades": metrics(trades[trades["side"] == "sell"] if not trades.empty else trades),
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    signal_columns = [
        "time", "close", "regime", "regime_name", "confidence", "bullish_history",
        "bearish_history", "no_trade_history", "breakout_high", "breakout_low", "atr14",
        "buy_signal", "sell_signal",
    ]
    examined.loc[examined["buy_signal"] | examined["sell_signal"], signal_columns].to_csv(
        args.output_dir / "signals.csv", index=False
    )
    trades.to_csv(args.output_dir / "trades.csv", index=False)
    with (args.output_dir / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, allow_nan=False)
    print(json.dumps(summary, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
