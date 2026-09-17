#!/usr/bin/env python3
"""_kv_roundtrip.py — cross-PROCESS NIXL STORE/RETRIEVE proof for whichever
storage backend KV_BACKEND selects (SPDK_NVMe_KV against SMC3's NVMe-oF
target, or XNVME_KV against a LOCAL Pensando DSC char device — see
config/cluster.env's KV_BACKEND comment). Invoked by
scripts/verify/30-verify-kv-roundtrip.sh, once per OS process (--write,
then --read as a SEPARATE `python` invocation — never imported and called
twice in one interpreter), which is the whole point: this is testing that
a process that never saw the writer's memory can independently derive the
SAME on-wire key and find the SAME bytes.

WHY the payload is derived from --nonce + --size rather than passed
in-band between the two processes: LMCache's real content-derived key
(NixlDynamicStorageAgent._format_object_key(), see
scripts/common/start-lmcache-daemon.sh's "THE CONTENT-DERIVED-KEY CONSTRAINT"
and, for the XNVME_KV-specific key-derivation detail,
tmp/TOPOLOGY-KV-DATAPATH.md §4.3's "Two key namespaces" section) works
precisely because BOTH the prefill process that stores a KV chunk and the
decode process that looks it up compute the identical hash from identical
input (the same model + token content) without either one telling the
other what the hash is. Mirroring that here — both --write and --read
derive metaInfo purely from (nonce, size), never from each other — is what
makes this test actually exercise cross-process key AGREEMENT rather than
just cross-process plumbing.

Multipart split: mimics LMCache's own sub-key convention documented in
plugins/nvme-kv/spdk_nvme_kv_backend.h's make_key() comment (and, for
XNVME_KV, tmp/TOPOLOGY-KV-DATAPATH.md §4.5's "`mem_split_n` — and the
`#{j}` landmine") — "LMCache names objects obj_{slot}_{uuid4}[#{part}]",
i.e. chunk `i` of a multi-part page is stored under `f"{base_meta}#{i}"`.
That suffix is LOAD-BEARING for XNVME_KV specifically, which keys off
metaInfo and ignores addr/offset entirely: drop the suffix and every
sub-part after the first silently overwrites the one before it, with no
error at any layer. A --size larger than KV_MAX_VALUE_SIZE_EFFECTIVE is
REQUIRED to exercise this split path at all — see
30-verify-kv-roundtrip.sh's --size default and comment, and this file's
own do_read() byte-compare, which is the only thing that would ever catch
a collapsed suffix (or, on SPDK_NVMe_KV, an off-by-one in the split
boundary arithmetic).
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
    """query_memory() is now CONFIRMED (introspected 2026-09-15 against a
    live nixl_agent, not guessed) as the one and only name NIXL's python
    bindings expose for the C++ backend's queryMem() existence-probe —
    query_mem/queryMem/query never existed. The lookup is kept as a
    hasattr() guard rather than a bare `agent.query_memory` reference
    purely so an agent build that genuinely lacks the method (e.g. an
    older nixl wheel) fails with our own clear RESULT:QUERY_API_NOT_FOUND
    instead of an AttributeError with no context. Returns the bound
    method, or None.
    """
    fn = getattr(agent, "query_memory", None)
    return fn if callable(fn) else None


def wait_for_xfer(agent, handle) -> tuple[bool, str]:
    """Poll a transfer to completion and report success/failure.

    check_xfer_state() cannot actually return the string "ERR" in
    practice, despite its own source appearing to have an `else: return
    "ERR"` branch: its underlying binding — getXferStatus() in
    nixl_bindings.cpp — calls throw_nixl_exception(ret) UNCONDITIONALLY,
    and throw_nixl_exception() only special-cases NIXL_IN_PROG and
    NIXL_SUCCESS as non-throwing; every OTHER status (NIXL_ERR_BACKEND,
    NIXL_ERR_NOT_FOUND, ...) raises a TYPED python exception instead,
    which happens before nixl_agent.check_xfer_state()'s own if/elif/else
    ever gets a chance to run. A caller that only ever compared the
    return value against the string "ERR" (an earlier version of this
    script did exactly that, and it looked reasonable — the string is
    right there in the binding's source) would NEVER catch a genuine
    failure this way; it would see an uncaught exception instead.
    Measured 2026-09-15: reading a key that was never written raises
    nixlBackendError, not a returned "ERR" string.

    Returns (True, "DONE") on success, (False, "<ExceptionClass>: <msg>")
    on any failure — the CALLER decides what the failure means (a
    genuine transport error vs. this backend's only available
    existence-miss signal; see do_read()'s retrieve-as-probe fallback).
    """
    try:
        while agent.check_xfer_state(handle) == "PROC":
            time.sleep(0.005)
        return True, "DONE"
    except Exception as exc:  # noqa: BLE001 — deliberately broad, see docstring
        return False, f"{type(exc).__name__}: {exc}"


def do_write(agent, backend, meta_infos: list[str], chunks: list[bytes]) -> None:
    import ctypes

    for meta, chunk in zip(meta_infos, chunks):
        buf = (ctypes.c_ubyte * len(chunk))(*chunk)
        addr = ctypes.addressof(buf)

        # register_memory()'s param is `backends` (a LIST), not `backend` — the
        # SINGULAR-keyword call raises TypeError: unexpected keyword argument
        # 'backend' (measured 2026-09-15 against a live nixl_agent). NIXL lets
        # one registration cover several backends at once, hence the list
        # shape even though this script only ever has exactly one.
        #
        # register_memory() ALSO builds the reg-desc list itself when handed
        # raw tuples (it calls get_reg_descs() internally — confirmed by
        # reading nixl._api.nixl_agent.register_memory()'s source on the live
        # container), so there is no separate get_reg_descs() call needed
        # here; the DRAM metaInfo ("") is unused by this backend's DRAM_SEG
        # registerMem() branch (a bare pointer-store — see
        # xnvme_kv_backend.cpp's registerMem(), DRAM_SEG case), so it is
        # left empty on purpose — the OBJ registration below is where
        # metaInfo actually matters.
        local_reg = agent.register_memory([(addr, len(chunk), 0, "")], "DRAM",
                                           backends=[backend])

        # THIS registration is the one that matters: metaInfo=meta here IS
        # the on-wire KV key. xnvme_kv_backend.cpp's registerMem() OBJ_SEG
        # branch stashes mem.metaInfo into the backend's per-region metadata,
        # and postXfer() later derives make_key() from
        # file_desc.metadataP->meta_info — i.e. the key is carried entirely
        # by this registration, not by anything in the xfer descriptor
        # itself. addr=0/devId=0 are placeholders: an object has no memory
        # address of its own.
        obj_reg = agent.register_memory([(0, len(chunk), 0, meta)], "OBJ",
                                         backends=[backend])

        # .trim() converts a REG desc list (4-tuple, carries metaInfo) into
        # the XFER desc list shape (3-tuple) that initialize_xfer() actually
        # requires. Building the remote xfer descs directly via
        # get_xfer_descs([(0, len(chunk), 0, meta)], "OBJ") — a 4-tuple — was
        # the FIRST thing tried here and fails: NIXL logs "3-tuple list
        # needed for transfer" and silently returns None, which then blows up
        # inside createXferReq() with remote_descs=None (measured 2026-09-15).
        # .trim() is how NIXL's own storage examples do it
        # (examples/python/remote_storage_example: `nixl_file_reg_descs.trim()`)
        # — NIXL keeps the addr/len/devId -> metaInfo association from the
        # registration internally and hands the matching metadata back to
        # the backend at transfer time (see postXfer()'s
        # file_desc.metadataP), which is also why this MUST be the same
        # reg_descs object that was just registered, not a freshly built one.
        local_xfer = local_reg.trim()
        remote_xfer = obj_reg.trim()

        # remote_agent=agent.name (SELF), not "" — this is a LOCAL transfer
        # (no second nixl_agent peer in this test; the "remote" side is the
        # KV device attached directly to THIS backend). remote_agent=""
        # was the FIRST thing tried here and fails: "createXferReq: metadata
        # for remote agent '' not found" / NIXL_ERR_NOT_FOUND (measured
        # 2026-09-15) — NIXL resolves remote_agent by name lookup against
        # its own metadata table, and only the agent's OWN name is
        # pre-populated there without an explicit add_remote_agent() call.
        # This matches NIXL's own local-storage-transfer examples
        # (examples/python/remote_storage_example: `my_agent.name` as
        # remote_name for a same-host storage transfer). backends=[backend]
        # pins which backend actually executes it, same as
        # register/deregister_memory above. notif_msg is left at its b''
        # default — passing meta.encode() there was the SECOND thing tried
        # and fails: "the selected backend 'XNVME_KV' does not support
        # notifications" / NIXL_ERR_BACKEND (measured 2026-09-15; matches
        # HANDOFF.md §6's note that this backend declines supportsRemote()).
        # The key is already fully carried by the OBJ registration's
        # metaInfo above — a notification was never needed to convey it.
        handle = agent.initialize_xfer("WRITE", local_xfer, remote_xfer,
                                        agent.name, backends=[backend])
        agent.transfer(handle)
        ok, detail = wait_for_xfer(agent, handle)
        agent.release_xfer_handle(handle)
        agent.deregister_memory(local_reg, backends=[backend])
        agent.deregister_memory(obj_reg, backends=[backend])
        if not ok:
            print(f"RESULT:WRITE_FAIL:{meta}:{detail}")
            sys.exit(1)
        print(f"INFO: wrote {len(chunk)} bytes under metaInfo={meta}")

    print("RESULT:OK")


def do_read(agent, backend, meta_infos: list[str], expected_chunks: list[bytes]) -> None:
    import ctypes

    from nixl._bindings import nixlNotSupportedError

    qfn = find_query_callable(agent)
    if qfn is None:
        print(
            "RESULT:QUERY_API_NOT_FOUND: agent.query_memory does not exist "
            "on this nixl_agent build. Cannot run the existence-probe half "
            "of this test; see plugins/xnvme-kv/xnvme_kv_backend.cpp's "
            "queryMem() comment for why this call matters (its absence is "
            "what made every decode-side lookup a miss before it was "
            "added)."
        )
        sys.exit(1)

    # Whether query_memory() is actually USABLE against the .so this process
    # loaded — a DIFFERENT question from whether the python method exists
    # (just checked above). MEASURED 2026-09-15: calling it against
    # KV_BACKEND=XNVME_KV raises nixlNotSupportedError (NIXL_ERR_NOT_
    # SUPPORTED). `nm -D --defined-only` on the exact .so this container
    # loads (/opt/nixl/lib/x86_64-linux-gnu/plugins/libplugin_XNVME_KV.so,
    # md5 confirmed identical to /tmp/xnvme-kv-build/'s copy, built
    # 2026-09-09) shows ONLY the weak `nixlBackendEngine::queryMem` base-
    # class symbol — NOT `nixlXnvmeKvEngine::queryMem`, even though this
    # repo's plugins/xnvme-kv/xnvme_kv_backend.cpp (~line 694) DOES define
    # that override. Conclusion, established by testing rather than assumed:
    # this specific prebuilt binary predates the queryMem() override — a
    # STALE-ARTIFACT gap, not "NIXL's python binding lacks this" and not
    # "this backend architecturally cannot support existence probes" (the
    # source clearly can). The constraint here is: do NOT weaken this check
    # to make it pass — so on NOT_SUPPORTED we degrade EXPLICITLY, visibly,
    # once, and fall back to treating the RETRIEVE itself as the existence
    # proof (a transfer that fails below is reported as a miss; one that
    # succeeds proves both existence and content in a single step) rather
    # than silently skipping the check.
    query_supported = True

    for meta, expected in zip(meta_infos, expected_chunks):
        if not query_supported:
            continue
        probe_descs = agent.get_reg_descs([(0, len(expected), 0, meta)], "OBJ")
        try:
            resp = qfn(probe_descs, backend)
        except nixlNotSupportedError:
            query_supported = False
            print(
                "INFO: agent.query_memory() raised NIXL_ERR_NOT_SUPPORTED "
                f"for backend={backend} — see do_read()'s comment for what "
                "was measured (nm -D on the loaded .so). Degrading to "
                "retrieve-as-probe for this and all remaining chunks; a "
                "RESULT:QUERY_MISS below now means 'the retrieve transfer "
                "itself failed', not 'a separate existence probe reported "
                "absent'."
            )
            continue

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
                "(check KV_TRID matches on both sides for SPDK_NVMe_KV, or "
                "XNVME_DEV/--dev-uri matches on both sides for XNVME_KV — "
                "note /dev/ng1n1 is a DSC-presented namespace, not "
                "necessarily a node-local one: whether writer and reader "
                "actually share it depends on whether both DSCs are backed "
                "by the SAME target namespace, not on which host each "
                "process runs on. Verify with `nvme ns-descs /dev/ng1n1 -n "
                "1` on BOTH hosts and compare the `eui64` field — matching "
                "eui64 means the SAME namespace (writer and reader should "
                "see each other's keys), a differing eui64 means genuinely "
                "separate namespaces), or "
                "KV_SLOT_OFFSET_PREFILL/KV_SLOT_OFFSET_DECODE + a "
                "metaInfo-LESS caller collided this key with something "
                "else (see scripts/target/50-reset-namespace.sh if you "
                "suspect stale cross-geometry data in the namespace)."
            )
            sys.exit(1)
        print(f"INFO: query_memory confirms key EXISTS: {meta}")

    buf = (ctypes.c_ubyte * sum(len(c) for c in expected_chunks))()
    offset = 0
    got_chunks = []
    for meta, expected in zip(meta_infos, expected_chunks):
        sub = (ctypes.c_ubyte * len(expected)).from_buffer(buf, offset)
        addr = ctypes.addressof(sub)

        # Same register_memory()/`.trim()` shape as do_write() — see its
        # comments for why: raw-tuple register_memory(mem_type=...) builds
        # the reg descs itself, the OBJ registration's metaInfo IS the key,
        # and .trim() (not get_xfer_descs() on a hand-built 4-tuple) is what
        # produces a valid xfer desc list from it.
        local_reg = agent.register_memory([(addr, len(expected), 0, "")], "DRAM",
                                           backends=[backend])
        obj_reg = agent.register_memory([(0, len(expected), 0, meta)], "OBJ",
                                         backends=[backend])
        local_xfer = local_reg.trim()
        remote_xfer = obj_reg.trim()

        # remote_agent=agent.name — see do_write()'s comment; "" raises
        # NIXL_ERR_NOT_FOUND. notif_msg left at its b'' default — see
        # do_write()'s comment; XNVME_KV does not support notifications.
        handle = agent.initialize_xfer("READ", local_xfer, remote_xfer,
                                        agent.name, backends=[backend])
        agent.transfer(handle)
        ok, detail = wait_for_xfer(agent, handle)
        agent.release_xfer_handle(handle)

        got = bytes(sub)
        agent.deregister_memory(local_reg, backends=[backend])
        agent.deregister_memory(obj_reg, backends=[backend])
        if not ok:
            if not query_supported:
                # The retrieve-as-probe fallback path: a failed transfer
                # here IS the existence-miss signal (see this function's
                # opening comment and wait_for_xfer()'s docstring for why
                # this arrives as a raised exception, not a returned "ERR"
                # string), so report it as a miss, not a generic transport
                # failure — the two have different remedies.
                print(
                    f"RESULT:QUERY_MISS:{meta}: retrieve-as-probe fallback "
                    "(query_memory unsupported by this build — see this "
                    f"function's comment) reports this key does NOT exist "
                    f"on the target; transfer failure was {detail}. Same "
                    "causes as a genuine QUERY_MISS — see that message "
                    "elsewhere in this file for the list."
                )
            else:
                print(f"RESULT:READ_FAIL:{meta}:{detail}")
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
            "make_key() comment (and, for XNVME_KV, "
            "tmp/TOPOLOGY-KV-DATAPATH.md §4.5's `#{j}` landmine): two "
            "deployments (or two split geometries of the SAME deployment) "
            "sharing a key space produced a collision — for XNVME_KV "
            "specifically this means the multipart split's `#{j}` suffix "
            "collapsed, since that backend keys purely off metaInfo and "
            "ignores addr/offset, so later sub-parts silently overwrite "
            "earlier ones with no error at any layer. Check "
            "KV_SLOT_OFFSET_PREFILL/KV_SLOT_OFFSET_DECODE are disjoint "
            "(SPDK_NVMe_KV), and if KV_MAX_VALUE_SIZE/"
            "KV_MAX_VALUE_SIZE_EFFECTIVE was ever changed on this "
            "namespace/device, drain or reformat it first: "
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

    # backends=[] on PURPOSE. nixl_agent_config(backends=[X]) makes the agent
    # instantiate X itself, during construction, with DEFAULT parameters — and
    # then create_backend(X, params) below fails with
    #   createBackend: backend already created for type 'X'
    #   NIXL_ERR_INVALID_PARAM
    # (measured 2026-09-15 against XNVME_KV). The failure is the harmless half
    # of the problem. The dangerous half is that the backend which DID get
    # built never saw backend_params: no dev_uri, no trid. For XNVME_KV that
    # means it fell back to the plugin's own /dev autodiscovery, which on the
    # decode host selects a LOCAL Pensando DSC KV controller rather than the
    # NVMe-oF target (see resolve_xnvme_kv_dev() in scripts/common/lib.sh).
    # A test that passed that way would be proving the wrong device works.
    # So: construct the agent with NO backends, then create exactly one,
    # explicitly, with our parameters.
    agent = nixl_agent(f"kvstack-verify-30-{args.mode}",
                        nixl_agent_config(backends=[]))
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
