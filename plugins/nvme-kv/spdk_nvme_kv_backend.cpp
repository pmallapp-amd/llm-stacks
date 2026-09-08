// SPDK NVMe-KV NIXL backend — implementation.
// See spdk_nvme_kv_backend.h for mode descriptions.
//
// Async model:
//   postXfer() heap-allocates one SpdkKvWorkEx per descriptor, posts all via
//   spdk_thread_send_msg(), then returns NIXL_IN_PROG immediately (no blocking).
//   The SPDK reactor thread calls do_kv_io_async() for each work item:
//     - In-process mode: memcpy into/from kvbuf_, call kv_complete_cb().
//     - TCP/PCIe mode:   spdk_nvme_kv_store/retrieve(); callback calls kv_complete_cb().
//   kv_complete_cb() atomically decrements req->pending. When it reaches zero
//   the entire batch is done. checkXfer() reads the counter — no mutex needed.
//
// In-process KV buffer layout:
//   kvbuf_[slot * slot_size_ .. (slot+1) * slot_size_)  holds the value.
//   slot = slot_for_key(key12) — see header for the hash function.
//   slot_size_ = NIXL_KV_SLOT_MB * 1048576 (default 64MB, set via env var).
//   Total buffer = NIXL_KV_BUF_GB * 1024^3 (default 8 GB).
//   Allocated with rte_malloc (2MB-aligned hugepage backing) when DPDK is
//   initialised, or with posix_memalign as fallback if hugepages are absent.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "spdk_nvme_kv_backend.h"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>   // queryMem's per-probe work items
#include <thread>   // queryMem's bounded wait

// Populated by query_max_value_size() at construction; read by the plugin's
// getParams(). See the declaration in the header for why this is static and
// why a zero/stale value is always the safe direction.
std::atomic<uint32_t> nixlSpdkKvEngine::discovered_max_value_size_{0};
#include <sched.h>
#include <sstream>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>

extern "C" {
#include <rte_errno.h>
#include <rte_malloc.h>
#include "spdk/env.h"
#include "spdk/log.h"
#include "spdk/nvme.h"
#include "spdk/nvme_kv.h"
#include "spdk/string.h"
#include "spdk/thread.h"
}

// ---- NUMA-local CPU discovery -----------------------------------------------
// Reactor threads must be pinned to cores on the SAME NUMA node as the NVMe
// device, not just "any core but 0" — cross-socket polling/DMA measurably
// hurts throughput (confirmed: qpair-count scaling regressed 3.04->0.70 GB/s
// on a host where the naive "1 + idx % (nproc-1)" scheme alternated reactors
// between the device's node and the far socket). /sys/bus/pci/devices/<bdf>/
// local_cpulist is the kernel's own answer for "which cores are local to this
// device" — use it instead of guessing.

static std::vector<int> parse_cpulist(const std::string &s) {
    std::vector<int> cpus;
    std::stringstream ss(s);
    std::string tok;
    while (std::getline(ss, tok, ',')) {
        auto dash = tok.find('-');
        if (dash != std::string::npos) {
            int lo = std::atoi(tok.substr(0, dash).c_str());
            int hi = std::atoi(tok.substr(dash + 1).c_str());
            for (int c = lo; c <= hi; ++c) cpus.push_back(c);
        } else if (!tok.empty()) {
            cpus.push_back(std::atoi(tok.c_str()));
        }
    }
    return cpus;
}

// Returns the NVMe device's NUMA-local CPU list for PCIe transports (parsed
// from sysfs), or "every core but 0" as a reasonable default for TCP loopback
// (no PCIe device to be local to) or if sysfs is unavailable.
static std::vector<int> local_cpus_for_trid(const std::string &trid_str) {
    auto pos = trid_str.find("traddr:");
    if (pos != std::string::npos) {
        std::string bdf = trid_str.substr(pos + 7);
        auto space = bdf.find(' ');
        if (space != std::string::npos) bdf = bdf.substr(0, space);
        std::ifstream f("/sys/bus/pci/devices/" + bdf + "/local_cpulist");
        std::string line;
        if (f.good() && std::getline(f, line)) {
            auto cpus = parse_cpulist(line);
            if (!cpus.empty()) return cpus;
        }
    }
    long nproc = sysconf(_SC_NPROCESSORS_ONLN);
    std::vector<int> cpus;
    for (long c = 1; c < nproc; ++c) cpus.push_back(static_cast<int>(c));
    if (cpus.empty()) cpus.push_back(0);
    return cpus;
}

// ---- nixlSpdkKvReqH ---------------------------------------------------------

nixlSpdkKvReqH::~nixlSpdkKvReqH() {
#ifndef NIXL_KV_NO_VRAM
    if (staging_) {
        (void)hipHostUnregister(staging_);
        spdk_free(staging_);
    }
#endif
}

// ---- Shared completion path ------------------------------------------------

void nixlSpdkKvEngine::kv_complete_cb(SpdkKvWorkEx *work, bool ok) {
    auto *req = work->req;
    if (!ok) req->error.store(true, std::memory_order_relaxed);
    // Decrement and check if last op in the batch.
    if (req->pending.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        // All descriptors done — wake any blocking waitXfer caller.
        req->cv.notify_all();
    }
    delete work;
}

// ---- NVMe-oF / PCIe async completion callbacks ----------------------------

void nixlSpdkKvEngine::kv_store_cb_async(void *arg,
                                          const struct spdk_nvme_cpl *cpl) {
    auto *work = static_cast<SpdkKvWorkEx *>(arg);
    kv_complete_cb(work, spdk_nvme_cpl_is_success(cpl));
}

void nixlSpdkKvEngine::kv_retrieve_cb_async(void *arg,
                                              const struct spdk_nvme_cpl *cpl) {
    auto *work = static_cast<SpdkKvWorkEx *>(arg);
    bool ok = spdk_nvme_cpl_is_success(cpl);
#ifndef NIXL_KV_NO_VRAM
    // VRAM_SEG READ: copy the just-retrieved staging-buffer slice into VRAM
    // before signalling completion.
    if (ok && work->vram_dst) {
        hipError_t e = hipMemcpy(work->vram_dst, work->buf, work->buf_len,
                                  hipMemcpyHostToDevice);
        if (e != hipSuccess) {
            SPDK_PLUGIN_ERR << "staging->VRAM hipMemcpy failed: " << hipGetErrorString(e);
            ok = false;
        }
    }
#endif
    kv_complete_cb(work, ok);
}

// ---- Async I/O dispatcher (runs on SPDK reactor thread) -------------------

// steady clock in ns. Deliberately not spdk_get_ticks(): this only ever
// measures a coarse multi-second deadline, and steady_clock cannot be affected
// by a TSC-frequency mis-detection.
static inline uint64_t kv_now_ns() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

// "Submission queue is momentarily full" — retry, do not fail.
//
// Both signs are accepted deliberately. SPDK's convention is negative errno,
// but this is the hinge the whole fix turns on: if the KV wrapper ever returns
// a positive errno, a sign-only check would silently never engage and the bug
// would look unfixed while appearing handled in the source. Accepting both is
// free and cannot misfire, because every nonzero rc is a failure in this API —
// the only question is whether it is transient.
static inline bool kv_rc_is_retryable(int rc) {
    return rc == -ENOMEM || rc == ENOMEM || rc == -EAGAIN || rc == EAGAIN;
}

int nixlSpdkKvEngine::submit_kv_io(SpdkKvWorkEx *work) {
    if (work->op == NIXL_WRITE) {
        return spdk_nvme_kv_store(work->ns, work->qpair,
                                  work->key, work->key_len,
                                  work->buf, work->buf_len,
                                  kv_store_cb_async, work, /*options=*/0);
    }
    return spdk_nvme_kv_retrieve(work->ns, work->qpair,
                                 work->key, work->key_len,
                                 work->buf, work->buf_len,
                                 kv_retrieve_cb_async, work, /*options=*/0);
}

void nixlSpdkKvEngine::maybe_report_backpressure(size_t idx, size_t depth) {
    if (!enomem_report_interval_ns_) return;

    uint64_t total    = enomem_retries_.load(std::memory_order_relaxed);
    uint64_t reported = enomem_reported_.load(std::memory_order_relaxed);
    if (total == reported) return;   // nothing new — the common case, kept cheap

    uint64_t last = enomem_report_at_ns_.load(std::memory_order_relaxed);
    uint64_t now  = kv_now_ns();
    if (now - last < enomem_report_interval_ns_) return;

    // Claim this reporting slot. If another reactor got there first its CAS
    // wins and this one stays quiet, so the interval holds across all reactors
    // rather than being multiplied by the reactor count.
    if (!enomem_report_at_ns_.compare_exchange_strong(last, now,
                                                      std::memory_order_relaxed)) {
        return;
    }
    enomem_reported_.store(total, std::memory_order_relaxed);

    printf("[SPDK_NVMe_KV] submission backpressure ongoing: %llu op(s) deferred "
           "on -ENOMEM in total (+%llu since last report); %zu currently queued "
           "on reactor %zu. Retries are draining — this is backpressure, not "
           "failure.\n",
           static_cast<unsigned long long>(total),
           static_cast<unsigned long long>(total - reported),
           depth, idx);
    fflush(stdout);
}

// Re-submit deferred items. Called from reactor_loop() AFTER completions have
// been processed — see the header comment on why that ordering is the whole
// mechanism and not an incidental detail.
void nixlSpdkKvEngine::drain_retry_queue(size_t idx) {
    auto &q = retry_qs_[idx];

    // Report before draining, so `depth` reflects the backlog that actually
    // built up rather than whatever survives this pass. Called unconditionally
    // (not only when q is non-empty) so the final delta after backpressure ends
    // still gets reported within one interval instead of waiting for teardown.
    maybe_report_backpressure(idx, q.size());
    while (!q.empty()) {
        SpdkKvWorkEx *work = q.front();

        int rc = submit_kv_io(work);
        if (kv_rc_is_retryable(rc)) {
            // Still full. Stop here rather than walking the rest of the queue:
            // every later item would fail identically, and spinning through
            // them just burns the reactor without letting completions land.
            // Order is preserved as a side benefit.
            if (enomem_timeout_ns_ &&
                kv_now_ns() - work->enomem_since_ns > enomem_timeout_ns_) {
                SPDK_PLUGIN_ERR << "submission queue has not drained in "
                                << (enomem_timeout_ns_ / 1000000000ULL)
                                << "s — failing deferred op. The device or "
                                   "target has stopped completing I/O; this is "
                                   "not the transient queue-full condition.";
                q.pop_front();
                kv_complete_cb(work, false);
                continue;  // give the rest of the queue the same deadline test
            }
            return;
        }

        q.pop_front();
        if (rc != 0) kv_complete_cb(work, false);  // genuine, permanent error
    }
}

void nixlSpdkKvEngine::flush_retry_queue_failed(size_t idx) {
    auto &q = retry_qs_[idx];
    while (!q.empty()) {
        SpdkKvWorkEx *work = q.front();
        q.pop_front();
        // Fail rather than delete: kv_complete_cb decrements req->pending, so a
        // caller blocked in waitXfer/checkXfer gets an error instead of hanging.
        kv_complete_cb(work, false);
    }
}

void nixlSpdkKvEngine::do_kv_io_async(void *arg) {
    auto *work = static_cast<SpdkKvWorkEx *>(arg);
    auto *eng  = work->engine;

    if (eng->inprocess_mode_) {
        // In-process: direct hugepage memcpy, no SPDK/TCP involved.
        uint64_t slot     = eng->slot_for_key(work->key);
        uint8_t *kv_slot  = eng->kvbuf_ + slot * eng->slot_size_;
        size_t   copy_len = std::min(static_cast<size_t>(work->buf_len),
                                     eng->slot_size_);
        if (work->op == NIXL_WRITE)
            std::memcpy(kv_slot, work->buf, copy_len);
        else
            std::memcpy(work->buf, kv_slot, copy_len);
        kv_complete_cb(work, true);
        return;
    }

    // TCP or PCIe: use SPDK NVMe-KV command set.
    int rc = submit_kv_io(work);
    if (rc == 0) return;
    // On success the SPDK reactor's completion drain picks it up on the next poll.

    // -ENOMEM / -EAGAIN mean "submission queue momentarily full", NOT failure.
    // SPDK expects the caller to poll for completions and re-submit. Treating
    // it as a permanent error — which this code did until 2026-08-25 — makes
    // any batch larger than the queue depth fail, and the serving path cannot
    // avoid that: LMCache's chunk geometry (256 tokens at 4096 B/page) submits
    // 704 descriptors PER CHUNK, so a 5-chunk store issues 3,520 at once
    // against a documented safe depth of 32. Measured consequence, before this
    // fix: 770 of 3,520 ops completed, then the whole transfer returned
    // NIXL_ERR_BACKEND. See
    // results/<SETUP3_DECODE_NODE>/2026-08-25-rocm-aic-l2-store/.
    //
    // Defer to this reactor's retry queue instead. Do NOT re-post via
    // spdk_thread_send_msg(): that would re-enter the message ring, which
    // spdk_thread_poll() may drain in the same iteration, starving the
    // completion processing that is the only thing able to free a slot.
    if (kv_rc_is_retryable(rc)) {
        if (work->enomem_since_ns == 0) work->enomem_since_ns = kv_now_ns();
        eng->enomem_retries_.fetch_add(1, std::memory_order_relaxed);
        // One-shot notice: a silent retry path is an unverifiable one.
        if (!eng->enomem_logged_.exchange(true, std::memory_order_relaxed)) {
            printf("[SPDK_NVMe_KV] submission queue full (-ENOMEM); deferring "
                   "and retrying after completions drain. This is normal "
                   "backpressure under a deep batch, not an error.\n");
        }
        eng->retry_qs_[work->reactor_idx].push_back(work);
        return;
    }

    kv_complete_cb(work, false);  // genuine, permanent error
}

// ---- SPDK probe callbacks --------------------------------------------------

static bool probe_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
                     struct spdk_nvme_ctrlr_opts *opts) {
    auto *ctx = static_cast<ProbeCtx *>(cb_ctx);
    // Request enough I/O queue resource up front for all planned qpairs —
    // without this the controller may only provision its default queue
    // count, silently capping how many spdk_nvme_ctrlr_alloc_io_qpair()
    // calls can succeed later (see kv_bench_spdk's probe_cb, which requests
    // spdk_env_get_core_count() queues for the same reason).
    if (ctx && ctx->num_io_queues > 0) opts->num_io_queues = ctx->num_io_queues;
    printf("[SPDK_NVMe_KV] probing %s\n", trid->traddr);
    return true;
}

static void attach_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
                      struct spdk_nvme_ctrlr *ctrlr,
                      const struct spdk_nvme_ctrlr_opts *opts) {
    (void)trid; (void)opts;
    auto *ctx = static_cast<ProbeCtx *>(cb_ctx);
    if (ctx->found) return;

    int num_ns = spdk_nvme_ctrlr_get_num_ns(ctrlr);
    for (int nsid = 1; nsid <= num_ns; ++nsid) {
        struct spdk_nvme_ns *ns = spdk_nvme_ctrlr_get_ns(ctrlr, nsid);
        if (!ns || !spdk_nvme_ns_is_active(ns)) continue;
        if (spdk_nvme_ns_get_csi(ns) != SPDK_NVME_CSI_KV) continue;

        struct spdk_nvme_qpair *qpair =
            spdk_nvme_ctrlr_alloc_io_qpair(ctrlr, NULL, 0);
        if (!qpair) {
            fprintf(stderr, "[SPDK_NVMe_KV] alloc_io_qpair failed\n");
            return;
        }
        ctx->ctrlr = ctrlr;
        ctx->kv_ns = ns;
        ctx->qpair = qpair;
        ctx->found = true;
        printf("[SPDK_NVMe_KV] attached KV namespace nsid=%d\n", nsid);
        return;
    }
}

// ---- SPDK reactor threads ---------------------------------------------------
// One reactor thread per qpair (see NIXL_KV_NUM_QPAIRS). Each thread owns and
// exclusively polls qpairs_[idx] via its own spdk_thread — no cross-thread
// access to a qpair ever happens, so no locking is needed around them. Only
// reactor 0 polls the shared controller's admin queue (SPDK expects admin
// completions to be polled by a single consistent caller).

void *nixlSpdkKvEngine::reactor_entry(void *arg) {
    auto *ra = static_cast<ReactorArgs *>(arg);
    ra->engine->reactor_loop(ra->idx);
    delete ra;
    return nullptr;
}

void nixlSpdkKvEngine::reactor_loop(size_t idx) {
    char name[32];
    std::snprintf(name, sizeof(name), "nixl_spdk_kv_%zu", idx);
    struct spdk_thread *thr = spdk_thread_create(name, nullptr);
    if (!thr) {
        fprintf(stderr, "[SPDK_NVMe_KV] spdk_thread_create failed for reactor %zu\n", idx);
        return;
    }
    spdk_set_thread(thr);
    spdk_thrs_[idx] = thr;

    // Pin this reactor to a core local to the NVMe device (reactor_cpus_,
    // populated from /sys/.../local_cpulist before these threads were
    // spawned — see local_cpus_for_trid()) so device completions are polled
    // with low, consistent scheduling latency, on the right NUMA node,
    // instead of competing with everything else on the box (mirrors
    // kv_bench_spdk's DPDK-lcore-pinned workers).
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    int core = reactor_cpus_.empty() ? 0 : reactor_cpus_[idx % reactor_cpus_.size()];
    CPU_SET(core, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    {
        std::lock_guard<std::mutex> lk(ready_mtx_);
        reactors_ready_.fetch_add(1, std::memory_order_acq_rel);
    }
    ready_cv_.notify_all();

    // qpairs_[idx] isn't populated until the constructor's probe/alloc step
    // completes on the main thread (which happens after these reactors are
    // spawned) — re-read it each iteration rather than caching it once.
    while (!reactor_stop_.load(std::memory_order_relaxed)) {
        spdk_thread_poll(thr, 0, 0);
        if (idx == 0 && ctrlr_) spdk_nvme_ctrlr_process_admin_completions(ctrlr_);
        struct spdk_nvme_qpair *qpair = qpairs_[idx];
        if (qpair) spdk_nvme_qpair_process_completions(qpair, 0);
        // AFTER completions, never before: processing completions is what frees
        // the submission-queue slots a deferred op is waiting for. Draining
        // first would retry into a queue that is still full and accomplish
        // nothing. See do_kv_io_async()'s -ENOMEM branch.
        drain_retry_queue(idx);
    }

    // Anything still deferred at shutdown must be failed, not dropped: these
    // items each hold a decrement of req->pending, so silently deleting them
    // would leave a caller in checkXfer()/waitXfer() forever.
    flush_retry_queue_failed(idx);

    spdk_thread_exit(thr);
    while (!spdk_thread_is_exited(thr))
        spdk_thread_poll(thr, 0, 0);
    spdk_thread_destroy(thr);
    spdk_thrs_[idx] = nullptr;
}

// ---- Constructor / Destructor ----------------------------------------------

nixlSpdkKvEngine::nixlSpdkKvEngine(const nixlBackendInitParams *init_params)
    : nixlBackendEngine(init_params) {

    // Check for in-process mode first — no SPDK NVMe needed.
    const char *inprocess_env = std::getenv("NIXL_KV_INPROCESS");
    inprocess_mode_ = (inprocess_env && std::string(inprocess_env) == "1");

    if (inprocess_mode_) {
        // ── In-process mode: allocate hugepage-backed KV buffer ──────────
        // NIXL_KV_BUF_GB  — total buffer size in GB   (default 8)
        // NIXL_KV_SLOT_MB — slot size (max value) in MB (default 64)
        const char *buf_env  = std::getenv("NIXL_KV_BUF_GB");
        const char *slot_env = std::getenv("NIXL_KV_SLOT_MB");
        size_t buf_gb   = buf_env  ? static_cast<size_t>(std::atoi(buf_env))  : 8;
        size_t slot_mb  = slot_env ? static_cast<size_t>(std::atoi(slot_env)) : 64;

        slot_size_  = slot_mb  * 1024 * 1024;
        size_t buf_bytes = buf_gb * 1024 * 1024 * 1024;
        num_slots_  = buf_bytes / slot_size_;

        printf("[SPDK_NVMe_KV] in-process mode: %zu GB / %zu MB slots = %zu slots\n",
               buf_gb, slot_mb, num_slots_);

        // In-process mode: NO SPDK/DPDK dependency at all.
        // Allocate KV buffer with mmap (anonymous, backed by regular pages or
        // transparent huge pages — no explicit hugepage setup required).
        void *mapped = mmap(nullptr, buf_bytes,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE,
                            -1, 0);
        if (mapped == MAP_FAILED) {
            mapped = mmap(nullptr, buf_bytes,
                          PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS,
                          -1, 0);
        }
        if (mapped == MAP_FAILED) {
            fprintf(stderr, "[SPDK_NVMe_KV] mmap failed for %zu GB KV buffer: %s\n",
                    buf_gb, strerror(errno));
            initErr = true;
            return;
        }
        kvbuf_ = static_cast<uint8_t *>(mapped);
        // Request transparent huge pages (kernel best-effort, silently ignored if unavailable).
#ifdef MADV_HUGEPAGE
        madvise(kvbuf_, buf_bytes, MADV_HUGEPAGE);
#endif
        // Pre-fault all pages so first-access latency doesn't pollute benchmark numbers.
        for (size_t s = 0; s < num_slots_; ++s)
            kvbuf_[s * slot_size_] = 0;

        // In-process mode bypasses SPDK entirely — no reactor threads needed.
        // postXfer does memcpy directly on the caller's thread.
        // (qpairs_ stays empty; postXfer checks inprocess_mode_ before any SPDK call)

        printf("[SPDK_NVMe_KV] in-process KV buffer ready (%zu GB @ %p)\n",
               buf_gb, static_cast<void *>(kvbuf_));
        initErr = false;
        return;
    }

    // ── TCP or PCIe mode ─────────────────────────────────────────────────────
    // Priority: NIXL_KV_TRID env var > plugin initParam "trid" > hardcoded default.
    // getParams() returns a default "trid" initParam so getInitParam always succeeds —
    // env var is checked FIRST to allow runtime TRID override.
    {
        const char *trid_env = std::getenv("NIXL_KV_TRID");
        std::string trid_param;
        if (trid_env && trid_env[0] != '\0') {
            trid_str_ = trid_env;
            fprintf(stderr, "[SPDK_NVMe_KV] TRID from env: %s\n", trid_str_.c_str());
        } else if (getInitParam("trid", trid_param) == NIXL_SUCCESS) {
            trid_str_ = trid_param;
        } else {
            trid_str_ = "trtype:TCP adrfam:IPv4 traddr:127.0.0.1 trsvcid:4420 "
                        "subnqn:nqn.2024-01.io.nixl:kv0";
        }
    }

    // Per-deployment key-space offset — see getParams()'s "kv_slot_offset"
    // doc comment. Same env-var-first, then initParam, priority as trid_.
    {
        const char *offset_env = std::getenv("NIXL_KV_SLOT_OFFSET");
        std::string offset_param;
        if (offset_env && offset_env[0] != '\0') {
            slot_offset_ = std::strtoull(offset_env, nullptr, 10);
            fprintf(stderr, "[SPDK_NVMe_KV] slot offset from env: %lu\n",
                    static_cast<unsigned long>(slot_offset_));
        } else if (getInitParam("kv_slot_offset", offset_param) == NIXL_SUCCESS) {
            slot_offset_ = std::strtoull(offset_param.c_str(), nullptr, 10);
        }
    }

    // queryMem()'s bounded wait — see query_timeout_ns_ in the header.
    {
        const char *qt_env = std::getenv("NIXL_KV_QUERY_TIMEOUT_MS");
        if (qt_env && qt_env[0] != '\0') {
            const unsigned long long ms = std::strtoull(qt_env, nullptr, 10);
            if (ms > 0) query_timeout_ns_ = ms * 1000000ULL;
        }
    }

    // Number of independent qpairs (and reactor threads) to run — one per
    // nixlbench --num_threads is the intended usage. Default 1 preserves the
    // original single-qpair behavior.
    {
        const char *nq_env = std::getenv("NIXL_KV_NUM_QPAIRS");
        int nq = nq_env ? std::atoi(nq_env) : 1;
        num_qpairs_ = (nq > 0) ? static_cast<size_t>(nq) : 1;
    }
    qpairs_.assign(num_qpairs_, nullptr);
    // One deferred-submission queue per reactor. Sized here, before any reactor
    // thread is spawned, so a reactor never sees a short vector.
    retry_qs_.resize(num_qpairs_);

    // Deadline for a single deferred op. Generous by default: under a deep
    // batch an op can legitimately wait many drain cycles (a 3,520-descriptor
    // store against a 32-deep queue needs ~110 of them), so this must bound
    // "the device died", not "the queue is busy". 0 disables the deadline
    // entirely, at the cost of turning a dead device into a hung transfer.
    {
        const char *t_env = std::getenv("NIXL_KV_ENOMEM_TIMEOUT_SEC");
        long t = t_env ? std::atol(t_env) : 30;
        if (t < 0) t = 0;
        enomem_timeout_ns_ = static_cast<uint64_t>(t) * 1000000000ULL;
    }

    // Throttle for the ongoing backpressure report. See the header: the
    // teardown total alone is useless for a container that runs for days.
    {
        const char *r_env = std::getenv("NIXL_KV_BACKPRESSURE_LOG_SEC");
        long r = r_env ? std::atol(r_env) : 60;
        if (r < 0) r = 0;
        enomem_report_interval_ns_ = static_cast<uint64_t>(r) * 1000000000ULL;
    }
    // Start the clock at construction so the first periodic report waits a full
    // interval rather than firing immediately on top of the one-shot notice.
    enomem_report_at_ns_.store(kv_now_ns(), std::memory_order_relaxed);

    // Determine which cores are local to this device's NUMA node BEFORE
    // reactor threads are spawned (start_spdk_reactor(), below) — see
    // local_cpus_for_trid()'s doc comment for why this matters.
    reactor_cpus_ = local_cpus_for_trid(trid_str_);

    struct spdk_env_opts opts = {};
    opts.opts_size = sizeof(opts);
    spdk_env_opts_init(&opts);
    opts.name     = "nixl_spdk_kv";
    opts.shm_id   = -1;
    opts.mem_size = -1;
    // For PCIe NVMe-KV: set no_pci=false so SPDK scans PCIe bus.
    // For TCP NVMe-oF: no_pci=true (skip PCIe scan, faster init).
    opts.no_pci   = (trid_str_.find("trtype:PCIe") == std::string::npos);

    if (spdk_env_init(&opts) < 0) {
        fprintf(stderr, "[SPDK_NVMe_KV] spdk_env_init failed\n");
        initErr = true;
        return;
    }
    if (spdk_thread_lib_init(nullptr, 0) != 0) {
        fprintf(stderr, "[SPDK_NVMe_KV] spdk_thread_lib_init failed\n");
        initErr = true;
        return;
    }
    if (start_spdk_reactor() != NIXL_SUCCESS) { initErr = true; return; }

    struct spdk_nvme_transport_id trid = {};
    if (spdk_nvme_transport_id_parse(&trid, trid_str_.c_str()) != 0) {
        fprintf(stderr, "[SPDK_NVMe_KV] bad transport ID: %s\n", trid_str_.c_str());
        initErr = true;
        return;
    }

    ProbeCtx probe_ctx = {};
    probe_ctx.num_io_queues = static_cast<uint32_t>(num_qpairs_);
    int rc = spdk_nvme_probe(&trid, &probe_ctx, probe_cb, attach_cb, nullptr);
    if (rc != 0 || !probe_ctx.found) {
        fprintf(stderr, "[SPDK_NVMe_KV] no KV namespace found at %s\n",
                trid_str_.c_str());
    } else {
        ctrlr_ = probe_ctx.ctrlr;
        kv_ns_ = probe_ctx.kv_ns;
        qpairs_[0] = probe_ctx.qpair;
        // Allocation is thread-agnostic in SPDK — only the later submit/poll
        // usage must stay confined to one thread per qpair, which the
        // reactor-per-qpair design guarantees.
        for (size_t i = 1; i < num_qpairs_; ++i) {
            struct spdk_nvme_qpair *qp = spdk_nvme_ctrlr_alloc_io_qpair(ctrlr_, NULL, 0);
            if (!qp) {
                fprintf(stderr, "[SPDK_NVMe_KV] alloc_io_qpair failed for qpair %zu/%zu\n",
                        i, num_qpairs_);
                break;
            }
            qpairs_[i] = qp;
        }
        printf("[SPDK_NVMe_KV] %zu qpair(s) ready\n", num_qpairs_);
        // Controller and namespace are live — ask what they actually support.
        // Best-effort and non-fatal; failure leaves the compiled-in default.
        query_max_value_size();
    }

    initErr = false;
}

void nixlSpdkKvEngine::query_max_value_size() {
    if (!kv_ns_ || !ctrlr_) return;   // in-process mode has neither

    const struct spdk_nvme_kv_ns_data *kvns = spdk_nvme_kv_ns_get_data(kv_ns_);
    if (!kvns) {
        fprintf(stderr, "[SPDK_NVMe_KV] max_value_size query: namespace is not KV type; "
                        "keeping compiled-in default %u\n", SPDK_KV_DEFAULT_MAX_VALUE_SIZE);
        return;
    }

    // kvfc.kvfi selects which of the up-to-16 KV format descriptors is active.
    // nkvf is 0's based, so nkvf==0 means exactly one format.
    uint8_t idx = kvns->kvfc.kvfi;
    if (idx > kvns->nkvf) idx = 0;
    const uint32_t vml = kvns->kvf[idx].kvvml;
    const uint16_t kml = kvns->kvf[idx].kvkml;

    // The binding constraint here is usually the TRANSPORT, not the device:
    // bdev_kvmalloc permits 64 MiB values but NVMe-oF/TCP caps a single I/O
    // far below that. Take the minimum so neither side can be exceeded.
    const uint32_t max_xfer = spdk_nvme_ctrlr_get_max_xfer_size(ctrlr_);

    uint32_t eff = vml;
    if (eff == 0 || (max_xfer != 0 && max_xfer < eff)) eff = max_xfer;

    fprintf(stderr,
            "[SPDK_NVMe_KV] device KV format %u: value_max=%u key_max=%u, "
            "ctrlr max_xfer=%u -> effective=%u (compiled-in default %u)\n",
            idx, vml, kml, max_xfer, eff, SPDK_KV_DEFAULT_MAX_VALUE_SIZE);

    if (kml != 0 && kml < 12) {
        fprintf(stderr, "[SPDK_NVMe_KV] WARNING: device max key length %u is below the "
                        "12 bytes make_key() emits — stores will be rejected\n", kml);
    }
    if (eff == 0) {
        fprintf(stderr, "[SPDK_NVMe_KV] neither device nor controller indicated a limit; "
                        "keeping compiled-in default %u\n", SPDK_KV_DEFAULT_MAX_VALUE_SIZE);
        return;
    }

    discovered_max_value_size_.store(eff, std::memory_order_relaxed);
    if (eff < SPDK_KV_DEFAULT_MAX_VALUE_SIZE) {
        // The compiled-in default exceeds what this path can carry; writes at
        // the default size would be rejected by the target. Loud, because the
        // fallback is not the safe choice here.
        fprintf(stderr, "[SPDK_NVMe_KV] WARNING: effective limit %u is SMALLER than the "
                        "compiled-in default %u — set NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE=1 "
                        "or stores will fail\n", eff, SPDK_KV_DEFAULT_MAX_VALUE_SIZE);
    }
}

nixlSpdkKvEngine::~nixlSpdkKvEngine() {
    stop_spdk_reactor();
    for (auto *qp : qpairs_) {
        if (qp) spdk_nvme_ctrlr_free_io_qpair(qp);
    }
    if (ctrlr_) spdk_nvme_detach(ctrlr_);
    if (kvbuf_ && inprocess_mode_) {
        munmap(kvbuf_, num_slots_ * slot_size_);
    }
}

nixl_status_t nixlSpdkKvEngine::start_spdk_reactor() {
    thread_ids_.assign(num_qpairs_, pthread_t{});
    spdk_thrs_.assign(num_qpairs_, nullptr);

    for (size_t i = 0; i < num_qpairs_; ++i) {
        auto *ra = new ReactorArgs{this, i};
        if (pthread_create(&thread_ids_[i], nullptr, reactor_entry, ra) != 0) {
            delete ra;
            reactor_stop_.store(true, std::memory_order_relaxed);
            for (size_t j = 0; j < i; ++j) pthread_join(thread_ids_[j], nullptr);
            return NIXL_ERR_BACKEND;
        }
    }

    std::unique_lock<std::mutex> lk(ready_mtx_);
    ready_cv_.wait(lk, [this]{
        return reactors_ready_.load(std::memory_order_acquire) == num_qpairs_;
    });
    return NIXL_SUCCESS;
}

void nixlSpdkKvEngine::stop_spdk_reactor() {
    reactor_stop_.store(true, std::memory_order_relaxed);
    for (auto tid : thread_ids_) {
        if (tid) pthread_join(tid, nullptr);
    }
    thread_ids_.clear();

    // FINAL total. This is the last of the three report points (first-signal,
    // periodic, final — see the header); it is a closing summary, NOT the only
    // visibility, which is what it used to be and why a days-long serving run
    // never printed it. Nonzero here is normal and healthy under deep batches —
    // it is the mechanism working, not a warning.
    uint64_t retries = enomem_retries_.load(std::memory_order_relaxed);
    if (retries) {
        printf("[SPDK_NVMe_KV] submission backpressure, final total: %llu op(s) "
               "deferred on -ENOMEM and retried after completions drained\n",
               static_cast<unsigned long long>(retries));
        fflush(stdout);
    }
}

// ---- registerMem / deregisterMem ------------------------------------------

nixl_status_t nixlSpdkKvEngine::registerMem(const nixlBlobDesc &mem,
                                             const nixl_mem_t   &nixl_mem,
                                             nixlBackendMD      *&out) {
    auto *md = new nixlSpdkKvMD();
    md->type   = nixl_mem;
    md->size   = mem.len;
    md->dev_id = mem.devId;
    // Caller-supplied KV identity, when there is one (LMCache's OBJ-mode
    // object name — instance-unique, not content-derived; see the header).
    // Captured for every seg type (harmless for DRAM/VRAM, which are never the
    // storage side of a transfer); make_key() only consults it when non-empty.
    md->meta_info = mem.metaInfo;

    switch (nixl_mem) {
    case DRAM_SEG:
        md->ptr = reinterpret_cast<void *>(mem.addr);
        if (!inprocess_mode_) {
            // Pin for zero-copy DMA to NVMe-KV controller.
            if (spdk_mem_register(md->ptr, mem.len) != 0)
                fprintf(stderr, "[SPDK_NVMe_KV] spdk_mem_register warning — "
                        "DMA fallback path active\n");
        }
        break;

    case VRAM_SEG: {
#ifdef NIXL_KV_NO_VRAM
        fprintf(stderr, "[SPDK_NVMe_KV] VRAM_SEG requested but this plugin was built "
                "without VRAM support (no ROCm on this host)\n");
        delete md; return NIXL_ERR_NOT_SUPPORTED;
#else
        // Staged, not zero-copy — see header comment. Just validate it's a
        // real HIP device allocation; the actual copy happens per-descriptor
        // in postXfer() via the batch's staging buffer (or directly against
        // kvbuf_ in in-process mode). No spdk_mem_register — this pointer is
        // never handed to SPDK directly.
        hipPointerAttribute_t attr{};
        hipError_t e = hipPointerGetAttributes(&attr, reinterpret_cast<void *>(mem.addr));
        if (e != hipSuccess) {
            fprintf(stderr, "[SPDK_NVMe_KV] VRAM_SEG pointer validation failed: %s\n",
                    hipGetErrorString(e));
            delete md; return NIXL_ERR_INVALID_PARAM;
        }
        md->ptr = reinterpret_cast<void *>(mem.addr);
        break;
#endif
    }

    case FILE_SEG:
    case OBJ_SEG:
        // OBJ_SEG is LMCache's key-addressed storage pool (NixlObjectPool).
        // Both seg types are handled identically here; make_key() picks the
        // derivation per descriptor — metaInfo when the caller set one
        // (LMCache OBJ mode), devId+addr otherwise (kv_io.py, nixlbench).
        //
        // This previously keyed off devId+addr unconditionally, on the
        // reasoning that LMCache's own bookkeeping decides which slot holds
        // which content-key and reuses that slot for STORE and RETRIEVE. That
        // holds within one process and fails across two: pool slots are
        // allocated from 0 independently per NixlObjPool, so separate
        // deployments sharing a namespace collided on their early slots
        // (rocm-aic README §3). Mirrors xnvme_kv_backend.cpp's handling.
        if (!inprocess_mode_ && !kv_ns_) {
            fprintf(stderr, "[SPDK_NVMe_KV] FILE_SEG/OBJ_SEG registerMem: no KV namespace\n");
            delete md; return NIXL_ERR_BACKEND;
        }
        if (!inprocess_mode_) {
            if (spdk_nvme_kv_ns_get_data(kv_ns_) == nullptr) {
                fprintf(stderr, "[SPDK_NVMe_KV] namespace is not KV type\n");
                delete md; return NIXL_ERR_BACKEND;
            }
        }
        // In-process mode: FILE_SEG/OBJ_SEG represents a slot in kvbuf_ — always OK.
        break;

    default:
        fprintf(stderr, "[SPDK_NVMe_KV] unsupported seg type %d\n", nixl_mem);
        delete md; return NIXL_ERR_INVALID_PARAM;
    }

    out = md;
    return NIXL_SUCCESS;
}

nixl_status_t nixlSpdkKvEngine::deregisterMem(nixlBackendMD *meta) {
    auto *md = static_cast<nixlSpdkKvMD *>(meta);
    if (!inprocess_mode_ && md->type == DRAM_SEG && md->ptr)
        spdk_mem_unregister(md->ptr, md->size);
    delete md;
    return NIXL_SUCCESS;
}

// ---- prepXfer --------------------------------------------------------------

nixl_status_t nixlSpdkKvEngine::prepXfer(
        const nixl_xfer_op_t   &operation,
        const nixl_meta_dlist_t &local,
        const nixl_meta_dlist_t &remote,
        const std::string       &,
        nixlBackendReqH         *&handle,
        const nixl_opt_b_args_t *) const {

    if (local.descCount() != remote.descCount() || local.descCount() == 0)
        return NIXL_ERR_INVALID_PARAM;
    nixl_mem_t local_type = local.getType();
    nixl_mem_t remote_type = remote.getType();
    if ((local_type != DRAM_SEG && local_type != VRAM_SEG) ||
        (remote_type != FILE_SEG && remote_type != OBJ_SEG))
        return NIXL_ERR_INVALID_PARAM;

    auto *req = new nixlSpdkKvReqH();

    // VRAM_SEG (non-in-process only — in-process copies straight against
    // kvbuf_ in postXfer, no staging needed): allocate one hugepage-backed,
    // HIP-pinned staging buffer sized to the whole batch.
#ifndef NIXL_KV_NO_VRAM
    if (!inprocess_mode_ && local_type == VRAM_SEG) {
        size_t total = 0;
        for (int i = 0; i < local.descCount(); ++i) total += local[i].len;

        void *buf = spdk_zmalloc(total, 4096, nullptr, SPDK_ENV_NUMA_ID_ANY, SPDK_MALLOC_DMA);
        if (!buf) {
            SPDK_PLUGIN_ERR << "spdk_zmalloc(" << total << ") failed for VRAM staging buffer";
            delete req;
            return NIXL_ERR_BACKEND;
        }
        hipError_t e = hipHostRegister(buf, total, hipHostRegisterDefault);
        if (e != hipSuccess) {
            SPDK_PLUGIN_ERR << "hipHostRegister(" << total << ") failed: " << hipGetErrorString(e);
            spdk_free(buf);
            delete req;
            return NIXL_ERR_BACKEND;
        }
        req->staging_    = buf;
        req->staging_sz_ = total;
    }
#endif

    handle = req;
    return NIXL_SUCCESS;
}

// ---- postXfer — async, non-blocking ----------------------------------------

nixl_status_t nixlSpdkKvEngine::postXfer(
        const nixl_xfer_op_t   &operation,
        const nixl_meta_dlist_t &local,
        const nixl_meta_dlist_t &remote,
        const std::string       &,
        nixlBackendReqH         *&handle,
        const nixl_opt_b_args_t *) const {

    if (!inprocess_mode_ && (!kv_ns_ || qpairs_.empty() || !qpairs_[0])) return NIXL_ERR_BACKEND;

    auto *req = static_cast<nixlSpdkKvReqH *>(handle);
    int n = local.descCount();
    req->error.store(false, std::memory_order_relaxed);

    bool vram = (local.getType() == VRAM_SEG);

    // Fallback for storage descriptors whose registered MD is absent — not
    // every xfer-descriptor-building path is confirmed to populate metadataP.
    // Held as a named object rather than materialised per-descriptor by a
    // ternary, which would copy the meta_info string on every key derivation.
    static const std::string kEmptyMeta;

    if (inprocess_mode_) {
        // ── In-process: execute all copy ops directly on caller thread ──
        // No SPDK, no reactor, no hugepages. All ops complete before return.
        // VRAM_SEG: hipMemcpy straight against kvbuf_ — no staging buffer
        // needed since kvbuf_ is already ordinary host memory.
        for (int i = 0; i < n; ++i) {
            const auto &mem_desc  = local[i];
            const auto &file_desc = remote[i];

            uint8_t key[SPDK_NVME_KV_KEY_MAX_LEN] = {};
            uint8_t key_len = 0;
            auto *file_md = static_cast<nixlSpdkKvMD *>(file_desc.metadataP);
            make_key(file_desc.devId + slot_offset_, file_desc.addr,
                     file_md ? file_md->meta_info : kEmptyMeta, key, &key_len);

            uint64_t slot    = slot_for_key(key);
            uint8_t *kv_slot = kvbuf_ + slot * slot_size_;
            size_t   len     = std::min(static_cast<size_t>(mem_desc.len), slot_size_);
            void    *mem_ptr = reinterpret_cast<void *>(mem_desc.addr);

#ifndef NIXL_KV_NO_VRAM
            if (vram) {
                hipError_t e = (operation == NIXL_WRITE)
                    ? hipMemcpy(kv_slot, mem_ptr, len, hipMemcpyDeviceToHost)
                    : hipMemcpy(mem_ptr, kv_slot, len, hipMemcpyHostToDevice);
                if (e != hipSuccess) {
                    SPDK_PLUGIN_ERR << "in-process VRAM hipMemcpy failed: " << hipGetErrorString(e);
                    req->error.store(true, std::memory_order_relaxed);
                }
            } else
#endif
            if (operation == NIXL_WRITE) {
                std::memcpy(kv_slot, mem_ptr, len);
            } else {
                std::memcpy(mem_ptr, kv_slot, len);
            }
        }
        req->pending.store(0, std::memory_order_release);
        return NIXL_SUCCESS;  // Already done — caller can skip checkXfer.
    }

    // ── NVMe-oF TCP / PCIe: async dispatch to SPDK reactor(s) ────────────
    if (!kv_ns_ || qpairs_.empty() || !qpairs_[0]) return NIXL_ERR_BACKEND;

    char  *staging_ptr = vram ? static_cast<char *>(req->staging_) : nullptr;
    size_t staging_off = 0;

    // Set pending BEFORE submitting any work (avoids race where a fast
    // completion decrements to 0 before all work items are posted).
    req->pending.store(n, std::memory_order_release);

    for (int i = 0; i < n; ++i) {
        const auto &mem_desc  = local[i];
        const auto &file_desc = remote[i];

        // Round-robin each descriptor across all qpairs — spreads work from a
        // single caller's batch across every reactor, not just cross-thread
        // traffic when nixlbench runs with --num_threads > 1.
        uint32_t idx = next_qpair_.fetch_add(1, std::memory_order_relaxed) %
                       static_cast<uint32_t>(num_qpairs_);
        // Fall back to qpair 0 (guaranteed non-null here) if a higher-index
        // qpair failed to allocate at construction time. eff_idx must follow
        // that fallback: it selects the retry queue the deferred-submission
        // path will use, and a qpair may only ever be touched by the one
        // reactor thread that polls it.
        uint32_t eff_idx = qpairs_[idx] ? idx : 0;
        struct spdk_nvme_qpair *qpair = qpairs_[eff_idx];
        struct spdk_thread     *thr   = spdk_thrs_[eff_idx];

        auto *work = new SpdkKvWorkEx{};
        work->engine  = const_cast<nixlSpdkKvEngine *>(this);
        work->ns      = kv_ns_;
        work->qpair   = qpair;
        work->reactor_idx = eff_idx;
        work->buf_len = static_cast<uint32_t>(mem_desc.len);
        work->op      = operation;
        work->req     = req;
        auto *file_md = static_cast<nixlSpdkKvMD *>(file_desc.metadataP);
        make_key(file_desc.devId + slot_offset_, file_desc.addr,
                 file_md ? file_md->meta_info : kEmptyMeta,
                 work->key, &work->key_len);

        if (vram) {
            // VRAM_SEG: SPDK only ever touches the staging slice. WRITE
            // copies VRAM->staging synchronously here (must land before the
            // store is submitted); READ leaves vram_dst set so the
            // completion callback copies staging->VRAM once the retrieve
            // finishes.
            void *slice = staging_ptr + staging_off;
            staging_off += mem_desc.len;

            if (operation == NIXL_WRITE) {
#ifndef NIXL_KV_NO_VRAM
                hipError_t e = hipMemcpy(slice, reinterpret_cast<void *>(mem_desc.addr),
                                         mem_desc.len, hipMemcpyDeviceToHost);
                if (e != hipSuccess) {
                    SPDK_PLUGIN_ERR << "VRAM->staging hipMemcpy failed: " << hipGetErrorString(e);
                    kv_complete_cb(work, false);
                    continue;
                }
#endif
            } else {
                work->vram_dst = reinterpret_cast<void *>(mem_desc.addr);
            }
            work->buf = slice;
        } else {
            work->buf = reinterpret_cast<void *>(mem_desc.addr);
        }

        // Dispatch to the owning reactor thread — returns immediately.
        //
        // The return value is checked because ignoring it (as this did until
        // 2026-08-25) turns a full message ring into a LEAK, not an error: the
        // work item is never delivered, so nothing ever decrements
        // req->pending, and the caller blocks in checkXfer()/waitXfer()
        // forever. Failing the descriptor converts a silent hang into a
        // reportable error, which is strictly the better failure.
        if (spdk_thread_send_msg(thr, do_kv_io_async, work) != 0) {
            SPDK_PLUGIN_ERR << "spdk_thread_send_msg failed (reactor "
                            << eff_idx << " message ring full) — failing "
                               "descriptor rather than leaking it";
            kv_complete_cb(work, false);
        }
    }

    return NIXL_IN_PROG;
}

// ---- checkXfer / releaseReqH ------------------------------------------------

nixl_status_t nixlSpdkKvEngine::checkXfer(nixlBackendReqH *handle) const {
    auto *req = static_cast<nixlSpdkKvReqH *>(handle);
    if (req->pending.load(std::memory_order_acquire) != 0)
        return NIXL_IN_PROG;
    return req->error.load() ? NIXL_ERR_BACKEND : NIXL_SUCCESS;
}

nixl_status_t nixlSpdkKvEngine::releaseReqH(nixlBackendReqH *handle) const {
    delete handle;
    return NIXL_SUCCESS;
}

// ---- queryMem (NVMe KV Exist) -----------------------------------------------
//
// See the declaration in the header for why this method has to exist at all.
//
// THREADING. queryMem() is called on the caller's thread (LMCache's lookup
// path), but a qpair may only ever be touched by the reactor thread that polls
// it — the invariant the whole async path is built on. So this does NOT submit
// directly. It hands one work item per descriptor to reactor 0 via
// spdk_thread_send_msg(), exactly like postXfer(), and waits on an atomic per
// item. Allocating a private qpair for queries instead would work, but it would
// put a second submitter on the controller for no benefit: KV Exist is a
// metadata-only command and the reactor drains it on its normal poll.

namespace {

// One in-flight KV Exist. state_ is the only cross-thread channel: written by
// the reactor/completion thread, read by the caller thread in the wait loop.
struct SpdkKvQueryEx {
    enum : int { PENDING = 0, EXISTS = 1, MISSING = 2, FAILED = 3 };

    struct spdk_nvme_ns     *ns    = nullptr;
    struct spdk_nvme_qpair  *qpair = nullptr;
    uint8_t                  key[SPDK_NVME_KV_KEY_MAX_LEN] = {};
    uint8_t                  key_len = 0;
    std::atomic<int>         state{PENDING};
};

// Completion. A missing key is NOT an error: bdev_kvmalloc's exist handler
// answers SCT_GENERIC / SC_KV_KEY_DOES_NOT_EXIST for a key it has never seen
// (patches/0002-spdk-bdev-kvmalloc.patch, kvmalloc_handle_exist), which is the
// ordinary cache-miss answer and must be reported as such rather than as a
// backend failure — otherwise a cold cache looks like a broken device.
void kv_exist_cb(void *cb_arg, const struct spdk_nvme_cpl *cpl) {
    auto *q = static_cast<SpdkKvQueryEx *>(cb_arg);
    if (!spdk_nvme_cpl_is_error(cpl)) {
        q->state.store(SpdkKvQueryEx::EXISTS, std::memory_order_release);
        return;
    }
    if (cpl->status.sct == SPDK_NVME_SCT_GENERIC &&
        cpl->status.sc  == SPDK_NVME_SC_KV_KEY_DOES_NOT_EXIST) {
        q->state.store(SpdkKvQueryEx::MISSING, std::memory_order_release);
        return;
    }
    q->state.store(SpdkKvQueryEx::FAILED, std::memory_order_release);
}

// Runs ON the reactor thread that owns q->qpair.
//
// -ENOMEM here means "submission queue momentarily full", the same benign
// backpressure the write path handles with a retry queue. Draining completions
// in-line is safe because we are already on the polling thread, and a bounded
// loop is enough: unlike a KV store batch, a lookup batch is small and the
// queue frees quickly. Bounding it matters — an unbounded spin would wedge the
// reactor and stall every in-flight transfer, not just this query.
void do_kv_exist_async(void *arg) {
    auto *q = static_cast<SpdkKvQueryEx *>(arg);
    for (int attempt = 0; attempt < 4096; ++attempt) {
        int rc = spdk_nvme_kv_exist(q->ns, q->qpair, q->key, q->key_len,
                                    kv_exist_cb, q);
        if (rc == 0) return;                    // completion cb owns it now
        if (!kv_rc_is_retryable(rc)) break;
        spdk_nvme_qpair_process_completions(q->qpair, 0);
    }
    q->state.store(SpdkKvQueryEx::FAILED, std::memory_order_release);
}

} // namespace

nixl_status_t nixlSpdkKvEngine::queryMem(const nixl_reg_dlist_t         &descs,
                                         std::vector<nixl_query_resp_t> &resp) const {
    const int n = descs.descCount();
    // Default every slot to "absent". Any path that fails below therefore
    // degrades to a miss (recompute), never to a fabricated hit.
    resp.assign(static_cast<size_t>(n), std::nullopt);
    if (n == 0) return NIXL_SUCCESS;

    // In-process mode has no device and no KV command set — kvbuf_ is a plain
    // mmap'd slot array with no notion of which slots were ever written. Answer
    // NOT_SUPPORTED rather than guessing; LMCache then keeps its own index.
    if (inprocess_mode_) return NIXL_ERR_NOT_SUPPORTED;

    if (!kv_ns_ || qpairs_.empty() || !qpairs_[0] ||
        spdk_thrs_.empty() || !spdk_thrs_[0]) {
        return NIXL_ERR_BACKEND;
    }

    std::vector<std::unique_ptr<SpdkKvQueryEx>> work;
    work.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        const nixlBlobDesc &d = descs[i];
        auto q   = std::make_unique<SpdkKvQueryEx>();
        q->ns    = kv_ns_;
        q->qpair = qpairs_[0];
        // Identical derivation to the store/retrieve path — a query that hashed
        // differently from the write would be worse than no query at all.
        make_key(d.devId + slot_offset_, d.addr, d.metaInfo,
                 q->key, &q->key_len);
        work.push_back(std::move(q));
    }

    for (auto &q : work) {
        if (spdk_thread_send_msg(spdk_thrs_[0], do_kv_exist_async, q.get()) != 0) {
            // Ring full. Fail just this descriptor; see postXfer's note on why
            // an unchecked send_msg is a hang rather than an error.
            q->state.store(SpdkKvQueryEx::FAILED, std::memory_order_release);
        }
    }

    // Bounded wait. A lookup must never be able to hang the serving path, so a
    // stuck probe times out into a miss and vLLM recomputes the chunk.
    const uint64_t deadline_ns = kv_now_ns() + query_timeout_ns_;
    size_t settled = 0;
    while (settled < work.size()) {
        settled = 0;
        for (auto &q : work) {
            if (q->state.load(std::memory_order_acquire) != SpdkKvQueryEx::PENDING)
                ++settled;
        }
        if (settled == work.size()) break;
        if (kv_now_ns() > deadline_ns) {
            fprintf(stderr,
                    "[SPDK_NVMe_KV] queryMem: %zu/%zu probes unanswered after "
                    "%llu ms — reporting them as misses\n",
                    work.size() - settled, work.size(),
                    static_cast<unsigned long long>(query_timeout_ns_ / 1000000ULL));
            break;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }

    bool any_failed = false;
    for (int i = 0; i < n; ++i) {
        const int st = work[static_cast<size_t>(i)]->state.load(std::memory_order_acquire);
        if (st == SpdkKvQueryEx::EXISTS) {
            resp[static_cast<size_t>(i)] = nixl_b_params_t{};
        } else if (st == SpdkKvQueryEx::FAILED) {
            any_failed = true;
        }
        // MISSING and PENDING(timed out) both stay std::nullopt.
    }

    // A transport failure is reported so the caller can distinguish "the device
    // says no" from "the device did not answer"; the resp vector is still valid
    // and conservative either way.
    return any_failed ? NIXL_ERR_BACKEND : NIXL_SUCCESS;
}
