//+------------------------------------------------------------------+
//|                                      support_resistance.mq5      |
//| M5 Strategy Tester EA using support and a 3 ATR trailing line.  |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input int    InpAtrPeriod = 14;                 // ATR period
input double InpSupportProximityAtr = 0.20;     // Distance from support that arms trading
input double InpAtrLineMultiplier = 3.0;        // ATR trailing-line multiplier
input double InpMinimumBuyGapAtr = 6.0;         // Minimum spacing between BUY entries
input int    InpMaximumBuyOrders = 5;           // Maximum BUY orders until all are closed
input bool   InpUseH1AtrEntryFilter = true;     // Require completed H1 close above H1 ATR
input double InpLots = 0.01;                    // Buy volume
input int    InpDeviationPoints = 20;           // Maximum order deviation
input ulong  InpMagicNumber = 22222222;         // EA magic number
input bool   InpCloseAllAtEndOfDay = true;      // Close symbol positions at broker-day change
input color  InpSupportColor = clrLimeGreen;    // Support line colour
input color  InpPivotColor = clrGold;            // Daily pivot line colour
input color  InpResistanceColor = clrTomato;    // Resistance line colour
input color  InpAtrLineColor = clrDodgerBlue;   // 3 ATR line colour
input bool   InpShowPanel = true;               // Show status panel

#define PREFIX "SR_TESTER_"
#define SUPPORT_LINE PREFIX "SUPPORT"
#define PIVOT_LINE PREFIX "PIVOT"
#define RESISTANCE_LINE PREFIX "RESISTANCE"
#define BUTTON_BUY PREFIX "BUTTON_BUY"
#define BUTTON_SELL PREFIX "BUTTON_SELL"
#define BUTTON_CLOSE_BUY PREFIX "BUTTON_CLOSE_BUY"
#define BUTTON_CLOSE_SELL PREFIX "BUTTON_CLOSE_SELL"

CTrade   g_trade;
int      g_atrHandle = INVALID_HANDLE;
int      g_h1AtrHandle = INVALID_HANDLE;
datetime g_lastProcessedBar = 0;
bool     g_tradePossible = false;
double   g_support = 0.0;
double   g_pivot = 0.0;
double   g_resistance = 0.0;
double   g_atr = 0.0;
double   g_atrLine = 0.0;
double   g_h1AtrLine = 0.0;
double   g_h1ClosedPrice = 0.0;
double   g_lastBuyEntryPrice = 0.0;
int      g_buyOrderCount = 0;
datetime g_currentTradingDay = 0;

//+------------------------------------------------------------------+
bool CalculateDailyPivotLevels(double &support, double &pivot,
                               double &resistance)
  {
   MqlRates previousDay[];
   ArraySetAsSeries(previousDay, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, previousDay) != 1)
      return false;
   if(previousDay[0].high <= previousDay[0].low ||
      previousDay[0].close <= 0.0)
      return false;
   pivot = (previousDay[0].high + previousDay[0].low +
            previousDay[0].close) / 3.0;
   support = 2.0 * pivot - previousDay[0].high;
   resistance = 2.0 * pivot - previousDay[0].low;
   return support > 0.0 && pivot > 0.0 && resistance > 0.0;
  }

//+------------------------------------------------------------------+
bool CalculateAtrLine(double &currentLine, double &currentAtr)
  {
   const int requested = 600;
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(_Symbol, PERIOD_M5, 0, requested, rates);
   if(ratesCount < 3)
      return false;
   int atrCount = CopyBuffer(g_atrHandle, 0, 0, ratesCount, atrValues);
   int count = MathMin(ratesCount, atrCount);
   if(count < 3)
      return false;

   double stops[];
   ArrayResize(stops, count);
   int firstValid = -1;
   for(int index = 0; index < count - 1; index++)
     {
      if(atrValues[index] == EMPTY_VALUE || atrValues[index] <= 0.0)
        {
         stops[index] = EMPTY_VALUE;
         continue;
        }

      double loss = InpAtrLineMultiplier * atrValues[index];
      if(firstValid < 0)
        {
         stops[index] = rates[index].close - loss;
         firstValid = index;
        }
      else
        {
         double previousStop = stops[index - 1];
         if(previousStop == EMPTY_VALUE)
            stops[index] = rates[index].close - loss;
         else if(rates[index].close > previousStop &&
                 rates[index - 1].close > previousStop)
            stops[index] = MathMax(previousStop, rates[index].close - loss);
         else if(rates[index].close < previousStop &&
                 rates[index - 1].close < previousStop)
            stops[index] = MathMin(previousStop, rates[index].close + loss);
         else
            stops[index] = rates[index].close > previousStop
                           ? rates[index].close - loss
                           : rates[index].close + loss;
        }
     }

   int closedIndex = count - 2;
   if(firstValid < 0 || stops[closedIndex] == EMPTY_VALUE)
      return false;
   currentLine = stops[closedIndex];
   currentAtr = atrValues[closedIndex];

   int firstPlot = MathMax(firstValid + 1, count - 301);
   for(int index = firstPlot; index <= closedIndex; index++)
     {
      if(stops[index - 1] == EMPTY_VALUE || stops[index] == EMPTY_VALUE)
         continue;
      string name = PREFIX + "ATR_LINE_" + IntegerToString(index - firstPlot);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      rates[index - 1].time, stops[index - 1],
                      rates[index].time, stops[index]);
      else
        {
         ObjectMove(0, name, 0, rates[index - 1].time, stops[index - 1]);
         ObjectMove(0, name, 1, rates[index].time, stops[index]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpAtrLineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   return true;
  }

//+------------------------------------------------------------------+
bool CalculateH1AtrLine(double &currentLine)
  {
   const int requested = 600;
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(_Symbol, PERIOD_H1, 0, requested, rates);
   if(ratesCount < 3)
      return false;
   int atrCount = CopyBuffer(g_h1AtrHandle, 0, 0, ratesCount, atrValues);
   int count = MathMin(ratesCount, atrCount);
   if(count < 3)
      return false;

   double previousStop = 0.0;
   double stop = 0.0;
   bool initialized = false;
   for(int index = 0; index < count - 1; index++)
     {
      if(atrValues[index] == EMPTY_VALUE || atrValues[index] <= 0.0)
         continue;
      double loss = InpAtrLineMultiplier * atrValues[index];
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
                ? rates[index].close - loss
                : rates[index].close + loss;
      previousStop = stop;
     }
   if(!initialized)
      return false;
   currentLine = stop;
   return true;
  }

//+------------------------------------------------------------------+
void DrawHorizontalLevel(const string name, const double price,
                         const color lineColor)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void RemoveIndicatorSubwindows()
  {
   int windowCount = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int window = windowCount - 1; window >= 1; window--)
      for(int index = ChartIndicatorsTotal(0, window) - 1; index >= 0; index--)
        {
         string indicatorName = ChartIndicatorName(0, window, index);
         if(indicatorName != "")
            ChartIndicatorDelete(0, window, indicatorName);
        }
  }

//+------------------------------------------------------------------+
void CreateTradeButton(const string name, const string text,
                       const int x, const int width, const color background)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 165);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void CreateTradeButtons()
  {
   CreateTradeButton(BUTTON_BUY, "BUY", 15, 90, clrForestGreen);
   CreateTradeButton(BUTTON_SELL, "SELL", 113, 90, clrFireBrick);
   CreateTradeButton(BUTTON_CLOSE_BUY, "CLOSE BUY", 211, 130,
                     clrDarkSlateGray);
   CreateTradeButton(BUTTON_CLOSE_SELL, "CLOSE SELL", 349, 130,
                     clrDarkSlateGray);
  }

//+------------------------------------------------------------------+
void RefreshLastBuyEntryPrice()
  {
   g_lastBuyEntryPrice = 0.0;
   long latestTime = -1;
   int openBuyPositions = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;
      openBuyPositions++;
      long positionTime = PositionGetInteger(POSITION_TIME_MSC);
      if(positionTime > latestTime)
        {
         latestTime = positionTime;
         g_lastBuyEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   if(openBuyPositions == 0)
      g_buyOrderCount = 0;
   else if(g_buyOrderCount == 0)
      g_buyOrderCount = openBuyPositions;
  }

//+------------------------------------------------------------------+
bool BuyGapPassed(const double proposedEntry)
  {
   if(g_lastBuyEntryPrice <= 0.0)
      return true;
   if(g_atr <= 0.0)
      return false;
   return MathAbs(proposedEntry - g_lastBuyEntryPrice) >=
          InpMinimumBuyGapAtr * g_atr;
  }

//+------------------------------------------------------------------+
void ResetBuyTrackingIfFlat()
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         return;
     }
   g_buyOrderCount = 0;
   g_lastBuyEntryPrice = 0.0;
  }

//+------------------------------------------------------------------+
void PlaceManualOrder(const bool buyOrder)
  {
   ResetBuyTrackingIfFlat();
   if(buyOrder && InpUseH1AtrEntryFilter &&
      (g_h1ClosedPrice <= 0.0 || g_h1ClosedPrice <= g_h1AtrLine))
     {
      Print("Manual BUY blocked: completed H1 close is not above H1 ATR line");
      return;
     }
   double proposedEntry = buyOrder
                          ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(buyOrder && g_buyOrderCount >= InpMaximumBuyOrders)
     {
      Print("Manual BUY blocked: maximum ", InpMaximumBuyOrders,
            " BUY orders already placed");
      return;
     }
   if(buyOrder && !BuyGapPassed(proposedEntry))
     {
      Print("Manual BUY blocked by minimum gap: current gap=",
            DoubleToString(MathAbs(proposedEntry - g_lastBuyEntryPrice), _Digits),
            ", required=", DoubleToString(InpMinimumBuyGapAtr * g_atr, _Digits),
            " (", DoubleToString(InpMinimumBuyGapAtr, 1), " ATR)");
      return;
     }
   bool opened = buyOrder
                 ? g_trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0,
                               "Manual button BUY")
                 : g_trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0,
                                "Manual button SELL");
   if(!opened)
      Print("Manual ", buyOrder ? "BUY" : "SELL", " failed: ",
            g_trade.ResultRetcodeDescription());
   else
     {
      if(buyOrder)
        {
         g_lastBuyEntryPrice = g_trade.ResultPrice() > 0.0
                               ? g_trade.ResultPrice() : proposedEntry;
         g_buyOrderCount++;
        }
      Print("Manual ", buyOrder ? "BUY" : "SELL", " opened; volume=",
            DoubleToString(InpLots, 2));
     }
  }

//+------------------------------------------------------------------+
void ClosePositions(const long positionType)
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != positionType)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
         Print("Button close failed for position #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
      else
         Print("Button closed position #", ticket);
     }
   if(positionType == POSITION_TYPE_BUY)
      RefreshLastBuyEntryPrice();
  }

//+------------------------------------------------------------------+
void CloseAllAtDayChange()
  {
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay <= 0)
      return;
   if(g_currentTradingDay <= 0)
     {
      g_currentTradingDay = currentDay;
      return;
     }
   if(!InpCloseAllAtEndOfDay || currentDay == g_currentTradingDay)
     {
      g_currentTradingDay = currentDay;
      return;
     }

   bool positionsRemain = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
        {
         positionsRemain = true;
         Print("End-of-day close failed for position #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
        }
      else
         Print("End-of-day closed position #", ticket);
     }

   if(!positionsRemain)
     {
      g_currentTradingDay = currentDay;
      g_tradePossible = false;
      RefreshLastBuyEntryPrice();
      Print("End-of-day close completed; trading state reset");
     }
  }

//+------------------------------------------------------------------+
bool HandleTradeButton(const string buttonName)
  {
   if(buttonName == BUTTON_BUY)
      PlaceManualOrder(true);
   else if(buttonName == BUTTON_SELL)
      PlaceManualOrder(false);
   else if(buttonName == BUTTON_CLOSE_BUY)
      ClosePositions(POSITION_TYPE_BUY);
   else if(buttonName == BUTTON_CLOSE_SELL)
      ClosePositions(POSITION_TYPE_SELL);
   else
      return false;
   ObjectSetInteger(0, buttonName, OBJPROP_STATE, false);
   ChartRedraw();
   return true;
  }

//+------------------------------------------------------------------+
void ProcessPressedTradeButtons()
  {
   string buttons[] =
     {
      BUTTON_BUY, BUTTON_SELL, BUTTON_CLOSE_BUY, BUTTON_CLOSE_SELL
     };
   for(int index = 0; index < ArraySize(buttons); index++)
      if(ObjectFind(0, buttons[index]) >= 0 &&
         ObjectGetInteger(0, buttons[index], OBJPROP_STATE) == 1)
         HandleTradeButton(buttons[index]);
  }

//+------------------------------------------------------------------+
void DrawPanel(const double closePrice, const bool supportTouched)
  {
   if(!InpShowPanel)
      return;
   string name = PREFIX + "STATUS";
   string status = "DAILY PIVOTS / M5 SIGNALS\n";
   status += "S1 support: " + DoubleToString(g_support, _Digits) + "\n";
   status += "Pivot: " + DoubleToString(g_pivot, _Digits) + "\n";
   status += "R1 resistance: " + DoubleToString(g_resistance, _Digits) + "\n";
   status += "ATR: " + DoubleToString(g_atr, _Digits) + "\n";
   status += "3 ATR line: " + DoubleToString(g_atrLine, _Digits) + "\n";
   status += "H1 close / ATR: " +
             DoubleToString(g_h1ClosedPrice, _Digits) + " / " +
             DoubleToString(g_h1AtrLine, _Digits) + " [" +
             (!InpUseH1AtrEntryFilter ? "OFF" :
              g_h1ClosedPrice > g_h1AtrLine ? "PASS" : "FAIL") + "]\n";
   status += "Near support: " + (supportTouched ? "YES" : "NO") + "\n";
   status += "Trade possible: " + (g_tradePossible ? "ACTIVE" : "OFF") + "\n";
   status += "BUY orders: " + IntegerToString(g_buyOrderCount) + " / " +
             IntegerToString(InpMaximumBuyOrders) + "\n";
   status += "Daily close: " +
             (InpCloseAllAtEndOfDay ? "ENABLED" : "DISABLED") + "\n";
   status += "Close above line: " + (closePrice > g_atrLine ? "YES" : "NO");
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 15);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    g_tradePossible ? clrLimeGreen : clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, status);
   CreateTradeButtons();
  }

//+------------------------------------------------------------------+
void ProcessCompletedM5Bar()
  {
   ResetBuyTrackingIfFlat();
   datetime barTime = iTime(_Symbol, PERIOD_M5, 1);
   if(barTime <= 0 || barTime <= g_lastProcessedBar)
      return;

   MqlRates closedBar[];
   MqlRates h1Bar[];
   ArraySetAsSeries(closedBar, true);
   ArraySetAsSeries(h1Bar, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, closedBar) != 1 ||
      CopyRates(_Symbol, PERIOD_H1, 1, 1, h1Bar) != 1)
      return;
   if(!CalculateAtrLine(g_atrLine, g_atr) ||
      !CalculateH1AtrLine(g_h1AtrLine) ||
      !CalculateDailyPivotLevels(g_support, g_pivot, g_resistance))
      return;

   g_lastProcessedBar = barTime;
   g_h1ClosedPrice = h1Bar[0].close;
   DrawHorizontalLevel(SUPPORT_LINE, g_support, InpSupportColor);
   DrawHorizontalLevel(PIVOT_LINE, g_pivot, InpPivotColor);
   DrawHorizontalLevel(RESISTANCE_LINE, g_resistance, InpResistanceColor);

   double proximity = InpSupportProximityAtr * g_atr;
   bool supportTouched = closedBar[0].low <= g_support + proximity &&
                         closedBar[0].high >= g_support - proximity;
   bool wasTradePossible = g_tradePossible;
   if(!g_tradePossible && supportTouched)
     {
      g_tradePossible = true;
      Print("Trade possible activated near M5 support ",
            DoubleToString(g_support, _Digits));
     }

   if(wasTradePossible && closedBar[0].close > g_atrLine &&
      (!InpUseH1AtrEntryFilter || g_h1ClosedPrice > g_h1AtrLine))
     {
      double proposedEntry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(g_buyOrderCount >= InpMaximumBuyOrders)
        {
         Print("Signal BUY waiting: maximum ", InpMaximumBuyOrders,
               " BUY orders reached; waiting until all BUYs are closed");
        }
      else if(!BuyGapPassed(proposedEntry))
        {
         Print("Signal BUY waiting for minimum gap: current gap=",
               DoubleToString(MathAbs(proposedEntry - g_lastBuyEntryPrice),
                              _Digits),
               ", required=",
               DoubleToString(InpMinimumBuyGapAtr * g_atr, _Digits));
        }
      else if(g_trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0,
                     "Support + 3 ATR BUY"))
        {
         g_lastBuyEntryPrice = g_trade.ResultPrice() > 0.0
                               ? g_trade.ResultPrice() : proposedEntry;
         g_buyOrderCount++;
         Print("BUY opened after support setup; close=",
               DoubleToString(closedBar[0].close, _Digits),
               ", 3 ATR line=", DoubleToString(g_atrLine, _Digits));
         g_tradePossible = false;
        }
      else if(BuyGapPassed(proposedEntry))
         Print("BUY failed: ", g_trade.ResultRetcodeDescription());
     }

   DrawPanel(closedBar[0].close, supportTouched);
   RemoveIndicatorSubwindows();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      Print("support_resistance.mq5 runs only in MT5 Strategy Tester.");
      return INIT_FAILED;
     }
   if(InpAtrPeriod < 1 || InpSupportProximityAtr < 0.0 ||
      InpMinimumBuyGapAtr < 0.0 ||
      InpMaximumBuyOrders < 1 ||
      InpAtrLineMultiplier <= 0.0 || InpLots <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   g_h1AtrHandle = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE || g_h1AtrHandle == INVALID_HANDLE)
     {
      Print("Unable to create M5/H1 ATR handles. Error ", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_currentTradingDay = iTime(_Symbol, PERIOD_D1, 0);
   RefreshLastBuyEntryPrice();
   CreateTradeButtons();
   ProcessCompletedM5Bar();
   RemoveIndicatorSubwindows();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_h1AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_h1AtrHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CloseAllAtDayChange();
   ResetBuyTrackingIfFlat();
   ProcessPressedTradeButtons();
   ProcessCompletedM5Bar();
   RemoveIndicatorSubwindows();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
      HandleTradeButton(sparam);
  }
//+------------------------------------------------------------------+
