# patches/spdk/ — NVIDIA NVMe Key-Value command-set patches

All four patches are authored by Ben Walker `<ben@nvidia.com>` and tracked
upstream on the public SPDK Gerrit review queue
(<https://review.spdk.io/q/topic:kv>). **There is no private fork.** An
earlier version of this repo's `config/cluster.env` pointed a `KV_SPDK_REPO`
"fork URL" at nothing and treated its absence as a hard blocker for
`scripts/target/02-build-spdk-kv.sh` — that described a tree that never
existed. These are upstream-bound patches, some already merged, some still
in review; this repo carries the ones that have not merged yet as local
`.patch` files applied with `git am` at build time.

Status verified 2026-09-14. **Re-check
<https://review.spdk.io/q/topic:kv+status:open> before relying on this
table** — 0002/0003 may merge into v26.09 at any point, at which point they
become as redundant as 0001/0004 already are on current master.

## Per-patch status

| # | Subject | Gerrit | Change-Id | Status | Upstream commit | SPDK base |
|---|---|---|---|---|---|---|
| 0001 | nvme: recognize KV command set namespaces | [28260](https://review.spdk.io/c/spdk/spdk/+/28260) | `Ie7975a8a33f7915eca99586d1120e25895ca1889` | **MERGED** 2026-08-25 | `8dc83278ab3cac12ca47d349eb7b73cbd62b6d96` | v26.05 (pre-merge only) |
| 0002 | bdev/kvmalloc: add a malloc-like bdev that supports the KV command set | [27889](https://review.spdk.io/c/spdk/spdk/+/27889) | `I24736dd9cce0d33310a7072aa390b9d3ec591323` | **OPEN** — CR+2, Verified+1, mergeable, 0 unresolved, patch set 26, hashtag `26.09` | — | any (target-side, always needed until merged) |
| 0003 | nvmf: add KV namespace support | [28298](https://review.spdk.io/c/spdk/spdk/+/28298) | `Ic23fcd8585411397935ba51532e263768f533076` | **OPEN** — CR+2 from two reviewers, Verified+1, mergeable, 0 unresolved, patch set 21, hashtag `26.09`; depends on 0002 | — | any (target-side, always needed until merged) |
| 0004 | nvme: add a unit test suite for the KV command set | [27886](https://review.spdk.io/c/spdk/spdk/+/27886) | `Ibe4ada04757aec20c4fb191e6052d0a19da75a72` | **MERGED** 2026-08-25 | `b12a3728d073de4577e12fd4e3296a16747fc900` | v26.05 (pre-merge only) |

## What this means for a build

- **v26.05** (released 2026-05-29) has the NVMe-KV *initiator* API
  (`include/spdk/nvme_kv.h`, `spdk_nvme_kv_{store,retrieve,exist,delete,list}()`)
  but **none** of the four patches above — apply all four, in order, to get
  a KV-capable target from this base.
- **Current master** (`26.09.0-pre` as of this writing) already has 0001 and
  0004 (merged 2026-08-25). Applying them again would fail outright.
  0002/0003 still have not merged and must still be applied.
- **0002 and 0003 are the only patches that matter long-term**: they are the
  target-side pieces (`module/bdev/kvmalloc/`, and `lib/nvmf/ctrlr.c` /
  `lib/nvmf/subsystem.c`'s KV opcode routing) that make a stock `nvmf_tgt`
  capable of serving a KV namespace at all. 0001/0004 are initiator-side
  conveniences (CSI recognition on the bdev layer, unit tests) that this
  repo's target build does not strictly require once 0002/0003 are in
  place, but that ship as part of the same patch series.

`scripts/target/02-build-spdk-kv.sh` does not decide which patches to skip
based on the SPDK base name or ref — it detects, by content, whether each
patch's effect is already present in the checked-out tree (e.g. `grep -q
SPDK_NVME_CSI_KV module/bdev/nvme/bdev_nvme.c` for 0001, `[ -d
module/bdev/kvmalloc ]` for 0002) and applies only what is missing. This is
correct regardless of whether `SPDK_TARGET_REF` (`config/cluster.env`)
points at v26.05, master, or something in between.

## Apply order

Apply in numeric order — 0003 depends on 0002 (nvmf KV routing calls into
the bdev module 0002 adds), and while 0001/0004 do not have a hard
dependency on the others, the numeric order matches the order they were
authored and reviewed upstream:

```
cd "${SPDK_TARGET_SRC}"
git am patches/spdk/0001-spdk-nvme-recognize-kv-namespaces.patch   # skip if already upstream
git am patches/spdk/0002-spdk-bdev-kvmalloc.patch
git am patches/spdk/0003-spdk-nvmf-kv-namespace.patch
git am patches/spdk/0004-spdk-nvme-kv-unit-tests.patch             # skip if already upstream
```

`scripts/target/02-build-spdk-kv.sh` does this automatically, including the
skip-if-already-present detection above.
