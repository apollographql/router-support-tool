"""Container memory and CPU for the router's pods, read from the kubelet.

The router-resource-usage collector of mode: job (specs/collection/base_spec.md ->
Kubelet stats collection). troubleshoot.sh runs it as a hostCollectors.run script inside
the Job's pod, started by a one-line sh wrapper that sets NAMESPACE, SELECTOR and
KUBELET_DECLINED. It lists the pods matching SELECTOR through the API server, asks each
distinct node's kubelet once, and keeps only those pods.
"""
import concurrent.futures
import dataclasses
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import urllib.parse

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API_HOST = "kubernetes.default.svc"
KUBELET_PORT = 10250
CONNECT_TIMEOUT_SECONDS = 5
REQUEST_TIMEOUT_SECONDS = 30
BATCH = 10

@dataclasses.dataclass
class NodeInfo:
    """A node that runs router pods: its name, its kubelet's address, and those pods' names."""
    name: str
    ip: str
    pods: list

def info(line):
    print(line, flush=True)

def warn(line):
    print(line, file=sys.stderr, flush=True)

def request(host, port, path, token, context):
    """Makes a GET request over HTTPS. Returns (status, body)."""
    conn = http.client.HTTPSConnection(host, port, timeout=CONNECT_TIMEOUT_SECONDS, context=context)
    expired = threading.Event()

    def expire():
        expired.set()
        # Read once: conn.close() sets conn.sock to None when the request finishes
        # which can happen between a check and a use.
        sock = conn.sock
        if sock is not None:
            try:
                # The plain socket method: SSLSocket.shutdown also discards the TLS state
                # that the blocked read is using.
                socket.socket.shutdown(sock, socket.SHUT_RDWR)
            except OSError:
                # The socket is already closed or was never connected. Therefore, the
                # request is over and nothing is left to cut short.
                # The caller reports the outcome.
                pass

    # REQUEST_TIMEOUT_SECONDS covers the whole request. A socket timeout alone wouldn't because it
    # restarts on every read. Therefore, a server sending a byte at a time would never trip it.
    # This timer shuts the socket down at the deadline.
    timer = threading.Timer(REQUEST_TIMEOUT_SECONDS, expire)
    timer.start()
    try:
        conn.connect()
        if expired.is_set():
            return 0, b"timed out"
        conn.sock.settimeout(REQUEST_TIMEOUT_SECONDS)
        conn.request("GET", path, headers={"Authorization": "Bearer " + token, "Accept": "*/*"})
        resp = conn.getresponse()
        return resp.status, resp.read()
    except (OSError, http.client.HTTPException) as e:
        return 0, b"timed out" if expired.is_set() else str(e).encode()
    finally:
        timer.cancel()
        conn.close()

def filter_summary(data, namespace, router_pods):
    """Returns the kubelet's /stats/summary reduced to the node figures and the router pods."""
    kept = [
        p for p in data.get("pods", [])
        if p.get("podRef", {}).get("name") in router_pods
        and p.get("podRef", {}).get("namespace") == namespace
    ]
    summary = {"node": data.get("node", {}), "pods": kept}
    pods_found = [p["podRef"]["name"] for p in kept]
    return summary, pods_found

def read_node(node, cfg, get_kubelet):
    """Read one node's kubelet. Returns the lines to print."""
    # The kubelet is read directly rather than through the API server's proxy so its own
    # authorization applies and the Job only needs nodes/stats on the cluster.
    status, body = get_kubelet(node.ip, "/stats/summary")
    if status == 0:
        return [f"kubelet stats not collected for node {node.name}: could not reach the kubelet at {node.ip}:{KUBELET_PORT}"]
    if status != 200:
        return [f"kubelet stats not collected for node {node.name}: kubelet returned HTTP {status}"]
    try:
        summary, pods_found = filter_summary(json.loads(body), cfg["namespace"], set(node.pods))
    except (ValueError, AttributeError, KeyError, TypeError):
        return [f"kubelet stats not collected for node {node.name}: the kubelet's response could not be read"]
    # Create one file per node in the output directory troubleshoot.sh provides
    with open(os.path.join(cfg["out"], node.name + ".json"), "w") as f:
        json.dump(summary, f, indent=2)
    # Name each pod listed on this node but missing from the kubelet's stats.
    return [
        f"kubelet stats not collected for pod {pod}: not in node {node.name}'s stats"
        for pod in node.pods if pod not in pods_found
    ]

def collect(cfg, get_api, get_kubelet):
    if cfg["declined"]:
        info("kubelet stats not collected: declined at install (job.collectNodeMetrics is false)")
        return

    # The router's pods are listed through the API server, which is how we find their nodes.
    ns = urllib.parse.quote(cfg["namespace"], safe="")
    selector = urllib.parse.quote(cfg["selector"], safe="")
    status, body = get_api(f"/api/v1/namespaces/{ns}/pods?labelSelector={selector}")
    try:
        if status != 200:
            raise ValueError(f"HTTP {status}: {body[:500].decode(errors='replace')}")
        items = json.loads(body).get("items", [])
    except (ValueError, AttributeError) as e:
        warn(f"listing pods: {e}")
        info(f"kubelet stats not collected: could not list pods matching selector {cfg['selector']} in namespace {cfg['namespace']}")
        return
    if not items:
        info(f"kubelet stats not collected: no pods matched selector {cfg['selector']} in namespace {cfg['namespace']}")
        return

    # A pod with no node yet (still Pending) has nothing to ask the kubelet.
    nodes = {}
    for item in items:
        pod = item["metadata"]["name"]
        node_name = item.get("spec", {}).get("nodeName")
        ip = item.get("status", {}).get("hostIP")
        if not node_name or not ip:
            info(f"kubelet stats not collected for pod {pod}: pod has no node yet")
        else:
            if node_name not in nodes:
                nodes[node_name] = NodeInfo(node_name, ip, [pod])
            else:
                nodes[node_name].pods.append(pod)

    # Nodes are asked BATCH at a time.
    ordered = sorted(nodes.values(), key=lambda node: node.name)
    with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH) as pool:
        results = pool.map(lambda node: read_node(node, cfg, get_kubelet), ordered)
        for lines in results:
            for line in lines:
                info(line)

def config(env):
    """The settings the chart's wrapper and troubleshoot.sh pass in."""
    # A missing var means the wrapper is broken. 
    missing = [name for name in ("NAMESPACE", "SELECTOR", "KUBELET_DECLINED", "TS_OUTPUT_DIR") if name not in env]
    if missing:
        raise SystemExit("router-resource-usage: missing environment variable(s): " + ", ".join(missing))
    return {
        "namespace": env["NAMESPACE"],
        "selector": env["SELECTOR"],
        "declined": env["KUBELET_DECLINED"] == "1",
        "out": env["TS_OUTPUT_DIR"],
    }

def create_contexts():
    """Returns (api_ctx, kubelet_ctx), the TLS settings for the API server and the kubelet."""
    api_ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    # The kubelet's serving certificate is commonly self-signed or issued by a CA other
    # than the one mounted here so it is not verified.
    kubelet_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    kubelet_ctx.check_hostname = False
    kubelet_ctx.verify_mode = ssl.CERT_NONE
    return (api_ctx, kubelet_ctx)

def main():
    cfg = config(os.environ)
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    api_ctx, kubelet_ctx = create_contexts()

    collect(
        cfg,
        lambda path: request(API_HOST, 443, path, token, api_ctx),
        lambda ip, path: request(ip, KUBELET_PORT, path, token, kubelet_ctx),
    )

if __name__ == "__main__":
    main()
