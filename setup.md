# Setup Guide – SPX MT5 Expert Advisors

Two MetaTrader 5 Expert Advisors (EAs) built for trading the S&P 500 index
(broker symbols are usually `US500`, `SPX500`, `SP500`, `USA500` or `SPX`).

| EA | Style | Timeframe | What it does |
|----|-------|-----------|--------------|
| `SPX_TrendPullback_EA` | Trend-following | M15 (H1 confirm) | Buys pullbacks in an uptrend / sells rallies in a downtrend, only when ADX says the trend is real. |
| `SPX_OpeningRange_EA` | Day-trade breakout | M5 | Trades the first clean break of the 09:30–09:45 NY opening range, filtered by VWAP, volume and range size. |

Both are built around **reducing false signals**: closed-bar confirmation only
(no repainting), multi-layer filters, session windows, cooldowns, max trades
per day, daily loss limit, spread filter, and automatic flatten before the
US close.

---

## 1. Requirements

- MetaTrader 5 (build 3000+). MT4 is **not** supported (these are `.mq5`).
- A broker account that offers an S&P 500 CFD or futures symbol.
- Hedging or netting account – both work (one position at a time per EA).

## 2. Install the files

1. In MT5 go to **File → Open Data Folder**. A folder opens that contains an `MQL5` directory.
2. Copy this repository's `MQL5` folder **over** that `MQL5` folder, so you end up with:

   ```
   <DataFolder>/MQL5/Experts/SPX/SPX_TrendPullback_EA.mq5
   <DataFolder>/MQL5/Experts/SPX/SPX_OpeningRange_EA.mq5
   <DataFolder>/MQL5/Include/SPX/SPX_Common.mqh
   ```

3. Open **MetaEditor** (F4 in MT5), find `Experts/SPX` in the Navigator, open each `.mq5` file and press **F7 (Compile)**. You should see `0 errors, 0 warnings`.
   The `.ex5` binaries appear next to the sources.
4. Back in MT5, press **Ctrl+N** to open the Navigator. Under **Expert Advisors → SPX** you will see both EAs.

## 3. Enable automated trading

- **Tools → Options → Expert Advisors**: tick *Allow algorithmic trading*.
- Click the **Algo Trading** button in the toolbar so it turns green.

## 4. Set the New York time offset (important)

Both EAs run on **New York time** internally, but your broker's server runs on
its own clock (most brokers use GMT+2 in winter / GMT+3 in summer, which keeps
a constant **-7 h** offset to New York all year).

Input `InpNYOffsetHours` = *hours to ADD to server time to get New York time.*

| Broker server time | Value |
|--------------------|-------|
| GMT+2 / GMT+3 (EET, follows US DST) – most brokers | `-7` |
| GMT+0 (UTC, no DST) | `-5` (winter) / `-4` (summer) |
| GMT-5 (New York) | `0` |

To check: open **Market Watch**, note the server time shown, compare with the
current time in New York.

## 5. Attach an EA to a chart

1. Open a chart of your S&P 500 symbol.
2. Set the chart timeframe: **M15** for `SPX_TrendPullback_EA`, **M5** for `SPX_OpeningRange_EA`
   (the EAs also have an `InpTF` input; keep it equal to the chart timeframe).
3. Drag the EA onto the chart. In the dialog, **Common** tab → tick *Allow Algo Trading*.
4. Go to the **Inputs** tab and adjust:
   - `InpNYOffsetHours` (see section 4)
   - `InpRiskPercent` – % of balance risked per trade (default 0.5 %). Set to `0` to use `InpFixedLots`.
   - `InpMaxSpreadPoints` – check your symbol's typical spread in points and set a sensible cap.
5. Press OK. A smiley face / "SPX-… Initialised" message in the **Experts** tab confirms it is running.

Run each EA on **its own chart**. They use different magic numbers (`55010`, `55020`)
so they can run side by side without interfering.

## 6. Key inputs explained

### SPX_TrendPullback_EA

| Input | Default | Meaning |
|-------|---------|---------|
| `InpFastEMA / InpSlowEMA` | 20 / 50 | Trend direction on the trading TF |
| `InpHigherTF / InpHigherEMA` | H1 / 50 | Higher-TF must agree with the trend |
| `InpADXMin` | 22 | Minimum trend strength. Raise to 25–30 for fewer, cleaner trades |
| `InpRSIBuyZone / InpRSISellZone` | 40 / 60 | How deep the pullback must go before a trade is allowed |
| `InpPullbackLookback` | 5 | Bars to search for the pullback |
| `InpRequireEMAtouch` | true | Price must touch the fast EMA during the pullback |
| `InpSL_ATR / InpTP_ATR` | 1.5 / 2.5 | Stop & target as ATR multiples |
| `InpTrailStart_ATR / InpTrail_ATR` | 1.0 / 1.2 | ATR trailing stop (set start to 0 to disable) |
| `InpMaxTradesPerDay` | 3 | Hard cap |
| `InpCooldownBars` | 4 | Bars to wait after a position closes |
| `InpDailyLossLimitPct` | 2.0 | Stops trading for the day after this loss |
| Session inputs | 09:45–15:30 NY, flatten 15:55 | Entry window and forced flatten |

### SPX_OpeningRange_EA

| Input | Default | Meaning |
|-------|---------|---------|
| `InpRangeMinutes` | 15 | Opening-range length (must be a multiple of the TF) |
| `InpLastEntryHour/Min` | 11:30 | No entries after this time |
| `InpBreakBufferPoints` | 20 | Close must exceed the range by this many points |
| `InpMinRangeATR / InpMaxRangeATR` | 0.15 / 0.60 | Range must be this fraction of daily ATR, else the day is skipped |
| `InpUseVWAP` | true | Long only above VWAP, short only below |
| `InpUseVolume / InpVolumeMult` | true / 1.2 | Breakout bar volume vs. average range-bar volume |
| `InpAllowBothDirections` | false | Allow one long and one short per day (second only after the first is stopped) |
| `InpMaxSL_ATR` | 0.5 | Caps the stop at a fraction of daily ATR |
| `InpTP_R` | 2.0 | Target as R multiple of the stop |
| `InpBreakEvenAt1R` | true | Stop moves to entry at +1R |

## 7. Backtest first

1. **View → Strategy Tester** (Ctrl+R).
2. Select the EA, your S&P symbol, the timeframe above, *Every tick based on real ticks* if available.
3. Set the date range (12+ months recommended) and the same inputs you plan to use live.
4. Run, then use **Optimisation** on `InpADXMin`, `InpSL_ATR`, `InpTP_ATR` (Trend EA) or
   `InpRangeMinutes`, `InpBreakBufferPoints`, `InpTP_R` (ORB EA).

Then forward-test on a **demo account for at least 2–4 weeks** before going live.

## 8. Troubleshooting

| Symptom | Fix |
|---------|-----|
| "cannot open file SPX\SPX_Common.mqh" when compiling | The `Include/SPX` folder was not copied. Check step 2. |
| EA never trades | Check the Experts tab. Usually `InpNYOffsetHours` is wrong (session filter blocks everything) or the spread is above `InpMaxSpreadPoints`. |
| "Range … outside ATR bounds, skipping day" | Normal – the ORB EA skips days where the opening range is too small/large. Loosen `InpMin/MaxRangeATR` if it skips too often. |
| Invalid stops / retcode 10016 | Broker minimum stop level is larger than the ATR stop. The EAs already clamp to the minimum; increase `InpSL_ATR` if it persists. |
| Trades at odd hours | `InpNYOffsetHours` is wrong. |

## 9. Disclaimer

These EAs are provided for educational and evaluation purposes. Trading index
CFDs/futures involves substantial risk of loss. Always backtest and demo-trade
before risking real money.
