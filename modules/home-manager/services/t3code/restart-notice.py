"""Claude Code SessionStart hook: report managed T3 Code restarts that interrupted this session.

A T3 restart kills the Claude Code process behind every thread, with its
background shells, monitors and subagents. T3 tells the next turn that the
server restarted, but not which unit or when. This hook runs only inside a T3
unit's cgroup, reads the restart log written by t3code-record-restart and
prints that unit's restarts that happened after the session's first
transcript entry and have not been reported to this session before. Its
stdout becomes session context.

Arguments: restart log path, directory remembering what each session was
told, cgroup file (/proc/self/cgroup), T3 unit names.
"""

import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_AGE = timedelta(days=7)


def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def owning_unit(cgroup_path, units):
    """The T3 unit whose cgroup this process runs in, or None."""
    try:
        with open(cgroup_path, encoding="utf-8", errors="replace") as cgroup:
            content = cgroup.read()
    except OSError:
        return None
    for unit in units:
        if re.search(r"(^|/)" + re.escape(unit) + r"(/|$)", content, re.MULTILINE):
            return unit
    return None


def first_activity(transcript_path):
    """Earliest transcript timestamp: the session existed from then on."""
    earliest = None
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                stamp = parse_time(entry.get("timestamp"))
                if stamp is None:
                    continue
                if earliest is None or stamp < earliest:
                    earliest = stamp
    except OSError:
        return None
    return earliest


def reported_until(marker):
    try:
        return parse_time(marker.read_text(encoding="utf-8").strip())
    except OSError:
        return None


def restarts(log_path, unit, after, now):
    found = []
    try:
        with open(log_path, encoding="utf-8", errors="replace") as log:
            for line in log:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 3:
                    continue
                stamp = parse_time(fields[0])
                if stamp is None or stamp <= after or stamp < now - MAX_AGE:
                    continue
                if unit not in fields[2].split():
                    continue
                found.append((stamp, fields[0], fields[1], fields[3] if len(fields) > 3 else ""))
    except OSError:
        return []
    return sorted(found)


def main():
    if len(sys.argv) < 5:
        return 0
    log_path, state_dir, cgroup_path = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    units = sys.argv[4:]
    unit = owning_unit(cgroup_path, units)
    if unit is None:
        return 0
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("source") == "clear":
        return 0
    transcript_path = payload.get("transcript_path")
    session_id = payload.get("session_id")
    if not isinstance(transcript_path, str) or not isinstance(session_id, str):
        return 0
    if not re.fullmatch(r"[A-Za-z0-9._-]+", session_id):
        return 0
    # The log is small and usually has nothing for this unit; read it before
    # parsing a possibly large transcript.
    now = datetime.now(timezone.utc)
    marker = state_dir / session_id
    after = reported_until(marker) or datetime.min.replace(tzinfo=timezone.utc)
    if not restarts(log_path, unit, after, now):
        return 0
    started = first_activity(transcript_path)
    if started is None:
        return 0
    if after < started:
        after = started
    found = restarts(log_path, unit, after, now)
    if not found:
        return 0
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        marker.write_text(found[-1][1] + "\n", encoding="utf-8")
    except OSError:
        pass
    lines = [f"T3 Code restart notice: {unit}, the server behind this session, restarted since this session started."]
    for _, stamp, trigger, detail in found:
        lines.append(f"- {stamp}: restarted by {trigger}" + (f" ({detail})" if detail else ""))
    lines.append(
        "If this session had background commands, monitors, subagents or scheduled wake-ups running at that time, they were killed and will not report back: check their results or rerun them. T3's own note lists the background work it had recorded; a wake-up scheduled inside the provider process is not recorded there."
    )
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
