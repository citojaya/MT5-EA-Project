//+------------------------------------------------------------------+
//|                         market_structure_pyramiding.mq5          |
//| Adds one same-direction position on every new valid signal.      |
//+------------------------------------------------------------------+
#property copyright "Candlestick"
#property version   "1.00"
#property strict

#define ALLOW_SAME_DIRECTION_ENTRIES_DEFAULT true
#define MAGIC_NUMBER_DEFAULT 11111112

#include "market_structure.mq5"
//+------------------------------------------------------------------+
