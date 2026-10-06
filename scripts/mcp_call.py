#!/usr/bin/env python3
"""Calls one tool on AVWE's MCP server, for manual play and smoke tests.

    scripts/mcp_call.py <tool> ['<json args>']   e.g. scripts/mcp_call.py join '{"body": "Mira"}'
    scripts/mcp_call.py --new <tool> [...]       end the saved session and start a new one
    scripts/mcp_call.py --json <tool> [...]      also print the structured result
    scripts/mcp_call.py --leave                  leave the body and end the saved session
    scripts/mcp_call.py tools                    list the tools

The first call initialises an MCP session (streamable HTTP, revision
2025-11-25) and keeps its id in tmp/mcp_session (or AVWE_MCP_SESSION_FILE),
so later calls play the same body. When the server no longer knows the
saved session (404), a new one is started once and the call made again;
any other refusal is printed as the server gave it. The server is
AVWE_MCP_URL, default http://127.0.0.1:4041/mcp (`mix run --no-halt` in
dev). Prints the tool's text; exits 1 on a tool error or a refusal.
Standard library only.
"""

import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("AVWE_MCP_URL", "http://127.0.0.1:4041/mcp")
VERSION = "2025-11-25"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSION_FILE = os.environ.get(
    "AVWE_MCP_SESSION_FILE", os.path.join(ROOT, "tmp", "mcp_session")
)
TIMEOUT = 60


class Refused(Exception):
    """The server refused a request with an HTTP error other than 404."""


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


def refusal(error):
    """What an HTTP error says: its JSON-RPC error message, or its body."""
    try:
        body = error.read().decode()
    except OSError:
        body = ""
    try:
        message = json.loads(body).get("error")
        if isinstance(message, dict):
            message = message.get("message")
        if message:
            return f"HTTP {error.code}: {message}"
    except (ValueError, AttributeError):
        pass
    return f"HTTP {error.code}: {body.strip() or error.reason}"


def delete(session):
    """Ends the session on the server. A session already gone is no error."""
    request = urllib.request.Request(
        URL,
        headers={"Mcp-Session-Id": session, "MCP-Protocol-Version": VERSION},
        method="DELETE",
    )
    try:
        urllib.request.urlopen(request, timeout=TIMEOUT).read()
    except urllib.error.HTTPError:
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
    try:
        reply, headers = post(hello)
    except urllib.error.HTTPError as error:
        raise Refused(refusal(error)) from error
    if reply is None or "error" in reply:
        sys.exit(f"initialize failed: {reply}")
    session = headers.get("Mcp-Session-Id")
    if not session:
        sys.exit("The server gave no session id.")
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
    saved = {"url": URL, "session": session, "next_id": 2}
    save(saved)
    return saved


def load():
    try:
        with open(SESSION_FILE) as file:
            saved = json.load(file)
        return saved if saved.get("url") == URL else None
    except (OSError, ValueError):
        return None


def save(saved):
    os.makedirs(os.path.dirname(SESSION_FILE) or ".", exist_ok=True)
    with open(SESSION_FILE, "w") as file:
        json.dump(saved, file)


def forget():
    try:
        os.remove(SESSION_FILE)
    except OSError:
        pass


def request(saved, method, params):
    id = saved["next_id"]
    saved["next_id"] = id + 1
    save(saved)
    reply, _headers = post(
        {"jsonrpc": "2.0", "id": id, "method": method, "params": params}, saved["session"]
    )
    return reply


def call(saved, method, params):
    """Makes a request, starting a new session once if the server forgot the saved one."""
    try:
        return saved, request(saved, method, params)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise Refused(refusal(error)) from error
    print("(The saved session is gone; starting a new one.)", file=sys.stderr)
    saved = initialise()
    try:
        return saved, request(saved, method, params)
    except urllib.error.HTTPError as error:
        raise Refused(refusal(error)) from error


def print_result(reply, show_json):
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


def leave():
    """Leaves the body, if any, and ends the saved session."""
    saved = load()
    if not saved:
        print("No saved session.")
        return 0
    status = 0
    try:
        reply, _headers = post(
            {
                "jsonrpc": "2.0",
                "id": saved["next_id"],
                "method": "tools/call",
                "params": {"name": "leave", "arguments": {}},
            },
            saved["session"],
        )
        status = print_result(reply, False)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            print(refusal(error))
    delete(saved["session"])
    forget()
    print("Session ended.")
    return status


def main(argv):
    flags = ("--new", "--json", "--leave")
    new = "--new" in argv
    show_json = "--json" in argv
    args = [arg for arg in argv if arg not in flags]
    if "--leave" in argv:
        return leave()
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
    return print_result(reply, show_json)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as refused:
        print(f"The server refused the request: {refused}")
        sys.exit(1)
    except urllib.error.HTTPError as error:
        print(f"The server refused the request: {refusal(error)}")
        sys.exit(1)
    except urllib.error.URLError as error:
        sys.exit(f"Can't reach the MCP server at {URL}: {error.reason}")
