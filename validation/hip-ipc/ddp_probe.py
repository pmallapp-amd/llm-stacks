import os, sys, time, torch, torch.distributed as dist

lr = int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(lr)
dist.init_process_group(backend="nccl")
r = dist.get_rank()
t = torch.ones(1024, device=f"cuda:{lr}")
dist.all_reduce(t)
torch.cuda.synchronize()
if r == 0:
    print(f"GROUP_OK allreduce_sum={int(t[0].item())}", flush=True)
time.sleep(int(os.environ.get("HOLD_SEC", "0")))
dist.destroy_process_group()
