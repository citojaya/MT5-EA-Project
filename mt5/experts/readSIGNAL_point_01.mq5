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
input string           InpFileName        = "latest_regime_*.txt"; // File name
input bool             InpUseCommonFolder = false;                // Read from Common Files (MQL5\..\Common\Files)
input int              InpRefreshSeconds  = 5;                   // Refresh interval (seconds)
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER;   // Panel corner
input int              InpXOffset         = 15;                  // X offset (px)
input int              InpYOffset         = 15;                  // Y offset (px)
input int              InpFontSize        = 10;                  // Font size
input string           InpFontName        = "Consolas";           // Font name
input int              InpStaleMinutes    = 15;                  // Minutes before data flagged stale
input bool             InpEnableTrading   = true;                // Enable trading from signal
input double           InpLots            = 0.01;                // Fixed position size
input int              InpAtrPeriod       = 14;                  // ATR period
input double           InpTakeProfitAtr   = 6.0;                 // Take profit in ATR multiples
input double           InpStopLossAtr     = 6.0;                 // Stop loss in ATR multiples
input double           InpBreakEvenAtAtr  = 2.5;                 // Move SL after profit reaches ATR multiple
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

//+------------------------------------------------------------------+
//| Convert chart symbol to signal-file symbol                        |
//+------------------------------------------------------------------+
string ChartSignalSymbol()
  {
   string symbol = _Symbol;
   int suffixPos = StringFind(symbol, ".a");
   if(suffixPos >= 0)
      symbol = StringSubstr(symbol, 0, suffixPos);
   return symbol;
  }

//+------------------------------------------------------------------+
//| Convert chart timeframe to signal-file timeframe text             |
//+------------------------------------------------------------------+
string ChartTimeframeString()
  {
   ENUM_TIMEFRAMES period = (ENUM_TIMEFRAMES)_Period;

   if(period == PERIOD_M1)  return "M1";
   if(period == PERIOD_M5)  return "M5";
   if(period == PERIOD_M15) return "M15";
   if(period == PERIOD_M30) return "M30";
   if(period == PERIOD_H1)  return "H1";
   if(period == PERIOD_H4)  return "H4";
   if(period == PERIOD_D1)  return "D1";

   return EnumToString(period);
  }

//+------------------------------------------------------------------+
//| Build the live signal file name from the chart symbol/timeframe   |
//+------------------------------------------------------------------+
string ChartSignalFileName()
  {
   return "latest_regime_" + ChartSignalSymbol() + "_" + ChartTimeframeString() + ".txt";
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   EventSetTimer(MathMax(1, InpRefreshSeconds));
   ReadAndDisplay();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
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
   string filename = ChartSignalFileName();
   g_fileOk = ReadKeyValueFile(filename, InpUseCommonFolder);
   DrawPanel();
   ProcessTradingSignal();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Parse a "key=value" per line text file into g_keys/g_vals         |
//+------------------------------------------------------------------+
bool ReadKeyValueFile(string filename, bool commonFolder)
  {
   g_count = 0;

   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(commonFolder)
      flags |= FILE_COMMON;

   int handle = FileOpen(filename, flags);
   if(handle == INVALID_HANDLE)
     {
      g_lastErr = "Cannot open file: " + filename + "  (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }

   while(!FileIsEnding(handle) && g_count < MAX_KV)
     {
      string line = FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0)
         continue;

      int pos = StringFind(line, "=");
      if(pos <= 0)
         continue;

      string key = StringSubstr(line, 0, pos);
      string val = StringSubstr(line, pos + 1);
      StringTrimLeft(key);  StringTrimRight(key);
      StringTrimLeft(val);  StringTrimRight(val);

      g_keys[g_count] = key;
      g_vals[g_count] = val;
      g_count++;
     }

   FileClose(handle);
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
   int handle = iATR(_Symbol, timeframe, InpAtrPeriod);
   if(handle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle. Error: ", GetLastError());
      return 0.0;
     }

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(handle, 0, 0, 1, atrBuffer) != 1)
     {
      Print("Failed to read ATR buffer. Error: ", GetLastError());
      IndicatorRelease(handle);
      return 0.0;
     }

   IndicatorRelease(handle);
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

   if(signalSymbol != ChartSignalSymbol())
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
