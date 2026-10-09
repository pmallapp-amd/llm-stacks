"""nixl_kv_l2_adapter.py — content-addressed, cross-node LMCache L2 adapter
for a single NIXL backend (XNVME_KV, writing to the Pensando DSC).

Implements docs/design/nixl-kv-l2-adapter.md. Registered as the LMCache L2
adapter type "nixl_kv", purely via lmcache's existing *_l2_adapter.py
auto-discovery (no vendor file edits) — see
scripts/common/container.sh's adapter-overlay/adapter-check.

The L2AdapterInterface contract (base.py), the config registration API
(register_l2_adapter_type/register_l2_adapter_factory in config.py/
factory.py), and ObjectKey/MemoryObj/L1MemoryDesc/L2StoreResult/Bitmap were
all confirmed by reading the real installed lmcache 0.5.3 package on a live
node (not guessed) — this module mirrors the proven event-fd/task-id/
background-event-loop structure of the vendor's own nixl_store_l2_adapter.py
(NixlStoreL2Adapter), which implements the identical interface against the
same NIXL backend family. What's NOT shared with it: nixl_store pre-
allocates a fixed pool of obj_{i}_{uuid4} storage slots at startup (random
names, one per daemon — see design doc §1 "Blocker 2"); this adapter is
content-addressed, has no pool, and derives every on-device name from the
caller's ObjectKey, so the same content maps to the same name on every
daemon that stores or looks it up.
"""
from __future__ import annotations

import asyncio
import ctypes
import json
import logging
import threading
import time
from typing import Optional

logger = logging.getLogger(__name__)

_RESERVED_NAME_CHARS = set("@~!")

# ═══════════════════════════════════════════════════════════════════════════
# §4 — naming scheme. Pure functions, independently unit-tested
# (test_nixl_kv_naming.py) — this is the on-device persistence format and
# must never change silently (no delete primitive on this backend).
# ═══════════════════════════════════════════════════════════════════════════


def object_key_to_string(object_key) -> str:
    """<model_name>@<kv_rank:08x>@<object_group_id:x>@<chunk_hash.hex()>[@<cache_salt>]

    Spelled out here, not imported from any of LMCache's four private
    per-adapter copies (s3/bigtable/hfbucket/native_connector) — see design
    doc §4's "spell it ourselves, do not import it" for why: this string
    determines the 12-byte on-device key via the plugin's FNV-1a derivation,
    so it is this adapter's persistence format, not an implementation detail
    to share. ObjectKey.__post_init__ (lmcache.v1.distributed.api) already
    enforces the '@'-free invariant on model_name and the '@'-free (plus
    '/','\\',NUL) invariant on cache_salt; the per-field check below is
    belt-and-suspenders, not the primary enforcement.
    """
    parts = [
        str(object_key.model_name),
        f"{object_key.kv_rank:08x}",
        f"{object_key.object_group_id:x}",
        object_key.chunk_hash.hex() if hasattr(object_key.chunk_hash, "hex")
        else str(object_key.chunk_hash),
    ]
    cache_salt = getattr(object_key, "cache_salt", None)
    if cache_salt:
        parts.append(str(cache_salt))
    for p in parts:
        if _RESERVED_NAME_CHARS & set(p):
            raise ValueError(
                f"object_key field {p!r} contains a reserved naming-grammar "
                f"character ({_RESERVED_NAME_CHARS!r})"
            )
    return "@".join(parts)


def page_name(namespace: str, object_key_string: str, page_ordinal: int) -> str:
    return f"{namespace}@{object_key_string}~{page_ordinal}"


def commit_name(namespace: str, object_key_string: str) -> str:
    return f"{namespace}@{object_key_string}!c"


def validate_namespace(namespace: str) -> None:
    if not namespace:
        raise ValueError("namespace must be non-empty")
    bad = _RESERVED_NAME_CHARS & set(namespace)
    if bad:
        raise ValueError(
            f"namespace {namespace!r} contains reserved character(s) "
            f"{sorted(bad)!r} ('@' field separator, '~' tile ordinal, "
            "'!' commit suffix — see design doc §4/§5)"
        )


# ═══════════════════════════════════════════════════════════════════════════
# NIXL interaction layer — direct agent/backend calls. Batches every page of
# one ObjectKey into a single WRITE/READ transfer (design doc §6 step 4),
# with the commit object as a separate small transfer using its own scratch
# buffer (design doc §11.4 — its payload is JSON, not caller KV bytes).
# ═══════════════════════════════════════════════════════════════════════════


class NixlKvStorageAgent:
    """Owns one nixl_agent + one created backend, and the devId monotonic
    counter that is this design's hard invariant (§6): every OBJ
    registration this adapter ever makes — page or commit, any call — gets
    a devId from one daemon-global counter, so no two live registrations
    can ever collide on (addr=0, size, devId) regardless of call order or
    concurrent overlap (TODO 6.34).
    """

    def __init__(self, backend_name: str, backend_params: dict):
        from nixl._api import nixl_agent, nixl_agent_config

        self._backend = backend_name
        # backends=[] then create_backend() explicitly, with OUR params —
        # not nixl_agent_config(backends=[backend_name]), which constructs
        # the backend itself with default params and then rejects a second
        # create_backend() call for the same type (NIXL_ERR_INVALID_PARAM;
        # measured against this exact backend, see scripts/verify/
        # _kv_roundtrip.py's comment).
        self._agent = nixl_agent(f"lmcache-nixl-kv-{id(self)}",
                                  nixl_agent_config(backends=[]))
        self._agent.create_backend(backend_name, dict(backend_params))

        self._devid_lock = threading.Lock()
        self._next_devid = 0

        # Serialises every call into self._agent. The devId counter above
        # makes OBJ registrations disjoint by NAME (§6), but the agent and
        # its backend carry their own shared mutable state — the section
        # descriptor list that register_memory/deregister_memory append to
        # and erase from, and the xfer handle table. None of it is
        # thread-safe, and store tasks reach it from the default executor,
        # which is min(32, cpu+4) threads wide (32 on these nodes).
        #
        # Measured 2026-10-09: concurrency=4 in the llama-benchy sweep
        # aborts the daemon ~3/3 runs, always right after
        # "getXferStatus: backend 'XNVME_KV' returned NIXL_ERR_BACKEND",
        # with three different heap signatures — "double free or corruption
        # (!prev)", "corrupted size vs. prev_size while consolidating", and
        # a std::vector<nixlSectionDesc>::operator[] assertion
        # '__n < this->size()'. That last one names the raced structure
        # outright: one thread indexes the section vector while another
        # thread's deregister_memory shrinks it.
        #
        # RLock, not Lock: _do_xfer takes it and is called from inside
        # write_pages/read_pages/etc., which already hold it.
        self._agent_lock = threading.RLock()

        self.max_value_size = int(
            self._agent.get_plugin_params(backend_name).get("max_value_size", 0)
        )

    def next_devid(self) -> int:
        with self._devid_lock:
            devid = self._next_devid
            self._next_devid += 1
            return devid

    def self_probe(self) -> bool:
        """§7 assert 5 — probe one known-absent key at init. The plugin's
        query_dev_ open is deliberately non-fatal on failure (see
        xnvme_kv_backend.cpp), so a dead probe path otherwise looks
        identical to "device fine, key absent" until every later lookup
        silently reports absent forever. A raised exception here is fatal;
        a clean falsy/None result means the probe path itself is alive.
        """
        probe_name = f"__nixl_kv_self_probe__{time.time_ns()}"
        try:
            with self._agent_lock:
                descs = self._agent.get_reg_descs(
                    [(0, 1, self.next_devid(), probe_name)], "OBJ")
                qfn = getattr(self._agent, "query_memory", None)
                if qfn is None:
                    raise RuntimeError(
                        "agent.query_memory does not exist on this nixl_agent build")
                qfn(descs, self._backend)
            return True
        except Exception:
            logger.exception("nixl_kv self-probe failed — lookup path may be dead")
            return False

    def _do_xfer(self, op: str, local_reg, remote_reg) -> None:
        with self._agent_lock:
            handle = self._agent.initialize_xfer(
                op, local_reg.trim(), remote_reg.trim(),
                self._agent.name, backends=[self._backend])
            try:
                self._agent.transfer(handle)
                while self._agent.check_xfer_state(handle) == "PROC":
                    time.sleep(0.001)
            finally:
                self._agent.release_xfer_handle(handle)

    def write_pages(self, base_addr: int, page_count: int, align_bytes: int,
                    namespace: str, object_key_string: str) -> int:
        """One batched WRITE of every page of this object (§6 step 3-4).
        Returns bytes transferred.
        """
        local_tuples = []
        obj_tuples = []
        for i in range(page_count):
            addr = base_addr + i * align_bytes
            devid = self.next_devid()
            local_tuples.append((addr, align_bytes, 0, ""))
            obj_tuples.append((0, align_bytes, devid, page_name(namespace, object_key_string, i)))

        with self._agent_lock:
            local_reg = self._agent.register_memory(local_tuples, "DRAM", backends=[self._backend])
            obj_reg = self._agent.register_memory(obj_tuples, "OBJ", backends=[self._backend])
            try:
                self._do_xfer("WRITE", local_reg, obj_reg)
            finally:
                self._agent.deregister_memory(local_reg, backends=[self._backend])
                self._agent.deregister_memory(obj_reg, backends=[self._backend])
        return page_count * align_bytes

    def write_commit(self, namespace: str, object_key_string: str, page_count: int,
                     align_bytes: int) -> None:
        """§11.4 — the commit object needs its own scratch buffer: its
        payload is JSON, not KV bytes from the caller's L1 region.
        """
        payload = json.dumps({
            "v": 1, "ns": namespace, "pages": page_count,
            "page_size": align_bytes, "phy_size": page_count * align_bytes,
        }).encode()
        if len(payload) > self.max_value_size:
            raise RuntimeError(
                f"commit object ({len(payload)} B) exceeds backend "
                f"max_value_size ({self.max_value_size} B)")
        buf = (ctypes.c_ubyte * len(payload))(*payload)
        addr = ctypes.addressof(buf)
        devid = self.next_devid()
        with self._agent_lock:
            local_reg = self._agent.register_memory([(addr, len(payload), 0, "")], "DRAM",
                                                      backends=[self._backend])
            obj_reg = self._agent.register_memory(
                [(0, len(payload), devid, commit_name(namespace, object_key_string))],
                "OBJ", backends=[self._backend])
            try:
                self._do_xfer("WRITE", local_reg, obj_reg)
            finally:
                self._agent.deregister_memory(local_reg, backends=[self._backend])
                self._agent.deregister_memory(obj_reg, backends=[self._backend])
        # Keep buf alive until the transfer completes (it does, synchronously,
        # inside _do_xfer above) — referenced here only to document the
        # lifetime requirement, not because ctypes needs the hint.
        del buf

    def probe_commit(self, namespace: str, object_key_string: str) -> Optional[dict]:
        """§6 Lookup step 2-3 — one Exist per ObjectKey (commit key only),
        never per page. PRESENT is `{}` (falsy, not None) — callers MUST
        check `is not None`, never truthiness.
        """
        qfn = getattr(self._agent, "query_memory", None)
        if qfn is None:
            raise RuntimeError("agent.query_memory does not exist on this nixl_agent build")
        name = commit_name(namespace, object_key_string)
        with self._agent_lock:
            descs = self._agent.get_reg_descs([(0, self.max_value_size, 0, name)], "OBJ")
            resp = qfn(descs, self._backend)
        first = resp[0] if isinstance(resp, (list, tuple)) else resp
        return {} if (first is not None and first is not False) else None

    def read_commit(self, namespace: str, object_key_string: str) -> dict:
        buf = (ctypes.c_ubyte * self.max_value_size)()
        addr = ctypes.addressof(buf)
        devid = self.next_devid()
        with self._agent_lock:
            local_reg = self._agent.register_memory([(addr, self.max_value_size, 0, "")], "DRAM",
                                                      backends=[self._backend])
            obj_reg = self._agent.register_memory(
                [(0, self.max_value_size, devid, commit_name(namespace, object_key_string))],
                "OBJ", backends=[self._backend])
            try:
                self._do_xfer("READ", local_reg, obj_reg)
            finally:
                self._agent.deregister_memory(local_reg, backends=[self._backend])
                self._agent.deregister_memory(obj_reg, backends=[self._backend])
        return json.loads(bytes(buf).rstrip(b"\x00"))

    def read_pages(self, base_addr: int, page_count: int, align_bytes: int,
                  namespace: str, object_key_string: str) -> None:
        """One batched READ of every page of this object directly into the
        caller's L1 buffer at base_addr (§6 Load step 3).
        """
        local_tuples = []
        obj_tuples = []
        for i in range(page_count):
            addr = base_addr + i * align_bytes
            devid = self.next_devid()
            local_tuples.append((addr, align_bytes, 0, ""))
            obj_tuples.append((0, align_bytes, devid, page_name(namespace, object_key_string, i)))

        with self._agent_lock:
            local_reg = self._agent.register_memory(local_tuples, "DRAM", backends=[self._backend])
            obj_reg = self._agent.register_memory(obj_tuples, "OBJ", backends=[self._backend])
            try:
                self._do_xfer("READ", local_reg, obj_reg)
            finally:
                self._agent.deregister_memory(local_reg, backends=[self._backend])
                self._agent.deregister_memory(obj_reg, backends=[self._backend])

    def close(self) -> None:
        pass


# ═══════════════════════════════════════════════════════════════════════════
# L2AdapterInterface implementation — event-fd + task-id async model, mirrors
# NixlStoreL2Adapter's structure (background asyncio loop thread, task
# dicts guarded by one lock, eventfd signaled on completion). §6 protocol,
# §7 hard asserts, §8/§8.1 counters are this adapter's own.
# ═══════════════════════════════════════════════════════════════════════════

try:
    from lmcache.v1.distributed.l2_adapters.base import L2AdapterInterface
    from lmcache.v1.distributed.l2_adapters.config import (
        L2AdapterConfigBase,
        register_l2_adapter_type,
    )
    from lmcache.v1.distributed.l2_adapters.factory import (
        register_l2_adapter_factory,
    )
    from lmcache.v1.distributed.internal_api import L1MemoryDesc, L2StoreResult
    from lmcache.native_storage_ops import Bitmap
    from lmcache.v1.platform import create_event_notifier
    _HAVE_LMCACHE = True
except ModuleNotFoundError:
    # Expected in unit-test/dev environments (test_nixl_kv_naming.py imports
    # this module's pure naming functions with no lmcache installed). On a
    # real node where this module is loaded by lmcache's own pkgutil
    # discovery, lmcache is importable by definition, so the classes below
    # subclass the real base classes and the registration calls at the
    # bottom of this file run and raise loudly if anything is wrong.
    logger.debug("lmcache not installed — nixl_kv L2 adapter classes will "
                 "not be registered")
    L2AdapterInterface = object
    L2AdapterConfigBase = object
    L1MemoryDesc = object
    _HAVE_LMCACHE = False


class _ObjEntry:
    __slots__ = ("page_count", "pin_count", "recorded", "_lock")

    def __init__(self, page_count: Optional[int], recorded: bool = True):
        self.page_count = page_count
        self.pin_count = 0
        self.recorded = recorded
        self._lock = threading.Lock()

    def increase_pin_count(self):
        with self._lock:
            self.pin_count += 1

    def decrease_pin_count(self):
        with self._lock:
            if self.pin_count > 0:
                self.pin_count -= 1


class NixlKvL2Adapter(L2AdapterInterface):
    def __init__(self, config: "NixlKvL2AdapterConfig", l1_memory_desc: L1MemoryDesc):
        self.storage = NixlKvStorageAgent(config.backend, config.backend_params)
        self._config = config
        self.align_bytes = l1_memory_desc.align_bytes

        # §7 hard asserts — refuse to start, do not warn.
        if self.storage.max_value_size and self.align_bytes > self.storage.max_value_size:
            raise RuntimeError(
                f"§7 assert 1: align_bytes ({self.align_bytes}) exceeds backend "
                f"max_value_size ({self.storage.max_value_size}) — the value-size "
                "split this would require has no recorded sub_size and no "
                "atomicity. Refusing to start."
            )
        validate_namespace(config.namespace)  # §7 assert 3 (also checked in from_dict)
        if not self.storage.self_probe():  # §7 assert 5
            raise RuntimeError(
                "§7 assert 5: self-probe failed — the lookup path "
                "(query_memory) appears dead; every future lookup would "
                "silently report absent. Refusing to advertise as a "
                "working L2 tier."
            )

        # max_capacity_bytes=0: content-addressed, no pool, no known ceiling
        # (§7 assert 4 — no pool_size at all). get_usage()/
        # supports_global_eviction() report "unknown" via the base class.
        super().__init__(max_capacity_bytes=0)

        self._store_efd = create_event_notifier()
        self._lookup_efd = create_event_notifier()
        self._load_efd = create_event_notifier()

        self._memory_objects: dict[object, _ObjEntry] = {}
        self._index_lock = threading.Lock()

        self._next_task_id = 0
        self._task_id_lock = threading.Lock()
        self._completed_store_tasks: dict[int, L2StoreResult] = {}
        self._completed_lookup_tasks: dict[int, Bitmap] = {}
        self._completed_load_tasks: dict[int, Bitmap] = {}
        self._results_lock = threading.Lock()

        # §8 outcome counters.
        self.l2_index_hits = 0
        self.l2_device_hits = 0
        self.l2_probe_errors = 0
        self.l2_commit_writes = 0
        self.l2_load_aborts = 0
        # §8.1 attempt counters.
        self.l2_lookup_calls = 0
        self.l2_lookup_keys = 0
        self.l2_lookup_executions = 0
        self.l2_keys_probed = 0
        self.l2_probe_misses = 0
        self._first_probe_logged = False
        self._first_commit_logged = False
        self._counters_lock = threading.Lock()

        self._loop = asyncio.new_event_loop()
        self._loop_thread = threading.Thread(target=self._run_event_loop, daemon=True)
        self._loop_thread.start()

    def _run_event_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _get_next_task_id(self) -> int:
        with self._task_id_lock:
            task_id = self._next_task_id
            self._next_task_id += 1
            return task_id

    # ---- Event Fd Interface ---------------------------------------------

    def get_store_event_fd(self) -> int:
        return self._store_efd.fileno()

    def get_lookup_and_lock_event_fd(self) -> int:
        return self._lookup_efd.fileno()

    def get_load_event_fd(self) -> int:
        return self._load_efd.fileno()

    # ---- §6 Store ---------------------------------------------------------

    def submit_store_task(self, keys: list, objects: list) -> int:
        task_id = self._get_next_task_id()
        asyncio.run_coroutine_threadsafe(
            self._execute_store_in_the_loop(keys, objects, task_id), self._loop)
        return task_id

    def pop_completed_store_tasks(self) -> dict:
        with self._results_lock:
            completed = self._completed_store_tasks
            self._completed_store_tasks = {}
        return completed

    async def _execute_store_in_the_loop(self, keys, objects, task_id: int) -> None:
        success = True
        bytes_transferred = 0
        stored_keys = []
        stored_sizes = []
        try:
            for key, obj in zip(keys, objects, strict=False):
                with self._index_lock:
                    if key in self._memory_objects:
                        continue

                key_str = object_key_to_string(key)
                phy_size = obj.meta.phy_size
                page_count = phy_size // self.align_bytes
                if page_count * self.align_bytes != phy_size:
                    raise RuntimeError(
                        f"§7 assert 2: phy_size ({phy_size}) is not an exact "
                        f"multiple of align_bytes ({self.align_bytes}) for {key_str}")

                # §6 Store protocol: pages first, await completion, THEN
                # commit — a key is never discoverable until its pages are
                # durable (step 5-6: "await completion, verify DONE ... only
                # then write the commit object").
                n = await self._loop.run_in_executor(
                    None, self.storage.write_pages,
                    obj.meta.address, page_count, self.align_bytes,
                    self._config.namespace, key_str)
                await self._loop.run_in_executor(
                    None, self.storage.write_commit,
                    self._config.namespace, key_str, page_count, self.align_bytes)

                with self._counters_lock:
                    self.l2_commit_writes += 1
                    if not self._first_commit_logged:
                        logger.info("FIRST COMMIT WRITE: %s", key_str)
                        self._first_commit_logged = True

                with self._index_lock:
                    self._memory_objects[key] = _ObjEntry(page_count)
                stored_keys.append(key)
                stored_sizes.append(phy_size)
                bytes_transferred += n
        except Exception:
            logger.exception("nixl_kv store task %d failed", task_id)
            success = False
            bytes_transferred = 0

        if stored_keys:
            self._notify_keys_stored(stored_keys, stored_sizes)

        with self._results_lock:
            self._completed_store_tasks[task_id] = L2StoreResult(success, bytes_transferred)
        self._store_efd.notify()

    # ---- §6 Lookup ----------------------------------------------------

    def submit_lookup_and_lock_task(self, keys: list, group_layout_descs: dict) -> int:
        task_id = self._get_next_task_id()
        self._loop.call_soon_threadsafe(self._execute_lookup_in_the_loop, keys, task_id)
        return task_id

    def query_lookup_and_lock_result(self, task_id: int):
        with self._results_lock:
            return self._completed_lookup_tasks.pop(task_id, None)

    def submit_unlock(self, keys: list) -> None:
        def _unlock(keys):
            with self._index_lock:
                for key in keys:
                    entry = self._memory_objects.get(key)
                    if entry is not None:
                        entry.decrease_pin_count()
        self._loop.call_soon_threadsafe(_unlock, keys)

    def _execute_lookup_in_the_loop(self, keys: list, task_id: int) -> None:
        # Counted at the synchronous submit_lookup_and_lock_task entry would
        # be better, but this still runs on the FIRST loop tick scheduled by
        # call_soon_threadsafe, before any device probe — see §8.1's note on
        # why attempt counters must be incremented before work, not after.
        with self._counters_lock:
            self.l2_lookup_calls += 1
            self.l2_lookup_keys += len(keys)
            self.l2_lookup_executions += 1

        bitmap = Bitmap(len(keys))
        for i, key in enumerate(keys):
            with self._index_lock:
                entry = self._memory_objects.get(key)
            if entry is not None:
                with self._counters_lock:
                    self.l2_index_hits += 1
                bitmap.set(i)
                entry.increase_pin_count()
                continue

            key_str = object_key_to_string(key)
            with self._counters_lock:
                self.l2_keys_probed += 1  # before the probe can fail (§8.1)
                if not self._first_probe_logged:
                    logger.info("FIRST DEVICE PROBE: %s", key_str)
                    self._first_probe_logged = True
            try:
                resp = self.storage.probe_commit(self._config.namespace, key_str)
            except Exception as exc:  # noqa: BLE001 — device error, not a miss
                with self._counters_lock:
                    self.l2_probe_errors += 1
                logger.warning("nixl_kv probe error for %s: %s", key_str, exc)
                continue

            if resp is None:  # never truthiness — PRESENT is {}
                with self._counters_lock:
                    self.l2_probe_misses += 1
                continue

            with self._counters_lock:
                self.l2_device_hits += 1
            # Lazily populate the index with an unknown size; accounting is
            # notified only once load has read+validated the commit object
            # (deferred _notify_keys_stored — design doc §11.2).
            new_entry = _ObjEntry(None, recorded=False)
            new_entry.increase_pin_count()
            with self._index_lock:
                self._memory_objects[key] = new_entry
            bitmap.set(i)

        with self._results_lock:
            self._completed_lookup_tasks[task_id] = bitmap
        self._lookup_efd.notify()

    # ---- §6 Load ------------------------------------------------------

    def submit_load_task(self, keys: list, objects: list) -> int:
        task_id = self._get_next_task_id()
        asyncio.run_coroutine_threadsafe(
            self._execute_load_in_loop(keys, objects, task_id), self._loop)
        return task_id

    def query_load_result(self, task_id: int):
        with self._results_lock:
            return self._completed_load_tasks.pop(task_id, None)

    async def _execute_load_in_loop(self, keys, objects, task_id: int) -> None:
        bitmap = Bitmap(len(keys))
        accessed_keys = []
        for i, key in enumerate(keys):
            key_str = object_key_to_string(key)
            obj = objects[i]
            expected_pages = obj.meta.phy_size // self.align_bytes
            try:
                commit = await self._loop.run_in_executor(
                    None, self.storage.read_commit, self._config.namespace, key_str)
            except Exception as exc:  # noqa: BLE001
                with self._counters_lock:
                    self.l2_load_aborts += 1
                logger.warning("nixl_kv commit read failed for %s: %s", key_str, exc)
                continue

            if (commit.get("ns") != self._config.namespace
                    or commit.get("page_size") != self.align_bytes
                    or commit.get("pages") != expected_pages):
                # Any mismatch -> abort this key's group, report miss. Never
                # hand partial or mis-shaped data upward (§6 Load step 2).
                with self._counters_lock:
                    self.l2_load_aborts += 1
                logger.warning(
                    "nixl_kv commit geometry mismatch for %s: %r vs expected "
                    "ns=%s page_size=%s pages=%s",
                    key_str, commit, self._config.namespace, self.align_bytes,
                    expected_pages)
                continue

            try:
                await self._loop.run_in_executor(
                    None, self.storage.read_pages,
                    obj.meta.address, commit["pages"], self.align_bytes,
                    self._config.namespace, key_str)
            except Exception as exc:  # noqa: BLE001
                with self._counters_lock:
                    self.l2_load_aborts += 1
                logger.warning("nixl_kv page read failed for %s: %s", key_str, exc)
                continue

            bitmap.set(i)
            accessed_keys.append(key)
            with self._index_lock:
                entry = self._memory_objects.get(key)
                if entry is not None and not entry.recorded:
                    entry.recorded = True
                    entry.page_count = commit["pages"]

        if accessed_keys:
            self._notify_keys_accessed(accessed_keys)
        with self._results_lock:
            self._completed_load_tasks[task_id] = bitmap
        self._load_efd.notify()

    # ---- Eviction / status ----------------------------------------------

    def delete(self, keys: list) -> None:
        """§6 Delete/eviction — no device delete. Removes the index entry
        only; device space is NOT reclaimed (design doc §6, §10).
        """
        deleted_keys = []
        deleted_sizes = []
        with self._index_lock:
            for key in keys:
                entry = self._memory_objects.get(key)
                if entry is None or entry.pin_count > 0:
                    continue
                del self._memory_objects[key]
                deleted_keys.append(key)
                deleted_sizes.append((entry.page_count or 0) * self.align_bytes)
        if deleted_keys:
            logger.warning(
                "nixl_kv delete(): removed %d index entries — device space "
                "is NOT reclaimed (no delete primitive on this backend)",
                len(deleted_keys))
            self._notify_keys_deleted(deleted_keys, deleted_sizes)

    def report_status(self) -> dict:
        with self._index_lock:
            stored_object_count = len(self._memory_objects)
        with self._counters_lock:
            counters = {
                "l2_index_hits": self.l2_index_hits,
                "l2_device_hits": self.l2_device_hits,
                "l2_probe_errors": self.l2_probe_errors,
                "l2_commit_writes": self.l2_commit_writes,
                "l2_load_aborts": self.l2_load_aborts,
                "l2_lookup_calls": self.l2_lookup_calls,
                "l2_lookup_keys": self.l2_lookup_keys,
                "l2_lookup_executions": self.l2_lookup_executions,
                "l2_keys_probed": self.l2_keys_probed,
                "l2_probe_misses": self.l2_probe_misses,
            }
        return {
            "is_healthy": self._loop_thread.is_alive(),
            "type": "NixlKvL2Adapter",
            "backend": self._config.backend,
            "namespace": self._config.namespace,
            "stored_object_count": stored_object_count,
            "event_loop_alive": self._loop_thread.is_alive(),
            **counters,
        }

    def close(self) -> None:
        async def _stop_tasks():
            tasks = [t for t in asyncio.all_tasks(self._loop)
                     if t is not asyncio.current_task()]
            for t in tasks:
                t.cancel()
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
            self.storage.close()
        finally:
            self._loop.close()
            self._store_efd.close()
            self._lookup_efd.close()
            self._load_efd.close()


class NixlKvL2AdapterConfig(L2AdapterConfigBase):
    """Config for the content-addressed nixl_kv L2 adapter.

    Fields:
    - backend: NIXL backend name (this stack only ever uses "XNVME_KV").
    - backend_params: forwarded verbatim to nixl_agent.create_backend().
    - namespace: geometry fingerprint (design doc §5) — must not contain
      '@', '~', or '!' (§7 assert 3). No pool_size: this adapter is
      content-addressed and has no pool (§7 assert 4) — reject the key if
      present rather than silently ignoring it, so a config copied from a
      nixl_store deployment fails loudly instead of looking accepted.
    """

    def __init__(self, backend: str, backend_params: dict, namespace: str):
        validate_namespace(namespace)
        self.backend = backend
        self.backend_params = backend_params
        self.namespace = namespace

    @classmethod
    def from_dict(cls, d: dict) -> "NixlKvL2AdapterConfig":
        if "pool_size" in d:
            raise ValueError(
                "nixl_kv is content-addressed and takes no 'pool_size' — "
                "got one anyway (looks like a nixl_store config was reused "
                "by mistake)"
            )
        missing = [k for k in ("backend", "backend_params", "namespace") if k not in d]
        if missing:
            raise ValueError(f"nixl_kv config missing required field(s): {missing}")
        backend_params = d["backend_params"]
        if not isinstance(backend_params, dict):
            raise ValueError("backend_params must be a dict of string key-value pairs")
        return cls(backend=d["backend"], backend_params=dict(backend_params),
                   namespace=d["namespace"])

    @classmethod
    def help(cls) -> str:
        return (
            "nixl_kv: content-addressed, cross-node L2 adapter (design doc "
            "nixl-kv-l2-adapter.md). Fields:\n"
            "- backend (str): NIXL backend name, e.g. 'XNVME_KV' (required)\n"
            "- backend_params (dict): forwarded verbatim to "
            "nixl_agent.create_backend() (required)\n"
            "- namespace (str): geometry fingerprint, must not contain "
            "'@', '~', or '!' (required)\n"
            "No pool_size — this adapter is content-addressed."
        )


def _create_nixl_kv_adapter(config: L2AdapterConfigBase,
                            l1_memory_desc: Optional[L1MemoryDesc] = None) -> L2AdapterInterface:
    if l1_memory_desc is None:
        raise ValueError("l1_memory_desc is required to create a NixlKvL2Adapter.")
    return NixlKvL2Adapter(config, l1_memory_desc)  # type: ignore[arg-type]


if _HAVE_LMCACHE:
    register_l2_adapter_type("nixl_kv", NixlKvL2AdapterConfig)
    register_l2_adapter_factory("nixl_kv", _create_nixl_kv_adapter)
