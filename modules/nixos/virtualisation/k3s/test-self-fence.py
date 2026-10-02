#!/usr/bin/env python3

import importlib.util
import os
import pathlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest import mock

STATE = tempfile.mkdtemp()
os.environ.update({
    "NODE_NAME": "n1", "PEERS": "p1 p2", "STATE_DIRECTORY": STATE,
    "FENCE_MODE": "enforce",
})
SCRIPT = pathlib.Path(__file__).with_name("self-fence.py")
SPEC = importlib.util.spec_from_file_location("self_fence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def probes(ready=(), api=(), accepts=(), refused=(), released=()):
    return (lambda s: s in ready, lambda s: s in api, lambda s: s in accepts,
            lambda s: s in accepts or s in refused, lambda s: s in released)


HEALTHY = probes(ready={"127.0.0.1"})
ISOLATED = probes()
NOT_READY = probes(api={"p1"}, accepts={"p1"})  # cluster up, this Node not Ready
ACCEPTING = probes(accepts={"p1"})  # API port open, no API ready: outage
REACHABLE = probes(refused={"p1"})  # host answers, API port closed


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

    def test_shim_pattern_matches_only_k3s(self):
        pattern = re.compile(MODULE.K3S_SHIM_PATTERN)
        self.assertTrue(pattern.search(
            "/nix/store/x-k3s-containerd/bin/containerd-shim-runc-v2 -namespace k8s.io -id a "
            "-address /run/k3s/containerd/containerd.sock"))
        self.assertFalse(pattern.search(
            "/nix/store/x-docker-containerd/bin/containerd-shim-runc-v2 -namespace moby -id a "
            "-address /run/forgejo-docker/containerd/containerd.sock"))


class AgentTests(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(STATE)
        os.makedirs(STATE)
        self.calls = []
        self.gone = True
        self.heartbeats = []
        self.agent = self.new_agent()

    def new_agent(self, run=None, grace=True):
        agent = MODULE.Agent(ops=(run or self.fake_run, lambda: self.gone, self.fake_annotate))
        if not grace:
            return agent
        agent.grace_until = 0  # most tests start long after boot
        return agent

    def fake_run(self, args, timeout):
        self.calls.append(args)
        return 0

    def fake_annotate(self, now):
        self.heartbeats.append(now)
        return True

    def fence_now(self, p=ISOLATED, at=0):
        self.agent.step(at, p)
        return self.agent.step(at + 60, p)

    def test_fences_only_after_deadline(self):
        self.assertEqual(self.agent.step(0, ISOLATED), "unhealthy, waiting")
        self.assertEqual(self.agent.step(59, ISOLATED), "unhealthy, waiting")
        self.assertEqual(self.agent.step(60, ISOLATED), "fenced")
        self.assertEqual(self.calls[:2], [["systemctl", "stop", "k3s.service"], [MODULE.KILLALL]])
        self.assertTrue(os.path.exists(MODULE.MARKER))

    def test_cluster_view_not_ready_fences(self):
        # Whatever k3s is doing (stuck activating, crash-looping, stopped).
        self.assertEqual(self.fence_now(NOT_READY), "fenced")

    def test_recovery_resets_the_timer(self):
        self.agent.step(0, ISOLATED)
        self.agent.step(30, HEALTHY)
        self.assertEqual(self.agent.step(70, ISOLATED), "unhealthy, waiting")

    def test_ambiguous_fences_only_after_its_longer_deadline(self):
        for now in range(0, 150, 5):
            self.assertEqual(self.agent.step(now, ACCEPTING), "ambiguous, waiting")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.agent.step(150, ACCEPTING), "fenced")

    def test_only_boot_grace_is_exempt(self):
        self.agent = self.new_agent(grace=False)
        self.assertEqual(self.agent.step(100, ISOLATED), "grace")
        self.assertEqual(self.fence_now(at=150), "fenced")

    def test_unfence_starts_a_grace_period(self):
        self.fence_now()
        self.agent.step(200, REACHABLE)
        self.agent.step(230, REACHABLE)
        self.assertEqual(self.agent.step(300, NOT_READY), "grace")
        self.agent.step(380, NOT_READY)
        self.assertEqual(self.agent.step(440, NOT_READY), "fenced")

    def test_marker_write_failure_reboots(self):
        # Without the marker nothing would keep k3s stopped.
        with mock.patch.object(MODULE, "write_json", side_effect=OSError("no space")):
            self.assertEqual(self.fence_now(), "reboot")
        self.assertIn(["systemctl", "reboot", "--force"], self.calls)

    def test_unreadable_marker_completes_the_fence(self):
        with open(MODULE.MARKER, "w", encoding="utf-8") as handle:
            handle.write("")
        agent = self.new_agent()
        self.assertEqual(agent.step(500, ISOLATED), "fenced")
        self.assertIn([MODULE.KILLALL], self.calls)

    def test_observe_mode_never_acts(self):
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.fence_now(), "would fence")
        self.assertEqual(self.calls, [])

    def test_switching_to_observe_releases_an_existing_fence(self):
        self.fence_now()
        self.calls.clear()
        with mock.patch.object(MODULE, "MODE", "observe"):
            self.assertEqual(self.agent.step(500, REACHABLE), "released for observe mode")
        self.assertEqual(self.calls, [["systemctl", "start", "--no-block", "k3s.service"]])
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_unconfirmed_stop_forces_a_reboot(self):
        self.gone = False  # k3s or a container survived, or pgrep failed
        self.assertEqual(self.fence_now(), "reboot")
        self.assertIn(["systemctl", "reboot", "--force"], self.calls)

    def test_interrupted_fence_is_completed_after_restart(self):
        # The agent was killed between writing the marker and finishing the fence.
        MODULE.write_json(MODULE.MARKER, {"phase": "fencing", "reason": "isolated",
                                          "backoff": 60.0, "not_before": 120.0})
        restarted = self.new_agent()
        self.assertEqual(restarted.step(100, ISOLATED), "fenced")
        self.assertIn([MODULE.KILLALL], self.calls)

    def test_unfence_needs_stable_reachability_and_backoff(self):
        self.fence_now()
        self.assertEqual(self.agent.step(70, ISOLATED), "fenced, peers unreachable")
        self.assertEqual(self.agent.step(80, REACHABLE), "fenced, waiting")
        self.assertEqual(self.agent.step(110, REACHABLE), "fenced, waiting")  # not before 120
        self.assertEqual(self.agent.step(120, REACHABLE), "unfenced")
        self.assertEqual(self.calls[-1], ["systemctl", "start", "--no-block", "k3s.service"])
        self.assertFalse(os.path.exists(MODULE.MARKER))

    def test_refused_peers_unfence_after_a_network_wide_outage(self):
        self.fence_now()
        self.agent.step(200, REACHABLE)
        self.assertEqual(self.agent.step(230, REACHABLE), "unfenced")

    def test_reachability_must_be_continuous(self):
        self.fence_now()
        self.agent.step(200, REACHABLE)
        self.agent.step(215, ISOLATED)
        self.assertEqual(self.agent.step(240, REACHABLE), "fenced, waiting")

    def test_refencing_soon_doubles_backoff_across_restarts(self):
        self.fence_now()
        self.agent.step(200, REACHABLE)
        self.agent.step(230, REACHABLE)
        self.agent = self.new_agent()
        self.fence_now(at=600)
        self.assertEqual(self.agent.state["backoff"], 120)

    def test_removing_the_marker_releases_the_fence_with_grace(self):
        self.fence_now()
        os.remove(MODULE.MARKER)
        self.assertEqual(self.agent.step(500, REACHABLE), "released")
        self.assertIsNone(self.agent.state)
        self.assertEqual(self.agent.step(560, NOT_READY), "grace")

    def test_probes_run_in_parallel(self):
        import time
        def slow(_):
            time.sleep(0.3)
            return False
        started = time.monotonic()
        MODULE.classify(slow, slow, slow)
        self.assertLess(time.monotonic() - started, 1.5)  # sequential would be 2.1 s

    def test_timeouts_kill_the_whole_process_group(self):
        pid_file = os.path.join(STATE, "child.pid")
        status = MODULE.run(["sh", "-c", f"sleep 30 & echo $! > {pid_file}; wait"], timeout=1)
        self.assertEqual(status, -1)
        with open(pid_file, encoding="utf-8") as handle:
            child = int(handle.read())
        for _ in range(50):
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            import time
            time.sleep(0.05)
        else:
            self.fail("background child survived the timeout")

    def test_cluster_up_waits_for_release_before_restarting_k3s(self):
        self.fence_now(NOT_READY)
        not_released = probes(api={"p1"}, accepts={"p1"})
        self.assertEqual(self.agent.step(500, not_released),
                         "fenced, waiting for the cluster to release this node")
        released = probes(api={"p1"}, accepts={"p1"}, released={"p1"})
        self.agent.step(600, released)
        self.assertEqual(self.agent.step(630, released), "unfenced")

    def test_post_unfence_grace_survives_agent_restart(self):
        self.fence_now()
        self.agent.step(200, REACHABLE)
        self.agent.step(230, REACHABLE)
        restarted = self.new_agent(grace=False)
        self.assertEqual(restarted.step(300, NOT_READY), "grace")

    def test_fence_command_errors_force_a_reboot(self):
        def broken(args, timeout):
            self.calls.append(args)
            if args[0] == MODULE.KILLALL:
                raise FileNotFoundError(args[0])
            return 0
        self.agent = self.new_agent(run=broken)
        self.assertEqual(self.fence_now(), "reboot")
        self.assertIn(["systemctl", "reboot", "--force"], self.calls)

    def test_completed_fence_reports_an_enforce_heartbeat(self):
        self.fence_now()
        self.assertEqual(len(self.heartbeats), 1)

    def test_stop_signal_does_not_mark_a_fenced_node_stopped(self):
        self.fence_now()
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


if __name__ == "__main__":
    unittest.main()
