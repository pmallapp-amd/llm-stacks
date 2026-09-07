// xNVMe NVMe-KV NIXL plugin entry points.
// Registers nixlXnvmeKvEngine as plugin "XNVME_KV" version "0.1.0".
//
// Direct lambda init avoids nixlBackendPluginCreator<> whose error path
// uses NIXL_ERROR (absl-backed) — same pattern as SPDK_NVMe_KV / AMD_ROCM.
#include <cstdlib>   // getenv
#include <string>    // to_string

#include "backend/backend_plugin.h"
#include "xnvme_kv_backend.h"

static nixlBackendPlugin g_plugin = {
    NIXL_PLUGIN_API_VERSION,

    [](const nixlBackendInitParams *p) -> nixlBackendEngine * {
        try { return new nixlXnvmeKvEngine(p); }
        catch (...) { return nullptr; }
    },

    [](nixlBackendEngine *e) { delete e; },

    []() -> const char * { return "XNVME_KV"; },
    []() -> const char * { return "0.1.0"; },
    []() -> nixl_b_params_t {
        // Expose configurable params: dev_uri (char device path).
        //
        // max_value_size: hard ceiling on a single STORE/RETRIEVE value.
        // Callers transferring larger logical objects (e.g. LMCache's KV
        // cache chunks) must split into multiple <= max_value_size
        // sub-transfers themselves; see stack/tracks/lmcache/patches/ for the
        // LMCache-side multipart patch that consumes this.
        //
        // The value is now QUERIED from the device at backend construction
        // (query_max_value_size() in xnvme_kv_backend.cpp reads the KV
        // Identify Namespace) — but adopting it is OPT-IN, because changing
        // this number silently changes the on-disk geometry.
        //
        // Why opt-in: nothing currently records, alongside a stored object,
        // what sub_size it was written with. The reader recomputes
        // n = ceil(page_size / max_value_size) from the CURRENT value. If that
        // value changes, the derived sub-keys partially still exist, so reads
        // return short values into longer descriptors and the page reassembles
        // half-stale — silently, since the completion path checks status and
        // not returned length. Until the manifest lands (which records the
        // geometry per object and makes a mismatch a clean miss), the safe
        // default is to keep advertising the empirically-validated constant.
        //
        //   NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE=1   adopt the queried value
        //
        // The discovered value is logged at construction either way, so a
        // device/firmware disagreeing with the constant is always visible.
        uint32_t mvs = XNVME_KV_DEFAULT_MAX_VALUE_SIZE;
        const char *use_dev = std::getenv("NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE");
        if (use_dev && use_dev[0] == '1') {
            uint32_t d = nixlXnvmeKvEngine::discovered_max_value_size_.load(
                std::memory_order_relaxed);
            if (d != 0) mvs = d;
        }
        return {{"dev_uri", "/dev/ng0n1"},
                {"max_value_size", std::to_string(mvs)}};
    },
    []() -> nixl_mem_list_t { return {DRAM_SEG, FILE_SEG}; },
};

extern "C" NIXL_PLUGIN_EXPORT nixlBackendPlugin *
nixl_plugin_init() { return &g_plugin; }

extern "C" NIXL_PLUGIN_EXPORT void
nixl_plugin_fini() {}
