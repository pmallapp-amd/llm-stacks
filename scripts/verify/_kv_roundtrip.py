#!/usr/bin/env python3
"""_kv_roundtrip.py — cross-PROCESS NIXL STORE/RETRIEVE proof for the
SPDK_NVMe_KV backend. Invoked by scripts/verify/30-verify-kv-roundtrip.sh,
once per OS process (--write, then --read as a SEPARATE `python` invocation
— never imported and called twice in one interpreter), which is the whole
point: this is testing that a process that never saw the writer's memory
can independently derive the SAME on-wire key and find the SAME bytes.

WHY the payload is derived from --nonce + --size rather than passed
in-band between the two processes: LMCache's real content-derived key
(NixlDynamicStorageAgent._format_object_key(), see
scripts/common/gen-lmcache-config.sh's "THE CONTENT-DERIVED-KEY CONSTRAINT")
works precisely because BOTH the prefill process that stores a KV chunk and
the decode process that looks it up compute the identical hash from
identical input (the same model + token content) without either one telling
the other what the hash is. Mirroring that here — both --write and --read
derive metaInfo purely from (nonce, size), never from each other — is what
makes this test actually exercise cross-process key AGREEMENT rather than
just cross-process plumbing.

Multipart split: mimics LMCache's own sub-key convention documented in
plugins/nvme-kv/spdk_nvme_kv_backend.h's make_key() comment — "LMCache
names objects obj_{slot}_{uuid4}[#{part}]" — i.e. chunk `i` of a
multi-part page is stored under `f"{base_meta}#{i}"`. A --size larger than
KV_MAX_VALUE_SIZE is REQUIRED to exercise this at all; see
30-verify-kv-roundtrip.sh's --size default and comment.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
import time

NIXL_IMPORT_ERROR_PREFIX = "RESULT:IMPORT_FAIL:"


def derive_payload(nonce: str, size: int) -> bytes:
    """Deterministic pseudo-random byte stream, reproducible by ANY process
    given the same (nonce, size) — no shared state, no IPC. Built by
    chaining sha256(nonce || counter) blocks rather than e.g. seeding
    random.Random(), because the exact bit-for-bit algorithm has to be
    something we're writing here in plain sight (auditable), not delegating
    to a stdlib PRNG whose output stream length/seeding contract isn't part
    of its documented API.
    """
    out = bytearray()
    counter = 0
    while len(out) < size:
        block = hashlib.sha256(f"{nonce}:{counter}".encode()).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:size])


def base_meta_info(payload: bytes) -> str:
    return f"kvstack-selftest-{hashlib.sha256(payload).hexdigest()}"


def chunk_meta_infos(base_meta: str, num_parts: int) -> list[str]:
    if num_parts == 1:
        return [base_meta]
    return [f"{base_meta}#{i}" for i in range(num_parts)]


def find_query_callable(agent):
    """The C++ backend's queryMem() existence-probe is what NIXL's python
    bindings expose under SOME name — this repo has no confirmed-installed
    NIXL build to check the exact one against (see
    patches/lmcache/README.md's ASSUMED section), so try the plausible
    candidates in order and report which one worked rather than guessing
    silently. Returns (name, bound_method) or (None, None).
    """
    for name in ("query_memory", "query_mem", "queryMem", "query"):
        fn = getattr(agent, name, None)
        if callable(fn):
            return name, fn
    return None, None


def do_write(agent, backend, meta_infos: list[str], chunks: list[bytes]) -> None:
    import ctypes

    for meta, chunk in zip(meta_infos, chunks):
        buf = (ctypes.c_ubyte * len(chunk))(*chunk)
        addr = ctypes.addressof(buf)

        reg_descs = agent.get_reg_descs([(addr, len(chunk), 0, meta)], "DRAM")
        agent.register_memory(reg_descs, backend=backend)

        local_xfer = agent.get_xfer_descs([(addr, len(chunk), 0)], "DRAM")
        remote_xfer = agent.get_xfer_descs([(0, len(chunk), 0, meta)], "OBJ")

        handle = agent.initialize_xfer("WRITE", local_xfer, remote_xfer, "", meta.encode())
        agent.transfer(handle)
        while agent.check_xfer_state(handle) == "PROC":
            time.sleep(0.005)
        state = agent.check_xfer_state(handle)
        agent.release_xfer_handle(handle)
        agent.deregister_memory(reg_descs)
        if state not in ("DONE", "SUCCESS", 0):
            print(f"RESULT:WRITE_FAIL:{meta}:final_state={state!r}")
            sys.exit(1)
        print(f"INFO: wrote {len(chunk)} bytes under metaInfo={meta}")

    print("RESULT:OK")


def do_read(agent, backend, meta_infos: list[str], expected_chunks: list[bytes]) -> None:
    import ctypes

    qname, qfn = find_query_callable(agent)
    if qfn is None:
        print(
            "RESULT:QUERY_API_NOT_FOUND: tried query_memory/query_mem/"
            "queryMem/query — none exist on this nixl_agent build. Cannot "
            "run the existence-probe half of this test; see "
            "plugins/nvme-kv/spdk_nvme_kv_backend.h's queryMem() comment "
            "for why this call matters (its absence is what made every "
            "decode-side lookup a miss before it was added)."
        )
        sys.exit(1)
    print(f"INFO: using agent.{qname}() for the existence probe")

    for meta, expected in zip(meta_infos, expected_chunks):
        probe_descs = agent.get_reg_descs([(0, len(expected), 0, meta)], "OBJ")
        try:
            resp = qfn(probe_descs, backend)
        except TypeError:
            try:
                resp = qfn(probe_descs, backend=backend)
            except TypeError:
                resp = qfn(probe_descs)

        exists = False
        if resp:
            first = resp[0] if isinstance(resp, (list, tuple)) else resp
            exists = first is not None and first is not False

        if not exists:
            print(
                f"RESULT:QUERY_MISS:{meta}: existence probe reports this "
                "key does NOT exist on the target. Either the writer "
                "process never ran / failed silently, this reader is "
                "pointed at a DIFFERENT namespace/target than the writer "
                "(check KV_TRID matches on both sides), or "
                "KV_SLOT_OFFSET_PREFILL/KV_SLOT_OFFSET_DECODE + a "
                "metaInfo-LESS caller collided this key with something "
                "else (see scripts/target/50-reset-namespace.sh if you "
                "suspect stale cross-geometry data in the namespace)."
            )
            sys.exit(1)
        print(f"INFO: queryMem confirms key EXISTS: {meta}")

    buf = (ctypes.c_ubyte * sum(len(c) for c in expected_chunks))()
    offset = 0
    got_chunks = []
    for meta, expected in zip(meta_infos, expected_chunks):
        sub = (ctypes.c_ubyte * len(expected)).from_buffer(buf, offset)
        addr = ctypes.addressof(sub)

        reg_descs = agent.get_reg_descs([(addr, len(expected), 0, meta)], "DRAM")
        agent.register_memory(reg_descs, backend=backend)

        local_xfer = agent.get_xfer_descs([(addr, len(expected), 0)], "DRAM")
        remote_xfer = agent.get_xfer_descs([(0, len(expected), 0, meta)], "OBJ")

        handle = agent.initialize_xfer("READ", local_xfer, remote_xfer, "", meta.encode())
        agent.transfer(handle)
        while agent.check_xfer_state(handle) == "PROC":
            time.sleep(0.005)
        state = agent.check_xfer_state(handle)
        agent.release_xfer_handle(handle)

        got = bytes(sub)
        agent.deregister_memory(reg_descs)
        if state not in ("DONE", "SUCCESS", 0):
            print(f"RESULT:READ_FAIL:{meta}:final_state={state!r}")
            sys.exit(1)
        got_chunks.append(got)
        offset += len(expected)

    got_full = b"".join(got_chunks)
    expected_full = b"".join(expected_chunks)
    if got_full != expected_full:
        first_diff = next(
            (i for i in range(len(expected_full)) if got_full[i] != expected_full[i]),
            None,
        )
        print(
            f"RESULT:MISMATCH: read back {len(got_full)} bytes, expected "
            f"{len(expected_full)} bytes, first differing byte at offset "
            f"{first_diff!r}. THIS IS THE SILENT-CORRUPTION SIGNATURE "
            "described in plugins/nvme-kv/spdk_nvme_kv_backend.h's "
            "make_key() comment: two deployments (or two split geometries "
            "of the SAME deployment) sharing a key space produced a "
            "collision. Check KV_SLOT_OFFSET_PREFILL/KV_SLOT_OFFSET_DECODE "
            "are disjoint, and if KV_MAX_VALUE_SIZE was ever changed on "
            "this namespace, drain it first: "
            "scripts/target/50-reset-namespace.sh."
        )
        sys.exit(1)

    print("RESULT:OK")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", required=True, choices=("write", "read"))
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--size", type=int, required=True)
    ap.add_argument("--max-value-size", type=int, required=True)
    ap.add_argument("--trid", default=None,
                     help="SPDK_NVMe_KV connect param — required when "
                          "--backend=SPDK_NVMe_KV, ignored otherwise.")
    ap.add_argument("--dev-uri", default=None,
                     help="XNVME_KV connect param (e.g. /dev/ng1n1) — "
                          "required when --backend=XNVME_KV, ignored "
                          "otherwise. See plugins/xnvme-kv/xnvme_kv_plugin.cpp's "
                          "getParams(): this backend has no trid concept at all.")
    ap.add_argument("--backend", default="SPDK_NVMe_KV")
    args = ap.parse_args()

    # Backend-appropriate create_backend() params. Deliberately NOT a single
    # {"trid": args.trid} dict for every backend — XNVME_KV's getParams()
    # advertises {dev_uri, max_value_size} only (no trid, no kv_slot_offset;
    # confirmed by reading xnvme_kv_backend.cpp/.h end to end), so handing it
    # a trid would just be an ignored, misleading extra key at best and a
    # rejected/unexpected param at worst.
    if args.backend == "XNVME_KV":
        if not args.dev_uri:
            print("RESULT:MISSING_ARG:--dev-uri is required when --backend=XNVME_KV")
            return 1
        backend_params = {"dev_uri": args.dev_uri}
    else:
        if not args.trid:
            print("RESULT:MISSING_ARG:--trid is required when "
                  f"--backend={args.backend}")
            return 1
        backend_params = {"trid": args.trid}

    try:
        from nixl._api import nixl_agent, nixl_agent_config
    except Exception as exc:  # noqa: BLE001
        print(f"{NIXL_IMPORT_ERROR_PREFIX}{type(exc).__name__}: {exc}")
        return 1

    payload = derive_payload(args.nonce, args.size)
    base_meta = base_meta_info(payload)
    num_parts = max(1, (args.size + args.max_value_size - 1) // args.max_value_size)
    metas = chunk_meta_infos(base_meta, num_parts)

    chunks = []
    off = 0
    for i in range(num_parts):
        part_len = min(args.max_value_size, args.size - off)
        chunks.append(payload[off:off + part_len])
        off += part_len

    print(f"INFO: mode={args.mode} size={args.size} max_value_size={args.max_value_size} "
          f"num_parts={num_parts} base_meta={base_meta}")

    agent = nixl_agent(f"kvstack-verify-30-{args.mode}",
                        nixl_agent_config(backends=[args.backend]))
    try:
        agent.create_backend(args.backend, backend_params)
    except Exception as exc:  # noqa: BLE001
        print(f"RESULT:CREATE_BACKEND_FAIL:{type(exc).__name__}: {exc}")
        return 1

    try:
        if args.mode == "write":
            do_write(agent, args.backend, metas, chunks)
        else:
            do_read(agent, args.backend, metas, chunks)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"RESULT:UNEXPECTED_EXCEPTION:{type(exc).__name__}: {exc}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
