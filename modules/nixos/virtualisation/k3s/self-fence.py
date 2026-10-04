#!/usr/bin/env python3
"""Fence this k3s server when the cluster can no longer count on it.

A node cut off from its peers keeps running its containers. If the rest of the
cluster then releases that node's volumes, the old processes could keep
writing. This agent reboots the node once it has been unhealthy for
FENCE_AFTER seconds, with a persistent MARKER that keeps k3s from starting
again, so a cluster-side controller can safely apply the out-of-service taint
later (gitops ADR-058). A reboot is the fence because nothing short of it can
rule out orphaned container processes or busy mounts. All probes of a poll run
in parallel, so a poll takes at most about 6 s plus POLL. Worst case from
failure to a fenced node: BOOT_GRACE 150 + AMBIGUOUS_FENCE_AFTER 150 + two polls
~22 + a reboot attempt 30 + REBOOT_RETRY 30 + a poll 5 + systemd-shutdown
killing processes and unmounting up to ~90 = ~480 s. That stays below the
controller's earliest taint: it starts its timer only when it sees the node
not Ready (~40 s after the failure) and waits TAINT_AFTER 480 s, ~520 s in all.
A process stuck in D state on a dead volume cannot complete its writes, and
RebootWatchdogSec bounds the shutdown. A host whose reboot watchdog is off
(rebootWatchdogSec "0") may wedge after its processes are gone: it stays
fenced but needs a power cycle. All deadlines use CLOCK_BOOTTIME, so wall-clock
changes cannot postpone a fence.

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
are exempt, so k3s can rejoin. A k3s start the agent did not make (an operator
or a rebuild) delays a fence until BOOT_GRACE after the unhealthy period began,
which also bounds a crash-looping k3s.

MARKER lives on persistent storage and records the boot_id of the fencing
boot, the reason, the backoff and the phase. The agent writes it (phase
"fencing") before `systemctl reboot --force`; if it cannot, it powers off
instead, because a reboot without a marker would start k3s again. A marker
write that hangs for MARKER_WRITE_TIMEOUT (a stalled disk) crashes the kernel
through /proc/sysrq-trigger ('c'): a poweroff or sync could block on the disk
while userspace keeps running, but a panic stops every CPU at once. With the
panic timeout set to 0 first (the kubelet sets 10) the node then stays halted
until it is power-cycled. A
timed-out write is cancelled before it replaces MARKER, and no release happens
while it is still outstanding. A marker
from an earlier boot means the reboot happened: the phase becomes "fenced".
A "fencing" marker from this boot means the reboot did not happen: the agent
retries with `--force --force`. An unreadable marker is rewritten as "fencing"
for this boot and rebooted once, so it cannot loop. k3s.service must not start
while MARKER exists (the module adds a ConditionPathExists), so timers and
rebuilds cannot undo a fence. Heartbeats are written only while healthy: the
controller restarts its taint timer on a heartbeat newer than the failure.

A fenced node restarts k3s only when that cannot bring old workloads back
before the cluster releases their volumes. If any peer API server answers an
authenticated request (even with /readyz failing), it waits for release
evidence: its Node carries an out-of-service taint and no pods (other than
finished, DaemonSet, mirror or taint-tolerating ones) or VolumeAttachments
remain for it, or the controller is disabled for it and never tainted it. Only when no
API server answers at all does a peer reachable on the API port suffice (a
refused connection counts), so the cluster recovers after every node fenced
during a network-wide outage. Either condition must hold for UNFENCE_STABLE
seconds, with exponential backoff, and the post-unfence grace survives agent
restarts. Removing MARKER by hand releases any fence (with a grace that also
survives restarts). For maintenance, stop this service: it then marks its
Node `fence.alc.xyz/agent-mode=stopped`, and the controller does not taint a
node whose agent is not enforcing. A fenced agent never marks itself stopped.
While healthy, the agent records `fence.alc.xyz/agent-heartbeat` and
`fence.alc.xyz/agent-mode` on its Node with the field manager node-self-fence;
the controller reads the API server's managedFields time for that manager, not
the node's clock. There is deliberately no pause switch: a paused agent with a
fresh enforce heartbeat would let the controller release volumes that are
still in use. Use the controller's `fence.alc.xyz/disabled` annotation for
planned work.

The history file stays in the runtime directory: its times are CLOCK_BOOTTIME
and must not survive a reboot.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

FENCE_AFTER = float(os.environ.get("FENCE_AFTER", "60"))
AMBIGUOUS_FENCE_AFTER = float(os.environ.get("AMBIGUOUS_FENCE_AFTER", "150"))
BOOT_GRACE = float(os.environ.get("BOOT_GRACE", "150"))
UNFENCE_STABLE = float(os.environ.get("UNFENCE_STABLE", "30"))
REBOOT_RETRY = float(os.environ.get("REBOOT_RETRY", "30"))
MARKER_WRITE_TIMEOUT = float(os.environ.get("MARKER_WRITE_TIMEOUT", "15"))
POLL = float(os.environ.get("POLL_SECONDS", "5"))
HEARTBEAT = float(os.environ.get("HEARTBEAT_SECONDS", "60"))
MODE = os.environ.get("FENCE_MODE", "observe")
NODE = os.environ.get("NODE_NAME", "")
PEERS = [peer for peer in os.environ.get("PEERS", "").split() if peer]
API_PORT = int(os.environ.get("API_PORT", "6443"))
KUBECONFIG = os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
K3S = os.environ.get("K3S_BIN", "k3s")
RUN_DIR = os.environ.get("RUNTIME_DIRECTORY", "/run/node-self-fence")
MARKER = os.environ.get("FENCE_MARKER", "/var/lib/node-self-fence/fenced")
HISTORY = os.path.join(RUN_DIR, "history.json")
BOOT_ID = "/proc/sys/kernel/random/boot_id"
PANIC = "/proc/sys/kernel/panic"
SYSRQ = "/proc/sysrq-trigger"
OUT_OF_SERVICE = "node.kubernetes.io/out-of-service"
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


def capture_full(args: list[str], timeout: float) -> tuple[int, str, str]:
    """Return (status, stdout, stderr); status -1 means the command timed out."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return -1, "", ""
    finally:
        notify("WATCHDOG=1")
    return result.returncode, result.stdout, result.stderr


def capture(args: list[str], timeout: float) -> tuple[int, str]:
    return capture_full(args, timeout)[:2]


def kubectl_full(server: str, args: list[str]) -> tuple[int, str, str]:
    return capture_full(
        [K3S, "kubectl", "--kubeconfig", KUBECONFIG, "--server", f"https://{server}:{API_PORT}",
         "--request-timeout=3s", *args],
        timeout=6,
    )


def kubectl(server: str, args: list[str]) -> tuple[int, str]:
    return kubectl_full(server, args)[:2]


def kubectl_json(server: str, args: list[str]) -> dict | None:
    status, output = kubectl(server, [*args, "-o", "json"])
    if status != 0:
        return None
    try:
        value = json.loads(output)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def node_ready_via(server: str) -> bool:
    """True only if this API server answers that this Node is Ready."""
    node = kubectl_json(server, ["get", "node", NODE])
    conditions = ((node or {}).get("status") or {}).get("conditions") or []
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


def tolerates(pod: dict, taint: dict) -> bool:
    """True if the pod tolerates the taint indefinitely, so it is never evicted."""
    for toleration in (pod.get("spec") or {}).get("tolerations") or []:
        if toleration.get("effect") not in (None, "", taint.get("effect")):
            continue
        if toleration.get("tolerationSeconds") is not None:
            continue  # evicted later, so still running for now
        key = toleration.get("key") or ""
        if (toleration.get("operator") or "Equal") == "Exists":
            if key in ("", OUT_OF_SERVICE):
                return True
        elif key == OUT_OF_SERVICE:
            if (toleration.get("value") or "") == (taint.get("value") or ""):
                return True
    return False


def blocks_release(pod: dict, taint: dict) -> bool:
    """False for finished pods and pods the out-of-service taint never evicts."""
    metadata = pod.get("metadata") or {}
    if any(owner.get("kind") == "DaemonSet" for owner in metadata.get("ownerReferences") or []):
        return False
    if "kubernetes.io/config.mirror" in (metadata.get("annotations") or {}):
        return False
    # Finished pods run no containers, and the taint may never remove them.
    if (pod.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
        return False
    return not tolerates(pod, taint)


# kubectl's stderr when no API server could give evidence: dial errors and client
# timeouts, refused connections, and server errors from a backend that is down.
NO_ANSWER_ERRORS = ("Unable to connect to the server", "was refused",
                    "Error from server (InternalError)", "(ServiceUnavailable)", "(Timeout)")


def release_status(server: str) -> str:
    """Return "no-answer", "released" or "held" for this Node as seen by server.

    Only transport failures and server-side outages are "no-answer"; any other
    failure (NotFound, Forbidden, Unauthorized, throttling, unknown) is "held".
    Timeouts stay "no-answer" deliberately: after a network-wide outage fenced
    every node, the first to restart k3s may serve an API that hangs without
    etcd quorum, and treating that as "held" would deadlock the others.
    """
    status, output, errors = kubectl_full(server, ["get", "node", NODE, "-o", "json"])
    if status == -1 or (status != 0 and any(e in errors for e in NO_ANSWER_ERRORS)):
        return "no-answer"
    if status != 0:
        return "held"
    try:
        node = json.loads(output)
    except ValueError:
        return "held"
    taints = [t for t in (node.get("spec") or {}).get("taints") or []
              if t.get("key") == OUT_OF_SERVICE]
    if not taints:
        # The controller never taints a disabled node, so its volumes never moved.
        disabled = ((node.get("metadata") or {}).get("annotations") or {}).get(
            "fence.alc.xyz/disabled")
        return "released" if disabled == "true" else "held"
    pods = kubectl_json(server, ["get", "pods", "-A", f"--field-selector=spec.nodeName={NODE}"])
    if pods is None or any(blocks_release(pod, taints[0]) for pod in pods.get("items") or []):
        return "held"
    attachments = kubectl_json(server, ["get", "volumeattachments"])
    if attachments is None or any((va.get("spec") or {}).get("nodeName") == NODE
                                  for va in attachments.get("items") or []):
        return "held"
    return "released"


def k3s_age() -> float | None:
    """Seconds since k3s.service last started its main process, or None if unknown."""
    status, output = capture(["systemctl", "show", "-p", "ExecMainStartTimestampMonotonic",
                              "--value", "k3s.service"], timeout=5)
    try:
        started = int(output.strip()) if status == 0 else 0
    except ValueError:
        return None
    if started <= 0:
        return None
    return time.monotonic() - started / 1e6  # both CLOCK_MONOTONIC


def sysrq(command: str) -> None:
    if command == "c":
        # The kubelet sets kernel.panic to 10; a reboot after the panic would
        # come up without the marker and start k3s again, so halt instead.
        with open(PANIC, "w", encoding="ascii") as handle:
            handle.write("0")
    with open(SYSRQ, "w", encoding="ascii") as handle:
        handle.write(command)


def boot_id() -> str:
    try:
        with open(BOOT_ID, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def boottime() -> float:
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def parallel(probe, targets: list[str]) -> list:
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


def write_json(path: str, value: dict, cancel: threading.Event | None = None) -> None:
    """Replace path atomically and durably, unless cancel is set before the replace."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    if cancel is not None and cancel.is_set():
        os.remove(temporary)
        return
    os.replace(temporary, path)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_json(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


class Agent:
    def __init__(self, ops=None) -> None:
        # ops: (run, annotate_heartbeat, k3s_age, boot_id, sysrq) for tests.
        # step() receives CLOCK_BOOTTIME seconds, which is also the uptime.
        (self.run, self.annotate, self.k3s_age, self.boot_id, self.sysrq) = (
            ops or (run, annotate_heartbeat, k3s_age, boot_id, sysrq))
        self.unhealthy_since: float | None = None
        self.reachable_since: float | None = None
        self.last_heartbeat = -1e12
        self.last_state = ""
        history = read_json(HISTORY) or {}
        self.grace_until = max(BOOT_GRACE, float(history.get("grace_until", 0.0)))
        self.state = read_json(MARKER)
        self.marker_on_disk = os.path.exists(MARKER)
        self.writer: threading.Thread | None = None  # a marker write that timed out
        if self.marker_on_disk and self.state is None:
            # Unknown boot: reboot once, after rewriting it for this boot.
            log("fence marker unreadable; fencing again")
            self.state = {"phase": "fencing", "boot_id": None, "reason": "unreadable fence marker",
                          "backoff": 60.0, "attempts": 0}

    def step(self, now: float, probes) -> str:
        """Advance one poll at boot time now; returns the action for logs and tests."""
        if self.state is not None:
            if self.write_pending() and self.state.get("phase") != "fencing":
                # It could still recreate MARKER after a release. A fence that
                # is still "fencing" keeps retrying its crash or reboot instead.
                self.reachable_since = None
                return "fenced, marker write still pending"
            if self.marker_on_disk and not os.path.exists(MARKER):
                log("fence marker removed by hand; releasing the fence")
                self.state = None
                self.marker_on_disk = False
                self.grace_until = now + BOOT_GRACE
                self.record_history(grace_until=self.grace_until)
                return "released"
            if MODE != "enforce":
                # Fencing was switched off: do not leave k3s blocked.
                log("fence marker present in observe mode; releasing it and starting k3s")
                self.release(now)
                return "released for observe mode"
            return self.fenced_step(now, probes)
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
        elapsed = now - self.unhealthy_since
        if elapsed < deadline:
            return f"{verdict}, waiting"
        if elapsed < BOOT_GRACE:
            # Someone else restarted k3s; give it time to rejoin, but never more
            # than BOOT_GRACE into the unhealthy period, so a crash loop still fences.
            age = self.k3s_age()
            if age is not None and age < BOOT_GRACE:
                return "k3s restarted, grace"
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
        self.state = {"phase": "fencing", "boot_id": None, "reason": reason,
                      "backoff": backoff, "attempts": 0}
        return self.request_reboot(now)

    def persist(self) -> bool | None:
        """Write MARKER; False if that failed, None if it hung past MARKER_WRITE_TIMEOUT."""
        if self.write_pending():
            log("an earlier fence marker write is still hanging")
            return None
        result = {}
        state = dict(self.state)
        cancel = threading.Event()

        def write() -> None:
            try:
                write_json(MARKER, state, cancel)
                result["ok"] = True
            except OSError as error:
                log(f"cannot write the fence marker: {error}")

        # A stalled disk can block fsync indefinitely; never wait on it unbounded.
        writer = threading.Thread(target=write, daemon=True)
        writer.start()
        writer.join(MARKER_WRITE_TIMEOUT)
        if writer.is_alive():
            cancel.set()
            self.writer = writer
            log(f"fence marker write hung for {MARKER_WRITE_TIMEOUT:.0f}s")
            return None
        if not result:
            return False
        self.marker_on_disk = True
        return True

    def write_pending(self) -> bool:
        return self.writer is not None and self.writer.is_alive()

    def sysrq_crash(self, reason: str) -> str:
        """Panic the kernel: no device shutdown or sync can block on the stalled disk."""
        log(f"{reason}; crashing the kernel through sysrq")
        try:
            self.sysrq("c")
        except OSError as error:
            log(f"sysrq crash failed: {error}")
            self.run(["systemctl", "poweroff", "--force", "--force", "--no-sync"], 30)
        return "sysrq crash"

    def poweroff(self, reason: str) -> str:
        log(f"{reason}; forcing a poweroff")
        self.run(["systemctl", "poweroff", "--force"], 60)
        return "poweroff"

    def request_reboot(self, now: float) -> str:
        """Record this boot as fencing, then reboot; escalate on a retry."""
        boot = self.boot_id()
        if not boot:
            return self.poweroff("cannot read the boot id, so a reboot could not be confirmed")
        attempts = int(self.state.get("attempts", 0))
        self.state.update(boot_id=boot, attempts=attempts + 1, attempted_at=now)
        persisted = self.persist()
        # A reboot without a marker would start k3s again.
        if persisted is None:
            # The disk is stuck, so a poweroff could hang as well.
            return self.sysrq_crash("the disk does not complete the fence marker write")
        if not persisted:
            return self.poweroff("cannot persist the fence marker")
        command = ["systemctl", "reboot", "--force"] + (["--force"] if attempts else [])
        log(f"rebooting to fence ({' '.join(command)})")
        self.run(command, 30)
        return "reboot"

    def fenced_step(self, now: float, probes) -> str:
        boot = self.boot_id()
        if not boot:
            return self.poweroff("cannot read the boot id while fenced")
        marker_boot = self.state.get("boot_id")
        if marker_boot is not None and marker_boot != boot:
            # The fencing reboot (or a later one) happened; old times are void.
            self.state.update(phase="fenced", boot_id=boot,
                              not_before=now + float(self.state.get("backoff", 60.0)))
            self.state.pop("attempted_at", None)
            if not self.persist():
                log("cannot update the fence marker; it still blocks k3s")
            log(f"fenced; k3s restarts once the cluster has released this node, not before "
                f"{self.state['backoff']:.0f}s")
        elif self.state.get("phase") != "fenced":
            if now - float(self.state.get("attempted_at", -1e12)) < REBOOT_RETRY:
                return "fencing, reboot pending"
            if "attempted_at" in self.state:
                log("the fencing reboot did not happen")
            return self.request_reboot(now)
        return self.try_unfence(now, probes)

    def try_unfence(self, now: float, probes) -> str:
        peer_reachable, release = probes[3:5]
        statuses = parallel(release, PEERS)
        if "released" not in statuses:
            if "held" in statuses:
                # An API server answers: only release evidence may restart k3s.
                self.reachable_since = None
                return "fenced, waiting for the cluster to release this node"
            if not any(parallel(peer_reachable, PEERS)):
                self.reachable_since = None
                return "fenced, peers unreachable"
        if self.reachable_since is None:
            self.reachable_since = now
        not_before = float(self.state.get("not_before", 0.0))
        if now - self.reachable_since < UNFENCE_STABLE or now < not_before:
            return "fenced, waiting"
        log("safe to restart k3s; starting it")
        backoff = self.state["backoff"]
        self.release(now)
        self.record_history(backoff=backoff, last_unfence=now, grace_until=self.grace_until)
        return "unfenced"

    def record_history(self, **values) -> None:
        history = read_json(HISTORY) or {}
        history.update(values)
        try:
            write_json(HISTORY, history)
        except OSError as error:
            log(f"cannot record fence history: {error}")

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
    probes = (node_ready_via, api_ready, tcp_accepts, tcp_reachable, release_status)
    while True:
        try:
            agent.step(boottime(), probes)
        except Exception as error:  # noqa: BLE001 - keep running; the watchdog covers hangs
            log(f"poll failed: {error!r}")
        notify("WATCHDOG=1")
        time.sleep(POLL)


if __name__ == "__main__":
    raise SystemExit(main())
