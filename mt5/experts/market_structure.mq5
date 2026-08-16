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

#ifndef ALLOW_SAME_DIRECTION_ENTRIES_DEFAULT
#define ALLOW_SAME_DIRECTION_ENTRIES_DEFAULT false
#endif

#ifndef MAGIC_NUMBER_DEFAULT
#define MAGIC_NUMBER_DEFAULT 11111111
#endif

enum TradeDirectionMode
  {
   TRADE_BOTH_DIRECTIONS = 0,
   TRADE_BUY_ONLY = 1,
   TRADE_SELL_ONLY = 2
  };

input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5; // Entry timeframe: M5 only
input TradeDirectionMode InpTradeDirectionMode = TRADE_BOTH_DIRECTIONS;
input int    InpPivotLeft = 2;                        // Older bars around a pivot
input int    InpPivotRight = 2;                       // Newer closed bars confirming a pivot
input int    InpPivotLookback = 300;                  // Bars searched for swing points
input int    InpMaximumSwingAgeBars = 150;            // Maximum age of latest high/low
input int    InpBreakoutLookback = 20;                // Completed candles defining the range
input int    InpAtrPeriod = 14;                       // ATR period
input double InpBreakoutBufferAtr = 0.10;             // Break distance beyond range in ATR
input int    InpAdxPeriod = 14;                       // ADX period
input bool   InpUseAdxFilter = true;                  // Require minimum ADX for entries
input double InpSidewaysAdx = 20.0;                   // Below this is always sideways
input double InpMinimumTrendAdx = 20.0;               // Minimum ADX required to trade
input bool   InpRequireConsolidation = false;         // Apply optional pre-breakout range filter
input double InpMaximumRangeAtr = 3.0;                // Maximum range width in ATR
input double InpMaximumPreBreakoutAdx = 25.0;         // Maximum ADX before breakout
input int    InpFastEmaPeriod = 21;                   // Fast EMA period
input int    InpSlowEmaPeriod = 50;                   // Slow EMA period
input bool   InpUseEma21 = false;                     // Use EMA(21) for trading
input bool   InpUseEma50 = false;                     // Use EMA(50) for trading
input color  InpEma21Color = clrDeepSkyBlue;          // EMA(21) chart colour
input color  InpEma50Color = clrOrange;               // EMA(50) chart colour
input color  InpEma100Color = clrMagenta;              // EMA(100) chart colour
input double InpAtrTrailingMultiplier = 3.0;           // ATR trailing-stop distance
input color  InpAtrTrailingColor = clrRed;             // ATR trailing-stop chart colour
const bool   InpUseRegimeCsv = false;                 // Legacy reader disabled
const string InpRegimeCsvFile = "";                  // Legacy reader disabled
const int    InpCsvTimeOffsetHours = 0;               // Legacy reader disabled
input double InpLots = 0.01;                          // Fixed trade volume
input int    InpTradeStartHour = 1;                   // Server hour, inclusive
input int    InpTradeEndHour = 22;                    // Server hour, exclusive
input bool   InpAllowSameDirectionEntries = ALLOW_SAME_DIRECTION_ENTRIES_DEFAULT;
input int    InpMaximumSameDirectionEntries = 5;      // Maximum entries per symbol/direction
input double InpMinimumEntryGapAtr = 2.0;             // Minimum gap from previous entry
input int    InpProfitableExitBars = 240;              // Close profitable trades after this many candles
input double InpTakeProfitAtrMultiplier = 60.0;        // Take-profit distance in ATR
input int    InpDeviationPoints = 20;                 // Maximum order deviation
input ulong  InpMagicNumber = MAGIC_NUMBER_DEFAULT;   // EA magic number
input bool             InpShowPanel = true;           // Show status panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int              InpXOffset = 15;
input int              InpYOffset = 15;
input int              InpFontSize = 10;
input string           InpFontName = "Consolas";

#define PREFIX "STRUCTURE_EA_"
#define REGIME_FILTER_TIMEFRAME "M1"
#define ALLOWED_TRENDING_REGIME 2

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
   double atrTrailingStop;
   double h1AtrTrailingStop;
   double close;
   double previousBarHigh;
   double previousBarLow;
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
int      g_h1AtrHandle = INVALID_HANDLE;
int      g_adxHandle = INVALID_HANDLE;
int      g_fastEmaHandle = INVALID_HANDLE;
int      g_slowEmaHandle = INVALID_HANDLE;
int      g_ema100Handle = INVALID_HANDLE;
int      g_chartEma21Handle = INVALID_HANDLE;
int      g_chartEma50Handle = INVALID_HANDLE;
int      g_chartEma100Handle = INVALID_HANDLE;
int      g_chartAtrHandle = INVALID_HANDLE;
datetime g_lastProcessedBar = 0;
long     g_lastTesterBarBucket = -1;
int      g_signalPeriodSeconds = 0;
bool     g_isTester = false;
double   g_lastEntryPrice = 0.0;
StructureState g_state;
bool     g_stateAvailable = false;
CsvRegimeSignal g_csvSignals[];
bool     g_csvSignalAvailable = false;
int      g_currentCsvRegime = -1;
string   g_currentCsvName = "";
double   g_currentCsvConfidence = 0.0;
string   g_regimeCsvFile = "";
string   g_liveSignalFile = "";
string   g_regimeFilterFile = "";
bool     g_regimeFilterAvailable = false;
int      g_regimeFilterValue = -1;
string   g_regimeFilterTimeframe = REGIME_FILTER_TIMEFRAME;
string   g_regimeFilterName = "";
#define ATR_PROTECTION_COMMENT "ATR protection"

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
   DrawEma(g_chartEma21Handle, "21", InpEma21Color);
   DrawEma(g_chartEma50Handle, "50", InpEma50Color);
   DrawEma(g_chartEma100Handle, "100", InpEma100Color);
  }

//+------------------------------------------------------------------+
void DrawAtrTrailingStop()
  {
   if(g_chartAtrHandle == INVALID_HANDLE)
      return;

   const int requested = 600;
   const int plotted = 300;
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(_Symbol, InpSignalTimeframe, 0, requested, rates);
   int atrCount = CopyBuffer(g_chartAtrHandle, 0, 0, requested, atrValues);
   int count = MathMin(ratesCount, atrCount);
   if(count < 3)
      return;

   double stops[];
   ArrayResize(stops, count);
   int firstValid = -1;
   for(int index = 0; index < count; index++)
     {
      if(atrValues[index] == EMPTY_VALUE || atrValues[index] <= 0.0)
        {
         stops[index] = EMPTY_VALUE;
         continue;
        }

      double loss = InpAtrTrailingMultiplier * atrValues[index];
      if(firstValid < 0)
        {
         stops[index] = rates[index].close - loss;
         firstValid = index;
         continue;
        }

      double previousStop = stops[index - 1];
      if(previousStop == EMPTY_VALUE)
        {
         stops[index] = rates[index].close - loss;
         continue;
        }

      if(rates[index].close > previousStop &&
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

   int firstPlot = MathMax(firstValid + 1, count - plotted);
   for(int index = firstPlot; index < count; index++)
     {
      if(stops[index - 1] == EMPTY_VALUE || stops[index] == EMPTY_VALUE)
         continue;
      string name = PREFIX + "ATR_STOP_" + IntegerToString(index - firstPlot);
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_TREND, 0,
                      rates[index - 1].time, stops[index - 1],
                      rates[index].time, stops[index]);
      else
        {
         ObjectMove(0, name, 0, rates[index - 1].time, stops[index - 1]);
         ObjectMove(0, name, 1, rates[index].time, stops[index]);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpAtrTrailingColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
bool CalculateAtrTrailingStop(const ENUM_TIMEFRAMES timeframe,
                              const int atrHandle, double &stop)
  {
   const int requested = 600;
   MqlRates rates[];
   double atrValues[];
   int ratesCount = CopyRates(_Symbol, timeframe, 0, requested, rates);
   if(ratesCount < 3)
      return false;
   int atrCount = CopyBuffer(atrHandle, 0, 0, ratesCount, atrValues);
   if(atrCount != ratesCount)
      return false;

   double previousStop = 0.0;
   for(int index = 0; index < ratesCount - 1; index++)
     {
      if(atrValues[index] == EMPTY_VALUE || atrValues[index] <= 0.0)
         return false;

      double loss = InpAtrTrailingMultiplier * atrValues[index];
      if(index == 0)
         stop = rates[index].close - loss;
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
   return true;
  }

//+------------------------------------------------------------------+
bool AtrLineFilterPassed(const StructureState &state)
  {
   if(state.trend == TREND_UP)
      return state.close > state.atrTrailingStop;
   if(state.trend == TREND_DOWN)
      return state.close < state.atrTrailingStop;
   return false;
  }

//+------------------------------------------------------------------+
bool AdxFilterPassed(const StructureState &state)
  {
   return !InpUseAdxFilter || state.adx >= InpMinimumTrendAdx;
  }

//+------------------------------------------------------------------+
bool H1AtrLineFilterPassed(const StructureState &state)
  {
   if(state.trend == TREND_UP)
      return state.close > state.h1AtrTrailingStop;
   if(state.trend == TREND_DOWN)
      return state.close < state.h1AtrTrailingStop;
   return false;
  }

//+------------------------------------------------------------------+
bool Ema21EntryFilterPassed(const StructureState &state)
  {
   if(state.trend == TREND_UP)
      return state.close > state.fastEma;
   if(state.trend == TREND_DOWN)
      return state.close < state.fastEma;
   return false;
  }

//+------------------------------------------------------------------+
bool TradeDirectionAllowed(const TrendDirection direction)
  {
   if(InpTradeDirectionMode == TRADE_BUY_ONLY)
      return direction == TREND_UP;
   if(InpTradeDirectionMode == TRADE_SELL_ONLY)
      return direction == TREND_DOWN;
   return direction == TREND_UP || direction == TREND_DOWN;
  }

//+------------------------------------------------------------------+
string TradeDirectionModeText()
  {
   if(InpTradeDirectionMode == TRADE_BUY_ONLY)
      return "BUY ONLY";
   if(InpTradeDirectionMode == TRADE_SELL_ONLY)
      return "SELL ONLY";
   return "BUY & SELL";
  }

//+------------------------------------------------------------------+
string H1AtrAllowedDirectionText()
  {
   if(!g_stateAvailable || g_state.h1AtrTrailingStop <= 0.0)
      return "WAITING";
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price > g_state.h1AtrTrailingStop)
      return TradeDirectionAllowed(TREND_UP) ? "BUY ONLY" : "NO TRADE";
   if(price < g_state.h1AtrTrailingStop)
      return TradeDirectionAllowed(TREND_DOWN) ? "SELL ONLY" : "NO TRADE";
   return "NO TRADE";
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
//| Read the three-region ML result from this terminal's MQL5\Files. |
//| The filter fails closed: any missing or invalid value blocks new  |
//| entries while leaving existing position management unchanged.    |
//+------------------------------------------------------------------+
bool UpdateRegimeFilter()
  {
   g_regimeFilterAvailable = false;
   g_regimeFilterValue = -1;
   g_regimeFilterTimeframe = REGIME_FILTER_TIMEFRAME;
   g_regimeFilterName = "";

   int handle = FileOpen(g_regimeFilterFile,
                         FILE_READ | FILE_TXT | FILE_ANSI |
                         FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
      return false;

   string symbolText = "";
   string timeframeText = "";
   string regimeText = "";
   string regimeNameText = "";
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

      if(key == "symbol") symbolText = value;
      else if(key == "timeframe") timeframeText = value;
      else if(key == "regime") regimeText = value;
      else if(key == "regime_name") regimeNameText = value;
     }
   FileClose(handle);

   if(regimeText == "" ||
      CanonicalSymbol(symbolText) != CanonicalSymbol(_Symbol) ||
      timeframeText != REGIME_FILTER_TIMEFRAME)
      return false;

   g_regimeFilterValue = (int)StringToInteger(regimeText);
   g_regimeFilterTimeframe = timeframeText;
   g_regimeFilterName = regimeNameText;
   g_regimeFilterAvailable = true;
   return true;
  }

//+------------------------------------------------------------------+
bool RegimeFilterAllowsTrade()
  {
   return g_regimeFilterAvailable &&
          g_regimeFilterValue == ALLOWED_TRENDING_REGIME;
  }

//+------------------------------------------------------------------+
string RegimeFilterText()
  {
   if(!g_regimeFilterAvailable)
      return "N/A";
   if(g_regimeFilterName != "")
      return IntegerToString(g_regimeFilterValue) + " (" +
             g_regimeFilterName + ")";
   if(g_regimeFilterValue == 0)
      return "0 (Choppy)";
   if(g_regimeFilterValue == 1)
      return "1 (Uncertain)";
   if(g_regimeFilterValue == 2)
      return "2 (Trending)";
   return IntegerToString(g_regimeFilterValue) + " (Unknown)";
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
      return "BUY - M5 ATR/EMA ALIGNMENT";
   if(trend == TREND_DOWN)
      return "SELL - M5 ATR/EMA ALIGNMENT";
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
      !ReadBufferValue(g_fastEmaHandle, 0, 1, state.fastEma) ||
      !ReadBufferValue(g_slowEmaHandle, 0, 1, state.slowEma) ||
      !ReadBufferValue(g_ema100Handle, 0, 1, state.ema100) ||
      state.atr <= 0.0)
      return false;
   state.adx = 0.0;
   if(InpUseAdxFilter &&
      !ReadBufferValue(g_adxHandle, 0, 1, state.adx))
      return false;
   if(!CalculateAtrTrailingStop(PERIOD_M5, g_atrHandle,
                                state.atrTrailingStop) ||
      !CalculateAtrTrailingStop(PERIOD_H1, g_h1AtrHandle,
                                state.h1AtrTrailingStop))
      return false;

   state.close = rates[1].close;
   state.previousBarHigh = rates[1].high;
   state.previousBarLow = rates[1].low;

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

   state.trend = TREND_TRANSITION;
   state.detail = "M5 ATR/EMA direction is not aligned";
   if(state.close > state.atrTrailingStop && state.close > state.fastEma)
     {
      state.trend = TREND_UP;
      state.detail = "M5 close is above ATR line and EMA(21)";
     }
   else if(state.close < state.atrTrailingStop && state.close < state.fastEma)
     {
      state.trend = TREND_DOWN;
      state.detail = "M5 close is below ATR line and EMA(21)";
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
#ifdef REMOVED_TREND_LINE_CODE
bool FindTradeTrendExtremes(TrendDirection direction,
                            SwingPoint &older, SwingPoint &newer)
  {
   int requested = InpTradeTrendLookback + 1;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpSignalTimeframe, 0, requested, rates);
   if(copied < requested)
      return false;

   int firstShift = 1;
   int secondShift = 2;
   double firstPrice = direction == TREND_UP ? rates[firstShift].low
                                             : rates[firstShift].high;
   double secondPrice = direction == TREND_UP ? rates[secondShift].low
                                              : rates[secondShift].high;
   bool secondIsMoreExtreme = direction == TREND_UP
                              ? secondPrice < firstPrice
                              : secondPrice > firstPrice;
   if(secondIsMoreExtreme)
     {
      int savedShift = firstShift;
      double savedPrice = firstPrice;
      firstShift = secondShift;
      firstPrice = secondPrice;
      secondShift = savedShift;
      secondPrice = savedPrice;
     }

   for(int shift = 3; shift <= InpTradeTrendLookback; shift++)
     {
      double price = direction == TREND_UP ? rates[shift].low
                                           : rates[shift].high;
      bool isMoreExtreme = direction == TREND_UP ? price < firstPrice
                                                  : price > firstPrice;
      if(isMoreExtreme)
        {
         secondPrice = firstPrice;
         secondShift = firstShift;
         firstPrice = price;
         firstShift = shift;
        }
      else
        {
         bool isSecondMoreExtreme = direction == TREND_UP
                                    ? price < secondPrice
                                    : price > secondPrice;
         if(isSecondMoreExtreme)
           {
            secondPrice = price;
            secondShift = shift;
           }
        }
     }

   int olderShift = MathMax(firstShift, secondShift);
   int newerShift = MathMin(firstShift, secondShift);
   older.type = direction == TREND_UP ? SWING_LOW : SWING_HIGH;
   older.time = rates[olderShift].time;
   older.price = direction == TREND_UP ? rates[olderShift].low
                                       : rates[olderShift].high;
   older.shift = olderShift;
   newer.type = older.type;
   newer.time = rates[newerShift].time;
   newer.price = direction == TREND_UP ? rates[newerShift].low
                                       : rates[newerShift].high;
   newer.shift = newerShift;
   return true;
  }

//+------------------------------------------------------------------+
bool PlotFrozenTradeTrendLine(TrendDirection direction, datetime entryTime,
                              double entryPrice)
  {
   if(g_tradeTrendLinePlotted || ObjectFind(0, TRADE_TREND_LINE_NAME) >= 0)
     {
      g_tradeTrendLinePlotted = true;
      return true;
     }

   SwingPoint older, newer;
   if(!FindTradeTrendExtremes(direction, older, newer) ||
      newer.time <= older.time)
     {
      Print("Trade trend line not plotted: two ",
            direction == TREND_UP ? "lowest lows" : "highest highs",
            " were not available in the previous ",
            InpTradeTrendLookback, " completed candles");
      return false;
     }

   datetime projectionStart = entryTime > newer.time ? entryTime : newer.time;
   datetime projectionEnd = projectionStart +
                            InpTradeTrendProjectionBars * g_signalPeriodSeconds;
   double entryAtr = 0.0;
   int entryShift = iBarShift(_Symbol, InpSignalTimeframe, entryTime, false);
   if(entryShift < 0 ||
      !ReadBufferValue(g_atrHandle, 0, entryShift, entryAtr) || entryAtr <= 0.0)
     {
      Print("Trade trend line not plotted: ATR was unavailable at entry");
      return false;
     }
   double secondsBetweenPivots = (double)(newer.time - older.time);
   double slopeMagnitude = MathAbs((newer.price - older.price) /
                                   secondsBetweenPivots);
   double minimumSlope = SymbolInfoDouble(_Symbol, SYMBOL_POINT) /
                         secondsBetweenPivots;
   slopeMagnitude = MathMax(slopeMagnitude, minimumSlope);
   double secondsAfterEntry = (double)(projectionEnd - entryTime);
   double entryGap = InpTradeTrendOffsetAtr * entryAtr;
   if(secondsAfterEntry > 0.0)
      slopeMagnitude = MathMin(slopeMagnitude, entryGap / secondsAfterEntry);
   double slopePerSecond = direction == TREND_UP ? slopeMagnitude
                                                 : -slopeMagnitude;

   // At entry the BUY line is exactly below price and increases; the SELL
   // line is exactly above price and decreases. The capped slope prevents
   // either projected segment from crossing the order entry price.
   double linePriceAtEntry = direction == TREND_UP
                             ? entryPrice - entryGap
                             : entryPrice + entryGap;
   older.price = linePriceAtEntry +
                 slopePerSecond * (double)(older.time - entryTime);
   double projectedPrice = linePriceAtEntry +
                           slopePerSecond * secondsAfterEntry;

   if(!ObjectCreate(0, TRADE_TREND_LINE_NAME, OBJ_TREND, 0,
                    older.time, older.price, projectionEnd, projectedPrice))
     {
      Print("Unable to plot frozen trade trend line. Error ", GetLastError());
      return false;
     }
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_COLOR,
                    direction == TREND_UP ? InpBuyTrendLineColor
                                          : InpSellTrendLineColor);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, TRADE_TREND_LINE_NAME, OBJPROP_HIDDEN, true);
   ObjectSetString(0, TRADE_TREND_LINE_NAME, OBJPROP_TOOLTIP,
                   direction == TREND_UP
                   ? "Frozen BUY support trend line (" +
                     DoubleToString(InpTradeTrendOffsetAtr, 2) +
                     " ATR below entry, increasing)"
                   : "Frozen SELL resistance trend line (" +
                     DoubleToString(InpTradeTrendOffsetAtr, 2) +
                     " ATR above entry, decreasing)");
   g_tradeTrendLinePlotted = true;
   double currentLinePrice = ObjectGetValueByTime(0, TRADE_TREND_LINE_NAME,
                                                   TimeCurrent(), 0);
   double currentPrice = direction == TREND_UP
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_tradeTrendPriceWasSafe = direction == TREND_UP
                              ? currentPrice >= currentLinePrice
                              : currentPrice <= currentLinePrice;
   g_tradeTrendPriceStateAvailable = currentLinePrice != 0.0;
   g_tradeTrendDirection = direction;
   ChartRedraw();
   return true;
  }

//+------------------------------------------------------------------+
void SynchronizeTradeTrendLine()
  {
   long positionType = -1;
   datetime entryTime = 0;
   double entryPrice = 0.0;
   long oldestTimeMsc = LONG_MAX;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long positionTimeMsc = PositionGetInteger(POSITION_TIME_MSC);
      if(positionTimeMsc < oldestTimeMsc)
        {
         oldestTimeMsc = positionTimeMsc;
         positionType = PositionGetInteger(POSITION_TYPE);
         entryTime = (datetime)PositionGetInteger(POSITION_TIME);
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }

   // Charting deliberately applies to every position on this symbol,
   // including manually opened trades and trades from other magic numbers.
   if(positionType != POSITION_TYPE_BUY && positionType != POSITION_TYPE_SELL)
     {
      if(g_tradeTrendLinePlotted ||
         ObjectFind(0, TRADE_TREND_LINE_NAME) >= 0)
        {
         ObjectDelete(0, TRADE_TREND_LINE_NAME);
         ChartRedraw();
        }
      g_tradeTrendLinePlotted = false;
      g_tradeTrendPriceStateAvailable = false;
      g_tradeTrendPriceWasSafe = false;
      g_tradeTrendExitActive = false;
      g_tradeTrendDirection = TREND_SIDEWAYS;
      return;
     }

   if(g_tradeTrendLinePlotted || ObjectFind(0, TRADE_TREND_LINE_NAME) >= 0)
     {
      g_tradeTrendLinePlotted = true;
      if(g_tradeTrendDirection == TREND_SIDEWAYS)
         g_tradeTrendDirection = positionType == POSITION_TYPE_BUY
                                 ? TREND_UP : TREND_DOWN;
      return;
     }
   TrendDirection direction = positionType == POSITION_TYPE_BUY
                              ? TREND_UP : TREND_DOWN;
   PlotFrozenTradeTrendLine(direction, entryTime, entryPrice);
  }

#endif

//+------------------------------------------------------------------+
bool CloseAllSymbolPositions(const string reason)
  {
   bool allClosed = true;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
        {
         allClosed = false;
         Print("Failed to close position #", ticket, " (", reason, "): ",
               g_trade.ResultRetcodeDescription());
        }
      else
         Print("Closed position #", ticket, " (", reason, ")");
     }
   return allClosed;
  }

//+------------------------------------------------------------------+
void CheckProfitableAgeExit()
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      datetime entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      int candlesSinceEntry = iBarShift(_Symbol, InpSignalTimeframe,
                                        entryTime, false);
      if(candlesSinceEntry < InpProfitableExitBars ||
         PositionGetDouble(POSITION_PROFIT) <= 0.0)
         continue;

      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
         Print("Failed to close profitable position #", ticket, " after ",
               candlesSinceEntry, " candles: ",
               g_trade.ResultRetcodeDescription());
      else
         Print("Closed profitable position #", ticket, " after ",
               candlesSinceEntry, " candles");
     }
  }

#ifdef REMOVED_TREND_LINE_CODE
//+------------------------------------------------------------------+
void CheckTrendLineExit()
  {
   if(!HasOpenPositionForSymbol() ||
      ObjectFind(0, TRADE_TREND_LINE_NAME) < 0)
      return;

   datetime now = TimeCurrent();
   double linePrice = ObjectGetValueByTime(0, TRADE_TREND_LINE_NAME, now, 0);
   if(linePrice == 0.0)
      return;

   if(g_tradeTrendDirection != TREND_UP &&
      g_tradeTrendDirection != TREND_DOWN)
      return;

   double price = g_tradeTrendDirection == TREND_UP
                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool priceIsSafe = g_tradeTrendDirection == TREND_UP
                      ? price >= linePrice
                      : price <= linePrice;
   if(!g_tradeTrendPriceStateAvailable)
     {
      g_tradeTrendPriceWasSafe = priceIsSafe;
      g_tradeTrendPriceStateAvailable = true;
      return;
     }

   bool crossedExitSide = g_tradeTrendPriceWasSafe && !priceIsSafe;
   g_tradeTrendPriceWasSafe = priceIsSafe;
   if(crossedExitSide)
      g_tradeTrendExitActive = true;
   if(g_tradeTrendExitActive)
     {
      string reason = g_tradeTrendDirection == TREND_UP
                      ? "BUY price dropped below frozen trend line"
                      : "SELL price crossed above frozen trend line";
      CloseAllSymbolPositions(reason);
      SynchronizeTradeTrendLine();
     }
  }

#endif

//+------------------------------------------------------------------+
int SameDirectionEntryCount(TrendDirection direction, bool &blocked)
  {
   blocked = false;
   double totalVolume = 0.0;
   long requiredType = direction == TREND_UP ? POSITION_TYPE_BUY
                                             : POSITION_TYPE_SELL;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         PositionGetInteger(POSITION_TYPE) != requiredType)
        {
         blocked = true;
         continue;
        }
      totalVolume += PositionGetDouble(POSITION_VOLUME);
     }

   double entryVolume = NormalizeVolume(InpLots);
   if(entryVolume <= 0.0)
      return 0;
   return (int)MathCeil(totalVolume / entryVolume - 1e-9);
  }

//+------------------------------------------------------------------+
bool CanOpenTrade(TrendDirection direction)
  {
   if(direction != TREND_UP && direction != TREND_DOWN)
      return false;
   if(!InpAllowSameDirectionEntries)
      return !HasOpenPositionForSymbol();

   bool blocked;
   int entries = SameDirectionEntryCount(direction, blocked);
   return !blocked && entries < InpMaximumSameDirectionEntries;
  }

//+------------------------------------------------------------------+
double LatestManagedEntryPrice(TrendDirection direction)
  {
   long requiredType = direction == TREND_UP ? POSITION_TYPE_BUY
                                             : POSITION_TYPE_SELL;
   long latestTimeMsc = -1;
   double latestPrice = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         PositionGetInteger(POSITION_TYPE) != requiredType)
         continue;

      long positionTimeMsc = PositionGetInteger(POSITION_TIME_MSC);
      if(positionTimeMsc > latestTimeMsc)
        {
         latestTimeMsc = positionTimeMsc;
         latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return latestPrice;
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
void CheckH1AtrDirectionExit()
  {
   if(!g_stateAvailable || g_state.h1AtrTrailingStop <= 0.0)
      return;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long typeToClose = price > g_state.h1AtrTrailingStop
                      ? POSITION_TYPE_SELL
                      : price < g_state.h1AtrTrailingStop
                        ? POSITION_TYPE_BUY
                        : -1;
   if(typeToClose < 0)
      return;

   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_TYPE) != typeToClose)
         continue;

      if(!g_trade.PositionClose(ticket, InpDeviationPoints))
         Print("H1 ATR direction close failed for position #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
      else
         Print("H1 ATR direction closed position #", ticket,
               "; price=", DoubleToString(price, _Digits),
               "; H1 ATR line=",
               DoubleToString(g_state.h1AtrTrailingStop, _Digits));
     }
  }

//+------------------------------------------------------------------+
bool IsAtrProtectionOrder()
  {
   return OrderGetString(ORDER_SYMBOL) == _Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
          StringFind(OrderGetString(ORDER_COMMENT), ATR_PROTECTION_COMMENT) == 0;
  }

//+------------------------------------------------------------------+
void DeleteAtrProtectionOrders()
  {
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket > 0 && IsAtrProtectionOrder() &&
         !g_trade.OrderDelete(ticket))
         Print("Failed to delete ATR protection order #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
bool HasAnyOpenPositionOnSymbol()
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
void DeleteAllSymbolPendingStopOrders()
  {
   for(int index = OrdersTotal() - 1; index >= 0; index--)
     {
      ulong ticket = OrderGetTicket(index);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isStopOrder = type == ORDER_TYPE_BUY_STOP ||
                         type == ORDER_TYPE_SELL_STOP ||
                         type == ORDER_TYPE_BUY_STOP_LIMIT ||
                         type == ORDER_TYPE_SELL_STOP_LIMIT;
      if(isStopOrder && !g_trade.OrderDelete(ticket))
         Print("Failed to delete flat-symbol pending stop #", ticket, ": ",
               g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void MaintainAtrProtectionStop()
  {
   if(!HasAnyOpenPositionOnSymbol())
      DeleteAllSymbolPendingStopOrders();
  }

//+------------------------------------------------------------------+
bool OpenTrade(TrendDirection direction, bool pullbackEntry = false)
  {
   if(!TradeDirectionAllowed(direction) ||
      !g_stateAvailable || !AtrLineFilterPassed(g_state) ||
      !H1AtrLineFilterPassed(g_state) ||
      !Ema21EntryFilterPassed(g_state) ||
      !CanOpenTrade(direction))
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = direction == TREND_UP ? ask : bid;
   double takeProfit = direction == TREND_UP
                       ? entry + InpTakeProfitAtrMultiplier * g_state.atr
                       : entry - InpTakeProfitAtrMultiplier * g_state.atr;
   takeProfit = NormalizePrice(takeProfit);
   string comment = pullbackEntry
                    ? (direction == TREND_UP ? "Additional aligned BUY"
                                             : "Additional aligned SELL")
                    : (direction == TREND_UP ? "M5 aligned BUY"
                                             : "M5 aligned SELL");

   bool opened = direction == TREND_UP
                 ? g_trade.Buy(NormalizeVolume(InpLots), _Symbol, 0.0,
                               0.0, takeProfit, comment)
                 : g_trade.Sell(NormalizeVolume(InpLots), _Symbol, 0.0,
                                0.0, takeProfit, comment);
   if(!opened)
     {
      Print("Order failed: ", g_trade.ResultRetcodeDescription());
      return false;
     }
   double resultPrice = g_trade.ResultPrice();
   g_lastEntryPrice = resultPrice > 0.0 ? resultPrice : entry;
   Print("Opened ", comment, "; TP=", DoubleToString(takeProfit, _Digits),
         " (", DoubleToString(InpTakeProfitAtrMultiplier, 1), " ATR)");
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
   if(!InpShowPanel || g_isTester)
      return;
   int x = InpXOffset;
   int y = InpYOffset;
   int lineHeight = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 560, lineHeight * 14 + 14);

   if(!g_stateAvailable)
     {
      SetLabel(PREFIX + "title", "MARKET STRUCTURE EA", x, y, clrWhite, InpFontSize + 1);
      SetLabel(PREFIX + "l1", "H1 ATR trade:  " + H1AtrAllowedDirectionText(),
               x, y + lineHeight, clrAqua);
      SetLabel(PREFIX + "l2", "Waiting for sufficient price/indicator data...",
               x, y + lineHeight * 2, clrOrange);
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
                      TradeDirectionAllowed(g_state.trend) &&
                      AtrLineFilterPassed(g_state) &&
                      H1AtrLineFilterPassed(g_state) &&
                      AdxFilterPassed(g_state) &&
                      Ema21EntryFilterPassed(g_state) &&
                      IsWithinEntryHours() && CanOpenTrade(g_state.trend);
   bool atrLinePassed = AtrLineFilterPassed(g_state);
   bool adxPassed = AdxFilterPassed(g_state);

   int row = 0;
   SetLabel(PREFIX + "title", "MARKET STRUCTURE EA", x, y + lineHeight * row++,
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
   SetLabel(PREFIX + "l7", "ADX:          " +
            (InpUseAdxFilter ? DoubleToString(g_state.adx, 1) + " / " +
             DoubleToString(InpMinimumTrendAdx, 1) + " [" +
             (adxPassed ? "PASS" : "FAIL") + "]" : "OFF") +
            "; hours " + (IsWithinEntryHours() ? "OPEN" : "CLOSED"),
            x, y + lineHeight * row++, adxPassed ? clrSilver : clrOrange);
   SetLabel(PREFIX + "l8", "Price / ATR line: " +
            DoubleToString(g_state.close, digits) + " / " +
            DoubleToString(g_state.atrTrailingStop, digits) + " [" +
            (atrLinePassed ? "PASS" : "FAIL") + "]",
            x, y + lineHeight * row++,
            atrLinePassed ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l9", "Exit:         " +
            DoubleToString(InpTakeProfitAtrMultiplier, 1) +
            " ATR TP or profitable after " +
            IntegerToString(InpProfitableExitBars) + " candles; additions " +
            (InpAllowSameDirectionEntries ? "ON" : "OFF"),
            x, y + lineHeight * row++, clrSilver);
   SetLabel(PREFIX + "l10", "Position:     " + positionText,
            x, y + lineHeight * row++, anyPosition ? clrAqua : clrSilver);
   SetLabel(PREFIX + "l11", "Order status: " +
            (tradeReady ? "READY" : anyPosition ? "WAITING FOR CLOSE" : "NO ENTRY"),
            x, y + lineHeight * row++, tradeReady ? clrLimeGreen : clrOrange);
   SetLabel(PREFIX + "l12", "Last bar:     " +
            TimeToString(g_state.barTime, TIME_DATE | TIME_MINUTES),
            x, y + lineHeight * row++, clrGray);
   SetLabel(PREFIX + "l13", "H1 ATR trade:  " + H1AtrAllowedDirectionText(),
            x, y + lineHeight * row++, clrAqua);
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
     {
      DrawPanel();
      return;
     }

   DrawChartEmas();
   DrawAtrTrailingStop();

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

   if(state.trend != TREND_UP && state.trend != TREND_DOWN)
      return;

   // A position of any magic number on this symbol blocks all new entries.
   // No signal closes or reverses an existing trade. Once opened, a position
   // remains unchanged until its original broker-side SL or TP is executed.
   if(!CanOpenTrade(state.trend) || !IsWithinEntryHours())
      return;
   if(!AtrLineFilterPassed(state))
      return;
   if(!H1AtrLineFilterPassed(state))
     {
      Print("Trade blocked by H1 ATR line: M5 close=",
            DoubleToString(state.close, _Digits), ", H1 ATR line=",
            DoubleToString(state.h1AtrTrailingStop, _Digits));
      DrawPanel();
      return;
     }
   if(!AdxFilterPassed(state))
      return;
   if(!Ema21EntryFilterPassed(state))
     {
      Print("Trade blocked by EMA(21): close=",
            DoubleToString(state.close, _Digits), ", EMA21=",
            DoubleToString(state.fastEma, _Digits));
      DrawPanel();
      return;
     }
   // An addition requires continued M5 alignment in the existing position's
   // direction and sufficient distance from the latest entry.
   if(InpAllowSameDirectionEntries && HasOpenPositionForSymbol())
     {
      double prospectiveEntry = state.trend == TREND_UP
                                ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(g_lastEntryPrice <= 0.0)
         g_lastEntryPrice = LatestManagedEntryPrice(state.trend);
      if(g_lastEntryPrice <= 0.0 ||
         MathAbs(prospectiveEntry - g_lastEntryPrice) <
         InpMinimumEntryGapAtr * state.atr)
         return;

      OpenTrade(state.trend, true);
      DrawPanel();
      return;
     }
   OpenTrade(state.trend);
   DrawPanel();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(InpSignalTimeframe != PERIOD_M5)
     {
      Print("Unsupported entry timeframe. Select M5.");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_signalPeriodSeconds = PeriodSeconds(InpSignalTimeframe);
   if(g_signalPeriodSeconds <= 0)
      return INIT_PARAMETERS_INCORRECT;

   g_liveSignalFile = "live_signal_" + RegimeFileSymbol() + ".csv";
   Print("Chart symbol ", Symbol(), ": live signal file=", g_liveSignalFile);

   if(InpBreakoutLookback < 2 || InpAtrPeriod < 1 || InpAdxPeriod < 1 ||
      InpBreakoutBufferAtr < 0.0 || InpLots <= 0.0 ||
      InpMinimumTrendAdx < 0.0 ||
      InpAtrTrailingMultiplier <= 0.0 ||
      InpTradeStartHour < 0 || InpTradeStartHour > 23 ||
      InpTradeEndHour < 1 || InpTradeEndHour > 24 ||
      InpTradeStartHour >= InpTradeEndHour ||
      InpProfitableExitBars < 1 ||
      InpTakeProfitAtrMultiplier <= 0.0 ||
      InpMaximumSameDirectionEntries < 1 || InpMinimumEntryGapAtr < 0.0)
      return INIT_PARAMETERS_INCORRECT;

   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   g_h1AtrHandle = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   if(InpUseAdxFilter)
      g_adxHandle = iADX(_Symbol, InpSignalTimeframe, InpAdxPeriod);
   g_fastEmaHandle = iMA(_Symbol, InpSignalTimeframe, 21,
                         0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(_Symbol, InpSignalTimeframe, 50,
                         0, MODE_EMA, PRICE_CLOSE);
   g_ema100Handle = iMA(_Symbol, InpSignalTimeframe, 100,
                        0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_h1AtrHandle == INVALID_HANDLE ||
      (InpUseAdxFilter && g_adxHandle == INVALID_HANDLE) ||
      g_fastEmaHandle == INVALID_HANDLE ||
      g_slowEmaHandle == INVALID_HANDLE || g_ema100Handle == INVALID_HANDLE)
     {
      Print("Unable to create ATR/ADX/EMA handles. Error ", GetLastError());
      return INIT_FAILED;
     }

   // The ATR line is also drawn in visual Strategy Tester runs.
   g_chartAtrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   if(g_chartAtrHandle == INVALID_HANDLE)
      return INIT_FAILED;

   // Chart EMA objects remain disabled in Strategy Tester.
   if(!g_isTester)
     {
      if(!CreateChartEma(21, g_chartEma21Handle) ||
         !CreateChartEma(50, g_chartEma50Handle) ||
         !CreateChartEma(100, g_chartEma100Handle))
         return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(!g_isTester)
      EventSetTimer(1);
   ProcessSignal();
   MaintainAtrProtectionStop();
   g_lastTesterBarBucket = (long)TimeCurrent() / g_signalPeriodSeconds;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteAtrProtectionOrders();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_h1AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_h1AtrHandle);
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
   if(g_chartAtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_chartAtrHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckProfitableAgeExit();
   ProcessSignal();
   CheckH1AtrDirectionExit();
   MaintainAtrProtectionStop();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CheckProfitableAgeExit();
   // Process the just-completed candle before recording touches for the new
   // candle, preserving the EMA21-touch + breakout pairing in live and test.
   long barBucket = (long)TimeCurrent() / g_signalPeriodSeconds;
   if(barBucket != g_lastTesterBarBucket)
     {
      g_lastTesterBarBucket = barBucket;
      ProcessSignal();
     }
   CheckH1AtrDirectionExit();
   MaintainAtrProtectionStop();

  }
//+------------------------------------------------------------------+
