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

  # HANDOFF OPEN-3: turn the by-hand OPEN-2 arithmetic into one repeatable run.
  # Requires --concurrency 1 (the three arms below are only meaningful serially)
  # and --kv-bytes-per-token (bytes of KV per token per request -- compute it
  # from the model config, e.g. layers * kv_heads/TP * head_size * 2(K,V) * 2(bf16)).
  pd_bench.py --url http://127.0.0.1:9001 --model <m> --label reuse72 \
              --concurrency 1 --prompt-tokens 3840 --max-tokens 32 \
              --kvpath --kv-bytes-per-token 327680 --link-mbps 3125
"""
import argparse, json, time, statistics, sys, threading, queue
import urllib.request

FILLER = ("The quarterly logistics review noted that regional distribution "
          "centers continued to operate within expected tolerances. ")


def build_prompt(seed: int, approx_tokens: int, shared_prefix: int = 0) -> str:
    """
    shared_prefix=0  -> every request gets a UNIQUE long prefix. Chunk keys are
                        prefix-derived, so nothing is reusable and every request
                        pays a full prefill. This is the HANDOFF case.

    shared_prefix=N  -> every request shares ONE long prefix keyed by N, and
                        differs only in a short trailing question. All but the
                        final chunk are therefore reusable across requests, so
                        one store amortises over many loads. This is the REUSE
                        case, and the only one where the economics can work.

    vLLM's own prefix cache MUST be off (--no-enable-prefix-caching) or vLLM
    answers the repeat itself and LMCache is never consulted -- the number would
    then be measuring vLLM, not the storage tier.
    """
    reps = max(1, approx_tokens // 13)
    if shared_prefix:
        body = (f"Document reference {shared_prefix:09d}. Internal circulation only.\n\n"
                + FILLER * reps)
        return body + f"\n\nQuestion {seed:06d}: summarize the status.\nAnswer:"
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


def run_level(url, model, conc, total, ptokens, max_tokens, timeout, seed0, shared=0):
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
                r = one_request(url, model,
                                build_prompt(seed, ptokens, shared),
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


def median_min_max(vals):
    vals = sorted(vals)
    return statistics.median(vals), vals[0], vals[-1]


def run_arm(url, model, ptokens, shared_key, max_tokens, timeout, seed_start, repeats):
    """
    One warmup request (discarded) followed by `repeats` measured requests, all
    at concurrency 1. The warmup is unconditional across all three kvpath arms:
    for the reuse arm it is what turns the FIRST request from a store into a
    load (everything measured after it is a hit); for the decode and recompute
    arms there is no cache to warm, but a first request still pays one-time
    JIT/allocator costs that a real workload would have already absorbed, so
    it is discarded here too for parity between the three arms.

    shared_key=0 gives every call (warmup included) a fresh, unique prefix --
    the recompute arm, which must never measure a hit against itself. A nonzero
    shared_key gives every call the SAME long prefix (only the trailing
    question text varies with the seed) -- the reuse arm, where that repetition
    across calls is the entire point.
    """
    one_request(url, model, build_prompt(seed_start, ptokens, shared_key),
                max_tokens, timeout)
    lat, ptoks = [], []
    for i in range(repeats):
        dt, ptok, _ = one_request(url, model,
                                  build_prompt(seed_start + 1 + i, ptokens, shared_key),
                                  max_tokens, timeout)
        lat.append(dt)
        ptoks.append(ptok)
    return lat, ptoks


def run_kvpath(args):
    """
    HANDOFF OPEN-3: this is the by-hand OPEN-2 arithmetic (three separate
    pd_bench runs, a decode isolation, and subtraction typed into a markdown
    table) turned into one repeatable instrument, so "make the number bigger,
    then re-measure" does not require re-deriving the method each time.

    Three arms, all at concurrency 1:
      decode   -- SHORT prompt (--decode-probe-tokens). Latency is decode plus
                  fixed overhead, and stands in for the floor under both
                  subtractions below.
      recompute-- full-length prompt, UNIQUE prefix (shared_prefix=0). Latency
                  minus the decode floor is prefill time.
      reuse    -- full-length prompt, SHARED prefix (same idea as --reuse KEY).
                  Latency minus the decode floor is KV load time.

    Every arm reports median/min/max over --kvpath-repeats samples; the
    derived MB/s numbers are computed from the MEDIANS, not from single
    samples, because OPEN-2's original 617 MB/s was already a fragile
    subtraction of two ~2s numbers and a single noisy sample on either side
    would move it a lot.
    """
    if args.kv_bytes_per_token is None:
        print("ERROR: --kvpath requires --kv-bytes-per-token (bytes of KV per "
              "token per request -- layers * kv_heads/TP * head_size * 2(K,V) "
              "* 2(bf16); see HANDOFF's 16 MiB store ceiling section for the "
              "worked example). Refusing to guess.", file=sys.stderr)
        return 2

    repeats = args.kvpath_repeats
    # Fold in the low bits of wall-clock time so that re-running this with the
    # default --seed-base does not collide with a shared-prefix key left live
    # from a previous invocation -- HANDOFF's own trap #2 ("every run needs
    # fresh seeds, the backend is persistent") applies just as much to the
    # reuse arm's warmup-as-store as it does to a full concurrency sweep.
    seed = args.seed_base + (int(time.time()) % 100000) * 10

    print(f"# kvpath  url={args.url}  model={args.model}  label={args.label}  "
          f"prompt~{args.prompt_tokens}tok  decode_probe~{args.decode_probe_tokens}tok  "
          f"max_tokens={args.max_tokens}  repeats={repeats}  "
          f"kv_bytes_per_token={args.kv_bytes_per_token}")
    print("# method: decode-only baseline, unique-prefix recompute, shared-prefix "
          "reuse -- see HANDOFF OPEN-2/OPEN-3. All three arms run at concurrency 1.")

    arms = {}
    try:
        print("# warmup: one discarded request per arm before any timing is kept "
              "(cache store for reuse, JIT/allocator warmth for the other two)")

        lat, ptoks = run_arm(args.url, args.model, args.decode_probe_tokens, 0,
                             args.max_tokens, args.timeout, seed, repeats)
        arms["decode"] = (lat, ptoks)
        seed += (repeats + 1) * 10  # never reuse a prefix, same discipline as run_level

        lat, ptoks = run_arm(args.url, args.model, args.prompt_tokens, 0,
                             args.max_tokens, args.timeout, seed, repeats)
        arms["recompute"] = (lat, ptoks)
        seed += (repeats + 1) * 10

        reuse_key = seed  # constant for this arm: warmup stores it, repeats load it
        lat, ptoks = run_arm(args.url, args.model, args.prompt_tokens, reuse_key,
                             args.max_tokens, args.timeout, seed, repeats)
        arms["reuse"] = (lat, ptoks)
    except Exception as e:
        print(f"ERROR: kvpath measurement failed: {type(e).__name__}: {e}",
              file=sys.stderr)
        return 1

    stats = {}
    print(f"\n{'arm':>10} {'median_s':>9} {'min_s':>9} {'max_s':>9} {'ptok':>6}")
    for name in ("decode", "recompute", "reuse"):
        lat, ptoks = arms[name]
        med, lo, hi = median_min_max(lat)
        ptok = statistics.median(ptoks)
        stats[name] = (med, lo, hi, ptok)
        print(f"{name:>10} {med:>9.3f} {lo:>9.3f} {hi:>9.3f} {ptok:>6.0f}")
        spread = (hi - lo) / med if med else 0.0
        if spread > 0.25:
            print(f"WARNING: arm '{name}' latency spread is {spread * 100:.0f}% "
                  f"- treat the derived MB/s as indicative only")

    t_decode = stats["decode"][0]
    t_recompute, t_reuse = stats["recompute"][0], stats["reuse"][0]
    ptok_recompute, ptok_reuse = stats["recompute"][3], stats["reuse"][3]
    bpt = args.kv_bytes_per_token

    prefill_time = t_recompute - t_decode
    load_time = t_reuse - t_decode
    # The floor under both subtractions is the SAME decode probe, measured at a
    # short context. Decode costs slightly more at full context than at 81
    # tokens, so both prefill_time and load_time above are mild over-estimates
    # -- and they move together, so the ratio between them (the speedup line
    # below) is less affected than either number alone. This is the same
    # caveat OPEN-2 noted by hand; it does not go away just because the
    # subtraction is now automated.
    floor_valid = prefill_time > 0 and prefill_time >= 0.05 * t_decode
    load_valid = load_time > 0 and load_time >= 0.05 * t_decode

    kv_bytes_reuse = ptok_reuse * bpt
    kv_bytes_recompute = ptok_recompute * bpt
    load_mbps = None  # set below iff load_valid; kept unbound-safe for the link block

    print("\n# derived")
    print(f"  KV per request ({ptok_reuse:.0f} tok x {bpt} B/tok)"
          f"{'':>10} {kv_bytes_reuse / 1e9:.2f} GB")

    if floor_valid:
        prefill_mbps = kv_bytes_recompute / prefill_time / 1e6
        print(f"  prefill, full prompt{'':>25} {prefill_time:.2f} s   "
              f"({prefill_mbps:.0f} MB/s equivalent)")
    else:
        print(f"  prefill, full prompt{'':>25} INDETERMINATE  "
              f"(recompute {t_recompute:.3f}s - decode {t_decode:.3f}s = "
              f"{prefill_time:.3f}s is <=0 or under 5% of the decode floor -- "
              f"the decode probe is not a valid floor here)")

    if load_valid:
        load_mbps = kv_bytes_reuse / load_time / 1e6
        print(f"  KV load, same tokens{'':>25} {load_time:.2f} s   ->  {load_mbps:.0f} MB/s")
    else:
        print(f"  KV load, same tokens{'':>25} INDETERMINATE  "
              f"(reuse {t_reuse:.3f}s - decode {t_decode:.3f}s = "
              f"{load_time:.3f}s is <=0 or under 5% of the decode floor -- "
              f"the decode probe is not a valid floor here)")

    if args.link_mbps:
        print(f"  link{'':>41} {args.link_mbps:.0f} MB/s")
        if load_valid:
            eff = load_mbps / args.link_mbps * 100
            print(f"  path efficiency{'':>30} {eff:.1f}%")
        else:
            print(f"  path efficiency{'':>30} INDETERMINATE")

    if floor_valid and load_valid and load_time > 0:
        speedup = prefill_time / load_time
        verdict = "WIN" if speedup > 1.0 else "LOSS"
        print(f"  reuse speedup (prefill / load){'':>15} {speedup:.2f}x   {verdict}")
    else:
        print(f"  reuse speedup (prefill / load){'':>15} INDETERMINATE")

    print("\n# CAVEAT: the decode probe is measured at --decode-probe-tokens "
          f"({args.decode_probe_tokens}) tokens of context, and decode costs "
          "slightly more at the full --prompt-tokens context, so prefill_time "
          "and load_time above are both mild over-estimates that move together.")
    print("# REMINDER: cross-check `need to load` on the server/receiver log for "
          "both the recompute and reuse arms before trusting this. A speedup "
          "that is really a silent re-prefill and a dead heat that is really a "
          "cache MISS are the two standing failure modes this file cannot see "
          "from the client side alone.")
    return 0


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
    ap.add_argument("--reuse", type=int, default=0, metavar="KEY",
                    help="shared-prefix REUSE mode: all requests share the long "
                         "prefix keyed by KEY and differ only in a short suffix. "
                         "0 (default) = unique prefix per request (no reuse).")
    ap.add_argument("--kvpath", action="store_true",
                    help="HANDOFF OPEN-3: measure the KV transfer path's effective "
                         "MB/s in one invocation (decode-only baseline vs "
                         "recompute vs reuse, all at concurrency 1), instead of "
                         "the by-hand three-run derivation. Requires --concurrency "
                         "1 and --kv-bytes-per-token.")
    ap.add_argument("--decode-probe-tokens", type=int, default=81,
                    help="prompt length for the kvpath decode-only baseline arm "
                         "(default 81, the value OPEN-2 used by hand).")
    ap.add_argument("--kv-bytes-per-token", type=int, default=None,
                    help="bytes of KV per token per request, e.g. "
                         "layers * kv_heads/TP * head_size * 2(K,V) * 2(bf16). "
                         "Required by --kvpath.")
    ap.add_argument("--kvpath-repeats", type=int, default=5,
                    help="measured samples per arm in --kvpath mode (default 5); "
                         "a warmup request precedes these and is discarded.")
    ap.add_argument("--link-mbps", type=float, default=None,
                    help="optional: known link bandwidth in MB/s, to print "
                         "kvpath's path efficiency = load_mbps / link_mbps.")
    args = ap.parse_args()

    levels = [int(x) for x in args.concurrency.split(",")]

    if args.kvpath:
        if len(levels) != 1 or levels[0] != 1:
            print("ERROR: --kvpath measures all three arms at concurrency 1 "
                  "(the decode/recompute/reuse subtraction is only meaningful "
                  "serially). Pass --concurrency 1, not "
                  f"{args.concurrency!r}.", file=sys.stderr)
            return 2
        return run_kvpath(args)

    seed = args.seed_base
    mode = f"REUSE(shared prefix key={args.reuse})" if args.reuse else "UNIQUE prefix per request"
    print(f"# {args.label}  url={args.url}  prompt~{args.prompt_tokens}tok  "
          f"max_tokens={args.max_tokens}  n={args.requests}/level")
    print(f"# mode: {mode}")
    print(f"{'conc':>5} {'ok':>4} {'err':>4} {'wall_s':>8} {'req/s':>7} "
          f"{'mean_s':>8} {'p50_s':>8} {'p95_s':>8} {'ptok':>6}")
    rows = []
    for c in levels:
        res, errs, wall = run_level(args.url, args.model, c, args.requests,
                                    args.prompt_tokens, args.max_tokens,
                                    args.timeout, seed, args.reuse)
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
