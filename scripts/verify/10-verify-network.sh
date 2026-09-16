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
# Raw TCP throughput on every leg relevant to this host (compute leg to the
# other of prefill/decode, and/or the storage leg to SMC3), via iperf3 if
# present. Soft/advisory: requires an iperf3 SERVER already running on the
# peer (this script does not start one — starting a listener on a remote
# node from a "read-only, run from anywhere" verify script would be a
# bigger blast-radius action than this tree's other scripts take), so a
# failure here just as plausibly means "no iperf3 server on the peer" as
# "the network is slow" — hence check_soft, not check.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_THROUGHPUT}" -eq 1 ]; then
    step "Throughput (skipped: --skip-throughput)"
elif [ "${#PEERS[@]}" -eq 0 ]; then
    step "Throughput (skipped: no peer resolved for this host)"
else
    for _label in "${!PEERS[@]}"; do
        read -r _ip _port <<< "${PEERS[${_label}]}"
        step "Raw TCP throughput on the leg -> ${_label}"
        if command -v iperf3 >/dev/null 2>&1; then
            _out="$(timeout 15 iperf3 -c "${_ip}" -t 5 -J 2>/dev/null || true)"
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
                    # The fabric NICs (Pensando DSC3-2Q400, ionic_0..7 /
                    # benicNp1) are MEASURED 400 Gb/s links (HANDOFF.md §15.6:
                    # `ethtool` reports Speed: 400000Mb/s on all 8 ports on
                    # both nodes; `/sys/class/infiniband/ionic_2/ports/1/rate`
                    # reads "400 Gb/sec (4X NDR)"). ib_write_bw (RC,
                    # cross-node) measured 41,898 MiB/s (~351 Gb/s, ~88% of
                    # line rate) at 8 MiB messages — see §15.5. iperf3/TCP
                    # will not reach that ceiling (TCP over a RoCE-capable
                    # NIC still pays kernel-stack overhead that RDMA
                    # bypasses), but a healthy 400G NIC on this fabric should
                    # still clear well over 100 Gbps on a single stream; a
                    # result in the 10G-class range (roughly <=15) is a
                    # strong signal of a negotiation/driver/cabling/wrong-NIC
                    # problem and should be run down before trusting any
                    # KV-transfer benchmark on this leg.
                    check_soft "throughput -> ${_label} >= 100 Gbps (400G-class NIC floor)" \
                        bash -c "python3 -c \"import sys; sys.exit(0 if float('${_mbps}') >= 100 else 1)\""
                else
                    warn "  iperf3 ran but JSON output could not be parsed"
                fi
            else
                warn "  iperf3 client could not reach an iperf3 SERVER on" \
                     " ${_ip} (not started, or blocked) — start" \
                     " 'iperf3 -s' there first to get a throughput number." \
                     " This is advisory only; not a hard failure."
            fi
        else
            warn "  iperf3 not installed — advisory throughput check skipped." \
                 " Install iperf3 to get a quantitative floor check on this leg."
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# LMCache MP daemon port (local, same-host). LMCACHE_MP_HOST is loopback BY
# DESIGN (config/cluster.env's LMCACHE_MP_HOST comment: the daemon shares
# the host's IPC namespace with the vLLM process it serves — this is a
# same-host rendezvous, not a cross-node leg), so this is a local
# port-reachability check, not a network-topology one — it lives here
# rather than in scripts/verify/20-verify-nixl-plugin.sh because 20- is
# specifically scoped to the NIXL/XNVME_KV storage-leg plugin and never
# touches LMCache at all; this is the network-layer script, and "is the
# port this host's vLLM will dial even open" is a network-layer question.
# Advisory only (check_soft): the daemon may legitimately not be started
# yet at the point this script runs (e.g. verifying host networking before
# ever starting any service), so a closed port here is not on its own a
# cluster defect.
# ─────────────────────────────────────────────────────────────────────────────
case "${THIS_ROLE}" in
    prefill|decode)
        step "LMCache MP daemon port (local, same-host rendezvous)"
        _lmcache_mp_host="${LMCACHE_MP_HOST#tcp://}"
        check_soft "LMCache MP daemon reachable at ${_lmcache_mp_host}:${LMCACHE_MP_PORT}" \
            wait_for_port "${_lmcache_mp_host}" "${LMCACHE_MP_PORT}" 3
        ;;
    *)
        step "LMCache MP daemon port (skipped: not a compute node — this is a" \
             " same-host loopback rendezvous, not something a jump host can check)"
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# RDMA fabric checks — HARD checks in KV_TRANSPORT=rdma (Phase 2), SKIPPED
# entirely in tcp mode (Phase 1). See config/cluster.env's KV_TRANSPORT
# comment and lib.sh's setup_ucx_env: rdma mode deliberately does not fall
# back to tcp, so a broken RDMA fabric must fail loudly here rather than
# silently degrading the moment vLLM actually starts.
#
# ${PEERS} above already contains exactly the cross-node peer(s) relevant
# to whichever role this host is (or all three, from a jump host) —
# TARGET_RDMA_DEV is checked the same way as PREFILL_RDMA_DEV/
# DECODE_RDMA_DEV below.
#
# MEASURED baseline (docs/HANDOFF.md §15, 2026-09-16, after the routing fix
# and firmware update): these are 400 Gb/s links (`ethtool` reports
# Speed: 400000Mb/s on all 8 ports on both nodes; NOT the 200 Gb/s this
# repo asserted before that was measured and corrected — see §15.6).
# Static routes now exist for all 8 fabric pairs (30.1.N.0/24 <->
# 30.2.N.0/24, both directions) and cross-node RC pingpong/ib_write_bw
# both work: ib_write_bw (RC, cross-node, -d ionic_2 -x 1 -F, 5000 iters)
# reached 41,898 MiB/s (~351 Gb/s, ~88% of 400G line rate) at 8 MiB
# messages. If you run a real (non-connectivity-only) ib_write_bw pair by
# hand against this baseline, treat a result well under that as suspect.
#
# HOW TO CONFIRM TRAFFIC ACTUALLY CROSSED (§15.7 — do not use rx_bytes):
# `/sys/class/net/<netdev>/statistics/rx_bytes` is USELESS for RoCE —
# RoCE bypasses the kernel netdev path entirely, so this counter barely
# moves even across a multi-GiB transfer (measured: ~1.9 KB moved during
# a 1.95 GiB transfer). `ionic`'s own `hw_counters/` under
# /sys/class/infiniband/<dev>/ports/1/ exposes only ERROR counters, no
# byte counters. The instrument that actually works is MAC-level
# `ethtool -S <netdev> | grep octets_rx_ok` READ ON THE RECEIVING NODE —
# and it LAGS by roughly 5 seconds; settling for only ~3s before reading
# it produced a false "did not cross" verdict in §15.7. This script does
# not attempt an automated crossing-proof (that requires a coordinated,
# multi-second-settled counter diff on the PEER, which is out of scope
# for a single-host connectivity check) — an operator who wants that
# proof should run ib_write_bw for real (not the 10s connectivity probe
# below) and diff `ethtool -S` octets_rx_ok on the receiver before/after,
# with a settle of several seconds after the transfer completes.
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
