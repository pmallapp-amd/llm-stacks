#!/usr/bin/env bash
# deploy-pd-disaggregated.sh — persistent, production-shaped P/D (prefill/decode)
# disaggregation deploy: two vLLM instances (producer=prefill, consumer=decode)
# with real KV handoff over NixlConnector/UCX, plus vLLM's own upstream XpYd
# proxy (disagg_proxy_demo.py, vendored from vllm-project/vllm) in front for a
# single client-facing endpoint.
#
# Unlike ../../stack/tracks/nixl/vllm/05-llm.sh's run_pd() (which benchmarks once then tears
# both instances down), this leaves everything running — matches the shape of
# this repo's other persistent deploy scripts (../../stack/tracks/nixl/vllm/08-deploy-qwen-nixl.sh).
#
# Stack:
#   client -> disagg_proxy_demo.py (port PROXY_PORT, default 9000)
#               |-- prefill instance (port PREFILL_PORT, kv_role=kv_producer)
#               '-- decode instance  (port DECODE_PORT,  kv_role=kv_consumer)
#   KV handoff: NixlConnector over UCX, in whichever memory KV_BUFFER_DEVICE
#   names. `cpu` was not a choice until 2026-08-14, it was a workaround: the
#   nixl:base image built UCX --without-rocm, so NIXL's UCX plugin could not
#   register VRAM at all (its memReg() ucp_mem_query()s the registration and
#   refuses when GPU memory comes back as UCS_MEMORY_TYPE_HOST). UCX is now
#   built --with-rocm and shipped into the runtime, so `cuda` works — see
#   ../../stack/tracks/nixl/core/Dockerfile.nixl-base.
#
# Prerequisites: vllm-nixl:rocm + nixl-libs volume (../../stack/tracks/nixl/vllm/06-build-vllm.sh).
#
# Deployment shape — single host or 3-node — is controlled entirely by ROLE/
# PREFILL_HOST/DECODE_HOST; the container-launch logic is identical either way:
#   Single host (default): ROLE=all, PREFILL_HOST/DECODE_HOST left at 127.0.0.1,
#     optionally set PREFILL_GPUS/DECODE_GPUS to pin each instance to a disjoint
#     GPU set on a multi-GPU box instead of sharing one GPU via GPU_MEM_UTIL.
#   3-node: run this script once per host with ROLE=prefill|decode|proxy and
#     PREFILL_HOST/DECODE_HOST set to each host's real routable IP.
#
# Override env:
#   MODEL=<hf-name>        (default: TinyLlama/TinyLlama-1.1B-Chat-v1.0 — matches
#                          ../../stack/tracks/nixl/vllm/05-llm.sh's own choice for the dual-instance
#                          P/D case; a 14B model's weights alone (~28GB) don't leave
#                          room for two full instances at 0.40 util each on one MI210)
#   VLLM_IMAGE=<img>       (default: vllm-nixl:rocm)
#   GPU_MEM_UTIL=<f>       per-instance GPU mem fraction (default: 0.40 — sized for
#                          two instances sharing one GPU; raise substantially, e.g.
#                          0.85+, when PREFILL_GPUS/DECODE_GPUS give each instance
#                          its own dedicated GPU(s) instead). Applies per GPU, so
#                          under tensor parallelism the KV headroom is
#                          GPU_MEM_UTIL x per-GPU VRAM x TP minus the sharded
#                          weights, not minus the whole model.
#   DTYPE=<dtype>          --dtype passed to vLLM (default: float16 — unchanged
#                          from before this option existed). Use bfloat16 for
#                          checkpoints published in bf16 (Llama-3.x, Qwen2.5):
#                          float16's narrower exponent range can overflow to
#                          inf/NaN in large models trained in bf16.
#   PREFILL_PORT=<n>       (default: 8100)
#   DECODE_PORT=<n>        (default: 8000)
#   PROXY_PORT=<n>         client-facing single endpoint (default: 9000)
#   NIXL_BACKEND=UCX       (default; NixlConnector's only working transfer path)
#   KV_BUFFER_DEVICE=cpu|cuda
#                          where NixlConnector holds the KV buffer it transfers
#                          (default: cpu — unchanged, so existing callers and
#                          every historical result keep their meaning).
#                            cpu  : vLLM copies KV out of VRAM into a host
#                                   staging buffer, UCX moves host->host, the
#                                   consumer copies back into VRAM. Two extra
#                                   full-size device<->host copies per transfer;
#                                   for Qwen2.5-72B that is ~320 KB/token, i.e.
#                                   ~5.2 GB at depth 16384 crossing PCIe twice.
#                            cuda : the GPU KV cache is registered directly and
#                                   UCX moves it as VRAM (rocm_copy/rocm_ipc).
#                                   Requires a nixl-libs volume whose UCX has
#                                   ROCm support; this script checks and refuses
#                                   rather than letting vLLM fail at handoff
#                                   time with an opaque registration error.
#                          vLLM names the AMD device "cuda" — that is vLLM's
#                          platform-independent spelling, not a mistake.
#   UCX_TLS=<list>         passed straight through to UCX as UCX_TLS in both
#                          instances (default: unset — UCX picks for itself).
#   MAX_MODEL_LEN=<n>      --max-model-len passed to both instances (default: unset,
#                          vLLM infers from the HF config's max_position_embeddings —
#                          32768 for stock Qwen2.5-72B-Instruct, which is smaller
#                          than an agentic CLI's system prompt + tool schemas can
#                          easily exceed, producing a 400 that disagg_proxy_demo.py
#                          mislabels the same way as the tool-parser gap above: a
#                          200-status stream whose body is really an error, seen
#                          client-side as "stream ended without a finish reason").
#   HF_OVERRIDES=<json>    --hf-overrides passed to both instances (default: unset).
#                          Pairs with MAX_MODEL_LEN to enable Qwen2.5's documented
#                          YARN context extension beyond its native 32768. Validated
#                          recipe (4x, matches Qwen's own documented range) — this is
#                          what's actually live on <SETUP3_PREFILL_NODE>/<SETUP3_DECODE_NODE> as of 2026-08-19:
#                            MAX_MODEL_LEN=131072
#                            HF_OVERRIDES='{"rope_scaling":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":32768}}'
#                          NOTE: this build's _get_and_verify_max_len wants the dict
#                          key "rope_type", NOT "type" — Qwen's own model-card docs
#                          use "type", which throws KeyError: 'rope_type' at
#                          engine-args validation, before the server even binds a
#                          port. See [[reference_qwen_cli_72b_access]] session memory.
#                          1M recipe (UNVALIDATED — 32x factor, far past Qwen's own
#                          tested/documented YARN range of ~4x/131072; expect
#                          degraded output quality, and a single 1048576-token
#                          sequence would consume nearly this deployment's entire
#                          measured ~1.78M-token GPU KV cache budget at TP=4,
#                          leaving no headroom for concurrent requests):
#                            MAX_MODEL_LEN=1048576
#                            HF_OVERRIDES='{"rope_scaling":{"rope_type":"yarn","factor":32.0,"original_max_position_embeddings":32768}}'
#   TOOL_CALL_PARSER=<name> (default: hermes — Qwen2.5's tool-call format).
#                          Passed as --enable-auto-tool-choice --tool-call-parser
#                          <name> to both instances. A client that sends a
#                          `tools` array (any OpenAI-agentic CLI, e.g. Qwen CLI)
#                          against a server started without this gets a 400
#                          from vLLM ("auto" tool choice requires
#                          --enable-auto-tool-choice ...) that disagg_proxy_demo.py
#                          then mislabels as text/event-stream, which surfaces to
#                          the client as a bare "stream ended without a finish
#                          reason" instead of the real error. Set empty
#                          (TOOL_CALL_PARSER=) to omit both flags.
#
#                          ── When you need it: UCX_TLS=^rocm_ipc ──
#                          On a host whose kernel predates the cuMem/VMM path
#                          (< 6.8, e.g. <SETUP3_PREFILL_NODE>'s 5.15), UCX's
#                          rocm_ipc memory domain cannot register the KV cache
#                          of the SECOND concurrent multi-process GPU group:
#                            rocm_ipc_md.c  ERROR Failed to create ipc for 0x...
#                            ucp_mm.c       ERROR failed to register address ...
#                                           on md[6]=rocm_ipc: Address not valid
#                                           (md supports: rocm)
#                            nixl_agent.cpp registerMem: registration failed
#                          and the decode instance dies during KV-cache init.
#                          Note "md supports: rocm" — UCX *has* ROCm support and
#                          has correctly identified the buffer as device memory;
#                          what fails is HSA IPC handle creation, the same
#                          hipIpcGetMemHandle limitation that CONCURRENT_TP_
#                          WORKAROUND exists for. Same root cause, third caller.
#                          Excluding rocm_ipc leaves rocm_copy, which registers
#                          fine; the transfer then stages through pinned host
#                          memory under UCX's control rather than being a
#                          device-to-device IPC copy.
#                          NOT defaulted on: a host with kernel >= 6.8 should get
#                          the real GPU-IPC path, and silently disabling it there
#                          would be exactly the kind of invisible downgrade this
#                          script's other options exist to prevent.
#   HF_CACHE=<path>        (default: ~/.cache/huggingface)
#   ROLE=all|prefill|decode|proxy   which piece(s) to launch on this host
#                          (default: all — single-host behavior, unchanged from
#                          before this option existed)
#   PREFILL_HOST=<ip>      address the NixlConnector side channel and the proxy
#                          use to reach the prefill instance (default: 127.0.0.1
#                          — same box). Set to the prefill host's real IP for a
#                          3-node deploy. This value is ALSO exported into the
#                          container as VLLM_NIXL_SIDE_CHANNEL_HOST, which is
#                          what the side channel actually BINDS to.
#                          2026-08-17: that export is why cross-host works at
#                          all. vLLM's VLLM_NIXL_SIDE_CHANNEL_HOST defaults to
#                          "localhost" (vllm/envs.py), and setting only
#                          kv_connector_extra_config.hostname does NOT change
#                          the bind — the side channel came up on 127.0.0.1:5600
#                          and no remote decode could ever reach it. Verify with
#                          `ss -ltn | grep 5600`: it must show the routable IP,
#                          not 127.0.0.1.
#   DECODE_HOST=<ip>       same, for the decode instance (default: 127.0.0.1)
#   PREFILL_GPUS=<list>    comma-separated GPU indices (e.g. "0,1,2,3") to pass
#                          as HIP_VISIBLE_DEVICES to the prefill container.
#                          Empty/unset (default) = don't restrict, use whatever
#                          GPUs this host exposes. Only meaningful when prefill
#                          and decode share a host — leave unset in the 3-node
#                          case where each instance already has the whole host's
#                          GPUs to itself.
#   DECODE_GPUS=<list>     same, for the decode container.
#   PREFILL_TP=<n>         --tensor-parallel-size for the prefill instance
#                          (default: 1 — exactly the behaviour from before this
#                          option existed, when the flag was never passed at all).
#                          NOT derived from PREFILL_GPUS: setting HIP_VISIBLE_DEVICES
#                          only decides which GPUs the container can see, and vLLM
#                          at TP=1 then loads the whole model onto the first of
#                          them. That silent single-GPU load is the failure this
#                          option exists to fix, so sharding is opt-in and explicit
#                          rather than inferred from an unrelated variable.
#                          Must divide the number of GPUs the instance will see
#                          (PREFILL_GPUS if set, else this host's GPU count); the
#                          script refuses up front instead of letting vLLM OOM or
#                          thrash. Sizing: weights are sharded, so bf16 needs
#                          ~2 GB/param/TP per GPU — a 70B model is ~140 GB total,
#                          i.e. ~35 GB on each of 4 GPUs at TP=4.
#   DECODE_TP=<n>          same, for the decode instance (default: 1).
#   CONCURRENT_TP_WORKAROUND=1
#                          (default: 0 — off, so nothing changes for TP=1 users.)
#                          Set NCCL_P2P_DISABLE=1 and pass
#                          --disable-custom-all-reduce to BOTH instances.
#                          Needed because two concurrent vLLM instances with
#                          TP>1 cannot both start on this ROCm stack: whichever
#                          starts second dies during device init.
#
#                          ── Root cause (measured 2026-08-14, 8xMI300X/gfx942) ──
#                          BOTH disabled components independently call the same
#                          broken HIP primitive: hipIpcGetMemHandle, which
#                          returns hipErrorInvalidValue ('invalid argument') for
#                          the SECOND concurrent multi-process GPU group on this
#                          host. That single fact is why both flags are needed —
#                          they are not two unrelated bugs:
#                            * RCCL's P2P transport calls it from
#                              src/transport/p2p_tmp.cc:283, surfacing as
#                                NCCL WARN hipIpcGetMemHandle failed : invalid argument
#                                [FATAL ERROR]: HIP failure: 'invalid argument'
#                                RuntimeError: NCCL error: unhandled cuda error
#                              inside pynccl's ncclCommInitRank.
#                              NCCL_P2P_DISABLE=1 removes this call.
#                            * vLLM's CustomAllreduce calls it from
#                              custom_all_reduce.py:297 create_shared_buffer ->
#                              ops.allocate_shared_buffer_and_handle, surfacing as
#                                RuntimeError: CUDA error: invalid argument
#                                (hipErrorInvalidValue)
#                              --disable-custom-all-reduce removes this call.
#                          RCCL falls back to that legacy IPC path because this
#                          host's kernel is 5.15, so the two modern alternatives
#                          are both unavailable — RCCL logs
#                            cuMem support requires Linux kernel >= 6.8
#                            DMA_BUF_SUPPORT Failed: missing kernel symbols
#                          A kernel >= 6.8 (cuMem/VMM-based sharing) is therefore
#                          the actual fix; this flag is the workaround until then.
#
#                          ── Ruled out, with evidence (do not re-derive) ──
#                          The full 2x2 matrix was run at TP=4 x2 on this host:
#                            A  neither flag                        -> FAIL (RCCL)
#                            B  --disable-custom-all-reduce alone   -> FAIL (RCCL,
#                               signature IDENTICAL to A: P2P is still on, so
#                               RCCL still makes the failing call)
#                            C  NCCL_P2P_DISABLE=1 alone            -> FAIL
#                               (CustomAllreduce, as above)
#                            D  both                                -> PASS
#                          Also tested and rejected: NCCL_DMABUF_ENABLE=1 (fails
#                          identically to A — the kallsyms probe is not the
#                          blocker), and swapping in the cluster's alternate RCCL
#                          builds under /apps/shared (all but one link
#                          libamdhip64.so.6 against this image's ROCm 7.14
#                          libamdhip64.so.7; the one ABI-compatible build,
#                          rccl-rel-7.1 = RCCL 2.27.7, is OLDER than the image's
#                          own RCCL and fails even a SINGLE instance). Not a
#                          topology problem either: rocm-smi reports all 8 GPUs
#                          mutually XGMI-connected with 256 GB BARs.
#
#                          COST: TP collectives no longer use XGMI peer-to-peer
#                          and fall back to host-staged transfers, which lowers
#                          absolute throughput. Applied to both instances rather
#                          than only the second, so prefill and decode stay
#                          symmetric and the P/D delta is not confounded by two
#                          different collective paths. Any result produced with
#                          this set characterises a degraded-interconnect
#                          configuration and must say so.
#   READY_TIMEOUT=<sec>    how long to wait for each locally-launched instance to
#                          answer /health (default: 240 — the 48x5s loop this
#                          replaced, so unchanged for existing callers). Weight
#                          loading dominates startup and scales with model size:
#                          TinyLlama is ready in seconds, but a 72B reading
#                          ~145 GB of shards off disk into 4 GPUs needs far more.
#                          Raising this is always safe — the loop exits as soon
#                          as the endpoint answers, so a large value costs
#                          nothing when startup is fast.
#   DEPLOY_RECORD=<0|1>    write the deployment record that lets a benchmark's
#                          provenance stamp report the SERVER configuration
#                          (default: 1). See "Deployment record" below and
#                          ../lib/deployment.sh. Set 0 only if you have a reason
#                          to leave a benchmark unable to attest what it
#                          measured — a run against an unrecorded deployment is
#                          stamped "SERVER CONFIG: NOT RECORDED".
#
# ── Deployment record ─────────────────────────────────────────────────────────
# On success this script writes its FULLY-RESOLVED configuration — every value
# above after defaults are applied, not the raw environment — to
# /run/kv-cache-bench/deployment-<port>.env (falling back to $XDG_RUNTIME_DIR
# then /tmp; see ../lib/deployment.sh). bench/lib/{preflight,provenance}.sh read
# it, so a serving result's `.provenance.txt` sidecar shows the server config
# beside the client config and the preflight gate can refuse a VALIDATED claim
# over a degraded deployment.
#
# This replaces the hand-written DEPLOYMENT.md that used to sit next to a result
# (see results/setup3-prefill-node/2026-08-14-llama-benchy/): that run was
# stamped VALIDATED while both instances ran with CONCURRENT_TP_WORKAROUND=1,
# and nothing automatic revealed it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

MODEL=${MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}
VLLM_IMAGE=${VLLM_IMAGE:-vllm-nixl:rocm}
GPU_MEM_UTIL=${GPU_MEM_UTIL:-0.40}
PREFILL_PORT=${PREFILL_PORT:-8100}
DECODE_PORT=${DECODE_PORT:-8000}
PROXY_PORT=${PROXY_PORT:-9000}
NIXL_BACKEND=${NIXL_BACKEND:-UCX}
KV_BUFFER_DEVICE=${KV_BUFFER_DEVICE:-cpu}
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
ROLE=${ROLE:-all}
PREFILL_HOST=${PREFILL_HOST:-127.0.0.1}
DECODE_HOST=${DECODE_HOST:-127.0.0.1}
PREFILL_GPUS=${PREFILL_GPUS:-}
DECODE_GPUS=${DECODE_GPUS:-}
PREFILL_TP=${PREFILL_TP:-1}
DECODE_TP=${DECODE_TP:-1}
DTYPE=${DTYPE:-float16}
READY_TIMEOUT=${READY_TIMEOUT:-240}
CONCURRENT_TP_WORKAROUND=${CONCURRENT_TP_WORKAROUND:-0}
DEPLOY_RECORD=${DEPLOY_RECORD:-1}
TOOL_CALL_PARSER=${TOOL_CALL_PARSER:-hermes}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-}
HF_OVERRIDES=${HF_OVERRIDES:-}

# Extra flags/env implied by CONCURRENT_TP_WORKAROUND (empty when off, so the
# launch lines below are byte-identical to before for existing callers).
#
# Both entries are load-bearing and neither is redundant: each removes one of
# the two independent callers of hipIpcGetMemHandle (RCCL's P2P transport and
# vLLM's CustomAllreduce respectively), and that call is what fails for the
# second concurrent instance. Dropping either one puts its caller back and the
# second instance dies again — measured, see the header's matrix. Do not "tidy"
# this down to one flag without re-running that matrix.
TP_WORKAROUND_ARGS=()
TP_WORKAROUND_ENV=()
if [ "${CONCURRENT_TP_WORKAROUND}" = "1" ]; then
    TP_WORKAROUND_ARGS=(--disable-custom-all-reduce)
    TP_WORKAROUND_ENV=(-e NCCL_P2P_DISABLE=1)
fi

# UCX_TLS is forwarded only when the caller set it, so an unset UCX_TLS means
# "UCX decides", byte-identical to this script's behaviour before the option
# existed — rather than this script quietly imposing a transport list.
UCX_TLS_ENV=()
if [ -n "${UCX_TLS:-}" ]; then
    UCX_TLS_ENV=(-e "UCX_TLS=${UCX_TLS}")
fi

DO_PREFILL=0; DO_DECODE=0; DO_PROXY=0
case "${ROLE}" in
    all)     DO_PREFILL=1; DO_DECODE=1; DO_PROXY=1 ;;
    prefill) DO_PREFILL=1 ;;
    decode)  DO_DECODE=1 ;;
    proxy)   DO_PROXY=1 ;;
    *) echo "ERR: ROLE must be all|prefill|decode|proxy (got '${ROLE}')"; exit 1 ;;
esac

# ── Tensor-parallel sizing ────────────────────────────────────────────────────
# vLLM at TP=N uses the first N GPUs it can see. HIP_VISIBLE_DEVICES controls
# *which* GPUs are visible but not *how many are used*, so a mismatch between
# the two is silent: a 4-GPU list at TP=1 loads the entire model onto one GPU
# and OOMs (or thrashes) on anything large. These checks make the mismatch loud.

# _gpu_count_from_list <csv> — entries in a HIP_VISIBLE_DEVICES-style list
_gpu_count_from_list() {
    [ -z "${1}" ] && { echo 0; return 0; }
    echo "${1}" | tr ',' '\n' | grep -c '[^[:space:]]' || true
}

# _host_gpu_count — GPUs this host exposes, or 0 when it can't be determined
# (a proxy-only host, or a container without the tooling — never fatal).
_host_gpu_count() {
    local n=0
    if command -v rocm-smi >/dev/null 2>&1; then
        n=$(rocm-smi --showid 2>/dev/null | grep -c '^GPU\[' || true)
    fi
    if [ "${n:-0}" -eq 0 ]; then
        n=$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | wc -l || true)
    fi
    echo "${n:-0}"
}

# _validate_tp <ROLE> <tp> <gpu-list> — refuse an impossible TP/GPU combination
_validate_tp() {
    local role=$1 tp=$2 list=$3 visible source
    case "${tp}" in
        ''|*[!0-9]*) echo "ERR: ${role}_TP='${tp}' is not a positive integer"; exit 1 ;;
    esac
    [ "${tp}" -ge 1 ] || { echo "ERR: ${role}_TP=${tp} must be >= 1"; exit 1; }

    if [ -n "${list}" ]; then
        visible=$(_gpu_count_from_list "${list}")
        source="${role}_GPUS='${list}'"
    else
        visible=$(_host_gpu_count)
        source="this host's GPU count (${role}_GPUS unset, so all GPUs are visible)"
    fi

    if [ "${visible}" -eq 0 ]; then
        echo "WARN: could not determine how many GPUs the ${role} instance will see;"
        echo "      ${role}_TP=${tp} passed through unvalidated."
        return 0
    fi
    if [ "${tp}" -gt "${visible}" ]; then
        echo "ERR: ${role}_TP=${tp} exceeds the ${visible} GPU(s) that instance will see"
        echo "     (${source})."
        echo "     vLLM cannot shard across GPUs it has not been given. Either lower"
        echo "     ${role}_TP to ${visible} or widen ${role}_GPUS."
        exit 1
    fi
    if [ $((visible % tp)) -ne 0 ]; then
        echo "ERR: ${role}_TP=${tp} does not divide the ${visible} visible GPU(s)"
        echo "     (${source}). Attention heads and KV blocks are split evenly across"
        echo "     the TP group, so the counts must line up."
        exit 1
    fi
    if [ "${tp}" -lt "${visible}" ]; then
        echo "WARN: ${role}_TP=${tp} but ${visible} GPU(s) are visible (${source}) —"
        echo "      vLLM will use only the first ${tp} and leave $((visible - tp)) idle."
        echo "      Set ${role}_TP=${visible} to use them all."
    fi
}

# ── Preflight checks ──────────────────────────────────────────────────────────
if [ "${DO_PREFILL}" = "1" ] || [ "${DO_DECODE}" = "1" ]; then
    [ -e /dev/kfd ] || { echo "ERR: /dev/kfd absent — run: modprobe amdgpu"; exit 1; }
    [ "${DO_PREFILL}" = "1" ] && _validate_tp PREFILL "${PREFILL_TP}" "${PREFILL_GPUS}"
    [ "${DO_DECODE}" = "1" ]  && _validate_tp DECODE  "${DECODE_TP}"  "${DECODE_GPUS}"
    docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1 || {
        echo "ERR: ${VLLM_IMAGE} not found — run ../../stack/tracks/nixl/vllm/06-build-vllm.sh first"; exit 1; }
    docker volume inspect nixl-libs >/dev/null 2>&1 || {
        echo "ERR: nixl-libs volume missing — run ../../stack/tracks/nixl/vllm/06-build-vllm.sh first"; exit 1; }

    case "${KV_BUFFER_DEVICE}" in
        cpu|cuda) ;;
        *) echo "ERR: KV_BUFFER_DEVICE must be cpu or cuda (got '${KV_BUFFER_DEVICE}')"; exit 1 ;;
    esac

    # A VRAM-resident KV buffer is only meaningful if the UCX in the volume can
    # register VRAM. Checking here costs one short container start; NOT checking
    # costs a 72B model load followed by a handoff-time failure whose message
    # ("VRAM memory is detected as host by UCX") appears only in the prefill
    # instance's log, long after the deploy reported success.
    if [ "${KV_BUFFER_DEVICE}" = "cuda" ]; then
        echo "=== Checking the nixl-libs UCX can register GPU memory ==="
        docker run --rm \
            -v nixl-libs:/usr/local/nixl:ro \
            -e LD_LIBRARY_PATH=/usr/local/nixl/lib/x86_64-linux-gnu:/usr/local/nixl/system-libs \
            "${VLLM_IMAGE}" bash -lc '
                [ -x /usr/local/nixl/bin/ucx_info ] || exit 90
                /usr/local/nixl/bin/ucx_info -b | grep -q -- "--with-rocm=" || exit 91
                ls /usr/local/nixl/lib/x86_64-linux-gnu/ucx/libuct_rocm.so >/dev/null 2>&1 || exit 92
            ' || {
            rc=$?
            echo "ERR: KV_BUFFER_DEVICE=cuda but the nixl-libs volume cannot support it (rc=${rc})."
            case ${rc} in
              90) echo "     /usr/local/nixl/bin/ucx_info absent — the volume predates the UCX" ;;
              91) echo "     the volume's UCX was built --without-rocm" ;;
              92) echo "     libuct_rocm.so is not in the volume's ucx module dir" ;;
            esac
            echo "     shipping change. Rebuild the stack:"
            echo "       bash stack/tracks/nixl/core/01-build-base.sh"
            echo "       bash stack/tracks/nixl/core/02-compile-bench.sh"
            echo "       bash stack/tracks/nixl/core/rocm-plugin/build.sh"
            echo "       bash stack/tracks/nixl/vllm/06-build-vllm.sh"
            echo "     Or deploy with KV_BUFFER_DEVICE=cpu (KV staged through host DRAM)."
            exit 1; }
        echo "OK: volume UCX has ROCm support"
    fi
fi
if [ "${DO_PROXY}" = "1" ]; then
    [ -f "${SCRIPT_DIR}/disagg_proxy_demo.py" ] || {
        echo "ERR: ${SCRIPT_DIR}/disagg_proxy_demo.py missing (vendored from vllm-project/vllm)"; exit 1; }
fi

echo "deploy-pd-disaggregated: vLLM XpYd (1 prefill, 1 decode) + NixlConnector"
echo "  role     : ${ROLE}"
echo "  model    : ${MODEL}"
echo "  prefill  : ${PREFILL_HOST}:${PREFILL_PORT} (producer)${PREFILL_GPUS:+, GPUs ${PREFILL_GPUS}}, TP=${PREFILL_TP}"
echo "  decode   : ${DECODE_HOST}:${DECODE_PORT} (consumer)${DECODE_GPUS:+, GPUs ${DECODE_GPUS}}, TP=${DECODE_TP}"
echo "  proxy    : port ${PROXY_PORT} (client-facing)"
echo "  dtype    : ${DTYPE} | gpu-mem-util: ${GPU_MEM_UTIL}"
echo "  kv buffer: ${KV_BUFFER_DEVICE}$([ "${KV_BUFFER_DEVICE}" = "cpu" ] && echo "  (KV staged through host DRAM — set KV_BUFFER_DEVICE=cuda for VRAM-resident KV)")"
if [ "${CONCURRENT_TP_WORKAROUND}" = "1" ]; then
    echo "  NOTE     : CONCURRENT_TP_WORKAROUND=1 — NCCL_P2P_DISABLE=1 +"
    echo "             --disable-custom-all-reduce on both instances. TP"
    echo "             collectives bypass XGMI P2P, so absolute throughput is"
    echo "             lower than this hardware can reach. Say so in any result."
fi
echo ""

[ "${DO_PREFILL}" = "1" ] && docker rm -f vllm-pd-prefill 2>/dev/null || true
[ "${DO_DECODE}" = "1" ] && docker rm -f vllm-pd-decode 2>/dev/null || true
[ "${DO_PROXY}" = "1" ] && docker rm -f pd-proxy 2>/dev/null || true

# No --group-add render — the 24.04 vllm-nixl:rocm image has no "render" group
# at all (only "video"); container runs as root so device access isn't gated
# by group membership anyway (see ../../stack/tracks/nixl/vllm/08-deploy-qwen-nixl.sh's comment).
GPU_FLAGS=(--device /dev/kfd --device /dev/dri
           --group-add video
           --network host --ipc=host
           --security-opt seccomp=unconfined)
NIXL_FLAGS=(-v nixl-libs:/usr/local/nixl:ro)
HF_FLAGS=(-v "${HF_CACHE}":/root/.cache/huggingface
          -e VLLM_ROCM_USE_AITER=0
          -e LD_LIBRARY_PATH=/usr/local/nixl/lib/x86_64-linux-gnu:/usr/local/nixl/system-libs)

# kv_buffer_device is KV_BUFFER_DEVICE (see header). It is no longer pinned to
# "cpu" by the UCX build's inability to register VRAM.
KV_CFG_PRODUCER="{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_producer\",\"kv_buffer_device\":\"${KV_BUFFER_DEVICE}\",\"kv_connector_extra_config\":{\"hostname\":\"${PREFILL_HOST}\",\"port\":14579}}"
KV_CFG_CONSUMER="{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_consumer\",\"kv_buffer_device\":\"${KV_BUFFER_DEVICE}\",\"kv_connector_extra_config\":{\"hostname\":\"${PREFILL_HOST}\",\"port\":14579}}"

# The vLLM argv is built once into an array rather than written inline in the
# `docker run` lines, so the deployment record can report EXACTLY what ran
# instead of a reconstruction that can drift from it. Same words, same order.
TOOL_CALL_ARGS=()
if [ -n "${TOOL_CALL_PARSER}" ]; then
    TOOL_CALL_ARGS=(--enable-auto-tool-choice --tool-call-parser "${TOOL_CALL_PARSER}")
fi
CONTEXT_ARGS=()
[ -n "${MAX_MODEL_LEN}" ] && CONTEXT_ARGS+=(--max-model-len "${MAX_MODEL_LEN}")
[ -n "${HF_OVERRIDES}" ] && CONTEXT_ARGS+=(--hf-overrides "${HF_OVERRIDES}")

PREFILL_VLLM_ARGS=(--model "${MODEL}" --port "${PREFILL_PORT}"
                   --gpu-memory-utilization "${GPU_MEM_UTIL}"
                   --tensor-parallel-size "${PREFILL_TP}"
                   --enforce-eager --dtype "${DTYPE}"
                   "${TP_WORKAROUND_ARGS[@]+"${TP_WORKAROUND_ARGS[@]}"}"
                   "${TOOL_CALL_ARGS[@]+"${TOOL_CALL_ARGS[@]}"}"
                   "${CONTEXT_ARGS[@]+"${CONTEXT_ARGS[@]}"}"
                   --kv-transfer-config "${KV_CFG_PRODUCER}")
DECODE_VLLM_ARGS=(--model "${MODEL}" --port "${DECODE_PORT}"
                  --gpu-memory-utilization "${GPU_MEM_UTIL}"
                  --tensor-parallel-size "${DECODE_TP}"
                  --enforce-eager --dtype "${DTYPE}"
                  "${TP_WORKAROUND_ARGS[@]+"${TP_WORKAROUND_ARGS[@]}"}"
                  "${TOOL_CALL_ARGS[@]+"${TOOL_CALL_ARGS[@]}"}"
                  "${CONTEXT_ARGS[@]+"${CONTEXT_ARGS[@]}"}"
                  --kv-transfer-config "${KV_CFG_CONSUMER}")

if [ "${DO_PREFILL}" = "1" ]; then
    echo "=== Step 1: prefill instance (producer) ==="
    PREFILL_GPU_FLAGS=("${GPU_FLAGS[@]}")
    [ -n "${PREFILL_GPUS}" ] && PREFILL_GPU_FLAGS+=(-e "HIP_VISIBLE_DEVICES=${PREFILL_GPUS}")
    docker run -d --name vllm-pd-prefill \
        "${PREFILL_GPU_FLAGS[@]}" "${NIXL_FLAGS[@]}" "${HF_FLAGS[@]}" \
        "${TP_WORKAROUND_ENV[@]+"${TP_WORKAROUND_ENV[@]}"}" \
        "${UCX_TLS_ENV[@]+"${UCX_TLS_ENV[@]}"}" \
        -e NIXL_BACKEND="${NIXL_BACKEND}" \
        -e VLLM_NIXL_SIDE_CHANNEL_PORT=5600 \
        -e VLLM_NIXL_SIDE_CHANNEL_HOST="${PREFILL_HOST}" \
        "${VLLM_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server "${PREFILL_VLLM_ARGS[@]}"
fi

if [ "${DO_DECODE}" = "1" ]; then
    echo ""
    echo "=== Step 2: decode instance (consumer) ==="
    DECODE_GPU_FLAGS=("${GPU_FLAGS[@]}")
    [ -n "${DECODE_GPUS}" ] && DECODE_GPU_FLAGS+=(-e "HIP_VISIBLE_DEVICES=${DECODE_GPUS}")
    docker run -d --name vllm-pd-decode \
        "${DECODE_GPU_FLAGS[@]}" "${NIXL_FLAGS[@]}" "${HF_FLAGS[@]}" \
        "${TP_WORKAROUND_ENV[@]+"${TP_WORKAROUND_ENV[@]}"}" \
        "${UCX_TLS_ENV[@]+"${UCX_TLS_ENV[@]}"}" \
        -e NIXL_BACKEND="${NIXL_BACKEND}" \
        -e VLLM_NIXL_SIDE_CHANNEL_PORT=5601 \
        -e VLLM_NIXL_SIDE_CHANNEL_HOST="${DECODE_HOST}" \
        "${VLLM_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server "${DECODE_VLLM_ARGS[@]}"
fi

if [ "${DO_PREFILL}" = "1" ] || [ "${DO_DECODE}" = "1" ]; then
    echo ""
    echo "=== Step 3: waiting for locally-launched instance(s) ==="
    LOCAL_PORTS=()
    [ "${DO_PREFILL}" = "1" ] && LOCAL_PORTS+=("${PREFILL_PORT}")
    [ "${DO_DECODE}" = "1" ] && LOCAL_PORTS+=("${DECODE_PORT}")
    READY_ATTEMPTS=$(( READY_TIMEOUT / 5 ))
    [ "${READY_ATTEMPTS}" -lt 1 ] && READY_ATTEMPTS=1
    echo "  (waiting up to ${READY_TIMEOUT}s per instance)"
    for port in "${LOCAL_PORTS[@]}"; do
        READY=0
        for i in $(seq 1 "${READY_ATTEMPTS}"); do
            if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
                echo "  port ${port}: READY after $((i*5))s"; READY=1; break
            fi
            sleep 5
        done
        [ "${READY}" = "1" ] || {
            echo "ERR: port ${port} failed to come up within ${READY_TIMEOUT}s"
            [ "${DO_PREFILL}" = "1" ] && docker logs vllm-pd-prefill 2>&1 | tail -20
            [ "${DO_DECODE}" = "1" ] && docker logs vllm-pd-decode 2>&1 | tail -20
            exit 1
        }
    done

    # Same false-positive trap as this session's 11-deploy-qwen-nixl-xnvme.sh incident: a
    # health check can pass against a DIFFERENT already-running server bound to the same
    # port. Confirm the container(s) are genuinely Up, not exited, before trusting the above.
    LOCAL_NAMES=()
    [ "${DO_PREFILL}" = "1" ] && LOCAL_NAMES+=("vllm-pd-prefill")
    [ "${DO_DECODE}" = "1" ] && LOCAL_NAMES+=("vllm-pd-decode")
    for name in "${LOCAL_NAMES[@]}"; do
        docker ps --filter "name=^${name}$" --filter status=running --format '{{.Names}}' \
            | grep -qx "${name}" || {
            echo "ERR: ${name} is not actually running (health check may have hit a stale"
            echo "     process already bound to that port — GPU memory conflict is the"
            echo "     usual cause; check docker logs ${name})"
            docker ps -a --filter "name=${name}"
            exit 1
        }
    done
fi

if [ "${DO_PROXY}" = "1" ]; then
    echo ""
    echo "=== Step 4: starting proxy (client-facing single endpoint) ==="
    echo "  vendored from vllm-project/vllm: examples/disaggregated/disaggregated_serving/disagg_proxy_demo.py"
    docker run -d --name pd-proxy \
        --network host \
        -v "${SCRIPT_DIR}/disagg_proxy_demo.py":/disagg_proxy_demo.py:ro \
        "${VLLM_IMAGE}" \
        python3 /disagg_proxy_demo.py \
            --model "${MODEL}" \
            --prefill "${PREFILL_HOST}:${PREFILL_PORT}" \
            --decode "${DECODE_HOST}:${DECODE_PORT}" \
            --port "${PROXY_PORT}"

    PROXY_READY=0
    for i in $(seq 1 24); do
        if curl -sf "http://127.0.0.1:${PROXY_PORT}/status" >/dev/null 2>&1; then
            echo "  proxy READY after $((i*5))s"; PROXY_READY=1; break
        fi
        sleep 5
    done
    [ "${PROXY_READY}" = "1" ] || {
        echo "ERR: proxy /status never responded"; docker logs pd-proxy 2>&1 | tail -30; exit 1; }

    echo ""
    echo "=== Step 5: smoke test (through the proxy) ==="
    RESP=$(curl -sf "http://127.0.0.1:${PROXY_PORT}/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${MODEL}\",
             \"prompt\":\"The benefit of prefill/decode disaggregation is\",
             \"max_tokens\":60,\"temperature\":0}")
    echo "${RESP}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['text'])" \
        2>/dev/null || echo "${RESP}"
fi

# ── Deployment record ─────────────────────────────────────────────────────────
# Written last, once every locally-launched piece is confirmed up, so a record
# only ever describes a deployment that actually came alive. Non-fatal by
# design: a deploy that cannot write its record is still a working deploy — the
# consequence is that a benchmark against it is stamped "SERVER CONFIG: NOT
# RECORDED", which is the honest outcome, not a silent one.
if [ "${DEPLOY_RECORD}" = "1" ] && [ -f "${REPO_ROOT}/bench/lib/deployment.sh" ]; then
    # shellcheck source=../lib/deployment.sh
    source "${REPO_ROOT}/bench/lib/deployment.sh"

    # Ports this deployment answers on, MOST CLIENT-FACING FIRST: a benchmark
    # pointed at any of them finds the same record.
    REC_PORTS=""
    [ "${DO_PROXY}"   = "1" ] && REC_PORTS="${REC_PORTS}${REC_PORTS:+ }${PROXY_PORT}"
    [ "${DO_PREFILL}" = "1" ] && REC_PORTS="${REC_PORTS}${REC_PORTS:+ }${PREFILL_PORT}"
    [ "${DO_DECODE}"  = "1" ] && REC_PORTS="${REC_PORTS}${REC_PORTS:+ }${DECODE_PORT}"

    REC_CONTAINERS=""
    [ "${DO_PREFILL}" = "1" ] && REC_CONTAINERS="${REC_CONTAINERS}${REC_CONTAINERS:+ }vllm-pd-prefill"
    [ "${DO_DECODE}"  = "1" ] && REC_CONTAINERS="${REC_CONTAINERS}${REC_CONTAINERS:+ }vllm-pd-decode"
    [ "${DO_PROXY}"   = "1" ] && REC_CONTAINERS="${REC_CONTAINERS}${REC_CONTAINERS:+ }pd-proxy"

    # Anything that makes the numbers unrepresentative of the hardware names
    # itself here. The preflight gate reads this key generically, so a future
    # degrading option becomes visible to the gate by adding a word to this
    # list — no new gate check needed.
    #
    # Only claimed when this host actually launched a vLLM instance: the
    # workaround degrades TP collectives, and a proxy-only host has none. On a
    # proxy-only host CONCURRENT_TP_WORKAROUND says nothing about the remote
    # instances, so asserting it here would be a false positive that refuses a
    # perfectly good run.
    REC_DEGRADED=""
    if [ "${CONCURRENT_TP_WORKAROUND}" = "1" ] \
       && { [ "${DO_PREFILL}" = "1" ] || [ "${DO_DECODE}" = "1" ]; }; then
        REC_DEGRADED="nccl-p2p-disabled,custom-all-reduce-disabled"
    fi

    REC_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "${VLLM_IMAGE}" 2>/dev/null || echo unknown)

    # Only record what THIS host actually launched. In a 3-node deploy each host
    # runs this script with its own ROLE, so a proxy-only host has no idea what
    # TP or GPU set the remote prefill/decode instances were given — recording
    # this script's defaults for them would be a confidently wrong record, the
    # exact failure the whole mechanism exists to prevent.
    REC_ARGS=("stack=pd-disaggregated"
              "kv_connector=NixlConnector"
              "kv_buffer_device=${KV_BUFFER_DEVICE}"
              "nixl_backend=${NIXL_BACKEND}"
              "ucx_tls=${UCX_TLS:-(UCX default)}"
              "role=${ROLE}"
              "roles_launched_here=$(
                  r=""
                  [ "${DO_PREFILL}" = "1" ] && r="${r}${r:+,}prefill"
                  [ "${DO_DECODE}"  = "1" ] && r="${r}${r:+,}decode"
                  [ "${DO_PROXY}"   = "1" ] && r="${r}${r:+,}proxy"
                  printf '%s' "${r}")"
              "model=${MODEL}"
              "image=${VLLM_IMAGE}"
              "image_id=${REC_IMAGE_ID}"
              "prefill_endpoint=${PREFILL_HOST}:${PREFILL_PORT}"
              "decode_endpoint=${DECODE_HOST}:${DECODE_PORT}"
              "proxy_port=${PROXY_PORT}"
              "hf_cache=${HF_CACHE}"
              "ready_timeout=${READY_TIMEOUT}")

    if [ "${DO_PREFILL}" = "1" ] || [ "${DO_DECODE}" = "1" ]; then
        # dtype / gpu-mem-util / the RCCL workaround apply to whichever vLLM
        # instances this host launched, so they are only meaningful here.
        REC_ARGS+=("dtype=${DTYPE}"
                   "gpu_mem_util=${GPU_MEM_UTIL}"
                   "enforce_eager=1"
                   "concurrent_tp_workaround=${CONCURRENT_TP_WORKAROUND}"
                   "nccl_p2p_disable=$([ "${CONCURRENT_TP_WORKAROUND}" = "1" ] && echo 1 || echo 0)"
                   "disable_custom_all_reduce=$([ "${CONCURRENT_TP_WORKAROUND}" = "1" ] && echo 1 || echo 0)")
    fi
    if [ "${DO_PREFILL}" = "1" ]; then
        REC_ARGS+=("prefill_tp=${PREFILL_TP}"
                   "prefill_gpus=${PREFILL_GPUS:-(all GPUs visible to this host)}"
                   "kv_role_prefill=kv_producer"
                   "vllm_argv_prefill=python3 -m vllm.entrypoints.openai.api_server ${PREFILL_VLLM_ARGS[*]}")
    else
        REC_ARGS+=("prefill_tp=(not launched by this host)"
                   "prefill_gpus=(not launched by this host)")
    fi
    if [ "${DO_DECODE}" = "1" ]; then
        REC_ARGS+=("decode_tp=${DECODE_TP}"
                   "decode_gpus=${DECODE_GPUS:-(all GPUs visible to this host)}"
                   "kv_role_decode=kv_consumer"
                   "vllm_argv_decode=python3 -m vllm.entrypoints.openai.api_server ${DECODE_VLLM_ARGS[*]}")
    else
        REC_ARGS+=("decode_tp=(not launched by this host)"
                   "decode_gpus=(not launched by this host)")
    fi
    if [ "${ROLE}" != "all" ]; then
        REC_ARGS+=("note=multi-host deploy (ROLE=${ROLE}); values for roles launched on OTHER hosts are not knowable from here and are marked as such. KNOWN LIMITATION: the record is host-local, so a degraded setting on a remote prefill/decode instance is NOT reflected in this record or in the gate's verdict.")
    fi

    if [ -n "${REC_PORTS}" ]; then
        echo ""
        echo "=== Recording deployment configuration ==="
        DEPLOY_RECORD_SCRIPT="${BASH_SOURCE[0]}" \
        DEPLOY_RECORD_CONTAINERS="${REC_CONTAINERS}" \
        DEPLOY_RECORD_DEGRADED="${REC_DEGRADED}" \
        deployment_record_write "${REC_PORTS}" "${REC_ARGS[@]}" \
            || echo "  (continuing — the deployment is up; only its record is missing)"
    fi
fi

echo ""
echo "=== Deployed (role: ${ROLE}) ==="
[ "${DO_PREFILL}" = "1" ] && echo "  prefill (producer)   : vllm-pd-prefill  http://127.0.0.1:${PREFILL_PORT}"
[ "${DO_DECODE}" = "1" ]  && echo "  decode  (consumer)   : vllm-pd-decode   http://127.0.0.1:${DECODE_PORT}"
if [ "${DO_PROXY}" = "1" ]; then
    echo "  proxy (client-facing): pd-proxy         http://$(hostname -I | awk '{print $1}'):${PROXY_PORT}/v1"
    echo "  stack: client -> disagg_proxy_demo.py -> {${PREFILL_HOST}:${PREFILL_PORT}, ${DECODE_HOST}:${DECODE_PORT}} -> NixlConnector (kv_producer/kv_consumer) -> UCX"
    echo ""
    echo "  curl http://127.0.0.1:${PROXY_PORT}/v1/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\":\"${MODEL}\",\"prompt\":\"Hello\",\"max_tokens\":50}'"
fi
