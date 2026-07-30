//+------------------------------------------------------------------+
//|                              regime_change_strategy.mq5          |
//| MT5 implementation of examine_regime_change_strategy.py.        |
//+------------------------------------------------------------------+
#property copyright "Candlestick ML"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string          InpSignalFile = "XAUUSD_M5_backtest_signals.csv";
input bool            InpUseCommonFiles = true;
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5;
input int             InpCsvToServerOffsetHours = 0;
input double          InpLots = 0.01;
input int             InpHistoryBars = 12;
input int             InpRequiredRegimeBars = 8;
input int             InpAtrPeriod = 14;
input double          InpStopLossAtr = 1.5;
input double          InpRewardRisk = 2.0;
input int             InpDeviationPoints = 20;
input ulong           InpMagicNumber = 30072026;
input bool            InpCloseAtEndOfSignals = false;

CTrade g_trade;
datetime g_times[];
double   g_closes[];
int      g_regimes[];
int      g_signalCount = 0;
int      g_nextSignal = 0;
bool     g_endHandled = false;

int HeaderIndex(string &headers[], string wanted)
  {
   for(int i = 0; i < ArraySize(headers); i++)
     {
      string value = headers[i];
      StringTrimLeft(value);
      StringTrimRight(value);
      StringToLower(value);
      if(value == wanted)
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
   // Python evaluates each signal at the end of its candle.
   return g_times[index] + PeriodSeconds(InpSignalTimeframe);
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
   int closeCol = HeaderIndex(headers, "close");
   int regimeCol = HeaderIndex(headers, "regime");
   if(timeCol < 0 || closeCol < 0 || regimeCol < 0)
     {
      Print("Signal CSV must contain time, close, and regime columns");
      FileClose(handle);
      return false;
     }

   while(!FileIsEnding(handle))
     {
      string fields[];
      ArrayResize(fields, ArraySize(headers));
      for(int col = 0; col < ArraySize(headers); col++)
         fields[col] = FileReadString(handle);
      if(fields[timeCol] == "" && FileIsEnding(handle))
         break;
      datetime signalTime = ParseSignalTime(fields[timeCol]);
      if(signalTime <= 0)
         continue;
      int size = g_signalCount + 1;
      ArrayResize(g_times, size);
      ArrayResize(g_closes, size);
      ArrayResize(g_regimes, size);
      g_times[g_signalCount] = signalTime;
      g_closes[g_signalCount] = StringToDouble(fields[closeCol]);
      g_regimes[g_signalCount] = (int)StringToInteger(fields[regimeCol]);
      g_signalCount++;
     }
   FileClose(handle);
   Print("Loaded ", g_signalCount, " regime rows from ", InpSignalFile);
   return g_signalCount > 0;
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

void CloseManagedPosition(string reason)
  {
   long type;
   if(SelectManagedPosition(type))
     {
      if(!g_trade.PositionClose(_Symbol))
         Print("Close failed (", reason, "): ", g_trade.ResultRetcodeDescription());
      else
         Print("Position closed: ", reason);
     }
  }

bool IsRegimeIn(const int regime, const int a, const int b)
  {
   return regime == a || regime == b;
  }

double PriorAtr(const int index)
  {
   // Close-only ATR proxy used by the Python script: the mean of the prior
   // 14 absolute close-to-close changes, excluding the entry candle.
   if(index < InpAtrPeriod + 1)
      return 0.0;
   double total = 0.0;
   for(int i = index - InpAtrPeriod; i < index; i++)
      total += MathAbs(g_closes[i] - g_closes[i - 1]);
   return total / InpAtrPeriod;
  }

bool EntrySignal(const int index, int &direction, double &atr)
  {
   direction = 0;
   if(index < InpHistoryBars)
      return false;
   int bullish = 0, bearish = 0, noTrade = 0;
   double breakoutHigh = g_closes[index - InpHistoryBars];
   double breakoutLow = breakoutHigh;
   for(int i = index - InpHistoryBars; i < index; i++)
     {
      int regime = g_regimes[i];
      if(IsRegimeIn(regime, 0, 1)) bullish++;
      if(IsRegimeIn(regime, 2, 5)) bearish++;
      if(regime == 4 || regime == 6 || regime == 7) noTrade++;
      breakoutHigh = MathMax(breakoutHigh, g_closes[i]);
      breakoutLow = MathMin(breakoutLow, g_closes[i]);
     }
   atr = PriorAtr(index);
   if(atr <= 0.0 || noTrade >= 8)
      return false;
   bool buy = g_regimes[index] == 0 && bullish >= InpRequiredRegimeBars &&
              g_closes[index] > breakoutHigh && g_regimes[index - 1] != 5;
   bool sell = g_regimes[index] == 2 && bearish >= InpRequiredRegimeBars &&
               g_closes[index] < breakoutLow;
   direction = buy ? 1 : (sell ? -1 : 0);
   return direction != 0;
  }

void OpenPosition(const int direction, const double atr)
  {
   double price = direction > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk = InpStopLossAtr * atr;
   double sl = NormalizeDouble(price - direction * risk, _Digits);
   double tp = NormalizeDouble(price + direction * InpRewardRisk * risk, _Digits);
   bool sent = direction > 0
               ? g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "regime breakout")
               : g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "regime breakout");
   if(!sent)
      Print("Entry failed: ", g_trade.ResultRetcodeDescription());
  }

void ApplyBreakEven()
  {
   long type;
   if(!SelectManagedPosition(type))
      return;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   if(sl == 0.0 || tp == 0.0)
      return;
   double initialRisk = MathAbs(tp - entry) / InpRewardRisk;
   double price = type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool triggered = type == POSITION_TYPE_BUY ? price >= entry + initialRisk
                                               : price <= entry - initialRisk;
   bool improves = type == POSITION_TYPE_BUY ? sl < entry : sl > entry;
   if(triggered && improves && !g_trade.PositionModify(_Symbol, NormalizeDouble(entry, _Digits), tp))
      Print("Break-even update failed: ", g_trade.ResultRetcodeDescription());
  }

void ApplySignal(const int index)
  {
   long positionType;
   bool hasPosition = SelectManagedPosition(positionType);
   if(hasPosition)
     {
      bool exitBuy = positionType == POSITION_TYPE_BUY &&
                     (g_regimes[index] == 2 || g_regimes[index] == 3 ||
                      g_regimes[index] == 4 || g_regimes[index] == 7);
      bool exitSell = positionType == POSITION_TYPE_SELL &&
                      (g_regimes[index] == 0 || g_regimes[index] == 1 ||
                       g_regimes[index] == 4 || g_regimes[index] == 7);
      if(exitBuy || exitSell)
        {
         CloseManagedPosition("directional regime exit");
         hasPosition = SelectManagedPosition(positionType);
        }
     }

   // Like the Python loop, a regime exit may be followed by a new entry on
   // the same completed signal candle.
   if(!hasPosition)
     {
      int direction;
      double atr;
      if(EntrySignal(index, direction, atr))
         OpenPosition(direction, atr);
     }
  }

int OnInit()
  {
   if(InpLots <= 0.0 || InpHistoryBars <= 0 || InpRequiredRegimeBars < 0 ||
      InpRequiredRegimeBars > InpHistoryBars || InpAtrPeriod <= 0 ||
      InpStopLossAtr <= 0.0 || InpRewardRisk <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   return LoadSignals() ? INIT_SUCCEEDED : INIT_FAILED;
  }

void OnTick()
  {
   ApplyBreakEven();
   datetime now = TimeCurrent();
   // Process every due row; history-dependent logic must not skip CSV rows.
   while(g_nextSignal < g_signalCount && EffectiveSignalTime(g_nextSignal) <= now)
     {
      ApplySignal(g_nextSignal);
      g_nextSignal++;
     }
   if(InpCloseAtEndOfSignals && !g_endHandled && g_nextSignal >= g_signalCount)
     {
      CloseManagedPosition("end of signal file");
      g_endHandled = true;
     }
  }
//+------------------------------------------------------------------+
