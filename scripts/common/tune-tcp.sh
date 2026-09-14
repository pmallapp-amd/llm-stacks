#!/usr/bin/env bash
# tune-tcp.sh — TCP/network sysctl tuning shared by every node in the cluster.
#
# Node:          any (SMC1 prefill, SMC2 decode, SMC3 target)
# Prerequisites: root
# Next step:     called from scripts/prefill/01-host-prep.sh,
#                scripts/decode/01-host-prep.sh, and the target's equivalent.
#                Not meant to be run standalone, but safe to (idempotent).
#
# WHY this exists as a single shared script rather than copy-pasted sysctls:
# both legs of the datapath in Phase 1 (KV_TRANSPORT=tcp) run over plain TCP —
# NVMe-oF/TCP to SMC3 and UCX's "tcp,self,sm" transport between SMC1/SMC2 —
# and both are large-payload, high-fan-out flows (a ~5.7MB KV page split into
# <=512KiB sub-transfers, times however many concurrent requests the batching
# scheduler admits). Default Linux TCP buffer/backlog sizing is tuned for many
# small short-lived connections, not a handful of always-open, high-bandwidth
# streams; under-sized buffers show up as throughput far below line rate with
# no error anywhere (TCP window is just never allowed to grow), which is a lot
# harder to diagnose than an outright failure.
#
# Idempotent: every value is applied with `sysctl -w` (safe to re-run) AND
# written to a drop-in file so it survives reboot; the drop-in is fully
# overwritten each run rather than appended-to, so re-running never duplicates
# lines or leaves a stale value behind from an earlier version of this script.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root

SYSCTL_FILE="/etc/sysctl.d/99-kvstack-tcp.conf"

step "TCP/network tuning -> ${SYSCTL_FILE}"

# rmem/wmem max: default 212992 bytes caps a single TCP socket's window well
# below what's needed to keep a 25/100GbE-class link full over any real RTT
# (BDP at 100Gbps/200us is ~2.5MB). autotuning (tcp_rmem/tcp_wmem 3rd value)
# is what actually governs a given connection's ceiling; core.rmem/wmem_max
# is the hard ceiling autotuning is allowed to grow into, and setsockopt()
# callers (SPDK's sock_posix, UCX's tcp transport) can request up to it
# explicitly. Left too low, both silently cap out with no error, just
# lower-than-expected throughput.
cat > "${SYSCTL_FILE}" <<'EOF'
# Managed by scripts/common/tune-tcp.sh — do not hand-edit, re-run the script.

# Socket buffer ceilings (bytes). See tune-tcp.sh for the BDP math.
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216

# TCP autotuning ranges: min, default, max (bytes). The max entry must not
# exceed net.core.*mem_max above or the kernel silently clamps it.
net.ipv4.tcp_rmem = 4096 87380 268435456
net.ipv4.tcp_wmem = 4096 65536 268435456

# NIC ring/qdisc backlog. Default (1000) drops bursts from a single large
# NVMe-oF/TCP PDU landing faster than the socket layer drains it — visible as
# `netstat -s` TCPBacklogDrop, not as anything SPDK or UCX report themselves.
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096

# Don't reset cwnd back to slow-start after an idle period. The prefill<->decode
# UCX side channel and the NVMe-oF/TCP qpairs are bursty (batch-of-requests,
# then idle between batches) — without this, every burst re-pays slow-start
# instead of reusing the previously-discovered window.
net.ipv4.tcp_slow_start_after_idle = 0

# Selective ACK + timestamps: required for the kernel to recover a large
# window efficiently after any loss. Both are default-on on any kernel this
# stack targets, set explicitly so a hardened base image can't have disabled
# them without this script re-asserting the assumption.
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# Wide ephemeral port range: NVMe-oF/TCP (KV_NUM_QPAIRS qpairs per initiator)
# and UCX (one connection per active transfer) both open many outbound
# connections to a small number of peers; the default range (32768-60999,
# ~28k ports) is more than enough at our scale but this leaves headroom for
# running verify/bench tooling alongside the live services without exhausting
# it.
net.ipv4.ip_local_port_range = 16384 65535

# Allow TIME_WAIT socket reuse for outbound connections. Repeated short-lived
# probe connections (health checks, wait_for_port from every script in this
# repo) would otherwise slowly exhaust the ephemeral range under heavy
# start/stop cycling during bring-up.
net.ipv4.tcp_tw_reuse = 1
EOF

sysctl -p "${SYSCTL_FILE}" >/dev/null
ok "sysctl values applied and persisted to ${SYSCTL_FILE}"

# MTU is NOT set here: it's per-interface and the caller (01-host-prep.sh)
# knows which interface carries which leg of the datapath. This script only
# owns host-wide (net.core/net.ipv4) knobs.
