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

#define PREFIX "OPEN_ORDERS_"

CTrade g_trade;
string g_selectedSymbol = "";
int g_ema21Handle = INVALID_HANDLE;
int g_ema50Handle = INVALID_HANDLE;
int g_ema100Handle = INVALID_HANDLE;
datetime g_lastEmaBar = 0;

//+------------------------------------------------------------------+
void DrawEma(const int handle, const string tag, const color lineColor)
  {
   const int requested = 300;
   datetime times[];
   double values[];
   int count = MathMin(CopyTime(g_selectedSymbol, PERIOD_CURRENT, 0,
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
   datetime currentBar = iTime(g_selectedSymbol, PERIOD_CURRENT, 0);
   if(currentBar <= 0 || currentBar == g_lastEmaBar)
      return;
   g_lastEmaBar = currentBar;
   DrawEma(g_ema21Handle, "21", InpEma21Color);
   DrawEma(g_ema50Handle, "50", InpEma50Color);
   DrawEma(g_ema100Handle, "100", InpEma100Color);
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
   SetBackground(PREFIX + "bg", x - 8, y - 8, 440,
                 lineHeight * 9 + 14);

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
   if(InpRefreshSeconds < 1 || g_selectedSymbol == "")
      return INIT_PARAMETERS_INCORRECT;
   if(!SymbolSelect(g_selectedSymbol, true))
     {
      Print("Unable to select symbol ", g_selectedSymbol,
            ". Error ", GetLastError());
      return INIT_FAILED;
     }

   g_ema21Handle = iMA(g_selectedSymbol, PERIOD_CURRENT, 21,
                       0, MODE_EMA, PRICE_CLOSE);
   g_ema50Handle = iMA(g_selectedSymbol, PERIOD_CURRENT, 50,
                       0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(g_selectedSymbol, PERIOD_CURRENT, 100,
                        0, MODE_EMA, PRICE_CLOSE);
   if(g_ema21Handle == INVALID_HANDLE || g_ema50Handle == INVALID_HANDLE ||
      g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create EMA handles for ", g_selectedSymbol,
            ". Error ", GetLastError());
      return INIT_FAILED;
     }

   EventSetTimer(InpRefreshSeconds);
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
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   MonitorSelectedSymbol();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
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
