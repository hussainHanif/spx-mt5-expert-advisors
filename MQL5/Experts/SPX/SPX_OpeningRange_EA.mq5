//+------------------------------------------------------------------+
//|                                        SPX_OpeningRange_EA.mq5   |
//|   Opening Range Breakout EA for SPX / US500 (MetaTrader 5)       |
//|   Author: Hussain Hanif                                          |
//+------------------------------------------------------------------+
//
//  STRATEGY
//  --------
//  The Opening Range Breakout (ORB) is the classic SPX intraday setup:
//  mark the high/low of the first N minutes after the 09:30 NY open and
//  trade the first clean break of that range in the direction of the
//  day's bias.
//
//  FALSE-SIGNAL FILTERS
//  --------------------
//  1. Range quality : range must be between MinRangeATR and MaxRangeATR
//                     multiples of the daily ATR. Too tight = noise break,
//                     too wide = move already happened.
//  2. Close-through : we need a CLOSED bar beyond the range (plus a buffer),
//                     not just a wick. No intrabar entries.
//  3. VWAP bias     : longs only if close is above session VWAP, shorts only
//                     below. Keeps us on the side of institutional flow.
//  4. Volume        : breakout bar tick volume must be >= X times the
//                     average volume of the range bars (optional).
//  5. Time window   : breakouts are only valid until a cut-off time; late
//                     breaks are ignored.
//  6. One trade/day : max 1 entry (optionally 1 per direction after a
//                     failed break), flat before the close.
//  7. Risk          : stop = opposite side of range (or ATR cap), target =
//                     R multiple, optional partial at 1R + trail to BE.
//
#property copyright "Hussain Hanif"
#property version   "1.00"

#include <SPX\SPX_Common.mqh>

//--- Inputs ---------------------------------------------------------
input group "=== General ==="
input ENUM_TIMEFRAMES InpTF            = PERIOD_M5;   // Trading timeframe (M1/M5 recommended)
input long            InpMagic         = 55020;       // Magic number

input group "=== Opening Range (New York time) ==="
input int    InpNYOffsetHours          = -7;          // Hours to ADD to server time to get NY time
input int    InpOpenHour               = 9;           // Market open hour (NY)
input int    InpOpenMin                = 30;          // Market open minute (NY)
input int    InpRangeMinutes           = 15;          // Opening range length (minutes)
input int    InpLastEntryHour          = 11;          // No new entries after this hour (NY)
input int    InpLastEntryMin           = 30;          // ...and minute
input int    InpFlattenHour            = 15;          // Flatten hour (NY)
input int    InpFlattenMin             = 55;          // Flatten minute (NY)

input group "=== Breakout Filters ==="
input double InpBreakBufferPoints      = 20;          // Close must exceed range by this many points
input int    InpATRDailyPeriod         = 14;          // Daily ATR period for range sizing
input double InpMinRangeATR            = 0.15;        // Min range as fraction of daily ATR
input double InpMaxRangeATR            = 0.60;        // Max range as fraction of daily ATR
input bool   InpUseVWAP                = true;        // Require VWAP agreement
input bool   InpUseVolume              = true;        // Require volume confirmation
input double InpVolumeMult             = 1.2;         // Breakout bar volume >= avg range volume x
input bool   InpAllowBothDirections    = false;       // Allow 1 long + 1 short per day (after a stop-out)

input group "=== Risk Management ==="
input double InpRiskPercent            = 0.5;         // Risk per trade (% balance). 0 = fixed lots
input double InpFixedLots              = 0.10;        // Fixed lots (if risk % = 0)
input double InpMaxSL_ATR              = 0.5;         // Cap stop at daily ATR x (0 = no cap)
input double InpTP_R                   = 2.0;         // Take profit = R multiple of stop
input bool   InpBreakEvenAt1R          = true;        // Move stop to breakeven at +1R
input double InpMaxSpreadPoints        = 80;          // Max spread in points (0 = ignore)
input double InpDailyLossLimitPct      = 2.0;         // Stop trading if today's loss > % balance (0 = off)

//--- Globals --------------------------------------------------------
CTrade   g_trade;
int      g_hATRDaily = INVALID_HANDLE;
datetime g_lastBar   = 0;
int      g_dayStamp  = 0;

// per-day state
bool     g_rangeReady   = false;
double   g_rangeHigh    = 0.0;
double   g_rangeLow     = 0.0;
double   g_rangeAvgVol  = 0.0;
int      g_rangeBars    = 0;
bool     g_tookLong     = false;
bool     g_tookShort    = false;
int      g_tradesToday  = 0;
// VWAP accumulators (session, from open)
double   g_vwapPV = 0.0, g_vwapV = 0.0;
datetime g_vwapLastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_hATRDaily = iATR(_Symbol, PERIOD_D1, InpATRDailyPeriod);
   if(g_hATRDaily == INVALID_HANDLE) { Print("[SPX-ORB] ATR handle failed"); return INIT_FAILED; }

   int tfMin = PeriodSeconds(InpTF) / 60;
   if(InpRangeMinutes % tfMin != 0)
   {
      PrintFormat("[SPX-ORB] Range minutes (%d) must be a multiple of the timeframe (%d min)", InpRangeMinutes, tfMin);
      return INIT_PARAMETERS_INCORRECT;
   }
   Print("[SPX-ORB] Initialised on ", _Symbol, " ", EnumToString(InpTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { IndicatorRelease(g_hATRDaily); }

//+------------------------------------------------------------------+
void ResetDay()
{
   g_rangeReady = false; g_rangeHigh = 0; g_rangeLow = 0; g_rangeAvgVol = 0; g_rangeBars = 0;
   g_tookLong = false; g_tookShort = false; g_tradesToday = 0;
   g_vwapPV = 0; g_vwapV = 0; g_vwapLastBar = 0;
}

// Server-time datetime of today's NY open.
datetime TodayOpenServerTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent() + (datetime)(InpNYOffsetHours * 3600), dt);
   dt.hour = InpOpenHour; dt.min = InpOpenMin; dt.sec = 0;
   return StructToTime(dt) - (datetime)(InpNYOffsetHours * 3600);
}

// Build the opening range from closed bars once the range window has elapsed.
void TryBuildRange()
{
   if(g_rangeReady) return;
   datetime openT  = TodayOpenServerTime();
   datetime endT   = openT + InpRangeMinutes * 60;
   if(TimeCurrent() < endT) return;                     // window not finished

   int bars = InpRangeMinutes / (PeriodSeconds(InpTF) / 60);
   MqlRates r[];
   if(CopyRates(_Symbol, InpTF, openT, endT - 1, r) < bars) return;

   double hi = -DBL_MAX, lo = DBL_MAX; double vol = 0; int n = 0;
   for(int i = 0; i < ArraySize(r); i++)
   {
      if(r[i].time < openT || r[i].time >= endT) continue;
      hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); vol += (double)r[i].tick_volume; n++;
   }
   if(n < bars) return;

   g_rangeHigh = hi; g_rangeLow = lo; g_rangeBars = n; g_rangeAvgVol = vol / n; g_rangeReady = true;
   PrintFormat("[SPX-ORB] Range built: H %.2f L %.2f (%.2f pts, %d bars)", hi, lo, hi - lo, n);
}

// Update session VWAP with each newly closed bar since open.
void UpdateVWAP()
{
   datetime openT = TodayOpenServerTime();
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int cnt = CopyRates(_Symbol, InpTF, 1, 200, r);
   if(cnt <= 0) return;
   // rebuild from scratch each new bar: cheap and avoids drift
   g_vwapPV = 0; g_vwapV = 0;
   for(int i = cnt - 1; i >= 0; i--)
   {
      if(r[i].time < openT) continue;
      double typ = (r[i].high + r[i].low + r[i].close) / 3.0;
      g_vwapPV += typ * (double)r[i].tick_volume;
      g_vwapV  += (double)r[i].tick_volume;
   }
}

double VWAP() { return g_vwapV > 0 ? g_vwapPV / g_vwapV : 0.0; }

// Breakeven management: once price moves +1R in our favour, SL -> entry.
void ManageBreakEven()
{
   if(!InpBreakEvenAt1R) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);
      if(sl == 0) continue;
      double risk = MathAbs(open - sl);

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(sl < open && bid - open >= risk)
            g_trade.PositionModify(ticket, SPX_NormalizePrice(_Symbol, open), tp);
      }
      else
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(sl > open && open - ask >= risk)
            g_trade.PositionModify(ticket, SPX_NormalizePrice(_Symbol, open), tp);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   int today = SPX_NYDay(InpNYOffsetHours);
   if(today != g_dayStamp) { g_dayStamp = today; ResetDay(); }

   int posCount = SPX_CountPositions(_Symbol, InpMagic);

   // flatten before the close
   if(posCount > 0 && SPX_InSession(InpNYOffsetHours, InpFlattenHour, InpFlattenMin, 23, 59))
   {
      SPX_CloseAll(g_trade, _Symbol, InpMagic, "session end");
      return;
   }
   if(posCount > 0) ManageBreakEven();

   if(!SPX_IsNewBar(_Symbol, InpTF, g_lastBar)) return;

   // Only work during NY session
   if(!SPX_InSession(InpNYOffsetHours, InpOpenHour, InpOpenMin, InpFlattenHour, InpFlattenMin)) return;

   TryBuildRange();
   if(!g_rangeReady) return;
   UpdateVWAP();

   if(posCount > 0) return;
   if(!SPX_InSession(InpNYOffsetHours, InpOpenHour, InpOpenMin, InpLastEntryHour, InpLastEntryMin)) return;
   if(!SPX_SpreadOk(_Symbol, InpMaxSpreadPoints)) return;

   int maxTrades = InpAllowBothDirections ? 2 : 1;
   if(g_tradesToday >= maxTrades) return;

   if(InpDailyLossLimitPct > 0)
   {
      double pl = SPX_TodayRealizedPL(_Symbol, InpMagic, InpNYOffsetHours);
      if(pl < 0 && MathAbs(pl) >= AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLossLimitPct / 100.0) return;
   }

   //--- range quality vs daily ATR
   double atrD[1];
   if(CopyBuffer(g_hATRDaily, 0, 1, 1, atrD) < 1 || atrD[0] <= 0) return;
   double range = g_rangeHigh - g_rangeLow;
   if(range < atrD[0] * InpMinRangeATR || range > atrD[0] * InpMaxRangeATR)
   {
      static int loggedDay = 0;
      if(loggedDay != today) { PrintFormat("[SPX-ORB] Range %.2f outside ATR bounds (ATR %.2f), skipping day", range, atrD[0]); loggedDay = today; }
      return;
   }

   //--- last closed bar
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, 1, r) < 1) return;
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer = InpBreakBufferPoints * point;

   bool volOk = !InpUseVolume || (g_rangeAvgVol > 0 && (double)r[0].tick_volume >= g_rangeAvgVol * InpVolumeMult);
   double vwap = VWAP();

   bool longBreak  = r[0].close > g_rangeHigh + buffer && r[0].close > r[0].open;
   bool shortBreak = r[0].close < g_rangeLow  - buffer && r[0].close < r[0].open;
   if(InpUseVWAP && vwap > 0)
   {
      longBreak  = longBreak  && r[0].close > vwap;
      shortBreak = shortBreak && r[0].close < vwap;
   }
   longBreak  = longBreak  && volOk && !g_tookLong;
   shortBreak = shortBreak && volOk && !g_tookShort;
   if(!longBreak && !shortBreak) return;

   //--- stop & target
   double minStop = SPX_MinStopDistance(_Symbol);
   double slDist;
   if(longBreak)  slDist = (r[0].close - g_rangeLow);
   else           slDist = (g_rangeHigh - r[0].close);
   if(InpMaxSL_ATR > 0) slDist = MathMin(slDist, atrD[0] * InpMaxSL_ATR);
   slDist = MathMax(slDist, minStop);
   double tpDist = MathMax(slDist * InpTP_R, minStop);

   double lots = SPX_LotsByRisk(_Symbol, InpRiskPercent, slDist, InpFixedLots);
   if(lots <= 0) return;

   if(longBreak)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = SPX_NormalizePrice(_Symbol, ask - slDist);
      double tp  = SPX_NormalizePrice(_Symbol, ask + tpDist);
      if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "SPX-ORB long"))
      {
         g_tookLong = true; g_tradesToday++;
         PrintFormat("[SPX-ORB] LONG %.2f @ %.2f SL %.2f TP %.2f VWAP %.2f", lots, ask, sl, tp, vwap);
      }
      else PrintFormat("[SPX-ORB] Buy failed: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = SPX_NormalizePrice(_Symbol, bid + slDist);
      double tp  = SPX_NormalizePrice(_Symbol, bid - tpDist);
      if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "SPX-ORB short"))
      {
         g_tookShort = true; g_tradesToday++;
         PrintFormat("[SPX-ORB] SHORT %.2f @ %.2f SL %.2f TP %.2f VWAP %.2f", lots, bid, sl, tp, vwap);
      }
      else PrintFormat("[SPX-ORB] Sell failed: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
