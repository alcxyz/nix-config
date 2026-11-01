#!/usr/bin/env python3
"""Run storage shell bodies with synthetic commands, without mounting anything."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class StorageTest(unittest.TestCase):
    def run_shell(self, script):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(
                ['bash', '-euo', 'pipefail', '-c', script], cwd=directory,
                text=True, capture_output=True, env=os.environ.copy(),
            )

    def test_pool_import_property_is_independent_of_root_dataset(self):
        body = Path('modules/nixos/services/storage-health-monitor/check-storage.sh').read_text()
        for readonly in ('off', 'on', 'error'):
            for root_mounted in ('yes', 'no'):
                for require_rw in ('true', 'false'):
                    with self.subTest(readonly=readonly, root_mounted=root_mounted, require_rw=require_rw):
                        # Issues are recorded by the caller, not returned from the function.
                        result = self.run_shell(textwrap.dedent('''\
                            report=report
                            issues=0
                            record_issue() { issues=$((issues + 1)); }
                            zpool() {
                              if [ "$1" = list ]; then echo '10 100000 ONLINE';
                              elif [ "$readonly" = error ]; then return 1;
                              else echo "$readonly"; fi
                            }
                            zfs() { echo queried >&2; [ "$root_mounted" = yes ] && echo off; }
                        ''') + f'\nreadonly={readonly}\nroot_mounted={root_mounted}\n' + body + f'\ncheck_storage pool zpool synthetic 80 0 {require_rw}\necho "$issues"\n')
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stderr, "")
                        self.assertEqual(result.stdout.splitlines()[-1], '1' if require_rw == 'true' and readonly != 'off' else '0')

    def test_repository_mount_on_parent_filesystem_and_source_guard(self):
        module = Path('modules/nixos/services/snapshot-restic-home/default.nix').read_text()
        guard = module.split("  repositoryGuard = ''\n", 1)[1].split("\n  '';", 1)[0]
        guard = guard.replace('${lib.escapeShellArg cfg.repositoryMountPoint}', '"$mountpoint"')
        guard = guard.replace('${lib.escapeShellArg cfg.repositoryDataset}', '"$dataset"')
        mount = module.split('      if ! findmnt', 1)[1].split('      ${repositoryGuard}', 1)[0]
        mount = 'if ! findmnt' + mount
        for state in ('parent', 'correct', 'wrong-source'):
            with self.subTest(state=state):
                result = self.run_shell(textwrap.dedent('''\
                    dataset=synthetic/repository
                    mountpoint=/synthetic/repository
                    zfs() { [ "$*" = "mount $dataset" ]; echo mounted; state=correct; }
                    findmnt() {
                      case "$*" in
                        *--mountpoint*) [ "$state" != parent ] ;;
                        *'-o SOURCE'*)
                          case "$state" in correct) echo "$dataset";; parent) echo /dev/parent;; *) echo wrong/dataset;; esac ;;
                        *'-o TARGET'*) if [ "$state" = parent ]; then echo /; else echo "$mountpoint"; fi ;;
                        *--target*) return 0 ;;
                        *) return 93 ;;
                      esac
                    }
                ''') + f'\nstate={state}\n' + mount + guard)
                self.assertEqual(result.returncode == 0, state != 'wrong-source', result.stderr)
                self.assertEqual('mounted' in result.stdout, state == 'parent')


if __name__ == '__main__':
    unittest.main()
