# Introduction

A mechanism-level examination of what `systemd` actually is, the problem it was built to solve, the architectural decisions that define it, and the vocabulary you need before the rest of this series makes sense. This is not a "getting started" tutorial — it is the conceptual foundation the following nine documents build on.

---

## 1. The Problem Before systemd

To understand why `systemd` exists, you have to understand what PID 1 was doing before it, and why that model broke down as Linux systems grew more complex.

### 1.1 SysVinit and the runlevel model

For roughly two decades, the dominant init system on Linux was **SysVinit**, inherited almost unchanged from Unix System V. Its model was simple:

- The kernel starts `/sbin/init` as PID 1.
- `init` reads `/etc/inittab` to determine the default **runlevel** (0–6, where each number represents a coarse system state — halt, single-user, multi-user without networking, multi-user with networking, custom, graphical, reboot).
- For each runlevel, a directory such as `/etc/rc3.d/` contains a flat list of symlinks — `S10network`, `S12syslog`, `S20sshd`, `K15httpd`, etc. — pointing back into `/etc/init.d/`.
- `init` executes these symlinks **serially**, in lexical order, each one a shell script that itself has to implement start/stop/status/restart logic by hand.

The `S`/`K` prefix and numeric ordering encoded the *entire* dependency model. If `sshd` needed the network to be up, the only way to guarantee that was to name it `S20sshd` and make sure the networking script was `S15network` or earlier. There was no actual dependency graph — only a human-maintained illusion of one, expressed as a sort order.

### 1.2 Why that model collapsed

Three separate problems compounded:

**Serial execution.** Every script in `/etc/rc3.d/` ran one after another, and each script blocked until the daemon it started had (supposedly) finished initializing. On a machine with dozens of services — which became the norm as distributions grew — boot time scaled linearly with the number of services, because there was no way to express "these five services don't depend on each other, start them concurrently."

**No real dependency resolution.** Numeric ordering is a total order imposed on what is, in reality, a partial order. Two services with no relationship to each other still had to be assigned *some* relative position, and if a new package needed to slot in "after networking but before anything that logs," the packager had to pick a number and hope. Multiply this across hundreds of packages maintained by different people, and ordering conflicts were routine.

**No process supervision.** A SysVinit script's job was to launch a daemon and then exit. The daemon was expected to **fork and detach** from its controlling process (double-forking, `setsid()`, etc.) so that `init` wasn't blocked waiting on it. But once that daemon detached, `init` lost all reliable knowledge of it. It didn't know if the daemon had actually started successfully, and if the daemon crashed, nothing restarted it, and nothing reliably killed all of its children if you tried to stop it. Tracking a service's process tree usually fell back to PID files — a daemon writing its own PID to `/var/run/foo.pid` — which is trivially wrong the moment a daemon forks helper processes, or if the PID gets reused by an unrelated process after a crash.

### 1.3 Upstart: a partial fix

Ubuntu's **Upstart** (2006) was an attempt to address the first problem. It replaced the rigid runlevel/rc-script model with an **event-driven** system: jobs declared what events they should start or stop on ("start on filesystem and net-device-up"), and Upstart's engine reacted to those events as they occurred, allowing genuine parallelism.

This was a real improvement, but it kept the fundamental unit of work as a **shell script wrapping arbitrary logic**, and it never fully solved process supervision or fine-grained resource tracking. Event ordering also proved to be a genuinely hard problem to reason about at scale — the system's behavior depended on the *order in which events happened to fire*, which made some boot sequences effectively non-deterministic.

### 1.4 What was actually needed

By around 2010, it was clear the fix needed to attack all three problems at once, structurally:

1. A **declarative dependency graph**, not an imperative script order — so the init system itself could compute a valid parallel execution plan.
2. **Native parallelism** as the default, with explicit ordering only where a real dependency exists.
3. **Reliable process tracking**, at the kernel level, so that "is this service still running, and what are all of its processes" is a fact the init system can *know*, not guess.

`systemd`, started by Lennart Poettering and Kay Sievers and first released in 2010, was designed around exactly these three requirements. It reached most major distributions (Fedora, RHEL/CentOS, Debian, Ubuntu, SUSE, Arch) by the mid-2010s and is, as of this writing, the init system on the overwhelming majority of production Linux servers and desktops — with Alpine/OpenRC-based distributions and a handful of others being the notable holdouts.

---

## 2. Design Philosophy

`systemd`'s architecture is easiest to understand as a small number of firm, sometimes controversial, design commitments.

### 2.1 Declarative units instead of imperative scripts

Instead of a shell script that manually implements `start()`, `stop()`, `restart()`, `status()`, a `systemd` service is described by a **unit file** — a static, declarative INI-style document that states *what* the service is (its executable, its user, its restart policy, its dependencies) rather than *how* to manage its lifecycle procedurally. `systemd` itself implements the "how." This is the single biggest shift from the SysVinit model: control logic moves out of thousands of independently-written shell scripts and into one auditable, testable program.

### 2.2 Dependency-based, not order-based

Units declare relationships to other units — "I want the network online before I start," "I must not start unless this mount point exists," "if this socket unit stops, stop me too." `systemd` builds an actual directed graph from these declarations and computes a topologically-sorted, maximally parallel execution plan called a **transaction**. Two units with no dependency relationship *will* start concurrently, with no special configuration required, because concurrency is the default rather than something you have to opt into.

### 2.3 Aggressive parallelization via activation

Even a correct dependency graph has bottlenecks: if `sshd` merely depends on the network being "up" in the abstract, and the network stack takes eight seconds to fully initialize, `sshd` waits eight seconds even though it doesn't need the network *yet* — only once a client connects. `systemd` addresses this with **activation mechanisms**:

- **Socket activation** — `systemd` can create and bind a listening socket on a service's behalf *before the service itself exists as a running process*. Connections queue at the kernel socket level; `systemd` starts the actual daemon only when the first connection arrives (or immediately at boot, non-blocking, in parallel with everything else), and hands it the already-open socket via file descriptor passing. The daemon does not need to know or care when it was actually started.
- **Bus activation** — analogous mechanism for D-Bus services: a service is started on-demand the first time something addresses its D-Bus name.
- **Device/path/timer activation** — units can be triggered by a udev device appearing, a file or directory changing, or a calendar/monotonic timer elapsing, rather than being started unconditionally at boot.

The practical effect: at boot, `systemd` can bind the SSH listening socket, the D-Bus name, and every other externally-visible entry point *immediately and in parallel*, and defer the actual expensive daemon startup until it's genuinely needed, without any client-visible failure window — connections simply queue.

### 2.4 The kernel, not a PID file, is the source of truth

`systemd` uses Linux **control groups (cgroups)** to place every process belonging to a unit into a dedicated cgroup at launch. This means `systemd` does not need a daemon to self-report its PID, and does not lose track of a service's process tree when that service forks, double-forks, or spawns workers. "Is this unit still running, and what are the current PIDs" is answered by asking the kernel to enumerate a cgroup, which cannot lie or drift out of sync the way a PID file can. This is also what makes reliable, complete process termination possible — `systemctl stop` can signal every process in the cgroup, including orphaned children a script-based approach would have missed entirely.

### 2.5 Unified, structured logging

Every process launched by `systemd` has its stdout/stderr captured automatically and routed to **journald**, `systemd`'s logging component, without the service needing to implement its own log rotation, syslog integration, or file handling. Journal entries are stored as structured, indexed, binary records with metadata (PID, unit name, boot ID, monotonic timestamp, credentials of the sending process, and more) attached automatically — not as unstructured lines of text you have to `grep` and hope the format hasn't changed between daemons.

### 2.6 One tool, one mental model

Where the SysVinit ecosystem was a loose confederation of `service`, `chkconfig`/`update-rc.d`, `/etc/inittab`, cron, and various distribution-specific wrappers, `systemd` consolidates process supervision, logging, device management, login/session tracking, network configuration, time synchronization, and scheduled tasks under one consistent unit-file syntax and one primary command-line tool, `systemctl`. You will see this consistency play out across every document in this series — a timer unit (covered in `07-Timers-and-Scheduled-Tasks.md`) uses the same dependency syntax as a service unit, because it *is*, structurally, the same kind of object.

---

## 3. What systemd Actually Is

It's worth being precise about scope, because "systemd" colloquially refers to several distinct things:

1. **`systemd` the process** — PID 1 itself, the actual init process the kernel starts, responsible for supervising units, managing the dependency graph, and mounting early filesystems.
2. **`systemd` the project** — an umbrella of tightly-integrated components that ship together and share a release cycle, most of which are *not* PID 1 but rather separate daemons that PID 1 starts and supervises like any other unit:

| Component | Responsibility |
|---|---|
| `systemd-journald` | Structured log collection and storage |
| `systemd-logind` | User login/session tracking, seat management, power-key handling |
| `systemd-networkd` | Optional native network configuration daemon |
| `systemd-resolved` | Local DNS resolution/caching stub |
| `systemd-timesyncd` | Lightweight NTP client |
| `systemd-udevd` | Device node management, replacing standalone udev |
| `systemd-tmpfiles` | Creation/cleanup of files and directories in tmpfs and elsewhere on boot |
| `systemd-cryptsetup` | Encrypted volume unlocking at boot |
| `systemd-machined` | Tracking of containers/VMs registered with systemd |
| `systemd-hostnamed`, `systemd-localed`, `systemd-timedated` | Hostname, locale, and timezone management exposed over D-Bus |
| `systemd-oomd` | Userspace out-of-memory killer with cgroup-aware policy |

3. **`systemd` the unit-file format and IPC protocol** — the declarative syntax and D-Bus API that both PID 1 and its satellite daemons expose, and which tools like `systemctl`, `journalctl`, `loginctl`, `timedatectl`, `hostnamectl`, and `networkctl` all talk to.

When people say "systemd starts my service," they mean component (1). When people criticize "systemd" for "doing too much," they are usually really objecting to the fact that (2) ships as a tightly-coupled suite rather than fully independent, separately-installable projects — a legitimate architectural debate, but orthogonal to whether the *init* design itself (declarative units, dependency graphs, cgroup-based tracking) is sound. This series focuses primarily on (1) and (3), with targeted coverage of `journald` in `06-journald-and-Logging.md`.

---

## 4. The Unit Abstraction

Everything `systemd` manages — a daemon, a mount point, a device, a scheduled job, a group of processes — is represented as a **unit**. A unit is identified by a name and a type suffix, and every unit type is handled by the same dependency-resolution and job-scheduling engine. This uniformity is deliberate: learning how one unit type's dependencies work teaches you how *all* of them work.

| Suffix | Represents | Typical use |
|---|---|---|
| `.service` | A managed process (a daemon or one-shot command) | `sshd.service`, `nginx.service` |
| `.socket` | A network or IPC socket, optionally activating a `.service` | `sshd.socket` |
| `.target` | A named synchronization point / grouping of units | `multi-user.target` |
| `.mount` | A filesystem mount point | `home.mount` (for `/home`) |
| `.automount` | A mount point that mounts on first access | lazy-mounted `/mnt/usb` |
| `.device` | A kernel device object exposed via udev | `dev-sda1.device` |
| `.swap` | A swap device or file | `swapfile.swap` |
| `.path` | A filesystem path being watched for changes, triggering another unit | spool-directory watchers |
| `.timer` | A scheduled trigger for another unit (cron replacement) | `backup.timer` |
| `.slice` | A cgroup grouping node for resource control | `user.slice`, `system.slice` |
| `.scope` | Externally-created process groups tracked by systemd (not launched by it) | user session process groups |

Unit types `08-Security-and-Hardening.md` and `07-Timers-and-Scheduled-Tasks.md` will go deep on `.slice`/hardening directives and `.timer` respectively. For this introduction, `.service` and `.target` are the two you need to internalize first.

---

## 5. Anatomy of a Unit File

Unit files are plain-text, INI-style documents: bracketed section headers, `Key=Value` pairs beneath them. Here is a realistic, complete `.service` unit for a hypothetical web application:

```ini
# /etc/systemd/system/webapp.service
[Unit]
Description=Example web application
Documentation=https://example.com/docs
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=notify
User=webapp
Group=webapp
WorkingDirectory=/srv/webapp
ExecStart=/srv/webapp/bin/serve --config /etc/webapp/config.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Breaking this down by section:

**`[Unit]`** — metadata and dependency declarations common to *every* unit type. `Description` and `Documentation` are purely informational (shown by `systemctl status`). `After=` and `Requires=`/`Wants=` are dependency directives — the subject of Section 6 below.

**`[Service]`** (or `[Socket]`, `[Mount]`, `[Timer]`, etc.) — directives specific to this unit type. `Type=notify` tells `systemd` how to determine the service has finished starting (covered fully in `03-Service-Management.md`); `ExecStart=` is the command actually run; `Restart=on-failure` tells `systemd` to relaunch the process automatically if it exits with a non-zero status or is killed by a signal — a supervision guarantee SysVinit never provided natively.

**`[Install]`** — used only when *enabling* the unit (i.e., wiring it into a target so it starts automatically at boot). `WantedBy=multi-user.target` means "when `multi-user.target` is activated, this unit should be pulled in too." This section is inert while the unit is merely running manually; it only takes effect via `systemctl enable`, which is explained mechanically in Section 9.

---

## 6. Unit File Locations and Precedence

`systemd` does not look for unit files in a single directory — it merges them from three canonical locations, in a defined precedence order, plus a mechanism for partial overrides:

| Path | Purpose | Precedence |
|---|---|---|
| `/usr/lib/systemd/system/` (`/lib/systemd/system/` on Debian-family) | Unit files installed by distribution packages | Lowest |
| `/run/systemd/system/` | Runtime-generated / transient units | Middle |
| `/etc/systemd/system/` | Local administrator configuration | Highest |

If the same unit name exists in more than one of these, the version in the **higher-precedence** directory wins entirely — `/etc/systemd/system/sshd.service` fully shadows the packaged `/usr/lib/systemd/system/sshd.service`. This is how you can safely override a distribution-shipped service without editing (and risking package-manager overwrites to) the packaged file.

For *partial* overrides — changing or adding one directive without replacing the whole file — `systemd` supports **drop-in directories**: `/etc/systemd/system/sshd.service.d/*.conf`. Any `.conf` file placed there is merged on top of the original unit. The safe, scripted way to create one is:

```bash
systemctl edit sshd.service
```

which opens (or creates) exactly such a drop-in in `$EDITOR`, and — critically — automatically runs `systemctl daemon-reload` for you afterward so `systemd` re-parses the merged result. `systemctl edit --full sshd.service` instead opens a full local copy of the unit for editing, placed in `/etc/systemd/system/`.

---

## 7. The Dependency Graph and Job Transactions

This is the mechanism that actually replaces SysVinit's numeric ordering, and it is built from two **orthogonal** axes that are easy to conflate but behave completely differently.

### 7.1 Requirement (do I need it at all?)

- **`Requires=`** — a hard dependency. If unit B is `Required=`'d by unit A and B fails to start, A's start is treated as a failure too (subject to the ordering discussed below — `Requires=` alone says nothing about *when*).
- **`Wants=`** — a soft dependency. `systemd` will try to start B when starting A, but if B fails, A proceeds anyway. This is the directive you should reach for in the overwhelming majority of cases — it expresses "I'd like this to be running" without creating fragile hard failures.
- **`Requisite=`** — like `Requires=`, but instead of *starting* B, it checks that B is *already* active; if not, A fails immediately rather than waiting.
- **`BindsTo=`** — like `Requires=`, but also stops A automatically the moment B stops or fails, even after both were successfully running. Commonly used to tie a unit's lifetime to a device unit that might disappear (e.g., removable hardware).
- **`PartOf=`** — propagates stop/restart from B to A, but not start.
- **`Conflicts=`** — the inverse of `Requires=`: starting A stops B, and vice versa. `rescue.target` and `multi-user.target`, for example, conflict with each other.

### 7.2 Ordering (when, relative to it?)

- **`Before=`** and **`After=`** — pure ordering, with **no implication of a requirement relationship whatsoever**. `After=network-online.target` only says "if `network-online.target` is going to be started anyway, start it before me" — it does *not* cause `network-online.target` to be started. This is the single most common `systemd` unit-file mistake: writing `After=` and assuming it implies `Requires=`. It does not. If you actually need the network, you must add `Wants=network-online.target` (or `Requires=`) *in addition to* `After=network-online.target`.

Without any `Before=`/`After=` directive at all between two units, `systemd` is free to start them **fully in parallel** — this is the mechanism, not an accident, and it's precisely what makes boot fast.

### 7.3 Transactions

When you run `systemctl start webapp.service`, `systemd` doesn't just launch that one unit — it computes a **transaction**: the full set of units that must be started or stopped as a consequence (everything reachable via `Requires=`/`Wants=`/`Conflicts=`), verifies the transaction doesn't contain an unresolvable cycle or contradiction (e.g., two units in the same transaction that conflict with each other), and only then executes it, starting everything that has no unmet ordering constraint concurrently, and everything else as soon as its `After=` dependencies complete. This whole graph-solving step happens before a single process is spawned.

---

## 8. Targets as Synchronization Points

A **`.target`** unit does no work itself — it has no `ExecStart=` — it exists purely as a named grouping node in the dependency graph, a synchronization point that other units hang off of via `WantedBy=`/`RequiredBy=`. This is `systemd`'s conceptual replacement for SysVinit runlevels, but structurally more flexible because a target is just another node in the same graph, not a special separate concept.

Common targets:

| Target | Rough SysVinit equivalent | Meaning |
|---|---|---|
| `poweroff.target` | runlevel 0 | System shutdown |
| `rescue.target` | runlevel 1 | Single-user, minimal services, root shell |
| `multi-user.target` | runlevel 3 | Full multi-user, no display manager |
| `graphical.target` | runlevel 5 | Multi-user plus display manager / GUI |
| `reboot.target` | runlevel 6 | System reboot |
| `emergency.target` | — | Bare minimum, used when boot fails badly enough that even `rescue.target` can't be reached |

`graphical.target` itself declares `Requires=multi-user.target` and `After=multi-user.target` — targets can depend on and order relative to other targets, letting you build a layered system state out of composable pieces rather than an arbitrary flat integer.

`systemctl get-default` / `systemctl set-default graphical.target` read and write the symlink `/etc/systemd/system/default.target`, which is what `systemd` activates at the end of boot — this symlink is the entire mechanism behind "which mode does my machine boot into."

---

## 9. PID 1, Process Supervision, and cgroups

`systemd`, running as PID 1, is the direct or indirect parent (via `fork()`+`exec()`) of every unit's process tree, and immediately places each launched process into a dedicated **cgroup** — visible under `/sys/fs/cgroup/system.slice/webapp.service/` on a cgroup-v2 system. Every child, grandchild, or otherwise-forked descendant a service spawns inherits that cgroup automatically at the kernel level, with no cooperation required from the daemon itself.

This has two direct, practical consequences:

**Accurate status.** `systemctl status webapp.service` can enumerate the *actual current process tree* by reading the cgroup, rather than trusting a PID file the daemon may have written once and never updated:

```
● webapp.service - Example web application
     Loaded: loaded (/etc/systemd/system/webapp.service; enabled)
     Active: active (running) since Fri 2026-07-17 08:12:03 UTC; 2h 14min ago
   Main PID: 4821 (serve)
      Tasks: 9 (limit: 4915)
     Memory: 84.2M
        CPU: 12.309s
     CGroup: /system.slice/webapp.service
             ├─4821 /srv/webapp/bin/serve --config /etc/webapp/config.yaml
             ├─4830 worker: request handler 1
             └─4831 worker: request handler 2
```

**Complete termination.** `systemctl stop webapp.service` sends `SIGTERM` (then `SIGKILL` after `TimeoutStopSec=`) to **every process in that cgroup**, not just the one PID it originally launched. A daemon that forks workers and dies without reaping them cannot leave orphans behind the way it routinely could under SysVinit's PID-file model.

Slices (`.slice` units, e.g. `system.slice`, `user.slice`, `machine.slice`) are the higher-level cgroup nodes that group related units together and are also where CPU/memory/IO resource limits get applied hierarchically — the mechanism `06-Hardening.md`'s resource-control directives (`MemoryMax=`, `CPUQuota=`, etc.) build directly on top of.

---

## 10. systemctl: The Primary Interface

Nearly every interaction with `systemd` from the command line goes through `systemctl`, which talks to PID 1 over its private D-Bus interface. The core verbs you'll use constantly:

```bash
systemctl status sshd.service        # current state, recent log excerpt, cgroup tree
systemctl start sshd.service         # start now (does not persist across reboot)
systemctl stop sshd.service          # stop now
systemctl restart sshd.service       # stop then start
systemctl reload sshd.service        # ask the daemon to reload config without restarting (ExecReload=)
systemctl enable sshd.service        # create the WantedBy= symlink -> starts on future boots
systemctl disable sshd.service       # remove that symlink -> will not autostart
systemctl enable --now sshd.service  # enable and start in one call
systemctl is-active sshd.service     # prints active/inactive/failed, exit code reflects it
systemctl is-enabled sshd.service    # prints enabled/disabled
systemctl mask sshd.service          # symlink the unit to /dev/null — prevents it starting even manually
systemctl cat sshd.service           # print the fully-resolved unit file, including drop-ins
systemctl show sshd.service          # dump every property systemd knows about the unit
systemctl daemon-reload              # re-read unit files after editing them by hand
systemctl list-units --type=service  # everything currently loaded
systemctl list-unit-files            # everything installed, and its enabled/disabled state
systemctl list-dependencies sshd.service   # render the dependency tree for a unit
```

Two distinctions worth internalizing immediately, because they trip up nearly everyone new to `systemd`:

- **`start`/`stop` vs `enable`/`disable`** are entirely independent axes. `start` affects the *current* boot only; `enable` affects *future* boots by wiring the `[Install]` section's `WantedBy=` target. A unit can be enabled-but-not-currently-running, or running-but-not-enabled (will not survive a reboot), or both, or neither.
- **`mask` is stronger than `disable`.** A disabled unit can still be started manually or pulled in as a dependency of something else. A masked unit's file is symlinked to `/dev/null`, so it cannot be started by any means — including as someone else's dependency — until unmasked.

---

## 11. A Minimal Worked Example

To make the mechanism concrete, here is the complete lifecycle of introducing a new service, end to end.

**1. Write the unit file:**

```bash
sudo tee /etc/systemd/system/hello.service > /dev/null <<'EOF'
[Unit]
Description=Minimal example service

[Service]
ExecStart=/usr/bin/sleep infinity
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

**2. Make systemd aware a new unit file exists:**

```bash
sudo systemctl daemon-reload
```

This step is required any time a unit file is created or hand-edited outside of `systemctl edit` — `systemd` caches parsed unit files and will not notice the new file on disk otherwise.

**3. Start it immediately, and enable it for future boots, in one step:**

```bash
sudo systemctl enable --now hello.service
```

**4. Inspect it:**

```bash
systemctl status hello.service
journalctl -u hello.service --since "5 minutes ago"
```

**5. Tear it down cleanly:**

```bash
sudo systemctl disable --now hello.service
sudo rm /etc/systemd/system/hello.service
sudo systemctl daemon-reload
```

Every service you'll build in `03-Service-Management.md` and `04-Unit-Files.md` follows this same skeleton — only the contents of `[Service]` and the dependency directives in `[Unit]` grow more sophisticated.

---

## 12. systemd vs. Traditional Init — Direct Comparison

| Concern | SysVinit / rc-scripts | systemd |
|---|---|---|
| Unit definition | Imperative shell script | Declarative INI-style unit file |
| Ordering | Total order via numeric filename prefix | Partial order via explicit `Before=`/`After=` graph edges |
| Parallelism | None by default | Default, unless explicitly ordered |
| Dependency semantics | Implied by ordering only | Explicit, separate from ordering (`Requires=`/`Wants=`/etc.) |
| Process tracking | Self-reported PID files | Kernel cgroups |
| Crash recovery | Not handled by init | `Restart=` policies, natively supervised |
| On-demand start | Not supported | Socket/bus/path/timer activation |
| Logging | Each daemon manages its own (often syslog) | Centralized, structured, indexed (`journald`) |
| Config reload | Re-run the script's `reload` case, if implemented | `systemctl reload`, standardized via `ExecReload=` |
| Resource limits | `ulimit` in the script, if anyone bothered | Native cgroup-backed directives (`MemoryMax=`, `CPUQuota=`, etc.) |

---

## 13. Common Misconceptions Worth Correcting Early

**"`systemd` is just an init system."** Precisely speaking, PID 1 is the init system; the broader `systemd` *project* additionally ships the tightly-integrated daemons enumerated in Section 3. Conflating the two is the source of most "systemd does too much" arguments — legitimate critiques of the project's scope are not critiques of the init design itself.

**"`After=X` means X will be started."** As covered in Section 7.2, it does not. Ordering and requirement are separate directives, and this is the most common source of "why did my service start before its dependency was ready" bugs.

**"Disabling a service stops it right now."** It does not — `disable` only removes the boot-time symlink; the currently-running instance, if any, keeps running until explicitly stopped.

**"You need a PID file for systemd to track a daemon."** You never do — cgroup-based tracking (Section 9) works for any process tree regardless of whether the daemon writes a PID file at all. `Type=forking` services optionally use a `PIDFile=` directive only to identify *which* process is the "main" one for status-reporting purposes, not to track the process tree.

---

## 14. What's Ahead in This Series

This introduction deliberately stayed at the conceptual and mechanism level. The documents that follow go deep on each piece introduced here:

- **`02-Units-and-Dependencies.md`** — the full dependency-directive reference, ordering-cycle resolution, and how to read `systemctl list-dependencies` output correctly.
- **`03-Service-Management.md`** — every `Type=` value (`simple`, `exec`, `forking`, `oneshot`, `notify`, `dbus`, `idle`) and exactly how `systemd` determines "the service has started" for each.
- **`04-Unit-Files.md`** — the complete directive reference across all unit types, specifiers, environment handling, and templated/instantiated units (`getty@.service`-style).
- **`05-Boot-Process-and-Targets.md`** — the full boot sequence from kernel handoff to `default.target`, including the initramfs boundary.
- **`06-journald-and-Logging.md`** — journal internals, structured fields, persistence configuration, and forwarding to traditional syslog.
- **`07-Timers-and-Scheduled-Tasks.md`** — `.timer` units as a cron replacement, calendar syntax, and monotonic timers.
- **`08-Security-and-Hardening.md`** — sandboxing directives (`ProtectSystem=`, `NoNewPrivileges=`, namespacing, seccomp filters) and resource-control slices.
- **`09-Troubleshooting.md`** — systematic diagnosis of failed units, boot failures, and ordering-cycle debugging.
- **`10-References.md`** — canonical manual pages, upstream documentation, and further reading.

---

## References

- `systemd(1)`, `systemd.unit(5)`, `systemd.service(5)`, `systemd.target(5)` manual pages
- freedesktop.org systemd project documentation
- Lennart Poettering's original systemd design write-ups (2010)
