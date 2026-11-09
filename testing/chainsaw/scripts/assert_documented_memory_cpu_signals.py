#!/usr/bin/env python3
"""
Tests that every memory/CPU signal the spec documents (specs/collection/base_spec.md,
"Memory and CPU information collected") are present in the bundle.

Usage: assert_documented_memory_cpu_signals.py <bundle-dir>

Run only against bundles that collected kubelet stats.
MEMORY_CPU_SPEC_FILE points the check at another copy of the spec.
SKIP_PROMETHEUS_SIGNALS=1 skips the Prometheus signals check for a router that does not serve
them.
"""
import glob
import json
import os
import re
import sys

from memory_cpu_signals import DEFAULT_SPEC, documented_signals, lookup


class Failure(Exception):
    pass


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


def check_kubelet_stats(bundle, signals):
    # mode: local writes node-metrics/*.json.
    # mode: job's router-resource-usage script writes one <node-name>.json per node.
    files = sorted(
        glob.glob(os.path.join(bundle, "node-metrics", "*.json"))
        + glob.glob(os.path.join(bundle, "host-collectors", "run-host", "router-resource-usage", "nodes", "*.json"))
    )
    if not files:
        raise Failure("no node-metrics/*.json or router-resource-usage/nodes/*.json in the bundle, but the spec documents kubelet memory/CPU signals")
    saw_router = False
    for path in files:
        try:
            with open(path) as f:
                data = json.load(f)
        except ValueError:
            continue
        # Collect the router's container stats from every pod on this node.
        routers = []
        for pod in data.get("pods") or []:
            for container in pod.get("containers") or []:
                if container.get("name") == "router":
                    routers.append(container)
        if not routers:
            continue
        saw_router = True
        for signal in signals:
            if any(lookup(container, signal) is None for container in routers):
                raise Failure(f"{os.path.basename(path)}: the spec documents {signal} for the router container, but it is missing (psi also needs the KubeletPSI feature gate, see testing/kind-config.yaml)")
    if not saw_router:
        raise Failure("no container named router in the kubelet stats files")


def main(argv):
    if len(argv) != 2:
        print(f"usage: {os.path.basename(argv[0])} <bundle-dir>, got {len(argv) - 1} argument(s)", file=sys.stderr)
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
        if not os.environ.get("SKIP_PROMETHEUS_SIGNALS"):
            check_prometheus_scrapes(bundle, prom)
        check_kubelet_stats(bundle, kube)
    except Failure as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
