// SPDK NVMe-KV NIXL backend plugin.
// Transfers data between DRAM_SEG/VRAM_SEG and FILE_SEG (NVMe-KV namespace)
// using SPDK's kernel-bypass NVMe driver and the NVMe Key-Value Command Set.
//
// VRAM_SEG is staged, not zero-copy: the GPU (MI210) and the Pensando DSC
// sit on different NUMA nodes/CPU sockets on the hosts this runs on, so true
// peer-to-peer DMA isn't a worthwhile investment here (see project notes) —
// every VRAM transfer bounces through a spdk_zmalloc()'d + hipHostRegister()'d
// host staging buffer via hipMemcpy, same pattern as rocm-plugin's POSIX path.
//
// Two modes (selected at construction time via NIXL_KV_INPROCESS env var):
//
//   TCP mode (default):  connects to a running spdk_tgt over NVMe-oF TCP.
//     trid: "trtype:TCP adrfam:IPv4 traddr:127.0.0.1 trsvcid:4420 ..."
//     Good for testing; replace with PCIe trid for real hardware.
//
//   In-process mode (NIXL_KV_INPROCESS=1):  no separate process, no TCP.
//     KV data lives in a hugepage-backed RAM buffer inside this process.
//     When real PCIe NVMe-KV hardware is attached (kernel driver unbound,
//     device handed to uio_pci_generic/vfio-pci), clear NIXL_KV_INPROCESS
//     and set NIXL_KV_TRID="trtype:PCIe traddr:0000:xx:yy.z" — the same
//     async code path calls spdk_nvme_kv_store() over PCIe instead of memcpy.
//
// Async model:
//   postXfer() submits ALL descriptors in the batch without waiting.
//   checkXfer() returns NIXL_IN_PROG until the atomic pending counter hits 0.
//   nixlbench's waitXfer() spins on checkXfer() — no condition variable needed
//   for the fast path; cv.notify is only used if a caller explicitly waits.
//
// Key encoding: 12 bytes, derived two ways depending on the descriptor (see
// make_key() below):
//   metaInfo set   — FNV-1a(metaInfo) x2 seeds. This is the path LMCache OBJ
//                    mode takes, and the only one safe for a namespace shared
//                    by more than one deployment. NOTE: the caller's metaInfo
//                    is NOT content-derived and is NOT stable across processes
//                    — LMCache names objects obj_{slot}_{uuid4}[#{part}],
//                    i.e. a pool-slot name carrying a per-process random
//                    suffix, bound at registerMem() time. That is exactly why
//                    it de-collides two deployments, and exactly why it cannot
//                    support restart survival or cross-process sharing.
//   metaInfo empty — 8 bytes devId + 4 bytes addr[31:0], as before. Used by
//                    kv_io.py / nixlbench, which never set metaInfo.
//   In-process slot: slot = (devId * Knuth64 XOR addr) % num_slots_
//   NVMe-KV key: the 12 bytes passed directly to spdk_nvme_kv_store/retrieve.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <pthread.h>
#include <sstream>
#include <string>
#include <vector>

extern "C" {
#include "spdk/env.h"
#include "spdk/nvme.h"
#include "spdk/nvme_kv.h"
#include "spdk/thread.h"
}

#ifndef NIXL_KV_NO_VRAM
#include <hip/hip_runtime.h>
#endif

#include "backend/backend_engine.h"

// Compiled-in fallback for the max single-value size, used when the device has
// not been queried yet (no backend instance created) or the query failed.
//
// Unlike XNVME_KV's 32768 (a real DSC firmware limit), this number is NOT a
// device limit: bdev_kvmalloc allows 64 MiB values. It is the NVMe-oF/TCP
// transport's SGL ceiling — nvmf_tcp_create() rejects max_io_size above
// roughly max_io_size/large_bufsize(132KB) > SPDK_NVMF_MAX_SGL_ENTRIES(16),
// i.e. ~2MB, and start-kv-target.sh configures max_io_size=1048576. 524288
// leaves headroom under that for NVMe/TCP PDU framing. So the effective limit
// is min(device KV Value Max Length, controller max transfer size) — see
// query_max_value_size() in the .cpp, which takes exactly that minimum.
#define SPDK_KV_DEFAULT_MAX_VALUE_SIZE 524288u

// Per-registered memory descriptor.
class nixlSpdkKvMD : public nixlBackendMD {
public:
    nixl_mem_t  type;
    void       *ptr    = nullptr;
    size_t      size   = 0;
    uint64_t    dev_id = 0;
    // Set from nixlBlobDesc::metaInfo at registerMem() time — when non-empty,
    // this (not devId/addr) is the caller-supplied KV identity (e.g. LMCache's
    // OBJ-mode object name, obj_{slot}_{uuid4}[#{part}]: instance-unique, NOT
    // content-derived, and re-randomised on every process start). Empty for
    // callers that never set metaInfo (kv_io.py, nixlbench), which keep the
    // original devId/addr-derived key.
    // Mirrors nixlXnvmeKvMD::meta_info exactly — see xnvme_kv_backend.h.
    std::string meta_info;

    explicit nixlSpdkKvMD() : nixlBackendMD(true) {}
    ~nixlSpdkKvMD() override = default;
};

// Per-transfer request handle. Holds an atomic countdown of in-flight ops.
struct nixlSpdkKvReqH : public nixlBackendReqH {
    std::atomic<int>  pending{0};   // decremented by completion callbacks
    std::atomic<bool> error{false}; // set on any failed op
    // cv/mtx only used if a caller blocks in waitXfer(); not hot path.
    std::mutex              mtx;
    std::condition_variable cv;

    // VRAM_SEG staging buffer (see "Staged VRAM support" in the .cpp) — one
    // spdk_zmalloc()'d, hipHostRegister()'d buffer per batch, sized to the
    // batch's total bytes. Null/0 when the batch has no VRAM_SEG side.
    void   *staging_    = nullptr;
    size_t  staging_sz_ = 0;

    ~nixlSpdkKvReqH() override;
};

// Forward declaration
class nixlSpdkKvEngine;

// Async I/O work item — heap-allocated in postXfer(), freed by completion cb.
struct SpdkKvWorkEx {
    nixlSpdkKvEngine       *engine  = nullptr;
    struct spdk_nvme_ns    *ns      = nullptr;
    struct spdk_nvme_qpair *qpair   = nullptr;
    uint8_t                 key[SPDK_NVME_KV_KEY_MAX_LEN] = {};
    uint8_t                 key_len = 0;
    void                   *buf     = nullptr;
    uint32_t                buf_len = 0;
    nixl_xfer_op_t          op      = NIXL_WRITE;
    nixlSpdkKvReqH         *req     = nullptr;
    // Which reactor (and therefore which qpair) owns this item. Needed so a
    // submission deferred by -ENOMEM can be pushed onto the RIGHT reactor's
    // retry queue: a qpair may only be touched by the single thread that polls
    // it, so an item must never migrate between reactors. This is the EFFECTIVE
    // index actually used, which is not always the round-robin pick — postXfer
    // falls back to reactor 0 when a higher-index qpair failed to allocate.
    uint32_t                reactor_idx = 0;
    // steady-clock nanoseconds at which this item FIRST hit -ENOMEM, or 0 if it
    // never has. Used to bound how long a single item may sit in the retry
    // queue, so a permanently stalled device fails loudly instead of leaving
    // the transfer pending forever (checkXfer would otherwise return
    // NIXL_IN_PROG for all time, which reads as a hang).
    uint64_t                enomem_since_ns = 0;
    // VRAM_SEG READ only: destination VRAM pointer to hipMemcpy `buf`
    // (a staging-buffer slice) into once the SPDK retrieve completes.
    // Null for DRAM_SEG transfers and for all WRITEs (those copy VRAM->staging
    // synchronously in postXfer, before submission).
    void                   *vram_dst = nullptr;
};

// SPDK probe context.
struct ProbeCtx {
    struct spdk_nvme_ctrlr *ctrlr   = nullptr;
    struct spdk_nvme_ns    *kv_ns   = nullptr;
    struct spdk_nvme_qpair *qpair   = nullptr;
    bool                    found   = false;
    // Requested I/O queue count, passed in before spdk_nvme_probe() so
    // probe_cb can size opts->num_io_queues — see kv_bench_spdk's probe_cb
    // (spdk_env_get_core_count()) for the reference pattern this mirrors.
    uint32_t                num_io_queues = 1;
};

class nixlSpdkKvEngine : public nixlBackendEngine {
public:
    explicit nixlSpdkKvEngine(const nixlBackendInitParams *init_params);
    ~nixlSpdkKvEngine() override;

    // Max single-value size discovered at construction — min(device KV Value
    // Max Length, controller max transfer size). 0 = not discovered (no
    // backend created yet, query failed, or in-process mode) — getParams()
    // then reports the compiled-in SPDK_KV_DEFAULT_MAX_VALUE_SIZE.
    //
    // Read by getParams() in spdk_nvme_kv_plugin.cpp. Safe because NIXL never
    // caches plugin params: nixlAgent::getPluginParams() ->
    // nixlBackendPluginHandle::getBackendOptions() calls the plugin's
    // function pointer fresh every time (nixl src/core/nixl_plugin_manager.cpp),
    // so a value stored here during create_backend() is visible to any later
    // get_plugin_params() — the order LMCache uses.
    //
    // Static because getParams() is a plugin-level callback with no engine
    // pointer. See the XNVME_KV counterpart for the same reasoning.
    static std::atomic<uint32_t> discovered_max_value_size_;

    bool supportsRemote() const override { return false; }
    bool supportsLocal()  const override { return true; }
    bool supportsNotif()  const override { return false; }

    nixl_mem_list_t getSupportedMems() const override {
        // OBJ_SEG alongside FILE_SEG: LMCache's key-addressed storage pool
        // (NixlObjectPool) uses OBJ_SEG descriptors, handled identically to
        // FILE_SEG in registerMem()/prepXfer() below — see spdk_nvme_kv_backend.cpp.
        // Mirrors xnvme_kv_backend.h's identical FILE_SEG/OBJ_SEG pairing.
#ifndef NIXL_KV_NO_VRAM
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

    // SPDK NVMe state (TCP or PCIe mode).
    // One qpair per reactor thread — see NIXL_KV_NUM_QPAIRS. Each qpair is only
    // ever submitted-to/polled-by its own reactor thread (spdk_thrs_[i]); no
    // cross-thread access, so no mutex is needed around them.
    struct spdk_nvme_ctrlr *ctrlr_ = nullptr;
    struct spdk_nvme_ns    *kv_ns_ = nullptr;
    std::vector<struct spdk_nvme_qpair *> qpairs_;

    // In-process KV buffer (hugepage-backed).
    bool     inprocess_mode_ = false;
    uint8_t *kvbuf_          = nullptr;
    size_t   num_slots_      = 0;
    size_t   slot_size_      = 0;  // bytes per slot (= max value size)

    // Map a 12-byte key to a slot index in kvbuf_.
    uint64_t slot_for_key(const uint8_t *key12) const {
        uint64_t dev_id = 0; uint32_t lo = 0;
        std::memcpy(&dev_id, key12,   8);
        std::memcpy(&lo,     key12+8, 4);
        // Knuth multiplicative hash to spread devId, XOR with block address.
        return ((dev_id * 2654435761ULL) ^ static_cast<uint64_t>(lo)) % num_slots_;
    }

private:
    size_t                  num_qpairs_ = 1;
    std::vector<pthread_t>  thread_ids_;
    std::vector<struct spdk_thread *> spdk_thrs_;
    // NUMA-local CPU list for the target device (from sysfs local_cpulist),
    // populated before reactor threads are spawned — see local_cpus_for_trid()
    // in the .cpp. Read-only once set; safe for reactor threads to read
    // without synchronization.
    std::vector<int>        reactor_cpus_;
    mutable std::atomic<uint32_t> next_qpair_{0};  // round-robin dispatch index
    std::atomic<uint32_t>  reactors_ready_{0};      // counts up to num_qpairs_
    std::atomic<bool>      reactor_stop_{false};
    std::mutex             ready_mtx_;
    std::condition_variable ready_cv_;
    std::string            trid_str_;
    // Added to devId before make_key() hashes it into the on-wire key — see
    // getParams()'s "kv_slot_offset" doc comment in spdk_nvme_kv_plugin.cpp.
    uint64_t               slot_offset_ = 0;

    // ---- -ENOMEM backpressure (see do_kv_io_async / drain_retry_queue) -----
    //
    // One deferred-submission queue per reactor. Each is touched ONLY by its
    // own reactor thread — do_kv_io_async() runs on that thread, and so does
    // drain_retry_queue() — so these need no locking. Do not access them from
    // postXfer() or any caller thread; that assumption is what makes them safe.
    std::vector<std::deque<SpdkKvWorkEx *>> retry_qs_;
    // How long a single item may stay deferred before it is failed. Bounds the
    // "device stopped draining" case, which would otherwise hang a transfer
    // permanently. Override with NIXL_KV_ENOMEM_TIMEOUT_SEC.
    uint64_t               enomem_timeout_ns_ = 0;
    // Observability: without these, a fixed -ENOMEM storm is indistinguishable
    // from never having hit one, and this fix would be unverifiable from logs.
    //
    // Reported in three places on purpose, because one is not enough:
    //   FIRST    — enomem_logged_, a one-shot notice the moment backpressure
    //              first occurs, so it is visible immediately.
    //   ONGOING  — a throttled periodic report (below) while it continues.
    //   FINAL    — a total at teardown, in stop_spdk_reactor().
    // The teardown total ALONE was the original design and it was not enough:
    // a serving container runs for days, so during the 2026-08-25 validation the
    // total never printed at all and the deferral count could not be recovered.
    // A metric only emitted at shutdown does not exist for a long-lived process.
    //
    // Deliberately NOT exposed through the plugin's getParams(): that publishes
    // into a process-global STATIC table (the same one already documented as
    // reporting a stale compiled-in `trid`, and which a second backend in the
    // same process overwrites). A per-engine runtime counter surfaced through a
    // process-global name would be wrong precisely when it mattered most.
    std::atomic<uint64_t>  enomem_retries_{0};
    std::atomic<bool>      enomem_logged_{false};
    // Counter value as of the last periodic report, and when that report was
    // emitted. Atomic because every reactor thread may reach the report point;
    // the timestamp is claimed with compare_exchange so only one of them prints
    // per interval.
    std::atomic<uint64_t>  enomem_reported_{0};
    std::atomic<uint64_t>  enomem_report_at_ns_{0};
    // Minimum gap between periodic reports. Throttled by TIME rather than by
    // count so the log volume is bounded no matter how deep the batch gets:
    // a single 3,520-descriptor store can defer thousands of ops in well under
    // a second. Override with NIXL_KV_BACKPRESSURE_LOG_SEC; 0 disables the
    // periodic report (the first-signal and teardown lines still print).
    uint64_t               enomem_report_interval_ns_ = 0;

    // Emit the periodic backpressure report if one is due. Cheap no-op when
    // nothing new has been deferred, so it is safe to call every reactor tick.
    void maybe_report_backpressure(size_t idx, size_t depth);

    nixl_status_t start_spdk_reactor();
    void          stop_spdk_reactor();

    // Read the namespace's KV Identify data and the controller's max transfer
    // size, and publish min(the two) into discovered_max_value_size_.
    // Best-effort: any failure leaves it 0 so the compiled-in default is used.
    void          query_max_value_size();

    struct ReactorArgs { nixlSpdkKvEngine *engine; size_t idx; };
    static void *reactor_entry(void *arg);
    void         reactor_loop(size_t idx);

    // Async I/O dispatcher (called on SPDK reactor thread).
    static void do_kv_io_async(void *arg);

    // The bare submission, factored out so do_kv_io_async() and
    // drain_retry_queue() cannot drift apart. Returns spdk_nvme_kv_*'s raw rc:
    // 0 submitted, -ENOMEM the queue is momentarily full (RETRYABLE, not an
    // error), anything else a genuine failure.
    static int submit_kv_io(SpdkKvWorkEx *work);

    // Re-submit items previously deferred by -ENOMEM. MUST be called from the
    // owning reactor thread and only AFTER spdk_nvme_qpair_process_completions()
    // in the same loop iteration — that ordering is the entire mechanism, since
    // draining completions is what frees the submission-queue slots the retry
    // needs. Stops at the first -ENOMEM rather than spinning the whole queue.
    void drain_retry_queue(size_t idx);

    // Fail every item still deferred on reactor `idx`. Called during shutdown
    // so a queued item can never be dropped silently: its req->pending would
    // never be decremented and the transfer would hang instead of erroring.
    void flush_retry_queue_failed(size_t idx);

    // NVMe-oF completion callbacks (TCP / PCIe modes).
    static void kv_store_cb_async(void *arg, const struct spdk_nvme_cpl *cpl);
    static void kv_retrieve_cb_async(void *arg, const struct spdk_nvme_cpl *cpl);

    // Shared completion handler — decrements pending, frees work item.
    static void kv_complete_cb(SpdkKvWorkEx *work, bool ok);

    // FNV-1a over a string with a caller-supplied seed. Chosen (over
    // std::hash) because the on-wire key must be reproducible across
    // processes, hosts and rebuilds — std::hash is only stable within a
    // single process/build, which is not a suitable contract for a key two
    // independent agents must agree on. Identical to xnvme_kv_backend.h's
    // fnv1a64(); the two plugins must derive byte-identical keys from the
    // same meta_info or they cannot share a namespace.
    static uint64_t fnv1a64(const std::string &s, uint64_t seed) {
        uint64_t h = seed;
        for (unsigned char c : s) {
            h ^= c;
            h *= 1099511628211ULL;
        }
        return h;
    }

    // meta_info non-empty (e.g. LMCache's OBJ-mode object name, carried via
    // nixlBlobDesc::metaInfo): derive the 12-byte on-device key from it via
    // two independently-seeded FNV-1a hashes, ignoring dev_id/addr. meta_info
    // empty (kv_io.py, nixlbench, anything that never sets metaInfo):
    // unchanged devId/addr derivation.
    //
    // Why this matters: devId is a storage-pool slot index allocated from 0
    // independently by each caller's NixlObjPool, so the devId/addr derivation
    // makes two independent deployments sharing one namespace collide on their
    // early slot indices (rocm-aic README §3 — ~30/30 STOREs rejected as
    // duplicate keys on a target that refuses overwrite, 8/8 silent read-back
    // corruption on one that allows it). Keying off the caller's own object
    // name removes that class of collision entirely, and makes kv_slot_offset
    // redundant for OBJ_SEG (it still applies on the devId path for FILE_SEG
    // callers). It does NOT make the key content-derived or stable across
    // processes — LMCache's name carries a per-process uuid4 — so nothing here
    // supports restart survival or cross-process value sharing.
    static void make_key(uint64_t dev_id, uint64_t addr,
                         const std::string &meta_info,
                         uint8_t *key_out, uint8_t *key_len_out) {
        uint8_t k[12] = {};
        if (!meta_info.empty()) {
            uint64_t h1 = fnv1a64(meta_info, 14695981039346656037ULL);
            uint64_t h2 = fnv1a64(meta_info, 0x9E3779B97F4A7C15ULL);
            std::memcpy(k, &h1, 8);
            uint32_t lo = static_cast<uint32_t>(h2 & 0xFFFFFFFF);
            std::memcpy(k + 8, &lo, 4);
        } else {
            std::memcpy(k,     &dev_id, 8);
            uint32_t lo = static_cast<uint32_t>(addr & 0xFFFFFFFF);
            std::memcpy(k + 8, &lo,     4);
        }
        std::memcpy(key_out, k, 12);
        *key_len_out = 12;
    }

    struct ErrLog {
        ErrLog(const char *f, int l) {
            std::fprintf(stderr, "[SPDK_NVMe_KV] %s:%d: ", f, l);
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

#define SPDK_PLUGIN_ERR nixlSpdkKvEngine::ErrLog(__FILE__, __LINE__)
