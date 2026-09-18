#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""_nixl_kv_smoke.py — cross-node smoke test for the nixl_kv naming scheme.

Driven by scripts/verify/35-verify-nixl-kv-smoke.sh. Exercises the EXACT
name grammar and commit protocol nixl_kv_l2_adapter.py uses
(docs/design/nixl-kv-l2-adapter.md §4, §6), directly against the NIXL
backend, with NO LMCache in the path.

WHY THIS EXISTS SEPARATELY FROM 30-verify-kv-roundtrip.sh. That script
proves the DEVICE and NAMESPACE can carry a cross-node store+retrieve
(TODO 6.25). This one proves the ADAPTER'S SCHEME can: tile ordinals,
the commit-after-durable ordering, group-granular existence probing, and
the two negative controls that make a hit meaningful. It is the cheap
check that the scheme is sound before a full engine-level acceptance run
is allowed to blame anything else.

The writer and the reader never exchange a name. Both DERIVE names from
(namespace, key_string, ordinal) exactly as the adapter does, so a
successful cross-node read is evidence the derivation is stable across
processes and nodes -- not evidence the test passed a name over the wire.

Modes:
    write  --nonce N --pages P     store P pages + a commit object
    read   --nonce N --pages P     probe the commit key, then read+verify
    probe  --nonce N               probe only; prints HIT/MISS

Exit 0 on the asserted outcome, non-zero otherwise. Every outcome is
printed as a RESULT: line so the shell wrapper can grep deterministically.
"""

# Standard
import argparse
import ctypes
import hashlib
import json
import os
import sys
import time

# Third Party
from nixl._api import nixl_agent, nixl_agent_config

# The name grammar is IMPORTED from the adapter, never re-spelled here.
# patches/lmcache/README.md records what it cost the last time a verify
# script hand-mirrored an on-device naming convention instead of importing
# it (0007's `#{j}` scheme): the two silently drift and the check stops
# testing the property it exists to test.
sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                    "overlays", "lmcache")
)
import nixl_kv_l2_adapter as kv  # noqa: E402

PAGE = 4096


def page_payload(nonce: str, ordinal: int) -> bytes:
    """Deterministic per-page content, derived from (nonce, ordinal).

    Per-ordinal content is the whole point: if the adapter's naming ever
    collapses distinct pages onto one device key, every page reads back
    as the SAME bytes and the ordinal check below fails loudly. Identical
    filler across pages would make that failure invisible -- which is
    exactly the silent hole this scheme exists to close.
    """
    seed = hashlib.sha256(f"{nonce}|{ordinal}".encode()).digest()
    return (seed * (PAGE // len(seed) + 1))[:PAGE]


def make_agent(backend: str, dev_uri: str):
    # backends=[] then create_backend(): nixl_agent_config(backends=[X])
    # auto-instantiates X with DEFAULT params, after which the real params
    # silently never apply (HANDOFF §5).
    agent = nixl_agent(f"nixl-kv-smoke-{os.getpid()}", nixl_agent_config(backends=[]))
    agent.create_backend(backend, {"dev_uri": dev_uri})
    if backend not in agent.backends:
        sys.exit(f"RESULT:BACKEND_NOT_CREATED:{backend}")
    return agent


def _xfer(agent, backend, op, buf_addr, size, obj_name):
    local = agent.register_memory([(buf_addr, size, 0, "")], "DRAM", backends=[backend])
    remote = agent.register_memory([(0, size, 0, obj_name)], "OBJ", backends=[backend])
    try:
        h = agent.initialize_xfer(op, local.trim(), remote.trim(), agent.name)
        agent.transfer(h)
        state = agent.check_xfer_state(h)
        while state == "PROC":
            time.sleep(0.0005)
            state = agent.check_xfer_state(h)
        agent.release_xfer_handle(h)
        return state
    finally:
        agent.deregister_memory(local, backends=[backend])
        agent.deregister_memory(remote, backends=[backend])


def probe(agent, backend, name) -> bool:
    reg = agent.register_memory([(0, PAGE, 0, name)], "OBJ", backends=[backend])
    try:
        resp = agent.query_memory(reg, backend)
        # is_probe_hit(), not bool(): PRESENT is {} which is FALSY.
        return kv.is_probe_hit(resp[0])
    finally:
        agent.deregister_memory(reg, backends=[backend])


def do_write(agent, backend, ns, key_string, nonce, pages):
    buf = ctypes.create_string_buffer(PAGE)
    addr = ctypes.addressof(buf)

    for i in range(pages):
        ctypes.memmove(addr, page_payload(nonce, i), PAGE)
        name = kv.page_name(ns, key_string, i)
        state = _xfer(agent, backend, "WRITE", addr, PAGE, name)
        if state != "DONE":
            print(f"RESULT:PAGE_STORE_FAILED:{i}:{state}")
            return 1
    print(f"INFO: stored {pages} page(s)")

    # Commit LAST, and only after every page reported DONE (design §6).
    # This ordering is the entire atomicity story on a medium with no
    # tmp-then-rename: a key is not discoverable until its pages are
    # durable.
    payload = kv.encode_commit_payload(ns, pages, PAGE, pages * PAGE)
    cbuf = ctypes.create_string_buffer(payload, len(payload))
    state = _xfer(agent, backend, "WRITE", ctypes.addressof(cbuf), len(payload),
                  kv.commit_name(ns, key_string))
    if state != "DONE":
        print(f"RESULT:COMMIT_STORE_FAILED:{state}")
        return 1
    print("RESULT:OK")
    return 0


def do_read(agent, backend, ns, key_string, nonce, pages, expect_miss=False):
    cname = kv.commit_name(ns, key_string)
    if not probe(agent, backend, cname):
        print(f"RESULT:QUERY_MISS:{cname}")
        return 0 if expect_miss else 1
    if expect_miss:
        print(f"RESULT:UNEXPECTED_HIT:{cname}")
        return 1
    print(f"INFO: commit key EXISTS: {cname}")

    # Read + validate the commit object before touching any page. A
    # geometry disagreement must abort the group, not reassemble a
    # half-stale one (design §6 Load).
    clen = len(kv.encode_commit_payload(ns, pages, PAGE, pages * PAGE))
    cbuf = ctypes.create_string_buffer(clen)
    state = _xfer(agent, backend, "READ", ctypes.addressof(cbuf), clen, cname)
    if state != "DONE":
        print(f"RESULT:COMMIT_READ_FAILED:{state}")
        return 1
    try:
        meta = kv.decode_commit_payload(cbuf.raw)
        kv.validate_commit_payload(
            meta, ns=ns, page_size=PAGE, expected_pages=pages
        )
    except Exception as exc:
        print(f"RESULT:COMMIT_INVALID:{exc}")
        return 1
    print(f"INFO: commit payload valid: {meta}")

    buf = ctypes.create_string_buffer(PAGE)
    addr = ctypes.addressof(buf)
    for i in range(pages):
        name = kv.page_name(ns, key_string, i)
        ctypes.memset(addr, 0, PAGE)
        state = _xfer(agent, backend, "READ", addr, PAGE, name)
        if state != "DONE":
            print(f"RESULT:PAGE_READ_FAILED:{i}:{state}")
            return 1
        want = page_payload(nonce, i)
        if buf.raw[:PAGE] != want:
            # The page-collapse signature: if naming dropped the ordinal,
            # every page holds the LAST page's bytes.
            other = next(
                (j for j in range(pages) if buf.raw[:PAGE] == page_payload(nonce, j)),
                None,
            )
            print(f"RESULT:PAGE_MISMATCH:{i}"
                  + (f":got_page_{other}" if other is not None else ":got_garbage"))
            return 1
    print(f"INFO: verified {pages} page(s), byte-exact, correct ordinals")
    print("RESULT:OK")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["write", "read", "probe"])
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--pages", type=int, default=4)
    ap.add_argument("--namespace", default=os.environ.get("SMOKE_NS", "smoketest"))
    ap.add_argument("--backend", default=os.environ.get("KV_BACKEND", "XNVME_KV"))
    ap.add_argument("--dev-uri", default=os.environ.get("NIXL_XNVME_DEV", "/dev/ng1n1"))
    ap.add_argument("--expect-miss", action="store_true")
    a = ap.parse_args()

    kv.validate_namespace(a.namespace)
    # A realistic ObjectKey string shape, derived from the nonce. Both
    # sides compute this independently -- it is never sent over the wire.
    key_string = f"smoke/model@{0:08x}@0@{hashlib.sha256(a.nonce.encode()).hexdigest()[:16]}"
    print(f"INFO: ns={a.namespace} key_string={key_string} pages={a.pages}")
    print(f"INFO: page[0] name = {kv.page_name(a.namespace, key_string, 0)}")
    print(f"INFO: commit name  = {kv.commit_name(a.namespace, key_string)}")

    agent = make_agent(a.backend, a.dev_uri)
    if a.mode == "write":
        return do_write(agent, a.backend, a.namespace, key_string, a.nonce, a.pages)
    if a.mode == "probe":
        hit = probe(agent, a.backend, kv.commit_name(a.namespace, key_string))
        print(f"RESULT:{'HIT' if hit else 'MISS'}")
        return (1 if hit else 0) if a.expect_miss else (0 if hit else 1)
    return do_read(agent, a.backend, a.namespace, key_string, a.nonce, a.pages,
                   expect_miss=a.expect_miss)


if __name__ == "__main__":
    sys.exit(main())
