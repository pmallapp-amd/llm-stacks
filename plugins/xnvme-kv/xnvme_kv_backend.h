// xNVMe NVMe-KV NIXL backend plugin.
// Transfers data between DRAM_SEG/VRAM_SEG and FILE_SEG (NVMe-KV namespace)
// using libxnvme's io_uring_cmd backend and its native KV command-set API
// (xnvme_kvs_store/retrieve/delete, from <libxnvme.h>).
//
// Why this exists alongside SPDK_NVMe_KV (see nvme-kv-plugin/): that backend
// needs the device bound to vfio-pci and a KV-patched SPDK/DPDK build whose
// SPDK_SRC must match at build and run time — and Docker's VFIO DMA mapping
// has been unreliable for this device's admin queue inside a container (see
// 09-nixlbench-pcie-kv-host.sh's header and project memory). io_uring_cmd
// instead talks to the device through the kernel's own `nvme` char-device
// passthrough ioctl/io_uring interface: no VFIO group, no DPDK, no hugepages,
// no SPDK build/run version pairing to get wrong — and it only needs a
// character device node handed to the container (`--device`), not a VFIO
// group mount, so it should work inside plain Docker.
//
// Prerequisite (NOT done by this plugin or its build script): the target
// NVMe-KV controller must be bound to the kernel's stock `nvme` driver
// (`modprobe nvme`), not vfio-pci, so a generic namespace character device
// (e.g. /dev/ng0n1) exists. See stack/tracks/nixl/README.md's XNVME_KV section.
//
// Device/queue model: one xnvme_dev + one xnvme_queue per internal worker
// (NIXL_XNVME_NUM_QUEUES, default 1) — mirrors the reference implementation
// at /root/<USER>/kv_bench_xnvme/kv_bench.c on the project's primary host,
// which already validates this API/queue pattern against the real DSC.
// xnvme_queue handles are not safe to touch from more than one thread, so
// each worker owns a dedicated reactor pthread that exclusively submits to
// and polls its own queue; postXfer() only enqueues work items onto that
// worker's mailbox (mutex + condvar), matching the SPDK backend's
// spdk_thread_send_msg dispatch model.
//
// Async model:
//   postXfer() submits ALL descriptors in the batch without waiting.
//   checkXfer() returns NIXL_IN_PROG until the atomic pending counter hits 0.
//
// Key encoding: 8 bytes devId + 4 bytes addr[31:0] = 12 bytes total — same
// scheme as the SPDK_NVMe_KV backend, so results are directly comparable.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <sstream>
#include <string>
#include <vector>

extern "C" {
#include <libxnvme.h>
}

#ifndef NIXL_XNVME_NO_VRAM
#include <hip/hip_runtime.h>
#endif

#include "backend/backend_engine.h"

#define XNVME_KV_KEY_MAX_LEN 16u

// Compiled-in fallback for the max single-value size, used when the device has
// not been queried yet (no backend instance created) or the query failed.
// 32768 was established EMPIRICALLY against the real Pensando DSC — 32768 B
// stores/retrieves cleanly, 65536 B fails with a vendor-specific NVMe
// completion status (sct=7 sc=234). Keep it as the fallback rather than
// trusting an advertised value blindly: that empirical probe is the only
// evidence we have that a size actually works end-to-end on this firmware.
#define XNVME_KV_DEFAULT_MAX_VALUE_SIZE 32768u

// Per-registered memory descriptor.
class nixlXnvmeKvMD : public nixlBackendMD {
public:
    nixl_mem_t  type;
    void       *ptr    = nullptr;
    size_t      size   = 0;
    uint64_t    dev_id = 0;
    // Set from nixlBlobDesc::metaInfo at registerMem() time for FILE_SEG/OBJ_SEG
    // registrations — when non-empty, this (not devId/addr) is the caller-
    // supplied KV identity (e.g. LMCache's OBJ-mode object name,
    // obj_{slot}_{uuid4}[#{part}]: instance-unique, NOT content-derived, and
    // re-randomised on every process start — see rocm-aic README §3).
    // Empty for callers that never set metaInfo (kv_io.py, nixlbench), which
    // keep the original devId/addr-derived key.
    std::string meta_info;

    explicit nixlXnvmeKvMD() : nixlBackendMD(true) {}
    ~nixlXnvmeKvMD() override = default;
};

// Per-transfer request handle. Holds an atomic countdown of in-flight ops.
struct nixlXnvmeKvReqH : public nixlBackendReqH {
    std::atomic<int>  pending{0};   // decremented by completion callbacks
    std::atomic<bool> error{false}; // set on any failed op
    std::mutex              mtx;
    std::condition_variable cv;

    // VRAM_SEG staging buffer — one hipHostRegister()'d buffer per batch,
    // sized to the batch's total bytes. Null/0 when the batch has no
    // VRAM_SEG side. Same staging strategy as the SPDK_NVMe_KV backend (see
    // its header for why: GPU and DSC sit on different NUMA nodes here).
    void   *staging_    = nullptr;
    size_t  staging_sz_ = 0;

    ~nixlXnvmeKvReqH() override;
};

class nixlXnvmeKvEngine;

// Async I/O work item — heap-allocated in postXfer(), freed by completion cb.
struct XnvmeKvWorkEx {
    struct QueueWorker     *qw      = nullptr;
    uint8_t                 key[XNVME_KV_KEY_MAX_LEN] = {};
    uint8_t                 key_len = 0;
    void                   *buf     = nullptr;
    uint32_t                buf_len = 0;
    nixl_xfer_op_t          op      = NIXL_WRITE;
    nixlXnvmeKvReqH         *req    = nullptr;
    // VRAM_SEG READ only: destination VRAM pointer to hipMemcpy `buf` (a
    // staging-buffer slice) into once the retrieve completes. Null for
    // DRAM_SEG transfers and for all WRITEs.
    void                   *vram_dst = nullptr;
    // steady-clock ns at the moment the device ACCEPTED this op (kSubmitted),
    // not when it was queued. Completion subtracts it for the latency
    // histogram, so a deferred op's wait in the local backlog is excluded —
    // that wait is backpressure, not device latency, and conflating the two
    // would make a retry storm look like a slow device.
    uint64_t                submit_ns = 0;
};

// One xnvme_dev + one xnvme_queue, exclusively owned by its reactor thread.
struct QueueWorker {
    struct xnvme_dev   *dev   = nullptr;
    struct xnvme_queue *queue = nullptr;
    pthread_t           thread{};

    std::mutex                    mbox_mtx;
    std::condition_variable       mbox_cv;
    std::deque<XnvmeKvWorkEx *>   mbox;
    std::atomic<bool>             stop{false};

    // steady-clock ns of the last observed forward progress on this queue —
    // updated on every successful submission and on every completion. Used
    // only to detect "the device has stopped responding entirely"; see
    // reactor_loop()'s stall check. Touched exclusively by this worker's own
    // reactor thread (completions run from xnvme_queue_poke() on that same
    // thread), so it needs no synchronization.
    uint64_t                      last_progress_ns = 0;
    // Ops submitted and accepted by the device but not yet completed. Needed
    // by the stall check for the case that matters most: the device accepts a
    // batch, the local backlog drains to empty, and THEN the device wedges. A
    // check that only looked at pending-but-unsubmitted work would see an empty
    // backlog and never fire, which is precisely the wedge this is for.
    // Same single-thread ownership as last_progress_ns.
    uint64_t                      in_flight = 0;
    // Latches once a stall has been reported, so the diagnostic is printed once
    // rather than every loop iteration. Cleared on any forward progress.
    bool                          stall_reported = false;

    // ---- M0/W0.2 runtime metrics ------------------------------------------
    // Incremented ONLY by this worker's own reactor thread (submit_one() and
    // completion_trampoline() both run there), and read by whichever reactor
    // happens to win the metrics-write claim. Relaxed atomics rather than plain
    // integers purely because the reader is a different thread; single-writer
    // means there is never RMW contention on them.
    //
    // These exist because the aggregate counters this plugin family used to
    // keep were emitted ONLY at engine teardown. During the 2026-08-25
    // SPDK_NVMe_KV validation that total never printed at all and the deferral
    // count could not be recovered: a metric emitted only at shutdown does not
    // exist for a container that runs for days.
    std::atomic<uint64_t> m_store_ops{0};
    std::atomic<uint64_t> m_retrieve_ops{0};
    std::atomic<uint64_t> m_store_bytes{0};
    std::atomic<uint64_t> m_retrieve_bytes{0};
    std::atomic<uint64_t> m_completions_ok{0};
    std::atomic<uint64_t> m_completions_err{0};
    std::atomic<uint64_t> m_submit_retry{0};   // -EBUSY/-EAGAIN/-ENOMEM backpressure
    std::atomic<uint64_t> m_submit_fail{0};    // genuine submission failures
    std::atomic<uint64_t> m_stalls{0};         // stall-check trips
    std::atomic<uint64_t> m_peak_in_flight{0};
    std::atomic<uint64_t> m_lat_sum_us{0};
    // Device-latency histogram, submit-accepted -> completion. Bucket upper
    // bounds in XNVME_KV_LAT_BUCKET_US; last bucket is the overflow.
    std::atomic<uint64_t> m_lat_bucket[8]{};
};

// Upper bounds (microseconds) for QueueWorker::m_lat_bucket. Chosen around the
// ~100 us scale a real NVMe-oF/TCP KV round-trip lands at, with enough headroom
// above it that a wedge-in-progress is visibly distinct from a slow device.
static constexpr uint64_t XNVME_KV_LAT_BUCKET_US[8] = {
    16, 64, 256, 1024, 4096, 16384, 65536, UINT64_MAX
};

class nixlXnvmeKvEngine : public nixlBackendEngine {
public:
    explicit nixlXnvmeKvEngine(const nixlBackendInitParams *init_params);
    ~nixlXnvmeKvEngine() override;

    // Max single-value size as reported by the device's KV Identify Namespace,
    // discovered once at construction. 0 = not discovered (no backend created
    // yet, or the query failed) — getParams() then reports the compiled-in
    // XNVME_KV_DEFAULT_MAX_VALUE_SIZE instead.
    //
    // Read by the plugin's getParams() in xnvme_kv_plugin.cpp. That works
    // because NIXL never caches plugin params: nixlAgent::getPluginParams()
    // calls nixlBackendPluginHandle::getBackendOptions(), which calls the
    // plugin's get_backend_options function pointer fresh every time (see
    // nixl src/core/nixl_plugin_manager.cpp). So a value stored here during
    // create_backend() is visible to a get_plugin_params() call made after it
    // — which is the order LMCache uses.
    //
    // Static rather than per-instance because getParams() is a plugin-level
    // callback with no engine pointer. Multiple engines on different devices
    // would race; in practice one process opens one KV device, and the
    // conservative-fallback design below means a lost race costs finer
    // splitting, never a too-large write.
    static std::atomic<uint32_t> discovered_max_value_size_;

    bool supportsRemote() const override { return false; }
    bool supportsLocal()  const override { return true; }
    bool supportsNotif()  const override { return false; }

    nixl_mem_list_t getSupportedMems() const override {
        // OBJ_SEG alongside FILE_SEG: same local-KV-store semantics in this
        // plugin, just the enum tag NIXL/callers (e.g. LMCache's OBJ-mode
        // storage backend) use for type-checking the remote/storage side.
#ifndef NIXL_XNVME_NO_VRAM
        return {DRAM_SEG, VRAM_SEG, FILE_SEG, OBJ_SEG};
#else
        return {DRAM_SEG, FILE_SEG, OBJ_SEG};
#endif
    }

    nixl_status_t connect(const std::string &)    override { return NIXL_SUCCESS; }
    nixl_status_t disconnect(const std::string &) override { return NIXL_SUCCESS; }
    nixl_status_t loadLocalMD(nixlBackendMD *in, nixlBackendMD *&out) override {
        out = in; return NIXL_SUCCESS;
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

    bool     ready_ = false;
    uint32_t nsid_  = 0;

private:
    std::string dev_uri_;
    size_t      num_queues_ = 1;
    std::vector<std::unique_ptr<QueueWorker>> workers_;
    mutable std::atomic<uint32_t> next_queue_{0};  // round-robin dispatch index

    // How long a queue may make ZERO forward progress — no submission accepted
    // and no completion reaped — while work is still pending, before that work
    // is failed. 0 disables the check.
    //
    // This exists because the retry path below is otherwise unbounded: if the
    // device stops completing, work is re-queued forever, req->pending never
    // reaches 0, and checkXfer() returns NIXL_IN_PROG for all time. On THIS
    // plugin that is not a hypothetical — XNVME_KV is the path to the real
    // Pensando DSC, whose documented failure mode is exactly "stops completing
    // and never recovers" (see CLAUDE.md's safety section).
    //
    // IMPORTANT: tripping this reports an error to the caller and NOTHING ELSE.
    // It must never attempt device recovery — no reset, no FLR, no re-init. Per
    // CLAUDE.md, host-side attempts to clear a wedged DSC make it strictly
    // worse and the only real recovery is an out-of-band DPU-side restart.
    // Turning a permanent hang into a reported failure is the entire goal.
    uint64_t    stall_timeout_ns_ = 0;

    // ---- M0/W0.2 metrics export -------------------------------------------
    // Absolute path of the JSON metrics file, or empty when export is off.
    // Resolved once at construction using the SAME directory search order as
    // bench/lib/deployment.sh's deployment record ($KV_BENCH_DEPLOY_STATE_DIR,
    // /run/kv-cache-bench, $XDG_RUNTIME_DIR/kv-cache-bench,
    // /tmp/kv-cache-bench-$(id -u)) — deliberately not a sixth location, since
    // the non-root landing spot has already produced two wrong "no record"
    // conclusions in this project.
    std::string metrics_path_;
    // Write period in ns; 0 disables. NIXL_KV_METRICS_INTERVAL_SEC, default 10.
    uint64_t    metrics_interval_ns_ = 0;
    // steady-clock ns of the last write. Claimed with compare_exchange so that
    // exactly one reactor thread writes per interval.
    std::atomic<uint64_t> last_metrics_ns_{0};

    // Aggregate every worker's counters and rewrite metrics_path_ atomically
    // (write to .tmp, then rename). Cheap enough to call unconditionally from
    // the reactor loop — it self-throttles on metrics_interval_ns_.
    // force=true bypasses the interval throttle and is used for the final
    // flush at reactor shutdown. Without that flush the last (up to
    // metrics_interval_ns_) worth of ops is silently lost — which is the exact
    // inverse of the teardown-only bug this whole mechanism exists to fix, and
    // it was caught by the first real run rather than by reading the code.
    void          write_metrics(bool force = false);

    // Fail every work item still queued for `qw` — both deferred-locally and
    // still sitting in its mbox. Each item holds a decrement of req->pending,
    // so dropping one silently leaves a caller blocked in checkXfer()/waitXfer()
    // forever; failing it surfaces an error instead.
    void          fail_queued_work(QueueWorker *qw, std::deque<XnvmeKvWorkEx *> &local);

    nixl_status_t start_workers();
    void          stop_workers();

    // Issue Identify Namespace (CSI=KV) and publish the device's reported
    // KV Value Max Length into discovered_max_value_size_. Best-effort: any
    // failure leaves the value at 0 so the compiled-in default is used.
    void          query_max_value_size(struct xnvme_dev *dev);

    static void  *reactor_entry(void *arg);
    void          reactor_loop(QueueWorker *qw);

    // kSubmitted: async op in flight, completion_trampoline will finish it.
    // kRetry: transient "queue full" (-EBUSY/-EAGAIN/-ENOMEM) — ctx already
    //   returned to the pool; caller should re-submit `work` later, not treat
    //   it as failed. See submit_one()'s .cpp comment for why this matters.
    // kFailed: permanent error — kv_complete_cb(work, false) already called.
    enum class SubmitResult { kSubmitted, kRetry, kFailed };
    SubmitResult submit_one(QueueWorker *qw, struct xnvme_cmd_ctx *ctx,
                            XnvmeKvWorkEx *work) const;

    static void kv_complete_cb(XnvmeKvWorkEx *work, bool ok);
    static void completion_trampoline(struct xnvme_cmd_ctx *ctx, void *cb_arg);

    // FNV-1a 64-bit, deliberately not std::hash (which is only guaranteed
    // stable within a single process/build, not a suitable contract for a
    // key two independent processes/agents must agree on).
    static uint64_t fnv1a64(const std::string &s, uint64_t seed) {
        uint64_t h = seed;
        for (unsigned char c : s) {
            h ^= c;
            h *= 1099511628211ULL;
        }
        return h;
    }

    // meta_info non-empty (e.g. LMCache's OBJ-mode object name, carried via
    // nixlBlobDesc::metaInfo): derive the 12-byte on-device key
    // from it via two independently-seeded FNV-1a hashes, ignoring dev_id/
    // addr (which are meaningless/non-stable in that mode — see
    // nixlXnvmeKvMD::meta_info). meta_info empty (kv_io.py, nixlbench,
    // anything that never sets metaInfo): unchanged devId/addr derivation.
    static void make_key(uint64_t dev_id, uint64_t addr, const std::string &meta_info,
                         uint8_t *key_out, uint8_t *key_len_out) {
        uint8_t k[12] = {};
        if (!meta_info.empty()) {
            uint64_t h1 = fnv1a64(meta_info, 14695981039346656037ULL);
            uint64_t h2 = fnv1a64(meta_info, 0x9E3779B97F4A7C15ULL);
            std::memcpy(k, &h1, 8);
            uint32_t lo = static_cast<uint32_t>(h2 & 0xFFFFFFFF);
            std::memcpy(k + 8, &lo, 4);
        } else {
            std::memcpy(k, &dev_id, 8);
            uint32_t lo = static_cast<uint32_t>(addr & 0xFFFFFFFF);
            std::memcpy(k + 8, &lo, 4);
        }
        std::memcpy(key_out, k, 12);
        *key_len_out = 12;
    }

    struct ErrLog {
        ErrLog(const char *f, int l) {
            std::fprintf(stderr, "[XNVME_KV] %s:%d: ", f, l);
        }
        ~ErrLog() { std::fputc('\n', stderr); std::fflush(stderr); }
        template<typename T>
        ErrLog &operator<<(const T &v) {
            std::ostringstream s; s << v;
            std::fputs(s.str().c_str(), stderr);
            return *this;
        }
    };
};

#define XNVME_PLUGIN_ERR nixlXnvmeKvEngine::ErrLog(__FILE__, __LINE__)
