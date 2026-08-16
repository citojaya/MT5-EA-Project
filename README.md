# MT5 Market Structure EAs

This project contains two related M5 trend-alignment Expert Advisors:

- `mt5/experts/market_structure.mq5` — live-chart EA.
- `mt5/experts/backtester_market_structure.mq5` — MT5 Strategy Tester EA with optional visual trading buttons.

Both EAs use the same automated trading logic. They do not read M1 regime text or CSV files.

## Timeframes

Automated entries are based on completed M5 candles. `InpSignalTimeframe` must be `PERIOD_M5`; initialization fails if another value is selected.

The strategy also calculates an ATR trailing line from completed H1 data. The H1 line is used as an additional entry filter and as a real-time directional exit.

## M5 direction signal

Direction is evaluated from the latest completed M5 candle. Higher-high, lower-low, range-high, and range-low breakouts are not required.

- Buy direction: M5 close is above both the M5 ATR trailing line and M5 EMA(21).
- Sell direction: M5 close is below both the M5 ATR trailing line and M5 EMA(21).
- If the two indicators do not agree, there is no directional signal.

## Automated order-entry rules

An automated order is considered once per newly completed M5 candle. Every applicable rule must pass.

### Automated buy

1. M5 ATR and EMA(21) select buy direction.
2. `InpTradeDirectionMode` permits buys.
3. The completed M5 close is above the M5 ATR trailing line.
4. The completed M5 close is above the H1 ATR trailing line.
5. The completed M5 close is above EMA(21) calculated on M5.
6. ADX is at least `InpMinimumTrendAdx` (`20` by default) when `InpUseAdxFilter` is enabled.
7. Broker/server time is at or after `InpTradeStartHour` and before `InpTradeEndHour` (01:00–22:00 by default).
8. Existing-position and additional-entry rules permit a new order.

### Automated sell

1. M5 ATR and EMA(21) select sell direction.
2. `InpTradeDirectionMode` permits sells.
3. The completed M5 close is below the M5 ATR trailing line.
4. The completed M5 close is below the H1 ATR trailing line.
5. The completed M5 close is below EMA(21) calculated on M5.
6. The same ADX, time, and position rules pass.

Equality with an EMA or ATR line does not pass the directional filter.

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
- Every addition still requires continued M5 ATR/EMA alignment and all entry filters.
- The prospective entry must be at least `InpMinimumEntryGapAtr × M5 ATR` from the latest managed entry (`2 × ATR` by default).

## Market-order settings

- Volume: `InpLots` (`0.01` by default).
- Buy orders execute at market Ask.
- Sell orders execute at market Bid.
- No broker-side stop loss is attached.
- Take profit is placed `InpTakeProfitAtrMultiplier × M5 ATR` from entry (`60 × ATR` by default).
- Maximum deviation is `InpDeviationPoints` (`20` points by default).
- Automated orders use `InpMagicNumber`.

The EAs do not place `BUY_STOP`, `SELL_STOP`, or stop-limit protection orders.

## Closing rules

### H1 ATR directional exit

This rule is evaluated continuously using current Bid and the latest calculated H1 ATR line:

- `Bid > H1 ATR line` — close every sell position on the chart symbol.
- `Bid < H1 ATR line` — close every buy position on the chart symbol.
- `Bid == H1 ATR line` — take no action.

This exit applies regardless of magic number or origin. It can therefore close manual positions and positions opened by other EAs on the same symbol.

### Take profit

Each automated entry has a broker-side take profit at `InpTakeProfitAtrMultiplier × M5 ATR` from its entry price.

### Profitable-age exit

After `InpProfitableExitBars` completed M5 candles (`240` by default), a position is closed only when its current profit is positive. This rule applies only to positions matching the chart symbol and `InpMagicNumber`.

### Rules that are not active

- No trend-line exit or trend-line plotting.
- No EMA crossover exit.
- No M1 regime exit.
- No opposite-breakout close or automatic reversal.
- No daily close-all rule in these two current EAs.

## Pending-order cleanup

Although the EAs no longer place pending stop orders, they retain the requested cleanup behavior:

- When no position remains open on the chart symbol, all `BUY_STOP`, `SELL_STOP`, `BUY_STOP_LIMIT`, and `SELL_STOP_LIMIT` orders on that symbol are deleted.
- This flat-symbol cleanup includes manual pending stops and pending stops belonging to other EAs.
- `BUY_LIMIT` and `SELL_LIMIT` orders are not deleted.
- Historical protection orders created by an earlier version of this EA are removed when the EA is detached.

## Live EA behavior

`market_structure.mq5` runs on a normal chart. It recalculates the M5 strategy after each completed M5 candle and evaluates position exits during ticks and its timer cycle.

It also writes its market-structure direction to:

```text
MQL5/Files/live_signal_<base-symbol>.csv
```

This output is informational and is not read back as an entry condition.

## Strategy Tester EA

`backtester_market_structure.mq5` refuses to initialize outside MT5 Strategy Tester. It does not require external signal files.

When Visual Mode and `InpShowPanel` are enabled, four chart buttons are available:

- `BUY`
- `SELL`
- `CLOSE BUY`
- `CLOSE SELL`

### Manual BUY/SELL buttons

Manual button entries use `InpLots`, `InpMagicNumber`, and the normal ATR-based take profit when indicator data is available. They bypass the automated range-breakout, ADX, trading-hours, M5 ATR-line, and automated position-count rules.

They still require:

- The selected direction to be allowed by `InpTradeDirectionMode`.
- Manual BUY Ask to be above the latest completed M5 EMA(21).
- Manual SELL Bid to be below the latest completed M5 EMA(21).
- Manual BUY Ask to be above the H1 ATR line.
- Manual SELL Bid to be below the H1 ATR line.

If Visual Tester does not deliver a chart-click event, the EA also polls button state on each simulated tick. A button clicked while testing is paused executes on the first tick after the test resumes.

### Manual close buttons

- `CLOSE BUY` closes every buy position on the tested symbol.
- `CLOSE SELL` closes every sell position on the tested symbol.

These controls ignore magic number and position origin.

## Chart panel

The panel reports:

- Chart symbol and M5 timeframe.
- Current M5 ATR/EMA direction and reason.
- Range high, range low, width, ATR, and breakout buffer.
- ADX and trading-hours status.
- M5 price versus the M5 ATR line.
- Position and automated-order readiness.
- Latest completed M5 candle.

M1 regime information is no longer read or displayed.

## Inputs currently not active in order placement

Some legacy inputs remain declared but do not currently alter automated entry decisions:

- `InpUseEma21` and `InpUseEma50` — EMA(21) is mandatory regardless of these switches; EMA(50) is not an active entry filter.
- `InpFastEmaPeriod` and `InpSlowEmaPeriod` — indicator handles currently use fixed periods 21 and 50.
- `InpRequireConsolidation`, `InpMaximumRangeAtr`, and `InpMaximumPreBreakoutAdx`.
- `InpSidewaysAdx`.
