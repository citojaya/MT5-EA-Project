//+------------------------------------------------------------------+
//|                                  volumized_order_block.mq5       |
//| MT5 conversion of "Volume Orderbook (Zeiierman)"                |
//| Original work (c) Zeiierman                                     |
//| CC BY-NC-SA 4.0: https://creativecommons.org/licenses/by-nc-sa/4.0/
//+------------------------------------------------------------------+
#property copyright "Original concept and Pine Script © Zeiierman"
#property link      "https://creativecommons.org/licenses/by-nc-sa/4.0/"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input string             InpSelectedSymbol = "";       // Blank uses chart symbol
input ENUM_TIMEFRAMES    InpTimeframe = PERIOD_CURRENT;
input ENUM_APPLIED_PRICE InpSource = PRICE_CLOSE;
input int                InpRows = 10;                  // Rows above/below price
input double             InpWidthMultiplier = 0.5;      // Price-bin width multiplier
input bool               InpShowPoc = false;            // Extend highest-volume level left
input bool               InpShowTableBorder = false;
input int                InpLeftBars = 5;               // Future offset in bars
input bool               InpShowGrid = false;
input int                InpHistoryBars = 2000;          // Bars used for volume profile
input bool               InpUseRealVolume = false;      // Otherwise use tick volume
input int                InpRefreshSeconds = 1;
input double             InpChartShiftPercent = 45.0;  // Space for profile on right
input color              InpSellColor = clrTomato;
input color              InpBuyColor = clrLimeGreen;
input color              InpCurrentColor = clrGray;
input color              InpGridColor = clrDimGray;
input color              InpTextColor = clrWhite;
input color              InpEma50Color = clrDodgerBlue;
input color              InpEma100Color = clrMagenta;
input ENUM_BASE_CORNER   InpPanelCorner = CORNER_LEFT_UPPER;
input int                InpPanelX = 15;
input int                InpPanelY = 15;
input int                InpPanelFontSize = 11;
input ulong              InpMagicNumber = 26082801;
input int                InpAtrPeriod = 14;
input double             InpTakeProfitAtrMultiplier = 4.0;
input double             InpManualLots = 0.01;

#define PREFIX "VOLUMIZED_ORDERBOOK_"
#define BUTTON_BUY PREFIX "BUTTON_BUY"
#define BUTTON_SELL PREFIX "BUTTON_SELL"
#define BUTTON_CLOSE_SELECTED PREFIX "BUTTON_CLOSE_SELECTED"
#define POSITION_BUTTON_PREFIX PREFIX "POSITION_"

string g_symbol = "";
bool g_previousChartShift = false;
double g_previousChartShiftSize = 20.0;
datetime g_lastCalculationBar = 0;
int g_atrHandle = INVALID_HANDLE;
int g_ema50Handle = INVALID_HANDLE;
int g_ema100Handle = INVALID_HANDLE;
CTrade g_trade;
ulong g_selectedTickets[];
bool g_skipRatioTradeOnce = false;

//+------------------------------------------------------------------+
int SelectedTicketIndex(const ulong ticket)
  {
   for(int index = 0; index < ArraySize(g_selectedTickets); index++)
      if(g_selectedTickets[index] == ticket)
         return index;
   return -1;
  }

//+------------------------------------------------------------------+
void ToggleSelectedTicket(const ulong ticket)
  {
   int selectedIndex = SelectedTicketIndex(ticket);
   if(selectedIndex < 0)
     {
      int size = ArraySize(g_selectedTickets);
      ArrayResize(g_selectedTickets, size + 1);
      g_selectedTickets[size] = ticket;
      return;
     }
   int last = ArraySize(g_selectedTickets) - 1;
   g_selectedTickets[selectedIndex] = g_selectedTickets[last];
   ArrayResize(g_selectedTickets, last);
  }

//+------------------------------------------------------------------+
void DrawEma(const int handle, const string tag, const color lineColor,
             const int width)
  {
   const int requested = 300;
   datetime times[];
   double values[];
   int count = MathMin(CopyTime(g_symbol, InpTimeframe, 0,
                                requested, times),
                       CopyBuffer(handle, 0, 0, requested, values));
   if(count < 2)
      return;
   for(int index = 1; index < count; index++)
     {
      string name = PREFIX + "EMA_" + tag + "_" +
                    IntegerToString(index);
      if(!ObjectCreate(0, name, OBJ_TREND, 0,
                       times[index - 1], values[index - 1],
                       times[index], values[index]))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
void UpdateOnNewTimeframeBar()
  {
   datetime currentBar = iTime(g_symbol, InpTimeframe, 0);
   if(currentBar <= 0 || currentBar == g_lastCalculationBar)
      return;

   g_lastCalculationBar = currentBar;
   DrawVolumeOrderbook();
  }

//+------------------------------------------------------------------+
void TradeVolumeRatio(const double greenBelow, const double redAbove)
  {
   if(g_skipRatioTradeOnce)
     {
      g_skipRatioTradeOnce = false;
      return;
     }
   bool ratioAvailable = greenBelow > 0.0;
   double ratio = ratioAvailable
                  ? (greenBelow - redAbove) / greenBelow : 0.0;
   bool buySignal = ratioAvailable && ratio > 0.45;
   bool sellSignal = ratioAvailable && ratio <= -1.0;

   bool invalidPositionRemains = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool signalGone = (type == POSITION_TYPE_BUY && !buySignal) ||
                        (type == POSITION_TYPE_SELL && !sellSignal);
      if(!signalGone)
         continue;
      if(PositionGetDouble(POSITION_PROFIT) <= 0.0)
        {
         invalidPositionRemains = true;
         continue;
        }
      if(!g_trade.PositionClose(ticket))
        {
         invalidPositionRemains = true;
         Print("Signal exit could not close position #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
        }
     }
   if(!buySignal && !sellSignal)
      return;
   if(invalidPositionRemains)
      return;

   ENUM_POSITION_TYPE desiredType = buySignal
                                    ? POSITION_TYPE_BUY
                                    : POSITION_TYPE_SELL;

   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == g_symbol &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == desiredType)
         return;
     }

   double atrValues[1];
   if(g_atrHandle == INVALID_HANDLE ||
      CopyBuffer(g_atrHandle, 0, 1, 1, atrValues) != 1 ||
      atrValues[0] <= 0.0)
     {
      Print("Unable to calculate ATR for trade entry on ", g_symbol);
      return;
     }

   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double buyTakeProfit = NormalizeDouble(
      ask + InpTakeProfitAtrMultiplier * atrValues[0], digits);
   double sellTakeProfit = NormalizeDouble(
      bid - InpTakeProfitAtrMultiplier * atrValues[0], digits);

   double volume = NormalizeTradeVolume(0.01);
   bool sent = buySignal
               ? g_trade.Buy(volume, g_symbol, 0.0, 0.0,
                             buyTakeProfit, "Volume ratio BUY")
               : g_trade.Sell(volume, g_symbol, 0.0, 0.0,
                              sellTakeProfit, "Volume ratio SELL");

   if(!sent)
      Print("Trade request failed for ", g_symbol, ". Ratio=",
            DoubleToString(ratio, 4), ", retcode=", g_trade.ResultRetcode(),
            " (", g_trade.ResultRetcodeDescription(), ")");
  }

//+------------------------------------------------------------------+
string FormatVolume(const double volume)
  {
   if(volume >= 1000000000.0)
      return DoubleToString(volume / 1000000000.0, 3) + "B";
   if(volume >= 1000000.0)
      return DoubleToString(volume / 1000000.0, 3) + "M";
   if(volume >= 1000.0)
      return DoubleToString(volume / 1000.0, 3) + "K";
   return DoubleToString(volume, 0);
  }

//+------------------------------------------------------------------+
color RankedColor(const color baseColor, const int rank,
                  const int maximumRank)
  {
   double strength = maximumRank > 0
                     ? 0.45 + 0.55 * rank / maximumRank : 1.0;
   uint value = (uint)baseColor;
   uint red = (uint)((value & 0xFF) * strength);
   uint green = (uint)(((value >> 8) & 0xFF) * strength);
   uint blue = (uint)(((value >> 16) & 0xFF) * strength);
   return (color)(red | (green << 8) | (blue << 16));
  }

//+------------------------------------------------------------------+
void SetPanelLabel(const string name, const string text, const int x,
                   const int y, const color textColor, const int fontSize)
  {
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void CreatePanelButton(const string name, const string text, const int x,
                       const int y, const int width, const color background)
  {
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 26);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFontSize);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 110);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
double NormalizeTradeVolume(const double requested)
  {
   double minimum = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return requested;
   double volume = MathMax(minimum, MathMin(maximum, requested));
   return NormalizeDouble(MathFloor(volume / step + 1e-9) * step, 8);
  }

//+------------------------------------------------------------------+
void PlaceManualOrder(const bool buyOrder)
  {
   double atrValues[1];
   if(g_atrHandle == INVALID_HANDLE ||
      CopyBuffer(g_atrHandle, 0, 1, 1, atrValues) != 1 ||
      atrValues[0] <= 0.0)
     {
      Print("Manual order blocked: ATR is unavailable for ", g_symbol);
      return;
     }
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double entry = buyOrder ? ask : bid;
   double takeProfit = NormalizeDouble(
      buyOrder ? entry + InpTakeProfitAtrMultiplier * atrValues[0]
               : entry - InpTakeProfitAtrMultiplier * atrValues[0], digits);
   double volume = NormalizeTradeVolume(InpManualLots);
   bool placed = buyOrder
                 ? g_trade.Buy(volume, g_symbol, 0.0, 0.0, takeProfit,
                               "Manual button BUY")
                 : g_trade.Sell(volume, g_symbol, 0.0, 0.0, takeProfit,
                                "Manual button SELL");
   if(!placed)
      Print("Manual ", buyOrder ? "BUY" : "SELL", " failed: ",
            g_trade.ResultRetcodeDescription());
   else
     {
      g_skipRatioTradeOnce = true;
      DrawVolumeOrderbook();
     }
  }

//+------------------------------------------------------------------+
void CloseSelectedPositions()
  {
   ulong tickets[];
   ArrayCopy(tickets, g_selectedTickets);
   for(int index = 0; index < ArraySize(tickets); index++)
     {
      ulong ticket = tickets[index];
      if(!PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(g_trade.PositionClose(ticket))
         Print("Closed selected position #", ticket);
      else
         Print("Selected close failed for #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
   ArrayResize(g_selectedTickets, 0);
   g_skipRatioTradeOnce = true;
   DrawVolumeOrderbook();
  }

//+------------------------------------------------------------------+
int DrawPositionSelectors(const int y)
  {
   int row = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      bool selected = SelectedTicketIndex(ticket) >= 0;
      string side = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY
                    ? "BUY " : "SELL";
      string name = POSITION_BUTTON_PREFIX + IntegerToString((long)ticket);
      string text = (selected ? "[X] " : "[ ] ") + side + " #" +
                    IntegerToString((long)ticket) + "  " +
                    DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
                    " lots  P/L " +
                    DoubleToString(PositionGetDouble(POSITION_PROFIT), 2);
      CreatePanelButton(name, text, InpPanelX, y + row * 30, 410,
                        selected ? clrDarkGoldenrod : C'48,55,68');
      row++;
     }
   return row;
  }

//+------------------------------------------------------------------+
void DrawVolumeTotalsPanel(const double redTotal, const double greenTotal)
  {
   int symbolPositionCount = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == g_symbol)
         symbolPositionCount++;
     }
   string background = PREFIX + "PANEL_BG";
   if(ObjectCreate(0, background, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, background, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, background, OBJPROP_XDISTANCE, InpPanelX - 8);
      ObjectSetInteger(0, background, OBJPROP_YDISTANCE, InpPanelY - 8);
      ObjectSetInteger(0, background, OBJPROP_XSIZE, 430);
      ObjectSetInteger(0, background, OBJPROP_YSIZE,
                       (InpPanelFontSize + 9) * 7 + 86 +
                       symbolPositionCount * 30);
      ObjectSetInteger(0, background, OBJPROP_BGCOLOR, C'20,24,32');
      ObjectSetInteger(0, background, OBJPROP_BORDER_COLOR, C'75,85,105');
      ObjectSetInteger(0, background, OBJPROP_ZORDER, 100);
      ObjectSetInteger(0, background, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, background, OBJPROP_HIDDEN, true);
     }
   int lineHeight = InpPanelFontSize + 9;
   SetPanelLabel(PREFIX + "PANEL_TITLE", "VOLUME ORDERBOOK TOTALS",
                 InpPanelX, InpPanelY, clrWhite, InpPanelFontSize + 1);
   SetPanelLabel(PREFIX + "PANEL_RED", "RED ABOVE:   " +
                 FormatVolume(redTotal), InpPanelX,
                 InpPanelY + lineHeight, InpSellColor, InpPanelFontSize);
   SetPanelLabel(PREFIX + "PANEL_GREEN", "GREEN BELOW: " +
                 FormatVolume(greenTotal), InpPanelX,
                 InpPanelY + lineHeight * 2, InpBuyColor,
                 InpPanelFontSize);

   bool ratioAvailable = greenTotal > 0.0;
   double ratio = ratioAvailable
                  ? (greenTotal - redTotal) / greenTotal : 0.0;
   bool buyCondition = ratioAvailable && ratio > 0.45;
   bool sellCondition = ratioAvailable && ratio <= -1.0;
   SetPanelLabel(PREFIX + "PANEL_RATIO", "TRADE RATIO:  " +
                 (ratioAvailable ? DoubleToString(ratio, 4) : "N/A"),
                 InpPanelX, InpPanelY + lineHeight * 3,
                 buyCondition ? InpBuyColor
                 : sellCondition ? InpSellColor : InpTextColor,
                 InpPanelFontSize);
   SetPanelLabel(PREFIX + "PANEL_BUY_CONDITION",
                 "BUY:  ratio > 0.45       [" +
                 (buyCondition ? "YES" : "NO") + "]",
                 InpPanelX, InpPanelY + lineHeight * 4,
                 buyCondition ? InpBuyColor : clrSilver,
                 InpPanelFontSize);
   SetPanelLabel(PREFIX + "PANEL_SELL_CONDITION",
                 "SELL: ratio <= -1.00     [" +
                 (sellCondition ? "YES" : "NO") + "]",
                 InpPanelX, InpPanelY + lineHeight * 5,
                 sellCondition ? InpSellColor : clrSilver,
                 InpPanelFontSize);

   string status = "ORDER STATUS: NO OPEN POSITION";
   color statusColor = InpTextColor;
   if(PositionSelect(g_symbol))
     {
      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double lots = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      string side = type == POSITION_TYPE_BUY ? "BUY" : "SELL";
      statusColor = type == POSITION_TYPE_BUY ? InpBuyColor : InpSellColor;
      status = "ORDER STATUS: " + side + " " + DoubleToString(lots, 2) +
               " LOT | P/L " + DoubleToString(profit, 2);
     }
   SetPanelLabel(PREFIX + "PANEL_ORDER_STATUS", status, InpPanelX,
                 InpPanelY + lineHeight * 6, statusColor,
                 InpPanelFontSize);
   int buttonY = InpPanelY + lineHeight * 7 + 4;
   CreatePanelButton(BUTTON_BUY, "BUY", InpPanelX,
                     buttonY, 200, clrDarkGreen);
   CreatePanelButton(BUTTON_SELL, "SELL", InpPanelX + 210,
                     buttonY, 200, clrFireBrick);
   int selectorCount = DrawPositionSelectors(buttonY + 34);
   CreatePanelButton(BUTTON_CLOSE_SELECTED, "CLOSE SELECTED", InpPanelX,
                     buttonY + 34 + selectorCount * 30, 410,
                     clrDarkSlateGray);
  }

//+------------------------------------------------------------------+
double SourceValue(const MqlRates &bar)
  {
   switch(InpSource)
     {
      case PRICE_OPEN:     return bar.open;
      case PRICE_HIGH:     return bar.high;
      case PRICE_LOW:      return bar.low;
      case PRICE_MEDIAN:   return (bar.high + bar.low) * 0.5;
      case PRICE_TYPICAL:  return (bar.high + bar.low + bar.close) / 3.0;
      case PRICE_WEIGHTED: return (bar.high + bar.low + 2.0 * bar.close) / 4.0;
      default:             return bar.close;
     }
  }

//+------------------------------------------------------------------+
double BarVolume(const MqlRates &bar)
  {
   if(InpUseRealVolume && bar.real_volume > 0)
      return (double)bar.real_volume;
   return (double)bar.tick_volume;
  }

//+------------------------------------------------------------------+
int VolumeRank(const double &values[], const int count, const int target)
  {
   int rank = 0;
   for(int index = 0; index < count; index++)
      if(values[index] < values[target])
         rank++;
   return rank;
  }

//+------------------------------------------------------------------+
void ConfigureRectangle(const string name, const color objectColor,
                        const bool fill = true, const int width = 1)
  {
   ObjectSetInteger(0, name, OBJPROP_COLOR, objectColor);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void CreateVolumeText(const string name, const datetime time,
                      const double price, const double volume)
  {
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, time, price))
      return;
   ObjectSetString(0, name, OBJPROP_TEXT, FormatVolume(volume));
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpTextColor);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void DrawVolumeOrderbook()
  {
   MqlRates rates[];
   int copied = CopyRates(g_symbol, InpTimeframe, 0, InpHistoryBars, rates);
   if(copied < 2)
      return;

   double step = (rates[0].high - rates[0].low) * InpWidthMultiplier;
   if(step <= 0.0)
      for(int index = 1; index < copied; index++)
        {
         step = (rates[index].high - rates[index].low) *
                InpWidthMultiplier;
         if(step > 0.0)
            break;
        }
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(step <= 0.0)
      step = point > 0.0 ? point : 0.00001;

   double minimumSource = DBL_MAX;
   double maximumSource = -DBL_MAX;
   for(int index = 0; index < copied; index++)
     {
      double source = SourceValue(rates[index]);
      minimumSource = MathMin(minimumSource, source);
      maximumSource = MathMax(maximumSource, source);
     }

   double initialSource = SourceValue(rates[0]);
   double topLevel = initialSource + step;
   while(maximumSource >= topLevel)
      topLevel += step;
   int binCount = (int)MathCeil((topLevel - minimumSource) / step) + 1;
   if(binCount < 1 || binCount > 200000)
      return;

   double profile[];
   ArrayResize(profile, binCount);
   ArrayInitialize(profile, 0.0);
   for(int index = 0; index < copied; index++)
     {
      int bin = (int)MathFloor((topLevel - SourceValue(rates[index])) / step);
      bin = MathMax(0, MathMin(binCount - 1, bin));
      double volume = BarVolume(rates[index]);
      profile[bin] += volume;
     }

   double currentSource = SourceValue(rates[copied - 1]);
   int currentBin = (int)MathFloor((topLevel - currentSource) / step);
   currentBin = MathMax(0, MathMin(binCount - 1, currentBin));
   int rowCount = InpRows * 2 + 1;
   double visibleVolumes[];
   int visibleBins[];
   ArrayResize(visibleVolumes, rowCount);
   ArrayResize(visibleBins, rowCount);
   double redTotal = 0.0;
   double greenTotal = 0.0;
   for(int row = 0; row < rowCount; row++)
     {
      int bin = currentBin - InpRows + row;
      visibleBins[row] = bin;
      visibleVolumes[row] = bin >= 0 && bin < binCount
                            ? profile[bin] : 0.0;
      if(row < InpRows)
         redTotal += visibleVolumes[row];
      else if(row > InpRows)
         greenTotal += visibleVolumes[row];
     }

   ObjectsDeleteAll(0, PREFIX);
   DrawEma(g_ema50Handle, "50", InpEma50Color, 1);
   DrawEma(g_ema100Handle, "100", InpEma100Color, 2);
   int seconds = PeriodSeconds(InpTimeframe);
   if(seconds <= 0)
      seconds = PeriodSeconds((ENUM_TIMEFRAMES)ChartPeriod(0));
   datetime currentTime = rates[copied - 1].time;
   datetime baseTime = (datetime)((long)currentTime +
                                  (long)seconds * InpLeftBars);
   int maximumRank = 0;
   for(int row = 0; row < rowCount; row++)
      maximumRank = MathMax(maximumRank,
                            VolumeRank(visibleVolumes, rowCount, row));
   double tableTop = 0.0;
   double tableBottom = 0.0;

   for(int row = 0; row < rowCount; row++)
     {
      int bin = visibleBins[row];
      if(bin < 0 || bin >= binCount)
         continue;
      int rank = VolumeRank(visibleVolumes, rowCount, row);
      double priceTop = topLevel - bin * step;
      double priceBottom = priceTop - step;
      color rowColor = row < InpRows ? InpSellColor
                       : row > InpRows ? InpBuyColor
                       : InpCurrentColor;
      rowColor = RankedColor(rowColor, rank, maximumRank);
      datetime leftTime = (datetime)((long)baseTime + (long)seconds *
                          (InpRows * 2 - rank));
      datetime rightTime = (datetime)((long)baseTime + (long)seconds *
                           (InpRows * 2 + rank));
      if(rightTime <= leftTime)
         rightTime = leftTime + seconds;
      string boxName = PREFIX + "BOX_" + IntegerToString(row);
      if(ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, leftTime, priceTop,
                      rightTime, priceBottom))
         ConfigureRectangle(boxName, rowColor);

      datetime textTime = (datetime)(((long)leftTime + (long)rightTime) / 2);
      CreateVolumeText(PREFIX + "TEXT_" + IntegerToString(row), textTime,
                       (priceTop + priceBottom) * 0.5,
                       visibleVolumes[row]);

      if(InpShowGrid)
        {
         string gridName = PREFIX + "GRID_" + IntegerToString(row);
         datetime gridEnd = (datetime)((long)baseTime + (long)seconds *
                            (InpRows * 2 + rowCount));
         if(ObjectCreate(0, gridName, OBJ_TREND, 0, baseTime, priceTop,
                         gridEnd, priceTop))
           {
            ObjectSetInteger(0, gridName, OBJPROP_COLOR, InpGridColor);
            ObjectSetInteger(0, gridName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, gridName, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, gridName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, gridName, OBJPROP_HIDDEN, true);
           }
        }

      if(InpShowPoc && rank == maximumRank)
        {
         string pocName = PREFIX + "POC";
         if(ObjectCreate(0, pocName, OBJ_TREND, 0, rates[0].time,
                         (priceTop + priceBottom) * 0.5, rightTime,
                         (priceTop + priceBottom) * 0.5))
           {
            ObjectSetInteger(0, pocName, OBJPROP_COLOR, rowColor);
            ObjectSetInteger(0, pocName, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, pocName, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, pocName, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, pocName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, pocName, OBJPROP_HIDDEN, true);
           }
        }
      if(tableTop == 0.0 || priceTop > tableTop)
         tableTop = priceTop;
      if(tableBottom == 0.0 || priceBottom < tableBottom)
         tableBottom = priceBottom;
     }

   if(InpShowTableBorder && tableTop > tableBottom)
     {
      datetime tableEnd = (datetime)((long)baseTime + (long)seconds *
                          (InpRows * 2 + rowCount));
      string borderName = PREFIX + "TABLE_BORDER";
      if(ObjectCreate(0, borderName, OBJ_RECTANGLE, 0, baseTime, tableTop,
                      tableEnd, tableBottom))
         ConfigureRectangle(borderName, InpGridColor, false, 2);
     }
   TradeVolumeRatio(greenTotal, redTotal);
   DrawVolumeTotalsPanel(redTotal, greenTotal);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = InpSelectedSymbol == "" ? _Symbol : InpSelectedSymbol;
   if(g_symbol == "" || InpRows < 0 || InpRows > 50 ||
      InpWidthMultiplier < 0.1 || InpWidthMultiplier > 10.0 ||
      InpLeftBars < 0 || InpLeftBars > 50 || InpHistoryBars < 2 ||
      InpRefreshSeconds < 1 || InpAtrPeriod < 1 ||
      InpManualLots <= 0.0 ||
      InpTakeProfitAtrMultiplier <= 0.0 ||
      InpChartShiftPercent < 10.0 ||
      InpChartShiftPercent > 50.0)
      return INIT_PARAMETERS_INCORRECT;
   if(!SymbolSelect(g_symbol, true))
     {
      Print("Unable to select symbol ", g_symbol, ". Error ", GetLastError());
      return INIT_FAILED;
     }
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_atrHandle = iATR(g_symbol, InpTimeframe, InpAtrPeriod);
   g_ema50Handle = iMA(g_symbol, InpTimeframe, 50, 0,
                       MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(g_symbol, InpTimeframe, 100, 0,
                        MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE ||
      g_ema50Handle == INVALID_HANDLE || g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create ATR/EMA indicators. Error ", GetLastError());
      return INIT_FAILED;
     }
   g_previousChartShift = (bool)ChartGetInteger(0, CHART_SHIFT);
   g_previousChartShiftSize = ChartGetDouble(0, CHART_SHIFT_SIZE);
   ChartSetInteger(0, CHART_SHIFT, true);
   ChartSetDouble(0, CHART_SHIFT_SIZE, InpChartShiftPercent);
   ChartNavigate(0, CHART_END, 0);
   EventSetTimer(InpRefreshSeconds);
   DrawVolumeOrderbook();
   g_lastCalculationBar = iTime(g_symbol, InpTimeframe, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_ema50Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema50Handle);
   if(g_ema100Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema100Handle);
   ObjectsDeleteAll(0, PREFIX);
   ChartSetInteger(0, CHART_SHIFT, g_previousChartShift);
   ChartSetDouble(0, CHART_SHIFT_SIZE, g_previousChartShiftSize);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateOnNewTimeframeBar();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateOnNewTimeframeBar();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(StringFind(sparam, POSITION_BUTTON_PREFIX) == 0)
     {
      ulong ticket = (ulong)StringToInteger(
         StringSubstr(sparam, StringLen(POSITION_BUTTON_PREFIX)));
      if(ticket > 0 && PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL) == g_symbol)
        {
         ToggleSelectedTicket(ticket);
         bool selected = SelectedTicketIndex(ticket) >= 0;
         string oldText = ObjectGetString(0, sparam, OBJPROP_TEXT);
         ObjectSetString(0, sparam, OBJPROP_TEXT,
                         (selected ? "[X] " : "[ ] ") +
                         StringSubstr(oldText, 4));
         ObjectSetInteger(0, sparam, OBJPROP_BGCOLOR,
                          selected ? clrDarkGoldenrod : C'48,55,68');
        }
     }
   else if(sparam == BUTTON_BUY)
      PlaceManualOrder(true);
   else if(sparam == BUTTON_SELL)
      PlaceManualOrder(false);
   else if(sparam == BUTTON_CLOSE_SELECTED)
      CloseSelectedPositions();
   else
      return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
