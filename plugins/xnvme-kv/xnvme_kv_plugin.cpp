// xNVMe NVMe-KV NIXL plugin entry points.
// Registers nixlXnvmeKvEngine as plugin "XNVME_KV" version "0.1.0".
//
// Direct lambda init avoids nixlBackendPluginCreator<> whose error path
// uses NIXL_ERROR (absl-backed) — same pattern as SPDK_NVMe_KV / AMD_ROCM.
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
        // WHY THIS MUST NEVER SILENTLY CHANGE UNDER A READER. Nothing
        // currently records, alongside a stored object, what sub_size it was
        // written with. The reader recomputes n = ceil(page_size /
        // max_value_size) from the CURRENT value. If that value changes, the
        // derived sub-keys partially still exist, so reads return short
        // values into longer descriptors and the page reassembles
        // half-stale — silently, since the completion path checks status and
        // not returned length. Until a manifest lands (recording the
        // geometry per object and making a mismatch a clean miss instead of
        // silent corruption), the value returned here must be a single,
        // deliberately-chosen constant that only ever changes alongside a
        // namespace drain (scripts/target/50-reset-namespace.sh).
        //
        // NEW MODEL, as of 2026-09-17 (superseding the OPT-IN device-adoption
        // design this comment used to describe — NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE
        // is REMOVED, see query_max_value_size()'s comment in
        // xnvme_kv_backend.cpp for the call-order defect that killed it):
        // CONFIG is authoritative, the DEVICE is a VALIDATOR.
        // xnvme_kv_configured_max_value_size() (xnvme_kv_backend.cpp) reads
        // NIXL_KV_MAX_VALUE_SIZE (exported from config/cluster.env's
        // KV_MAX_VALUE_SIZE_EFFECTIVE by lib.sh's setup_nixl_kv_env()) and
        // falls back to the compiled-in XNVME_KV_DEFAULT_MAX_VALUE_SIZE.
        // query_max_value_size() then validates that value against the
        // device's KV Identify Namespace at create_backend() time and HARD
        // FAILS init if the device's own ceiling is smaller — it never
        // silently adopts a different number.
        //
        // This function is therefore call-order independent BY CONSTRUCTION:
        // it reads the same source of truth whether it is called before or
        // after create_backend(), because that source of truth is config, not
        // a value only create_backend() populates. That is exactly the defect
        // the old design had — get_plugin_params() could be (and per
        // scripts/verify/20-verify-nixl-plugin.sh, IS) called before
        // create_backend(), so an opt-in gated on a construction-time field
        // could silently do nothing.
        const uint32_t mvs = xnvme_kv_configured_max_value_size();
        // dev_uri is DISCOVERED, never hardcoded. This used to advertise
        // "/dev/ng0n1", which is correct on the single MI210 host this backend
        // was written for and is a real local SSD with data on it on every
        // Austin node — see nixlXnvmeKvEngine::discover_kv_device(). Empty when
        // nothing is found, so a caller that blindly adopts this param gets a
        // clean init failure rather than a wrong device.
        return {{"dev_uri", nixlXnvmeKvEngine::discover_kv_device()},
                {"max_value_size", std::to_string(mvs)}};
    },
    []() -> nixl_mem_list_t { return {DRAM_SEG, FILE_SEG}; },
};

extern "C" NIXL_PLUGIN_EXPORT nixlBackendPlugin *
nixl_plugin_init() { return &g_plugin; }

extern "C" NIXL_PLUGIN_EXPORT void
nixl_plugin_fini() {}
