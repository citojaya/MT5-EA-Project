# Volumized Order Block — TradingView

`volumized_order_block.pine` is the TradingView Pine Script v6 conversion of the volume-profile signal logic currently used by `mt5/experts/volumized_order_block.mq5`.

## Signal calculation

The indicator builds volume-at-price bins from the selected source over `History Bars`. Around the current-price bin it displays `Rows` bins above and below.

```text
trade ratio = (GREEN BELOW - RED ABOVE) / GREEN BELOW
```

- BUY: trade ratio is greater than `0.45`.
- SELL: trade ratio is less than or equal to `-1.00`.
- No signal when `GREEN BELOW` is zero.

The thresholds are configurable in the TradingView settings.

## Installation

1. Open TradingView's Pine Editor.
2. Copy the contents of `volumized_order_block.pine` into a new indicator.
3. Save it and select **Add to chart**.
4. Create alerts using **Volumized Orderbook BUY** or **Volumized Orderbook SELL**.

The rolling calculation uses the active TradingView chart timeframe. Set the chart to the same timeframe as `InpTimeframe` in MT5 when comparing outputs. Results can still differ because broker and TradingView volume feeds are not necessarily identical.

This derivative retains Zeiierman's CC BY-NC-SA 4.0 attribution and licensing.
