#!/usr/bin/env python3
"""_nixl_kv_smoke.py — adapter-level smoke test for nixl_kv_l2_adapter.py's
NixlKvStorageAgent: the multi-page store/commit protocol (design doc §6),
exercised directly against the real DSC, independent of whether this
adapter's LMCache registration has been confirmed yet (see
nixl_kv_l2_adapter.py's module docstring).

Layering, cross-referenced against the rest of scripts/verify/:
  20-verify-nixl-plugin.sh   — raw NIXL, no adapter, no data roundtrip
  30-verify-kv-roundtrip.sh  — raw NIXL single-value store/retrieve
  THIS                       — the adapter's own multi-page store/commit/
                               load protocol (page naming, commit object,
                               geometry check), still bypassing LMCache
  40/50-verify-*.sh          — full vLLM+LMCache end to end

Invoked by scripts/verify/35-verify-nixl-kv-smoke.sh, once per OS process
(--write, then --read as a separate `python` invocation), mirroring
_kv_roundtrip.py's cross-process key agreement proof.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "overlays" / "lmcache"))

NIXL_IMPORT_ERROR_PREFIX = "RESULT:IMPORT_FAIL:"


def derive_page(nonce: str, page_index: int, size: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < size:
        block = hashlib.sha256(f"{nonce}:{page_index}:{counter}".encode()).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:size])


def do_write(agent, namespace: str, object_key_string: str, pages: list[bytes],
             align_bytes: int) -> None:
    agent.store_pages(namespace, object_key_string, pages, align_bytes)
    print(f"RESULT:OK:{len(pages)} pages stored under {object_key_string!r}")


def do_read(agent, namespace: str, object_key_string: str, expected_pages: list[bytes],
            align_bytes: int) -> None:
    exists = agent.probe_commit(namespace, object_key_string)
    if exists is None:
        print(f"RESULT:MISS:{object_key_string}: commit object not found")
        sys.exit(1)

    commit = agent.read_commit(namespace, object_key_string)
    expected_geom = {
        "v": 1, "ns": namespace, "pages": len(expected_pages),
        "page_size": align_bytes, "phy_size": len(expected_pages) * align_bytes,
    }
    if commit != expected_geom:
        print(f"RESULT:GEOMETRY_MISMATCH: got {commit!r}, expected {expected_geom!r}")
        sys.exit(1)

    got_pages = agent.read_pages(namespace, object_key_string, commit["pages"], align_bytes)
    if got_pages != expected_pages:
        for i, (got, exp) in enumerate(zip(got_pages, expected_pages)):
            if got != exp:
                print(f"RESULT:MISMATCH: page {i} differs "
                      f"(this is the §6/§7 page-collapse failure signature "
                      "if every page reads back as the LAST page written)")
                sys.exit(1)
        print("RESULT:MISMATCH: page count differs")
        sys.exit(1)

    print(f"RESULT:OK:{len(got_pages)} pages verified byte-for-byte under "
          f"{object_key_string!r}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", required=True, choices=("write", "read"))
    ap.add_argument("--nonce", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--pages", type=int, default=3,
                     help="number of pages — >1 to exercise the multi-page "
                          "store/commit protocol, not just a single value")
    ap.add_argument("--align-bytes", type=int, default=4096)
    ap.add_argument("--dev-uri", required=True,
                     help="XNVME_KV connect param, e.g. /dev/ng1n1")
    args = ap.parse_args()

    try:
        from nixl_kv_l2_adapter import NixlKvStorageAgent
    except Exception as exc:  # noqa: BLE001
        print(f"{NIXL_IMPORT_ERROR_PREFIX}{type(exc).__name__}: {exc}")
        return 1

    object_key_string = f"smoke-test@{args.nonce}"
    pages = [derive_page(args.nonce, i, args.align_bytes) for i in range(args.pages)]

    print(f"INFO: mode={args.mode} pages={args.pages} align_bytes={args.align_bytes} "
          f"namespace={args.namespace} object_key_string={object_key_string}")

    try:
        agent = NixlKvStorageAgent("XNVME_KV", {"dev_uri": args.dev_uri})
    except Exception as exc:  # noqa: BLE001
        print(f"RESULT:CREATE_BACKEND_FAIL:{type(exc).__name__}: {exc}")
        return 1

    if not agent.self_probe():
        print("RESULT:SELF_PROBE_FAIL: §7 assert 5 — lookup path appears dead")
        return 1

    try:
        if args.mode == "write":
            do_write(agent, args.namespace, object_key_string, pages, args.align_bytes)
        else:
            do_read(agent, args.namespace, object_key_string, pages, args.align_bytes)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"RESULT:UNEXPECTED_EXCEPTION:{type(exc).__name__}: {exc}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
