// AMD ROCm NIXL backend — implementation.
// See rocm_backend.h for design notes.
#include <cassert>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rocm_backend.h"
#include "nixl_types.h"

// Avoid linking nixl's absl-based logger — plugins shouldn't pull in the host
// library's absl version. Use a simple stream-to-stderr helper instead.
#undef NIXL_ERROR
namespace { struct AmdErrLog {
    AmdErrLog(const char *f, int l) { std::fprintf(stderr, "[AMD_ROCM] %s:%d: ", f, l); }
    ~AmdErrLog() { std::fputc('\n', stderr); std::fflush(stderr); }
    template<typename T> AmdErrLog &operator<<(const T &v) {
        std::ostringstream s; s << v; std::fputs(s.str().c_str(), stderr); return *this; }
}; }
#define NIXL_ERROR AmdErrLog(__FILE__, __LINE__)

// ---- helpers ---------------------------------------------------------------

static const char *hipErrStr(hipError_t e) {
    return hipGetErrorString(e);
}

#define HIP_CHECK(call)                                                         \
    do {                                                                        \
        hipError_t _e = (call);                                                 \
        if (_e != hipSuccess) {                                                  \
            NIXL_ERROR << "HIP error " << hipErrStr(_e)                         \
                       << " at " << __FILE__ << ":" << __LINE__;                \
            return NIXL_ERR_BACKEND;                                             \
        }                                                                       \
    } while (0)

// ---- nixlRocmMD ------------------------------------------------------------

nixlRocmMD::~nixlRocmMD() {
    if (fd >= 0) {
        ::close(fd);
        fd = -1;
    }
}

// ---- nixlRocmReqH ----------------------------------------------------------

nixlRocmReqH::~nixlRocmReqH() {
    if (staging) {
        hipHostFree(staging);
        staging = nullptr;
    }
}

// ---- nixlRocmEngine --------------------------------------------------------

nixlRocmEngine::nixlRocmEngine(const nixlBackendInitParams *init_params)
    : nixlBackendEngine(init_params) {

    // Read optional uring_depth from custom params
    std::string val;
    if (getInitParam("uring_depth", val) == NIXL_SUCCESS) {
        try { uring_depth_ = static_cast<unsigned>(std::stoul(val)); }
        catch (...) {}
    }

    if (io_uring_queue_init(uring_depth_, &ring_, 0) < 0) {
        NIXL_ERROR << "io_uring_queue_init failed: " << strerror(errno);
        initErr = true;
        return;
    }
    initErr = false;
}

nixlRocmEngine::~nixlRocmEngine() {
    io_uring_queue_exit(&ring_);
}

// ---- registerMem -----------------------------------------------------------

nixl_status_t
nixlRocmEngine::registerMem(const nixlBlobDesc &mem,
                            const nixl_mem_t   &nixl_mem,
                            nixlBackendMD      *&out) {
    auto *md = new nixlRocmMD();
    md->type = nixl_mem;
    md->size = mem.len;

    switch (nixl_mem) {
    case FILE_SEG:
        // For FILE_SEG, nixlbench passes the already-open file descriptor in devId.
        // addr is the offset within the file.
        md->fd = static_cast<int>(mem.devId);
        break;
    case DRAM_SEG:
        // No registration needed; store addr for sanity
        md->ptr = reinterpret_cast<void *>(mem.addr);
        break;

    case VRAM_SEG: {
        // Validate the pointer is a valid HIP device allocation
        hipPointerAttribute_t attr{};
        hipError_t e = hipPointerGetAttributes(&attr, reinterpret_cast<void *>(mem.addr));
        if (e != hipSuccess) {
            NIXL_ERROR << "VRAM_SEG pointer validation failed: " << hipErrStr(e);
            delete md;
            return NIXL_ERR_INVALID_PARAM;
        }
        md->ptr = reinterpret_cast<void *>(mem.addr);
        break;
    }
    default:
        NIXL_ERROR << "Unsupported mem type: " << nixl_mem;
        delete md;
        return NIXL_ERR_INVALID_PARAM;
    }

    out = md;
    return NIXL_SUCCESS;
}

nixl_status_t
nixlRocmEngine::deregisterMem(nixlBackendMD *meta) {
    auto *md = static_cast<nixlRocmMD *>(meta);
    // For FILE_SEG, the fd is owned by nixlbench — don't close it.
    if (md->type == FILE_SEG) md->fd = -1;
    delete md;
    return NIXL_SUCCESS;
}

// ---- uringRW ---------------------------------------------------------------

nixl_status_t
nixlRocmEngine::uringRW(int fd, void *buf, size_t len,
                        off_t file_off, nixl_xfer_op_t op) const {
    std::lock_guard<std::mutex> lk(ring_mu_);

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring_);
    if (!sqe) {
        NIXL_ERROR << "io_uring_get_sqe: ring full";
        return NIXL_ERR_BACKEND;
    }

    if (op == NIXL_WRITE) {
        io_uring_prep_write(sqe, fd, buf, static_cast<unsigned>(len), file_off);
    } else {
        io_uring_prep_read(sqe, fd, buf, static_cast<unsigned>(len), file_off);
    }
    io_uring_sqe_set_data(sqe, nullptr);

    int ret = io_uring_submit(&ring_);
    if (ret < 0) {
        NIXL_ERROR << "io_uring_submit: " << strerror(-ret);
        return NIXL_ERR_BACKEND;
    }

    struct io_uring_cqe *cqe = nullptr;
    ret = io_uring_wait_cqe(&ring_, &cqe);
    if (ret < 0) {
        NIXL_ERROR << "io_uring_wait_cqe: " << strerror(-ret);
        return NIXL_ERR_BACKEND;
    }

    int res = cqe->res;
    io_uring_cqe_seen(&ring_, cqe);

    if (res < 0) {
        NIXL_ERROR << "io_uring I/O error: " << strerror(-res);
        return NIXL_ERR_BACKEND;
    }
    if (static_cast<size_t>(res) != len) {
        NIXL_ERROR << "io_uring short I/O: " << res << " of " << len;
        return NIXL_ERR_BACKEND;
    }
    return NIXL_SUCCESS;
}

// ---- prepXfer --------------------------------------------------------------

nixl_status_t
nixlRocmEngine::prepXfer(const nixl_xfer_op_t   &operation,
                         const nixl_meta_dlist_t &local,
                         const nixl_meta_dlist_t &remote,
                         const std::string       &remote_agent,
                         nixlBackendReqH         *&handle,
                         const nixl_opt_b_args_t *) const {
    if (local.descCount() != remote.descCount()) {
        return NIXL_ERR_INVALID_PARAM;
    }

    // One of the two sides must be a FILE_SEG
    nixl_mem_t local_type  = local.getType();
    nixl_mem_t remote_type = remote.getType();
    bool has_file = (local_type == FILE_SEG || remote_type == FILE_SEG);
    if (!has_file) {
        NIXL_ERROR << "AMD ROCm plugin: at least one side must be FILE_SEG";
        return NIXL_ERR_INVALID_PARAM;
    }

    // Check if any VRAM_SEG is involved so we know to pre-allocate staging
    bool needs_staging = (local_type == VRAM_SEG || remote_type == VRAM_SEG);

    size_t total_bytes = 0;
    if (needs_staging) {
        for (int i = 0; i < local.descCount(); ++i) {
            total_bytes += local[i].len;
        }
    }

    auto *req = new nixlRocmReqH();
    req->n_ios = static_cast<unsigned>(local.descCount());

    if (needs_staging && total_bytes > 0) {
        hipError_t e = hipHostMalloc(&req->staging, total_bytes,
                                     hipHostMallocDefault);
        if (e != hipSuccess) {
            NIXL_ERROR << "hipHostMalloc(" << total_bytes << "): " << hipErrStr(e);
            delete req;
            return NIXL_ERR_BACKEND;
        }
        req->staging_sz = total_bytes;
    }

    handle = req;
    return NIXL_SUCCESS;
}

// ---- postXfer --------------------------------------------------------------

nixl_status_t
nixlRocmEngine::postXfer(const nixl_xfer_op_t   &operation,
                         const nixl_meta_dlist_t &local,
                         const nixl_meta_dlist_t &remote,
                         const std::string       &remote_agent,
                         nixlBackendReqH         *&handle,
                         const nixl_opt_b_args_t *) const {
    auto *req = static_cast<nixlRocmReqH *>(handle);

    nixl_mem_t local_type  = local.getType();
    nixl_mem_t remote_type = remote.getType();

    // Determine which side is memory (DRAM/VRAM) and which is file
    bool write_op = (operation == NIXL_WRITE);

    // Convention: WRITE = memory → file, READ = file → memory
    // local  = memory side, remote = file side (typical nixlbench layout)
    // Handle both orientations by checking types.
    bool local_is_mem  = (local_type  == DRAM_SEG || local_type  == VRAM_SEG);
    bool remote_is_file = (remote_type == FILE_SEG);
    if (!local_is_mem || !remote_is_file) {
        // Handle the reverse orientation (file local, mem remote)
        NIXL_ERROR << "AMD ROCm plugin: expected local=MEM remote=FILE";
        return NIXL_ERR_INVALID_PARAM;
    }

    bool vram = (local_type == VRAM_SEG);

    char *staging_ptr = static_cast<char *>(req->staging);
    off_t staging_off = 0;

    for (int i = 0; i < local.descCount(); ++i) {
        const auto &mem_desc  = local[i];
        const auto &file_desc = remote[i];
        auto *file_md = static_cast<nixlRocmMD *>(file_desc.metadataP);

        void *mem_ptr  = reinterpret_cast<void *>(mem_desc.addr);
        size_t len     = mem_desc.len;
        int    fd      = file_md->fd;
        off_t  file_off = static_cast<off_t>(file_desc.addr);

        nixl_status_t status;

        if (write_op) {
            // WRITE: memory → file
            if (vram) {
                // Copy VRAM → staging DRAM, then write file
                hipError_t e = hipMemcpy(staging_ptr + staging_off,
                                         mem_ptr, len,
                                         hipMemcpyDeviceToHost);
                if (e != hipSuccess) {
                    NIXL_ERROR << "hipMemcpy D->H: " << hipErrStr(e);
                    return NIXL_ERR_BACKEND;
                }
                status = uringRW(fd, staging_ptr + staging_off,
                                  len, file_off, NIXL_WRITE);
            } else {
                status = uringRW(fd, mem_ptr, len, file_off, NIXL_WRITE);
            }
        } else {
            // READ: file → memory
            if (vram) {
                status = uringRW(fd, staging_ptr + staging_off,
                                  len, file_off, NIXL_READ);
                if (status == NIXL_SUCCESS) {
                    hipError_t e = hipMemcpy(mem_ptr,
                                             staging_ptr + staging_off,
                                             len,
                                             hipMemcpyHostToDevice);
                    if (e != hipSuccess) {
                        NIXL_ERROR << "hipMemcpy H->D: " << hipErrStr(e);
                        status = NIXL_ERR_BACKEND;
                    }
                }
            } else {
                status = uringRW(fd, mem_ptr, len, file_off, NIXL_READ);
            }
        }

        if (status != NIXL_SUCCESS) {
            return status;
        }

        staging_off += static_cast<off_t>(len);
    }

    req->done = true;
    return NIXL_IN_PROG;  // signal to caller that checkXfer will confirm
}

// ---- checkXfer -------------------------------------------------------------

nixl_status_t
nixlRocmEngine::checkXfer(nixlBackendReqH *handle) const {
    auto *req = static_cast<nixlRocmReqH *>(handle);
    if (req->done) return NIXL_SUCCESS;
    return NIXL_IN_PROG;
}

// ---- releaseReqH -----------------------------------------------------------

nixl_status_t
nixlRocmEngine::releaseReqH(nixlBackendReqH *handle) const {
    delete handle;
    return NIXL_SUCCESS;
}
