//+------------------------------------------------------------------+
//|                                        SPX_TrendPullback_EA.mq5  |
//|   Trend-following pullback EA for SPX / US500 (MetaTrader 5)     |
//|   Author: Hussain Hanif                                          |
//+------------------------------------------------------------------+
//
//  STRATEGY (designed to cut false signals, not maximise trade count)
//  ---------------------------------------------------------------
//  1. TREND   : Fast EMA above/below Slow EMA on the trading timeframe,
//               AND price on the higher timeframe is on the same side of
//               its EMA (multi-timeframe agreement).
//  2. STRENGTH: ADX above a threshold -> we only trade when the market is
//               actually trending, not chopping.
//  3. PULLBACK: RSI dips to an oversold zone in an uptrend (or overbought
//               in a downtrend) and then turns back -> entry on the pullback,
//               never on the chase.
//  4. TRIGGER : The bar that confirms the RSI turn must close in the
//               direction of the trend. We evaluate CLOSED bars only
//               (shift 1), so there is no intrabar repainting.
//  5. SESSION : Trade only inside New York regular hours by default
//               (09:30 - 16:00 NY). Avoid first/last N minutes (optional).
//  6. RISK    : ATR-based stop loss and take profit, risk-% position
//               sizing, cooldown between trades, max trades per day,
//               daily loss limit, spread filter, flat at session end.
//
#property copyright "Hussain Hanif"
#property version   "1.00"

#include <SPX\SPX_Common.mqh>

//--- Inputs ---------------------------------------------------------
input group "=== Symbol & Timeframe ==="
input ENUM_TIMEFRAMES InpTF          = PERIOD_M15;   // Trading timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H1;    // Higher timeframe for trend agreement
input long            InpMagic       = 55010;        // Magic number

input group "=== Trend Filter ==="
input int    InpFastEMA              = 20;           // Fast EMA period
input int    InpSlowEMA              = 50;           // Slow EMA period
input int    InpHigherEMA            = 50;           // Higher-TF EMA period
input int    InpADXPeriod            = 14;           // ADX period
input double InpADXMin               = 22.0;         // Min ADX to allow trades (trend strength)

input group "=== Pullback Trigger ==="
input int    InpRSIPeriod            = 14;           // RSI period
input double InpRSIBuyZone           = 40.0;         // RSI must dip below this in an uptrend
input double InpRSISellZone          = 60.0;         // RSI must rise above this in a downtrend
input int    InpPullbackLookback     = 5;            // Bars to look back for the RSI dip
input bool   InpRequireEMAtouch      = true;         // Require price to touch Fast EMA during pullback

input group "=== Risk Management ==="
input double InpRiskPercent          = 0.5;          // Risk per trade (% balance). 0 = use fixed lots
input double InpFixedLots            = 0.10;         // Fixed lots (if risk % = 0)
input int    InpATRPeriod            = 14;           // ATR period
input double InpSL_ATR               = 1.5;          // Stop loss = ATR x
input double InpTP_ATR               = 2.5;          // Take profit = ATR x
input double InpTrailStart_ATR       = 1.0;          // Start trailing after profit of ATR x (0 = off)
input double InpTrail_ATR            = 1.2;          // Trail distance = ATR x
input double InpMaxSpreadPoints      = 80;           // Max spread in points (0 = ignore)
input int    InpMaxTradesPerDay      = 3;            // Max trades per day
input int    InpCooldownBars         = 4;            // Bars to wait after a trade closes
input double InpDailyLossLimitPct    = 2.0;          // Stop trading if today's loss > % balance (0 = off)

input group "=== Session (New York time) ==="
input int    InpNYOffsetHours        = -7;           // Hours to ADD to server time to get NY time
input int    InpSessionStartHour     = 9;            // Session start hour (NY)
input int    InpSessionStartMin      = 45;           // Session start minute (skip opening noise)
input int    InpSessionEndHour       = 15;           // Last entry hour (NY)
input int    InpSessionEndMin        = 30;           // Last entry minute (NY)
input bool   InpCloseAtSessionEnd    = true;         // Flatten positions at 15:55 NY
input int    InpFlattenHour          = 15;           // Flatten hour (NY)
input int    InpFlattenMin           = 55;           // Flatten minute (NY)

//--- Globals --------------------------------------------------------
CTrade        g_trade;
int           g_hFastEMA   = INVALID_HANDLE;
int           g_hSlowEMA   = INVALID_HANDLE;
int           g_hHigherEMA = INVALID_HANDLE;
int           g_hADX       = INVALID_HANDLE;
int           g_hRSI       = INVALID_HANDLE;
int           g_hATR       = INVALID_HANDLE;
datetime      g_lastBar    = 0;
int           g_tradesToday = 0;
int           g_dayStamp    = 0;
datetime      g_lastCloseBar = 0;   // bar time when last position was closed
int           g_prevPosCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_hFastEMA   = iMA (_Symbol, InpTF,       InpFastEMA,   0, MODE_EMA, PRICE_CLOSE);
   g_hSlowEMA   = iMA (_Symbol, InpTF,       InpSlowEMA,   0, MODE_EMA, PRICE_CLOSE);
   g_hHigherEMA = iMA (_Symbol, InpHigherTF, InpHigherEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hADX       = iADX(_Symbol, InpTF,       InpADXPeriod);
   g_hRSI       = iRSI(_Symbol, InpTF,       InpRSIPeriod, PRICE_CLOSE);
   g_hATR       = iATR(_Symbol, InpTF,       InpATRPeriod);

   if(g_hFastEMA == INVALID_HANDLE || g_hSlowEMA == INVALID_HANDLE || g_hHigherEMA == INVALID_HANDLE ||
      g_hADX == INVALID_HANDLE || g_hRSI == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Print("[SPX-TP] Failed to create indicator handles");
      return INIT_FAILED;
   }
   if(InpFastEMA >= InpSlowEMA)
   {
      Print("[SPX-TP] Fast EMA must be smaller than Slow EMA");
      return INIT_PARAMETERS_INCORRECT;
   }
   Print("[SPX-TP] Initialised on ", _Symbol, " ", EnumToString(InpTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_hFastEMA);
   IndicatorRelease(g_hSlowEMA);
   IndicatorRelease(g_hHigherEMA);
   IndicatorRelease(g_hADX);
   IndicatorRelease(g_hRSI);
   IndicatorRelease(g_hATR);
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- daily counters reset
   int today = SPX_NYDay(InpNYOffsetHours);
   if(today != g_dayStamp) { g_dayStamp = today; g_tradesToday = 0; }

   //--- detect a position closing (for cooldown)
   int posCount = SPX_CountPositions(_Symbol, InpMagic);
   if(posCount < g_prevPosCount) g_lastCloseBar = iTime(_Symbol, InpTF, 0);
   g_prevPosCount = posCount;

   //--- flatten at session end
   if(InpCloseAtSessionEnd && posCount > 0 &&
      SPX_InSession(InpNYOffsetHours, InpFlattenHour, InpFlattenMin, 23, 59))
   {
      SPX_CloseAll(g_trade, _Symbol, InpMagic, "session end");
      return;
   }

   //--- trailing stop (every tick, uses latest closed-bar ATR)
   double atrNow[1];
   if(posCount > 0 && InpTrailStart_ATR > 0 && CopyBuffer(g_hATR, 0, 1, 1, atrNow) == 1)
      SPX_TrailByATR(g_trade, _Symbol, InpMagic, atrNow[0], InpTrail_ATR, InpTrailStart_ATR);

   //--- evaluate signals once per closed bar only
   if(!SPX_IsNewBar(_Symbol, InpTF, g_lastBar)) return;
   if(posCount > 0) return;                                   // one position at a time
   if(!SPX_InSession(InpNYOffsetHours, InpSessionStartHour, InpSessionStartMin, InpSessionEndHour, InpSessionEndMin)) return;
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(!SPX_SpreadOk(_Symbol, InpMaxSpreadPoints)) return;

   //--- cooldown after last close
   if(g_lastCloseBar > 0 && InpCooldownBars > 0)
   {
      int barsSince = iBarShift(_Symbol, InpTF, g_lastCloseBar, false);
      if(barsSince >= 0 && barsSince < InpCooldownBars) return;
   }

   //--- daily loss guard
   if(InpDailyLossLimitPct > 0)
   {
      double pl = SPX_TodayRealizedPL(_Symbol, InpMagic, InpNYOffsetHours);
      if(pl < 0 && MathAbs(pl) >= AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLossLimitPct / 100.0)
      {
         static int warnedDay = 0;
         if(warnedDay != today) { Print("[SPX-TP] Daily loss limit hit, no more trades today"); warnedDay = today; }
         return;
      }
   }

   //--- pull indicator data (closed bars: shift 1 .. N)
   int need = InpPullbackLookback + 2;
   double fast[], slow[], higher[], adx[], rsi[], atr[];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true); ArraySetAsSeries(higher, true);
   ArraySetAsSeries(adx, true);  ArraySetAsSeries(rsi, true);  ArraySetAsSeries(atr, true);

   if(CopyBuffer(g_hFastEMA,   0, 1, need, fast)   < need) return;
   if(CopyBuffer(g_hSlowEMA,   0, 1, need, slow)   < need) return;
   if(CopyBuffer(g_hHigherEMA, 0, 1, 1,    higher) < 1)    return;
   if(CopyBuffer(g_hADX,       0, 1, 1,    adx)    < 1)    return;
   if(CopyBuffer(g_hRSI,       0, 1, need, rsi)    < need) return;
   if(CopyBuffer(g_hATR,       0, 1, 1,    atr)    < 1)    return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, need, r) < need) return;
   double higherClose = iClose(_Symbol, InpHigherTF, 1);

   //--- 1 & 2: trend + strength
   bool upTrend   = fast[0] > slow[0] && higherClose > higher[0];
   bool downTrend = fast[0] < slow[0] && higherClose < higher[0];
   bool strong    = adx[0] >= InpADXMin;
   if(!strong || (!upTrend && !downTrend)) return;

   //--- 3: pullback detection within lookback window
   bool dipped = false, touched = !InpRequireEMAtouch;
   for(int i = 1; i <= InpPullbackLookback; i++)
   {
      if(upTrend   && rsi[i] < InpRSIBuyZone)  dipped = true;
      if(downTrend && rsi[i] > InpRSISellZone) dipped = true;
      if(upTrend   && r[i].low  <= fast[i])     touched = true;
      if(downTrend && r[i].high >= fast[i])     touched = true;
   }
   if(!dipped || !touched) return;

   //--- 4: trigger bar (last closed bar) confirms the turn
   bool buySignal  = upTrend   && rsi[0] > rsi[1] && rsi[0] > InpRSIBuyZone  && r[0].close > r[0].open && r[0].close > fast[0];
   bool sellSignal = downTrend && rsi[0] < rsi[1] && rsi[0] < InpRSISellZone && r[0].close < r[0].open && r[0].close < fast[0];
   if(!buySignal && !sellSignal) return;

   //--- 6: risk sizing & order
   double atrVal = atr[0];
   if(atrVal <= 0) return;
   double slDist = atrVal * InpSL_ATR;
   double tpDist = atrVal * InpTP_ATR;
   double minStop = SPX_MinStopDistance(_Symbol);
   if(slDist < minStop) slDist = minStop;
   if(tpDist < minStop) tpDist = minStop;

   double lots = SPX_LotsByRisk(_Symbol, InpRiskPercent, slDist, InpFixedLots);
   if(lots <= 0) return;

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = SPX_NormalizePrice(_Symbol, ask - slDist);
      double tp  = SPX_NormalizePrice(_Symbol, ask + tpDist);
      if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "SPX-TP buy"))
      {
         g_tradesToday++;
         PrintFormat("[SPX-TP] BUY %.2f @ %.2f SL %.2f TP %.2f ADX %.1f RSI %.1f", lots, ask, sl, tp, adx[0], rsi[0]);
      }
      else PrintFormat("[SPX-TP] Buy failed: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
   else if(sellSignal)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = SPX_NormalizePrice(_Symbol, bid + slDist);
      double tp  = SPX_NormalizePrice(_Symbol, bid - tpDist);
      if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "SPX-TP sell"))
      {
         g_tradesToday++;
         PrintFormat("[SPX-TP] SELL %.2f @ %.2f SL %.2f TP %.2f ADX %.1f RSI %.1f", lots, bid, sl, tp, adx[0], rsi[0]);
      }
      else PrintFormat("[SPX-TP] Sell failed: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
