#!/usr/bin/env python3
"""Parse `claude -p --output-format json` stdin → session_id<TAB>result."""
import json
import sys

raw = sys.stdin.read()
text = raw.strip()
if not text:
    sys.stderr.write("empty Claude JSON output\n")
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
if obj is None:
    sys.stderr.write("could not parse Claude JSON output\n")
    sys.exit(1)

sid = obj.get("session_id") or obj.get("sessionId") or ""
result = obj.get("result") or obj.get("text") or ""
if not isinstance(result, str):
    result = json.dumps(result)
print(sid + "\t" + result.replace("\t", " "))
