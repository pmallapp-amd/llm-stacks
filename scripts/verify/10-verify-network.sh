#!/usr/bin/env bash
# 10-verify-network.sh — network-layer verification for the P/D-disaggregated
# KV cache cluster: reachability, MTU, throughput, and (in RDMA mode) fabric
# health, for whichever legs are relevant to THIS host.
#
# Node:          any (SMC1 prefill, SMC2 decode, SMC3 target) — also safe to
#                run from a jump host/laptop with reach to all three, in
#                which case it just checks every leg instead of self-excluding.
# Prerequisites: none. Read-only: pings, connects, and (optionally) an
#                iperf3/ib_write_bw client run against a peer that must
#                already be running the corresponding server side (this
#                script never starts a server on the peer).
# Next step:     scripts/verify/20-verify-nixl-plugin.sh (compute nodes only).
#
# usage: 10-verify-network.sh [--skip-throughput] [--skip-rdma]
#
# WHY this exists as its own layer below the NIXL/LMCache checks: every
# failure mode those higher layers report ("plugin unsupported", "NIXL
# batched query failed", "hit tokens: 0", a request that just hangs) can
# ALSO be explained by something as mundane as an MTU mismatch or a link
# that only fails once payloads get large. Ruling the network out FIRST
# means a later failure in 20-/30-/40- can be trusted to be an application
# (plugin/LMCache) problem rather than "was it the network after all".

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"

SKIP_THROUGHPUT=0
SKIP_RDMA=0
for arg in "$@"; do
    case "${arg}" in
        --skip-throughput) SKIP_THROUGHPUT=1 ;;
        --skip-rdma)       SKIP_RDMA=1 ;;
        *) die "unknown argument: ${arg} (expected --skip-throughput, --skip-rdma)" ;;
    esac
done

step "Network verification: $(hostname) ($(date -u +%FT%TZ))  KV_TRANSPORT=${KV_TRANSPORT}"
banner_config

# ─────────────────────────────────────────────────────────────────────────────
# Which node is this, and which peers are relevant? Self-excluding, same
# pattern as scripts/common/00-preflight.sh's "Cluster reachability" section
# — this lets the script run unmodified from any of the three nodes, or from
# an operator's jump host (THIS_ROLE=unknown -> checks all three peers).
# ─────────────────────────────────────────────────────────────────────────────
_local_ips="$(hostname -I 2>/dev/null || true)"
THIS_ROLE="unknown"
case " ${_local_ips} " in
    *" ${PREFILL_HOST} "*) THIS_ROLE="prefill" ;;
    *" ${DECODE_HOST} "*)  THIS_ROLE="decode" ;;
    *" ${TARGET_HOST} "*)  THIS_ROLE="target" ;;
esac
info "role: ${THIS_ROLE}   local IPs: ${_local_ips:-<none>}"

declare -A PEERS=()   # label -> "host port"
[ "${THIS_ROLE}" = "prefill" ] || PEERS["prefill(${PREFILL_HOST})"]="${PREFILL_HOST} ${PREFILL_PORT}"
[ "${THIS_ROLE}" = "decode" ]  || PEERS["decode(${DECODE_HOST})"]="${DECODE_HOST} ${DECODE_PORT}"
[ "${THIS_ROLE}" = "target" ]  || PEERS["target(${TARGET_HOST})"]="${TARGET_HOST} ${NVMF_TRSVCID}"

if [ "${#PEERS[@]}" -eq 0 ]; then
    die "this host matches ALL of PREFILL_HOST/DECODE_HOST/TARGET_HOST —" \
        " cluster.env's addresses can't all be the same box; fix config/cluster.env"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ICMP + TCP reachability.
# ─────────────────────────────────────────────────────────────────────────────
step "ICMP + TCP reachability"
for _label in "${!PEERS[@]}"; do
    read -r _ip _port <<< "${PEERS[${_label}]}"
    check "ping reachable: ${_label}" bash -c "ping -c2 -W2 '${_ip}' >/dev/null 2>&1" || true
    check "TCP reachable: ${_label}:${_port}" wait_for_port "${_ip}" "${_port}" 5 || true
done

# ─────────────────────────────────────────────────────────────────────────────
# MTU: report the LOCAL interface MTU toward each peer, then actively probe
# path MTU with `ping -M do -s <size>` at two sizes chosen to distinguish a
# 1500-byte path (fails only above ~1472 payload bytes, 28 bytes of IP+ICMP
# header) from a genuine 9000-byte jumbo path (fails only above ~8972).
#
# WHY this matters more than it looks: a jumbo-frame MTU mismatch on either
# leg does NOT show up as "the network is down" — small packets (handshakes,
# health checks, even most control-plane RPCs) sail through untouched. It
# only manifests once something tries to move a large payload at the
# configured MTU: NVMe-oF/TCP PDUs and UCX's "tcp" transport both send
# payload-sized segments that, with `ping -M do` (DF bit set, no
# fragmentation) failing above 1472 despite an interface configured for
# 9000, means SOME hop on the path (a switch, a bond member, a VLAN) is
# still at 1500 and silently drops or black-holes the oversized frames
# instead of returning an ICMP "fragmentation needed" (common behind
# misconfigured firewalls/security groups) — the connection just stalls
# under load with no error anywhere, which is exactly the "everything looks
# fine until it doesn't" failure class this whole verify/ tree exists to
# catch before it's mistaken for an application bug.
# ─────────────────────────────────────────────────────────────────────────────
step "MTU: local interface + active path-MTU probe"
for _label in "${!PEERS[@]}"; do
    read -r _ip _port <<< "${PEERS[${_label}]}"
    _if="$(iface_to "${_ip}")"
    if [ -n "${_if}" ]; then
        _mtu="$(cat "/sys/class/net/${_if}/mtu" 2>/dev/null || echo '?')"
        log "  ${_label}: iface_to=${_if} local_mtu=${_mtu}"
    else
        warn "  ${_label}: iface_to() could not resolve a route — is the peer reachable at all?"
    fi

    _largest_ok=0
    for _payload in 1472 8972; do
        if ping -M "do" -c2 -W2 -s "${_payload}" "${_ip}" >/dev/null 2>&1; then
            _largest_ok="${_payload}"
        fi
    done
    case "${_largest_ok}" in
        8972) ok  "  ${_label}: path MTU >= 9000 (jumbo frames pass end-to-end)" ;;
        1472) warn "  ${_label}: path MTU is ~1500, NOT 9000 — jumbo frames do" \
                   " NOT pass end-to-end on this leg even though the local" \
                   " interface may be configured for 9000. This is the" \
                   " classic 'NVMe-oF/TCP or UCX stalls only on large" \
                   " transfers' cause: small control traffic (health checks," \
                   " NVMe-oF connect/keepalive, UCX handshake) all fit under" \
                   " 1500 and work fine, but any KV-page-sized transfer" \
                   " sent at a 9000-MTU socket option gets black-holed" \
                   " partway down a 1500-MTU hop. Fix every hop's MTU" \
                   " (physical NIC on both ends AND any switch/bond/VLAN" \
                   " in between) to match before trusting a throughput or" \
                   " KV-transfer test on this leg." ;;
        0)    check "  ${_label}: path MTU >= 1500 (bare minimum)" false || true ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Raw TCP throughput on the storage leg (this host <-> TARGET_HOST), via
# iperf3 if present. Soft/advisory: requires an iperf3 SERVER already
# running on the peer (this script does not start one — starting a listener
# on a remote node from a "read-only, run from anywhere" verify script would
# be a bigger blast-radius action than this tree's other scripts take), so
# a failure here just as plausibly means "no iperf3 server on the peer" as
# "the network is slow" — hence check_soft, not check.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_THROUGHPUT}" -eq 1 ]; then
    step "Throughput (skipped: --skip-throughput)"
elif [ "${THIS_ROLE}" = "target" ]; then
    step "Throughput (skipped: this host IS the storage target — run this" \
         " check from prefill or decode instead, with an iperf3 server" \
         " already started here on ${TARGET_HOST})"
else
    step "Raw TCP throughput on the storage leg (-> ${TARGET_HOST})"
    if command -v iperf3 >/dev/null 2>&1; then
        _out="$(timeout 15 iperf3 -c "${TARGET_HOST}" -t 5 -J 2>/dev/null || true)"
        if [ -n "${_out}" ] && command -v python3 >/dev/null 2>&1; then
            _mbps="$(printf '%s' "${_out}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    bps = d["end"]["sum_received"]["bits_per_second"]
    print(f"{bps / 1e9:.2f}")
except Exception:
    print("")
' 2>/dev/null || true)"
            if [ -n "${_mbps}" ]; then
                log "  measured: ${_mbps} Gbps"
                # DSC3-2Q400 / POLLARA-1Q400 are 400G-class NICs (see
                # config/cluster.env's topology comment). A 400G NIC that
                # negotiates full duplex and isn't starved by CPU/PCIe
                # should clear well over 100 Gbps on a single iperf3 stream
                # in most cases, and a LOT more with parallel streams; a
                # result in the 10G-class range (roughly <=15) on hardware
                # provisioned for 400G is not "a bit slow", it's a strong
                # signal of a negotiation/driver/cabling problem (wrong
                # speed auto-negotiated, a bad SFP/cable, or traffic
                # accidentally routed over a management NIC instead of the
                # data-plane NIC) and should be run down before trusting any
                # KV-transfer benchmark on this leg.
                check_soft "storage-leg throughput >= 100 Gbps (400G-class NIC floor)" \
                    bash -c "python3 -c \"import sys; sys.exit(0 if float('${_mbps}') >= 100 else 1)\""
            else
                warn "  iperf3 ran but JSON output could not be parsed"
            fi
        else
            warn "  iperf3 client could not reach an iperf3 SERVER on" \
                 " ${TARGET_HOST} (not started, or blocked) — start" \
                 " 'iperf3 -s' there first to get a throughput number." \
                 " This is advisory only; not a hard failure."
        fi
    else
        warn "  iperf3 not installed — advisory throughput check skipped." \
             " Install iperf3 to get a quantitative floor check on this leg."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# RDMA fabric checks — HARD checks in KV_TRANSPORT=rdma (Phase 2), SKIPPED
# entirely in tcp mode (Phase 1). See config/cluster.env's KV_TRANSPORT
# comment and lib.sh's setup_ucx_env: rdma mode deliberately does not fall
# back to tcp, so a broken RDMA fabric must fail loudly here rather than
# silently degrading the moment vLLM actually starts.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${KV_TRANSPORT}" != "rdma" ]; then
    step "RDMA fabric checks (skipped: KV_TRANSPORT=${KV_TRANSPORT})"
elif [ "${SKIP_RDMA}" -eq 1 ]; then
    step "RDMA fabric checks (skipped: --skip-rdma)"
else
    step "RDMA fabric checks (KV_TRANSPORT=rdma — these are HARD checks)"

    case "${THIS_ROLE}" in
        prefill) _rdma_dev="${PREFILL_RDMA_DEV}" ;;
        decode)  _rdma_dev="${DECODE_RDMA_DEV}" ;;
        target)  _rdma_dev="${TARGET_RDMA_DEV}" ;;
        *) _rdma_dev="" ;;
    esac
    [ -n "${_rdma_dev}" ] || warn "no RDMA device configured for role=${THIS_ROLE} in" \
                                  " cluster.env (*_RDMA_DEV) — device-specific checks below" \
                                  " will be skipped, but link-level checks still run."

    check "ibv_devinfo available" command -v ibv_devinfo || true
    if command -v ibv_devinfo >/dev/null 2>&1; then
        _devinfo="$(ibv_devinfo 2>/dev/null || true)"
        printf '%s\n' "${_devinfo}" | while IFS= read -r line; do log "  ${line}"; done
        check "at least one RDMA port reports PORT_ACTIVE" \
            bash -c "printf '%s' \"\${1}\" | grep -q 'state:.*PORT_ACTIVE'" _ "${_devinfo}" || true
        if [ -n "${_rdma_dev}" ]; then
            check "configured RDMA device '${_rdma_dev}' present in ibv_devinfo" \
                bash -c "printf '%s' \"\${1}\" | grep -q '${_rdma_dev}'" _ "${_devinfo}" || true
        fi
    fi

    check "rdma-core 'rdma link show' available" command -v rdma || true
    if command -v rdma >/dev/null 2>&1; then
        _linkshow="$(rdma link show 2>/dev/null || true)"
        printf '%s\n' "${_linkshow}" | while IFS= read -r line; do log "  ${line}"; done
        check "rdma link show reports at least one link" test -n "${_linkshow}" || true
    fi

    for _label in "${!PEERS[@]}"; do
        read -r _ip _port <<< "${PEERS[${_label}]}"
        if command -v ib_write_bw >/dev/null 2>&1; then
            info "ib_write_bw against ${_label} requires a server" \
                 " ('ib_write_bw' with no args) already running on the" \
                 " peer — attempting client connect with a short timeout;" \
                 " a connection-refused here just means no server is up" \
                 " on the peer right now, which is expected unless you" \
                 " started one."
            check_soft "ib_write_bw reaches ${_label}" \
                bash -c "timeout 10 ib_write_bw -d '${_rdma_dev:-}' '${_ip}' >/dev/null 2>&1"
        elif command -v rping >/dev/null 2>&1; then
            check_soft "rping reaches ${_label}" \
                bash -c "timeout 10 rping -c -a '${_ip}' -C 1 >/dev/null 2>&1"
        else
            warn "neither ib_write_bw nor rping installed — cannot" \
                 " exercise the RDMA data path against ${_label}," \
                 " only link state was checked above"
        fi
    done
fi

checks_summary
