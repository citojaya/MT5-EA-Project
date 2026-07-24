//+------------------------------------------------------------------+
//|                                                     live_EA.mq5  |
//| Trades the latest M5 ML signal written by the Python live engine.|
//+------------------------------------------------------------------+
#property copyright "Candlestick ML"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InpSignalFile = "signal_{symbol}_5M.csv"; // {symbol} = current chart symbol
input string InpRegimeFile = "latest_regime_{symbol}_M5.txt"; // {symbol} = current chart symbol
input bool   InpUseCommonFiles = false;              // false = terminal MQL5\Files
input double InpLots = 0.01;                         // Fixed trade volume
input bool   InpUseCsvConfidence = false;             // Require confidence threshold
input double InpMinimumConfidence = 0.70;            // Absolute confidence floor
input bool   InpUsePredLabelCheck = false;             // Require pred_label to match order direction
input bool   InpUseRegimeCheck = false;                 // Require strong regime to match order direction
input bool   InpCloseWhenUnqualified = false;         // Close when entry filters fail
input bool   InpCloseOnTransition = false;             // Close when regime becomes Transition
input bool   InpUseVolOkFilter = false;                // Require vol_ok=1 for new orders
input ENUM_TIMEFRAMES InpEmaTimeframe = PERIOD_M5;    // EMA calculation timeframe
input bool   InpUseEma9 = true;                       // Include EMA(9) in entry check and chart
input bool   InpUseEma21 = true;                      // Include EMA(21) in entry check and chart
input bool   InpUseEma200 = true;                       // Include EMA(200) in entry check and chart
input double InpMinimumEmaGapIncreaseAtr = 0.05;       // Required EMA(9)-EMA(21) gap increase in ATR
input bool   InpUseAdxFilter = true;                  // Require minimum ADX for new orders
input ENUM_TIMEFRAMES InpAdxTimeframe = PERIOD_M5;    // ADX calculation timeframe
input int    InpAdxPeriod = 14;                       // ADX calculation period
input double InpMinimumAdx = 25.0;                    // Minimum ADX for entry
input bool   InpUseCsvTrailingStop = false;            // Apply atr_trailing_stop from CSV
input double InpStopLossAtrMultiplier = 4.0;          // Initial SL distance in ATR
input double InpTakeProfitAtrMultiplier = 6.0;        // Initial TP distance in ATR
input double InpBreakEvenTriggerAtr = 3.0;             // Move SL after profit reaches this ATR multiple
input double InpBreakEvenOffsetAtr = 0.1;              // Lock this ATR multiple beyond entry
input int    InpTradeStartHour = 1;                   // Entry start, server time (inclusive)
input int    InpTradeEndHour = 22;                    // Entry end, server time (exclusive)
input int    InpRefreshSeconds = 1;                  // File polling interval
input int    InpDeviationPoints = 20;                // Maximum order deviation
input ulong  InpMagicNumber = 22222222;              // EA magic number
input bool             InpShowPanel = true;          // Display signal panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER; // Panel corner
input int              InpXOffset = 15;              // Panel X offset
input int              InpYOffset = 15;              // Panel Y offset
input int              InpFontSize = 10;             // Panel font size
input string           InpFontName = "Consolas";     // Panel font

CTrade g_trade;
int      g_adxHandle = INVALID_HANDLE;
int      g_ema9Handle = INVALID_HANDLE;
int      g_ema21Handle = INVALID_HANDLE;
int      g_ema200Handle = INVALID_HANDLE;
datetime g_lastSignalTime = 0;
datetime g_lastRegimeTime = 0;
double   g_activeTrailingStop = 0.0;
double   g_entryAtr = 0.0;
bool     g_fileOk = false;
string   g_lastFileError = "Waiting for signal file";
string   g_signalFile = "";
string   g_regimeFile = "";

#define PREFIX "MLEA_"

//+------------------------------------------------------------------+
string ResolveSymbolFile(string fileTemplate)
  {
   string fileSymbol = _Symbol;
   string lowerSymbol = fileSymbol;
   StringToLower(lowerSymbol);
   int symbolLength = StringLen(fileSymbol);
   if(symbolLength >= 2 && StringSubstr(lowerSymbol, symbolLength - 2) == ".a")
      fileSymbol = StringSubstr(fileSymbol, 0, symbolLength - 2);

   StringReplace(fileTemplate, "{symbol}", fileSymbol);
   StringReplace(fileTemplate, "{SYMBOL}", fileSymbol);
   return fileTemplate;
  }

struct LiveSignal
  {
   datetime time;
   int      predLabel;
   double   probDown;
   double   probUp;
   double   confidence;
   double   confidenceThreshold;
   double   atrPercentile;
   int      volOk;
   double   atr;
   double   nLoss;
   double   trailingStop;
   int      csvPosition;
  };

struct LiveRegime
  {
   datetime time;
   int      number;
   string   name;
  };

//+------------------------------------------------------------------+
datetime ParseSignalTime(string value)
  {
   if(StringLen(value) > 19)
      value = StringSubstr(value, 0, 19);
   StringReplace(value, "-", ".");
   return StringToTime(value);
  }

//+------------------------------------------------------------------+
bool ReadLatestRegime(LiveRegime &regime)
  {
   int flags = FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int handle = FileOpen(g_regimeFile, flags);
   if(handle == INVALID_HANDLE)
     {
      g_fileOk = false;
      g_lastFileError = "Cannot read " + g_regimeFile + " (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }

   string timeText = "";
   string regimeText = "";
   string regimeName = "";
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      int separator = StringFind(line, "=");
      if(separator < 1)
         continue;
      string key = StringSubstr(line, 0, separator);
      string value = StringSubstr(line, separator + 1);
      StringTrimLeft(key); StringTrimRight(key); StringToLower(key);
      StringTrimLeft(value); StringTrimRight(value);
      if(key == "time") timeText = value;
      else if(key == "regime") regimeText = value;
      else if(key == "regime_name") regimeName = value;
     }
   FileClose(handle);

   regime.time = ParseSignalTime(timeText);
   regime.number = (int)StringToInteger(regimeText);
   if(regimeName == "")
     {
      if(regime.number == 0) regimeName = "Strong Bull Trend";
      else if(regime.number == 2) regimeName = "Strong Bear Trend";
      else if(regime.number == 7) regimeName = "Transition";
     }
   regime.name = regimeName;
   if(regime.time <= 0 || regime.name == "")
     {
      g_fileOk = false;
      g_lastFileError = "Missing valid time/regime in " + g_regimeFile;
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool ReadLatestSignal(LiveSignal &signal)
  {
   int flags = FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int handle = FileOpen(g_signalFile, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      g_fileOk = false;
      g_lastFileError = "Cannot read " + g_signalFile + " (error " + IntegerToString(GetLastError()) + ")";
      return false;
     }

   // CSV columns:
   // time,open,high,low,close,bid,ask,pred_label,prob_down,prob_up,
   // confidence,conf_th_roll,atrp_pctl_m5,vol_ok,atr,nLoss,
   // atr_trailing_stop,pos
   for(int column = 0; column < 18 && !FileIsEnding(handle); column++)
      FileReadString(handle);

   bool found = false;
   while(!FileIsEnding(handle))
     {
      string timeText = FileReadString(handle);
      if(timeText == "" && FileIsEnding(handle))
         break;

      FileReadString(handle); // open
      FileReadString(handle); // high
      FileReadString(handle); // low
      FileReadString(handle); // close
      FileReadString(handle); // bid
      FileReadString(handle); // ask
      string predText       = FileReadString(handle);
      string probDownText   = FileReadString(handle);
      string probUpText     = FileReadString(handle);
      string confidenceText = FileReadString(handle);
      string thresholdText  = FileReadString(handle);
      string atrPctlText    = FileReadString(handle);
      string volOkText      = FileReadString(handle);
      string atrText        = FileReadString(handle);
      string nLossText      = FileReadString(handle);
      string trailingText   = FileReadString(handle);
      string positionText   = FileReadString(handle);

      datetime parsed = ParseSignalTime(timeText);
      if(parsed <= 0)
         continue;

      signal.time                = parsed;
      signal.predLabel           = (int)StringToInteger(predText);
      signal.probDown            = StringToDouble(probDownText);
      signal.probUp              = StringToDouble(probUpText);
      signal.confidence          = StringToDouble(confidenceText);
      signal.confidenceThreshold = StringToDouble(thresholdText);
      signal.atrPercentile       = StringToDouble(atrPctlText);
      signal.volOk               = (int)StringToInteger(volOkText);
      signal.atr                 = StringToDouble(atrText);
      signal.nLoss               = StringToDouble(nLossText);
      signal.trailingStop        = StringToDouble(trailingText);
      signal.csvPosition         = (int)StringToInteger(positionText);
      found = true;
     }

   FileClose(handle);
   g_fileOk = found;
   g_lastFileError = found ? "" : "No valid rows in " + g_signalFile;
   return found;
  }

//+------------------------------------------------------------------+
bool SelectManagedPosition(long &positionType)
  {
   if(!PositionSelect(_Symbol))
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      return false;
   positionType = PositionGetInteger(POSITION_TYPE);
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
bool CloseManagedPosition(string reason)
  {
   long positionType = -1;
   if(!SelectManagedPosition(positionType))
      return true;
   if(!g_trade.PositionClose(_Symbol))
     {
      Print("Close failed: ", reason, ". ", g_trade.ResultRetcodeDescription());
      return false;
     }
   g_activeTrailingStop = 0.0;
   g_entryAtr = 0.0;
   Print("Position closed: ", reason);
   return true;
  }

//+------------------------------------------------------------------+
bool IsWithinEntryHours()
  {
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   return currentTime.hour >= InpTradeStartHour
          && currentTime.hour < InpTradeEndHour;
  }

//+------------------------------------------------------------------+
bool IsStopValidForDirection(int direction, double stop)
  {
   if(!InpUseCsvTrailingStop || stop <= 0.0)
      return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return direction > 0 ? stop < bid : stop > ask;
  }

//+------------------------------------------------------------------+
double NormalizeStop(double stop)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(stop, digits);
  }

//+------------------------------------------------------------------+
void EnforceTrailingStop()
  {
   long positionType = -1;
   if(!SelectManagedPosition(positionType) || g_activeTrailingStop <= 0.0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(positionType == POSITION_TYPE_BUY && bid <= g_activeTrailingStop)
     {
      CloseManagedPosition("BUY reached CSV atr_trailing_stop");
      return;
     }
   if(positionType == POSITION_TYPE_SELL && ask >= g_activeTrailingStop)
     {
      CloseManagedPosition("SELL reached CSV atr_trailing_stop");
      return;
     }

   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   bool improves = positionType == POSITION_TYPE_BUY
                   ? (currentSl == 0.0 || g_activeTrailingStop > currentSl)
                   : (currentSl == 0.0 || g_activeTrailingStop < currentSl);
   if(improves && !g_trade.PositionModify(_Symbol, NormalizeStop(g_activeTrailingStop), currentTp))
      Print("Failed to update CSV trailing stop. ", g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void UpdateCsvStop(int direction, double trailingStop)
  {
   if(!IsStopValidForDirection(direction, trailingStop))
      return;

   double newStop = NormalizeStop(trailingStop);
   bool improves = direction > 0
                   ? (g_activeTrailingStop == 0.0 || newStop > g_activeTrailingStop)
                   : (g_activeTrailingStop == 0.0 || newStop < g_activeTrailingStop);
   if(improves)
      g_activeTrailingStop = newStop;
   EnforceTrailingStop();
  }

//+------------------------------------------------------------------+
bool OpenTrade(int direction, double trailingStop, double atr)
  {
   if(HasOpenPositionForSymbol())
     {
      Print("Open skipped: a position is already open for ", _Symbol);
      return false;
     }

   if(atr <= 0.0)
     {
      Print("Open skipped: CSV ATR is unavailable or invalid: ", atr);
      return false;
     }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeStop(direction > 0 ? ask - InpStopLossAtrMultiplier * atr
                                           : bid + InpStopLossAtrMultiplier * atr);
   double tp = NormalizeStop(direction > 0 ? ask + InpTakeProfitAtrMultiplier * atr
                                           : bid - InpTakeProfitAtrMultiplier * atr);

   bool opened = direction > 0
                  ? g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "ML +1 BUY")
                  : g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "ML -1 SELL");
   if(!opened)
     {
      Print("Open failed. ", g_trade.ResultRetcodeDescription(),
            ", direction=", direction, ", stop=", sl);
      return false;
     }

   g_activeTrailingStop = IsStopValidForDirection(direction, trailingStop)
                           ? NormalizeStop(trailingStop) : 0.0;
   g_entryAtr = atr;
   return true;
  }

//+------------------------------------------------------------------+
void ApplyBreakEven()
  {
   long positionType = -1;
   if(!SelectManagedPosition(positionType))
     {
      g_entryAtr = 0.0;
      return;
     }
   if(g_entryAtr <= 0.0)
      return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitDistance = positionType == POSITION_TYPE_BUY
                           ? bid - openPrice : openPrice - ask;
   if(profitDistance < InpBreakEvenTriggerAtr * g_entryAtr)
      return;

   double breakEvenSl = NormalizeStop(
                        positionType == POSITION_TYPE_BUY
                        ? openPrice + InpBreakEvenOffsetAtr * g_entryAtr
                        : openPrice - InpBreakEvenOffsetAtr * g_entryAtr);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   bool improves = positionType == POSITION_TYPE_BUY
                   ? (currentSl == 0.0 || breakEvenSl > currentSl)
                   : (currentSl == 0.0 || breakEvenSl < currentSl);
   if(improves && !g_trade.PositionModify(_Symbol, breakEvenSl, currentTp))
      Print("Break-even update failed. ", g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
bool GetAdxValue(datetime signalTime, double &value)
  {
   int shift = iBarShift(_Symbol, InpAdxTimeframe, signalTime, false);
   if(shift < 0)
     {
      Print("ADX filter: no candle found for signal at ", TimeToString(signalTime));
      return false;
     }

   double values[];
   if(CopyBuffer(g_adxHandle, 0, shift, 1, values) != 1 || values[0] == EMPTY_VALUE)
     {
      Print("ADX filter: value unavailable for signal at ", TimeToString(signalTime),
            ". Error ", GetLastError());
      return false;
     }

   value = values[0];
   return true;
  }

//+------------------------------------------------------------------+
bool GetIndicatorValue(int handle, ENUM_TIMEFRAMES timeframe, datetime signalTime,
                       string name, double &value)
  {
   int shift = iBarShift(_Symbol, timeframe, signalTime, false);
   if(shift < 0)
     {
      Print(name, " filter: no candle found for signal at ", TimeToString(signalTime));
      return false;
     }

   double values[];
   if(CopyBuffer(handle, 0, shift, 1, values) != 1 || values[0] == EMPTY_VALUE)
     {
      Print(name, " filter: value unavailable for signal at ", TimeToString(signalTime),
            ". Error ", GetLastError());
      return false;
     }
   value = values[0];
   return true;
  }

//+------------------------------------------------------------------+
bool GetPreviousIndicatorValue(int handle, ENUM_TIMEFRAMES timeframe, datetime signalTime,
                               string name, double &value)
  {
   int shift = iBarShift(_Symbol, timeframe, signalTime, false);
   if(shift < 0)
     {
      Print(name, " filter: no candle found for signal at ", TimeToString(signalTime));
      return false;
     }

   double values[];
   if(CopyBuffer(handle, 0, shift + 1, 1, values) != 1 || values[0] == EMPTY_VALUE)
     {
      Print(name, " filter: previous value unavailable for signal at ",
            TimeToString(signalTime), ". Error ", GetLastError());
      return false;
     }
   value = values[0];
   return true;
  }

//+------------------------------------------------------------------+
bool EmaPassed(datetime signalTime, int direction, double atr)
  {
   double ema9 = 0.0, ema21 = 0.0, ema200 = 0.0;
   double previousEma9 = 0.0, previousEma21 = 0.0;
   bool have9 = !InpUseEma9 ||
                GetIndicatorValue(g_ema9Handle, InpEmaTimeframe, signalTime, "EMA(9)", ema9);
   bool have21 = !InpUseEma21 ||
                 GetIndicatorValue(g_ema21Handle, InpEmaTimeframe, signalTime, "EMA(21)", ema21);
   bool have200 = !InpUseEma200 ||
                  GetIndicatorValue(g_ema200Handle, InpEmaTimeframe, signalTime, "EMA(200)", ema200);
   if(!have9 || !have21 || !have200)
      return false;

   if(InpUseEma9 && InpUseEma21)
     {
      if(atr <= 0.0 ||
         !GetPreviousIndicatorValue(g_ema9Handle, InpEmaTimeframe, signalTime,
                                    "EMA(9)", previousEma9) ||
         !GetPreviousIndicatorValue(g_ema21Handle, InpEmaTimeframe, signalTime,
                                    "EMA(21)", previousEma21))
         return false;

      double currentGap = MathAbs(ema9 - ema21);
      double previousGap = MathAbs(previousEma9 - previousEma21);
      double gapIncrease = currentGap - previousGap;
      double requiredIncrease = InpMinimumEmaGapIncreaseAtr * atr;
      if(gapIncrease < requiredIncrease)
        {
         Print("Trade skipped: EMA(9)/EMA(21) gap increase ",
               DoubleToString(gapIncrease, _Digits), " is below ",
               DoubleToString(requiredIncrease, _Digits), " (",
               DoubleToString(InpMinimumEmaGapIncreaseAtr, 2), " ATR)");
         return false;
        }
     }

   bool fastPassed = !InpUseEma9 || !InpUseEma21 ||
                     (direction > 0 ? ema9 > ema21 : ema9 < ema21);
   bool slowPassed = !InpUseEma21 || !InpUseEma200 ||
                     (direction > 0 ? ema21 > ema200 : ema21 < ema200);
   if(!fastPassed || !slowPassed)
     {
      Print("Trade skipped: EMA condition failed. EMA(9)=", DoubleToString(ema9, _Digits),
            ", EMA(21)=", DoubleToString(ema21, _Digits),
            ", EMA(200)=", DoubleToString(ema200, _Digits));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool AdxPassed(datetime signalTime)
  {
   if(!InpUseAdxFilter)
      return true;

   double adx = 0.0;
   if(!GetAdxValue(signalTime, adx))
      return false;

   if(adx < InpMinimumAdx)
     {
      Print("Trade skipped: ADX ", DoubleToString(adx, 2),
            " is below minimum ", DoubleToString(InpMinimumAdx, 2));
      return false;
     }
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void SetLabel(string name, string text, int x, int y, color clr, int fontSize = -1)
  {
   if(fontSize < 0)
      fontSize = InpFontSize;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
void DrawFileErrorPanel()
  {
   if(!InpShowPanel)
      return;
   int x = InpXOffset, y = InpYOffset;
   int lineH = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 430, lineH * 4 + 14);
   SetLabel(PREFIX + "title", "CANDLESTICK ML LIVE - FILE ERROR", x, y, clrRed, InpFontSize + 1);
   SetLabel(PREFIX + "l1", g_lastFileError, x, y + lineH, clrOrange);
   SetLabel(PREFIX + "l2", "Expected: " + g_signalFile, x, y + lineH * 2, clrSilver);
   SetLabel(PREFIX + "l3", "Regime:   " + g_regimeFile, x, y + lineH * 3, clrSilver);
   for(int i = 3; i < 20; i++)
      SetLabel(PREFIX + "l" + IntegerToString(i), "", x, y + lineH * i, clrGray);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void DrawPanel(const LiveSignal &signal, const LiveRegime &regime, double requiredConfidence,
               bool adxAvailable, double adxValue)
  {
   if(!InpShowPanel)
      return;
   int x = InpXOffset, y = InpYOffset;
   int lineH = InpFontSize + 8;
   int panelW = 430;
   int panelH = lineH * 20 + 14;
   SetBackground(PREFIX + "bg", x - 8, y - 8, panelW, panelH);

   string direction = signal.predLabel > 0 ? "BUY" :
                       signal.predLabel < 0 ? "SELL" : "FLAT";
   bool qualified = (!InpUseCsvConfidence || signal.confidence > requiredConfidence);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   long positionType = -1;
   bool hasPosition = SelectManagedPosition(positionType);
   string positionText = !hasPosition ? "FLAT" :
                         positionType == POSITION_TYPE_BUY ? "BUY" : "SELL";
   color directionCol = direction == "BUY" ? clrLimeGreen :
                        direction == "SELL" ? clrTomato : clrSilver;
   color qualifiedCol = qualified ? clrLimeGreen : clrRed;
   long ageSeconds = (long)(TimeCurrent() - signal.time);
   string ageText = ageSeconds >= 0 ? IntegerToString((int)(ageSeconds / 60)) + "m ago" : "future";
   color ageCol = ageSeconds > 600 ? clrRed : ageSeconds > 300 ? clrOrange : clrLimeGreen;
   double ema9 = 0.0, ema21 = 0.0, ema200 = 0.0;
   bool haveEma9 = InpUseEma9 &&
                   GetIndicatorValue(g_ema9Handle, InpEmaTimeframe, signal.time, "EMA(9)", ema9);
   bool haveEma21 = InpUseEma21 &&
                    GetIndicatorValue(g_ema21Handle, InpEmaTimeframe, signal.time, "EMA(21)", ema21);
   bool haveEma200 = InpUseEma200 &&
                     GetIndicatorValue(g_ema200Handle, InpEmaTimeframe, signal.time, "EMA(200)", ema200);
   bool fastEmaBullish = haveEma9 && haveEma21 && ema9 > ema21;
   bool slowEmaBullish = haveEma21 && haveEma200 && ema21 > ema200;
   double previousEma9 = 0.0, previousEma21 = 0.0;
   bool havePreviousEma9 = haveEma9 &&
                           GetPreviousIndicatorValue(g_ema9Handle, InpEmaTimeframe,
                                                     signal.time, "EMA(9)", previousEma9);
   bool havePreviousEma21 = haveEma21 &&
                            GetPreviousIndicatorValue(g_ema21Handle, InpEmaTimeframe,
                                                      signal.time, "EMA(21)", previousEma21);
   double absoluteGapIncrease = MathAbs(ema9 - ema21) -
                                MathAbs(previousEma9 - previousEma21);
   double requiredGapIncrease = InpMinimumEmaGapIncreaseAtr * signal.atr;
   bool gapDataAvailable = havePreviousEma9 && havePreviousEma21 && signal.atr > 0.0;
   bool gapIncreasing = gapDataAvailable && absoluteGapIncrease >= requiredGapIncrease;
   string fastEmaText = haveEma9 && haveEma21
                        ? "EMA(9)>EMA(21):  " + (fastEmaBullish ? "YES" : "NO") +
                          "  " + DoubleToString(ema9, digits) + " / " +
                          DoubleToString(ema21, digits)
                        : "EMA(9)>EMA(21):  unavailable";
   string slowEmaText = haveEma21 && haveEma200
                        ? "EMA(21)>EMA(200): " + (slowEmaBullish ? "YES" : "NO") +
                          "  " + DoubleToString(ema21, digits) + " / " +
                          DoubleToString(ema200, digits)
                        : "EMA(21)>EMA(200): unavailable";
   string gapRuleLabel = "EMA gap +" +
                         DoubleToString(InpMinimumEmaGapIncreaseAtr, 2) + "ATR: ";
   string gapIncreaseText = gapDataAvailable
                            ? gapRuleLabel + (gapIncreasing ? "TRUE" : "FALSE")
                            : gapRuleLabel + "unavailable";
   color gapIncreaseColor = gapIncreasing ? clrLimeGreen : clrRed;

   int i = 0;
   SetLabel(PREFIX + "title", "CANDLESTICK ML LIVE SIGNAL", x, y + lineH * i, clrWhite, InpFontSize + 1); i++;
   SetLabel(PREFIX + "l1", "Symbol:       " + _Symbol + "   [M5]", x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l2", "Signal Time:  " + TimeToString(signal.time, TIME_DATE | TIME_MINUTES), x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l3", "Signal Age:   " + ageText, x, y + lineH * i, ageCol); i++;
   SetLabel(PREFIX + "l4", "pred_label:   " + IntegerToString(signal.predLabel) + "  ->  " + direction, x, y + lineH * i, directionCol); i++;
   SetLabel(PREFIX + "l5", "Prob D/U:     " + DoubleToString(signal.probDown, 6) + " / " + DoubleToString(signal.probUp, 6), x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l6", "Confidence:   " + DoubleToString(signal.confidence * 100.0, 2) + "%", x, y + lineH * i, qualifiedCol); i++;
   SetLabel(PREFIX + "l7", "Threshold:    " + DoubleToString(requiredConfidence * 100.0, 2) + "%  [" + (qualified ? "PASS" : "FAIL") + "]", x, y + lineH * i, qualifiedCol); i++;
   bool adxPassed = adxAvailable && adxValue >= InpMinimumAdx;
   string adxText = !InpUseAdxFilter ? "ADX:          OFF" :
                    adxAvailable ? "ADX:          " + DoubleToString(adxValue, 2) +
                                   " / " + DoubleToString(InpMinimumAdx, 2) +
                                   "  [" + (adxPassed ? "PASS" : "FAIL") + "]" :
                                   "ADX:          unavailable";
   color adxColor = !InpUseAdxFilter ? clrSilver : adxPassed ? clrLimeGreen : clrRed;
   SetLabel(PREFIX + "l8", adxText, x, y + lineH * i, adxColor); i++;
   SetLabel(PREFIX + "l9", "ATR Pctl:     " + DoubleToString(signal.atrPercentile, 6) + "  vol_ok=" + IntegerToString(signal.volOk), x, y + lineH * i, signal.volOk == 1 ? clrLimeGreen : clrOrange); i++;
   SetLabel(PREFIX + "l10", "ATR / nLoss:  " + DoubleToString(signal.atr, 6) + " / " + DoubleToString(signal.nLoss, 6), x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l11", "CSV Stop:     " + DoubleToString(signal.trailingStop, digits), x, y + lineH * i, clrOrange); i++;
   SetLabel(PREFIX + "l12", "Regime:       #" + IntegerToString(regime.number) + " " + regime.name, x, y + lineH * i, clrAqua); i++;
   SetLabel(PREFIX + "l13", "EA Position:  " + positionText, x, y + lineH * i, positionText == "FLAT" ? clrSilver : clrAqua); i++;
   SetLabel(PREFIX + "l14", "EA Stop:      " + DoubleToString(g_activeTrailingStop, digits), x, y + lineH * i, clrOrange); i++;
   SetLabel(PREFIX + "l15", "Bid / Ask:    " + DoubleToString(bid, digits) + " / " + DoubleToString(ask, digits), x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l16", fastEmaText, x, y + lineH * i, fastEmaBullish ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l17", slowEmaText, x, y + lineH * i, slowEmaBullish ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l18", gapIncreaseText, x, y + lineH * i, gapIncreaseColor); i++;
   SetLabel(PREFIX + "l19", "Files:        ML signal + latest regime", x, y + lineH * i, clrSilver); i++;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void ProcessLatestSignal()
  {
   LiveSignal signal;
   if(!ReadLatestSignal(signal))
     {
      DrawFileErrorPanel();
      return;
     }

   LiveRegime regime;
   if(!ReadLatestRegime(regime))
     {
      DrawFileErrorPanel();
      return;
     }
   g_fileOk = true;
   g_lastFileError = "";

   double requiredConfidence = InpMinimumConfidence;
   if(InpUseCsvConfidence)
      requiredConfidence = MathMax(requiredConfidence, signal.confidenceThreshold);
   double adxValue = 0.0;
   bool adxAvailable = InpUseAdxFilter && GetAdxValue(signal.time, adxValue);
   DrawPanel(signal, regime, requiredConfidence, adxAvailable, adxValue);

   long positionType = -1;
   bool hasPosition = SelectManagedPosition(positionType);
   if(hasPosition)
      EnforceTrailingStop();

   bool newSignal = signal.time > g_lastSignalTime;
   bool newRegime = regime.time > g_lastRegimeTime;
   if(!newSignal && !newRegime)
      return;
   if(newSignal) g_lastSignalTime = signal.time;
   if(newRegime) g_lastRegimeTime = regime.time;

   string regimeName = regime.name;
   StringTrimLeft(regimeName);
   StringTrimRight(regimeName);
   StringToLower(regimeName);
   if(InpUseRegimeCheck && InpCloseOnTransition && regimeName == "transition")
     {
      CloseManagedPosition("regime changed to Transition");
      return;
     }

   // The requested rule is strict: confidence must be greater than threshold.
   bool confidencePassed = (!InpUseCsvConfidence || signal.confidence > requiredConfidence);
   bool strongBullish = (regimeName == "strong bull trend" || regimeName == "strong bullish");
   bool strongBearish = (regimeName == "strong bear trend" || regimeName == "strong bearish");
   bool buySignal = (!InpUsePredLabelCheck || signal.predLabel == 1) && confidencePassed &&
                    (!InpUseRegimeCheck || strongBullish);
   bool sellSignal = (!InpUsePredLabelCheck || signal.predLabel == -1) && confidencePassed &&
                     (!InpUseRegimeCheck || strongBearish);
   if(!buySignal && !sellSignal)
     {
      if(InpCloseWhenUnqualified)
         CloseManagedPosition("signal did not pass entry filters");
      return;
     }

   int desiredDirection = buySignal && sellSignal
                          ? (signal.predLabel == -1 ? -1 : 1)
                          : (buySignal ? 1 : -1);
   hasPosition = SelectManagedPosition(positionType);
   int currentDirection = !hasPosition ? 0 :
                           positionType == POSITION_TYPE_BUY ? 1 : -1;
   if(currentDirection == desiredDirection)
     {
      UpdateCsvStop(desiredDirection, signal.trailingStop);
      return;
     }

   if(InpUseVolOkFilter && signal.volOk != 1)
      return;

   if(!EmaPassed(signal.time, desiredDirection, signal.atr))
      return;

   if(!AdxPassed(signal.time))
      return;

   if(hasPosition)
     {
      CloseManagedPosition("opposite qualified signal");
      return;
     }
   if(!IsWithinEntryHours())
      return;
   OpenTrade(desiredDirection, signal.trailingStop, signal.atr);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_signalFile = ResolveSymbolFile(InpSignalFile);
   g_regimeFile = ResolveSymbolFile(InpRegimeFile);
   Print("Chart symbol ", _Symbol, ": signal file=", g_signalFile,
         ", regime file=", g_regimeFile);

   if(InpStopLossAtrMultiplier <= 0.0 || InpTakeProfitAtrMultiplier <= 0.0
      || InpBreakEvenTriggerAtr <= 0.0 || InpBreakEvenOffsetAtr < 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpMinimumEmaGapIncreaseAtr < 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpTradeStartHour < 0 || InpTradeStartHour > 23
      || InpTradeEndHour < 1 || InpTradeEndHour > 24
      || InpTradeStartHour >= InpTradeEndHour)
      return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(InpUseEma9)
      g_ema9Handle = iMA(_Symbol, InpEmaTimeframe, 9, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseEma21)
      g_ema21Handle = iMA(_Symbol, InpEmaTimeframe, 21, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseEma200)
      g_ema200Handle = iMA(_Symbol, InpEmaTimeframe, 200, 0, MODE_EMA, PRICE_CLOSE);
   if((InpUseEma9 && g_ema9Handle == INVALID_HANDLE) ||
      (InpUseEma21 && g_ema21Handle == INVALID_HANDLE) ||
      (InpUseEma200 && g_ema200Handle == INVALID_HANDLE))
     {
      Print("Cannot create one or more EMA indicator handles. Error ", GetLastError());
      return INIT_FAILED;
     }
   if(InpUseEma9 && !ChartIndicatorAdd(0, 0, g_ema9Handle))
      Print("Cannot plot EMA(9). Error ", GetLastError());
   if(InpUseEma21 && !ChartIndicatorAdd(0, 0, g_ema21Handle))
      Print("Cannot plot EMA(21). Error ", GetLastError());
   if(InpUseEma200 && !ChartIndicatorAdd(0, 0, g_ema200Handle))
      Print("Cannot plot EMA(200). Error ", GetLastError());
   if(InpUseAdxFilter)
     {
      g_adxHandle = iADX(_Symbol, InpAdxTimeframe, InpAdxPeriod);
      if(g_adxHandle == INVALID_HANDLE)
        {
         Print("Cannot create ADX indicator handle. Error ", GetLastError());
         return INIT_FAILED;
        }
     }
   EventSetTimer(MathMax(1, InpRefreshSeconds));
   ProcessLatestSignal();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
   if(g_ema9Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema9Handle);
   if(g_ema21Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema21Handle);
   if(g_ema200Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema200Handle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ProcessLatestSignal();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ApplyBreakEven();
   EnforceTrailingStop();
  }
//+------------------------------------------------------------------+
