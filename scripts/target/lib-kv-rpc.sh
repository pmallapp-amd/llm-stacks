#!/usr/bin/env bash
# lib-kv-rpc.sh — shared helpers for the SMC3 NVMe-KV target: --json config
# generation (the single source of truth for nvmf_tgt bring-up) and
# read-only rpc.py INSPECTION helpers used only by scripts/target/04-verify-
# target.sh.
#
# WHY THIS FILE NO LONGER RUNS AN RPC SEQUENCE: an earlier version of this
# file drove nvmf_tgt through five SEPARATE RPCs run in order after the
# process was already up — nvmf_create_transport, then bdev_kvmalloc_create
# (guessed argument shape, since the target-side SPDK tree was not vendored
# here and its exact RPC surface could not be verified statically), then
# nvmf_create_subsystem, nvmf_subsystem_add_ns, nvmf_subsystem_add_listener.
# scripts/target/03-start-kv-target.sh (fresh start) and scripts/target/50-
# reset-namespace.sh (drain-and-recreate) each had to reproduce that exact
# sequence, in that exact order, or the two could drift into different
# configurations of the same target with no test that would catch it.
#
# rocm-aic/target.sh — the PROVEN working configuration this repo's target
# scripts were rewritten from — does none of that: it hands nvmf_tgt ONE
# --json config file at startup (--json applies transport/bdev/subsystem/
# ns/listener atomically, before the process ever accepts a connection) and
# uses rpc.py afterward ONLY to inspect what came up, never to mutate it.
# That removes the whole "did start and reset apply the same sequence"
# class of bug by construction: same config/cluster.env in, same JSON file
# out, every time. See kv_target_gen_json_config() below for the generator
# and scripts/target/50-reset-namespace.sh for why "reset" is now simply
# "restart the process" rather than a mirrored RPC teardown.
#
# Requires the CALLER to have already sourced scripts/common/lib.sh (uses
# die/info/ok/warn/log/step from it) and to have cluster.env's NVMF_*,
# KV_BDEV_*, SPDK_TARGET_SRC, SPDK_RPC_SOCK, STACK_ROOT, PREFILL_HOST in
# scope. NOTE: SPDK_TARGET_SRC, not SPDK_SRC — this file is target-only
# (SMC3); SPDK_SRC is the INITIATOR tree path (SMC1/SMC2) and is a
# different, independently-built tree (see config/cluster.env's SPDK
# section).
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
#     source "$(dirname "${BASH_SOURCE[0]}")/lib-kv-rpc.sh"

rpc_json() {
    "${SPDK_TARGET_SRC}/scripts/rpc.py" -s "${SPDK_RPC_SOCK}" "$@"
}

# kv_target_spdk_version — informational only. Every version-dependent
# branch that used to live here (pre-/post-26.05 io_unit_size handling,
# probing nvmf_create_transport --help for iobuf cache-size flags) is gone:
# config/cluster.env's SPDK_TARGET_REF now always resolves to a tree that
# has 0002/0003 applied on top of upstream (scripts/target/02-build-spdk-
# kv.sh), so there is exactly one target-side RPC surface to reason about,
# not a matrix of them.
kv_target_spdk_version() {
    if [ -f "${SPDK_TARGET_SRC}/VERSION" ]; then
        cat "${SPDK_TARGET_SRC}/VERSION"
    else
        echo "unknown"
    fi
}

# kv_target_check_sgl — the hard constraint nvmf_tcp_create() enforces,
# asserted here, ARITHMETICALLY, before nvmf_tgt is even launched:
#     max_io_size / large_bufsize <= SPDK_NVMF_MAX_SGL_ENTRIES (16)
#
# NOTE the denominator is NVMF_LARGE_BUFSIZE, NOT NVMF_IO_UNIT_SIZE. An
# earlier version of this function divided by io_unit_size — simply wrong:
# nvmf_tcp_create() sizes its SGL buffers from the iobuf pool's
# large_bufsize, not io_unit_size. iobuf's DEFAULT large_bufsize is 132KB,
# which caps max_io_size at ~2MB no matter what io_unit_size is set to;
# raising large_bufsize to 1MiB (config/cluster.env's NVMF_LARGE_BUFSIZE) is
# what lifts the ceiling to 16 x 1MiB = 16MiB — exactly rocm-aic/target.sh's
# proven 16777216 / 1048576 = 16 configuration.
kv_target_check_sgl() {
    local sgl_entries=$(( NVMF_MAX_IO_SIZE / NVMF_LARGE_BUFSIZE ))
    info "SGL check: NVMF_MAX_IO_SIZE(${NVMF_MAX_IO_SIZE}) /" \
         " NVMF_LARGE_BUFSIZE(${NVMF_LARGE_BUFSIZE}) = ${sgl_entries}" \
         " (limit: SPDK_NVMF_MAX_SGL_ENTRIES=16)"
    if [ "${sgl_entries}" -gt 16 ]; then
        die "SGL entries ${sgl_entries} > 16:" \
            " NVMF_MAX_IO_SIZE=${NVMF_MAX_IO_SIZE} /" \
            " NVMF_LARGE_BUFSIZE=${NVMF_LARGE_BUFSIZE} = ${sgl_entries}." \
            " nvmf_tcp_create() will reject this transport outright." \
            " Either raise NVMF_LARGE_BUFSIZE or lower NVMF_MAX_IO_SIZE in" \
            " config/cluster.env so the ratio is <= 16 (rocm-aic/target.sh's" \
            " proven configuration is 16777216 / 1048576 = 16, exactly at" \
            " the limit)."
    else
        ok "SGL check passed: ${sgl_entries} <= 16"
    fi
}

# kv_target_sanity_check_traddr — NVMF_TRADDR must actually be a local
# address on this host, or the --json config's listener will bind nothing
# an initiator can reach — a misconfiguration that only surfaces on
# SMC1/SMC2 as a connection timeout, nowhere near this script's output.
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
         " ${PREFILL_HOST} (${prefill_src:-<none>}). nvmf_tgt will still" \
         " bind the listener from the --json config, but no initiator will" \
         " be able to reach it if this address isn't actually bound on" \
         " this host."
}

# kv_target_gen_json_config <output-path> — the single source of truth for
# nvmf_tgt's --json startup config. Every value here traces to
# rocm-aic/target.sh (the PROVEN configuration this repo's target scripts
# were rewritten from — see that file's own comments for the measured
# failures behind each one) via config/cluster.env's NVMF_*/KV_BDEV_* vars.
# Called from scripts/target/03-start-kv-target.sh before every launch —
# deterministic given the same env, so regenerating it on every start
# (including a --restart) is always safe and never drifts.
kv_target_gen_json_config() {
    local out="$1"
    mkdir -p "$(dirname "${out}")"
    cat > "${out}" <<EOF
{
  "subsystems": [
    {
      "subsystem": "iobuf",
      "config": [
        {
          "method": "iobuf_set_options",
          "params": {
            "small_pool_count": ${NVMF_SMALL_POOL_COUNT},
            "large_pool_count": ${NVMF_LARGE_POOL_COUNT},
            "small_bufsize": ${NVMF_SMALL_BUFSIZE},
            "large_bufsize": ${NVMF_LARGE_BUFSIZE}
          }
        }
      ]
    },
    {
      "subsystem": "bdev",
      "config": [
        {
          "method": "bdev_kvmalloc_create",
          "params": {
            "name": "${KV_BDEV_NAME}",
            "max_key_size": ${KV_BDEV_MAX_KEY_SIZE},
            "max_value_size": ${KV_BDEV_VALUE_MAX}
          }
        }
      ]
    },
    {
      "subsystem": "nvmf",
      "config": [
        {
          "method": "nvmf_create_transport",
          "params": {
            "trtype": "${NVMF_TRTYPE}",
            "max_io_size": ${NVMF_MAX_IO_SIZE},
            "io_unit_size": ${NVMF_IO_UNIT_SIZE},
            "max_io_qpairs_per_ctrlr": ${NVMF_MAX_IO_QPAIRS_PER_CTRLR}
          }
        },
        {
          "method": "nvmf_create_subsystem",
          "params": {
            "nqn": "${NVMF_SUBNQN}",
            "allow_any_host": true,
            "serial_number": "NIXLKV00001",
            "model_number": "NIXL KV NullDev"
          }
        },
        {
          "method": "nvmf_subsystem_add_ns",
          "params": {
            "nqn": "${NVMF_SUBNQN}",
            "namespace": { "bdev_name": "${KV_BDEV_NAME}", "nsid": 1 }
          }
        },
        {
          "method": "nvmf_subsystem_add_listener",
          "params": {
            "nqn": "${NVMF_SUBNQN}",
            "listen_address": {
              "trtype": "${NVMF_TRTYPE}",
              "adrfam": "${NVMF_ADRFAM}",
              "traddr": "${NVMF_TRADDR}",
              "trsvcid": "${NVMF_TRSVCID}"
            }
          }
        }
      ]
    }
  ]
}
EOF
}

# ── Inspection-only helpers (rpc.py against a RUNNING nvmf_tgt) ────────────
# Used exclusively by scripts/target/04-verify-target.sh. Never used to
# MUTATE config — see the file header on why that class of bug is retired.
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
