//+------------------------------------------------------------------+
//|                                      backtest_EA_regime.mq5      |
//|   Long/flat XAUUSD regime strategy. Long in regimes 1,2,5,7;    |
//|   flat otherwise. Signals are acted on after the source bar.     |
//+------------------------------------------------------------------+
#property copyright "Regime Backtest EA"
#property link      ""
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs ----------------------------------------------------------
input string           InpFileName        = "XAUUSD_M5_backtest_signals.csv"; // File name
input bool             InpUseCommonFolder = true;               // Read from Common Files (MQL5\..\Common\Files)
input bool             InpUseTimer        = false;               // Process signals on timer instead of ticks
input int              InpRefreshSeconds  = 5;                   // Refresh interval (seconds)
input bool             InpShowPanel       = true;                // Draw chart panel
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER;   // Panel corner
input int              InpXOffset         = 15;                  // X offset (px)
input int              InpYOffset         = 15;                  // Y offset (px)
input int              InpFontSize        = 10;                  // Font size
input string           InpFontName        = "Consolas";           // Font name
input int              InpStaleMinutes    = 15;                  // Minutes before data flagged stale
input bool             InpEnableTrading   = true;                // Enable trading from signal
input string           InpTradeStartTime  = "00:00";             // Earliest time to open trades
input string           InpTradeEndTime    = "23:59";             // Latest time to open trades
input double           InpLots            = 0.01;                // Fixed position size
input int              InpAtrPeriod       = 14;                  // ATR period
input bool             InpUseAdxFilter    = false;               // Optional ADX filter (not in analysed strategy)
input int              InpAdxPeriod       = 14;                  // ADX period
input double           InpMinAdx          = 25.0;                // Minimum ADX for new trades
input double           InpTakeProfitAtr   = 0.0;                 // Optional TP in ATR multiples; 0 disables
input double           InpStopLossAtr     = 0.0;                 // Optional SL in ATR multiples; 0 disables
input int              InpCloseAfterBars  = 0;                   // Optional time exit; 0 disables
input double           InpMinTradeConfidence = 0.0;              // Optional confidence floor; 0 disables
input bool             InpUseStage2Filter = false;                // Require stage 2 trade approval
input double           InpMinStage2Confidence = 0.55;            // Minimum stage 2 favorable probability
input bool             InpWaitForSignalCandleClose = true;       // Use signal one candle after CSV time
input bool             InpEnableBreakEven = false;               // Optional break-even (not in analysed strategy)
input double           InpBreakEvenAtAtr  = 3.0;                 // Move SL after profit reaches ATR multiple
input double           InpBreakEvenPlusAtr= 0.4;                 // Break-even offset in ATR multiples
input ulong            InpMagicNumber     = 26071701;            // Magic number

#define PREFIX  "RSP_"
#define MAX_KV  30

//--- Globals -----------------------------------------------------------
string g_keys[MAX_KV];
string g_vals[MAX_KV];
int    g_count   = 0;
bool   g_fileOk  = false;
string g_lastErr = "";
CTrade g_trade;
string g_lastTradeSignalTime = "";
bool   g_signalsLoaded = false;
datetime g_signalTimes[];
string g_signalTimeText[];
string g_signalSymbols[];
string g_signalTimeframes[];
string g_signalClose[];
string g_signalRegimes[];
string g_signalRegimeNames[];
string g_signalConfidence[];
string g_signalUpdatedUtc[];
string g_signalStage2Signals[];
string g_signalStage2Confidence[];
int    g_selectedSignalIndex = -1;
int    g_atrHandle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_atrTimeframe = PERIOD_CURRENT;
int    g_adxHandle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_adxTimeframe = PERIOD_CURRENT;
double g_latestAdx = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_signalsLoaded = LoadSignalCsv(InpFileName, InpUseCommonFolder);
   if(!g_signalsLoaded)
      Print(g_lastErr);
   if(InpUseTimer)
      EventSetTimer(MathMax(1, InpRefreshSeconds));
   ReadAndDisplay();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpUseTimer)
      EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!InpUseTimer)
      ReadAndDisplay();

   //ManageAdxExit();
   ManageBreakEven();
   ManageCandleExit();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ReadAndDisplay();
  }

//+------------------------------------------------------------------+
//| Read file, parse it, and redraw the panel                         |
//+------------------------------------------------------------------+
void ReadAndDisplay()
  {
   g_fileOk = SelectSignalForTesterTime();
   ProcessTradingSignal();
   if(InpShowPanel)
     {
      DrawPanel();
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
//| Store one key/value pair                                          |
//+------------------------------------------------------------------+
void SetKeyValue(string key, string val)
  {
   StringTrimLeft(key);  StringTrimRight(key);
   StringTrimLeft(val);  StringTrimRight(val);

   if(StringLen(key) == 0 || g_count >= MAX_KV)
      return;

   g_keys[g_count] = key;
   g_vals[g_count] = val;
   g_count++;
  }

//+------------------------------------------------------------------+
//| Split one CSV/TSV line                                            |
//+------------------------------------------------------------------+
int SplitSignalLine(string line, string &fields[])
  {
   StringTrimLeft(line);
   StringTrimRight(line);

   ushort delimiter = StringGetCharacter(",", 0);
   if(StringFind(line, "\t") >= 0)
      delimiter = StringGetCharacter("\t", 0);

   return StringSplit(line, delimiter, fields);
  }

//+------------------------------------------------------------------+
//| Store one CSV signal row in memory                                |
//+------------------------------------------------------------------+
void AppendSignalRow(string &fields[])
  {
   datetime signalTime = ParseUtcDateTime(fields[0]);
   if(signalTime <= 0)
      return;

   int rowIndex = ArraySize(g_signalTimes);
   ArrayResize(g_signalTimes, rowIndex + 1, 10000);
   ArrayResize(g_signalTimeText, rowIndex + 1, 10000);
   ArrayResize(g_signalSymbols, rowIndex + 1, 10000);
   ArrayResize(g_signalTimeframes, rowIndex + 1, 10000);
   ArrayResize(g_signalClose, rowIndex + 1, 10000);
   ArrayResize(g_signalRegimes, rowIndex + 1, 10000);
   ArrayResize(g_signalRegimeNames, rowIndex + 1, 10000);
   ArrayResize(g_signalConfidence, rowIndex + 1, 10000);
   ArrayResize(g_signalUpdatedUtc, rowIndex + 1, 10000);
   ArrayResize(g_signalStage2Signals, rowIndex + 1, 10000);
   ArrayResize(g_signalStage2Confidence, rowIndex + 1, 10000);

   g_signalTimes[rowIndex] = signalTime;
   g_signalTimeText[rowIndex] = fields[0];
   g_signalSymbols[rowIndex] = fields[1];
   g_signalTimeframes[rowIndex] = fields[2];
   g_signalClose[rowIndex] = fields[3];
   g_signalRegimes[rowIndex] = fields[4];
   g_signalRegimeNames[rowIndex] = fields[5];
   g_signalConfidence[rowIndex] = fields[6];
   g_signalUpdatedUtc[rowIndex] = fields[7];
   g_signalStage2Signals[rowIndex] = ArraySize(fields) > 8 ? fields[8] : "0";
   g_signalStage2Confidence[rowIndex] = ArraySize(fields) > 9 ? fields[9] : "0";
  }

//+------------------------------------------------------------------+
//| Read signal CSV/TSV once                                          |
//+------------------------------------------------------------------+
bool LoadSignalCsv(string filename, bool commonFolder)
  {
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(commonFolder)
      flags |= FILE_COMMON;

   int handle = FileOpen(filename, flags);
   if(handle == INVALID_HANDLE)
     {
      g_lastErr = "Cannot open file: " + filename + "  (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }

   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0)
         continue;

      string fields[];
      int fieldCount = SplitSignalLine(line, fields);
      if(fieldCount < 8)
         continue;

      string firstField = fields[0];
      StringToLower(firstField);
      if(firstField == "time")
         continue;

      AppendSignalRow(fields);
     }

   FileClose(handle);

   if(ArraySize(g_signalTimes) == 0)
     {
      g_lastErr = "No signal rows loaded from file: " + filename;
      return false;
     }

   g_lastErr = "";
   g_selectedSignalIndex = -1;
   return true;
  }

//+------------------------------------------------------------------+
//| Time when a loaded signal row is safe to use in tester            |
//+------------------------------------------------------------------+
datetime SignalReadyTime(int signalIndex)
  {
   datetime signalTime = g_signalTimes[signalIndex];
   if(!InpWaitForSignalCandleClose)
      return signalTime;

   ENUM_TIMEFRAMES signalTimeframe = TimeframeFromString(g_signalTimeframes[signalIndex]);
   int timeframeSeconds = PeriodSeconds(signalTimeframe);
   if(timeframeSeconds <= 0)
      timeframeSeconds = PeriodSeconds(_Period);

   return signalTime + timeframeSeconds;
  }

//+------------------------------------------------------------------+
//| Select latest loaded signal row once its candle has completed     |
//+------------------------------------------------------------------+
bool SelectSignalForTesterTime()
  {
   if(!g_signalsLoaded)
      return false;

   datetime testerTime = TimeCurrent();
   int signalCount = ArraySize(g_signalTimes);
   int previousIndex = g_selectedSignalIndex;

   if(g_selectedSignalIndex >= 0 && SignalReadyTime(g_selectedSignalIndex) > testerTime)
      g_selectedSignalIndex = -1;

   int nextIndex = g_selectedSignalIndex + 1;
   while(nextIndex < signalCount && SignalReadyTime(nextIndex) <= testerTime)
     {
      g_selectedSignalIndex = nextIndex;
      nextIndex++;
     }

   if(g_selectedSignalIndex < 0)
     {
      g_lastErr = "No ready signal row found at/before tester time: " + TimeToString(testerTime, TIME_DATE | TIME_MINUTES);
      return false;
     }

   if(g_selectedSignalIndex == previousIndex && g_count > 0)
      return true;

   g_count = 0;
   for(int kvIndex = 0; kvIndex < MAX_KV; kvIndex++)
     {
      g_keys[kvIndex] = "";
      g_vals[kvIndex] = "";
     }

   SetKeyValue("time",        g_signalTimeText[g_selectedSignalIndex]);
   SetKeyValue("symbol",      g_signalSymbols[g_selectedSignalIndex]);
   SetKeyValue("timeframe",   g_signalTimeframes[g_selectedSignalIndex]);
   SetKeyValue("close",       g_signalClose[g_selectedSignalIndex]);
   SetKeyValue("regime",      g_signalRegimes[g_selectedSignalIndex]);
   SetKeyValue("regime_name", g_signalRegimeNames[g_selectedSignalIndex]);
   SetKeyValue("confidence",  g_signalConfidence[g_selectedSignalIndex]);
   SetKeyValue("updated_utc", g_signalUpdatedUtc[g_selectedSignalIndex]);
   SetKeyValue("stage2_signal", g_signalStage2Signals[g_selectedSignalIndex]);
   SetKeyValue("stage2_confidence", g_signalStage2Confidence[g_selectedSignalIndex]);
   SetKeyValue("stage2_probability", g_signalStage2Confidence[g_selectedSignalIndex]);

   g_lastErr = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Lookup a value by key                                             |
//+------------------------------------------------------------------+
string GetVal(string key, string def = "")
  {
   for(int i = 0; i < g_count; i++)
      if(g_keys[i] == key)
         return g_vals[i];
   return def;
  }

//+------------------------------------------------------------------+
//| Parse "YYYY-MM-DD HH:MI:SS..." (UTC) into a datetime               |
//+------------------------------------------------------------------+
datetime ParseUtcDateTime(string s)
  {
   if(StringLen(s) < 19)
      return 0;

   MqlDateTime dt;
   dt.year = (int)StringToInteger(StringSubstr(s, 0, 4));
   dt.mon  = (int)StringToInteger(StringSubstr(s, 5, 2));
   dt.day  = (int)StringToInteger(StringSubstr(s, 8, 2));
   dt.hour = (int)StringToInteger(StringSubstr(s, 11, 2));
   dt.min  = (int)StringToInteger(StringSubstr(s, 14, 2));
   dt.sec  = (int)StringToInteger(StringSubstr(s, 17, 2));
   dt.day_of_week = 0;
   dt.day_of_year = 0;

   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Map a regime name to a display color                              |
//+------------------------------------------------------------------+
color RegimeColor(string regimeName)
  {
   string n = regimeName;
   StringToLower(n);

   if(StringFind(n, "low vol")  >= 0) return clrLimeGreen;
   if(StringFind(n, "high vol") >= 0) return clrRed;
   if(StringFind(n, "crash")    >= 0) return clrCrimson;
   if(StringFind(n, "trend")    >= 0) return clrDodgerBlue;
   if(StringFind(n, "range")    >= 0) return clrOrange;
   if(StringFind(n, "bull")     >= 0) return clrLimeGreen;
   if(StringFind(n, "bear")     >= 0) return clrRed;

   return clrSilver;
  }

//+------------------------------------------------------------------+
//| Convert timeframe text from signal file to MT5 timeframe          |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TimeframeFromString(string timeframeName)
  {
   string tf = timeframeName;
   StringToUpper(tf);

   if(tf == "M1")  return PERIOD_M1;
   if(tf == "M5")  return PERIOD_M5;
   if(tf == "M15") return PERIOD_M15;
   if(tf == "M30") return PERIOD_M30;
   if(tf == "H1")  return PERIOD_H1;
   if(tf == "H4")  return PERIOD_H4;
   if(tf == "D1")  return PERIOD_D1;

   return PERIOD_CURRENT;
  }

//+------------------------------------------------------------------+
//| Convert HH:MM time text to minutes from midnight                  |
//+------------------------------------------------------------------+
int TimeTextToMinutes(string timeText)
  {
   if(StringLen(timeText) < 5)
      return -1;

   int hour = (int)StringToInteger(StringSubstr(timeText, 0, 2));
   int minute = (int)StringToInteger(StringSubstr(timeText, 3, 2));

   if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
      return -1;

   return hour * 60 + minute;
  }

//+------------------------------------------------------------------+
//| Check whether new trades are allowed at the current tester time   |
//+------------------------------------------------------------------+
bool IsWithinTradeTime()
  {
   int startMinute = TimeTextToMinutes(InpTradeStartTime);
   int endMinute = TimeTextToMinutes(InpTradeEndTime);
   if(startMinute < 0 || endMinute < 0)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int currentMinute = now.hour * 60 + now.min;

   if(startMinute <= endMinute)
      return currentMinute >= startMinute && currentMinute <= endMinute;

   return currentMinute >= startMinute || currentMinute <= endMinute;
  }

//+------------------------------------------------------------------+
//| Get latest ATR value                                              |
//+------------------------------------------------------------------+
double GetAtrValue(ENUM_TIMEFRAMES timeframe, int bufferShift = 0)
  {
   if(g_atrHandle == INVALID_HANDLE || g_atrTimeframe != timeframe)
     {
      if(g_atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_atrHandle);

      g_atrHandle = iATR(_Symbol, timeframe, InpAtrPeriod);
      g_atrTimeframe = timeframe;

      if(g_atrHandle == INVALID_HANDLE)
        {
         Print("Failed to create ATR handle. Error: ", GetLastError());
         return 0.0;
        }
     }

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(g_atrHandle, 0, bufferShift, 1, atrBuffer) != 1)
     {
      Print("Failed to read ATR buffer. Error: ", GetLastError());
      return 0.0;
     }

   return atrBuffer[0];
  }

//+------------------------------------------------------------------+
//| Get latest ADX value                                              |
//+------------------------------------------------------------------+
bool TryGetAdxValue(ENUM_TIMEFRAMES timeframe, double &adx, int bufferShift = 0)
  {
   if(g_adxHandle == INVALID_HANDLE || g_adxTimeframe != timeframe)
     {
      if(g_adxHandle != INVALID_HANDLE)
         IndicatorRelease(g_adxHandle);

      g_adxHandle = iADX(_Symbol, timeframe, InpAdxPeriod);
      g_adxTimeframe = timeframe;

      if(g_adxHandle == INVALID_HANDLE)
        {
         Print("Failed to create ADX handle. Error: ", GetLastError());
         return false;
        }
     }

   double adxBuffer[];
   ArraySetAsSeries(adxBuffer, true);

   if(CopyBuffer(g_adxHandle, 0, bufferShift, 1, adxBuffer) != 1)
     {
      Print("Failed to read ADX buffer. Error: ", GetLastError());
      return false;
     }

   g_latestAdx = adxBuffer[0];
   adx = g_latestAdx;
   return true;
  }

double GetAdxValue(ENUM_TIMEFRAMES timeframe, int bufferShift = 0)
  {
   double adx = 0.0;
   TryGetAdxValue(timeframe, adx, bufferShift);
   return adx;
  }

//+------------------------------------------------------------------+
//| Read the fast and slow EMA values used by the entry filter        |
//+------------------------------------------------------------------+
bool TryGetEntryEmaValues(ENUM_TIMEFRAMES timeframe, double &ema9, double &ema21)
  {
   int ema9Handle = iMA(_Symbol, timeframe, 9, 0, MODE_EMA, PRICE_CLOSE);
   int ema21Handle = iMA(_Symbol, timeframe, 21, 0, MODE_EMA, PRICE_CLOSE);

   if(ema9Handle == INVALID_HANDLE || ema21Handle == INVALID_HANDLE)
     {
      Print("Failed to create EMA handles. Error: ", GetLastError());
      if(ema9Handle != INVALID_HANDLE)
         IndicatorRelease(ema9Handle);
      if(ema21Handle != INVALID_HANDLE)
         IndicatorRelease(ema21Handle);
      return false;
     }

   double ema9Buffer[];
   double ema21Buffer[];
   if(CopyBuffer(ema9Handle, 0, 1, 1, ema9Buffer) != 1 ||
      CopyBuffer(ema21Handle, 0, 1, 1, ema21Buffer) != 1)
     {
      Print("Failed to read EMA buffers. Error: ", GetLastError());
      IndicatorRelease(ema9Handle);
      IndicatorRelease(ema21Handle);
      return false;
     }

   ema9 = ema9Buffer[0];
   ema21 = ema21Buffer[0];
   IndicatorRelease(ema9Handle);
   IndicatorRelease(ema21Handle);
   return true;
  }

//+------------------------------------------------------------------+
//| Check if this EA already has an open position on the chart symbol |
//+------------------------------------------------------------------+
bool HasManagedPosition()
  {
   if(!PositionSelect(_Symbol))
      return false;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   return magic == InpMagicNumber;
  }

//+------------------------------------------------------------------+
//| Regimes selected by the chronological long/flat analysis         |
//+------------------------------------------------------------------+
bool IsLongRegime(string regime)
  {
   return regime == "1" || // Weak Bull Trend
          regime == "2" || // Strong Bear Trend (empirically long in this sample)
          regime == "5" || // High Volatility
          regime == "7";   // Transition
  }

//+------------------------------------------------------------------+
//| Close this EA's open position on the chart symbol                 |
//+------------------------------------------------------------------+
void CloseManagedPosition(string reason)
  {
   if(!PositionSelect(_Symbol))
      return;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return;

   if(!g_trade.PositionClose(_Symbol))
      Print("Failed to close position: ", reason, ". Retcode: ", g_trade.ResultRetcodeDescription());
   else
      Print("Closed position: ", reason);
  }

//+------------------------------------------------------------------+
//| Close this EA's position when ADX falls below the entry minimum   |
//+------------------------------------------------------------------+
void ManageAdxExit()
  {
   if(!InpEnableTrading || !InpUseAdxFilter || !HasManagedPosition())
      return;

   ENUM_TIMEFRAMES timeframe = TimeframeFromString(GetVal("timeframe", ""));
   double adx = 0.0;
   if(!TryGetAdxValue(timeframe, adx) || adx >= InpMinAdx)
      return;

   CloseManagedPosition(
      "ADX " + DoubleToString(adx, 2) +
      " below minimum " + DoubleToString(InpMinAdx, 2)
   );
  }

//+------------------------------------------------------------------+
//| Close managed position when the current regime no longer supports |
//| its direction                                                     |
//+------------------------------------------------------------------+
bool ClosePositionOnRegimeChange(string regime, string signalTime)
  {
   if(!PositionSelect(_Symbol))
      return false;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return false;

   if(!IsLongRegime(regime))
     {
      CloseManagedPosition("Regime " + regime + " is outside long set {1,2,5,7}");
      g_lastTradeSignalTime = signalTime;
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Close this EA's position after the configured candle count        |
//+------------------------------------------------------------------+
void ManageCandleExit()
  {
   if(!InpEnableTrading || InpCloseAfterBars <= 0)
      return;

   if(!PositionSelect(_Symbol))
      return;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return;

   string timeframe = GetVal("timeframe", "");
   ENUM_TIMEFRAMES exitTimeframe = TimeframeFromString(timeframe);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int barsSinceOpen = iBarShift(_Symbol, exitTimeframe, openTime, false);

   if(barsSinceOpen < InpCloseAfterBars)
      return;

   CloseManagedPosition(
      "Time exit after " + IntegerToString(InpCloseAfterBars) + " candles"
   );
  }

//+------------------------------------------------------------------+
//| Place buy/sell based on the regime signal                         |
//+------------------------------------------------------------------+
void ProcessTradingSignal()
  {
   if(!InpEnableTrading || !g_fileOk)
      return;

   string signalSymbol = GetVal("symbol", "");
   string timeframe    = GetVal("timeframe", "");
   string regime       = GetVal("regime", "");
   string regimeName   = GetVal("regime_name", "");
   string confidenceStr= GetVal("confidence", "");
   string stage2Signal = GetVal("stage2_signal", "0");
   string stage2ConfidenceStr = GetVal("stage2_confidence", "0");
   string signalTime   = GetVal("time", "");

   if(signalSymbol != _Symbol)
      return;

   if(signalTime == "" || signalTime == g_lastTradeSignalTime)
      return;

   if(ClosePositionOnRegimeChange(regime, signalTime))
      return;

   ManageBreakEven();

   if(HasManagedPosition())
     {
      g_lastTradeSignalTime = signalTime;
      return;
     }

   bool buySignal = IsLongRegime(regime);
   if(!buySignal)
      return;

   if(!IsWithinTradeTime())
     {
      Print("Trade skipped outside allowed time window ", InpTradeStartTime, "-", InpTradeEndTime,
            " for regime signal: ", regimeName, " at ", signalTime);
      g_lastTradeSignalTime = signalTime;
      return;
     }

   double confidence = StringToDouble(confidenceStr);
   if(confidence < InpMinTradeConfidence)
     {
      Print("Trade skipped. Confidence ", confidence, " is below minimum ", InpMinTradeConfidence,
            " for regime signal: ", regimeName, " at ", signalTime);
      g_lastTradeSignalTime = signalTime;
      return;
     }

   double stage2Confidence = StringToDouble(stage2ConfidenceStr);
   if(InpUseStage2Filter && (stage2Signal != "1" || stage2Confidence < InpMinStage2Confidence))
     {
      Print("Trade skipped by stage 2. Stage2 signal ", stage2Signal,
            ", confidence ", stage2Confidence,
            ", minimum ", InpMinStage2Confidence,
            " for regime signal: ", regimeName, " at ", signalTime);
      g_lastTradeSignalTime = signalTime;
      return;
     }

   ENUM_TIMEFRAMES atrTimeframe = TimeframeFromString(timeframe);
   double adx = GetAdxValue(atrTimeframe, 1);
   if(InpUseAdxFilter && adx < InpMinAdx)
     {
      Print("Trade skipped by ADX filter. ADX ", adx,
            " is below minimum ", InpMinAdx,
            " for regime signal: ", regimeName, " at ", signalTime);
      g_lastTradeSignalTime = signalTime;
      return;
     }

   double atr = 0.0;
   if(InpStopLossAtr > 0.0 || InpTakeProfitAtr > 0.0)
     {
      atr = GetAtrValue(atrTimeframe, 1);
      if(atr <= 0.0)
         return;
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = InpStopLossAtr > 0.0 ? NormalizeDouble(ask - InpStopLossAtr * atr, digits) : 0.0;
   double tp = InpTakeProfitAtr > 0.0 ? NormalizeDouble(ask + InpTakeProfitAtr * atr, digits) : 0.0;
   bool opened = g_trade.Buy(InpLots, _Symbol, ask, sl, tp, "Long regime " + regime);

   if(opened)
     {
      g_lastTradeSignalTime = signalTime;
      Print("Opened trade from regime signal: ", regimeName,
            ", stage2 signal ", stage2Signal,
            ", stage2 confidence ", stage2Confidence,
            ", ADX ", adx,
            " at ", signalTime);
     }
   else
     {
      Print("Trade open failed. Retcode: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Move stop loss to break-even plus offset after ATR profit         |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpEnableTrading || !InpEnableBreakEven)
      return;

   if(!PositionSelect(_Symbol))
      return;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return;

   string timeframe = GetVal("timeframe", "");
   ENUM_TIMEFRAMES atrTimeframe = TimeframeFromString(timeframe);
   double atr = GetAtrValue(atrTimeframe);
   if(atr <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long positionType = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(positionType == POSITION_TYPE_BUY)
     {
      double trigger = entry + InpBreakEvenAtAtr * atr;
      double newSl = NormalizeDouble(entry + InpBreakEvenPlusAtr * atr, digits);

      if(bid >= trigger && (currentSl == 0.0 || currentSl < newSl))
        {
         if(!g_trade.PositionModify(_Symbol, newSl, currentTp))
            Print("Failed to move BUY SL to break-even. Retcode: ", g_trade.ResultRetcodeDescription());
        }
     }
   else if(positionType == POSITION_TYPE_SELL)
     {
      double trigger = entry - InpBreakEvenAtAtr * atr;
      double newSl = NormalizeDouble(entry - InpBreakEvenPlusAtr * atr, digits);

      if(ask <= trigger && (currentSl == 0.0 || currentSl > newSl))
        {
         if(!g_trade.PositionModify(_Symbol, newSl, currentTp))
            Print("Failed to move SELL SL to break-even. Retcode: ", g_trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Create/update a text label object                                 |
//+------------------------------------------------------------------+
void SetLabel(string name, string text, int x, int y, color clr, int fontSize = -1)
  {
   if(fontSize < 0)
      fontSize = InpFontSize;

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| Create/update the panel's background rectangle                    |
//+------------------------------------------------------------------+
void SetBackground(string name, int x, int y, int w, int h)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,20,20');
     }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
  }

//+------------------------------------------------------------------+
//| Draw the whole info panel                                         |
//+------------------------------------------------------------------+
void DrawPanel()
  {
   int x       = InpXOffset;
   int y       = InpYOffset;
   int lineH   = InpFontSize + 8;
   int panelW  = 360;
   int panelH  = lineH * 11 + 14;

   SetBackground(PREFIX + "bg", x - 8, y - 8, panelW, panelH);

   if(!g_fileOk)
     {
      SetLabel(PREFIX + "title", "REGIME SIGNAL - FILE ERROR", x, y, clrRed, InpFontSize + 1);
      SetLabel(PREFIX + "l1", g_lastErr, x, y + lineH, clrOrange);
      for(int i = 2; i < 11; i++)
         SetLabel(PREFIX + "l" + IntegerToString(i), "", x, y + lineH * i, clrGray);
      return;
     }

   string sym        = GetVal("symbol",      "-");
   string tf          = GetVal("timeframe",   "-");
   string closeStr    = GetVal("close",       "-");
   string regimeNum   = GetVal("regime",      "-");
   string regimeName  = GetVal("regime_name", "-");
   string confStr     = GetVal("confidence",  "-");
   string stage2Signal= GetVal("stage2_signal", "-");
   string stage2ConfStr = GetVal("stage2_confidence", "-");
   string sigTime     = GetVal("time",        "-");
   string updUtc      = GetVal("updated_utc", "-");

   double conf   = StringToDouble(confStr) * 100.0;
   double stage2Conf = StringToDouble(stage2ConfStr) * 100.0;
   ENUM_TIMEFRAMES panelTimeframe = TimeframeFromString(tf);
   double adx = GetAdxValue(panelTimeframe, 1);
   bool longRegime = IsLongRegime(regimeNum);
   string strategyState = longRegime ? "LONG" : "FLAT";
   color strategyColor = longRegime ? clrLimeGreen : clrSilver;
   color  regCol = RegimeColor(regimeName);

   datetime updDt  = ParseUtcDateTime(updUtc);
   datetime nowUtc = TimeGMT();
   color freshCol  = clrLimeGreen;
   string ageText  = "n/a";

   if(updDt > 0)
     {
      long ageSec = (long)(nowUtc - updDt);
      long ageMin = ageSec / 60;
      ageText = (ageMin >= 0 ? IntegerToString(ageMin) + "m ago" : "in the future?");
      if(ageMin > InpStaleMinutes)          freshCol = clrRed;
      else if(ageMin > InpStaleMinutes / 2) freshCol = clrOrange;
     }

   int i = 0;
   SetLabel(PREFIX + "title", "REGIME SIGNAL", x, y + lineH * i, clrWhite, InpFontSize + 1); i++;
   SetLabel(PREFIX + "l1", "Symbol:      " + sym + "   [" + tf + "]",              x, y + lineH * i, clrWhite);  i++;
   SetLabel(PREFIX + "l2", "Close:       " + closeStr,                             x, y + lineH * i, clrWhite);  i++;
   SetLabel(PREFIX + "l3", "Regime:      #" + regimeNum + " " + regimeName,        x, y + lineH * i, regCol);    i++;
   SetLabel(PREFIX + "l4", "Confidence:  " + DoubleToString(conf, 2) + "%",        x, y + lineH * i, clrWhite);  i++;
   SetLabel(PREFIX + "l5", "Stage2:      " + stage2Signal + " / " + DoubleToString(stage2Conf, 2) + "%", x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l6", "ADX:         " + DoubleToString(adx, 2) + " / min " + DoubleToString(InpMinAdx, 2), x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l7", "Strategy:    " + strategyState + " (long set: 1,2,5,7)", x, y + lineH * i, strategyColor); i++;
   SetLabel(PREFIX + "l8", "Signal Time: " + sigTime,                              x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l9", "Updated UTC: " + updUtc,                               x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l10", "Data Age:    " + ageText,                             x, y + lineH * i, freshCol);  i++;
  }
//+------------------------------------------------------------------+
