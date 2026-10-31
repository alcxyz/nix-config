# ADR-0096: Bound the first-timer freshness exception after reboot

**Status:** Accepted
**Date:** 2026-10-15
**Amended:** 2026-10-31, the Podman store reset replaces the idle cleanup and its completion fence as the boot-timer consumer ([#916](https://git.alc.xyz/alcxyz/nix-config/issues/916))
**History:** [replaced text](archive/0096-bounded-first-timer-freshness-history.md)
**Applies to:** storage health recent-success checks and timer consumers

## Context

Durable success survives reboot, but its wall-clock age includes downtime.
The first scheduled check can therefore be pending while earlier valid success
is already stale. Increasing the ordinary age limit cannot accommodate arbitrary
downtime. The previous missing-marker exception checked only an active timer
with no last trigger, allowing an unscheduled or overdue timer indefinite grace.

[ADR-0059](0059-file-selective-home-backup-and-storage-monitoring.md) requires
bounded first-run exceptions without inventing success. Runner admission and
the Podman store reset remain governed by
[ADR-0105](0105-offline-podman-store-reset.md).

## Decision

For consumers opting into `allowPendingFirstTimer`, apply the same bounded
exception to missing success and well-formed, non-future stale success. Check
current failure first, validate any marker, and retain ordinary freshness for a
recent success. Never change the marker merely to apply the exception.

The exception requires a loaded matching timer in active/waiting state, no
current-boot trigger, and an inactive service with no execution this boot. It
expires at the earlier of:

- the actual next deadline plus the timer's accuracy window;
- `pendingFirstTimerMaximumAgeSeconds` since boot, including suspend.

Require available, typed numeric deadline and trigger metadata. Use the
appropriate realtime or monotonic clock for each deadline. If a timer has both,
use the earlier expiry. Systemd already includes its selected randomized delay
in the next deadline; add only accuracy. A persistent calendar timer's restored
wall-clock trigger from an earlier boot does not count as a current-boot trigger.

The generic cap defaults to the consumer's existing `maximumAgeSeconds`.
Explicit caps for public boot timers cover their first schedule, maximum random
delay and accuracy: the Podman store reset 1320 seconds, namespace audit 180 seconds and orphan
check 390 seconds. A timer restart or a later deadline cannot extend the boot
cap. There is no exception after the first trigger, including during the first
service execution. A successful check then restores ordinary freshness through
the existing durable recorder.

Current service failures continue to override success. Invalid markers or metadata, inactive timers,
missed deadlines and expired caps cannot receive the exception. Consumers that
do not opt in retain ordinary success-age checks. Private consumers and alert
wiring remain in their owning repository.

## Alternatives Considered

- Increase the ordinary success-age limit: weakens steady-state detection and
  still cannot cover arbitrary downtime.
- Trust active, untriggered timers indefinitely: hides missed first triggers.
- Trust only the next deadline: restart or rescheduling can keep moving it.
- Use only a boot-age cap: can hide a missed earlier deadline until the cap.
- Record additional durable shutdown or boot state: could distinguish prior
  staleness or repeated reboots, but introduces another lifecycle contract that
  is unnecessary for this bounded alert-freshness exception.

## Consequences

Arbitrarily old but valid success can receive a bounded post-reboot exception,
even if it was stale before shutdown. The timestamp alone cannot establish its
freshness at shutdown. Each reboot can open a new bounded window. Reboot is
never recorded as successful work, and runner admission is unchanged.

Disabled or overdue timers cannot acquire grace merely by remaining loaded.
The cap also bounds suspend and timer restarts. Timers with later first schedules
must configure an appropriate cap explicitly. The real-systemd lifecycle test
and deterministic matrix verify alert semantics; they do not qualify deployment
or host-specific store resets.

Tracks [#565](https://git.alc.xyz/alcxyz/nix-config/issues/565).
