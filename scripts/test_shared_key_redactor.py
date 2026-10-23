"""
Runs the response_cache shared_key redactor's patterns over every shape the key can take.

Called by mise-tasks/test-shared-key-redactor, which reads the patterns from the rendered
chart and writes them to a file, one per line. See that task for why this exists.
"""
import re
import sys

MASK = "***HIDDEN***"

# (name, input, expected)
CASES = [
    # Masked
    ("block", r'shared_key: SECRET', r'shared_key: ***HIDDEN***'),
    ("raw quoted", r'shared_key: "SECRET"', r'shared_key: "***HIDDEN***"'),
    ("raw quoted, looks like a number", r'shared_key: "12345678"', r'shared_key: "***HIDDEN***"'),
    ("json-escaped quoted", r'shared_key: \"SECRET\"\n', r'shared_key: \"***HIDDEN***\"\n'),
    ("json-escaped block, more keys follow", r'shared_key: SECRET\n    next: 1', r'shared_key: ***HIDDEN***\n    next: 1'),
    ("last line of router.yaml, no trailing newline", r'shared_key: SECRET"', r'shared_key: ***HIDDEN***"'),
    ("flow style (the closing brace is masked too, as documented)", r'{ enabled: true, shared_key: SECRET }\n', r'{ enabled: true, shared_key: ***HIDDEN***\n'),
    ("json", r'"shared_key": "SECRET"', r'"shared_key": "***HIDDEN***"'),
    ("last-applied-configuration annotation", r'\"shared_key\":\"SECRET\"', r'\"shared_key\":\"***HIDDEN***\"'),
    ("env indirection is masked too", r'shared_key: ${env.INVALIDATION_KEY}', r'shared_key: ***HIDDEN***'),
    # Left alone
    ("empty, raw", r'shared_key: ""', r'shared_key: ""'),
    ("empty, json-escaped", r'shared_key: \"\"\n', r'shared_key: \"\"\n'),
    ("empty, json", r'"shared_key": ""', r'"shared_key": ""'),
    ("empty, in flow style", r'{ enabled: true, shared_key: "" }', r'{ enabled: true, shared_key: "" }'),
    ("bare key", r'shared_key:\n    next: 1', r'shared_key:\n    next: 1'),
    ("unrelated key", r'other_key: SECRET', r'other_key: SECRET'),
    ("key with a longer name", r'shared_keys: SECRET', r'shared_keys: SECRET'),
]


def load_patterns(path):
    with open(path) as f:
        patterns = [line.rstrip("\n") for line in f if line.strip()]
    compiled = []
    for p in patterns:
        c = re.compile(p)
        # troubleshoot.sh replaces only the `mask` group, so every pattern must be
        # (prefix)(?P<mask>...)(suffix).
        if c.groups != 3 or c.groupindex != {"mask": 2}:
            sys.exit(f"pattern is not (prefix)(?P<mask>...)(suffix): {p}")
        compiled.append(c)
    return compiled


def redact(patterns, text):
    for c in patterns:
        text = c.sub(lambda m: m.group(1) + MASK + m.group(3), text)
    return text


def main():
    patterns = load_patterns(sys.argv[1])
    failed = 0
    for name, given, expected in CASES:
        got = redact(patterns, given)
        if got != expected:
            failed += 1
            print(f"FAIL: {name}\n  input:    {given}\n  expected: {expected}\n  got:      {got}", file=sys.stderr)
    if failed:
        sys.exit(1)
    print(f"ok: {len(CASES)} shapes")


if __name__ == "__main__":
    main()
