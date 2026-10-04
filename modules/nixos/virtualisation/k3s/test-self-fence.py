#!/usr/bin/env python3

import importlib.util
import json
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


def probes(ready=(), api=(), accepts=(), refused=(), released=(), held=()):
    # An API server that is ready also answers, and holds the node unless released.
    def release(s):
        if s in released:
            return "released"
        return "held" if s in held or s in api else "no-answer"
    return (lambda s: s in ready, lambda s: s in api, lambda s: s in accepts,
            lambda s: s in accepts or s in refused, release)


HEALTHY = probes(ready={"127.0.0.1"})
ISOLATED = probes()
NOT_READY = probes(api={"p1"}, accepts={"p1"})  # cluster up, this Node not Ready
ACCEPTING = probes(accepts={"p1"})  # API port open, no API ready: outage
REACHABLE = probes(refused={"p1"})  # host answers, API port closed


def read_marker():
    with open(MODULE.MARKER, encoding="utf-8") as handle:
        return json.load(handle)


class ClassifyTests(unittest.TestCase):
    def classify(self, p):
        return MODULE.classify(*p[:3])[0]

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
        self.agent = self.new_agent()

    def new_agent(self, run=None, grace=True):
        agent = MODULE.Agent(ops=(run or self.fake_run, self.fake_annotate,
                                  lambda: self.age, lambda: self.boot, self.sysrq.append))
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
        self.assertEqual(self.fence_and_reboot(), "fenced, peers unreachable")
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
        self.assertEqual(self.agent.step(10, ISOLATED), "fenced, peers unreachable")
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

    def test_unfence_needs_stable_reachability_and_backoff(self):
        self.fence_and_reboot()
        self.assertEqual(self.agent.step(110, ISOLATED), "fenced, peers unreachable")
        self.assertEqual(self.agent.step(120, REACHABLE), "fenced, waiting")
        self.assertEqual(self.agent.step(155, REACHABLE), "fenced, waiting")  # not before 160
        self.assertEqual(self.agent.step(160, REACHABLE), "unfenced")
        self.assertEqual(self.calls[-1], START)
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_reachability_must_be_continuous(self):
        self.fence_and_reboot()
        self.agent.step(200, REACHABLE)
        self.agent.step(215, ISOLATED)
        self.assertEqual(self.agent.step(240, REACHABLE), "fenced, waiting")

    def test_answering_api_blocks_unfence_even_when_readyz_fails(self):
        self.fence_and_reboot()
        held = probes(accepts={"p1", "p2"}, held={"p1"})  # no /readyz anywhere
        for now in (200, 300, 400):
            self.assertEqual(self.agent.step(now, held),
                             "fenced, waiting for the cluster to release this node")
        self.assertNotIn(START, self.calls)

    def test_any_released_answer_unfences(self):
        self.fence_and_reboot()
        released = probes(api={"p1", "p2"}, accepts={"p1"}, released={"p2"})
        self.agent.step(200, released)
        self.assertEqual(self.agent.step(230, released), "unfenced")

    def test_tcp_fallback_only_without_any_answer(self):
        self.fence_and_reboot()
        self.agent.step(200, REACHABLE)
        self.assertEqual(self.agent.step(230, REACHABLE), "unfenced")

    def test_refencing_soon_doubles_backoff(self):
        self.fence_and_reboot()
        self.agent.step(200, REACHABLE)
        self.agent.step(230, REACHABLE)
        self.agent = self.new_agent()
        self.fence_now(at=600)
        self.assertEqual(read_marker()["backoff"], 120)

    def test_switching_to_observe_releases_an_existing_fence(self):
        self.fence_and_reboot()
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.agent.step(500, REACHABLE), "released for observe mode")
        self.assertEqual(self.calls, [START])
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_observe_mode_never_acts(self):
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.fence_now(), "would fence")
        self.assertEqual(self.calls, [])
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_post_unfence_grace_survives_agent_restart(self):
        self.fence_and_reboot()
        self.agent.step(200, REACHABLE)
        self.agent.step(230, REACHABLE)
        restarted = self.new_agent(grace=False)
        self.assertEqual(restarted.step(300, NOT_READY), "grace")

    def test_manual_release_grace_survives_agent_restart(self):
        self.fence_and_reboot()
        os.remove(MODULE.MARKER)
        self.assertEqual(self.agent.step(500, REACHABLE), "released")
        self.assertIsNone(self.agent.state)
        self.assertEqual(self.agent.step(560, NOT_READY), "grace")
        restarted = self.new_agent(grace=False)
        self.assertEqual(restarted.step(600, NOT_READY), "grace")
        self.assertNotEqual(restarted.step(650, NOT_READY), "grace")

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
                                       lambda: self.boot, broken))
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
            self.agent.step(100, REACHABLE)
            self.assertTrue(self.agent.write_pending())
            for now in (200, 230, 260):
                self.assertEqual(self.agent.step(now, REACHABLE),
                                 "fenced, marker write still pending")
            self.assertNotIn(START, self.calls)
            stuck.set()
            self.agent.writer.join(1)
            self.assertEqual(read_marker()["phase"], "fencing")  # cancelled, not replaced
            # The stability window starts again once the write is gone.
            self.assertEqual(self.agent.step(300, REACHABLE), "fenced, waiting")
            self.assertEqual(self.agent.step(330, REACHABLE), "unfenced")
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
                                       lambda: self.boot, broken))
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


if __name__ == "__main__":
    unittest.main()
