# MT5 Market Structure EAs

This project contains two related M5 trend-alignment Expert Advisors:

- `mt5/experts/market_structure.mq5` — live-chart EA.
- `mt5/experts/backtester_market_structure.mq5` — MT5 Strategy Tester EA with optional visual trading buttons.

The live EA requires regime `2` from its M1 text signal. The backtester does not read an external signal file.

## Timeframes

The live EA remains fixed to completed M5 candles. The backtester uses two selectable filters: `InpLowTimeframe` (`M5` by default) and `InpHighTimeframe` (`H1` by default). Both timeframes must independently pass the same directional price/EMA/ATR rules. Entry timing, structural swing stop, take-profit ATR, and ATR-side latch use the low timeframe.

All active signal calculations use completed M5 candles. M1 and H1 candles are not used.

## Entry direction signal

Direction is evaluated from the latest completed M5 candle. Higher-high, lower-low, range-high, and range-low breakouts are not required.

- Buy direction: `M5 close > EMA(21) > EMA(50) > EMA(100)` and the close is above the M5 ATR trailing line.
- Sell direction: `M5 close < EMA(21) < EMA(50) < EMA(100)` and the close is below the M5 ATR trailing line.

## Automated order-entry rules

An automated order is considered once per newly completed M5 candle. Every applicable rule must pass.

### Automated buy

1. `M5 close > EMA(21) > EMA(50) > EMA(100)` on the completed candle.
2. `InpTradeDirectionMode` permits buys.
3. The completed M5 close is above the M5 ATR trailing line.
4. ADX is at least `InpMinimumTrendAdx` (`20` by default) when `InpUseAdxFilter` is enabled.
5. Broker/server time is at or after `InpTradeStartHour` and before `InpTradeEndHour` (01:00–22:00 by default).
6. Existing-position and additional-entry rules permit a new order.

### Automated sell

1. `M5 close < EMA(21) < EMA(50) < EMA(100)` on the completed candle.
2. `InpTradeDirectionMode` permits sells.
3. The completed M5 close is below the M5 ATR trailing line.
4. The same ADX, time, and position rules pass.

Equality with an ATR line does not pass the directional filter.

## Direction selector

`InpTradeDirectionMode` has three choices:

- `TRADE_BOTH_DIRECTIONS`
- `TRADE_BUY_ONLY`
- `TRADE_SELL_ONLY`

The selector applies to automated entries in both EAs and manual BUY/SELL buttons in the tester EA. It does not prevent position-closing operations.

## Existing positions and additional entries

`InpAllowSameDirectionEntries` is disabled by default. In that mode, any existing position on the chart symbol blocks a new automated entry, including manual positions and positions belonging to another EA.

When same-direction entries are enabled:

- Existing positions must use this EA's magic number and match the requested direction.
- A foreign-magic, manual, or opposite position blocks the addition.
- The number of entries is limited by `InpMaximumSameDirectionEntries` (`5` by default).
- Every addition still requires continued EMA-stack/M5-ATR alignment and all entry filters.
- The prospective entry must be at least `InpMinimumEntryGapAtr × M5 ATR` from the latest managed entry (`2 × ATR` by default).

## Market-order settings

- Volume: `InpLots` (`0.01` by default).
- Buy orders execute at market Ask.
- Sell orders execute at market Bid.
- Buy stop loss is fixed at the most recent confirmed M5 lower low; sell stop loss is fixed at the most recent confirmed M5 higher high.
- Take profit is placed `InpTakeProfitAtrMultiplier × M5 ATR` from entry (`5 × ATR` by default).
- Maximum deviation is `InpDeviationPoints` (`20` points by default).
- Automated orders use `InpMagicNumber`.

The EAs do not place `BUY_STOP`, `SELL_STOP`, or stop-limit protection orders.

## Closing rules

There are only two automatic closing mechanisms:

- Broker-side take profit at `5 × M5 ATR` from entry.
- Fixed structural stop loss at the confirmed M5 lower low for buys or higher high for sells.

Break-even, profitable-age, ATR-crossover market close, H1 close, trend-line close, EMA crossover close, opposite-breakout close, reversal, regime exit, and daily close-all rules are disabled.

## Pending-order cleanup

Although the EAs no longer place pending stop orders, they retain the requested cleanup behavior:

- When no position remains open on the chart symbol, all `BUY_STOP`, `SELL_STOP`, `BUY_STOP_LIMIT`, and `SELL_STOP_LIMIT` orders on that symbol are deleted.
- This flat-symbol cleanup includes manual pending stops and pending stops belonging to other EAs.
- `BUY_LIMIT` and `SELL_LIMIT` orders are not deleted.
- Historical protection orders created by an earlier version of this EA are removed when the EA is detached.

## Live EA behavior

`market_structure.mq5` runs on a normal chart and recalculates the strategy after each completed M5 candle. It requires `latest_regime_{base-symbol}_M1.txt` in the terminal MQL5 Files directory and permits entries only when that file reports `regime=2`.

It also writes its market-structure direction to:

```text
MQL5/Files/live_signal_<base-symbol>.csv
```

This output is informational and is not read back as an entry condition.

## Strategy Tester EA

`backtester_market_structure.mq5` refuses to initialize outside MT5 Strategy Tester and does not read an external signal file. `InpLowTimeframe` and `InpHighTimeframe` can be changed to two different valid MT5 timeframes.

For a buy, both completed timeframe closes must independently satisfy `close > EMA(21) > EMA(50) > EMA(100)` and be above their respective ATR trailing lines. For a sell, both must satisfy `close < EMA(21) < EMA(50) < EMA(100)` and be below their respective ATR lines. The buy stop is the most recent confirmed lower-timeframe lower low; the sell stop is the most recent confirmed lower-timeframe higher high. The structural stop is not trailed.

The tester permits only one entry per M5 ATR side. After opening a buy above the ATR line, another buy is blocked until a completed M5 close moves below the ATR line. After opening a sell below the ATR line, another sell is blocked until a completed M5 close moves above it. This latch also applies to visual tester BUY/SELL buttons.

When Visual Mode and `InpShowPanel` are enabled, four chart buttons are available:

- `BUY`
- `SELL`
- `CLOSE BUY`
- `CLOSE SELL`

### Manual BUY/SELL buttons

Manual button entries use `InpLots`, `InpMagicNumber`, the confirmed structural swing as stop loss, and the `5 × ATR` take profit. They bypass ADX, trading-hours, and automated position-count rules.

They still require:

- The selected direction to be allowed by `InpTradeDirectionMode`.
- For manual BUY: `EMA(21) > EMA(50) > EMA(100)` and the latest completed M5 close is above the M5 ATR line.
- For manual SELL: `EMA(21) < EMA(50) < EMA(100)` and the latest completed M5 close is below the M5 ATR line.

The eligibility comparison uses the completed M5 close; the accepted order still executes at the current market Ask or Bid.

If Visual Tester does not deliver a chart-click event, the EA also polls button state on each simulated tick. A button clicked while testing is paused executes on the first tick after the test resumes.

### Manual close buttons

- `CLOSE BUY` closes every buy position on the tested symbol.
- `CLOSE SELL` closes every sell position on the tested symbol.

These controls ignore magic number and position origin.

## Chart panel

The panel reports:

- Chart symbol and M5 timeframe.
- Current EMA-stack/M5-ATR direction and reason.
- Range high, range low, width, ATR, and breakout buffer.
- ADX and trading-hours status.
- Completed M5 close versus the M5 ATR line.
- Position and automated-order readiness.
- Latest completed M5 candle.

M1 regime information is no longer read or displayed.

## Inputs currently not active in order placement

Some legacy inputs remain declared but do not currently alter automated entry decisions:

- `InpUseEma21` and `InpUseEma50` — the switches are inactive because EMA(21), EMA(50), and EMA(100) alignment is mandatory.
- `InpFastEmaPeriod` and `InpSlowEmaPeriod` — indicator handles currently use fixed periods 21 and 50.
- `InpRequireConsolidation`, `InpMaximumRangeAtr`, and `InpMaximumPreBreakoutAdx`.
- `InpSidewaysAdx`.
