import io
import json
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

import mlx.core as mx
import pytest
from laya_mlx import Agent

from laya_serve import (
    Service,
    checkpoint,
    handle_rpc,
    is_loopback,
    make_http_server,
    serve_stdio,
)

SERVER = Path(__file__).resolve().parents[1] / "laya_serve.py"


@pytest.fixture
def service(tiny_checkpoint):
    return Service(Agent(tiny_checkpoint, dtype="float32"))


def rpc(service, method, params=None, ident=1):
    message = {"jsonrpc": "2.0", "id": ident, "method": method}
    if params is not None:
        message["params"] = params
    return handle_rpc(service, json.dumps(message))


def test_checkpoint_names_commit_subfolder_and_dtype(tiny_checkpoint):
    agent = Agent(tiny_checkpoint)
    assert checkpoint(agent) == "%s float16" % tiny_checkpoint
    assert checkpoint(Agent(tiny_checkpoint, dtype="float32")).endswith(" float32")
    agent.model_id = "org/laya"
    agent.model_dir = Path("/hub/models--org--laya/snapshots/abc123/multilingual")
    assert checkpoint(agent) == "org/laya@abc123/multilingual float16"
    # laya-mlx itself always says this; only the server substitutes the checkpoint.
    assert agent.predict("hello", {"q": {"type": "noul", "instructions": "?"}})["model"] == (
        "laya-rl-agent"
    )


def test_service_answers_like_predict_and_names_checkpoint(service, questions):
    direct = service.predictor.predict("hello", questions)
    served = service.systemone({"state": "hello", "questions": questions, "model": "jev-latest"})
    assert served["model"] == checkpoint(service.predictor)
    assert served["answers"] == direct["answers"]
    assert served["usage"] == direct["usage"]


@pytest.mark.parametrize(
    "request_body",
    [
        [],
        {"questions": {"q": {"type": "noul", "instructions": "?"}}},
        {"state": "hello"},
        {"state": "hello", "questions": {}},
        {"state": "hello", "questions": {"q": {"type": "maybe", "instructions": "?"}}},
        {"state": "hello", "questions": {"q": {"type": "choice", "instructions": "?"}}},
    ],
)
def test_invalid_requests_are_422_not_500(service, request_body):
    response = rpc(service, "systemone", request_body)
    assert response["error"]["code"] == -32602
    assert response["error"]["data"]["status"] == 422


def test_rpc_framing_errors_and_health(service, questions):
    assert handle_rpc(service, "{not json")["error"]["code"] == -32700
    assert handle_rpc(service, "[1, 2]")["error"]["code"] == -32600
    assert rpc(service, "nope")["error"]["data"]["status"] == 404
    assert rpc(service, "health", ident="h")["result"] == {
        "status": "ok",
        "model": checkpoint(service.predictor),
    }
    ok = rpc(service, "systemone", {"state": "hello", "questions": questions}, ident=7)
    assert ok["id"] == 7 and set(ok["result"]["answers"]) == set(questions)


def test_unexpected_failures_are_500_and_the_server_survives(service, questions):
    def broken(state, qs):
        raise RuntimeError("Metal went away")

    original, service.predictor.predict = service.predictor.predict, broken
    response = rpc(service, "systemone", {"state": "hello", "questions": questions})
    assert response["error"]["code"] == -32603
    assert response["error"]["data"]["status"] == 500
    assert "Metal went away" in response["error"]["message"]
    service.predictor.predict = original
    assert "result" in rpc(service, "systemone", {"state": "hello", "questions": questions})


def test_stdio_one_response_line_per_request_line(service, questions):
    lines = [
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": "health"}),
        "",
        "garbage",
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "systemone",
                "params": {"state": "hello", "questions": questions},
            }
        ),
    ]
    out = io.StringIO()
    serve_stdio(service, stdin=io.StringIO("\n".join(lines) + "\n"), stdout=out)
    responses = [json.loads(line) for line in out.getvalue().splitlines()]
    assert [r["id"] for r in responses] == [1, None, 2]
    assert "error" in responses[1]


def test_stdio_cli_keeps_stdout_clean(tiny_checkpoint, questions):
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "systemone",
        "params": {"state": "hello", "questions": questions},
    }
    proc = subprocess.run(
        [
            sys.executable,
            str(SERVER),
            "--model",
            str(tiny_checkpoint),
            "--dtype",
            "float32",
            "--stdio",
        ],
        input=json.dumps(request) + "\n" + json.dumps({**request, "id": 2}) + "\n",
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )
    responses = [json.loads(line) for line in proc.stdout.splitlines()]
    assert [r["id"] for r in responses] == [1, 2]
    assert responses[0]["result"] == responses[1]["result"]


def test_http_transport(service, questions):
    server = make_http_server(service, port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = "http://127.0.0.1:%d" % server.server_port

    def post(path, payload):
        request = urllib.request.Request(
            base + path,
            data=json.dumps(payload).encode(),
            method="POST",
            headers={"Content-Type": "application/json", "Authorization": "Bearer ignored"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    try:
        status, body = post("/v1/systemone", {"state": "hello", "questions": questions})
        assert status == 200 and body["model"] == checkpoint(service.predictor)
        assert set(body["answers"]) == set(questions)
        status, body = post("/v1/systemone", {"state": "hello"})
        assert status == 422 and "questions" in body["error"]["message"]
        assert post("/v1/elsewhere", {})[0] == 404
        with urllib.request.urlopen(base + "/v1/health", timeout=30) as response:
            assert json.loads(response.read())["status"] == "ok"
    finally:
        server.shutdown()
        server.server_close()


def test_loopback_detection():
    assert is_loopback("127.0.0.1") and is_loopback("::1") and is_loopback("localhost")
    assert not is_loopback("0.0.0.0") and not is_loopback("192.168.1.4")


def test_router_responses_name_the_routed_checkpoint(questions):
    class Loaded:
        def __init__(self, name):
            self.model_id, self.revision, self.dtype = "org/laya", None, mx.float16
            self.model_dir = Path("/hub/models--org--laya/snapshots/abc/%s" % name)

    class FakeRouter:
        def predict(self, state, qs):
            return {
                "model": "laya-rl-agent",
                "answers": {},
                "usage": {},
                "routing": {"model": "multilingual" if not state.isascii() else "english"},
            }

        def load(self, name):
            return Loaded(name)

    service = Service(FakeRouter())
    assert service.health() == {"status": "ok", "model": "laya-router"}
    served = service.systemone({"state": "发票", "questions": questions})
    assert served["model"] == "org/laya@abc/multilingual float16"
    assert service.systemone({"state": "hi", "questions": questions})["model"].endswith(
        "english float16"
    )
