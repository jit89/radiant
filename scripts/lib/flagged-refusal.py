#!/usr/bin/env python3
"""Exit 0 if a headless Claude turn was stopped by a safety flag, 1 if it was not.

Usage: flagged-refusal.py <envelope.json> [<stderr-file>]

Prints one word on a match — `stop_reason` or `text` — so the caller can log why.

Claude Code reports a flagged message as text ("<model>'s safeguards flagged this
message", "<model> has safety measures that flagged this message for a
cybersecurity topic") and the API as `stop_reason: "refusal"`. Either way the model
produced no review, so the caller may retry on another model.

Deliberately NOT matched: the Usage Policy notice and "can't help with this". Those
are not over-flags, and this exists to ride out a classifier's false positive, not to
route around a policy refusal.

A false positive here discards a real review and re-runs it on a weaker model, so the
text test is narrow. A review that merely QUOTES the phrase — the diff under review can
contain it, this file being one — ends with a `VERDICT:` line and starts with prose, so
the phrase must be absent a verdict and sit at the very start of the reply.
"""
import json
import re
import sys

PHRASES = (
    "safeguards flagged this message",
    "safety measures that flagged this message",
)
TEXT_KEYS = ("result", "text", "response", "output")
HEAD = 300  # a flag notice is one short sentence; anything later is review prose


def load(path: str):
    """Return the envelope dict, tolerating NDJSON, or None when unreadable."""
    try:
        text = open(path, encoding="utf-8").read().strip()
    except OSError:
        return None
    for candidate in [text, *reversed(text.splitlines())]:
        candidate = candidate.strip()
        if candidate.startswith("{") and candidate.endswith("}"):
            try:
                obj = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                return obj
    return None


def head_has_phrase(text: str) -> bool:
    return any(p in text.strip()[:HEAD].lower() for p in PHRASES)


def main() -> int:
    obj = load(sys.argv[1]) if len(sys.argv) > 1 else None
    if obj is not None:
        details = obj.get("stop_details")
        if obj.get("stop_reason") == "refusal" or (
            isinstance(details, dict) and details.get("type") == "refusal"
        ):
            print("stop_reason")
            return 0
        body = next((str(obj[k]) for k in TEXT_KEYS if obj.get(k)), "")
        if body and not re.search(r"(?m)^\s*VERDICT:", body) and head_has_phrase(body):
            print("text")
            return 0
    if len(sys.argv) > 2:
        try:
            err = open(sys.argv[2], encoding="utf-8", errors="replace").read()
        except OSError:
            err = ""
        if err and not re.search(r"(?m)^\s*VERDICT:", err) and head_has_phrase(err):
            print("text")
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
