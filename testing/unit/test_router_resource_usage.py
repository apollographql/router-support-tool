"""Unit tests for router-diagnostics-chart/files/router-resource-usage.py.

Run with: python3 -m unittest discover -s testing/unit
"""
import http.client
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock

# The script's name has hyphens and its folder isn't on sys.path so it must be imported this way.
HERE = os.path.dirname(os.path.abspath(__file__))
PATH =os.path.join(HERE, "..", "..", "router-diagnostics-chart", "files", "router-resource-usage.py")
spec = importlib.util.spec_from_file_location("router_resource_usage", PATH)
rru = importlib.util.module_from_spec(spec) # rru (router-resource-usage) is the loaded script
spec.loader.exec_module(rru)

NAMESPACE = "demo"
SELECTOR = "app=router"
LOCALHOST = "127.0.0.1"
TOKEN = "token"
# The kubelet addresses of nodes n1 and n2.
N1_IP = "10.0.0.1"
N2_IP = "10.0.0.2"

def http_response(status, body):
    """Builds a raw HTTP/1.1 response, as bytes, for the fake server to send."""
    header = f"HTTP/1.1 {status} X\r\nContent-Length: {len(body)}\r\n\r\n"
    return header.encode() + body

def pod_item(name, node="n1", ip=N1_IP):
    """Builds a pod as the API server lists it. node=None or ip=None leaves that field out, like a Pending pod."""
    item = {"metadata": {"name": name}, "spec": {}, "status": {}}
    if node:
        item["spec"]["nodeName"] = node
    if ip:
        item["status"]["hostIP"] = ip
    return item

def summary(*pods, node="n1", namespace=NAMESPACE):
    """Builds a fake kubelet /stats/summary reply for `node` that lists the named pods."""
    return {
        "node": {"nodeName": node, "memory": {"availableBytes": 1}},
        "pods": [
            {"podRef": {"name": p, "namespace": namespace}, "containers": [{"name": "router"}]}
            for p in pods
        ],
    }


class Run:
    """Runs collect() against canned responses and records what it printed."""

    def __init__(self, test, pods=None, list_status=200, kubelet_replies=None, declined=False):
        self.out = []
        self.err = []
        self.api_calls = []
        self.kubelet_calls = []
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        cfg = {"namespace": NAMESPACE, "selector": SELECTOR, "declined": declined, "out": self.dir.name}
        kubelet_replies = kubelet_replies or {}

        def get_api(path):
            self.api_calls.append(path)
            assert path.startswith(f"/api/v1/namespaces/{NAMESPACE}/pods")
            # Assert the SELECTOR, URL-encoded, is in the path
            assert "labelSelector=app%3Drouter" in path
            list_body = json.dumps({"items": pods or []}).encode()
            return list_status, list_body

        def get_kubelet(ip, path):
            self.kubelet_calls.append((ip, path))
            return kubelet_replies.get((ip, path), (0, b"refused"))

        # collect() reports through the script's info() and warn() functions. While this
        # block runs they are replaced so every line collect() prints is stored there
        # for the tests to check.
        with mock.patch.object(rru, "info", self.out.append), \
                mock.patch.object(rru, "warn", self.err.append):
            rru.collect(cfg, get_api, get_kubelet)

    def file(self, *parts):
        return os.path.join(self.dir.name, *parts)

    def read(self, *parts):
        with open(self.file(*parts)) as f:
            return f.read()

    def files(self):
        found = []
        for root, _, names in os.walk(self.dir.name):
            found += [os.path.relpath(os.path.join(root, n), self.dir.name) for n in names]
        return sorted(found)


class FilterTests(unittest.TestCase):
    def test_summary_keeps_only_wanted_pods_in_the_namespace(self):
        data = summary("router-a", "other")
        data["pods"].append({"podRef": {"name": "router-a", "namespace": "elsewhere"}})
        out, pods_found = rru.filter_summary(data, NAMESPACE, {"router-a"})
        self.assertEqual(pods_found, ["router-a"])
        self.assertEqual([p["podRef"]["namespace"] for p in out["pods"]], [NAMESPACE])
        self.assertEqual(out["node"]["nodeName"], "n1")


class CollectTests(unittest.TestCase):
    def test_kubelet_read_keeps_only_the_routers_pods(self):
        # The API server lists only router-a but the kubelet's reply also has
        # "not-router" which should be filtered out.
        r = Run(self, pods=[pod_item("router-a")],
                kubelet_replies={(N1_IP, "/stats/summary"): (200, json.dumps(summary("router-a", "not-router")).encode())})
        self.assertEqual(r.out, [])
        self.assertEqual(r.files(), ["n1.json"])
        names = [p["podRef"]["name"] for p in json.loads(r.read("n1.json"))["pods"]]
        self.assertEqual(names, ["router-a"])

    def test_one_request_per_node(self):
        # Both pods are on node 1 so the kubelet should be asked once.
        pods = [pod_item("a"), pod_item("b")]
        reply = (200, json.dumps(summary("a", "b")).encode())
        r = Run(self, pods=pods, kubelet_replies={(N1_IP, "/stats/summary"): reply})
        self.assertEqual(r.kubelet_calls, [(N1_IP, "/stats/summary")])

    def test_each_node_gets_its_own_file(self):
        pods = [pod_item("a", "n1", N1_IP), pod_item("b", "n2", N2_IP)]
        r = Run(self, pods=pods, kubelet_replies={
            (N1_IP, "/stats/summary"): (200, json.dumps(summary("a")).encode()),
            (N2_IP, "/stats/summary"): (200, json.dumps(summary("b", node="n2")).encode())})
        self.assertEqual(r.out, [])
        self.assertEqual(r.files(), ["n1.json", "n2.json"])
        # Each file holds its own node's stats.
        self.assertEqual(json.loads(r.read("n1.json"))["node"]["nodeName"], "n1")
        self.assertEqual(json.loads(r.read("n2.json"))["node"]["nodeName"], "n2")

    def test_cannot_list_pods(self):
        r = Run(self, list_status=403)
        self.assertEqual(r.out, [f"kubelet stats not collected: could not list pods matching selector {SELECTOR} in namespace {NAMESPACE}"])
        self.assertIn("HTTP 403", r.err[0])

    def test_no_pods_match(self):
        r = Run(self, pods=[])
        self.assertEqual(r.out, [f"kubelet stats not collected: no pods matched selector {SELECTOR} in namespace {NAMESPACE}"])

    def test_declined_writes_only_its_line_and_asks_nothing(self):
        r = Run(self, pods=[pod_item("a")], declined=True,
                kubelet_replies={(N1_IP, "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected: declined at install (job.collectNodeMetrics is false)"])
        self.assertEqual(r.api_calls, [])
        self.assertEqual(r.files(), [])

    def test_pending_pod_is_named_and_not_retried(self):
        r = Run(self, pods=[pod_item("p", node=None, ip=None)])
        self.assertEqual(r.out, ["kubelet stats not collected for pod p: pod has no node yet"])
        self.assertEqual(r.files(), [])

    def test_unreachable_kubelet_is_named(self):
        r = Run(self, pods=[pod_item("a")])
        self.assertEqual(r.out, [f"kubelet stats not collected for node n1: could not reach the kubelet at {N1_IP}:10250"])
        self.assertEqual(r.files(), [])

    def test_refused_kubelet_is_named(self):
        for status in (401, 403):
            r = Run(self, pods=[pod_item("a")], kubelet_replies={(N1_IP, "/stats/summary"): (status, b"")})
            self.assertEqual(r.out, [f"kubelet stats not collected for node n1: kubelet returned HTTP {status}"])
            self.assertEqual(r.files(), [])

    def test_unreadable_kubelet_response_is_named(self):
        r = Run(self, pods=[pod_item("a")], kubelet_replies={(N1_IP, "/stats/summary"): (200, b"<html>")})
        self.assertEqual(r.out, ["kubelet stats not collected for node n1: the kubelet's response could not be read"])
        self.assertEqual(r.files(), [])

    def test_pod_missing_from_the_nodes_stats(self):
        r = Run(self, pods=[pod_item("a"), pod_item("gone")],
                kubelet_replies={(N1_IP, "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected for pod gone: not in node n1's stats"])
        self.assertEqual(r.files(), ["n1.json"])

    def test_a_failed_node_does_not_stop_the_others(self):
        pods = [pod_item("a", "n1", N1_IP), pod_item("b", "n2", N2_IP)]
        r = Run(self, pods=pods, kubelet_replies={(N2_IP, "/stats/summary"): (200, json.dumps(summary("b", node="n2")).encode())})
        self.assertEqual(r.out, [f"kubelet stats not collected for node n1: could not reach the kubelet at {N1_IP}:10250"])
        self.assertEqual(r.files(), ["n2.json"])


class RequestTests(unittest.TestCase):
    """Call request() against a real local socket. The TLS layer is swapped for HTTP so
    these tests cover the timeout behavior, not the handshake."""

    def serve(self, handler):
        """Serves one connection on a free local port. Returns the port."""
        listener = socket.socket()
        listener.bind((LOCALHOST, 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        threading.Thread(target=self.handle_one, args=(listener, handler), daemon=True).start()
        return listener.getsockname()[1]

    def handle_one(self, listener, handler):
        """Accepts one connection and lets handler respond to it."""
        conn, _ = listener.accept()
        # The request it receives is kept in self.received.
        self.received = conn.recv(4096)
        try:
            # handler sends the response.
            handler(conn)
        except OSError:
            pass
        conn.close()

    def send_request(self, port, limit=1):
        # request() makes an HTTPS connection and since the fake server uses HTTP this
        # takes the place of HTTPSConnection and ignores the TLS context.
        plain_http = lambda host, port, timeout, context: http.client.HTTPConnection(host, port, timeout=timeout)
        # Two patches that are undone when this block ends:
        # 1. HTTPSConnection becomes plain_http so request() connects without TLS.
        # 2. REQUEST_TIMEOUT_SECONDS becomes limit so the timeout tests don't wait the full 30 seconds.
        with mock.patch.object(rru.http.client, "HTTPSConnection", plain_http), \
                mock.patch.object(rru, "REQUEST_TIMEOUT_SECONDS", limit):
            return rru.request(LOCALHOST, port, "/", TOKEN, None)

    def test_returns_the_status_and_body(self):
        port = self.serve(lambda c: c.sendall(http_response(200, b"ok")))
        status, body = self.send_request(port)
        self.assertEqual(status, 200)
        self.assertEqual(body, b"ok")

    def test_sends_the_token_as_a_bearer_header(self):
        port = self.serve(lambda c: c.sendall(http_response(200, b"ok")))
        self.send_request(port)
        # The request was stored before the response was sent.
        self.assertIn(f"Authorization: Bearer {TOKEN}\r\n".encode(), self.received)

    def test_a_server_that_trickles_bytes_is_cut_off_at_the_limit(self):
        def trickle(conn):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
            # Send one byte every 0.1s for 6s, much longer than the 1s limit.
            # Only a deadline on the whole request can stop it.
            for _ in range(60):
                conn.sendall(b"x")
                time.sleep(0.1)
        self.assertEqual(self.send_request(self.serve(trickle)), (0, b"timed out"))

    def test_a_server_that_goes_silent_after_the_headers_is_cut_off_at_the_limit(self):
        def stall(conn):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
            time.sleep(6)
        self.assertEqual(self.send_request(self.serve(stall)), (0, b"timed out"))

    def test_a_refused_connection_names_the_error_not_a_timeout(self):
        listener = socket.socket()
        listener.bind((LOCALHOST, 0))
        port = listener.getsockname()[1]
        listener.close()
        status, body = self.send_request(port)
        self.assertEqual(status, 0)
        self.assertNotEqual(body, b"timed out")


class ConfigTests(unittest.TestCase):
    ENV = {"NAMESPACE": NAMESPACE, "SELECTOR": SELECTOR, "KUBELET_DECLINED": "0", "TS_OUTPUT_DIR": "/out"}

    def test_reads_the_four_settings(self):
        self.assertEqual(rru.config(self.ENV),
                         {"namespace": NAMESPACE, "selector": SELECTOR, "declined": False, "out": "/out"})

    def test_declined_only_when_kubelet_declined_set(self):
        self.assertTrue(rru.config({**self.ENV, "KUBELET_DECLINED": "1"})["declined"])
        self.assertFalse(rru.config({**self.ENV, "KUBELET_DECLINED": "0"})["declined"])

    def test_a_missing_setting_fails_instead_of_defaulting(self):
        for name in self.ENV:
            # The standard environment minus this one setting.
            env_with_missing_var = {k: v for k, v in self.ENV.items() if k != name}
            # config must exit naming the variable and not fall back to a default.
            with self.subTest(missing=name), self.assertRaises(SystemExit) as raised:
                rru.config(env_with_missing_var)
            self.assertIn(name, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
