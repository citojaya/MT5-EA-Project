//+------------------------------------------------------------------+
//|                                      backtest_open_orders.mq5    |
//| M5 EMA-stack entries with ATR filter and EMA100 SELL STOP hedge.|
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input int    InpAtrPeriod = 14;                    // M5 ATR period
input double InpAtrMultiplier = 3.0;               // M5 ATR-line multiplier
input double InpTakeProfitAtrMultiplier = 3.0;     // BUY take profit in M5 ATR
input double InpLots = 0.01;                       // BUY volume per signal
input int    InpSellStopOffsetPoints = 1;          // SELL STOP distance below EMA100
input int    InpDeviationPoints = 20;              // Maximum market-order deviation
input ulong  InpMagicNumber = 44444444;            // EA magic number
input color  InpEma21Color = clrYellow;            // EMA21 colour
input color  InpEma50Color = clrDodgerBlue;        // EMA50 colour
input color  InpEma100Color = clrMagenta;          // EMA100 colour
input color  InpAtrColor = clrRed;                 // M5 ATR-line colour
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int    InpPanelX = 15;
input int    InpPanelY = 15;
input int    InpFontSize = 10;
input string InpFontName = "Consolas";

#define PREFIX "BACKTEST_OPEN_ORDERS_"
#define HEDGE_COMMENT "EMA100 SELL STOP hedge"
#define BUTTON_BUY PREFIX "BUTTON_BUY"
#define BUTTON_SELL PREFIX "BUTTON_SELL"
#define BUTTON_CLOSE_BUY PREFIX "BUTTON_CLOSE_BUY"
#define BUTTON_CLOSE_SELL PREFIX "BUTTON_CLOSE_SELL"

CTrade   g_trade;
int      g_atrHandle = INVALID_HANDLE;
int      g_ema21Handle = INVALID_HANDLE;
int      g_ema50Handle = INVALID_HANDLE;
int      g_ema100Handle = INVALID_HANDLE;
datetime g_lastProcessedBar = 0;
double   g_atrLine = 0.0;
double   g_atr = 0.0;
double   g_ema21 = 0.0;
double   g_ema50 = 0.0;
double   g_ema100 = 0.0;
double   g_lastClose = 0.0;
bool     g_buyArmed = true;

//+------------------------------------------------------------------+
double NormalizeVolume(const double requestedVolume)
  {
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return requestedVolume;
   double volume = MathMax(minimum, MathMin(maximum, requestedVolume));
   return NormalizeDouble(MathFloor(volume / step + 1e-9) * step, 8);
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
void DrawEma(const int handle, const string tag, const color lineColor)
  {
   const int requested = 300;
   datetime times[];
   double values[];
   int count = MathMin(CopyTime(_Symbol, PERIOD_M5, 0, requested, times),
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
bool CalculateAndDrawAtrLine(double &currentLine)
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
      string name = PREFIX + "ATR_" + IntegerToString(index - firstPlot);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      rates[index - 1].time, stops[index - 1],
                      rates[index].time, stops[index]);
      else
        {
         ObjectMove(0, name, 0, rates[index - 1].time, stops[index - 1]);
         ObjectMove(0, name, 1, rates[index].time, stops[index]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpAtrColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
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
   int windows = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int window = windows - 1; window >= 1; window--)
      for(int index = ChartIndicatorsTotal(0, window) - 1; index >= 0; index--)
        {
         string name = ChartIndicatorName(0, window, index);
         if(name != "")
            ChartIndicatorDelete(0, window, name);
        }
  }

//+------------------------------------------------------------------+
void ReadExposure(double &buyVolume, double &sellVolume,
                  int &buyCount, int &sellCount)
  {
   buyVolume = 0.0;
   sellVolume = 0.0;
   buyCount = 0;
   sellCount = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      double volume = PositionGetDouble(POSITION_VOLUME);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         buyVolume += volume;
         buyCount++;
        }
      else
        {
         sellVolume += volume;
         sellCount++;
        }
     }
  }

//+------------------------------------------------------------------+
void DeleteHedgeOrders()
  {
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber ||
         OrderGetString(ORDER_COMMENT) != HEDGE_COMMENT)
         continue;
      if(!g_trade.OrderDelete(ticket))
         Print("Unable to delete EMA100 SELL STOP #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
bool CloseAllSellPositions()
  {
   bool allClosed = true;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
        {
         allClosed = false;
         Print("Unable to close SELL position #", ticket,
               " before BUY: ", g_trade.ResultRetcodeDescription());
        }
      else
         Print("Closed SELL position #", ticket, " before new BUY signal");
     }
   return allClosed;
  }

//+------------------------------------------------------------------+
void MaintainSellStop()
  {
   double buyVolume;
   double sellVolume;
   int buyCount;
   int sellCount;
   ReadExposure(buyVolume, sellVolume, buyCount, sellCount);
   double uncoveredVolume = buyVolume - sellVolume;
   double minimumVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(uncoveredVolume < minimumVolume - 1e-9 || g_ema100 <= 0.0)
     {
      DeleteHedgeOrders();
      return;
     }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double belowEma = g_ema100 - InpSellStopOffsetPoints * point;
   double maximumValidPrice = bid - stopsLevel * point;
   double stopPrice = NormalizeDouble(MathMin(belowEma, maximumValidPrice),
                                      _Digits);
   if(stopPrice <= 0.0 || stopPrice >= bid)
      return;

   double requiredVolume = NormalizeVolume(uncoveredVolume);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   bool matching = false;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber ||
         OrderGetString(ORDER_COMMENT) != HEDGE_COMMENT)
         continue;
      bool same = MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - stopPrice) <
                  point * 0.5 &&
                  MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT) -
                          requiredVolume) < volumeStep * 0.5;
      if(!matching && same)
         matching = true;
      else if(!g_trade.OrderDelete(ticket))
         Print("Unable to replace EMA100 SELL STOP #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
   if(matching)
      return;
   if(!g_trade.SellStop(requiredVolume, stopPrice, _Symbol, 0.0, 0.0,
                        ORDER_TIME_GTC, 0, HEDGE_COMMENT))
      Print("EMA100 SELL STOP failed: ",
            g_trade.ResultRetcodeDescription());
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
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void SetLabel(const string name, const string text, const int x, const int y,
              const color textColor, int size = -1)
  {
   if(size < 0)
      size = InpFontSize;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void CreateButton(const string name, const string text, const int x,
                  const int y, const int width, const color background)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void CreateTradeButtons(const int y)
  {
   CreateButton(BUTTON_BUY, "BUY", InpPanelX, y, 90, clrForestGreen);
   CreateButton(BUTTON_SELL, "SELL", InpPanelX + 98, y, 90, clrFireBrick);
   CreateButton(BUTTON_CLOSE_BUY, "CLOSE BUY", InpPanelX + 196, y,
                130, clrDarkSlateGray);
   CreateButton(BUTTON_CLOSE_SELL, "CLOSE SELL", InpPanelX + 334, y,
                130, clrDarkSlateGray);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void PlaceManualOrder(const bool buyOrder)
  {
   if(buyOrder && g_atr <= 0.0)
     {
      Print("Manual BUY blocked: completed M5 ATR is not available");
      return;
     }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double takeProfit = buyOrder
                       ? NormalizeDouble(ask +
                         InpTakeProfitAtrMultiplier * g_atr, _Digits)
                       : 0.0;
   bool opened = buyOrder
                 ? g_trade.Buy(NormalizeVolume(InpLots), _Symbol,
                               0.0, 0.0, takeProfit, "Manual button BUY")
                 : g_trade.Sell(NormalizeVolume(InpLots), _Symbol,
                                0.0, 0.0, 0.0, "Manual button SELL");
   if(!opened)
      Print("Manual ", buyOrder ? "BUY" : "SELL", " failed: ",
            g_trade.ResultRetcodeDescription());
   else
      Print("Manual ", buyOrder ? "BUY" : "SELL", " opened");
  }

//+------------------------------------------------------------------+
void ClosePositionsByType(const long positionType)
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != positionType)
         continue;
      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
         Print("Button close failed for #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
      else
         Print("Button closed position #", ticket);
     }
  }

//+------------------------------------------------------------------+
bool HandleTradeButton(const string name)
  {
   if(name == BUTTON_BUY)
      PlaceManualOrder(true);
   else if(name == BUTTON_SELL)
      PlaceManualOrder(false);
   else if(name == BUTTON_CLOSE_BUY)
      ClosePositionsByType(POSITION_TYPE_BUY);
   else if(name == BUTTON_CLOSE_SELL)
      ClosePositionsByType(POSITION_TYPE_SELL);
   else
      return false;
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   MaintainSellStop();
   ChartRedraw();
   return true;
  }

//+------------------------------------------------------------------+
void ProcessPressedTradeButtons()
  {
   string buttons[] =
     {BUTTON_BUY, BUTTON_SELL, BUTTON_CLOSE_BUY, BUTTON_CLOSE_SELL};
   for(int index = 0; index < ArraySize(buttons); index++)
      if(ObjectFind(0, buttons[index]) >= 0 &&
         ObjectGetInteger(0, buttons[index], OBJPROP_STATE) == 1)
         HandleTradeButton(buttons[index]);
  }

//+------------------------------------------------------------------+
void DrawPanel(const bool buySignal)
  {
   double buyVolume;
   double sellVolume;
   int buyCount;
   int sellCount;
   ReadExposure(buyVolume, sellVolume, buyCount, sellCount);
   int x = InpPanelX;
   int y = InpPanelY;
   int lineHeight = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 500,
                 lineHeight * 11 + 14);
   int row = 0;
   SetLabel(PREFIX + "title", "BACKTEST OPEN ORDERS", x,
            y + lineHeight * row++, clrWhite, InpFontSize + 1);
   SetLabel(PREFIX + "l1", "M5 close / ATR: " +
            DoubleToString(g_lastClose, _Digits) + " / " +
            DoubleToString(g_atrLine, _Digits),
            x, y + lineHeight * row++, g_lastClose > g_atrLine
            ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l2", "EMA 21 / 50 / 100: " +
            DoubleToString(g_ema21, _Digits) + " / " +
            DoubleToString(g_ema50, _Digits) + " / " +
            DoubleToString(g_ema100, _Digits),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l3", "BUY signal:    " +
            (buySignal ? "YES" : "NO"),
            x, y + lineHeight * row++, buySignal ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l4", "Re-entry armed: " +
            (g_buyArmed ? "YES" : "NO"),
            x, y + lineHeight * row++, g_buyArmed ? clrAqua : clrSilver);
   SetLabel(PREFIX + "l5", "BUY exposure:  " +
            IntegerToString(buyCount) + " / " +
            DoubleToString(buyVolume, 2) + " lots",
            x, y + lineHeight * row++, clrLimeGreen);
   SetLabel(PREFIX + "l6", "SELL exposure: " +
            IntegerToString(sellCount) + " / " +
            DoubleToString(sellVolume, 2) + " lots",
            x, y + lineHeight * row++, sellCount > 0 ? clrTomato : clrSilver);
   SetLabel(PREFIX + "l7", "Uncovered BUY: " +
            DoubleToString(MathMax(0.0, buyVolume - sellVolume), 2) + " lots",
            x, y + lineHeight * row++, clrAqua);
   SetLabel(PREFIX + "l8", "SELL STOP:     below EMA100",
            x, y + lineHeight * row++, clrSilver);
   CreateTradeButtons(y + lineHeight * row);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void ProcessCompletedBar()
  {
   datetime barTime = iTime(_Symbol, PERIOD_M5, 1);
   if(barTime <= 0 || barTime <= g_lastProcessedBar)
      return;
   MqlRates bar[];
   ArraySetAsSeries(bar, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, bar) != 1 ||
      !ReadClosedValue(g_atrHandle, g_atr) ||
      !ReadClosedValue(g_ema21Handle, g_ema21) ||
      !ReadClosedValue(g_ema50Handle, g_ema50) ||
      !ReadClosedValue(g_ema100Handle, g_ema100) ||
      !CalculateAndDrawAtrLine(g_atrLine))
      return;

   g_lastProcessedBar = barTime;
   g_lastClose = bar[0].close;
   DrawEma(g_ema21Handle, "21", InpEma21Color);
   DrawEma(g_ema50Handle, "50", InpEma50Color);
   DrawEma(g_ema100Handle, "100", InpEma100Color);

   if(g_lastClose < g_ema100)
      g_buyArmed = true;
   bool buySignal = g_lastClose > g_atrLine &&
                    g_lastClose > g_ema21 &&
                    g_ema21 > g_ema50 &&
                    g_ema50 > g_ema100;
   if(g_buyArmed && buySignal)
     {
      DeleteHedgeOrders();
      if(!CloseAllSellPositions())
         Print("BUY blocked because one or more SELL positions could not close");
      else
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double takeProfit = NormalizeDouble(
            ask + InpTakeProfitAtrMultiplier * g_atr, _Digits);
         if(g_trade.Buy(NormalizeVolume(InpLots), _Symbol, 0.0, 0.0,
                        takeProfit, "M5 ATR EMA stack BUY"))
           {
            g_buyArmed = false;
            Print("BUY opened; TP=", DoubleToString(takeProfit, _Digits),
                  " (", DoubleToString(InpTakeProfitAtrMultiplier, 1),
                  " ATR)");
           }
         else
            Print("BUY failed: ", g_trade.ResultRetcodeDescription());
        }
     }
   MaintainSellStop();
   DrawPanel(buySignal);
   RemoveIndicatorSubwindows();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      Print("backtest_open_orders.mq5 runs only in MT5 Strategy Tester.");
      return INIT_FAILED;
     }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) !=
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("EMA100 SELL STOP hedging requires a hedging account.");
      return INIT_FAILED;
     }
   if(InpAtrPeriod < 1 || InpAtrMultiplier <= 0.0 ||
      InpTakeProfitAtrMultiplier <= 0.0 || InpLots <= 0.0 ||
      InpSellStopOffsetPoints < 1)
      return INIT_PARAMETERS_INCORRECT;

   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   g_ema21Handle = iMA(_Symbol, PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE);
   g_ema50Handle = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(_Symbol, PERIOD_M5, 100, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_ema21Handle == INVALID_HANDLE ||
      g_ema50Handle == INVALID_HANDLE || g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create ATR/EMA handles. Error ", GetLastError());
      return INIT_FAILED;
     }
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   CreateTradeButtons(InpPanelY + (InpFontSize + 8) * 9);
   ProcessCompletedBar();
   MaintainSellStop();
   RemoveIndicatorSubwindows();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   DeleteHedgeOrders();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_ema21Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema21Handle);
   if(g_ema50Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema50Handle);
   if(g_ema100Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema100Handle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessPressedTradeButtons();
   ProcessCompletedBar();
   MaintainSellStop();
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
