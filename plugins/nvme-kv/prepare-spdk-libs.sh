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

echo "OK: split archives ready in ${LIB_DIR}"
