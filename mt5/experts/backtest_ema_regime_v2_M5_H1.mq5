//+------------------------------------------------------------------+
//|                             backtest_ema_regime_v2_M5_H1.mq5           |
//| EMA alignment entries with numeric regime exits.                |
//+------------------------------------------------------------------+
#property copyright "Candlestick ML"
#property version   "2.10"
#property strict

#include <Trade/Trade.mqh>

input string          InpSignalFile = "XAUUSD_M5_backtest_signals.csv";
input string          InpH1SignalFile = "XAUUSD_H1_backtest_signals.csv";
input bool            InpUseH1SignalFilter = true;
input bool            InpUseCommonFiles = true;
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5;
input ENUM_TIMEFRAMES InpH1SignalTimeframe = PERIOD_H1;
input bool            InpTradeAfterCandleClose = true;
input int             InpCsvToServerOffsetHours = 0;

input double          InpLots = 0.01;
input int             InpAtrPeriod = 14;
input double          InpStopLossAtrMultiplier = 4.0;
input double          InpTakeProfitAtrMultiplier = 6.0;
input double          InpBreakEvenTriggerAtr = 3.0;
input double          InpBreakEvenOffsetAtr = 0.1;
input bool            InpUseAtrTrailingStop = false;
input double          InpTrailingStopAtrMultiplier = 3.0;
input int             InpDeviationPoints = 20;
input ulong           InpMagicNumber = 30072027;
input bool            InpCloseAtEndOfSignals = false;

CTrade g_trade;
int g_ema9Handle = INVALID_HANDLE;
int g_ema21Handle = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;
datetime g_times[];
int g_regimes[];
datetime g_h1Times[];
int g_h1Regimes[];
int g_signalCount = 0;
int g_h1SignalCount = 0;
int g_nextSignal = 0;
double g_entryAtr = 0.0;
bool g_endHandled = false;

int HeaderIndex(string &headers[], string wanted)
  {
   for(int i = 0; i < ArraySize(headers); i++)
     {
      string name = headers[i];
      StringTrimLeft(name);
      StringTrimRight(name);
      StringToLower(name);
      if(name == wanted)
         return i;
     }
   return -1;
  }

datetime ParseSignalTime(string value)
  {
   if(StringLen(value) >= 19)
      value = StringSubstr(value, 0, 19);
   StringReplace(value, "-", ".");
   datetime result = StringToTime(value);
   return result <= 0 ? 0 : result + InpCsvToServerOffsetHours * 3600;
  }

datetime EffectiveSignalTime(const int index)
  {
   datetime result = g_times[index];
   if(InpTradeAfterCandleClose)
      result += PeriodSeconds(InpSignalTimeframe);
   return result;
  }

bool LoadSignals()
  {
   int flags = FILE_READ | FILE_CSV | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;
   int handle = FileOpen(InpSignalFile, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot open ", InpSignalFile, ". Error ", GetLastError());
      return false;
     }

   string headers[];
   while(!FileIsEnding(handle))
     {
      int size = ArraySize(headers);
      ArrayResize(headers, size + 1);
      headers[size] = FileReadString(handle);
      if(FileIsLineEnding(handle))
         break;
     }
   int timeCol = HeaderIndex(headers, "time");
   int regimeCol = HeaderIndex(headers, "regime");
   if(timeCol < 0 || regimeCol < 0)
     {
      Print("Signal CSV must contain time and regime columns");
      FileClose(handle);
      return false;
     }

   while(!FileIsEnding(handle))
     {
      string fields[];
      ArrayResize(fields, ArraySize(headers));
      for(int column = 0; column < ArraySize(headers); column++)
         fields[column] = FileReadString(handle);
      if(fields[timeCol] == "" && FileIsEnding(handle))
         break;
      datetime signalTime = ParseSignalTime(fields[timeCol]);
      if(signalTime <= 0)
         continue;
      int size = g_signalCount + 1;
      ArrayResize(g_times, size);
      ArrayResize(g_regimes, size);
      g_times[g_signalCount] = signalTime;
      g_regimes[g_signalCount] = (int)StringToInteger(fields[regimeCol]);
      g_signalCount++;
     }
   FileClose(handle);
   Print("Loaded ", g_signalCount, " regime rows from ", InpSignalFile);
   return g_signalCount > 0;
  }

bool LoadH1Signals()
  {
   // The H1 confirmation file is explicitly read from Terminal Common Files.
   int handle = FileOpen(InpH1SignalFile,
                         FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot open H1 signal file ", InpH1SignalFile,
            " in Common Files. Error ", GetLastError());
      return false;
     }

   string headers[];
   while(!FileIsEnding(handle))
     {
      int size = ArraySize(headers);
      ArrayResize(headers, size + 1);
      headers[size] = FileReadString(handle);
      if(FileIsLineEnding(handle))
         break;
     }
   int timeCol = HeaderIndex(headers, "time");
   int regimeCol = HeaderIndex(headers, "regime");
   if(timeCol < 0 || regimeCol < 0)
     {
      Print("H1 signal CSV must contain time and regime columns");
      FileClose(handle);
      return false;
     }

   while(!FileIsEnding(handle))
     {
      string fields[];
      ArrayResize(fields, ArraySize(headers));
      for(int column = 0; column < ArraySize(headers); column++)
         fields[column] = FileReadString(handle);
      if(fields[timeCol] == "" && FileIsEnding(handle))
         break;
      datetime signalTime = ParseSignalTime(fields[timeCol]);
      if(signalTime <= 0)
         continue;
      int size = g_h1SignalCount + 1;
      ArrayResize(g_h1Times, size);
      ArrayResize(g_h1Regimes, size);
      g_h1Times[g_h1SignalCount] = signalTime;
      g_h1Regimes[g_h1SignalCount] = (int)StringToInteger(fields[regimeCol]);
      g_h1SignalCount++;
     }
   FileClose(handle);
   Print("Loaded ", g_h1SignalCount, " H1 regime rows from ", InpH1SignalFile);
   return g_h1SignalCount > 0;
  }

bool LatestCompletedH1Regime(const datetime decisionTime, int &regime)
  {
   // Use only an H1 candle whose close is known at the M5 decision time.
   int left = 0;
   int right = g_h1SignalCount - 1;
   int latest = -1;
   int h1Seconds = PeriodSeconds(InpH1SignalTimeframe);
   while(left <= right)
     {
      int middle = (left + right) / 2;
      datetime completedAt = g_h1Times[middle] + h1Seconds;
      if(completedAt <= decisionTime)
        {
         latest = middle;
         left = middle + 1;
        }
      else
         right = middle - 1;
     }
   if(latest < 0)
      return false;
   regime = g_h1Regimes[latest];
   return true;
  }

bool SelectManagedPosition(long &positionType)
  {
   if(!PositionSelect(_Symbol))
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      return false;
   positionType = PositionGetInteger(POSITION_TYPE);
   return true;
  }

bool HasOpenPositionForSymbol()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

bool CloseManagedPosition(string reason)
  {
   long type;
   if(!SelectManagedPosition(type))
      return true;
   if(!g_trade.PositionClose(_Symbol))
     {
      Print("Close failed: ", reason, ". ", g_trade.ResultRetcodeDescription());
      return false;
     }
   g_entryAtr = 0.0;
   Print("Position closed: ", reason);
   return true;
  }

bool SignalValues(const int index, double &priceClose, double &ema9,
                  double &ema21, double &atr)
  {
   int shift = iBarShift(_Symbol, InpSignalTimeframe, g_times[index], false);
   if(shift < 0)
      return false;
   double closeValues[], ema9Values[], ema21Values[], atrValues[];
   if(CopyClose(_Symbol, InpSignalTimeframe, shift, 1, closeValues) != 1 ||
      CopyBuffer(g_ema9Handle, 0, shift, 1, ema9Values) != 1 ||
      CopyBuffer(g_ema21Handle, 0, shift, 1, ema21Values) != 1 ||
      CopyBuffer(g_atrHandle, 0, shift, 1, atrValues) != 1)
      return false;
   priceClose = closeValues[0];
   ema9 = ema9Values[0];
   ema21 = ema21Values[0];
   atr = atrValues[0];
   return priceClose != EMPTY_VALUE && ema9 != EMPTY_VALUE &&
          ema21 != EMPTY_VALUE && atr != EMPTY_VALUE && atr > 0.0;
  }

bool OpenPosition(const int direction, const double atr)
  {
   if(HasOpenPositionForSymbol())
     {
      Print("Open skipped: a position already exists for ", _Symbol);
      return false;
     }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = direction > 0 ? ask : bid;
   double sl = NormalizeDouble(entry - direction * InpStopLossAtrMultiplier * atr, _Digits);
   double tp = NormalizeDouble(entry + direction * InpTakeProfitAtrMultiplier * atr, _Digits);
   bool opened = direction > 0
                 ? g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "EMA regime buy")
                 : g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "EMA regime sell");
   if(opened)
      g_entryAtr = atr;
   else
      Print("Open failed: ", g_trade.ResultRetcodeDescription());
   return opened;
  }

void ApplyBreakEven()
  {
   long type;
   if(!SelectManagedPosition(type) || g_entryAtr <= 0.0)
      return;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profit = type == POSITION_TYPE_BUY ? bid - entry : entry - ask;
   if(profit < InpBreakEvenTriggerAtr * g_entryAtr)
      return;
   double newSl = NormalizeDouble(type == POSITION_TYPE_BUY
                                  ? entry + InpBreakEvenOffsetAtr * g_entryAtr
                                  : entry - InpBreakEvenOffsetAtr * g_entryAtr, _Digits);
   double currentSl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   bool improves = type == POSITION_TYPE_BUY ? newSl > currentSl : newSl < currentSl;
   if(improves && !g_trade.PositionModify(_Symbol, newSl, tp))
      Print("Break-even update failed: ", g_trade.ResultRetcodeDescription());
  }

void ApplyAtrTrailingStop()
  {
   if(!InpUseAtrTrailingStop)
      return;
   long type;
   if(!SelectManagedPosition(type))
      return;
   double atrValues[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrValues) != 1 || atrValues[0] <= 0.0)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stops = (int)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                            SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   double minimumDistance = stops * point;
   double distance = InpTrailingStopAtrMultiplier * atrValues[0];
   double newSl = type == POSITION_TYPE_BUY
                  ? MathMin(bid - distance, bid - minimumDistance)
                  : MathMax(ask + distance, ask + minimumDistance);
   newSl = NormalizeDouble(newSl, _Digits);
   double currentSl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   bool improves = type == POSITION_TYPE_BUY ? newSl > currentSl : newSl < currentSl;
   if(improves && !g_trade.PositionModify(_Symbol, newSl, tp))
      Print("ATR trailing-stop update failed: ", g_trade.ResultRetcodeDescription());
  }

void ApplySignal(const int index)
  {
   double priceClose, ema9, ema21, atr;
   if(!SignalValues(index, priceClose, ema9, ema21, atr))
     {
      Print("Indicator values unavailable at ", TimeToString(g_times[index]));
      return;
     }

   int regime = g_regimes[index];
   long positionType;
   if(SelectManagedPosition(positionType))
     {
      bool closeBuy = positionType == POSITION_TYPE_BUY &&
                      (regime == 7 || regime == 2 ||
                       (ema9 < ema21 && priceClose < ema21));
      bool closeSell = positionType == POSITION_TYPE_SELL &&
                       (regime == 7 || regime == 0 ||
                        (ema9 > ema21 && priceClose > ema21));
      if(closeBuy || closeSell)
         CloseManagedPosition(closeBuy ? "buy exit condition" : "sell exit condition");
      return;
     }

   bool buySignal = priceClose > ema9 && ema9 > ema21 &&
                    (regime == 5 || regime == 0);
   bool sellSignal = priceClose < ema9 && ema9 < ema21 &&
                     (regime == 5 || regime == 2);
   if(!buySignal && !sellSignal)
      return;
   bool h1BuyAllowed = true;
   bool h1SellAllowed = true;
   if(InpUseH1SignalFilter)
     {
      int h1Regime = -1;
      if(!LatestCompletedH1Regime(EffectiveSignalTime(index), h1Regime))
        {
         Print("Entry skipped: no completed H1 regime is available at ",
               TimeToString(EffectiveSignalTime(index)));
         return;
        }
      h1BuyAllowed = h1Regime == 0 || h1Regime == 5;
      h1SellAllowed = h1Regime == 2 || h1Regime == 5;
     }
   if(buySignal && h1BuyAllowed)
      OpenPosition(1, atr);
   else if(sellSignal && h1SellAllowed)
      OpenPosition(-1, atr);
  }

int OnInit()
  {
   if(InpLots <= 0.0 || InpAtrPeriod <= 0 ||
      InpStopLossAtrMultiplier <= 0.0 || InpTakeProfitAtrMultiplier <= 0.0 ||
      InpBreakEvenTriggerAtr <= 0.0 || InpBreakEvenOffsetAtr < 0.0 ||
      InpTrailingStopAtrMultiplier <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_ema9Handle = iMA(_Symbol, InpSignalTimeframe, 9, 0, MODE_EMA, PRICE_CLOSE);
   g_ema21Handle = iMA(_Symbol, InpSignalTimeframe, 21, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   if(g_ema9Handle == INVALID_HANDLE || g_ema21Handle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE)
     {
      Print("Cannot create indicator handles. Error ", GetLastError());
      return INIT_FAILED;
     }
   if(!LoadSignals() || (InpUseH1SignalFilter && !LoadH1Signals()))
      return INIT_FAILED;
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_ema9Handle != INVALID_HANDLE) IndicatorRelease(g_ema9Handle);
   if(g_ema21Handle != INVALID_HANDLE) IndicatorRelease(g_ema21Handle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
  }

void OnTick()
  {
   ApplyBreakEven();
   ApplyAtrTrailingStop();
   datetime now = TimeCurrent();
   int latestDue = -1;
   while(g_nextSignal < g_signalCount && EffectiveSignalTime(g_nextSignal) <= now)
     {
      latestDue = g_nextSignal;
      g_nextSignal++;
     }
   if(latestDue >= 0)
      ApplySignal(latestDue);
   if(InpCloseAtEndOfSignals && !g_endHandled && g_nextSignal >= g_signalCount)
     {
      datetime finalClose = EffectiveSignalTime(g_signalCount - 1) +
                            PeriodSeconds(InpSignalTimeframe);
      if(now >= finalClose)
        {
         CloseManagedPosition("end of signal file");
         g_endHandled = true;
        }
     }
  }
//+------------------------------------------------------------------+
