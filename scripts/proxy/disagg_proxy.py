#!/usr/bin/env python3
"""disagg_proxy.py — minimal async P/D disaggregation router.

Node:          runs wherever scripts/proxy/start-proxy.sh is launched from
               (conventionally SMC2/decode, since PROXY_HOST defaults to
               DECODE_HOST in config/cluster.env — but this process itself
               is host-agnostic; it only needs network reach to both
               upstreams).
Prerequisites: both scripts/prefill/03-start-prefill.sh and
               scripts/decode/03-start-decode.sh are up (the proxy degrades
               gracefully if prefill is down, but decode being down means
               nothing works).
Next step:     none — this is the client-facing entry point. Point OpenAI
               clients at http://<PROXY_HOST>:<PROXY_PORT>/v1/...

WHY a two-hop proxy instead of pointing clients straight at decode: vLLM's
kv-transfer stack (NixlConnector direct P->D transfer, composed with
LMCacheMPConnector as an L2 reuse tier — see config/cluster.env's
"Compute leg (P->D)" section and scripts/common/gen-kv-transfer-config.sh)
is populated by whichever node actually runs the prefill forward pass. If a
client's request went straight to decode, decode would have to do its OWN
prefill (recomputing every prompt token) before it could start generating —
there would be no P/D split happening at all, just two idle-most-of-the-time
servers. Sending a max_tokens=1 "priming" request to the prefill node first
is what makes prefill actually run the prompt forward pass.

THREADING kv_transfer_params (NixlConnector's XpYd handoff) is a THREE-step
handshake, not two. Measured against the installed vLLM 0.26.0+rocm on
2026-09-15, reference implementation
`/app/vllm/tests/v1/kv_connector/nixl_integration/toy_proxy_server.py`:

  1. REQUEST the handoff from prefill. The priming request must carry
     kv_transfer_params={"do_remote_decode": True, "do_remote_prefill":
     False, remote_* : None}. This is what tells NixlConnector's scheduler
     that this request's KV is destined for a remote decode, so it must
     stage the blocks and report where they are.
  2. EXTRACT kv_transfer_params from prefill's JSON response — it comes
     back inverted (do_remote_prefill=True) and populated with
     remote_engine_id / remote_block_ids / remote_host / remote_port /
     remote_request_id / tp_size / remote_num_tokens.
  3. THREAD that object into decode's request body, which is what makes
     decode PULL the KV over the side channel instead of re-prefilling.

Step 1 is the one that is easy to miss and was in fact missing here until
2026-09-15: without it prefill answers perfectly normally and simply
returns NO kv_transfer_params at all, so there is nothing to thread, and
decode silently re-prefills the entire prompt. Every request still
succeeds. The pipeline serves correct text at correct latency while doing
no disaggregation whatsoever — exactly the "looks fine, isn't" failure
this repo's invariants exist to catch. Do not read a missing handoff as
"this deployment doesn't use one"; read it as step 1 not happening.

The Stats.prefill_no_handoff counter (surfaced at /status) exists to catch
this: a nonzero value there is the signature of a misconfigured direct leg.

TRANSPORT PREREQUISITE (separate failure, same symptom class): even with
all three steps correct, decode's loadRemoteMD() will fail
NIXL_ERR_BACKEND unless UCX advertises an address decode can actually
reach — see config/cluster.env's UCX_NET_DEVICES and docs/HANDOFF.md §2.

Degraded-mode philosophy: a prefill failure must not become a client-visible
failure. Worst case without a working prefill leg, decode just does its own
prefill (LMCache miss -> recompute) — slower, but correct. A decode failure,
by contrast, IS fatal to the request: decode is the only thing that ever
produces output tokens. This asymmetry is why prefill errors are logged +
counted but swallowed, while decode errors propagate to the client. A
missing kv_transfer_params handoff follows the SAME philosophy: it is
logged and counted (prefill_no_handoff), never fatal — the direct leg not
firing just means decode falls back to its own LMCache lookup/recompute,
not that the request fails.

FLEET / N-prefill-M-decode UPGRADE SEAM: today this is 1P1D — one prefill
instance, one decode instance. Both fleets are modeled as an EndpointPool
(round-robin over a list[Endpoint]) fed from config/cluster.env's plural
PREFILL_HOSTS/PREFILL_PORTS and DECODE_HOSTS/DECODE_PORTS, which already
default to single-entry lists built from the singular PREFILL_HOST/
PREFILL_PORT/DECODE_HOST/DECODE_PORT. Going to NPMD means:

  1. Add entries to PREFILL_HOSTS/PREFILL_PORTS and/or DECODE_HOSTS/
     DECODE_PORTS in config/cluster.env (or the creds file) — space
     separated, e.g. PREFILL_HOSTS="p1.example p2.example p3.example".
  2. Nothing else. The pool and its round-robin select() already handle
     any N/M — this module does not need structural changes.
  3. One real per-instance knob to remember when standing up the new
     instances themselves (not this proxy's concern, but the reason NPMD
     is a values change and not just "point more hosts at one config"):
     each prefill/decode instance's NIXL side-channel port
     (NIXL_SIDE_CHANNEL_PORT_PREFILL / _DECODE in cluster.env) must be
     unique per instance of that role — base port + instance index — or
     two instances on the same host collide on the out-of-band handshake
     port before RDMA ever gets involved.
"""
from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass
from typing import Any

from aiohttp import (
    ClientConnectorError,
    ClientSession,
    ClientTimeout,
    ServerTimeoutError,
    web,
)

logging.basicConfig(
    level=os.environ.get("PROXY_LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("disagg_proxy")

REQUEST_ID_HEADER = "X-Request-Id"

# Endpoints that trigger the two-hop prefill-prime + decode-stream sequence.
# Both take the same request body shape (OpenAI completions-family schema),
# so they share one handler parameterized by path.
COMPLETION_PATHS = ("/v1/completions", "/v1/chat/completions")


@dataclass(frozen=True)
class Endpoint:
    """One upstream vLLM instance (a single prefill or decode member of the
    fleet). Frozen + hashable so it can key EndpointPool.request_counts
    directly instead of needing a synthetic string key.
    """

    host: str
    port: int

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"


def _split_list_env(value: str) -> list[str]:
    """Space-separated env var -> list of non-empty tokens. Matches how
    cluster.env's plural PREFILL_HOSTS/PREFILL_PORTS etc. are documented
    and quoted (bash word-splitting on an unquoted variable), so a value
    of "h1 h2 h3" parses the same way here as it does when a shell script
    iterates over it with `for h in ${PREFILL_HOSTS}`.
    """
    return [tok for tok in value.split() if tok]


def _parse_fleet(
    hosts_var: str,
    single_host_var: str,
    ports_var: str,
    single_port_var: str,
    default_host: str,
    default_port: int,
    role: str,
) -> list[Endpoint]:
    """Build a role's fleet from the plural env vars, falling back to the
    singular ones when the plurals are absent/empty — mirroring
    config/cluster.env's own PREFILL_HOSTS="${PREFILL_HOSTS:-${PREFILL_HOST}}"
    fallback, done again here so this proxy is also correct when run
    standalone (without start-proxy.sh's export of the plurals) or against
    an older env that only ever set the singular.
    """
    hosts = _split_list_env(os.environ.get(hosts_var, ""))
    if not hosts:
        hosts = _split_list_env(os.environ.get(single_host_var, default_host))

    ports = _split_list_env(os.environ.get(ports_var, ""))
    if not ports:
        ports = _split_list_env(os.environ.get(single_port_var, str(default_port)))

    # Broadcast a single port across N hosts (the common NPD case: many
    # prefill hosts, all vLLM instances on the same port) or a single host
    # across N ports (many instances co-located on one host, distinct
    # ports) — either way 1P1D (both lists length 1) is unaffected.
    if len(hosts) > 1 and len(ports) == 1:
        ports = ports * len(hosts)
    elif len(ports) > 1 and len(hosts) == 1:
        hosts = hosts * len(ports)
    elif len(hosts) != len(ports):
        log.warning(
            "%s: %s has %d entries but %s has %d — pairing element-wise "
            "and dropping the excess; fix the env so these match",
            role,
            hosts_var,
            len(hosts),
            ports_var,
            len(ports),
        )
        n = min(len(hosts), len(ports))
        hosts, ports = hosts[:n], ports[:n]

    return [Endpoint(host=h, port=int(p)) for h, p in zip(hosts, ports)]


class EndpointPool:
    """Round-robin selection over one role's fleet (all-prefill or
    all-decode). At N=1 next() on a 1-element itertools.cycle always
    returns that same element, so behaviour is identical to the old
    single-endpoint Config at 1P1D — this is what makes the fleet a
    values-only upgrade rather than a structural one.

    select() is called once per client request per role (see
    handle_completion) — P and D are selected INDEPENDENTLY of each other,
    each from its own pool, and each selection is reused for that whole
    request's lifecycle rather than re-selected mid-request (so a single
    client request always talks to exactly one prefill instance and one
    decode instance, never a mix).

    Thread-safety: this process runs as a single-threaded aiohttp
    web.run_app (asyncio event loop, no executor/thread pool handling
    requests — see Stats' docstring for the same reasoning about its
    plain-int counters). next() on itertools.cycle plus the dict increment
    below both run to completion within one event-loop tick with no
    `await` in between, so they are already atomic with respect to every
    other coroutine; no threading.Lock is needed here. If this server ever
    became multi-threaded, this method is exactly the seam that would need
    one (guarding both the cycle's internal state and request_counts).
    """

    def __init__(self, endpoints: list[Endpoint]) -> None:
        if not endpoints:
            raise ValueError("EndpointPool requires at least one endpoint")
        self.endpoints = endpoints
        self._cycle = itertools.cycle(endpoints)
        self.request_counts: dict[Endpoint, int] = {ep: 0 for ep in endpoints}

    def select(self) -> Endpoint:
        endpoint = next(self._cycle)
        self.request_counts[endpoint] += 1
        return endpoint


class Config:
    """All values overridable via env var, matching config/cluster.env's
    naming — this process is normally launched by start-proxy.sh, which
    sources cluster.env first and exports these, but every default here
    matches cluster.env's own default so the proxy is also runnable
    standalone for local testing without that plumbing.
    """

    def __init__(self) -> None:
        # The fleet, per role — see EndpointPool's docstring and this
        # module's "FLEET / N-prefill-M-decode UPGRADE SEAM" note above.
        # Today (1P1D) each pool has exactly one Endpoint, built from the
        # singular PREFILL_HOST/PORT and DECODE_HOST/PORT via cluster.env's
        # own PREFILL_HOSTS="${PREFILL_HOSTS:-${PREFILL_HOST}}" fallback
        # (mirrored again in _parse_fleet so this proxy is correct even
        # when run standalone, without cluster.env sourced).
        self.prefill_pool = EndpointPool(
            _parse_fleet(
                "PREFILL_HOSTS",
                "PREFILL_HOST",
                "PREFILL_PORTS",
                "PREFILL_PORT",
                "prefill.invalid",
                8100,
                "prefill",
            )
        )
        self.decode_pool = EndpointPool(
            _parse_fleet(
                "DECODE_HOSTS",
                "DECODE_HOST",
                "DECODE_PORTS",
                "DECODE_PORT",
                "decode.invalid",
                8200,
                "decode",
            )
        )
        self.proxy_port = int(os.environ.get("PROXY_PORT", "8000"))

        # Priming request budget: max_tokens=1 still has to run the FULL
        # prompt forward pass (that's the point), so this must be generous
        # enough for a long-context prefill on an 8x MI300X TP shard, not
        # just "1 token of generation latency". Kept short relative to
        # decode's timeout because a stuck prefill must not stall decode's
        # window: this is a soft priming step, not a required dependency.
        self.prefill_timeout_sec = float(os.environ.get("PROXY_PREFILL_TIMEOUT_SEC", "60"))

        # Decode timeout has no total cap: a real generation can legitimately
        # run for minutes at MAX_MODEL_LEN. sock_connect/sock_read bound the
        # failure modes that actually indicate a dead upstream (nothing
        # answering the TCP handshake, or a connection that goes silent
        # mid-stream) without capping total request duration.
        self.decode_connect_timeout_sec = float(
            os.environ.get("PROXY_DECODE_CONNECT_TIMEOUT_SEC", "10")
        )
        self.decode_read_timeout_sec = float(
            os.environ.get("PROXY_DECODE_READ_TIMEOUT_SEC", "120")
        )

        self.health_timeout_sec = float(os.environ.get("PROXY_HEALTH_TIMEOUT_SEC", "5"))

        # The field name vLLM's NixlConnector uses to carry P->D handoff
        # metadata in a completion response, and the field decode's request
        # body must carry it back under to trigger a direct load.
        # VERIFIED 2026-09-15 against the installed vLLM 0.26.0+rocm: the
        # name is "kv_transfer_params" on both the request and the response
        # side. Kept configurable because this is the single point where a
        # vLLM rename would silently disable disaggregation rather than
        # error — see config/cluster.env's PD_HANDOFF_FIELD.
        self.pd_handoff_field = os.environ.get("PD_HANDOFF_FIELD", "kv_transfer_params")


class Stats:
    """Counters surfaced at /status. Plain ints behind no lock: this process
    is single-threaded asyncio, so increments from within a single event
    loop tick are already atomic with respect to each other — no coroutine
    yields between a read and a write of any counter here.
    """

    def __init__(self) -> None:
        self.total_requests = 0
        self.prefill_failures = 0
        self.decode_failures = 0
        # Prefill answered (HTTP < 400, valid JSON) but the response carried
        # no kv_transfer_params (or whatever PD_HANDOFF_FIELD names) at
        # all. This is NOT a prefill failure — the request itself
        # succeeded — it is the signature of a misconfigured DIRECT leg:
        # NixlConnector not composed into --kv-transfer-config (check
        # PD_ENABLED), or an installed vLLM that names this field
        # differently than PD_HANDOFF_FIELD assumes. A nonzero value here
        # means the direct P->D transfer is silently never firing even
        # though every request still succeeds via LMCache/recompute.
        self.prefill_no_handoff = 0
        self.started_at = time.time()

    def as_dict(self) -> dict[str, Any]:
        return {
            "total_requests": self.total_requests,
            "prefill_failures": self.prefill_failures,
            "decode_failures": self.decode_failures,
            "prefill_no_handoff": self.prefill_no_handoff,
            "uptime_sec": round(time.time() - self.started_at, 1),
        }


def _request_id(request: web.Request) -> str:
    """Propagate the client's request id if given, else mint one. Passed
    to BOTH upstream calls as the same header so prefill's and decode's
    logs for the same client request can be correlated by grepping for it
    on either node.
    """
    return request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex


async def _prime_prefill(
    session: ClientSession,
    cfg: Config,
    stats: Stats,
    endpoint: Endpoint,
    path: str,
    body: dict[str, Any],
    req_id: str,
) -> Any | None:
    """Best-effort: send a max_tokens=1, stream=false copy of the request to
    the prefill node so it runs the prompt forward pass and stages its KV
    blocks for a remote decode. Never raises — a prefill failure is
    logged and counted, not propagated, per this module's docstring.

    `endpoint` is the single prefill instance the caller already selected
    from cfg.prefill_pool for this request (see handle_completion) — P is
    selected independently of D, once, before either upstream call is made.

    Returns the value of cfg.pd_handoff_field from prefill's JSON response
    (NixlConnector's P->D handoff metadata), or None if prefill failed,
    returned unparseable JSON, or the field was simply absent. The caller
    threads a non-None return value into decode's request body — that is
    what actually triggers a direct NixlConnector load rather than just a
    populated LMCache L2 tier.
    """
    primed = dict(body)
    primed["max_tokens"] = 1
    primed["stream"] = False
    # Some callers use max_completion_tokens instead of max_tokens (newer
    # OpenAI chat schema) — set both so the priming request is honored
    # under either name rather than silently doing a full-length generation
    # on the prefill node too.
    primed["max_completion_tokens"] = 1

    # STEP 1 of the XpYd handshake — ASK for the handoff. Without this
    # block prefill runs the prompt perfectly well and returns no
    # kv_transfer_params at all, leaving nothing to thread and making
    # decode re-prefill the whole prompt in silence. The remote_* keys are
    # sent explicitly as None rather than omitted, matching vLLM's own
    # toy_proxy_server.py: this is the producer-side shape of the field,
    # and the response comes back with the same keys populated and the two
    # booleans inverted.
    primed[cfg.pd_handoff_field] = {
        "do_remote_decode": True,
        "do_remote_prefill": False,
        "remote_engine_id": None,
        "remote_block_ids": None,
        "remote_host": None,
        "remote_port": None,
    }

    # Sampling controls the producer cannot honour under max_tokens=1.
    # vLLM rejects min_tokens > max_tokens outright, so a client that sets
    # min_tokens would turn every priming request into an HTTP 400 and
    # disable disaggregation for exactly the long-generation requests that
    # benefit from it most. Dropped from the PRIMING copy only — `body`
    # itself is untouched, so decode still receives them.
    primed.pop("min_tokens", None)
    primed.pop("min_completion_tokens", None)
    # stream=False with stream_options set is a schema error in vLLM.
    primed.pop("stream_options", None)

    timeout = ClientTimeout(total=cfg.prefill_timeout_sec)
    try:
        async with session.post(
            f"{endpoint.base_url}{path}",
            json=primed,
            headers={REQUEST_ID_HEADER: req_id},
            timeout=timeout,
        ) as resp:
            raw = await resp.read()
            if resp.status >= 400:
                stats.prefill_failures += 1
                log.warning(
                    "[%s] prefill priming returned HTTP %d (degraded: "
                    "continuing to decode anyway)",
                    req_id,
                    resp.status,
                )
                return None
            log.debug("[%s] prefill priming OK (HTTP %d)", req_id, resp.status)

            try:
                data = json.loads(raw)
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                stats.prefill_no_handoff += 1
                log.warning(
                    "[%s] prefill response was not valid JSON (%s) — cannot "
                    "extract %s; the direct NIXL leg will not fire for this "
                    "request (LMCache/recompute still cover it)",
                    req_id,
                    exc,
                    cfg.pd_handoff_field,
                )
                return None

            handoff = data.get(cfg.pd_handoff_field) if isinstance(data, dict) else None
            # Falsy, not just None: vLLM returns an empty dict when the
            # connector declined to stage anything (e.g. a prompt shorter
            # than one block). An empty dict threaded into decode's request
            # is worse than none — it looks like a handoff to this proxy's
            # counters while carrying no block ids at all.
            if not handoff:
                stats.prefill_no_handoff += 1
                log.warning(
                    "[%s] prefill response carried no usable '%s' — decode "
                    "will re-prefill this prompt itself. Checked in order: "
                    "(1) is NixlConnector actually in prefill's "
                    "--kv-transfer-config with kv_role=kv_producer; (2) is "
                    "the prompt at least one block long (a short prompt "
                    "legitimately stages nothing); (3) does this vLLM name "
                    "the field something other than PD_HANDOFF_FIELD. Note "
                    "the request DID succeed — a silently non-disaggregating "
                    "pipeline is the failure mode here, not an error",
                    req_id,
                    cfg.pd_handoff_field,
                )
                return None

            log.debug("[%s] captured %s from prefill response", req_id, cfg.pd_handoff_field)
            return handoff
    except (ClientConnectorError, ServerTimeoutError, asyncio.TimeoutError) as exc:
        stats.prefill_failures += 1
        log.warning(
            "[%s] prefill priming failed (%s: %s) — degraded, forwarding to "
            "decode without a primed cache (decode will recompute the "
            "prefill itself; slower but correct)",
            req_id,
            type(exc).__name__,
            exc,
        )
        return None
    except Exception as exc:  # noqa: BLE001 - priming must never take the request down
        stats.prefill_failures += 1
        log.warning("[%s] prefill priming raised unexpected %s: %s", req_id, type(exc).__name__, exc)
        return None


async def _stream_decode_response(
    session: ClientSession,
    cfg: Config,
    endpoint: Endpoint,
    request: web.Request,
    path: str,
    body: dict[str, Any],
    req_id: str,
) -> web.StreamResponse:
    """Forward the ORIGINAL (unmodified) request to decode and relay its
    response back to the client. Handles both streaming (SSE) and
    non-streaming bodies through the same aiohttp.web.StreamResponse so
    there is exactly one code path regardless of the client's `stream` flag
    — no buffering step that would defeat token-by-token SSE delivery.

    `endpoint` is the single decode instance the caller already selected
    from cfg.decode_pool for this request (see handle_completion) — it is
    selected exactly once, before this call, and reused for this whole
    call: there is no re-selection mid-stream, so a request never talks to
    more than one decode instance.
    """
    timeout = ClientTimeout(
        total=None,
        sock_connect=cfg.decode_connect_timeout_sec,
        sock_read=cfg.decode_read_timeout_sec,
    )
    async with session.post(
        f"{endpoint.base_url}{path}",
        json=body,
        headers={REQUEST_ID_HEADER: req_id},
        timeout=timeout,
    ) as upstream:
        response = web.StreamResponse(
            status=upstream.status,
            headers={
                "Content-Type": upstream.headers.get("Content-Type", "application/json"),
                REQUEST_ID_HEADER: req_id,
            },
        )
        await response.prepare(request)
        # iter_any() yields chunks as they arrive off the socket rather than
        # waiting to assemble a complete line/frame — this is what makes SSE
        # ("data: {...}\n\n" per generated token) pass through unbuffered
        # instead of batching several tokens' worth of chunks before the
        # client sees any of them.
        # NOTE: `write()` itself awaits the underlying payload writer (which
        # performs its own backpressure-aware drain), so there is no
        # separate flush step needed here — an explicit extra `.drain()`
        # call after every write is both redundant and, as of aiohttp>=3.9,
        # deprecated. `write()` alone is what keeps this unbuffered.
        async for chunk in upstream.content.iter_any():
            await response.write(chunk)
        await response.write_eof()
        return response


def make_app(cfg: Config, stats: Stats) -> web.Application:
    app = web.Application()
    app["cfg"] = cfg
    app["stats"] = stats

    async def on_startup(app: web.Application) -> None:
        # Single shared ClientSession for the process lifetime: aiohttp
        # pools/reuses connections per session, so upstream connections to
        # prefill/decode are kept warm across requests instead of a fresh
        # TCP+HTTP handshake per call.
        app["session"] = ClientSession()

    async def on_cleanup(app: web.Application) -> None:
        await app["session"].close()

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)

    async def handle_completion(request: web.Request) -> web.StreamResponse:
        cfg: Config = request.app["cfg"]
        stats: Stats = request.app["stats"]
        session: ClientSession = request.app["session"]
        stats.total_requests += 1

        req_id = _request_id(request)
        try:
            body = await request.json()
        except Exception:
            return web.json_response(
                {"error": "request body must be valid JSON"}, status=400
            )

        path = request.path

        # Select P and D INDEPENDENTLY, once each, before either upstream
        # call — never re-selected mid-request. At 1P1D each pool has one
        # endpoint so this is a no-op selection; at NPMD this is the one
        # and only load-balancing decision this request makes.
        prefill_ep = cfg.prefill_pool.select()
        decode_ep = cfg.decode_pool.select()
        log.info(
            "[%s] %s (prompt priming -> %s, then -> %s)",
            req_id,
            path,
            prefill_ep.base_url,
            decode_ep.base_url,
        )

        # Priming and the real decode request are intentionally sequential,
        # not concurrent: the whole point is for prefill's KV chunks to
        # exist in the shared NIXL storage backend BEFORE decode's LMCache
        # lookup runs. Running them concurrently would race decode's lookup
        # against prefill's store and reintroduce the same miss-every-time
        # failure mode this proxy exists to avoid.
        handoff = await _prime_prefill(session, cfg, stats, prefill_ep, path, body, req_id)

        # Thread the handoff into decode's request body (F1) — this is
        # what actually triggers a direct NixlConnector load. A separate
        # dict, not a mutation of `body`, so the client's own request body
        # is never altered even if priming somehow ran twice.
        decode_body = dict(body)
        if handoff is not None:
            decode_body[cfg.pd_handoff_field] = handoff

        try:
            return await _stream_decode_response(
                session, cfg, decode_ep, request, path, decode_body, req_id
            )
        except (ClientConnectorError, ServerTimeoutError, asyncio.TimeoutError) as exc:
            stats.decode_failures += 1
            log.error("[%s] decode request failed (%s: %s) — this IS fatal, "
                      "decode is the only producer of output tokens", req_id,
                      type(exc).__name__, exc)
            return web.json_response(
                {"error": f"decode upstream failed: {exc}", "request_id": req_id},
                status=502,
            )

    async def _proxy_to_decode_get(request: web.Request) -> web.Response:
        """Simple GET pass-through to decode for /v1/models and /health —
        no priming needed, these don't touch the KV cache at all. Still
        goes through the decode pool's round-robin select() so these
        health/model-list calls also spread across an NPMD decode fleet
        rather than always hitting one instance.
        """
        cfg: Config = request.app["cfg"]
        session: ClientSession = request.app["session"]
        decode_ep = cfg.decode_pool.select()
        timeout = ClientTimeout(total=cfg.health_timeout_sec)
        try:
            async with session.get(f"{decode_ep.base_url}{request.path}", timeout=timeout) as upstream:
                data = await upstream.read()
                # NOTE: passed via `headers=`, not the `content_type=` kwarg
                # — aiohttp's Response(content_type=...) parses that string
                # as a bare media type and raises ValueError if it contains
                # a "; charset=" suffix, which is exactly what upstream's
                # own Content-Type header looks like (e.g.
                # "application/json; charset=utf-8"). Passing it straight
                # through as a header avoids aiohttp's re-parsing entirely.
                return web.Response(
                    body=data,
                    status=upstream.status,
                    headers={
                        "Content-Type": upstream.headers.get(
                            "Content-Type", "application/json"
                        )
                    },
                )
        except (ClientConnectorError, ServerTimeoutError, asyncio.TimeoutError) as exc:
            return web.json_response(
                {"error": f"decode upstream unreachable: {exc}"}, status=502
            )

    async def handle_status(request: web.Request) -> web.Response:
        cfg: Config = request.app["cfg"]
        stats: Stats = request.app["stats"]
        session: ClientSession = request.app["session"]

        async def probe(endpoint: Endpoint) -> dict[str, Any]:
            timeout = ClientTimeout(total=cfg.health_timeout_sec)
            t0 = time.time()
            try:
                async with session.get(
                    f"{endpoint.base_url}/health", timeout=timeout
                ) as resp:
                    await resp.read()
                    return {
                        "healthy": resp.status < 400,
                        "status_code": resp.status,
                        "latency_ms": round((time.time() - t0) * 1000, 1),
                    }
            except Exception as exc:  # noqa: BLE001 - status probe must never raise
                return {"healthy": False, "error": f"{type(exc).__name__}: {exc}"}

        async def describe_pool(pool: EndpointPool) -> list[dict[str, Any]]:
            # Fleet report: every endpoint in the pool, its live health,
            # and its round-robin request count so an operator can see
            # balancing actually happening once N/M > 1.
            healths = await asyncio.gather(*(probe(ep) for ep in pool.endpoints))
            return [
                {
                    "base_url": ep.base_url,
                    "request_count": pool.request_counts[ep],
                    **health,
                }
                for ep, health in zip(pool.endpoints, healths)
            ]

        prefill_endpoints, decode_endpoints = await asyncio.gather(
            describe_pool(cfg.prefill_pool), describe_pool(cfg.decode_pool)
        )
        return web.json_response(
            {
                "prefill": {"endpoints": prefill_endpoints},
                "decode": {"endpoints": decode_endpoints},
                "stats": stats.as_dict(),
            }
        )

    for path in COMPLETION_PATHS:
        app.router.add_post(path, handle_completion)
    app.router.add_get("/v1/models", _proxy_to_decode_get)
    app.router.add_get("/health", _proxy_to_decode_get)
    app.router.add_get("/status", handle_status)

    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="override PROXY_PORT env var (default from config/cluster.env)",
    )
    args = parser.parse_args()

    cfg = Config()
    if args.port is not None:
        cfg.proxy_port = args.port

    stats = Stats()
    app = make_app(cfg, stats)

    log.info(
        "disagg_proxy starting on 0.0.0.0:%d (prefill fleet=%s decode fleet=%s)",
        cfg.proxy_port,
        [ep.base_url for ep in cfg.prefill_pool.endpoints],
        [ep.base_url for ep in cfg.decode_pool.endpoints],
    )
    web.run_app(app, host="0.0.0.0", port=cfg.proxy_port, print=None)


if __name__ == "__main__":
    main()
