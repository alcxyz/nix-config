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
# A host's second pool slot, on the same API and scratch.
POOL2 = 'forgejo-podman-runner-2.service'
HOLD = 'forgejo-runner-hold.service'
GAME = 'game-signal.service'
RUNNERS = [PRIMARY, POOL]
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
    props = {'FreezerState': state['freezer']} if name == 'forgejobuilds.slice' else dict(unit(name))
    # A runner whose pause file exists reports the pause (nix-packages ADR-0017).
    pause = Path(os.environ['FAKE_PAUSE_DIR']) / name
    if pause.exists() and 'StatusText' in wanted:
        props['StatusText'] = state.get('paused_texts', {}).get(name, state.get('paused_text', 'paused tasks=0'))
        # Simulates a running job that ends after N reads of the status.
        busy = state.get('busy_reads', {})
        if busy.get(name, 0) > 0:
            props['StatusText'] = 'paused tasks=1'
            busy[name] -= 1
            path.write_text(json.dumps(state))
        # Simulates a runner restart that removes the pause after N reads.
        if 'remove_pause_after_reads' in state:
            state['remove_pause_after_reads'] -= 1
            if state['remove_pause_after_reads'] <= 0:
                pause.unlink()
                del state['remove_pause_after_reads']
            path.write_text(json.dumps(state))
    for key in wanted:
        print(props.get(key, '') if '--value' in args else f'{key}={props.get(key, "")}')
elif args[0] == 'is-active':
    sys.exit(0 if unit(args[-1])['ActiveState'] == 'active' else 3)
elif args[0] in ('stop', 'start'):
    names = [arg for arg in args[1:] if not arg.startswith('--')]
    if args[0] in state.get('fail', []):
        sys.exit(1)
    # Record any scratch trash the units would start beside.
    if args[0] == 'start' and os.environ.get('FAKE_SCRATCH_PARENT'):
        trash = sorted(p.name for p in Path(os.environ['FAKE_SCRATCH_PARENT']).glob('.storage.trash.*'))
        state.setdefault('trash_at_start', []).append(trash)
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
# The list with stopped containers may have its own reply, "<socket>.all".
if sys.argv[-1].endswith('?all=true') and reply.with_name(reply.name + '.all').exists():
    reply = reply.with_name(reply.name + '.all')
if not reply.exists():
    sys.exit(7)
text = reply.read_text()
# A job container that is gone after N more lists, "<socket>.reads".
reads = reply.with_name(reply.name + '.reads')
if not sys.argv[-1].endswith('?all=true') and reads.exists():
    left = int(reads.read_text())
    if left <= 0:
        text = '[]'
        reply.write_text(text)
        reads.unlink()
    else:
        reads.write_text(str(left - 1))
sys.stdout.write(text)
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

# A path may have its own values in "<values>.<basename>", as the scratch has,
# and its own inode counts in "<values>.inodes.<basename>"; any other has
# 100 inodes, all free.
FAKE_DF = r'''#!/bin/sh
for last; do :; done
values=$FAKE_DF_VALUES
[ -e "$values.${last##*/}" ] && values=$values.${last##*/}
line=$(cat "$values")
case " $* " in
*itotal*)
  inodes="100 100"
  [ -e "$FAKE_DF_VALUES.inodes.${last##*/}" ] && inodes=$(cat "$FAKE_DF_VALUES.inodes.${last##*/}")
  line="$line $inodes"
  ;;
esac
printf 'Size Avail\n%s\n' "$line"
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
                   RUNNER_UNITS=f'{PRIMARY} {POOL}',
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
                   FAKE_DF_VALUES=str(self.df),
                   PAUSE_DIR=str(self.root / 'paused'),
                   PAUSE_RECORD=str(self.root / 'pause-record'),
                   FAKE_PAUSE_DIR=str(self.root / 'paused'))
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

    def scratch(self):
        """A RAM scratch graphroot beside the image store (#1027)."""
        scratch_parent = self.root / 'scratch'
        graph = scratch_parent / 'storage'
        (graph / 'volumes' / 'workspace').mkdir(parents=True)
        (graph / 'volumes' / 'workspace' / 'file').write_text('job\n')
        return scratch_parent, graph

    def test_scratch_is_reset_together_with_the_store(self):
        scratch_parent, graph = self.scratch()
        self.age_stamp(8 * DAY)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertIn('scratch_percent=20', result.stdout)
        self.assertFalse(graph.exists())
        self.assertFalse(self.store.exists())
        self.assertEqual(list(scratch_parent.glob('.storage.trash.*')), [])
        self.assertEqual(self.trashes(), [])

    def test_full_scratch_resets_at_any_age_and_is_freed_before_the_start(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 60\n')
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=40 age_seconds=')
        self.assertEqual(self.mutations(), [])
        Path(f'{self.df}.scratch').write_text('100 25\n')
        # A busy host would leave the disk trash for later, never the scratch.
        self.set_pressure(900)
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, 'io_pressure')
        self.set_pressure(0)
        result = self.run_reset(SCRATCH_STORE=str(graph), FAKE_SCRATCH_PARENT=str(scratch_parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        self.assertEqual(list(scratch_parent.glob('.storage.trash.*')), [])
        # The units started with the scratch trash already gone.
        starts = json.loads(self.fake_state.read_text())['trash_at_start']
        self.assertTrue(starts)
        self.assertEqual(starts, [[] for _ in starts])
        # The images and the age clock stay: only the scratch was reset.
        self.assertTrue((self.store / 'db.sql').exists())
        self.assertLess(time.time() - self.stamp.stat().st_mtime, 3600 + 60)
        self.assertGreater(time.time() - self.stamp.stat().st_mtime, 500)


    def leftover_list(self, containers):
        (self.engines / 'podman.sock.all').write_text(json.dumps(
            [{'Names': [f'/{name}'], 'State': state} for name, state in containers]))

    def test_leftover_containers_reset_the_scratch_alone(self):
        scratch_parent, graph = self.scratch()
        self.age_stamp(600)
        # A cancelled job's service still runs and its build container stopped.
        self.leftover_list([('happy_galileo', 'running'), ('quirky_mcclintock', 'exited')])
        result = self.run_reset(SCRATCH_STORE=str(graph), FAKE_SCRATCH_PARENT=str(scratch_parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('leftover_containers=2', result.stdout)
        self.assertIn('reset due=leftover_containers', result.stdout)
        self.assertFalse(graph.exists())
        self.assertEqual(list(scratch_parent.glob('.storage.trash.*')), [])
        # The images and the age clock stay: only the scratch was reset.
        self.assertTrue((self.store / 'db.sql').exists())
        self.assertGreater(time.time() - self.stamp.stat().st_mtime, 500)

    def test_running_job_containers_are_no_leftovers(self):
        scratch_parent, graph = self.scratch()
        self.age_stamp(600)
        self.leftover_list([('FORGEJO-ACTIONS-TASK-7_WORKFLOW-x_JOB-build', 'running')])
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=20 age_seconds=')
        self.assertIn('leftover_containers=0', result.stdout)
        self.assertEqual(self.mutations(), [])
        # A job container that stopped and was never removed is one.
        self.leftover_list([('FORGEJO-ACTIONS-TASK-7_WORKFLOW-x_JOB-build', 'exited')])
        result = self.run_reset(SCRATCH_STORE=str(graph), FAKE_SCRATCH_PARENT=str(scratch_parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=leftover_containers', result.stdout)

    def test_leftovers_wait_for_a_quiet_pool(self):
        scratch_parent, graph = self.scratch()
        self.age_stamp(600)
        self.leftover_list([('happy_galileo', 'running')])
        (self.journals / POOL).write_text('level=info msg="task 9 repo is alcxyz/example"\n')
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'recent_job unit={POOL}')
        self.assertEqual(self.mutations(), [])
        self.assertTrue(graph.exists())

    def test_an_unreadable_container_list_triggers_nothing(self):
        scratch_parent, graph = self.scratch()
        self.age_stamp(600)
        (self.engines / 'podman.sock.all').write_text('{"message": "busy"}')
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=20 age_seconds=')
        self.assertIn('leftover_containers=unknown', result.stdout)
        (self.engines / 'podman.sock.all').unlink()
        (self.engines / 'podman.sock').unlink()
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assertIn('leftover_containers=unknown', result.stdout)
        self.assertEqual(self.mutations(), [])

    def test_leftovers_need_the_scratch(self):
        self.age_stamp(600)
        self.leftover_list([('happy_galileo', 'running')])
        result = self.run_reset()
        self.assert_skipped(result, 'not_due used_percent=20 age_seconds=')
        self.assertNotIn('leftover_containers', result.stdout)
        self.assertEqual(self.mutations(), [])

    INVOCATION = '0123456789abcdef0123456789abcdef'

    def volume_filesystem(self, options='rw,relatime', super_options='rw,discard,errors=remount-ro'):
        """The volume filesystem in RAM (ADR-0108), as mountinfo shows it,
        made by the running API's start."""
        mount = self.root / 'run' / 'forgejo-podman-volumes'
        with self.mountinfo.open('a') as mountinfo:
            mountinfo.write(f'23 1 252:1 / {mount} {options} - ext4 /dev/zram1 {super_options}\n')
        self.ext4 = self.root / 'sys-fs-ext4'
        (self.ext4 / 'zram1').mkdir(parents=True, exist_ok=True)
        self.set_errors(0)
        # zram's sysfs, where the reset compacts the device.
        self.zram = self.root / 'sys-block'
        (self.zram / 'zram1').mkdir(parents=True, exist_ok=True)
        (self.zram / 'zram1' / 'compact').write_text('')
        self.volume_stamp = self.root / 'run' / 'forgejo-podman-volumes.started'
        self.volume_stamp.parent.mkdir(exist_ok=True)
        self.volume_stamp.write_text(self.INVOCATION + '\n')
        props = running()
        props['InvocationID'] = self.INVOCATION
        self.update_units(**{PODMAN: props})
        return mount

    def set_errors(self, count):
        (self.ext4 / 'zram1' / 'errors_count').write_text(f'{count}\n')

    def volume_env(self, graph, mount, **extra):
        return dict(SCRATCH_STORE=str(graph), VOLUME_MOUNT=str(mount),
                    VOLUME_STAMP=str(self.volume_stamp), EXT4_SYSFS=str(self.ext4),
                    ZRAM_SYSFS=str(self.zram), **extra)

    def test_leftover_volumes_reset_the_scratch_alone(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        Path(f'{self.df}.{mount.name}').write_text('100 75\n')
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=20 volume_percent=25 volume_inode_percent=0 age_seconds=')
        self.assertEqual(self.mutations(), [])
        # Each check compacts the device's memory.
        self.assertEqual((self.zram / 'zram1' / 'compact').read_text(), '1\n')
        Path(f'{self.df}.{mount.name}').write_text('100 25\n')
        result = self.run_reset(**self.volume_env(graph, mount, FAKE_SCRATCH_PARENT=str(scratch_parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('volume_percent=75', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        # The API's start makes the volumes again; the images and the age
        # clock stay.
        self.assertTrue(any('forgejo-runner-podman.service' in call for call in self.calls('start')))
        self.assertTrue((self.store / 'db.sql').exists())
        self.assertGreater(time.time() - self.stamp.stat().st_mtime, 500)

    def test_leftover_inodes_reset_the_scratch_alone(self):
        """Many small files use up the inodes before the bytes."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        Path(f'{self.df}.{mount.name}').write_text('100 95\n')
        Path(f'{self.df}.inodes.{mount.name}').write_text('100 50\n')
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=20 volume_percent=5 volume_inode_percent=50 age_seconds=')
        self.assertEqual(self.mutations(), [])
        Path(f'{self.df}.inodes.{mount.name}').write_text('100 25\n')
        result = self.run_reset(**self.volume_env(graph, mount, FAKE_SCRATCH_PARENT=str(scratch_parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('volume_percent=5 volume_inode_percent=75', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertTrue(any(PODMAN in call for call in self.calls('start')))
        self.assertTrue((self.store / 'db.sql').exists())

    def test_used_up_inodes_drain_the_pool_and_reset(self):
        """With no inode left every new volume fails, as on a full
        filesystem, so a recent job does not hold the reset."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        Path(f'{self.df}.{mount.name}').write_text('100 99\n')
        Path(f'{self.df}.inodes.{mount.name}').write_text('100 0\n')
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount, FAKE_SCRATCH_PARENT=str(scratch_parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('volume_percent=1 volume_inode_percent=100', result.stdout)
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertTrue((self.store / 'db.sql').exists())
        # Below the recovery threshold a recent job still holds it.
        Path(f'{self.df}.inodes.{mount.name}').write_text('100 20\n')
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assert_skipped(result, f'recent_job unit={POOL}')

    def test_unreadable_inode_counts_trigger_nothing(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        Path(f'{self.df}.inodes.{mount.name}').write_text('0 0\n')
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assert_skipped(result, 'volumes_unreadable')
        self.assertEqual(self.mutations(), [])

    def assert_unusable(self, graph, mount, scratch_parent, state):
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        result = self.run_reset(**self.volume_env(graph, mount, FAKE_SCRATCH_PARENT=str(scratch_parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'volume_state={state}', result.stdout)
        # Every job fails on it, so a recent job does not hold the reset.
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assertIn('reset due=volumes_unusable', result.stdout)
        # A reset of the scratch alone: the images stay.
        self.assertTrue((self.store / 'db.sql').exists())

    def test_an_ext4_error_drains_the_pool_and_resets(self):
        """In the VM check, on the hosts' kernel 7.3.3, ext4's errors=remount-ro
        leaves the mount and the superblock rw in mountinfo (the superblock
        adds emergency_ro); its error count shows the error."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        self.set_errors(1)
        self.age_stamp(600)
        self.assert_unusable(graph, mount, scratch_parent, 'fs_error')

    def test_a_read_only_volume_filesystem_drains_the_pool_and_resets(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem('ro,relatime')
        self.age_stamp(600)
        self.assert_unusable(graph, mount, scratch_parent, 'read_only')

    def test_a_read_only_superblock_drains_the_pool_and_resets(self):
        """Kernels from before ext4's emergency_ro state mark only the
        superblock read-only after an error."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem(super_options='ro,discard,errors=remount-ro')
        self.age_stamp(600)
        self.assert_unusable(graph, mount, scratch_parent, 'read_only')

    def test_an_unmounted_volume_filesystem_drains_the_pool_and_resets(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        self.mountinfo.write_text('22 1 0:21 / / rw - ext4 /dev/root rw\n')
        self.age_stamp(600)
        self.assert_unusable(graph, mount, scratch_parent, 'unmounted')

    def test_another_filesystem_at_the_volume_mount_drains_the_pool_and_resets(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        with self.mountinfo.open('a') as mountinfo:
            mountinfo.write(f'24 23 0:30 / {mount} rw,relatime - tmpfs tmpfs rw\n')
        self.age_stamp(600)
        self.assert_unusable(graph, mount, scratch_parent, 'foreign')

    def test_an_api_from_before_the_volumes_moved_is_left_alone(self):
        """A deploy gives the reset VOLUME_MOUNT while the running API, which
        a deploy does not restart, still keeps its volumes on disk."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        self.mountinfo.write_text('22 1 0:21 / / rw - ext4 /dev/root rw\n')
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        self.age_stamp(600)
        # No API start has made a filesystem yet, or an earlier API did.
        for stamp in (None, 'fedcba9876543210fedcba9876543210\n'):
            if stamp is None:
                self.volume_stamp.unlink()
            else:
                self.volume_stamp.write_text(stamp)
            result = self.run_reset(**self.volume_env(graph, mount))
            self.assert_skipped(result, 'not_due used_percent=20 scratch_percent=20 volumes=not_in_use age_seconds=')
            self.assertNotIn('volume_state', result.stdout)
            self.assertEqual(self.mutations(), [])
            self.assertFalse((self.root / 'paused').exists())
        # An inactive API has no invocation ID to match.
        props = stopped()
        props['InvocationID'] = ''
        self.update_units(**{PODMAN: props})
        self.volume_stamp.write_text('\n')
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assertIn('volumes=not_in_use', result.stdout)
        self.assertEqual(self.mutations(), [])

    def test_an_unreadable_error_count_triggers_nothing(self):
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        (self.ext4 / 'zram1' / 'errors_count').unlink()
        self.age_stamp(600)
        result = self.run_reset(**self.volume_env(graph, mount))
        self.assert_skipped(result, 'volumes_unreadable')
        self.assertEqual(self.mutations(), [])

    def test_volumes_in_ram_need_the_scratch(self):
        mount = self.volume_filesystem()
        result = self.run_reset(VOLUME_MOUNT=str(mount))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutations(), [])

    def test_full_scratch_pauses_and_drains_the_pool_runner(self):
        scratch_parent, graph = self.scratch()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        # Above the trigger but below full: a recent job start still holds it.
        Path(f'{self.df}.scratch').write_text('100 25\n')
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'recent_job unit={POOL}')
        self.assertTrue(graph.exists())
        # Full: every job's setup fails, so the quiet interval no longer holds.
        Path(f'{self.df}.scratch').write_text('100 5\n')
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        # No runner starts paused.
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def job_container(self, socket='podman.sock', reads=None):
        """A running job's task container; with reads, it is gone after
        that many more lists, as its job's cleanup removes it."""
        (self.engines / socket).write_text(json.dumps([{'Names': ['/FORGEJO-ACTIONS-TASK-1_x']}]))
        if reads is not None:
            (self.engines / f'{socket}.reads').write_text(str(reads))

    def test_a_running_pool_job_holds_a_reset_below_the_full_mark(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 25\n')
        self.age_stamp(600)
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'job_running socket={self.root}/run/podman.sock')
        self.assertEqual(self.mutations(), [])
        self.assertFalse((self.root / 'paused').exists())
        self.assertTrue(graph.exists())

    def test_full_scratch_pauses_the_pool_and_resets_once_its_job_ends(self):
        """Leaked volumes fill the volume filesystem while jobs keep coming:
        a running pool job no longer skips the reset; the pool is paused, so
        it takes no new job, and the reset waits for the running one."""
        scratch_parent, graph = self.scratch()
        mount = self.volume_filesystem()
        Path(f'{self.df}.{mount.name}').write_text('100 0\n')
        self.age_stamp(600)
        # The runner reports its job for two status reads, and its container
        # outlives that report by one list.
        self.set_fake(busy_reads={POOL: 2})
        self.job_container(reads=3)
        result = self.run_reset(**self.volume_env(graph, mount, FAKE_SCRATCH_PARENT=str(scratch_parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('volume_percent=100', result.stdout)
        self.assertIn(f'pausing units={POOL}', result.stdout)
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        self.assertTrue((self.store / 'db.sql').exists())
        # The runner was stopped only after its job ended.
        self.assertEqual(json.loads(self.fake_state.read_text())['busy_reads'], {POOL: 0})
        self.assertFalse((self.engines / 'podman.sock.reads').exists())
        self.assertIn(f'stop {POOL}', self.calls('stop'))
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def test_full_scratch_drains_a_running_job_on_both_pool_slots(self):
        scratch_parent, graph = self.scratch()
        units = self.second_slot()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        self.set_fake(busy_reads={POOL: 1, POOL2: 3})
        self.job_container(reads=2)
        result = self.run_reset(SCRATCH_STORE=str(graph), FAKE_SCRATCH_PARENT=str(scratch_parent), **units)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'pausing units={POOL} {POOL2}', result.stdout)
        self.assertIn(f'drained unit={POOL2}', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        for unit in (POOL, POOL2):
            self.assertFalse((self.root / 'paused' / unit).exists())

    def test_full_scratch_unpauses_when_a_pool_job_outlasts_the_wait(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        self.set_fake(paused_text='paused tasks=1')
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph), PAUSE_WAIT_SECONDS='1')
        self.assertIn(f'pausing units={POOL}', result.stdout)
        self.assert_skipped(result, f'pool_not_drained unit={POOL}')
        self.assertEqual(self.calls('stop'), [])
        self.assertTrue(graph.exists())
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def test_full_scratch_unpauses_when_a_job_container_outlasts_the_wait(self):
        """The runner reports no job, but a task container still runs."""
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph), PAUSE_WAIT_SECONDS='1')
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assert_skipped(result, f'pool_not_drained socket={self.root}/run/podman.sock')
        self.assertEqual(self.calls('stop'), [])
        self.assertTrue(graph.exists())
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def test_full_scratch_still_skips_a_docker_job(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        self.job_container('docker.sock')
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'job_running socket={self.root}/run/docker.sock')
        self.assertEqual(self.mutations(), [])
        self.assertFalse((self.root / 'paused').exists())

    def test_full_scratch_skips_a_job_no_running_pool_runner_can_drain(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        self.update_units(**{POOL: stopped()})
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'job_running socket={self.root}/run/podman.sock')
        self.assertEqual(self.mutations(), [])
        self.assertFalse((self.root / 'paused').exists())

    def test_full_scratch_leaves_someone_elses_pause_alone_with_a_job_running(self):
        scratch_parent, graph = self.scratch()
        Path(f'{self.df}.scratch').write_text('100 5\n')
        (self.root / 'paused').mkdir()
        (self.root / 'paused' / POOL).touch()
        self.age_stamp(600)
        self.job_container()
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'runner_paused unit={POOL}')
        self.assertTrue((self.root / 'paused' / POOL).exists())
        self.assertEqual(self.mutations(), [])

    def second_slot(self):
        (self.state_dir / 'runners' / POOL2).mkdir()
        self.update_units(**{POOL2: running()})
        return {'RUNNER_UNITS': f'{PRIMARY} {POOL} {POOL2}'}

    def test_full_scratch_drains_both_pool_slots(self):
        scratch_parent, graph = self.scratch()
        units = self.second_slot()
        # Only the second slot started a job recently; both take no new one.
        (self.journals / POOL2).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 25\n')
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph), **units)
        self.assert_skipped(result, f'recent_job unit={POOL2}')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        result = self.run_reset(SCRATCH_STORE=str(graph), **units)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assertIn(f'drained unit={POOL2}', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        stops = '\n'.join(self.calls('stop'))
        self.assertIn(f'stop {POOL}', stops)
        self.assertIn(f'stop {POOL2}', stops)
        self.assertEqual(self.calls('start')[-1], f'start {DOCKER} {PODMAN} {PRIMARY} {POOL} {POOL2}')
        for unit in (POOL, POOL2):
            self.assertFalse((self.root / 'paused' / unit).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def test_full_scratch_leaves_a_pause_on_the_second_slot_alone(self):
        scratch_parent, graph = self.scratch()
        units = self.second_slot()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        (self.root / 'paused').mkdir()
        (self.root / 'paused' / POOL2).touch()
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph), **units)
        self.assert_skipped(result, f'runner_paused unit={POOL2}')
        self.assertTrue((self.root / 'paused' / POOL2).exists())
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertTrue(graph.exists())

    def test_full_scratch_skips_when_the_second_slot_does_not_drain(self):
        scratch_parent, graph = self.scratch()
        units = self.second_slot()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        # The first slot drains; the second still runs a job.
        self.set_fake(paused_texts={POOL2: 'paused tasks=1'})
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph), PAUSE_WAIT_SECONDS='1', **units)
        self.assertIn(f'drained unit={POOL}', result.stdout)
        self.assert_skipped(result, f'pool_not_drained unit={POOL2}')
        self.assertTrue(graph.exists())
        self.assertEqual(self.calls('stop'), [])
        for unit in (POOL, POOL2):
            self.assertFalse((self.root / 'paused' / unit).exists())

    def test_full_scratch_skips_when_the_pool_runner_does_not_drain(self):
        scratch_parent, graph = self.scratch()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.set_fake(paused_text='paused tasks=1')
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph), PAUSE_WAIT_SECONDS='1')
        self.assert_skipped(result, f'pool_not_drained unit={POOL}')
        self.assertTrue(graph.exists())
        self.assertEqual(self.calls('stop'), [])
        self.assertFalse((self.root / 'paused' / POOL).exists())

    def test_full_scratch_leaves_someone_elses_pause_alone(self):
        scratch_parent, graph = self.scratch()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        (self.root / 'paused').mkdir()
        (self.root / 'paused' / POOL).touch()
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'runner_paused unit={POOL}')
        self.assertTrue((self.root / 'paused' / POOL).exists())

    def test_a_pause_removed_before_the_stop_skips_the_reset(self):
        scratch_parent, graph = self.scratch()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        # A runner restart ends and removes every pause right after the drain.
        self.set_fake(remove_pause_after_reads=1)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'pool_unpaused unit={POOL}')
        self.assertTrue(graph.exists())
        self.assertNotIn(f'stop {POOL}', '\n'.join(self.calls('stop')))

    def test_disk_trash_left_does_not_hold_a_scratch_reset(self):
        scratch_parent, graph = self.scratch()
        leftover = self.parent / '.storage.trash.1'
        (leftover / 'overlay').mkdir(parents=True)
        (leftover / 'overlay' / 'blob').write_text('old\n')
        Path(f'{self.df}.scratch').write_text('100 20\n')
        self.age_stamp(600)
        # The disk deletion runs out of time at once: a slow remover for the
        # trash entries, which delete_trash_in passes as /proc/self/fd/8/...,
        # so a tiny file cannot finish before the deadline check. The scratch
        # trash's own removal names its path and stays fast.
        slow_rm = self.bin / 'slow-rm'
        slow_rm.write_text('#!/bin/sh\ncase "$*" in */proc/self/fd/*) exec sleep 30 ;; esac\nexec rm "$@"\n')
        slow_rm.chmod(0o755)
        result = self.run_reset(SCRATCH_STORE=str(graph), TRASH_SECONDS='0', REMOVE_BIN=str(slow_rm))
        self.assertEqual(result.returncode, 0, result.stderr)
        # The slow remover was used and the deadline stopped it.
        self.assertIn('trash_left reason=deadline', result.stdout)
        self.assertIn('reset due=scratch_use', result.stdout)
        self.assertFalse(graph.exists())
        self.assertTrue(self.store.exists())
        # An age reset still waits for it.
        self.age_stamp(8 * DAY)
        result = self.run_reset(SCRATCH_STORE=str(graph), TRASH_SECONDS='0', REMOVE_BIN=str(slow_rm))
        self.assert_skipped(result, 'trash_left')
        self.assertTrue(self.store.exists())

    def test_a_killed_drain_leaves_no_runner_paused(self):
        (self.root / 'paused').mkdir()
        (self.root / 'paused' / POOL).touch()
        (self.root / 'pause-record').write_text(f'{POOL}\n')
        result = self.run_reset('restart')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'paused' / POOL).exists())
        self.assertFalse((self.root / 'pause-record').exists())

    def test_full_scratch_keeps_the_docker_runners_quiet_interval(self):
        scratch_parent, graph = self.scratch()
        # The Docker runner's job uses its own store: a full Podman scratch
        # does not lift its guard, whatever made the reset due.
        (self.journals / PRIMARY).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(600)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assert_skipped(result, f'recent_job unit={PRIMARY}')
        self.assertTrue(graph.exists())

    def test_full_scratch_lifts_the_pool_quiet_interval_for_an_age_reset_too(self):
        scratch_parent, graph = self.scratch()
        (self.journals / POOL).write_text(
            'time="2026-10-31T12:00:00+01:00" level=info msg="task 9 repo is o/r x y"\n')
        Path(f'{self.df}.scratch').write_text('100 5\n')
        self.age_stamp(8 * DAY)
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertFalse(graph.exists())
        self.assertFalse(self.store.exists())

    def test_leftover_scratch_trash_is_deleted_first(self):
        scratch_parent, graph = self.scratch()
        leftover = scratch_parent / '.storage.trash.1'
        (leftover / 'overlay').mkdir(parents=True)
        (leftover / 'overlay' / 'blob').write_text('old\n')
        result = self.run_reset(SCRATCH_STORE=str(graph))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('trash_deleted', result.stdout)
        self.assertFalse(leftover.exists())
        self.assertTrue(graph.exists())

    def test_scratch_beside_the_store_is_refused(self):
        result = self.run_reset(SCRATCH_STORE=str(self.parent / 'graph'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mutations(), [])

    def test_due_reset_stops_renames_starts_then_deletes_trash(self):
        self.age_stamp(8 * DAY)
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset due=store_age', result.stdout)
        self.assertIn('trash_deleted seconds=', result.stdout)
        self.assertEqual(self.mutations(), [
            f'stop {PRIMARY}', f'stop {POOL}',
            f'stop {DOCKER} {PODMAN}',
            f'start {DOCKER} {PODMAN} {PRIMARY} {POOL}',
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
        self.update_units(**{POOL: stopped()})
        (self.state_dir / 'runners' / POOL / 'held').touch()
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [
            f'stop {PRIMARY}', f'stop {DOCKER} {PODMAN}',
            f'start {DOCKER} {PODMAN} {PRIMARY}'])

    def test_failed_runners_are_left_alone(self):
        self.age_stamp(8 * DAY)
        self.update_units(**{POOL: dict(stopped(), ActiveState='failed', SubState='failed')})
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
            f'runner_state_missing unit={POOL}': lambda: (self.state_dir / 'runners' / POOL).rmdir(),
            f'prune_active unit={PRUNES[0]}': lambda: self.update_units(**{PRUNES[0]: running()}),
            f'api_inactive unit={PODMAN}': lambda: self.update_units(**{PODMAN: stopped()}),
            f'runner_job unit={POOL}': lambda: self.update_units(**{POOL: dict(running(), Job='7')}),
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
        self.set_fake(journal_on_stop=POOL)
        result = self.run_reset()
        self.assert_skipped(result, f'recent_job unit={POOL}')
        self.assertEqual(self.mutations(), [f'stop {PRIMARY}'])
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
        self.assertEqual(self.mutations(), [f'start {DOCKER} {PODMAN} {PRIMARY} {POOL}'])
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
        self.update_units(**{POOL: stopped()})
        self.set_fake(start_on_stop=POOL)
        result = self.run_reset()
        self.assert_skipped(result, f'runner_started unit={POOL}')
        self.assertEqual(self.mutations(), [f'stop {PRIMARY}'])
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
        self.assertEqual(self.calls('start')[-1], f'start {DOCKER} {PODMAN} {PRIMARY} {POOL}')

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
        for units in ('', PRIMARY, f'{POOL} {PRIMARY}', f'{PRIMARY} {POOL} bad;unit',
                      f'{PRIMARY} {POOL2}', f'{PRIMARY} {POOL2} {POOL}',
                      f'{PRIMARY} {POOL} forgejo-podman-runner-3.service',
                      f'{PRIMARY} {POOL} {POOL2} {POOL2}'):
            with self.subTest(units=units):
                self.assertEqual(self.run_reset(RUNNER_UNITS=units).returncode, 1)
                self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
