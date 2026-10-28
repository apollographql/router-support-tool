#!/usr/bin/env python3
"""
Tests that every memory/CPU signal the spec documents (specs/collection/base_spec.md,
"Memory and CPU information collected") are present in the bundle.

Usage: assert_documented_memory_cpu_signals.py <bundle-dir>

Run only against bundles collected with nodeMetrics enabled.
MEMORY_CPU_SPEC_FILE points the check at another copy of the spec (to test the check).
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SPEC = os.path.join(HERE, "..", "..", "..", "specs", "collection", "base_spec.md")

# Signals the spec says the router does not serve (see its jemalloc row). If a router starts
# serving one, update the spec and docs rather than loosening this check.
NOT_SERVED = ("process_resident_memory_bytes", "process_cpu_seconds_total")


class Failure(Exception):
    pass


def documented_signals(spec_text, source):
    """
    Collects every signal the spec says to expect from a given source.

    The spec's "Memory and CPU information collected" table in specs/collection/base_spec.md
    lists what the bundle should contain. This reads the expected signals from that table.
    It returns the names in the rows whose Source cell contains `source`.
    """
    signals = []
    base = ""
    for line in spec_text.splitlines():
        cells = line.split("|")
        # cells[0] is what precedes the row's leading pipe, cells[1] is Signal, cells[2] Source.
        if len(cells) < 3 or source not in cells[2]:
            continue
        # A row's first cell lists signal names in backticks. A name that starts with "_" is
        # shorthand for the previous full name with its last word swapped. For example, the cell
        # `apollo_router_jemalloc_allocated`, `_active` names two signals:
        # apollo_router_jemalloc_allocated and apollo_router_jemalloc_active.
        for token in re.findall(r"`([^`]*)`", cells[1]):
            if token.startswith("_"):
                signals.append(base + token)
            else:
                signals.append(token)
                base = token.rsplit("_", 1)[0]
    return signals


def lookup(obj, dotted):
    """
    Finds a documented kubelet signal in a container's stats.

    The spec names kubelet signals as dotted paths, such as `memory.workingSetBytes`, which
    match the nesting in the kubelet's Summary API JSON. This follows that path through the
    container's stats and returns the value, or None if any step is missing, so the caller
    can detect a documented signal the bundle lacks.
    """
    for key in dotted.split("."):
        if not isinstance(obj, dict) or key not in obj:
            return None
        obj = obj[key]
    return obj


def check_prometheus_scrapes(bundle, signals):
    pods_dir = os.path.join(bundle, "host-collectors", "run-host", "router-metrics", "pods")
    files = sorted(glob.glob(os.path.join(pods_dir, "*.txt")))
    if not files:
        raise Failure(f"no per-pod scrape files under {pods_dir} to check the documented Prometheus signals against")
    for path in files:
        with open(path, errors="replace") as f:
            text = f.read()
        for sig in signals:
            if not re.search(r"^" + re.escape(sig) + r"[{ ]", text, re.MULTILINE):
                raise Failure(f"{os.path.basename(path)}: the spec documents {sig} as served by the router's Prometheus endpoint, but it is not in the scrape")
        for sig in NOT_SERVED:
            if re.search(r"^" + re.escape(sig) + r"[{ ]", text, re.MULTILINE):
                raise Failure(f"{os.path.basename(path)}: the router now serves {sig}, which the spec says it does not; update the spec and docs")


def check_kubelet_stats(bundle, signals):
    files = sorted(glob.glob(os.path.join(bundle, "node-metrics", "*.json")))
    if not files:
        raise Failure("no node-metrics/*.json in the bundle, but the spec documents kubelet memory/CPU signals")
    saw_router = False
    for path in files:
        try:
            with open(path) as f:
                data = json.load(f)
        except ValueError:
            continue
        routers = [
            c
            for p in data.get("pods") or []
            for c in p.get("containers") or []
            if c.get("name") == "router"
        ]
        if not routers:
            continue
        saw_router = True
        for sig in signals:
            if any(lookup(c, sig) is None for c in routers):
                raise Failure(f"{os.path.basename(path)}: the spec documents {sig} for the router container, but it is missing (psi also needs the KubeletPSI feature gate, see testing/kind-config.yaml)")
    if not saw_router:
        raise Failure("no container named router in any node-metrics/*.json")


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    bundle = argv[1]
    spec = os.environ.get("MEMORY_CPU_SPEC_FILE") or DEFAULT_SPEC
    try:
        if not os.path.isfile(spec):
            raise Failure(f"spec not found at {spec}")
        with open(spec) as f:
            text = f.read()
        prom = documented_signals(text, "Router Prometheus endpoint")
        if not prom:
            raise Failure(f"no 'Router Prometheus endpoint' signals found in {spec} - did the Memory and CPU table change shape?")
        kube = documented_signals(text, "kubelet Summary API")
        if not kube:
            raise Failure(f"no 'kubelet Summary API' signals found in {spec} - did the Memory and CPU table change shape?")
        check_prometheus_scrapes(bundle, prom)
        check_kubelet_stats(bundle, kube)
    except Failure as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
