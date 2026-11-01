#!/usr/bin/env python3
"""Run just with a harmless nix stub and inspect the requested deploy target."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / 'nix'
    stub.write_text('#!' + shutil.which('bash') + '\nprintf "%s\\n" "$@" > "$RECIPE_ARGS"\n')
    stub.chmod(0o755)
    arguments = root / 'arguments'
    env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', RECIPE_ARGS=str(arguments))
    subprocess.run(['just', '--justfile', 'justfile', 'home', 'remote-example'], env=env, check=True)
    assert arguments.read_text().splitlines() == ['run', '.#nix-deploy', '--', '--hm', 'remote-example']
print('Home recipe routes the requested target through deploy')
