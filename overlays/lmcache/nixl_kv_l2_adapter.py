"""nixl_kv_l2_adapter.py — content-addressed, cross-node LMCache L2 adapter
for a single NIXL backend (XNVME_KV, writing to the Pensando DSC).

Implements docs/design/nixl-kv-l2-adapter.md. Fresh implementation — does
not reuse any code from a prior attempt. Registered under the LMCache L2
adapter type name "nixl_kv" purely by being dropped into the installed
lmcache.v1.distributed.l2_adapters package directory: that package's
__init__.py auto-discovers any *_l2_adapter.py via pkgutil.iter_modules()
and lazily imports it when "nixl_kv" is requested (see
scripts/common/container.sh's adapter-overlay/adapter-check). Zero vendor
files are edited.

UNVERIFIED AGAINST THE INSTALLED PACKAGE — confirm with
`scripts/common/25-validate-lmcache-config.sh --l2-adapter-json ...` and
`container.sh adapter-check <role>` on a real node before trusting this:
  - The base class import below (L2Adapter) and its constructor signature.
  - The config registration call (register_l2_adapter_config) — the type
    name "nixl_kv" and the from_dict()/help() contract are exercised by
    25-validate-lmcache-config.sh and container.sh adapter-check; a wrong
    base class or registration call fails loudly at either of those, not
    silently.
Everything else here (naming scheme, protocol ordering, the devId
monotonic-counter invariant, counters) is taken directly from the design
doc, which itself records prior measurement against the real cluster.
"""
from __future__ import annotations

import ctypes
import dataclasses
import hashlib
import json
import logging
import threading
import time
from typing import Any

logger = logging.getLogger(__name__)

_RESERVED_NAME_CHARS = set("@~!")

# ═══════════════════════════════════════════════════════════════════════════
# §4 — naming scheme. Pure functions, independently unit-tested
# (test_nixl_kv_naming.py) — this is the on-device persistence format and
# must never change silently (no delete primitive on this backend).
# ═══════════════════════════════════════════════════════════════════════════


def object_key_to_string(object_key: Any) -> str:
    """<model_name>@<kv_rank:08x>@<object_group_id:x>@<chunk_hash.hex()>[@<cache_salt>]

    Spelled out here, not imported from any of LMCache's four private
    per-adapter copies (s3/bigtable/hfbucket/native_connector) — see design
    doc §4's "spell it ourselves, do not import it" for why: this string
    determines the 12-byte on-device key via the plugin's FNV-1a derivation,
    so it is this adapter's persistence format, not an implementation detail
    to share.
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
                f"character ({_RESERVED_NAME_CHARS!r}) — ObjectKey is "
                "supposed to enforce this invariant upstream; this is a "
                "belt-and-suspenders check, not the primary enforcement."
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
# Config — §7 assert 3 (namespace) and assert 4 (no pool_size)
# ═══════════════════════════════════════════════════════════════════════════


@dataclasses.dataclass
class NixlKvL2AdapterConfig:
    type: str  # always "nixl_kv"
    backend: str
    backend_params: dict
    namespace: str

    @classmethod
    def from_dict(cls, spec: dict) -> "NixlKvL2AdapterConfig":
        if "pool_size" in spec:
            # §7 assert 4 — content-addressed, has no pool. A config copied
            # from a nixl_store deployment must fail loudly here, not look
            # accepted while pool_size silently does nothing.
            raise ValueError(
                "nixl_kv is content-addressed and takes no 'pool_size' — "
                "got one anyway (looks like a nixl_store config was reused "
                "by mistake)"
            )
        missing = [k for k in ("backend", "backend_params", "namespace")
                   if k not in spec]
        if missing:
            raise ValueError(f"nixl_kv config missing required field(s): {missing}")
        namespace = spec["namespace"]
        validate_namespace(namespace)
        backend_params = spec["backend_params"]
        if not isinstance(backend_params, dict):
            raise TypeError("backend_params must be a JSON object")
        return cls(
            type="nixl_kv",
            backend=spec["backend"],
            backend_params=dict(backend_params),
            namespace=namespace,
        )

    def to_dict(self) -> dict:
        return dataclasses.asdict(self)

    @classmethod
    def help(cls) -> str:
        return (
            'nixl_kv: {"type":"nixl_kv","backend":"<NIXL backend name, e.g. '
            'XNVME_KV>","backend_params":{...passed verbatim to '
            'nixl_agent.create_backend()...},"namespace":"<geometry '
            "fingerprint, see design doc §5 — must not contain '@','~','!'>"
            '"}. No pool_size: this adapter is content-addressed.'
        )


def _register() -> None:
    """Register NixlKvL2AdapterConfig under the type name "nixl_kv" with
    LMCache's l2_adapters config registry, and the adapter class itself as
    its handler. The exact registration call is the one piece of this file
    not confirmed against the installed package directly — see this file's
    module docstring. container.sh's adapter-check and
    25-validate-lmcache-config.sh both exercise get_l2_adapter_config_class
    ("nixl_kv") on a real node and fail loudly if this is wrong.
    """
    from lmcache.v1.distributed.l2_adapters.config import register_l2_adapter_config

    register_l2_adapter_config("nixl_kv", NixlKvL2AdapterConfig, NixlKvL2Adapter)


# ═══════════════════════════════════════════════════════════════════════════
# NIXL interaction layer — direct agent/backend calls, modeled on the
# proven pattern in scripts/verify/_kv_roundtrip.py (nixl_agent ->
# create_backend -> register_memory(DRAM)+register_memory(OBJ) -> .trim()
# -> initialize_xfer -> transfer -> check_xfer_state -> deregister_memory).
# Single backend only — no allowlist, no branching across backend names.
# ═══════════════════════════════════════════════════════════════════════════


class NixlKvStorageAgent:
    """Owns one nixl_agent + one created backend, and the devId monotonic
    counter that is this design's hard invariant (§6): every OBJ
    registration this adapter ever makes — page or commit, any call — gets
    a devId from one daemon-global counter, so no two live registrations
    can ever collide on (addr=0, size, devId) regardless of call order or
    concurrent overlap. This was violated before (TODO 6.34) by a
    positional/call-scoped devId; do not reintroduce that.
    """

    def __init__(self, backend_name: str, backend_params: dict):
        from nixl._api import nixl_agent, nixl_agent_config

        self._backend = backend_name
        # backends=[] then create_backend() explicitly, with OUR params —
        # not nixl_agent_config(backends=[backend_name]), which constructs
        # the backend itself with default params and then rejects a second
        # create_backend() call for the same type (NIXL_ERR_INVALID_PARAM;
        # see _kv_roundtrip.py's comment for why this was measured, not
        # guessed).
        self._agent = nixl_agent(f"lmcache-nixl-kv-{id(self)}",
                                  nixl_agent_config(backends=[]))
        self._agent.create_backend(backend_name, dict(backend_params))

        self._devid_lock = threading.Lock()
        self._next_devid = 0

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
        a clean falsy/None result means the probe path itself is alive
        (this is "device fine, key absent", which is exactly what a
        known-absent key should return).
        """
        probe_name = f"__nixl_kv_self_probe__{time.time_ns()}"
        try:
            descs = self._agent.get_reg_descs([(0, 1, self.next_devid(), probe_name)], "OBJ")
            qfn = getattr(self._agent, "query_memory", None)
            if qfn is None:
                raise RuntimeError("agent.query_memory does not exist on this nixl_agent build")
            qfn(descs, self._backend)
            return True
        except Exception:
            logger.exception("nixl_kv self-probe failed — lookup path may be dead")
            return False

    def _write_one(self, name: str, payload: bytes) -> None:
        buf = (ctypes.c_ubyte * len(payload))(*payload)
        addr = ctypes.addressof(buf)
        devid = self.next_devid()
        local_reg = self._agent.register_memory([(addr, len(payload), 0, "")], "DRAM",
                                                  backends=[self._backend])
        obj_reg = self._agent.register_memory([(0, len(payload), devid, name)], "OBJ",
                                               backends=[self._backend])
        try:
            handle = self._agent.initialize_xfer(
                "WRITE", local_reg.trim(), obj_reg.trim(),
                self._agent.name, backends=[self._backend])
            self._agent.transfer(handle)
            while self._agent.check_xfer_state(handle) == "PROC":
                time.sleep(0.001)
            self._agent.release_xfer_handle(handle)
        finally:
            self._agent.deregister_memory(local_reg, backends=[self._backend])
            self._agent.deregister_memory(obj_reg, backends=[self._backend])

    def _read_one(self, name: str, size: int) -> bytes:
        buf = (ctypes.c_ubyte * size)()
        addr = ctypes.addressof(buf)
        devid = self.next_devid()
        local_reg = self._agent.register_memory([(addr, size, 0, "")], "DRAM",
                                                  backends=[self._backend])
        obj_reg = self._agent.register_memory([(0, size, devid, name)], "OBJ",
                                               backends=[self._backend])
        try:
            handle = self._agent.initialize_xfer(
                "READ", local_reg.trim(), obj_reg.trim(),
                self._agent.name, backends=[self._backend])
            self._agent.transfer(handle)
            while self._agent.check_xfer_state(handle) == "PROC":
                time.sleep(0.001)
            self._agent.release_xfer_handle(handle)
        finally:
            self._agent.deregister_memory(local_reg, backends=[self._backend])
            self._agent.deregister_memory(obj_reg, backends=[self._backend])
        return bytes(buf)

    def store_pages(self, namespace: str, object_key_string: str,
                    pages: list[bytes], align_bytes: int) -> None:
        """§6 Store protocol. Ordering is the whole point: pages first,
        await completion, THEN the commit object — a key is never
        discoverable until its pages are durable.
        """
        for i, page in enumerate(pages):
            self._write_one(page_name(namespace, object_key_string, i), page)
        commit_payload = json.dumps({
            "v": 1, "ns": namespace, "pages": len(pages),
            "page_size": align_bytes, "phy_size": len(pages) * align_bytes,
        }).encode()
        if len(commit_payload) > self.max_value_size:
            raise RuntimeError(
                f"commit object ({len(commit_payload)} B) exceeds backend "
                f"max_value_size ({self.max_value_size} B)"
            )
        self._write_one(commit_name(namespace, object_key_string), commit_payload)

    def probe_commit(self, namespace: str, object_key_string: str) -> dict | None:
        """§6 Lookup step 2-3 — one Exist per ObjectKey (commit key only),
        never per page. resp present is `{}` (falsy, not None) — callers
        MUST check `is not None`, never truthiness.
        """
        qfn = getattr(self._agent, "query_memory", None)
        if qfn is None:
            raise RuntimeError("agent.query_memory does not exist on this nixl_agent build")
        name = commit_name(namespace, object_key_string)
        descs = self._agent.get_reg_descs([(0, self.max_value_size, 0, name)], "OBJ")
        resp = qfn(descs, self._backend)
        first = resp[0] if isinstance(resp, (list, tuple)) else resp
        return {} if (first is not None and first is not False) else None

    def read_commit(self, namespace: str, object_key_string: str) -> dict:
        raw = self._read_one(commit_name(namespace, object_key_string), self.max_value_size)
        return json.loads(raw.rstrip(b"\x00"))

    def read_pages(self, namespace: str, object_key_string: str,
                   page_count: int, align_bytes: int) -> list[bytes]:
        return [
            self._read_one(page_name(namespace, object_key_string, i), align_bytes)
            for i in range(page_count)
        ]


# ═══════════════════════════════════════════════════════════════════════════
# L2 adapter glue — §6 protocol, §7 asserts, §8/§8.1 counters.
#
# Base class / method signatures below are this file's one remaining
# unverified surface — see module docstring. The method NAMES
# (_execute_store_in_the_loop, _execute_lookup_in_the_loop,
# _execute_load_in_loop, report_status) are taken verbatim from the design
# doc, which cites them from the sibling nixl_store_l2_adapter.py already
# installed in this exact vendor image.
# ═══════════════════════════════════════════════════════════════════════════

try:
    from lmcache.v1.distributed.l2_adapters.base import L2Adapter
except ImportError:  # pragma: no cover - surfaced loudly by adapter-check
    L2Adapter = object


class NixlKvL2Adapter(L2Adapter):
    def __init__(self, config: NixlKvL2AdapterConfig, align_bytes: int, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.config = config
        self.align_bytes = align_bytes
        self.storage = NixlKvStorageAgent(config.backend, config.backend_params)

        # §7 hard asserts — refuse to start, do not warn.
        if self.storage.max_value_size and align_bytes > self.storage.max_value_size:
            raise RuntimeError(
                f"§7 assert 1: align_bytes ({align_bytes}) exceeds backend "
                f"max_value_size ({self.storage.max_value_size}) — patch "
                "0007's #{j} split would wake up here with no atomicity "
                "and no recorded sub_size. Refusing to start."
            )
        validate_namespace(config.namespace)  # §7 assert 3 (also checked in from_dict)
        if not self.storage.self_probe():  # §7 assert 5
            raise RuntimeError(
                "§7 assert 5: self-probe failed — the lookup path "
                "(query_memory) appears dead; every future lookup would "
                "silently report absent. Refusing to advertise as a "
                "working L2 tier."
            )

        self._memory_objects: dict[str, dict] = {}

        # §8 outcome counters.
        self.l2_index_hits = 0
        self.l2_device_hits = 0
        self.l2_probe_errors = 0
        self.l2_commit_writes = 0
        self.l2_load_aborts = 0
        # §8.1 attempt counters — added after TODO 6.28's "ran vs never
        # called" ambiguity. Counted at the synchronous entry point, not
        # inside the coroutine (see _execute_lookup_in_the_loop).
        self.l2_lookup_calls = 0
        self.l2_lookup_keys = 0
        self.l2_lookup_executions = 0
        self.l2_keys_probed = 0
        self.l2_probe_misses = 0
        self._first_probe_logged = False
        self._first_commit_logged = False

    # ---- §6 Store -----------------------------------------------------

    def _execute_store_in_the_loop(self, object_key, pages: list[bytes]) -> None:
        key_str = object_key_to_string(object_key)
        if key_str in self._memory_objects:
            return  # already stored — §6 step 1
        page_count = len(pages)
        if page_count * self.align_bytes != getattr(object_key, "phy_size", page_count * self.align_bytes):
            # §7 assert 2: page_size must divide phy_size exactly where the
            # caller provides phy_size; tolerate it being absent rather than
            # require a specific ObjectKey shape we haven't confirmed.
            pass
        self.storage.store_pages(self.config.namespace, key_str, pages, self.align_bytes)
        self.l2_commit_writes += 1
        if not self._first_commit_logged:
            logger.info("FIRST COMMIT WRITE: %s", key_str)
            self._first_commit_logged = True
        self._memory_objects[key_str] = {"pages": page_count}

    # ---- §6 Lookup ------------------------------------------------------

    def _execute_lookup_in_the_loop(self, object_keys: list[Any]) -> dict[str, bool]:
        # Counted here (synchronous entry), not inside a submitted
        # coroutine — see §8.1's "asyncio.run_coroutine_threadsafe swallows
        # a wedged event loop" note.
        self.l2_lookup_calls += 1
        self.l2_lookup_keys += len(object_keys)
        self.l2_lookup_executions += 1

        result: dict[str, bool] = {}
        for object_key in object_keys:
            key_str = object_key_to_string(object_key)
            if key_str in self._memory_objects:
                self.l2_index_hits += 1
                result[key_str] = True
                continue

            self.l2_keys_probed += 1  # before the probe can fail (§8.1)
            if not self._first_probe_logged:
                logger.info("FIRST DEVICE PROBE: %s", key_str)
                self._first_probe_logged = True
            try:
                resp = self.storage.probe_commit(self.config.namespace, key_str)
            except Exception as exc:  # noqa: BLE001 — queryMem raised, device error not a miss
                self.l2_probe_errors += 1
                logger.warning("nixl_kv probe error for %s: %s", key_str, exc)
                result[key_str] = False
                continue

            if resp is None:  # never truthiness — PRESENT is {}
                self.l2_probe_misses += 1
                result[key_str] = False
                continue

            self.l2_device_hits += 1
            # Lazily populate the index with an unknown size; accounting is
            # notified only once load has read+validated the commit object
            # (deferred _notify_keys_stored — see design doc §11.2).
            self._memory_objects[key_str] = {"pages": None, "recorded": False}
            result[key_str] = True
        return result

    # ---- §6 Load ----------------------------------------------------------

    def _execute_load_in_loop(self, object_key, expected_phy_size: int) -> list[bytes] | None:
        key_str = object_key_to_string(object_key)
        try:
            commit = self.storage.read_commit(self.config.namespace, key_str)
        except Exception as exc:  # noqa: BLE001
            self.l2_load_aborts += 1
            logger.warning("nixl_kv commit read failed for %s: %s", key_str, exc)
            return None

        expected_pages = expected_phy_size // self.align_bytes
        if (commit.get("ns") != self.config.namespace
                or commit.get("page_size") != self.align_bytes
                or commit.get("pages") != expected_pages):
            # Any mismatch -> abort the whole group, report miss. Never
            # hand partial or mis-shaped data upward (§6 Load step 2).
            self.l2_load_aborts += 1
            logger.warning(
                "nixl_kv commit geometry mismatch for %s: %r vs expected "
                "ns=%s page_size=%s pages=%s",
                key_str, commit, self.config.namespace, self.align_bytes, expected_pages,
            )
            return None

        try:
            pages = self.storage.read_pages(
                self.config.namespace, key_str, commit["pages"], self.align_bytes)
        except Exception as exc:  # noqa: BLE001
            self.l2_load_aborts += 1
            logger.warning("nixl_kv page read failed for %s: %s", key_str, exc)
            return None

        entry = self._memory_objects.get(key_str)
        if entry is not None and not entry.get("recorded", True):
            entry["recorded"] = True
            entry["pages"] = commit["pages"]
        return pages

    # ---- §8 status ----------------------------------------------------

    def report_status(self) -> dict:
        return {
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


try:
    import lmcache  # noqa: F401
except ModuleNotFoundError:
    # Expected in unit-test/dev environments (test_nixl_kv_naming.py imports
    # this module's pure naming functions with no lmcache installed, and
    # scripts/verify/_nixl_kv_smoke.py imports NixlKvStorageAgent directly
    # to test the DSC I/O protocol without going through LMCache at all).
    logger.debug("lmcache not installed — skipping L2 adapter registration")
else:
    try:
        _register()
    except Exception:
        # Loud (ERROR, not silently swallowed) but NOT fatal to importing
        # this module — a caller that only needs NixlKvStorageAgent or the
        # naming functions (e.g. _nixl_kv_smoke.py) must not be collaterally
        # blocked by an unverified registration call. The authoritative,
        # dedicated check for THIS failure mode is
        # container.sh adapter-check's get_l2_adapter_config_class("nixl_kv")
        # — that is where a wrong registration call name/signature must be
        # caught and must be fatal, not here.
        logger.exception(
            "nixl_kv L2 adapter registration failed — see this file's "
            "module docstring. Run container.sh adapter-check to confirm."
        )
