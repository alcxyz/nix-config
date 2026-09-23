#!/usr/bin/env python3
"""Synthetic freeze ownership tests; never contact systemd or Docker."""
import os
import fcntl
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import time
import unittest

GUARD = Path(sys.argv.pop(1)).resolve()
LIFECYCLE = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 else
             GUARD.with_name('aggregate-lifecycle-stop.sh')).resolve()
GATE = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 else
        GUARD.with_name('runner-start-gate.sh')).resolve()


class GuardTests(unittest.TestCase):
    def run_guard(self, values, initial='running', owned=False, pending=False,
                  fail_action='', fail_count='0', fail_state='', action_delay='0',
                  transition_timeout='120', admission=False, drain_owned=False,
                  drain_pending=False, resume_pending=False, runner_state='active',
                  runner_enabled='enabled', runner_load='loaded', runner_result='success',
                  stop_state='inactive', fail_runner_action='', runner_generation='123',
                  drain_generation=None, stop_generation='0', lifecycle_active=True,
                  teardown_required=False, show_fail_count='0'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            if owned:
                (state / 'owned').touch()
            if pending:
                (state / 'pending').touch()
            if drain_owned:
                (state / 'drain-owned').write_text(
                    (drain_generation or runner_generation) + '\n')
            if drain_pending:
                (state / 'drain-pending').touch()
            if resume_pending:
                (state / 'resume-pending').touch()
            if teardown_required:
                (state / 'teardown-required').touch()
            (root / 'actual').write_text(initial)
            (root / 'runner-active').write_text(runner_state)
            (root / 'runner-enabled').write_text(runner_enabled)
            (root / 'runner-load').write_text(runner_load)
            (root / 'runner-result').write_text(runner_result)
            (root / 'runner-generation').write_text(runner_generation)
            (root / 'pressure').write_text('\n'.join(map(str, values)) + '\n')
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == is-active && $2 == forgejo-runner-aggregate-lifecycle.service ]]; then
  [[ $LIFECYCLE_ACTIVE == 1 ]] && printf 'active\\n' || { printf 'inactive\\n'; exit 3; }
  exit
fi
if [[ $1 == show ]]; then
  if ((SHOW_FAIL_COUNT > 0)); then
    count=0
    [[ ! -e $FIXTURE/show-attempts ]] || count=$(cat "$FIXTURE/show-attempts")
    count=$((count + 1))
    printf '%s\\n' "$count" > "$FIXTURE/show-attempts"
    ((count > SHOW_FAIL_COUNT)) || exit 1
  fi
  property=${2#--property=}
  [[ $3 == --value ]]
  case "$4:$property" in
    forgejobuilds.slice:FreezerState) cat "$FIXTURE/actual" ;;
    forgejo-actions-runner.service:ActiveState) cat "$FIXTURE/runner-active" ;;
    forgejo-actions-runner.service:UnitFileState) cat "$FIXTURE/runner-enabled" ;;
    forgejo-actions-runner.service:LoadState) cat "$FIXTURE/runner-load" ;;
    forgejo-actions-runner.service:Result) cat "$FIXTURE/runner-result" ;;
    forgejo-actions-runner.service:ExecMainStartTimestampMonotonic) cat "$FIXTURE/runner-generation" ;;
    *) exit 2 ;;
  esac
  exit
fi
if [[ $1 == --no-block ]]; then
  [[ $# == 3 && $3 == forgejo-actions-runner.service ]]
  printf '%s\n' "$2" >> "$FIXTURE/runner-actions"
  [[ $2 != "$FAIL_RUNNER_ACTION" ]] || exit 1
  case "$2" in
    stop)
      printf '%s' "$STOP_STATE" > "$FIXTURE/runner-active"
      printf '%s' "$STOP_GENERATION" > "$FIXTURE/runner-generation"
      ;;
    start) printf active > "$FIXTURE/runner-active" ;;
    *) exit 2 ;;
  esac
  exit
fi
[[ $# == 2 && $2 == forgejobuilds.slice ]]
[[ ${SYSTEMD_BUS_TIMEOUT:-} =~ ^[1-9][0-9]*s$ ]]
[[ ${SYSTEMD_BUS_TIMEOUT%s} -le $TRANSITION_TIMEOUT_SECONDS ]]
printf '%s\\n' "$1" >> "$FIXTURE/actions"
attempt=$(wc -l < "$FIXTURE/actions")
if [[ $1 == "$FAIL_ACTION" && $attempt -le $FAIL_COUNT ]]; then
  [[ -z $FAIL_STATE ]] || printf '%s' "$FAIL_STATE" > "$FIXTURE/actual"
  exit 1
fi
if [[ $1 == freeze && $ACTION_DELAY != 0 ]]; then sleep "$ACTION_DELAY"; fi
case "$1" in
  freeze) printf frozen > "$FIXTURE/actual" ;;
  thaw) printf running > "$FIXTURE/actual" ;;
  *) exit 2 ;;
esac
''')
            mock.chmod(0o755)
            env = {**os.environ, 'FIXTURE': str(root),
                   'STATE_DIR': str(state), 'SYSTEMCTL_BIN': str(mock),
                   'SYSTEMD_NOTIFY_BIN': 'true', 'LOGGER_BIN': 'true',
                   'PRESSURE_VALUES_FILE': str(root / 'pressure'),
                   'SAMPLE_SECONDS': '0', 'HIGH_SAMPLES_REQUIRED': '2',
                   'LOW_SAMPLES_REQUIRED': '2', 'MAX_ITERATIONS': str(len(values)),
                   'FAIL_ACTION': fail_action, 'FAIL_COUNT': fail_count,
                   'FAIL_STATE': fail_state, 'ACTION_DELAY': action_delay,
                   'TRANSITION_TIMEOUT_SECONDS': transition_timeout,
                   'ADMISSION_CONTROL_ENABLED': '1' if admission else '0',
                   'SEVERE_THRESHOLD_HUNDREDTHS': '6000',
                   'SEVERE_SAMPLES_REQUIRED': '3', 'STOP_STATE': stop_state,
                   'STOP_GENERATION': stop_generation,
                   'FAIL_RUNNER_ACTION': fail_runner_action,
                   'LIFECYCLE_ACTIVE': '1' if lifecycle_active else '0',
                   'SHOW_FAIL_COUNT': show_fail_count}
            result = subprocess.run(['bash', str(GUARD)], env=env, capture_output=True)
            self.events = result.stdout.decode().splitlines()
            actions = (root / 'actions').read_text().splitlines() if (root / 'actions').exists() else []
            self.runner_actions = ((root / 'runner-actions').read_text().splitlines()
                                   if (root / 'runner-actions').exists() else [])
            self.drain_owned = (state / 'drain-owned').exists()
            self.drain_pending = (state / 'drain-pending').exists()
            self.resume_pending = (state / 'resume-pending').exists()
            self.drain_disowned = (state / 'drain-disowned').exists()
            return result.returncode, actions, (state / 'owned').exists(), (state / 'pending').exists()

    def test_hysteresis_freezes_and_thaws_aggregate(self):
        self.assertEqual(self.run_guard([2500, 2500, 1000, 0, 0]), (0, ['freeze', 'thaw'], False, False))

    def test_transition_events_are_ordered_and_include_duration(self):
        self.run_guard([2500, 2500, 1000, 0, 0])
        self.assertEqual([line.split()[0] for line in self.events],
                         ['event=freeze_requested', 'event=frozen',
                          'event=thaw_requested', 'event=thawed'])
        self.assertIn('sampled_full_avg10_hundredths=2500', self.events[0])
        self.assertRegex(self.events[-1], r'transition_seconds=\d+ frozen_seconds=\d+$')

    def test_restart_does_not_invent_frozen_duration(self):
        self.run_guard([0, 0], initial='frozen', owned=True)
        self.assertIn('frozen_seconds=unknown', self.events[-1])

    def test_failed_transition_does_not_report_completion(self):
        self.run_guard([2500, 2500], fail_action='freeze', fail_count='1',
                       fail_state='freezing')
        self.assertEqual([line.split()[0] for line in self.events], ['event=freeze_requested'])

    def test_short_pressure_does_not_freeze(self):
        self.assertEqual(self.run_guard([2500, 0, 0]), (0, [], False, False))

    def test_manual_freeze_is_never_thawed(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen'), (1, [], False, False))

    def test_owned_freeze_survives_restart(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True), (0, ['thaw'], False, False))

    def test_ambiguous_freeze_never_thaws(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', pending=True), (1, [], False, True))

    def test_failed_freeze_retains_pending(self):
        self.assertEqual(self.run_guard([2500, 2500], fail_action='freeze', fail_count='1',
                                        fail_state='freezing'), (1, ['freeze'], False, True))

    def test_aborted_freeze_retries_within_original_deadline(self):
        self.assertEqual(self.run_guard([2500, 2500], fail_action='freeze', fail_count='1'),
                         (0, ['freeze', 'freeze'], True, False))

    def test_freeze_retry_exhausts_original_deadline(self):
        result, actions, owned, pending = self.run_guard(
            [2500, 2500], fail_action='freeze', fail_count='99', transition_timeout='2')
        self.assertEqual(result, 1)
        self.assertGreaterEqual(len(actions), 1)
        self.assertTrue(all(action == 'freeze' for action in actions))
        self.assertFalse(owned)
        self.assertTrue(pending)

    def test_freeze_can_exceed_metadata_timeout(self):
        self.assertEqual(self.run_guard([2500, 2500], action_delay='6', transition_timeout='10'),
                         (0, ['freeze'], True, False))

    def test_failed_thaw_retains_ownership(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True, fail_action='thaw',
                                        fail_count='1'),
                         (1, ['thaw'], True, True))

    def test_external_thaw_requires_recovery(self):
        self.assertEqual(self.run_guard([0], owned=True), (1, [], True, False))

    def test_lost_pressure_freezes_before_stopping(self):
        self.assertEqual(self.run_guard([0, 'invalid']), (1, ['freeze'], True, False))

    def test_unreadable_startup_does_not_claim_ownership(self):
        self.assertEqual(self.run_guard(['invalid']), (1, [], False, False))

    def test_read_only_metadata_retries_during_daemon_reload(self):
        self.assertEqual(self.run_guard([0], show_fail_count='2'),
                         (0, [], False, False))

    def test_pressure_is_deferred_until_lifecycle_is_armed(self):
        self.assertEqual(self.run_guard([6500, 6500, 6500], lifecycle_active=False),
                         (0, [], False, False))

    def test_teardown_marker_blocks_guard_reentry(self):
        self.assertEqual(self.run_guard([0], teardown_required=True),
                         (1, [], False, False))

    def test_admission_mode_drains_at_moderate_pressure_without_freezing(self):
        self.assertEqual(self.run_guard([2500] * 8, admission=True),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)
        self.assertEqual([line.split()[0] for line in self.events],
                         ['event=admission_drain_requested', 'event=admission_draining'])

    def test_admission_mode_freezes_only_after_severe_pressure(self):
        self.assertEqual(self.run_guard([6500, 6500, 6500], admission=True),
                         (0, ['freeze'], True, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)

    def test_recovery_thaws_before_restarting_runner(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True,
                                        admission=True, drain_owned=True,
                                        runner_state='inactive'),
                         (0, ['thaw'], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        events = [line.split()[0] for line in self.events]
        self.assertLess(events.index('event=thawed'),
                        events.index('event=admission_resume_requested'))
        self.assertFalse(self.drain_owned)

    def test_draining_job_is_not_stopped_twice_or_started_early(self):
        self.assertEqual(self.run_guard([2500, 2500, 0, 0], admission=True,
                                        stop_state='deactivating'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)

    def test_guard_restart_resumes_owned_drain_without_second_stop(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', runner_generation='0',
                                        drain_generation='123'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        self.assertFalse(self.drain_owned)

    def test_skipped_switch_start_does_not_block_owned_resume(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', runner_result='exec-condition',
                                        runner_generation='0', drain_generation='123'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])

    def test_guard_restart_does_not_claim_inactive_runner(self):
        self.assertEqual(self.run_guard([2500, 2500, 0, 0], admission=True,
                                        runner_state='inactive'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)

    def test_disabled_runner_is_neither_drained_nor_restarted(self):
        self.run_guard([2500, 2500, 0, 0], admission=True,
                       runner_enabled='disabled')
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)

    def test_failed_runner_with_owned_drain_is_not_restarted(self):
        self.run_guard([0, 0], admission=True, drain_owned=True,
                       runner_state='failed', runner_result='exit-code')
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_owned)

    def test_disabled_runner_with_owned_drain_is_not_restarted(self):
        self.run_guard([0, 0, 0, 0], admission=True, drain_owned=True,
                       runner_state='inactive', runner_enabled='disabled')
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_owned)
        self.assertEqual(sum('event=admission_resume_blocked' in event
                             for event in self.events), 1)

    def test_ambiguous_drain_fails_without_second_stop(self):
        self.assertEqual(self.run_guard([2500], admission=True, drain_pending=True),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_pending)

    def test_ambiguous_resume_fails_without_duplicate_start(self):
        self.assertEqual(self.run_guard([0], admission=True, resume_pending=True,
                                        runner_state='inactive'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.resume_pending)

    def test_failed_stop_retains_ambiguous_drain_state(self):
        self.assertEqual(self.run_guard([2500, 2500], admission=True,
                                        fail_runner_action='stop'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_pending)
        self.assertFalse(self.drain_owned)

    def test_failed_start_retains_ambiguous_resume_state(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', fail_runner_action='start'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        self.assertTrue(self.resume_pending)
        self.assertFalse(self.drain_owned)

    def test_unreadable_pressure_in_admission_mode_freezes_and_fails_closed(self):
        self.assertEqual(self.run_guard([0, 'invalid'], admission=True),
                         (1, ['freeze'], True, False))

    def test_changed_runner_generation_is_disowned_and_fails_closed(self):
        self.assertEqual(self.run_guard([0], admission=True, drain_owned=True,
                                        runner_generation='456', drain_generation='123'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)
        self.assertTrue(self.drain_disowned)
        self.assertIn('event=admission_drain_disowned', self.events[0])

    def test_active_runner_without_generation_is_disowned_and_fails_closed(self):
        self.assertEqual(self.run_guard([0], admission=True, drain_owned=True,
                                        runner_state='active', runner_generation='0',
                                        drain_generation='123'),
                         (1, [], False, False))
        self.assertTrue(self.drain_disowned)


class LifecycleTests(unittest.TestCase):
    def run_stop(self, freezer='frozen', guard='failed', owned=False,
                 pending=False, drain_disowned=False, runner='inactive',
                 lock_held=False, kill_stays_deactivating=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            cgroup = root / 'cgroup' / 'forgejobuilds.slice'
            cgroup.mkdir(parents=True)
            (cgroup / 'cgroup.kill').touch()
            (cgroup / 'cgroup.events').write_text('populated 0\n')
            (root / 'freezer').write_text(freezer)
            (root / 'guard').write_text(guard)
            (root / 'runner').write_text(runner)
            if owned:
                (state / 'owned').touch()
            if pending:
                (state / 'pending').touch()
            if drain_disowned:
                (state / 'drain-disowned').touch()
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == show ]]; then
  case "$2:$4" in
    --property=ControlGroup:forgejobuilds.slice) printf '/forgejobuilds.slice\\n' ;;
    --property=FreezerState:forgejobuilds.slice) cat "$FIXTURE/freezer" ;;
    --property=ActiveState:forgejo-runner-io-pressure-guard.service) cat "$FIXTURE/guard" ;;
    --property=ActiveState:forgejo-actions-runner.service) cat "$FIXTURE/runner" ;;
    *) exit 2 ;;
  esac
elif [[ $1 == thaw && $2 == forgejobuilds.slice ]]; then
  [[ $(cat "$FIXTURE/cgroup/forgejobuilds.slice/cgroup.kill") == 1 ]]
  printf running > "$FIXTURE/freezer"
  printf 'thaw\\n' >> "$FIXTURE/actions"
elif [[ $1 == kill && $2 == --signal=KILL && $3 == --kill-whom=all && $4 == forgejo-actions-runner.service ]]; then
  [[ $(cat "$FIXTURE/cgroup/forgejobuilds.slice/cgroup.kill") == 1 ]]
  printf 'kill\\n' >> "$FIXTURE/actions"
  [[ $KILL_STAYS_DEACTIVATING == 1 ]] || printf inactive > "$FIXTURE/runner"
else
  exit 2
fi
''')
            mock.chmod(0o755)
            env = {**os.environ, 'FIXTURE': str(root), 'STATE_DIR': str(state),
                   'CGROUP_ROOT': str(root / 'cgroup'), 'SYSTEMCTL_BIN': str(mock),
                   'TEARDOWN_TIMEOUT_SECONDS': '2' if lock_held or kill_stays_deactivating else '270',
                   'KILL_STAYS_DEACTIVATING': '1' if kill_stays_deactivating else '0'}
            with (state / 'lifecycle.lock').open('w') as lock:
                if lock_held:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(['bash', str(LIFECYCLE)], env=env,
                                        capture_output=True, timeout=6)
            killed = (cgroup / 'cgroup.kill').read_text().strip() == '1'
            actions = ((root / 'actions').read_text().splitlines()
                       if (root / 'actions').exists() else [])
            return (result.returncode, killed, actions,
                    (state / 'owned').exists(), (state / 'teardown-required').exists())

    def test_guard_loss_kills_before_owned_thaw_even_if_drain_disowned(self):
        self.assertEqual(self.run_stop(owned=True, drain_disowned=True),
                         (0, True, ['thaw'], False, True))

    def test_manual_freeze_kills_workers_without_thaw(self):
        self.assertEqual(self.run_stop(), (0, True, [], False, True))

    def test_ambiguous_freeze_is_not_thawed(self):
        self.assertEqual(self.run_stop(owned=True, pending=True),
                         (0, True, [], True, True))

    def test_incomplete_freeze_terminates_workers_without_claiming_thaw(self):
        self.assertEqual(self.run_stop(freezer='freezing', pending=True),
                         (0, True, [], False, True))

    def test_routine_unfrozen_stop_keeps_graceful_path(self):
        self.assertEqual(self.run_stop(freezer='running', guard='active'),
                         (0, False, [], False, False))

    def test_unfrozen_guard_loss_kills_workers(self):
        self.assertEqual(self.run_stop(freezer='running'),
                         (0, True, [], False, True))

    def test_blocking_runner_is_killed_before_owned_thaw(self):
        self.assertEqual(self.run_stop(owned=True, runner='deactivating'),
                         (0, True, ['kill', 'thaw'], False, True))

    def test_lock_wait_consumes_the_same_teardown_deadline(self):
        self.assertEqual(self.run_stop(lock_held=True),
                         (1, False, [], False, False))

    def test_signal_delivery_without_runner_stop_does_not_report_success(self):
        self.assertEqual(self.run_stop(owned=True, runner='deactivating',
                                       kill_stays_deactivating=True),
                         (1, True, ['kill'], True, True))


class StartGateTests(unittest.TestCase):
    def run_gate(self, marker='', freezer='running', lifecycle=True, guard=True,
                 clear_under_lock=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            if marker:
                (state / marker).touch()
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == is-active && $2 == --quiet ]]; then
  case "$3" in
    forgejo-runner-aggregate-lifecycle.service) [[ $LIFECYCLE_ACTIVE == 1 ]] ;;
    forgejo-runner-io-pressure-guard.service) [[ $GUARD_ACTIVE == 1 ]] ;;
    *) exit 2 ;;
  esac
elif [[ $1 == show && $2 == --property=FreezerState && $3 == --value && $4 == forgejobuilds.slice ]]; then
  printf '%s\\n' "$FREEZER_STATE"
else
  exit 2
fi
''')
            mock.chmod(0o755)
            env = {**os.environ, 'STATE_DIR': str(state), 'SYSTEMCTL_BIN': str(mock),
                   'GATE_TIMEOUT_SECONDS': '2', 'FREEZER_STATE': freezer,
                   'LIFECYCLE_ACTIVE': '1' if lifecycle else '0',
                   'GUARD_ACTIVE': '1' if guard else '0'}
            if clear_under_lock:
                with (state / 'lifecycle.lock').open('w') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    process = subprocess.Popen(['bash', str(GATE)], env=env,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    time.sleep(0.1)
                    (state / marker).unlink()
                process.communicate(timeout=6)
                return process.returncode, (state / marker).exists()
            result = subprocess.run(['bash', str(GATE)], env=env,
                                    capture_output=True, timeout=6)
            return result.returncode, bool(marker and (state / marker).exists())

    def test_clear_healthy_start_is_admitted(self):
        self.assertEqual(self.run_gate(), (0, False))

    def test_switch_start_during_owned_drain_is_skipped_without_mutation(self):
        self.assertEqual(self.run_gate(marker='drain-owned'), (1, True))

    def test_ambiguous_resume_is_skipped(self):
        self.assertEqual(self.run_gate(marker='resume-pending'), (1, True))

    def test_guard_can_clear_resume_intent_before_start_gate_observes_it(self):
        self.assertEqual(self.run_gate(marker='resume-pending', clear_under_lock=True),
                         (0, False))

    def test_owned_freeze_is_skipped(self):
        self.assertEqual(self.run_gate(marker='owned'), (1, True))

    def test_manual_freeze_is_skipped(self):
        self.assertEqual(self.run_gate(freezer='frozen'), (1, False))

    def test_unarmed_lifecycle_is_skipped_within_deadline(self):
        self.assertEqual(self.run_gate(lifecycle=False), (1, False))


if __name__ == '__main__':
    unittest.main()
