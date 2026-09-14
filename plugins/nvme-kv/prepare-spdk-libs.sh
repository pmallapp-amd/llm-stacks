#!/usr/bin/env bash
# prepare-spdk-libs.sh — generate the "_only" split static archives that
# meson.build links against but a stock SPDK build does not produce.
#
# nixl-spdk-nvme-kv-plugin needs the TCP/PCIe transport + POSIX sock modules
# isolated into their own archives so they can be forced in with
# --whole-archive (for self-registration constructors) without pulling in
# every object in libspdk_nvme.a / libspdk_sock_posix.a.
#
# Idempotent: skips any archive that already exists.
#
#   SPDK_SRC=<path>   pre-built SPDK root (default: /root/spdk-kv or /root/kv_spdk)
set -euo pipefail

SPDK_SRC=${SPDK_SRC:-}
if [ -z "${SPDK_SRC}" ]; then
    if [ -f /root/spdk-kv/build/lib/libspdk_nvme.a ]; then
        SPDK_SRC=/root/spdk-kv
    elif [ -f /root/kv_spdk/build/lib/libspdk_nvme.a ]; then
        SPDK_SRC=/root/kv_spdk
    fi
fi

[ -n "${SPDK_SRC}" ] && [ -f "${SPDK_SRC}/build/lib/libspdk_nvme.a" ] || {
    echo "ERR: pre-built SPDK not found (set SPDK_SRC=<path>)"; exit 1; }

LIB_DIR="${SPDK_SRC}/build/lib"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

make_split() {
    local out=$1 src_a=$2; shift 2
    local objs=("$@")
    [ -f "${LIB_DIR}/${out}" ] && { echo "  ${out} — already present"; return; }
    echo "  ${out} <- ${src_a} (${objs[*]})"
    ( cd "${WORK}" && ar x "${LIB_DIR}/${src_a}" "${objs[@]}" && ar rcs "${LIB_DIR}/${out}" "${objs[@]}" && rm -f "${objs[@]}" )
}

echo "SPDK split archives in ${LIB_DIR}:"
make_split libspdk_nvme_tcp_only.a   libspdk_nvme.a       nvme_tcp.o nvme_transport.o
make_split libspdk_nvme_pcie_only.a  libspdk_nvme.a       nvme_pcie.o nvme_pcie_common.o
make_split libspdk_sock_posix_only.a libspdk_sock_posix.a posix.o

# libspdk_nvme_rdma_only.a — Phase 2 (RDMA) prerequisite. nvme_rdma.o only
# exists inside libspdk_nvme.a if this tree was configured --with-rdma
# (F4); a TCP-only tree (the common case, SPDK_WITH_RDMA=0) simply does not
# have it. Detect with `ar t` FIRST and skip cleanly rather than letting
# make_split's `ar x` fail on a name that isn't in the archive — this must
# be a no-op on a TCP-only build, not a script failure.
# Building this archive alone does not enable RDMA in the plugin: see
# plugins/nvme-kv/meson.build's -Denable_rdma option, which must ALSO add
# this archive to the --whole-archive group plus -lrdmacm -libverbs before
# an RDMA-linked plugin actually works.
if ar t "${LIB_DIR}/libspdk_nvme.a" 2>/dev/null | grep -q '^nvme_rdma\.o$'; then
    make_split libspdk_nvme_rdma_only.a libspdk_nvme.a nvme_rdma.o
else
    echo "  libspdk_nvme_rdma_only.a — skipped (nvme_rdma.o not in" \
         " libspdk_nvme.a; this tree was not configured --with-rdma)"
fi

echo "OK: split archives ready in ${LIB_DIR}"
