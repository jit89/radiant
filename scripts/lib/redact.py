"""redact.py — one redactor for the house: secrets out of anything a model or a
log will read.

redact(text) is the lessons hook's (scripts/lessons.py). redact_proof(text)
is for host proof output sent to the implementer (scripts/lib/proof-excerpt.py):
the same patterns, but a PEM block only from its BEGIN line to its END line,
since redact()'s rule also takes an unclosed block to the end of the text,
which on a proof log would erase the failure. An unclosed block's base64 body
lines are still caught by the long-opaque rule. It also returns how many
values it replaced.
"""
import re

# The secret word must end a component of the name (GROK_API_KEY, auth-token,
# PGPASSWORD, AUTHTOKEN), so KeyError: or max_tokens= are left alone.
_SECRET_NAME = (r"(?:[A-Za-z0-9]+[_.-])*[A-Za-z0-9]*?(?:api[_-]?key|key|token|secret|password|passwd|credentials?)"
                r"(?:[_.-][A-Za-z0-9]+)*(?![A-Za-z0-9])")
REDACTIONS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", re.S), "[REDACTED]"),
    (re.compile(r"\b(?:sk|xai|sk-ant|sk-proj)-[A-Za-z0-9_-]{8,}"), "[REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"), "[REDACTED]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{16,}"), "[REDACTED]"),
    (re.compile(r"\bAKIA[0-9A-Z]{12,}"), "[REDACTED]"),
    (re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [REDACTED]"),
    # "api_key": "value" / 'token': 'value' (JSON, Python dicts)
    (re.compile(r"""(?i)(["']""" + _SECRET_NAME + r"""["']\s*:\s*)(["'])[^"'\n]*\2"""), r"\1\2[REDACTED]\2"),
    # export NAME=value, NAME=value, .env lines, YAML name: value
    (re.compile(r"(?i)\b(" + _SECRET_NAME + r")(\s*[=:]\s*)(?![\s\"']*\[REDACTED\])(\"[^\"\n]*\"|'[^'\n]*'|[^\s\"',;]+)"), r"\1\2[REDACTED]"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "[REDACTED]"),
]
_LONG = re.compile(r"[A-Za-z0-9+/_-]{40,}={0,2}")


def _opaque(m):
    """A 40+ char run is redacted when it looks like a key (base64/base64url:
    upper, lower and digits mixed in), not a path or a long word."""
    s = m.group(0)
    if "/" in s and all(re.fullmatch(r"[A-Za-z0-9._-]{0,39}", part) for part in s.split("/")):
        if sum(c.isdigit() for c in s) < 6:
            return s
    upper = sum(c.isupper() for c in s)
    lower = sum(c.islower() for c in s)
    digits = sum(c.isdigit() for c in s)
    return "[REDACTED]" if upper >= 3 and lower >= 3 and digits >= 3 else s


def redact(text):
    for pattern, repl in REDACTIONS:
        text = pattern.sub(repl, text)
    return _LONG.sub(_opaque, text)


# One block only: from a BEGIN line to the first END line with no other BEGIN
# between, so an unclosed block followed by a closed one keeps what lies
# between them (the failure, often).
_PEM_CLOSED = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:(?!-----BEGIN ).)*?-----END [A-Z ]*PRIVATE KEY-----", re.S)
_PEM_BEGIN = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")


def redact_proof(text):
    """redact() for proof output: (redacted text, number of values replaced).

    A match counts only when its replacement changes it, so a value already
    [REDACTED] by an earlier rule is not counted again."""
    count = 0

    def sub(pattern, repl, s):
        def one(m):
            nonlocal count
            out = m.expand(repl)
            if out != m.group(0):
                count += 1
            return out
        return pattern.sub(one, s)

    text = sub(_PEM_CLOSED, "[REDACTED]", text)
    text = sub(_PEM_BEGIN, "[REDACTED]", text)
    for pattern, repl in REDACTIONS[1:]:
        text = sub(pattern, repl, text)

    def opaque(m):
        nonlocal count
        out = _opaque(m)
        if out != m.group(0):
            count += 1
        return out

    return _LONG.sub(opaque, text), count
