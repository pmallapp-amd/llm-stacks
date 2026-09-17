#!/usr/bin/env bash
# container.sh — run this repo's runtime scripts INSIDE the rocm-aic image.
#
# Node:          SMC1 (prefill) or SMC2 (decode).
# Prerequisites: the rocm-aic image present locally (docker images), the
#                repo deployed (scripts/common/deploy.sh), and the
#                /opt/kvstack shim in place (this script's `shim`
#                subcommand creates it).
# Next step:     container.sh exec <role> scripts/<role>/03-start-<role>.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# ─────────────────────────────────────────────────────────────────────────────
# docs/HANDOFF.md §10.1 records the mismatch this script closes: every
# runtime script in this repo (start-vllm.sh, start-lmcache-daemon.sh)
# sources ${STACK_ROOT}/etc/env.sh and executes ${VENV}/bin/python — the
# from-source layout that scripts/common/20-build-vllm-lmcache.sh would
# produce at /opt/kvstack. That build has never completed in this lab, and
# is deprioritized (TODO 6.2). What the lab actually has is the vendor's
# rocm-aic container image, which already ships the exact stack those
# scripts want: vllm 0.26.0+rocm, lmcache 0.5.3, and a NIXL whose plugin
# directory contains libplugin_XNVME_KV.so and libplugin_SPDK_NVMe_KV.so.
#
# Rather than fork every runtime script to be container-aware, this script
# makes the container satisfy the layout the scripts already expect:
#   - `shim` writes /opt/kvstack/etc/env.sh and a /opt/kvstack/venv/bin/
#     python symlink to the image's system interpreter, so ${VENV}/bin/python
#     and `source ${STACK_ROOT}/etc/env.sh` both resolve unmodified.
#   - `up` starts ONE long-lived container per role (`sleep infinity`), so
#     that processes the repo's start_bg helper backgrounds inside it — the
#     LMCache MP daemon, vLLM — outlive the command that launched them.
#     A `docker run --rm ... ./03-start-prefill.sh` would tear all of them
#     down the instant the start script returned, because start_bg
#     deliberately returns immediately.
#   - `exec` runs a repo-relative script inside that container.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE FLAGS THAT ARE NOT OPTIONAL — each was established by a failure
# ─────────────────────────────────────────────────────────────────────────────
#   --security-opt seccomp=unconfined
#       REQUIRED for KV_BACKEND=XNVME_KV. xNVMe reaches the KV namespace via
#       io_uring_cmd, and Docker's DEFAULT seccomp profile denies
#       io_uring_setup (syscall 425) with EPERM. Measured on this lab
#       2026-09-16: the syscall returns -1 EPERM under the default profile
#       while the host kernel (6.8.0-139) has kernel.io_uring_disabled=0.
#       Without this flag the plugin fails at xnvme_queue_init with the
#       misleading "FAILED: io_uring cmd, not supported by kernel!" — which
#       reads as a kernel/device limitation and is not one.
#   --device ${XNVME_DEV}
#       The DSC-presented NVMe KV char device (csi=0x1). Without it the
#       plugin falls back to its compiled-in /dev/ng0n1 default, which on
#       these nodes is the Micron BOOT DRIVE, not a KV namespace.
#   --device /dev/kfd --device /dev/dri, --group-add
#       ROCm. vLLM sees no GPU otherwise.
#   --ipc host / --shm-size
#       vLLM worker shared memory.
#   --network host
#       NixlConnector's UCX side channel and the LMCache MP daemon's ZMQ
#       channel are both addressed as loopback/host ports by
#       config/cluster.env (LMCACHE_MP_HOST=tcp://127.0.0.1 by design — see
#       that file's comment on raw pointers crossing the ZMQ boundary).
#
# usage:
#   container.sh shim                       # write the /opt/kvstack shim
#   container.sh up <prefill|decode>        # start the long-lived container
#   container.sh exec <role> <cmd...>       # run something inside it
#   container.sh logs <role> [-f]
#   container.sh down <role>
#   container.sh status <role>

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE="${KVSTACK_IMAGE:-rocm-aic:mp-pd-ionic2609}"
SHM_SIZE="${KVSTACK_SHM_SIZE:-64g}"
# Where the image keeps its NIXL plugins — the mount point for the rebuilt
# XNVME_KV plugin (see cmd_plugin_build). Matches the image's own
# NIXL_PLUGIN_DIR; kept separate from the shim's exported value so that
# changing one cannot silently desync the bind-mount target.
NIXL_PLUGIN_DIR_IN_IMAGE="${NIXL_PLUGIN_DIR_IN_IMAGE:-/opt/nixl/lib/x86_64-linux-gnu/plugins}"

_cname() { echo "kvstack-$1"; }

_role_dev() {
    # XNVME_DEV is resolved per-node; on both compute nodes in this lab the
    # DSC KV namespace is /dev/ng1n1 and ng0n1 is the Micron boot drive.
    echo "${XNVME_DEV:-/dev/ng1n1}"
}

cmd_shim() {
    step "Writing /opt/kvstack shim (container-path equivalent of 20-build-vllm-lmcache.sh)"
    mkdir -p "${STACK_ROOT}/venv/bin" "${STACK_ROOT}/etc"
    ln -sfn /usr/bin/python3 "${STACK_ROOT}/venv/bin/python"
    ln -sfn /usr/bin/python3 "${STACK_ROOT}/venv/bin/python3"
    cat > "${STACK_ROOT}/venv/bin/activate" <<'EOF'
# Container shim: the rocm-aic image already has vllm/lmcache/nixl on its
# SYSTEM interpreter, so there is no virtualenv to activate. This stays a
# no-op purely so ${STACK_ROOT}/etc/env.sh can `source` it unmodified.
export VIRTUAL_ENV=/opt/kvstack/venv
export PATH="/opt/kvstack/venv/bin:${PATH}"
EOF
    cat > "${STACK_ROOT}/etc/env.sh" <<'EOF'
# Generated by scripts/common/container.sh — do not hand-edit.
# Container-path equivalent of what 20-build-vllm-lmcache.sh emits.
source "/opt/kvstack/venv/bin/activate"

# The image sets this already; re-exported so the value is explicit and a
# script sourcing this file out of band still gets a correct one.
export NIXL_PLUGIN_DIR="${NIXL_PLUGIN_DIR:-/opt/nixl/lib/x86_64-linux-gnu/plugins}"

# See 20-build-vllm-lmcache.sh for the full rationale: expandable_segments
# breaks HIP IPC export of vLLM's KV tensors when NIXL hands out a raw
# device pointer for VRAM_SEG registration.
export PYTORCH_HIP_ALLOC_CONF="expandable_segments:False"

# NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE IS DELIBERATELY NOT EXPORTED HERE.
#
# It used to be, set to 1, on the reasoning that the DSC KV namespace reports
# value_max=4096 (smaller than the plugin's compiled-in 32768) and that
# "every store larger than the device ceiling fails". Removed 2026-09-16.
# Three separate reasons, any one of which is sufficient:
#
#   1. IT NEVER TOOK EFFECT. start-vllm.sh sources this file and THEN calls
#      lib.sh's setup_nixl_kv_env(), which `unset`s the variable outright
#      (lib.sh:613-621, HANDOFF §7 invariant 4). lib.sh always won. An
#      operator control that is silently annulled is worse than none.
#
#   2. ITS PREMISE IS FALSE ON THIS DEPLOYMENT. The MP daemon's nixl_store
#      unit is --l1-align-bytes (4096), so mem_split_n == 1 and every stored
#      object is 4096 B. Nothing has ever exceeded even the 4096 ceiling.
#      The completions_err counts that motivated this are the DSC stall
#      watchdog, not size rejections — they come in exact multiples of the
#      64-deep queue (measured: 704 err == 11 stalls x 64).
#
#   3. IT IS CALL-ORDER DEPENDENT AND SO CANNOT BE TRUSTED ANYWAY.
#      getParams() (xnvme_kv_plugin.cpp:52-58) reads discovered_max_value_size_,
#      which start_workers() only populates during create_backend(). A caller
#      doing get_plugin_params() BEFORE create_backend() — which
#      20-verify-nixl-plugin.sh does, :171 then :214 — still sees 32768 even
#      with the flag set. On-wire geometry must never depend on call order.
#
# The correct model: geometry comes from config (KV_MAX_VALUE_SIZE_EFFECTIVE),
# the device is a VALIDATOR, and a disagreement should be a startup failure.
# Aligning the plugin's compiled-in default to 4096 needs `plugin-build`.
EOF
    ok "wrote ${STACK_ROOT}/etc/env.sh and ${STACK_ROOT}/venv/bin/python"
}

# ─────────────────────────────────────────────────────────────────────────────
# vllm-patch — re-derive the nixl_utils.py override from the IMAGE's own copy.
#
# Upstream vLLM's vllm/distributed/nixl_utils.py hardcodes
#     package_name = "rixl" if current_platform.is_rocm() else "nixl"
# in TWO places. The rocm-aic images ship a ROCm-patched package named
# **nixl** and no **rixl** at all, so on ROCm that platform test rejects a
# perfectly working install: _load_nixl_attr() catches the ImportError,
# logs "NIXL is not available", sets NixlWrapper = None, and NixlConnector's
# base_worker.py then raises RuntimeError("NIXL is not available") — which
# is what kills EngineCore at startup, long after the log line scrolled by.
# This is the same fix as commit 723d440 ("drop the rixl requirement,
# resolve NIXL by what is installed"); its helper script was deleted in
# HANDOFF §17.1 alongside start-vllm-container.sh, so it is re-homed here.
#
# Derived from the image at run time rather than vendored as a static file,
# so that bumping KVSTACK_IMAGE cannot silently reinstate a stale copy of a
# module that upstream is still editing.
_PATCH_DIR() { echo "${STACK_ROOT}/vllm-patch"; }

cmd_vllm_patch() {
    local pdir; pdir="$(_PATCH_DIR)"
    mkdir -p "${pdir}"
    step "Deriving nixl_utils.py override from ${IMAGE}"

    # Located by FILESYSTEM lookup, deliberately not by importing vllm:
    # `import vllm` pulls in torch.cuda and dies with "No CUDA GPUs are
    # available" in a throwaway container that has no --device flags, which
    # would make this step require a GPU it has no other reason to need.
    local target
    target="$(docker run --rm --entrypoint find "${IMAGE}" \
        / -path '*/vllm/distributed/nixl_utils.py' -print -quit 2>/dev/null | tr -d '\r')"
    [ -n "${target}" ] || die "could not locate vllm/distributed/nixl_utils.py" \
        " inside ${IMAGE} — the module may have been renamed or moved" \
        " upstream; re-read it and update this function rather than" \
        " shipping an unpatched override."
    info "image module path: ${target}"

    docker run --rm --entrypoint cat "${IMAGE}" "${target}" > "${pdir}/nixl_utils.orig.py"

    python3 - "${pdir}/nixl_utils.orig.py" "${pdir}/nixl_utils.py" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

HARDCODED = '"rixl" if current_platform.is_rocm() else "nixl"'
if HARDCODED not in text:
    # Either upstream changed the expression, or this is already patched.
    # Refuse to emit a file that merely LOOKS patched.
    if "_kvstack_nixl_pkg" in text:
        print("already patched upstream-side; copying through", file=sys.stderr)
        open(dst, "w").write(text)
        sys.exit(0)
    sys.exit("nixl_utils.py no longer contains the hardcoded rixl/nixl "
             "expression this patch rewrites — re-read the file and update "
             "container.sh rather than shipping an unpatched override.")

HELPER = '''

def _kvstack_nixl_pkg() -> str:
    """Return the installed NIXL package name.

    Patched in by scripts/common/container.sh. Upstream hardcodes "rixl" on
    ROCm, but the rocm-aic images ship a ROCm-patched "nixl" and no "rixl"
    at all, so the platform test rejects a working install. Probe instead:
    prefer nixl, fall back to rixl, and if neither is importable return
    "nixl" so the caller's own ImportError path reports it.
    """
    import importlib.util
    for _pkg in ("nixl", "rixl"):
        try:
            if importlib.util.find_spec(_pkg) is not None:
                return _pkg
        except (ImportError, ValueError):
            continue
    return "nixl"

'''

# Insert the helper right after the logger definition so it precedes both
# use sites regardless of how they are ordered in the file.
anchor = re.search(r'^logger\s*=\s*init_logger\(__name__\)\s*$', text, re.M)
if not anchor:
    sys.exit("could not find the 'logger = init_logger(__name__)' anchor")
text = text[:anchor.end()] + "\n" + HELPER + text[anchor.end():]

text, n = text.replace(HARDCODED, "_kvstack_nixl_pkg()"), text.count(HARDCODED)
if n != 2:
    sys.exit(f"expected 2 occurrences of the hardcoded expression, found {n}")

open(dst, "w").write(text)
print(f"patched {n} call site(s)")
PYEOF

    echo "${target}" > "${pdir}/target-path"
    ok "wrote ${pdir}/nixl_utils.py (mounts over ${target})"
}

# ─────────────────────────────────────────────────────────────────────────────
# plugin-build — rebuild the XNVME_KV NIXL plugin from THIS REPO's source.
#
# WHY: the rocm-aic image ships a plugin built from the vendor's separate
# `kv-plugins/xnvme-kv-plugin/` tree (its own runtime log lines name that
# path), and that build PREDATES this repo's queryMem() override. Measured
# 2026-09-16 on the image's copy:
#
#   nm -D libplugin_XNVME_KV.so | c++filt | grep nixlXnvmeKvEngine::
#     -> 25 methods, queryMem NOT among them; the only queryMem symbol is
#        the WEAK base-class nixlBackendEngine::queryMem.
#
# plugins/xnvme-kv/xnvme_kv_backend.h's own header comment states exactly
# what that costs: NIXL's base class answers NIXL_ERR_NOT_SUPPORTED, LMCache
# reports EVERY L2 lookup as a miss, and "this backend then stores correctly
# and can never read anything back: writes land and are unreachable... it is
# also precisely what makes P/D disaggregation impossible, because a
# receiver's entire job is to discover keys IT NEVER WROTE."
#
# That is not a prediction — it is what this cluster did: a real query drove
# 283,520 stores / 1.16 GB onto the device, and no read ever followed.
#
# Configure options are the image's own, recovered from its build tree
# (/tmp/xnvme-kv-build/meson-info/intro-buildoptions.json), so the rebuild
# differs from the shipped artifact in SOURCE only, not in build config.
cmd_plugin_build() {
    local odir="${STACK_ROOT}/plugins"
    mkdir -p "${odir}"
    step "Rebuilding libplugin_XNVME_KV.so from ${REPO_ROOT}/plugins/xnvme-kv"

    # No --device flags: compiling against ROCm HEADERS needs no GPU, so this
    # stays runnable on a node whose amdgpu module is not loaded yet.
    docker run --rm \
        -v "${REPO_ROOT}:${REPO_ROOT}" -v "${odir}:/out" \
        --entrypoint bash "${IMAGE}" -c '
            set -e
            rm -rf /tmp/xnvme-kv-rebuild
            meson setup /tmp/xnvme-kv-rebuild '"${REPO_ROOT}"'/plugins/xnvme-kv \
                -Dnixl_path=/opt/nixl \
                -Dxnvme_incdir=/usr/local/include \
                -Dxnvme_libdir=/usr/local/lib/x86_64-linux-gnu \
                -Drocm_path=/opt/rocm \
                -Denable_vram=true \
                --prefix=/opt/nixl --buildtype=release >/dev/null
            ninja -C /tmp/xnvme-kv-rebuild
            cp /tmp/xnvme-kv-rebuild/libplugin_XNVME_KV.so /out/
        ' || die "plugin rebuild failed — see the meson/ninja output above."

    # Refuse to install a plugin that still lacks the override this whole
    # function exists to restore. A silently-unpatched .so would reproduce
    # the original bug while looking like a fix.
    docker run --rm -v "${odir}:/out" --entrypoint bash "${IMAGE}" -c \
        'nm -D --defined-only /out/libplugin_XNVME_KV.so | c++filt \
            | grep -q "nixlXnvmeKvEngine::queryMem"' \
        || die "the rebuilt plugin STILL has no nixlXnvmeKvEngine::queryMem" \
               " override — the source in plugins/xnvme-kv did not provide it," \
               " so installing this would silently reproduce the exact" \
               " every-lookup-is-a-miss bug it is meant to fix."
    ok "built ${odir}/libplugin_XNVME_KV.so (queryMem override present)"
}

cmd_up() {
    local role="$1"; local cname; cname="$(_cname "${role}")"
    local dev; dev="$(_role_dev)"
    local pdir; pdir="$(_PATCH_DIR)"
    local plugin_so="${STACK_ROOT}/plugins/libplugin_XNVME_KV.so"

    [ -f "${plugin_so}" ] || cmd_plugin_build

    [ -f "${pdir}/nixl_utils.py" ] && [ -f "${pdir}/target-path" ] \
        || cmd_vllm_patch
    local patch_target; patch_target="$(cat "${pdir}/target-path")"

    if docker inspect "${cname}" >/dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Running}}' "${cname}")" = "true" ]; then
            ok "${cname} already running — not recreating"
            return 0
        fi
        info "removing stopped ${cname}"
        docker rm -f "${cname}" >/dev/null
    fi

    [ -c "${dev}" ] || die "KV device ${dev} is not a char device on this" \
        " node — refusing to start a container that would silently fall" \
        " back to the plugin's /dev/ng0n1 default (the BOOT DRIVE)."

    step "Starting ${cname} from ${IMAGE} (KV device ${dev})"
    docker run -d --name "${cname}" \
        --network host --ipc host --shm-size "${SHM_SIZE}" \
        --security-opt seccomp=unconfined \
        --cap-add SYS_PTRACE \
        --device /dev/kfd --device /dev/dri --device "${dev}" \
        --group-add video --group-add render \
        -v "${REPO_ROOT}:${REPO_ROOT}" \
        -v "${STACK_ROOT}:${STACK_ROOT}" \
        -v "${HF_HOME}:${HF_HOME}" \
        -v "${pdir}/nixl_utils.py:${patch_target}:ro" \
        -v "${plugin_so}:${NIXL_PLUGIN_DIR_IN_IMAGE}/libplugin_XNVME_KV.so:ro" \
        -e HF_HOME="${HF_HOME}" \
        -e XNVME_DEV="${dev}" \
        -e KV_BACKEND="${KV_BACKEND}" \
        -e LMCACHE_DAEMON_ROLE="${role}" \
        -w "${REPO_ROOT}" \
        --entrypoint sleep "${IMAGE}" infinity >/dev/null
    ok "${cname} up"
}

cmd_exec() {
    local role="$1"; shift
    local cname; cname="$(_cname "${role}")"
    docker inspect "${cname}" >/dev/null 2>&1 \
        || die "${cname} is not running — run: container.sh up ${role}"
    docker exec "${cname}" bash -lc "cd ${REPO_ROOT} && $*"
}

ACTION="${1:-}"; shift || true
case "${ACTION}" in
    shim)   cmd_shim ;;
    vllm-patch)   cmd_vllm_patch ;;
    plugin-build) cmd_plugin_build ;;
    up)     cmd_up "${1:?role required}" ;;
    exec)   cmd_exec "${1:?role required}" "${@:2}" ;;
    logs)   docker logs "${@:2}" "$(_cname "${1:?role required}")" ;;
    down)   docker rm -f "$(_cname "${1:?role required}")" >/dev/null && ok "removed" ;;
    status) docker ps -a --filter "name=$(_cname "${1:?role required}")" ;;
    *) die "usage: container.sh {shim|up|exec|logs|down|status} ..." ;;
esac
