# llama-benchy — llama-bench-style benchmarking for vLLM

A generic, cross-track benchmark client: [`eugr/llama-benchy`](https://github.com/eugr/llama-benchy)
brings `llama-bench`-style prompt-processing (pp) / token-generation (tg) sweep measurements to any
OpenAI-compatible endpoint, including vLLM and SGLang — unlike `llama-bench` itself (llama.cpp only)
or vLLM's own `benchmark_serving` (limited accuracy at varying context depths). It works against
**either** KV-transfer track's deployed server (`../../tracks/nixl/vllm/08-deploy-qwen-nixl.sh`,
`../../tracks/mooncake/vllm/03-deploy.sh`, etc.) since it just talks to `/v1/chat/completions` — it
has no opinion about NixlConnector vs. MooncakeConnector underneath.

[`alexziskind1/llama-benchy-viz-tui`](https://github.com/alexziskind1/llama-benchy-viz-tui) consumes
llama-benchy's `--emit-progress` JSONL stream to render a live terminal dashboard: streaming tok/s
chart, separate prefill (pp) vs. decode (tg) speed, TTFT, and a results table filling in as each
depth/pp/tg/concurrency cell completes.

## Run

```bash
cd /root/rixl-bench   # or wherever this repo lands on the remote host
bash bench/llama-benchy/run.sh
```

One command does everything: installs `llama-benchy`/`llama-benchy-viz-tui` via `uv tool install` on
first run (installs `uv` itself if missing is on you — see the script's error message), checks
whether `BASE_URL` is already healthy, and if not, **runs `DEPLOY_SCRIPT` for you** (default:
`../../tracks/nixl/vllm/08-deploy-qwen-nixl.sh`, serving `Qwen/Qwen2.5-Coder-14B-Instruct` on port
8000) before launching the sweep. If `BASE_URL` is already serving, it skips straight to
benchmarking — safe to re-run against a server left up from a previous session.

**Docker image builds are not automatic** — that's a separate ~20-25 min one-time step
(`../../tracks/nixl/vllm/06-build-vllm.sh`, `../../tracks/mooncake/vllm/01-build.sh`, etc.). If the
image the deploy script needs isn't built yet, it fails with a clear "run NN-build first" message
rather than trying to build it inline.

See the script's header comment for the full list of overridable env vars (`BASE_URL`, `MODEL`,
`AUTO_DEPLOY`, `DEPLOY_SCRIPT`, `PORT`, `DEPTH`, `PP`, `TG`, `CONCURRENCY`, etc.).

```bash
# Benchmark the Mooncake track instead — deploys via its 03-deploy.sh if not already up:
DEPLOY_SCRIPT=stack/tracks/mooncake/vllm/03-deploy.sh MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
bash bench/llama-benchy/run.sh

# Point at a server that's already running elsewhere, no auto-deploy, plain output, save as JSON:
BASE_URL=http://<SETUP2_PD_NODE_IP>:8000/v1 AUTO_DEPLOY=0 VIZ=0 SAVE_FORMAT=json \
bash bench/llama-benchy/run.sh
```

Results land in `results/$(hostname -s)/$(date +%F)-llama-benchy/` (or `RESULTS=<path>` override) as `llama-benchy-<timestamp>.<format>`.
