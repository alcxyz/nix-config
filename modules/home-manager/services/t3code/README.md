# T3 Code package selection

The headless service runs `pkgs.t3code`, the published upstream nightly from
the pinned `nix-packages` input. An explicit `services.t3code.package` override
still takes precedence.

Hourly discovery checks for newly published releases. Unchanged candidates
skip builds. Package and consumer validation still gate deployment.

Apply the configuration through the usual Home Manager activation. The restart
guard and the service-cgroup guard govern restarts, and downgrades remain
blocked. State left by the retired fork channels (`fork`, `fork-nightly`,
`fork-stable`) counts as a different channel, so moving such a host to upstream
is allowed even when the upstream version sorts lower.

## Restart guard

A managed restart (profile switch or Home Manager executable change) kills the
provider process behind every thread, including background shells, monitors,
subagents and scheduled wake-ups that a thread started and is waiting for. The
guard therefore counts *live work*, not only running turns, in each instance's
`userdata/statev2.sqlite` (the orchestrator database since upstream
`de34391427`) or `userdata/state.sqlite` (used by older builds, and a frozen copy
afterwards). The running build writes its
database on every event, so the more recently written of the two (database or
non-empty WAL, nanosecond mtime, chosen on every sample) is the live one; stale rows in
the other, for example from a crash before a channel switch, are ignored.
When the two were written within an hour of each other, or the older one
within the last hour, both count, so a channel switch or a stray write to
the frozen file fails closed; a write to the frozen file more than an hour
after the live one was last written is taken as the live file. The guard
counts:

- turns that are preparing, starting, running or waiting, and queued turns that
  are not held;
- provider threads that are active or still list pending background tasks
  (background commands, monitors, subagents and tasks). Delegated tasks are
  child threads with their own turns.

A restart proceeds only after that count stays at zero for
`restartGuard.settleSeconds`; otherwise the updater retries later (exit 75).
A database that exists but cannot be read counts as busy. T3's startup and
shutdown recovery clears stale active threads and rosters, so a crash does not
leave the guard busy forever. `T3CODE_ALLOW_ACTIVE_RESTART=1` bypasses the
guard for an intentional interruption. Work the database cannot show, such as
a wake-up scheduled inside the provider process of an otherwise idle thread,
is still interrupted; a T3 fix is needed for that.

Every restart performed by the profile switch or the guarded Home Manager
activation is appended to `services.t3code.restartLog`
(`~/.local/state/t3code/managed-restarts.log`: time, trigger, units, detail)
and logged to the journal; the units are listed before the restart and
recorded after it, even when one fails to come back, and a failed record
never blocks the restart. A Home Manager restart that finds T3 busy after the
unit reload, or runs inside a T3 unit, keeps its marker and lets the rest of
the activation finish; one that fails keeps the marker and fails the
activation. The next activation retries the units the marker names once the
guard reports idle, skipping units that restarted or were stopped after it
was written, and drops the marker when none is left. With `restartGuard.enable = false` Home Manager
restarts changed units itself, unguarded and unrecorded. The `t3code-restart-notice` Claude Code `SessionStart`
hook, installed by `programs.ai`, runs only inside a T3 unit's cgroup and
reports, once per session, that unit's restarts that happened after the
session's first transcript entry (`~/.local/state/t3code/notified/` remembers
what each session was told), so an agent learns which unit restarted and
when. The record is written after the restart, so a turn cut off mid-stream
is still older than it. T3 itself adds a note listing the cancelled background
work, and Claude Code reports background commands that did not finish before
the previous process ended. Codex sessions get only T3's note.

With `autoUpdate.enable`, T3 and its providers run from the
`~/.local/state/nix/profiles/ai-stack` profile instead (ADR-0077). Home Manager
seeds it on first deployment or when it holds another channel's bundle;
afterwards `t3code-auto-update` builds the `ai-stack-upstream` bundle from the
nix-packages `promoted` branch, which moves only after local configuration
validation (ADR-0080), and `t3code-ai-stack-switch` installs it, refusing same-channel downgrades and
restarting T3 only when the restart guard sees no live work. Neither runs Home
Manager activation. Roll
back with `nix-env --profile ~/.local/state/nix/profiles/ai-stack --rollback`
followed by `systemctl --user restart t3code` (and `t3code-<name>` for each
additional instance).

## Additional instances

`services.t3code.instances.<name>` runs another server as
`t3code-<name>.service` with its own port and state directory (default
`~/.t3-<name>`), for example to keep one group of projects out of the primary
sidebar:

```nix
services.t3code.instances.bn.port = 3774;
```

Instances share the primary server's package or AI stack profile, update timer
and restart guards. A package or profile change restarts every running
instance together, and only once none of them has live work; stopped
instances stay stopped.
Projects and threads do not move between instances, and T3's agent tools only
reach projects in their own instance. Open each new port in the host firewall
and give it its own edge route.
