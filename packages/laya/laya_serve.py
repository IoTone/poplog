"""Serve laya-mlx typed decisions to other processes: the Python half of Poplog's LIB LAYA.

    uv run --project packages/laya python packages/laya/laya_serve.py --stdio [options]
    uv run --project packages/laya python packages/laya/laya_serve.py --port 8765 [options]

Built on laya-mlx's public API (`Agent`, `Router`), pinned and unmodified in pyproject.toml.
Two transports share one handler, both taking the `POST /v1/systemone` request shape:

- stdio: one JSON-RPC 2.0 message per line (`systemone` and `health` methods). The parent owns
  the child's lifetime; end of input ends the server. This is what LIB LAYA runs.
- HTTP: `POST /v1/systemone` and `GET /v1/health` on a loopback port, so clients written for
  the hosted API only change their base URL. There is no authentication; keep it on loopback.

The response is `Agent.system_one`'s payload with `model` replaced by the checkpoint that
answered (id, resolved commit, subfolder, dtype), because that is what a stored result needs to
be reproducible. laya-mlx itself always says "laya-rl-agent".
"""

import argparse
import ipaddress
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

from laya_mlx.agent import DTYPES

INVALID_REQUEST = 422
INTERNAL_ERROR = 500
# JSON-RPC codes; `data.status` carries the HTTP-equivalent status for clients that share
# error handling with the HTTP transport.
RPC_PARSE_ERROR, RPC_INVALID_REQUEST, RPC_METHOD_NOT_FOUND = -32700, -32600, -32601
RPC_INVALID_PARAMS, RPC_INTERNAL_ERROR = -32602, -32603


class RequestError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def checkpoint(agent):
    """What produced an answer: id, resolved Hub commit and subfolder when known, and dtype.

    A Hub download lives at .../snapshots/<commit>/<subfolder>, so the path says exactly which
    revision was loaded even when none was asked for.
    """
    parts = agent.model_dir.parts
    if "snapshots" in parts[:-1]:
        at = parts.index("snapshots")
        name = agent.model_id + "@" + "/".join(parts[at + 1 :])
    else:
        name = str(agent.model_dir)  # a local directory is its own identity
    dtype = next((k for k, v in DTYPES.items() if v == agent.dtype), str(agent.dtype))
    return "%s %s" % (name, dtype)


class Service:
    """Validate a request, answer it, and name the checkpoint that answered."""

    def __init__(self, predictor):
        self.predictor = predictor

    def checkpoint(self, result=None):
        # A Router names its routed checkpoint in `routing`; ask it for that loaded Agent.
        if result is not None and "routing" in result:
            return checkpoint(self.predictor.load(result["routing"]["model"]))
        if hasattr(self.predictor, "model_dir"):
            return checkpoint(self.predictor)
        return "laya-router"

    def health(self):
        return {"status": "ok", "model": self.checkpoint()}

    def systemone(self, request):
        if not isinstance(request, dict):
            raise RequestError(INVALID_REQUEST, "request must be a JSON object")
        if "state" not in request:
            raise RequestError(INVALID_REQUEST, 'request is missing "state"')
        questions = request.get("questions")
        if not isinstance(questions, dict) or not questions:
            raise RequestError(INVALID_REQUEST, '"questions" must be a nonempty JSON object')
        try:
            result = self.predictor.predict(request["state"], questions)
        except (ValueError, TypeError, KeyError) as error:
            raise RequestError(INVALID_REQUEST, str(error)) from error
        result["model"] = self.checkpoint(result)
        return result


def _status_of(error):
    return error.status if isinstance(error, RequestError) else INTERNAL_ERROR


def _rpc_error(ident, code, message, status):
    error = {"code": code, "message": message, "data": {"status": status}}
    return {"jsonrpc": "2.0", "id": ident, "error": error}


def handle_rpc(service, line):
    """Answer one JSON-RPC line. Never raises: every failure becomes an error response."""
    try:
        message = json.loads(line)
    except ValueError as error:
        return _rpc_error(None, RPC_PARSE_ERROR, "parse error: %s" % error, INVALID_REQUEST)
    if not isinstance(message, dict) or not isinstance(message.get("method"), str):
        return _rpc_error(None, RPC_INVALID_REQUEST, "not a JSON-RPC request", INVALID_REQUEST)
    ident, method = message.get("id"), message["method"]
    try:
        if method == "systemone":
            result = service.systemone(message.get("params"))
        elif method == "health":
            result = service.health()
        else:
            return _rpc_error(ident, RPC_METHOD_NOT_FOUND, "unknown method " + method, 404)
    except Exception as error:  # noqa: BLE001 - a server must answer, not die
        status = _status_of(error)
        code = RPC_INVALID_PARAMS if status == INVALID_REQUEST else RPC_INTERNAL_ERROR
        return _rpc_error(ident, code, "%s: %s" % (type(error).__name__, error), status)
    return {"jsonrpc": "2.0", "id": ident, "result": result}


def serve_stdio(service, stdin=None, stdout=None):
    """Read requests from stdin until end of input, one response line per request line."""
    if stdout is None:
        # The protocol owns the real stdout. Anything else that prints -- a library warning,
        # a stray print, C code writing to fd 1 -- is moved to stderr so it cannot corrupt it.
        stdout = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", newline="\n")
        sys.stdout.flush()
        os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    stdin = sys.stdin.buffer if stdin is None else stdin
    for raw in stdin:
        line = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
        if not line.strip():
            continue
        response = handle_rpc(service, line)
        stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        stdout.flush()


def make_http_server(service, host="127.0.0.1", port=8765, verbose=False):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "laya-mlx"

        def _send(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _error(self, status, message):
            self._send(status, {"error": {"status": status, "message": message}})

        def do_GET(self):
            if self.path.rstrip("/") in ("/v1/health", "/health"):
                self._send(200, service.health())
            else:
                self._error(404, "not found: " + self.path)

        def do_POST(self):
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                self._error(411, "Content-Length required")
                return
            body = self.rfile.read(int(length))
            if self.path.rstrip("/") not in ("/v1/systemone", "/systemone"):
                self._error(404, "not found: " + self.path)
                return
            try:
                request = json.loads(body)
            except ValueError as error:
                self._error(INVALID_REQUEST, "request is not JSON: %s" % error)
                return
            try:
                self._send(200, service.systemone(request))
            except Exception as error:  # noqa: BLE001 - report it to the client, keep serving
                self._error(_status_of(error), "%s: %s" % (type(error).__name__, error))

        def log_message(self, format, *args):
            if verbose:
                super().log_message(format, *args)

    return HTTPServer((host, port), Handler)


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def serve_http(service, host="127.0.0.1", port=8765, verbose=False):
    if not is_loopback(host):
        print(
            "laya_serve: %s is not a loopback address; this endpoint has no "
            "authentication, so anyone who can reach it can use the model" % host,
            file=sys.stderr,
        )
    server = make_http_server(service, host, port, verbose)
    print(
        "laya_serve: %s on http://%s:%d/v1/systemone"
        % (service.checkpoint(), host, server.server_port),
        file=sys.stderr,
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument(
        "--stdio", action="store_true", help="JSON-RPC 2.0, one message per line"
    )
    transport.add_argument("--port", type=int, help="HTTP port for POST /v1/systemone")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--model", default="aac6fef/laya-mlx", help="Hub id or local directory")
    parser.add_argument("--subfolder")
    parser.add_argument("--revision")
    parser.add_argument("--dtype", choices=DTYPES, default="float16")
    parser.add_argument("--device", choices=("gpu", "cpu"), default="gpu")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument(
        "--router",
        action="store_true",
        help="route by language across the three checkpoints (ignores --model)",
    )
    parser.add_argument("--verbose", action="store_true", help="log HTTP requests")
    args = parser.parse_args(argv)

    if args.router:
        from laya_mlx import Router

        # Keep every routed checkpoint resident: a long-lived server that reloads weights
        # whenever the input language changes would spend seconds per switch.
        predictor = Router(dtype=args.dtype, device=args.device, max_loaded=3)
    else:
        from laya_mlx import Agent

        predictor = Agent(
            args.model,
            device=args.device,
            dtype=args.dtype,
            revision=args.revision,
            subfolder=args.subfolder,
            batch_size=args.batch_size,
        )
    service = Service(predictor)
    if args.stdio:
        serve_stdio(service)
    else:
        serve_http(service, args.host, args.port, args.verbose)


if __name__ == "__main__":
    main()
