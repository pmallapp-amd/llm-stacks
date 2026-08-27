# moriio_proxy_health.py — run vLLM's moriio_toy_proxy_server with a /health route.
#
# Why this exists: bench/tracks.registry's contract requires a track to answer a
# readiness probe at /health (bench/llama-benchy/run.sh falls back to /status for
# disagg_proxy_demo.py-fronted tracks). vLLM's moriio_toy_proxy_server.py — the
# reference proxy for MoRIIOConnector, vendored beside this file — exposes only
# /v1/completions, /v1/chat/completions, /start_profile and /stop_profile. It
# 404s on /health, /status AND /v1/models, so every readiness probe this repo
# knows about concludes a perfectly healthy MoRIIO proxy is down, and
# llama-benchy re-runs the deploy script on top of a running deployment.
#
# Rather than fork the upstream proxy (which would have to be re-synced with
# every vLLM bump), this imports it unmodified and adds one route. The upstream
# file's app.run() is guarded by `if __name__ == "__main__"`, so importing it is
# side-effect-free apart from module-level globals; this module owns startup.
#
# Readiness semantics deliberately match what the proxy can actually promise:
#   200 — at least one prefill AND one decode instance have registered over the
#         ZMQ discovery socket, i.e. a request can be served end to end.
#   503 — the proxy is listening but one or both legs have not registered yet.
#         This is the state during vLLM startup, and it is exactly what a
#         readiness probe should report as "not ready" rather than "ready".
# Both are the truth as the proxy sees it. /status returns the same body with
# 200 unconditionally, for a human debugging which leg failed to register.
#
# Run (from 02-deploy-mori-pd.sh, inside the vLLM image — the upstream proxy
# imports vllm.distributed...moriio_common, so it cannot run outside it):
#   python3 /proxy/moriio_proxy_health.py --port 9000 --discovery-port 36367
import argparse
import sys

try:
    import moriio_toy_proxy_server as toy
except ImportError as exc:  # pragma: no cover - surfaced at container start
    sys.exit(
        f"ERR: cannot import moriio_toy_proxy_server ({exc}).\n"
        "     It must sit beside this file on PYTHONPATH, and this must run\n"
        "     inside the vLLM image (it imports vllm.distributed...moriio_common)."
    )

app = toy.app


def _registered():
    with toy._list_lock:
        return len(toy.prefill_instances), len(toy.decode_instances)


def _body(n_prefill, n_decode):
    return {
        "prefill_instances": n_prefill,
        "decode_instances": n_decode,
        "ready": bool(n_prefill and n_decode),
        "kv_connector": "MoRIIOConnector",
    }


@app.route("/health", methods=["GET"])
async def health():
    n_prefill, n_decode = _registered()
    body = _body(n_prefill, n_decode)
    return (body, 200 if body["ready"] else 503)


@app.route("/status", methods=["GET"])
async def status():
    n_prefill, n_decode = _registered()
    return (_body(n_prefill, n_decode), 200)


def main():
    parser = argparse.ArgumentParser(
        description="moriio_toy_proxy_server + a /health readiness route"
    )
    parser.add_argument("--port", type=int, default=9000,
                        help="client-facing OpenAI-compatible port")
    parser.add_argument("--discovery-port", type=int, default=36367,
                        help="ZMQ port prefill/decode instances register on; "
                             "must equal each instance's proxy_ping_port")
    args = parser.parse_args()

    # Upstream hardcodes 36367 in its own __main__; we make it an argument so
    # the deploy script can move it off a port already in use.
    listener = toy.start_service_discovery("0.0.0.0", args.discovery_port)
    app.config["BODY_TIMEOUT"] = 360000
    app.config["RESPONSE_TIMEOUT"] = 360000
    app.run(host="0.0.0.0", port=args.port)
    listener.join()


if __name__ == "__main__":
    main()
