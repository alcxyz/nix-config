#!/usr/bin/env python3
"""Fence this k3s server when the cluster can no longer count on it.

A node cut off from its peers keeps running its containers. If the rest of the
cluster then releases that node's volumes, the old processes could keep
writing. This agent stops k3s and kills its containers once the node has been
unhealthy for FENCE_AFTER seconds, so a cluster-side controller can safely
apply the out-of-service taint later (gitops ADR-058). All probes of a poll run
in parallel, so a poll takes at most about 6 s plus POLL. Worst case from failure to a
verified fence: BOOT_GRACE 150 + AMBIGUOUS_FENCE_AFTER 150 + two polls ~22 +
fence commands ~75 = ~400 s. The controller starts its own timer only when it
sees the node not Ready (~40 s after the failure) and waits TAINT_AFTER 480 s.
All deadlines use CLOCK_BOOTTIME, so wall-clock changes cannot postpone a fence.

Each poll classifies the node from the cluster's point of view, regardless of
the state of k3s itself:

- healthy: an API server (local first, then peers) reports this Node Ready;
- unhealthy: a peer API server is ready but no API server confirms this Node
  Ready, so the cluster sees it as failed;
- ambiguous: no peer API server is ready, but a peer accepts a TCP connection
  on the API port, which usually means the whole control plane is down (a
  refused connection, for example from a REJECT rule, does not count). The
  node fences only after AMBIGUOUS_FENCE_AFTER: the cluster may in fact be
  healthy and about to release this node's volumes;
- isolated (unhealthy): no peer accepts a connection.

Only the first BOOT_GRACE seconds after boot and after the agent restarts k3s
are exempt, so k3s can rejoin.

Fencing is recorded in MARKER before it starts and marked complete only once
no k3s container survives; an interrupted fence is retried, and any doubt about
survivors, or about k3s itself having stopped, forces a reboot, and so does a
failure to write MARKER: k3s.service must not start while MARKER exists (the
module adds a ConditionPathExists), so timers and rebuilds cannot undo a fence.
A fenced node restarts k3s only when that cannot bring old workloads back
before the cluster releases their volumes: while a peer API server is ready,
it waits until its Node carries an out-of-service taint (or the controller is
disabled for it); while no API server is ready anywhere, it waits for a peer
to be reachable on the API port (a refused connection counts), so the cluster
recovers after every node fenced during a network-wide outage. Either
condition must hold for UNFENCE_STABLE seconds, with exponential backoff, and
the post-unfence grace survives agent restarts. Removing MARKER by hand
releases any fence. For maintenance, stop this service: it then marks its
Node `fence.alc.xyz/agent-mode=stopped`, and the controller does not taint a
node whose agent is not enforcing. A fenced agent never marks itself stopped,
and after a completed fence it reports an enforce heartbeat when it can, as
positive evidence for the controller. While healthy, the agent records
`fence.alc.xyz/agent-heartbeat` and `fence.alc.xyz/agent-mode` on its Node
with the field manager node-self-fence; the controller reads the API
server's managedFields time for that manager, not the node's clock.
There is deliberately no pause switch: a paused agent with a fresh enforce
heartbeat would let the controller release volumes that are still in use. Use
the controller's `fence.alc.xyz/disabled` annotation for planned work.

The unit name must not start with "k3s": k3s-killall.sh stops every k3s*
service.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import socket
import subprocess
import sys
import time

FENCE_AFTER = float(os.environ.get("FENCE_AFTER", "60"))
AMBIGUOUS_FENCE_AFTER = float(os.environ.get("AMBIGUOUS_FENCE_AFTER", "150"))
BOOT_GRACE = float(os.environ.get("BOOT_GRACE", "150"))
UNFENCE_STABLE = float(os.environ.get("UNFENCE_STABLE", "30"))
POLL = float(os.environ.get("POLL_SECONDS", "5"))
HEARTBEAT = float(os.environ.get("HEARTBEAT_SECONDS", "60"))
MODE = os.environ.get("FENCE_MODE", "observe")
NODE = os.environ.get("NODE_NAME", "")
PEERS = [peer for peer in os.environ.get("PEERS", "").split() if peer]
API_PORT = int(os.environ.get("API_PORT", "6443"))
KUBECONFIG = os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
K3S = os.environ.get("K3S_BIN", "k3s")
KILLALL = os.environ.get("KILLALL_BIN", "k3s-killall.sh")
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/run/node-self-fence")
MARKER = os.path.join(STATE_DIR, "fenced")
HISTORY = os.path.join(STATE_DIR, "history.json")
# Only k3s's own runtime; Docker-based CI containers use a different address.
K3S_SHIM_PATTERN = "containerd-shim.*-address /run/k3s/containerd"
K3S_PROCESS_PATTERN = "/bin/k3s (server|agent)"
REFENCE_WINDOW = 900

HEALTHY = "healthy"
UNHEALTHY = "unhealthy"
AMBIGUOUS = "ambiguous"


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.sendto(message.encode(), address)


def run(args: list[str], timeout: float) -> int:
    """Run a command, feeding the systemd watchdog while it runs.

    Returns the exit status, or -1 if it timed out and was killed.
    """
    # A new session lets a timeout kill the command's whole process group, so
    # no cleanup child keeps running after the agent moves on.
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    deadline = time.monotonic() + timeout
    while True:
        try:
            return process.wait(timeout=min(5.0, max(0.1, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            notify("WATCHDOG=1")
            if time.monotonic() >= deadline:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                return -1


def capture(args: list[str], timeout: float) -> tuple[int, str]:
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return -1, ""
    finally:
        notify("WATCHDOG=1")
    return result.returncode, result.stdout


def kubectl(server: str, args: list[str]) -> tuple[int, str]:
    return capture(
        [K3S, "kubectl", "--kubeconfig", KUBECONFIG, "--server", f"https://{server}:{API_PORT}",
         "--request-timeout=3s", *args],
        timeout=6,
    )


def node_ready_via(server: str) -> bool:
    """True only if this API server answers that this Node is Ready."""
    status, output = kubectl(server, ["get", "node", NODE, "-o", "json"])
    if status != 0:
        return False
    try:
        conditions = json.loads(output).get("status", {}).get("conditions") or []
    except ValueError:
        return False
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)


def api_ready(server: str) -> bool:
    status, output = kubectl(server, ["get", "--raw=/readyz"])
    return status == 0 and output.strip() == "ok"


def tcp_connect(address: str) -> str:
    """Return "accepted", "refused" or "unreachable" for the peer's API port."""
    try:
        with socket.create_connection((address, API_PORT), timeout=3):
            return "accepted"
    except ConnectionRefusedError:
        return "refused"
    except OSError:
        return "unreachable"
    finally:
        notify("WATCHDOG=1")


def tcp_accepts(address: str) -> bool:
    return tcp_connect(address) == "accepted"


def tcp_reachable(address: str) -> bool:
    """A refused connection still proves the peer host is reachable."""
    return tcp_connect(address) != "unreachable"


def annotate_heartbeat(now: float, mode: str = MODE) -> bool:
    del now  # the controller uses the API server's managedFields time
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for server in ["127.0.0.1", *PEERS]:
        status, _ = kubectl(server, ["annotate", "node", NODE, "--overwrite",
                                     "--field-manager=node-self-fence",
                                     f"fence.alc.xyz/agent-heartbeat={stamp}",
                                     f"fence.alc.xyz/agent-mode={mode}"])
        if status == 0:
            return True
    return False


def released_by_cluster(server: str) -> bool:
    """True if this Node carries an out-of-service taint or opted out of the controller."""
    status, output = kubectl(server, ["get", "node", NODE, "-o", "json"])
    if status != 0:
        return False
    try:
        node = json.loads(output)
    except ValueError:
        return False
    taints = node.get("spec", {}).get("taints") or []
    disabled = (node.get("metadata", {}).get("annotations") or {}).get("fence.alc.xyz/disabled")
    return disabled == "true" or any(
        t.get("key") == "node.kubernetes.io/out-of-service" for t in taints)


def k3s_stopped() -> bool:
    """True only if pgrep positively found neither k3s nor a k3s container shim."""
    for pattern in (K3S_SHIM_PATTERN, K3S_PROCESS_PATTERN):
        status, _ = capture(["pgrep", "-f", pattern], timeout=5)
        if status != 1:
            return False
    return True


def boottime() -> float:
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def parallel(probe, targets: list[str]) -> list[bool]:
    """Run probe against every target at once so a poll stays short."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as pool:
        return list(pool.map(probe, targets))


def probe_all(checks: list[tuple]) -> list[bool]:
    """Run (probe, target) pairs at once; one poll costs one probe timeout."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(checks)) as pool:
        return list(pool.map(lambda check: check[0](check[1]), checks))


def classify(ready, peer_api_ready, peer_accepts) -> tuple[str, str]:
    """Classify the node from injected probes; returns (state, reason)."""
    servers = ["127.0.0.1", *PEERS]
    results = probe_all([(ready, s) for s in servers] + [(peer_api_ready, p) for p in PEERS]
                        + [(peer_accepts, p) for p in PEERS])
    confirmed = any(results[:len(servers)])
    api = any(results[len(servers):len(servers) + len(PEERS)])
    accepts = any(results[len(servers) + len(PEERS):])
    if confirmed:
        return HEALTHY, "Node confirmed Ready"
    if api:
        return UNHEALTHY, "peer API servers are ready but this Node is not confirmed Ready"
    if accepts:
        return AMBIGUOUS, "no API server is ready but peers accept connections: control-plane outage"
    return UNHEALTHY, "no peer accepts a connection: node is isolated"


def write_json(path: str, value: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
    os.replace(temporary, path)


def read_json(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


class Agent:
    def __init__(self, ops=None) -> None:
        # ops: (run, k3s_stopped, annotate_heartbeat) for tests.
        # step() receives CLOCK_BOOTTIME seconds, which is also the uptime.
        (self.run, self.k3s_stopped, self.annotate) = ops or (run, k3s_stopped, annotate_heartbeat)
        self.unhealthy_since: float | None = None
        self.reachable_since: float | None = None
        self.last_heartbeat = -1e12
        self.last_state = ""
        history = read_json(HISTORY) or {}
        self.grace_until = max(BOOT_GRACE, float(history.get("grace_until", 0.0)))
        self.state = read_json(MARKER)
        self.marker_on_disk = os.path.exists(MARKER)
        if self.marker_on_disk and self.state is None:
            log("fence marker unreadable; completing the fence")
            self.state = {"phase": "fencing", "reason": "unreadable fence marker",
                          "backoff": 60.0, "not_before": 0.0}

    def step(self, now: float, probes) -> str:
        """Advance one poll at wall-clock now; returns the action for logs and tests."""
        if self.state is not None:
            if self.marker_on_disk and not os.path.exists(MARKER):
                log("fence marker removed by hand; releasing the fence")
                self.state = None
                self.marker_on_disk = False
                self.grace_until = now + BOOT_GRACE
                return "released"
            if MODE != "enforce":
                # Fencing was switched off: do not leave k3s blocked.
                log("fence marker present in observe mode; releasing it and starting k3s")
                self.release(now)
                return "released for observe mode"
            if self.state.get("phase") == "fencing":
                return self.complete_fence()
            return self.try_unfence(now, probes)
        if now < self.grace_until:
            self.unhealthy_since = None
            return "grace"
        ready, peer_api_ready, peer_accepts = probes[:3]
        verdict, reason = classify(ready, peer_api_ready, peer_accepts)
        if verdict != self.last_state:
            log(f"{verdict}: {reason}")
            self.last_state = verdict
        if verdict == HEALTHY and now - self.last_heartbeat >= HEARTBEAT:
            if self.annotate(now):
                self.last_heartbeat = now
        if verdict == HEALTHY:
            self.unhealthy_since = None
            return verdict
        if self.unhealthy_since is None:
            self.unhealthy_since = now
        deadline = AMBIGUOUS_FENCE_AFTER if verdict == AMBIGUOUS else FENCE_AFTER
        if now - self.unhealthy_since < deadline:
            return f"{verdict}, waiting"
        self.unhealthy_since = None
        if MODE != "enforce":
            log(f"observe mode: would fence now ({reason})")
            return "would fence"
        return self.fence(now, reason)

    def fence(self, now: float, reason: str) -> str:
        log(f"fencing: {reason}")
        history = read_json(HISTORY) or {}
        recent = now - history.get("last_unfence", -1e12) < REFENCE_WINDOW
        backoff = min(history.get("backoff", 30.0) * 2, 3600.0) if recent else 60.0
        self.state = {"phase": "fencing", "reason": reason,
                      "backoff": backoff, "not_before": now + backoff}
        if not self.persist():
            return self.reboot("cannot write the fence marker, so nothing would keep k3s stopped")
        return self.complete_fence()

    def persist(self) -> bool:
        try:
            write_json(MARKER, self.state)
        except OSError as error:
            log(f"cannot write the fence marker: {error}")
            return False
        self.marker_on_disk = True
        return True

    def reboot(self, reason: str) -> str:
        log(f"{reason}; forcing a reboot")
        self.run(["systemctl", "reboot", "--force"], 60)
        return "reboot"

    def complete_fence(self) -> str:
        """Stop k3s and kill its containers; idempotent, retried until verified."""
        try:
            self.run(["systemctl", "stop", "k3s.service"], 20)
            self.run([KILLALL], 45)
            stopped = self.k3s_stopped()
        except Exception as error:  # noqa: BLE001 - any doubt means survivors
            log(f"fence command failed: {error!r}")
            stopped = False
        if not stopped:
            return self.reboot("cannot confirm that k3s and all its containers stopped")
        self.state["phase"] = "fenced"
        if not self.persist():
            return self.reboot("cannot record the completed fence")
        log(f"fenced; k3s restarts once the cluster has released this node, not before "
            f"{self.state['backoff']:.0f}s")
        # Positive evidence for the controller, if the API is reachable at all.
        self.annotate(0.0)
        return "fenced"

    def try_unfence(self, now: float, probes) -> str:
        _, peer_api_ready, _, peer_reachable, released = probes
        if any(parallel(peer_api_ready, PEERS)):
            # The cluster is up: restart only once it has released this node.
            if not any(parallel(released, PEERS)):
                self.reachable_since = None
                return "fenced, waiting for the cluster to release this node"
        elif not any(parallel(peer_reachable, PEERS)):
            self.reachable_since = None
            return "fenced, peers unreachable"
        if self.reachable_since is None:
            self.reachable_since = now
        if now - self.reachable_since < UNFENCE_STABLE or now < self.state["not_before"]:
            return "fenced, waiting"
        log("safe to restart k3s; starting it")
        backoff = self.state["backoff"]
        self.release(now)
        try:
            write_json(HISTORY, {"backoff": backoff, "last_unfence": now,
                                 "grace_until": self.grace_until})
        except OSError as error:
            log(f"cannot record unfence history: {error}")
        return "unfenced"

    def release(self, now: float) -> None:
        try:
            os.remove(MARKER)  # k3s.service refuses to start while the marker exists
        except FileNotFoundError:
            pass
        self.state = None
        self.marker_on_disk = False
        self.reachable_since = None
        self.grace_until = now + BOOT_GRACE
        if self.run(["systemctl", "start", "--no-block", "k3s.service"], 30) != 0:
            log("could not queue a k3s start; the next unhealthy period fences again")


AGENT = None


def stop(signum, frame) -> None:
    """On a stop, tell the controller this node is unprotected, unless it is fenced."""
    del signum, frame
    if AGENT is not None and AGENT.state is not None:
        log("stopping while fenced; leaving the fence in place")
    elif annotate_heartbeat(boottime(), mode="stopped"):
        log("stopping; marked the Node agent-mode=stopped")
    else:
        log("stopping; could not mark the Node agent-mode=stopped")
    raise SystemExit(0)


def main() -> int:
    if not NODE or not PEERS:
        log("NODE_NAME and PEERS must be set")
        return 1
    signal.signal(signal.SIGTERM, stop)
    log(f"self-fence for {NODE} in {MODE} mode; peers: {' '.join(PEERS)}")
    global AGENT
    agent = AGENT = Agent()
    notify("READY=1")
    probes = (node_ready_via, api_ready, tcp_accepts, tcp_reachable, released_by_cluster)
    while True:
        try:
            agent.step(boottime(), probes)
        except Exception as error:  # noqa: BLE001 - keep running; the watchdog covers hangs
            log(f"poll failed: {error!r}")
        notify("WATCHDOG=1")
        time.sleep(POLL)


if __name__ == "__main__":
    raise SystemExit(main())
