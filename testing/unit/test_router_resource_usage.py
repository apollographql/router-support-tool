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


CADVISOR = (
    '# HELP container_memory_usage_bytes usage\n'
    '# TYPE container_memory_usage_bytes gauge\n'
    'container_memory_usage_bytes{namespace="demo",pod="router-a"} 5\n'
    'container_memory_usage_bytes{namespace="demo",pod="other"} 6\n'
    'container_memory_usage_bytes{namespace="elsewhere",pod="router-a"} 7\n'
    '# HELP unrelated nope\n'
    'unrelated{pod="router-a",namespace="demo"} 1\n'
)


class Run:
    """Runs collect() against canned responses and records what it printed."""

    def __init__(self, test, pods=None, list_status=200, kubelet=None, metrics=None,
                 declined=False, cadvisor=False):
        self.out = []
        self.err = []
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        cfg = {"namespace": NS, "selector": "app=router", "declined": declined,
               "cadvisor": cadvisor, "out": self.dir.name}
        kubelet = kubelet or {}
        metrics = metrics if metrics is not None else (404, b"{}")

        def get_api(path):
            if path.startswith("/api/v1/namespaces/demo/pods"):
                assert "labelSelector=app%3Drouter" in path
                body = json.dumps({"items": pods or []}).encode()
                return list_status, body
            assert path.startswith("/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods")
            return metrics

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

    def test_cadvisor_keeps_wanted_series_with_their_help_and_type(self):
        text, found = rru.filter_cadvisor(CADVISOR, NS, {"router-a"})
        self.assertEqual(found, {"router-a"})
        self.assertIn('pod="router-a"', text)
        self.assertNotIn('pod="other"', text)
        self.assertNotIn('namespace="elsewhere"', text)
        self.assertIn("# TYPE container_memory_usage_bytes gauge", text)
        self.assertEqual(text.count("# HELP container_memory_usage_bytes"), 1)
        self.assertIn("# HELP unrelated nope", text)


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
        cfg = {"namespace": NS, "selector": "x", "declined": False, "cadvisor": False,
               "out": tempfile.mkdtemp()}
        rru.collect(cfg, lambda p: (200, json.dumps({"items": pods}).encode()),
                    lambda ip, p: calls.append((ip, p)) or (200, body), lambda l: None, lambda l: None)
        self.assertEqual(calls, [("10.0.0.1", "/stats/summary")])

    def test_cadvisor_only_when_asked(self):
        k = {("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("router-a")).encode()),
             ("10.0.0.1", "/metrics/cadvisor"): (200, CADVISOR.encode())}
        self.assertEqual(Run(self, pods=[pod_item("router-a")], kubelet=k).files(), ["n1/stats-summary.json"])
        r = Run(self, pods=[pod_item("router-a")], kubelet=k, cadvisor=True)
        self.assertEqual(r.files(), ["n1/cadvisor.txt", "n1/stats-summary.json"])
        self.assertNotIn('pod="other"', r.read("n1", "cadvisor.txt"))

    def test_cadvisor_refusal_is_named_and_keeps_the_summary(self):
        k = {("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("router-a")).encode()),
             ("10.0.0.1", "/metrics/cadvisor"): (403, b"")}
        r = Run(self, pods=[pod_item("router-a")], kubelet=k, cadvisor=True)
        self.assertEqual(r.out, ["kubelet cadvisor metrics not collected for node n1: kubelet returned HTTP 403"])
        self.assertEqual(r.files(), ["n1/stats-summary.json"])

    def test_cannot_list_pods(self):
        r = Run(self, list_status=403)
        self.assertEqual(r.out, ["kubelet stats not collected: could not list pods matching selector app=router in namespace demo"])
        self.assertIn("HTTP 403", r.err[0])

    def test_no_pods_match(self):
        r = Run(self, pods=[])
        self.assertEqual(r.out, ["kubelet stats not collected: no pods matched selector app=router in namespace demo"])

    def test_pending_pod_is_named_and_not_retried(self):
        r = Run(self, pods=[pod_item("p", node=None, ip=None)])
        self.assertEqual(r.out, ["kubelet stats not collected for pod p: pod has no node yet"])
        self.assertEqual(r.files(), [])

    def test_pod_missing_from_the_nodes_stats(self):
        r = Run(self, pods=[pod_item("a"), pod_item("gone")],
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected for pod gone: not in node n1's stats"])

    def test_unreadable_kubelet_response_is_not_retried(self):
        r = Run(self, pods=[pod_item("a")], kubelet={("10.0.0.1", "/stats/summary"): (200, b"<html>")})
        self.assertEqual(r.out, ["kubelet stats not collected for node n1: the kubelet's response could not be read"])
        self.assertEqual(r.files(), [])

    def test_unreachable_kubelet_falls_back_to_the_metrics_api(self):
        usage = {"items": [
            {"metadata": {"name": "a", "namespace": NS}, "containers": [{"name": "router", "usage": {"cpu": "3m"}}]},
            {"metadata": {"name": "a", "namespace": "elsewhere"}, "containers": []}]}
        r = Run(self, pods=[pod_item("a"), pod_item("b")], metrics=(200, json.dumps(usage).encode()))
        self.assertEqual(r.out, [
            "kubelet stats not collected for node n1: could not reach the kubelet at 10.0.0.1:10250",
            "metrics API has no entry for pod b"])
        self.assertEqual(r.files(), ["n1/metrics-api.json"])
        items = json.loads(r.read("n1", "metrics-api.json"))["items"]
        self.assertEqual([i["metadata"]["namespace"] for i in items], [NS])

    def test_refused_kubelet_falls_back_and_is_named(self):
        r = Run(self, pods=[pod_item("a")], kubelet={("10.0.0.1", "/stats/summary"): (403, b"")},
                metrics=(404, b"{}"))
        self.assertEqual(r.out, [
            "kubelet stats not collected for node n1: kubelet returned HTTP 403",
            "metrics API not available: metrics.k8s.io not found"])

    def test_metrics_api_failures_are_named(self):
        for status, reason in [(404, "metrics.k8s.io not found"), (503, "service unavailable"),
                               (403, "forbidden"), (500, "HTTP 500")]:
            r = Run(self, pods=[pod_item("a")], metrics=(status, b"{}"))
            self.assertEqual(r.out[-1], f"metrics API not available: {reason}")
            self.assertEqual(r.files(), [])

    def test_declined_goes_straight_to_the_metrics_api(self):
        usage = {"items": [{"metadata": {"name": "a", "namespace": NS}, "containers": []}]}
        r = Run(self, pods=[pod_item("a")], declined=True, metrics=(200, json.dumps(usage).encode()),
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.out, ["kubelet stats not collected: declined at install (job.collectNodeMetrics is false)"])
        self.assertEqual(r.files(), ["n1/metrics-api.json"])

    def test_only_failed_nodes_fall_back(self):
        pods = [pod_item("a", "n1", "10.0.0.1"), pod_item("b", "n2", "10.0.0.2")]
        usage = {"items": [{"metadata": {"name": "b", "namespace": NS}, "containers": []}]}
        r = Run(self, pods=pods, metrics=(200, json.dumps(usage).encode()),
                kubelet={("10.0.0.1", "/stats/summary"): (200, json.dumps(summary("a")).encode())})
        self.assertEqual(r.files(), ["n1/stats-summary.json", "n2/metrics-api.json"])


if __name__ == "__main__":
    unittest.main()
