//+------------------------------------------------------------------+
//|                                                   SPX_Common.mqh |
//|          Shared helpers for the SPX Expert Advisors (MQL5)       |
//|          Author: Hussain Hanif                                   |
//+------------------------------------------------------------------+
#ifndef __SPX_COMMON_MQH__
#define __SPX_COMMON_MQH__

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Session helper -------------------------------------------------
// Returns true if the current *server* time (converted via GMT offset)
// falls inside the [startHour:startMin, endHour:endMin) window in
// New York time. Broker server time is usually GMT+2/+3, so we expose
// an input for the offset between server time and New York time.
bool SPX_InSession(const int nyOffsetHours,
                   const int startHour, const int startMin,
                   const int endHour,   const int endMin)
{
   MqlDateTime dt;
   datetime ny = TimeCurrent() + (datetime)(nyOffsetHours * 3600);
   TimeToStruct(ny, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false; // weekend
   int now   = dt.hour * 60 + dt.min;
   int start = startHour * 60 + startMin;
   int end   = endHour * 60 + endMin;
   return (now >= start && now < end);
}

// New-York-local date of the current tick (used for "one trade per day").
int SPX_NYDay(const int nyOffsetHours)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent() + (datetime)(nyOffsetHours * 3600), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

//--- New bar detection ----------------------------------------------
bool SPX_IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime t = iTime(symbol, tf, 0);
   if(t == 0) return false;
   if(t != lastBarTime) { lastBarTime = t; return true; }
   return false;
}

//--- Position bookkeeping -------------------------------------------
int SPX_CountPositions(const string symbol, const long magic)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      n++;
   }
   return n;
}

//--- Lot sizing by risk ---------------------------------------------
// riskPercent of account balance, divided by stop distance in price units.
double SPX_LotsByRisk(const string symbol, const double riskPercent, const double stopDistance, const double fixedLots)
{
   if(riskPercent <= 0.0 || stopDistance <= 0.0) return SPX_NormalizeLots(symbol, fixedLots);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * riskPercent / 100.0;
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return SPX_NormalizeLots(symbol, fixedLots);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return SPX_NormalizeLots(symbol, fixedLots);

   return SPX_NormalizeLots(symbol, riskMoney / lossPerLot);
}

double SPX_NormalizeLots(const string symbol, double lots)
{
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
}

//--- Price helpers --------------------------------------------------
double SPX_NormalizePrice(const string symbol, const double price)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

// Makes sure SL/TP respect the broker's minimum stop level.
double SPX_MinStopDistance(const string symbol)
{
   long   stopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return stopLevel * point;
}

//--- Spread filter --------------------------------------------------
bool SPX_SpreadOk(const string symbol, const double maxSpreadPoints)
{
   if(maxSpreadPoints <= 0.0) return true;
   long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   return (double)spread <= maxSpreadPoints;
}

//--- Daily loss guard -----------------------------------------------
// Returns realised P/L (deals) for today's NY date for this magic number.
double SPX_TodayRealizedPL(const string symbol, const long magic, const int nyOffsetHours)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent() + (datetime)(nyOffsetHours * 3600), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStartNY     = StructToTime(dt);
   datetime dayStartServer = dayStartNY - (datetime)(nyOffsetHours * 3600);

   if(!HistorySelect(dayStartServer, TimeCurrent() + 86400)) return 0.0;

   double pl = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_INOUT) continue;
      pl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
          + HistoryDealGetDouble(ticket, DEAL_SWAP)
          + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return pl;
}

//--- Trailing stop (ATR based) --------------------------------------
void SPX_TrailByATR(CTrade &trade, const string symbol, const long magic,
                    const double atr, const double trailMult, const double startMult)
{
   if(trailMult <= 0.0 || atr <= 0.0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         if(bid - open < atr * startMult) continue;           // not yet in profit enough
         double newSl = SPX_NormalizePrice(symbol, bid - atr * trailMult);
         if(newSl > sl && newSl < bid - SPX_MinStopDistance(symbol))
            trade.PositionModify(ticket, newSl, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(open - ask < atr * startMult) continue;
         double newSl = SPX_NormalizePrice(symbol, ask + atr * trailMult);
         if((sl == 0.0 || newSl < sl) && newSl > ask + SPX_MinStopDistance(symbol))
            trade.PositionModify(ticket, newSl, tp);
      }
   }
}

//--- Close all for this magic ---------------------------------------
void SPX_CloseAll(CTrade &trade, const string symbol, const long magic, const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(trade.PositionClose(ticket))
         PrintFormat("[SPX] Closed #%I64u (%s)", ticket, reason);
      else
         PrintFormat("[SPX] Failed to close #%I64u: %d", ticket, trade.ResultRetcode());
   }
}

#endif // __SPX_COMMON_MQH__
