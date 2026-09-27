#!/usr/bin/env python3
"""Check the DMS updater's temporary Git authentication with synthetic data."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "scripts/ci/run-dms-update-with-private-inputs.sh"


class PrivateInputAuthTests(unittest.TestCase):
    def test_scoped_helper_rewrite_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts/ci").mkdir(parents=True)
            (root / "scripts/update-inputs").mkdir()
            shutil.copy2(WRAPPER, root / "scripts/ci/run-dms-update-with-private-inputs.sh")
            stub = root / "scripts/update-inputs/update-dms-plugins.sh"
            stub.write_text(
                """#!/usr/bin/env python3
import json, os, pathlib, subprocess
def fill(protocol, host):
    result = subprocess.run(['git', 'credential', 'fill'],
        input=f'protocol={protocol}\\nhost={host}\\n\\n', text=True,
        capture_output=True, check=False, timeout=5)
    return result.returncode, result.stdout
def helper(protocol, host):
    command = subprocess.run(['git', 'config', '--global', '--get',
        'credential.https://git.alc.xyz.helper'], text=True,
        capture_output=True, check=True).stdout.strip()[1:]
    result = subprocess.run([command, 'get'],
        input=f'protocol={protocol}\\nhost={host}\\n\\n', text=True,
        capture_output=True, check=True)
    return result.returncode, result.stdout
url = subprocess.run(['git', 'remote', 'get-url', 'origin'], text=True,
    capture_output=True, check=True).stdout.strip()
good = fill('https', 'git.alc.xyz')
bad_host = helper('https', 'example.org')
bad_protocol = helper('http', 'git.alc.xyz')
pathlib.Path('result.json').write_text(json.dumps({
    'url': url, 'good': good, 'bad_host': bad_host,
    'bad_protocol': bad_protocol, 'auth_dir': str(pathlib.Path(os.environ['GIT_CONFIG_GLOBAL']).parent),
    'secret_in_env': 'DMS_PRIVATE_INPUT_TOKEN' in os.environ,
}))
"""
            )
            stub.chmod(0o700)
            subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
            subprocess.run(['git', 'remote', 'add', 'origin',
                            'ssh://git@git-ssh.alc.xyz/alcxyz/paperless-tools.git'],
                           cwd=root, check=True)
            env = os.environ.copy()
            env['DMS_PRIVATE_INPUT_TOKEN'] = 'synthetic-reader-token'
            result = subprocess.run(['bash', str(root / 'scripts/ci/run-dms-update-with-private-inputs.sh')],
                                    cwd=root, env=env, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('synthetic-reader-token', result.stdout + result.stderr)
            report = json.loads((root / 'result.json').read_text())
            self.assertEqual(report['url'], 'https://git.alc.xyz/alcxyz/paperless-tools.git')
            self.assertEqual(report['good'], [0, 'protocol=https\nhost=git.alc.xyz\nusername=token\npassword=synthetic-reader-token\n'])
            self.assertEqual(report['bad_host'][0], 0)
            self.assertNotIn('synthetic-reader-token', report['bad_host'][1])
            self.assertEqual(report['bad_protocol'][0], 0)
            self.assertNotIn('synthetic-reader-token', report['bad_protocol'][1])
            self.assertFalse(report['secret_in_env'])
            self.assertFalse(Path(report['auth_dir']).exists())


if __name__ == '__main__':
    unittest.main()
