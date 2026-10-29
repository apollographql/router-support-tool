"""Container memory and CPU for the router's pods, read from the kubelet.

The router-resource-usage collector of mode: job (specs/collection/base_spec.md ->
Kubelet stats collection). troubleshoot.sh runs it as a hostCollectors.run script inside
the Job's pod, started by a one-line sh wrapper that sets NAMESPACE, SELECTOR and
KUBELET_DECLINED. It lists the pods matching SELECTOR through the API server, asks each
distinct node's kubelet once, and keeps only those pods. Every missing file gets a line on
stdout saying why. Standard library only, and it always exits 0: empty is not failure.
"""
import concurrent.futures
import http.client
import json
import os
import ssl
import sys
import time
import urllib.parse

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API_HOST = "kubernetes.default.svc"
KUBELET_PORT = 10250
CONNECT_TIMEOUT = 5
REQUEST_TIMEOUT = 30
BATCH = 10


def request(host, port, path, token, context):
    """GET over HTTPS. Returns (status, body); status 0 means no usable response and the
    body holds the reason. The whole request, body included, is capped at REQUEST_TIMEOUT."""
    deadline = time.monotonic() + REQUEST_TIMEOUT
    conn = http.client.HTTPSConnection(host, port, timeout=CONNECT_TIMEOUT, context=context)
    try:
        conn.connect()
        conn.sock.settimeout(REQUEST_TIMEOUT)
        conn.request("GET", path, headers={"Authorization": "Bearer " + token, "Accept": "*/*"})
        resp = conn.getresponse()
        chunks = []
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
            if time.monotonic() > deadline:
                return 0, b"timed out"
        return resp.status, b"".join(chunks)
    except (OSError, http.client.HTTPException) as e:
        return 0, str(e).encode()
    finally:
        conn.close()


def filter_summary(data, namespace, wanted):
    """The kubelet's /stats/summary reduced to the node figures and the wanted pods."""
    kept = [
        p for p in data.get("pods", [])
        if p.get("podRef", {}).get("name") in wanted
        and p.get("podRef", {}).get("namespace") == namespace
    ]
    return {"node": data.get("node", {}), "pods": kept}, [p["podRef"]["name"] for p in kept]


def _write(directory, name, content):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "w") as f:
        f.write(content)


def read_node(node, ip, pods, cfg, get_kubelet):
    """One node's kubelet. Returns the lines to print."""
    status, body = get_kubelet(ip, "/stats/summary")
    if status == 0:
        return [f"kubelet stats not collected for node {node}: could not reach the kubelet at {ip}:{KUBELET_PORT}"]
    if status != 200:
        return [f"kubelet stats not collected for node {node}: kubelet returned HTTP {status}"]
    try:
        summary, found = filter_summary(json.loads(body), cfg["namespace"], set(pods))
    except (ValueError, AttributeError, KeyError, TypeError):
        return [f"kubelet stats not collected for node {node}: the kubelet's response could not be read"]
    _write(os.path.join(cfg["out"], node), "stats-summary.json", json.dumps(summary, indent=2))
    return [
        f"kubelet stats not collected for pod {pod}: not in node {node}'s stats"
        for pod in pods if pod not in found
    ]


def collect(cfg, get_api, get_kubelet, say, warn):
    if cfg["declined"]:
        say("kubelet stats not collected: declined at install (job.collectNodeMetrics is false)")
        return

    ns = urllib.parse.quote(cfg["namespace"], safe="")
    sel = urllib.parse.quote(cfg["selector"], safe="")
    status, body = get_api(f"/api/v1/namespaces/{ns}/pods?labelSelector={sel}")
    try:
        if status != 200:
            raise ValueError(f"HTTP {status}: {body[:500].decode(errors='replace')}")
        items = json.loads(body).get("items", [])
    except (ValueError, AttributeError) as e:
        warn(f"listing pods: {e}")
        say(f"kubelet stats not collected: could not list pods matching selector {cfg['selector']} in namespace {cfg['namespace']}")
        return
    if not items:
        say(f"kubelet stats not collected: no pods matched selector {cfg['selector']} in namespace {cfg['namespace']}")
        return

    # A pod with no node yet (still Pending) has nothing to ask the kubelet.
    nodes = {}
    for item in items:
        name = item["metadata"]["name"]
        node = item.get("spec", {}).get("nodeName")
        ip = item.get("status", {}).get("hostIP")
        if not node or not ip:
            say(f"kubelet stats not collected for pod {name}: pod has no node yet")
        else:
            nodes.setdefault(node, (ip, []))[1].append(name)

    # Nodes are asked BATCH at a time, so a fleet of unreachable nodes costs about one
    # timeout per ten nodes instead of one per node.
    names = sorted(nodes)
    with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH) as pool:
        results = pool.map(
            lambda n: read_node(n, nodes[n][0], nodes[n][1], cfg, get_kubelet), names)
        for lines in results:
            for line in lines:
                say(line)


def main():
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    api_ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    # The kubelet's serving certificate is commonly self-signed, or issued by a CA other
    # than the one mounted here, so it is not verified.
    kubelet_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    kubelet_ctx.check_hostname = False
    kubelet_ctx.verify_mode = ssl.CERT_NONE

    cfg = {
        "namespace": os.environ["NAMESPACE"],
        "selector": os.environ["SELECTOR"],
        "declined": os.environ.get("KUBELET_DECLINED") == "1",
        "out": os.environ["TS_OUTPUT_DIR"],
    }

    def say(line):
        print(line, flush=True)

    def warn(line):
        print(line, file=sys.stderr, flush=True)

    collect(
        cfg,
        lambda path: request(API_HOST, 443, path, token, api_ctx),
        lambda ip, path: request(ip, KUBELET_PORT, path, token, kubelet_ctx),
        say,
        warn,
    )


if __name__ == "__main__":
    main()
