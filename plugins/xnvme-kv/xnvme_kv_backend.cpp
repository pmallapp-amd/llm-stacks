// xNVMe NVMe-KV NIXL backend — implementation.
// See xnvme_kv_backend.h for the device/queue/dispatch model.
//
// Reference implementation this mirrors: /root/<USER>/kv_bench_xnvme/kv_bench.c
// on the project's primary host (<SETUP2_PD_NODE>) — a working, already-validated
// async multi-threaded xNVMe KV benchmark against the real Pensando DSC. The
// per-worker xnvme_dev/xnvme_queue ownership, xnvme_queue_get_cmd_ctx() /
// xnvme_cmd_ctx_set_cb() / xnvme_kvs_store()/retrieve() / xnvme_queue_poke()
// / xnvme_queue_put_cmd_ctx() call sequence below follows that file exactly.
//
// Buffer registration note: unlike SPDK (which requires spdk_mem_register()
// to pin caller-owned DRAM before DMA), io_uring_cmd passthrough pins pages
// per-request via the kernel's normal O_DIRECT-style path — no persistent
// registration call exists for a foreign (NIXL-owned) buffer. registerMem()
// below therefore just validates and stores the pointer. This is the one
// part of this backend that hasn't been exercised against the real DSC yet
// (kv_bench.c allocates its own buffers via xnvme_buf_alloc(); nixlbench's
// buffers come from NIXL's own DRAM allocator instead) — verify data
// integrity carefully on the first real-hardware run before trusting numbers.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "xnvme_kv_backend.h"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// Populated by query_max_value_size() at construction; read by the plugin's
// getParams(). See the declaration in the header for why this is static and
// why a stale/zero value is always the safe direction.
std::atomic<uint32_t> nixlXnvmeKvEngine::discovered_max_value_size_{0};

// ---- nixlXnvmeKvReqH --------------------------------------------------------

nixlXnvmeKvReqH::~nixlXnvmeKvReqH() {
#ifndef NIXL_XNVME_NO_VRAM
    if (staging_) {
        (void)hipHostUnregister(staging_);
        free(staging_);
    }
#endif
}

// ---- Shared completion path -------------------------------------------------

// steady clock in ns — see stall_timeout_ns_'s declaration for what it bounds.
static inline uint64_t xnvme_now_ns() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

// NIXL_XNVME_KV_DEBUG, read ONCE. This used to be a getenv() on every single
// completion — a per-descriptor libc call and lock on the hot path, in a plugin
// whose serving workload submits thousands of descriptors per store.
static inline bool xnvme_kv_debug() {
    static const bool on = (std::getenv("NIXL_XNVME_KV_DEBUG") != nullptr);
    return on;
}

// Hex-print a KV key into a caller-provided buffer. The key is what the DEVICE
// sees, so it is the only identifier worth tracing: M3 will change how it is
// derived, and this trace is how that change gets verified.
static inline void xnvme_kv_key_hex(const uint8_t *key, int key_len, char *out) {
    static const char *h = "0123456789abcdef";
    int i = 0;
    for (; i < key_len; ++i) {
        out[i * 2]     = h[(key[i] >> 4) & 0xF];
        out[i * 2 + 1] = h[key[i] & 0xF];
    }
    out[i * 2] = '\0';
}

void nixlXnvmeKvEngine::kv_complete_cb(XnvmeKvWorkEx *work, bool ok) {
    auto *req = work->req;
    if (!ok) req->error.store(true, std::memory_order_relaxed);
    if (req->pending.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        req->cv.notify_all();
    }
    delete work;
}

// ---- xnvme async completion trampoline --------------------------------------
// Bound to each cmd_ctx via xnvme_cmd_ctx_set_cb() before submission. Called
// from the owning QueueWorker's reactor thread while it polls
// xnvme_queue_poke() — never from any other thread.

void nixlXnvmeKvEngine::completion_trampoline(struct xnvme_cmd_ctx *ctx, void *cb_arg) {
    auto *work = static_cast<XnvmeKvWorkEx *>(cb_arg);
    bool ok = !xnvme_cmd_ctx_cpl_status(ctx);

    // Device latency: submit-accepted -> completion. See XnvmeKvWorkEx::
    // submit_ns for why the local-backlog wait is deliberately excluded.
    const uint64_t lat_us =
        work->submit_ns ? (xnvme_now_ns() - work->submit_ns) / 1000ULL : 0;

    if (xnvme_kv_debug()) {
        char keyhex[XNVME_KV_KEY_MAX_LEN * 2 + 1];
        xnvme_kv_key_hex(reinterpret_cast<const uint8_t *>(&work->key),
                         work->key_len, keyhex);
        unsigned char *b = static_cast<unsigned char *>(work->buf);
        // t=complete pairs with the t=submit line emitted in submit_one(). Both
        // carry op= and key=, so `grep 't=complete rc=0' | wc -l` is directly
        // comparable against the target's completed_nvme_io delta — which is
        // exactly the cross-check M0 exists to make possible.
        fprintf(stderr,
                "[XNVME_KV] op=%s key=%s len=%u t=complete ok=%d sct=%u sc=%u "
                "cdw0=%u lat_us=%llu buf[0:16]=",
                work->op == NIXL_WRITE ? "store" : "retrieve", keyhex,
                (unsigned)work->buf_len, (int)ok, (unsigned)ctx->cpl.status.sct,
                (unsigned)ctx->cpl.status.sc, ctx->cpl.cdw0,
                (unsigned long long)lat_us);
        if (b) for (int i = 0; i < 16 && i < (int)work->buf_len; ++i) fprintf(stderr, "%02x", b[i]);
        fprintf(stderr, "\n");
        fflush(stderr);
    }

    // ---- W0.2 counters. Same thread as submit_one(), so single-writer. -----
    {
        QueueWorker *q = work->qw;
        if (ok) q->m_completions_ok.fetch_add(1, std::memory_order_relaxed);
        else    q->m_completions_err.fetch_add(1, std::memory_order_relaxed);
        if (work->submit_ns) {
            q->m_lat_sum_us.fetch_add(lat_us, std::memory_order_relaxed);
            int bi = 0;
            while (bi < 7 && lat_us >= XNVME_KV_LAT_BUCKET_US[bi]) ++bi;
            q->m_lat_bucket[bi].fetch_add(1, std::memory_order_relaxed);
        }
    }

#ifndef NIXL_XNVME_NO_VRAM
    if (ok && work->vram_dst) {
        hipError_t e = hipMemcpy(work->vram_dst, work->buf, work->buf_len,
                                  hipMemcpyHostToDevice);
        if (e != hipSuccess) {
            XNVME_PLUGIN_ERR << "staging->VRAM hipMemcpy failed: " << hipGetErrorString(e);
            ok = false;
        }
    }
#endif

    // Return the ctx to its queue's pool before the work item is freed —
    // skipping this exhausts the queue's ctx pool and stalls all future
    // submissions (same gotcha called out in kv_bench.c).
    xnvme_queue_put_cmd_ctx(work->qw->queue, ctx);
    // A completion — success OR failure — is forward progress: it proves the
    // device is still answering, which is exactly what the stall check asks.
    // Stamped before kv_complete_cb(), which frees `work`.
    if (work->qw->in_flight) work->qw->in_flight--;
    work->qw->last_progress_ns = xnvme_now_ns();
    work->qw->stall_reported   = false;
    kv_complete_cb(work, ok);
}

// ---- Submission (runs on the owning QueueWorker's reactor thread) ----------

nixlXnvmeKvEngine::SubmitResult nixlXnvmeKvEngine::submit_one(
        QueueWorker *qw, struct xnvme_cmd_ctx *ctx, XnvmeKvWorkEx *work) const {
    work->qw = qw;
    xnvme_cmd_ctx_set_cb(ctx, completion_trampoline, work);

    int rc;
    if (work->op == NIXL_WRITE) {
        rc = xnvme_kvs_store(ctx, nsid_, work->key, work->key_len,
                             work->buf, work->buf_len, /*opt=*/0);
    } else {
        rc = xnvme_kvs_retrieve(ctx, nsid_, work->key, work->key_len,
                                work->buf, work->buf_len, /*opt=*/0);
    }
    if (rc == 0) {
        work->submit_ns = xnvme_now_ns();
        if (work->op == NIXL_WRITE) {
            qw->m_store_ops.fetch_add(1, std::memory_order_relaxed);
            qw->m_store_bytes.fetch_add(work->buf_len, std::memory_order_relaxed);
        } else {
            qw->m_retrieve_ops.fetch_add(1, std::memory_order_relaxed);
            qw->m_retrieve_bytes.fetch_add(work->buf_len, std::memory_order_relaxed);
        }
        if (xnvme_kv_debug()) {
            char keyhex[XNVME_KV_KEY_MAX_LEN * 2 + 1];
            xnvme_kv_key_hex(reinterpret_cast<const uint8_t *>(&work->key),
                             work->key_len, keyhex);
            fprintf(stderr, "[XNVME_KV] op=%s key=%s len=%u t=submit rc=0\n",
                    work->op == NIXL_WRITE ? "store" : "retrieve", keyhex,
                    (unsigned)work->buf_len);
            fflush(stderr);
        }
        return SubmitResult::kSubmitted;
    }

    xnvme_queue_put_cmd_ctx(qw->queue, ctx);

    // -EBUSY/-EAGAIN/-ENOMEM here mean "queue/device temporarily full", not
    // a real transfer failure — the same failure class already documented
    // in this project for the SPDK_NVMe_KV plugin (do_kv_io_async() treating
    // any nonzero return as permanent NIXL_ERR_BACKEND, which caps the safe
    // usable pipeline depth well below what the hardware can sustain).
    // Confirmed reproducing here at NIXL_XNVME_NUM_QUEUES=8/NUM_THREADS=8/
    // PIPELINE_DEPTH=32 (2026-08-03) — retry instead of failing the slot.
    if (rc == -EBUSY || rc == -EAGAIN || rc == -ENOMEM) {
        qw->m_submit_retry.fetch_add(1, std::memory_order_relaxed);
        if (xnvme_kv_debug()) {
            fprintf(stderr, "[XNVME_KV] op=%s len=%u t=submit rc=%d deferred "
                            "(transient queue-full; normal backpressure)\n",
                    work->op == NIXL_WRITE ? "store" : "retrieve",
                    (unsigned)work->buf_len, rc);
            fflush(stderr);
        }
        return SubmitResult::kRetry;
    }

    qw->m_submit_fail.fetch_add(1, std::memory_order_relaxed);
    XNVME_PLUGIN_ERR << "submit failed (op=" << (int)work->op << "): " << strerror(-rc);
    kv_complete_cb(work, false);
    return SubmitResult::kFailed;
    // On kSubmitted, completion_trampoline() runs on this same thread's next
    // xnvme_queue_poke() call.
}

// ---- Reactor thread: exclusively owns qw->dev / qw->queue ------------------

void *nixlXnvmeKvEngine::reactor_entry(void *arg) {
    auto *self = static_cast<std::pair<nixlXnvmeKvEngine *, QueueWorker *> *>(arg);
    self->first->reactor_loop(self->second);
    delete self;
    return nullptr;
}

void nixlXnvmeKvEngine::fail_queued_work(QueueWorker *qw,
                                         std::deque<XnvmeKvWorkEx *> &local) {
    while (!local.empty()) {
        XnvmeKvWorkEx *work = local.front();
        local.pop_front();
        kv_complete_cb(work, false);
    }
    std::lock_guard<std::mutex> lk(qw->mbox_mtx);
    while (!qw->mbox.empty()) {
        XnvmeKvWorkEx *work = qw->mbox.front();
        qw->mbox.pop_front();
        kv_complete_cb(work, false);
    }
}

// ---- M0/W0.2: runtime metrics export ---------------------------------------
//
// Aggregates every worker's counters and rewrites metrics_path_ atomically
// (.tmp + rename), so a reader never sees a half-written file. Self-throttling:
// one reactor thread claims each interval via compare_exchange, the rest return
// immediately.
//
// Deliberately a FILE, not an HTTP endpoint. An endpoint would need a listener
// thread inside vLLM's address space, a port to allocate, and a collision story
// across the two-container deployments this repo runs. A file is greppable from
// `docker exec`, outlives the process, and costs nothing when nobody reads it.
void nixlXnvmeKvEngine::write_metrics(bool force) {
    if (metrics_path_.empty() || !metrics_interval_ns_) return;

    const uint64_t now  = xnvme_now_ns();
    if (!force) {
        uint64_t last = last_metrics_ns_.load(std::memory_order_relaxed);
        if (now - last < metrics_interval_ns_) return;
        // Claim the interval. Losers return rather than duplicating the write.
        if (!last_metrics_ns_.compare_exchange_strong(last, now,
                                                      std::memory_order_relaxed))
            return;
    } else {
        last_metrics_ns_.store(now, std::memory_order_relaxed);
    }

    uint64_t so = 0, ro = 0, sb = 0, rb = 0, cok = 0, cerr = 0;
    uint64_t sretry = 0, sfail = 0, stalls = 0, peak = 0, latsum = 0;
    uint64_t inflight = 0, buckets[8] = {0};
    for (auto &w : workers_) {
        if (!w) continue;
        so     += w->m_store_ops.load(std::memory_order_relaxed);
        ro     += w->m_retrieve_ops.load(std::memory_order_relaxed);
        sb     += w->m_store_bytes.load(std::memory_order_relaxed);
        rb     += w->m_retrieve_bytes.load(std::memory_order_relaxed);
        cok    += w->m_completions_ok.load(std::memory_order_relaxed);
        cerr   += w->m_completions_err.load(std::memory_order_relaxed);
        sretry += w->m_submit_retry.load(std::memory_order_relaxed);
        sfail  += w->m_submit_fail.load(std::memory_order_relaxed);
        stalls += w->m_stalls.load(std::memory_order_relaxed);
        latsum += w->m_lat_sum_us.load(std::memory_order_relaxed);
        peak   += w->m_peak_in_flight.load(std::memory_order_relaxed);
        inflight += w->in_flight;
        for (int i = 0; i < 8; ++i)
            buckets[i] += w->m_lat_bucket[i].load(std::memory_order_relaxed);
    }

    const std::string tmp = metrics_path_ + ".tmp";
    FILE *f = std::fopen(tmp.c_str(), "w");
    if (!f) return;   // best-effort: never fail a transfer over a metrics write
    std::fprintf(f,
        "{\n"
        "  \"backend\": \"XNVME_KV\",\n"
        "  \"pid\": %d,\n"
        "  \"device\": \"%s\",\n"
        "  \"queues\": %zu,\n"
        "  \"store_ops\": %llu,\n"
        "  \"retrieve_ops\": %llu,\n"
        "  \"store_bytes\": %llu,\n"
        "  \"retrieve_bytes\": %llu,\n"
        "  \"completions_ok\": %llu,\n"
        "  \"completions_err\": %llu,\n"
        "  \"submit_retry\": %llu,\n"
        "  \"submit_fail\": %llu,\n"
        "  \"stalls\": %llu,\n"
        "  \"in_flight\": %llu,\n"
        "  \"peak_in_flight\": %llu,\n"
        "  \"lat_us_sum\": %llu,\n"
        "  \"lat_us_bucket_upper\": [16,64,256,1024,4096,16384,65536,-1],\n"
        "  \"lat_us_bucket\": [%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu]\n"
        "}\n",
        (int)getpid(), dev_uri_.c_str(), workers_.size(),
        (unsigned long long)so, (unsigned long long)ro,
        (unsigned long long)sb, (unsigned long long)rb,
        (unsigned long long)cok, (unsigned long long)cerr,
        (unsigned long long)sretry, (unsigned long long)sfail,
        (unsigned long long)stalls, (unsigned long long)inflight,
        (unsigned long long)peak, (unsigned long long)latsum,
        (unsigned long long)buckets[0], (unsigned long long)buckets[1],
        (unsigned long long)buckets[2], (unsigned long long)buckets[3],
        (unsigned long long)buckets[4], (unsigned long long)buckets[5],
        (unsigned long long)buckets[6], (unsigned long long)buckets[7]);
    std::fclose(f);
    if (std::rename(tmp.c_str(), metrics_path_.c_str()) != 0)
        (void)::unlink(tmp.c_str());
}

void nixlXnvmeKvEngine::reactor_loop(QueueWorker *qw) {
    std::deque<XnvmeKvWorkEx *> local;

    qw->last_progress_ns = xnvme_now_ns();

    while (!qw->stop.load(std::memory_order_relaxed)) {
        {
            std::unique_lock<std::mutex> lk(qw->mbox_mtx);
            if (local.empty() && qw->mbox.empty()) {
                qw->mbox_cv.wait_for(lk, std::chrono::milliseconds(1), [&] {
                    return !qw->mbox.empty() || qw->stop.load(std::memory_order_relaxed);
                });
            }
            while (!qw->mbox.empty()) {
                local.push_back(qw->mbox.front());
                qw->mbox.pop_front();
            }
        }

        // Submit as many pending work items as the queue's ctx pool allows;
        // stop and poll for completions once it's full (mirrors kv_bench.c's
        // run_phase: get_cmd_ctx() returning NULL means "queue full, reap
        // completions and retry"). A kRetry result (transient -EBUSY/-EAGAIN/
        // -ENOMEM from the actual submit, as opposed to ctx-pool exhaustion)
        // gets the work item put back at the front and stops this pass early
        // — same "back off and let completions drain" response as the ctx-
        // pool-exhausted case just below.
        while (!local.empty()) {
            struct xnvme_cmd_ctx *ctx = xnvme_queue_get_cmd_ctx(qw->queue);
            if (!ctx) break;
            XnvmeKvWorkEx *work = local.front();
            local.pop_front();
            if (submit_one(qw, ctx, work) == SubmitResult::kRetry) {
                local.push_front(work);
                break;
            }
            // A submission the device accepted is forward progress, and so is
            // any completion reaped below (completion_trampoline stamps it).
            // Both feed the stall check.
            qw->in_flight++;
            if (qw->in_flight > qw->m_peak_in_flight.load(std::memory_order_relaxed))
                qw->m_peak_in_flight.store(qw->in_flight, std::memory_order_relaxed);
            qw->last_progress_ns = xnvme_now_ns();
            qw->stall_reported   = false;
        }

        xnvme_queue_poke(qw->queue, 0);

        // Self-throttling; see write_metrics(). Placed after poke so a sample
        // reflects completions reaped in this iteration.
        write_metrics();

        // Stall check. Deliberately placed AFTER poke, so completions reaped in
        // this iteration count as progress before we judge the queue dead.
        //
        // Only trips when work is pending AND nothing has been submitted or
        // completed for the whole timeout — i.e. genuinely no forward progress,
        // not merely "slow" or "busy". A device that is simply saturated keeps
        // completing, which keeps refreshing last_progress_ns.
        //
        // Reports and fails. Does NOT attempt any device recovery — see the
        // declaration of stall_timeout_ns_ for why that would be actively
        // harmful on the real DSC.
        bool outstanding = !local.empty() || qw->in_flight > 0;
        if (stall_timeout_ns_ && outstanding && !qw->stall_reported &&
            xnvme_now_ns() - qw->last_progress_ns > stall_timeout_ns_) {
            XNVME_PLUGIN_ERR
                << "queue made no forward progress for "
                << (stall_timeout_ns_ / 1000000000ULL) << "s: "
                << local.size() << " op(s) queued, " << qw->in_flight
                << " in flight. The device has stopped completing I/O; this is "
                   "NOT the transient queue-full condition. No device reset is "
                   "attempted: on the Pensando DSC only an out-of-band DPU-side "
                   "restart recovers this, and host-side resets make it worse.";
            qw->stall_reported = true;
            qw->m_stalls.fetch_add(1, std::memory_order_relaxed);

            // Only the queued-but-unsubmitted items can be failed. In-flight
            // ops are still owned by xNVMe: their cmd_ctx may yet be completed,
            // and completing them from here would race the trampoline into a
            // double free of the same work item. So a wedge that happens AFTER
            // submission still hangs the caller — that is a property of the
            // wedge, not something this check can honestly fix. What it does
            // buy is a named, loud diagnosis instead of silence, which is the
            // difference between "the DSC is wedged, restart the DPU-side app"
            // and an unexplained stall.
            fail_queued_work(qw, local);
        }

        // The stall clock must measure "time spent with work outstanding and no
        // progress", NOT wall time since the device last did anything. Without
        // this, a queue that sat idle for longer than the timeout would trip
        // the check on the very first item submitted after the quiet period —
        // a false positive that would fail perfectly healthy transfers.
        if (local.empty() && qw->in_flight == 0) {
            qw->last_progress_ns = xnvme_now_ns();
            qw->stall_reported   = false;
        }
    }

    // Drain in-flight completions before this queue's dev is torn down.
    xnvme_queue_drain(qw->queue);

    // Anything still queued after the drain was never submitted, so no
    // completion will ever arrive for it. Fail it rather than dropping it:
    // each item holds a decrement of req->pending, and a dropped item leaves
    // the caller blocked in checkXfer()/waitXfer() forever. Reached on normal
    // shutdown whenever a transfer was still in flight.
    fail_queued_work(qw, local);

    // Final flush. The periodic write above is throttled, so without this the
    // counters for everything that happened since the last tick never reach the
    // file: a short run reported store_ops=1 / completions_ok=0 / empty latency
    // histogram on 2026-09-02 precisely because it finished inside one interval.
    write_metrics(/*force=*/true);
}

// ---- Constructor / Destructor ----------------------------------------------

nixlXnvmeKvEngine::nixlXnvmeKvEngine(const nixlBackendInitParams *init_params)
    : nixlBackendEngine(init_params) {

    // Priority: NIXL_XNVME_DEV env var > plugin initParam "dev_uri".
    {
        const char *dev_env = std::getenv("NIXL_XNVME_DEV");
        std::string dev_param;
        if (dev_env && dev_env[0] != '\0') {
            dev_uri_ = dev_env;
            fprintf(stderr, "[XNVME_KV] device from env: %s\n", dev_uri_.c_str());
        } else if (getInitParam("dev_uri", dev_param) == NIXL_SUCCESS && !dev_param.empty()) {
            dev_uri_ = dev_param;
        } else {
            fprintf(stderr, "[XNVME_KV] NIXL_XNVME_DEV not set and no dev_uri param — "
                    "e.g. /dev/ng0n1 (kernel nvme driver must own the device, see README)\n");
            initErr = true;
            return;
        }
    }

    {
        const char *nsid_env = std::getenv("NIXL_XNVME_NSID");
        nsid_ = nsid_env ? static_cast<uint32_t>(std::atoi(nsid_env)) : 0;  // 0 = ask device
    }

    {
        const char *nq_env = std::getenv("NIXL_XNVME_NUM_QUEUES");
        int nq = nq_env ? std::atoi(nq_env) : 1;
        num_queues_ = (nq > 0) ? static_cast<size_t>(nq) : 1;
    }

    // Bound on "the device has stopped answering entirely" — see
    // stall_timeout_ns_'s declaration. Generous by default: it must never fire
    // on a merely busy or deep-queued device, only on one making literally zero
    // progress. Set 0 to disable, at the cost of turning a wedged device into a
    // transfer that hangs forever instead of one that reports an error.
    {
        const char *t_env = std::getenv("NIXL_XNVME_STALL_TIMEOUT_SEC");
        long t = t_env ? std::atol(t_env) : 30;
        if (t < 0) t = 0;
        stall_timeout_ns_ = static_cast<uint64_t>(t) * 1000000000ULL;
    }

    // ---- M0/W0.2: where to publish runtime counters ------------------------
    // NIXL_KV_METRICS_INTERVAL_SEC=0 disables export entirely (default 10 s).
    // NIXL_KV_METRICS_PATH overrides the file outright; otherwise resolve the
    // directory the same way bench/lib/deployment.sh resolves the deployment
    // record, and for the same reason — a sixth, plugin-specific location is
    // how "no record" gets concluded wrongly.
    {
        const char *iv = std::getenv("NIXL_KV_METRICS_INTERVAL_SEC");
        long sec = iv ? std::atol(iv) : 10;
        if (sec < 0) sec = 0;
        metrics_interval_ns_ = static_cast<uint64_t>(sec) * 1000000000ULL;

        if (metrics_interval_ns_) {
            const char *explicit_path = std::getenv("NIXL_KV_METRICS_PATH");
            if (explicit_path && explicit_path[0]) {
                metrics_path_ = explicit_path;
            } else {
                std::string tmpdir = "/tmp/kv-cache-bench-" +
                                     std::to_string((unsigned)getuid());
                const char *xdg = std::getenv("XDG_RUNTIME_DIR");
                std::string xdgdir = xdg && xdg[0]
                                   ? std::string(xdg) + "/kv-cache-bench" : "";
                const char *state = std::getenv("KV_BENCH_DEPLOY_STATE_DIR");
                std::vector<std::string> cands;
                if (state && state[0]) cands.push_back(state);
                cands.push_back("/run/kv-cache-bench");
                if (!xdgdir.empty()) cands.push_back(xdgdir);
                cands.push_back(tmpdir);

                for (const auto &d : cands) {
                    (void)::mkdir(d.c_str(), 0755);   // may already exist
                    if (::access(d.c_str(), W_OK) == 0) {
                        metrics_path_ = d + "/kv-metrics-" +
                                        std::to_string((int)getpid()) +
                                        "-XNVME_KV.json";
                        break;
                    }
                }
            }
            if (!metrics_path_.empty()) {
                fprintf(stderr, "[XNVME_KV] runtime metrics -> %s (every %lds)\n",
                        metrics_path_.c_str(), sec);
                fflush(stderr);
            }
        }
    }

    if (start_workers() != NIXL_SUCCESS) {
        initErr = true;
        return;
    }

    ready_ = true;
    initErr = false;
}

nixlXnvmeKvEngine::~nixlXnvmeKvEngine() {
    stop_workers();
}

nixl_status_t nixlXnvmeKvEngine::start_workers() {
    workers_.reserve(num_queues_);

    for (size_t i = 0; i < num_queues_; ++i) {
        auto qw = std::make_unique<QueueWorker>();

        struct xnvme_opts opts = xnvme_opts_default();
        opts.async = "io_uring_cmd";
        if (nsid_ != 0) opts.nsid = nsid_;

        qw->dev = xnvme_dev_open(dev_uri_.c_str(), &opts);
        if (!qw->dev) {
            XNVME_PLUGIN_ERR << "xnvme_dev_open(" << dev_uri_ << ") failed: " << strerror(errno);
            return NIXL_ERR_BACKEND;
        }
        if (nsid_ == 0) nsid_ = xnvme_dev_get_nsid(qw->dev);

        // Queue depth: fixed default (64) — same order of magnitude as
        // kv_bench.c's default (-q 32); nixlbench's own --num_iter/pipeline
        // depth governs how many descriptors are actually in flight at once.
        if (xnvme_queue_init(qw->dev, /*capacity=*/64, /*flags=*/0, &qw->queue)) {
            XNVME_PLUGIN_ERR << "xnvme_queue_init failed for worker " << i << ": " << strerror(errno);
            xnvme_dev_close(qw->dev);
            return NIXL_ERR_BACKEND;
        }

        QueueWorker *raw = qw.get();
        auto *targs = new std::pair<nixlXnvmeKvEngine *, QueueWorker *>(this, raw);
        if (pthread_create(&raw->thread, nullptr, reactor_entry, targs) != 0) {
            delete targs;
            xnvme_queue_term(qw->queue);
            xnvme_dev_close(qw->dev);
            return NIXL_ERR_BACKEND;
        }

        workers_.push_back(std::move(qw));
    }

    // Ask the device what it actually supports, now that a handle exists.
    // Best-effort and non-fatal: on any failure the compiled-in default stands.
    query_max_value_size(workers_[0]->dev);

    fprintf(stderr, "[XNVME_KV] %zu queue(s) ready on %s (nsid=%u)\n",
            num_queues_, dev_uri_.c_str(), nsid_);
    return NIXL_SUCCESS;
}

void nixlXnvmeKvEngine::query_max_value_size(struct xnvme_dev *dev) {
    // Identify Namespace with CSI=KV (Key Value Command Set Spec 1.0c, Fig 39).
    // The 4096-byte result carries up to 16 KV format descriptors; the active
    // one is selected by the KV Format Capabilities byte at offset 29 (low
    // nibble). libxnvme lumps that byte into rsvd29[]; SPDK names the same
    // byte kvfc.kvfi (see spdk_nvme_kv_ns_data in nvme_spec.h). Reading it
    // positionally here is deliberate, not a hack around a missing field.
    auto *idfy = static_cast<struct xnvme_spec_kvs_idfy *>(
        xnvme_buf_alloc(dev, sizeof(struct xnvme_spec_kvs_idfy)));
    if (!idfy) {
        XNVME_PLUGIN_ERR << "max_value_size query: xnvme_buf_alloc failed; keeping default "
                         << XNVME_KV_DEFAULT_MAX_VALUE_SIZE;
        return;
    }
    std::memset(idfy, 0, sizeof(struct xnvme_spec_kvs_idfy));

    struct xnvme_cmd_ctx ctx = xnvme_cmd_ctx_from_dev(dev);
    int err = xnvme_adm_idfy_ns_csi(&ctx, nsid_, XNVME_SPEC_CSI_KV, &idfy->base);
    if (err || xnvme_cmd_ctx_cpl_status(&ctx)) {
        fprintf(stderr,
                "[XNVME_KV] max_value_size query failed (err=%d sct=%u sc=%u) — "
                "keeping compiled-in default %u\n",
                err, (unsigned)ctx.cpl.status.sct, (unsigned)ctx.cpl.status.sc,
                XNVME_KV_DEFAULT_MAX_VALUE_SIZE);
        xnvme_buf_free(dev, idfy);
        return;
    }

    uint8_t idx = static_cast<uint8_t>(idfy->ns.rsvd29[0] & 0x0F);
    if (idx > idfy->ns.nkvf) idx = 0;   // nkvf is 0's based: 0 means one format
    const uint32_t vml = idfy->ns.kvf[idx].vml;
    const uint16_t kml = idfy->ns.kvf[idx].kml;

    // Report unconditionally, even though adopting the value is opt-in (see
    // getParams()). A device whose advertised size differs from the
    // empirically-validated default is precisely what someone needs to see
    // before deciding to change the on-disk geometry.
    fprintf(stderr,
            "[XNVME_KV] device KV format %u: value_max=%u key_max=%u novg=%u "
            "(compiled-in default %u)\n",
            idx, vml, kml, idfy->ns.novg, XNVME_KV_DEFAULT_MAX_VALUE_SIZE);

    if (kml != 0 && kml < 12) {
        XNVME_PLUGIN_ERR << "device max key length " << kml
                         << " is below the 12 bytes make_key() emits — stores will be rejected";
    }
    if (vml == 0) {
        fprintf(stderr, "[XNVME_KV] device reported value_max=0 (not indicated); "
                        "keeping compiled-in default %u\n", XNVME_KV_DEFAULT_MAX_VALUE_SIZE);
    } else {
        discovered_max_value_size_.store(vml, std::memory_order_relaxed);
        if (vml < XNVME_KV_DEFAULT_MAX_VALUE_SIZE) {
            // The compiled-in default is too big for this device: writes at
            // the default size would be rejected. Loud, because the fallback
            // is no longer the safe choice here.
            XNVME_PLUGIN_ERR << "WARNING: device value_max=" << vml
                             << " is SMALLER than the compiled-in default "
                             << XNVME_KV_DEFAULT_MAX_VALUE_SIZE
                             << " — set NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE=1 or stores will fail";
        }
    }
    xnvme_buf_free(dev, idfy);
}

void nixlXnvmeKvEngine::stop_workers() {
    for (auto &qw : workers_) {
        qw->stop.store(true, std::memory_order_relaxed);
        qw->mbox_cv.notify_all();
    }
    for (auto &qw : workers_) {
        pthread_join(qw->thread, nullptr);
        xnvme_queue_term(qw->queue);
        xnvme_dev_close(qw->dev);
    }
    workers_.clear();
}

// ---- registerMem / deregisterMem -------------------------------------------

nixl_status_t nixlXnvmeKvEngine::registerMem(const nixlBlobDesc &mem,
                                              const nixl_mem_t   &nixl_mem,
                                              nixlBackendMD      *&out) {
    auto *md = new nixlXnvmeKvMD();
    md->type   = nixl_mem;
    md->size   = mem.len;
    md->dev_id = mem.devId;

    switch (nixl_mem) {
    case DRAM_SEG:
        // No persistent DMA registration call for io_uring_cmd passthrough —
        // see header comment. Just store the pointer.
        md->ptr = reinterpret_cast<void *>(mem.addr);
        break;

    case VRAM_SEG: {
#ifdef NIXL_XNVME_NO_VRAM
        fprintf(stderr, "[XNVME_KV] VRAM_SEG requested but this plugin was built "
                "without VRAM support (no ROCm on this host)\n");
        delete md; return NIXL_ERR_NOT_SUPPORTED;
#else
        hipPointerAttribute_t attr{};
        hipError_t e = hipPointerGetAttributes(&attr, reinterpret_cast<void *>(mem.addr));
        if (e != hipSuccess) {
            fprintf(stderr, "[XNVME_KV] VRAM_SEG pointer validation failed: %s\n",
                    hipGetErrorString(e));
            delete md; return NIXL_ERR_INVALID_PARAM;
        }
        md->ptr = reinterpret_cast<void *>(mem.addr);
        break;
#endif
    }

    case FILE_SEG:
    case OBJ_SEG:
        if (!ready_) {
            fprintf(stderr, "[XNVME_KV] FILE_SEG/OBJ_SEG registerMem: device not ready\n");
            delete md; return NIXL_ERR_BACKEND;
        }
        // Stays empty for callers that never set metaInfo (kv_io.py,
        // nixlbench) — postXfer() falls back to devId/addr in that case.
        md->meta_info = mem.metaInfo;
        break;

    default:
        fprintf(stderr, "[XNVME_KV] unsupported seg type %d\n", nixl_mem);
        delete md; return NIXL_ERR_INVALID_PARAM;
    }

    out = md;
    return NIXL_SUCCESS;
}

nixl_status_t nixlXnvmeKvEngine::deregisterMem(nixlBackendMD *meta) {
    delete static_cast<nixlXnvmeKvMD *>(meta);
    return NIXL_SUCCESS;
}

// ---- prepXfer ---------------------------------------------------------------

nixl_status_t nixlXnvmeKvEngine::prepXfer(
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

    auto *req = new nixlXnvmeKvReqH();

#ifndef NIXL_XNVME_NO_VRAM
    if (local_type == VRAM_SEG) {
        size_t total = 0;
        for (int i = 0; i < local.descCount(); ++i) total += local[i].len;

        void *buf = nullptr;
        if (posix_memalign(&buf, 4096, total) != 0 || !buf) {
            XNVME_PLUGIN_ERR << "posix_memalign(" << total << ") failed for VRAM staging buffer";
            delete req;
            return NIXL_ERR_BACKEND;
        }
        hipError_t e = hipHostRegister(buf, total, hipHostRegisterDefault);
        if (e != hipSuccess) {
            XNVME_PLUGIN_ERR << "hipHostRegister(" << total << ") failed: " << hipGetErrorString(e);
            free(buf);
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

// ---- postXfer — async, non-blocking -----------------------------------------

nixl_status_t nixlXnvmeKvEngine::postXfer(
        const nixl_xfer_op_t   &operation,
        const nixl_meta_dlist_t &local,
        const nixl_meta_dlist_t &remote,
        const std::string       &,
        nixlBackendReqH         *&handle,
        const nixl_opt_b_args_t *) const {

    if (!ready_ || workers_.empty()) return NIXL_ERR_BACKEND;

    auto *req = static_cast<nixlXnvmeKvReqH *>(handle);
    int n = local.descCount();
    req->error.store(false, std::memory_order_relaxed);

    bool vram = (local.getType() == VRAM_SEG);
    char  *staging_ptr = vram ? static_cast<char *>(req->staging_) : nullptr;
    size_t staging_off = 0;

    // Set pending BEFORE submitting any work (avoids a race where a fast
    // completion decrements to 0 before all work items are posted).
    req->pending.store(n, std::memory_order_release);

    for (int i = 0; i < n; ++i) {
        const auto &mem_desc  = local[i];
        const auto &file_desc = remote[i];

        auto *work = new XnvmeKvWorkEx{};
        work->buf_len = static_cast<uint32_t>(mem_desc.len);
        work->op      = operation;
        work->req     = req;
        // metadataP points back at whatever registerMem() created for this
        // exact region (nixlMetaDesc contract) — retrieve the meta_info we
        // stashed there so callers with their own object name (e.g. LMCache's
        // OBJ mode) don't collide on devId/addr alone. Guard for
        // null since not every xfer-descriptor-building path is confirmed to
        // populate it identically (see plan's Part 4 verification).
        auto *file_md = static_cast<nixlXnvmeKvMD *>(file_desc.metadataP);
        const std::string &meta_info = file_md ? file_md->meta_info : std::string();
        make_key(file_desc.devId, file_desc.addr, meta_info, work->key, &work->key_len);

        if (vram) {
            void *slice = staging_ptr + staging_off;
            staging_off += mem_desc.len;

            if (operation == NIXL_WRITE) {
#ifndef NIXL_XNVME_NO_VRAM
                hipError_t e = hipMemcpy(slice, reinterpret_cast<void *>(mem_desc.addr),
                                         mem_desc.len, hipMemcpyDeviceToHost);
                if (e != hipSuccess) {
                    XNVME_PLUGIN_ERR << "VRAM->staging hipMemcpy failed: " << hipGetErrorString(e);
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

        // Round-robin each descriptor across all queues.
        uint32_t idx = next_queue_.fetch_add(1, std::memory_order_relaxed) %
                       static_cast<uint32_t>(num_queues_);
        QueueWorker *qw = workers_[idx].get();
        {
            std::lock_guard<std::mutex> lk(qw->mbox_mtx);
            qw->mbox.push_back(work);
        }
        qw->mbox_cv.notify_one();
    }

    return NIXL_IN_PROG;
}

// ---- checkXfer / releaseReqH ------------------------------------------------

nixl_status_t nixlXnvmeKvEngine::checkXfer(nixlBackendReqH *handle) const {
    auto *req = static_cast<nixlXnvmeKvReqH *>(handle);
    if (req->pending.load(std::memory_order_acquire) != 0)
        return NIXL_IN_PROG;
    return req->error.load() ? NIXL_ERR_BACKEND : NIXL_SUCCESS;
}

nixl_status_t nixlXnvmeKvEngine::releaseReqH(nixlBackendReqH *handle) const {
    delete handle;
    return NIXL_SUCCESS;
}
