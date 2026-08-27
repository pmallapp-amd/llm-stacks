// AMD ROCm NIXL backend plugin.
// Provides VRAM_SEG support for upstream NIXL via HIP.
//
// Transfer model (no ROCm-equivalent of cuFile/GDS today):
//   VRAM <-> FILE: hipMemcpy to/from a pinned host staging buffer, then
//                  io_uring for the file I/O leg.
//   DRAM <-> FILE: io_uring only (same path as the POSIX plugin).
//
// Design intentionally keeps the staging buffer simple (one alloc per
// transfer) to be correct first. A pooled/async pipeline is future work.
#pragma once

#include <fcntl.h>
#include <liburing.h>
#include <hip/hip_runtime.h>
#include <unordered_map>
#include <vector>
#include <mutex>
#include "backend/backend_engine.h"
// nixl_log.h intentionally excluded: plugins must not link host absl logging

// Per-descriptor metadata stored alongside each registered region.
class nixlRocmMD : public nixlBackendMD {
public:
    nixl_mem_t  type;
    // FILE_SEG: open file descriptor; DRAM/VRAM: -1
    int         fd    = -1;
    // DRAM_SEG/VRAM_SEG: device/host pointer from the descriptor; FILE_SEG: 0
    void       *ptr   = nullptr;
    size_t      size  = 0;

    explicit nixlRocmMD() : nixlBackendMD(/*isPrivate=*/true) {}
    ~nixlRocmMD() override;
};

// Per-transfer request handle.
class nixlRocmReqH : public nixlBackendReqH {
public:
    // Staging buffer pinned with hipHostMalloc (only for VRAM legs).
    void       *staging    = nullptr;
    size_t      staging_sz = 0;
    // io_uring completion tracking
    unsigned    n_ios      = 0;
    // Whether all I/O was submitted synchronously and is already complete.
    bool        done       = false;

    ~nixlRocmReqH() override;
};

class nixlRocmEngine : public nixlBackendEngine {
public:
    explicit nixlRocmEngine(const nixlBackendInitParams *init_params);
    ~nixlRocmEngine() override;

    bool supportsRemote() const override { return false; }
    bool supportsLocal()  const override { return true; }
    bool supportsNotif()  const override { return false; }

    nixl_mem_list_t getSupportedMems() const override {
        return {DRAM_SEG, VRAM_SEG, FILE_SEG};
    }

    nixl_status_t connect(const std::string &)    override { return NIXL_SUCCESS; }
    nixl_status_t disconnect(const std::string &) override { return NIXL_SUCCESS; }

    nixl_status_t loadLocalMD(nixlBackendMD *input, nixlBackendMD *&output) override {
        output = input;
        return NIXL_SUCCESS;
    }
    nixl_status_t unloadMD(nixlBackendMD *) override { return NIXL_SUCCESS; }

    nixl_status_t registerMem(const nixlBlobDesc &mem,
                              const nixl_mem_t   &nixl_mem,
                              nixlBackendMD      *&out) override;

    nixl_status_t deregisterMem(nixlBackendMD *meta) override;

    nixl_status_t prepXfer(const nixl_xfer_op_t   &operation,
                           const nixl_meta_dlist_t &local,
                           const nixl_meta_dlist_t &remote,
                           const std::string       &remote_agent,
                           nixlBackendReqH         *&handle,
                           const nixl_opt_b_args_t *opt_args = nullptr) const override;

    nixl_status_t postXfer(const nixl_xfer_op_t   &operation,
                           const nixl_meta_dlist_t &local,
                           const nixl_meta_dlist_t &remote,
                           const std::string       &remote_agent,
                           nixlBackendReqH         *&handle,
                           const nixl_opt_b_args_t *opt_args = nullptr) const override;

    nixl_status_t checkXfer(nixlBackendReqH *handle) const override;
    nixl_status_t releaseReqH(nixlBackendReqH *handle) const override;

private:
    // io_uring instance for file I/O (shared, mutex-guarded)
    mutable struct io_uring ring_;
    mutable std::mutex ring_mu_;

    unsigned uring_depth_ = 256;

    // Helper: perform a single file transfer leg using io_uring.
    // buf is a host pointer. op is NIXL_READ or NIXL_WRITE.
    nixl_status_t uringRW(int fd, void *buf, size_t len,
                          off_t file_off, nixl_xfer_op_t op) const;
};
