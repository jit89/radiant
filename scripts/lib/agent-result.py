#!/usr/bin/env python3
"""Parse a headless agent's JSON envelope on stdin → session_id<TAB>text.

Handles both harnesses this workflow drives:
  Claude Code  `claude -p --output-format json`  → {"session_id", "result"}
  Grok         `grok -p --output-format json`    → {"sessionId", "text"}

Falls back to the last JSON object on a line when the stream is NDJSON.
"""
import json
import sys

SID_KEYS = ("session_id", "sessionId", "session")
TEXT_KEYS = ("result", "text", "response", "output")

raw = sys.stdin.read()
text = raw.strip()
if not text:
    sys.stderr.write("empty agent JSON output\n")
    sys.exit(1)

obj = None
try:
    obj = json.loads(text)
except json.JSONDecodeError:
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                obj = json.loads(line)
                break
            except json.JSONDecodeError:
                pass
if obj is None or not isinstance(obj, dict):
    sys.stderr.write("could not parse agent JSON output\n")
    sys.exit(1)

sid = ""
for k in SID_KEYS:
    if obj.get(k):
        sid = str(obj[k])
        break

result = ""
for k in TEXT_KEYS:
    val = obj.get(k)
    if val:
        result = val
        break
if not isinstance(result, str):
    result = json.dumps(result)

print(sid + "\t" + result.replace("\t", " "))
