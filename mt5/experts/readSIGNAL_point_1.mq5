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
input string           InpFileName        = "latest_regime_XAUUSD_M1.txt"; // File name
input bool             InpUseCommonFolder = false;                // Read from Common Files (MQL5\..\Common\Files)
input int              InpRefreshSeconds  = 5;                   // Refresh interval (seconds)
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER;   // Panel corner
input int              InpXOffset         = 15;                  // X offset (px)
input int              InpYOffset         = 15;                  // Y offset (px)
input int              InpFontSize        = 10;                  // Font size
input string           InpFontName        = "Consolas";           // Font name
input int              InpStaleMinutes    = 15;                  // Minutes before data flagged stale
input bool             InpEnableTrading   = true;                // Enable trading from signal
input string           InpTradeStartTime  = "02:00";             // Earliest time to open trades
input string           InpTradeEndTime    = "22:00";             // Latest time to open trades
input double           InpLots            = 0.1;                // Fixed position size
input int              InpAtrPeriod       = 14;                  // ATR period
input bool             InpUseAdxFilter    = true;                // Require minimum ADX for new trades
input int              InpAdxPeriod       = 14;                  // ADX period
input double           InpMinAdx          = 25.0;                // Minimum ADX for new trades
input double           InpTakeProfitAtr   = 9.0;                 // Take profit in ATR multiples
input double           InpStopLossAtr     = 6.0;                 // Stop loss in ATR multiples
input int              InpCloseAfterBars  = 5;                   // Close position after this many candles
input double           InpMinTradeConfidence = 0.60;             // Minimum confidence for new trades
input double           InpBreakEvenAtAtr  = 3.0;                 // Move SL after profit reaches ATR multiple
input double           InpBreakEvenPlusAtr= 0.4;                 // Break-even offset in ATR multiples
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
//| Check whether new trades are allowed at the current server time   |
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
   int handle = iATR(_Symbol, timeframe, InpAtrPeriod);
   if(handle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle. Error: ", GetLastError());
      return 0.0;
     }

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(handle, 0, bufferShift, 1, atrBuffer) != 1)
     {
      Print("Failed to read ATR buffer. Error: ", GetLastError());
      IndicatorRelease(handle);
      return 0.0;
     }

   IndicatorRelease(handle);
   return atrBuffer[0];
  }

//+------------------------------------------------------------------+
//| Get latest ADX value                                              |
//+------------------------------------------------------------------+
bool TryGetAdxValue(ENUM_TIMEFRAMES timeframe, double &adx, int bufferShift = 0)
  {
   int handle = iADX(_Symbol, timeframe, InpAdxPeriod);
   if(handle == INVALID_HANDLE)
     {
      Print("Failed to create ADX handle. Error: ", GetLastError());
      return false;
     }

   double adxBuffer[];
   ArraySetAsSeries(adxBuffer, true);

   if(CopyBuffer(handle, 0, bufferShift, 1, adxBuffer) != 1)
     {
      Print("Failed to read ADX buffer. Error: ", GetLastError());
      IndicatorRelease(handle);
      return false;
     }

   IndicatorRelease(handle);
   adx = adxBuffer[0];
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
//| Close this EA's open position on the chart symbol                 |
//+------------------------------------------------------------------+
void CloseManagedPosition(string reason)
  {
   if(!PositionSelect(_Symbol))
      return;

   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic != InpMagicNumber)
      return;

   if(g_trade.PositionClose(_Symbol))
      Print("Closed managed position: ", reason);
   else
      Print("Failed to close managed position. Reason: ", reason,
            ". Retcode: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
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
   string regimeName   = GetVal("regime_name", "");
   string confidenceStr= GetVal("confidence", "");
   string signalTime   = GetVal("time", "");

   if(signalSymbol != ChartSignalSymbol())
      return;

   if(signalTime == "" || signalTime == g_lastTradeSignalTime)
      return;

   string regimeLower = regimeName;
   StringToLower(regimeLower);

   if(StringFind(regimeLower, "transition") >= 0)
     {
      CloseManagedPosition("Transition regime");
      g_lastTradeSignalTime = signalTime;
      return;
     }

   ManageBreakEven();

   if(HasManagedPosition())
      return;

   bool buySignal  = StringFind(regimeLower, "strong bull") >= 0;
   bool sellSignal = StringFind(regimeLower, "strong bear") >= 0;

   if(!buySignal && !sellSignal)
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

   double ema9 = 0.0;
   double ema21 = 0.0;
   if(!TryGetEntryEmaValues(atrTimeframe, ema9, ema21))
      return;

   if((buySignal && ema9 <= ema21) || (sellSignal && ema9 >= ema21))
     {
      Print("Trade skipped by EMA filter. EMA(9) ", ema9,
            buySignal ? " must be above " : " must be below ",
            "EMA(21) ", ema21,
            " for regime signal: ", regimeName, " at ", signalTime);
      g_lastTradeSignalTime = signalTime;
      return;
     }

   double atr = GetAtrValue(atrTimeframe, 1);
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
      Print("Opened trade from regime signal: ", regimeName,
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
   int panelW  = 360;
   int panelH  = lineH * 10 + 14;

   SetBackground(PREFIX + "bg", x - 8, y - 8, panelW, panelH);

   if(!g_fileOk)
     {
      SetLabel(PREFIX + "title", "REGIME SIGNAL - FILE ERROR", x, y, clrRed, InpFontSize + 1);
      SetLabel(PREFIX + "l1", g_lastErr, x, y + lineH, clrOrange);
      for(int i = 2; i < 10; i++)
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
   ENUM_TIMEFRAMES panelTimeframe = TimeframeFromString(tf);
   double adx = GetAdxValue(panelTimeframe, 1);
   double ema9 = 0.0;
   double ema21 = 0.0;
   bool emaAvailable = TryGetEntryEmaValues(panelTimeframe, ema9, ema21);
   string regimeLower = regimeName;
   StringToLower(regimeLower);
   bool buySignal = StringFind(regimeLower, "strong bull") >= 0;
   bool sellSignal = StringFind(regimeLower, "strong bear") >= 0;
   bool emaPass = (buySignal && ema9 > ema21) || (sellSignal && ema9 < ema21);
   string emaRelation = !emaAvailable ? "unavailable" :
                        DoubleToString(ema9, 2) + (ema9 > ema21 ? " > " : (ema9 < ema21 ? " < " : " = ")) +
                        DoubleToString(ema21, 2);
   string emaStatus = (buySignal || sellSignal) ? (emaPass ? "PASS" : "FAIL") : "N/A";
   color emaCol = !emaAvailable ? clrOrange :
                  ((!buySignal && !sellSignal) ? clrSilver :
                  (emaPass ? clrLimeGreen : clrRed));
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
   SetLabel(PREFIX + "l5", "ADX:         " + DoubleToString(adx, 2) + " / min " + DoubleToString(InpMinAdx, 2), x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l6", "EMA(9/21):   " + emaRelation + "  [" + emaStatus + "]", x, y + lineH * i, emaCol); i++;
   SetLabel(PREFIX + "l7", "Signal Time: " + sigTime,                              x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l8", "Updated UTC: " + updUtc,                               x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l9", "Data Age:    " + ageText,                              x, y + lineH * i, freshCol);  i++;
  }
//+------------------------------------------------------------------+
