#!/usr/bin/env python3
"""
needle_test.py - the discriminative P/D check.

Sends N long needle prompts through the proxy and reports, per request:
  - whether the needle was recovered (correctness)
  - the usage block (prompt token count)

Correctness ALONE cannot distinguish a working P/D pair from the illusion --
both configurations answer correctly. The caller MUST separately confirm
"need to load: > 0" on the RECEIVER's container log. This script prints the
log-scrape command to run.

usage:
  needle_test.py --port 9000 --model TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
                 --seed-base 0 --count 4 --repeats 34
"""
import argparse, json, hashlib, sys, urllib.request, time

# A filler sentence repeated to pad the prompt past chunk_size (256 tokens).
# NOTE: chunk keys are PREFIX-derived, so varying only --repeats rekeys just the
# final chunk. To force a genuinely cold store, --seed-base changes the
# BEGINNING of the prompt.
FILLER = ("The quarterly logistics review noted that regional distribution "
          "centers continued to operate within expected tolerances. ")


def build_prompt(seed: int, repeats: int, needle_val: str) -> str:
    head = f"Document reference {seed:08d}. Internal circulation only.\n\n"
    body = FILLER * repeats
    needle = f"\n\nThe access code for vault seven is {needle_val}.\n\n"
    tail = FILLER * repeats
    q = "\n\nQuestion: What is the access code for vault seven?\nAnswer:"
    return head + body + needle + tail + q


def post(url: str, payload: dict, timeout: int):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer dummy"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--seed-base", type=int, default=0)
    ap.add_argument("--count", type=int, default=4)
    ap.add_argument("--repeats", type=int, default=34,
                    help="filler repeats per half; 34 fits TinyLlama's 2048 ctx")
    ap.add_argument("--max-tokens", type=int, default=24)
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()

    url = f"http://{args.host}:{args.port}/v1/completions"
    ok = 0
    for i in range(args.count):
        seed = args.seed_base + i
        # needle value derived from seed so each request has a distinct answer
        needle_val = hashlib.md5(f"vault-{seed}".encode()).hexdigest()[:6].upper()
        prompt = build_prompt(seed, args.repeats, needle_val)
        payload = {"model": args.model, "prompt": prompt,
                   "max_tokens": args.max_tokens, "temperature": 0.0}
        t0 = time.time()
        try:
            d = post(url, payload, args.timeout)
        except Exception as e:
            print(f"[{i}] seed={seed} ERROR {type(e).__name__}: {e}")
            continue
        dt = time.time() - t0
        if "choices" not in d:
            print(f"[{i}] seed={seed} NO CHOICES: {json.dumps(d)[:300]}")
            continue
        text = d["choices"][0]["text"]
        usage = d.get("usage", {})
        hit = needle_val in text.upper()
        ok += hit
        print(f"[{i}] seed={seed} needle={needle_val} "
              f"{'RECOVERED' if hit else 'MISSING  '} "
              f"prompt_tok={usage.get('prompt_tokens')} "
              f"completion_tok={usage.get('completion_tokens')} "
              f"{dt:.2f}s")
        if not hit:
            print(f"      got: {text[:160]!r}")

    print(f"\nRESULT: {ok}/{args.count} needles recovered")
    print("\nCorrectness does NOT prove KV moved. Now confirm on the RECEIVER:")
    print('  docker logs <receiver-container> 2>&1 | grep -E "need to load" | tail -20')
    print("  -> 'need to load: 0' means NO KV crossed; it silently re-prefilled.")
    return 0 if ok == args.count else 1


if __name__ == "__main__":
    sys.exit(main())
