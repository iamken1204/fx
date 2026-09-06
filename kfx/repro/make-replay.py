#!/usr/bin/env python3
"""Turn an incident recovery checkpoint into a fake-codex REPLAY script.

usage: make-replay.py <parent recovery.json> <out.json> [child recovery.json]

The script maps a session key ("parent" or "CHILD-TASK-1") to the list of
responses the fake serves in order; each response is a list of tool calls, and
the session ends with a final text once the list runs out. Shell commands that
write or reach outside the repo are swapped for read-only stand-ins of similar
output size, and read_tool_result handles become $H:<tool> placeholders that
the fake resolves from the newest matching handle in the request body.
"""
import json
import re
import sys

HERE = __file__.rsplit("/", 1)[0]
BIN = HERE + "/../incidents/2026-09-05-sigtrap/sessions/m3uV9UuSv23X/logs/commands/"
MEMO_STANDIN = {
    "~/.optmem/memo wake": "cat " + BIN + "fx-command-replay-cab00d6468358a6be5d32455e0416242-29edd935f2adb617.bin",
    "~/.optmem/memo wake 2 283": "cat " + BIN + "fx-command-replay-92d2da80aaa78e5c1ca63bbe761d01ab-f09b7d4b61511135.bin",
    "~/.optmem/memo wake 3 283": "cat " + BIN + "fx-command-replay-d11f5c1234e029f37741e5433f9bd1b0-43f03d4c1d751c7c.bin",
}


def sanitize(name, args):
    if name == "shell":
        cmd = args.get("command", "")
        if cmd in MEMO_STANDIN:
            args["command"] = MEMO_STANDIN[cmd]
        cmd = args["command"].replace("git switch -c refactor-remove-eviction", "git branch --show-current")
        args["command"] = cmd
    if name == "read_tool_result":
        handle = args["request"]["handle"]
        tool = "shell" if handle.startswith("fx-command-replay") else re.sub(r"^result-([a-z_]+)-.*", r"\1", handle)
        args["request"]["handle"] = "$H:" + tool
    if name == "skill" and "location" in args:
        args = {"name": args["location"].rsplit("/", 1)[-1]}
    return args


def steps(path):
    cp = json.load(open(path))["checkpoint"]
    out = []
    for step in cp["execution"]["tool_steps"]:
        calls = []
        for call in step["tool_calls"]:
            args = json.loads(call["arguments_json"])
            calls.append({"name": call["name"], "arguments": sanitize(call["name"], args)})
        out.append(calls)
    return out


parent = steps(sys.argv[1])
parent.append([{"name": "subagent", "arguments": {
    "action": "message",
    "agent": "context-tests",
    "message": "CHILD-TASK-1: implement focused deterministic regression tests in tests/e2e/config-persistence.test.ts.",
}}])
child = steps(sys.argv[3]) if len(sys.argv) > 3 else []
child.append([
    {"name": "read_file", "arguments": {"path": "tests/e2e/config-persistence.test.ts", "line_count": 400}},
    {"name": "grep_files", "arguments": {"pattern": "startFakeGateway|runFx", "path": "tests/e2e", "context_lines": 2}},
    {"name": "glob_files", "arguments": {"pattern": "tests/e2e/*.test.ts"}},
])
json.dump({"parent": parent, "CHILD-TASK-1": child}, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print("parent steps", len(parent), "child steps", len(child))
