#!/usr/bin/env python3
"""Synthetic tests of the runner start record, nixfleet-runner-status and the
restart when idle (ADR-0041, nix-packages ADR-0017).

They never contact systemd or an engine: systemctl, curl, journalctl, date and
sleep are fakes, sleep advances a fake clock, and unit files are symlinks in a
temporary directory.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RECORD = Path(sys.argv.pop(1)).resolve()
STATUS = Path(sys.argv.pop(1)).resolve()
RESTART = Path(sys.argv.pop(1)).resolve()
STATE_HELPER = RECORD.with_name('runner-state.sh')
PRIMARY = 'forgejo-actions-runner.service'
POOL = 'forgejo-podman-runner.service'
FAST = 'forgejo-podman-runner-fast.service'
RUNNERS = [PRIMARY, POOL, FAST]
DOCKER = 'forgejo-runner-docker.service'
PODMAN = 'forgejo-runner-podman.service'
POLICY = 'forgejo-runner-resource-policy.service'
SERVICES = [DOCKER, PODMAN, POLICY]
HOLD = 'forgejo-runner-hold.service'
RESET = 'forgejo-podman-store-reset.service'

# Units live in one JSON file. A restart gives each unit a new invocation and
# runs the recorder as its ExecStartPost would, unless the fixture says the
# recorder fails or the restart fails.
FAKE_SYSTEMCTL = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
path = Path(os.environ['FAKE_STATE'])
state = json.loads(path.read_text())
args = [arg for arg in sys.argv[1:] if arg not in ('--no-block', '--quiet')]
with open(os.environ['FAKE_LOG'], 'a') as handle:
    handle.write(' '.join(args) + '\n')
def unit(name):
    return state['units'].setdefault(name, {'LoadState': 'loaded', 'UnitFileState': 'enabled',
                                            'ActiveState': 'inactive', 'SubState': 'dead', 'Result': 'success'})
if args[0] == 'show':
    name = args[-1]
    for arg in args:
        if arg.startswith('--property='):
            key = arg.split('=', 1)[1]
            value = unit(name).get(key, '')
            print(value if '--value' in args else f'{key}={value}')
elif args[0] == 'restart':
    if state.get('restart_fails'):
        sys.exit(1)
    for name in args[1:]:
        state['counter'] = state.get('counter', 0) + 1
        invocation = f"{state['counter']:032x}"
        unit(name).update(ActiveState='active', SubState='running', InvocationID=invocation)
        path.write_text(json.dumps(state))
        if not state.get('record_fails'):
            env = dict(os.environ, INVOCATION_ID=invocation)
            subprocess.run([os.environ['RECORDER'], name], env=env, check=True)
        state = json.loads(path.read_text())
else:
    sys.exit(2)
path.write_text(json.dumps(state))
'''

# The clock is a file; each sleep advances it and runs the fixture's step for
# that sample.
FAKE_SLEEP = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
clock = root / 'clock'
clock.write_text(str(int(clock.read_text()) + int(sys.argv[1])))
path = root / 'state.json'
state = json.loads(path.read_text())
steps = state.get('steps', [])
if steps:
    step = steps.pop(0)
    for key, value in step.items():
        state[key] = value
    state['steps'] = steps
    path.write_text(json.dumps(state))
'''

FAKE_DATE = r'''#!/usr/bin/env python3
import os
from pathlib import Path
print(Path(os.environ['FAKE_ROOT'], 'clock').read_text())
'''

# A socket path is the engine's name; the fixture lists job containers per
# engine, or makes an engine unreadable.
FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = json.loads(Path(os.environ['FAKE_STATE']).read_text())
socket = sys.argv[sys.argv.index('--unix-socket') + 1]
engine = Path(socket).name
if engine in state.get('engine_down', []):
    sys.exit(7)
names = state.get('jobs', {}).get(engine, [])
print(json.dumps([{'Names': ['/' + name]} for name in names] + [{'Names': ['/builder-cache']}]))
'''

FAKE_JOURNALCTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = json.loads(Path(os.environ['FAKE_STATE']).read_text())
unit = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--unit='))
for line in state.get('journal', {}).get(unit, []):
    print(line)
'''


class RunnerRestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, text in (('systemctl', FAKE_SYSTEMCTL), ('sleep', FAKE_SLEEP), ('date', FAKE_DATE),
                           ('curl', FAKE_CURL), ('journalctl', FAKE_JOURNALCTL)):
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        self.store = self.root / 'store'
        self.store.mkdir()
        self.etc = self.root / 'etc'
        self.etc.mkdir()
        self.records = self.root / 'run' / 'started'
        self.state_file = self.root / 'run' / 'restart'
        (self.root / 'clock').write_text('100000')
        self.log = self.root / 'systemctl.log'
        self.log.touch()
        self.recorder = self.bin / 'record'
        self.recorder.write_text(f'#!/usr/bin/env bash\nexec bash {RECORD} "$@"\n')
        self.recorder.chmod(0o755)
        units = {HOLD: {'ActiveState': 'active', 'StatusText': 'holding runners: none'},
                 RESET: {'ActiveState': 'inactive'}}
        counter = 0
        for name in RUNNERS + SERVICES:
            counter += 1
            units[name] = {'LoadState': 'loaded', 'UnitFileState': 'enabled', 'ActiveState': 'active',
                           'SubState': 'running', 'Result': 'success', 'InvocationID': f'{counter:032x}',
                           'FragmentPath': str(self.etc / name), 'DropInPaths': ''}
            self.deploy(name, 'v1')
        self.write_state({'units': units, 'counter': counter})
        for name in RUNNERS + SERVICES:
            self.record(name)

    def tearDown(self):
        self.tmp.cleanup()

    def env(self, **extra):
        env = dict(os.environ, FAKE_ROOT=str(self.root), FAKE_STATE=str(self.root / 'state.json'),
                   FAKE_LOG=str(self.log), RECORDER=str(self.recorder), STATE_HELPER_FILE=str(STATE_HELPER),
                   RECORD_DIR=str(self.records), SYSTEMCTL_BIN=str(self.bin / 'systemctl'),
                   JOURNALCTL_BIN=str(self.bin / 'journalctl'), CURL_BIN=str(self.bin / 'curl'),
                   DATE_BIN=str(self.bin / 'date'), SLEEP_BIN=str(self.bin / 'sleep'),
                   RUNNERS=' '.join(f'{unit}=label-{index}' for index, unit in enumerate(RUNNERS)),
                   SERVICES=' '.join(SERVICES), RUNNER_UNITS=' '.join(RUNNERS), SERVICE_UNITS=' '.join(SERVICES),
                   HOLD_UNIT=HOLD, RESET_UNIT=RESET, DOCKER_API_UNIT=DOCKER, PODMAN_API_UNIT=PODMAN,
                   DOCKER_SOCKET=str(self.root / 'docker'), PODMAN_SOCKET=str(self.root / 'podman'),
                   STATE_FILE=str(self.state_file), RESTART_STATE_FILE=str(self.state_file),
                   WAIT_SECONDS='60', QUIET_SECONDS='300', POLL_SECONDS='10', RESTART_TIMEOUT_SECONDS='30')
        env.update(extra)
        return env

    def state(self):
        return json.loads((self.root / 'state.json').read_text())

    def write_state(self, state):
        (self.root / 'state.json').write_text(json.dumps(state))

    def update_unit(self, name, **values):
        state = self.state()
        state['units'][name].update(values)
        self.write_state(state)

    def deploy(self, name, version):
        """Points the unit file at another store path, as a switch does."""
        target = self.store / f'{version}-{name}'
        target.write_text(version)
        link = self.etc / name
        if link.is_symlink():
            link.unlink()
        link.symlink_to(target)

    def record(self, name):
        invocation = self.state()['units'][name]['InvocationID']
        subprocess.run([self.recorder, name], env=self.env(INVOCATION_ID=invocation), check=True)

    def status(self):
        result = subprocess.run(['bash', STATUS], env=self.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split('\t') for line in result.stdout.splitlines()]
        units = {row[2]: row for row in rows if row[0] == 'unit'}
        return rows, units

    def restart(self, **extra):
        return subprocess.run(['bash', RESTART], env=self.env(**extra), capture_output=True, text=True, timeout=60)

    def restart_state(self):
        values = {'unit': []}
        for line in self.state_file.read_text().splitlines():
            key, value = line.split('=', 1)
            if key == 'unit':
                values['unit'].append(value)
            else:
                values[key] = value
        return values

    def restarts(self):
        return [line.split()[1:] for line in self.log.read_text().splitlines() if line.startswith('restart ')]

    def test_record_is_world_readable_and_matches_the_running_definition(self):
        record = self.records / PRIMARY
        self.assertEqual(record.stat().st_mode & 0o777, 0o644)
        self.assertIn(f'definition={self.store}/v1-{PRIMARY}', record.read_text())
        rows, units = self.status()
        self.assertEqual(rows[0], ['version', '1'])
        self.assertIn(['hold', 'active', 'none'], rows)
        self.assertIn(['restart-unit', 'forgejo-runner-restart.service', '3600'], rows)
        self.assertEqual(units[PRIMARY], ['unit', 'runner', PRIMARY, 'active', 'running', 'no', '-', 'label-0', '-'])
        self.assertEqual(units[POLICY][:7], ['unit', 'service', POLICY, 'active', 'running', 'no', '-'])
        self.assertFalse(any(row[0] == 'restart' for row in rows))

    def test_status_flags_a_changed_definition_a_missing_record_and_a_new_drop_in(self):
        self.deploy(PRIMARY, 'v2')
        self.update_unit(POOL, InvocationID='f' * 32)
        drop_in = self.root / 'override.conf'
        drop_in.write_text('[Service]\n')
        self.update_unit(DOCKER, DropInPaths=str(drop_in))
        (self.records / POLICY).unlink()
        # A stopped unit gets the deployed definition at its next start.
        self.deploy(FAST, 'v2')
        self.update_unit(FAST, ActiveState='inactive', SubState='dead')
        _, units = self.status()
        self.assertEqual(units[PRIMARY][5:7], ['yes', 'started from an older definition'])
        self.assertEqual(units[POOL][5:7], ['yes', 'no start record'])
        self.assertEqual(units[DOCKER][5:7], ['yes', 'started from an older definition'])
        self.assertEqual(units[POLICY][5:7], ['yes', 'no start record'])
        self.assertEqual(units[FAST][5:7], ['no', '-'])
        self.assertEqual(units[PODMAN][5:7], ['no', '-'])

    def test_status_explains_each_stopped_runner(self):
        cases = [
            ({'ActiveState': 'inactive', 'Result': 'success'}, {}, 'stopped by hand or by a reboot run; nothing starts it again'),
            ({'ActiveState': 'failed', 'Result': 'timeout'}, {}, 'failed (timeout)'),
            ({'ActiveState': 'inactive', 'Result': 'exec-condition'}, {},
             'its start gate refused the last start; the runner hold retries a held runner'),
            ({'ActiveState': 'inactive'}, {'hold': 'holding runners: game'},
             'held by the runner hold (game); it starts when that ends'),
            ({'ActiveState': 'inactive', 'UnitFileState': 'masked'}, {}, 'masked; nothing starts it'),
            ({'ActiveState': 'inactive'}, {'reset': 'activating'},
             'stopped while the Podman store reset runs, which starts again the runners it stopped'),
            ({'ActiveState': 'inactive'}, {'hold_down': True},
             'stopped by hand or by a reboot run; nothing starts it again; the runner hold is failed'),
            ({'ActiveState': 'deactivating', 'SubState': 'stop-sigterm'}, {},
             'stopping; its running jobs finish first'),
            ({'ActiveState': 'activating', 'SubState': 'auto-restart', 'Result': 'exit-code'}, {},
             'restarting after a failure (exit-code)'),
        ]
        for runner, host, reason in cases:
            with self.subTest(reason=reason):
                self.tmp.cleanup()
                self.setUp()
                self.update_unit(FAST, **runner)
                if 'hold' in host:
                    self.update_unit(HOLD, StatusText=host['hold'])
                if 'reset' in host:
                    self.update_unit(RESET, ActiveState=host['reset'])
                if host.get('hold_down'):
                    self.update_unit(HOLD, ActiveState='failed')
                _, units = self.status()
                self.assertEqual(units[FAST][8], reason)
                self.assertEqual(units[PRIMARY][8], '-')

    def test_status_reports_the_last_restart(self):
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(f'status=busy\ntime=123\nunit={PRIMARY}\nunit={POLICY}\nreason=job_running unit={DOCKER}\n')
        rows, _ = self.status()
        self.assertIn(['restart', 'inactive', 'busy', '123', f'{PRIMARY},{POLICY}', f'job_running unit={DOCKER}'], rows)
        # A run its timeout killed left waiting behind; that reads as failed,
        # while a running one reads as it is.
        self.state_file.write_text(f'status=waiting\ntime=124\nunit={PRIMARY}\nreason=recent_job unit={POOL}\n')
        self.update_unit('forgejo-runner-restart.service', ActiveState='failed')
        rows, _ = self.status()
        self.assertIn(['restart', 'failed', 'failed', '124', PRIMARY,
                       f'the restart unit ended (failed) without a result, last: waiting recent_job unit={POOL}'], rows)
        self.update_unit('forgejo-runner-restart.service', ActiveState='activating')
        rows, _ = self.status()
        self.assertIn(['restart', 'activating', 'waiting', '124', PRIMARY, f'recent_job unit={POOL}'], rows)
        # An unreadable state may be a live run's.
        state = self.state()
        state['units']['forgejo-runner-restart.service'] = 'unreadable'
        self.write_state(state)
        rows, _ = self.status()
        self.assertIn(['restart', 'unknown', 'waiting', '124', PRIMARY, f'recent_job unit={POOL}'], rows)

    def test_restart_does_nothing_when_every_unit_runs_its_definition(self):
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restart_state()['status'], 'nothing')
        self.assertEqual(self.restarts(), [])

    def test_restart_restarts_only_the_flagged_units_of_an_idle_host(self):
        self.deploy(PRIMARY, 'v2')
        self.deploy(POLICY, 'v2')
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restarts(), [[PRIMARY, POLICY]])
        state = self.restart_state()
        self.assertEqual(state['status'], 'done')
        self.assertEqual(state['unit'], [PRIMARY, POLICY])
        self.assertEqual(self.state_file.stat().st_mode & 0o777, 0o644)
        _, units = self.status()
        self.assertTrue(all(row[5] == 'no' for row in units.values()))

    def test_restart_waits_for_a_job_container_and_a_recent_task(self):
        self.deploy(DOCKER, 'v2')
        state = self.state()
        state['jobs'] = {'docker': ['FORGEJO-ACTIONS-TASK-7_WORKFLOW-ci_JOB-test']}
        # Two samples later the container is gone, but the pool runner took a
        # task; the journal reads empty at the next sample.
        state['steps'] = [{}, {'jobs': {}, 'journal': {POOL: ['level=info msg="task 8 repo is alcxyz/demo"']}},
                          {'journal': {}}]
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restarts(), [[DOCKER]])
        self.assertIn(f'event=waiting units={DOCKER} reason=job_running unit={DOCKER}', result.stdout)
        self.assertIn(f'event=waiting units={DOCKER} reason=recent_job unit={POOL}', result.stdout)
        self.assertEqual(self.restart_state()['status'], 'done')

    def test_restart_skips_engines_that_do_not_run(self):
        self.deploy(PRIMARY, 'v2')
        self.update_unit(PODMAN, ActiveState='inactive', SubState='dead')
        state = self.state()
        state['engine_down'] = ['podman']
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restarts(), [[PRIMARY]])

    def test_restart_gives_up_on_a_busy_host_without_restarting(self):
        self.deploy(PRIMARY, 'v2')
        state = self.state()
        state['jobs'] = {'podman': ['FORGEJO-ACTIONS-TASK-9']}
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restarts(), [])
        self.assertEqual(self.restart_state(), {'status': 'busy', 'time': '100060', 'unit': [PRIMARY],
                                                'reason': f'job_running unit={PODMAN}'})

    def test_restart_waits_for_an_unreadable_engine_a_store_reset_and_a_stopping_runner(self):
        self.deploy(POLICY, 'v2')
        state = self.state()
        state['engine_down'] = ['docker']
        state['units'][RESET]['ActiveState'] = 'activating'
        state['units'][FAST].update(ActiveState='deactivating', SubState='stop-sigterm')
        state['steps'] = [{}, {}, {}]
        self.write_state(state)
        result = self.restart(WAIT_SECONDS='100')
        self.assertIn('reason=store_reset_running', result.stdout)
        self.update_unit(RESET, ActiveState='inactive')
        result = self.restart(WAIT_SECONDS='0')
        self.assertIn(f'reason=runner_transition unit={FAST} state=deactivating:stop-sigterm', result.stdout)
        self.update_unit(FAST, ActiveState='active', SubState='running')
        result = self.restart(WAIT_SECONDS='0')
        self.assertIn(f'reason=engine_api_unavailable unit={DOCKER}', result.stdout)
        self.assertEqual(self.restarts(), [])

    def test_restart_does_not_wait_for_a_runner_that_restarts_after_a_failure(self):
        self.deploy(PRIMARY, 'v2')
        self.update_unit(FAST, ActiveState='activating', SubState='auto-restart', Result='exit-code')
        result = self.restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restarts(), [[PRIMARY]])

    def test_restart_records_a_failure_that_ends_the_run(self):
        self.deploy(PRIMARY, 'v2')
        # systemctl cannot read a runner: the run ends without a result of
        # its own, and says so.
        state = self.state()
        state['units'][POOL] = 'unreadable'
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.restart_state()['status'], 'failed')
        self.assertTrue(self.restart_state()['reason'].startswith('ended with status 1 before a result'))

    def test_restart_fails_when_systemctl_fails_or_no_new_record_appears(self):
        self.deploy(PRIMARY, 'v2')
        state = self.state()
        state['restart_fails'] = True
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.restart_state()['status'], 'failed')
        self.assertEqual(self.restart_state()['reason'], 'systemctl restart exited with status 1')
        state = self.state()
        state['restart_fails'] = False
        state['record_fails'] = True
        self.write_state(state)
        result = self.restart()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.restart_state()['reason'], 'still not running the deployed definition after the restart')

    def test_restart_and_record_refuse_bad_settings(self):
        # Each refusal replaces an earlier run's result with its own failure.
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        for setting in ({'RUNNER_UNITS': ''}, {'SERVICE_UNITS': 'bad unit'}, {'WAIT_SECONDS': 'soon'}):
            self.state_file.write_text('status=done\ntime=1\nreason=\n')
            self.assertEqual(self.restart(**setting).returncode, 1)
            self.assertEqual(self.restart_state()['status'], 'failed')
            self.assertEqual(self.restart_state()['reason'], 'ended with status 1 before a result')
        result = subprocess.run([self.recorder, PRIMARY], env=self.env(INVOCATION_ID='not-an-id'), capture_output=True)
        self.assertEqual(result.returncode, 2)
        result = subprocess.run([self.recorder, '../x.service'], env=self.env(INVOCATION_ID='a' * 32), capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
