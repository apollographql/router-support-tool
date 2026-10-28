"""Container memory and CPU for the router's pods, read from the kubelet.

The router-resource-usage collector of mode: job (specs/collection/base_spec.md ->
Kubelet stats collection). troubleshoot.sh runs it as a hostCollectors.run script inside
the Job's pod, started by a one-line sh wrapper that sets NAMESPACE, SELECTOR,
KUBELET_DECLINED and CADVISOR. It lists the pods matching SELECTOR through the API server,
asks each distinct node's kubelet once, and keeps only those pods. For a node whose kubelet
was declined, unreachable or refused, it asks the metrics API instead. Every missing file
gets a line on stdout saying why. Standard library only, and it always exits 0: empty is
not failure.
"""
import concurrent.futures
import http.client
import json
import os
import re
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


POD_LABEL = re.compile(r'(?:^|[{,])pod="([^"]*)"')
NS_LABEL = re.compile(r'(?:^|[{,])namespace="([^"]*)"')


def _family(name, known):
    if name in known:
        return name
    for suffix in ("_bucket", "_sum", "_count"):
        if name.endswith(suffix) and name[: -len(suffix)] in known:
            return name[: -len(suffix)]
    return name


def filter_cadvisor(text, namespace, wanted):
    """The kubelet's /metrics/cadvisor reduced to the wanted pods' series, each family's
    HELP and TYPE lines kept with its first series. Returns (text, pods found)."""
    meta = {}
    series = []
    for line in text.splitlines():
        if line.startswith("# HELP ") or line.startswith("# TYPE "):
            meta.setdefault(line.split(" ", 3)[2], []).append(line)
        elif line and not line.startswith("#"):
            pod = POD_LABEL.search(line)
            ns = NS_LABEL.search(line)
            if pod and pod.group(1) in wanted and ns and ns.group(1) == namespace:
                series.append(line)
    out, emitted, found = [], set(), set()
    for line in series:
        family = _family(re.split(r"[{ ]", line, maxsplit=1)[0], meta)
        if family not in emitted:
            emitted.add(family)
            out.extend(meta.get(family, []))
        out.append(line)
        found.add(POD_LABEL.search(line).group(1))
    return "".join(line + "\n" for line in out), found


def _write(directory, name, content):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "w") as f:
        f.write(content)


def read_node(node, ip, pods, cfg, get_kubelet):
    """One node's kubelet. Returns (lines to print, whether to fall back to the metrics API)."""
    lines = []
    node_dir = os.path.join(cfg["out"], node)
    ns = cfg["namespace"]

    status, body = get_kubelet(ip, "/stats/summary")
    if status == 0:
        return [f"kubelet stats not collected for node {node}: could not reach the kubelet at {ip}:{KUBELET_PORT}"], True
    if status != 200:
        return [f"kubelet stats not collected for node {node}: kubelet returned HTTP {status}"], True
    try:
        summary, found = filter_summary(json.loads(body), ns, set(pods))
    except (ValueError, AttributeError, KeyError, TypeError):
        return [f"kubelet stats not collected for node {node}: the kubelet's response could not be read"], False
    _write(node_dir, "stats-summary.json", json.dumps(summary, indent=2))
    for pod in pods:
        if pod not in found:
            lines.append(f"kubelet stats not collected for pod {pod}: not in node {node}'s stats")

    if cfg["cadvisor"]:
        status, body = get_kubelet(ip, "/metrics/cadvisor")
        if status == 0:
            lines.append(f"kubelet cadvisor metrics not collected for node {node}: could not reach the kubelet at {ip}:{KUBELET_PORT}")
        elif status != 200:
            lines.append(f"kubelet cadvisor metrics not collected for node {node}: kubelet returned HTTP {status}")
        else:
            try:
                text, _ = filter_cadvisor(body.decode(), ns, set(pods))
                _write(node_dir, "cadvisor.txt", text)
            except (ValueError, KeyError, TypeError):
                lines.append(f"kubelet cadvisor metrics not collected for node {node}: the kubelet's response could not be read")
    return lines, False


METRICS_API_REASONS = {
    404: "metrics.k8s.io not found",
    503: "service unavailable",
    403: "forbidden",
}


def metrics_fallback(fallback, cfg, get_api, say, warn):
    """The pods on nodes whose kubelet wasn't read, from the metrics API (metrics.k8s.io)."""
    ns = urllib.parse.quote(cfg["namespace"], safe="")
    sel = urllib.parse.quote(cfg["selector"], safe="")
    status, body = get_api(f"/apis/metrics.k8s.io/v1beta1/namespaces/{ns}/pods?labelSelector={sel}")
    if status != 200:
        warn(f"metrics API: HTTP {status}: {body[:500].decode(errors='replace')}")
        say(f"metrics API not available: {METRICS_API_REASONS.get(status, f'HTTP {status}')}")
        return
    try:
        items = json.loads(body).get("items", [])
        by_name = {
            i["metadata"]["name"]: i for i in items
            if i["metadata"].get("namespace") == cfg["namespace"]
        }
    except (ValueError, AttributeError, KeyError, TypeError):
        say("metrics API not available: response could not be read")
        return
    for node in sorted(fallback):
        found = [by_name[p] for p in fallback[node] if p in by_name]
        if found:
            _write(os.path.join(cfg["out"], node), "metrics-api.json", json.dumps({"items": found}, indent=2))
        for pod in fallback[node]:
            if pod not in by_name:
                say(f"metrics API has no entry for pod {pod}")


def collect(cfg, get_api, get_kubelet, say, warn):
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

    # A pod with no node yet (still Pending) has nothing to ask the kubelet or the metrics API.
    nodes = {}
    for item in items:
        name = item["metadata"]["name"]
        node = item.get("spec", {}).get("nodeName")
        ip = item.get("status", {}).get("hostIP")
        if not node or not ip:
            say(f"kubelet stats not collected for pod {name}: pod has no node yet")
        else:
            nodes.setdefault(node, (ip, []))[1].append(name)

    fallback = {}
    if cfg["declined"]:
        say("kubelet stats not collected: declined at install (job.collectNodeMetrics is false)")
        fallback = {node: pods for node, (_, pods) in nodes.items()}
    else:
        # Nodes are asked BATCH at a time, so a fleet of unreachable nodes costs about one
        # timeout per ten nodes instead of one per node.
        names = sorted(nodes)
        with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH) as pool:
            results = pool.map(
                lambda n: read_node(n, nodes[n][0], nodes[n][1], cfg, get_kubelet), names)
            for node, (lines, fell_back) in zip(names, results):
                for line in lines:
                    say(line)
                if fell_back:
                    fallback[node] = nodes[node][1]
    if fallback:
        metrics_fallback(fallback, cfg, get_api, say, warn)


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
        "cadvisor": os.environ.get("CADVISOR") == "1",
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
