// SPDK NVMe-KV NIXL plugin entry points.
// Registers nixlSpdkKvEngine as plugin "SPDK_NVMe_KV" version "0.1.0".
//
// Direct lambda init avoids nixlBackendPluginCreator<> whose error path
// uses NIXL_ERROR (absl-backed) — same pattern as AMD_ROCM plugin.
#include <cstdlib>   // getenv
#include <string>    // to_string

#include "backend/backend_plugin.h"
#include "spdk_nvme_kv_backend.h"

static nixlBackendPlugin g_plugin = {
    NIXL_PLUGIN_API_VERSION,

    [](const nixlBackendInitParams *p) -> nixlBackendEngine * {
        try { return new nixlSpdkKvEngine(p); }
        catch (...) { return nullptr; }
    },

    [](nixlBackendEngine *e) { delete e; },

    []() -> const char * { return "SPDK_NVMe_KV"; },
    []() -> const char * { return "0.1.0"; },
    []() -> nixl_b_params_t {
        // Expose configurable params: trid (transport ID string).
        //
        // max_value_size: hard ceiling on a single STORE/RETRIEVE value,
        // reported so LMCache's multipart-split patch
        // (stack/tracks/lmcache/patches/0002-*.patch) can transparently
        // split larger pages into multiple <=max_value_size sub-transfers
        // itself — same mechanism XNVME_KV uses (its own 32768 is a DSC
        // hardware limit; this one is not a bdev_kvmalloc limit, which is
        // configured for 64 MiB values — it's the NVMe-oF/TCP transport's
        // SGL ceiling: nvmf_tcp_create() rejects any max_io_size above
        // roughly max_io_size/large_bufsize(132KB) > SPDK_NVMF_MAX_SGL_ENTRIES
        // (16), i.e. ~2MB, and stack/foundation/spdk-kv/start-kv-target.sh
        // configures max_io_size=1048576 (1MB). 524288 leaves headroom below
        // that for NVMe/TCP PDU framing overhead. A LMCache KV page is
        // typically several MB (chunk_size=256 -> ~5.7MB for common models),
        // so without this, LMCache tries to send the whole page as one
        // descriptor and the target rejects it outright with
        // "SGL length ... exceeds max io size" — this was found and fixed
        // 2026-08-18 while wiring up the CIRRASCALE 3-node storage target
        // (see stack/tracks/lmcache/patches/README.md's note on 0003).
        // kv_slot_offset: added to devId before it's hashed into the on-wire
        // key (make_key() in spdk_nvme_kv_backend.h). devId is a storage-pool
        // slot index allocated from 0 independently by each caller's
        // NixlObjPool (LMCache) — two independent deployments (e.g. a P/D
        // producer + receiver, or two unrelated instances) sharing one
        // remote target otherwise collide on their early slot indices. Give
        // each deployment a disjoint offset (e.g. producer=0,
        // receiver=<pool_size>) so their key spaces never overlap. Default 0
        // preserves today's behavior.
        //
        // SUPERSEDED for any caller that sets metaInfo (LMCache OBJ mode):
        // make_key() now derives the key from metaInfo and ignores devId
        // entirely on that path, so the collision this works around cannot
        // occur there and the offset has no effect. Still load-bearing for
        // metaInfo-less callers (kv_io.py, nixlbench) on the devId path.
        // The value is now QUERIED at backend construction —
        // query_max_value_size() takes min(device KV Value Max Length,
        // controller max transfer size). Adopting it is OPT-IN via
        // NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE=1, because changing this number
        // silently changes the on-disk geometry: nothing yet records the
        // sub_size an object was written with, so a reader recomputing
        // n = ceil(page_size / max_value_size) from a changed value derives
        // sub-keys that partially still exist and reassembles a half-stale
        // page without error. Until the manifest lands, the default stays the
        // known-good constant. The discovered value is logged at construction
        // regardless, so a disagreement is always visible.
        uint32_t mvs = SPDK_KV_DEFAULT_MAX_VALUE_SIZE;
        const char *use_dev = std::getenv("NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE");
        if (use_dev && use_dev[0] == '1') {
            uint32_t d = nixlSpdkKvEngine::discovered_max_value_size_.load(
                std::memory_order_relaxed);
            if (d != 0) mvs = d;
        }
        return {{"trid", "trtype:TCP adrfam:IPv4 traddr:127.0.0.1 trsvcid:4420 "
                         "subnqn:nqn.2024-01.io.nixl:kv0"},
                {"max_value_size", std::to_string(mvs)},
                {"kv_slot_offset", "0"}};
    },
    []() -> nixl_mem_list_t { return {DRAM_SEG, FILE_SEG}; },
};

extern "C" NIXL_PLUGIN_EXPORT nixlBackendPlugin *
nixl_plugin_init() { return &g_plugin; }

extern "C" NIXL_PLUGIN_EXPORT void
nixl_plugin_fini() {}
