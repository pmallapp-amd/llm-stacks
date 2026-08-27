# `validation/hip-ipc` — cross-process HIP IPC capability probe

Answers one question about a host: **can two concurrent multi-process GPU groups each establish
HIP IPC / P2P handles?** On the MI300X CIRRASCALE cluster the answer is **no** — and this 13-line
probe is the minimal reproduction of that, with no vLLM, no NIXL and no connector layer involved.

This is the reproducer to hand to AMD. See `docs/escalation-kernel-p2p.md`.

## The bug it reproduces

`hipIpcGetMemHandle` returns `invalid argument` (RCCL `p2p_tmp.cc:283`) for the **second**
concurrent multi-process GPU group on a host. Established 2026-08-17 on
`<SETUP3_PREFILL_NODE>`, kernel `6.8.0-136-generic`, RCCL `2.30.4-HEAD:2b22ab0`.

**The rule is: at most ONE group may hold IPC/P2P handles.** A group that never requests them
does not consume the slot:

| group A (starts first) | group B | B result |
|---|---|---|
| P2P enabled | P2P enabled | FAIL — `hipIpcGetMemHandle failed : invalid argument` |
| **P2P disabled** (`NCCL_P2P_DISABLE=1`) | **P2P enabled** | **PASS** |
| — (A absent) | P2P enabled | PASS |

Ruled out as explanations: kernel version (6.8 did not fix it — `DMA_BUF` is enabled and the
`cuMem support requires Linux kernel >= 6.8` gate is satisfied), compute/memory partitioning (all
8 GPUs are SPX / NPS1), device masking (a lone group on GPUs 4-7 is healthy), and vLLM itself.

## Usage

Needs any ROCm + torch image (this repo uses `vllm-nixl:rocm`). Run group A holding, then B.

```bash
D="--network host --ipc host --device /dev/kfd --device /dev/dri --group-add video
   --security-opt seccomp=unconfined -v $PWD/validation/hip-ipc:/probe"

# group A — holds its IPC handles for 5 minutes
docker run -d --name ddp-a $D -e HIP_VISIBLE_DEVICES=0,1,2,3 -e HOLD_SEC=300 -e NCCL_DEBUG=WARN \
  vllm-nixl:rocm python3 -m torch.distributed.run --nproc_per_node=4 --master_port=29500 \
  /probe/ddp_probe.py
# wait for "GROUP_OK" in `docker logs ddp-a`, then:

# group B — the one that dies
docker run --rm --name ddp-b $D -e HIP_VISIBLE_DEVICES=4,5,6,7 -e NCCL_DEBUG=WARN \
  vllm-nixl:rocm python3 -m torch.distributed.run --nproc_per_node=4 --master_port=29501 \
  /probe/ddp_probe.py
```

Each group must use a **different `--master_port`**. `HOLD_SEC` keeps a group alive so the next
one starts while it still holds its handles — without it there is no concurrency and both pass.

Success prints `GROUP_OK allreduce_sum=<N>` where N is the number of ranks. Failure prints the
`hipIpcGetMemHandle` warning above and the process exits non-zero.

## Practical mitigation this probe justified

Since only one group must forgo P2P, the P/D split gives the degraded half to **prefill**
(collectives once per prompt) and full XGMI to **decode** (collectives ~80x per forward, every
token) — `bench/pd-disaggregation/deploy-pd-asymmetric-p2p.sh`. Better still, put the two halves
on **different hosts**, where neither has to give anything up: `ROLE=prefill|decode|proxy` in
`bench/pd-disaggregation/deploy-pd-disaggregated.sh`.
