# Handoff

State of the P/D-disaggregated KV cache project, for whoever picks this up next
(including future me). Last updated 2026-09-14.

Read this before [BRINGUP.md](BRINGUP.md). It tells you what is real, what is
assumed, and what is still wrong.

---

## 1. What this project is

Three nodes, splitting vLLM inference so prefill and decode run on different
machines and share KV cache.

| Role | Hardware | Function |
|---|---|---|
| Prefill | 8× MI300X `[1dd8:5303]`, 2× DSC3-2Q400 `[1dd8:5200]` | vLLM, KV producer |
| Decode | 8× MI300X `[1dd8:5303]`, 2× DSC3-2Q400 `[1dd8:5200]` | vLLM, KV consumer |
| Target | no GPU, 2× POLLARA-1Q400 `[1dd8:1002]` | SPDK NVMe-KV over NVMe-oF/TCP |

Addresses and credentials are **not in this repo** — see §3. Stack is
vLLM + LMCache + NIXL + the two NIXL plugins in `plugins/`, on ROCm.
Model is Qwen2.5-72B-Instruct at TP=8.

### Two independent legs

This distinction is the thing to get right; an earlier pass got it wrong and
built an entire phase plan around the mistake.

| Leg | Path | Transport | NICs |
|---|---|---|---|
| **A — P→D transfer** | prefill → decode, direct GPU-to-GPU via NIXL/UCX | TCP now → **RDMA = acceptance** | DSC3-2Q400 |
| **B — Shared KV storage** | both compute nodes → target over NVMe-oF | **TCP, permanently by design** | POLLARA-1Q400 |

Composed as `MultiConnector[NixlConnector, LMCacheMPConnector]`: NixlConnector
carries the P/D role and moves KV over RDMA; LMCache stays `kv_both` on both
sides as a reuse tier, not the transport.

---

## 2. Current state

18 commits on `main`, which is the default branch and in sync with
`github.com/pmallapp-amd/llm-stacks`. Working tree clean.

**The repository is PUBLIC.** Everything lab-specific has been externalised and
the history purged (§3). Verified: no credential or lab identifier appears in
any blob of any commit.

**Nothing has run on hardware.** Every script is written and lint-clean, and the
target and compute-leg configurations are now transcribed from a working
deployment rather than inferred — but no end-to-end run exists. Treat the first
invocation as bring-up, not a benchmark.

---

## 3. Credentials and lab identity

Per-setup identity lives outside the repo entirely:

```
creds/setup-4.env     real values, mode 0600, untracked
creds/active.env      symlink -> setup-4.env
config/creds.env.template   tracked template, placeholders only
scripts/common/init-creds.sh   scaffolds a creds file and the symlink
```

`.gitignore` carries a bare `/creds/` with **no negation exceptions**. A
`!creds/...` rule is one typo away from tracking a real credentials file in a
public repo, so the template deliberately sits on the tracked side of that line
in `config/`. `init-creds.sh` additionally refuses to write if `creds/` is not
ignored, verifying the assumption rather than trusting it.

`config/cluster.env` sources `${CREDS_FILE:-creds/active.env}` before its own
defaults, so creds always win. Anything unset falls back to a placeholder on the
reserved `.invalid` TLD — a checkout with no creds file fails DNS immediately
rather than resolving to a real machine.

To get a fresh checkout running: `scripts/common/init-creds.sh 4`, edit the
file, then `scripts/common/00-preflight.sh`.

> **Outstanding:** the BMC and root passwords were committed to a public repo
> before this cleanup. The history is purged and the published branch is clean,
> but if anyone cloned or GitHub cached it during that window, rotation is the
> only real remedy. This is tracked as TODO 0.2 and is not closed by the purge.

---

## 4. Repository map

```
config/cluster.env          single source of truth; sources creds/active.env first
config/creds.env.template   tracked template for a per-setup creds file
creds/                      UNTRACKED, gitignored — real addresses and passwords
scripts/common/             lib.sh (shared vocabulary), init-creds, preflight,
                            SPDK/UCX/NIXL build chain, venv, LMCache + kv-transfer
                            config generation, shared vLLM launcher
scripts/target/             SPDK build + nvmf_tgt, verify, namespace reset,
                            chunk-ceiling guard
scripts/prefill/            host prep, vLLM as kv_producer
scripts/decode/             host prep, vLLM as kv_consumer
scripts/proxy/              async disaggregation router
scripts/verify/             10 network → 20 plugin → 30 KV roundtrip →
                            40 end-to-end → 50 direct P/D transfer
scripts/bench/              llama-benchy harness + compare_runs.py
patches/spdk/               4 NVMe-KV patches (2 still required, see §5)
patches/lmcache/            NIXL backend allowlist patch, generated at apply time
plugins/                    vendored SPDK_NVMe_KV and XNVME_KV NIXL backends
docs/                       ARCHITECTURE, BRINGUP, TROUBLESHOOTING, BENCHMARKING,
                            TODO, HANDOFF
```

---

## 5. SPDK: upstream plus two patches

There is **no private fork**. NVMe-KV support is four upstream-bound patches by
Ben Walker (NVIDIA) on review.spdk.io, vendored in `patches/spdk/`:

| Patch | Gerrit | Status |
|---|---|---|
| `0001` nvme: recognize KV namespaces | 28260 | **MERGED** 2026-08-25 (`8dc8327`) |
| `0002` bdev/kvmalloc | 27889 | **OPEN** — CR+2, Verified+1, mergeable, tagged `26.09` |
| `0003` nvmf: KV namespace support | 28298 | **OPEN** — CR+2 ×2, Verified+1, tagged `26.09`; depends on 0002 |
| `0004` nvme: KV unit tests | 27886 | **MERGED** 2026-08-25 (`b12a372`) |

v26.05 has the KV *initiator* API but predates all four. Master carries 0001 and
0004. **Only 0002 and 0003 must be carried**, and both are review-complete —
re-check `https://review.spdk.io/q/topic:kv+status:open`; when they land, the
vendored copies can be dropped. See [patches/spdk/README.md](../patches/spdk/README.md).

---

## 6. Verified vs assumed

The scripts fail loudly on the assumed items rather than guessing. Preserve that
when editing.

### Verified

- Plugin env vars, params and failure modes — read from `plugins/nvme-kv/*.{h,cpp}`.
  The `queryMem()`, `make_key()` and `max_value_size` comments are authoritative.
- SPDK patch provenance and Gerrit status (§5), queried directly.
- Target configuration — `nvmf_tgt` binary, single `--json` startup config,
  `bdev_kvmalloc_create` taking `name`/`max_key_size`/`max_value_size`,
  `max_io_qpairs_per_ctrlr`, the iobuf sizing — all transcribed from a working
  deployment, not inferred.
- The chunk-size formula (§7 invariant 8), validated against two independent
  measurements.
- Compute-leg composition and UCX configuration — `MultiConnector` schema,
  `UCX_TLS=ib,rocm,self,sm`, the RoCE `/31` subnet workaround, side-channel
  behaviour — all from the same working deployment.
- LMCache's own `enable_pd`/`pd_role` peer channel is **unusable** with this
  plugin: it requires `supportsRemote() == true`, which
  `spdk_nvme_kv_backend.h` explicitly declines. This is why the P/D role goes on
  NixlConnector and never on LMCache.

### Assumed — reconcile on first contact with hardware

- **LMCache YAML key names and the allowlist patch sites.** Derived against
  v0.5.4, validated only against a mock. `apply-patches.sh` fails loudly if it
  finds zero allowlist sites, because that means the assumption is stale.
- **The `kv_transfer_params` field name** the proxy threads from prefill to
  decode. Could not be confirmed against an installed vLLM; made configurable
  via `PD_HANDOFF_FIELD` rather than guessed silently.
- **The NIXL Python API surface** used by the verify scripts — partially
  grounded, partially inferred. Failures surface as `AttributeError`, not as
  silent passes.
- **Which `ionic_*` device is which physical port on each host.** The indices
  are *not* symmetric across machines; only the first two line up. Must be
  pinned per host.
- **All benchmark numbers** in `BENCHMARKING.md` are order-of-magnitude
  estimates, labelled as such.

---

## 7. Invariants — do not break these

Each guards a **silent** failure: the cluster looks healthy while doing the
wrong thing. This is why several scripts refuse to start.

1. **`nixl_pool_size: 0`** selects LMCache's content-derived-key backend. The
   object-pool backend names objects `obj_{slot}_{uuid4}` — per-process random —
   so prefill and decode derive different keys for identical content and every
   decode lookup misses. Symptom: `LMCache hit tokens: 0`.

2. **The `ldd` self-containment check** on `libplugin_SPDK_NVMe_KV.so`. A
   `DT_NEEDED` on `librte_eal.so` or `libspdk_*.so` makes NIXL's `dlopen()` fail
   *silently* and report only "unsupported backend". This is why SPDK is built
   `--without-shared` and `meson.build` links explicit `.a` paths.

3. **`PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`.** Otherwise vLLM's KV
   tensors cannot be exported over HIP IPC and registration fails.

4. **`NIXL_KV_USE_DEVICE_MAX_VALUE_SIZE` stays unset.** Adopting the
   device-reported ceiling changes on-wire object geometry, and nothing records
   the `sub_size` an object was written with — a reader would reassemble a
   half-stale page without error.

5. **Drain the namespace whenever `KV_MAX_VALUE_SIZE` changes** —
   `scripts/target/50-reset-namespace.sh`. Same root cause as (4).

6. **`UCX_TLS` must include `rocm` and must not include `tcp`.** Without `rocm`,
   UCX loads no ROCm memory domain, reports VRAM as host, and NIXL refuses
   registration with an error blaming a missing ROCm build — misleading, because
   the build has ROCm and `UCX_TLS` configured it out. Without excluding `tcp`,
   RDMA acceptance can pass on a silent TCP fallback. `ib,rocm,self,sm`.

7. **`max_io_qpairs_per_ctrlr = 512`, spelled exactly that way.** SPDK silently
   ignores the older `max_qpairs_per_ctrlr` spelling, leaving the default 127.
   One plugin instance opens all 128 qpairs on its controller, so against a
   shared target the first role to connect takes the whole budget and the second
   is refused — surfacing as `CQ transport error -6` and `NIXL_ERR_BACKEND`
   while LMCache logs a successful store and HTTP returns 200, with **zero bytes
   reaching the device**.

8. **The chunk-size ceiling.** One LMCache chunk is one NIXL object; exceeding
   the controller transfer size fails the store with `NIXL_ERR_BACKEND` and
   takes the server down rather than degrading. Per rank:
   `layers × chunk × (kv_heads/TP) × head_dim × 2 × 2`. Current config is 10 MiB
   against a 16 MiB ceiling — 37% headroom, which is thin. Guarded by
   `scripts/target/05-check-chunk-ceiling.sh`. **`chunk_size` is part of the
   cache key, so both roles must use the same value** or the receiver silently
   re-prefills.

9. **Startup preconditions in `start-vllm.sh`** — target reachable, LMCache
   config validated, side channel not loopback, RDMA access confirmed in RDMA
   mode. Without them vLLM serves from local cache only and disaggregation does
   nothing while appearing correct.

---

## 8. Known measurement trap

**vLLM's own prefix cache sits upstream of the connector layer.** If it hits, no
connector is consulted — LMCache included. With a large GPU KV cache,
same-endpoint repeats are served by vLLM and the whole KV tier looks dead
regardless of configuration. This confound invalidated every earlier retrieve
measurement on the reference deployment.

A valid reuse number is therefore **cross-instance** (decode loading what
prefill stored) or same-instance only after genuine eviction. Confirm with a
non-zero `need to load:` and a non-zero `External prefix cache hit rate` in the
logs — never with the presence of a flag.

`scripts/bench/20-bench-prefix-cache.sh` currently sends the same context twice
to the same endpoint and is therefore subject to this. The warning and a
`--confirm-connector-hit` mode are in place; restructuring the benchmark is
TODO 1.13.

---

## 9. How to resume

1. `scripts/common/init-creds.sh 4`, populate it, confirm
   `source config/cluster.env` resolves real addresses.
2. Work [TODO.md §2](TODO.md) — hardware bring-up. The architecture correction
   (§1) is complete; the remaining blockers are physical.
3. Follow [BRINGUP.md](BRINGUP.md).

The first three things likely to bite, in order: the LMCache allowlist patch
against whatever version actually installs; the `kv_transfer_params` field name;
and the per-host `ionic_*` device mapping.
