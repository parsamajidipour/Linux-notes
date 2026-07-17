# References

A consolidated bibliography, complete directive index, command index, and task-based quick-lookup for the entire nine-document series that precedes this one. Where each of `01-Introduction.md` through `09-Troubleshooting.md` covered its own subject in depth and cited its own narrow set of manual pages, this document is the single place to look something up without already knowing which of the nine documents covers it — every directive, every command, and every manual page named anywhere in this series, cross-referenced back to its exact origin.

This document is deliberately structured differently from the nine that precede it. It contains no worked examples, no exercises, and no anti-patterns of its own — those belong to the documents that actually teach the mechanisms in question. What follows is purely an index: a map of the territory the rest of this series already covered, built so that "where did we cover `RestrictNamespaces=`" or "which manual page documents calendar syntax" can be answered by lookup rather than by re-reading nine documents in sequence.

---

## 1. Series Map

A one-paragraph summary of each document, for orientation before diving into the indexes below.

**`01-Introduction.md`** — What systemd is, the problem it replaced (SysVinit's serial, dependency-blind boot model), the core design commitments (declarative units, dependency graphs, activation mechanisms, cgroup-based tracking), the eleven unit types, unit file anatomy and location precedence, and a first, minimal worked service lifecycle.

**`02-Units-and-Dependencies.md`** — The complete requirement-class (`Wants=`, `Requires=`, `BindsTo=`, and the rest) and ordering-class (`Before=`/`After=`) directive reference, the transaction and job-merging algorithm, implicit default dependencies, ordering-cycle detection, `systemctl list-dependencies`, and the full `systemd-analyze` boot-diagnostic toolkit.

**`03-Service-Management.md`** — Every `Type=` value and precisely how systemd determines a service has started, the `sd_notify`/watchdog protocol, the complete `Exec*=` lifecycle, `Restart=` policy and start-rate limiting, timeouts, kill behavior, and `systemd-run` for transient services.

**`04-Unit-Files.md`** — The complete specifier reference, templated/instantiated units in full, the drop-in override mechanism, the complete `systemd.exec(5)` execution-context directive set, `[Unit]`/`[Install]` sections comprehensively, and the non-service unit types (`.mount`, `.automount`, `.swap`, `.path`, `.device`).

**`05-Boot-Process-and-Targets.md`** — The full boot timeline from kernel handoff through the initramfs boundary to `default.target`, generators, `basic.target`, `multi-user.target`/`graphical.target`, emergency and rescue targets, kernel command-line parameters, and the mirror-image shutdown sequence.

**`06-journald-and-Logging.md`** — Journal file internals, persistence and rotation configuration, the complete structured-field model, the full `journalctl` query syntax, cross-unit/cross-boot correlation, syslog forwarding, remote journal shipping, verification and sealing, rate limiting, and the message catalog.

**`07-Timers-and-Scheduled-Tasks.md`** — `.timer` units as a `cron` replacement: the complete calendar-event grammar, the monotonic timer family, `Persistent=` missed-run handling, precision and thundering-herd controls, timer-to-service pairing, and `systemctl list-timers`/`systemd-analyze calendar`.

**`08-Security-and-Hardening.md`** — The complete sandboxing directive family: filesystem namespacing, the private-namespace family, privilege restriction and Linux capabilities, seccomp-based system-call filtering, memory/execution protections, cgroup-v2 resource control, `DynamicUser=` in depth, and `systemd-analyze security`.

**`09-Troubleshooting.md`** — A consolidated diagnostic methodology built around the `result=` field taxonomy, with dedicated branches for dependency cascades, service-level failures, boot failures, logging gaps, timer problems, hardening-induced failures, and OOM kills.

### 1.1 Reading Paths for Different Readers

The nine documents were written to be read in sequence — each genuinely depends on directives and mechanisms established in the ones before it, and this series does not attempt to be independently readable out of order for a first pass. That said, a reader returning to this series with a specific, narrower goal in mind can reasonably follow one of the following shorter paths, treating the remaining documents as reference material to consult only when a specific cross-reference points there:

- **Coming from `cron`, want to modernize scheduled tasks specifically:** `01` (for vocabulary) → `02` §§1–3 (enough of the dependency model to understand `Requires=`/`After=` on a triggered service) → `03` §2.3 (`Type=oneshot`) → `07` in full.
- **Writing a new application service from scratch:** `01` → `02` → `03` → `04` §§1–6 → `08` §§1, 2, 4, 10 (the highest-value hardening directives, per that document's own Stage 1).
- **Doing a security review of existing units:** `08` in full, using its own cross-references back into `02`–`04` only as needed to understand a specific directive's interaction with the broader graph or execution model.
- **On-call, actively debugging a production incident:** `09` §20 (the fast-path checklist) first, falling back to `09`'s full method, using this document's Section 5 task-based lookup to jump directly to whichever earlier document a specific `result=` category points toward.
- **Responsible for boot-time performance on a fleet of machines:** `02` §10 → `05` in full → `09` §8.

---

## 2. Complete Directive Index

Every `[Unit]`, `[Service]`, `[Timer]`, `[Install]`, `[Mount]`, `[Path]`, `[Journal]`, and `systemd.exec(5)`-family directive named anywhere in this series, alphabetically, with the document and section where it was introduced or most fully treated.

| Directive | Document — Section |
|---|---|
| `AccuracySec=` | 07 §6.1 |
| `Alias=` | 04 §6 |
| `AllowIsolate=` | 02 §8 |
| `Also=` | 02 §5.5; 04 §6 |
| `AmbientCapabilities=` | 08 §4.3 |
| `Before=` / `After=` | 02 §3.1 |
| `BindsTo=` | 02 §2.4 |
| `CacheDirectory=` | 04 §4.7 |
| `CapabilityBoundingSet=` | 08 §4.2 |
| `Conflicts=` | 02 §2.6 |
| `ConditionFirstBoot=` | 05 §7.2 |
| `Condition*=` / `Assert*=` (general) | 03 §11 |
| `Compress=` (journald.conf) | 06 §2.4 |
| `CPUAffinity=` | 04 §4.4 |
| `CPUQuota=` / `CPUWeight=` | 08 §7.2 |
| `CPUSchedulingPolicy=` | 04 §4.4 |
| `DefaultDependencies=` | 02 §4 |
| `DefaultInstance=` | 04 §2.4 |
| `Description=` / `Documentation=` | 04 §5 |
| `DynamicUser=` | 04 §4.1; 08 §8 (full depth) |
| `EnvironmentFile=` | 03 §11; 04 §4.3 |
| `Environment=` | 03 §11; 04 §4.3 |
| `ExecCondition=` | 03 §4.6 |
| `ExecReload=` | 03 §4.5 |
| `ExecStartPost=` | 03 §4.2 |
| `ExecStartPre=` | 03 §4.1 |
| `ExecStop=` | 03 §4.3 |
| `ExecStopPost=` | 03 §4.4 |
| `FailureAction=` / `SuccessAction=` | 03 §9 |
| `FailureActionExitStatus=` | 03 §9 |
| `FinalKillSignal=` | 03 §8.2 |
| `ForwardToSyslog=` / `ForwardToKMsg=` / `ForwardToConsole=` / `ForwardToWall=` | 06 §8 |
| `Group=` / `SupplementaryGroups=` | 04 §4.1 |
| `IgnoreOnIsolate=` | 02 §5.8 |
| `InaccessiblePaths=` | 08 §2.3 |
| `IOReadBandwidthMax=` / `IOWriteBandwidthMax=` | 08 §7.3 |
| `IOSchedulingClass=` / `IOSchedulingPriority=` | 04 §4.4 |
| `IOWeight=` | 08 §7.3 |
| `JoinsNamespaceOf=` | 02 §5.4; 04 §4.9 (context) |
| `KillMode=` | 03 §8.1 |
| `KillSignal=` | 03 §8.2 |
| `LockPersonality=` | 08 §6.2 |
| `LogNamespace=` | 06 §12 |
| `LogsDirectory=` | 04 §4.7 |
| `LimitNOFILE=` and the `Limit*=` family | 04 §4.5 |
| `MaxFileSec=` | 06 §3.2 |
| `MaxRetentionSec=` | 06 §3.2 |
| `MemoryDenyWriteExecute=` | 08 §6.1 |
| `MemoryHigh=` / `MemoryMax=` | 08 §7.1 |
| `Nice=` | 04 §4.4 |
| `NoNewPrivileges=` | 08 §4.1 |
| `NotifyAccess=` | 03 §2.5, §3.4 |
| `OnActiveSec=` | 07 §3.3 |
| `OnBootSec=` / `OnStartupSec=` | 07 §3.1–3.2 |
| `OnCalendar=` | 07 §4 |
| `OnFailure=` / `OnSuccess=` | 02 §5.2 |
| `OnUnitActiveSec=` / `OnUnitInactiveSec=` | 07 §3.4 |
| `OOMScoreAdjust=` | 04 §4.8 |
| `PartOf=` | 02 §2.5 |
| `PassEnvironment=` / `UnsetEnvironment=` | 04 §4.3 |
| `Persistent=` | 07 §5 |
| `PIDFile=` | 03 §2.2 |
| `PrivateDevices=` | 08 §3.1 |
| `PrivateNetwork=` | 08 §3.2 |
| `PrivateTmp=` | 04 §4.9; 08 §3 (family) |
| `PrivateUsers=` | 08 §3.3 |
| `ProtectClock=` / `ProtectHostname=` | 08 §3.7 |
| `ProtectControlGroups=` | 08 §3.6 |
| `ProtectHome=` | 08 §2.2 |
| `ProtectKernelLogs=` | 08 §3.5 |
| `ProtectKernelTunables=` / `ProtectKernelModules=` | 08 §3.4 |
| `ProtectSystem=` | 08 §2.1 |
| `PropagatesReloadTo=` / `ReloadPropagatedFrom=` | 02 §5.3 |
| `RandomizedDelaySec=` | 07 §6.2 |
| `RateLimitIntervalSec=` / `RateLimitBurst=` | 06 §11 |
| `ReadOnlyPaths=` / `ReadWritePaths=` | 08 §2.3 |
| `RefuseManualStart=` / `RefuseManualStop=` | 02 §5.7 |
| `RemainAfterExit=` | 03 §2.3, §10 |
| `RemoveIPC=` | 08 §4.5 |
| `RequiredBy=` | 02 §6 |
| `Requires=` | 02 §2.2 |
| `RequiresMountsFor=` | 02 §5.1 |
| `Requisite=` | 02 §2.3 |
| `RestrictAddressFamilies=` | 08 §6.6 |
| `RestrictNamespaces=` | 08 §6.4 |
| `RestrictRealtime=` | 08 §6.3 |
| `RestrictSUIDSGID=` | 08 §6.5 |
| `Restart=` | 03 §5.1 |
| `RestartSec=` / `RestartSteps=` / `RestartMaxDelaySec=` | 03 §5.2 |
| `RootDirectory=` / `RootImage=` | 04 §4.2; 08 §2.4 |
| `RuntimeDirectory=` | 04 §4.7 |
| `RuntimeMaxUse=` / `SystemMaxUse=` / `SystemKeepFree=` | 06 §3.2 |
| `RuntimeWatchdogSec=` / `RebootWatchdogSec=` | 05 §9.2 |
| `SendSIGKILL=` | 03 §8.3 |
| `Slice=` | 02 §12 |
| `SourcePath=` | 04 §5 |
| `StandardOutput=` / `StandardError=` | 04 §4.6 |
| `StartLimitAction=` | 03 §6 |
| `StartLimitIntervalSec=` / `StartLimitBurst=` | 03 §6 |
| `StateDirectory=` | 04 §4.7 |
| `Storage=` (journald.conf) | 06 §3.1 |
| `StopWhenUnneeded=` | 02 §5.6 |
| `SyslogIdentifier=` / `SyslogFacility=` / `SyslogLevelPrefix=` | 04 §4.6 |
| `SystemCallArchitectures=` | 08 §5.3 |
| `SystemCallErrorNumber=` | 08 §5.2 |
| `SystemCallFilter=` | 08 §5.2 |
| `TasksMax=` | 08 §7.4 |
| `TimeoutAbortSec=` | 03 §7.3 |
| `TimeoutSec=` | 03 §7.4 |
| `TimeoutStartSec=` | 03 §7.1 |
| `TimeoutStopSec=` | 03 §7.2 |
| `Type=` (service) | 03 §2 (all values) |
| `UMask=` | 04 §4.2 |
| `Unit=` (timer/path) | 04 §7.4; 07 §7 |
| `User=` | 04 §4.1 |
| `WakeSystem=` | 07 §8 |
| `WantedBy=` | 02 §6 |
| `WatchdogSec=` | 03 §3.3 |
| `WatchdogSignal=` | 03 §8.4 |
| `What=` / `Where=` (mount) | 04 §7.1 |
| `WorkingDirectory=` | 04 §4.2 |

### 2.1 The Same Index, by Category

The alphabetical listing above is the fastest lookup when a directive's name is already known. The following groups the same directives by functional category, useful when the question is instead "what tools exist for X" — each entry cross-references back to the alphabetical table's own document/section rather than repeating it.

**Requirement and ordering (the dependency graph):** `Wants=`, `Requires=`, `Requisite=`, `BindsTo=`, `PartOf=`, `Conflicts=`, `Before=`/`After=`, `RequiresMountsFor=`, `DefaultDependencies=` — all `02`.

**Reactive triggers and propagation:** `OnFailure=`/`OnSuccess=`, `PropagatesReloadTo=`/`ReloadPropagatedFrom=`, `JoinsNamespaceOf=` — `02`.

**Installation-time enablement:** `WantedBy=`, `RequiredBy=`, `Also=`, `Alias=`, `DefaultInstance=` — `02` §6, `04` §§2.4, 6.

**Service readiness and lifecycle:** `Type=` (all values), `NotifyAccess=`, `ExecStartPre=`/`ExecStartPost=`/`ExecStop=`/`ExecStopPost=`/`ExecReload=`/`ExecCondition=`, `RemainAfterExit=` — `03`.

**Automatic recovery:** `Restart=`, `RestartSec=`/`RestartSteps=`/`RestartMaxDelaySec=`, `StartLimitIntervalSec=`/`StartLimitBurst=`/`StartLimitAction=` — `03` §§5–6.

**Timeouts and termination:** `TimeoutStartSec=`/`TimeoutStopSec=`/`TimeoutAbortSec=`/`TimeoutSec=`, `KillMode=`/`KillSignal=`/`FinalKillSignal=`/`SendSIGKILL=`/`WatchdogSignal=` — `03` §§7–8.

**Identity and execution context:** `User=`/`Group=`/`SupplementaryGroups=`/`DynamicUser=`, `WorkingDirectory=`, `UMask=`, `Environment=`/`EnvironmentFile=`/`PassEnvironment=`/`UnsetEnvironment=` — `04` §4.

**Scheduling priority and resource limits (rlimit-based):** `Nice=`, `IOSchedulingClass=`/`IOSchedulingPriority=`, `CPUSchedulingPolicy=`, `CPUAffinity=`, the `Limit*=` family — `04` §§4.4–4.5.

**Managed directories:** `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` — `04` §4.7.

**Output routing:** `StandardOutput=`/`StandardError=`, `SyslogIdentifier=`/`SyslogFacility=`/`SyslogLevelPrefix=` — `04` §4.6.

**Filesystem sandboxing:** `ProtectSystem=`, `ProtectHome=`, `ReadOnlyPaths=`/`ReadWritePaths=`/`InaccessiblePaths=`, `RootDirectory=`/`RootImage=` — `08` §2.

**Private namespaces:** `PrivateTmp=`, `PrivateDevices=`, `PrivateNetwork=`, `PrivateUsers=`, `ProtectKernelTunables=`/`ProtectKernelModules=`/`ProtectKernelLogs=`/`ProtectControlGroups=`/`ProtectClock=`/`ProtectHostname=` — `04` §4.9, `08` §3.

**Privilege and capability restriction:** `NoNewPrivileges=`, `CapabilityBoundingSet=`, `AmbientCapabilities=`, `RemoveIPC=` — `08` §4.

**System-call and memory restriction:** `SystemCallFilter=`/`SystemCallErrorNumber=`/`SystemCallArchitectures=`, `MemoryDenyWriteExecute=`, `LockPersonality=`, `RestrictRealtime=`/`RestrictNamespaces=`/`RestrictSUIDSGID=`/`RestrictAddressFamilies=` — `08` §§5–6.

**cgroup resource control:** `MemoryMax=`/`MemoryHigh=`, `CPUQuota=`/`CPUWeight=`, `IOWeight=`/`IOReadBandwidthMax=`/`IOWriteBandwidthMax=`, `TasksMax=`, `Slice=` — `02` §12, `08` §7.

**Journal configuration:** `Storage=`, `SystemMaxUse=`/`SystemKeepFree=`/`RuntimeMaxUse=`/`MaxRetentionSec=`/`MaxFileSec=`, `Compress=`, `ForwardToSyslog=`/`ForwardToKMsg=`/`ForwardToConsole=`/`ForwardToWall=`, `RateLimitIntervalSec=`/`RateLimitBurst=`, `LogNamespace=` — `06`.

**Timer scheduling:** `OnCalendar=`, `OnBootSec=`/`OnStartupSec=`/`OnActiveSec=`/`OnUnitActiveSec=`/`OnUnitInactiveSec=`, `Persistent=`, `AccuracySec=`/`RandomizedDelaySec=`, `Unit=` (timer context), `WakeSystem=` — `07`.

**Boot and system-manager level (not per-unit):** `RuntimeWatchdogSec=`/`RebootWatchdogSec=` (`system.conf`), `ConditionFirstBoot=` — `05`.

---

## 3. Complete Command Index

Every command-line tool and its most significant flags/subcommands used across the series.

### 3.1 `systemctl`

| Invocation | Document — Section |
|---|---|
| `start` / `stop` / `restart` / `reload` | 01 §10 |
| `enable` / `disable` / `mask` | 01 §10 |
| `status` / `show` / `cat` | 01 §10; 09 §2.2 (full field-by-field read) |
| `is-active` / `is-enabled` / `is-failed` | 01 §10; 09 §2 |
| `list-units` / `list-unit-files` | 01 §10 |
| `daemon-reload` | 01 §10 |
| `list-dependencies` [`--reverse`, `--all`, `--plain`] | 02 §9 |
| `isolate` | 02 §8 |
| `kill` / `reset-failed` / `set-property` | 03 §11 |
| `edit` [`--full`, `--stdin`] / `revert` | 04 §3.4–3.5 |
| `get-default` / `set-default` | 05 §6 |
| `poweroff` / `reboot` / `kexec` | 05 §11.3 |
| `list-timers` [`--all`] | 07 §9 |
| `--failed` | 09 §18a |

### 3.2 `journalctl`

| Invocation | Document — Section |
|---|---|
| `-u`, `-p`, `--since`/`--until`, `-b` | 06 §5.1–5.2 |
| `FIELD=value`, `+` (OR override) | 06 §5.3 |
| `-o json` / `-o verbose` / `-o cat` | 06 §5.4 |
| `-f`, `-n`, `-e`, `-r` | 06 §5.5 |
| `--grep` | 06 §5.6 |
| `-x` (catalog explanations) | 06 §5.7 |
| `-k` (kernel messages) | 06 §7 |
| `--show-cursor` / `--after-cursor` | 06 §6.3 |
| `--verify` / `--setup-keys` (FSS) | 06 §10 |
| `--vacuum-size` / `--vacuum-time` / `--vacuum-files` | 06 §3.4 |
| `--rotate` | 06 §3.3 |
| `--namespace=` | 06 §12 |
| `-D` (explicit journal directory) | 06 §9.1 |
| `--list-boots` | 06 §5.2 |

### 3.3 `systemd-analyze`

| Subcommand | Document — Section |
|---|---|
| `verify` | 02 §7.2 |
| `dot` | 02 §7.2 |
| `blame` | 02 §10.2 |
| `critical-chain` | 02 §10.3 |
| `plot` | 02 §10.4 |
| `dump` | 02 §10.5 |
| `time` | 05 §9 |
| `calendar` [`--iterations=`] | 07 §10 |
| `security` [`--json=`] | 08 §9 |

### 3.4 Other Tools

| Tool | Purpose | Document — Section |
|---|---|---|
| `systemd-run` [`--unit=`, `--scope`, `--on-calendar=`, `--on-active=`] | Transient units, ad hoc scheduling | 03 §14; 07 §9.2 |
| `systemd-escape` [`--path`, `--template=`, `--unescape`] | Unit-name escaping | 04 §2.2, §8.6 |
| `systemd-cat` | Structured logging from shell scripts | 06 §4.4 |
| `systemd-cgls` / `systemd-cgtop` | cgroup tree inspection | 01 §9; 03 §13.1 |
| `systemd-inhibit` [`--list`] | Shutdown inhibitor locks | 05 §11.4 |
| `systemd-firstboot` | First-boot provisioning | 05 §7.2 |
| `systemd-journal-upload` / `systemd-journal-remote` | Native remote journal shipping | 06 §9 |
| `strace` (non-native, integrated via `systemd-run`) | Syscall-level diagnosis | 09 §14 |
| `hostnamectl` / `timedatectl` / `loginctl` / `networkctl` | Satellite-daemon CLIs | 01 §3 (component table) |
| `dot` (Graphviz, external) | Rendering `systemd-analyze dot` output | 02 §7.2 |

---

## 4. Manual Page Bibliography

Organized by category rather than alphabetically, since a reader looking for "everything about execution context" is better served by a grouped list than a scattered alphabetical one.

### 4.1 Core Unit and Dependency Model

- `systemd.unit(5)` — `[Unit]`/`[Install]` sections, specifiers, general syntax — 02, 04
- `systemd.special(7)` — well-known target units — 02, 05
- `systemd.syntax(7)` — the formal unit-file grammar — 04

### 4.2 Unit Types

- `systemd.service(5)` — 03, 04
- `systemd.socket(5)` — 02 §11
- `systemd.mount(5)` / `systemd.automount(5)` — 04 §7.1–7.2
- `systemd.swap(5)` — 04 §7.3
- `systemd.path(5)` — 04 §7.4
- `systemd.device(5)` — 04 §7.5
- `systemd.timer(5)` — 07
- `systemd.time(7)` — calendar/time-span grammar — 07 §4

### 4.3 Execution, Security, and Resource Control

- `systemd.exec(5)` — execution context and sandboxing directives — 04, 08
- `systemd.kill(5)` — kill-related directive reference — 03 §8
- `systemd.resource-control(5)` — cgroup-based resource control — 08 §7
- `capabilities(7)` — Linux capabilities — 08 §4
- `seccomp(2)` — the kernel facility underlying `SystemCallFilter=` — 08 §5
- `user_namespaces(7)` — underlying `PrivateUsers=` — 08 §3.3

### 4.4 Boot and Process Management

- `bootup(7)` — the canonical boot-sequence reference — 05
- `dracut(8)` / `mkinitcpio(8)` — initramfs assembly — 05 §2.2
- `kernel-command-line(7)` — boot parameter reference — 05 §10

### 4.5 Logging

- `systemd-journald.service(8)` / `journald.conf(5)` — 06
- `journalctl(1)` — 06
- `systemd.journal-fields(7)` — standard structured fields — 06 §4
- `sd_journal_send(3)` — custom structured logging API — 06 §4.3
- `systemd-journal-remote(8)` / `systemd-journal-upload(8)` — 06 §9
- `catalog(7)` — message catalog format — 06 §12

### 4.6 Notification and Supervision

- `sd_notify(3)` — the `Type=notify` protocol — 03 §3
- `systemd-notify(1)` — shell-callable notify tool — 03 §3.2

### 4.7 Diagnostic Tools

- `systemctl(1)` — 01 and throughout
- `systemd-analyze(1)` — 02, 05, 07, 08, 09

---

## 5. Master Glossary

Each of `02` through `09` closed with its own glossary, scoped to that document's own subject matter. The following consolidates the terms most load-bearing across the series as a whole — ones a reader is likely to encounter again in a later document after first meeting them in an earlier one — rather than reproducing every individual document's full glossary verbatim.

**Unit** — a loaded, static configuration object (`.service`, `.target`, `.timer`, and the rest). 01, 02.
**Job** — a pending or in-progress operation (start/stop/reload) against a specific unit. 02 §1.
**Transaction** — the complete, validated set of jobs computed together in response to a single request. 02 §1.
**Requirement edge / ordering edge** — the two orthogonal axes of the dependency graph: whether a unit is pulled in at all, versus when it runs relative to another. 02 §§2–3.
**Synchronization point** — a target whose sole purpose is marking "everything in this closure is ready" (`basic.target`, `sysinit.target`). 02 §8, 05.
**Readiness signal** — the specific event a given `Type=` treats as "this unit is now active." 03 §2.
**Watchdog ping** — a periodic liveness assertion distinct from one-time startup readiness. 03 §3.3.
**Specifier** — a `%`-prefixed sequence expanded by systemd at unit-load time. 04 §1.
**Template / instance** — a unit file pattern (`worker@.service`) versus a specific, fully-qualified unit created from it (`worker@emails.service`). 04 §2.
**Drop-in** — a layered `.conf` override merged onto a base unit file. 04 §3.
**Generator** — a program run very early by PID 1 producing ordinary unit files from a non-native configuration source (`/etc/fstab` being the running example). 05 §3.3.
**initramfs / switch-root** — the temporary bootstrap filesystem and the operation replacing it with the real root. 05 §§1–2.
**Structured field** — a `FIELD=value` pair attached to a journal entry at write time, indexed and precisely queryable. 06 §1.
**Trusted field** — a `_`-prefixed field recorded by the kernel or journald itself, unforgeable by the logging process. 06 §4.1.
**Invocation ID** — a unique identifier for one specific start-to-stop lifecycle of a unit. 06 §6.1.
**Calendar timer / monotonic timer** — absolute wall-clock scheduling versus elapsed-duration-since-an-event scheduling. 07 §2.1.
**Thundering herd** — the load-spike problem of many independent instances triggering simultaneously, mitigated by `RandomizedDelaySec=`. 07 §6.2.
**Blast radius** — the scope of what a successful exploit inside a sandboxed process can actually reach, the quantity `08`'s entire directive family works to minimize. 08 §1.
**Defense in depth** — the principle that several independent, layered restrictions provide stronger containment together than any one alone. 08 §1.2.
**Capability** — one of several dozen individually-grantable subdivisions of traditional Unix root privilege. 08 §4.
**Exposure score** — `systemd-analyze security`'s heuristic, aggregate rating of a unit's hardening configuration. 08 §9.
**`result=`** — the single field this series' entire troubleshooting method (`09`) is organized around, categorizing why a unit failed at the point of failure itself.
**Root cause / cascade** — the single genuine failure behind a chain of `result=dependency` propagated symptoms, versus the chain of symptoms itself. 09 §4.

---

## 6. "I Want To..." Task-Based Quick Lookup

For a reader who knows what they want to accomplish but not which document covers it.

| Task | Document — Section |
|---|---|
| Make one service wait for another to actually be ready, not just started | 03 §2.5 (`Type=notify`) |
| Understand why my `After=` isn't enforcing what I expected | 02 §3.1 |
| Give a service its own writable directory that's cleaned up automatically | 04 §4.7 |
| Run the same service definition multiple times with different parameters | 04 §2 (templates) |
| Override one setting in a distro-shipped unit without editing the original | 04 §3 (drop-ins) |
| Make a service restart automatically after a crash, but not forever | 03 §5, §6 |
| Find out why my machine dropped into a rescue/emergency shell | 05 §8 |
| Query logs from one specific run of a service, not every restart today | 06 §6.1 |
| Replace a `cron` job with something dependency-aware | 07 (whole document); 07 §12 |
| Stop a fleet of machines from hammering a shared resource at the same scheduled minute | 07 §6.2 |
| Reduce what a compromised process could actually do | 08 (whole document) |
| Cap how much memory/CPU one service can consume | 08 §7 |
| Figure out why a unit reports `failed` and where to start | 09 §1–3 |
| Confirm a scheduled task's `OnCalendar=` expression means what I think | 07 §10 |
| Understand the difference between `enable` and `start` | 01 §10 |
| See the actual process tree systemd is tracking for a unit | 01 §9; 03 §13.1 |
| Give a service access to a privileged port without running it as root | 08 §4.2–4.3 |
| Make `systemctl reload` actually wait for the reload to finish, not just fire-and-forget | 03 §2.5 (`Type=notify-reload`) |
| Diagnose why a service starts before its database dependency is truly ready | 02 §2.2, §3.1; 03 §2.5 |
| Understand what happens to running services during `systemctl poweroff` | 05 §11 |
| Find out whether a shutdown that "hung" is actually just delayed | 05 §11.4 |
| Correlate an application-level custom field across multiple hosts' logs | 06 §9.1 |
| Ship structured logs to a central collector without losing custom fields | 06 §9 |
| Isolate one heavy-logging service's impact from the rest of a shared host's journal | 06 §12 |
| Understand exactly what `%i` expands to for a given instance name | 04 §2.2 |
| Know whether an `.fstab` entry should have `nofail` | 05 §3.2, §8.2 |
| Decide between `Wants=`/`Requires=`/`BindsTo=`/`PartOf=` for a given relationship | 02 §2 |
| Confirm a unit's aggregate hardening posture with one command | 08 §9 |
| Trace a `SIGSYS` crash back to the specific syscall a filter is blocking | 08 §5.4; 09 §14 |
| Know whether `AccuracySec=` or `RandomizedDelaySec=` is the right tool | 07 §6 |

---

## 7. Version and Compatibility Notes

systemd is an actively developed project, and several directives referenced throughout this series are more recent additions than others — worth a brief, consolidated note here rather than scattered across nine documents, for a reader working against an older, still-widely-deployed systemd version who needs to know which mechanisms might not be available.

**Comparatively recent additions** (not present in older long-term-support distribution releases): `Type=exec` (03 §2.1, an addition after the original `Type=simple`), `Type=notify-reload` (03 §2.5), `RestartSteps=`/`RestartMaxDelaySec=` (03 §5.2, exponential backoff — older versions have only the flat `RestartSec=` delay), `LogNamespace=` (06 §12), and `systemd-analyze security`'s scoring (08 §9) itself. A unit file relying on any of these against an older host will generally fail to parse that specific directive, in most cases logging a warning about the unrecognized key rather than failing the entire unit outright — worth confirming via `systemd-analyze verify` (02 §7.2) against the actual target systemd version before relying on a newly-introduced directive in a production unit file.

**Long-stable, safe to assume nearly everywhere:** the core dependency directives (02 §2–3), the core `Type=` values other than `exec`/`notify-reload` (03 §2), the drop-in mechanism (04 §3), `.timer` units in their entirety (07), and the foundational sandboxing directives from `08` §§2–6 have all been present, largely unchanged, for long enough that compatibility is rarely a practical concern on any systemd-based distribution still receiving updates.

**Checking what a specific host actually supports:**

```bash
systemctl --version
man systemd.exec | grep -A2 "^ *RestartSteps="
```

`systemctl --version` reports the installed systemd version number directly; cross-referencing a specific directive's own manual page (04's bibliography, Section 4 of this document) against the "added in version" note most systemd manual pages carry near each directive's own description is the authoritative way to confirm availability, rather than relying on this document's own necessarily-approximate summary above.

---

## 8. What This Series Deliberately Did Not Cover

Worth stating explicitly, for completeness: this series focused on system-wide `systemd` (PID 1) administration on a general-purpose Linux host. Several adjacent, genuinely large topics were mentioned only in passing or not at all, and would warrant their own dedicated treatment:

- **`systemd --user` instances** in full depth — per-user session managers, distinct from the system-wide PID 1 this series focused on, mentioned only briefly in `05-Boot-Process-and-Targets.md` Section 3.2 and `07-Timers-and-Scheduled-Tasks.md`'s user-timer context.
- **`systemd-networkd` and `systemd-resolved`** configuration in depth — named in `01-Introduction.md`'s component table but never given their own directive-level treatment.
- **`systemd-nspawn`** container management — the lightweight container tooling built on the same namespacing primitives `08-Security-and-Hardening.md` covered, but never itself addressed directly.
- **`systemd-homed`** and portable service images — newer, less universally-deployed subsystems outside this series' scope.
- **Cross-distribution packaging conventions** for shipping systemd units — how Debian, Fedora, and other distributions each layer their own packaging conventions on top of the native mechanisms this series covered.

---

## 9. The `webapp.service` Thread: A Worked-Example Index

One deliberate structural choice across this series is worth surfacing explicitly: `webapp.service` is the *same* running example from its first appearance through its last, incrementally acquiring directives in roughly the order a real production service might acquire them. A reader wanting to see the cumulative effect — rather than any single document's own isolated snippet — can trace it directly:

| Stage | What was added | Document — Section |
|---|---|---|
| First appearance, minimal | `ExecStart=`, basic `[Unit]`/`[Service]`/`[Install]` shape | 01 §5 |
| Dependency graph | `Requires=postgresql.service`, `Wants=cache.service`, `After=` | 02 §13 |
| Full lifecycle directives | `Type=notify`, `Restart=`, `RestartSteps=`, `WatchdogSec=`, `KillMode=` | 03 §13 |
| Templated variant | `worker@.service` scaling pattern, drop-in customization | 04 §9 |
| Boot-sequence placement | Where in `multi-user.target`'s closure it actually starts | 05 §12 |
| Full incident investigation | `journalctl` correlation across an invocation and a dependency | 06 §13 |
| Scheduled companion | `backup.timer`/`backup.service` pairing depending on the same `postgresql.service` | 07 §13 |
| Incremental hardening | Four-stage `ProtectSystem=`/`DynamicUser=`/`SystemCallFilter=`/resource-control pass | 08 §10 |
| Failure diagnosis | `MemoryMax=` OOM-kill investigation against the hardened configuration | 09 §16 |

Reading these nine snippets in this table's order, independent of the surrounding prose in each document, is a reasonably compact way to see the entire series' cumulative argument made concrete against one continuously-evolving unit, rather than nine separate, unrelated illustrations.

---

## 10. Closing Note

Nine documents, read in sequence, cover systemd from PID 1's own kernel handoff through unit authoring, service lifecycle, boot sequencing, logging, scheduling, sandboxing, and systematic failure diagnosis — each building on directives, tools, and worked examples established in the documents before it, with this final index existing to make that accumulated material navigable without requiring a linear re-read. The `webapp.service` running example threaded through `02` via `09` is deliberately the same unit throughout, incrementally acquiring dependency edges, lifecycle directives, hardening, and scheduled companions exactly in the order a real service might acquire them in production — worth revisiting as one continuous thread, via this index, whenever a specific mechanism's role in that larger, cumulative picture needs re-establishing.
