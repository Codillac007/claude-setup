# SMAC price feed

Daily US-market closing data for the SMAC research desk, produced by the GitHub Action
`.github/workflows/smac-prices.yml` after each US session (01:20 and 02:10 Baku).

- `latest.json` — one summary per symbol: date, OHLC, close, % change (1d/5d/21d), SMA50/200, 52-week high/low, volume vs 50-day average. Covers `tickers.txt`, `extra.txt` and the S&P 500.
- `bars/<SYMBOL>.csv` — daily OHLCV: 5 years for `tickers.txt` and `extra.txt`, 1 year for the other S&P 500 names (`^` and `=` in symbols become `_`).
- Add a symbol to `extra.txt` (one per line) to get its full history too.
