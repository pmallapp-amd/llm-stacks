#!/usr/bin/env bash
# lib-kv-rpc.sh — shared spdk_tgt RPC configuration sequence for the SMC3
# NVMe-KV target.
#
# Sourced by scripts/target/03-start-kv-target.sh (fresh bring-up) and
# scripts/target/50-reset-namespace.sh (drain-and-recreate after a geometry
# change). Both need the EXACT same transport/bdev/subsystem/ns/listener
# sequence; keeping it in one file means "start fresh" and "reset" cannot
# drift into two different configurations of the same target — which would
# be a much harder bug to catch than a duplicated-code smell, since it would
# only show up as prefill and decode getting inconsistent behavior depending
# on which script last touched the namespace.
#
# Requires the CALLER to have already sourced scripts/common/lib.sh (uses
# die/info/ok/warn/log/step from it) and to have cluster.env's NVMF_*,
# KV_BDEV_*, SPDK_TARGET_SRC, SPDK_RPC_SOCK, STACK_ROOT, PREFILL_HOST in
# scope. NOTE: SPDK_TARGET_SRC, not SPDK_SRC — this file is target-only
# (SMC3); SPDK_SRC is the INITIATOR tree path (SMC1/SMC2) and, as of
# SPDK v26.05, is very likely a different tree entirely (see
# config/cluster.env's SPDK section).
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
#     source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

rpc_json() {
    "${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" "$@"
}

kv_transport_exists() {
    rpc_json nvmf_get_transports 2>/dev/null | grep -qi "\"trtype\": *\"${NVMF_TRTYPE}\""
}

kv_bdev_exists() {
    rpc_json bdev_get_bdevs 2>/dev/null | grep -q "\"name\": *\"${KV_BDEV_NAME}\""
}

kv_subsystem_exists() {
    rpc_json nvmf_get_subsystems 2>/dev/null | grep -q "\"nqn\": *\"${NVMF_SUBNQN}\""
}

kv_ns_attached() {
    rpc_json nvmf_get_subsystems 2>/dev/null | grep -q "\"bdev_name\": *\"${KV_BDEV_NAME}\""
}

kv_listener_attached() {
    rpc_json nvmf_get_subsystems 2>/dev/null | grep -q "\"trsvcid\": *\"${NVMF_TRSVCID}\""
}

# create_kv_bdev — kv_spdk (SPDK 26.05.0-pre + NVIDIA NVMe-KV patches) is not
# vendored in this repo, so its bdev_kvmalloc_create RPC's exact argument
# names cannot be verified from here (only its rpc.py --help, at runtime,
# can). This tries ONE most-likely argument form (matching the -b/-s/--flag
# idiom every other SPDK bdev_*_create RPC uses) and, on failure, prints
# rpc.py's own --help output and dies — it does NOT try further silent
# guesses, and does NOT swallow the error, because a wrong guess that
# "succeeds" by coincidentally matching some OTHER RPC's argument shape
# would create a bdev with the wrong size/value-max silently.
create_kv_bdev() {
    if [ -n "${KV_BDEV_CREATE_ARGS:-}" ]; then
        info "bdev_kvmalloc_create: using KV_BDEV_CREATE_ARGS override: ${KV_BDEV_CREATE_ARGS}"
        # shellcheck disable=SC2086
        rpc_json bdev_kvmalloc_create ${KV_BDEV_CREATE_ARGS}
        return
    fi
    local bytes guess
    bytes=$(( KV_BDEV_SIZE_GB * 1024 * 1024 * 1024 ))
    guess="-b ${KV_BDEV_NAME} -s ${bytes} --value-max-size ${KV_BDEV_VALUE_MAX}"
    info "bdev_kvmalloc_create: trying guessed argument form: ${guess}"
    # shellcheck disable=SC2086
    if rpc_json bdev_kvmalloc_create ${guess}; then
        ok "bdev_kvmalloc_create succeeded with guessed argument form"
        return 0
    fi
    err "bdev_kvmalloc_create failed with the guessed argument form above."
    err "kv_spdk's exact RPC argument names for this command cannot be"
    err "verified from this repo (the fork is not vendored here). rpc.py's"
    err "own --help for the command:"
    rpc_json bdev_kvmalloc_create --help >&2 || true
    die "Set KV_BDEV_CREATE_ARGS to the exact argument string this kv_spdk" \
        "build expects (see --help above) and re-run, e.g.:" \
        "  KV_BDEV_CREATE_ARGS='-b ${KV_BDEV_NAME} -s ${bytes}' $0"
}

# delete_kv_bdev — same caution as create_kv_bdev, mirrored for the delete
# side (only reached from scripts/target/50-reset-namespace.sh).
delete_kv_bdev() {
    if [ -n "${KV_BDEV_DELETE_ARGS:-}" ]; then
        info "bdev_kvmalloc_delete: using KV_BDEV_DELETE_ARGS override: ${KV_BDEV_DELETE_ARGS}"
        # shellcheck disable=SC2086
        rpc_json bdev_kvmalloc_delete ${KV_BDEV_DELETE_ARGS}
        return
    fi
    info "bdev_kvmalloc_delete: trying guessed argument form: ${KV_BDEV_NAME}"
    if rpc_json bdev_kvmalloc_delete "${KV_BDEV_NAME}"; then
        ok "bdev_kvmalloc_delete succeeded"
        return 0
    fi
    err "bdev_kvmalloc_delete failed with the guessed argument form above."
    err "rpc.py's own --help for the command:"
    rpc_json bdev_kvmalloc_delete --help >&2 || true
    die "Set KV_BDEV_DELETE_ARGS to the exact argument string this kv_spdk" \
        "build expects (see --help above) and re-run."
}

# kv_target_spdk_version — parse ${SPDK_TARGET_SRC}/VERSION so the SGL-vs-
# iobuf decision below (and the RPC-flag probing in
# kv_target_build_transport_args) can run BEFORE spdk_tgt is even launched.
# Preferred over `rpc.py spdk_get_version` for that reason: the file exists
# the moment the tree is built, the RPC only after the process is up — and
# the whole point of kv_target_check_sgl historically was to fail BEFORE
# launch, not after (see its own comment).
kv_target_spdk_version() {
    if [ -f "${SPDK_TARGET_SRC}/VERSION" ]; then
        cat "${SPDK_TARGET_SRC}/VERSION"
    else
        echo "unknown"
    fi
}

# kv_target_spdk_is_pre_2605 — true (rc 0) if the detected version looks
# OLDER than v26.05, false otherwise. Unknown versions are treated as
# pre-26.05 (the conservative choice: keep the hard SGL assertion rather
# than silently downgrading it to a warning against a tree we can't place).
kv_target_spdk_is_pre_2605() {
    local v; v="$(kv_target_spdk_version)"
    case "${v}" in
        v26.0[5-9]*|v26.1*|v2[7-9].*|v[3-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# kv_target_check_sgl — the hard constraint documented in
# plugins/nvme-kv/spdk_nvme_kv_backend.h (~line 76): nvmf_tcp_create()
# rejects max_io_size when max_io_size / io_unit_size exceeds
# SPDK_NVMF_MAX_SGL_ENTRIES (16). Asserted here, arithmetically, BEFORE the
# nvmf_create_transport RPC is ever attempted — otherwise this only surfaces
# as spdk_tgt bluntly refusing that RPC after the process is already up,
# with no arithmetic shown, deep into a start/reset script's output.
#
# SPDK v26.05 DEPRECATED io_unit_size to a no-op (F3 in config/cluster.env's
# SPDK section): the transport now sizes its buffers from the iobuf pool
# (iobuf-small-cache-size / iobuf-large-cache-size) instead. That means this
# ratio is no longer necessarily the thing that governs whether
# nvmf_create_transport accepts NVMF_MAX_IO_SIZE on >=26.05 — so on those
# versions this is downgraded from a hard die() to a warn(). It still RUNS
# (and still prints the arithmetic) on every version, because it costs
# nothing and the ratio may still matter in practice even if it's no longer
# formally enforced the same way.
#
# CRITICAL: none of this changes KV_MAX_VALUE_SIZE=524288 (config/
# cluster.env). That default is validated independently of which SPDK
# version is in play — the SGL reasoning here is how it was ORIGINALLY
# derived, not a claim that raising it is now safe on >=26.05. Raising it is
# an EXPERIMENT: it requires draining the namespace first
# (scripts/target/50-reset-namespace.sh — see its own comment on why a
# geometry change without a drain silently corrupts reads) and then
# re-running scripts/verify/30-verify-kv-roundtrip.sh with a payload larger
# than the new value to prove the new ceiling actually round-trips.
kv_target_check_sgl() {
    local sgl_entries=$(( NVMF_MAX_IO_SIZE / NVMF_IO_UNIT_SIZE ))
    local spdk_version; spdk_version="$(kv_target_spdk_version)"
    info "SGL check: NVMF_MAX_IO_SIZE(${NVMF_MAX_IO_SIZE}) /" \
         " NVMF_IO_UNIT_SIZE(${NVMF_IO_UNIT_SIZE}) = ${sgl_entries}" \
         " (limit: SPDK_NVMF_MAX_SGL_ENTRIES=16; SPDK version: ${spdk_version})"
    if [ "${sgl_entries}" -gt 16 ]; then
        if kv_target_spdk_is_pre_2605; then
            die "SGL entries ${sgl_entries} > 16:" \
                " NVMF_MAX_IO_SIZE=${NVMF_MAX_IO_SIZE} /" \
                " NVMF_IO_UNIT_SIZE=${NVMF_IO_UNIT_SIZE} = ${sgl_entries}." \
                " nvmf_tcp_create() will reject this transport outright" \
                " (SPDK version ${spdk_version}, pre-26.05: io_unit_size" \
                " still governs SGL sizing on this tree)." \
                " Either raise NVMF_IO_UNIT_SIZE or lower NVMF_MAX_IO_SIZE in" \
                " config/cluster.env so the ratio is <= 16."
        else
            warn "SGL entries ${sgl_entries} > 16 (NVMF_MAX_IO_SIZE=" \
                 "${NVMF_MAX_IO_SIZE} / NVMF_IO_UNIT_SIZE=${NVMF_IO_UNIT_SIZE})." \
                 " On SPDK ${spdk_version} (>=26.05) io_unit_size is a" \
                 " DEPRECATED no-op (F3) — the transport sizes its buffers" \
                 " from the iobuf pool instead, so this ratio is NOT" \
                 " necessarily the real ceiling anymore, and" \
                 " nvmf_create_transport may or may not reject it; this is" \
                 " unverified against this specific tree. Proceeding, but if" \
                 " transport creation fails below, that arithmetic is no" \
                 " longer a reliable predictor of why on this SPDK version."
        fi
    else
        ok "SGL check passed: ${sgl_entries} <= 16 (SPDK ${spdk_version})"
    fi
}

# kv_target_build_transport_args — returns (via echo, one arg per line) the
# extra nvmf_create_transport arguments appropriate to the detected SPDK
# version. Kept separate from kv_target_apply_config so 03-start-kv-
# target.sh's --skip-config path and 50-reset-namespace.sh both go through
# the identical derivation.
#
# On >=26.05 this PROBES `rpc.py nvmf_create_transport --help` for
# --iobuf-small-cache-size / --iobuf-large-cache-size rather than assuming
# the fork's RPC surface has them under those exact flag names — this repo
# does not vendor kv_spdk, so the fork's RPC argument names cannot be
# verified statically (same caution as create_kv_bdev's comment above).
# Requires spdk_tgt to already be reachable (the probe calls rpc.py), so
# this can only be called from kv_target_apply_config, AFTER kv_target_
# check_sgl has already run pre-launch.
kv_target_build_transport_args() {
    local -a args=(-u "${NVMF_IO_UNIT_SIZE}" -i "${NVMF_MAX_IO_SIZE}" \
        -q "${NVMF_MAX_QUEUE_DEPTH}" -m "${NVMF_MAX_QPAIRS_PER_CTRLR}" -c 0)
    if ! kv_target_spdk_is_pre_2605; then
        local help_out
        help_out="$(rpc_json nvmf_create_transport --help 2>/dev/null || true)"
        if echo "${help_out}" | grep -q -- '--iobuf-small-cache-size'; then
            args+=(--iobuf-small-cache-size "${NVMF_IOBUF_SMALL_CACHE_SIZE}")
        else
            info "nvmf_create_transport --help does not advertise" \
                 " --iobuf-small-cache-size on this tree — skipping it" \
                 " (NVMF_IOBUF_SMALL_CACHE_SIZE=${NVMF_IOBUF_SMALL_CACHE_SIZE}" \
                 " configured but not applied)."
        fi
        if echo "${help_out}" | grep -q -- '--iobuf-large-cache-size'; then
            args+=(--iobuf-large-cache-size "${NVMF_IOBUF_LARGE_CACHE_SIZE}")
        else
            info "nvmf_create_transport --help does not advertise" \
                 " --iobuf-large-cache-size on this tree — skipping it" \
                 " (NVMF_IOBUF_LARGE_CACHE_SIZE=${NVMF_IOBUF_LARGE_CACHE_SIZE}" \
                 " configured but not applied)."
        fi
    fi
    printf '%s\n' "${args[@]}"
}

# kv_target_sanity_check_traddr — NVMF_TRADDR must actually be a local
# address on this host, or spdk_tgt will happily ACCEPT the
# nvmf_subsystem_add_listener RPC yet never bind anything an initiator can
# reach — a misconfiguration that only surfaces on SMC1/SMC2 as a connection
# timeout, nowhere near this script's output.
kv_target_sanity_check_traddr() {
    local local_ips prefill_src
    local_ips="$(hostname -I 2>/dev/null || true)"
    case " ${local_ips} " in
        *" ${NVMF_TRADDR} "*)
            ok "NVMF_TRADDR=${NVMF_TRADDR} is a local address on this host"
            return 0
            ;;
    esac
    prefill_src="$(srcip_to "${PREFILL_HOST}" 2>/dev/null || true)"
    if [ "${prefill_src}" = "${NVMF_TRADDR}" ]; then
        ok "NVMF_TRADDR=${NVMF_TRADDR} matches the route-derived source IP" \
           " toward ${PREFILL_HOST}"
        return 0
    fi
    warn "NVMF_TRADDR=${NVMF_TRADDR} does not match any local address" \
         " (hostname -I: ${local_ips:-<none>}) nor the source IP toward" \
         " ${PREFILL_HOST} (${prefill_src:-<none>}). The listener RPC will" \
         " still be accepted by spdk_tgt, but no initiator will be able to" \
         " reach it if this address isn't actually bound on this host."
}

# kv_target_apply_config — the full, idempotent RPC sequence. Every step
# checks whether its target state already exists before mutating anything,
# so this is safe to call repeatedly (fresh start, --skip-config re-run,
# or post-teardown recreation from 50-reset-namespace.sh).
kv_target_apply_config() {
    kv_target_check_sgl

    step "RPC: transport ${NVMF_TRTYPE}"
    if [ "${NVMF_TRTYPE}" = "RDMA" ]; then
        # Precondition, not a launch blocker: spdk_tgt itself may still be
        # able to come up (see 03-start-kv-target.sh's own RDMA warning) —
        # but nvmf_create_transport -t RDMA needs a kernel-visible RDMA
        # device to succeed at all.
        [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ] \
            || warn "/sys/class/infiniband is empty or absent —" \
                    " nvmf_create_transport -t RDMA is likely to fail" \
                    " without a kernel-visible RDMA device."
    fi
    if kv_transport_exists; then
        info "transport ${NVMF_TRTYPE} already created — skip"
    else
        local -a _transport_args
        mapfile -t _transport_args < <(kv_target_build_transport_args)
        rpc_json nvmf_create_transport -t "${NVMF_TRTYPE}" "${_transport_args[@]}"
        ok "transport ${NVMF_TRTYPE} created"
    fi

    step "RPC: bdev_kvmalloc ${KV_BDEV_NAME} (${KV_BDEV_SIZE_GB} GiB, value-max ${KV_BDEV_VALUE_MAX})"
    if kv_bdev_exists; then
        info "bdev ${KV_BDEV_NAME} already exists — skip"
    else
        create_kv_bdev
        ok "bdev ${KV_BDEV_NAME} created"
    fi

    step "RPC: subsystem ${NVMF_SUBNQN}"
    if kv_subsystem_exists; then
        info "subsystem ${NVMF_SUBNQN} already exists — skip"
    else
        # Phase 2 TODO: drop -a (allow-any-host) in favour of explicit
        # nvmf_subsystem_add_host calls for NVMF_HOSTNQN_PREFILL and
        # NVMF_HOSTNQN_DECODE. -a is acceptable for a closed bring-up lab
        # network; it is not something acceptance testing should ship with,
        # since it means any host that can reach this port and speak
        # NVMe-oF can attach to the subsystem.
        rpc_json nvmf_create_subsystem "${NVMF_SUBNQN}" -a \
            -s KVTGT00000001 -d NVMe-KV
        ok "subsystem ${NVMF_SUBNQN} created"
    fi

    step "RPC: attach namespace ${KV_BDEV_NAME} -> ${NVMF_SUBNQN}"
    if kv_ns_attached; then
        info "namespace already attached — skip"
    else
        rpc_json nvmf_subsystem_add_ns "${NVMF_SUBNQN}" "${KV_BDEV_NAME}"
        ok "namespace attached"
    fi

    step "RPC: listener ${NVMF_TRTYPE} ${NVMF_TRADDR}:${NVMF_TRSVCID}"
    kv_target_sanity_check_traddr
    if kv_listener_attached; then
        info "listener already attached — skip"
    else
        rpc_json nvmf_subsystem_add_listener "${NVMF_SUBNQN}" \
            -t "${NVMF_TRTYPE}" -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}" \
            -f "${NVMF_ADRFAM}"
        ok "listener attached"
    fi

    mkdir -p "${STACK_ROOT}/etc"
    rpc_json save_config > "${STACK_ROOT}/etc/kv-target-config.json"
    ok "config saved -> ${STACK_ROOT}/etc/kv-target-config.json"
}

# kv_target_teardown_namespace — reverse order of the namespace-related
# steps in kv_target_apply_config (listener, subsystem, bdev). Deliberately
# leaves the transport in place: spdk_tgt does not need it recreated, and
# there is no per-namespace state on it to go stale.
kv_target_teardown_namespace() {
    step "RPC: remove listener ${NVMF_TRTYPE} ${NVMF_TRADDR}:${NVMF_TRSVCID}"
    if kv_listener_attached; then
        rpc_json nvmf_subsystem_remove_listener "${NVMF_SUBNQN}" \
            -t "${NVMF_TRTYPE}" -a "${NVMF_TRADDR}" -s "${NVMF_TRSVCID}"
        ok "listener removed"
    else
        info "no listener attached — skip"
    fi

    step "RPC: delete subsystem ${NVMF_SUBNQN}"
    if kv_subsystem_exists; then
        rpc_json nvmf_delete_subsystem "${NVMF_SUBNQN}"
        ok "subsystem deleted"
    else
        info "subsystem already absent — skip"
    fi

    step "RPC: delete bdev ${KV_BDEV_NAME}"
    if kv_bdev_exists; then
        delete_kv_bdev
        ok "bdev deleted"
    else
        info "bdev already absent — skip"
    fi
}
