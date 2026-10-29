"""Unit tests for router-diagnostics-chart/files/router-resource-usage.py.

Run with: python3 -m unittest discover -s testing/unit
The collector's HTTP calls are replaced by fakes, so no cluster is needed. What a real
kubelet returns is covered by the chainsaw tests.
"""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "..", "router-diagnostics-chart", "files", "router-resource-usage.py")
spec = importlib.util.spec_from_file_location("router_resource_usage", PATH)
rru = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rru)

NS = "demo"


def pod_item(name, node="n1", ip="10.0.0.1"):
    item = {"metadata": {"name": name}, "spec": {}, "status": {}}
    if node:
        item["spec"]["nodeName"] = node
    if ip:
        item["status"]["hostIP"] = ip
    return item


def summary(*pods, namespace=NS):
    return {
        "node": {"nodeName": "n1", "memory": {"availableBytes": 1}},
        "pods": [
            {"podRef": {"name": p, "namespace": namespace}, "containers": [{"name": "router"}]}
            for p in pods
        ],
    }


class Run:
    """Runs collect() against canned responses and records what it printed."""

    def __init__(self, test, pods=None, list_status=200, kubelet=None, declined=False):
        self.out = []
        self.err = []
        self.api_calls = []
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        cfg = {"namespace": NS, "selector": "app=router", "declined": declined, "out": self.dir.name}
        kubelet = kubelet or {}

        def get_api(path):
            self.api_calls.append(path)
            assert path.startswith("/api/v1/namespaces/demo/pods")
            assert "labelSelector=app%3Drouter" in path
            return list_status, json.dumps({"items": pods or []}).encode()

        def get_kubelet(ip, path):
            return kubelet.get((ip, path), (0, b"refused"))

        rru.collect(cfg, get_api, get_kubelet, self.out.append, self.err.append)

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
        out, found = rru.filter_summary(data, NS, {"router-a"})
        self.assertEqual(found, ["router-a"])
        self.assertEqual([p["podRef"]["namespace"] for p in out["pods"]], [NS])
        self.assertEqual(out["node"]["nodeName"], "n1")


class CollectTests(unittest.TestCase):
    def test_kubelet_read_keeps_only_the_routers_pods(self):
        r = Run(self, pods=[pod_item("router-a")],
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("router-a", "other")).encode())})
        self.assertEqual(r.out, [])
        self.assertEqual(r.files(), ["n1/stats-summary.json"])
        names = [p["podRef"]["name"] for p in json.loads(r.read("n1", "stats-summary.json"))["pods"]]
        self.assertEqual(names, ["router-a"])

    def test_one_request_per_node(self):
        calls = []
        pods = [pod_item("a"), pod_item("b")]
        body = json.dumps(summary("a", "b")).encode()
        cfg = {"namespace": NS, "selector": "x", "declined": False, "out": tempfile.mkdtemp()}
        rru.collect(cfg, lambda p: (200, json.dumps({"items": pods}).encode()),
                    lambda ip, p: calls.append((ip, p)) or (200, body), lambda l: None, lambda l: None)
        self.assertEqual(calls, [("10.0.0.1", "/stats/summary")])

    def test_each_node_gets_its_own_file(self):
        pods = [pod_item("a", "n1", "10.0.0.1"), pod_item("b", "n2", "10.0.0.2")]
        r = Run(self, pods=pods, kubelet={
            ("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode()),
            ("10.0.0.2", "/stats/summary"): (200, json.dumps(summary("b")).encode())})
        self.assertEqual(r.out, [])
        self.assertEqual(r.files(), ["n1/stats-summary.json", "n2/stats-summary.json"])

    def test_cannot_list_pods(self):
        r = Run(self, list_status=403)
        self.assertEqual(r.out, ["kubelet stats not collected: could not list pods matching selector app=router in namespace demo"])
        self.assertIn("HTTP 403", r.err[0])

    def test_no_pods_match(self):
        r = Run(self, pods=[])
        self.assertEqual(r.out, ["kubelet stats not collected: no pods matched selector app=router in namespace demo"])

    def test_declined_writes_only_its_line_and_asks_nothing(self):
        r = Run(self, pods=[pod_item("a")], declined=True,
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected: declined at install (job.collectNodeMetrics is false)"])
        self.assertEqual(r.api_calls, [])
        self.assertEqual(r.files(), [])

    def test_pending_pod_is_named_and_not_retried(self):
        r = Run(self, pods=[pod_item("p", node=None, ip=None)])
        self.assertEqual(r.out, ["kubelet stats not collected for pod p: pod has no node yet"])
        self.assertEqual(r.files(), [])

    def test_unreachable_kubelet_is_named(self):
        r = Run(self, pods=[pod_item("a")])
        self.assertEqual(r.out, ["kubelet stats not collected for node n1: could not reach the kubelet at 10.0.0.1:10250"])
        self.assertEqual(r.files(), [])

    def test_refused_kubelet_is_named(self):
        for status in (401, 403):
            r = Run(self, pods=[pod_item("a")], kubelet={("10.0.0.1", "/stats/summary"): (status, b"")})
            self.assertEqual(r.out, [f"kubelet stats not collected for node n1: kubelet returned HTTP {status}"])
            self.assertEqual(r.files(), [])

    def test_unreadable_kubelet_response_is_named(self):
        r = Run(self, pods=[pod_item("a")], kubelet={("10.0.0.1", "/stats/summary"): (200, b"<html>")})
        self.assertEqual(r.out, ["kubelet stats not collected for node n1: the kubelet's response could not be read"])
        self.assertEqual(r.files(), [])

    def test_pod_missing_from_the_nodes_stats(self):
        r = Run(self, pods=[pod_item("a"), pod_item("gone")],
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected for pod gone: not in node n1's stats"])
        self.assertEqual(r.files(), ["n1/stats-summary.json"])

    def test_a_failed_node_does_not_stop_the_others(self):
        pods = [pod_item("a", "n1", "10.0.0.1"), pod_item("b", "n2", "10.0.0.2")]
        r = Run(self, pods=pods, kubelet={("10.0.0.2", "/stats/summary"): (200, json.dumps(summary("b")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected for node n1: could not reach the kubelet at 10.0.0.1:10250"])
        self.assertEqual(r.files(), ["n2/stats-summary.json"])


if __name__ == "__main__":
    unittest.main()
