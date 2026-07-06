//+------------------------------------------------------------------+
//|                                            RegimeSignalPanel.mq5 |
//|   Reads a key=value regime-signal text file and displays it on   |
//|   the chart as a clean, auto-refreshing info panel.              |
//+------------------------------------------------------------------+
#property copyright "Regime Signal Panel"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs ----------------------------------------------------------
input string           InpFileName        = "XAUUSD_M5_backtest_signals.csv"; // File name
input bool             InpUseCommonFolder = true;               // Read from Common Files (MQL5\..\Common\Files)
input bool             InpUseTimer        = false;               // Process signals on timer instead of ticks
input int              InpRefreshSeconds  = 5;                   // Refresh interval (seconds)
input bool             InpShowPanel       = false;               // Draw chart panel
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER;   // Panel corner
input int              InpXOffset         = 15;                  // X offset (px)
input int              InpYOffset         = 15;                  // Y offset (px)
input int              InpFontSize        = 10;                  // Font size
input string           InpFontName        = "Consolas";           // Font name
input int              InpStaleMinutes    = 15;                  // Minutes before data flagged stale
input bool             InpEnableTrading   = true;                // Enable trading from signal
input double           InpLots            = 0.01;                // Fixed position size
input int              InpAtrPeriod       = 14;                  // ATR period
input double           InpTakeProfitAtr   = 3.0;                 // Take profit in ATR multiples
input double           InpStopLossAtr     = 2.0;                 // Stop loss in ATR multiples
input double           InpBreakEvenAtAtr  = 1.5;                 // Move SL after profit reaches ATR multiple
input double           InpBreakEvenPlusAtr= 0.2;                 // Break-even offset in ATR multiples
input ulong            InpMagicNumber     = 26070601;            // Magic number

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
int    g_selectedSignalIndex = -1;
int    g_atrHandle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_atrTimeframe = PERIOD_CURRENT;

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
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!InpUseTimer)
      ReadAndDisplay();

   ManageBreakEven();
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
//| Load selected row into key/value panel fields                     |
//+------------------------------------------------------------------+
void ProcessSignalFields(string &fields[])
  {
   if(ArraySize(fields) < 8)
      return;

   SetKeyValue("time",        fields[0]);
   SetKeyValue("symbol",      fields[1]);
   SetKeyValue("timeframe",   fields[2]);
   SetKeyValue("close",       fields[3]);
   SetKeyValue("regime",      fields[4]);
   SetKeyValue("regime_name", fields[5]);
   SetKeyValue("confidence",  fields[6]);
   SetKeyValue("updated_utc", fields[7]);
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

   g_signalTimes[rowIndex] = signalTime;
   g_signalTimeText[rowIndex] = fields[0];
   g_signalSymbols[rowIndex] = fields[1];
   g_signalTimeframes[rowIndex] = fields[2];
   g_signalClose[rowIndex] = fields[3];
   g_signalRegimes[rowIndex] = fields[4];
   g_signalRegimeNames[rowIndex] = fields[5];
   g_signalConfidence[rowIndex] = fields[6];
   g_signalUpdatedUtc[rowIndex] = fields[7];
  }

//+------------------------------------------------------------------+
//| Read signal CSV/TSV once                                          |
//+------------------------------------------------------------------+
bool LoadSignalCsv(string filename, bool commonFolder)
  {
   g_count = 0;
   for(int kvIndex = 0; kvIndex < MAX_KV; kvIndex++)
     {
      g_keys[kvIndex] = "";
      g_vals[kvIndex] = "";
     }

   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(commonFolder)
      flags |= FILE_COMMON;

   int handle = FileOpen(filename, flags);
   if(handle == INVALID_HANDLE)
     {
      g_lastErr = "Cannot open file: " + filename + "  (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }

   ArrayResize(g_signalTimes, 0);
   ArrayResize(g_signalTimeText, 0);
   ArrayResize(g_signalSymbols, 0);
   ArrayResize(g_signalTimeframes, 0);
   ArrayResize(g_signalClose, 0);
   ArrayResize(g_signalRegimes, 0);
   ArrayResize(g_signalRegimeNames, 0);
   ArrayResize(g_signalConfidence, 0);
   ArrayResize(g_signalUpdatedUtc, 0);

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
//| Select latest loaded signal row at/before tester time             |
//+------------------------------------------------------------------+
bool SelectSignalForTesterTime()
  {
   if(!g_signalsLoaded)
      return false;

   datetime testerTime = TimeCurrent();
   int signalCount = ArraySize(g_signalTimes);
   int previousIndex = g_selectedSignalIndex;

   if(g_selectedSignalIndex >= 0 && g_signalTimes[g_selectedSignalIndex] > testerTime)
      g_selectedSignalIndex = -1;

   int nextIndex = g_selectedSignalIndex + 1;
   while(nextIndex < signalCount && g_signalTimes[nextIndex] <= testerTime)
     {
      g_selectedSignalIndex = nextIndex;
      nextIndex++;
     }

   if(g_selectedSignalIndex < 0)
     {
      g_lastErr = "No signal row found at/before tester time: " + TimeToString(testerTime, TIME_DATE | TIME_MINUTES);
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
//| Get latest ATR value                                              |
//+------------------------------------------------------------------+
double GetAtrValue(ENUM_TIMEFRAMES timeframe)
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

   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuffer) != 1)
     {
      Print("Failed to read ATR buffer. Error: ", GetLastError());
      return 0.0;
     }

   return atrBuffer[0];
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
//| Place buy/sell based on the regime signal                         |
//+------------------------------------------------------------------+
void ProcessTradingSignal()
  {
   if(!InpEnableTrading || !g_fileOk)
      return;

   string signalSymbol = GetVal("symbol", "");
   string timeframe    = GetVal("timeframe", "");
   string regimeName   = GetVal("regime_name", "");
   string signalTime   = GetVal("time", "");

   if(signalSymbol != _Symbol)
      return;

   if(signalTime == "" || signalTime == g_lastTradeSignalTime)
      return;

   ManageBreakEven();

   if(HasManagedPosition())
      return;

   string regimeLower = regimeName;
   StringToLower(regimeLower);

   bool buySignal  = StringFind(regimeLower, "strong bull") >= 0;
   bool sellSignal = StringFind(regimeLower, "strong bear") >= 0;

   if(!buySignal && !sellSignal)
      return;

   ENUM_TIMEFRAMES atrTimeframe = TimeframeFromString(timeframe);
   double atr = GetAtrValue(atrTimeframe);
   if(atr <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool opened = false;

   if(buySignal)
     {
      double sl = NormalizeDouble(ask - InpStopLossAtr * atr, digits);
      double tp = NormalizeDouble(ask + InpTakeProfitAtr * atr, digits);
      opened = g_trade.Buy(InpLots, _Symbol, ask, sl, tp, "Strong Bull regime buy");
     }
   else if(sellSignal)
     {
      double sl = NormalizeDouble(bid + InpStopLossAtr * atr, digits);
      double tp = NormalizeDouble(bid - InpTakeProfitAtr * atr, digits);
      opened = g_trade.Sell(InpLots, _Symbol, bid, sl, tp, "Strong Bear regime sell");
     }

   if(opened)
     {
      g_lastTradeSignalTime = signalTime;
      Print("Opened trade from regime signal: ", regimeName, " at ", signalTime);
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
   if(!InpEnableTrading)
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
   int panelW  = 300;
   int panelH  = lineH * 9 + 14;

   SetBackground(PREFIX + "bg", x - 8, y - 8, panelW, panelH);

   if(!g_fileOk)
     {
      SetLabel(PREFIX + "title", "REGIME SIGNAL - FILE ERROR", x, y, clrRed, InpFontSize + 1);
      SetLabel(PREFIX + "l1", g_lastErr, x, y + lineH, clrOrange);
      for(int i = 2; i < 8; i++)
         SetLabel(PREFIX + "l" + IntegerToString(i), "", x, y + lineH * i, clrGray);
      return;
     }

   string sym        = GetVal("symbol",      "-");
   string tf          = GetVal("timeframe",   "-");
   string closeStr    = GetVal("close",       "-");
   string regimeNum   = GetVal("regime",      "-");
   string regimeName  = GetVal("regime_name", "-");
   string confStr     = GetVal("confidence",  "-");
   string sigTime     = GetVal("time",        "-");
   string updUtc      = GetVal("updated_utc", "-");

   double conf   = StringToDouble(confStr) * 100.0;
   color  regCol = RegimeColor(regimeName);

   // --- Freshness of the underlying data ---
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
   SetLabel(PREFIX + "l5", "Signal Time: " + sigTime,                              x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l6", "Updated UTC: " + updUtc,                               x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l7", "Data Age:    " + ageText,                              x, y + lineH * i, freshCol);  i++;
  }
//+------------------------------------------------------------------+
