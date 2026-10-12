#!/usr/bin/env bash
# lib-verify.sh — per-step sanity checks for one role, run after each
# bring-up step so a broken precondition surfaces as ITSELF rather than as
# a failure three layers downstream.
#
# This complements scripts/verify/ (the cross-cutting rung ladder 10..60,
# which proves the DATA PATH between nodes). These check that THIS node is
# in a sane state to proceed to the next step. Different question, so a
# different file: rung 40 failing tells you disaggregation is broken; these
# tell you the daemon is a zombie, which is why.
#
# Every check here exists because its absence has cost this project real
# time. Each one names the trap it guards in a comment — do not drop a
# check without reading why it is there.
#
# Usage from a role wrapper:
#     ROLE=decode
#     source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib-verify.sh"
#     v_daemon
#
# All functions run ON THE NODE (host namespace) and reach into the
# container with docker exec where the state lives there — pidfiles and
# /var/log/kvstack are inside the container, /sys and nvme are not.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ROLE="${ROLE:?lib-verify: ROLE must be set to prefill|decode}"
case "${ROLE}" in
    prefill) _VPORT="${PREFILL_PORT:-8100}" ;;
    decode)  _VPORT="${DECODE_PORT:-8200}" ;;
    *) die "lib-verify: unknown ROLE '${ROLE}' (expected prefill|decode)" ;;
esac
_VCNAME="kvstack-${ROLE}"

# Run a command inside this role's container. Kept as one definition so a
# container-naming change lands in exactly one place.
_vc() { docker exec "${_VCNAME}" bash -lc "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# 01 — host: kernel, GPU driver, allocation, co-tenancy
# ─────────────────────────────────────────────────────────────────────────────
v_host() {
    step "[${ROLE}] 01 host — kernel, amdgpu, co-tenancy"

    log "kernel: $(uname -r)   uptime: $(uptime -p)"

    # amdgpu LOADED, not merely installed. A reboot can come up with the
    # module absent entirely (measured on smc2, 2026-10-12): rocm-smi then
    # reports one 'GPU' and every later step fails for unrelated-looking
    # reasons. lsmod is the only honest source — modinfo reads the FILE on
    # disk and happily prints a version for a module nobody loaded.
    check "amdgpu module is loaded" bash -c 'lsmod | awk "\$1==\"amdgpu\"{found=1} END{exit !found}"'

    local on_disk; on_disk="$(modinfo -F version amdgpu 2>/dev/null || true)"
    log "amdgpu on-disk version for $(uname -r): ${on_disk:-unknown}"
    if [ -r /sys/module/amdgpu/version ]; then
        log "amdgpu loaded version: $(cat /sys/module/amdgpu/version)"
    fi

    # Pin the driver version when the caller states one. smc2 fake-OOMs
    # above GPU_MEM_UTIL 0.45 on 6.18.4 and is fine on 6.16.13 (proven by
    # the role-swap 2x2, 2026-10-12), so the version is load-bearing, not
    # cosmetic. Export EXPECT_AMDGPU to enforce it.
    if [ -n "${EXPECT_AMDGPU:-}" ]; then
        check "amdgpu version is ${EXPECT_AMDGPU}" bash -c \
            "[ \"\$(modinfo -F version amdgpu 2>/dev/null)\" = \"${EXPECT_AMDGPU}\" ]"
    fi

    # All 8 devices should enumerate even though this project may only USE
    # two of them (docs/setups/setup-4.md §1.1). A short count means the
    # driver came up wrong, not that someone took our GPUs.
    local ngpu; ngpu="$(ls -d /sys/class/drm/card*/device/vendor 2>/dev/null | wc -l)"
    check "GPU devices enumerate (got ${ngpu}, expect >= 2)" bash -c "[ ${ngpu} -ge 2 ]"

    # Co-tenancy (AGENTS.md §1.1). Advisory, not fatal: a neighbour is
    # allowed to exist — we just must never conclude their resources are
    # ours. Print, do not judge.
    log "containers on this host:"
    docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | head -10 >&2 || true

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 02 — RDMA: device names, port state, firmware personality
# ─────────────────────────────────────────────────────────────────────────────
v_rdma() {
    step "[${ROLE}] 02 RDMA — device names, port state, firmware"

    # Re-derive names; never assume (AGENTS.md §4). A reboot once renamed
    # every device from ionic_N to roce_benicNp1 and silently broke a pin
    # that had been correct for weeks.
    local devs; devs="$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')"
    log "RDMA devices present: ${devs:-<none>}"
    check "at least one RDMA device exists" bash -c '[ -n "$(ls /sys/class/infiniband/ 2>/dev/null)" ]'

    # Every device this role's creds pin must actually exist under the name
    # the creds use. This is the check that catches the rename.
    local pinned; pinned="$(eval echo "\${${ROLE^^}_UCX_NET_DEVICES:-${UCX_NET_DEVICES:-}}")"
    if [ -n "${pinned}" ]; then
        local d
        for d in ${pinned//,/ }; do
            local base="${d%%:*}"
            check "pinned RDMA device '${base}' exists" test -d "/sys/class/infiniband/${base}"
        done
    else
        warn "no UCX_NET_DEVICES pinned for ${ROLE} — skipping name match"
    fi

    # ibverbs-utils is NOT in the rocm-aic image (measured 2026-10-09); it
    # gets installed into the container by hand and is LOST on every
    # container recreate. require_rdma_access() hard-depends on it, so vLLM
    # dies at preflight with "missing required command(s): ibv_devinfo".
    check "ibv_devinfo present in container" _vc 'command -v ibv_devinfo'
    check "ibv_devinfo enumerates >= 1 device" _vc \
        'test -n "$(ibv_devinfo -l 2>/dev/null | tail -n +2 | tr -d " \t")"'
    check_soft "at least one port reports PORT_ACTIVE" _vc \
        'ibv_devinfo 2>/dev/null | grep -q PORT_ACTIVE'

    # The firmware trap (AGENTS.md §5): a 'hydra' card cannot create a UD
    # queue pair, UCX fails to build a worker, and vLLM dies ~2 minutes
    # later as "Engine core initialization failed" naming neither the NIC
    # nor the firmware. eth_dbgtool's p4_program is the ONLY discriminator —
    # fw_ver, ethtool -i and devlink are identical on hydra and pulsar.
    if command -v eth_dbgtool >/dev/null 2>&1; then
        check_soft "AI NIC firmware personality is pulsar" bash -c \
            'eth_dbgtool --bdf "$(_rdma_card_bdf_for_ibdev ionic_0)" -V 2>/dev/null | grep -qi pulsar'
    else
        warn "eth_dbgtool not in PATH — cannot verify pulsar vs hydra personality"
    fi

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 03 — KV device: NVMe-oF connection and the right namespace
# ─────────────────────────────────────────────────────────────────────────────
v_kvdev() {
    step "[${ROLE}] 03 KV device — NVMe-oF connection and namespace"

    # A reboot drops the fabric connection and does NOT bring it back
    # (measured on smc2, 2026-10-12: nvme1 and /dev/ng1n1 both gone after
    # reboot while nvme0, the local boot drive, was fine). Without this
    # check the next thing you see is a daemon that starts and then fails
    # every store for reasons that look like the backend's fault.
    log "nvme controllers:"
    local c
    for c in /sys/class/nvme/nvme*; do
        [ -e "${c}/subsysnqn" ] || continue
        log "  $(basename "${c}"): state=$(cat "${c}/state" 2>/dev/null) nqn=$(cut -c1-50 < "${c}/subsysnqn")"
    done

    # More than the local boot drive must be present. After a reboot the
    # fabric controller is simply absent and only the Micron boot NVMe
    # remains (measured on smc2, 2026-10-12).
    local nctrl; nctrl="$(ls -d /sys/class/nvme/nvme* 2>/dev/null | wc -l)"
    check "more than one nvme controller present (got ${nctrl}, fabric one must be back)" \
        bash -c "[ ${nctrl} -ge 2 ]"

    # Two legitimate ways to identify the KV device, and this cluster uses
    # the first: creds pin XNVME_DEV explicitly, because the DSC presents
    # its OWN subsystem NQN (nqn.2019-08.com.pensando:...) rather than the
    # target's NVMF_SUBNQN (nqn.2024-01.io.nixl:kv0). resolve_xnvme_kv_dev
    # matches on NVMF_SUBNQN and therefore correctly finds nothing here —
    # treating that as a failure is a false alarm, which is why this branches.
    local kvdev="${XNVME_DEV:-}"
    if [ -n "${kvdev}" ]; then
        log "KV device from explicit XNVME_DEV pin: ${kvdev}"
        check "pinned KV device ${kvdev} exists" test -e "${kvdev}"
        check "pinned KV device is a character device" test -c "${kvdev}"
        # The invariant that actually matters, and the one that stops us
        # writing the boot drive: a real KV namespace has NO block device,
        # because the kernel cannot build one for a non-NVM command set.
        check "KV namespace has no block sibling (${kvdev/\/dev\/ng//dev/nvme} must not exist)" \
            bash -c "[ ! -e '${kvdev/\/dev\/ng//dev/nvme}' ]"
        check_soft "KV namespace reports csi 0x1" assert_kv_char_device "${kvdev}"
    elif kvdev="$(resolve_xnvme_kv_dev 2>/dev/null)"; then
        log "KV char device resolved by NQN: ${kvdev}"
        check "KV char device exists" test -e "${kvdev}"
        check_soft "KV namespace reports csi 0x1" assert_kv_char_device "${kvdev}"
    else
        err "KV device unresolvable: XNVME_DEV unset and no namespace matches NVMF_SUBNQN"
        _CHECKS_FAIL=$((_CHECKS_FAIL + 1)); _FAILED_NAMES+=("resolve KV device")
    fi

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 04 — container: exists, mounts the right tree, has what the image lacks
# ─────────────────────────────────────────────────────────────────────────────
v_container() {
    step "[${ROLE}] 04 container — state, mounts, shim"

    check "container ${_VCNAME} is running" bash -c \
        "docker ps --format '{{.Names}}' | grep -qx '${_VCNAME}'"

    # The repo is bind-mounted at the SAME path inside the container
    # (-v REPO_ROOT:REPO_ROOT, -w REPO_ROOT), so the in-container path and
    # the host path are the same string. After the 2026-10-09 consolidation
    # the single source of truth is /root/pmallapp/kv-stack; a container
    # still mounting /root/kv-cache is running deleted code.
    local wd; wd="$(docker inspect -f '{{.Config.WorkingDir}}' "${_VCNAME}" 2>/dev/null || true)"
    log "container workdir: ${wd}"
    check "workdir is not the retired /root/kv-cache" bash -c "[ \"${wd}\" != '/root/kv-cache' ]"
    check "no mount references the retired /root/kv-cache" bash -c \
        "[ \"\$(docker inspect '${_VCNAME}' 2>/dev/null | grep -c '/root/kv-cache')\" = '0' ]"

    # container.sh up does NOT run container.sh shim, but start-vllm.sh and
    # start-lmcache-daemon.sh both require it (AGENTS.md §6). It is a
    # mandatory, non-automatic prerequisite that the README does not list.
    check "shim present: ${STACK_ROOT:-/opt/kvstack}/etc/env.sh" _vc \
        "test -f ${STACK_ROOT:-/opt/kvstack}/etc/env.sh"
    check "shim present: ${STACK_ROOT:-/opt/kvstack}/venv/bin/python" _vc \
        "test -e ${STACK_ROOT:-/opt/kvstack}/venv/bin/python"

    # Lost on every container recreate — see v_rdma. Checked in both places
    # deliberately: here it is a container-state problem you can fix now,
    # there it is an RDMA precondition.
    check "ibverbs-utils installed in container" _vc 'command -v ibv_devinfo'

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 05 — LMCache MP daemon: alive, healthy, correct L2 adapter
# ─────────────────────────────────────────────────────────────────────────────
v_daemon() {
    step "[${ROLE}] 05 LMCache MP daemon — liveness and L2 adapter"

    # THE zombie trap (KNOWN-ISSUES.md item 20, AGENTS.md §3). Container PID 1 is
    # `sleep infinity` and never reaps, so a dead daemon lingers as a
    # defunct process; kill -0 SUCCEEDS against it and every "is it running"
    # test based on the pidfile returns true. start_bg then refuses to
    # restart it ("already running") and every later cold-read test is
    # silently invalid. Only the process STATE distinguishes them.
    local stat; stat="$(_vc 'ps -o stat= -p $(cat /run/kvstack/lmcache-mp-daemon.pid 2>/dev/null) 2>/dev/null' 2>/dev/null | tr -d ' ' || true)"
    log "daemon process state: ${stat:-<absent>}"
    check "daemon pidfile points at a live process" bash -c "[ -n '${stat}' ]"
    check "daemon is NOT a zombie (state '${stat:-?}' must not start with Z)" bash -c \
        "case '${stat}' in Z*) exit 1;; *) exit 0;; esac"

    local dstatus="http://127.0.0.1:${LMCACHE_MP_HTTP_PORT:-8080}/status"
    check "daemon HTTP frontend answers (${dstatus})" _vc "curl -sf -m 10 ${dstatus} -o /dev/null"

    # Scrape the port WE bound. On a shared host a co-tenant may own 8080,
    # in which case curling it anyway returns another stack's counters and
    # they look entirely plausible (BRINGUP §1 Conventions).
    # Write the JSON to a file and let python read it. Interpolating the
    # body into a -c string does not survive the quoting (the payload is
    # itself full of quotes) and produced a FALSE failure against a daemon
    # that was reporting is_healthy=true — measured 2026-10-12.
    local bodyf; bodyf="$(mktemp)"
    _vc "curl -s -m 10 ${dstatus}" > "${bodyf}" 2>/dev/null || true

    if [ -s "${bodyf}" ]; then
        python3 - "${bodyf}" <<'PY' >&2 2>/dev/null || true
import json,sys
d=json.load(open(sys.argv[1]))
print(f"       is_healthy: {d.get('is_healthy')}")
for a in d.get('storage_manager',{}).get('l2_adapters',[]):
    print(f"       l2 adapter: {a.get('type')}  backend: {a.get('backend')}  namespace: {a.get('namespace')}")
PY
        check "daemon reports is_healthy true" \
            python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('is_healthy') else 1)" "${bodyf}"
        # The namespace is a geometry fingerprint over model/TP/chunk/dtype.
        # BOTH nodes must derive the same value or every cross-node lookup
        # correctly misses. TP_SIZE is an input, so changing TP changes it.
        check "L2 adapter is backed by XNVME_KV" \
            python3 -c "import json,sys; a=json.load(open(sys.argv[1])).get('storage_manager',{}).get('l2_adapters',[]); sys.exit(0 if a and a[0].get('backend')=='XNVME_KV' else 1)" "${bodyf}"
        log "namespace must MATCH the other node — compare both before trusting a cross-node hit"
    else
        err "daemon /status returned nothing"
        _CHECKS_FAIL=$((_CHECKS_FAIL + 1)); _FAILED_NAMES+=("daemon /status body")
    fi
    rm -f "${bodyf}"

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 06 — vLLM: healthy, and running the geometry we think it is
# ─────────────────────────────────────────────────────────────────────────────
v_vllm() {
    step "[${ROLE}] 06 vLLM — liveness and geometry"

    local stat; stat="$(_vc "ps -o stat= -p \$(cat /run/kvstack/vllm-${ROLE}.pid 2>/dev/null) 2>/dev/null" 2>/dev/null | tr -d ' ' || true)"
    log "vllm-${ROLE} state: ${stat:-<absent>}"
    check "vllm-${ROLE} process is alive" bash -c "[ -n '${stat}' ]"
    check "vllm-${ROLE} is NOT a zombie" bash -c "case '${stat}' in Z*) exit 1;; *) exit 0;; esac"

    # /v1/models answering is NOT proof the engine works. When EngineCore
    # dies the API server keeps answering /v1/models for a while and then
    # shuts itself down; generation is what actually exercises the engine
    # (measured 2026-10-09). v_serving covers that.
    check "vLLM answers /v1/models on :${_VPORT}" bash -c \
        "curl -sf -m 10 http://127.0.0.1:${_VPORT}/v1/models -o /dev/null"

    # Geometry actually in effect, read off the running process rather than
    # the config we believe we passed.
    local cmd; cmd="$(_vc "tr '\\0' '\\n' < /proc/\$(cat /run/kvstack/vllm-${ROLE}.pid)/cmdline" 2>/dev/null || true)"
    local tp mu
    tp="$(printf '%s\n' "${cmd}" | grep -A1 -x -- '--tensor-parallel-size' | tail -1)"
    mu="$(printf '%s\n' "${cmd}" | grep -A1 -x -- '--gpu-memory-utilization' | tail -1)"
    log "running geometry: TP=${tp:-?}  GPU_MEM_UTIL=${mu:-?}  (configured TP_SIZE=${TP_SIZE:-?})"
    if [ -n "${tp}" ] && [ -n "${TP_SIZE:-}" ]; then
        check "running TP (${tp}) matches configured TP_SIZE (${TP_SIZE})" bash -c "[ '${tp}' = '${TP_SIZE}' ]"
    fi

    # TP=N must light up N GPUs. One busy GPU under TP=2 means the pin did
    # not take and half the model is somewhere you did not intend.
    local busy; busy="$(_vc 'rocm-smi --showmeminfo vram 2>/dev/null' 2>/dev/null |
        awk '/VRAM Total Used Memory/{gsub(/[^0-9]/,"",$NF); if ($NF/1073741824 > 5) n++} END{print n+0}')"
    log "GPUs holding >5 GiB: ${busy}"
    if [ -n "${tp}" ]; then
        check "GPUs in use (${busy}) matches TP (${tp})" bash -c "[ '${busy}' = '${tp}' ]"
    fi

    checks_summary
}

# ─────────────────────────────────────────────────────────────────────────────
# 07 — serving: a real completion, not just a liveness probe
# ─────────────────────────────────────────────────────────────────────────────
v_serving() {
    step "[${ROLE}] 07 serving — real generation"

    # The decode node also hosts the proxy. Check it before the engine so a
    # proxy fault is not misread as an engine fault.
    if [ "${ROLE}" = "decode" ]; then
        local pstat; pstat="$(_vc 'ps -o stat= -p $(cat /run/kvstack/disagg-proxy.pid 2>/dev/null) 2>/dev/null' 2>/dev/null | tr -d ' ' || true)"
        log "disagg-proxy state: ${pstat:-<absent>}"
        check "disagg-proxy is alive and not a zombie" bash -c \
            "[ -n '${pstat}' ] && case '${pstat}' in Z*) exit 1;; *) exit 0;; esac"
        check "proxy answers /v1/models on :${PROXY_PORT:-8000}" bash -c \
            "curl -sf -m 10 http://127.0.0.1:${PROXY_PORT:-8000}/v1/models -o /dev/null"
    fi

    # A correct completion proves the engine is alive. (It does NOT prove
    # disaggregation — HANDOFF §5: two separate defects in this project
    # produced perfect output while transferring zero KV. Use the rung
    # ladder in scripts/verify/ for that claim.)
    local target="http://127.0.0.1:${_VPORT}/v1"
    [ "${ROLE}" = "decode" ] && target="http://127.0.0.1:${PROXY_PORT:-8000}/v1"
    local body='{"model":"'"${MODEL_NAME:-Qwen/Qwen3-8B}"'","messages":[{"role":"user","content":"Reply with the single word OK."}],"max_tokens":8}'
    local code
    code="$(curl -s -m 120 -o /tmp/.kvverify-resp.json -w '%{http_code}' \
            -X POST "${target}/chat/completions" \
            -H 'Content-Type: application/json' -d "${body}" 2>/dev/null || echo 000)"
    log "chat/completions against ${target} -> HTTP ${code}"
    check "chat completion returns HTTP 200" bash -c "[ '${code}' = '200' ]"
    check "response carries non-empty generated content" bash -c \
        "python3 -c \"import json; d=json.load(open('/tmp/.kvverify-resp.json')); assert d['choices'][0]['message']['content'].strip()\""
    rm -f /tmp/.kvverify-resp.json

    checks_summary
}
