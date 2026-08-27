// AMD ROCm NIXL plugin entry points.
// Registers nixlRocmEngine as plugin "AMD_ROCM" version "0.1.0".
//
// Intentionally avoids nixlBackendPluginCreator<> — that template's
// error path uses NIXL_ERROR (absl), which pulls in host absl symbols
// that are not in the plugin's link chain. Direct lambda init is equivalent.
#include "backend/backend_plugin.h"
#include "rocm_backend.h"

static nixlBackendPlugin g_plugin = {
    NIXL_PLUGIN_API_VERSION,

    [](const nixlBackendInitParams *p) -> nixlBackendEngine * {
        try { return new nixlRocmEngine(p); }
        catch (...) { return nullptr; }
    },

    [](nixlBackendEngine *e) { delete e; },

    []() -> const char * { return "AMD_ROCM"; },
    []() -> const char * { return "0.1.0"; },
    []() -> nixl_b_params_t { return {}; },
    []() -> nixl_mem_list_t { return {DRAM_SEG, VRAM_SEG, FILE_SEG}; },
};

extern "C" NIXL_PLUGIN_EXPORT nixlBackendPlugin *
nixl_plugin_init() { return &g_plugin; }

extern "C" NIXL_PLUGIN_EXPORT void
nixl_plugin_fini() {}
