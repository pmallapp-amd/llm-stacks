#!/usr/bin/env python3
"""Teach vLLM's MoRIIOConnector the [num_blocks, 2, ...] KV-cache layout.

WHY THIS EXISTS
---------------
MoRIIOConnector hardcodes the legacy non-MLA KV-cache layout

    [2 (k and v), num_blocks, block_size, kv_heads, head_dim]

but in vLLM 0.23 every attention backend that may be used *with a KV
connector* returns the transposed

    [num_blocks, 2 (k and v), block_size, kv_heads, head_dim]

(flash_attn, flashinfer, flex_attention, rocm_aiter_fa,
rocm_aiter_unified_attn, triton_attn). The one backend that still returns the
legacy layout, ROCM_ATTN, is rejected outright the moment a KV connector is
configured:

    ValueError: Selected backend AttentionBackendEnum.ROCM_ATTN is not valid
    for this configuration. Reason: ['KV connector not supported']

So the layout the connector assumes is UNREACHABLE, and the KV handoff is
silently corrupt for every non-MLA (MHA/GQA) model.

The mismatch is silent because `block_shape = shape[-3:]` is
(block_size, kv_heads, head_dim) under BOTH layouts, so the connector's
`assert block_size == self.block_size` guard passes either way. What actually
breaks:

  * `self.num_blocks = shape[1]` reads the k/v dimension, yielding 2.
  * In `_compute_block_transfer_offsets`, stride[0] and stride[1] swap meaning.
    The code takes stride[0] as the k->v stride and stride[1] as the block
    stride; under the new layout stride[0] IS the block stride and stride[1] IS
    the k->v stride. Every block is then read from roughly half its correct
    offset, with K and V interleaved wrongly.

Observed effect before this patch: HTTP 200 with fluent but semantically
unrelated text, differing between runs at temperature=0 (the bad offsets land
in whatever KV happens to occupy that region at the time).

Under the new layout a block's K and V are adjacent *within* that block, so the
remote k->v stride no longer depends on the peer's num_blocks. The
`remote_ktov_stride = block_stride * remote_num_blocks` correction the legacy
layout needed is therefore dropped on the new path — which also makes
heterogeneous prefill/decode num_blocks work by construction rather than by
arithmetic.

The MLA path (3-dim [num_blocks, block_size, latent_dim]) is untouched and was
always correct, which is presumably why this went unnoticed upstream.

Both layouts stay supported: the connector now detects which one it was handed.

Usage (idempotent; exits non-zero and changes nothing if the source moved):
    python3 fix_moriio_kv_layout.py [path/to/moriio_connector.py]
With no argument it locates the file inside the installed vllm package.
"""

import sys

# ── The exact fragments this patch replaces. If any of these stops matching,
#    the connector has been rewritten upstream and this patch must be
#    re-derived rather than force-fitted — hence the hard failure.
OLD_REGISTER = """        else:
            # [2 (k and v), num_blocks, ...]
            self.num_blocks = first_kv_cache.shape[1]
            block_rank = 3  # [block_size, kv_heads, head_dim]
"""

NEW_REGISTER = """        else:
            # Two non-MLA layouts exist in the wild:
            #   legacy : [2 (k and v), num_blocks, block_size, kv_heads, head_dim]
            #   vLLM   : [num_blocks, 2 (k and v), block_size, kv_heads, head_dim]
            # Tell them apart by which of the first two dims is the k/v pair.
            # They are only ambiguous when num_blocks == 2, which no real
            # deployment has; prefer the vLLM layout there, since the legacy one
            # is unreachable whenever a KV connector is configured.
            self.kv_dim_first = first_kv_cache.shape[1] != 2
            self.num_blocks = (
                first_kv_cache.shape[1]
                if self.kv_dim_first
                else first_kv_cache.shape[0]
            )
            block_rank = 3  # [block_size, kv_heads, head_dim]
"""

OLD_OFFSETS = """        else:
            _, blknum, blksize, hn, hs = self.kv_cache_shape
            local_ktov_stride = stride[0]
            block_stride = stride[1]
            remote_ktov_stride = block_stride * remote_moriio_meta.num_blocks
"""

NEW_OFFSETS = """        elif self.kv_dim_first:
            # legacy [2, num_blocks, block_size, kv_heads, head_dim]
            _, blknum, blksize, hn, hs = self.kv_cache_shape
            local_ktov_stride = stride[0]
            block_stride = stride[1]
            # K and V are separate regions, so the distance between them
            # depends on how many blocks the peer allocated.
            remote_ktov_stride = block_stride * remote_moriio_meta.num_blocks
        else:
            # vLLM 0.23 [num_blocks, 2, block_size, kv_heads, head_dim]
            blknum, _, blksize, hn, hs = self.kv_cache_shape
            block_stride = stride[0]
            local_ktov_stride = stride[1]
            # K and V are adjacent inside a block, so this is independent of
            # the peer's num_blocks.
            remote_ktov_stride = local_ktov_stride
"""

# Default for the attribute, so a connector instance that somehow reaches the
# offset code without register_kv_caches() raises AttributeError-free and
# behaves like stock vLLM rather than silently mis-striding.
OLD_INIT = """        self.block_shape = None
"""
NEW_INIT = """        self.block_shape = None
        # Set properly in register_kv_caches(); see fix_moriio_kv_layout.py.
        self.kv_dim_first = False
"""

REPLACEMENTS = [
    ("__init__ layout flag", OLD_INIT, NEW_INIT),
    ("register_kv_caches num_blocks", OLD_REGISTER, NEW_REGISTER),
    ("_compute_block_transfer_offsets strides", OLD_OFFSETS, NEW_OFFSETS),
]

MARKER = "self.kv_dim_first"


def default_target():
    import vllm  # noqa: PLC0415  (deliberately lazy: only needed for autodetect)
    from pathlib import Path

    return str(
        Path(vllm.__file__).parent
        / "distributed/kv_transfer/kv_connector/v1/moriio/moriio_connector.py"
    )


def main(argv):
    target = argv[1] if len(argv) > 1 else default_target()

    with open(target, encoding="utf-8") as fh:
        src = fh.read()

    if MARKER in src:
        print(f"OK: {target} already patched (found {MARKER!r}); nothing to do")
        return 0

    for label, old, new in REPLACEMENTS:
        count = src.count(old)
        if count != 1:
            sys.exit(
                f"ERR: {label}: expected exactly 1 occurrence of the anchor in\n"
                f"     {target}\n"
                f"     found {count}. The upstream connector has changed; "
                f"re-derive this patch instead of forcing it.\n"
                f"     Anchor was:\n{old}"
            )
        src = src.replace(old, new, 1)

    with open(target, "w", encoding="utf-8") as fh:
        fh.write(src)

    print(f"OK: patched {target} for the [num_blocks, 2, ...] KV-cache layout")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
