"""Run generated endpoint setup against temporary, synthetic paired profiles."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

for case in json.loads(Path(sys.argv[1]).read_text()):
    with tempfile.TemporaryDirectory() as directory:
        home = Path(directory)
        profile = home / ".config/Moonlight Game Streaming Project/Moonlight.conf"
        profile.parent.mkdir(parents=True)
        original = "[hosts]\n1\\hostname=browser-fixture\n1\\localaddress=192.168.50.9\n1\\paired=true\n"
        profile.write_text(original)
        environment = {**os.environ, "HOME": str(home)}
        subprocess.run([case["command"]], env=environment, check=True)
        contents = profile.read_text()
        if case.get("unchanged"):
            assert contents == original
        else:
            values = dict(line.split("=", 1) for line in contents.splitlines() if "=" in line)
            assert values["1\\hostname"] == case["host"]
            assert values["1\\localaddress"] == case["local"]
            assert values["1\\manualaddress"] == case["local"]
            assert values["1\\remoteaddress"] == case["remote"]
            assert values["1\\paired"] == "true"
            if case["port"]:
                assert all(values["1\\" + key] == "48000" for key in ("localport", "manualport", "remoteport"))
            else:
                assert "1\\localport" not in values
        subprocess.run([case["command"]], env=environment, check=True)
        assert profile.read_text() == contents
print("Five generated endpoint setup cases passed, including migration and idempotence")
