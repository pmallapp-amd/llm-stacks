# SPDX-License-Identifier: Apache-2.0
"""
nixl_kv_thin_l2_adapter.py — content-addressed NIXL L2 adapter whose
splitting/naming/atomicity protocol lives in the NIXL plugin, not here.

This branch carries ONLY this adapter (the earlier Python-side nixl_kv —
which tiled each object into ``phy_size / align_bytes``
``{ns}@{key}~{ordinal}`` pages, wrote a separate ``{ns}@{key}!c`` commit
object only after every page was durable, and hard-refused to start if
``align_bytes`` ever exceeded the backend's declared ``max_value_size`` —
and the vendor's per-daemon-uuid4 ``nixl_store`` have both been removed).

This file registers and transfers the WHOLE object as ONE descriptor under
ONE name, ``{ns}@{key}``. ``plugins/xnvme-kv/xnvme_kv_backend.cpp`` does the
rest: it tiles anything over the (dynamically queried) ``max_value_size``
into exactly the same ``~{ordinal}``/``!c`` grammar, with the exact same
atomicity guarantee (no commit marker until every part is durable), but
entirely inside the plugin — this module never constructs a page name,
never writes a commit object, and never asserts a size ceiling, because
none of that is this layer's problem anymore. See
``docs/design/nixl-kv-l2-adapter.md`` for the protocol this still conforms
to on the wire (still accurate even though the adapter it was written
against has been removed — the wire grammar it documents is now owned by
the plugin instead).

DOES NOT USE LMCache's persistent pinned L1 buffer
(``NixlStorageAgent.init_mem_handlers()``'s shared, ``align_bytes``-tiled
dlist, reused unchanged by both ``nixl_kv`` and the vendor ``nixl_store``).
That strategy registers the local/DRAM side as ``ceil(size/align_bytes)``
separate fixed-size descriptors for ANY object bigger than one page —
confirmed empirically (``docs/TODO.md`` §6.35: a 256 KB chunk is always 64
pages, never 1) — and NIXL's own ``prepXfer()`` requires the local and
remote descriptor counts in one transfer to match 1:1
(``xnvme_kv_backend.cpp``'s ``local.descCount() != remote.descCount()``
check). A persistent, page-tiled local side can therefore never be paired
with a single storage name in one ``transfer()`` call — there is no way to
hand the plugin "one object, arbitrary size" while routing through that
buffer. Every store/load here instead registers exactly the DRAM range
involved in THIS call, ephemerally — the same pattern
``_nixl_kv_thin_smoke.py`` uses — so NIXL always hands the plugin ONE local
descriptor per object, and the plugin's fan-out genuinely does all the
splitting. The trade-off is explicit and intentional: this pays a
register_memory/deregister_memory round trip on every store and load,
instead of reusing one persistent pinned-buffer registration. No
measurement of that cost has been taken yet on real hardware — do that
before trusting this on the serving path.

Self-registers as L2 adapter type ``"nixl_kv_thin"`` (see
``l2_adapters/__init__.py``'s ``pkgutil``-based auto-discovery of any
``*_l2_adapter.py`` module — no vendor-file change needed).
"""

# Future
from __future__ import annotations

# Standard
from dataclasses import dataclass, field
from typing import Optional
import asyncio
import threading
import uuid

_NIXL_KV_THIN_RUNTIME_AVAILABLE = True
try:
    # Third Party
    from nixl._api import nixl_agent as NixlAgent
    from nixl._api import nixl_agent_config as NixlAgentConfig

    # First Party
    from lmcache.logging import init_logger
    from lmcache.native_storage_ops import Bitmap
    from lmcache.v1.distributed.api import ObjectKey
    from lmcache.v1.distributed.internal_api import L1MemoryDesc, L2StoreResult
    from lmcache.v1.distributed.l2_adapters.base import L2AdapterInterface, L2TaskId
    from lmcache.v1.distributed.l2_adapters.config import (
        L2AdapterConfigBase,
        register_l2_adapter_type,
    )
    from lmcache.v1.distributed.l2_adapters.factory import (
        register_l2_adapter_factory,
    )
    from lmcache.v1.memory_management import MemoryObj
    from lmcache.v1.platform import create_event_notifier
except ImportError:
    _NIXL_KV_THIN_RUNTIME_AVAILABLE = False

if _NIXL_KV_THIN_RUNTIME_AVAILABLE:
    logger = init_logger(__name__)
else:  # pragma: no cover - exercised only on the control host without lmcache
    import logging as _logging

    logger = _logging.getLogger(__name__)


#: Forbidden in a namespace value: '@' is the ns/key-string field separator,
#: '~' is the page-ordinal separator, '!' marks a commit name. A namespace
#: containing any of these could alias onto an unrelated page/commit name.
_NS_FORBIDDEN_CHARS = frozenset("@~!")

#: Sleep granularity while polling an in-flight xfer handle. Matches
#: _nixl_kv_thin_smoke.py's blocking poll loop — same device, same
#: observed completion latency (~57 us per the design doc).
_XFER_POLL_INTERVAL_S = 0.0005


def validate_namespace(ns: str) -> None:
    """Validate a geometry-fingerprint namespace
    (docs/design/nixl-kv-l2-adapter.md §5, §7 assert 3).

    Raises:
        ValueError: ``ns`` is empty, or contains ``@``, ``~``, or ``!``.
    """
    if not ns:
        raise ValueError(
            "nixl_kv_thin: 'namespace' must be non-empty (spec §7 assert 3)"
        )
    bad = _NS_FORBIDDEN_CHARS & set(ns)
    if bad:
        raise ValueError(
            "nixl_kv_thin: 'namespace' must not contain %s (got %r) "
            "(spec §7 assert 3)" % (sorted(bad), ns)
        )


def object_key_to_string(key) -> str:
    """Serialize an ObjectKey to the deterministic on-device name fragment.

    ``<model_name>@<kv_rank:08x>@<object_group_id:x>@<chunk_hash_hex>[@<cache_salt>]``

    DELIBERATELY SPELLED HERE RATHER THAN IMPORTED. LMCache ships **four
    independent copies** of this function (``s3_l2_adapter``,
    ``bigtable_l2_adapter``, ``hfbucket_l2_adapter``,
    ``native_connector_l2_adapter``) — the first three byte-identical, the
    fourth parameterised on a module-level ``_KEY_SEP`` that merely agrees
    with the others today. Every one is private (``_``-prefixed): none is a
    public API, and nothing stops a vendor image from editing any of them.

    This string is our **persistence format** — it determines the 12-byte
    device key via the plugin's FNV-1a derivation. Importing it would make
    our on-device naming hostage to a vendor edit we cannot see, and because
    this backend has **no delete primitive**, a silent format change does
    not degrade gracefully: every object already on the device becomes
    unreachable at once, and two nodes on different images would silently
    stop agreeing on names. So: own it.

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

    PRESENT is an empty, **falsy** dict (``{}``); ABSENT is ``None``. This
    is the single, deliberate point of truth for that distinction: identity
    check (``is not None``), never truthiness (``bool(x)`` / ``if x:``). A
    truthiness-based check silently scores every hit as a miss.
    """
    return resp_entry is not None


if _NIXL_KV_THIN_RUNTIME_AVAILABLE:

    @dataclass
    class NixlKvThinObj:
        """In-process record for one content-addressed object.

        No ``page_count``/``layout`` tracking — unlike ``NixlKvObj``, there
        is no commit payload for this adapter to read back and validate: the
        plugin's own commit-marker protocol is the only source of truth for
        "is this object fully durable", and this adapter never inspects it
        directly (queryMem()/a retrieve either succeed or report absent).
        """

        key_string: str
        size: Optional[int] = None
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
                        "nixl_kv_thin: decreasing pin count of key %s below 0",
                        self.key_string,
                    )

    @dataclass
    class _ThinXfer:
        """One in-flight ephemeral transfer: the handle to poll, plus the
        local/remote registrations to tear down once it settles. Neither
        registration is shared with any other call — see module docstring
        for why this adapter never reuses a persistent registration."""

        handle: object
        local: object
        remote: object

    class NixlKvThinStorageAgent:
        """Storage-side NIXL glue for the thin adapter.

        Does NOT subclass ``NixlStorageAgent`` and does NOT call
        ``init_mem_handlers`` — see module docstring: that machinery
        registers LMCache's persistent pinned L1 buffer as one
        ``align_bytes``-tiled dlist, which forces NIXL to see N local
        descriptors for any object bigger than one page, and NIXL requires
        the paired remote (storage) side to carry the same N — permanently
        ruling out "one descriptor, one name" for an object routed through
        that buffer. Every store/load below instead does its own ephemeral
        ``register_memory``/``transfer``/``deregister_memory`` round trip,
        exactly the shape ``_nixl_kv_thin_smoke.py`` uses.
        """

        def __init__(self, backend: str, backend_params: dict[str, str]):
            self.backend = backend
            self.backend_params = backend_params

            self.agent_name = "NixlKvThinAgent_" + str(uuid.uuid4())
            nixl_conf = NixlAgentConfig(backends=[])
            self.nixl_agent = NixlAgent(self.agent_name, nixl_conf)
            self.nixl_agent.create_backend(backend, backend_params)

        def _start_xfer(self, op: str, addr: int, size: int, name: str) -> "_ThinXfer":
            local = self.nixl_agent.register_memory(
                [(addr, size, 0, "")], "DRAM", backends=[self.backend]
            )
            remote = self.nixl_agent.register_memory(
                [(0, size, 0, name)], "OBJ", backends=[self.backend]
            )
            handle = self.nixl_agent.initialize_xfer(
                op, local.trim(), remote.trim(), self.agent_name
            )
            self.nixl_agent.transfer(handle)
            return _ThinXfer(handle=handle, local=local, remote=remote)

        def start_store(self, addr: int, size: int, name: str) -> "_ThinXfer":
            return self._start_xfer("WRITE", addr, size, name)

        def start_load(self, addr: int, size: int, name: str) -> "_ThinXfer":
            return self._start_xfer("READ", addr, size, name)

        async def await_xfer(self, xfer: "_ThinXfer") -> str:
            """Poll to completion (or failure), then tear down both
            ephemeral registrations. Returns the final xfer state
            (``"DONE"`` on success) — callers decide what a non-DONE state
            means for the object it belongs to.
            """
            state = self.nixl_agent.check_xfer_state(xfer.handle)
            while state == "PROC":
                await asyncio.sleep(_XFER_POLL_INTERVAL_S)
                state = self.nixl_agent.check_xfer_state(xfer.handle)
            self.nixl_agent.release_xfer_handle(xfer.handle)
            self.nixl_agent.deregister_memory(xfer.local, backends=[self.backend])
            self.nixl_agent.deregister_memory(xfer.remote, backends=[self.backend])
            return state

        def query_exists(self, names: list[str]):
            """Probe presence only. Pass the BARE ``{ns}@{key}`` name — the
            plugin's queryMem() appends its own ``!c`` suffix internally
            before deriving the device key; this layer never constructs a
            commit name itself. Matches nixl_kv_l2_adapter.py's own
            query_exists (and spec §6 Lookup): query_memory takes the raw
            descriptor-tuple list directly, no register_memory round trip.
            """
            reg_list = [(0, 0, 0, name) for name in names]
            return self.nixl_agent.query_memory(reg_list, self.backend, mem_type="OBJ")

        def close(self) -> None:
            """Nothing persistent to release — every registration this
            agent makes is torn down by await_xfer()/query_exists() in the
            same call that created it."""

    class NixlKvThinL2Adapter(L2AdapterInterface):
        """Content-addressed NIXL L2 adapter; splitting/commit live in the
        plugin. See module docstring."""

        def __init__(
            self,
            config: "NixlKvThinL2AdapterConfig",
            l1_memory_desc: "L1MemoryDesc",
        ):
            self._ns = config.namespace

            # l1_memory_desc is accepted only because the factory interface
            # always supplies it — this adapter never touches LMCache's
            # persistent pinned buffer (see module docstring), so it's
            # otherwise unused here.
            self.nixl_agent = NixlKvThinStorageAgent(
                backend=config.backend,
                backend_params=config.backend_params,
            )

            # Self-probe a known-absent key at init — same rationale as
            # nixl_kv's spec §7 assert 5: a failed device-handle open is
            # non-fatal in the plugin, so the only way to notice from here
            # is confirming the probe path itself doesn't raise.
            probe_key = f"{self._ns}@__nixl_kv_thin_self_probe__{uuid.uuid4().hex}"
            try:
                probe_resp = self.nixl_agent.query_exists([probe_key])
            except Exception as exc:
                self.nixl_agent.close()
                raise RuntimeError(
                    "nixl_kv_thin: init self-probe failed; the query_memory "
                    "path is not usable, refusing to start: %r" % exc
                ) from exc
            if len(probe_resp) != 1 or is_probe_hit(probe_resp[0]):
                logger.warning(
                    "nixl_kv_thin: init self-probe for a random, never-written "
                    "key returned %r instead of absent — unexpected, but not "
                    "by itself fatal",
                    probe_resp,
                )

            # No pool -> no known device capacity; same as nixl_kv.
            super().__init__(max_capacity_bytes=0)
            self._config = config

            self._store_efd = create_event_notifier()
            self._lookup_efd = create_event_notifier()
            self._load_efd = create_event_notifier()

            self._memory_objects: dict["ObjectKey", NixlKvThinObj] = {}

            self._next_task_id: L2TaskId = 0
            self._completed_store_tasks: dict[L2TaskId, "L2StoreResult"] = {}
            self._completed_lookup_tasks: dict[L2TaskId, "Bitmap"] = {}
            self._completed_load_tasks: dict[L2TaskId, "Bitmap"] = {}
            self._lock = threading.Lock()

            self._l2_index_hits = 0
            self._l2_device_hits = 0
            self._l2_probe_errors = 0
            self._l2_commit_writes = 0
            self._l2_load_aborts = 0

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
        #####################

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
            """Index entry removal only — no device delete, same
            no-reclamation limitation as nixl_kv."""
            deleted_keys: list["ObjectKey"] = []
            deleted_sizes: list[int] = []
            with self._lock:
                for key in keys:
                    obj = self._memory_objects.get(key)
                    if obj is None:
                        continue
                    if obj.pin_count > 0:
                        continue
                    del self._memory_objects[key]
                    if obj.recorded and obj.size is not None:
                        deleted_keys.append(key)
                        deleted_sizes.append(obj.size)
            if deleted_keys:
                logger.warning(
                    "nixl_kv_thin: dropped index entry for %d key(s); "
                    "underlying device objects are NOT reclaimed. "
                    "Namespace %r usage is monotonic until reset "
                    "(scripts/target/50-reset-namespace.sh).",
                    len(deleted_keys),
                    self._ns,
                )
                self._notify_keys_deleted(deleted_keys, deleted_sizes)

        #####################
        # Status Interface
        #####################

        def report_status(self) -> dict:
            with self._lock:
                stored_object_count = len(self._memory_objects)
                pinned_object_count = sum(
                    1 for obj in self._memory_objects.values() if obj.pin_count > 0
                )
                counters = {
                    "l2_index_hits": self._l2_index_hits,
                    "l2_device_hits": self._l2_device_hits,
                    "l2_probe_errors": self._l2_probe_errors,
                    "l2_commit_writes": self._l2_commit_writes,
                    "l2_load_aborts": self._l2_load_aborts,
                }
            return {
                "is_healthy": self._loop_thread.is_alive(),
                "type": "NixlKvThinL2Adapter",
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

        ##################
        # Protocol: one descriptor, one name, per object. The plugin owns
        # everything past this point (fan-out, ordinals, commit marker).
        ##################

        async def _execute_store_in_the_loop(
            self,
            keys: list["ObjectKey"],
            objects: list["MemoryObj"],
            task_id: L2TaskId,
        ) -> None:
            """One independent ephemeral WRITE per key, all in flight
            concurrently (``asyncio.gather``) — no shared registration, no
            uniform-size constraint, since nothing here batches descriptors
            into one ``transfer()`` call any more (module docstring). Each
            xfer settling ``DONE`` means the plugin's own fan-out/commit
            sequence for that one object has completed (see
            ``xnvme_kv_backend.cpp``'s ``kv_complete_cb()``); any other
            state means its commit marker was never written, so that key
            alone is reported failed — a key succeeding in a batch where
            another fails is now the ordinary case, not a caveat.
            """
            bytes_transferred = 0
            try:
                to_store: list[tuple["ObjectKey", str, int, int, str]] = []
                for key, obj in zip(keys, objects, strict=False):
                    with self._lock:
                        if key in self._memory_objects:
                            continue
                    key_string = object_key_to_string(key)
                    name = f"{self._ns}@{key_string}"
                    to_store.append(
                        (key, key_string, obj.meta.address, obj.meta.phy_size, name)
                    )

                if not to_store:
                    with self._lock:
                        self._completed_store_tasks[task_id] = L2StoreResult(True, 0)
                    self._signal_store_event()
                    return

                xfers = [
                    (key, key_string, size, self.nixl_agent.start_store(addr, size, name))
                    for key, key_string, addr, size, name in to_store
                ]
                states = await asyncio.gather(
                    *(self.nixl_agent.await_xfer(xfer) for *_, xfer in xfers)
                )

                stored_keys: list["ObjectKey"] = []
                stored_sizes: list[int] = []
                any_failed = False
                with self._lock:
                    for (key, key_string, size, _), state in zip(
                        xfers, states, strict=True
                    ):
                        if state != "DONE":
                            any_failed = True
                            logger.warning(
                                "nixl_kv_thin: store failed for key %s: "
                                "xfer state=%s",
                                key_string,
                                state,
                            )
                            continue
                        self._memory_objects[key] = NixlKvThinObj(
                            key_string=key_string, size=size, recorded=True
                        )
                        stored_keys.append(key)
                        stored_sizes.append(size)
                    self._l2_commit_writes += len(stored_keys)

                if stored_keys:
                    self._notify_keys_stored(stored_keys, stored_sizes)
                bytes_transferred = sum(stored_sizes)
                success = not any_failed

            except Exception:
                logger.exception("nixl_kv_thin store task %d failed", task_id)
                success = False
                bytes_transferred = 0

            with self._lock:
                self._completed_store_tasks[task_id] = L2StoreResult(
                    success, bytes_transferred
                )
            self._signal_store_event()

        async def _execute_lookup_in_the_loop(
            self, keys: list["ObjectKey"], task_id: L2TaskId
        ) -> None:
            """Batched lookup and pin. One probe per logical object, on the
            BARE ``{ns}@{key}`` name — the plugin's queryMem() appends its
            own commit-marker suffix before deriving the device key, so
            this adapter never constructs or even knows about that suffix.
            """
            bitmap = Bitmap(len(keys))
            to_probe: list[tuple[int, "ObjectKey", str]] = []

            with self._lock:
                for i, key in enumerate(keys):
                    obj = self._memory_objects.get(key)
                    if obj is not None:
                        bitmap.set(i)
                        obj.increase_pin_count()
                        self._l2_index_hits += 1
                        continue
                    to_probe.append((i, key, object_key_to_string(key)))

            if to_probe:
                names = [f"{self._ns}@{ks}" for _, _, ks in to_probe]
                try:
                    resp = self.nixl_agent.query_exists(names)
                except Exception as exc:
                    # A genuine backend error — never fabricate a hit.
                    with self._lock:
                        self._l2_probe_errors += 1
                    logger.warning("nixl_kv_thin: query_memory probe failed: %r", exc)
                    resp = None

                if resp is not None:
                    with self._lock:
                        for (i, key, key_string), entry in zip(
                            to_probe, resp, strict=True
                        ):
                            if not is_probe_hit(entry):
                                continue
                            obj = self._memory_objects.get(key)
                            if obj is None:
                                obj = NixlKvThinObj(key_string=key_string)
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
            """Batched load. One flattened READ across every key already
            known to this adapter, each as its own independent ephemeral
            READ on the bare ``{ns}@{key}`` name, all in flight concurrently
            (``asyncio.gather``). The plugin's commit-check-then-parts
            protocol (xnvme_kv_backend.cpp) is what makes each READ atomic —
            it never issues any part read until it has confirmed the commit
            marker exists, and aborts that one object on any single part
            failure. One key's transport failure no longer takes down any
            other key in the same batch — there is no shared handle left to
            fail together.
            """
            bitmap = Bitmap(len(keys))
            try:
                to_load: list[tuple[int, "ObjectKey", str, int, int, str]] = []
                for i, (key, obj) in enumerate(zip(keys, objects, strict=False)):
                    with self._lock:
                        storage_obj = self._memory_objects.get(key)
                    if storage_obj is None:
                        continue
                    name = f"{self._ns}@{storage_obj.key_string}"
                    to_load.append(
                        (
                            i,
                            key,
                            storage_obj.key_string,
                            obj.meta.address,
                            obj.meta.phy_size,
                            name,
                        )
                    )

                if not to_load:
                    with self._lock:
                        self._completed_load_tasks[task_id] = bitmap
                    self._signal_load_event()
                    return

                xfers = [
                    (i, key, key_string, size, self.nixl_agent.start_load(addr, size, name))
                    for i, key, key_string, addr, size, name in to_load
                ]
                states = await asyncio.gather(
                    *(self.nixl_agent.await_xfer(xfer) for *_, xfer in xfers)
                )

                accessed_keys: list["ObjectKey"] = []
                newly_recorded_keys: list["ObjectKey"] = []
                newly_recorded_sizes: list[int] = []
                with self._lock:
                    for (i, key, key_string, size, _), state in zip(
                        xfers, states, strict=True
                    ):
                        if state != "DONE":
                            self._l2_load_aborts += 1
                            logger.warning(
                                "nixl_kv_thin: load failed for key %s: "
                                "xfer state=%s",
                                key_string,
                                state,
                            )
                            continue
                        storage_obj = self._memory_objects.get(key)
                        if storage_obj is None:
                            continue
                        record_now = not storage_obj.recorded
                        if storage_obj.size is None:
                            storage_obj.size = size
                        if record_now:
                            storage_obj.recorded = True
                            newly_recorded_keys.append(key)
                            newly_recorded_sizes.append(size)
                        bitmap.set(i)
                        accessed_keys.append(key)

                if accessed_keys:
                    self._notify_keys_accessed(accessed_keys)
                if newly_recorded_keys:
                    self._notify_keys_stored(newly_recorded_keys, newly_recorded_sizes)

            except Exception:
                logger.exception("nixl_kv_thin load task %d failed", task_id)

            with self._lock:
                self._completed_load_tasks[task_id] = bitmap
            self._signal_load_event()

    # -------------------------------------------------------------------
    # Config and self-registration
    # -------------------------------------------------------------------

    _VALID_NIXL_KV_THIN_BACKENDS = ("OBJ", "AZURE_BLOB", "SPDK_NVMe_KV", "XNVME_KV")

    class NixlKvThinL2AdapterConfig(L2AdapterConfigBase):
        """
        Config for the thin, content-addressed nixl_kv_thin L2 adapter.

        Fields:
        - backend: Nixl OBJ/KV storage backend
          (OBJ, AZURE_BLOB, SPDK_NVMe_KV, XNVME_KV).
        - backend_params: Backend-specific parameters (optional, default
          empty).
        - namespace: geometry fingerprint, same role and same validation as
          nixl_kv's (required, non-empty, must not contain '@', '~', '!').

        ``pool_size`` is rejected, not ignored — same reasoning as nixl_kv:
        content-addressed, no slot pool, so a config carrying one is almost
        certainly copy-pasted from a nixl_store spec.
        """

        def __init__(
            self, backend: str, backend_params: dict[str, str], namespace: str
        ):
            self.backend = backend
            self.backend_params = backend_params
            self.namespace = namespace

        @classmethod
        def from_dict(cls, d: dict) -> "NixlKvThinL2AdapterConfig":
            backend = d.get("backend")
            if backend not in _VALID_NIXL_KV_THIN_BACKENDS:
                raise ValueError(
                    "backend must be one of %s, got %r"
                    % (_VALID_NIXL_KV_THIN_BACKENDS, backend)
                )

            backend_params = d.get("backend_params", {})
            if not isinstance(backend_params, dict):
                raise ValueError(
                    "backend_params must be a dict of string key-value pairs"
                )

            if "pool_size" in d:
                raise ValueError(
                    "nixl_kv_thin does not take 'pool_size': it is "
                    "content-addressed and has no slot pool. Remove "
                    "'pool_size' from the adapter config."
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
                "Nixl KV thin (content-addressed, plugin-side split) L2 "
                "adapter config fields:\n"
                "- backend (str): Nixl OBJ/KV storage backend, "
                "one of %s (required)\n"
                "- backend_params (dict): backend-specific "
                "string key-value pairs (optional, default empty)\n"
                "- namespace (str): geometry fingerprint (required, "
                "non-empty, must not contain '@', '~' or '!')\n"
                "- 'pool_size' is NOT accepted here -- nixl_kv_thin is "
                "content-addressed and has no slot pool."
                % (_VALID_NIXL_KV_THIN_BACKENDS,)
            )

    register_l2_adapter_type("nixl_kv_thin", NixlKvThinL2AdapterConfig)

    def _create_nixl_kv_thin_adapter(
        config: "L2AdapterConfigBase",
        l1_memory_desc: Optional["L1MemoryDesc"] = None,
    ) -> "L2AdapterInterface":
        """Create a NixlKvThinL2Adapter from config."""
        if l1_memory_desc is None:
            raise ValueError(
                "l1_memory_desc is required to create a NixlKvThinL2Adapter."
            )
        return NixlKvThinL2Adapter(config, l1_memory_desc)  # type: ignore[arg-type]

    register_l2_adapter_factory("nixl_kv_thin", _create_nixl_kv_thin_adapter)
