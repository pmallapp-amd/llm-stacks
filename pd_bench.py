#!/usr/bin/env python3
"""
pd_bench.py - concurrency benchmark for the P/D pair.

WHY THIS EXISTS. HANDOFF OPEN-1: P+D is proven correct but not proven
worthwhile, and no latency or throughput number had ever been taken through the
proxy. The proxy is SEQUENTIAL per request -- it calls prefill with
max_tokens=1, discards the response, then streams from decode -- so end-to-end
latency for ONE request is both legs and will look like a loss. The win, if
there is one, comes from freeing the decode host from prefill work, and that
only shows up as throughput under CONCURRENT load. Measuring at c=1 and
reporting it as a result would be a misreading, not a result.

Every prompt is UNIQUE (the prefix is seeded), because chunk keys are
prefix-derived and a repeated prompt measures a cache hit rather than the path
under test.

usage:
  pd_bench.py --url http://127.0.0.1:9001 --model <m> --label disagg \
              --concurrency 1,4,8 --requests 16 --prompt-tokens 4000
"""
import argparse, json, time, statistics, sys, threading, queue
import urllib.request

FILLER = ("The quarterly logistics review noted that regional distribution "
          "centers continued to operate within expected tolerances. ")


def build_prompt(seed: int, approx_tokens: int) -> str:
    # ~13 tokens per filler sentence; seed varies the PREFIX so chunk keys differ
    reps = max(1, approx_tokens // 13)
    return (f"Document reference {seed:09d}. Internal circulation only.\n\n"
            + FILLER * reps
            + "\n\nSummarize the operational status in one sentence.\nAnswer:")


def one_request(url, model, prompt, max_tokens, timeout):
    payload = {"model": model, "prompt": prompt,
               "max_tokens": max_tokens, "temperature": 0.0}
    req = urllib.request.Request(
        url + "/v1/completions", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer dummy"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode())
    dt = time.perf_counter() - t0
    usage = d.get("usage", {}) or {}
    return dt, usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)


def run_level(url, model, conc, total, ptokens, max_tokens, timeout, seed0):
    work = queue.Queue()
    for i in range(total):
        work.put(seed0 + i)
    results, errors = [], []
    lock = threading.Lock()

    def worker():
        while True:
            try:
                seed = work.get_nowait()
            except queue.Empty:
                return
            try:
                r = one_request(url, model, build_prompt(seed, ptokens),
                                max_tokens, timeout)
                with lock:
                    results.append(r)
            except Exception as e:
                with lock:
                    errors.append(f"{type(e).__name__}: {e}")

    threads = [threading.Thread(target=worker) for _ in range(conc)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    return results, errors, wall


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--concurrency", default="1,4,8")
    ap.add_argument("--requests", type=int, default=16)
    ap.add_argument("--prompt-tokens", type=int, default=4000)
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--seed-base", type=int, default=100000)
    args = ap.parse_args()

    levels = [int(x) for x in args.concurrency.split(",")]
    seed = args.seed_base
    print(f"# {args.label}  url={args.url}  prompt~{args.prompt_tokens}tok  "
          f"max_tokens={args.max_tokens}  n={args.requests}/level")
    print(f"{'conc':>5} {'ok':>4} {'err':>4} {'wall_s':>8} {'req/s':>7} "
          f"{'mean_s':>8} {'p50_s':>8} {'p95_s':>8} {'ptok':>6}")
    rows = []
    for c in levels:
        res, errs, wall = run_level(args.url, args.model, c, args.requests,
                                    args.prompt_tokens, args.max_tokens,
                                    args.timeout, seed)
        seed += args.requests * 10          # never reuse a prefix
        if not res:
            print(f"{c:>5} {0:>4} {len(errs):>4}   ALL FAILED: {errs[:1]}")
            continue
        lat = sorted(r[0] for r in res)
        p50 = statistics.median(lat)
        p95 = lat[min(len(lat) - 1, int(0.95 * len(lat)))]
        ptok = statistics.median(r[1] for r in res)
        rps = len(res) / wall
        rows.append((c, rps, statistics.mean(lat)))
        print(f"{c:>5} {len(res):>4} {len(errs):>4} {wall:>8.2f} {rps:>7.3f} "
              f"{statistics.mean(lat):>8.2f} {p50:>8.2f} {p95:>8.2f} {ptok:>6.0f}")
        if errs:
            print(f"      first error: {errs[0][:120]}")
    if rows:
        base = rows[0][1]
        print("\n# throughput scaling vs c=1: " +
              ", ".join(f"c{c}={rps / base:.2f}x" for c, rps, _ in rows))
    print("\n# NOTE: a single-request (c=1) comparison is NOT a result -- the proxy")
    print("#       runs prefill then decode sequentially, so c=1 latency is both legs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
