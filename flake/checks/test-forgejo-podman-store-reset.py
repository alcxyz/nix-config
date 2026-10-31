#!/usr/bin/env python3
"""Synthetic Podman store reset tests; never contact systemd or an engine."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(sys.argv.pop(1)).resolve()
PRIMARY = 'forgejo-actions-runner.service'
POOL = 'forgejo-podman-runner.service'
FAST = 'forgejo-podman-runner-fast.service'
HOLD = 'forgejo-runner-hold.service'
GAME = 'game-signal.service'
RUNNERS = [PRIMARY, POOL, FAST]
DOCKER = 'forgejo-runner-docker.service'
PODMAN = 'forgejo-runner-podman.service'
APIS = [DOCKER, PODMAN]
PRUNES = ['forgejo-runner-cache-prune.service', 'forgejo-runner-cache-pressure-prune.service']
DAY = 86400

# Units live in one JSON file. Stops and starts change it; the fixture may
# ask for a job or an API restart to appear during a stop. A refused start
# leaves the start gate's held marker, as the real gate does.
FAKE_SYSTEMCTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ['FAKE_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as handle:
    handle.write(' '.join(args) + '\n')
units = state['units']
def unit(name):
    return units.setdefault(name, {'ActiveState': 'inactive', 'SubState': 'dead',
                                   'MainPID': '0', 'ControlPID': '0', 'Job': ''})
if args[0] == 'show':
    name = args[-1]
    wanted = [arg.split('=', 1)[1] for arg in args if arg.startswith('--property=')]
    props = {'FreezerState': state['freezer']} if name == 'forgejobuilds.slice' else unit(name)
    for key in wanted:
        print(props.get(key, '') if '--value' in args else f'{key}={props.get(key, "")}')
elif args[0] == 'is-active':
    sys.exit(0 if unit(args[-1])['ActiveState'] == 'active' else 3)
elif args[0] in ('stop', 'start'):
    names = [arg for arg in args[1:] if not arg.startswith('--')]
    if args[0] in state.get('fail', []):
        sys.exit(1)
    for name in names:
        if args[0] == 'stop':
            unit(name).update(ActiveState='inactive', SubState='dead', MainPID='0')
        elif name in state.get('fail_start', []):
            unit(name).update(ActiveState='failed', SubState='failed', MainPID='0')
        elif name in state.get('refuse', []):
            # A start gate's ExecCondition skips the start without failing it.
            unit(name).update(ActiveState='inactive', SubState='dead', MainPID='0')
            (Path(os.environ['FAKE_HOLD_DIR']) / 'runners' / name / 'held').touch()
        else:
            unit(name).update(ActiveState='active', SubState='running', MainPID='42')
    if args[0] == 'stop' and state.get('start_on_stop'):
        unit(state.pop('start_on_stop')).update(ActiveState='active', SubState='running', MainPID='43')
    if args[0] == 'stop' and state.get('journal_on_stop'):
        Path(os.environ['FAKE_JOURNALS'], state.pop('journal_on_stop')).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
    if args[0] == 'stop' and state.get('job_on_stop'):
        Path(os.environ['FAKE_ENGINES'], 'podman.sock').write_text(
            '[{"Names": ["/FORGEJO-ACTIONS-TASK-99_job"]}]')
    if args[0] == 'stop' and DOCKER in names and state.get('restart_api'):
        unit(state['restart_api']).update(ActiveState='activating', SubState='start', Job='9')
    path.write_text(json.dumps(state))
else:
    sys.exit(2)
'''.replace('DOCKER', repr(DOCKER))

FAKE_CURL = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
socket = sys.argv[sys.argv.index('--unix-socket') + 1]
reply = Path(os.environ['FAKE_ENGINES']) / Path(socket).name
if not reply.exists():
    sys.exit(7)
sys.stdout.write(reply.read_text())
'''

# Each unit's journal is a file; a missing one is an empty journal.
FAKE_JOURNALCTL = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
unit = next(arg.split('=', 1)[1] for arg in sys.argv[1:] if arg.startswith('--unit='))
journal = Path(os.environ['FAKE_JOURNALS']) / unit
if journal.exists():
    sys.stdout.write(journal.read_text())
'''

FAKE_DF = r'''#!/bin/sh
printf 'Size Avail\n%s\n' "$(cat "$FAKE_DF_VALUES")"
'''


def running():
    return {'ActiveState': 'active', 'SubState': 'running', 'MainPID': '42',
            'ControlPID': '0', 'Job': ''}


def stopped():
    return {'ActiveState': 'inactive', 'SubState': 'dead', 'MainPID': '0',
            'ControlPID': '0', 'Job': ''}


class StoreResetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state_dir = self.root / 'hold'
        for unit in RUNNERS:
            (self.state_dir / 'runners' / unit).mkdir(parents=True)
        self.state_dir.chmod(0o700)
        self.game_file = self.root / 'game-signal' / 'active'
        self.game_file.parent.mkdir()
        self.journals = self.root / 'journals'
        self.journals.mkdir()
        self.legacy_fence = self.root / 'old-guard' / 'cleanup-in-flight'
        self.parent = self.root / 'podman'
        self.store = self.parent / 'storage'
        (self.store / 'overlay' / 'layer').mkdir(parents=True)
        (self.store / 'overlay' / 'layer' / 'file').write_text('layer\n')
        (self.store / 'db.sql').write_text('db\n')
        self.stamp = self.root / 'reset-state' / 'reset-at'
        self.stamp.parent.mkdir()
        self.restart = self.root / 'restart'
        self.engines = self.root / 'engines'
        self.engines.mkdir()
        for name in ('docker.sock', 'podman.sock'):
            (self.engines / name).write_text('[]')
        self.cgroups = self.root / 'cgroup'
        for api in APIS:
            (self.cgroups / 'forgejobuilds.slice' / api).mkdir(parents=True)
            (self.cgroups / 'forgejobuilds.slice' / api / 'cgroup.events').write_text(
                'populated 0\nfrozen 0\n')
        self.mountinfo = self.root / 'mountinfo'
        self.mountinfo.write_text(f'22 1 0:21 / / rw - ext4 /dev/root rw\n')
        self.pressure = self.root / 'pressure'
        self.set_pressure(0)
        self.df = self.root / 'df-values'
        self.df.write_text('100 80\n')
        self.uptime = self.root / 'uptime'
        self.uptime.write_text('1000.00 1.00\n')
        self.log = self.root / 'systemctl.log'
        self.fake_state = self.root / 'units.json'
        units = {unit: running() for unit in [HOLD, GAME] + RUNNERS + APIS}
        units.update({unit: stopped() for unit in PRUNES})
        self.write_state({'units': units})
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, text in (('systemctl', FAKE_SYSTEMCTL), ('curl', FAKE_CURL),
                           ('df', FAKE_DF), ('journalctl', FAKE_JOURNALCTL)):
            path = self.bin / name
            path.write_text(text.replace('#!/usr/bin/env python3', f'#!{sys.executable}', 1))
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def write_state(self, state):
        self.fake_state.write_text(json.dumps(state))

    def update_units(self, **units):
        state = json.loads(self.fake_state.read_text())
        for name, props in units.items():
            state['units'][name] = props
        self.write_state(state)

    def set_fake(self, **values):
        state = json.loads(self.fake_state.read_text())
        state.update(values)
        self.write_state(state)

    def set_pressure(self, hundredths):
        self.pressure.write_text(
            f'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n'
            f'full avg10={hundredths / 100:.2f} avg60=0.00 avg300=0.00 total=0\n')

    def age_stamp(self, seconds):
        if not self.stamp.exists():
            self.stamp.write_text('0\n')
        stamp = time.time() - seconds
        os.utime(self.stamp, (stamp, stamp))

    def run_reset(self, *args, **extra):
        if self.log.exists():
            self.log.unlink()
        env = dict(os.environ,
                   PATH=f'{self.bin}:{os.environ["PATH"]}',
                   STATE_DIR=str(self.state_dir),
                   SYSTEMCTL_BIN=str(self.bin / 'systemctl'),
                   JOURNALCTL_BIN=str(self.bin / 'journalctl'),
                   CURL_BIN=str(self.bin / 'curl'),
                   DF_BIN=str(self.bin / 'df'),
                   MOUNTINFO_FILE=str(self.mountinfo),
                   CGROUP_ROOT=str(self.cgroups),
                   DOCKER_SOCKET=str(self.root / 'run' / 'docker.sock'),
                   PODMAN_SOCKET=str(self.root / 'run' / 'podman.sock'),
                   STORE_PATH=str(self.store),
                   RESTART_FILE=str(self.restart),
                   STAMP_FILE=str(self.stamp),
                   PRESSURE_FILE=str(self.pressure),
                   IO_PRESSURE_THRESHOLD_HUNDREDTHS='500',
                   RUNNER_UNITS=f'{PRIMARY} {POOL} {FAST}',
                   GAME_ENABLED='0',
                   GAME_FILE=str(self.game_file),
                   LEGACY_FENCE=str(self.legacy_fence),
                   QUIET_SECONDS='900',
                   POLL_SECONDS='1',
                   FAKE_HOLD_DIR=str(self.state_dir),
                   FAKE_JOURNALS=str(self.journals),
                   FAKE_STATE=str(self.fake_state),
                   FAKE_LOG=str(self.log),
                   FAKE_ENGINES=str(self.engines),
                   FAKE_DF_VALUES=str(self.df))
        env.update(extra)
        return subprocess.run(['bash', str(SCRIPT), *args], env=env,
                              capture_output=True, text=True, timeout=60)

    def calls(self, kind=None):
        if not self.log.exists():
            return []
        lines = self.log.read_text().splitlines()
        return [line for line in lines if kind is None or line.split()[0] == kind]

    def markers(self):
        return [unit for unit in RUNNERS
                if (self.state_dir / 'runners' / unit / 'held').exists()]

    def mutations(self):
        return self.calls('stop') + self.calls('start')

    def trashes(self):
        return sorted(path.name for path in self.parent.glob('.storage.trash.*'))

    def assert_skipped(self, result, reason):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'skipped reason={reason}', result.stdout)

    def assert_untouched(self):
        self.assertTrue((self.store / 'db.sql').exists())
        self.assertEqual(self.trashes(), [])

    def test_first_run_starts_the_age_clock_and_changes_nothing(self):
        result = self.run_reset()
        self.assert_skipped(result, 'not_due used_percent=20 age_seconds=0')
        self.assertTrue(self.stamp.exists())
        self.assertEqual(self.mutations(), [])
        self.assert_untouched()

    def test_due_reset_stops_renames_starts_then_deletes_trash(self):
        self.age_stamp(8 * DAY)
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertIn('trash_deleted seconds=', result.stdout)
        self.assertEqual(self.mutations(), [
            f'stop {PRIMARY}', f'stop {POOL}', f'stop {FAST}',
            f'stop {DOCKER} {PODMAN}',
            f'start {DOCKER} {PODMAN} {PRIMARY} {POOL} {FAST}',
        ])
        self.assertEqual(self.markers(), [])
        # The store is gone, its trash deleted, and no restart is left queued.
        self.assertFalse(self.store.exists())
        self.assertEqual(self.trashes(), [])
        self.assertFalse(self.restart.exists())
        self.assertLess(time.time() - self.stamp.stat().st_mtime, 60)
        # The next run finds nothing due.
        self.assert_skipped(self.run_reset(), 'not_due')

    def test_only_running_runners_are_stopped_and_started(self):
        self.age_stamp(8 * DAY)
        self.update_units(**{POOL: stopped(),
                             FAST: dict(stopped(), ActiveState='failed', SubState='failed')})
        (self.state_dir / 'runners' / POOL / 'held').touch()
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [
            f'stop {PRIMARY}', f'stop {DOCKER} {PODMAN}',
            f'start {DOCKER} {PODMAN} {PRIMARY}'])

    def test_store_use_resets_at_most_every_six_hours(self):
        self.df.write_text('100 25\n')
        self.age_stamp(3600)
        self.assert_skipped(self.run_reset(), 'not_due used_percent=75')
        self.age_stamp(7 * 3600)
        result = self.run_reset()
        self.assertIn('reset due=store_use', result.stdout)

    def test_busy_or_held_hosts_are_skipped_without_any_stop(self):
        cases = {
            'io_pressure full_avg10_hundredths=600': lambda: self.set_pressure(600),
            'hold_inactive': lambda: self.update_units(**{HOLD: stopped()}),
            f'runner_state_missing unit={FAST}': lambda: (self.state_dir / 'runners' / FAST).rmdir(),
            f'prune_active unit={PRUNES[0]}': lambda: self.update_units(**{PRUNES[0]: running()}),
            f'api_inactive unit={PODMAN}': lambda: self.update_units(**{PODMAN: stopped()}),
            f'runner_job unit={FAST}': lambda: self.update_units(**{FAST: dict(running(), Job='7')}),
            f'runner_transition unit={POOL} state=deactivating:stop-sigterm':
                lambda: self.update_units(**{POOL: dict(running(), ActiveState='deactivating', SubState='stop-sigterm')}),
            'job_running': lambda: (self.engines / 'podman.sock').write_text(
                '[{"Names": ["/FORGEJO-ACTIONS-TASK-12_job"]}]'),
            'engine_api_invalid': lambda: (self.engines / 'docker.sock').write_text('{}'),
            'engine_api_unavailable': lambda: (self.engines / 'docker.sock').unlink(),
            # A job still pulling its image has no container yet.
            f'recent_job unit={POOL}': lambda: (self.journals / POOL).write_text(
                'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n'),
        }
        for reason, arrange in cases.items():
            with self.subTest(reason=reason):
                self.tearDown()
                self.setUp()
                self.age_stamp(8 * DAY)
                arrange()
                self.assert_skipped(self.run_reset(), reason)
                self.assertEqual(self.mutations(), [])
                self.assert_untouched()

    def test_a_game_or_a_missing_game_signal_holds_the_reset(self):
        self.age_stamp(8 * DAY)
        self.game_file.write_text('wine:Game.exe\n')
        self.assert_skipped(self.run_reset(GAME_ENABLED='1'), 'game')
        self.assertEqual(self.mutations(), [])
        self.game_file.unlink()
        self.update_units(**{GAME: stopped()})
        self.assert_skipped(self.run_reset(GAME_ENABLED='1'), 'game_signal_unavailable')
        self.assertEqual(self.mutations(), [])
        # Without game holds the signal is not consulted.
        self.assertIn('reset due=store_age', self.run_reset().stdout)

    def test_a_job_admitted_during_the_stops_stops_no_further_runner(self):
        self.age_stamp(8 * DAY)
        self.set_fake(job_on_stop=True)
        result = self.run_reset()
        self.assert_skipped(result, 'job_running')
        # Only the runner stopped before the job appeared is stopped; the
        # restart list brings it back.
        self.assertEqual(self.mutations(), [f'stop {PRIMARY}'])
        self.assert_untouched()
        self.assertEqual(self.restart.read_text().split(), APIS + RUNNERS)

    def test_a_job_started_during_the_stops_stops_no_further_runner(self):
        # A job still pulling its image has no container yet.
        self.age_stamp(8 * DAY)
        self.set_fake(journal_on_stop=FAST)
        result = self.run_reset()
        self.assert_skipped(result, f'recent_job unit={FAST}')
        self.assertEqual(self.mutations(), [f'stop {PRIMARY}', f'stop {POOL}'])
        self.assert_untouched()

    def test_an_old_job_start_does_not_hold_the_reset(self):
        self.age_stamp(8 * DAY)
        (self.journals / POOL).write_text('level=info msg="[poller] launched"\n')
        self.assertIn('reset due=store_age', self.run_reset().stdout)

    def test_leftover_containers_that_are_not_jobs_do_not_block(self):
        self.age_stamp(8 * DAY)
        (self.engines / 'podman.sock').write_text(
            '[{"Names": ["/buildx_buildkit_builder0"]}, {"Names": null}]')
        self.assertIn('reset due=store_age', self.run_reset().stdout)

    def test_restart_hands_refused_runners_to_the_hold(self):
        self.restart.write_text('\n'.join(APIS + RUNNERS) + '\n')
        self.update_units(**{unit: stopped() for unit in APIS + RUNNERS})
        # A game started during the run: every runner's start gate refuses
        # and leaves its marker, and the runner hold starts them later.
        self.set_fake(refuse=RUNNERS)
        result = self.run_reset('restart')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [f'start {DOCKER} {PODMAN} {PRIMARY} {POOL} {FAST}'])
        self.assertFalse(self.restart.exists())
        self.assertEqual(self.markers(), RUNNERS)
        for unit in RUNNERS:
            self.assertIn(f'handed_to_hold unit={unit} state=inactive', result.stdout)

    def test_a_refused_start_after_the_reset_is_handed_to_the_hold(self):
        self.age_stamp(8 * DAY)
        self.set_fake(refuse=[POOL])
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertIn(f'handed_to_hold unit={POOL} state=inactive', result.stdout)
        self.assertEqual(self.markers(), [POOL])
        self.assertFalse(self.restart.exists())

    def test_a_failed_start_is_reported_and_not_handed_over(self):
        self.age_stamp(8 * DAY)
        self.set_fake(fail_start=[POOL])
        result = self.run_reset()
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'start_failed unit={POOL} state=failed', result.stderr)
        self.assertIn('failed step=start', result.stderr)
        self.assertNotIn('handed_to_hold', result.stdout)
        self.assertEqual(self.markers(), [])
        # ExecStopPost tries the recorded starts once more.
        self.assertTrue(self.restart.exists())

    def test_a_runner_started_during_the_stop_keeps_the_apis_running(self):
        self.age_stamp(8 * DAY)
        self.update_units(**{FAST: stopped()})
        self.set_fake(start_on_stop=FAST)
        result = self.run_reset()
        self.assert_skipped(result, f'runner_started unit={FAST}')
        self.assertEqual(self.mutations(), [f'stop {PRIMARY}', f'stop {POOL}'])
        self.assert_untouched()

    def test_restart_without_a_list_does_nothing(self):
        result = self.run_reset('restart')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_start_queued_during_the_stop_prevents_the_rename(self):
        self.age_stamp(8 * DAY)
        self.set_fake(restart_api=PODMAN)
        result = self.run_reset()
        self.assert_skipped(result, f'unit_not_stopped unit={PODMAN}')
        self.assert_untouched()
        self.assertTrue(self.restart.exists())

    def test_a_populated_api_cgroup_prevents_the_rename(self):
        self.age_stamp(8 * DAY)
        (self.cgroups / 'forgejobuilds.slice' / PODMAN / 'cgroup.events').write_text('populated 1\n')
        self.assert_skipped(self.run_reset(), f'api_cgroup_populated unit={PODMAN}')
        self.assert_untouched()

    def test_a_mount_inside_the_store_prevents_the_rename(self):
        self.age_stamp(8 * DAY)
        with self.mountinfo.open('a') as handle:
            handle.write(f'40 22 0:40 / {self.store}/overlay/layer/merged rw - overlay overlay rw\n')
        self.assert_skipped(self.run_reset(), f'store_mounted path={self.store}/overlay/layer/merged')
        self.assert_untouched()

    def test_a_store_that_is_itself_a_mount_is_never_renamed(self):
        self.age_stamp(8 * DAY)
        with self.mountinfo.open('a') as handle:
            handle.write(f'40 22 0:40 / {self.store} rw - zfs pool/podman rw\n')
        self.assert_skipped(self.run_reset(), f'store_mounted path={self.store}')
        self.assert_untouched()

    def test_a_missing_store_is_still_a_reset(self):
        self.age_stamp(8 * DAY)
        for path in sorted(self.store.rglob('*'), reverse=True):
            path.rmdir() if path.is_dir() else path.unlink()
        self.store.rmdir()
        result = self.run_reset()
        self.assertIn('reset due=store_age', result.stdout)

    def test_a_leftover_fence_is_reset_at_once_and_removed(self):
        fence = self.legacy_fence
        fence.mkdir(parents=True)
        (fence / 'owner').write_text('cleanup-v2 1 1 0 DELETE /images/x\n')
        result = self.run_reset()
        self.assertIn('reset due=legacy_fence', result.stdout)
        self.assertFalse(fence.exists())
        self.assertFalse(self.store.exists())

    def test_leftover_trash_is_deleted_first_and_holds_a_due_reset(self):
        self.age_stamp(8 * DAY)
        trash = self.parent / '.storage.trash.100'
        (trash / 'overlay' / 'old').mkdir(parents=True)
        self.game_file.write_text('process:reaper\n')
        result = self.run_reset(GAME_ENABLED='1')
        self.assert_skipped(result, 'trash_left')
        self.assertIn('trash_left reason=game', result.stdout)
        self.assertTrue(trash.exists())
        self.assertEqual(self.mutations(), [])
        self.game_file.unlink()
        result = self.run_reset()
        self.assertIn('trash_deleted', result.stdout)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertEqual(self.trashes(), [])

    def test_failures_after_a_trash_deletion_still_reach_stderr(self):
        self.age_stamp(8 * DAY)
        (self.parent / '.storage.trash.100' / 'overlay').mkdir(parents=True)
        self.set_fake(fail=['stop'])
        result = self.run_reset()
        self.assertEqual(result.returncode, 1)
        self.assertIn('trash_deleted', result.stdout)
        self.assertIn(f'failed step=runner_stop unit={PRIMARY}', result.stderr)

    def test_pressure_stops_the_trash_deletion_after_the_restart(self):
        self.age_stamp(8 * DAY)
        slow_remove = self.bin / 'slow-rm'
        slow_remove.write_text(
            '#!/bin/sh\n'
            f'printf "full avg10=90.00 avg60=0 avg300=0 total=0\\n" > {self.pressure}\n'
            'exec sleep 30\n')
        slow_remove.chmod(0o755)
        result = self.run_reset(REMOVE_BIN=str(slow_remove))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertIn('trash_left reason=io_pressure full_avg10_hundredths=9000', result.stdout)
        self.assertEqual(len(self.trashes()), 1)
        self.assertEqual(self.calls('start')[-1], f'start {DOCKER} {PODMAN} {PRIMARY} {POOL} {FAST}')

    def test_planted_trash_entries_are_unlinked_unfollowed_and_hold_nothing(self):
        self.age_stamp(8 * DAY)
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('keep\n')
        (self.parent / '.storage.trash.1').symlink_to(outside)
        os.mkfifo(self.parent / '.storage.trash.2')
        (self.parent / '.storage.trash.3').write_text('file\n')
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        for number in (1, 2, 3):
            self.assertIn(f'trash_skipped reason=not_a_directory path={self.parent}/.storage.trash.{number}',
                          result.stdout)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertTrue((outside / 'keep').exists())
        self.assertEqual(self.trashes(), [])

    def test_invalid_runner_lists_are_rejected(self):
        for units in ('', PRIMARY, f'{POOL} {PRIMARY}', f'{PRIMARY} {POOL} bad;unit'):
            with self.subTest(units=units):
                self.assertEqual(self.run_reset(RUNNER_UNITS=units).returncode, 1)
                self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
