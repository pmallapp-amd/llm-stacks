#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""_nixl_kv_thin_smoke.py — cross-node smoke test for the PLUGIN-SIDE
naming/fan-out/commit scheme (xnvme_kv_backend.cpp), with no LMCache in the
path. Splitting/naming/atomicity live entirely in the plugin on this branch
— there is no Python-side adapter left that duplicates this protocol (see
overlays/lmcache/nixl_kv_thin_l2_adapter.py's docstring), so this is the
only naming/commit-scheme smoke test this branch carries.

Driven by scripts/verify/36-verify-nixl-kv-thin-smoke.sh. Proves the
plugin's internal fan-out is what's actually doing the work when a caller
(this script, or overlays/lmcache/nixl_kv_thin_l2_adapter.py) issues ONE
descriptor of arbitrary size under ONE bare name and never constructs an
ordinal or commit suffix itself — the wire grammar being exercised is
"{ns}@{key}~{ordinal}" pages plus a "{ns}@{key}!c" commit.

WHY THIS EXISTS SEPARATELY FROM 30-verify-kv-roundtrip.sh. That rung proves
a single-process-pair store+retrieve works at all under the plugin's
fan-out. This one adds cross-node name AGREEMENT (writer and reader
independently derive the same bare name from (namespace, key_string), never
exchanging it), a namespace-isolation negative control, and -- unique to
this scheme -- a probe-before-commit-lands negative control, since the
commit marker here is written entirely inside the plugin's own completion
callback, not by a second explicit Python call.

Modes:
    write --nonce N --pages P   issue ONE descriptor of P*PAGE bytes under
                                 ONE bare name; the plugin fans it out
    read  --nonce N --pages P   issue ONE descriptor read of the same size;
                                 the plugin commit-checks then reassembles
    probe --nonce N             existence probe only; prints HIT/MISS
    race  --nonce N --pages P   fire a write WITHOUT waiting for completion,
                                 probe immediately (expect MISS -- the commit
                                 marker cannot exist until every part has),
                                 then wait for completion and probe again
                                 (expect HIT)

Exit 0 on the asserted outcome, non-zero otherwise. Every outcome is printed
as a RESULT: line so the shell wrapper can grep deterministically.
"""

# Standard
import argparse
import ctypes
import hashlib
import os
import sys
import time

# Third Party
from nixl._api import nixl_agent, nixl_agent_config

PAGE = 4096


def page_payload(nonce: str, ordinal: int) -> bytes:
    """Deterministic per-page content, derived from (nonce, ordinal).

    Per-ordinal content is the whole point: if the plugin's ordinal
    suffixing ever collapsed distinct pages onto one device key, every page
    would read back as the SAME bytes and the ordinal check below would
    fail loudly. Identical filler across pages would make that failure
    invisible — exactly the silent hole this scheme exists to close.
    """
    seed = hashlib.sha256(f"{nonce}|{ordinal}".encode()).digest()
    return (seed * (PAGE // len(seed) + 1))[:PAGE]


def make_agent(backend: str, dev_uri: str):
    agent = nixl_agent(f"nixl-kv-thin-smoke-{os.getpid()}", nixl_agent_config(backends=[]))
    agent.create_backend(backend, {"dev_uri": dev_uri})
    if backend not in agent.backends:
        sys.exit(f"RESULT:BACKEND_NOT_CREATED:{backend}")
    return agent


def _start_xfer(agent, backend, op, buf_addr, size, obj_name):
    """Register + initialize_xfer + transfer, WITHOUT waiting for
    completion. Returns (handle, local_reg, remote_reg) so the caller can
    poll check_xfer_state() and deregister once done -- split out from the
    blocking helper below specifically for the `race` mode, which needs the
    gap between "submitted" and "done" to be observable.
    """
    local = agent.register_memory([(buf_addr, size, 0, "")], "DRAM", backends=[backend])
    remote = agent.register_memory([(0, size, 0, obj_name)], "OBJ", backends=[backend])
    h = agent.initialize_xfer(op, local.trim(), remote.trim(), agent.name)
    agent.transfer(h)
    return h, local, remote


def _finish_xfer(agent, backend, h, local, remote):
    state = agent.check_xfer_state(h)
    while state == "PROC":
        time.sleep(0.0005)
        state = agent.check_xfer_state(h)
    agent.release_xfer_handle(h)
    agent.deregister_memory(local, backends=[backend])
    agent.deregister_memory(remote, backends=[backend])
    return state


def xfer(agent, backend, op, buf_addr, size, obj_name):
    h, local, remote = _start_xfer(agent, backend, op, buf_addr, size, obj_name)
    return _finish_xfer(agent, backend, h, local, remote)


def probe(agent, backend, name) -> bool:
    """Existence probe on the BARE name -- queryMem() appends its own "!c"
    suffix internally (xnvme_kv_backend.cpp); this script never constructs
    that suffix itself.
    """
    reg = agent.register_memory([(0, PAGE, 0, name)], "OBJ", backends=[backend])
    try:
        resp = agent.query_memory(reg, backend)
        entry = resp[0]
        # PRESENT is {} -- falsy -- so this must check identity, not bool().
        return entry is not None and entry is not False
    finally:
        agent.deregister_memory(reg, backends=[backend])


def do_write(agent, backend, name, nonce, pages):
    size = pages * PAGE
    buf = ctypes.create_string_buffer(size)
    addr = ctypes.addressof(buf)
    for i in range(pages):
        ctypes.memmove(addr + i * PAGE, page_payload(nonce, i), PAGE)

    state = xfer(agent, backend, "WRITE", addr, size, name)
    if state != "DONE":
        print(f"RESULT:STORE_FAILED:{state}")
        return 1
    print(f"INFO: stored {size} byte(s) as ONE descriptor under name={name}")
    print("RESULT:OK")
    return 0


def do_read(agent, backend, name, nonce, pages, expect_miss=False):
    if not probe(agent, backend, name):
        print(f"RESULT:QUERY_MISS:{name}")
        return 0 if expect_miss else 1
    if expect_miss:
        print(f"RESULT:UNEXPECTED_HIT:{name}")
        return 1
    print(f"INFO: commit marker EXISTS for: {name}")

    size = pages * PAGE
    buf = ctypes.create_string_buffer(size)
    addr = ctypes.addressof(buf)
    state = xfer(agent, backend, "READ", addr, size, name)
    if state != "DONE":
        print(f"RESULT:READ_FAILED:{state}")
        return 1

    for i in range(pages):
        got = buf.raw[i * PAGE:(i + 1) * PAGE]
        want = page_payload(nonce, i)
        if got != want:
            # Page-collapse signature: if the plugin's "~ordinal" suffixing
            # ever broke, every page would read back as the SAME
            # (likely last-written) page.
            other = next(
                (j for j in range(pages) if got == page_payload(nonce, j)),
                None,
            )
            print(f"RESULT:PAGE_MISMATCH:{i}"
                  + (f":got_page_{other}" if other is not None else ":got_garbage"))
            return 1
    print(f"INFO: verified {pages} page(s), byte-exact, correct ordinals, "
          "reassembled by the PLUGIN from ONE read descriptor")
    print("RESULT:OK")
    return 0


def do_race(agent, backend, name, nonce, pages):
    """Fire a write, probe immediately (before polling for completion), then
    poll to completion and probe again. The first probe is expected to MISS:
    the plugin's commit marker (xnvme_kv_backend.cpp's kv_complete_cb()) is
    only submitted after EVERY part's completion callback has fired, and
    transfer() returns immediately (NIXL_IN_PROG) without waiting for any of
    them -- so a probe issued right after transfer() lands in a genuine
    pre-commit window. This is a property of REAL hardware timing, not a
    mock: it can in principle flake on an implausibly fast device/small
    --pages, which is why the default run uses enough pages to make the
    window wide relative to probe latency (see shell wrapper's comment).
    """
    size = pages * PAGE
    buf = ctypes.create_string_buffer(size)
    addr = ctypes.addressof(buf)
    for i in range(pages):
        ctypes.memmove(addr + i * PAGE, page_payload(nonce, i), PAGE)

    h, local, remote = _start_xfer(agent, backend, "WRITE", addr, size, name)

    hit_mid_store = probe(agent, backend, name)
    if hit_mid_store:
        print(f"RESULT:RACE_FALSE_HIT:{name}: probe reported the commit "
              "marker present before the write's transfer handle was even "
              "polled for completion -- either the device is implausibly "
              "fast relative to --pages (retry with more pages) or the "
              "commit-after-all-parts-durable ordering broke.")

    state = _finish_xfer(agent, backend, h, local, remote)
    if state != "DONE":
        print(f"RESULT:STORE_FAILED:{state}")
        return 1

    hit_after = probe(agent, backend, name)
    if not hit_after:
        print(f"RESULT:MISSING_COMMIT_AFTER_DONE:{name}: transfer handle "
              "reported DONE but the commit marker still does not exist -- "
              "the commit op itself must have failed silently.")
        return 1

    if hit_mid_store:
        return 1
    print("RESULT:OK")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["write", "read", "probe", "race"])
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--pages", type=int, default=4)
    ap.add_argument("--namespace", default=os.environ.get("SMOKE_NS", "smoketest"))
    ap.add_argument("--backend", default=os.environ.get("KV_BACKEND", "XNVME_KV"))
    # No literal default: a hardcoded /dev/ngXnY guess is the KV namespace
    # on one lab and an ordinary data disk on another.
    ap.add_argument(
        "--dev-uri",
        default=os.environ.get("NIXL_XNVME_DEV") or os.environ.get("XNVME_DEV"),
    )
    ap.add_argument("--expect-miss", action="store_true")
    a = ap.parse_args()

    if not a.dev_uri:
        sys.exit(
            "RESULT:NO_DEV_URI: neither NIXL_XNVME_DEV nor XNVME_DEV is set "
            "and --dev-uri was not given. Resolve it by NQN (see "
            "resolve_xnvme_kv_dev in scripts/common/lib.sh) or pass "
            "--dev-uri explicitly."
        )

    for bad in ("@", "~", "!"):
        if bad in a.namespace:
            sys.exit(
                f"RESULT:BAD_NAMESPACE: namespace {a.namespace!r} contains "
                f"{bad!r}, a reserved field/ordinal/commit separator in the "
                "plugin's naming grammar."
            )

    # A realistic ObjectKey string shape -- both sides compute this
    # independently, never over the wire.
    key_string = f"smoke/model@{0:08x}@0@{hashlib.sha256(a.nonce.encode()).hexdigest()[:16]}"
    name = f"{a.namespace}@{key_string}"
    print(f"INFO: ns={a.namespace} key_string={key_string} pages={a.pages} name={name}")

    agent = make_agent(a.backend, a.dev_uri)
    if a.mode == "write":
        return do_write(agent, a.backend, name, a.nonce, a.pages)
    if a.mode == "probe":
        hit = probe(agent, a.backend, name)
        print(f"RESULT:{'HIT' if hit else 'MISS'}")
        return (1 if hit else 0) if a.expect_miss else (0 if hit else 1)
    if a.mode == "race":
        return do_race(agent, a.backend, name, a.nonce, a.pages)
    return do_read(agent, a.backend, name, a.nonce, a.pages, expect_miss=a.expect_miss)


if __name__ == "__main__":
    sys.exit(main())
