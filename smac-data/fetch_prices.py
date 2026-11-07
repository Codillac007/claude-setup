"""SMAC price feed v2. Runs on GitHub Actions after the US close.

Writes (always):
  smac-data/status.json      diagnostics of the last run (what worked, what failed and why)
Writes (when data was fetched):
  smac-data/latest.json      one summary row per symbol (core list + extra.txt + S&P 500)
  smac-data/bars/<SYM>.csv   daily OHLCV: 5y for tickers.txt/extra.txt, 1y for the other S&P 500 names
Sources, in order: yfinance (handles Yahoo cookies), Yahoo chart API, Stooq CSV.
"""
import csv, datetime as dt, io, json, os, sys, time, traceback, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"}
DIAG = {"started_utc": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "steps": [], "errors": {}}

def note(msg):
    print(msg, flush=True)
    DIAG["steps"].append(msg)

def err(source, sym, e):
    lst = DIAG["errors"].setdefault(source, [])
    if len(lst) < 8:
        lst.append(f"{sym}: {type(e).__name__}: {str(e)[:200]}")

def read_list(name):
    p = os.path.join(HERE, name)
    return [l.strip() for l in open(p) if l.strip() and not l.startswith("#")] if os.path.exists(p) else []

def get(url, timeout=12):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout).read()

# ---------- sources ----------
def via_yfinance(symbols, period):
    """Bulk download; returns {sym: rows}."""
    out = {}
    try:
        import yfinance as yf
    except Exception as e:
        err("yfinance", "import", e)
        return out
    for i in range(0, len(symbols), 80):
        chunk = symbols[i:i + 80]
        try:
            df = yf.download(chunk, period=period, interval="1d", group_by="ticker", auto_adjust=False,
                             threads=True, progress=False)
        except Exception as e:
            err("yfinance", ",".join(chunk[:3]), e)
            continue
        for sym in chunk:
            try:
                sub = df[sym] if len(chunk) > 1 else df
                sub = sub.dropna(subset=["Open", "High", "Low", "Close"])
                rows = [[idx.date().isoformat(), float(r["Open"]), float(r["High"]), float(r["Low"]), float(r["Close"]),
                         int(r["Volume"]) if r["Volume"] == r["Volume"] else 0] for idx, r in sub.iterrows()]
                if rows:
                    out[sym] = rows
            except Exception as e:
                err("yfinance", sym, e)
        time.sleep(1)
    return out

def via_yahoo(sym, rng):
    for host in ("query1", "query2"):
        try:
            u = f"https://{host}.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?range={rng}&interval=1d"
            r = json.loads(get(u))["chart"]["result"][0]
            q, off = r["indicators"]["quote"][0], r["meta"].get("gmtoffset", 0)
            rows = [[dt.datetime.utcfromtimestamp(t + off).date().isoformat(), o, h, l, c, v or 0]
                    for t, o, h, l, c, v in zip(r["timestamp"], q["open"], q["high"], q["low"], q["close"], q["volume"])
                    if None not in (o, h, l, c)]
            if rows:
                return rows
        except Exception as e:
            err("yahoo_chart", sym, e)
    return None

STOOQ_MAP = {"^GSPC": "^spx", "^IXIC": "^ndq", "^DJI": "^dji", "^VIX": "^vix", "ES=F": "es.f", "NQ=F": "nq.f",
             "CL=F": "cl.f", "BZ=F": "cb.f", "GC=F": "gc.f", "HG=F": "hg.f", "DX-Y.NYB": "dx.f"}

def via_stooq(sym):
    if sym in STOOQ_MAP:
        code = STOOQ_MAP[sym]
    elif sym.startswith("^") or "=" in sym or "." in sym:
        return None
    else:
        code = sym.lower().replace("-", ".") + ".us"
    try:
        txt = get(f"https://stooq.com/q/d/l/?s={code}&i=d").decode()
        rows = [[r["Date"], float(r["Open"]), float(r["High"]), float(r["Low"]), float(r["Close"]), int(float(r.get("Volume") or 0))]
                for r in csv.DictReader(io.StringIO(txt)) if r.get("Close") not in (None, "", "N/D")]
        return rows[-1300:] or None
    except Exception as e:
        err("stooq", sym, e)
        return None

def sp500():
    for url in ("https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv",):
        try:
            txt = get(url).decode()
            return [r["Symbol"].replace(".", "-") for r in csv.DictReader(io.StringIO(txt))]
        except Exception as e:
            err("sp500_list", url, e)
    return []

# ---------- output ----------
def summary(rows, keep_last10):
    closes, vols = [r[4] for r in rows], [r[5] for r in rows]
    sma = lambda n: round(sum(closes[-n:]) / n, 4) if len(closes) >= n else None
    yr = closes[-252:]
    out = {"date": rows[-1][0], "open": round(rows[-1][1], 4), "high": round(rows[-1][2], 4), "low": round(rows[-1][3], 4),
           "close": round(closes[-1], 4),
           "chg_pct": round((closes[-1] / closes[-2] - 1) * 100, 2) if len(closes) > 1 else None,
           "chg_5d_pct": round((closes[-1] / closes[-6] - 1) * 100, 2) if len(closes) > 5 else None,
           "chg_21d_pct": round((closes[-1] / closes[-22] - 1) * 100, 2) if len(closes) > 21 else None,
           "sma50": sma(50), "sma200": sma(200), "high_52w": round(max(yr), 4), "low_52w": round(min(yr), 4),
           "vol": vols[-1],
           "vol_vs_50d": round(vols[-1] / (sum(vols[-51:-1]) / 50), 2) if len(vols) > 50 and sum(vols[-51:-1]) else None}
    if keep_last10:
        out["last10"] = [[r[0], round(r[4], 4), r[5]] for r in rows[-10:]]
    return out

def write_status(extra):
    DIAG.update(extra)
    DIAG["finished_utc"] = dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(os.path.join(HERE, "status.json"), "w") as f:
        json.dump(DIAG, f, indent=1)

def main():
    t0 = time.time()
    core = list(dict.fromkeys(read_list("tickers.txt") + read_list("extra.txt")))
    broad = [s for s in sp500() if s not in core]
    note(f"core {len(core)}, s&p {len(broad)}")
    data, source = {}, {}

    for syms, period in ((core, "5y"), (broad, "1y")):
        got = via_yfinance(syms, period)
        for s, rows in got.items():
            data[s], source[s] = rows, "yfinance"
        note(f"yfinance {period}: {len(got)}/{len(syms)} in {int(time.time() - t0)}s")

    missing = [s for s in core + broad if s not in data]
    for s in missing:
        if time.time() - t0 > 18 * 60:
            break
        rows = via_yahoo(s, "5y" if s in core else "1y")
        src = "yahoo_chart"
        if not rows:
            rows, src = via_stooq(s), "stooq"
        if rows:
            data[s], source[s] = (rows if s in core else rows[-260:]), src
    note(f"after fallbacks: {len(data)}/{len(core) + len(broad)} in {int(time.time() - t0)}s")

    os.makedirs(os.path.join(HERE, "bars"), exist_ok=True)
    result = {}
    for s, rows in data.items():
        try:
            sm = summary(rows, s in core)
            sm["source"] = source[s]
            result[s] = sm
            with open(os.path.join(HERE, "bars", s.replace("^", "_").replace("=", "_") + ".csv"), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["date", "open", "high", "low", "close", "volume"])
                for r in rows:
                    w.writerow([r[0]] + [round(x, 4) for x in r[1:5]] + [int(r[5])])
        except Exception as e:
            err("summary", s, e)

    gspc = result.get("^GSPC", {}).get("date") or max((v["date"] for v in result.values()), default=None)
    errors = [s for s in core + broad if s not in result]
    if result:
        with open(os.path.join(HERE, "latest.json"), "w") as f:
            json.dump({"session_date": gspc, "generated_utc": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                       "count": len(result), "errors": errors,
                       "note": "session_date = last ^GSPC bar. A symbol whose 'date' is older than session_date did not trade or did not update.",
                       "symbols": result}, f, separators=(",", ":"))
    write_status({"ok": len(result) >= 30, "session_date": gspc, "count": len(result), "missing": len(errors),
                  "seconds": int(time.time() - t0)})
    note(f"done: session {gspc}, {len(result)} symbols, {len(errors)} missing")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        DIAG["fatal"] = traceback.format_exc()[-2000:]
        write_status({"ok": False})
        print(DIAG["fatal"])
    sys.exit(0)  # always let the commit step run; status.json says whether data is good
