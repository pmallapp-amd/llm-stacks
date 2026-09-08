#!/usr/bin/env bash
# target.sh — launch spdk_tgt with a bdev_kvmalloc KV namespace.
# Uses the pre-built spdk_tgt from kv_spdk — no source changes.
#
# The bdev_kvmalloc device is an in-memory NVMe-KV store (no hardware needed).
# Exposes it via NVMe-oF TCP on LISTEN_ADDR:4420 so the Docker container
# running 05-nvme-kv-floor.sh can connect via --network host.
#
#   SPDK_SRC=/root/kv_spdk    kv_spdk root with pre-built spdk_tgt
#   HUGE_PAGES=256            2MB huge pages (0 = skip, use malloc fallback)
#   LISTEN_ADDR=127.0.0.1     NVMe-oF TCP bind address (default: loopback-only).
#                             Set to a real routable IP to serve initiators on
#                             other hosts (e.g. a 3-node storage+prefill+decode
#                             layout) instead of just the local machine.
set -euo pipefail

HUGE_PAGES=${HUGE_PAGES:-0}
LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}

# SPDK_SRC resolution: prefer clean v26.05+KV build, fall back to kv_spdk
SPDK_SRC=${SPDK_SRC:-}
if [ -z "${SPDK_SRC}" ]; then
    [ -x /root/spdk-clean/build/bin/nvmf_tgt ] && SPDK_SRC=/root/spdk-clean
    [ -z "${SPDK_SRC}" ] && [ -x /root/kv_spdk/build/bin/nvmf_tgt ] && SPDK_SRC=/root/kv_spdk
fi

SPDK_TGT="${SPDK_SRC}/build/bin/nvmf_tgt"
[ -x "${SPDK_TGT}" ] || {
    echo "ERR: nvmf_tgt not found"
    echo "     Build SPDK: cd /root/spdk-clean && ./configure && make"
    echo "     (patches in patches/spdk-host/ — apply with git am)"
    exit 1
}

# max_io_qpairs_per_ctrlr: NOTE the exact key. SPDK v26.05 reports this field
# as "max_io_qpairs_per_ctrlr" and silently IGNORES the older spelling
# "max_qpairs_per_ctrlr" — no error, the RPC succeeds, and the default 127
# stays in force. Always confirm with:
#     rpc.py nvmf_get_transports | grep max_io_qpairs_per_ctrlr
#
# SPDK's default is 127 io qpairs, and ONE SPDK_NVMe_KV plugin
# instance opens all 128 on its single controller. That is fine for a
# single-node deploy, but it makes P+D IMPOSSIBLE against a shared target:
# whichever role connects first takes the entire budget, and the second one's
# I/O queue is refused. The observable symptom is NOT an out-of-resources
# message — it is
#     nvme_qpair.c: *ERROR*: [...,qid:1,...,DISCONNECTED] CQ transport error -6
#     nixl_agent.cpp: getXferStatus: backend 'SPDK_NVMe_KV' NIXL_ERR_BACKEND
# on the client, while LMCache still logs "Stored N out of N tokens" and the
# HTTP request returns 200. Zero bytes reach the device. Confirmed 2026-09-07
# with nvmf_subsystem_get_controllers reporting a single controller holding
# num_io_qpairs=128. 512 leaves room for both P/D roles plus headroom.
#
# max_io_size/io_unit_size/large_bufsize: these three are coupled.
# nvmf_tcp_create() rejects any max_io_size where max_io_size/large_bufsize
# exceeds SPDK_NVMF_MAX_SGL_ENTRIES (16). With iobuf's DEFAULT large_bufsize of
# 132KB that caps max_io_size at ~2MB — which is why large_bufsize is raised to
# 1MB in the iobuf block above, lifting the ceiling to 16 x 1MB = 16MB.
#
# 1MB was the previous value here, chosen on the assumption that the largest
# block these benchmarks exercise is <=32KB. THAT ASSUMPTION IS WRONG for the
# in-process LMCache path, which stores one NIXL object per KV *chunk*, not per
# block. TinyLlama at chunk_size=256 sends
#     22 layers x 2 x 256 tokens x 4 kv-heads x 64 head-dim x 2 bytes = 5.5MB
# in a single write. The target rejected it with
#     tcp.c:2713:nvmf_tcp_req_parse_sgl: *ERROR*:
#         SGL length 0x580000 exceeds max io size 0x100000
# then let the qpair sit until the 30s no-pdu timeout fired and dropped it. The
# CLIENT sees only "CQ transport error -6" + NIXL_ERR_BACKEND, while LMCache
# logs a successful "Stored N out of N tokens" — the silent zero-byte store this
# README warns about. Diagnosed 2026-09-07; the target-side log is the only
# place the real reason appears.
#
# SCALING WARNING: this value must exceed one chunk for YOUR model. It grows
# with layers x kv-heads x head-dim, so a large model can blow past even 16MB
# (Qwen2.5-72B at chunk_size=256 needs ~80MB) and would also exceed
# bdev_kvmalloc's max_value_size below. Recompute both before changing model.
#
# max_io_size does NOT limit bdev_kvmalloc's own max_value_size, which
# separately governs the largest single KV value the store will accept.
SPDK_CONFIG_JSON=$(mktemp /tmp/spdk-kv-config.XXXXXX.json)
cat > "${SPDK_CONFIG_JSON}" <<EOF
{
  "subsystems": [
    {
      "subsystem": "iobuf",
      "config": [
        {
          "method": "iobuf_set_options",
          "params": {
            "small_pool_count": 16384,
            "large_pool_count": 1024,
            "small_bufsize": 8192,
            "large_bufsize": 1048576
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
            "name": "KvMalloc0",
            "max_key_size": 16,
            "max_value_size": 67108864
          }
        }
      ]
    },
    {
      "subsystem": "nvmf",
      "config": [
        {
          "method": "nvmf_create_transport",
          "params": { "trtype": "TCP", "max_io_size": 16777216, "io_unit_size": 1048576,
                      "max_io_qpairs_per_ctrlr": 512 }
        },
        {
          "method": "nvmf_create_subsystem",
          "params": {
            "nqn": "nqn.2024-01.io.nixl:kv0",
            "allow_any_host": true,
            "serial_number": "NIXLKV00001",
            "model_number": "NIXL KV NullDev"
          }
        },
        {
          "method": "nvmf_subsystem_add_ns",
          "params": {
            "nqn": "nqn.2024-01.io.nixl:kv0",
            "namespace": { "bdev_name": "KvMalloc0", "nsid": 1 }
          }
        },
        {
          "method": "nvmf_subsystem_add_listener",
          "params": {
            "nqn": "nqn.2024-01.io.nixl:kv0",
            "listen_address": {
              "trtype": "TCP",
              "adrfam": "IPv4",
              "traddr": "${LISTEN_ADDR}",
              "trsvcid": "4420"
            }
          }
        }
      ]
    }
  ]
}
EOF

trap "rm -f ${SPDK_CONFIG_JSON}" EXIT

if [ "${HUGE_PAGES}" -gt 0 ]; then
    echo "Allocating ${HUGE_PAGES} × 2MB huge pages..."
    echo "${HUGE_PAGES}" > /proc/sys/vm/nr_hugepages 2>/dev/null || \
        echo "  (could not set huge pages — will fall back to malloc)"
fi

echo "Starting spdk_tgt (pre-built from kv_spdk, no source modifications)"
echo "  binary     : ${SPDK_TGT}"
echo "  NVMe-oF TCP: ${LISTEN_ADDR}:4420"
echo "  NQN        : nqn.2024-01.io.nixl:kv0"
echo "  KV device  : KvMalloc0 (in-memory, 65536 keys × 64 MB values)"
echo ""
echo "  Press Ctrl-C to stop."

LD_LIBRARY_PATH="${SPDK_SRC}/dpdk/build/lib:${LD_LIBRARY_PATH:-}" \
    "${SPDK_TGT}" \
    --json "${SPDK_CONFIG_JSON}" \
    --no-huge \
    -s 4096 \
    -m 0x1
