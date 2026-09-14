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

THREADING kv_transfer_params (F1's NixlConnector handoff): a max_tokens=1
priming request alone populates the LMCache L2 tier, but it does NOT, on
its own, trigger a direct NixlConnector transfer — that requires the
handoff metadata NixlConnector returns in the PRODUCER's (prefill's)
response to be threaded into the CONSUMER's (decode's) request body. This
proxy extracts that field (name configurable via PD_HANDOFF_FIELD, default
"kv_transfer_params" — see Config.pd_handoff_field's own comment for why
this is configurable rather than hardcoded) from prefill's JSON response
and merges it into the request forwarded to decode. Without this step, the
direct P->D leg silently never fires even with PD_ENABLED=1 on both roles
— requests still succeed (LMCache/recompute cover the miss), which is
exactly the kind of "looks fine, isn't" failure this repo has hit before.
The Stats.prefill_no_handoff counter (surfaced at /status) exists to catch
this: a nonzero value there is the signature of a misconfigured direct leg.

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
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import time
import uuid
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


class Config:
    """All values overridable via env var, matching config/cluster.env's
    naming — this process is normally launched by start-proxy.sh, which
    sources cluster.env first and exports these, but every default here
    matches cluster.env's own default so the proxy is also runnable
    standalone for local testing without that plumbing.
    """

    def __init__(self) -> None:
        self.prefill_host = os.environ.get("PREFILL_HOST", "REDACTED-ADDR")
        self.prefill_port = int(os.environ.get("PREFILL_PORT", "8100"))
        self.decode_host = os.environ.get("DECODE_HOST", "REDACTED-ADDR")
        self.decode_port = int(os.environ.get("DECODE_PORT", "8200"))
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
        # metadata (memory descriptors etc.) in a completion response, and
        # the field decode's request body must carry it back under to
        # trigger a direct load (F1). This could not be independently
        # verified against a specific installed vLLM version at the time
        # this was written, so rather than hardcode a guessed name and fail
        # silently if it's wrong, it is a configurable env var — see
        # config/cluster.env's PD_HANDOFF_FIELD, which this default matches.
        self.pd_handoff_field = os.environ.get("PD_HANDOFF_FIELD", "kv_transfer_params")

    @property
    def prefill_base(self) -> str:
        return f"http://{self.prefill_host}:{self.prefill_port}"

    @property
    def decode_base(self) -> str:
        return f"http://{self.decode_host}:{self.decode_port}"


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
    path: str,
    body: dict[str, Any],
    req_id: str,
) -> Any | None:
    """Best-effort: send a max_tokens=1, stream=false copy of the request to
    the prefill node so it runs the prompt forward pass and populates the
    shared LMCache/NIXL KV store. Never raises — a prefill failure is
    logged and counted, not propagated, per this module's docstring.

    Returns the value of cfg.pd_handoff_field from prefill's JSON response
    (NixlConnector's P->D handoff metadata, F1), or None if prefill failed,
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

    timeout = ClientTimeout(total=cfg.prefill_timeout_sec)
    try:
        async with session.post(
            f"{cfg.prefill_base}{path}",
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
            if handoff is None:
                stats.prefill_no_handoff += 1
                log.warning(
                    "[%s] prefill response has no '%s' field — this is the "
                    "signature of a misconfigured direct P->D leg (check "
                    "PD_ENABLED / gen-kv-transfer-config.sh's output, or "
                    "override PD_HANDOFF_FIELD if this installed vLLM names "
                    "the field differently); decode will fall back to its "
                    "own LMCache lookup/recompute for this request",
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
    """
    timeout = ClientTimeout(
        total=None,
        sock_connect=cfg.decode_connect_timeout_sec,
        sock_read=cfg.decode_read_timeout_sec,
    )
    async with session.post(
        f"{cfg.decode_base}{path}",
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
        log.info("[%s] %s (prompt priming -> %s, then -> %s)", req_id, path, cfg.prefill_base, cfg.decode_base)

        # Priming and the real decode request are intentionally sequential,
        # not concurrent: the whole point is for prefill's KV chunks to
        # exist in the shared NIXL storage backend BEFORE decode's LMCache
        # lookup runs. Running them concurrently would race decode's lookup
        # against prefill's store and reintroduce the same miss-every-time
        # failure mode this proxy exists to avoid.
        handoff = await _prime_prefill(session, cfg, stats, path, body, req_id)

        # Thread the handoff into decode's request body (F1) — this is
        # what actually triggers a direct NixlConnector load. A separate
        # dict, not a mutation of `body`, so the client's own request body
        # is never altered even if priming somehow ran twice.
        decode_body = dict(body)
        if handoff is not None:
            decode_body[cfg.pd_handoff_field] = handoff

        try:
            return await _stream_decode_response(session, cfg, request, path, decode_body, req_id)
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
        no priming needed, these don't touch the KV cache at all.
        """
        cfg: Config = request.app["cfg"]
        session: ClientSession = request.app["session"]
        timeout = ClientTimeout(total=cfg.health_timeout_sec)
        try:
            async with session.get(f"{cfg.decode_base}{request.path}", timeout=timeout) as upstream:
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

        async def probe(base: str) -> dict[str, Any]:
            timeout = ClientTimeout(total=cfg.health_timeout_sec)
            t0 = time.time()
            try:
                async with session.get(f"{base}/health", timeout=timeout) as resp:
                    await resp.read()
                    return {
                        "healthy": resp.status < 400,
                        "status_code": resp.status,
                        "latency_ms": round((time.time() - t0) * 1000, 1),
                    }
            except Exception as exc:  # noqa: BLE001 - status probe must never raise
                return {"healthy": False, "error": f"{type(exc).__name__}: {exc}"}

        prefill_health, decode_health = await asyncio.gather(
            probe(cfg.prefill_base), probe(cfg.decode_base)
        )
        return web.json_response(
            {
                "prefill": {"base_url": cfg.prefill_base, **prefill_health},
                "decode": {"base_url": cfg.decode_base, **decode_health},
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
        "disagg_proxy starting on 0.0.0.0:%d (prefill=%s decode=%s)",
        cfg.proxy_port,
        cfg.prefill_base,
        cfg.decode_base,
    )
    web.run_app(app, host="0.0.0.0", port=cfg.proxy_port, print=None)


if __name__ == "__main__":
    main()
