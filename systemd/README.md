# systemd

A mechanism-level examination of how `systemd` actually works — from the kernel handing off to PID 1, through the dependency graph that replaces SysVinit's serial boot model, to the sandboxing primitives that constrain what a compromised service can actually do. Written as a complete reference, not a getting-started guide: each document builds directly on directives and mechanisms established in the ones before it, using one running example (`webapp.service`) that incrementally acquires dependencies, lifecycle directives, hardening, and scheduled companions across the series.

## Contents

**[01-Introduction.md](01-Introduction.md)**
What systemd is, the problem it replaced, the core design commitments, the eleven unit types, unit file anatomy, and a first worked service lifecycle.

**[02-Units-and-Dependencies.md](02-Units-and-Dependencies.md)**
The complete requirement- and ordering-directive reference, the transaction and job-merging algorithm, implicit dependencies, ordering-cycle detection, and the `systemd-analyze` diagnostic toolkit.

**[03-Service-Management.md](03-Service-Management.md)**
Every `Type=` value and how systemd determines a service has started, the `sd_notify`/watchdog protocol, the complete `Exec*=` lifecycle, `Restart=` policy, timeouts, and kill behavior.

**[04-Unit-Files.md](04-Unit-Files.md)**
The complete specifier reference, templated/instantiated units, the drop-in override mechanism, the full execution-context directive set, and the non-service unit types.

**[05-Boot-Process-and-Targets.md](05-Boot-Process-and-Targets.md)**
The full boot timeline from kernel handoff through the initramfs boundary to `default.target`, emergency/rescue paths, and the mirror-image shutdown sequence.

**[06-journald-and-Logging.md](06-journald-and-Logging.md)**
Journal file internals, the structured-field model, the complete `journalctl` query syntax, remote log shipping, and integrity verification.

**[07-Timers-and-Scheduled-Tasks.md](07-Timers-and-Scheduled-Tasks.md)**
`.timer` units as a `cron` replacement: calendar syntax, monotonic timers, missed-run handling, and thundering-herd controls.

**[08-Security-and-Hardening.md](08-Security-and-Hardening.md)**
The complete sandboxing directive family: filesystem namespacing, private namespaces, capability restriction, seccomp filtering, and cgroup-based resource control.

**[09-Troubleshooting.md](09-Troubleshooting.md)**
A systematic diagnostic methodology built around the `result=` field, consolidating every failure-tracing technique introduced across the series into one method.

**[10-References.md](10-References.md)**
A complete directive index, command index, and manual-page bibliography for the entire series, organized for lookup rather than linear reading.

## How to read this

In order, start to finish — each document assumes the ones before it, and none is written to stand alone on a first read. `10-References.md` §1.1 has shorter reading paths for narrower goals (security review, active incident, migrating from `cron`) if a full pass isn't what's needed right now.
