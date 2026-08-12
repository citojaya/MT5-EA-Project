//+------------------------------------------------------------------+
//|                                                   atr_ema.mq5    |
//| EMA-filtered 3x ATR trailing-stop strategy.                      |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5;
input int    InpAtrPeriod = 14;
input double InpAtrMultiplier = 3.0;
input int    InpEma21Period = 21;
input int    InpEma50Period = 50;
input double InpLots = 0.01;
input double InpAdditionalEntryGapAtr = 3.0;
input int    InpMaximumEntries = 5;
input int    InpDeviationPoints = 20;
input ulong  InpMagicNumber = 33333333;
input bool   InpPlotIndicators = true;
input color  InpAtrLineColor = clrRed;
input color  InpEma21Color = clrDeepSkyBlue;
input color  InpEma50Color = clrOrange;

#define ATR_EMA_PREFIX "ATR_EMA_EA_"

enum TradeDirection
  {
   DIRECTION_NONE = 0,
   DIRECTION_BUY = 1,
   DIRECTION_SELL = -1
  };

struct SignalState
  {
   datetime barTime;
   double close;
   double previousClose;
   double ema21;
   double ema50;
   double atr;
   double atrStop;
   double previousAtrStop;
  };

CTrade g_trade;
int g_atrHandle = INVALID_HANDLE;
int g_ema21Handle = INVALID_HANDLE;
int g_ema50Handle = INVALID_HANDLE;
datetime g_lastProcessedBar = 0;
bool g_isTester = false;
double g_lastEntryPrice = 0.0;

//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return volume;
   volume = MathMax(minimum, MathMin(maximum, volume));
   return NormalizeDouble(MathFloor(volume / step + 1e-9) * step, 8);
  }

//+------------------------------------------------------------------+
bool LoadSeries(MqlRates &rates[], double &atr[], double &ema21[],
                double &ema50[], double &stops[], int &count)
  {
   const int requested = 600;
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(ema21, true);
   ArraySetAsSeries(ema50, true);

   int ratesCount = CopyRates(_Symbol, InpSignalTimeframe, 0, requested, rates);
   int atrCount = CopyBuffer(g_atrHandle, 0, 0, requested, atr);
   int ema21Count = CopyBuffer(g_ema21Handle, 0, 0, requested, ema21);
   int ema50Count = CopyBuffer(g_ema50Handle, 0, 0, requested, ema50);
   count = MathMin(MathMin(ratesCount, atrCount),
                   MathMin(ema21Count, ema50Count));
   if(count < MathMax(InpEma50Period + 5, InpAtrPeriod + 5))
      return false;

   ArrayResize(stops, count);
   ArraySetAsSeries(stops, true);
   bool seeded = false;
   for(int index = count - 1; index >= 0; index--)
     {
      if(atr[index] == EMPTY_VALUE || atr[index] <= 0.0)
        {
         stops[index] = EMPTY_VALUE;
         continue;
        }

      double loss = InpAtrMultiplier * atr[index];
      if(!seeded)
        {
         stops[index] = rates[index].close - loss;
         seeded = true;
         continue;
        }

      double previousStop = stops[index + 1];
      if(previousStop == EMPTY_VALUE)
        {
         stops[index] = rates[index].close - loss;
         continue;
        }

      if(rates[index].close > previousStop &&
         rates[index + 1].close > previousStop)
         stops[index] = MathMax(previousStop, rates[index].close - loss);
      else if(rates[index].close < previousStop &&
              rates[index + 1].close < previousStop)
         stops[index] = MathMin(previousStop, rates[index].close + loss);
      else
         stops[index] = rates[index].close > previousStop
                        ? rates[index].close - loss
                        : rates[index].close + loss;
     }
   return stops[1] != EMPTY_VALUE && stops[2] != EMPTY_VALUE;
  }

//+------------------------------------------------------------------+
void DrawSeries(const MqlRates &rates[], const double &values[], int count,
                const string tag, color lineColor, int width)
  {
   const int plotted = 300;
   int oldest = MathMin(count - 1, plotted);
   for(int index = oldest; index >= 1; index--)
     {
      if(values[index] == EMPTY_VALUE || values[index - 1] == EMPTY_VALUE)
         continue;
      string name = ATR_EMA_PREFIX + tag + "_" + IntegerToString(index);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      rates[index].time, values[index],
                      rates[index - 1].time, values[index - 1]);
      else
        {
         ObjectMove(0, name, 0, rates[index].time, values[index]);
         ObjectMove(0, name, 1, rates[index - 1].time, values[index - 1]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
bool CalculateSignal(SignalState &state)
  {
   MqlRates rates[];
   double atr[], ema21[], ema50[], stops[];
   int count;
   if(!LoadSeries(rates, atr, ema21, ema50, stops, count))
      return false;

   state.barTime = rates[1].time;
   state.close = rates[1].close;
   state.previousClose = rates[2].close;
   state.ema21 = ema21[1];
   state.ema50 = ema50[1];
   state.atr = atr[1];
   state.atrStop = stops[1];
   state.previousAtrStop = stops[2];

   if(InpPlotIndicators && !g_isTester)
     {
      DrawSeries(rates, stops, count, "ATR_STOP", InpAtrLineColor, 2);
      DrawSeries(rates, ema21, count, "EMA21", InpEma21Color, 1);
      DrawSeries(rates, ema50, count, "EMA50", InpEma50Color, 1);
      ChartRedraw();
     }
   return true;
  }

//+------------------------------------------------------------------+
bool SelectManagedPosition(long &positionType)
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         return false;
      positionType = PositionGetInteger(POSITION_TYPE);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool HasAnyPositionForSymbol()
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
int ManagedEntryCount(long requiredType)
  {
   double totalVolume = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         PositionGetInteger(POSITION_TYPE) != requiredType)
         continue;
      totalVolume += PositionGetDouble(POSITION_VOLUME);
     }
   double unitVolume = NormalizeVolume(InpLots);
   return unitVolume > 0.0
          ? (int)MathCeil(totalVolume / unitVolume - 1e-9) : 0;
  }

//+------------------------------------------------------------------+
double LatestEntryDealPrice(TradeDirection direction)
  {
   if(!HistorySelect(0, TimeCurrent()))
      return 0.0;
   long requiredDealType = direction == DIRECTION_BUY ? DEAL_TYPE_BUY
                                                       : DEAL_TYPE_SELL;
   for(int index = HistoryDealsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = HistoryDealGetTicket(index);
      if(ticket <= 0 ||
         HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber ||
         HistoryDealGetInteger(ticket, DEAL_TYPE) != requiredDealType ||
         HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      return HistoryDealGetDouble(ticket, DEAL_PRICE);
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
bool CloseManagedPositions()
  {
   bool allClosed = true;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(!g_trade.PositionClose(ticket))
        {
         Print("ATR/EMA close failed for #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
         allClosed = false;
        }
     }
   if(allClosed)
      g_lastEntryPrice = 0.0;
   return allClosed;
  }

//+------------------------------------------------------------------+
bool OpenPosition(TradeDirection direction, bool additional = false)
  {
   if(!additional && HasAnyPositionForSymbol())
      return false;
   string comment = additional
                    ? (direction == DIRECTION_BUY ? "ATR EMA ADD BUY"
                                                  : "ATR EMA ADD SELL")
                    : (direction == DIRECTION_BUY ? "ATR EMA BUY"
                                                  : "ATR EMA SELL");
   bool opened = direction == DIRECTION_BUY
                 ? g_trade.Buy(NormalizeVolume(InpLots), _Symbol, 0.0,
                               0.0, 0.0, comment)
                 : g_trade.Sell(NormalizeVolume(InpLots), _Symbol, 0.0,
                                0.0, 0.0, comment);
   if(!opened)
      Print("Order failed: ", g_trade.ResultRetcodeDescription());
   else
     {
      double resultPrice = g_trade.ResultPrice();
      g_lastEntryPrice = resultPrice > 0.0
                         ? resultPrice
                         : direction == DIRECTION_BUY
                           ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
     }
   return opened;
  }

//+------------------------------------------------------------------+
void ProcessSignal()
  {
   datetime closedBar = iTime(_Symbol, InpSignalTimeframe, 1);
   if(closedBar <= 0 || closedBar <= g_lastProcessedBar)
      return;

   SignalState state;
   if(!CalculateSignal(state))
      return;
   g_lastProcessedBar = state.barTime;

   bool aboveAtr = state.close > state.atrStop;
   bool belowAtr = state.close < state.atrStop;
   bool buySignal = aboveAtr && state.close > state.ema21 &&
                    state.close > state.ema50;
   bool sellSignal = belowAtr && state.close < state.ema21 &&
                     state.close < state.ema50;

   long positionType;
   if(SelectManagedPosition(positionType))
     {
      bool exitBuy = positionType == POSITION_TYPE_BUY &&
                     belowAtr && state.close < state.ema21;
      bool exitSell = positionType == POSITION_TYPE_SELL &&
                      aboveAtr && state.close > state.ema21;
      if(exitBuy || exitSell)
        {
         if(!CloseManagedPositions())
            return;
        }
      else
        {
         TradeDirection direction = positionType == POSITION_TYPE_BUY
                                    ? DIRECTION_BUY : DIRECTION_SELL;
         bool directionSignal = direction == DIRECTION_BUY
                                ? buySignal : sellSignal;
         if(!directionSignal ||
            ManagedEntryCount(positionType) >= InpMaximumEntries)
            return;

         if(g_lastEntryPrice <= 0.0)
            g_lastEntryPrice = LatestEntryDealPrice(direction);
         if(g_lastEntryPrice <= 0.0)
            return;

         double currentPrice = direction == DIRECTION_BUY
                               ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         bool gapPassed = direction == DIRECTION_BUY
                          ? currentPrice - g_lastEntryPrice >
                            InpAdditionalEntryGapAtr * state.atr
                          : g_lastEntryPrice - currentPrice >
                            InpAdditionalEntryGapAtr * state.atr;
         if(gapPassed)
            OpenPosition(direction, true);
         return;
        }
     }
   else if(HasAnyPositionForSymbol())
      return;

   if(buySignal)
      OpenPosition(DIRECTION_BUY);
   else if(sellSignal)
      OpenPosition(DIRECTION_SELL);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpAtrPeriod < 1 || InpAtrMultiplier <= 0.0 ||
      InpEma21Period < 1 || InpEma50Period <= InpEma21Period ||
      InpLots <= 0.0 || InpAdditionalEntryGapAtr <= 0.0 ||
      InpMaximumEntries < 1)
      return INIT_PARAMETERS_INCORRECT;

   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   g_ema21Handle = iMA(_Symbol, InpSignalTimeframe, InpEma21Period,
                       0, MODE_EMA, PRICE_CLOSE);
   g_ema50Handle = iMA(_Symbol, InpSignalTimeframe, InpEma50Period,
                       0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_ema21Handle == INVALID_HANDLE ||
      g_ema50Handle == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   ProcessSignal();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_ema21Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema21Handle);
   if(g_ema50Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema50Handle);
   ObjectsDeleteAll(0, ATR_EMA_PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProcessSignal();
  }
//+------------------------------------------------------------------+
