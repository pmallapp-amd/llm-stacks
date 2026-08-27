# llm-stacks / kv-cache

Scaffolding for benchmarking KV-cache offload in disaggregated LLM serving: build and deploy
scripts for several vLLM connector stacks, plus a small measurement harness.

> **This is a partial subset.** The majority of this project is not published here. Anything
> describing specific storage hardware — device behaviour, failure modes, command-set patches,
> measured performance, and the operating procedures around it — is deliberately excluded, along
> with all results, runbooks and written analysis. What remains is the generic scaffolding.
>
> Consequence worth stating plainly: several scripts here reference files that are not in this
> repo (for example the track registry and the preflight gate). They are not runnable as-is.

## Layout

```
stack/     build/deploy scripts for the connector stacks under test
  tracks/{nixl,lmcache,mooncake,mori,atom}/
bench/     measurement harness
  lib/       profile loader, track resolver, deployment recorder
  profiles/  named run intents (smoke / throughput / correctness)
  llama-benchy/       pp/tg sweep client for any OpenAI-compatible endpoint
  pd-disaggregation/  persistent prefill/decode split behind a proxy
validation/  correctness and health checks, kept separate from benchmarks
tools/       one-shot and watch-mode sync to a remote bench host
```

## Ideas worth stealing

Two conventions here are the reusable part, independent of any hardware:

**A run is `benchmark × track × profile × host`, all four declared rather than remembered.** Tracks
are selected by *name* through a registry, never by relative path, so a benchmark never hardcodes
the stack it measures — swapping the transfer layer is a one-word change.

**Configurations that would produce a misleading number are refused, not warned about.** A run
carries a named *profile* stating its intent, and every result gets a provenance sidecar recording
the verdict, the resolved parameters, and the deployment that served it. A serving benchmark
measures a server it did not configure, so the client and server halves are attested separately —
an unrecorded server config downgrades the verdict rather than being silently assumed.

## Host placeholders

Hosts are referred to by setup-scoped placeholders — never a real hostname, IP, MAC or credential.
A host belongs to a *setup*; its role (`prefill`, `decode`, `target`) is a property **within** that
setup, so `<SETUP3_TARGET_NODE>` and `<SETUP4_TARGET_NODE>` are unrelated machines in different
labs, not two nodes of one cluster.

| Setup | Shape |
|---|---|
| `SETUP2` | `<SETUP2_PD_NODE>` runs prefill **and** decode on one box; `<SETUP2_TARGET_NODE>` is a second host, CPU-only |
| `SETUP3` | 3-node GPU cluster: `<SETUP3_PREFILL_NODE>` / `<SETUP3_DECODE_NODE>` / `<SETUP3_TARGET_NODE>` |
| `SETUP4` | 3-node: `<SETUP4_PREFILL_NODE>` / `<SETUP4_DECODE_NODE>` / `<SETUP4_TARGET_NODE>` (prefill and decode interchangeable) |

Suffixes extend the same name: `_IP`, `_BMC`, `_MAC`.

To point any of this at real machines, copy `lab-inventory.local.env.example` to
`lab-inventory.local.env` and fill in your own values. `*.local.env` and `*.local.md` are
gitignored; no real host data is committed.

## License

See `LICENSE`.
