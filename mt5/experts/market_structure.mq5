//+------------------------------------------------------------------+
//|                                           live_ema_regime.mq5    |
//| Market-structure EA: HH/HL, LH/LL, or sideways.                 |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

#ifndef USE_REGIME_CSV_DEFAULT
#define USE_REGIME_CSV_DEFAULT true
#endif

input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5; // Structure timeframe
input int    InpPivotLeft = 2;                        // Older bars around a pivot
input int    InpPivotRight = 2;                       // Newer closed bars confirming a pivot
input int    InpPivotLookback = 300;                  // Bars searched for swing points
input int    InpMaximumSwingAgeBars = 150;            // Maximum age of latest high/low
input int    InpBreakoutLookback = 20;                // Completed candles defining the range
input int    InpAtrPeriod = 14;                       // ATR period
input double InpBreakoutBufferAtr = 0.10;             // Break distance beyond range in ATR
input int    InpAdxPeriod = 14;                       // ADX period
input double InpSidewaysAdx = 20.0;                   // Below this is always sideways
input double InpMinimumTrendAdx = 20.0;               // Minimum ADX required to trade
input bool   InpRequireConsolidation = false;         // Apply optional pre-breakout range filter
input double InpMaximumRangeAtr = 3.0;                // Maximum range width in ATR
input double InpMaximumPreBreakoutAdx = 25.0;         // Maximum ADX before breakout
input int    InpFastEmaPeriod = 21;                   // Fast EMA period
input int    InpSlowEmaPeriod = 50;                   // Slow EMA period
input bool   InpUseEma21 = false;                     // Use EMA(21) for trading
input bool   InpUseEma50 = false;                     // Use EMA(50) for trading
input bool   InpUseEma100 = false;                    // Use EMA(100) for trading
input color  InpEma21Color = clrDeepSkyBlue;          // EMA(21) chart colour
input color  InpEma50Color = clrOrange;               // EMA(50) chart colour
input color  InpEma100Color = clrMagenta;             // EMA(100) chart colour
input bool   InpUseRegimeCsv = USE_REGIME_CSV_DEFAULT;// Require CSV/TXT regime confirmation
input string InpRegimeCsvFile = "";                  // Backtest CSV in Common Files (default=false only)
input int    InpCsvTimeOffsetHours = 0;               // UTC source time -> broker server time
input double InpLots = 0.01;                          // Fixed trade volume
input double InpStopLossAtrMultiplier = 4.0;          // Initial stop distance
input double InpTakeProfitAtrMultiplier = 6.0;        // Initial target distance
input int    InpTradeStartHour = 1;                   // Server hour, inclusive
input int    InpTradeEndHour = 22;                    // Server hour, exclusive
input bool   InpCloseOnEmaFlip = true;                // Close when EMA50/EMA100 direction flips
input int    InpDeviationPoints = 20;                 // Maximum order deviation
input ulong  InpMagicNumber = 22222222;               // EA magic number
input bool             InpShowPanel = true;           // Show status panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int              InpXOffset = 15;
input int              InpYOffset = 15;
input int              InpFontSize = 10;
input string           InpFontName = "Consolas";

#define PREFIX "STRUCTURE_EA_"

enum TrendDirection
  {
   TREND_SIDEWAYS = 0,
   TREND_UP = 1,
   TREND_DOWN = -1,
   TREND_TRANSITION = 2
  };

enum SwingType
  {
   SWING_LOW = -1,
   SWING_HIGH = 1
  };

struct SwingPoint
  {
   SwingType type;
   datetime time;
   double price;
   int shift;
  };

struct StructureState
  {
   TrendDirection trend;
   datetime barTime;
   datetime latestHighTime;
   datetime previousHighTime;
   datetime latestLowTime;
   datetime previousLowTime;
   int latestHighShift;
   int latestLowShift;
   double latestHigh;
   double previousHigh;
   double latestLow;
   double previousLow;
   double atr;
   double adx;
   double fastEma;
   double slowEma;
   double ema100;
   double close;
   double upperLimit;
   double lowerLimit;
   double previousAdx;
   double rangeWidth;
   bool consolidationPassed;
   double buffer;
   string detail;
  };

struct CsvRegimeSignal
  {
   datetime time;
   int regime;
   string name;
   double confidence;
  };

CTrade   g_trade;
int      g_atrHandle = INVALID_HANDLE;
int      g_adxHandle = INVALID_HANDLE;
int      g_fastEmaHandle = INVALID_HANDLE;
int      g_slowEmaHandle = INVALID_HANDLE;
int      g_ema100Handle = INVALID_HANDLE;
int      g_chartEma21Handle = INVALID_HANDLE;
int      g_chartEma50Handle = INVALID_HANDLE;
int      g_chartEma100Handle = INVALID_HANDLE;
datetime g_lastProcessedBar = 0;
long     g_lastTesterBarBucket = -1;
int      g_signalPeriodSeconds = 0;
bool     g_isTester = false;
double   g_entryAtr = 0.0;
StructureState g_state;
bool     g_stateAvailable = false;
CsvRegimeSignal g_csvSignals[];
bool     g_csvSignalAvailable = false;
int      g_currentCsvRegime = -1;
string   g_currentCsvName = "";
double   g_currentCsvConfidence = 0.0;
string   g_regimeCsvFile = "";
string   g_liveSignalFile = "";

//+------------------------------------------------------------------+
bool CreateChartEma(const int period, int &handle)
  {
   handle = iMA(_Symbol, PERIOD_CURRENT, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
     {
      Print("Unable to create chart EMA(", period, ") handle. Error ",
            GetLastError());
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
void DrawEma(const int handle, const string tag, const color lineColor)
  {
   const int requested = 300;
   datetime times[];
   double values[];
   int count = MathMin(CopyTime(_Symbol, PERIOD_CURRENT, 0, requested, times),
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
   if(g_isTester)
      return;
   DrawEma(g_chartEma50Handle, "50", InpEma50Color);
   DrawEma(g_chartEma100Handle, "100", InpEma100Color);
  }

//+------------------------------------------------------------------+
bool EmaFilterPassed(const StructureState &state)
  {
   if(state.trend == TREND_UP)
      return state.close > state.slowEma;
   if(state.trend == TREND_DOWN)
      return state.close < state.slowEma;
   return false;
  }

//+------------------------------------------------------------------+
string RegimeFileSymbol()
  {
   string fileSymbol = Symbol();
   string lowerSymbol = fileSymbol;
   StringToLower(lowerSymbol);
   int length = StringLen(fileSymbol);
   if(length >= 2 && StringSubstr(lowerSymbol, length - 2) == ".a")
      fileSymbol = StringSubstr(fileSymbol, 0, length - 2);
   return fileSymbol;
  }

//+------------------------------------------------------------------+
string ResolveRegimeFile()
  {
   if(USE_REGIME_CSV_DEFAULT)
      return "latest_regime_" + RegimeFileSymbol() + "_M5.txt";
   return InpRegimeCsvFile;
  }

//+------------------------------------------------------------------+
bool WriteLiveSignal(datetime signalTime, TrendDirection signal)
  {
   int handle = FileOpen(g_liveSignalFile,
                         FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI |
                         FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot write terminal MQL5\\Files live signal ",
            g_liveSignalFile, ". Error ", GetLastError());
      return false;
     }

   ulong fileSize = FileSize(handle);
   FileSeek(handle, 0, SEEK_END);
   if(fileSize == 0)
      FileWrite(handle, "time", "signal");
   FileWrite(handle,
             TimeToString(signalTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
             IntegerToString((int)signal));
   FileFlush(handle);
   FileClose(handle);
   return true;
  }

//+------------------------------------------------------------------+
string CanonicalSymbol(string value)
  {
   StringToLower(value);
   int length = StringLen(value);
   if(length >= 2 && StringSubstr(value, length - 2) == ".a")
      value = StringSubstr(value, 0, length - 2);
   return value;
  }

//+------------------------------------------------------------------+
datetime ParseCsvTime(string value)
  {
   if(StringLen(value) > 19)
      value = StringSubstr(value, 0, 19);
   StringReplace(value, "-", ".");
   datetime parsed = StringToTime(value);
   if(parsed > 0)
      parsed += InpCsvTimeOffsetHours * 3600;
   return parsed;
  }

//+------------------------------------------------------------------+
bool IsLiveRegimeTextFile()
  {
   return USE_REGIME_CSV_DEFAULT;
  }

//+------------------------------------------------------------------+
bool ReadLiveRegimeText(CsvRegimeSignal &signal)
  {
   int handle = FileOpen(g_regimeCsvFile,
                         FILE_READ | FILE_TXT | FILE_ANSI |
                         FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot open terminal MQL5\\Files live regime ", g_regimeCsvFile,
            ". Error ", GetLastError());
      return false;
     }

   string timeText = "";
   string symbolText = "";
   string timeframeText = "";
   string regimeText = "";
   string regimeName = "";
   string confidenceText = "";
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      int separator = StringFind(line, "=");
      if(separator < 1)
         continue;

      string key = StringSubstr(line, 0, separator);
      string value = StringSubstr(line, separator + 1);
      StringTrimLeft(key);
      StringTrimRight(key);
      StringToLower(key);
      StringTrimLeft(value);
      StringTrimRight(value);

      if(key == "time") timeText = value;
      else if(key == "symbol") symbolText = value;
      else if(key == "timeframe") timeframeText = value;
      else if(key == "regime") regimeText = value;
      else if(key == "regime_name") regimeName = value;
      else if(key == "confidence") confidenceText = value;
     }
   FileClose(handle);

   signal.time = ParseCsvTime(timeText);
   signal.regime = (int)StringToInteger(regimeText);
   signal.name = regimeName;
   signal.confidence = StringToDouble(confidenceText);
   if(signal.time <= 0 || regimeText == "" || regimeName == "" ||
      confidenceText == "" || CanonicalSymbol(symbolText) != CanonicalSymbol(_Symbol) ||
      timeframeText != TimeframeText())
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool LoadRegimeCsv()
  {
   ArrayResize(g_csvSignals, 0);
   int handle = FileOpen(g_regimeCsvFile,
                         FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot open Common Files CSV ", g_regimeCsvFile,
            ". Error ", GetLastError());
      return false;
     }

   // time,symbol,timeframe,close,regime,regime_name,confidence,updated_utc
   for(int column = 0; column < 8 && !FileIsEnding(handle); column++)
      FileReadString(handle);

   string wantedSymbol = CanonicalSymbol(_Symbol);
   string wantedTimeframe = TimeframeText();
   while(!FileIsEnding(handle))
     {
      string timeText = FileReadString(handle);
      string symbolText = FileReadString(handle);
      string timeframeText = FileReadString(handle);
      FileReadString(handle); // close
      string regimeText = FileReadString(handle);
      string regimeName = FileReadString(handle);
      string confidenceText = FileReadString(handle);
      FileReadString(handle); // updated_utc

      datetime signalTime = ParseCsvTime(timeText);
      if(signalTime <= 0 || CanonicalSymbol(symbolText) != wantedSymbol ||
         timeframeText != wantedTimeframe)
         continue;

      int index = ArraySize(g_csvSignals);
      ArrayResize(g_csvSignals, index + 1, 4096);
      g_csvSignals[index].time = signalTime;
      g_csvSignals[index].regime = (int)StringToInteger(regimeText);
      g_csvSignals[index].name = regimeName;
      g_csvSignals[index].confidence = StringToDouble(confidenceText);
     }
   FileClose(handle);

   int count = ArraySize(g_csvSignals);
   Print("Loaded ", count, " regime signals from Common Files\\",
         g_regimeCsvFile, "; time offset=", InpCsvTimeOffsetHours, "h");
   return count > 0;
  }

//+------------------------------------------------------------------+
bool FindRegimeSignal(datetime barTime, CsvRegimeSignal &signal)
  {
   int left = 0;
   int right = ArraySize(g_csvSignals) - 1;
   while(left <= right)
     {
      int middle = left + (right - left) / 2;
      if(g_csvSignals[middle].time == barTime)
        {
         signal = g_csvSignals[middle];
         return true;
        }
      if(g_csvSignals[middle].time < barTime)
         left = middle + 1;
      else
         right = middle - 1;
     }
   return false;
  }

//+------------------------------------------------------------------+
void UpdateCurrentCsvSignal(datetime barTime)
  {
   g_csvSignalAvailable = false;
   g_currentCsvRegime = -1;
   g_currentCsvName = "";
   g_currentCsvConfidence = 0.0;
   if(!InpUseRegimeCsv)
      return;

   CsvRegimeSignal signal;
   bool found = IsLiveRegimeTextFile()
                ? ReadLiveRegimeText(signal)
                : FindRegimeSignal(barTime, signal);
   if(found && signal.time == barTime)
     {
      g_csvSignalAvailable = true;
      g_currentCsvRegime = signal.regime;
      g_currentCsvName = signal.name;
      g_currentCsvConfidence = signal.confidence;
     }
  }

//+------------------------------------------------------------------+
string TimeframeText()
  {
   string value = EnumToString(InpSignalTimeframe);
   StringReplace(value, "PERIOD_", "");
   return value;
  }

//+------------------------------------------------------------------+
string TrendText(TrendDirection trend)
  {
   if(trend == TREND_UP)
      return "BUY - UPPER RANGE BREAKOUT";
   if(trend == TREND_DOWN)
      return "SELL - LOWER RANGE BREAKOUT";
   if(trend == TREND_TRANSITION)
      return "TRANSITION - HOLD / NO NEW TRADE";
   return "SIDEWAYS - NO TRADE";
  }

//+------------------------------------------------------------------+
color TrendColor(TrendDirection trend)
  {
   if(trend == TREND_UP)
      return clrLimeGreen;
   if(trend == TREND_DOWN)
      return clrTomato;
   if(trend == TREND_TRANSITION)
      return clrAqua;
   return clrGold;
  }

//+------------------------------------------------------------------+
bool IsPivotHigh(const MqlRates &rates[], int total, int shift)
  {
   if(shift - InpPivotRight < 1 || shift + InpPivotLeft >= total)
      return false;
   double price = rates[shift].high;
   for(int i = 1; i <= InpPivotRight; i++)
      if(price <= rates[shift - i].high)
         return false;
   for(int i = 1; i <= InpPivotLeft; i++)
      if(price <= rates[shift + i].high)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
bool IsPivotLow(const MqlRates &rates[], int total, int shift)
  {
   if(shift - InpPivotRight < 1 || shift + InpPivotLeft >= total)
      return false;
   double price = rates[shift].low;
   for(int i = 1; i <= InpPivotRight; i++)
      if(price >= rates[shift - i].low)
         return false;
   for(int i = 1; i <= InpPivotLeft; i++)
      if(price >= rates[shift + i].low)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
bool ReadBufferValue(int handle, int bufferNumber, int shift, double &value)
  {
   double values[];
   if(CopyBuffer(handle, bufferNumber, shift, 1, values) != 1 ||
      values[0] == EMPTY_VALUE)
      return false;
   value = values[0];
   return true;
  }

//+------------------------------------------------------------------+
bool CalculateStructure(StructureState &state)
  {
   int requested = InpBreakoutLookback + 10;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpSignalTimeframe, 0, requested, rates);
   if(copied < InpBreakoutLookback + 2)
      return false;

   if(!ReadBufferValue(g_atrHandle, 0, 1, state.atr) ||
      !ReadBufferValue(g_slowEmaHandle, 0, 1, state.slowEma) ||
      !ReadBufferValue(g_ema100Handle, 0, 1, state.ema100) ||
      state.atr <= 0.0)
      return false;

   state.close = rates[1].close;

   state.barTime = rates[1].time;
   state.buffer = InpBreakoutBufferAtr * state.atr;

   // The breakout candle is shift 1. The range is built only from candles
   // before it (shifts 2..lookback+1), preventing look-ahead contamination.
   state.upperLimit = rates[2].high;
   state.lowerLimit = rates[2].low;
   for(int shift = 3; shift <= InpBreakoutLookback + 1; shift++)
     {
      state.upperLimit = MathMax(state.upperLimit, rates[shift].high);
      state.lowerLimit = MathMin(state.lowerLimit, rates[shift].low);
     }
   state.rangeWidth = state.upperLimit - state.lowerLimit;
   state.consolidationPassed = true;

   bool upperBreak = rates[1].close > state.upperLimit + state.buffer &&
                     rates[2].close <= state.upperLimit + state.buffer;
   bool lowerBreak = rates[1].close < state.lowerLimit - state.buffer &&
                     rates[2].close >= state.lowerLimit - state.buffer;

   state.trend = TREND_TRANSITION;
   state.detail = "Inside previous " + IntegerToString(InpBreakoutLookback) +
                  "-bar range";
   if(upperBreak)
     {
      state.trend = TREND_UP;
      state.detail = "Close broke above prior range + ATR buffer";
     }
   else if(lowerBreak)
     {
      state.trend = TREND_DOWN;
      state.detail = "Close broke below prior range - ATR buffer";
     }
   return true;
  }

//+------------------------------------------------------------------+
bool HasOpenPositionForSymbol()
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
bool SelectManagedPosition(long &positionType)
  {
   if(!PositionSelect(_Symbol) ||
      (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      return false;
   positionType = PositionGetInteger(POSITION_TYPE);
   return true;
  }

//+------------------------------------------------------------------+
bool IsWithinEntryHours()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   return now.hour >= InpTradeStartHour && now.hour < InpTradeEndHour;
  }

//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

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
bool OpenTrade(TrendDirection direction)
  {
   if((direction != TREND_UP && direction != TREND_DOWN) ||
      HasOpenPositionForSymbol())
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minimumStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                        SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = direction == TREND_UP ? ask : bid;
   // Use the lowest low/highest high of the completed pre-breakout range.
   double sl = direction == TREND_UP ? g_state.lowerLimit : g_state.upperLimit;
   bool stopValid = direction == TREND_UP
                    ? sl <= bid - minimumStop
                    : sl >= ask + minimumStop;
   if(!stopValid)
     {
      Print("Order skipped: previous range stop is inside broker minimum stop distance");
      return false;
     }
   double risk = MathAbs(entry - sl);
   double tp = direction == TREND_UP ? entry + 2.0 * risk
                                     : entry - 2.0 * risk;
   string comment = direction == TREND_UP ? "Range breakout BUY" : "Range breakout SELL";

   bool opened = direction == TREND_UP
                 ? g_trade.Buy(NormalizeVolume(InpLots), _Symbol, 0.0,
                               NormalizePrice(sl), NormalizePrice(tp), comment)
                 : g_trade.Sell(NormalizeVolume(InpLots), _Symbol, 0.0,
                                NormalizePrice(sl), NormalizePrice(tp), comment);
   if(!opened)
     {
      Print("Order failed: ", g_trade.ResultRetcodeDescription());
      return false;
     }
   g_entryAtr = g_state.atr;
   Print("Opened ", comment, "; SL=", DoubleToString(sl, _Digits),
         "; TP=", DoubleToString(tp, _Digits), "; reward/risk=2.0");
   return true;
  }

//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   long positionType;
   if(!SelectManagedPosition(positionType))
     {
      g_entryAtr = 0.0;
      return;
     }

   // After an EA/terminal restart, use the latest completed-bar ATR as the
   // best available replacement for the original entry ATR.
   if(g_entryAtr <= 0.0 &&
      !ReadBufferValue(g_atrHandle, 0, 1, g_entryAtr))
      return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minimumStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool isBuy = positionType == POSITION_TYPE_BUY;
   double profitDistance = isBuy ? bid - entry : entry - ask;
   bool alreadyAtBreakEven = isBuy ? currentSl >= entry - point * 0.5
                                   : currentSl > 0.0 && currentSl <= entry + point * 0.5;
   bool stopAllowed = isBuy ? entry <= bid - minimumStop
                            : entry >= ask + minimumStop;

   if(profitDistance < 2.0 * g_entryAtr || alreadyAtBreakEven || !stopAllowed)
      return;

   if(!g_trade.PositionModify(_Symbol, NormalizePrice(entry), currentTp))
     {
      Print("Break-even modification failed: ",
            g_trade.ResultRetcodeDescription());
      return;
     }
   Print("Stop moved to break even at ", DoubleToString(entry, _Digits),
         " after profit reached 2 x ATR");
  }

//+------------------------------------------------------------------+
bool CloseOnEmaFlip(const StructureState &state)
  {
   if(!InpCloseOnEmaFlip)
      return false;

   long positionType;
   if(!SelectManagedPosition(positionType))
      return false;

   bool flipped = positionType == POSITION_TYPE_BUY
                  ? state.slowEma <= state.ema100
                  : state.slowEma >= state.ema100;
   if(!flipped)
      return false;

   if(!g_trade.PositionClose(_Symbol))
     {
      Print("EMA flip close failed: ", g_trade.ResultRetcodeDescription());
      return false;
     }

   g_entryAtr = 0.0;
   Print("Position closed: EMA50/EMA100 direction flipped");
   return true;
  }

//+------------------------------------------------------------------+
void TrailProfitableTradeToPreviousRange(const StructureState &state)
  {
   long positionType;
   if(!SelectManagedPosition(positionType))
      return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minimumStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool isBuy = positionType == POSITION_TYPE_BUY;

   // Only trail a profitable position. The completed pre-breakout range gives
   // the previous lowest low for buys and previous highest high for sells.
   if((isBuy && bid <= entry) || (!isBuy && ask >= entry))
      return;

   double proposedSl = isBuy ? state.lowerLimit : state.upperLimit;
   bool improvesStop = isBuy ? (currentSl <= 0.0 || proposedSl > currentSl + point * 0.5)
                             : (currentSl <= 0.0 || proposedSl < currentSl - point * 0.5);
   bool stopAllowed = isBuy ? proposedSl <= bid - minimumStop
                            : proposedSl >= ask + minimumStop;
   if(!improvesStop || !stopAllowed)
      return;

   proposedSl = NormalizePrice(proposedSl);
   if(!g_trade.PositionModify(_Symbol, proposedSl, currentTp))
     {
      Print("Previous-range stop modification failed: ",
            g_trade.ResultRetcodeDescription());
      return;
     }
   Print("Profitable position stop moved to previous ",
         isBuy ? "lowest low: " : "highest high: ",
         DoubleToString(proposedSl, _Digits));
  }

//+------------------------------------------------------------------+
void CloseOnPreviousRangeBreak()
  {
   if(!g_stateAvailable)
      return;

   long positionType;
   if(!SelectManagedPosition(positionType))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isBuy = positionType == POSITION_TYPE_BUY;
   bool levelBroken = isBuy ? bid < g_state.lowerLimit
                            : ask > g_state.upperLimit;
   if(!levelBroken)
      return;

   if(!g_trade.PositionClose(_Symbol))
     {
      Print("Previous-range break close failed: ",
            g_trade.ResultRetcodeDescription());
      return;
     }

   g_entryAtr = 0.0;
   Print(isBuy ? "Buy closed: price broke the previous lowest low at "
               : "Sell closed: price broke the previous highest high at ",
         DoubleToString(isBuy ? g_state.lowerLimit : g_state.upperLimit,
                        _Digits));
  }

//+------------------------------------------------------------------+
void CloseOnPriceEma50Break()
  {
   long positionType;
   if(!SelectManagedPosition(positionType))
      return;

   double ema50;
   if(!ReadBufferValue(g_slowEmaHandle, 0, 0, ema50))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isBuy = positionType == POSITION_TYPE_BUY;
   bool emaBroken = isBuy ? bid < ema50 : ask > ema50;
   if(!emaBroken)
      return;

   if(!g_trade.PositionClose(_Symbol))
     {
      Print("Price/EMA50 close failed: ", g_trade.ResultRetcodeDescription());
      return;
     }

   g_entryAtr = 0.0;
   Print(isBuy ? "Buy closed: price fell below EMA50 at "
               : "Sell closed: price rose above EMA50 at ",
         DoubleToString(ema50, _Digits));
  }

//+------------------------------------------------------------------+
void SetBackground(string name, int x, int y, int width, int height)
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
void SetLabel(string name, string text, int x, int y, color clr, int size = -1)
  {
   if(size < 0)
      size = InpFontSize;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void DrawPanel()
  {
   if(!InpShowPanel || g_isTester)
      return;
   int x = InpXOffset;
   int y = InpYOffset;
   int lineHeight = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 560, lineHeight * 13 + 14);

   if(!g_stateAvailable)
     {
      SetLabel(PREFIX + "title", "RANGE BREAKOUT EA", x, y, clrWhite, InpFontSize + 1);
      SetLabel(PREFIX + "l1", "Waiting for sufficient price/indicator data...",
               x, y + lineHeight, clrOrange);
      ChartRedraw();
      return;
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool anyPosition = HasOpenPositionForSymbol();
   long positionType = -1;
   bool managedPosition = SelectManagedPosition(positionType);
   string positionText = !anyPosition ? "FLAT" :
                         managedPosition
                         ? (positionType == POSITION_TYPE_BUY ? "BUY" : "SELL")
                         : "BLOCKED BY OTHER POSITION";
   bool directionalTrend = g_state.trend == TREND_UP ||
                           g_state.trend == TREND_DOWN;
   bool tradeReady = directionalTrend &&
                     EmaFilterPassed(g_state) &&
                     IsWithinEntryHours() && !anyPosition;
   bool emaPassed = EmaFilterPassed(g_state);

   int row = 0;
   SetLabel(PREFIX + "title", "RANGE BREAKOUT EA", x, y + lineHeight * row++,
            clrWhite, InpFontSize + 1);
   SetLabel(PREFIX + "l1", "Symbol/TF:    " + _Symbol + " / " + TimeframeText(),
            x, y + lineHeight * row++, clrWhite);
   SetLabel(PREFIX + "l2", "SIGNAL:       " + TrendText(g_state.trend),
            x, y + lineHeight * row++, TrendColor(g_state.trend), InpFontSize + 1);
   SetLabel(PREFIX + "l3", "Reason:       " + g_state.detail,
            x, y + lineHeight * row++, TrendColor(g_state.trend));
   SetLabel(PREFIX + "l4", "Range U / L:  " +
            DoubleToString(g_state.upperLimit, digits) + " / " +
            DoubleToString(g_state.lowerLimit, digits),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l5", "Range width:  " +
            DoubleToString(g_state.rangeWidth, digits),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l6", "ATR / buffer: " +
            DoubleToString(g_state.atr, digits) + " / " +
            DoubleToString(g_state.buffer, digits),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l7", "Filters:      ADX, EMA21, regime DISABLED; hours " +
            (IsWithinEntryHours() ? "OPEN" : "CLOSED"),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l8", "Price / EMA50: " +
            DoubleToString(g_state.close, digits) + " / " +
            DoubleToString(g_state.slowEma, digits) + " [" +
            (emaPassed ? "PASS" : "FAIL") + "]",
            x, y + lineHeight * row++, emaPassed ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l9", "Stops:        Prior range; TP=2R; EMA flip close " +
            (InpCloseOnEmaFlip ? "ON" : "OFF"),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l10", "Position:     " + positionText,
            x, y + lineHeight * row++, anyPosition ? clrAqua : clrSilver);
   SetLabel(PREFIX + "l11", "Order status: " +
            (tradeReady ? "READY" : anyPosition ? "WAITING FOR CLOSE" : "NO ENTRY"),
            x, y + lineHeight * row++, tradeReady ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l12", "Last bar:     " +
            TimeToString(g_state.barTime, TIME_DATE | TIME_MINUTES),
            x, y + lineHeight * row++, clrGray);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void ProcessSignal()
  {
   // Entry signals use completed candles, so there is nothing to recalculate
   // until a new signal-timeframe bar has closed. This avoids doing the full
   // range/indicator calculation on every tester tick or one-second timer.
   datetime closedBarTime = iTime(_Symbol, InpSignalTimeframe, 1);
   if(closedBarTime <= 0 || closedBarTime <= g_lastProcessedBar)
      return;

   DrawChartEmas();

   StructureState state;
   if(!CalculateStructure(state))
     {
      g_stateAvailable = false;
      DrawPanel();
      return;
     }

   g_state = state;
   g_stateAvailable = true;
   DrawPanel();

   if(state.barTime <= g_lastProcessedBar)
      return;
   g_lastProcessedBar = state.barTime;
   if(!g_isTester)
      WriteLiveSignal(state.barTime, state.trend);

   // A flip exit is evaluated on completed signal-timeframe candles. Do not
   // reverse into a new position on the same candle that triggered the exit.
   if(CloseOnEmaFlip(state))
     {
      DrawPanel();
      return;
     }

   TrailProfitableTradeToPreviousRange(state);

   if(state.trend != TREND_UP && state.trend != TREND_DOWN)
      return;

   // A position of any magic number on this symbol blocks all new entries.
   // No signal closes or reverses an existing trade. Once opened, a position
   // remains unchanged until its original broker-side SL or TP is executed.
   if(HasOpenPositionForSymbol() || !IsWithinEntryHours())
      return;
   if(!EmaFilterPassed(state))
      return;
   OpenTrade(state.trend);
   DrawPanel();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   g_signalPeriodSeconds = PeriodSeconds(InpSignalTimeframe);
   if(g_signalPeriodSeconds <= 0)
      return INIT_PARAMETERS_INCORRECT;

   g_liveSignalFile = "live_signal_" + RegimeFileSymbol() + ".csv";
   Print("Chart symbol ", Symbol(), ": live signal file=", g_liveSignalFile);

   if(InpBreakoutLookback < 2 || InpAtrPeriod < 1 ||
      InpBreakoutBufferAtr < 0.0 || InpLots <= 0.0 ||
      InpTradeStartHour < 0 || InpTradeStartHour > 23 ||
      InpTradeEndHour < 1 || InpTradeEndHour > 24 ||
      InpTradeStartHour >= InpTradeEndHour)
      return INIT_PARAMETERS_INCORRECT;

   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   g_slowEmaHandle = iMA(_Symbol, InpSignalTimeframe, 50,
                         0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(_Symbol, InpSignalTimeframe, 100,
                        0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE ||
      g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create ATR/EMA handles. Error ", GetLastError());
      return INIT_FAILED;
     }

   // Chart-only EMA handles and objects are unnecessary in Strategy Tester.
   if(!g_isTester)
     {
      if(!CreateChartEma(50, g_chartEma50Handle) ||
         !CreateChartEma(100, g_chartEma100Handle))
         return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(!g_isTester)
      EventSetTimer(1);
   ProcessSignal();
   if(g_isTester)
      g_lastTesterBarBucket = (long)TimeCurrent() / g_signalPeriodSeconds;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
   if(g_fastEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEmaHandle);
   if(g_ema100Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema100Handle);
   if(g_chartEma21Handle != INVALID_HANDLE)
      IndicatorRelease(g_chartEma21Handle);
   if(g_chartEma50Handle != INVALID_HANDLE)
      IndicatorRelease(g_chartEma50Handle);
   if(g_chartEma100Handle != INVALID_HANDLE)
      IndicatorRelease(g_chartEma100Handle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ProcessSignal();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageBreakEven();

   if(g_isTester)
     {
      // Avoid an iTime()/CopyRates call on every simulated tick. Integer
      // division detects the first tick in each signal-timeframe candle.
      long barBucket = (long)TimeCurrent() / g_signalPeriodSeconds;
      if(barBucket != g_lastTesterBarBucket)
        {
         g_lastTesterBarBucket = barBucket;
         ProcessSignal();
        }
     }

   // Unlike entries, price/EMA and structure-break exits run on every tick.
   CloseOnPriceEma50Break();
   CloseOnPreviousRangeBreak();
  }
//+------------------------------------------------------------------+
