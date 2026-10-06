#!/usr/bin/env python3
"""Calls one tool on AVWE's MCP server, for manual play and smoke tests.

    scripts/mcp_call.py <tool> ['<json args>']   e.g. scripts/mcp_call.py join '{"body": "Mira"}'
    scripts/mcp_call.py --new <tool> [...]       end the saved session and start a new one
    scripts/mcp_call.py --json <tool> [...]      also print the structured result
    scripts/mcp_call.py tools                    list the tools

The first call initialises an MCP session (streamable HTTP, revision
2025-11-25) and keeps its id in tmp/mcp_session, so later calls play the
same body. The server is AVWE_MCP_URL, default http://127.0.0.1:4041/mcp
(`mix run --no-halt` in dev). Prints the tool's text; exits 1 on a tool
error. Standard library only.
"""

import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("AVWE_MCP_URL", "http://127.0.0.1:4041/mcp")
VERSION = "2025-11-25"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSION_FILE = os.path.join(ROOT, "tmp", "mcp_session")
TIMEOUT = 60


def post(message, session=None):
    """POSTs one JSON-RPC message; returns (response message or None, headers)."""
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session:
        headers["Mcp-Session-Id"] = session
        headers["MCP-Protocol-Version"] = VERSION
    request = urllib.request.Request(
        URL, data=json.dumps(message).encode(), headers=headers, method="POST"
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = response.read().decode()
        kind = response.headers.get("Content-Type", "")
        return parse(body, kind, message.get("id")), response.headers


def parse(body, kind, id):
    """The response to `id`, from a JSON body or a server-sent event stream."""
    if not body.strip():
        return None
    if "text/event-stream" not in kind:
        return json.loads(body)
    for event in body.split("\n\n"):
        data = "\n".join(
            line[5:].lstrip() for line in event.splitlines() if line.startswith("data:")
        )
        if data:
            message = json.loads(data)
            if message.get("id") == id:
                return message
    return None


def delete(session):
    request = urllib.request.Request(
        URL,
        headers={"Mcp-Session-Id": session, "MCP-Protocol-Version": VERSION},
        method="DELETE",
    )
    try:
        urllib.request.urlopen(request, timeout=TIMEOUT).read()
    except (urllib.error.URLError, OSError):
        pass


def initialise():
    hello = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": VERSION,
            "capabilities": {},
            "clientInfo": {"name": "mcp_call.py", "version": "1"},
        },
    }
    reply, headers = post(hello)
    if reply is None or "error" in reply:
        sys.exit(f"initialize failed: {reply}")
    session = headers.get("Mcp-Session-Id")
    if not session:
        sys.exit("The server gave no session id.")
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
    os.makedirs(os.path.dirname(SESSION_FILE), exist_ok=True)
    with open(SESSION_FILE, "w") as file:
        json.dump({"url": URL, "session": session, "next_id": 2}, file)
    return {"url": URL, "session": session, "next_id": 2}


def load():
    try:
        with open(SESSION_FILE) as file:
            saved = json.load(file)
        return saved if saved.get("url") == URL else None
    except (OSError, ValueError):
        return None


def save(saved):
    with open(SESSION_FILE, "w") as file:
        json.dump(saved, file)


def request(saved, method, params):
    id = saved["next_id"]
    saved["next_id"] = id + 1
    save(saved)
    reply, _headers = post(
        {"jsonrpc": "2.0", "id": id, "method": method, "params": params}, saved["session"]
    )
    return reply


def call(saved, method, params):
    """Makes a request, starting a new session once if the saved one is gone."""
    try:
        return saved, request(saved, method, params)
    except urllib.error.HTTPError as error:
        if error.code not in (400, 404):
            raise
        print("(The saved session is gone; starting a new one.)", file=sys.stderr)
        saved = initialise()
        return saved, request(saved, method, params)


def main(argv):
    new = "--new" in argv
    show_json = "--json" in argv
    args = [arg for arg in argv if arg not in ("--new", "--json")]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    tool = args[0]
    arguments = json.loads(args[1]) if len(args) > 1 else {}

    saved = load()
    if new and saved:
        delete(saved["session"])
        saved = None
    saved = saved or initialise()

    if tool == "tools":
        saved, reply = call(saved, "tools/list", {})
        for listed in reply["result"]["tools"]:
            print(f"{listed['name']}: {listed.get('description', '')}")
        return 0

    saved, reply = call(saved, "tools/call", {"name": tool, "arguments": arguments})
    if reply is None:
        sys.exit("No answer from the server.")
    if "error" in reply:
        print(f"Error: {reply['error'].get('message')}")
        return 1

    result = reply["result"]
    for content in result.get("content", []):
        if content.get("type") == "text":
            print(content["text"])
    if show_json and "structuredContent" in result:
        print(json.dumps(result["structuredContent"], indent=2))
    return 1 if result.get("isError") else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except urllib.error.URLError as error:
        sys.exit(f"Can't reach the MCP server at {URL}: {error}")
