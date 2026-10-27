#!/usr/bin/env python3
"""Manual manifest mode over disposable UNIX sockets, no runtime or host access."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import unittest

# The shared fixture consumes the helper argument and defines no test side effects.
spec = importlib.util.spec_from_file_location(
    'cleanup_fixture', Path(__file__).with_name('test-idle-podman-cleanup-fence.py'))
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)
Fixture = fixture_module.Fixture
STAMP = '2026-01-01T00:00:00Z'


class DockerVolumeTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture(fixture_module.THREE_RUNNERS)
        self.addCleanup(self.f.close)
        self.manifest = self.f.root / 'manifest.json'
        self.allow('fixture_one', 'fixture_two', 'fixture_three')
        self.f.env['DOCKER_VOLUME_MANIFEST'] = str(self.manifest)
        self.f.env['PRESSURE_ONLY'] = '0'
        curl = shutil.which('curl')
        self.requests = self.f.root / 'requests'
        self.f.script('curl', f'printf "%s\\n" "$*" >> "{self.requests}"\nexec {curl} --disable "$@"\n')
        self.addCleanup(self.no_podman_mutations)

    def no_podman_mutations(self):
        self.assertTrue(all(path.startswith('/volumes/') and path.endswith('?force=false')
                            for path in self.f.mutations), self.f.mutations)
        self.assertTrue(all(' docker DELETE /volumes/' in r for r in self.f.records))

    def allow(self, *names):
        self.manifest.write_text(json.dumps({'volumes': [
            dict(name=n, created_at=STAMP) for n in names]}))
        self.manifest.chmod(0o600)
        self.f.docker_volumes = {n: dict(Name=n, CreatedAt=STAMP, Driver='local',
                                        Scope='local', Options=None) for n in names}

    def run_ok(self, **env):
        result = self.f.run(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.f.fence.exists())
        return result.stdout

    def test_exact_two_attempt_cap_socket_and_deadline(self):
        output = self.run_ok()
        self.assertIn('bounded_partial cause=cap', output)
        self.assertEqual(self.f.mutations, ['/volumes/fixture_one?force=false',
                                           '/volumes/fixture_two?force=false'])
        self.assertTrue(all(r.startswith('cleanup-v3 ') for r in self.f.records))
        deletes = [line for line in self.requests.read_text().splitlines() if '-X DELETE' in line]
        self.assertEqual(len(deletes), 2)
        self.assertTrue(all('--max-time 25 ' in line and str(self.f.root / 'docker.sock') in line
                            for line in deletes))

    def test_refusal_is_complete_and_continues(self):
        self.f.status = 409
        self.f.reply = b'{"message":"volume is in use"}'
        output = self.run_ok()
        self.assertIn('reason=in_use', output)
        self.assertEqual(len(self.f.mutations), 2)

    def test_uncertain_status_body_and_transport_stop_with_v3_fence(self):
        self.allow('fixture_one')
        for status, body in [(204, b'illegal body'), (404, b'{"message":"absent"}'), (500, b'{"message":"failure"}'),
                             (409, b'{}'), (409, b'{"message":""}'),
                             (409, b'{"message":"busy"} {}'), (409, b'broken')]:
            with self.subTest(status=status, body=body):
                self.f.status, self.f.reply = status, body
                before = len(self.f.records)
                result = self.f.run()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(len(self.f.records), before + 1)
                self.assertTrue(self.f.fence.exists())
                shutil.rmtree(self.f.fence)
        # A dispatched request that disconnects has no completion receipt.
        self.f.script('curl', f'''case "$*" in
  *'-X DELETE'*) exec {shutil.which('curl')} --disable "$@" --max-time 0.1 ;;
  *) exec {shutil.which('curl')} --disable "$@" ;;
esac
''')
        self.f.delay = True
        result = self.f.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn('uncertain_request', result.stderr)
        self.assertTrue(self.f.fence.exists())

    def test_complete_manifest_validation_precedes_mutation(self):
        for data in [{}, {'volumes': [], 'extra': True}, {'volumes': [dict(name='fixture_one', created_at=STAMP),
                         dict(name='fixture_one', created_at=STAMP)]},
                     {'volumes': [dict(name='fixture_one', created_at=STAMP), dict(name='../bad', created_at=STAMP)]},
                     {'volumes': [dict(name='fixture_one\n', created_at=STAMP)]},
                     {'volumes': [dict(name='fixture_one', created_at=STAMP, extra=True)]},
                     {'volumes': [dict(name='fixture_one', created_at='yesterday')]},
                     {'volumes': [dict(name='fixture_one?force=true', created_at=STAMP)]},
                     {'volumes': [dict(name='fixture_one', created_at=STAMP), 4]}]:
            with self.subTest(data=data):
                self.manifest.write_text(json.dumps(data))
                result = self.f.run()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('docker_manifest_invalid', result.stderr)
                self.assertEqual(self.f.calls, [])
        self.manifest.write_text('{"volumes":[]} {}')
        self.assertEqual(self.f.run().returncode, 1)
        self.allow()
        self.assertIn('attempts=0', self.run_ok())

    def test_manifest_trust(self):
        self.manifest.chmod(0o644)
        self.assertEqual(self.f.run().returncode, 1)
        self.manifest.chmod(0o600)
        link = self.f.root / 'manifest-link'
        link.symlink_to(self.manifest)
        self.assertEqual(self.f.run(DOCKER_VOLUME_MANIFEST=str(link)).returncode, 1)
        link.unlink()
        os.link(self.manifest, link)
        self.assertEqual(self.f.run().returncode, 1)
        self.assertEqual(self.f.calls, [])

    def test_preserve_stopped_container_volume_references(self):
        self.f.docker_containers = [dict(Id='a' * 64, Created=0, State='exited',
                                        Mounts=[dict(Type='volume', Name='fixture_one')])]
        output = self.run_ok()
        self.assertIn('fixture_one reason=referenced', output)
        self.assertNotIn('/volumes/fixture_one', [p for _, p in self.f.calls])
        self.assertEqual(self.f.mutations, ['/volumes/fixture_two?force=false',
                                           '/volumes/fixture_three?force=false'])

    def test_both_inventories_fully_terminal_and_strict_before_mutation(self):
        for engine in ['docker', 'podman']:
            for value in [{}, [dict(State='exited')], [dict(Id='a' * 64, Created=0, State='running', Mounts=[])],
                          [dict(Id='a' * 64, Created=0, State='exited', Mounts=[]) for _ in range(2)]]:
                with self.subTest(engine=engine, value=value):
                    self.f.docker_containers = value if engine == 'docker' else []
                    self.f.containers = value if engine == 'podman' else []
                    self.assertIn('engine_api_invalid', self.run_ok())
                    self.assertEqual(self.f.mutations, [])
        self.f.containers = []
        for mounts in [None, [dict(Type='volume')], [dict(Type='volume', Name='../bad')], [dict(Name='fixture_one')]]:
            self.f.docker_containers = [dict(Id='a' * 64, Created=0, State='dead', Mounts=mounts)]
            self.assertIn('engine_api_invalid', self.run_ok())
            self.assertEqual(self.f.mutations, [])

    def test_inspect_identity_driver_scope_options_and_absence(self):
        self.allow('fixture_one')
        original = self.f.docker_volumes['fixture_one'].copy()
        for field, value in [('Name', 'other'), ('CreatedAt', '2026-02-01T00:00:00Z'),
                             ('Driver', 'other'), ('Scope', 'global'), ('Options', {'device': '/somewhere'})]:
            self.f.docker_volumes['fixture_one'] = {**original, field: value}
            self.assertIn('inspect_mismatch', self.run_ok())
            self.assertEqual(self.f.mutations, [])
        self.f.docker_inspect_status = 404
        self.assertIn('reason=absent', self.run_ok())
        self.assertEqual(self.f.mutations, [])

    def test_insufficient_budget_is_normal_partial_before_dispatch(self):
        output = self.run_ok(LOCK_BUDGET_SECONDS='24')
        self.assertIn('bounded_partial cause=budget step=remove_docker_volume', output)
        self.assertEqual(self.f.mutations, [])
        self.assertIn('below_critical_floor', self.run_ok(CRITICAL_FREE_BYTES='21'))

    def test_configured_runner_registry_and_lifecycle_guards_remain_required(self):
        registry = self.f.state / 'runner-units'
        original_registry = registry.read_text()
        registry.write_text('\n'.join(fixture_module.TWO_RUNNERS) + '\n')
        self.assertIn('runner_registry_mismatch', self.run_ok())
        registry.write_text(original_registry)
        systemctl = self.f.root / 'systemctl'
        original_systemctl = systemctl.read_text()
        for replacement, reason in [
            (original_systemctl.replace('echo running', 'echo frozen'), 'aggregate_frozen'),
            (original_systemctl.replace('echo 12345', 'echo 0'), 'api_generation_invalid'),
            (original_systemctl.replace('exit 0', 'exit 1'), 'guard_inactive'),
            ('#!/usr/bin/env bash\ncase "$*" in *forgejo-podman-runner-fast.service) '
             'printf "ActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlPID=1\\nJob=\\n"; exit ;; esac\n'
             + original_systemctl, 'runner_active unit=forgejo-podman-runner-fast.service'),
        ]:
            systemctl.write_text(replacement)
            self.assertIn(reason, self.run_ok())
        systemctl.write_text(original_systemctl)
        marker = self.f.state / 'runners' / fixture_module.EXTRA / 'pending'
        marker.touch()
        self.assertIn('transition_marker', self.run_ok())
        self.assertEqual(self.f.mutations, [])

    def test_budget_after_first_success_stops_next_request(self):
        # Simulate time consumed before dispatch without a slow fixture suite.
        self.f.script('curl', f'''case "$*" in
  *'-X DELETE'*) sleep 3 ;;
esac
exec {shutil.which('curl')} --disable "$@"
''')
        output = self.run_ok(LOCK_BUDGET_SECONDS='27')
        self.assertIn('bounded_partial cause=budget', output)
        self.assertEqual(len(self.f.mutations), 1)


if __name__ == '__main__':
    unittest.main()
