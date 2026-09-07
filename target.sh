#!/usr/bin/env bash
# start-kv-target.sh — launch spdk_tgt with a bdev_kvmalloc KV namespace.
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

# max_io_size/io_unit_size: nvmf_tcp_create() rejects any max_io_size where
# max_io_size/large_bufsize (iobuf default 132KB) exceeds SPDK_NVMF_MAX_SGL_ENTRIES
# (16) — i.e. anything much above ~2MB fails outright ("Unsupported max_io_size
# specified"). 1MB is comfortably under that cap and well above the largest
# block size this repo's benchmarks actually exercise (<=32KB); it does NOT
# limit bdev_kvmalloc's own max_value_size below, which governs the largest
# single KV value the store will accept.
SPDK_CONFIG_JSON=$(mktemp /tmp/spdk-kv-config.XXXXXX.json)
cat > "${SPDK_CONFIG_JSON}" <<EOF
{
  "subsystems": [
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
          "params": { "trtype": "TCP", "max_io_size": 1048576, "io_unit_size": 1048576 }
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
    -s 1024 \
    -m 0x1
