#!/usr/bin/env python3
"""l2-block-bench.py — run `lmcache bench l2` against a NIXL-backed L2 adapter.

WHAT THIS IS FOR
    KV-BLOCK-level measurement: blocks stored, blocks requested, hit rate,
    block size, and store/load bandwidth — measured at the L2 adapter,
    with no vLLM, no proxy, and no TTFT anywhere in the number. It drives
    the adapter directly, exactly as LMCache's storage manager would.

WHY A WRAPPER EXISTS AT ALL
    `lmcache bench l2` cannot drive ANY NIXL-backed L2 adapter in LMCache
    0.5.3 as shipped. Measured 2026-09-18 on this cluster:

        makeXferReq: local index out of range at index 0 with value 340075
        nixl_rocm._bindings.nixlInvalidParamError: NIXL_ERR_INVALID_PARAM

    The two halves of the vendor's own agent disagree about what an L1
    page index means.

    `NixlStorageAgent.init_mem_handlers()` builds the L1 transfer dlist
    BASE-RELATIVE — entry i is the page at `buffer_ptr + i * page_size`:

        xfer_desc = [(base_addr, page_size, device_id)
                     for base_addr in range(buffer_ptr,
                                            buffer_ptr + buffer_size,
                                            page_size)]

    but `NixlStorageAgent.get_memory_indices()` returns an ABSOLUTE page
    number, with no base subtracted:

        return [(raw_addr // self.l1_align_bytes + i) for i in range(num_pages)]

    Those two agree only when `buffer_ptr == 0`. Measured with the
    benchmark's own buffer: ptr=665980928, 32 dlist entries, and

        absolute  addr // 4096        = 162593   -> out of range
        relative (addr - ptr) // 4096 = 0        -> correct

    This is NOT a defect in this repo's `nixl_kv` adapter. Verified by
    A/B against the untouched vendor `nixl_store`, which fails on the
    identical line with the identical error and `Total success: 0`.
    `nixl_kv` inherits `get_memory_indices` from `NixlStorageAgent`
    unchanged, so it inherits the defect.

WHY PATCH HERE AND NOT IN THE ADAPTER
    Deliberate. Production (the live MP daemon) uses the same absolute
    arithmetic and does NOT crash, because its L1 buffer is 4 GiB
    (1,048,576 dlist entries) so `addr // 4096` lands IN range — but at
    an index shifted by `ptr // 4096`. Whether production is therefore
    silently mis-indexed is an OPEN QUESTION that needs its own decisive
    test (see docs/TODO.md), not an assumption folded into a benchmark
    run. Changing `nixl_kv_l2_adapter.py` would change the live serving
    path on the strength of that assumption.

    So the fix is applied to the vendor base class IN THIS PROCESS ONLY.
    The adapter file on disk is untouched; the running daemon is
    untouched. This process measures, it does not migrate anything.

WHAT THE PATCH DOES
    1. `init_mem_handlers` records the L1 base pointer it was handed.
       The vendor stores `l1_align_bytes` but throws the base away, so
       there is nothing to subtract without capturing it here.
    2. `get_memory_indices` subtracts that base, and RANGE-CHECKS the
       result against the dlist it will actually index into.

    The range check is the point. An out-of-range index is what NIXL
    already rejects loudly; an in-range WRONG index is what it cannot
    catch, and that is the failure mode this repo has been bitten by
    repeatedly (HANDOFF §5; TODO 6.34). Raising here converts a silent
    mis-index into a loud one.

    Note `(raw_addr - base) // align` reduces to `raw_addr // align`
    exactly when `base == 0`, so this is a strict superset of the
    vendor's behaviour, never a divergence from it.

USAGE
    Run INSIDE the role container (it needs the image's nixl + lmcache):

        ./scripts/common/container.sh exec decode \
            "python3 scripts/bench/l2-block-bench.py bench l2 \
                --l2-adapter '<JSON>' --l1-align-bytes 4096 ..."

    Every argument after the script name is passed through to the
    `lmcache` CLI verbatim.
"""

from __future__ import annotations

import os
import sys


def _install_base_relative_index_patch() -> None:
    """Make L1 page indices base-relative, and range-check them.

    Patches the vendor `NixlStorageAgent` base class, so every adapter
    that inherits from it (`nixl_kv`, `nixl_store`,
    `nixl_store_dynamic`) is fixed by one patch.
    """
    from lmcache.v1.distributed.l2_adapters.nixl_store_l2_adapter import (
        NixlStorageAgent,
    )

    _orig_init_mem_handlers = NixlStorageAgent.init_mem_handlers

    def init_mem_handlers(self, device, buffer_ptr, buffer_size, page_size, device_id):
        # Capture what the vendor discards. Recorded before delegating so
        # it is set even if the vendor call raises partway through.
        self._l1_base_addr = int(buffer_ptr)
        self._l1_page_size = int(page_size)
        self._l1_num_pages = int(buffer_size) // int(page_size)
        return _orig_init_mem_handlers(
            self, device, buffer_ptr, buffer_size, page_size, device_id
        )

    def get_memory_indices(self, raw_addr: int, mem_size: int) -> list[int]:
        align = self.l1_align_bytes
        if raw_addr % align != 0:
            raise ValueError(
                f"Raw address {raw_addr} is not aligned to page size {align}"
            )
        if mem_size % align != 0:
            raise ValueError(
                f"Memory size {mem_size} is not a multiple of page size {align}"
            )

        base = getattr(self, "_l1_base_addr", None)
        if base is None:
            # init_mem_handlers never ran (e.g. a FILE-backed path that
            # registers differently). Fall back to vendor behaviour
            # rather than guessing a base.
            num_pages = mem_size // align
            return [(raw_addr // align + i) for i in range(num_pages)]

        if raw_addr < base:
            raise ValueError(
                f"L1 address {raw_addr} is below the registered L1 buffer "
                f"base {base} — it is not inside the buffer this agent "
                f"registered, so no index into the transfer dlist can be "
                f"correct."
            )

        num_pages = mem_size // align
        first = (raw_addr - base) // align
        last = first + num_pages - 1
        limit = getattr(self, "_l1_num_pages", None)
        if limit is not None and last >= limit:
            # In-range-but-wrong is the silent failure; out-of-range is
            # the loud one. Prefer loud.
            raise ValueError(
                f"L1 page index {last} is outside the registered transfer "
                f"dlist ({limit} pages). addr={raw_addr} base={base} "
                f"size={mem_size} align={align}. The L1 buffer is too "
                f"small for the objects being transferred."
            )
        return [first + i for i in range(num_pages)]

    NixlStorageAgent.init_mem_handlers = init_mem_handlers
    NixlStorageAgent.get_memory_indices = get_memory_indices


def main() -> int:
    if os.environ.get("L2_BLOCK_BENCH_NO_PATCH") != "1":
        _install_base_relative_index_patch()
        print(
            "[l2-block-bench] base-relative L1 index patch INSTALLED "
            "(process-local; adapter file and running daemon untouched)",
            file=sys.stderr,
        )
    else:
        print(
            "[l2-block-bench] patch DISABLED via L2_BLOCK_BENCH_NO_PATCH=1 "
            "— expect 'local index out of range' on any NIXL adapter",
            file=sys.stderr,
        )

    from lmcache.cli.main import main as lmcache_main

    # argv[0] stays this script; the CLI only reads argv[1:].
    return lmcache_main()


if __name__ == "__main__":
    sys.exit(main())
