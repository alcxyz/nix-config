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

A managed restart (profile switch or Home Manager command change) kills the
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

The state directory each running instance was started with (read from its
process, since a reload already shows the new unit) counts too, so a
changed `baseDir` cannot hide the live work of an instance still running from
the old one.

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

Before a Home Manager activation reloads systemd, it compares each running
instance's loaded command line with the unit it has just linked. Without the
profile, a changed command must pass the restart guard or the activation is
deferred, as for an executable change. With the profile, the executable path
never changes, so a changed command (for example a new wrapper or port) only
writes the restart marker: the instances restart once the guard reports idle,
and otherwise at a later activation. The activation itself is never blocked.

## Session environment

Every instance starts through `t3code-session-env`, which sources Home
Manager's `hm-session-vars.sh` from the profile before it runs `t3`. The units
run it through the stable link `~/.local/state/t3code/bin/t3code-session-env`,
so a rebuild of the wrapper alone does not change their command or restart T3. The user
manager starts T3 at boot, before the graphical login imports those variables,
so without it agent shells would lack `home.sessionVariables` and
`home.sessionPath` until the next restart. The file is read again at every
start, even when the login already imported an older copy, so a restart picks
up the current values. A missing file is logged and T3 starts without it.

With `programs.ai.agentForge` enabled, the wrapper then gives agent sessions
the agent forge account (ADR-0081): `FORGEJO_API_TOKEN_FILE` names its token,
and `GIT_CONFIG_*` entries, appended to any already set, send pushes to the
forge over HTTPS with only its credential helper. Login shells keep the
operator's account. Since the link does not change, running instances pick
this up at their next restart.

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

## Preview browser

T3 renders previews with a pinned Chrome headless shell that it downloads into
each base directory, and that download cannot find its libraries on NixOS.
The nix-packages T3 package bundles the same build with its libraries linked
from the store. Before each instance starts, `t3code-link-preview-browser`
links that build into the instance's `tools/chrome-headless-shell` directory,
where T3 treats it as installed ([ADR-0092](../../../../docs/adr/0092-t3-preview-browser-from-nix.md)).
A T3 package without the bundle leaves T3's own download in place.
