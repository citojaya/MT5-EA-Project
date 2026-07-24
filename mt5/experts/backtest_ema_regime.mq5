//+------------------------------------------------------------------+
//|                                      backtest_ema_regime.mq5     |
//| Trades regime, EMA-gap and ADX signals in MT5 Strategy Tester.   |
//+------------------------------------------------------------------+
#property copyright "Candlestick ML"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string          InpSignalFile = "XAUUSD_M5_backtest_signals.csv"; // Regime signal CSV
input bool            InpUseCommonFiles = true;               // Read from Terminal Common Files
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5;          // CSV candle timeframe
input bool            InpTradeAfterCandleClose = true;         // Delay signal until its candle closes
input int             InpCsvToServerOffsetHours = 0;           // CSV UTC to tester-server offset

input double          InpMinimumConfidence = 0.95;              // Minimum regime confidence (strictly greater)
input ENUM_TIMEFRAMES InpEmaTimeframe = PERIOD_M5;               // EMA calculation timeframe
input bool            InpUseEma9 = true;                        // Plot EMA(9) on chart
input bool            InpUseEma21 = true;                       // Plot EMA(21) on chart
input bool            InpUseEma200 = false;                       // Include EMA(200) in entry check and chart
input double          InpMinimumEmaGapAtr = 0.01;                // Required absolute EMA-gap increase in ATR
input int             InpAdxPeriod = 14;                        // ADX calculation period
input double          InpMinimumAdx = 25.0;                     // Minimum ADX for entry

input double          InpLots = 0.01;                           // Fixed order volume
input bool            InpUseCsvTrailingStop = false;             // Apply atr_trailing_stop from CSV
input int             InpAtrPeriod = 14;                        // ATR period for initial SL/TP
input double          InpStopLossAtrMultiplier = 4.0;           // Initial SL distance in ATR
input double          InpTakeProfitAtrMultiplier = 6.0;         // Initial TP distance in ATR
input double          InpBreakEvenTriggerAtr = 3.0;              // Move SL after profit reaches this ATR multiple
input double          InpBreakEvenOffsetAtr = 0.1;               // Lock this ATR multiple beyond entry
input int             InpTradeStartHour = 1;                    // Entry start, server time (inclusive)
input int             InpTradeEndHour = 22;                     // Entry end, server time (exclusive)
input int             InpDeviationPoints = 20;                  // Maximum order deviation
input ulong           InpMagicNumber = 26071901;                // EA magic number
input bool            InpCloseAtEndOfSignals = false;           // Close after final signal candle
input bool             InpShowPanel = true;                      // Display backtest signal panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;       // Panel corner
input int              InpXOffset = 15;                          // Panel X offset
input int              InpYOffset = 15;                          // Panel Y offset
input int              InpFontSize = 10;                         // Panel font size
input string           InpFontName = "Consolas";                 // Panel font

CTrade g_trade;
int    g_adxHandle = INVALID_HANDLE;
int    g_ema9Handle = INVALID_HANDLE;
int    g_ema21Handle = INVALID_HANDLE;
int    g_ema200Handle = INVALID_HANDLE;
int    g_atrHandle = INVALID_HANDLE;

datetime g_times[];
int      g_predLabels[];
double   g_confidences[];
double   g_confThresholds[];
double   g_trailingStops[];
string   g_regimeNames[];
int      g_volOk[];
int      g_signalCount = 0;
int      g_nextSignal = 0;
bool     g_endHandled = false;
double   g_entryAtr = 0.0;
int      g_lastPanelIndex = -1;

#define PREFIX "MLBT_"

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
datetime ParseSignalTime(string value)
  {
   if(StringLen(value) >= 19)
      value = StringSubstr(value, 0, 19);
   StringReplace(value, "-", ".");
   datetime parsed = StringToTime(value);
   if(parsed <= 0)
      return 0;
   return parsed + InpCsvToServerOffsetHours * 3600;
  }

//+------------------------------------------------------------------+
datetime EffectiveSignalTime(int index)
  {
   datetime result = g_times[index];
   if(InpTradeAfterCandleClose)
      result += PeriodSeconds(InpSignalTimeframe);
   return result;
  }

//+------------------------------------------------------------------+
bool LoadSignals()
  {
   int flags = FILE_READ | FILE_CSV | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int handle = FileOpen(InpSignalFile, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("Cannot open signal file ", InpSignalFile,
            ". Error ", GetLastError(),
            InpUseCommonFiles ? " (Common Files)" : " (terminal Files)");
      return false;
     }

   string headers[];
   while(!FileIsEnding(handle))
     {
      int n = ArraySize(headers);
      ArrayResize(headers, n + 1);
      headers[n] = FileReadString(handle);
      if(FileIsLineEnding(handle))
         break;
     }

   int timeCol       = HeaderIndex(headers, "time");
   int confidenceCol = HeaderIndex(headers, "confidence");
   int regimeNameCol = HeaderIndex(headers, "regime_name");
   if(timeCol < 0 || confidenceCol < 0 || regimeNameCol < 0)
     {
      Print("Regime signal CSV is missing one or more required columns: "
            "time, regime_name, confidence");
      FileClose(handle);
      return false;
     }

   ArrayResize(g_times, 1024);
   ArrayResize(g_predLabels, 1024);
   ArrayResize(g_confidences, 1024);
   ArrayResize(g_confThresholds, 1024);
   ArrayResize(g_trailingStops, 1024);
   ArrayResize(g_regimeNames, 1024);
   ArrayResize(g_volOk, 1024);

   while(!FileIsEnding(handle))
     {
      string fields[];
      ArrayResize(fields, ArraySize(headers));
      for(int column = 0; column < ArraySize(headers); column++)
         fields[column] = FileReadString(handle);

      string timeText = fields[timeCol];
      if(timeText == "" && FileIsEnding(handle))
         break;

      datetime signalTime = ParseSignalTime(timeText);
      if(signalTime <= 0)
        {
         Print("Skipping signal with invalid time: ", timeText);
         continue;
        }

      if(g_signalCount >= ArraySize(g_times))
        {
         int newSize = ArraySize(g_times) + 4096;
         ArrayResize(g_times, newSize);
         ArrayResize(g_predLabels, newSize);
         ArrayResize(g_confidences, newSize);
         ArrayResize(g_confThresholds, newSize);
         ArrayResize(g_trailingStops, newSize);
         ArrayResize(g_regimeNames, newSize);
         ArrayResize(g_volOk, newSize);
        }

      g_times[g_signalCount]          = signalTime;
      g_predLabels[g_signalCount]     = 0;
      g_confidences[g_signalCount]    = StringToDouble(fields[confidenceCol]);
      g_confThresholds[g_signalCount] = InpMinimumConfidence;
      g_trailingStops[g_signalCount]  = 0.0;
      g_regimeNames[g_signalCount]    = fields[regimeNameCol];
      g_volOk[g_signalCount]          = 1;
      g_signalCount++;
     }

   FileClose(handle);
   ArrayResize(g_times, g_signalCount);
   ArrayResize(g_predLabels, g_signalCount);
   ArrayResize(g_confidences, g_signalCount);
   ArrayResize(g_confThresholds, g_signalCount);
   ArrayResize(g_trailingStops, g_signalCount);
   ArrayResize(g_regimeNames, g_signalCount);
   ArrayResize(g_volOk, g_signalCount);

   if(g_signalCount == 0)
     {
      Print("No valid signals loaded from ", InpSignalFile);
      return false;
     }

   Print("Loaded ", g_signalCount, " signals from ", InpSignalFile,
         ". First: ", TimeToString(g_times[0]),
         ", last: ", TimeToString(g_times[g_signalCount - 1]));
   return true;
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
   g_entryAtr = 0.0;
   Print("Position closed: ", reason);
   return true;
  }

//+------------------------------------------------------------------+
double ValidCsvStop(int direction, double csvStop)
  {
   if(!InpUseCsvTrailingStop || csvStop <= 0.0)
      return 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(direction > 0 && csvStop < bid)
      return NormalizeDouble(csvStop, digits);
   if(direction < 0 && csvStop > ask)
      return NormalizeDouble(csvStop, digits);
   return 0.0;
  }

//+------------------------------------------------------------------+
bool GetSignalAtr(int index, double &atr)
  {
   int shift = iBarShift(_Symbol, InpSignalTimeframe, g_times[index], false);
   if(shift < 0)
      return false;
   double values[];
   if(CopyBuffer(g_atrHandle, 0, shift, 1, values) != 1
      || values[0] == EMPTY_VALUE || values[0] <= 0.0)
      return false;
   atr = values[0];
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
void BuildStops(int direction, double atr, double &sl, double &tp)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   sl = NormalizeDouble(direction > 0 ? ask - InpStopLossAtrMultiplier * atr
                                      : bid + InpStopLossAtrMultiplier * atr, digits);
   tp = NormalizeDouble(direction > 0 ? ask + InpTakeProfitAtrMultiplier * atr
                                      : bid - InpTakeProfitAtrMultiplier * atr, digits);
  }

//+------------------------------------------------------------------+
bool OpenPosition(int direction, int signalIndex)
  {
   if(HasOpenPositionForSymbol())
     {
      Print("Open skipped: a position is already open for ", _Symbol);
      return false;
     }

   double atr = 0.0;
   if(!GetSignalAtr(signalIndex, atr))
     {
      Print("Open skipped: ATR unavailable at ", TimeToString(g_times[signalIndex]));
      return false;
     }
   double sl = 0.0, tp = 0.0;
   BuildStops(direction, atr, sl, tp);
   bool opened = direction > 0
                 ? g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "ML bullish signal")
                 : g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "ML bearish signal");
   if(!opened)
      Print("Open failed. ", g_trade.ResultRetcodeDescription(),
            ", direction=", direction, ", SL=", sl, ", TP=", tp);
   else
      g_entryAtr = atr;
   return opened;
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

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double breakEvenSl = NormalizeDouble(
                        positionType == POSITION_TYPE_BUY
                        ? openPrice + InpBreakEvenOffsetAtr * g_entryAtr
                        : openPrice - InpBreakEvenOffsetAtr * g_entryAtr,
                        digits);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   bool improves = positionType == POSITION_TYPE_BUY
                   ? (currentSl == 0.0 || breakEvenSl > currentSl)
                   : (currentSl == 0.0 || breakEvenSl < currentSl);
   if(improves && !g_trade.PositionModify(_Symbol, breakEvenSl, currentTp))
      Print("Break-even update failed. ", g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
bool AdxPassed(int index)
  {
   int shift = iBarShift(_Symbol, InpSignalTimeframe, g_times[index], false);
   if(shift < 0)
     {
      Print("ADX filter: no candle found for signal at ", TimeToString(g_times[index]));
      return false;
     }

   double adx[];
   if(CopyBuffer(g_adxHandle, 0, shift, 1, adx) != 1 || adx[0] == EMPTY_VALUE)
     {
      Print("ADX filter: value unavailable for signal at ", TimeToString(g_times[index]),
            ". Error ", GetLastError());
      return false;
     }
   return adx[0] > InpMinimumAdx;
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
bool GetPreviousIndicatorValue(int handle, ENUM_TIMEFRAMES timeframe,
                               datetime signalTime, string name, double &value)
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
bool EmaPassed(int index, int direction)
  {
   double ema9 = 0.0, ema21 = 0.0, ema200 = 0.0;
   bool have9 = GetIndicatorValue(g_ema9Handle, InpEmaTimeframe,
                                  g_times[index], "EMA(9)", ema9);
   bool have21 = GetIndicatorValue(g_ema21Handle, InpEmaTimeframe,
                                   g_times[index], "EMA(21)", ema21);
   bool have200 = !InpUseEma200 ||
                  GetIndicatorValue(g_ema200Handle, InpEmaTimeframe, g_times[index], "EMA(200)", ema200);
   if(!have9 || !have21 || !have200)
      return false;

   bool fastPassed = direction > 0 ? ema9 > ema21 : ema9 < ema21;
   bool slowPassed = !InpUseEma21 || !InpUseEma200 ||
                     (direction > 0 ? ema21 > ema200 : ema21 < ema200);
   if(!fastPassed || !slowPassed)
     {
      Print("Trade skipped: EMA condition failed. EMA(9)=", DoubleToString(ema9, _Digits),
            ", EMA(21)=", DoubleToString(ema21, _Digits),
            ", EMA(200)=", DoubleToString(ema200, _Digits));
      return false;
     }

   if(InpMinimumEmaGapAtr > 0.0)
     {
      double atr = 0.0;
      if(!GetSignalAtr(index, atr))
        {
         Print("Trade skipped: ATR unavailable for EMA divergence check at ",
               TimeToString(g_times[index]));
         return false;
        }

      double previousEma9 = 0.0, previousEma21 = 0.0;
      if(!GetPreviousIndicatorValue(g_ema9Handle, InpEmaTimeframe, g_times[index],
                                    "EMA(9)", previousEma9) ||
         !GetPreviousIndicatorValue(g_ema21Handle, InpEmaTimeframe, g_times[index],
                                    "EMA(21)", previousEma21))
         return false;

      double gapIncrease = MathAbs(ema9 - ema21) -
                           MathAbs(previousEma9 - previousEma21);
      double minimumIncrease = InpMinimumEmaGapAtr * atr;
      if(gapIncrease < minimumIncrease)
        {
         Print("Trade skipped: absolute EMA(9)-EMA(21) gap increase ",
               DoubleToString(gapIncrease, _Digits),
               " is below minimum ", DoubleToString(minimumIncrease, _Digits),
               " (", DoubleToString(InpMinimumEmaGapAtr, 2), " ATR)");
         return false;
        }
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
void DrawBacktestPanel(int index)
  {
   if(!InpShowPanel || index < 0 || index >= g_signalCount)
      return;

   int x = InpXOffset, y = InpYOffset;
   int lineH = InpFontSize + 8;
   SetBackground(PREFIX + "bg", x - 8, y - 8, 480, lineH * 17 + 14);

   string regime = g_regimeNames[index];
   StringTrimLeft(regime);
   StringTrimRight(regime);
   StringToLower(regime);
   bool bullishRegime = regime == "strong bull trend";
   bool bearishRegime = regime == "strong bear trend";
   bool exitRegime = regime == "transition" || regime == "range";
   bool confidencePassed = g_confidences[index] > InpMinimumConfidence;

   double adxValue = 0.0;
   int adxShift = iBarShift(_Symbol, InpSignalTimeframe, g_times[index], false);
   double adxValues[];
   bool adxAvailable = adxShift >= 0 &&
                       CopyBuffer(g_adxHandle, 0, adxShift, 1, adxValues) == 1 &&
                       adxValues[0] != EMPTY_VALUE;
   if(adxAvailable)
      adxValue = adxValues[0];
   bool adxPassed = adxAvailable && adxValue > InpMinimumAdx;

   double atr = 0.0;
   bool atrAvailable = GetSignalAtr(index, atr);
   double ema9 = 0.0, ema21 = 0.0;
   double previousEma9 = 0.0, previousEma21 = 0.0;
   bool emaAvailable =
      GetIndicatorValue(g_ema9Handle, InpEmaTimeframe, g_times[index], "EMA(9)", ema9) &&
      GetIndicatorValue(g_ema21Handle, InpEmaTimeframe, g_times[index], "EMA(21)", ema21);
   bool previousEmaAvailable = emaAvailable &&
      GetPreviousIndicatorValue(g_ema9Handle, InpEmaTimeframe, g_times[index],
                                "EMA(9)", previousEma9) &&
      GetPreviousIndicatorValue(g_ema21Handle, InpEmaTimeframe, g_times[index],
                                "EMA(21)", previousEma21);
   double gapIncrease = previousEmaAvailable
                        ? MathAbs(ema9 - ema21) -
                          MathAbs(previousEma9 - previousEma21) : 0.0;
   double requiredGapIncrease = InpMinimumEmaGapAtr * atr;
   bool gapPassed = atrAvailable && previousEmaAvailable &&
                    gapIncrease >= requiredGapIncrease;
   bool buyEmaPassed = emaAvailable && ema9 > ema21;
   bool sellEmaPassed = emaAvailable && ema9 < ema21;
   bool buyReady = bullishRegime && confidencePassed && buyEmaPassed &&
                   adxPassed && gapPassed;
   bool sellReady = bearishRegime && confidencePassed && sellEmaPassed &&
                    adxPassed && gapPassed;

   long positionType = -1;
   bool hasPosition = SelectManagedPosition(positionType);
   string positionText = !hasPosition ? "FLAT" :
                         positionType == POSITION_TYPE_BUY ? "BUY" : "SELL";
   double currentSl = hasPosition ? PositionGetDouble(POSITION_SL) : 0.0;
   double currentTp = hasPosition ? PositionGetDouble(POSITION_TP) : 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   int i = 0;
   SetLabel(PREFIX + "title", "EMA REGIME BACKTEST", x, y + lineH * i, clrWhite, InpFontSize + 1); i++;
   SetLabel(PREFIX + "l1", "Symbol:       " + _Symbol + "   [" + EnumToString(InpSignalTimeframe) + "]", x, y + lineH * i, clrWhite); i++;
   SetLabel(PREFIX + "l2", "Signal Time:  " + TimeToString(g_times[index], TIME_DATE | TIME_MINUTES), x, y + lineH * i, clrSilver); i++;
   SetLabel(PREFIX + "l3", "Regime:       " + g_regimeNames[index], x, y + lineH * i, bullishRegime || bearishRegime ? clrLimeGreen : clrAqua); i++;
   SetLabel(PREFIX + "l4", "Strong Bull:  " + (bullishRegime ? "TRUE" : "FALSE"), x, y + lineH * i, bullishRegime ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l5", "Strong Bear:  " + (bearishRegime ? "TRUE" : "FALSE"), x, y + lineH * i, bearishRegime ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l6", "Confidence:   " + DoubleToString(g_confidences[index], 6) + " > " + DoubleToString(InpMinimumConfidence, 2) + " [" + (confidencePassed ? "PASS" : "FAIL") + "]", x, y + lineH * i, confidencePassed ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l7", "EMA9 > EMA21: " + (buyEmaPassed ? "TRUE" : "FALSE"), x, y + lineH * i, buyEmaPassed ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l8", "EMA9 < EMA21: " + (sellEmaPassed ? "TRUE" : "FALSE"), x, y + lineH * i, sellEmaPassed ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l9", "EMA9 / EMA21: " + (emaAvailable ? DoubleToString(ema9, digits) + " / " + DoubleToString(ema21, digits) : "unavailable"), x, y + lineH * i, emaAvailable ? clrWhite : clrRed); i++;
   SetLabel(PREFIX + "l10", "ADX > " + DoubleToString(InpMinimumAdx, 0) + ":     " + (adxPassed ? "TRUE" : "FALSE") + (adxAvailable ? "  (" + DoubleToString(adxValue, 2) + ")" : ""), x, y + lineH * i, adxPassed ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l11", "Gap +" + DoubleToString(InpMinimumEmaGapAtr, 2) + "ATR: " + (gapPassed ? "TRUE" : "FALSE") + (previousEmaAvailable && atrAvailable ? "  (" + DoubleToString(gapIncrease, digits) + " / " + DoubleToString(requiredGapIncrease, digits) + ")" : ""), x, y + lineH * i, gapPassed ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l12", "BUY ready:    " + (buyReady ? "TRUE" : "FALSE") + "   SELL ready: " + (sellReady ? "TRUE" : "FALSE"), x, y + lineH * i, buyReady || sellReady ? clrLimeGreen : clrRed); i++;
   SetLabel(PREFIX + "l13", "Exit regime:  " + (exitRegime ? "TRUE" : "FALSE"), x, y + lineH * i, exitRegime ? clrOrange : clrSilver); i++;
   SetLabel(PREFIX + "l14", "EA Position:  " + positionText, x, y + lineH * i, hasPosition ? clrAqua : clrSilver); i++;
   SetLabel(PREFIX + "l15", "SL / TP:      " + DoubleToString(currentSl, digits) + " / " + DoubleToString(currentTp, digits), x, y + lineH * i, clrOrange); i++;
   SetLabel(PREFIX + "l16", "ATR:          " + (atrAvailable ? DoubleToString(atr, digits) : "unavailable") + "   Source: " + InpSignalFile, x, y + lineH * i, atrAvailable ? clrSilver : clrRed); i++;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void UpdateCsvStop(int direction, double csvStop)
  {
   double newSl = ValidCsvStop(direction, csvStop);
   if(newSl <= 0.0)
      return;

   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   bool improves = direction > 0
                   ? (currentSl == 0.0 || newSl > currentSl)
                   : (currentSl == 0.0 || newSl < currentSl);
   if(improves && !g_trade.PositionModify(_Symbol, newSl, currentTp))
      Print("Trailing-stop update failed. ", g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void ApplySignal(int index)
  {
   string regime = g_regimeNames[index];
   StringTrimLeft(regime);
   StringTrimRight(regime);
   StringToLower(regime);
   if(regime == "transition" || regime == "range")
     {
      CloseManagedPosition("regime changed to " + g_regimeNames[index]);
      return;
     }

   bool confidencePassed = g_confidences[index] > InpMinimumConfidence;
   bool buySignal = regime == "strong bull trend" && confidencePassed;
   bool sellSignal = regime == "strong bear trend" && confidencePassed;
   if(!buySignal && !sellSignal)
      return;

   int desiredDirection = buySignal ? 1 : -1;

   long positionType = -1;
   bool hasPosition = SelectManagedPosition(positionType);
   int currentDirection = !hasPosition ? 0 :
                          positionType == POSITION_TYPE_BUY ? 1 : -1;
   if(currentDirection == desiredDirection)
      return;

   if(!EmaPassed(index, desiredDirection))
      return;

   if(!AdxPassed(index))
      return;

   if(hasPosition)
     {
      CloseManagedPosition("opposite signal");
      return;
     }
   if(!IsWithinEntryHours())
      return;
   OpenPosition(desiredDirection, index);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpAtrPeriod <= 0 || InpStopLossAtrMultiplier <= 0.0
      || InpTakeProfitAtrMultiplier <= 0.0
      || InpMinimumEmaGapAtr < 0.0
      || InpBreakEvenTriggerAtr <= 0.0 || InpBreakEvenOffsetAtr < 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpTradeStartHour < 0 || InpTradeStartHour > 23
      || InpTradeEndHour < 1 || InpTradeEndHour > 24
      || InpTradeStartHour >= InpTradeEndHour)
      return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Cannot create ATR indicator handle. Error ", GetLastError());
      return INIT_FAILED;
     }
   g_ema9Handle = iMA(_Symbol, InpEmaTimeframe, 9, 0, MODE_EMA, PRICE_CLOSE);
   g_ema21Handle = iMA(_Symbol, InpEmaTimeframe, 21, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseEma200)
      g_ema200Handle = iMA(_Symbol, InpEmaTimeframe, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(g_ema9Handle == INVALID_HANDLE ||
      g_ema21Handle == INVALID_HANDLE ||
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
   g_adxHandle = iADX(_Symbol, InpSignalTimeframe, InpAdxPeriod);
   if(g_adxHandle == INVALID_HANDLE)
     {
      Print("Cannot create ADX indicator handle. Error ", GetLastError());
      return INIT_FAILED;
     }
   if(!LoadSignals())
      return INIT_FAILED;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_adxHandle != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle);
   if(g_ema9Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema9Handle);
   if(g_ema21Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema21Handle);
   if(g_ema200Handle != INVALID_HANDLE)
      IndicatorRelease(g_ema200Handle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ApplyBreakEven();

   if(g_signalCount == 0)
      return;

   datetime now = TimeCurrent();
   int latestDue = -1;
   while(g_nextSignal < g_signalCount && EffectiveSignalTime(g_nextSignal) <= now)
     {
      latestDue = g_nextSignal;
      g_nextSignal++;
     }

   // If multiple rows became due between ticks, use the latest state only.
   if(latestDue >= 0)
     {
      g_lastPanelIndex = latestDue;
      ApplySignal(latestDue);
     }

   DrawBacktestPanel(g_lastPanelIndex);

   if(InpCloseAtEndOfSignals && !g_endHandled && g_nextSignal >= g_signalCount)
     {
      datetime finalClose = EffectiveSignalTime(g_signalCount - 1)
                            + PeriodSeconds(InpSignalTimeframe);
      if(now >= finalClose)
        {
         CloseManagedPosition("end of signal file");
         g_endHandled = true;
        }
     }
  }
//+------------------------------------------------------------------+
