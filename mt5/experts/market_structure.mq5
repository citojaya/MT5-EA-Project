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
   DrawEma(g_chartEma21Handle, "21", InpEma21Color);
   DrawEma(g_chartEma50Handle, "50", InpEma50Color);
   DrawEma(g_chartEma100Handle, "100", InpEma100Color);
  }

//+------------------------------------------------------------------+
bool EmaFilterPassed(const StructureState &state)
  {
   if(state.trend != TREND_UP && state.trend != TREND_DOWN)
      return false;

   bool bullish = state.trend == TREND_UP;
   if(InpUseEma21 && InpUseEma50)
     {
      if(bullish ? state.fastEma <= state.slowEma
                 : state.fastEma >= state.slowEma)
         return false;
     }
   else if(InpUseEma21 &&
           (bullish ? state.close <= state.fastEma
                    : state.close >= state.fastEma))
      return false;
   else if(InpUseEma50 &&
           (bullish ? state.close <= state.slowEma
                    : state.close >= state.slowEma))
      return false;

   if(InpUseEma100 &&
      (bullish ? state.close <= state.ema100
               : state.close >= state.ema100))
      return false;
   return true;
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
   int requested = MathMax(InpPivotLookback + InpPivotLeft + InpPivotRight + 10,
                           InpBreakoutLookback + 10);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpSignalTimeframe, 0, requested, rates);
   if(copied < MathMax(InpPivotLeft + InpPivotRight + 10,
                       InpBreakoutLookback + 2))
      return false;

   int firstShift = InpPivotRight + 1;
   int lastShift = MathMin(copied - InpPivotLeft - 1, InpPivotLookback);

   // Build swings from oldest to newest. Consecutive pivots of the same
   // type are collapsed to the more extreme price, producing a genuinely
   // alternating sequence. Ambiguous outside bars that are both a high and
   // a low pivot are ignored rather than assigning two swings to one bar.
   SwingPoint swings[];
   int swingCount = 0;
   for(int shift = lastShift; shift >= firstShift; shift--)
     {
      bool pivotHigh = IsPivotHigh(rates, copied, shift);
      bool pivotLow = IsPivotLow(rates, copied, shift);
      if(pivotHigh == pivotLow)
         continue;

      SwingType type = pivotHigh ? SWING_HIGH : SWING_LOW;
      double price = pivotHigh ? rates[shift].high : rates[shift].low;
      if(swingCount > 0 && swings[swingCount - 1].type == type)
        {
         bool moreExtreme = type == SWING_HIGH
                            ? price > swings[swingCount - 1].price
                            : price < swings[swingCount - 1].price;
         if(moreExtreme)
           {
            swings[swingCount - 1].time = rates[shift].time;
            swings[swingCount - 1].price = price;
            swings[swingCount - 1].shift = shift;
           }
         continue;
        }

      ArrayResize(swings, swingCount + 1, 64);
      swings[swingCount].type = type;
      swings[swingCount].time = rates[shift].time;
      swings[swingCount].price = price;
      swings[swingCount].shift = shift;
      swingCount++;
     }

   int latestHighIndex = -1, previousHighIndex = -1;
   int latestLowIndex = -1, previousLowIndex = -1;
   for(int index = swingCount - 1; index >= 0; index--)
     {
      if(swings[index].type == SWING_HIGH)
        {
         if(latestHighIndex < 0) latestHighIndex = index;
         else if(previousHighIndex < 0) previousHighIndex = index;
        }
      else
        {
         if(latestLowIndex < 0) latestLowIndex = index;
         else if(previousLowIndex < 0) previousLowIndex = index;
        }
      if(previousHighIndex >= 0 && previousLowIndex >= 0)
         break;
     }

   if(previousHighIndex < 0 || previousLowIndex < 0 ||
      !ReadBufferValue(g_atrHandle, 0, 1, state.atr) ||
      !ReadBufferValue(g_adxHandle, 0, 1, state.adx) ||
      !ReadBufferValue(g_adxHandle, 0, 2, state.previousAdx) ||
      !ReadBufferValue(g_fastEmaHandle, 0, 1, state.fastEma) ||
      !ReadBufferValue(g_slowEmaHandle, 0, 1, state.slowEma) ||
      !ReadBufferValue(g_ema100Handle, 0, 1, state.ema100) ||
      state.atr <= 0.0)
      return false;

   state.close = rates[1].close;

   state.latestHigh = swings[latestHighIndex].price;
   state.latestHighTime = swings[latestHighIndex].time;
   state.latestHighShift = swings[latestHighIndex].shift;
   state.previousHigh = swings[previousHighIndex].price;
   state.previousHighTime = swings[previousHighIndex].time;
   state.latestLow = swings[latestLowIndex].price;
   state.latestLowTime = swings[latestLowIndex].time;
   state.latestLowShift = swings[latestLowIndex].shift;
   state.previousLow = swings[previousLowIndex].price;
   state.previousLowTime = swings[previousLowIndex].time;

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
   state.consolidationPassed = !InpRequireConsolidation ||
                               (state.rangeWidth <= InpMaximumRangeAtr * state.atr &&
                                state.previousAdx <= InpMaximumPreBreakoutAdx);

   bool upperBreak = rates[1].close > state.upperLimit + state.buffer &&
                     rates[2].close <= state.upperLimit + state.buffer;
   bool lowerBreak = rates[1].close < state.lowerLimit - state.buffer &&
                     rates[2].close >= state.lowerLimit - state.buffer;

   state.trend = TREND_TRANSITION;
   state.detail = "Inside previous " + IntegerToString(InpBreakoutLookback) +
                  "-bar range";
   if(state.adx < InpSidewaysAdx)
     {
      state.trend = TREND_SIDEWAYS;
      state.detail = "ADX below sideways threshold";
     }
   else if(!state.consolidationPassed)
      state.detail = "Breakout blocked by consolidation filter";
   else if(upperBreak)
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
bool OpenTrade(TrendDirection direction, double atr)
  {
   if((direction != TREND_UP && direction != TREND_DOWN) ||
      HasOpenPositionForSymbol())
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minimumStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                        SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopDistance = MathMax(InpStopLossAtrMultiplier * atr, minimumStop);
   double targetDistance = MathMax(InpTakeProfitAtrMultiplier * atr, minimumStop);
   double atrStop = direction == TREND_UP ? ask - stopDistance : bid + stopDistance;
   double structureStop = direction == TREND_UP ? g_state.latestLow : g_state.latestHigh;
   int structureStopAge = direction == TREND_UP
                          ? g_state.latestLowShift : g_state.latestHighShift;
   bool structureStopValid = structureStopAge <= InpMaximumSwingAgeBars &&
                             (direction == TREND_UP
                              ? structureStop <= bid - minimumStop
                              : structureStop >= ask + minimumStop);
   double sl = structureStopValid ? structureStop : atrStop;
   double tp = direction == TREND_UP ? ask + targetDistance : bid - targetDistance;
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
   Print("Opened ", comment, "; ADX=", DoubleToString(g_state.adx, 2));
   return true;
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
   if(!InpShowPanel)
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
   bool csvPassed = !InpUseRegimeCsv ||
                    (g_csvSignalAvailable &&
                     ((g_state.trend == TREND_UP &&
                       (g_currentCsvRegime == 0 || g_currentCsvRegime == 5)) ||
                      (g_state.trend == TREND_DOWN &&
                       (g_currentCsvRegime == 2 || g_currentCsvRegime == 5))));
   bool directionalTrend = g_state.trend == TREND_UP ||
                           g_state.trend == TREND_DOWN;
   bool tradeReady = directionalTrend &&
                     g_state.adx >= InpMinimumTrendAdx &&
                     EmaFilterPassed(g_state) && csvPassed &&
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
   SetLabel(PREFIX + "l5", "Range filter: " +
            (g_state.consolidationPassed ? "PASS" : "FAIL") +
            "  width=" + DoubleToString(g_state.rangeWidth, digits) +
            "  prior ADX=" + DoubleToString(g_state.previousAdx, 2),
            x, y + lineHeight * row++,
            g_state.consolidationPassed ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l6", "ATR / buffer: " +
            DoubleToString(g_state.atr, digits) + " / " +
            DoubleToString(g_state.buffer, digits),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l7", "ADX:          " + DoubleToString(g_state.adx, 2) +
            "  (trade >= " + DoubleToString(InpMinimumTrendAdx, 1) + ")",
            x, y + lineHeight * row++,
            g_state.adx >= InpMinimumTrendAdx ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l8", "EMA" + IntegerToString(InpFastEmaPeriod) +
            " / EMA" + IntegerToString(InpSlowEmaPeriod) + ": " +
            DoubleToString(g_state.fastEma, digits) + " / " +
            DoubleToString(g_state.slowEma, digits) + "  EMA100: " +
            DoubleToString(g_state.ema100, digits) + " [" +
            (emaPassed ? "PASS" : "FAIL") + "]",
            x, y + lineHeight * row++, emaPassed ? clrLimeGreen : clrOrange);
   string csvText = !InpUseRegimeCsv ? "DISABLED" :
                    !g_csvSignalAvailable ? "NO MATCHING ROW" :
                    IntegerToString(g_currentCsvRegime) + " " + g_currentCsvName +
                    "  conf=" + DoubleToString(g_currentCsvConfidence, 4) +
                    " [" + (csvPassed ? "PASS" : "FAIL") + "]";
   SetLabel(PREFIX + "l9", "Regime file:  " + csvText,
            x, y + lineHeight * row++, csvPassed ? clrLimeGreen : clrOrange);
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
   UpdateCurrentCsvSignal(state.barTime);
   DrawPanel();

   if(state.barTime <= g_lastProcessedBar)
      return;
   g_lastProcessedBar = state.barTime;
   WriteLiveSignal(state.barTime, state.trend);

   if(state.trend != TREND_UP && state.trend != TREND_DOWN)
      return;

   // A position of any magic number on this symbol blocks all new entries.
   // No signal closes or reverses an existing trade. Once opened, a position
   // remains unchanged until its original broker-side SL or TP is executed.
   if(HasOpenPositionForSymbol() || !IsWithinEntryHours())
      return;
   if(state.adx < InpMinimumTrendAdx)
      return;
   if(!EmaFilterPassed(state))
      return;
   if(InpUseRegimeCsv)
     {
      if(!g_csvSignalAvailable)
         return;
      bool csvBuyAllowed = g_currentCsvRegime == 0 || g_currentCsvRegime == 5;
      bool csvSellAllowed = g_currentCsvRegime == 2 || g_currentCsvRegime == 5;
      if((state.trend == TREND_UP && !csvBuyAllowed) ||
         (state.trend == TREND_DOWN && !csvSellAllowed))
         return;
     }

   OpenTrade(state.trend, state.atr);
   DrawPanel();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_regimeCsvFile = ResolveRegimeFile();
   g_liveSignalFile = "live_signal_" + RegimeFileSymbol() + ".csv";
   Print("Chart symbol ", Symbol(), ": live signal file=", g_liveSignalFile);
   if(!USE_REGIME_CSV_DEFAULT && g_regimeCsvFile == "")
     {
      Print("InpRegimeCsvFile must be supplied when USE_REGIME_CSV_DEFAULT=false");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpPivotLeft < 1 || InpPivotRight < 1 || InpPivotLookback < 20 ||
      InpMaximumSwingAgeBars < InpPivotRight + 1 ||
      InpBreakoutLookback < 2 || InpAtrPeriod < 1 || InpAdxPeriod < 1 ||
      InpBreakoutBufferAtr < 0.0 || InpMaximumRangeAtr <= 0.0 ||
      InpMaximumPreBreakoutAdx < 0.0 ||
      InpFastEmaPeriod < 1 || InpSlowEmaPeriod <= InpFastEmaPeriod ||
      InpCsvTimeOffsetHours < -24 || InpCsvTimeOffsetHours > 24 ||
      InpSidewaysAdx < 0.0 || InpMinimumTrendAdx < InpSidewaysAdx ||
      InpLots <= 0.0 || InpStopLossAtrMultiplier <= 0.0 ||
      InpTakeProfitAtrMultiplier <= 0.0 || InpTradeStartHour < 0 ||
      InpTradeStartHour > 23 || InpTradeEndHour < 1 ||
      InpTradeEndHour > 24 || InpTradeStartHour >= InpTradeEndHour)
      return INIT_PARAMETERS_INCORRECT;

   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   g_adxHandle = iADX(_Symbol, InpSignalTimeframe, InpAdxPeriod);
   g_fastEmaHandle = iMA(_Symbol, InpSignalTimeframe, InpFastEmaPeriod,
                         0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(_Symbol, InpSignalTimeframe, InpSlowEmaPeriod,
                         0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(_Symbol, InpSignalTimeframe, 100,
                        0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE ||
      g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE ||
      g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create ATR/ADX/EMA handles. Error ", GetLastError());
      return INIT_FAILED;
     }

   // EMA lines are always visible; the inputs control trading filters only.
   if(!CreateChartEma(21, g_chartEma21Handle) ||
      !CreateChartEma(50, g_chartEma50Handle) ||
      !CreateChartEma(100, g_chartEma100Handle))
      return INIT_FAILED;

   if(InpUseRegimeCsv)
     {
      if(IsLiveRegimeTextFile())
         Print("Live key=value regime source enabled: terminal MQL5\\Files\\",
               g_regimeCsvFile);
      else if(!LoadRegimeCsv())
         return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   EventSetTimer(1);
   ProcessSignal();
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
   // Intentionally empty: no trailing stop, break-even, or signal-based exit.
   // Open positions are closed only by their original stop-loss or take-profit.
  }
//+------------------------------------------------------------------+
