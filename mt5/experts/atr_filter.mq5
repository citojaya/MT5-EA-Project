//+------------------------------------------------------------------+
//|                                               atr_filter.mq5     |
//| H1 ATR regime with repeat M5 ATR-line BUY triggers.             |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input int    InpAtrPeriod = 14;                 // ATR period
input double InpAtrMultiplier = 3.0;            // ATR trailing-line multiplier
input int    InpMaximumBuyOrders = 3;           // Maximum open BUY entries
input double InpLots = 0.01;                    // Order volume
input int    InpDeviationPoints = 20;           // Maximum order deviation
input ulong  InpMagicNumber = 33333333;         // EA magic number
input color  InpM5AtrColor = clrDodgerBlue;     // M5 ATR line colour
input color  InpH1AtrColor = clrMagenta;        // H1 ATR line colour
input bool   InpCloseBelowH1Atr = true;         // Close positions when H1 close is below ATR
input bool   InpShowPanel = true;               // Show chart status

#define PREFIX "ATR_FILTER_"
#define BUTTON_BUY PREFIX "BUTTON_BUY"
#define BUTTON_SELL PREFIX "BUTTON_SELL"
#define BUTTON_CLOSE_BUY PREFIX "BUTTON_CLOSE_BUY"
#define BUTTON_CLOSE_SELL PREFIX "BUTTON_CLOSE_SELL"

CTrade   g_trade;
int      g_m5AtrHandle = INVALID_HANDLE;
int      g_h1AtrHandle = INVALID_HANDLE;
datetime g_lastProcessedM5Bar = 0;
double   g_m5AtrLine = 0.0;
double   g_h1AtrLine = 0.0;
double   g_h1ClosedPrice = 0.0;
bool     g_previousCombinedAbove = false;
int      g_buyOrderCount = 0;

//+------------------------------------------------------------------+
bool CalculateAtrLine(const ENUM_TIMEFRAMES timeframe, const int atrHandle,
                      const string tag, const color lineColor,
                      double &currentLine)
  {
   const int requested = 600;
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(_Symbol, timeframe, 0, requested, rates);
   if(ratesCount < 3)
      return false;
   int atrCount = CopyBuffer(atrHandle, 0, 0, ratesCount, atrValues);
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

      double loss = InpAtrMultiplier * atrValues[index];
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

   int firstPlot = MathMax(firstValid + 1, count - 301);
   for(int index = firstPlot; index <= closedIndex; index++)
     {
      if(stops[index - 1] == EMPTY_VALUE || stops[index] == EMPTY_VALUE)
         continue;
      string name = PREFIX + tag + "_" + IntegerToString(index - firstPlot);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      rates[index - 1].time, stops[index - 1],
                      rates[index].time, stops[index]);
      else
        {
         ObjectMove(0, name, 0, rates[index - 1].time, stops[index - 1]);
         ObjectMove(0, name, 1, rates[index].time, stops[index]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, timeframe == PERIOD_H1 ? 3 : 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   return true;
  }

//+------------------------------------------------------------------+
void RemoveIndicatorSubwindows()
  {
   int windowCount = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int window = windowCount - 1; window >= 1; window--)
      for(int index = ChartIndicatorsTotal(0, window) - 1; index >= 0; index--)
        {
         string name = ChartIndicatorName(0, window, index);
         if(name != "")
            ChartIndicatorDelete(0, window, name);
        }
  }

//+------------------------------------------------------------------+
void SynchronizeBuyCount()
  {
   int openBuys = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         openBuys++;
     }
   if(openBuys == 0)
      g_buyOrderCount = 0;
   else if(g_buyOrderCount == 0)
      g_buyOrderCount = openBuys;
  }

//+------------------------------------------------------------------+
void CreateButton(const string name, const string text, const int x,
                  const int width, const color background)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 135);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void CreateButtons()
  {
   CreateButton(BUTTON_BUY, "BUY", 15, 90, clrForestGreen);
   CreateButton(BUTTON_SELL, "SELL", 113, 90, clrFireBrick);
   CreateButton(BUTTON_CLOSE_BUY, "CLOSE BUY", 211, 130, clrDarkSlateGray);
   CreateButton(BUTTON_CLOSE_SELL, "CLOSE SELL", 349, 130, clrDarkSlateGray);
  }

//+------------------------------------------------------------------+
void PlaceManualOrder(const bool buyOrder)
  {
   SynchronizeBuyCount();
   if(buyOrder && g_buyOrderCount >= InpMaximumBuyOrders)
     {
      Print("Manual BUY blocked: maximum ", InpMaximumBuyOrders,
            " BUY orders are open");
      return;
     }
   bool opened = buyOrder
                 ? g_trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0,
                               "Manual ATR BUY")
                 : g_trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0,
                                "Manual ATR SELL");
   if(!opened)
      Print("Manual order failed: ", g_trade.ResultRetcodeDescription());
   else if(buyOrder)
      g_buyOrderCount++;
  }

//+------------------------------------------------------------------+
void ClosePositions(const long positionType, const string reason)
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != positionType)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
         Print(reason, " close failed for #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
   SynchronizeBuyCount();
  }

//+------------------------------------------------------------------+
bool HandleButton(const string name)
  {
   if(name == BUTTON_BUY)
      PlaceManualOrder(true);
   else if(name == BUTTON_SELL)
      PlaceManualOrder(false);
   else if(name == BUTTON_CLOSE_BUY)
      ClosePositions(POSITION_TYPE_BUY, "Button");
   else if(name == BUTTON_CLOSE_SELL)
      ClosePositions(POSITION_TYPE_SELL, "Button");
   else
      return false;
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   return true;
  }

//+------------------------------------------------------------------+
void ProcessPressedButtons()
  {
   string buttons[] =
     {BUTTON_BUY, BUTTON_SELL, BUTTON_CLOSE_BUY, BUTTON_CLOSE_SELL};
   for(int index = 0; index < ArraySize(buttons); index++)
      if(ObjectFind(0, buttons[index]) >= 0 &&
         ObjectGetInteger(0, buttons[index], OBJPROP_STATE) == 1)
         HandleButton(buttons[index]);
  }

//+------------------------------------------------------------------+
void DrawPanel(const double closePrice)
  {
   if(!InpShowPanel)
      return;
   string name = PREFIX + "STATUS";
   string text = "H1 / M5 ATR FILTER\n";
   text += "M5 close: " + DoubleToString(closePrice, _Digits) + "\n";
   text += "H1 close / ATR: " + DoubleToString(g_h1ClosedPrice, _Digits) +
           " / " + DoubleToString(g_h1AtrLine, _Digits) + " [" +
           (g_h1ClosedPrice > g_h1AtrLine ? "BUY ALLOWED" : "BLOCKED") +
           "]\n";
   text += "M5 ATR: " + DoubleToString(g_m5AtrLine, _Digits) + " [" +
           (closePrice > g_m5AtrLine ? "ABOVE" : "BELOW") + "]\n";
   text += "BUY orders: " + IntegerToString(g_buyOrderCount) + " / " +
           IntegerToString(InpMaximumBuyOrders) + "\n";
   text += "H1 ATR close: " +
           (InpCloseBelowH1Atr ? "ENABLED" : "DISABLED");
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 15);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    g_h1ClosedPrice > g_h1AtrLine && closePrice > g_m5AtrLine
                    ? clrLimeGreen : clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   CreateButtons();
  }

//+------------------------------------------------------------------+
void ProcessCompletedM5Bar()
  {
   datetime barTime = iTime(_Symbol, PERIOD_M5, 1);
   if(barTime <= 0 || barTime <= g_lastProcessedM5Bar)
      return;

   MqlRates bar[];
   MqlRates h1Bar[];
   ArraySetAsSeries(bar, true);
   ArraySetAsSeries(h1Bar, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, bar) != 1 ||
      CopyRates(_Symbol, PERIOD_H1, 1, 1, h1Bar) != 1 ||
      !CalculateAtrLine(PERIOD_M5, g_m5AtrHandle, "M5_ATR",
                        InpM5AtrColor, g_m5AtrLine) ||
      !CalculateAtrLine(PERIOD_H1, g_h1AtrHandle, "H1_ATR",
                        InpH1AtrColor, g_h1AtrLine))
      return;

   g_lastProcessedM5Bar = barTime;
   g_h1ClosedPrice = h1Bar[0].close;
   SynchronizeBuyCount();
   if(InpCloseBelowH1Atr && g_h1ClosedPrice < g_h1AtrLine)
     {
      ClosePositions(POSITION_TYPE_BUY, "H1 ATR exit");
      ClosePositions(POSITION_TYPE_SELL, "H1 ATR exit");
      g_previousCombinedAbove = false;
      DrawPanel(bar[0].close);
      RemoveIndicatorSubwindows();
      ChartRedraw();
      return;
     }

   bool combinedAbove = g_h1ClosedPrice > g_h1AtrLine &&
                        bar[0].close > g_m5AtrLine;
   bool newCombinedSignal = combinedAbove && !g_previousCombinedAbove;

   if(newCombinedSignal && g_buyOrderCount < InpMaximumBuyOrders)
     {
      if(g_trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0,
                     "H1 + M5 ATR BUY"))
        {
         g_buyOrderCount++;
         Print("ATR BUY opened; M5 close=",
               DoubleToString(bar[0].close, _Digits), ", H1 ATR=",
               DoubleToString(g_h1AtrLine, _Digits), ", M5 ATR=",
               DoubleToString(g_m5AtrLine, _Digits), ", count=",
               g_buyOrderCount);
        }
      else
         Print("ATR BUY failed: ", g_trade.ResultRetcodeDescription());
     }
   else if(newCombinedSignal)
      Print("ATR BUY blocked: maximum ", InpMaximumBuyOrders,
            " BUY orders are open");

   g_previousCombinedAbove = combinedAbove;
   DrawPanel(bar[0].close);
   RemoveIndicatorSubwindows();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      Print("atr_filter.mq5 runs only in MT5 Strategy Tester.");
      return INIT_FAILED;
     }
   if(InpAtrPeriod < 1 || InpAtrMultiplier <= 0.0 ||
      InpMaximumBuyOrders < 1 || InpLots <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   g_m5AtrHandle = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   g_h1AtrHandle = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   if(g_m5AtrHandle == INVALID_HANDLE || g_h1AtrHandle == INVALID_HANDLE)
     {
      Print("Unable to create ATR handles. Error ", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   SynchronizeBuyCount();
   CreateButtons();
   ProcessCompletedM5Bar();
   RemoveIndicatorSubwindows();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_m5AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5AtrHandle);
   if(g_h1AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_h1AtrHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   SynchronizeBuyCount();
   ProcessPressedButtons();
   ProcessCompletedM5Bar();
   RemoveIndicatorSubwindows();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
      HandleButton(sparam);
  }
//+------------------------------------------------------------------+
