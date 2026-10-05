#!/usr/bin/env python3

import importlib.util
import ipaddress
import hashlib
import hmac
import io
import json
import socket
import threading
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = tempfile.mkdtemp()
RUN_DIR = os.path.join(ROOT, "run")
STATE_DIR = os.path.join(ROOT, "state")
os.environ.update({
    "NODE_NAME": "n1", "PEERS": "p1 p2", "RUNTIME_DIRECTORY": RUN_DIR,
    "FENCE_MARKER": os.path.join(STATE_DIR, "fenced"), "FENCE_MODE": "enforce",
})
SCRIPT = pathlib.Path(__file__).with_name("self-fence.py")
SPEC = importlib.util.spec_from_file_location("self_fence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

REBOOT = ["systemctl", "reboot", "--force"]
REBOOT_HARDER = ["systemctl", "reboot", "--force", "--force"]
POWEROFF = ["systemctl", "poweroff", "--force"]
START = ["systemctl", "start", "--no-block", "k3s.service"]


def probes(ready=(), api=(), accepts=(), refused=(), released=(), held=(), fenced=(), states=None):
    # An API server that is ready also answers, and holds the node unless released.
    def release(s):
        if s in released:
            return "released"
        return "held" if s in held or s in api else "no-answer"
    del refused  # only accepted connections affect the unchanged classification
    def peer(s):
        return (states or {}).get(s, {"ok": s in fenced, "node": s, "mode": "enforce",
                                     "classification": "fenced", "fenced": s in fenced,
                                     "k3s_active": False})
    return (lambda s: s in ready, lambda s: s in api, lambda s: s in accepts, peer, release)


HEALTHY = probes(ready={"127.0.0.1"})
ISOLATED = probes()
NOT_READY = probes(api={"p1"}, accepts={"p1"})  # cluster up, this Node not Ready
ACCEPTING = probes(accepts={"p1"})  # API port open, no API ready: outage
REACHABLE = probes(refused={"p1"})  # host answers, API port closed
FENCED = probes(fenced={"p1"})  # one authenticated, enforcing, fenced peer


def state(node="p1", **fields):
    return {"node": node, "boot_id": "test-boot", "mode": "enforce", "classification": "fenced",
            "fenced": True, "k3s_active": False, "since_unfence": None,
            "refence_window": 900, "release_rule": None, "release_peers": [], **fields}


class EndpointTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        key_file = pathlib.Path(directory.name) / "key"
        key_file.write_bytes(b" test-only-key\n")
        self.key_file = str(key_file)
        self.key = MODULE.state_key(self.key_file)
        self.assertEqual(self.key, hmac.digest(b"test-only-key", b"node-self-fence state v1", "sha256"))
        self.agent = mock.Mock()
        self.agent.snapshot.return_value = state()
        self.server = MODULE.StateServer(("127.0.0.1", 0), self.agent, self.key_file)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.port = self.server.server_address[1]

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(1)

    def signed(self, **fields):
        payload = state(nonce="a" * 64, address="127.0.0.1", **fields)
        return {"state": payload, "mac": hmac.new(self.key, MODULE.canonical(payload),
                                                  hashlib.sha256).hexdigest()}

    def test_round_trip_with_temp_key_and_fresh_nonce(self):
        for _ in range(2):
            self.assertEqual(MODULE.peer_state("127.0.0.1", self.key_file, self.port),
                             {"ok": True, **state()})
        with mock.patch.object(MODULE.secrets, "token_hex", wraps=MODULE.secrets.token_hex) as nonce:
            MODULE.peer_state("127.0.0.1", self.key_file, self.port)
        nonce.assert_called_once_with(32)
        self.assertNotIn("nonce", self.agent.snapshot.return_value)

    def test_signed_release_fields_survive_round_trip(self):
        for rule in ("fenced-peers", "released", "manual", "observe", None):
            self.agent.snapshot.return_value = state(
                release_rule=rule, release_peers=["n1", "p2"] if rule == "fenced-peers" else [])
            self.assertEqual(MODULE.peer_state("127.0.0.1", self.key_file, self.port),
                             {"ok": True, **self.agent.snapshot.return_value})

    def test_key_rotation_is_used_by_next_server_request_and_client_probe(self):
        old_key = self.key
        replacement = pathlib.Path(self.key_file).with_name("replacement-key")
        replacement.write_bytes(b"rotated-test-key")
        replacement.replace(self.key_file)
        new_key = MODULE.state_key(self.key_file)
        self.assertNotEqual(new_key, old_key)
        with mock.patch.object(MODULE, "verify_state", wraps=MODULE.verify_state) as verify:
            self.assertTrue(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])
        self.assertEqual(verify.call_args.args[1], new_key)
        response, _, nonce, address = verify.call_args.args
        self.assertEqual(MODULE.verify_state(response, old_key, nonce, address)["error"],
                         "unauthenticated")

    def test_key_appearing_after_server_start_needs_no_restart(self):
        os.remove(self.key_file)
        self.assertIsNone(MODULE.state_key(self.key_file))
        self.assertEqual(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["error"], "no key")
        # A client with a key also fails while the running server has no key.
        client_key = pathlib.Path(self.key_file).with_name("client-key")
        client_key.write_bytes(b"test-only-key")
        self.assertFalse(MODULE.peer_state("127.0.0.1", str(client_key), self.port)["ok"])
        pathlib.Path(self.key_file).write_bytes(b"test-only-key")
        self.assertTrue(MODULE.peer_state("127.0.0.1", str(client_key), self.port)["ok"])

    def test_key_errors_return_none(self):
        for path in ("", str(pathlib.Path(self.key_file).parent), self.key_file + ".missing"):
            self.assertIsNone(MODULE.state_key(path))
        pathlib.Path(self.key_file).write_bytes(b" \n")
        self.assertIsNone(MODULE.state_key(self.key_file))

    def test_source_filter_rejects_before_taking_a_slot(self):
        request = mock.Mock()
        with mock.patch.object(MODULE, "PEERS", ["192.0.2.10"]), \
                mock.patch.object(self.server, "slots") as slots, \
                mock.patch.object(self.server, "shutdown_request") as close, \
                mock.patch.object(MODULE.socketserver.ThreadingMixIn, "process_request") as serve:
            for source in ("192.0.2.99", "::ffff:192.0.2.99"):
                self.server.process_request(request, (source, 12345))
            self.assertEqual(close.call_count, 2)
            slots.acquire.assert_not_called()
            serve.assert_not_called()

    def test_source_filter_serves_peers_and_loopback(self):
        request = mock.Mock()
        with mock.patch.object(MODULE, "PEERS", ["192.0.2.10", "2001:db8::10"]), \
                mock.patch.object(self.server, "slots") as slots, \
                mock.patch.object(self.server, "shutdown_request") as close, \
                mock.patch.object(MODULE.socketserver.ThreadingMixIn, "process_request") as serve:
            for source in ("192.0.2.10", "::ffff:192.0.2.10", "2001:db8::10",
                           "127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"):
                self.server.process_request(request, (source, 12345))
            self.assertEqual(serve.call_count, 7)
            self.assertEqual(slots.acquire.call_count, 7)
            close.assert_not_called()

    def test_rejects_bad_mac_wrong_nonce_wrong_address(self):
        response = self.signed()
        response["mac"] = "0" * 64
        self.assertEqual(MODULE.verify_state(response, self.key, "a" * 64, "127.0.0.1"),
                         {"ok": False, "error": "unauthenticated"})
        self.assertEqual(MODULE.verify_state(self.signed(), self.key, "b" * 64, "127.0.0.1"),
                         {"ok": False, "error": "unauthenticated"})
        self.assertEqual(MODULE.verify_state(self.signed(), self.key, "a" * 64, "p1"),
                         {"ok": False, "error": "wrong address"})
        wrong_key = pathlib.Path(self.key_file).with_name("wrong-key")
        wrong_key.write_bytes(b"wrong-test-key")
        self.assertEqual(MODULE.peer_state("127.0.0.1", str(wrong_key), self.port)["error"],
                         "unauthenticated")

    def test_client_rejects_signed_malformed_state(self):
        for fields in ({"fenced": 1}, {"node": ""}, {"mode": "stopped"},
                       {"since_unfence": float("nan")}, {"refence_window": "900"},
                       {"release_rule": "unknown"}, {"release_peers": "p1"},
                       {"release_peers": [1]}, {"release_peers": [""]},
                       {"release_rule": "fenced-peers", "release_peers": ["p2", "p1"]},
                       {"release_rule": "fenced-peers", "release_peers": ["p1", "p1"]},
                       {"release_rule": "manual", "release_peers": ["p1"]}):
            self.assertEqual(MODULE.verify_state(self.signed(**fields), self.key, "a" * 64,
                                                "127.0.0.1")["error"], "bad response")
        self.assertEqual(MODULE.verify_state({}, self.key, "a" * 64, "127.0.0.1")["error"],
                         "bad response")

    def test_endpoint_rejects_malformed_nonce(self):
        for nonce in ("", "a" * 63, "a" * 65, "g" * 64, "a" * 64 + "&extra=1"):
            with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
                sock.sendall(f"GET /v1/state?nonce={nonce} HTTP/1.0\r\n\r\n".encode())
                reply = MODULE.receive(sock, 8192, MODULE.time.monotonic() + 3)
            self.assertTrue(reply.startswith(b"HTTP/1.0 400"), nonce)
        self.agent.snapshot.assert_not_called()

    def test_slow_client_and_handler_exception_do_not_block_other_requests(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as slow:
            slow.sendall(b"GET /v1/state?")
            self.assertTrue(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])
            slow.settimeout(4)
            self.assertEqual(slow.recv(1), b"")
        self.agent.snapshot.side_effect = RuntimeError("test failure")
        self.assertFalse(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])
        self.agent.snapshot.side_effect = None
        self.assertTrue(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])

    def test_oversized_requests_and_responses_are_bounded(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            sock.sendall(b"x" * 4096)
            try:
                self.assertEqual(sock.recv(1), b"")
            except ConnectionResetError:
                pass
        self.agent.snapshot.return_value = state(node="x" * 9000)
        self.assertEqual(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["error"], "bad response")

    def test_handler_slots_bound_clients_and_are_reusable(self):
        for _ in range(16):
            self.assertTrue(self.server.slots.acquire(blocking=False))
        try:
            self.assertFalse(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])
        finally:
            for _ in range(16):
                self.server.slots.release()
        for _ in range(20):
            self.assertTrue(MODULE.peer_state("127.0.0.1", self.key_file, self.port)["ok"])

    def test_trickling_reads_cannot_extend_deadline(self):
        sock = mock.Mock()
        sock.recv.return_value = b"x"
        with mock.patch.object(MODULE.time, "monotonic", side_effect=(0, 1, 2, 3)):
            with self.assertRaises(TimeoutError):
                MODULE.receive(sock, 2048, 3)
        self.assertEqual(sock.recv.call_count, 3)
        self.assertEqual(sock.settimeout.call_args_list, [mock.call(3), mock.call(2), mock.call(1)])

    @unittest.skipUnless(socket.has_dualstack_ipv6(), "no dual-stack listener")
    def test_dual_stack_listener_binds_response_to_receiving_address(self):
        with MODULE.StateServer((str(ipaddress.IPv6Address(0)), 0), self.agent, self.key_file) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                loopback = str(ipaddress.IPv6Address(1))
                for address in ("127.0.0.1", loopback):
                    self.assertTrue(MODULE.peer_state(address, self.key_file, server.server_address[1])["ok"])
                expanded = ipaddress.ip_address(loopback).exploded
                self.assertTrue(MODULE.peer_state(expanded, self.key_file, server.server_address[1])["ok"])
            finally:
                server.shutdown()
                thread.join(1)


class EndpointLifetimeTests(unittest.TestCase):
    def test_bind_failure_retries_after_thirty_seconds_then_starts_server(self):
        agent = mock.Mock()
        server = mock.Mock()
        with mock.patch.object(MODULE, "StateServer", side_effect=(
                OSError("test bind failure"), OSError("test bind failure"), server)) as bind, \
                mock.patch.object(MODULE.threading, "Thread") as thread, \
                mock.patch.object(MODULE, "log") as log:
            endpoint = MODULE.StateEndpoint(agent)
            endpoint.start(0)
            for now in (1, 5, 29):
                endpoint.start(now)
            self.assertEqual(bind.call_count, 1)
            endpoint.start(30)
            self.assertEqual(bind.call_count, 2)
            self.assertEqual(log.call_count, 1)
            thread.assert_not_called()
            endpoint.start(60)
            self.assertEqual(bind.call_count, 3)
            thread.assert_called_once_with(target=server.serve_forever, daemon=True)
            thread.return_value.start.assert_called_once_with()
            endpoint.start(90)
            self.assertEqual(bind.call_count, 3)

    def test_different_bind_failure_kinds_are_logged_once_each(self):
        with mock.patch.object(MODULE, "StateServer", side_effect=(
                OSError("first"), ValueError("different"), OSError("again"))), \
                mock.patch.object(MODULE, "log") as log:
            endpoint = MODULE.StateEndpoint(mock.Mock())
            for now in (0, 30, 60):
                endpoint.start(now)
            self.assertEqual(log.call_count, 2)


class StatusTests(unittest.TestCase):
    def test_json_output_and_exit_codes(self):
        for failed, expected in ((False, 0), (True, 1)):
            def query(address, key_path=None):
                if failed and address == "p2":
                    return {"ok": False, "error": "no answer"}
                return {"ok": True, **state(node="n1" if address == "127.0.0.1" else address)}
            output = io.StringIO()
            with mock.patch.object(MODULE.os, "geteuid", return_value=0), \
                    mock.patch.object(MODULE, "state_key", return_value=b"test-key"), \
                    mock.patch.object(MODULE, "peer_state", side_effect=query), \
                    mock.patch("sys.stdout", output):
                self.assertEqual(MODULE.status_command(), expected)
            document = json.loads(output.getvalue())
            self.assertEqual((document["node"], document["servers"], document["quorum"]), ("n1", 3, 2))
            self.assertEqual([s["address"] for s in document["states"]], ["127.0.0.1", "p1", "p2"])
            self.assertEqual([s["self"] for s in document["states"]], [True, False, False])
            for reported in document["states"]:
                if reported["ok"]:
                    self.assertIsNone(reported["release_rule"])
                    self.assertEqual(reported["release_peers"], [])

    def test_no_key_prints_errors_and_exits_two(self):
        output = io.StringIO()
        with mock.patch.object(MODULE.os, "geteuid", return_value=0), \
                mock.patch.object(MODULE, "state_key", return_value=None), \
                mock.patch("sys.stdout", output):
            self.assertEqual(MODULE.status_command(), 2)
        self.assertTrue(all(s["error"] == "no key" and not s["ok"]
                            for s in json.loads(output.getvalue())["states"]))

    def test_requires_root(self):
        with mock.patch.object(MODULE.os, "geteuid", return_value=1000), \
                mock.patch.object(MODULE, "state_key") as key:
            self.assertEqual(MODULE.status_command(), 2)
        key.assert_not_called()

    def test_loopback_must_name_this_node(self):
        output = io.StringIO()
        with mock.patch.object(MODULE.os, "geteuid", return_value=0), \
                mock.patch.object(MODULE, "state_key", return_value=b"test-key"), \
                mock.patch.object(MODULE, "peer_state", return_value={"ok": True, **state()}), \
                mock.patch("sys.stdout", output):
            self.assertEqual(MODULE.status_command(), 1)
        self.assertEqual(json.loads(output.getvalue())["states"][0],
                         {"address": "127.0.0.1", "self": True, "ok": False, "error": "bad response"})


def read_marker():
    with open(MODULE.MARKER, encoding="utf-8") as handle:
        return json.load(handle)


class ClassifyTests(unittest.TestCase):
    def classify(self, p):
        return MODULE.classify(*p[:3])[0]

    def test_ipv6_api_urls_are_bracketed(self):
        # The transport helper, shared by classification and API release probes.
        address = str(ipaddress.IPv6Address(1))
        with mock.patch.object(MODULE, "capture_full", return_value=(0, "", "")) as capture:
            MODULE.kubectl_full(address, ["get", "node", MODULE.NODE])
        self.assertIn(f"https://[{address}]:6443", capture.call_args.args[0])

    def test_classification(self):
        self.assertEqual(self.classify(probes(ready={"p2"})), MODULE.HEALTHY)
        self.assertEqual(self.classify(NOT_READY), MODULE.UNHEALTHY)
        self.assertEqual(self.classify(ACCEPTING), MODULE.AMBIGUOUS)
        self.assertEqual(self.classify(ISOLATED), MODULE.UNHEALTHY)

    def test_refused_connections_mean_isolation_not_an_outage(self):
        self.assertEqual(self.classify(REACHABLE), MODULE.UNHEALTHY)


TAINT = {"key": MODULE.OUT_OF_SERVICE, "value": "nodeshutdown", "effect": "NoExecute"}


def pod(name, owner=None, tolerations=None, annotations=None, phase="Running"):
    metadata = {"name": name, "annotations": annotations or {}}
    if owner:
        metadata["ownerReferences"] = [{"kind": owner}]
    return {"metadata": metadata, "spec": {"nodeName": "n1", "tolerations": tolerations or []},
            "status": {"phase": phase}}


class ReleaseStatusTests(unittest.TestCase):
    """release_status against a fake API server."""

    def setUp(self):
        self.node = {"metadata": {"annotations": {}}, "spec": {"taints": [TAINT]}}
        self.pods = []
        self.attachments = []
        self.failing = {}  # resource -> (status, stderr) of a failed request
        for name, fake in (("kubectl_full", self.fake_kubectl),
                           ("kubectl", lambda server, args: self.fake_kubectl(server, args)[:2])):
            patcher = mock.patch.object(MODULE, name, fake)
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_kubectl(self, server, args):
        resource = args[1]
        if resource in self.failing:
            status, errors = self.failing[resource]
            return status, "", errors
        if resource == "node":
            return 0, json.dumps(self.node), ""
        if resource == "pods":
            self.assertIn("--field-selector=spec.nodeName=n1", args)
            return 0, json.dumps({"items": self.pods}), ""
        if resource == "volumeattachments":
            return 0, json.dumps({"items": self.attachments}), ""
        raise AssertionError(args)

    def status(self):
        return MODULE.release_status("p1")

    def test_transport_failures_and_outages_are_no_answer(self):
        for failure in (
            (-1, ""),  # the kubectl process timed out
            (1, "Unable to connect to the server: context deadline exceeded "
                "(Client.Timeout exceeded while awaiting headers)"),
            (1, "Unable to connect to the server: dial tcp 10.0.0.2:6443: i/o timeout"),
            (1, "The connection to the server 10.0.0.2:6443 was refused - "
                "did you specify the right host or port?"),
            (1, "Error from server (InternalError): an error on the server has prevented "
                "the request from succeeding"),
            (1, "Error from server (ServiceUnavailable): the server is currently unable "
                "to handle the request"),
            (1, "Error from server (Timeout): the server was unable to return a response "
                "in the time allotted"),
        ):
            self.failing = {"node": failure}
            self.assertEqual(self.status(), "no-answer", failure)

    def test_other_node_request_failures_hold(self):
        for errors in (
            'Error from server (NotFound): nodes "n1" not found',
            'Error from server (Forbidden): nodes "n1" is forbidden',
            "error: You must be logged in to the server (Unauthorized)",
            "Error from server (TooManyRequests): the server has received too many requests",
            "something unexpected",
        ):
            self.failing = {"node": (1, errors)}
            self.assertEqual(self.status(), "held", errors)

    def test_taint_without_pods_or_attachments_releases(self):
        self.assertEqual(self.status(), "released")

    def test_no_taint_holds(self):
        self.node["spec"]["taints"] = [{"key": "other", "effect": "NoExecute"}]
        self.assertEqual(self.status(), "held")

    def test_remaining_pod_holds(self):
        for phase in ("Running", "Pending", "Unknown"):
            self.pods = [pod("app", owner="ReplicaSet", phase=phase)]
            self.assertEqual(self.status(), "held", phase)

    def test_remaining_volume_attachment_holds(self):
        self.attachments = [{"spec": {"nodeName": "n2"}}, {"spec": {"nodeName": "n1"}}]
        self.assertEqual(self.status(), "held")

    def test_pods_the_taint_never_evicts_are_ignored(self):
        self.pods = [
            pod("ds", owner="DaemonSet"),
            pod("static", annotations={"kubernetes.io/config.mirror": "x"}),
            pod("all", tolerations=[{"operator": "Exists"}]),
            pod("oos", tolerations=[{"key": MODULE.OUT_OF_SERVICE, "operator": "Exists",
                                     "effect": "NoExecute"}]),
            pod("equal", tolerations=[{"key": MODULE.OUT_OF_SERVICE, "value": "nodeshutdown"}]),
            pod("job", owner="Job", phase="Succeeded"),
            pod("failed", owner="Job", phase="Failed"),
        ]
        self.assertEqual(self.status(), "released")

    def test_partial_tolerations_still_hold(self):
        for toleration in (
            {"key": MODULE.OUT_OF_SERVICE, "operator": "Exists", "tolerationSeconds": 300},
            {"key": MODULE.OUT_OF_SERVICE, "operator": "Exists", "effect": "NoSchedule"},
            {"key": MODULE.OUT_OF_SERVICE, "value": "other"},
            {"key": "node.kubernetes.io/unreachable", "operator": "Exists"},
        ):
            self.pods = [pod("p", tolerations=[toleration])]
            self.assertEqual(self.status(), "held", toleration)

    def test_failed_sub_requests_hold(self):
        for resource in ("pods", "volumeattachments"):
            self.failing = {resource: (1, "Error from server (Forbidden): forbidden")}
            self.assertEqual(self.status(), "held", resource)

    def test_disabled_without_taint_releases(self):
        self.node = {"metadata": {"annotations": {"fence.alc.xyz/disabled": "true"}},
                     "spec": {}}
        self.assertEqual(self.status(), "released")

    def test_disabled_with_taint_still_needs_evidence(self):
        self.node["metadata"]["annotations"]["fence.alc.xyz/disabled"] = "true"
        self.pods = [pod("app")]
        self.assertEqual(self.status(), "held")
        self.pods = []
        self.attachments = [{"spec": {"nodeName": "n1"}}]
        self.assertEqual(self.status(), "held")


class AgentTests(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(ROOT)
        os.makedirs(RUN_DIR)
        self.calls = []
        self.timeouts = []
        self.sysrq = []
        self.heartbeats = []
        self.annotate_ok = True
        self.boot = "boot-1"
        self.age = None  # k3s not started recently
        self.active = False
        self.agent = self.new_agent()

    def new_agent(self, run=None, grace=True):
        agent = MODULE.Agent(ops=(run or self.fake_run, self.fake_annotate,
                                  lambda: self.age, lambda: self.boot, self.sysrq.append,
                                  lambda: self.active))
        if grace:
            agent.grace_until = 0  # most tests start long after boot
        return agent

    def fake_run(self, args, timeout):
        self.calls.append(args)
        self.timeouts.append(timeout)
        return 0

    def fake_annotate(self, now):
        self.heartbeats.append(now)
        return self.annotate_ok

    def fence_now(self, p=ISOLATED, at=0):
        self.agent.step(at, p)
        return self.agent.step(at + 60, p)

    def reboot(self, grace=True):
        """Simulate the fencing reboot: new boot id, empty runtime directory."""
        self.boot = "boot-2"
        shutil.rmtree(RUN_DIR)
        os.makedirs(RUN_DIR)
        self.agent = self.new_agent(grace=grace)

    def fence_and_reboot(self, p=ISOLATED, after=ISOLATED):
        """Fence at 60, reboot, record the fence at 100; not_before is then 160."""
        self.assertEqual(self.fence_now(p), "reboot")
        self.reboot()
        self.calls.clear()
        return self.agent.step(100, after)

    def test_fences_by_reboot_only_after_deadline(self):
        self.assertEqual(self.agent.step(0, ISOLATED), "unhealthy, waiting")
        self.assertEqual(self.agent.step(59, ISOLATED), "unhealthy, waiting")
        self.assertEqual(self.agent.step(60, ISOLATED), "reboot")
        self.assertEqual(self.calls, [REBOOT])
        marker = read_marker()
        self.assertEqual(marker["phase"], "fencing")
        self.assertEqual(marker["boot_id"], "boot-1")
        self.assertEqual(marker["backoff"], 60.0)
        self.assertIn("isolated", marker["reason"])
        self.assertFalse(os.path.exists(MODULE.MARKER + ".tmp"))

    def test_marker_persist_failure_powers_off(self):
        # A reboot without the marker would start k3s again.
        with mock.patch.object(MODULE, "write_json", side_effect=OSError("no space")):
            self.assertEqual(self.fence_now(), "poweroff")
        self.assertEqual(self.calls, [POWEROFF])

    def test_unreadable_boot_id_powers_off(self):
        self.boot = ""
        self.assertEqual(self.fence_now(), "poweroff")
        self.assertEqual(self.calls, [POWEROFF])

    def test_same_boot_retries_the_reboot_harder(self):
        self.fence_now()
        self.assertEqual(self.agent.step(65, ISOLATED), "fencing, reboot pending")
        self.assertEqual(self.agent.step(89, ISOLATED), "fencing, reboot pending")
        self.assertEqual(self.agent.step(90, ISOLATED), "reboot")
        self.assertEqual(self.timeouts, [30, 30])
        self.assertEqual(self.calls, [REBOOT, REBOOT_HARDER])
        self.assertEqual(read_marker()["attempts"], 2)

    def test_agent_restart_in_the_same_boot_retries_the_reboot(self):
        self.fence_now()
        restarted = self.new_agent()
        self.assertEqual(restarted.step(130, ISOLATED), "reboot")
        self.assertEqual(self.calls[-1], REBOOT_HARDER)

    def test_new_boot_marks_the_fence_complete(self):
        self.assertEqual(self.fence_and_reboot(), "fenced, insufficient verified fenced peers")
        marker = read_marker()
        self.assertEqual(marker["phase"], "fenced")
        self.assertEqual(marker["boot_id"], "boot-2")
        self.assertEqual(marker["not_before"], 160)
        self.assertNotIn(REBOOT, self.calls)
        self.assertNotIn(START, self.calls)

    def test_unreadable_marker_reboots_once(self):
        os.makedirs(STATE_DIR)
        with open(MODULE.MARKER, "w", encoding="utf-8") as handle:
            handle.write("")
        self.agent = self.new_agent()
        self.assertEqual(self.agent.step(10, ISOLATED), "reboot")
        self.assertEqual(self.calls, [REBOOT])
        self.assertEqual(read_marker()["boot_id"], "boot-1")
        self.reboot()
        self.assertEqual(self.agent.step(10, ISOLATED), "fenced, insufficient verified fenced peers")
        self.assertEqual(self.calls, [REBOOT])
        self.assertEqual(read_marker()["phase"], "fenced")

    def test_cluster_view_not_ready_fences(self):
        # Whatever k3s is doing (stuck activating, crash-looping, stopped).
        self.assertEqual(self.fence_now(NOT_READY), "reboot")

    def test_recovery_resets_the_timer(self):
        self.agent.step(0, ISOLATED)
        self.agent.step(30, HEALTHY)
        self.assertEqual(self.agent.step(70, ISOLATED), "unhealthy, waiting")

    def test_ambiguous_fences_only_after_its_longer_deadline(self):
        for now in range(0, 150, 5):
            self.assertEqual(self.agent.step(now, ACCEPTING), "ambiguous, waiting")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.agent.step(150, ACCEPTING), "reboot")

    def test_only_boot_grace_is_exempt(self):
        self.agent = self.new_agent(grace=False)
        self.assertEqual(self.agent.step(100, ISOLATED), "grace")
        self.assertEqual(self.fence_now(at=150), "reboot")

    def test_external_k3s_restart_gets_a_bounded_grace(self):
        self.age = 10.0
        self.agent.step(0, ISOLATED)
        self.assertEqual(self.agent.step(60, ISOLATED), "k3s restarted, grace")
        self.assertEqual(self.agent.step(149, ISOLATED), "k3s restarted, grace")
        # A crash loop keeps k3s young, but the grace ends BOOT_GRACE into the episode.
        self.assertEqual(self.agent.step(150, ISOLATED), "reboot")

    def test_no_restart_grace_for_an_old_or_stopped_k3s(self):
        for age in (None, 500.0):
            self.setUp()
            self.age = age
            self.assertEqual(self.fence_now(), "reboot", age)

    def test_unfence_needs_stable_fence_evidence_and_backoff(self):
        self.fence_and_reboot()
        self.assertEqual(self.agent.step(110, ISOLATED), "fenced, insufficient verified fenced peers")
        self.assertEqual(self.agent.step(120, FENCED), "fenced, waiting")
        self.assertEqual(self.agent.step(155, FENCED), "fenced, waiting")  # not before 160
        self.assertEqual(self.agent.step(160, FENCED), "unfenced")
        self.assertEqual(self.calls[-1], START)
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_fence_evidence_must_be_continuous(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        self.agent.step(215, ISOLATED)
        self.assertEqual(self.agent.step(240, FENCED), "fenced, waiting")

    def test_answering_api_blocks_unfence_even_when_readyz_fails(self):
        self.fence_and_reboot()
        held = probes(accepts={"p1", "p2"}, held={"p1"})  # no /readyz anywhere
        for now in (200, 300, 400):
            self.assertEqual(self.agent.step(now, held),
                             "fenced, waiting for the cluster to release this node")
        self.assertNotIn(START, self.calls)

    def test_any_released_answer_unfences(self):
        self.fence_and_reboot()
        released = probes(api={"p2"}, accepts={"p1"}, released={"p2"})
        self.agent.step(200, released)
        self.assertEqual(self.agent.step(230, released), "unfenced")

    def test_one_fenced_peer_unfences_three_servers(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        self.assertEqual(self.agent.step(230, FENCED), "unfenced")

    def test_healthy_observe_and_unverified_peers_hold(self):
        self.fence_and_reboot()
        for peer in (state(fenced=False, classification="healthy", k3s_active=True),
                     state(mode="observe"), state(classification="fencing", fenced=False),
                     state(k3s_active=True), state(node=MODULE.NODE),
                     {"ok": False, "error": "unauthenticated"}):
            p = probes(states={"p1": {"ok": True, **peer}})
            for now in (200, 230, 10000):
                self.assertEqual(self.agent.step(now, p), "fenced, insufficient verified fenced peers")
        self.assertNotIn(START, self.calls)

    def test_recent_joint_release_counts_only_for_named_enforcing_node(self):
        joint = state(fenced=False, classification="grace", k3s_active=True,
                      release_rule="fenced-peers", release_peers=[MODULE.NODE],
                      since_unfence=MODULE.JOINT_WINDOW)
        self.fence_and_reboot()
        p = probes(states={"p1": {"ok": True, **joint}})
        self.agent.step(200, p)
        self.assertEqual(self.agent.step(230, p), "unfenced")
        self.assertEqual(self.agent.snapshot()["release_peers"], ["p1"])
        for changes in ({"release_peers": ["different-node"]},
                        {"since_unfence": MODULE.JOINT_WINDOW + 1},
                        {"since_unfence": None}, {"mode": "observe"},
                        {"release_rule": "manual"}):
            with self.subTest(changes=changes):
                self.setUp()
                self.fence_and_reboot()
                p = probes(states={"p1": {"ok": True, **joint, **changes}})
                for now in (200, 230, 10000):
                    self.assertEqual(self.agent.step(now, p),
                                     "fenced, insufficient verified fenced peers")
                self.assertNotIn(START, self.calls)

    def test_changing_fenced_peers_keeps_the_stability_window(self):
        self.fence_and_reboot()
        self.agent.step(200, probes(fenced={"p1"}))
        self.assertEqual(self.agent.step(230, probes(fenced={"p2"})), "unfenced")
        self.assertEqual(self.agent.snapshot()["release_peers"], ["p2"])

    def test_final_recheck_counts_peer_joint_release(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        calls = []
        def peer(address):
            if address != "p1":
                return {"ok": False}
            calls.append(address)
            if len(calls) == 1:
                return {"ok": True, **state()}
            return {"ok": True, **state(fenced=False, classification="grace", k3s_active=True,
                                        release_rule="fenced-peers", release_peers=[MODULE.NODE],
                                        since_unfence=0)}
        self.assertEqual(self.agent.step(230, (*FENCED[:3], peer, FENCED[4])), "unfenced")
        self.assertEqual(len(calls), 2)

    def test_two_fenced_agents_jointly_release_with_third_unreachable(self):
        self.joint_release(b_not_before=0)

    def test_joint_release_skips_a_longer_backoff(self):
        # B refenced recently and its backoff ends long after A's joint window.
        self.joint_release(b_not_before=10000)

    def joint_release(self, b_not_before: float):
        # Each probe reads the other agent's actual published state. Starting A
        # clears its fenced bit before B's next poll, so B needs joint evidence.
        agents, active, calls = {}, {}, {}
        def context(node):
            return mock.patch.multiple(MODULE, NODE=node,
                                       PEERS=[p for p in ("A", "B", "C") if p != node],
                                       MARKER=os.path.join(STATE_DIR, node),
                                       HISTORY=os.path.join(RUN_DIR, node + ".history"))
        for node in ("A", "B"):
            active[node], calls[node] = False, []
            def run(args, timeout, node=node):
                calls[node].append(args)
                if args == START:
                    active[node] = True
                return 0
            with context(node):
                MODULE.write_json(MODULE.MARKER, {
                    "phase": "fenced", "boot_id": node + "-boot", "backoff": 60,
                    "not_before": b_not_before if node == "B" else 0})
                agents[node] = MODULE.Agent(ops=(run, lambda _: True, lambda: None,
                                                lambda node=node: node + "-boot", lambda _: None,
                                                lambda node=node: active[node]))
                agents[node].publish(100, "fenced", False)
        def probe(address):
            return {"ok": True, **agents[address].snapshot()} if address in agents else {"ok": False}
        def ready(_):
            return all(active.values())
        p = (ready, lambda _: False, lambda _: False, probe, lambda _: "no-answer")
        for node, now in (("A", 200), ("B", 200 + MODULE.POLL)):
            with context(node):
                self.assertEqual(agents[node].step(now, p), "fenced, waiting")
        releases = {}
        for node, now in (("A", 230), ("B", 230 + MODULE.POLL)):
            with context(node):
                self.assertEqual(agents[node].step(now, p), "unfenced")
                releases[node] = now
                self.assertEqual(agents[node].snapshot()["release_rule"], "fenced-peers")
                self.assertEqual(agents[node].snapshot()["release_peers"],
                                 ["B" if node == "A" else "A"])
        self.assertLessEqual(abs(releases["A"] - releases["B"]), MODULE.POLL)
        for now in range(240, 600, int(MODULE.POLL)):
            for node in ("A", "B"):
                with context(node):
                    agents[node].step(now, p)
                    self.assertFalse(agents[node].snapshot()["fenced"])
        for node in ("A", "B"):
            self.assertEqual(agents[node].snapshot()["classification"], "healthy")
            self.assertEqual(calls[node], [START])

    def test_same_node_on_two_addresses_counts_once(self):
        self.fence_and_reboot()
        own_name = {"ok": True, **state(node=MODULE.NODE)}
        for now in (200, 230):
            p = probes(states={"p1": own_name, "p2": own_name})
            self.assertEqual(self.agent.step(now, p), "fenced, insufficient verified fenced peers")
        peers = ["p1", "p2", "p3", "p4"]  # N=5 needs three fences including self
        p = probes(states={"p1": {"ok": True, **state()}, "p2": {"ok": True, **state()}})
        with mock.patch.object(MODULE, "PEERS", peers):
            for now in (200, 230, 10000):
                self.assertEqual(self.agent.step(now, p), "fenced, insufficient verified fenced peers")
        self.assertNotIn(START, self.calls)

    def test_held_overrides_fenced_peers(self):
        self.fence_and_reboot()
        p = probes(fenced={"p1", "p2"}, held={"p1"})
        for now in (200, 230, 10000):
            self.assertEqual(self.agent.step(now, p),
                             "fenced, waiting for the cluster to release this node")
        self.assertNotIn(START, self.calls)

    def test_released_api_overrides_held_api(self):
        self.fence_and_reboot()
        p = probes(fenced={"p1", "p2"}, released={"p1"}, held={"p2"})
        self.agent.step(200, p)
        self.assertEqual(self.agent.step(230, p), "unfenced")
        self.assertEqual(self.agent.snapshot()["release_rule"], "released")
        self.assertEqual(self.agent.snapshot()["release_peers"], [])

    def test_final_recheck_aborts_when_peer_stops_reporting_fenced(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        observed = {"p1": 0}
        def peer(address):
            if address == "p1":
                observed[address] += 1
                return {"ok": True, **state(fenced=observed[address] == 1)}
            return {"ok": False}
        p = (*FENCED[:3], peer, FENCED[4])
        self.assertEqual(self.agent.step(230, p), "fenced, evidence changed before release")
        self.assertNotIn(START, self.calls)
        self.assertEqual(self.agent.step(240, FENCED), "fenced, waiting")
        self.assertEqual(self.agent.step(270, FENCED), "unfenced")

    def test_final_recheck_aborts_when_any_api_holds(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        observed = {"p1": 0}
        def release(address):
            if address == "p1":
                observed[address] += 1
                return "no-answer" if observed[address] == 1 else "held"
            return "no-answer"
        p = (*FENCED[:4], release)
        self.assertEqual(self.agent.step(230, p), "fenced, evidence changed before release")
        self.assertNotIn(START, self.calls)

    def test_final_recheck_aborts_when_api_release_disappears(self):
        self.fence_and_reboot()
        p = probes(released={"p1"})
        self.agent.step(200, p)
        observed = {"p1": 0}
        def release(address):
            if address == "p1":
                observed[address] += 1
                return "released" if observed[address] == 1 else "held"
            return "no-answer"
        self.assertEqual(self.agent.step(230, (*p[:4], release)),
                         "fenced, evidence changed before release")
        self.assertNotIn(START, self.calls)

    def test_switching_release_rules_restarts_stability_window(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        p = probes(released={"p1"})
        self.assertEqual(self.agent.step(230, p), "fenced, waiting")
        self.assertEqual(self.agent.step(260, p), "unfenced")

    def test_fleet_wide_fence_unfences_each_node(self):
        fleet = ["n1", "p1", "p2"]
        for node in fleet:
            with self.subTest(node=node), mock.patch.object(MODULE, "NODE", node), \
                    mock.patch.object(MODULE, "PEERS", [p for p in fleet if p != node]):
                self.setUp()
                peers = [p for p in fleet if p != node]
                p = probes(fenced=set(peers))
                self.fence_and_reboot(after=p)
                self.assertTrue(self.agent.snapshot()["fenced"])
                self.assertEqual(self.agent.step(160, p), "unfenced")
                self.assertEqual(self.calls, [START])

    def test_snapshot_clears_fenced_before_k3s_start(self):
        self.fence_and_reboot()
        self.assertTrue(self.agent.snapshot()["fenced"])
        def start(args, timeout):
            self.assertEqual(args, START)
            snapshot = self.agent.snapshot()
            self.assertFalse(snapshot["fenced"])
            self.assertEqual(snapshot["classification"], "grace")
            self.assertEqual(snapshot["since_unfence"], 0)
            return self.fake_run(args, timeout)
        self.agent.run = start
        self.agent.step(200, FENCED)
        self.assertEqual(self.agent.step(230, FENCED), "unfenced")
        restarted = self.new_agent(grace=False)
        restarted.step(240, HEALTHY)
        self.assertEqual(restarted.snapshot()["since_unfence"], 10)
        self.assertEqual(restarted.snapshot()["release_rule"], "fenced-peers")
        self.assertEqual(restarted.snapshot()["release_peers"], ["p1"])

    def test_fenced_snapshot_requires_completed_fence_and_inactive_k3s(self):
        self.fence_now()
        self.assertFalse(self.agent.snapshot()["fenced"])
        self.assertEqual(self.agent.snapshot()["classification"], "fencing")
        self.reboot()
        self.active = True
        self.agent.step(100, FENCED)
        self.assertFalse(self.agent.snapshot()["fenced"])
        self.agent.step(10000, FENCED)
        self.assertNotIn(START, self.calls)
        self.active = False
        self.agent.step(10005, FENCED)
        self.assertTrue(self.agent.snapshot()["fenced"])

    def test_partial_partition_with_healthy_peer_holds_forever(self):
        self.fence_and_reboot()
        healthy = {"ok": True, **state(fenced=False, classification="healthy", k3s_active=True)}
        for p in (probes(accepts={"p1"}, states={"p1": healthy}), REACHABLE):
            for now in (200, 230, 800, 10000, 1000000):
                self.assertEqual(self.agent.step(now, p), "fenced, insufficient verified fenced peers")
        self.assertNotIn(START, self.calls)

    def test_refencing_soon_doubles_backoff(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        self.agent.step(230, FENCED)
        self.agent = self.new_agent()
        self.fence_now(at=600)
        self.assertEqual(read_marker()["backoff"], 120)

    def test_switching_to_observe_releases_an_existing_fence(self):
        self.fence_and_reboot()
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.agent.step(500, FENCED), "released for observe mode")
        self.assertEqual(self.calls, [START])
        self.assertFalse(os.path.exists(MODULE.MARKER))
        self.assertEqual(self.agent.snapshot()["release_rule"], "observe")
        self.assertEqual(self.agent.snapshot()["release_peers"], [])

    def test_observe_mode_never_acts(self):
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.fence_now(), "would fence")
        self.assertEqual(self.calls, [])
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_post_unfence_grace_survives_agent_restart(self):
        self.fence_and_reboot()
        self.agent.step(200, FENCED)
        self.agent.step(230, FENCED)
        restarted = self.new_agent(grace=False)
        self.assertEqual(restarted.step(300, NOT_READY), "grace")

    def test_manual_release_grace_survives_agent_restart(self):
        self.fence_and_reboot()
        os.remove(MODULE.MARKER)
        self.assertEqual(self.agent.step(500, FENCED), "released")
        self.assertIsNone(self.agent.state)
        self.assertEqual(self.agent.step(560, NOT_READY), "grace")
        restarted = self.new_agent(grace=False)
        self.assertEqual(restarted.step(600, NOT_READY), "grace")
        self.assertNotEqual(restarted.step(650, NOT_READY), "grace")
        snapshot = restarted.snapshot()
        self.assertEqual(snapshot["since_unfence"], 150)
        self.assertEqual(snapshot["release_rule"], "manual")
        self.assertEqual(snapshot["release_peers"], [])
        history = MODULE.read_json(MODULE.HISTORY)
        self.assertEqual(history["last_unfence"], 500)
        self.assertEqual(history["release_rule"], "manual")
        self.assertEqual(history["release_peers"], [])

    def test_no_heartbeat_while_fenced(self):
        # A heartbeat newer than the failure would restart the controller's taint timer.
        self.fence_and_reboot()
        for now in range(105, 300, 5):
            self.agent.step(now, NOT_READY)
        self.assertEqual(self.heartbeats, [])

    def test_hanging_marker_write_crashes_through_sysrq(self):
        import threading
        import time
        stuck = threading.Event()
        self.addCleanup(stuck.set)
        with mock.patch.object(MODULE, "write_json", lambda *args: stuck.wait()), \
                mock.patch.object(MODULE, "MARKER_WRITE_TIMEOUT", 0.2):
            started = time.monotonic()
            self.assertEqual(self.fence_now(), "sysrq crash")
            self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(self.sysrq, ["c"])
        self.assertEqual(self.calls, [])  # no reboot without a marker

    def test_failed_sysrq_falls_back_to_a_poweroff_without_sync(self):
        import threading
        stuck = threading.Event()
        self.addCleanup(stuck.set)

        def broken(command):
            raise OSError("no sysrq")
        self.agent = MODULE.Agent(ops=(self.fake_run, self.fake_annotate, lambda: None,
                                       lambda: self.boot, broken, lambda: self.active))
        self.agent.grace_until = 0
        with mock.patch.object(MODULE, "write_json", lambda *args: stuck.wait()), \
                mock.patch.object(MODULE, "MARKER_WRITE_TIMEOUT", 0.2):
            self.assertEqual(self.fence_now(), "sysrq crash")
        self.assertEqual(self.calls,
                         [["systemctl", "poweroff", "--force", "--force", "--no-sync"]])

    def test_release_waits_for_a_timed_out_marker_write(self):
        import threading
        self.fence_now()
        self.reboot()
        stuck = threading.Event()
        self.addCleanup(stuck.set)
        real_write = MODULE.write_json

        def slow_write(path, value, cancel=None):
            stuck.wait()
            real_write(path, value, cancel)
        with mock.patch.object(MODULE, "write_json", slow_write), \
                mock.patch.object(MODULE, "MARKER_WRITE_TIMEOUT", 0.2):
            # The new-boot update to "fenced" times out; the old marker still blocks k3s.
            self.agent.step(100, FENCED)
            self.assertTrue(self.agent.write_pending())
            for now in (200, 230, 260):
                self.assertEqual(self.agent.step(now, FENCED),
                                 "fenced, marker write still pending")
            self.assertNotIn(START, self.calls)
            stuck.set()
            self.agent.writer.join(1)
            self.assertEqual(read_marker()["phase"], "fencing")  # cancelled, not replaced
            # The stability window starts again once the write is gone.
            self.assertEqual(self.agent.step(300, FENCED), "fenced, waiting")
            self.assertEqual(self.agent.step(330, FENCED), "unfenced")
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_hung_first_write_keeps_retrying_the_crash(self):
        import threading
        stuck = threading.Event()
        self.addCleanup(stuck.set)

        def broken(command):
            self.sysrq.append(command)
            raise OSError("no sysrq")
        self.sysrq = []
        self.agent = MODULE.Agent(ops=(self.fake_run, self.fake_annotate, lambda: None,
                                       lambda: self.boot, broken, lambda: self.active))
        self.agent.grace_until = 0
        with mock.patch.object(MODULE, "write_json", lambda *args: stuck.wait()), \
                mock.patch.object(MODULE, "MARKER_WRITE_TIMEOUT", 0.2):
            self.assertEqual(self.fence_now(), "sysrq crash")
            self.assertTrue(self.agent.write_pending())
            self.assertEqual(self.agent.step(200, ISOLATED), "sysrq crash")
        self.assertEqual(self.sysrq, ["c", "c"])

    def test_sysrq_crash_disables_the_panic_reboot_first(self):
        panic = os.path.join(RUN_DIR, "panic")
        trigger = os.path.join(RUN_DIR, "sysrq-trigger")
        with open(panic, "w", encoding="ascii") as handle:
            handle.write("10")
        with mock.patch.object(MODULE, "PANIC", panic), mock.patch.object(MODULE, "SYSRQ", trigger):
            MODULE.sysrq("c")
        with open(panic, encoding="ascii") as handle:
            self.assertEqual(handle.read(), "0")
        with open(trigger, encoding="ascii") as handle:
            self.assertEqual(handle.read(), "c")

    def test_unwritable_panic_timeout_does_not_crash(self):
        trigger = os.path.join(RUN_DIR, "sysrq-trigger")
        with mock.patch.object(MODULE, "PANIC", os.path.join(RUN_DIR, "missing", "panic")), \
                mock.patch.object(MODULE, "SYSRQ", trigger):
            with self.assertRaises(OSError):
                MODULE.sysrq("c")
        self.assertFalse(os.path.exists(trigger))

    def test_cancelled_write_does_not_replace_the_marker(self):
        import threading
        MODULE.write_json(MODULE.MARKER, {"phase": "fencing"})
        cancel = threading.Event()
        cancel.set()
        MODULE.write_json(MODULE.MARKER, {"phase": "fenced"}, cancel)
        self.assertEqual(read_marker(), {"phase": "fencing"})
        self.assertFalse(os.path.exists(MODULE.MARKER + ".tmp"))

    def test_no_heartbeat_before_the_reboot(self):
        self.fence_now()
        self.agent.step(65, ISOLATED)
        self.assertEqual(self.heartbeats, [])

    def test_stop_signal_does_not_mark_a_fenced_node_stopped(self):
        self.fence_and_reboot()
        with mock.patch.object(MODULE, "AGENT", self.agent), \
                mock.patch.object(MODULE, "annotate_heartbeat") as annotate:
            with self.assertRaises(SystemExit):
                MODULE.stop(15, None)
        annotate.assert_not_called()

    def test_heartbeat_only_while_healthy_and_rate_limited(self):
        for now in range(0, 125, 5):
            self.agent.step(now, HEALTHY)
        self.assertEqual(self.heartbeats, [0, 60, 120])
        self.agent.step(200, ISOLATED)
        self.assertEqual(self.heartbeats, [0, 60, 120])

    def test_probes_run_in_parallel(self):
        import time
        def slow(_):
            time.sleep(0.3)
            return False
        started = time.monotonic()
        MODULE.classify(slow, slow, slow)
        self.assertLess(time.monotonic() - started, 1.5)  # sequential would be 2.1 s

    def test_timeouts_kill_the_whole_process_group(self):
        import time
        pid_file = os.path.join(RUN_DIR, "child.pid")
        status = MODULE.run(["sh", "-c", f"sleep 30 & echo $! > {pid_file}; wait"], timeout=1)
        self.assertEqual(status, -1)
        with open(pid_file, encoding="utf-8") as handle:
            child = int(handle.read())
        for _ in range(50):
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail("background child survived the timeout")

    def test_k3s_age_reads_the_monotonic_start(self):
        import time
        started = int((time.monotonic() - 20) * 1e6)
        with mock.patch.object(MODULE, "capture", return_value=(0, f"{started}\n")):
            self.assertAlmostEqual(MODULE.k3s_age(), 20, delta=2)
        with mock.patch.object(MODULE, "capture", return_value=(0, "0\n")):
            self.assertIsNone(MODULE.k3s_age())


def tearDownModule():
    shutil.rmtree(ROOT)


if __name__ == "__main__":
    unittest.main()
