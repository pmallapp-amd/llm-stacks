# SPDX-License-Identifier: Apache-2.0
"""
nixl_kv_l2_adapter.py — content-addressed, cross-node NIXL L2 adapter.

Implements ``docs/design/nixl-kv-l2-adapter.md`` (the authoritative spec;
section references below, e.g. "spec §6", point at it). Fixes the two
independent blockers that design doc identifies in ``nixl_store``:

  1. Lookup only ever consults the in-process ``_memory_objects`` dict —
     a daemon never asks the shared device about a key it did not itself
     store, so a cross-daemon lookup is a miss before naming is even
     consulted (spec §1 "Blocker 1").
  2. Storage names are pool slots (``obj_{i}_{uuid4}``), not content —
     the content→slot mapping lives only in the same in-process dict
     (spec §1 "Blocker 2").

This module fixes both: names are deterministic and content-derived
(spec §4/§5), and Lookup falls back to a real device probe
(``query_memory``) on an in-process miss (spec §6 Lookup), mirroring the
"secondary lookup on index miss" shape of
``nixl_store_dynamic_l2_adapter.py`` — retargeted from FILE/POSIX to
OBJ/KV (spec §3).

Self-registers as L2 adapter type ``"nixl_kv"`` (see
``l2_adapters/__init__.py``'s ``pkgutil``-based auto-discovery of any
``*_l2_adapter.py`` module — no other vendor-file change is needed).

Structure of this file, and why:
    The pure naming / encoding / validation helpers below have no
    dependency on ``nixl`` or ``lmcache`` and are unit-tested directly
    from the control host with plain ``python3`` and neither installed
    (see ``test_nixl_kv_naming.py`` in this directory). The adapter
    classes further down need both and are guarded by a top-level
    try/except so importing this module never raises merely because
    nixl/lmcache aren't on the control host — only actually
    instantiating the adapter does (which can only happen inside the
    vendor container, where both are present).
"""

# Future
from __future__ import annotations

# Standard
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Optional
import asyncio
import ctypes
import json
import threading
import time
import uuid

# ---------------------------------------------------------------------
# Pure logic: naming, parsing, commit-payload encode/decode, namespace
# validation, probe-result interpretation, page-count arithmetic.
#
# No nixl / lmcache import anywhere below this comment block and above
# the "Heavy runtime dependencies" section — this is deliberate so
# test_nixl_kv_naming.py can import these names on a bare control host.
# ---------------------------------------------------------------------

#: Forbidden in a namespace value (spec §5 last line / §7 assert 3): '@'
#: is the ns/key-string field separator, '~' is the page-ordinal
#: separator, '!' marks a commit name. A namespace containing any of
#: these could alias onto an unrelated page/commit name.
_NS_FORBIDDEN_CHARS = frozenset("@~!")

#: Page-ordinal separator (spec §4). Deliberately not '#', which patch
#: 0007 uses for its own value-size sub-split convention, so the two
#: schemes can never be confused when reading a device key back.
_PAGE_SEP = "~"

#: Commit-object name suffix (spec §4).
_COMMIT_SUFFIX = "!c"

#: Commit payload schema version (spec §6 Store "Commit object payload").
_COMMIT_VERSION = 1


def validate_namespace(ns: str) -> None:
    """Validate a nixl_kv namespace fingerprint (spec §5, §7 assert 3).

    Raises:
        ValueError: ``ns`` is empty, or contains ``@``, ``~``, or ``!``.
    """
    if not ns:
        raise ValueError(
            "nixl_kv: 'namespace' must be non-empty (spec §7 assert 3)"
        )
    bad = _NS_FORBIDDEN_CHARS & set(ns)
    if bad:
        raise ValueError(
            "nixl_kv: 'namespace' must not contain %s (got %r) (spec §7 assert 3)"
            % (sorted(bad), ns)
        )


def page_name(ns: str, key_string: str, ordinal: int) -> str:
    """Build a page device name: ``{ns}@{key_string}~{ordinal}`` (spec §4).

    The ``~{ordinal}`` suffix is load-bearing: one ``ObjectKey`` tiles
    into ``phy_size / align_bytes`` pages (up to ~9,216 in production
    geometry — spec §2); naming every page with the same string makes
    each page overwrite the last, which is exactly the page-collapse
    hole this adapter exists to close (spec §4, §9's closing note).
    """
    return f"{ns}@{key_string}{_PAGE_SEP}{ordinal}"


def commit_name(ns: str, key_string: str) -> str:
    """Build a commit device name: ``{ns}@{key_string}!c`` (spec §4)."""
    return f"{ns}@{key_string}{_COMMIT_SUFFIX}"


def parse_name(name: str) -> tuple[str, str, Optional[int]]:
    """Inverse of :func:`page_name` / :func:`commit_name`.

    Returns:
        ``(ns, key_string, ordinal)``. ``ordinal`` is ``None`` for a
        commit name, an ``int >= 0`` for a page name.

    Raises:
        ValueError: ``name`` does not match either wire format.
    """
    ns, sep, rest = name.partition("@")
    if not sep:
        raise ValueError(
            f"malformed nixl_kv device name {name!r}: missing '@' ns separator"
        )
    if rest.endswith(_COMMIT_SUFFIX):
        return ns, rest[: -len(_COMMIT_SUFFIX)], None

    # rpartition (not partition/split) on the LAST '~': key_string itself
    # is built from '@'-joined ObjectKey fields and is not guaranteed
    # '~'-free, so the ordinal is always the tail segment after the
    # final separator, regardless of anything embedded earlier.
    key_string, sep2, ordinal_str = rest.rpartition(_PAGE_SEP)
    if not sep2:
        raise ValueError(
            f"malformed nixl_kv device name {name!r}: missing {_PAGE_SEP!r} "
            "ordinal separator and not a commit name"
        )
    try:
        ordinal = int(ordinal_str)
    except ValueError as exc:
        raise ValueError(
            f"malformed nixl_kv device name {name!r}: non-integer ordinal "
            f"{ordinal_str!r}"
        ) from exc
    if ordinal < 0:
        raise ValueError(
            f"malformed nixl_kv device name {name!r}: negative ordinal {ordinal}"
        )
    return ns, key_string, ordinal


def page_count_for(phy_size: int, align_bytes: int) -> int:
    """Number of ``align_bytes``-sized pages ``phy_size`` bytes tiles into.

    Raises:
        ValueError: ``align_bytes`` is not positive, or ``phy_size`` is
            not an exact multiple of it (spec §6 Store step 2, §7 assert 2).
    """
    if align_bytes <= 0:
        raise ValueError(f"align_bytes must be positive, got {align_bytes}")
    if phy_size % align_bytes != 0:
        raise ValueError(
            f"phy_size ({phy_size}) is not a multiple of align_bytes "
            f"({align_bytes}) (spec §7 assert 2)"
        )
    return phy_size // align_bytes


def encode_commit_payload(ns: str, page_count: int, page_size: int, phy_size: int) -> bytes:
    """Encode the commit-object JSON payload (spec §6 Store), NUL-padded to
    exactly ``page_size`` bytes so it occupies one page-sized device slot.

    Raises:
        ValueError: the JSON encoding (before padding) exceeds ``page_size``
            — ``align_bytes`` is too small to hold a commit record.
    """
    payload = {
        "v": _COMMIT_VERSION,
        "ns": ns,
        "pages": page_count,
        "page_size": page_size,
        "phy_size": phy_size,
    }
    data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(data) > page_size:
        raise ValueError(
            f"nixl_kv commit payload ({len(data)} bytes) exceeds page_size "
            f"({page_size} bytes); align_bytes is too small to hold a "
            "commit record"
        )
    return data + b"\x00" * (page_size - len(data))


def decode_commit_payload(data: bytes) -> dict:
    """Inverse of :func:`encode_commit_payload`: strip NUL padding, parse JSON.

    Raises:
        ValueError / ``json.JSONDecodeError``: ``data`` is not a valid
            NUL-padded JSON commit payload.
    """
    return json.loads(data.rstrip(b"\x00").decode("utf-8"))


def validate_commit_payload(
    payload: dict, *, ns: str, page_size: int, expected_pages: int
) -> None:
    """Validate a decoded commit payload against the caller's expectations
    (spec §6 Load step 1).

    Raises:
        ValueError: version, namespace, page_size, or page-count mismatch.
            Callers MUST treat this as a whole-group abort (spec §6 Load
            step 2) — never hand partial or mis-shaped data upward.
    """
    if payload.get("v") != _COMMIT_VERSION:
        raise ValueError(
            f"commit payload version mismatch: expected {_COMMIT_VERSION}, "
            f"got {payload.get('v')!r}"
        )
    if payload.get("ns") != ns:
        raise ValueError(
            f"commit payload namespace mismatch: expected {ns!r}, "
            f"got {payload.get('ns')!r}"
        )
    if payload.get("page_size") != page_size:
        raise ValueError(
            f"commit payload page_size mismatch: expected {page_size}, "
            f"got {payload.get('page_size')!r}"
        )
    if payload.get("pages") != expected_pages:
        raise ValueError(
            f"commit payload page count mismatch: expected {expected_pages}, "
            f"got {payload.get('pages')!r}"
        )


def object_key_to_string(key) -> str:
    """Serialize an ObjectKey to the deterministic on-device name fragment.

    ``<model_name>@<kv_rank:08x>@<object_group_id:x>@<chunk_hash_hex>[@<cache_salt>]``

    DELIBERATELY SPELLED HERE RATHER THAN IMPORTED, and this is a reversal
    of what docs/design/nixl-kv-l2-adapter.md §4 originally specified.

    LMCache ships **four independent copies** of this function —
    ``s3_l2_adapter``, ``bigtable_l2_adapter``, ``hfbucket_l2_adapter`` and
    ``native_connector_l2_adapter``. Measured 2026-09-17 against the
    installed 0.5.3: the first three are byte-identical, and
    ``native_connector``'s is NOT — it is parameterised on a module-level
    ``_KEY_SEP`` (currently ``"@"``, so its OUTPUT agrees today). Every one
    of the four is private (``_``-prefixed): none is a public API, and
    nothing stops a vendor image from editing any of them.

    This string is not an implementation detail — it is our **persistence
    format**. It determines the 12-byte device key via the plugin's
    FNV-1a derivation. Importing it would make our on-device naming hostage
    to a vendor edit we cannot see, and because this backend has **no delete
    primitive**, a silent format change does not degrade gracefully: every
    object already on the device becomes unreachable at once, and two nodes
    on different images would silently stop agreeing on names.

    So: own it, and pin it with a unit test that asserts the exact bytes.
    ``_COMMIT_VERSION``/the ``v1`` term in the namespace fingerprint is the
    lever for changing it deliberately.

    ``ObjectKey.__post_init__`` enforces that ``model_name`` and
    ``cache_salt`` contain no ``@``, so the encoding is unambiguous.
    """
    base = (
        f"{key.model_name}@{key.kv_rank:08x}"
        f"@{key.object_group_id:x}@{key.chunk_hash.hex()}"
    )
    if key.cache_salt:
        return f"{base}@{key.cache_salt}"
    return base


def is_probe_hit(resp_entry: object) -> bool:
    """Interpret one entry of a ``query_memory()`` response list.

    spec §6 Lookup item 3 / §2 measured fact: PRESENT is an empty,
    **falsy** dict (``{}``); ABSENT is ``None``. This is the single,
    deliberate point of truth for that distinction: identity check
    (``is not None``), never truthiness (``bool(x)`` / ``if x:``). A
    truthiness-based check silently scores every hit as a miss — this is
    the exact bug this adapter exists to fix (spec §2's measured-facts
    table, first row).
    """
    return resp_entry is not None


# ---------------------------------------------------------------------
# Heavy runtime dependencies (nixl + lmcache). Guarded so this module is
# still importable — and the pure logic above still testable — on a
# control host with neither installed.
# ---------------------------------------------------------------------

_NIXL_KV_RUNTIME_AVAILABLE = True
try:
    # Third Party
    from nixl._api import nixl_agent as NixlAgent
    from nixl._api import nixl_agent_config as NixlAgentConfig

    # First Party
    from lmcache.logging import init_logger
    from lmcache.native_storage_ops import Bitmap
    from lmcache.v1.distributed.api import MemoryLayoutDesc, ObjectKey
    from lmcache.v1.distributed.internal_api import L1MemoryDesc, L2StoreResult
    from lmcache.v1.distributed.l2_adapters.base import L2AdapterInterface, L2TaskId
    from lmcache.v1.distributed.l2_adapters.config import (
        L2AdapterConfigBase,
        register_l2_adapter_type,
    )
    from lmcache.v1.distributed.l2_adapters.factory import (
        register_l2_adapter_factory,
    )
    from lmcache.v1.distributed.l2_adapters.nixl_store_l2_adapter import (
        NixlStorageAgent,
    )
    from lmcache.v1.memory_management import MemoryObj
    from lmcache.v1.platform import create_event_notifier
except ImportError:
    _NIXL_KV_RUNTIME_AVAILABLE = False

if _NIXL_KV_RUNTIME_AVAILABLE:
    logger = init_logger(__name__)
else:  # pragma: no cover - exercised only on the control host without lmcache
    import logging as _logging

    logger = _logging.getLogger(__name__)


if _NIXL_KV_RUNTIME_AVAILABLE:
    # Rate-limit for WARNING logs on a wedged/erroring probe path so a
    # persistently broken device doesn't flood the log at request rate
    # (spec §6 Lookup item 5).
    _PROBE_ERROR_LOG_INTERVAL_S = 5.0

    # spec §6 Lookup: "Bound it with a deadline and report miss past it".
    # The spec does not name a specific number (only "single-digit
    # milliseconds" as the *expected* case — spec §2 measured 57µs per
    # descriptor); this value is our own conservative choice, generous
    # enough to absorb a legitimately busy device without false-miss
    # storms, tight enough that a truly wedged DSC degrades throughput
    # rather than hanging the engine. Flagged for review.
    _DEFAULT_PROBE_DEADLINE_S = 0.2

    @dataclass
    class NixlKvObj:
        """In-process record for one content-addressed nixl_kv object.

        ``page_count``/``size`` are ``None`` until this daemon has
        actually confirmed them by reading the object's commit record —
        either because this daemon just stored it (known immediately),
        or because Lookup discovered it via a device hit and Load later
        read+validated its commit object (spec §6 Lookup item 4 / Load
        item 1).

        This mirrors ``nixl_store_dynamic_l2_adapter.py``'s
        ``_secondary_lookup_locked`` pattern (lazily populate the index
        on a device hit) as closely as the OBJ probe primitive allows:
        unlike a FILE ``os.stat()``, an OBJ ``Exist`` probe carries no
        size (spec §2: PRESENT is ``{}``), so ``size``/``page_count``
        cannot be filled in until Load actually reads the commit object.
        ``recorded`` guards against double-counting ``_notify_keys_stored``
        for a lazily-discovered key that gets loaded more than once.
        """

        key_string: str
        page_count: Optional[int] = None
        size: Optional[int] = None
        layout: Optional["MemoryLayoutDesc"] = None
        pin_count: int = 0
        recorded: bool = False
        _lock: threading.Lock = field(
            default_factory=threading.Lock, repr=False, compare=False
        )

        def increase_pin_count(self) -> None:
            with self._lock:
                self.pin_count += 1

        def decrease_pin_count(self) -> None:
            with self._lock:
                if self.pin_count > 0:
                    self.pin_count -= 1
                else:
                    logger.warning(
                        "nixl_kv: decreasing pin count of key %s below 0",
                        self.key_string,
                    )

    class NixlKvStorageAgent(NixlStorageAgent):
        """Storage-side NIXL glue for the content-addressed nixl_kv adapter.

        Inherits the L1-memory-side machinery from ``NixlStorageAgent``
        unchanged — ``init_mem_handlers``, ``get_memory_indices``,
        ``post_non_blocking``, ``release_handle``, ``_resolve_mem_split``
        (spec: "The L1 memory side is correct as-is and must be reused
        unchanged — whole buffer registered once, prepped dlist of all
        pages, indexed by ``raw_addr // align_bytes``").

        Deliberately does **not** call ``NixlStorageAgent.__init__`` —
        that pre-registers a fixed pool of ``obj_{i}_{uuid4}`` slot
        names, which is exactly the pool-slot design this adapter
        replaces with per-transfer, content-derived OBJ registration
        (spec §3, §4). Instead this class registers a fresh OBJ dlist
        per store/lookup/load call and deregisters it immediately after
        — the same per-operation register/deregister shape as
        ``nixl_store_dynamic_l2_adapter.py``'s ``DynamicNixlStorageAgent``,
        retargeted from FILE to OBJ (spec §3).
        """

        def __init__(
            self,
            backend: str,
            backend_params: dict[str, str],
            l1_memory_desc: "L1MemoryDesc",
        ):
            self.backend = backend
            self.backend_params = backend_params
            self.device = "cpu"
            self.l1_align_bytes = l1_memory_desc.align_bytes

            self.agent_name = "NixlKvAgent_" + str(uuid.uuid4())
            nixl_conf = NixlAgentConfig(backends=[])
            self.nixl_agent = NixlAgent(self.agent_name, nixl_conf)
            self.nixl_agent.create_backend(backend, backend_params)

            # spec §7 assert 1: page_size must not exceed the backend's
            # declared max_value_size. nixl_store's #{j} sub-split exists
            # to cope with a violation, but content-addressed naming has
            # nowhere to put a sub-split ordinal without colliding with
            # the '~' ordinal convention (spec §4) or losing atomicity
            # (spec §7 assert 1) — refuse to start instead.
            mem_split_n = self._resolve_mem_split(l1_memory_desc.align_bytes)
            if mem_split_n != 1:
                raise ValueError(
                    "nixl_kv: l1_align_bytes (%d) exceeds backend %r's "
                    "declared max_value_size; nixl_kv requires "
                    "page_size <= max_value_size and refuses to start "
                    "otherwise (spec §7 assert 1)."
                    % (l1_memory_desc.align_bytes, backend)
                )
            self.mem_split_n = mem_split_n

            # Reused unchanged (see class docstring): whole L1 buffer
            # registered once, prepped dlist of all pages, indexed by
            # raw_addr // align_bytes.
            self.init_mem_handlers(
                self.device,
                l1_memory_desc.ptr,
                l1_memory_desc.size,
                l1_memory_desc.align_bytes,
                device_id=0,
            )

            # Guards make_prepped_xfer() calls against the shared,
            # persistent mem_xfer_handler — same rationale as
            # NixlStorageAgent's own _xfer_handle_lock: the C++
            # makeXferReq() is not safe to call concurrently against the
            # same pre-built dlist handle.
            self._xfer_handle_lock = threading.Lock()

            # Monotonic devId allocator for OBJ registrations — see
            # register_obj_names() for why restarting at 0 per call was a
            # correctness bug (TODO 6.34), not a cosmetic one.
            self._next_devid = 0
            self._devid_lock = threading.Lock()

        # ---- per-transfer OBJ registration (content-addressed, no pool) ----

        def register_obj_names(self, names: list[str], slot_size: int):
            """Register a fresh, per-call OBJ dlist keyed by content-derived
            names.

            Same per-operation register/prep/transfer/deregister shape as
            ``nixl_store_dynamic_l2_adapter.py``'s ``_register_single_file``
            — one FILE per op there, one OBJ entry per page/commit name
            here (spec §3: "retargeting that shape to OBJ/KV").

            ``devId`` is allocated from a DAEMON-GLOBAL monotonic counter,
            not from the position in ``names`` (TODO 6.34). This is a
            correctness requirement, not bookkeeping. Every OBJ descriptor
            this method builds sits at ``addr=0``, so ``devId`` is the only
            thing distinguishing one from another. When it restarted at 0
            for every call, two simultaneously-live registrations — the
            page dlist and the commit dlist of the same store, or the page
            dlists of two concurrent stores — were indistinguishable by
            ``(addr, len, devId)``. NIXL then bound the newer descriptors'
            ``metadataP`` to the OLDER live registration, and the plugin's
            ``make_key()`` hashed the wrong object's name
            (``xnvme_kv_backend.cpp``'s ``postXfer``, whose own comment
            warns callers must "not collide on devId/addr alone").
            Measured consequence: every commit write landed on a PAGE key,
            so the commit object was never created AND page 0..N-1 were
            overwritten with commit JSON. Monotonic devIds make any two
            live registrations disjoint by construction.

            ``devId`` does not affect the device key when ``metaInfo`` is
            non-empty — ``make_key()`` hashes the name and ignores devId —
            so widening it is safe for naming, and the probe path
            (``query_exists``) passes metaInfo directly without
            registering at all, so it is unaffected either way.
            """
            with self._devid_lock:
                base = self._next_devid
                self._next_devid += len(names)
            reg_list = [
                (0, slot_size, base + i, name) for i, name in enumerate(names)
            ]
            xfer_desc = [(0, slot_size, base + i) for i in range(len(names))]
            reg_descs = self.nixl_agent.register_memory(reg_list, mem_type="OBJ")
            xfer_descs = self.nixl_agent.get_xfer_descs(xfer_desc, mem_type="OBJ")
            xfer_handler = self.nixl_agent.prep_xfer_dlist(
                self.agent_name, xfer_descs, mem_type="OBJ"
            )
            return reg_descs, xfer_handler

        def deregister_obj_names(self, reg_descs, xfer_handler) -> None:
            self.nixl_agent.release_dlist_handle(xfer_handler)
            self.nixl_agent.deregister_memory(reg_descs)

        def register_host_buffer(self, nbytes: int, slot_size: int):
            """Allocate + register a scratch host buffer for commit-object
            I/O.

            The commit payload is JSON we synthesize, not KV bytes from
            the caller-managed L1 buffer, so it needs its own tiny DRAM
            registration — built the same way ``init_mem_handlers`` builds
            the *persistent* L1 registration (whole-buffer reg + a
            prepped dlist of ``nbytes // slot_size`` slots), but ephemeral
            and per-call.
            """
            buf = bytearray(nbytes)
            addr = ctypes.addressof((ctypes.c_char * nbytes).from_buffer(buf))
            reg_list = [(addr, nbytes, 0, "")]
            xfer_desc = [
                (base, slot_size, 0) for base in range(addr, addr + nbytes, slot_size)
            ]
            reg_descs = self.nixl_agent.register_memory(reg_list, mem_type="DRAM")
            xfer_descs = self.nixl_agent.get_xfer_descs(xfer_desc, mem_type="DRAM")
            xfer_handler = self.nixl_agent.prep_xfer_dlist(
                "", xfer_descs, mem_type="DRAM"
            )
            return buf, reg_descs, xfer_handler

        def deregister_host_buffer(self, reg_descs, xfer_handler) -> None:
            self.nixl_agent.release_dlist_handle(xfer_handler)
            self.nixl_agent.deregister_memory(reg_descs)

        def make_transfer(
            self,
            direction: str,
            mem_xfer_handler,
            mem_indices: list[int],
            storage_xfer_handler,
            storage_indices: list[int],
        ):
            """Wrap ``nixl_agent.make_prepped_xfer`` under the shared lock.

            Reused primitive per spec: "make_prepped_xfer ... come from
            here" — called directly (rather than through
            ``NixlStorageAgent.get_mem_to_storage_handle`` /
            ``get_storage_to_mem_handle``, which are hard-wired to the
            pool's persistent ``storage_xfer_handler`` this adapter does
            not have).
            """
            with self._xfer_handle_lock:
                return self.nixl_agent.make_prepped_xfer(
                    direction,
                    mem_xfer_handler,
                    mem_indices,
                    storage_xfer_handler,
                    storage_indices,
                )

        def query_exists(self, names: list[str]):
            """Probe presence only (Exist) — never a data read.

            spec §6 Lookup item 2: probing commit keys only keeps a batch
            at ~57µs instead of ~0.53s (spec §2). Raises whatever the
            underlying ``query_memory`` raises for a genuine backend
            error (``NIXL_ERR_BACKEND``); callers MUST catch it, count
            ``l2_probe_errors``, and never fabricate a hit (spec §6
            Lookup item 5 / §7 assert 5).
            """
            reg_list = [(0, 0, 0, name) for name in names]
            return self.nixl_agent.query_memory(reg_list, self.backend, mem_type="OBJ")

        def close(self) -> None:
            # Only the persistent L1 registration needs releasing here —
            # every storage-side registration in this adapter is
            # per-transfer and already deregistered by its caller
            # immediately after use.
            self.nixl_agent.release_dlist_handle(self.mem_xfer_handler)
            self.nixl_agent.deregister_memory(self.mem_reg_descs)

    class NixlKvL2Adapter(L2AdapterInterface):
        """Content-addressed, cross-node NIXL L2 adapter (spec §6-§8)."""

        def __init__(
            self,
            config: "NixlKvL2AdapterConfig",
            l1_memory_desc: "L1MemoryDesc",
        ):
            self._ns = config.namespace
            self._align_bytes = l1_memory_desc.align_bytes

            self.nixl_agent = NixlKvStorageAgent(
                backend=config.backend,
                backend_params=config.backend_params,
                l1_memory_desc=l1_memory_desc,
            )

            # spec §7 assert 5: self-probe a known-absent key at init.
            # The plugin's device-handle open is deliberately non-fatal
            # (xnvme_kv_backend.cpp), so a failed open leaves every lookup
            # returning absent forever while the daemon looks healthy;
            # the only externally-visible signal is one stderr line
            # (`lookup=KV Exist` vs `lookup=UNAVAILABLE`) that we cannot
            # capture from Python. What we CAN verify here is that the
            # probe path executes at all without raising — a raise means
            # the backend itself considers itself broken, so refuse to
            # advertise this tier as healthy. A clean ``None`` result is
            # not a strong positive signal (it is indistinguishable from
            # "genuinely absent" without the C++ stderr line), so we only
            # treat an unexpected non-None hit as worth a warning, not a
            # refusal.
            probe_key = commit_name(self._ns, f"__nixl_kv_self_probe__{uuid.uuid4().hex}")
            try:
                probe_resp = self.nixl_agent.query_exists([probe_key])
            except Exception as exc:
                self.nixl_agent.close()
                raise RuntimeError(
                    "nixl_kv: init self-probe failed; the query_memory "
                    "path is not usable, refusing to start "
                    "(spec §7 assert 5): %r" % exc
                ) from exc
            if len(probe_resp) != 1 or is_probe_hit(probe_resp[0]):
                logger.warning(
                    "nixl_kv: init self-probe for a random, never-written "
                    "key returned %r instead of absent — unexpected, but "
                    "not by itself fatal",
                    probe_resp,
                )

            # No pool -> no known device capacity; global (aggregate)
            # eviction is not supported here (spec §10: capacity is
            # monotonic within a namespace generation since there is no
            # device delete to reclaim it).
            super().__init__(max_capacity_bytes=0)
            self._config = config

            self._store_efd = create_event_notifier()
            self._lookup_efd = create_event_notifier()
            self._load_efd = create_event_notifier()

            # Cache data structures
            self._memory_objects: dict["ObjectKey", NixlKvObj] = {}

            # Task ID management
            self._next_task_id: L2TaskId = 0
            self._completed_store_tasks: dict[L2TaskId, "L2StoreResult"] = {}
            self._completed_lookup_tasks: dict[L2TaskId, "Bitmap"] = {}
            self._completed_load_tasks: dict[L2TaskId, "Bitmap"] = {}
            self._lock = threading.Lock()  # lock for all shared state

            # spec §8 counters.
            self._l2_index_hits = 0
            self._l2_device_hits = 0
            self._l2_probe_errors = 0
            self._l2_commit_writes = 0
            self._l2_load_aborts = 0

            # Attempt counters (TODO 6.28). The outcome counters above
            # cannot distinguish "lookup ran and the names did not match"
            # from "lookup was never invoked" — both read
            # l2_device_hits=0 / l2_probe_errors=0, which is exactly the
            # state the 2026-09-18 acceptance run left undiagnosable.
            # Count the attempt, not just the outcome:
            #   l2_lookup_calls      submit_lookup_and_lock_task entries —
            #                        i.e. did LMCache ever ask us at all.
            #   l2_lookup_keys       ObjectKeys presented across those calls.
            #   l2_lookup_executions _execute_lookup_in_the_loop entries.
            #                        calls > executions means the coroutine
            #                        is not being scheduled (wedged/dead
            #                        event loop) — a distinct failure mode
            #                        that is otherwise invisible, because
            #                        run_coroutine_threadsafe swallows it.
            #   l2_keys_probed       keys that actually reached a batched
            #                        device probe.
            #   l2_probe_misses      probed keys the device reported absent.
            # Reading them: calls==0 -> the seam above us never called;
            # calls>0, executions==0 -> our loop is wedged; keys_probed==0
            # with calls>0 -> every key short-circuited on the in-process
            # index; probe_misses>0 -> we probed and the names did not
            # match, which is a naming/key-derivation problem, not a
            # plumbing one.
            self._l2_lookup_calls = 0
            self._l2_lookup_keys = 0
            self._l2_lookup_executions = 0
            self._l2_keys_probed = 0
            self._l2_probe_misses = 0

            self._probe_log_lock = threading.Lock()
            self._last_probe_error_log = 0.0
            # One-shot INFO logs of the first name this daemon probes and
            # the first name it commits. The pair is what makes a
            # writer-vs-reader name comparison a two-line grep across the
            # two daemons' logs instead of a fresh instrumentation cycle.
            self._logged_first_probe_name = False
            self._logged_first_commit_name = False

            # spec §6 Lookup: probing must not block the event loop past
            # a bounded deadline. query_memory is a synchronous, blocking
            # call, so it runs on a small dedicated executor and we
            # asyncio.wait_for() it from the loop.
            self._probe_executor = ThreadPoolExecutor(
                max_workers=2, thread_name_prefix="nixl_kv_probe"
            )
            self._probe_deadline_s = _DEFAULT_PROBE_DEADLINE_S

            # Asyncio event loop running in a background thread
            self._loop = asyncio.new_event_loop()
            self._loop_thread = threading.Thread(
                target=self._run_event_loop, daemon=True
            )
            self._loop_thread.start()

        # --------------------
        # Event Fd Interface
        # --------------------

        def get_store_event_fd(self) -> int:
            return self._store_efd.fileno()

        def get_lookup_and_lock_event_fd(self) -> int:
            return self._lookup_efd.fileno()

        def get_load_event_fd(self) -> int:
            return self._load_efd.fileno()

        #####################
        # Store Interface
        #####################

        def submit_store_task(
            self,
            keys: list["ObjectKey"],
            objects: list["MemoryObj"],
        ) -> L2TaskId:
            with self._lock:
                task_id = self._get_next_task_id()

            asyncio.run_coroutine_threadsafe(
                self._execute_store_in_the_loop(keys, objects, task_id), self._loop
            )
            return task_id

        def pop_completed_store_tasks(self) -> dict[L2TaskId, "L2StoreResult"]:
            with self._lock:
                completed = self._completed_store_tasks
                self._completed_store_tasks = {}
            return completed

        #####################
        # Lookup and Lock Interface
        #####################

        def submit_lookup_and_lock_task(
            self,
            keys: list["ObjectKey"],
            group_layout_descs: dict[int, "MemoryLayoutDesc"],
        ) -> L2TaskId:
            with self._lock:
                task_id = self._get_next_task_id()
                # Counted HERE, on the synchronous entry, deliberately —
                # not inside the coroutine. This is the only place that
                # answers "did the layer above us actually call lookup",
                # independently of whether our event loop then ran it
                # (TODO 6.28).
                self._l2_lookup_calls += 1
                self._l2_lookup_keys += len(keys)

            # Unlike nixl_store's plain call_soon_threadsafe (safe there
            # because a dict-only lookup is fast enough to run inline),
            # nixl_kv's lookup can hit the device (query_memory) and must
            # be able to await a bounded deadline without blocking the
            # event loop (spec §6 Lookup) — so this is scheduled as a
            # coroutine, not a plain callback.
            asyncio.run_coroutine_threadsafe(
                self._execute_lookup_in_the_loop(keys, task_id), self._loop
            )
            return task_id

        def query_lookup_and_lock_result(self, task_id: L2TaskId) -> Optional["Bitmap"]:
            with self._lock:
                return self._completed_lookup_tasks.pop(task_id, None)

        def submit_unlock(self, keys: list["ObjectKey"]) -> None:
            def _unlock_keys(keys: list["ObjectKey"]) -> None:
                for key in keys:
                    obj = self._memory_objects.get(key)
                    if obj is not None:
                        obj.decrease_pin_count()

            self._loop.call_soon_threadsafe(_unlock_keys, keys)

        #####################
        # Load Interface
        ######################

        def submit_load_task(
            self,
            keys: list["ObjectKey"],
            objects: list["MemoryObj"],
        ) -> L2TaskId:
            with self._lock:
                task_id = self._get_next_task_id()

            asyncio.run_coroutine_threadsafe(
                self._execute_load_in_loop(keys, objects, task_id), self._loop
            )
            return task_id

        def query_load_result(self, task_id: L2TaskId) -> Optional["Bitmap"]:
            with self._lock:
                return self._completed_load_tasks.pop(task_id, None)

        def close(self) -> None:
            async def _stop_tasks():
                tasks = [
                    t
                    for t in asyncio.all_tasks(self._loop)
                    if t is not asyncio.current_task()
                ]
                for task in tasks:
                    task.cancel()
                if tasks:
                    await asyncio.gather(*tasks, return_exceptions=True)

            if not self._loop.is_closed():
                try:
                    future = asyncio.run_coroutine_threadsafe(_stop_tasks(), self._loop)
                    future.result(timeout=5)
                finally:
                    self._loop.call_soon_threadsafe(self._loop.stop)

            self._loop_thread.join()
            self._probe_executor.shutdown(wait=False)
            try:
                self.nixl_agent.close()
            finally:
                self._loop.close()
                self._store_efd.close()
                self._lookup_efd.close()
                self._load_efd.close()

        #####################
        # Eviction Interface
        #####################

        def delete(self, keys: list["ObjectKey"]) -> None:
            """Remove the index entry only — there is no device delete
            for nixl_kv (spec §6 "Delete / eviction", §10): device space
            is never reclaimed. Logged plainly at WARNING so an operator
            watching logs sees monotonic device growth, not a silent
            no-op that looks like real eviction.
            """
            deleted_keys: list["ObjectKey"] = []
            deleted_sizes: list[int] = []
            with self._lock:
                for key in keys:
                    obj = self._memory_objects.get(key)
                    if obj is None:
                        continue
                    if obj.pin_count > 0:
                        logger.debug(
                            "nixl_kv: skipping eviction of pinned key %s "
                            "(pin_count=%d)",
                            key,
                            obj.pin_count,
                        )
                        continue
                    del self._memory_objects[key]
                    # Only keys that reached a confirmed size (i.e. were
                    # actually _notify_keys_stored'd) should be reported
                    # deleted -- a lazily-discovered key that was never
                    # successfully loaded has no matching "stored" credit
                    # to reverse.
                    if obj.recorded and obj.size is not None:
                        deleted_keys.append(key)
                        deleted_sizes.append(obj.size)
            if deleted_keys:
                logger.warning(
                    "nixl_kv: dropped index entry for %d key(s); the "
                    "underlying device objects are NOT reclaimed (no "
                    "device delete primitive — spec §6/§10). Namespace "
                    "%r usage is monotonic until the namespace is reset "
                    "(scripts/target/50-reset-namespace.sh).",
                    len(deleted_keys),
                    self._ns,
                )
                self._notify_keys_deleted(deleted_keys, deleted_sizes)

        #####################
        # Status Interface
        #####################

        def report_status(self) -> dict:
            """Return a status dict — spec §8's five outcome counters, the
            five attempt counters added for TODO 6.28, and the same shape
            as ``NixlStoreL2Adapter.report_status()``.
            """
            with self._lock:
                stored_object_count = len(self._memory_objects)
                pinned_object_count = sum(
                    1 for obj in self._memory_objects.values() if obj.pin_count > 0
                )
                counters = {
                    # Outcomes (spec §8).
                    "l2_index_hits": self._l2_index_hits,
                    "l2_device_hits": self._l2_device_hits,
                    "l2_probe_errors": self._l2_probe_errors,
                    "l2_commit_writes": self._l2_commit_writes,
                    "l2_load_aborts": self._l2_load_aborts,
                    # Attempts (TODO 6.28) — without these a zero in the
                    # block above is undiagnosable. See __init__.
                    "l2_lookup_calls": self._l2_lookup_calls,
                    "l2_lookup_keys": self._l2_lookup_keys,
                    "l2_lookup_executions": self._l2_lookup_executions,
                    "l2_keys_probed": self._l2_keys_probed,
                    "l2_probe_misses": self._l2_probe_misses,
                }
            return {
                "is_healthy": self._loop_thread.is_alive(),
                "type": "NixlKvL2Adapter",
                "backend": self._config.backend,
                "namespace": self._ns,
                "stored_object_count": stored_object_count,
                "pinned_object_count": pinned_object_count,
                "event_loop_alive": self._loop_thread.is_alive(),
                **counters,
            }

        ##################
        # Helper functions
        ##################

        def _run_event_loop(self) -> None:
            asyncio.set_event_loop(self._loop)
            self._loop.run_forever()

        def _get_next_task_id(self) -> L2TaskId:
            task_id = self._next_task_id
            self._next_task_id += 1
            return task_id

        def _signal_store_event(self) -> None:
            self._store_efd.notify()

        def _signal_lookup_event(self) -> None:
            self._lookup_efd.notify()

        def _signal_load_event(self) -> None:
            self._load_efd.notify()

        def _log_probe_error(self, exc: BaseException) -> None:
            """Rate-limited WARNING for a probe failure (spec §6 Lookup
            item 5). A persistently broken device must not flood the log
            at request rate, but it must never be silent either — that
            silence is exactly how a dead probe path degrades to a
            permanent 0% hit rate that looks like today's bug (spec §6
            Lookup item 5 closing sentence).
            """
            now = time.monotonic()
            with self._probe_log_lock:
                if now - self._last_probe_error_log < _PROBE_ERROR_LOG_INTERVAL_S:
                    return
                self._last_probe_error_log = now
            logger.warning(
                "nixl_kv: query_memory probe failed (l2_probe_errors=%d so "
                "far): %r",
                self._l2_probe_errors,
                exc,
            )

        def _log_first_probe_name(self, commit_names: list[str]) -> None:
            """One-shot INFO naming the first commit key this daemon ever
            probes (TODO 6.28).

            Its counterpart is :meth:`_log_first_commit_name` on the store
            path. Together they turn "does the reader look for the name
            the writer wrote?" into a direct comparison of one line from
            each daemon's log — the question 6.28 has to answer next, and
            the one the outcome-only counters could not even pose.

            One-shot, not rate-limited: the *first* name is the evidence.
            Logging every batch would bury it at request rate.
            """
            if self._logged_first_probe_name or not commit_names:
                return
            with self._probe_log_lock:
                if self._logged_first_probe_name:
                    return
                self._logged_first_probe_name = True
            logger.info(
                "nixl_kv: FIRST DEVICE PROBE ns=%s batch=%d first_commit_name=%s",
                self._ns,
                len(commit_names),
                commit_names[0],
            )

        def _log_first_commit_name(self, commit_names: list[str]) -> None:
            """One-shot INFO naming the first commit key this daemon ever
            writes — the writer-side counterpart of
            :meth:`_log_first_probe_name` (TODO 6.28).
            """
            if self._logged_first_commit_name or not commit_names:
                return
            with self._probe_log_lock:
                if self._logged_first_commit_name:
                    return
                self._logged_first_commit_name = True
            logger.info(
                "nixl_kv: FIRST COMMIT WRITE ns=%s batch=%d first_commit_name=%s",
                self._ns,
                len(commit_names),
                commit_names[0],
            )

        async def _execute_store_in_the_loop(
            self,
            keys: list["ObjectKey"],
            objects: list["MemoryObj"],
            task_id: L2TaskId,
        ) -> None:
            """Batched store (spec §6 Store).

            Ordering is the whole point (spec §6 Store closing note): a
            key is never discoverable until its pages are durable.
            1. One flattened, batched page WRITE across every key in this
               task (mirrors ``nixl_store``'s monolithic batching, per
               spec §6 Store step 4 "exactly as nixl_store does"), using
               the persistent L1 dlist unchanged.
            2. Await completion; ``post_non_blocking`` (inherited,
               unchanged) raises on ``ERR``, never returns "half done".
            3. Only then: one flattened commit WRITE across the same keys.
            4. Only then: index insert + ``_notify_keys_stored``.
            Any exception anywhere in this sequence fails the whole task
            (matches the base class's documented coarse-grained store
            error contract) and nothing from this task is ever inserted
            into the index.
            """
            success = True
            bytes_transferred = 0
            page_reg_descs = None
            page_xfer_handler = None
            try:
                mem_indices_flat: list[int] = []
                page_names_flat: list[str] = []
                # (key, obj, key_string, page_count, phy_size) per key
                # actually included in this batch.
                store_infos: list[tuple["ObjectKey", "MemoryObj", str, int, int]] = []

                for key, obj in zip(keys, objects, strict=False):
                    with self._lock:
                        if key in self._memory_objects:
                            continue

                    mem_addr = obj.meta.address
                    mem_size = obj.meta.phy_size
                    # spec §7 assert 2: page_size divides phy_size exactly.
                    page_count = page_count_for(mem_size, self._align_bytes)
                    mem_indices = self.nixl_agent.get_memory_indices(mem_addr, mem_size)
                    key_string = object_key_to_string(key)

                    page_names_flat.extend(
                        page_name(self._ns, key_string, i) for i in range(page_count)
                    )
                    mem_indices_flat.extend(mem_indices)
                    store_infos.append((key, obj, key_string, page_count, mem_size))

                if not store_infos:
                    # Nothing to store (all keys already existed).
                    with self._lock:
                        self._completed_store_tasks[task_id] = L2StoreResult(True, 0)
                    self._signal_store_event()
                    return

                # ---- pages: one batched WRITE (spec §6 Store step 4). ----
                page_reg_descs, page_xfer_handler = self.nixl_agent.register_obj_names(
                    page_names_flat, self._align_bytes
                )
                page_storage_indices = list(range(len(page_names_flat)))
                handle = self.nixl_agent.make_transfer(
                    "WRITE",
                    self.nixl_agent.mem_xfer_handler,
                    mem_indices_flat,
                    page_xfer_handler,
                    page_storage_indices,
                )
                # spec §6 Store step 5: await completion, verify DONE not
                # ERR. post_non_blocking (inherited, unchanged) raises
                # RuntimeError on ERR.
                await self.nixl_agent.post_non_blocking(handle)
                self.nixl_agent.release_handle(handle)

                # ---- release the page dlist BEFORE the commit dlist is
                # created. Defence in depth alongside the monotonic devId
                # allocation in register_obj_names() (TODO 6.34): keeping
                # exactly one OBJ registration live across this boundary
                # means the commit descriptors cannot resolve against the
                # page registration even if descriptor identity is
                # weaker than devId. The pages are durable here —
                # post_non_blocking raises on ERR — so releasing them now
                # preserves the commit-after-durable ordering that is the
                # whole atomicity story (spec §6 Store). Cleared so the
                # trailing finally does not deregister twice.
                self.nixl_agent.deregister_obj_names(
                    page_reg_descs, page_xfer_handler
                )
                page_reg_descs = None
                page_xfer_handler = None

                # ---- commit objects: only written after pages are
                # confirmed durable (spec §6 Store step 6). One flattened
                # WRITE across all keys in this task, same shape as the
                # page write above but sourced from a synthesized host
                # buffer instead of the caller's L1 memory.
                commit_payloads = [
                    encode_commit_payload(
                        self._ns, page_count, self._align_bytes, phy_size
                    )
                    for _, _, _, page_count, phy_size in store_infos
                ]
                commit_buf, commit_mem_reg, commit_mem_xfer = (
                    self.nixl_agent.register_host_buffer(
                        len(commit_payloads) * self._align_bytes, self._align_bytes
                    )
                )
                for i, payload in enumerate(commit_payloads):
                    off = i * self._align_bytes
                    commit_buf[off : off + len(payload)] = payload

                commit_names = [
                    commit_name(self._ns, key_string)
                    for _, _, key_string, _, _ in store_infos
                ]
                self._log_first_commit_name(commit_names)
                commit_storage_reg, commit_storage_xfer = (
                    self.nixl_agent.register_obj_names(commit_names, self._align_bytes)
                )
                try:
                    commit_indices = list(range(len(commit_names)))
                    commit_handle = self.nixl_agent.make_transfer(
                        "WRITE",
                        commit_mem_xfer,
                        commit_indices,
                        commit_storage_xfer,
                        commit_indices,
                    )
                    await self.nixl_agent.post_non_blocking(commit_handle)
                    self.nixl_agent.release_handle(commit_handle)
                finally:
                    self.nixl_agent.deregister_obj_names(
                        commit_storage_reg, commit_storage_xfer
                    )
                    self.nixl_agent.deregister_host_buffer(
                        commit_mem_reg, commit_mem_xfer
                    )

                # ---- only now is each key durably discoverable. ----
                stored_keys: list["ObjectKey"] = []
                stored_sizes: list[int] = []
                with self._lock:
                    for key, obj, key_string, page_count, phy_size in store_infos:
                        self._memory_objects[key] = NixlKvObj(
                            key_string=key_string,
                            page_count=page_count,
                            size=phy_size,
                            layout=MemoryLayoutDesc([obj.meta.shape], [obj.meta.dtype]),
                            recorded=True,
                        )
                        stored_keys.append(key)
                        stored_sizes.append(phy_size)
                    self._l2_commit_writes += len(store_infos)

                self._notify_keys_stored(stored_keys, stored_sizes)
                bytes_transferred = sum(stored_sizes)

            except Exception:
                logger.exception("nixl_kv store task %d failed", task_id)
                success = False
                bytes_transferred = 0
            finally:
                if page_xfer_handler is not None:
                    self.nixl_agent.deregister_obj_names(
                        page_reg_descs, page_xfer_handler
                    )

            with self._lock:
                self._completed_store_tasks[task_id] = L2StoreResult(
                    success, bytes_transferred
                )
            self._signal_store_event()

        async def _execute_lookup_in_the_loop(
            self, keys: list["ObjectKey"], task_id: L2TaskId
        ) -> None:
            """Batched lookup and pin (spec §6 Lookup).

            1. In-process ``_memory_objects`` hit -> ``l2_index_hits``.
            2. Otherwise, one batched ``query_memory`` Exist probe over
               *commit keys only* (never per-page) for everything that
               missed step 1.
            3. ``resp[i] is not None`` — never truthiness (see
               :func:`is_probe_hit`).
            4. Device hit -> ``l2_device_hits``, lazily populate
               ``_memory_objects`` (size/page_count filled in later by
               Load), set the bit, take the pin.
            5. A probe exception (backend error) or a deadline timeout is
               counted as ``l2_probe_errors`` and reported as a miss for
               the whole to-probe batch — never a fabricated hit.

            Every step also counts its *attempt* (TODO 6.28), so a
            zero-hit reading stays diagnosable: see the counter block in
            ``__init__`` for how to read the combination.
            """
            bitmap = Bitmap(len(keys))
            to_probe: list[tuple[int, "ObjectKey", str]] = []

            with self._lock:
                self._l2_lookup_executions += 1
                for i, key in enumerate(keys):
                    obj = self._memory_objects.get(key)
                    if obj is not None:
                        bitmap.set(i)
                        obj.increase_pin_count()
                        self._l2_index_hits += 1
                        continue
                    to_probe.append((i, key, object_key_to_string(key)))

            if to_probe:
                commit_names = [commit_name(self._ns, ks) for _, _, ks in to_probe]
                with self._lock:
                    self._l2_keys_probed += len(commit_names)
                self._log_first_probe_name(commit_names)
                loop = asyncio.get_running_loop()
                resp = None
                try:
                    resp = await asyncio.wait_for(
                        loop.run_in_executor(
                            self._probe_executor,
                            self.nixl_agent.query_exists,
                            commit_names,
                        ),
                        timeout=self._probe_deadline_s,
                    )
                except Exception as exc:
                    # Covers both a genuine backend error surfaced by
                    # query_memory (NIXL_ERR_BACKEND — spec §6 Lookup
                    # item 5 / §7 assert 5) and our own deadline timeout
                    # (asyncio.TimeoutError): both mean "cannot trust the
                    # device right now", never a fabricated hit.
                    with self._lock:
                        self._l2_probe_errors += 1
                    self._log_probe_error(exc)

                if resp is not None:
                    with self._lock:
                        for (i, key, key_string), entry in zip(
                            to_probe, resp, strict=True
                        ):
                            if not is_probe_hit(entry):
                                # Counted explicitly rather than derived,
                                # so "the device said absent" is a fact in
                                # the status dict and not an inference
                                # from three other numbers (TODO 6.28).
                                self._l2_probe_misses += 1
                                continue
                            obj = self._memory_objects.get(key)
                            if obj is None:
                                obj = NixlKvObj(key_string=key_string)
                                self._memory_objects[key] = obj
                            bitmap.set(i)
                            obj.increase_pin_count()
                            self._l2_device_hits += 1

            with self._lock:
                self._completed_lookup_tasks[task_id] = bitmap
            self._signal_lookup_event()

        async def _execute_load_in_loop(
            self,
            keys: list["ObjectKey"],
            objects: list["MemoryObj"],
            task_id: L2TaskId,
        ) -> None:
            """Batched load (spec §6 Load).

            Each key is its own independent "group" (spec §6 Load /
            §9 closing note: one ``ObjectKey`` is up to ~9,216 pages) and
            is processed as its own coroutine, gathered with
            ``return_exceptions=True`` — the dynamic adapter's precedent
            for "one key's failure must not blind its siblings in the
            same batch" (see ``nixl_store_dynamic_l2_adapter.py``'s
            ``_execute_load_in_loop``). This is what gives us the
            required per-group abort granularity: a batched multi-key
            transfer has one coarse DONE/ERR for the whole handle, which
            would let one bad key fail everyone else's load too.
            """
            bitmap = Bitmap(len(keys))
            accessed_keys: list["ObjectKey"] = []
            newly_recorded_keys: list["ObjectKey"] = []
            newly_recorded_sizes: list[int] = []

            async def _load_one(i: int, key: "ObjectKey", mem_obj: "MemoryObj") -> None:
                with self._lock:
                    storage_obj = self._memory_objects.get(key)
                if storage_obj is None:
                    # Never looked up / never stored with this adapter —
                    # not a candidate for load.
                    return

                key_string = storage_obj.key_string
                expected_size = mem_obj.meta.phy_size
                expected_pages = page_count_for(expected_size, self._align_bytes)

                # ---- spec §6 Load step 1: read the commit object first. ----
                commit_buf, commit_mem_reg, commit_mem_xfer = (
                    self.nixl_agent.register_host_buffer(
                        self._align_bytes, self._align_bytes
                    )
                )
                commit_storage_reg, commit_storage_xfer = (
                    self.nixl_agent.register_obj_names(
                        [commit_name(self._ns, key_string)], self._align_bytes
                    )
                )
                try:
                    handle = self.nixl_agent.make_transfer(
                        "READ", commit_mem_xfer, [0], commit_storage_xfer, [0]
                    )
                    await self.nixl_agent.post_non_blocking(handle)
                    self.nixl_agent.release_handle(handle)
                    payload = decode_commit_payload(bytes(commit_buf))
                    # spec §6 Load step 2: any mismatch aborts the whole
                    # group (this key) and reports miss.
                    validate_commit_payload(
                        payload,
                        ns=self._ns,
                        page_size=self._align_bytes,
                        expected_pages=expected_pages,
                    )
                except Exception:
                    with self._lock:
                        self._l2_load_aborts += 1
                    logger.warning(
                        "nixl_kv: load aborted for key %s — commit "
                        "read/validate failed",
                        key_string,
                        exc_info=True,
                    )
                    return
                finally:
                    self.nixl_agent.deregister_obj_names(
                        commit_storage_reg, commit_storage_xfer
                    )
                    self.nixl_agent.deregister_host_buffer(
                        commit_mem_reg, commit_mem_xfer
                    )

                # ---- spec §6 Load step 3: batched READ of all pages. ----
                page_names = [
                    page_name(self._ns, key_string, o) for o in range(expected_pages)
                ]
                page_storage_reg, page_storage_xfer = self.nixl_agent.register_obj_names(
                    page_names, self._align_bytes
                )
                try:
                    mem_indices = self.nixl_agent.get_memory_indices(
                        mem_obj.meta.address, expected_size
                    )
                    handle = self.nixl_agent.make_transfer(
                        "READ",
                        self.nixl_agent.mem_xfer_handler,
                        mem_indices,
                        page_storage_xfer,
                        list(range(expected_pages)),
                    )
                    await self.nixl_agent.post_non_blocking(handle)
                    self.nixl_agent.release_handle(handle)
                except Exception:
                    # spec §6 Load step 4: any sub-read failure aborts
                    # the entire group — never a partial hit.
                    with self._lock:
                        self._l2_load_aborts += 1
                    logger.warning(
                        "nixl_kv: load aborted for key %s — page read failed",
                        key_string,
                        exc_info=True,
                    )
                    return
                finally:
                    self.nixl_agent.deregister_obj_names(
                        page_storage_reg, page_storage_xfer
                    )

                with self._lock:
                    if storage_obj.page_count is None:
                        storage_obj.page_count = expected_pages
                        storage_obj.size = expected_size
                    record_now = not storage_obj.recorded
                    if record_now:
                        storage_obj.recorded = True
                if record_now:
                    # spec §6 Lookup item 4: a lazily-populated (device
                    # hit) entry only gets its first _notify_keys_stored
                    # once Load has actually confirmed its real size via
                    # the commit object — an OBJ Exist probe carries no
                    # size (spec §2), so accounting cannot happen any
                    # earlier without risking bogus byte counts.
                    newly_recorded_keys.append(key)
                    newly_recorded_sizes.append(expected_size)

                bitmap.set(i)
                accessed_keys.append(key)

            tasks = [
                _load_one(i, key, objects[i]) for i, key in enumerate(keys)
            ]
            if tasks:
                results = await asyncio.gather(*tasks, return_exceptions=True)
                for key, result in zip(keys, results, strict=True):
                    if isinstance(result, BaseException):
                        logger.exception(
                            "nixl_kv: unexpected error loading key %s", key,
                            exc_info=result,
                        )

            if accessed_keys:
                self._notify_keys_accessed(accessed_keys)
            if newly_recorded_keys:
                self._notify_keys_stored(newly_recorded_keys, newly_recorded_sizes)

            with self._lock:
                self._completed_load_tasks[task_id] = bitmap
            self._signal_load_event()

    # -------------------------------------------------------------------
    # Config and self-registration
    # -------------------------------------------------------------------

    #: OBJ/KV-addressed backends only (spec §3: "retargeting that shape
    #: to OBJ/KV") — file-based backends (GDS/POSIX/HF3FS/...) have no
    #: content-key primitive and are out of scope for this adapter;
    #: nixl_store / nixl_store_dynamic already cover them.
    _VALID_NIXL_KV_BACKENDS = ("OBJ", "AZURE_BLOB", "SPDK_NVMe_KV", "XNVME_KV")

    class NixlKvL2AdapterConfig(L2AdapterConfigBase):
        """
        Config for the content-addressed nixl_kv L2 adapter.

        Fields:
        - backend: Nixl OBJ/KV storage backend
          (OBJ, AZURE_BLOB, SPDK_NVMe_KV, XNVME_KV).
        - backend_params: Backend-specific parameters as a dict of
          string key-value pairs (optional, default empty).
        - namespace: geometry fingerprint (spec §5). Required,
          non-empty, and must not contain '@', '~', or '!' (spec §7
          assert 3) — those are this adapter's wire-format field,
          ordinal, and commit-marker separators (spec §4).

        Note: unlike ``NixlStoreL2AdapterConfig``, ``pool_size`` is
        **rejected** if present, not silently ignored (spec §7 assert 4)
        — nixl_kv is content-addressed and has no slot pool, so a config
        that still specifies one is almost certainly a copy-paste from a
        ``nixl_store`` spec and deserves a loud error, not a config that
        quietly behaves differently from what was asked.
        """

        def __init__(
            self, backend: str, backend_params: dict[str, str], namespace: str
        ):
            self.backend = backend
            self.backend_params = backend_params
            self.namespace = namespace

        @classmethod
        def from_dict(cls, d: dict) -> "NixlKvL2AdapterConfig":
            backend = d.get("backend")
            if backend not in _VALID_NIXL_KV_BACKENDS:
                raise ValueError(
                    "backend must be one of %s, got %r"
                    % (_VALID_NIXL_KV_BACKENDS, backend)
                )

            backend_params = d.get("backend_params", {})
            if not isinstance(backend_params, dict):
                raise ValueError(
                    "backend_params must be a dict of string key-value pairs"
                )

            # spec §7 assert 4: reject, don't ignore.
            if "pool_size" in d:
                raise ValueError(
                    "nixl_kv does not take 'pool_size': it is "
                    "content-addressed and has no slot pool (spec §7 "
                    "assert 4). Remove 'pool_size' from the adapter config."
                )

            namespace = d.get("namespace")
            if not isinstance(namespace, str):
                raise ValueError("namespace (str) is required")
            validate_namespace(namespace)

            return cls(
                backend=backend, backend_params=backend_params, namespace=namespace
            )

        @classmethod
        def help(cls) -> str:
            return (
                "Nixl KV (content-addressed) L2 adapter config fields:\n"
                "- backend (str): Nixl OBJ/KV storage backend, "
                "one of %s (required)\n"
                "- backend_params (dict): backend-specific "
                "string key-value pairs (optional, default empty)\n"
                "- namespace (str): geometry fingerprint (required, "
                "non-empty, must not contain '@', '~' or '!')\n"
                "- 'pool_size' is NOT accepted here -- nixl_kv is "
                "content-addressed and has no slot pool; including it "
                "is a config error, not a no-op."
                % (_VALID_NIXL_KV_BACKENDS,)
            )

    # Self-register config type and adapter factory
    register_l2_adapter_type("nixl_kv", NixlKvL2AdapterConfig)

    def _create_nixl_kv_adapter(
        config: "L2AdapterConfigBase",
        l1_memory_desc: Optional["L1MemoryDesc"] = None,
    ) -> "L2AdapterInterface":
        """Create a NixlKvL2Adapter from config."""
        if l1_memory_desc is None:
            raise ValueError("l1_memory_desc is required to create a NixlKvL2Adapter.")
        return NixlKvL2Adapter(config, l1_memory_desc)  # type: ignore[arg-type]

    register_l2_adapter_factory("nixl_kv", _create_nixl_kv_adapter)
