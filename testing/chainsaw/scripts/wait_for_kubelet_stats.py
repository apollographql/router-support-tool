#!/usr/bin/env python3
"""
Waits until the kubelet reports every documented kubelet signal for the router containers.

Usage: wait_for_kubelet_stats.py <namespace> <selector>

The kubelet reports some of a container's stats late causing a router container read too soon
to lack some of the signals the spec documents (specs/collection/base_spec.md, "Memory and CPU
information collected"). This reads each router node's kubelet with the scenario's
ServiceAccount token, the way the router-resource-usage collector does, until every router
container has all of them.

It exits 0 when the wait runs out or the kubelet can't be read so that
assert_documented_memory_cpu_signals.py reports what is missing from the bundle.
MEMORY_CPU_SPEC_FILE points the wait at another copy of the spec.
"""
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

from memory_cpu_signals import DEFAULT_SPEC, documented_signals, lookup

TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
KUBELET_PORT = 10250
TIMEOUT_SECONDS = 120
INTERVAL_SECONDS = 2
REQUEST_TIMEOUT_SECONDS = 5

def router_node_ips(namespace, selector):
    """Returns the address of each node that runs a router pod."""
    out = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-l", selector,
         "-o", "jsonpath={.items[*].status.hostIP}"],
        capture_output=True, text=True, check=True,
    ).stdout
    # kubectl prints the addresses as one space-separated string.
    # Split it and keep each node once since several router pods can share a node.
    return sorted(set(out.split()))

def read_summary(ip, token, context):
    """Returns the kubelet's /stats/summary for the node at ip."""
    request = urllib.request.Request(
        f"https://{ip}:{KUBELET_PORT}/stats/summary",
        headers={"Authorization": "Bearer " + token},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS, context=context) as response:
        return json.load(response)

def has_every_signal(container, signals):
    return all(lookup(container, signal) is not None for signal in signals)

def routers_complete(summary, namespace, signals):
    """True when the summary has a router container in namespace and every one has every signal."""
    routers = []
    for pod in summary.get("pods") or []:
        if (pod.get("podRef") or {}).get("namespace") != namespace:
            continue
        for container in pod.get("containers") or []:
            if container.get("name") == "router":
                routers.append(container)
    if not routers:
        return False
    return all(has_every_signal(container, signals) for container in routers)

def wait_until_complete(ips, read_kubelet, namespace, signals, sleep=time.sleep, monotonic=time.monotonic):
    """
    Reads each node in ips until all of them are complete. Returns (outcome, detail) where outcome is
    "complete", "timeout", or "unreadable".
    """
    deadline = monotonic() + TIMEOUT_SECONDS
    while True:
        incomplete = []
        for ip in ips:
            try:
                summary = read_kubelet(ip)
            except urllib.error.HTTPError as e:
                return "unreadable", f"kubelet at {ip}:{KUBELET_PORT} returned HTTP {e.code}"
            except (OSError, ValueError) as e:
                return "unreadable", f"could not read the kubelet at {ip}:{KUBELET_PORT}: {e}"
            if not routers_complete(summary, namespace, signals):
                incomplete.append(ip)
        if not incomplete:
            return "complete", ""
        if monotonic() >= deadline:
            return "timeout", ", ".join(incomplete)
        sleep(INTERVAL_SECONDS)

def main(argv):
    if len(argv) != 3:
        print(f"usage: {os.path.basename(argv[0])} <namespace> <selector>, got {len(argv) - 1} argument(s)", file=sys.stderr)
        return 2
    namespace, selector = argv[1], argv[2]
    with open(os.environ.get("MEMORY_CPU_SPEC_FILE") or DEFAULT_SPEC) as f:
        signals = documented_signals(f.read(), "kubelet Summary API")
    if not signals:
        print("no 'kubelet Summary API' signals found in the spec - did the Memory and CPU table change?", file=sys.stderr)
        return 1
    try:
        ips = router_node_ips(namespace, selector)
    except subprocess.CalledProcessError as e:
        print(f"not waiting for kubelet stats: kubectl failed: {e.stderr.strip()}", file=sys.stderr)
        return 0
    except OSError as e:
        # kubectl could not be started at all, for example because it is not on the PATH.
        print(f"not waiting for kubelet stats: could not run kubectl: {e}", file=sys.stderr)
        return 0
    if not ips:
        print(f"no pod matching {selector} has a node yet, nothing to wait for", file=sys.stderr)
        return 0
    with open(TOKEN_PATH) as f:
        token = f.read().strip()
    # The kubelet's serving certificate is commonly self-signed or issued by a CA other than the
    # cluster's, as in the collector.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    outcome, detail = wait_until_complete(ips, lambda ip: read_summary(ip, token, context), namespace, signals)
    if outcome == "unreadable":
        print(f"not waiting for kubelet stats: {detail}", file=sys.stderr)
    elif outcome == "timeout":
        print(f"kubelet stats for the router containers still incomplete after {TIMEOUT_SECONDS}s on {detail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
