"""Unit tests for testing/chainsaw/scripts/wait_for_kubelet_stats.py and memory_cpu_signals.py.

Run with: python3 -m unittest discover -s testing/unit
"""
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "chainsaw", "scripts")
SPEC_FILE = os.path.join(HERE, "..", "..", "specs", "collection", "base_spec.md")

# The script isn't on sys.path so it is loaded by path and its folder is added so
# that it can import memory_cpu_signals.
sys.path.insert(0, SCRIPTS)
spec = importlib.util.spec_from_file_location("wait_for_kubelet_stats", os.path.join(SCRIPTS, "wait_for_kubelet_stats.py"))
wait_for_kubelet_stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wait_for_kubelet_stats)

NAMESPACE = "demo"
SIGNALS = ["memory.availableBytes", "memory.psi", "cpu.psi"]

def create_container_stats(complete=True, name="router"):
    """One container's stats as the kubelet reports them. complete=False leaves out the late signals."""
    memory = {"usageBytes": 1}
    cpu = {"usageNanoCores": 1}
    if complete:
        memory.update({"availableBytes": 1, "psi": {}})
        cpu["psi"] = {}
    return {"name": name, "memory": memory, "cpu": cpu}

def create_node_summary(*containers, namespace=NAMESPACE):
    return {"pods": [{"podRef": {"name": "p", "namespace": namespace}, "containers": list(containers)}]}

class RoutersCompleteTests(unittest.TestCase):
    def test_complete_router_container(self):
        self.assertTrue(wait_for_kubelet_stats.routers_complete(create_node_summary(create_container_stats()), NAMESPACE, SIGNALS))

    def test_a_missing_signal_is_incomplete(self):
        self.assertFalse(wait_for_kubelet_stats.routers_complete(create_node_summary(create_container_stats(complete=False)), NAMESPACE, SIGNALS))

    def test_every_router_container_must_be_complete(self):
        self.assertFalse(wait_for_kubelet_stats.routers_complete(create_node_summary(create_container_stats(), create_container_stats(complete=False)), NAMESPACE, SIGNALS))

    def test_no_router_container_yet_is_incomplete(self):
        self.assertFalse(wait_for_kubelet_stats.routers_complete({"pods": []}, NAMESPACE, SIGNALS))

    def test_other_containers_and_namespaces_are_ignored(self):
        self.assertFalse(wait_for_kubelet_stats.routers_complete(create_node_summary(create_container_stats(), namespace="other"), NAMESPACE, SIGNALS))
        self.assertTrue(wait_for_kubelet_stats.routers_complete(create_node_summary(create_container_stats(), create_container_stats(complete=False, name="sidecar")), NAMESPACE, SIGNALS))

class WaitUntilCompleteTests(unittest.TestCase):
    # wait_until_complete is given this fake clock and sleep so the tests run instantly and
    # the 2 minute timeout can be reached without waiting.
    def setUp(self):
        self.now = 0
        # The length of each sleep the code asked for so tests can check whether it waited.
        self.sleeps = []

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def wait_with_fake_clock(self, read_kubelet, ips=("10.0.0.1",)):
        return wait_for_kubelet_stats.wait_until_complete(list(ips), read_kubelet, NAMESPACE, SIGNALS, sleep=self.sleep, monotonic=lambda: self.now)

    def test_complete_at_once_does_not_wait(self):
        self.assertEqual(self.wait_with_fake_clock(lambda ip: create_node_summary(create_container_stats())), ("complete", ""))
        self.assertEqual(self.sleeps, [])

    def test_waits_until_the_signals_arrive(self):
        incomplete = create_node_summary(create_container_stats(complete=False))
        complete = create_node_summary(create_container_stats())
        # The kubelet reports incomplete stats twice, then every signal.
        responses = [incomplete, incomplete, complete]

        # Each read of the kubelet gets the next response.
        result = self.wait_with_fake_clock(lambda ip: responses.pop(0))

        self.assertEqual(result, ("complete", ""))
        # Assert it waited for the signals
        # We should have slept after each incomplete read and not after the complete one
        self.assertEqual(len(self.sleeps), 2)

    def test_every_node_must_be_complete(self):
        by_ip = {"10.0.0.1": create_node_summary(create_container_stats()), "10.0.0.2": create_node_summary(create_container_stats(complete=False))}
        result, detail = self.wait_with_fake_clock(lambda ip: by_ip[ip], ips=("10.0.0.1", "10.0.0.2"))
        self.assertEqual((result, detail), ("timeout", "10.0.0.2"))

    def test_gives_up_after_the_timeout(self):
        result, _ = self.wait_with_fake_clock(lambda ip: create_node_summary(create_container_stats(complete=False)))
        self.assertEqual(result, "timeout")
        self.assertGreaterEqual(self.now, wait_for_kubelet_stats.TIMEOUT_SECONDS)

    def test_an_unreachable_kubelet_is_not_waited_for(self):
        def refuse(ip):
            raise ConnectionRefusedError("refused")
        result, detail = self.wait_with_fake_clock(refuse)
        self.assertEqual(result, "unreadable")
        self.assertIn("10.0.0.1", detail)
        self.assertEqual(self.sleeps, [])

    def test_a_refused_request_is_not_waited_for(self):
        def forbidden(ip):
            raise urllib.error.HTTPError("https://x", 403, "Forbidden", {}, None)
        result, detail = self.wait_with_fake_clock(forbidden)
        self.assertEqual(result, "unreadable")
        self.assertIn("403", detail)

class RouterNodeIpsTests(unittest.TestCase):
    def kubectl_prints(self, stdout):
        """Returns a context manager inside which running kubectl appears to print stdout and succeed."""
        # Replaces subprocess.run, which router_node_ips calls to run kubectl, so no kubectl runs.
        # The fake returns a finished process with exit code 0 and the given output.
        fake_result = subprocess.CompletedProcess([], 0, stdout=stdout)
        return mock.patch.object(wait_for_kubelet_stats.subprocess, "run", return_value=fake_result)

    def test_lists_each_node_once_in_order(self):
        with self.kubectl_prints("10.0.0.2 10.0.0.1 10.0.0.2"):
            self.assertEqual(wait_for_kubelet_stats.router_node_ips(NAMESPACE, "app=router"), ["10.0.0.1", "10.0.0.2"])

    def test_no_pod_with_a_node_gives_no_addresses(self):
        with self.kubectl_prints(""):
            self.assertEqual(wait_for_kubelet_stats.router_node_ips(NAMESPACE, "app=router"), [])

    def test_a_failing_kubectl_is_reported_and_not_fatal(self):
        # What subprocess.run raises when kubectl exits with an error
        kubectl_fails = subprocess.CalledProcessError(1, "kubectl", stderr="forbidden\n")
        captured_stderr = io.StringIO()

        # Make running kubectl raise that error and collect what the script prints to stderr.
        with mock.patch.object(wait_for_kubelet_stats.subprocess, "run", side_effect=kubectl_fails), \
                contextlib.redirect_stderr(captured_stderr):
            exit_code = wait_for_kubelet_stats.main(["wait_for_kubelet_stats.py", NAMESPACE, "app=router"])

        # Check it still exits 0 so the scenario continues
        self.assertEqual(exit_code, 0)
        self.assertIn("kubectl failed: forbidden", captured_stderr.getvalue())

    def test_a_missing_kubectl_is_reported_and_not_fatal(self):
        # What subprocess.run raises when the kubectl program can't be found.
        kubectl_missing = FileNotFoundError(2, "No such file or directory", "kubectl")
        captured_stderr = io.StringIO()

        with mock.patch.object(wait_for_kubelet_stats.subprocess, "run", side_effect=kubectl_missing), \
                contextlib.redirect_stderr(captured_stderr):
            exit_code = wait_for_kubelet_stats.main(["wait_for_kubelet_stats.py", NAMESPACE, "app=router"])

        # It still exits 0, so the scenario goes on, and says why it is not waiting.
        self.assertEqual(exit_code, 0)
        self.assertIn("could not run kubectl", captured_stderr.getvalue())


class DocumentedSignalsTests(unittest.TestCase):
    def test_the_spec_documents_the_signals_the_wait_relies_on(self):
        with open(SPEC_FILE) as f:
            signals = wait_for_kubelet_stats.documented_signals(f.read(), "kubelet Summary API")
        self.assertIn("memory.availableBytes", signals)
        self.assertIn("cpu.psi", signals)


if __name__ == "__main__":
    unittest.main()
