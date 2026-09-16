#!/usr/bin/env python3
"""Synthetic freeze ownership tests; never contact systemd or Docker."""
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

GUARD = Path(sys.argv.pop(1)).resolve()


class GuardTests(unittest.TestCase):
    def run_guard(self, values, initial='running', owned=False, pending=False,
                  fail_action='', fail_count='0', fail_state='', action_delay='0',
                  transition_timeout='120', admission=False, drain_owned=False,
                  drain_pending=False, resume_pending=False, runner_state='active',
                  runner_enabled='enabled', runner_load='loaded', runner_result='success',
                  stop_state='inactive', fail_runner_action='', runner_generation='123',
                  drain_generation=None, stop_generation='0'):
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
            (root / 'actual').write_text(initial)
            (root / 'runner-active').write_text(runner_state)
            (root / 'runner-enabled').write_text(runner_enabled)
            (root / 'runner-load').write_text(runner_load)
            (root / 'runner-result').write_text(runner_result)
            (root / 'runner-generation').write_text(runner_generation)
            (root / 'pressure').write_text('\n'.join(map(str, values)) + '\n')
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == show ]]; then
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
                   'FAIL_RUNNER_ACTION': fail_runner_action}
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


if __name__ == '__main__':
    unittest.main()
