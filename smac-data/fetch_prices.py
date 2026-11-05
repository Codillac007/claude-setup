"""SMAC price feed. Runs on GitHub Actions after the US close.

Writes:
  smac-data/latest.json      one summary row per symbol (core list + S&P 500 + extra.txt)
  smac-data/bars/<SYM>.csv   5y daily OHLCV for the core list (tickers.txt) and extra.txt
Source: Yahoo Finance chart API; Stooq CSV as fallback for stocks.
"""
import csv, datetime as dt, io, json, os, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"}

def read_list(name):
    p = os.path.join(HERE, name)
    if not os.path.exists(p):
        return []
    return [l.strip() for l in open(p) if l.strip() and not l.startswith("#")]

def get(url, timeout=25):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout).read()

def yahoo(sym, rng):
    for host in ("query1", "query2"):
        try:
            u = f"https://{host}.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?range={rng}&interval=1d"
            r = json.loads(get(u))["chart"]["result"][0]
            q, off = r["indicators"]["quote"][0], r["meta"].get("gmtoffset", 0)
            rows = []
            for t, o, h, l, c, v in zip(r["timestamp"], q["open"], q["high"], q["low"], q["close"], q["volume"]):
                if None in (o, h, l, c):
                    continue
                d = dt.datetime.utcfromtimestamp(t + off).date().isoformat()
                rows.append([d, o, h, l, c, v or 0])
            if rows:
                return rows, "yahoo"
        except Exception:
            time.sleep(1)
    return None, None

def stooq(sym):
    if sym.startswith("^") or "=" in sym or "." in sym:
        return None, None
    try:
        txt = get(f"https://stooq.com/q/d/l/?s={sym.lower()}.us&i=d").decode()
        rows = [[r["Date"], float(r["Open"]), float(r["High"]), float(r["Low"]), float(r["Close"]), int(float(r.get("Volume") or 0))]
                for r in csv.DictReader(io.StringIO(txt)) if r.get("Close") not in (None, "", "N/D")]
        return (rows[-1300:], "stooq") if rows else (None, None)
    except Exception:
        return None, None

def summary(rows, keep_last10):
    closes = [r[4] for r in rows]
    vols = [r[5] for r in rows]
    sma = lambda n: round(sum(closes[-n:]) / n, 4) if len(closes) >= n else None
    yr = closes[-252:]
    out = {"date": rows[-1][0], "open": round(rows[-1][1], 4), "high": round(rows[-1][2], 4), "low": round(rows[-1][3], 4),
           "close": round(closes[-1], 4),
           "chg_pct": round((closes[-1] / closes[-2] - 1) * 100, 2) if len(closes) > 1 else None,
           "chg_5d_pct": round((closes[-1] / closes[-6] - 1) * 100, 2) if len(closes) > 5 else None,
           "chg_21d_pct": round((closes[-1] / closes[-22] - 1) * 100, 2) if len(closes) > 21 else None,
           "sma50": sma(50), "sma200": sma(200), "high_52w": round(max(yr), 4), "low_52w": round(min(yr), 4),
           "vol": vols[-1], "vol_vs_50d": round(vols[-1] / (sum(vols[-51:-1]) / 50), 2) if len(vols) > 50 and sum(vols[-51:-1]) else None}
    if keep_last10:
        out["last10"] = [[r[0], round(r[4], 4), r[5]] for r in rows[-10:]]
    return out

def sp500():
    try:
        txt = get("https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv").decode()
        return [r["Symbol"].replace(".", "-") for r in csv.DictReader(io.StringIO(txt))]
    except Exception:
        return []

def main():
    core = read_list("tickers.txt")
    extra = read_list("extra.txt")
    full = list(dict.fromkeys(core + extra))
    broad = [s for s in sp500() if s not in full]
    os.makedirs(os.path.join(HERE, "bars"), exist_ok=True)
    result, errors = {}, []

    def work(sym):
        keep = sym in full
        rows, src = yahoo(sym, "5y" if keep else "1y")
        if not rows:
            rows, src = stooq(sym)
        if not rows:
            return sym, None, None, None
        return sym, rows, src, keep

    with ThreadPoolExecutor(8) as ex:
        for sym, rows, src, keep in ex.map(work, full + broad):
            if not rows:
                errors.append(sym)
                continue
            s = summary(rows, keep)
            s["source"] = src
            result[sym] = s
            if keep:
                fn = sym.replace("^", "_").replace("=", "_")
                with open(os.path.join(HERE, "bars", fn + ".csv"), "w", newline="") as f:
                    w = csv.writer(f)
                    w.writerow(["date", "open", "high", "low", "close", "volume"])
                    for r in rows:
                        w.writerow([r[0]] + [round(x, 4) for x in r[1:5]] + [int(r[5])])

    gspc = result.get("^GSPC", {}).get("date")
    out = {"session_date": gspc, "generated_utc": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
           "count": len(result), "errors": errors,
           "note": "session_date = last ^GSPC bar. A symbol whose 'date' is older than session_date did not trade or did not update.",
           "symbols": result}
    with open(os.path.join(HERE, "latest.json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"session {gspc}: {len(result)} symbols, {len(errors)} errors: {errors[:20]}")
    if len(result) < 30:
        sys.exit(1)

if __name__ == "__main__":
    main()
