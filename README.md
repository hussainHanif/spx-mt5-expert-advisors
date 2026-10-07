# SPX MT5 Expert Advisors

Two MetaTrader 5 trading bots for the S&P 500 (US500 / SPX500), designed to
**filter out false signals** through multi-layer confirmation, closed-bar
evaluation, session windows and strict risk controls.

| EA | Approach |
|----|----------|
| **SPX_TrendPullback_EA** | EMA trend + higher-timeframe agreement + ADX strength + RSI pullback entry + ATR stops/trailing |
| **SPX_OpeningRange_EA** | Opening Range Breakout (09:30–09:45 NY) with VWAP bias, volume confirmation, ATR range-quality check and one-trade-per-day discipline |

Shared logic (session handling, risk sizing, trailing, daily loss guard) lives
in `MQL5/Include/SPX/SPX_Common.mqh`.

See **[setup.md](setup.md)** for installation, configuration and backtesting.

```
MQL5/
├── Experts/SPX/
│   ├── SPX_TrendPullback_EA.mq5
│   └── SPX_OpeningRange_EA.mq5
└── Include/SPX/
    └── SPX_Common.mqh
```

Author: Hussain Hanif
