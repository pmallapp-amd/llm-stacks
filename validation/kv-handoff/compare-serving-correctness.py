#!/usr/bin/env python3
"""Does this serving stack return CORRECT tokens? — track-agnostic correctness gate.

Why this exists
---------------
A broken KV handoff does not return an error. It returns HTTP 200 with fluent,
grammatical, completely wrong text. Every layer reports success: the transport
says the transfer completed, vLLM says the request finished, the client sees a
normal completion. Nothing is red.

On 2026-08-20 a MORI P/D deployment was diagnosed from ONE sample per mode. The
two samples happened to match, which produced the conclusion "byte-identical
output in READ and WRITE mode, therefore decode never consumes prefill's KV".
Both halves of that were wrong: the output was not deterministic (5 identical
greedy requests gave 4 distinct completions), and decode *was* consuming the KV
all along. The real cause was a KV-cache layout mismatch. Sampling the same
prompt five times would have killed the false lead in one minute.

So this tool applies two checks, in the order that makes the cheap one fail
first:

  1. DETERMINISM.  The same prompt, N times, temperature=0. Needs no baseline,
     so it is the first thing to run against anything.

  2. BYTE-IDENTITY.  Every prompt must produce byte-identical output to a
     reference endpoint serving the same model without the connector under
     test. This catches deterministic corruption, which check 1 cannot.

IMPORTANT — not every stack is deterministic, and that is not always a bug.
Measured 2026-08-21 on vLLM+AITER+ATOM serving Qwen3-235B-A22B-FP8 with expert
parallelism and NO KV connector at all: 5 identical greedy requests gave 5
distinct completions at max_tokens=20, but exactly 1 at max_tokens=3. All were
semantically correct. Fused-MoE and expert-parallel all-to-all reductions are
non-associative, their order varies run to run, a near-tied logit flips, and
autoregression amplifies it.

So on a MoE/EP stack, use --probe-horizon: it measures the longest reproducible
generation and runs both checks at or below it. That is also the regime where a
corrupt KV handoff shows up most clearly, because wrong KV corrupts the FIRST
token, not the fortieth. A horizon of 0 — irreproducible at a single token —
cannot be rounding accumulation and IS a genuine defect.

Neither check is about speed. Run both, and only then benchmark.

Usage
-----
    # determinism only — no baseline needed
    ./compare-serving-correctness.py --endpoint http://127.0.0.1:9100/v1 \
        --model TinyLlama/TinyLlama-1.1B-Chat-v1.0

    # full gate, against a no-connector reference
    ./compare-serving-correctness.py --endpoint http://127.0.0.1:9100/v1 \
        --baseline http://127.0.0.1:8130/v1 --model <hf-name>

Exit code is 0 only if every requested check passes, so this can gate a deploy
script or a benchmark run.

NEVER point --endpoint at a prefill/decode port directly when a MoRIIO connector
is active: that connector encodes the peer ZMQ address into the request_id, and
an ordinary id raises ValueError and kills the EngineCore. Use the router/proxy.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

# Short factual prompts with unambiguous continuations, plus one long prompt.
# Length matters: a prompt shorter than one KV block can skip the transfer path
# entirely, so a suite of only short prompts can pass while the real path is
# broken. The last entry is deliberately long enough to span several blocks.
DEFAULT_PROMPTS = [
    "The capital of France is",
    "Two plus two equals",
    "The largest planet in our solar system is",
    "Write a Python function that returns the nth Fibonacci number.",
    (
        "In computer science, a hash table is a data structure that maps keys to "
        "values using a hash function. It offers average-case constant time "
        "lookup. A common way to resolve collisions between two keys that hash to "
        "the same bucket is called separate chaining, in which each bucket holds "
        "a linked list of entries. An alternative is open addressing, where the "
        "table probes for the next free slot. Summarize the difference between "
        "these two collision resolution strategies."
    ),
]


def complete(base_url, model, prompt, max_tokens, timeout):
    """One greedy completion. Returns (text, prompt_tokens)."""
    body = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": 0,
        }
    ).encode()
    req = urllib.request.Request(
        base_url.rstrip("/") + "/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d["choices"][0]["text"], d.get("usage", {}).get("prompt_tokens", -1)


def check_determinism(url, model, prompt, repeats, max_tokens, timeout):
    print(f"[1] Determinism — same prompt x{repeats}, temperature=0")
    print(f"    prompt: {prompt!r}")
    seen = {}
    for i in range(repeats):
        try:
            text, _ = complete(url, model, prompt, max_tokens, timeout)
        except Exception as e:
            print(f"    run {i}: REQUEST FAILED: {e}")
            return False
        seen.setdefault(text, []).append(i)
        print(f"    run {i}: {text[:72]!r}")
        sys.stdout.flush()

    n = len(seen)
    if n == 1:
        print(f"    PASS — 1 distinct output across {repeats} runs\n")
        return True
    print(f"    FAIL at max_tokens={max_tokens} — {n} distinct outputs across {repeats} runs.")
    print("           This is NOT automatically corruption. See --probe-horizon.\n")
    return False


def probe_horizon(url, model, prompt, repeats, timeout, ladder=(1, 3, 8, 16, 32)):
    """Find the longest generation that is still reproducible.

    Not every stack is deterministic at temperature=0. Measured 2026-08-21 on
    vLLM+AITER+ATOM serving Qwen3-235B-A22B-FP8 with expert parallelism, with NO
    KV connector at all:

        max_tokens=1  -> 1 distinct     max_tokens=3  -> 1 distinct
        max_tokens=8  -> 2 distinct     (and 5/5 distinct at 20)

    Every output was semantically correct; they diverged only in wording. The
    cause is non-associative floating-point reduction in the fused-MoE and
    expert-parallel all-to-all kernels: reduction order varies run to run, a
    near-tied logit flips, and autoregressive feedback amplifies it.

    So on a MoE/EP stack a flat "must be deterministic" gate fails on a
    known-good baseline, and byte-identity against a single baseline sample is
    meaningless past the horizon. Measure the horizon, then compare within it —
    which is also the regime where a corrupt KV handoff is most obvious, since
    wrong KV corrupts the FIRST token, not the fortieth.
    """
    print("[0] Deterministic horizon — longest reproducible generation")
    horizon = 0
    for n in ladder:
        try:
            outs = {complete(url, model, prompt, n, timeout)[0] for _ in range(repeats)}
        except Exception as e:
            print(f"    max_tokens={n:<3} REQUEST FAILED: {e}")
            break
        print(f"    max_tokens={n:<3} distinct={len(outs)}")
        if len(outs) != 1:
            break
        horizon = n
    if horizon == 0:
        print("    horizon = 0 — not reproducible even for a SINGLE token.")
        print("    One token cannot diverge by accumulated rounding, so this is a")
        print("    genuine defect, not MoE numerics.\n")
    else:
        print(f"    horizon = {horizon} tokens — compare byte-identity at or below this.\n")
    return horizon


def check_against_baseline(url, baseline, model, prompts, max_tokens, timeout):
    print("[2] Byte-identity against the no-connector baseline")
    passed = 0
    for i, p in enumerate(prompts):
        try:
            got, n_got = complete(url, model, p, max_tokens, timeout)
            ref, n_ref = complete(baseline, model, p, max_tokens, timeout)
        except Exception as e:
            print(f"    case {i}: REQUEST FAILED: {e}")
            continue

        # Some P/D proxies consume prefill's first sampled token, so the
        # candidate can be exactly one token shorter than the baseline. Compare
        # on the common prefix rather than reporting that as corruption.
        k = min(len(got), len(ref))
        if k and got[:k] == ref[:k]:
            passed += 1
            note = "" if len(got) == len(ref) else "  (candidate shorter; compared on overlap)"
            print(f"    case {i}: MATCH  [{n_got} prompt tokens]{note}")
        else:
            print(f"    case {i}: DIFFER [{n_got} vs {n_ref} prompt tokens]")
            print(f"        candidate: {got[:90]!r}")
            print(f"        baseline : {ref[:90]!r}")
        sys.stdout.flush()

    ok = passed == len(prompts)
    print(f"    {'PASS' if ok else 'FAIL'} — {passed}/{len(prompts)} byte-identical\n")
    return ok


def main():
    ap = argparse.ArgumentParser(
        description="Correctness gate for a serving stack: determinism + byte-identity."
    )
    ap.add_argument("--endpoint", required=True,
                    help="candidate OpenAI-compatible base URL, e.g. http://127.0.0.1:9100/v1 "
                         "(the ROUTER/PROXY — never a prefill/decode port under MoRIIO)")
    ap.add_argument("--baseline", default=None,
                    help="reference base URL serving the same model with no KV connector. "
                         "Omit to run the determinism check only.")
    ap.add_argument("--model", required=True, help="model name as the server expects it")
    ap.add_argument("--repeats", type=int, default=5, help="determinism samples (default: 5)")
    ap.add_argument("--max-tokens", type=int, default=24)
    ap.add_argument("--timeout", type=int, default=300, help="per-request seconds")
    ap.add_argument("--prompts-file", default=None,
                    help="newline-separated prompts to use instead of the built-in set")
    ap.add_argument("--probe-horizon", action="store_true",
                    help="first measure the longest reproducible generation and use it "
                         "for --max-tokens. Required on MoE/expert-parallel stacks, whose "
                         "baselines are legitimately non-deterministic past a few tokens.")
    args = ap.parse_args()

    prompts = DEFAULT_PROMPTS
    if args.prompts_file:
        with open(args.prompts_file, encoding="utf-8") as fh:
            prompts = [ln.rstrip("\n") for ln in fh if ln.strip()]

    print(f"candidate : {args.endpoint}")
    print(f"baseline  : {args.baseline or '(none — determinism check only)'}")
    print(f"model     : {args.model}\n")

    if args.probe_horizon:
        h = probe_horizon(args.endpoint, args.model, prompts[0], args.repeats, args.timeout)
        if h == 0:
            print("RESULT: FAIL — not reproducible at one token.")
            return 1
        args.max_tokens = min(args.max_tokens, h)
        print(f"    using max_tokens={args.max_tokens} for the checks below\n")

    results = [check_determinism(args.endpoint, args.model, prompts[0],
                                 args.repeats, args.max_tokens, args.timeout)]
    if args.baseline:
        results.append(check_against_baseline(args.endpoint, args.baseline, args.model,
                                              prompts, args.max_tokens, args.timeout))
    else:
        print("[2] Byte-identity — SKIPPED (no --baseline).")
        print("    Determinism alone does NOT prove correctness: a deterministic")
        print("    layout bug passes check 1 every time. Stand up a no-connector")
        print("    instance of the same model and re-run before trusting output.\n")

    if all(results):
        print("RESULT: PASS" + ("" if args.baseline else " (determinism only — see note above)"))
        return 0
    print("RESULT: FAIL — do not benchmark this deployment.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
