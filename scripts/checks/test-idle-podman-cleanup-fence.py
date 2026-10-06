#!/usr/bin/env python3
"""Disposable UNIX API fixture: never contacts systemd or a container runtime."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HELPER = Path(sys.argv.pop(1)).resolve()
MODULE = HELPER.parent
IMAGE = 'a' * 64


def image(number, created=0, **fields):
    return dict(Id=f'sha256:{number:064x}', Created=created, Containers=0,
                RepoTags=['fixture:old'], ParentId='', **fields)


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        (self.state / 'runners' / 'forgejo-podman-runner.service').mkdir(parents=True)
        self.state.chmod(0o700)
        self.units = ['forgejo-actions-runner.service', 'forgejo-podman-runner.service']
        (self.state / 'runner-units').write_text('\n'.join(self.units) + '\n')
        self.fence = self.state / 'cleanup-in-flight'
        self.calls = []
        self.mutations = []
        self.images = [image(int(IMAGE, 16))]
        self.containers = []
        self.volumes = []
        self.started = threading.Event()
        self.completed = threading.Event()
        self.release = threading.Event()
        self.delay = False
        self.reply = None
        self.status = 200
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.calls.append(('GET', self.path))
                if getattr(self.server, 'docker', False):
                    value = []
                elif self.path == '/containers/json?all=1':
                    value = owner.containers
                elif self.path == '/v5.0.0/libpod/volumes/json':
                    value = owner.volumes
                elif self.path == '/images/json?all=true':
                    value = owner.images
                else:
                    self.send_error(404)
                    return
                self.respond(200, json.dumps(value).encode())

            def destructive(self):
                owner.calls.append((self.command, self.path))
                # The fence must already exist when the server sees a mutation.
                if not owner.fence.is_dir() or not (owner.fence / 'owner').is_file():
                    self.send_error(500)
                    return
                owner.started.set()
                if owner.delay:
                    owner.release.wait(25)
                owner.mutations.append(self.path)
                owner.completed.set()
                status = owner.status
                if '/images/' in self.path:
                    image_id = self.path.split('/images/')[1].split('?')[0]
                    body = json.dumps([{'Deleted': image_id}]).encode()
                elif '/containers/prune' in self.path:
                    body = b'[]'
                elif '/containers/' in self.path:
                    container_id = self.path.split('/containers/')[1].split('?')[0]
                    body = json.dumps([{'Id': container_id}]).encode()
                    owner.containers = []
                elif '/volumes/' in self.path:
                    status = 204 if status == 200 else status
                    body = b''
                else:
                    self.send_error(404)
                    return
                if status == 409:
                    body = b'{"cause":"conflict","message":"in use","response":409}'
                if owner.reply is not None:
                    body = owner.reply
                self.respond(status, body)

            do_DELETE = destructive
            do_POST = destructive

            def respond(self, status, body):
                try:
                    self.send_response(status)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True

        self.server = Server(str(self.root / 'api.sock'), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.docker_server = Server(str(self.root / 'docker.sock'), Handler)
        self.docker_server.docker = True
        threading.Thread(target=self.docker_server.serve_forever, daemon=True).start()
        self.script('systemctl', '''case "$*" in
  'is-active --quiet '*) exit 0 ;;
  'show --property=FreezerState --value '*) echo running ;;
  'show --property=ExecMainStartTimestampMonotonic --value '*) echo 12345 ;;
  'show --property=ActiveState --property=SubState --property=MainPID --property=ControlPID --property=Job '*)
    printf 'ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=0\\nJob=\\n' ;;
  *) exit 2 ;;
esac
''')
        self.script('df', 'printf "Size Avail\\n100 20\\n"\n')
        curl = shutil.which('curl')
        self.script('curl', f'exec {curl} --disable "$@"\n')
        self.env = {**os.environ, 'STATE_DIR': str(self.state),
                    'SYSTEMCTL_BIN': str(self.root / 'systemctl'),
                    'DF_BIN': str(self.root / 'df'), 'CURL_BIN': str(self.root / 'curl'),
                    'DOCKER_SOCKET': str(self.root / 'docker.sock'),
                    'PODMAN_SOCKET': str(self.root / 'api.sock'),
                    'GAME_ADMISSION_ENABLED': '0', 'DISK_SPACE_ENABLED': '0',
                    'RUNNER_UNITS': ' '.join(self.units), 'GATE_TIMEOUT_SECONDS': '2'}

    def script(self, name, body):
        path = self.root / name
        path.write_text('#!/usr/bin/env bash\nset -eu\n' + body)
        path.chmod(0o755)

    def run(self, **env):
        return subprocess.run(['bash', str(HELPER)], env={**self.env, **env},
                              capture_output=True, text=True, timeout=25)

    def start(self):
        return subprocess.Popen(['bash', str(HELPER)], env=self.env, start_new_session=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.docker_server.shutdown()
        self.docker_server.server_close()
        self.temp.cleanup()


class FenceTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.close)

    def assert_fenced(self):
        self.assertTrue(self.f.fence.exists() or self.f.fence.is_symlink())
        with (self.f.state / 'lifecycle.lock').open('a') as lock:
            # Reaped helper stdout is not a barrier for every killed child's
            # inherited lock descriptor. Require bounded release, not same-tick
            # scheduling; a leaked or living descriptor still fails the test.
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.02)
        before = list(self.f.calls)
        result = self.f.run()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), 'failed step=cleanup_in_flight')
        self.assertEqual(self.f.calls, before)
        for unit in self.f.units:
            result = subprocess.run(['bash', str(MODULE / 'runner-start-gate.sh')],
                                    env={**self.f.env, 'RUNNER_UNIT': unit}, capture_output=True)
            self.assertEqual(result.returncode, 1)
        result = subprocess.run(['bash', str(MODULE / 'podman-api-start-gate.sh')],
                                env=self.f.env, capture_output=True)
        self.assertEqual(result.returncode, 1)

    def test_acknowledged_operations_clear_only_owned_fence(self):
        self.f.containers = [{'Id': IMAGE, 'State': 'running', 'Created': 0,
                              'Names': ['/buildx_buildkit_fixture0']}]
        self.f.volumes = [{'Name': 'buildx_buildkit_fixture0_state'}]
        (self.f.state / 'drain-owned').write_text('123\n')
        (self.f.state / 'runners' / self.f.units[1] / 'drain-owned').write_text('456\n')
        result = self.f.run()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(len(self.f.mutations), 4)
        self.assertFalse(self.f.fence.exists())
        self.assertEqual((self.f.state / 'drain-owned').read_text(), '123\n')
        self.assertEqual((self.f.state / 'runners' / self.f.units[1] / 'drain-owned').read_text(), '456\n')

    def test_selection_is_oldest_capped_and_preserves_protected_images(self):
        self.f.images = [image(i, created=i) for i in reversed(range(1, 13))]
        self.f.images += [image(20, int(time.time())),
                          dict(image(21), Containers=1),
                          dict(image(22), RepoTags=['fixture:a', 'fixture:b']),
                          dict(image(23), ParentId=f'{24:064x}'), image(24)]
        result = self.f.run()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        deleted = [path for path in self.f.mutations if path.startswith('/images/')]
        self.assertEqual(deleted, [f'/images/{i:064x}?force=false&noprune=true'
                                   for i in [23, 1, 2, 3, 4, 5, 6, 7]])
        self.assertFalse(any('images/prune' in path for _, path in self.f.calls))

    def test_empty_or_protected_image_selection_is_successful(self):
        for images in ([], [image(1, int(time.time())),
                            dict(image(2), Containers=1),
                            dict(image(3), RepoTags=['fixture:a', 'fixture:b'])]):
            with self.subTest(images=images):
                self.f.images = images
                self.f.mutations.clear()
                result = self.f.run()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn('images=0 reclaimed_bytes=', result.stdout)
                self.assertNotIn('engine_api_invalid', result.stdout)
                self.assertFalse(self.f.fence.exists())
                self.assertFalse(any(path.startswith('/images/') for path in self.f.mutations))
    def test_age_cutoff_and_budget_stop_allow_bounded_partial_work(self):
        self.f.images = [image(1, int(time.time()) - 49 * 3600)]
        result = self.f.run(IMAGE_MIN_AGE='72h')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.f.mutations), 1)  # container prune only
        self.f.mutations.clear()
        result = self.f.run(LOCK_BUDGET_SECONDS='12')
        self.assertEqual(result.returncode, 0)
        self.assertIn('lock_budget_exhausted step=remove_image', result.stdout)
        self.assertEqual(len(self.f.mutations), 1)
        self.assertFalse(self.f.fence.exists())

    def test_large_creation_age_does_not_overflow_into_recent_deletion(self):
        self.f.images = [image(1, int(time.time()))]
        result = self.f.run(IMAGE_MIN_AGE='18446744073709551616h')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(len(self.f.mutations), 1)

    def test_invalid_image_snapshot_never_deletes_an_image(self):
        for images in ({}, [dict(image(1), Created='old')], [image(1), image(1)]):
            self.f.images = images
            result = self.f.run()
            self.assertIn('engine_api_invalid engine=podman', result.stdout)
            self.assertFalse(any(path.startswith('/images/') for path in self.f.mutations))
            self.assertFalse(self.f.fence.exists())

    def test_fence_failure_precedes_disk_and_live_runner_skips(self):
        for kind in ('directory', 'file', 'dangling'):
            with self.subTest(kind=kind):
                if kind == 'directory':
                    self.f.fence.mkdir()
                elif kind == 'file':
                    self.f.fence.write_text('malformed\n')
                else:
                    self.f.fence.symlink_to(self.f.root / 'missing')
                # A genuinely live runner would normally produce a healthy skip.
                self.f.script('systemctl', '''case "$*" in
  'show --property=FreezerState --value '*) echo running ;;
  'is-active --quiet '*) exit 0 ;;
  'show --property=ActiveState '*)
    printf 'ActiveState=active\\nSubState=running\\nMainPID=123\\nControlPID=0\\nJob=\\n' ;;
  *) exit 2 ;;
esac
''')
                for available in (90, 20):
                    self.f.script('df', f'printf "Size Avail\\n100 {available}\\n"\n')
                    for _ in range(3):
                        result = self.f.run()
                        self.assertEqual(result.returncode, 1)
                        self.assertEqual(result.stderr.strip(), 'failed step=cleanup_in_flight')
                        self.assertEqual(self.f.calls, [])
                if kind == 'directory':
                    self.f.fence.rmdir()
                else:
                    self.f.fence.unlink()

    def test_no_pressure_and_no_window_skips_remain_healthy(self):
        self.f.script('df', 'printf "Size Avail\\n100 90\\n"\n')
        result = self.f.run()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'skipped reason=below_trigger')
        self.f.script('df', 'printf "Size Avail\\n100 20\\n"\n')
        self.f.script('systemctl', '''case "$*" in
  'show --property=FreezerState --value '*) echo running ;;
  'is-active --quiet '*) exit 0 ;;
  'show --property=ActiveState '*)
    printf 'ActiveState=active\\nSubState=running\\nMainPID=123\\nControlPID=0\\nJob=\\n' ;;
  *) exit 2 ;;
esac
''')
        result = self.f.run()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'skipped reason=runner_active unit=forgejo-actions-runner.service')
        self.assertEqual(self.f.calls, [])

    def test_fence_created_while_waiting_for_lock_fails(self):
        with (self.f.state / 'lifecycle.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # A disk sample proves the pre-lock fence check already passed.
            checkpoint = self.f.root / 'disk-sampled'
            self.f.script('df', f'touch {checkpoint}\nprintf "Size Avail\\n100 20\\n"\n')
            process = self.f.start()
            try:
                deadline = time.monotonic() + 3
                while not checkpoint.exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.02)
                self.f.fence.mkdir()
                fcntl.flock(lock, fcntl.LOCK_UN)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 1, stdout + stderr)
                self.assertEqual(stderr.strip(), 'failed step=cleanup_in_flight')
                self.assertEqual(self.f.calls, [])
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()

    def test_dangling_and_protected_snapshots_use_strict_compat_schema(self):
        # v5.8.7 compat normalizes untagged RepoTags to []; Containers is a count.
        self.f.images = [dict(image(1), RepoTags=[]), dict(image(2), Containers=1),
                         dict(image(3), RepoTags=['a:old', 'b:old']),
                         dict(image(4), ParentId=f'{5:064x}'),
                         dict(image(5), RepoTags=[])]
        result = self.f.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        deleted = [path for path in self.f.mutations if path.startswith('/images/')]
        self.assertEqual(deleted, [f'/images/{i:064x}?force=false&noprune=true' for i in (1, 4)])
        self.assertIn('images=2 reclaimed_bytes=', result.stdout)
        for fields in ({'RepoTags': None}, {'RepoTags': 'tag'}, {'RepoTags': [None]},
                       {'Containers': None}, {'Containers': -1}, {'Containers': '0'},
                       {'Containers': 0.5}):
            with self.subTest(fields=fields):
                self.f.images = [image(1), dict(image(2), **fields)]
                self.f.mutations.clear()
                result = self.f.run()
                self.assertIn('engine_api_invalid engine=podman', result.stdout)
                self.assertFalse(any(path.startswith('/images/') for path in self.f.mutations))

    def test_bad_completion_responses_leave_fence(self):
        for status, body in [(500, b'{"message":"error"}'), (202, b'[]'),
                             (200, b'['), (200, b'[] []'), (200, b'{}'),
                             (200, b'[{"Id":"' + IMAGE.encode() + b'","Size":0,"Err":"failure"}]'),
                             (200, b' ' * (8388608 + 1))]:
            with self.subTest(status=status, body_length=len(body)):
                self.f.status, self.f.reply = status, body
                result = self.f.run()
                self.assertEqual(result.returncode, 1)
                self.assert_fenced()
                shutil.rmtree(self.f.fence)  # test fixture reset only

    def test_all_destructive_kinds_leave_fence_on_error(self):
        for kind in ('container', 'volume', 'prune', 'image'):
            self.f.containers = ([{'Id': IMAGE, 'State': 'running', 'Created': 0,
                                   'Names': ['/buildx_buildkit_fixture0']}] if kind == 'container' else [])
            self.f.volumes = [{'Name': 'buildx_buildkit_fixture0_state'}] if kind == 'volume' else []
            # Fail the selected endpoint, allow preceding acknowledged requests.
            curl = shutil.which('curl')
            path = {'container': '/libpod/containers/', 'volume': '/libpod/volumes/',
                    'prune': '/libpod/containers/prune', 'image': '/images/'}[kind]
            self.f.script('curl', f'''case "${{@: -1}}" in
  *'{path}'*) if [[ -d $STATE_DIR/cleanup-in-flight ]]; then printf '{{"message":"error"}}' > "$STATE_DIR/cleanup-in-flight/response"; printf 500; else exec {curl} --disable "$@"; fi ;;
  *) exec {curl} --disable "$@" ;;
esac
''')
            result = self.f.run()
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assert_fenced()
            shutil.rmtree(self.f.fence)

    def test_validated_volume_conflict_is_completed_and_preserved(self):
        self.f.volumes = [{'Name': 'buildx_buildkit_fixture0_state'}]
        curl = shutil.which('curl')
        self.f.script('curl', f'''case "${{@: -1}}" in
  */libpod/volumes/*) if [[ -d $STATE_DIR/cleanup-in-flight ]]; then printf '{{"cause":"conflict","message":"in use","response":409}}' > "$STATE_DIR/cleanup-in-flight/response"; printf 409; else exec {curl} --disable "$@"; fi ;;
  *) exec {curl} --disable "$@" ;;
esac
''')
        result = self.f.run()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('kept_builder_volume', result.stdout)
        self.assertFalse(self.f.fence.exists())

    def test_changed_ownership_cannot_be_cleared_by_acknowledgement(self):
        jq = shutil.which('jq')
        self.f.script('jq', f'''if [[ $1 == -se ]]; then
  printf 'replacement-owner\\n' > "$STATE_DIR/cleanup-in-flight/owner"
fi
exec {jq} "$@"
''')
        result = self.f.run(JQ_BIN=str(self.f.root / 'jq'))
        self.assertEqual(result.returncode, 1)
        self.assertIn('cleanup_fence_ownership', result.stderr)
        self.assert_fenced()
        self.assertEqual((self.f.fence / 'owner').read_text(), 'replacement-owner\n')

    def test_outer_deadline_during_mutation_retains_fence(self):
        self.f.delay = True
        process = subprocess.Popen(['timeout', '-k', '1s', '1s', 'bash', str(HELPER)],
                                   env=self.f.env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.f.started.wait(1))
            process.communicate(timeout=4)
            self.assertEqual(process.returncode, 124)
            self.assert_fenced()
            self.f.release.set()
            self.assertTrue(self.f.completed.wait(3))
            self.assert_fenced()
        finally:
            self.f.release.set()
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_helper_death_with_live_curl_does_not_clear_fence(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                self.f.delay = True
                self.f.release.clear()
                self.f.started.clear()
                self.f.completed.clear()
                process = self.f.start()
                try:
                    self.assertTrue(self.f.started.wait(3))
                    os.kill(process.pid, sig)
                    # Let the orphaned curl receive a complete response. Only
                    # the dead helper owned acknowledgement/fence removal.
                    self.f.release.set()
                    process.communicate(timeout=4)
                    self.assertTrue(self.f.completed.wait(3))
                    self.assert_fenced()
                finally:
                    self.f.release.set()
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                    shutil.rmtree(self.f.fence)

    def test_existing_malformed_and_dangling_fences_are_never_replaced(self):
        self.f.fence.symlink_to(self.f.root / 'missing')
        self.assert_fenced()
        self.f.fence.unlink()
        self.f.fence.write_text('unowned\n')
        self.assert_fenced()
        self.assertEqual(self.f.fence.read_text(), 'unowned\n')

    def test_late_server_mutation_after_real_client_timeout_remains_fenced(self):
        # Delay the actual first 15-second image DELETE, after acknowledged prune.
        original = self.f.server.RequestHandlerClass.destructive
        def delayed(handler):
            self.f.delay = handler.path.startswith('/images/')
            original(handler)
        self.f.server.RequestHandlerClass.do_DELETE = delayed
        process = self.f.start()
        try:
            deadline = time.monotonic() + 8
            while not any(method == 'DELETE' for method, _ in self.f.calls):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            stdout, stderr = process.communicate(timeout=19)
            self.assertEqual(process.returncode, 1, stdout + stderr)
            self.assertFalse(any(path.startswith('/images/') for path in self.f.mutations))
            self.assert_fenced()
            self.f.release.set()
            deadline = time.monotonic() + 3
            while not any(path.startswith('/images/') for path in self.f.mutations):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            self.assert_fenced()
        finally:
            self.f.release.set()
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_helper_signals_before_during_and_after_server_completion(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for phase in ('before', 'during', 'after'):
                with self.subTest(signal=sig, phase=phase):
                    checkpoint = self.f.root / 'checkpoint'
                    checkpoint.unlink(missing_ok=True)
                    curl, jq = shutil.which('curl'), shutil.which('jq')
                    self.f.script('curl', f'exec {curl} --disable "$@"\n')
                    self.f.env['JQ_BIN'] = jq
                    self.f.delay = phase == 'during'
                    self.f.started.clear()
                    self.f.completed.clear()
                    self.f.release.clear()
                    if phase == 'before':
                        self.f.script('curl', f'''if [[ "${{@: -1}}" == */containers/prune ]]; then
  touch {checkpoint}; sleep 25
fi
exec {curl} --disable "$@"
''')
                    if phase == 'after':
                        self.f.script('jq', f'''if [[ $1 == -se ]]; then
  touch {checkpoint}; sleep 25
fi
exec {jq} "$@"
''')
                        self.f.env['JQ_BIN'] = str(self.f.root / 'jq')
                    process = self.f.start()
                    try:
                        deadline = time.monotonic() + 6
                        while not (self.f.started.is_set() if phase == 'during' else checkpoint.exists()):
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.02)
                        if phase == 'after':
                            self.assertTrue(self.f.completed.is_set())
                        os.killpg(process.pid, sig)
                        process.communicate(timeout=3)
                        self.f.release.set()
                        if phase == 'during':
                            self.assertTrue(self.f.completed.wait(3))
                        self.assert_fenced()
                    finally:
                        self.f.release.set()
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.communicate()
                        shutil.rmtree(self.f.fence)
        self.f.env['JQ_BIN'] = shutil.which('jq')


if __name__ == '__main__':
    unittest.main()
