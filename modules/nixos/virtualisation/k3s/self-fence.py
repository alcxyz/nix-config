#!/usr/bin/env python3
"""Fence this k3s server when the cluster can no longer count on it.

A node cut off from its peers keeps running its containers. If the rest of the
cluster then releases that node's volumes, the old processes could keep
writing. This agent reboots the node once it has been unhealthy for
FENCE_AFTER seconds, with a persistent MARKER that keeps k3s from starting
again, so a cluster-side controller can safely apply the out-of-service taint
later (gitops ADR-058). A reboot is the fence because nothing short of it can
rule out orphaned container processes or busy mounts. Classification probes run
in parallel; with the state snapshot a poll takes at most about 7 s plus POLL.
Worst case from failure to a fenced node: BOOT_GRACE 150 + AMBIGUOUS_FENCE_AFTER 150 + two polls
~24 + a reboot attempt 30 + REBOOT_RETRY 30 + a poll 5 + systemd-shutdown
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
remain for it, or the controller is disabled for it and never tainted it. Any
API release evidence wins over other answers; otherwise any API answer holds
the fence. When every peer API returns no answer, this node plus distinct peers
verified fenced must number at least N - Q + 1 (N servers, Q = N//2 + 1): the
remainder cannot form a quorum. An enforcing peer that released under this rule
within JOINT_WINDOW seconds also counts if its signed release_peers names this node, so staggered
polls can release together; such joint evidence also skips this node's own
backoff, which could otherwise outlast the window. Changing the counted peers does not restart the
stable window. TCP reachability and elapsed time alone never release a fence.
Either rule must hold continuously for UNFENCE_STABLE seconds and pass a final
check, with exponential backoff, and the post-unfence grace survives agent
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

The threaded /v1/state endpoint stays alive while fenced on STATE_PORT (9097
by default), independently of k3s. It signs locked snapshots with HMAC-SHA256
using a subkey derived from STATE_KEY_FILE. Requests carry a
fresh 64-hex nonce; clients verify the MAC, nonce and receiving socket address
within 3 s. Only a completed fence with k3s inactive reports fenced, and that
report is cleared before k3s starts. Signed release_rule and release_peers
record the last release for this boot, including manual and observe releases.
The key file is read on every request and probe, so rotation and late key
provisioning need no restart. Failed endpoint starts retry every 30 seconds,
logging each failure kind once. Only loopback and configured peer sources are
served, including on trusted pod interfaces. Reads and concurrent clients are
bounded.
node-self-fence-status --json uses the same client for loopback and every peer,
reading the configured key path as root. It exits 0 for all verified states,
1 for any failed probe, or 2 when it cannot run (including a missing key).

The history file stays in the runtime directory: its times are CLOCK_BOOTTIME
and must not survive a reboot.
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import hmac
import ipaddress
import json
import os
import signal
import secrets
import socket
import socketserver
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
STATE_PORT = int(os.environ.get("STATE_PORT", "9097"))
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
JOINT_WINDOW = 60

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
    host = f"[{server}]" if ":" in server else server
    return capture_full(
        [K3S, "kubectl", "--kubeconfig", KUBECONFIG, "--server", f"https://{host}:{API_PORT}",
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


def state_key(path: str) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            token = handle.read().strip()
        return hmac.digest(token, b"node-self-fence state v1", "sha256") if token else None
    except Exception:  # key failures must never expose key material
        return None


def canonical(state: dict) -> bytes:
    return json.dumps(state, sort_keys=True, separators=(",", ":")).encode()


def receive(sock, limit: int, deadline: float, headers_only: bool = False) -> bytes:
    """Bound both total bytes and elapsed time, including trickling clients."""
    data = b""
    while len(data) <= limit:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        sock.settimeout(remaining)
        chunk = sock.recv(min(1024, limit + 1 - len(data)))
        if not chunk:
            return data
        data += chunk
        if len(data) > limit:
            raise ValueError("response too large")
        if headers_only and b"\r\n\r\n" in data:
            return data
    raise ValueError("response too large")


def valid_state(state: dict) -> bool:
    return (all(isinstance(state.get(field), str) and state[field]
                for field in ("node", "boot_id", "nonce", "address"))
            and state.get("mode") in ("enforce", "observe")
            and state.get("classification") in
            ("grace", HEALTHY, UNHEALTHY, AMBIGUOUS, "fencing", "fenced")
            and type(state.get("fenced")) is bool
            and type(state.get("k3s_active")) is bool
            and "release_rule" in state
            and state["release_rule"] in (None, "fenced-peers", "released", "manual", "observe")
            and isinstance(state.get("release_peers"), list)
            and all(isinstance(peer, str) and peer for peer in state["release_peers"])
            and state["release_peers"] == sorted(set(state["release_peers"]))
            and (state["release_rule"] == "fenced-peers" or not state["release_peers"])
            and "since_unfence" in state
            and (state["since_unfence"] is None or
                 type(state.get("since_unfence")) in (int, float)
                 and 0 <= state["since_unfence"] < float("inf"))
            and type(state.get("refence_window")) is int and state["refence_window"] > 0)


def verify_state(response: dict, key: bytes, nonce: str, address: str) -> dict:
    state = response.get("state")
    mac = response.get("mac")
    if not isinstance(state, dict) or not isinstance(mac, str):
        return {"ok": False, "error": "bad response"}
    expected = hmac.new(key, canonical(state), hashlib.sha256).hexdigest()
    if not mac.isascii() or not hmac.compare_digest(mac, expected) or state.get("nonce") != nonce:
        return {"ok": False, "error": "unauthenticated"}
    if state.get("address") != address:
        return {"ok": False, "error": "wrong address"}
    if not valid_state(state):
        return {"ok": False, "error": "bad response"}
    fields = ("node", "boot_id", "mode", "classification", "fenced", "k3s_active",
              "since_unfence", "refence_window", "release_rule", "release_peers")
    return {"ok": True, **{field: state[field] for field in fields}}


def peer_state(address: str, key_path: str | None = None, port: int = STATE_PORT) -> dict:
    key = state_key(key_path if key_path is not None else os.environ.get("STATE_KEY_FILE", ""))
    if key is None:
        return {"ok": False, "error": "no key"}
    nonce = secrets.token_hex(32)
    deadline = time.monotonic() + 3
    try:
        # Literal addresses avoid DNS delays and proxies; address binding prevents
        # a relay from making one fenced node stand in for several peers.
        address = str(ipaddress.ip_address(address))
        with socket.create_connection((address, port), timeout=3) as sock:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            sock.settimeout(remaining)
            sock.sendall(f"GET /v1/state?nonce={nonce} HTTP/1.0\r\n\r\n".encode())
            raw = receive(sock, 8192, deadline)
    except OSError:
        return {"ok": False, "error": "no answer"}
    except ValueError:
        return {"ok": False, "error": "bad response"}
    try:
        headers, body = raw.split(b"\r\n\r\n", 1)
        if headers.split(b"\r\n", 1)[0].split()[1] != b"200":
            return {"ok": False, "error": "bad response"}
        response = json.loads(body)
        if not isinstance(response, dict):
            return {"ok": False, "error": "bad response"}
        return verify_state(response, key, nonce, address)
    except (ValueError, IndexError, TypeError, RecursionError):
        return {"ok": False, "error": "bad response"}


class StateHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        try:
            deadline = time.monotonic() + 3
            raw = receive(self.request, 2048, deadline, headers_only=True)
            line = raw.split(b"\r\n", 1)[0].split()
            prefix = b"/v1/state?nonce="
            valid = (b"\r\n\r\n" in raw and len(line) == 3 and line[0] == b"GET"
                     and line[1].startswith(prefix) and line[2] in (b"HTTP/1.0", b"HTTP/1.1"))
            nonce = line[1][len(prefix):] if valid else b""
            valid = len(nonce) == 64 and all(c in b"0123456789abcdefABCDEF" for c in nonce)
            if valid:
                key = state_key(self.server.key_path if self.server.key_path is not None
                                else os.environ.get("STATE_KEY_FILE", ""))
                if key is None:
                    return
                state = dict(self.server.agent.snapshot())
                address = ipaddress.ip_address(self.request.getsockname()[0])
                if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
                    address = address.ipv4_mapped
                state.update(nonce=nonce.decode("ascii"), address=str(address))
                body = json.dumps({"state": state, "mac": hmac.new(
                    key, canonical(state), hashlib.sha256).hexdigest()}).encode()
                status = b"200 OK"
            else:
                status, body = b"400 Bad Request", b"{}"
            self.request.settimeout(max(0.001, deadline - time.monotonic()))
            self.request.sendall(b"HTTP/1.0 " + status + b"\r\nContent-Type: application/json\r\n"
                                 b"Connection: close\r\nContent-Length: " + str(len(body)).encode()
                                 + b"\r\n\r\n" + body)
        except Exception:  # a failed request must never disturb fencing or log key material
            pass


class StateServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, agent, key_path: str | None = None) -> None:
        self.agent, self.key_path = agent, key_path
        self.slots = threading.BoundedSemaphore(16)
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, StateHandler)

    def server_bind(self) -> None:
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def process_request(self, request, client_address) -> None:
        try:
            source = ipaddress.ip_address(client_address[0])
            if isinstance(source, ipaddress.IPv6Address) and source.ipv4_mapped:
                source = source.ipv4_mapped
            allowed = source.is_loopback
            for peer in PEERS:
                try:
                    address = ipaddress.ip_address(peer)
                    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
                        address = address.ipv4_mapped
                    allowed = allowed or source == address
                except ValueError:
                    continue
        except ValueError:
            allowed = False
        if not allowed:
            self.shutdown_request(request)
            return
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address) -> None:
        pass


class StateEndpoint:
    def __init__(self, agent) -> None:
        self.agent = agent
        self.server = None
        self.last_attempt: float | None = None
        self.failures = set()

    def start(self, now: float) -> None:
        if self.server is not None or (self.last_attempt is not None and now - self.last_attempt < 30):
            return
        self.last_attempt = now
        server = None
        try:
            listen = str(ipaddress.IPv6Address(0)) if socket.has_dualstack_ipv6() else "0.0.0.0"
            server = StateServer((listen, STATE_PORT), self.agent)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.server = server
        except (OSError, ValueError) as error:
            if server is not None:
                server.server_close()
            kind = (type(error).__name__, getattr(error, "errno", None))
            if kind not in self.failures:
                self.failures.add(kind)
                log(f"fence-state endpoint unavailable, fencing continues without it: {kind[0]}"
                    f" (errno {kind[1]})")


def k3s_active() -> bool:
    status, output = capture(["systemctl", "show", "-p", "ActiveState", "--value", "k3s.service"], 1)
    # Unknown and activating states cannot attest that k3s is stopped.
    return status != 0 or output.strip() not in ("inactive", "failed")


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
        # ops: (run, annotate_heartbeat, k3s_age, boot_id, sysrq, k3s_active) for tests.
        # step() receives CLOCK_BOOTTIME seconds, which is also the uptime.
        (self.run, self.annotate, self.k3s_age, self.boot_id, self.sysrq, self.k3s_active) = (
            ops or (run, annotate_heartbeat, k3s_age, boot_id, sysrq, k3s_active))
        self.unhealthy_since: float | None = None
        self.evidence_since: float | None = None
        self.evidence_rule = ""
        self.evidence_peers = []
        self.evidence_joint = False
        self.snapshot_lock = threading.Lock()
        self.published = {}
        self.last_heartbeat = -1e12
        self.last_state = ""
        history = read_json(HISTORY) or {}
        self.last_unfence = history.get("last_unfence")
        self.release_rule = history.get("release_rule")
        self.release_peers = history.get("release_peers", [])
        self.grace_until = max(BOOT_GRACE, float(history.get("grace_until", 0.0)))
        self.state = read_json(MARKER)
        self.marker_on_disk = os.path.exists(MARKER)
        self.writer: threading.Thread | None = None  # a marker write that timed out
        if self.marker_on_disk and self.state is None:
            # Unknown boot: reboot once, after rewriting it for this boot.
            log("fence marker unreadable; fencing again")
            self.state = {"phase": "fencing", "boot_id": None, "reason": "unreadable fence marker",
                          "backoff": 60.0, "attempts": 0}
        self.publish(boottime(), "grace", True)

    def publish(self, now: float, classification: str, active: bool) -> None:
        phase = (self.state or {}).get("phase")
        with self.snapshot_lock:
            self.published = {
                "node": NODE, "boot_id": self.boot_id(), "mode": MODE,
                "classification": phase if phase in ("fencing", "fenced") else classification,
                "fenced": phase == "fenced" and not active, "k3s_active": active,
                "since_unfence": None if self.last_unfence is None else max(0, now - self.last_unfence),
                "refence_window": REFENCE_WINDOW,
                "release_rule": self.release_rule, "release_peers": list(self.release_peers),
            }

    def snapshot(self) -> dict:
        with self.snapshot_lock:
            return dict(self.published)

    def step(self, now: float, probes) -> str:
        """Advance one poll at boot time now; returns the action for logs and tests."""
        result = "grace"
        try:
            result = self.advance(now, probes)
            return result
        finally:
            classification = result.split(",", 1)[0]
            if result == "k3s restarted, grace":
                classification = "grace"
            if classification not in ("grace", HEALTHY, UNHEALTHY, AMBIGUOUS):
                classification = "grace" if now < self.grace_until else self.last_state or UNHEALTHY
            self.publish(now, classification, self.k3s_active())

    def advance(self, now: float, probes) -> str:
        if self.state is not None:
            if self.write_pending() and self.state.get("phase") != "fencing":
                # It could still recreate MARKER after a release. A fence that
                # is still "fencing" keeps retrying its crash or reboot instead.
                self.evidence_since = None
                return "fenced, marker write still pending"
            if self.marker_on_disk and not os.path.exists(MARKER):
                log("fence marker removed by hand; releasing the fence")
                self.release(now, "manual", start=False)
                return "released"
            if MODE != "enforce":
                # Fencing was switched off: do not leave k3s blocked.
                log("fence marker present in observe mode; releasing it and starting k3s")
                self.release(now, "observe")
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
        self.publish(now, "fencing", True)
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
            log(f"fenced; k3s restarts on release evidence or verified fenced peers, not before "
                f"{self.state['backoff']:.0f}s")
        elif self.state.get("phase") != "fenced":
            if now - float(self.state.get("attempted_at", -1e12)) < REBOOT_RETRY:
                return "fencing, reboot pending"
            if "attempted_at" in self.state:
                log("the fencing reboot did not happen")
            return self.request_reboot(now)
        return self.try_unfence(now, probes)

    def release_evidence(self, probes) -> str:
        self.evidence_peers = []
        self.evidence_joint = False
        peer, release = probes[3:5]
        statuses = parallel(release, PEERS)
        if "released" in statuses:
            return "released"
        if "held" in statuses:
            return "held"
        if any(status != "no-answer" for status in statuses) or self.k3s_active():
            return "unverified"
        states = parallel(peer, PEERS)
        valid = [state for state in states
                 if state.get("ok") is True and state.get("mode") == "enforce"
                 and state.get("node") != NODE]
        fenced = {state["node"] for state in valid
                  if state.get("fenced") is True and state.get("k3s_active") is False
                  and state.get("classification") == "fenced"}
        joint = {state["node"] for state in valid
                 if state.get("release_rule") == "fenced-peers"
                 and NODE in state.get("release_peers", [])
                 and state.get("since_unfence") is not None
                 and 0 <= state["since_unfence"] <= JOINT_WINDOW}
        names = fenced | joint
        self.evidence_peers = sorted(names)
        self.evidence_joint = bool(joint)
        servers = len(PEERS) + 1
        quorum = servers // 2 + 1
        return "fenced-peers" if len(names) + 1 >= servers - quorum + 1 else "unverified"

    def try_unfence(self, now: float, probes) -> str:
        rule = self.release_evidence(probes)
        if rule not in ("released", "fenced-peers"):
            self.evidence_since = None
            self.evidence_rule = ""
            return ("fenced, waiting for the cluster to release this node" if rule == "held"
                    else "fenced, insufficient verified fenced peers")
        if self.evidence_since is None or rule != self.evidence_rule:
            self.evidence_since = now
            self.evidence_rule = rule
        # A peer that already restarted counting on this node cannot wait out
        # this node's backoff: its joint evidence expires after JOINT_WINDOW.
        not_before = 0.0 if self.evidence_joint else float(self.state.get("not_before", 0.0))
        if now - self.evidence_since < UNFENCE_STABLE or now < not_before:
            return "fenced, waiting"
        # Both rules are queried again; switching rules needs its own stable window.
        if self.release_evidence(probes) != rule:
            self.evidence_since = None
            self.evidence_rule = ""
            return "fenced, evidence changed before release"
        log("safe to restart k3s; starting it")
        backoff = self.state["backoff"]
        self.release(now, rule, self.evidence_peers)
        self.record_history(backoff=backoff)
        return "unfenced"

    def record_history(self, **values) -> None:
        history = read_json(HISTORY) or {}
        history.update(values)
        try:
            write_json(HISTORY, history)
        except OSError as error:
            log(f"cannot record fence history: {error}")

    def release(self, now: float, rule: str = "manual", peers: list[str] | None = None,
                start: bool = True) -> None:
        try:
            os.remove(MARKER)  # k3s.service refuses to start while the marker exists
        except FileNotFoundError:
            pass
        self.state = None
        self.marker_on_disk = False
        self.evidence_since = None
        self.evidence_rule = ""
        self.release_rule = rule
        self.release_peers = sorted(set(peers or [])) if rule == "fenced-peers" else []
        self.grace_until = now + BOOT_GRACE
        self.last_unfence = now
        self.publish(now, "grace", False)
        self.record_history(last_unfence=now, grace_until=self.grace_until,
                            release_rule=self.release_rule, release_peers=self.release_peers)
        if start and self.run(["systemctl", "start", "--no-block", "k3s.service"], 30) != 0:
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


def status_command() -> int:
    if not NODE or not PEERS or os.geteuid() != 0:
        log("status requires root, NODE_NAME and PEERS")
        return 2
    addresses = ["127.0.0.1", *PEERS]
    results = parallel(peer_state, addresses)
    states = [{**result, "address": address, "self": index == 0}
              for index, (address, result) in enumerate(zip(addresses, results))]
    # A loopback endpoint must name this node, not another local agent.
    if states[0].get("ok") and states[0].get("node") != NODE:
        states[0] = {"address": addresses[0], "self": True, "ok": False, "error": "bad response"}
    servers = len(PEERS) + 1
    print(json.dumps({"node": NODE, "servers": servers, "quorum": servers // 2 + 1,
                      "states": states}))
    return 2 if any(state.get("error") == "no key" for state in states) else int(
        any(not state["ok"] for state in states))


def main() -> int:
    if not NODE or not PEERS:
        log("NODE_NAME and PEERS must be set")
        return 1
    signal.signal(signal.SIGTERM, stop)
    log(f"self-fence for {NODE} in {MODE} mode; peers: {' '.join(PEERS)}")
    global AGENT
    agent = AGENT = Agent()
    # Fencing must not depend on the endpoint: without it, peers cannot count
    # this node toward their release evidence. Retry while fencing continues.
    endpoint = StateEndpoint(agent)
    notify("READY=1")
    probes = (node_ready_via, api_ready, tcp_accepts, peer_state, release_status)
    while True:
        try:
            now = boottime()
            endpoint.start(now)
            agent.step(now, probes)
        except Exception as error:  # noqa: BLE001 - keep running; the watchdog covers hangs
            log(f"poll failed: {error!r}")
        notify("WATCHDOG=1")
        time.sleep(POLL)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--status" and sys.argv[2:] in ([], ["--json"]):
        raise SystemExit(status_command())
    if len(sys.argv) > 1:
        log("usage: self-fence.py [--status [--json]]")
        raise SystemExit(2)
    raise SystemExit(main())
