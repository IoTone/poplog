#!/usr/bin/env python3
"""End-to-end test of the Pop-11 MCP server over the real protocol.

Drives tools/pop11-mcp as an agent client would: initialize, list the
tools, run code, define a procedure and call it from a LATER request
(the whole point of the server -- one live session, natively compiled),
survive a mishap, refuse structurally incomplete code, look up
documentation, and answer a bad method properly.

    python3 tools/mcp/test-e2e.py
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVER = os.path.join(REPO, "tools", "pop11-mcp")

failures = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name
          + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


class Mcp:
    """One message per line, which is all MCP stdio framing is."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL)
        self.next_id = 1

    def request(self, method, params=None):
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.next_id += 1
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return json.loads(line) if line else None

    def raw(self, text):
        self.proc.stdin.write((text + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return json.loads(line) if line else None

    def call(self, tool, args):
        return self.request("tools/call", {"name": tool, "arguments": args})

    def text(self, reply):
        try:
            return reply["result"]["content"][0]["text"]
        except (KeyError, IndexError, TypeError):
            return ""

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def main():
    mcp = Mcp()

    r = mcp.request("initialize", {"protocolVersion": "2024-11-05"})
    check("initialize", r and r["result"]["serverInfo"]["name"] == "pop11-mcp", r)
    check("protocol version echoed",
          r["result"]["protocolVersion"] == "2024-11-05", r)

    r = mcp.request("tools/list")
    names = {t["name"] for t in r["result"]["tools"]}
    check("tools/list", {"pop11_eval", "pop11_help", "pop11_state"} <= names,
          sorted(names))

    r = mcp.call("pop11_eval", {"code": "npr(19 + 23);"})
    check("eval prints", mcp.text(r).strip() == "42", mcp.text(r))

    # The session persists: define here, call in the next request.
    mcp.call("pop11_eval", {"code": "define sq(n); lvars n; n * n enddefine;"})
    r = mcp.call("pop11_eval", {"code": "sq(12) =>"})
    check("session persists across requests", "144" in mcp.text(r), mcp.text(r))

    # A mishap comes back as a tool error, and the server keeps going.
    r = mcp.call("pop11_eval", {"code": "hd(3);"})
    check("mishap -> isError", r["result"].get("isError") is True, r["result"])
    check("mishap text names it", "LIST NEEDED" in mcp.text(r), mcp.text(r))
    r = mcp.call("pop11_eval", {"code": "sq(5) =>"})
    check("session survived the mishap", "25" in mcp.text(r), mcp.text(r))

    # Structurally incomplete code never reaches the compiler.
    r = mcp.call("pop11_eval", {"code": "npr('oops);"})
    check("incomplete code refused", "refused" in mcp.text(r), mcp.text(r))
    check("refusal says why", "unterminated string" in mcp.text(r), mcp.text(r))
    r = mcp.call("pop11_eval", {"code": "sq(3) =>"})
    check("session survived the refusal", "9" in mcp.text(r), mcp.text(r))

    r = mcp.call("pop11_help", {"name": "npr"})
    check("help lookup", "HELP NPR" in mcp.text(r), mcp.text(r)[:60])

    r = mcp.call("pop11_state", {})
    check("state reports evals", "evals:" in mcp.text(r), mcp.text(r)[:60])

    r = mcp.call("nosuchtool", {})
    check("unknown tool", "unknown tool" in mcp.text(r), mcp.text(r))

    r = mcp.request("nope/nope")
    check("unknown method -> -32601", r["error"]["code"] == -32601, r)

    r = mcp.raw("{ this is not json")
    check("bad json -> -32700", r["error"]["code"] == -32700, r)
    r = mcp.call("pop11_eval", {"code": "sq(4) =>"})
    check("still serving after a parse error", "16" in mcp.text(r), mcp.text(r))

    mcp.close()
    check("clean exit", mcp.proc.returncode == 0, mcp.proc.returncode)

    print()
    if failures:
        print(f"SUMMARY: {len(failures)} FAILURES: " + ", ".join(failures))
        return 1
    print("SUMMARY: ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
