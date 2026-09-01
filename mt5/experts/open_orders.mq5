//+------------------------------------------------------------------+
//|                                                open_orders.mq5   |
//| Monitor all positions and stop orders for a selected symbol.    |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string           InpSelectedSymbol = "";        // Blank uses chart symbol
input int              InpRefreshSeconds = 1;         // Panel/cleanup interval
input ENUM_TIMEFRAMES  InpTimeframe = PERIOD_M5;      // Analysis timeframe
input int              InpAtrPeriod = 14;
input double           InpAtrMultiplier = 3.0;
input int              InpDeviationPoints = 20;
input ulong            InpMagicNumber = 55555555;
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int              InpPanelX = 15;
input int              InpPanelY = 15;
input int              InpFontSize = 11;
input string           InpFontName = "Consolas";
input color            InpTextColor = clrWhite;
input color            InpActiveColor = clrLimeGreen;
input color            InpFlatColor = clrOrange;
input color            InpEma21Color = clrYellow;
input color            InpEma50Color = clrDodgerBlue;
input color            InpEma100Color = clrMagenta;
input int              InpOrderBlockLookback = 10;
input int              InpOrderBlockSearch = 8;
input double           InpOrderBlockDisplacementAtr = 1.0;
input int              InpOrderBlockVolumeMa = 20;
input double           InpOrderBlockMinVolumeRatio = 1.0;
input double           InpOrderBlockMinMovePercent = 0.10;
input bool             InpOrderBlockMitigateOnMid = true;
input int              InpOrderBlockHistory = 500;
input int              InpOrderBlockMaxVisible = 6;
input int              InpOrderBlockProjectionBars = 100;
input color            InpBullishOrderBlockColor = clrSeaGreen;
input color            InpBearishOrderBlockColor = clrIndianRed;

#define PREFIX "OPEN_ORDERS_"
#define ORDER_BLOCK_PREFIX PREFIX "OB_"

CTrade g_trade;
string g_selectedSymbol = "";
int g_ema21Handle = INVALID_HANDLE;
int g_ema50Handle = INVALID_HANDLE;
int g_ema100Handle = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;
datetime g_lastEmaBar = 0;
datetime g_lastStrategyBar = 0;
double g_ema21 = 0.0;
double g_ema50 = 0.0;
double g_ema100 = 0.0;
double g_atr = 0.0;
double g_atrLine = 0.0;
bool g_hadBuyPositions = false;
string g_nearestBullishBlock = "none";
string g_nearestBearishBlock = "none";

//+------------------------------------------------------------------+
void DrawEma(const int handle, const string tag, const color lineColor)
  {
   const int requested = 300;
   datetime times[];
   double values[];
   int count = MathMin(CopyTime(g_selectedSymbol, InpTimeframe, 0,
                                requested, times),
                       CopyBuffer(handle, 0, 0, requested, values));
   if(count < 2)
      return;

   for(int index = 1; index < count; index++)
     {
      string name = PREFIX + "EMA_" + tag + "_" + IntegerToString(index);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      times[index - 1], values[index - 1],
                      times[index], values[index]);
      else
        {
         ObjectMove(0, name, 0, times[index - 1], values[index - 1]);
         ObjectMove(0, name, 1, times[index], values[index]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, tag == "100" ? 2 : 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
void DrawChartEmas()
  {
   datetime currentBar = iTime(g_selectedSymbol, InpTimeframe, 0);
   if(currentBar <= 0 || currentBar == g_lastEmaBar)
      return;
   g_lastEmaBar = currentBar;
   DrawEma(g_ema21Handle, "21", InpEma21Color);
   DrawEma(g_ema50Handle, "50", InpEma50Color);
   DrawEma(g_ema100Handle, "100", InpEma100Color);
  }

//+------------------------------------------------------------------+
bool ReadClosedValue(const int handle, double &value)
  {
   double buffer[1];
   if(CopyBuffer(handle, 0, 1, 1, buffer) != 1 ||
      buffer[0] == EMPTY_VALUE)
      return false;
   value = buffer[0];
   return true;
  }

//+------------------------------------------------------------------+
bool CalculateAtrLine(double &line)
  {
   MqlRates rates[];
   double atrValues[];
   int count = CopyRates(g_selectedSymbol, InpTimeframe, 0, 600, rates);
   if(count < 3 || CopyBuffer(g_atrHandle, 0, 0, count, atrValues) != count)
      return false;
   double stop = 0.0;
   double previousStop = 0.0;
   bool initialized = false;
   for(int index = 0; index < count - 1; index++)
     {
      if(atrValues[index] == EMPTY_VALUE || atrValues[index] <= 0.0)
         continue;
      double loss = InpAtrMultiplier * atrValues[index];
      if(!initialized)
        {
         stop = rates[index].close - loss;
         initialized = true;
        }
      else if(rates[index].close > previousStop &&
              rates[index - 1].close > previousStop)
         stop = MathMax(previousStop, rates[index].close - loss);
      else if(rates[index].close < previousStop &&
              rates[index - 1].close < previousStop)
         stop = MathMin(previousStop, rates[index].close + loss);
      else
         stop = rates[index].close > previousStop
                ? rates[index].close - loss : rates[index].close + loss;
      previousStop = stop;
     }
   if(!initialized)
      return false;
   line = stop;
   return true;
  }

//+------------------------------------------------------------------+
void DrawOrderBlocks()
  {
   ObjectsDeleteAll(0, ORDER_BLOCK_PREFIX);
   g_nearestBullishBlock = "none";
   g_nearestBearishBlock = "none";

   int requested = MathMax(InpOrderBlockHistory,
                           InpOrderBlockLookback + InpOrderBlockSearch + 20);
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(g_selectedSymbol, InpTimeframe, 1,
                              requested, rates);
   int atrCount = CopyBuffer(g_atrHandle, 0, 1, ratesCount, atrValues);
   int count = MathMin(ratesCount, atrCount);
   if(count <= InpOrderBlockLookback + 2)
      return;

   datetime projectionEnd = iTime(g_selectedSymbol, InpTimeframe, 0) +
                            PeriodSeconds(InpTimeframe) *
                            InpOrderBlockProjectionBars;
   double currentPrice = SymbolInfoDouble(g_selectedSymbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(g_selectedSymbol, SYMBOL_DIGITS);
   double nearestBullDistance = DBL_MAX;
   double nearestBearDistance = DBL_MAX;
   int visible = 0;

   for(int breakout = count - 1;
       breakout >= InpOrderBlockLookback &&
       visible < InpOrderBlockMaxVisible;
       breakout--)
     {
      if(atrValues[breakout] == EMPTY_VALUE || atrValues[breakout] <= 0.0)
         continue;
      double priorHigh = -DBL_MAX;
      double priorLow = DBL_MAX;
      for(int index = breakout - InpOrderBlockLookback;
          index < breakout; index++)
        {
         priorHigh = MathMax(priorHigh, rates[index].high);
         priorLow = MathMin(priorLow, rates[index].low);
        }
      double body = MathAbs(rates[breakout].close - rates[breakout].open);
      bool bullishBreak = rates[breakout].close > priorHigh &&
                          rates[breakout].close > rates[breakout].open &&
                          body >= InpOrderBlockDisplacementAtr *
                                  atrValues[breakout];
      bool bearishBreak = rates[breakout].close < priorLow &&
                          rates[breakout].close < rates[breakout].open &&
                          body >= InpOrderBlockDisplacementAtr *
                                  atrValues[breakout];
      if(!bullishBreak && !bearishBreak)
         continue;

      int blockIndex = -1;
      int firstSearch = MathMax(0, breakout - InpOrderBlockSearch);
      for(int index = breakout - 1; index >= firstSearch; index--)
        {
         bool opposing = bullishBreak
                         ? rates[index].close < rates[index].open
                         : rates[index].close > rates[index].open;
         if(opposing)
           {
            blockIndex = index;
            break;
           }
        }
      if(blockIndex < 0)
         continue;

      double blockHigh = rates[blockIndex].high;
      double blockLow = rates[blockIndex].low;
      double movePercent = bullishBreak
                           ? (rates[breakout].close - blockHigh) /
                             blockHigh * 100.0
                           : (blockLow - rates[breakout].close) /
                             blockLow * 100.0;
      if(movePercent < InpOrderBlockMinMovePercent)
         continue;

      int volumeStart = MathMax(0, breakout - InpOrderBlockVolumeMa);
      double averageVolume = 0.0;
      int volumeSamples = 0;
      for(int index = volumeStart; index < breakout; index++)
        {
         averageVolume += (double)rates[index].tick_volume;
         volumeSamples++;
        }
      if(volumeSamples <= 0)
         continue;
      averageVolume /= volumeSamples;
      double volumeRatio = averageVolume > 0.0
                           ? (double)rates[breakout].tick_volume /
                             averageVolume : 0.0;
      if(volumeRatio < InpOrderBlockMinVolumeRatio)
         continue;

      double buyVolume = 0.0;
      double sellVolume = 0.0;
      for(int index = blockIndex; index <= breakout; index++)
        {
         double range = rates[index].high - rates[index].low;
         double buyShare = range > 0.0
                           ? (rates[index].close - rates[index].low) / range
                           : 0.5;
         buyShare = MathMax(0.0, MathMin(1.0, buyShare));
         buyVolume += (double)rates[index].tick_volume * buyShare;
         sellVolume += (double)rates[index].tick_volume * (1.0 - buyShare);
        }
      double totalPressureVolume = buyVolume + sellVolume;
      if(totalPressureVolume <= 0.0)
         continue;
      double buyPower = 100.0 * buyVolume / totalPressureVolume;
      double sellPower = 100.0 - buyPower;
      if((bullishBreak && buyPower <= sellPower) ||
         (bearishBreak && sellPower <= buyPower))
         continue;

      bool invalidated = false;
      bool mitigated = false;
      double midpoint = (blockHigh + blockLow) * 0.5;
      for(int index = breakout + 1; index < count; index++)
        {
         if(bullishBreak)
           {
            if(rates[index].close < blockLow)
              {
               invalidated = true;
               break;
              }
            double mitigationLevel = InpOrderBlockMitigateOnMid
                                     ? midpoint : blockLow;
            if(rates[index].low <= mitigationLevel)
               mitigated = true;
           }
         else
           {
            if(rates[index].close > blockHigh)
              {
               invalidated = true;
               break;
              }
            double mitigationLevel = InpOrderBlockMitigateOnMid
                                     ? midpoint : blockHigh;
            if(rates[index].high >= mitigationLevel)
               mitigated = true;
           }
        }
      if(invalidated || mitigated)
         continue;

      string direction = bullishBreak ? "BULL" : "BEAR";
      string name = ORDER_BLOCK_PREFIX + direction + "_" +
                    IntegerToString((long)rates[blockIndex].time);
      if(ObjectFind(0, name) >= 0)
         continue;
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, rates[blockIndex].time,
                       blockHigh, projectionEnd, blockLow))
         continue;
      color blockColor = bullishBreak ? InpBullishOrderBlockColor
                                      : InpBearishOrderBlockColor;
      ObjectSetInteger(0, name, OBJPROP_COLOR, blockColor);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP,
                      direction + " order block | " +
                      "ACTIVE | Buy " + DoubleToString(buyPower, 1) +
                      "% / Sell " + DoubleToString(sellPower, 1) +
                      "% | Vol " + DoubleToString(volumeRatio, 2) + "x | " +
                      DoubleToString(blockLow, digits) + " - " +
                      DoubleToString(blockHigh, digits));

      datetime meterStart = rates[blockIndex].time;
      long meterSpan = (long)PeriodSeconds(InpTimeframe) * 12;
      datetime buyMeterEnd = (datetime)((long)meterStart +
                              (long)(meterSpan * buyPower / 100.0));
      datetime sellMeterEnd = (datetime)((long)meterStart +
                               (long)(meterSpan * sellPower / 100.0));
      string buyMeter = name + "_BUY_POWER";
      string sellMeter = name + "_SELL_POWER";
      ObjectCreate(0, buyMeter, OBJ_RECTANGLE, 0, meterStart, midpoint,
                   buyMeterEnd, blockLow);
      ObjectSetInteger(0, buyMeter, OBJPROP_COLOR, clrLimeGreen);
      ObjectSetInteger(0, buyMeter, OBJPROP_FILL, true);
      ObjectSetInteger(0, buyMeter, OBJPROP_BACK, true);
      ObjectSetInteger(0, buyMeter, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, buyMeter, OBJPROP_HIDDEN, true);
      ObjectCreate(0, sellMeter, OBJ_RECTANGLE, 0, meterStart, blockHigh,
                   sellMeterEnd, midpoint);
      ObjectSetInteger(0, sellMeter, OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, sellMeter, OBJPROP_FILL, true);
      ObjectSetInteger(0, sellMeter, OBJPROP_BACK, true);
      ObjectSetInteger(0, sellMeter, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, sellMeter, OBJPROP_HIDDEN, true);
      visible++;

      double distance = currentPrice < blockLow ? blockLow - currentPrice
                        : currentPrice > blockHigh ? currentPrice - blockHigh
                        : 0.0;
      string summary = DoubleToString(blockLow, digits) + "-" +
                       DoubleToString(blockHigh, digits) + " B" +
                       DoubleToString(buyPower, 0) + "/S" +
                       DoubleToString(sellPower, 0);
      if(bullishBreak && distance < nearestBullDistance)
        {
         nearestBullDistance = distance;
         g_nearestBullishBlock = summary;
        }
      else if(bearishBreak && distance < nearestBearDistance)
        {
         nearestBearDistance = distance;
         g_nearestBearishBlock = summary;
        }
     }
  }

//+------------------------------------------------------------------+
string BuyTpStorageKey(const ulong ticket)
  {
   return PREFIX + "TP_" + g_selectedSymbol + "_" +
          IntegerToString((long)ticket);
  }

//+------------------------------------------------------------------+
void ManageBuyTakeProfits()
  {
   int buyCount = 0;
   int sellCount = 0;
   double lowestEntry = DBL_MAX;
   double groupTarget = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 ||
         PositionGetString(POSITION_SYMBOL) != g_selectedSymbol)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_SELL)
        {
         sellCount++;
         continue;
        }
      if(type != POSITION_TYPE_BUY)
         continue;
      buyCount++;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double takeProfit = PositionGetDouble(POSITION_TP);
      string key = BuyTpStorageKey(ticket);
      if(takeProfit > 0.0)
         GlobalVariableSet(key, takeProfit);
      else if(GlobalVariableCheck(key))
         takeProfit = GlobalVariableGet(key);
      if(entry < lowestEntry)
        {
         lowestEntry = entry;
         groupTarget = takeProfit;
        }
     }

   bool removeIndividualTargets = sellCount > 0 || buyCount > 1;
   if(removeIndividualTargets)
      for(int index = PositionsTotal() - 1; index >= 0; index--)
        {
         ulong ticket = PositionGetTicket(index);
         if(ticket <= 0 ||
            PositionGetString(POSITION_SYMBOL) != g_selectedSymbol ||
            PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY ||
            PositionGetDouble(POSITION_TP) <= 0.0)
            continue;
         double stopLoss = PositionGetDouble(POSITION_SL);
         if(!g_trade.PositionModify(ticket, stopLoss, 0.0))
            Print("Unable to remove BUY TP from #", ticket, ": ",
                  g_trade.ResultRetcodeDescription());
        }

   if(buyCount > 1 && groupTarget > 0.0 &&
      SymbolInfoDouble(g_selectedSymbol, SYMBOL_BID) >= groupTarget)
      for(int index = PositionsTotal() - 1; index >= 0; index--)
        {
         ulong ticket = PositionGetTicket(index);
         if(ticket <= 0 ||
            PositionGetString(POSITION_SYMBOL) != g_selectedSymbol ||
            PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
            continue;
         if(!g_trade.PositionClose(ticket, InpDeviationPoints))
            Print("Group BUY close failed for #", ticket, ": ",
                  g_trade.ResultRetcodeDescription());
        }
  }

//+------------------------------------------------------------------+
void CloseSellsAfterBuyBasketClosed()
  {
   bool hasBuy = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == g_selectedSymbol &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         hasBuy = true;
         break;
        }
     }
   if(hasBuy)
     {
      g_hadBuyPositions = true;
      return;
     }
   if(!g_hadBuyPositions)
      return;

   bool sellsRemain = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 ||
         PositionGetString(POSITION_SYMBOL) != g_selectedSymbol ||
         PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
        {
         sellsRemain = true;
         Print("Unable to close SELL #", ticket,
               " after BUY basket closed: ",
               g_trade.ResultRetcodeDescription());
        }
     }
   if(!sellsRemain)
      g_hadBuyPositions = false;
  }

//+------------------------------------------------------------------+
void ProcessStrategy()
  {
   datetime barTime = iTime(g_selectedSymbol, InpTimeframe, 1);
   if(barTime <= 0 || barTime <= g_lastStrategyBar)
      return;
   if(!ReadClosedValue(g_atrHandle, g_atr) ||
      !ReadClosedValue(g_ema21Handle, g_ema21) ||
      !ReadClosedValue(g_ema50Handle, g_ema50) ||
      !ReadClosedValue(g_ema100Handle, g_ema100) ||
      !CalculateAtrLine(g_atrLine))
      return;
   g_lastStrategyBar = barTime;
   DrawOrderBlocks();
  }

//+------------------------------------------------------------------+
bool IsStopOrder(const ENUM_ORDER_TYPE orderType)
  {
   return orderType == ORDER_TYPE_BUY_STOP ||
          orderType == ORDER_TYPE_SELL_STOP ||
          orderType == ORDER_TYPE_BUY_STOP_LIMIT ||
          orderType == ORDER_TYPE_SELL_STOP_LIMIT;
  }

//+------------------------------------------------------------------+
void ReadPositionTotals(int &positionCount, double &totalVolume,
                        int &buyCount, double &buyVolume,
                        int &sellCount, double &sellVolume)
  {
   positionCount = 0;
   totalVolume = 0.0;
   buyCount = 0;
   buyVolume = 0.0;
   sellCount = 0;
   sellVolume = 0.0;

   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 ||
         PositionGetString(POSITION_SYMBOL) != g_selectedSymbol)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      long positionType = PositionGetInteger(POSITION_TYPE);
      positionCount++;
      totalVolume += volume;
      if(positionType == POSITION_TYPE_BUY)
        {
         buyCount++;
         buyVolume += volume;
        }
      else if(positionType == POSITION_TYPE_SELL)
        {
         sellCount++;
         sellVolume += volume;
        }
     }
  }

//+------------------------------------------------------------------+
int CountStopOrders()
  {
   int count = 0;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != g_selectedSymbol)
         continue;
      if(IsStopOrder((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
int DeleteAllStopOrders()
  {
   int deleted = 0;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != g_selectedSymbol)
         continue;

      ENUM_ORDER_TYPE orderType =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsStopOrder(orderType))
         continue;

      if(g_trade.OrderDelete(ticket))
        {
         deleted++;
         Print("Deleted flat-symbol stop order #", ticket, " for ",
               g_selectedSymbol);
        }
      else
         Print("Failed to delete stop order #", ticket, " for ",
               g_selectedSymbol, ": ",
               g_trade.ResultRetcodeDescription());
     }
   return deleted;
  }

//+------------------------------------------------------------------+
void SetBackground(const string name, const int x, const int y,
                   const int width, const int height)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,24,32');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'75,85,105');
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void SetLabel(const string name, const string text, const int x, const int y,
              const color textColor, int fontSize = -1)
  {
   if(fontSize < 0)
      fontSize = InpFontSize;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void DrawPanel(const int positionCount, const double totalVolume,
               const int buyCount, const double buyVolume,
               const int sellCount, const double sellVolume,
               const int stopOrderCount, const int deletedCount)
  {
   int x = InpPanelX;
   int y = InpPanelY;
   int lineHeight = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 520,
                 lineHeight * 13 + 14);

   color statusColor = positionCount > 0 ? InpActiveColor : InpFlatColor;
   string cleanupText = positionCount > 0
                        ? "WAITING FOR FLAT SYMBOL"
                        : deletedCount > 0
                          ? "DELETED " + IntegerToString(deletedCount) +
                            " STOP ORDER(S)"
                          : "FLAT / NO STOP ORDERS";
   int row = 0;
   SetLabel(PREFIX + "title", "OPEN TRADE CONTROL", x,
            y + lineHeight * row++, clrWhite, InpFontSize + 1);
   SetLabel(PREFIX + "l1", "Symbol:        " + g_selectedSymbol,
            x, y + lineHeight * row++, InpTextColor);
   SetLabel(PREFIX + "tf", "Timeframe:     " + EnumToString(InpTimeframe),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l2", "STATUS:        " +
            (positionCount > 0 ? "POSITIONS OPEN" : "FLAT"),
            x, y + lineHeight * row++, statusColor, InpFontSize + 1);
   SetLabel(PREFIX + "l3", "Open trades:   " +
            IntegerToString(positionCount),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l4", "Total volume:  " +
            DoubleToString(totalVolume, 2) + " lots",
            x, y + lineHeight * row++, clrAqua);
   SetLabel(PREFIX + "l5", "BUY:           " +
            IntegerToString(buyCount) + " / " +
            DoubleToString(buyVolume, 2) + " lots",
            x, y + lineHeight * row++, buyCount > 0 ? clrLimeGreen : clrSilver);
   SetLabel(PREFIX + "l6", "SELL:          " +
            IntegerToString(sellCount) + " / " +
            DoubleToString(sellVolume, 2) + " lots",
            x, y + lineHeight * row++, sellCount > 0 ? clrTomato : clrSilver);
   SetLabel(PREFIX + "l7", "Stop orders:   " +
            IntegerToString(stopOrderCount),
            x, y + lineHeight * row++, stopOrderCount > 0 ? clrOrange : clrSilver);
   SetLabel(PREFIX + "l8", "Cleanup:       " + cleanupText,
            x, y + lineHeight * row++, statusColor);
   SetLabel(PREFIX + "l9", "Entries:       SIGNAL ENTRIES DISABLED",
            x, y + lineHeight * row++, clrAqua);
   SetLabel(PREFIX + "l10", "Bullish VOB:   " + g_nearestBullishBlock,
            x, y + lineHeight * row++, InpBullishOrderBlockColor);
   SetLabel(PREFIX + "l11", "Bearish VOB:   " + g_nearestBearishBlock,
            x, y + lineHeight * row++, InpBearishOrderBlockColor);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void MonitorSelectedSymbol()
  {
   DrawChartEmas();
   int positionCount;
   double totalVolume;
   int buyCount;
   double buyVolume;
   int sellCount;
   double sellVolume;
   ReadPositionTotals(positionCount, totalVolume,
                      buyCount, buyVolume, sellCount, sellVolume);

   int deletedCount = 0;
   if(positionCount == 0)
      deletedCount = DeleteAllStopOrders();
   int stopOrderCount = CountStopOrders();

   DrawPanel(positionCount, totalVolume,
             buyCount, buyVolume, sellCount, sellVolume,
             stopOrderCount, deletedCount);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_selectedSymbol = InpSelectedSymbol == ""
                      ? _Symbol : InpSelectedSymbol;
   if(InpRefreshSeconds < 1 || g_selectedSymbol == "" ||
      InpAtrPeriod < 1 || InpAtrMultiplier <= 0.0 ||
      InpOrderBlockLookback < 2 || InpOrderBlockSearch < 1 ||
      InpOrderBlockDisplacementAtr <= 0.0 || InpOrderBlockVolumeMa < 2 ||
      InpOrderBlockMinVolumeRatio <= 0.0 ||
      InpOrderBlockMinMovePercent < 0.0 || InpOrderBlockHistory < 50 ||
      InpOrderBlockMaxVisible < 1 || InpOrderBlockProjectionBars < 1)
      return INIT_PARAMETERS_INCORRECT;
   if(!SymbolSelect(g_selectedSymbol, true))
     {
      Print("Unable to select symbol ", g_selectedSymbol,
            ". Error ", GetLastError());
      return INIT_FAILED;
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) !=
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("BUY/SELL cycling requires a hedging account.");
      return INIT_FAILED;
     }
   g_ema21Handle = iMA(g_selectedSymbol, InpTimeframe, 21,
                       0, MODE_EMA, PRICE_CLOSE);
   g_ema50Handle = iMA(g_selectedSymbol, InpTimeframe, 50,
                       0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(g_selectedSymbol, InpTimeframe, 100,
                        0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(g_selectedSymbol, InpTimeframe, InpAtrPeriod);
   if(g_ema21Handle == INVALID_HANDLE || g_ema50Handle == INVALID_HANDLE ||
      g_ema100Handle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Print("Unable to create EMA handles for ", g_selectedSymbol,
            ". Error ", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_selectedSymbol);
   int initialPositionCount, initialBuyCount, initialSellCount;
   double initialTotalVolume, initialBuyVolume, initialSellVolume;
   ReadPositionTotals(initialPositionCount, initialTotalVolume,
                      initialBuyCount, initialBuyVolume,
                      initialSellCount, initialSellVolume);
   g_hadBuyPositions = initialBuyCount > 0;
   EventSetTimer(InpRefreshSeconds);
   ProcessStrategy();
   MonitorSelectedSymbol();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_ema21Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema21Handle);
   if(g_ema50Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema50Handle);
   if(g_ema100Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema100Handle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CloseSellsAfterBuyBasketClosed();
   ProcessStrategy();
   ManageBuyTakeProfits();
   CloseSellsAfterBuyBasketClosed();
   MonitorSelectedSymbol();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CloseSellsAfterBuyBasketClosed();
   ProcessStrategy();
   ManageBuyTakeProfits();
   CloseSellsAfterBuyBasketClosed();
   MonitorSelectedSymbol();
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   MonitorSelectedSymbol();
  }
//+------------------------------------------------------------------+
