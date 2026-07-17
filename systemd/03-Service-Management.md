# Service Management

A complete, mechanism-level reference for the `.service` unit type: the full `Type=` vocabulary and precisely how systemd determines a service has actually finished starting for each one, the `sd_notify` protocol and watchdog mechanism underneath `Type=notify`, the complete `Exec*=` lifecycle directive set, every `Restart=` policy and how it interacts with the dependency graph established in `02-Units-and-Dependencies.md`, start-rate limiting, timeout and kill behavior, and enough worked failure timelines that you can predict exactly what systemd will do to a misbehaving service rather than needing to test it empirically each time.

`01-Introduction.md` used `Type=notify` in its worked examples without explaining what that determination mechanism actually is. This document fills that gap completely, alongside every other `Type=` value, and goes on to cover the parts of a service's lifecycle — startup probing, restart policy, timeouts, and termination — that were deliberately deferred out of the first two documents in this series.

---

## 1. The Service State Machine

Every `.service` unit systemd tracks moves through a well-defined set of states, and nearly everything in this document is really about the *rules* governing transitions between them.

| State | Meaning |
|---|---|
| `inactive` | Not running, no job in progress |
| `activating` | A start job is in progress; the unit is not yet considered fully up |
| `active` | Successfully started and (for long-running services) currently running |
| `deactivating` | A stop job is in progress |
| `failed` | Exited, or failed to start, in a way systemd considers an error |
| `reloading` | `ExecReload=` is currently executing |

Two of these deserve immediate elaboration because they're easy to conflate: `activating` is not merely "the process has been `fork()`+`exec()`'d" — for most `Type=` values, a service can sit in `activating` for a meaningful amount of wall-clock time after its process already exists, because "the process exists" and "the service is ready" are different facts, and the entire point of `Type=` (Section 2) is telling systemd how to distinguish between them. A unit's dependents (`After=` in the graph sense) are only released to proceed once the unit transitions **out of** `activating` into `active` — not the moment the process itself is spawned.

`activating` itself has sub-states systemd tracks internally and surfaces in `systemctl status` output — `start`, `start-pre`, `start-post` — corresponding to which phase of the `Exec*=` lifecycle (Section 4) is currently executing. You will see these in the `Active:` line of `systemctl status` output while a service with a slow `ExecStartPre=` is still working through its pre-start phase, distinguishing "still running pre-start setup" from "the actual daemon binary is executing but not yet ready" from a glance at status output alone.

---

## 2. `Type=`: How systemd Knows You've Actually Started

This is the single most consequential directive in the `[Service]` section, because it defines the exact signal systemd waits for before considering the unit `active` — and, transitively, before releasing anything ordered `After=` this unit.

### 2.1 `Type=simple` (and `Type=exec`)

The default if `Type=` is omitted (with an important caveat below). systemd considers the service started **the instant the main process is successfully forked and executed** — no further signal is awaited at all.

```ini
[Service]
Type=simple
ExecStart=/usr/local/bin/worker --config /etc/worker.conf
```

This is appropriate for a process that does its own internal setup quickly and doesn't have dependents that genuinely need to wait for that setup to complete — the moment `exec()` succeeds, systemd moves on, regardless of whether the process has actually opened its listening socket, connected to a database, or finished any other internal initialization.

**`Type=exec`** is functionally almost identical, with one meaningful difference: `Type=simple` considers the service started as soon as `fork()` succeeds, before confirming the subsequent `exec()` of your actual binary succeeded — meaning a service whose `ExecStart=` binary doesn't exist, or isn't executable, can briefly appear to be starting successfully before failing. `Type=exec`, added specifically to close this gap, waits for the `exec()` call itself to succeed before reporting `active`, giving a marginally more accurate signal for the common case of "the binary failed to even launch." For virtually all new unit files, `Type=exec` is the more precise choice over `Type=simple`, and is treated as the modern default recommendation, though `Type=simple` remains far more common in the wild simply because it predates `Type=exec`'s introduction.

**Gotcha:** because no readiness signal beyond process existence is awaited, a service with `Type=simple`/`Type=exec` that takes several seconds to actually become useful (opening a port, warming a cache) will have its dependents proceed immediately, under the false impression it's ready — this is the exact scenario `Type=notify` (Section 2.5) exists to solve correctly.

### 2.2 `Type=forking`

For traditional Unix daemons that follow the classic double-fork-and-detach pattern: the process systemd directly launches is expected to fork a child, then **exit itself**, leaving the child as the actual long-running daemon, detached from the original process's controlling terminal and session.

```ini
[Service]
Type=forking
PIDFile=/run/legacy-daemon.pid
ExecStart=/usr/sbin/legacy-daemon
```

systemd considers the service started once the **original process it launched exits** (having done its forking) — at that point, if `PIDFile=` is set, systemd reads that file to determine which PID is actually the long-running daemon process, for status-reporting and future signal-delivery purposes. Note precisely what `PIDFile=` is and is not doing here, tying back to `01-Introduction.md` Section 9: it identifies *which* process, among potentially several in the service's cgroup, is the "main" one to report as `Main PID:` in `systemctl status` — it is not how systemd tracks the process tree for supervision or termination purposes at all; that remains entirely cgroup-based regardless of `Type=`.

**Gotcha:** `Type=forking` is a legacy accommodation for daemons that predate systemd and were written assuming a SysVinit-style init that needed them to self-detach. A daemon you're writing today, with no such legacy constraint, should almost always prefer `Type=notify` or plain `Type=exec` running in the foreground — `Type=forking` exists for compatibility, not as a recommended pattern for new software.

### 2.3 `Type=oneshot`

For commands that are expected to **run to completion and exit**, rather than remain running — a one-time setup or migration script being the canonical example, as opposed to a long-running daemon.

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/run-migrations.sh
RemainAfterExit=yes
```

Without `RemainAfterExit=yes`, the unit reverts to `inactive` the moment `ExecStart=` completes — meaning `systemctl status` on it, checked any time after that, shows it as not active, even though it ran successfully and did exactly what it was supposed to. `RemainAfterExit=yes` keeps the unit reported as `active` after successful completion, which matters specifically when *other* units have a dependency on this one (`Requires=run-migrations.service`) — without `RemainAfterExit=yes`, a dependent checking "is my dependency satisfied" after the oneshot has already finished and reverted to `inactive` would see it as not satisfied, and systemd would attempt to re-run it, which is very likely not the intended behavior for a migration script that should run exactly once per boot (or, with appropriate `ConditionPathExists=` guards, exactly once ever).

`Type=oneshot` is also the only `Type=` value that supports **multiple `ExecStart=` lines**, executed sequentially in the order they appear — every other `Type=` accepts exactly one `ExecStart=` (though `ExecStartPre=`/`ExecStartPost=` themselves always support multiple entries regardless of the main `Type=`, covered in Section 4).

### 2.4 `Type=idle`

Functionally almost identical to `Type=simple`/`Type=exec`, with one behavioral addition: systemd **delays actual execution** of `ExecStart=` until all other currently-queued *start* jobs in the transaction have finished, or a short internal timeout elapses, whichever comes first.

```ini
[Service]
Type=idle
ExecStart=/usr/bin/some-noninteractive-tool
```

This exists almost exclusively to avoid interleaving a unit's console output with the output of other units still actively starting — `getty@.service` historically used this to avoid a login prompt's output getting jumbled together with other boot-time console messages still being printed by units starting concurrently. It has essentially no relevance to dependency ordering itself (Section 3 of `02-Units-and-Dependencies.md` remains entirely unaffected — `Type=idle` does not add or remove any graph edges), and is rarely the right choice for an application service; it is included here for completeness because it does appear in distribution-shipped units you may encounter and want to understand correctly rather than misinterpret as some kind of ordering directive.

### 2.5 `Type=notify` (and `Type=notify-reload`)

The precise, correct-signal mechanism `01-Introduction.md`'s worked examples relied on without explaining. Rather than inferring readiness from process existence (`simple`/`exec`) or process exit (`forking`), the service itself **explicitly tells systemd** it has finished starting, via a dedicated, narrow IPC mechanism — the `sd_notify` protocol, covered in full mechanical detail in Section 3.

```ini
[Service]
Type=notify
ExecStart=/srv/webapp/bin/serve
NotifyAccess=main
```

The service remains in `activating` until it sends a `READY=1` notification over this channel — meaning a database connection pool warming up, a cache being populated, or any other internal initialization work can genuinely complete *before* systemd reports the unit `active` and releases anything ordered `After=` it, which is precisely the guarantee `Type=simple` cannot provide. This requires the daemon's own source code to cooperate — calling `sd_notify(0, "READY=1")` (or the equivalent via a thin shell wrapper using `systemd-notify --ready`, for daemons you can't modify directly) at the correct point in its own startup sequence — `Type=notify` is not something you can retrofit onto an arbitrary binary purely from the unit file side without either modifying it or wrapping it.

**`Type=notify-reload`** extends this to the reload path as well: the service is expected to send `RELOADING=1` upon receiving a reload request, do its reconfiguration work, and send `READY=1` again once done — giving systemd (and, transitively, `systemctl reload`'s caller, which blocks until this completes) an accurate signal for reload completion too, rather than `ExecReload=` merely being fired-and-forgotten.

### 2.6 `Type=dbus`

Similar in spirit to `Type=notify`, but the readiness signal is "this service has acquired its well-known name on the D-Bus bus," rather than an explicit `sd_notify` call.

```ini
[Service]
Type=dbus
BusName=org.example.MyService
ExecStart=/usr/lib/myservice/daemon
```

systemd watches the bus itself for the named service to appear and considers the unit started at that point — appropriate specifically for daemons whose primary integration point *is* D-Bus, where "has claimed its bus name" is already a natural, accurate proxy for "is ready," without needing the daemon to additionally implement `sd_notify` on top of the D-Bus machinery it already has.

### 2.7 Type Selection Summary

| `Type=` | Ready signal | Use when |
|---|---|---|
| `simple` | Process forked | Legacy default; prefer `exec` for new units |
| `exec` | Process `exec()`'d successfully | Foreground process, no explicit readiness needed |
| `forking` | Launching process exits | Legacy double-forking daemons only |
| `oneshot` | `ExecStart=` completes | One-time commands, migrations, setup scripts |
| `idle` | Deferred until other starts finish | Console-output ordering only, rarely applications |
| `notify` / `notify-reload` | Explicit `sd_notify` call | New daemons where accurate readiness matters |
| `dbus` | Bus name acquired | D-Bus-centric daemons |

---

## 3. The `sd_notify` Protocol in Mechanical Detail

Because `Type=notify` is the mechanism `01-Introduction.md` leaned on without explaining, and because it's genuinely the most robust option for new software, it's worth understanding precisely how the signal actually travels from daemon process to PID 1.

### 3.1 The channel

When systemd launches a `Type=notify` service, it creates an `AF_UNIX` datagram socket and exports its path to the launched process via the `NOTIFY_SOCKET` environment variable. The daemon (via `libsystemd`'s `sd_notify()` function, or the `systemd-notify` command-line helper for shell scripts and daemons you can't recompile) writes newline-separated `KEY=VALUE` messages to that socket. This is a narrow, purpose-built channel — not a general RPC mechanism — carrying a small, fixed vocabulary of state assertions.

### 3.2 The message vocabulary

| Message | Meaning |
|---|---|
| `READY=1` | Startup (or reload) is complete; transition to `active` |
| `RELOADING=1` | A reload has begun (paired with `Type=notify-reload`) |
| `STOPPING=1` | The service is beginning a graceful shutdown |
| `STATUS=<text>` | Free-text status shown in `systemctl status` output |
| `ERRNO=<n>` / `BUSERROR=<x>` | Structured error reporting on failure |
| `WATCHDOG=1` | "I am still alive" — covered in Section 3.3 |
| `MAINPID=<pid>` | Explicitly informs systemd of the main PID, for cases where the notifying process differs from the one systemd originally launched |

`STATUS=` is worth calling out specifically because it's the most visible in day-to-day operations — a well-instrumented `Type=notify` daemon that sends periodic `STATUS=` updates (`STATUS=Warming cache: 40% complete`) makes `systemctl status` genuinely informative about *what a service is currently doing*, not merely whether it's active, which is a meaningfully better operational experience than a daemon that only ever reports readiness or nothing at all.

### 3.3 The watchdog mechanism

Beyond one-time startup readiness, `Type=notify` services can opt into **ongoing liveness checking** via `WatchdogSec=`:

```ini
[Service]
Type=notify
ExecStart=/srv/webapp/bin/serve
WatchdogSec=30s
```

systemd exports the configured interval to the process via the `WATCHDOG_USEC` environment variable, and expects the daemon to send `WATCHDOG=1` at least that often, on its own internal timer, for as long as it remains healthy. If systemd does not receive a watchdog ping within the configured interval, it treats the service as having failed — even though the process itself may still technically be running — and acts according to `WatchdogSignal=`/`FailureAction=` (Section 6/9), typically restarting it. This is a meaningfully stronger liveness guarantee than "the process still exists," catching deadlocks, infinite loops, and other failure modes where a process is technically alive but has stopped making forward progress on actual work — a class of failure a simple process-existence check can never detect, but which an application-level heartbeat, wired through to systemd's own restart machinery, catches automatically.

**Gotcha:** the watchdog is opt-in on both ends — setting `WatchdogSec=` in the unit file does nothing at all for a daemon that never calls `sd_notify(0, "WATCHDOG=1")` internally; the unit file setting only configures the *timeout systemd enforces*, not the daemon's own obligation to actually ping within it, which must be implemented in the daemon's own code (typically on a background timer at roughly half the configured `WatchdogSec=`, to leave margin).

### 3.4 `NotifyAccess=`

Governs which process(es) within the unit's cgroup systemd will actually accept notification messages from — `main` (default: only the originally-launched main process), `exec` (any process from any `Exec*=` line), or `all` (any process anywhere in the cgroup). This matters specifically for services that fork internal workers where the *worker*, not the originally-launched process, ends up being the one best positioned to know when true readiness has been reached — without widening `NotifyAccess=` appropriately, a `READY=1` sent from such a worker is silently ignored, and the unit sits in `activating` until `TimeoutStartSec=` (Section 7.1) eventually fails it, with no other diagnostic beyond the eventual timeout.

---

## 4. The `Exec*=` Lifecycle Directives

A service's full lifecycle is composed of more than just the main process — systemd supports distinct hook points before, during, and after both start and stop, each with its own directive and its own failure-handling rules.

### 4.1 `ExecStartPre=`

Runs before `ExecStart=`, commonly used for setup that must complete first — creating a directory, checking a precondition, waiting for a dependency to be genuinely ready in a way the dependency graph alone can't express.

```ini
[Service]
ExecStartPre=/usr/bin/mkdir -p /var/lib/webapp/cache
ExecStartPre=/usr/local/bin/wait-for-it.sh db:5432 --timeout=30
ExecStart=/srv/webapp/bin/serve
```

Multiple `ExecStartPre=` lines run **sequentially**, in the order written, and by default a non-zero exit from any of them aborts the entire start attempt — `ExecStart=` is never reached, and the unit is considered failed to start, exactly as if `ExecStart=` itself had failed. Prefixing a command with `-` (`ExecStartPre=-/usr/bin/optional-setup.sh`) makes its exit code ignored, allowing genuinely optional pre-start steps without an unrelated failure there blocking the actual service.

### 4.2 `ExecStartPost=`

Runs after the service is considered started (per whatever `Type=` determined that, Section 2) — commonly used for registering the now-running service somewhere, sending a one-time notification, or writing a marker file.

```ini
[Service]
ExecStartPost=/usr/local/bin/register-with-consul.sh
```

Unlike `ExecStartPre=`, a failure here does **not** retroactively fail the start job — the service is already considered active by the time `ExecStartPost=` runs — but it is logged, and depending on configuration can still trigger the unit's own failure-handling path for the *post-start step itself*, distinct from the service's core running state.

### 4.3 `ExecStop=`

The command used to stop the service explicitly. If omitted entirely, systemd simply sends the configured termination signal (`KillSignal=`, Section 8) directly to the process — `ExecStop=` is only necessary when graceful shutdown requires something more specific than a signal, such as a daemon with its own control-socket-based shutdown command.

```ini
[Service]
ExecStop=/usr/local/bin/graceful-shutdown.sh
```

**Gotcha:** for `Type=notify`/`Type=dbus`/`Type=exec` services (anything where systemd is directly supervising the main process it launched), an explicit `ExecStop=` is often unnecessary — systemd already knows the main PID and can signal it directly and correctly. `ExecStop=` becomes necessary specifically when the running daemon has bespoke shutdown requirements a plain signal doesn't correctly trigger, and is easy to over-specify defensively when a signal alone would have worked identically.

### 4.4 `ExecStopPost=`

Runs unconditionally after the service has stopped, **regardless of whether the stop was clean, a crash, or a failed start** — this is the one lifecycle hook guaranteed to run in virtually every termination scenario, making it the correct place for cleanup that must happen no matter *why* the service is no longer running (removing a lock file, cleaning up a temp directory, releasing an external resource).

```ini
[Service]
ExecStopPost=/usr/bin/rm -f /run/webapp.lock
```

### 4.5 `ExecReload=`

Invoked by `systemctl reload`, expected to cause the running process to re-read its configuration **without a full stop/start cycle**.

```ini
[Service]
ExecReload=/bin/kill -HUP $MAINPID
```

`$MAINPID` here is a systemd-provided environment variable pointing at the actual running main process, correctly resolved regardless of `Type=` — this is the standard idiom for daemons that implement config-reload via a `SIGHUP` handler, which remains an extremely common pattern (`nginx`, `rsyslog`, and many others). For daemons using `Type=notify-reload` (Section 2.5), the interaction between `ExecReload=` and the `RELOADING=1`/`READY=1` notification pair gives `systemctl reload` an accurate completion signal rather than returning as soon as the signal was merely sent.

### 4.6 `ExecCondition=`

A less commonly used but precise hook: runs before `ExecStartPre=`, and if it exits non-zero, the unit is treated as **skipped**, not failed — a meaningful distinction from `ExecStartPre=`'s failure behavior. This is the correct tool for "don't run this unit at all under these circumstances, and don't report that as an error" — as opposed to `ExecStartPre=`, where a non-zero exit is always treated as a genuine failure.

```ini
[Service]
ExecCondition=/usr/local/bin/should-run-today.sh
ExecStart=/usr/local/bin/daily-batch-job.sh
```

### 4.7 Ordering summary

The complete sequence, for a normal start-then-stop lifecycle:

```
ExecCondition= → ExecStartPre= → ExecStart= → (running) → ExecStop= → ExecStopPost=
```

with `ExecStartPost=` firing once `ExecStart=` is considered "started" per `Type=` (which, for `Type=notify`, may be considerably later than when the process was actually launched), and `ExecReload=` as a separate path triggered independently of this main sequence, invoked any number of times while the service remains active.

---

## 5. `Restart=`: Automatic Recovery Policy

This directive is the mechanism that gives systemd-supervised services a self-healing property SysVinit never provided natively at all — a crashed daemon under SysVinit simply stayed dead until a human or an external monitoring script noticed and intervened.

### 5.1 The policy values

| Value | Restarts when the process exits... |
|---|---|
| `no` (default) | Never automatically |
| `always` | Unconditionally, regardless of exit reason — clean exit, error exit, or signal |
| `on-success` | Only on a clean exit (status 0, or a signal configured as a "clean" one) |
| `on-failure` | On non-zero exit, an unhandled signal, a timeout, or a failed watchdog check — the most commonly used non-default value |
| `on-abnormal` | On an unhandled signal, timeout, or watchdog failure — but *not* a plain non-zero exit |
| `on-abort` | Only on an unhandled signal |
| `on-watchdog` | Only when the watchdog timeout (Section 3.3) specifically was the trigger |

```ini
[Service]
Restart=on-failure
RestartSec=5s
```

`on-failure` is the standard choice for the overwhelming majority of long-running application services — restart on a crash or non-zero exit, but do not restart following a deliberate, clean `systemctl stop` (which is not treated as a "failure" for this purpose regardless of the policy chosen; an explicitly requested stop never triggers `Restart=`, under any of these values — this is a deliberate, universal exception, not something `on-failure` specifically opts into).

### 5.2 `RestartSec=` and backoff

`RestartSec=` sets the delay between the process exiting and systemd attempting to start it again — a flat delay by default, existing specifically to avoid a tight, CPU-consuming crash loop where a persistently broken service is relaunched thousands of times a second.

Newer systemd versions additionally support **`RestartSteps=`** and **`RestartMaxDelaySec=`**, which turn this into a genuine exponential backoff rather than a flat delay:

```ini
[Service]
Restart=on-failure
RestartSec=1s
RestartSteps=5
RestartMaxDelaySec=30s
```

This configuration starts at a 1-second delay and increases across 5 steps up to a ceiling of 30 seconds, rather than retrying every single second indefinitely against a dependency that's going to take a full minute to recover — meaningfully reducing load against a downstream system that's already struggling, compared to a flat, aggressive retry interval hammering it throughout an outage.

### 5.3 Interaction with the dependency graph

It's worth being explicit about something `02-Units-and-Dependencies.md` didn't cover, because `Restart=` sits slightly outside the pure requirement/ordering model: a unit restarting due to `Restart=` does **not** re-trigger the dependency graph resolution that happened at the original start — it does not re-check `Requires=`/`Wants=` targets, and does not re-run `ExecStartPre=` conditions that were satisfied once at initial boot but might no longer hold (a `Requisite=` check, for instance, is not re-evaluated on an automatic restart the way it would be on a fresh, externally-requested start). This means a service that automatically restarts many times over a long uptime is not receiving the same startup-time safety guarantees fresh boots receive — it is trusting that the conditions checked once, long ago, still hold, which is usually true but is a real, if subtle, distinction worth knowing when debugging a service that behaves correctly on a clean boot but oddly after its fifth automatic restart three days into an incident.

---

## 6. Start-Rate Limiting

Without a circuit breaker, a service with `Restart=always` and a bug causing it to crash instantly on every launch would restart, effectively, as fast as the kernel can schedule new processes — consuming CPU, filling the journal, and providing zero operational value. `StartLimitIntervalSec=` and `StartLimitBurst=` exist specifically to prevent this.

```ini
[Service]
Restart=on-failure
RestartSec=2s
StartLimitIntervalSec=60s
StartLimitBurst=5
```

This configuration means: if the unit is started (including automatic `Restart=`-triggered starts) more than 5 times within any rolling 60-second window, systemd stops attempting further restarts entirely and transitions the unit to `failed` — not merely "delayed," but genuinely given up on, requiring an explicit `systemctl reset-failed` (Section 11) followed by a manual `systemctl start` before it will be attempted again. This is a hard stop, not a backoff — distinct from the `RestartSteps=` mechanism in Section 5.2, which slows retries down but never stops them outright; `StartLimitBurst=`/`StartLimitIntervalSec=` is the actual ceiling that eventually says "no more automatic attempts," and the two mechanisms are commonly used together — backoff to reduce load during a recoverable outage, with a hard limit as the final backstop against a genuinely unrecoverable, instantly-crashing configuration.

`StartLimitAction=` configures what happens, beyond simply marking the unit `failed`, once this limit is hit — options include rebooting the machine (`reboot`, `reboot-force`) or halting it, intended for the rare case where a critical service's complete inability to stay up should be treated as a signal the whole system needs external intervention, not merely that one service should sit idle in `failed` state.

---

## 7. Timeouts

### 7.1 `TimeoutStartSec=`

The maximum time systemd waits for the unit to reach `active` (per whatever signal `Type=` defines, Section 2) before giving up and treating the start as failed.

```ini
[Service]
Type=notify
TimeoutStartSec=90s
```

For `Type=notify` specifically, this bounds how long systemd will wait for `READY=1` — a daemon that hangs indefinitely during its own initialization, never sending the notification, will have its start job forcibly failed at this timeout rather than leaving the transaction (and everything ordered `After=` it) blocked forever.

### 7.2 `TimeoutStopSec=`

The maximum time systemd allows for graceful shutdown (`ExecStop=`, or the default termination signal, plus the process actually exiting) before escalating to a forced kill.

```ini
[Service]
TimeoutStopSec=30s
```

If the process hasn't exited within this window, systemd sends `SIGKILL` to the entire cgroup (Section 8), unconditionally terminating it regardless of whatever graceful-shutdown logic it may have still been mid-way through — this is a deliberate, non-negotiable backstop, ensuring `systemctl stop` (and, transitively, system shutdown itself) cannot be blocked indefinitely by a single misbehaving service.

### 7.3 `TimeoutAbortSec=`

A more specific timeout applying to the watchdog-triggered shutdown path specifically (Section 3.3) — bounding how long systemd waits for a service that failed its watchdog check to actually terminate once systemd has decided to kill it, separate from the general `TimeoutStopSec=` governing ordinary, deliberately-requested stops.

### 7.4 `TimeoutSec=`

A convenience shorthand that sets both `TimeoutStartSec=` and `TimeoutStopSec=` to the same value in one line, when there's no need to differentiate between them.

---

## 8. Kill Behavior

### 8.1 `KillMode=`

Controls precisely which processes receive the termination signal when a unit is stopped.

| Value | Behavior |
|---|---|
| `control-group` (default) | Every process in the unit's cgroup receives the signal |
| `mixed` | The main process receives `SIGTERM` first; after `TimeoutStopSec=`, `SIGKILL` is sent to the *entire remaining cgroup* |
| `process` | Only the main process is signaled at all — other processes in the cgroup are left entirely alone |
| `none` | No signal is sent by systemd at all; the unit is expected to handle its own complete shutdown |

```ini
[Service]
KillMode=mixed
```

The default, `control-group`, is almost always correct and is precisely what makes the cgroup-based process tracking described in `01-Introduction.md` Section 9 actually pay off at shutdown time — every descendant process, including ones the daemon itself may have forgotten about or failed to reap, is reliably terminated. `KillMode=process` is a narrow exception, occasionally used when a service deliberately spawns long-lived helper processes that are meant to *outlive* the parent unit being stopped — a genuinely rare and specific requirement, not a default to reach for casually, since it reintroduces exactly the orphaned-process risk cgroup-based tracking exists to eliminate.

### 8.2 `KillSignal=` and `FinalKillSignal=`

`KillSignal=` (default `SIGTERM`) sets the initial, graceful termination signal. `FinalKillSignal=` (default `SIGKILL`) sets the signal used for the forced escalation once `TimeoutStopSec=` elapses without the process having exited. Some applications expect a different graceful-shutdown signal convention (`SIGINT`, or a custom signal used for a specific internal shutdown handler) — `KillSignal=` lets the unit file match the daemon's actual expectations rather than forcing every service into the `SIGTERM` convention regardless of what its own code actually listens for.

### 8.3 `SendSIGKILL=`

A boolean (default `yes`) governing whether the forced `SIGKILL` escalation happens at all after `TimeoutStopSec=` — setting it to `no` means a process that ignores `SIGTERM` (or whatever `KillSignal=` is configured to) indefinitely will simply be left running indefinitely as well, rather than being force-killed. This is rarely what you actually want in production — it exists primarily for narrow debugging scenarios where you deliberately need to inspect a hung process's state rather than have systemd terminate it out from under you.

### 8.4 `WatchdogSignal=`

The specific signal sent to a service that has failed its `WatchdogSec=` liveness check (Section 3.3) — defaulting to `SIGABRT`, deliberately different from the plain `KillSignal=` used for an ordinary stop, since a watchdog failure often warrants a signal that produces a core dump or otherwise captures diagnostic state about *why* the process stopped making progress, which a routine `SIGTERM` shutdown has no need to produce.

---

## 9. `FailureAction=` and `SuccessAction=`

Distinct from `OnFailure=`/`OnSuccess=` covered in `02-Units-and-Dependencies.md` Section 5.2 — those trigger *another unit*; `FailureAction=`/`SuccessAction=` instead trigger a **system-level action** directly, without needing a separate helper unit at all.

```ini
[Service]
FailureAction=none
```

Values include `none` (default — do nothing beyond marking the unit failed), `reboot`, `reboot-force`, `poweroff`, `poweroff-force`, `exit`, and `exit-force` — reserved for genuinely critical services where their failure should be treated as cause for restarting or halting the entire machine, not merely logged. This is a blunt, system-wide instrument and is appropriately rare in ordinary application unit files; it appears far more often in infrastructure-level units where "this specific safety-critical component failing" genuinely should escalate beyond the scope of that one unit. `FailureActionExitStatus=` lets you pin a specific exit code to the `exit`/`exit-force` variants, useful when systemd itself is running inside a container and the surrounding orchestrator inspects PID 1's own exit status to decide how to react.

**A concrete case for `reboot-force`:** consider a unit responsible for mounting and validating a redundant storage array at boot, upstream of every other data-dependent service on the machine. If this unit exhausts its own `StartLimitBurst=` — meaning even repeated attempts across the configured interval couldn't bring the array to a valid state — continuing to boot into a state where dozens of dependent services either fail (via `Requires=`, per `02-Units-and-Dependencies.md` Section 2.2) or, worse, silently run against missing or partial data is arguably worse than a further reboot attempt, on the theory that a fresh boot occasionally clears a transient hardware-initialization race that a same-session retry cannot. `FailureAction=reboot-force` (skipping graceful shutdown of everything else, since the array unit's own failure means a graceful shutdown might itself behave unpredictably) encodes this judgment call directly into the unit definition, rather than relying on an external monitoring system to notice the failure and trigger the same reboot minutes later, at greater cost to overall availability.

### 9.1 Scaling Services with Templates: A Preview

Every worked example in this document has been a single, uniquely-named service. Real deployments frequently need several near-identical instances of the same service — worker processes on different queues, or the same application bound to multiple ports — and `02-Units-and-Dependencies.md` Section 15 introduced the `@`-suffixed template mechanism in the context of dependency edges (`After=getty@tty1.service`). The full templated-unit syntax is the subject of `04-Unit-Files.md`, but it's worth a brief preview here specifically because every `Type=`/`Restart=`/timeout directive covered in this document applies identically, unchanged, to a template — a `worker@.service` template with `Restart=on-failure` and `StartLimitBurst=5` applies that policy **independently, per instance**:

```ini
# /etc/systemd/system/worker@.service
[Service]
Type=notify
ExecStart=/srv/webapp/bin/worker --queue=%i
Restart=on-failure
RestartSec=2s
StartLimitIntervalSec=60s
StartLimitBurst=5
```

```bash
systemctl enable --now worker@emails.service
systemctl enable --now worker@thumbnails.service
systemctl enable --now worker@exports.service
```

Each instance (`worker@emails.service`, `worker@thumbnails.service`, `worker@exports.service`) is tracked as a genuinely separate unit with its own state machine (Section 1), its own restart counter and start-limit window (Section 6), and its own cgroup — a crash loop in `worker@exports.service` trips *only* that instance's `StartLimitBurst=` and leaves the other two entirely unaffected, without any special configuration beyond the template mechanism itself providing this isolation for free. This is directly relevant to the `Restart=`/watchdog machinery this document has covered in depth: none of it needs to be reconsidered or specially adapted for the scaled, multi-instance case — it was never coupled to a single, uniquely-named unit in the first place, only to *a* unit, and a template instance is, for every purpose this document has discussed, simply a unit like any other.

---

## 10. `RemainAfterExit=` Beyond `Type=oneshot`

Section 2.3 introduced `RemainAfterExit=` in the context of `Type=oneshot`, but it is worth a dedicated, standalone treatment because its interaction with the dependency graph is a common source of confusion independent of which `Type=` it's paired with. Setting `RemainAfterExit=yes` on any service type means systemd continues reporting the unit `active` after its main process exits, **as long as that exit was clean** (or matched whatever `SuccessExitStatus=` was configured) — a service that exits with a failure code still transitions to `failed` even with `RemainAfterExit=yes` set, this directive only changes the *successful*-exit behavior. The practical effect is turning a service that models "a condition that, once true, stays true until something explicitly changes it" — a one-time environment setup, a feature flag being enabled, a piece of hardware being initialized — into something the dependency graph can correctly treat as a standing precondition (`Requires=`) rather than something that needs to be perpetually re-checked.

---

## 11. `Condition*=` and `Assert*=`: Guarded Execution

Beyond `ExecCondition=` (Section 4.6), which runs an arbitrary command and treats its exit code as a skip/proceed signal, systemd provides a large family of built-in `Condition*=`/`Assert*=` directives that check specific, common facts about the system directly — no external command needed — before deciding whether to actually attempt starting a unit at all.

```ini
[Unit]
ConditionPathExists=/etc/webapp/enabled
ConditionVirtualization=!container
AssertPathIsReadWrite=/srv/webapp/data
```

The distinction between the two families is precise and important: a **`Condition*=`** that evaluates false causes the unit to be **skipped silently** — logged at a low severity, the job reported as successful-but-skipped, no failure recorded against the unit at all. An **`Assert*=`** that evaluates false causes the unit's start job to **fail outright**, exactly as if `ExecStartPre=` had failed. Both families check the same broad categories of fact — the difference is purely in how a false result is reported and handled downstream.

Common members of this family include `ConditionPathExists=`/`ConditionPathExistsGlob=` (a file or glob pattern is present), `ConditionPathIsDirectory=`/`ConditionPathIsSymbolicLink=`, `ConditionDirectoryNotEmpty=`, `ConditionFileNotEmpty=`, `ConditionUser=`/`ConditionGroup=` (the unit is being started as a specific user context), `ConditionVirtualization=` (running inside/outside a VM or container, and which kind), `ConditionKernelCommandLine=` (a specific boot parameter is present), `ConditionFirstBoot=`, and `ConditionACPower=` (relevant to laptops and power-sensitive scheduled tasks, covered again in `07-Timers-and-Scheduled-Tasks.md`).

**Practical distinction from the dependency directives in `02-Units-and-Dependencies.md`:** `Condition*=`/`Assert*=` express facts about the *environment* — is this file present, is this the right kind of virtualization, is this the first boot — not relationships to *other units*. A unit that should only run inside a container has no natural corresponding "unit" to express `Requires=`/`After=` against; `ConditionVirtualization=` is the correct tool precisely because there is no graph edge that could express this kind of environmental fact.

**Multiple conditions of the same type are OR'd together; conditions of different types are AND'd.** Two `ConditionPathExists=` lines mean "either of these files being present is sufficient"; a `ConditionPathExists=` combined with a `ConditionVirtualization=` means both must independently hold. This asymmetry is easy to get backwards when a unit accumulates several condition lines over time from different contributors, each assuming AND semantics uniformly.

---

## 12. Environment and Execution Context

Two directives govern what a launched process actually sees in its own environment, worth a brief mention here even though `04-Unit-Files.md` covers the complete `systemd.exec(5)` execution-context reference in full.

```ini
[Service]
Environment=LOG_LEVEL=info
Environment=CACHE_DIR=/var/lib/webapp/cache
EnvironmentFile=/etc/webapp/secrets.env
User=webapp
Group=webapp
WorkingDirectory=/srv/webapp
```

`Environment=` sets variables directly, inline in the unit file — appropriate for non-sensitive configuration, but a poor fit for secrets, since unit files are frequently world-readable and, more importantly, their contents (including inline `Environment=` values) are visible via `systemctl show`/`systemctl cat` to any user permitted to inspect the unit at all. `EnvironmentFile=` instead points at an external file of `KEY=VALUE` lines, loaded at launch time — critically, that file can be permissioned far more restrictively (`0600`, owned by root or the service's own user) than the unit file itself, which is the standard pattern for injecting secrets (database passwords, API keys) without embedding them in unit-file text that ends up readable through ordinary `systemctl` introspection commands.

---

## 13. A Fully Worked Example: Complete Lifecycle Under Failure

Extending the `webapp.service` from `02-Units-and-Dependencies.md` Section 13 with the full set of directives this document has covered:

```ini
# /etc/systemd/system/webapp.service
[Unit]
Description=Example web application
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service
OnFailure=alert-oncall.service

[Service]
Type=notify
User=webapp
WorkingDirectory=/srv/webapp
EnvironmentFile=/etc/webapp/secrets.env
ExecStartPre=/usr/bin/mkdir -p /var/lib/webapp/cache
ExecStart=/srv/webapp/bin/serve
ExecReload=/bin/kill -HUP $MAINPID
ExecStopPost=/usr/bin/rm -f /run/webapp.lock
Restart=on-failure
RestartSec=2s
RestartSteps=4
RestartMaxDelaySec=20s
StartLimitIntervalSec=120s
StartLimitBurst=6
TimeoutStartSec=60s
TimeoutStopSec=30s
WatchdogSec=15s
KillMode=mixed

[Install]
WantedBy=multi-user.target
```

Trace what actually happens if the application begins deadlocking under load, hanging without crashing:

1. The process is still technically running — no exit, no signal, nothing a plain `Type=simple` supervision model would ever notice.
2. Because `Type=notify` and `WatchdogSec=15s` are configured, and the daemon's own internal heartbeat (implemented in its own source, per Section 3.3) has stopped sending `WATCHDOG=1` because its main loop is deadlocked, systemd detects the missed watchdog window after 15 seconds.
3. systemd treats this as a failure and initiates a stop, per `KillMode=mixed`: `SIGTERM` to the main process first.
4. The deadlocked process does not respond to `SIGTERM` (it's genuinely stuck, not merely slow) — after `TimeoutStopSec=30s`, `SIGKILL` is sent to the entire remaining cgroup.
5. `ExecStopPost=` runs unconditionally, removing the stale lock file regardless of the abnormal termination.
6. `Restart=on-failure` triggers; the watchdog-triggered failure qualifies. `RestartSec=2s` (the first step of the configured `RestartSteps=4` backoff) delays the relaunch briefly.
7. The unit restarts. `ExecStartPre=` re-runs, `ExecStart=` launches a fresh process, and `Type=notify` waits for a new `READY=1` before reporting `active` again.
8. If this cycle repeats 6 times within the configured 120-second `StartLimitIntervalSec=` window — say, the deadlock is triggered by every request under current load, and each fresh instance deadlocks again within seconds — the unit is marked `failed` outright, no further automatic restarts are attempted, and `OnFailure=alert-oncall.service` fires, notifying a human that automatic recovery has been exhausted.

The corresponding `journalctl -u webapp.service` excerpt for one such cycle:

```
systemd[1]: webapp.service: Watchdog timeout (limit 15s)!
systemd[1]: webapp.service: Killing process 4821 (serve) with signal SIGTERM.
systemd[1]: webapp.service: State 'stop-sigterm' timed out. Killing.
systemd[1]: webapp.service: Killing process 4821 (serve) with signal SIGKILL.
systemd[1]: webapp.service: Failed with result 'watchdog'.
systemd[1]: webapp.service: Scheduled restart job, restart counter is at 5.
systemd[1]: Starting Example web application...
systemd[1]: webapp.service: Start request repeated too quickly.
systemd[1]: webapp.service: Failed with result 'start-limit-hit'.
systemd[1]: Starting alert-oncall.service...
```

`result 'watchdog'` versus the final `result 'start-limit-hit'` are the two log phrases worth specifically recognizing here — the first tells you *why* an individual restart cycle was triggered, the second tells you *why systemd eventually gave up entirely*, and distinguishing them is the fastest way to understand, from logs alone, whether you're looking at "one bad request that's since resolved" versus "a persistent problem systemd has already stopped trying to auto-recover from."

### 13.1 Cross-Checking with `systemd-cgls` Mid-Incident

The journal excerpt above tells you what already happened. While a service is actively deadlocked but *before* the watchdog timeout has fired — in the window where you might be paged and investigating live — `systemd-cgls`, briefly introduced conceptually in `01-Introduction.md` Section 9, is the direct way to confirm the process tree systemd is actually tracking, independent of anything the application itself is reporting (which, if it's deadlocked, may not be reporting anything useful at all):

```bash
systemd-cgls /system.slice/webapp.service
```

```
Control group /system.slice/webapp.service:
├─4821 /srv/webapp/bin/serve
├─4830 worker: request handler 1
└─4831 worker: request handler 2
```

Cross-referencing this against `ps -o pid,stat,etime -p 4821,4830,4831` (checking process state and elapsed CPU time) at this stage is often what actually confirms "yes, this is genuinely hung, not merely slow" ahead of the watchdog's own eventual determination — a process sitting in uninterruptible sleep (`D` state) for an extended `etime` alongside zero CPU-time growth is a strong independent signal corroborating a suspected deadlock, useful context to have gathered before the automatic restart cycle in Section 13.2 begins and the original hung process's state becomes unavailable for inspection.

### 13.2 A Second Scenario: `Type=forking` with a Stale PID File

The failure mode above is specific to `Type=notify`. It's worth contrasting with a failure mode specific to `Type=forking` (Section 2.2), because the two `Type=` values fail in genuinely different, characteristic ways that are worth being able to tell apart from symptoms alone.

Consider `legacy-daemon.service` from Section 2.2's example, with `PIDFile=/run/legacy-daemon.pid`. Suppose the machine loses power uncleanly, and on the next boot the stale PID file from before the crash is still present on disk (having been written to a filesystem that was not properly unmounted), now pointing at a PID that either doesn't exist or, worse, has since been reused by an entirely unrelated process the kernel happened to assign that number to.

1. systemd launches the daemon per `ExecStart=`. The daemon double-forks as expected, and the launching process exits — satisfying `Type=forking`'s readiness signal (Section 2.2) regardless of what the stale PID file says, since that signal is about the *launching* process exiting, not about the PID file's contents.
2. systemd reads `PIDFile=` to determine the "main" PID for status/signal purposes — and here is where the divergence happens: if the daemon itself rewrites the PID file with its own actual PID as part of its own startup (the common, correct convention), the stale value is overwritten and no problem occurs. If, however, the daemon has a bug where it fails to rewrite the file under some specific condition, systemd is left believing the main PID is the stale, wrong value.
3. `systemctl status legacy-daemon.service` in this broken state may show `Main PID: 2201 (some-unrelated-process)` — an entirely different program's name — because systemd is faithfully reporting whatever process the (wrong) PID currently refers to, having no independent way to know the number is stale.
4. Critically, this does **not** affect actual process supervision or shutdown correctness — as emphasized in Section 2.2 and `01-Introduction.md` Section 9, cgroup-based tracking is entirely independent of `PIDFile=`, so `systemctl stop legacy-daemon.service` still correctly terminates every process in the unit's actual cgroup regardless of what the PID file claims. The blast radius of this specific bug class is limited to *misleading status output and misdirected signals sent via `kill -PID` outside of systemd* (an administrator manually running `kill 2201` based on trusting the stale reported PID, for instance) — a good illustration of why the cgroup-based model exists as the actual source of truth, with `PIDFile=` serving only a cosmetic, best-effort reporting role on top of it.

This contrast — a `Type=notify` failure manifesting as a clean, well-signaled restart cycle with precise log phrases, versus a `Type=forking` failure manifesting as silently misleading status output with no restart triggered at all, since nothing about the scenario actually violates any condition `Restart=` checks — is a genuinely useful diagnostic instinct: when a service "looks fine" per `systemctl status` but behaves oddly, checking whether it's `Type=forking` with a `PIDFile=` is a reasonable early hypothesis before assuming the application logic itself is at fault.

---

## 14. `systemd-run`: Transient, Ad-Hoc Services

Every example so far has been a unit file written to disk ahead of time. `systemd-run` instead constructs and starts a **transient unit** — one that exists only in systemd's in-memory state for as long as it's needed, with no corresponding file under `/etc/systemd/system/` at all — directly from a command line invocation, and is worth knowing about because it gives you the entire supervision/cgroup/logging machinery this document has covered for a one-off command, without the ceremony of authoring a unit file first.

```bash
systemd-run --unit=one-off-backup --description="Ad-hoc backup run" \
  --property=Restart=no \
  /usr/local/bin/backup.sh /srv/webapp/data
```

This launches `/usr/local/bin/backup.sh` as a fully-fledged, cgroup-tracked, journal-logged unit named `one-off-backup.service`, inspectable with the exact same `systemctl status`/`journalctl -u` commands used throughout this document, and cleaned up automatically once it exits (for a `Type=oneshot`-equivalent transient unit) or left running under normal supervision (for a long-running command, with `--property=` accepting any directive from this document — `Restart=`, `MemoryMax=`, and the rest — applied to the transient unit exactly as it would be to one defined in a file).

**`--scope`** is a related but distinct mode: rather than asking systemd to *launch* a new process, it wraps an **already-running, externally-started process tree** into a `.scope` unit — placing it under the same cgroup-based tracking and resource-control machinery post hoc, useful for bringing an ad-hoc, manually-started process under systemd's supervision umbrella without having originally started it via `systemd-run` or a unit file.

`systemd-run --user` (Section 12's `User=` directive has a broader analogue here) launches a transient unit under the invoking user's own systemd **user instance** rather than the system-wide PID 1 — relevant for desktop session management and covered more fully in the context of `systemd-logind` integration outside the scope of this series, but worth knowing exists as the mechanism behind, for instance, a desktop environment's own per-user background services.

---

## 15. Service-Specific `systemctl` Commands

Beyond the general-purpose commands introduced in `01-Introduction.md` Section 10, several are specific to the failure/restart mechanics covered in this document.

```bash
systemctl reset-failed webapp.service   # clear the failed state and restart counter,
                                          # required after a StartLimitBurst= trip
                                          # before automatic restart will resume
systemctl kill webapp.service            # send a signal directly, bypassing ExecStop=
systemctl kill -s SIGUSR1 webapp.service # send a specific, non-default signal
systemctl show webapp.service            # dump every resolved property, including
                                          # effective Restart=/TimeoutStartSec=/etc.,
                                          # after all drop-ins are merged
systemctl set-property webapp.service MemoryMax=512M   # change a runtime-adjustable
                                                          # property without editing
                                                          # the unit file at all
```

`reset-failed` deserves particular emphasis given Section 6: after a `StartLimitBurst=` trip, the unit sits in `failed` state indefinitely, and neither time passing nor the underlying problem being fixed will bring it back on its own — `systemctl reset-failed` (implicitly run by a plain `systemctl start` in recent systemd versions, but worth knowing explicitly for older ones and for scripted remediation) is the required step before automatic `Restart=` resumes functioning again.

`systemctl show webapp.service --property=Restart,TimeoutStartSec` narrows the otherwise-overwhelming full property dump to specific fields of interest — useful when you specifically want to confirm the *effective*, post-drop-in-merge value of one or two directives rather than scrolling through the complete output.

---

## 16. Comparison to Standalone Process Supervisors

It's reasonable to ask, given the depth of the `Restart=`/watchdog/timeout machinery covered above, how this compares to purpose-built process supervisors like `supervisord` or `runit`, which some environments run *on top of* systemd, or in its place inside containers. The comparison is worth making explicit because the answer is genuinely "it depends on the deployment context," not a one-sided recommendation.

| Concern | systemd | supervisord | runit |
|---|---|---|---|
| Process tracking | Kernel cgroups — cannot be fooled by forking/orphaning | Direct child PID only, by default | Direct child PID only |
| Init-system integration | Native — is PID 1 itself | None — runs as an ordinary managed process, itself needing supervision | None, similarly |
| Dependency graph | Full graph, per `02-Units-and-Dependencies.md` | Simple priority-ordered start sequence, no real graph | Minimal — mostly independent services |
| Logging | Structured, integrated `journald` | Plain-text log files per process | Plain-text via `svlogd` |
| Socket activation | Native | Not supported | Not supported |
| Typical deployment | Bare-metal and VM hosts | Inside containers, or on hosts without systemd | Inside containers, minimal base images |

The practical pattern in containerized deployments specifically: a container's PID 1 is very often *not* systemd at all (many base images have no init system running as PID 1, running the application directly as PID 1 instead) — in that context, `supervisord` or a similarly lightweight supervisor exists to fill a gap systemd would otherwise fill on a bare-metal host, precisely because the container has opted out of running a full init system for image-size and simplicity reasons. This is not a case of one tool being categorically better — it's a reflection of the fact that systemd's full graph/cgroup/logging machinery has a footprint and a set of assumptions (a persistent, single-tenant OS instance) that doesn't always fit a minimal, single-process container image, whereas it's close to unconditionally the right choice on a persistent host or VM actually running its own full init system. Running systemd itself *inside* a container is possible and occasionally done (for genuinely systemd-dependent workloads, or nested-virtualization-style testing scenarios) but requires specific container runtime accommodations (cgroup delegation, particular mount configurations) beyond the scope of this document.

---

## 17. Common Anti-Patterns

**Using `Type=simple` for a service with real dependents that need accurate readiness.** As covered in Section 2.1's gotcha, this is the single most common source of "my dependent started before its dependency was actually ready" bugs that survive *despite* correct `Requires=`/`After=` graph edges — the graph edges only guarantee the dependency's *process* exists, not that `Type=simple` reported readiness at a meaningful moment.

**Setting `WatchdogSec=` without the daemon actually implementing the corresponding `sd_notify` calls.** As covered in Section 3.3's gotcha, the unit-file setting alone accomplishes nothing without matching application code — it is easy to copy this directive into a unit file for a daemon that was never written to support it, silently getting no benefit at all while appearing configured correctly.

**`Restart=always` without any `StartLimitBurst=`/`StartLimitIntervalSec=` tuning.** Modern systemd ships reasonable defaults for these, but relying on defaults without deliberately considering whether they fit a *specific* service's actual expected failure characteristics is a common gap — a service expected to occasionally need several legitimate quick restarts during, say, a rolling dependency upgrade can trip a default limit that was never tuned with that scenario in mind.

**Reaching for `KillMode=process` defensively.** As covered in Section 8.1, this specifically reintroduces the orphaned-process risk that cgroup-based supervision (`01-Introduction.md` Section 9) exists to eliminate, and should be a deliberate, narrow exception, not a default reached for out of caution.

**Treating `ExecStop=` as always necessary.** As covered in Section 4.3's gotcha, many services need no `ExecStop=` at all — a plain signal, which systemd sends automatically regardless, is frequently sufficient, and an unnecessary custom `ExecStop=` script is one more thing that can itself fail or hang during shutdown.

**Confusing `ExecStartPre=` failure semantics with `ExecCondition=`'s.** As covered in Section 4.6, a non-zero `ExecStartPre=` is always a genuine failure; only `ExecCondition=` treats a non-zero exit as "skip, don't fail" — using the wrong one for a "don't run under these circumstances" check produces a unit that reports `failed` (and, if `OnFailure=` is configured, triggers alerting) for what was actually an entirely intentional, expected skip.

**Putting secrets in `Environment=` instead of a restrictively-permissioned `EnvironmentFile=`.** As covered in Section 11, inline `Environment=` values are visible through ordinary, unprivileged `systemctl show`/`cat` introspection to anyone permitted to inspect the unit at all — a materially weaker guarantee than a separately-permissioned file most users on the system cannot read regardless of their `systemctl` access.

---

## 18. Exercises

**1.** A service is `Type=simple` with a slow internal cache-warming step taking roughly ten seconds after the process starts. A dependent unit has `Requires=` and `After=` correctly set against it. Does the dependent wait for the cache-warming to finish? *(No — `Type=simple` reports the unit `active` the instant the process is forked, regardless of internal readiness; the correctly-configured graph edges only guarantee the dependent waits for the *process* to exist, not for cache-warming specifically, which is exactly the gap `Type=notify` closes.)*

**2.** A `Type=oneshot` unit with no `RemainAfterExit=` is `Required=` by another unit. The oneshot runs successfully once at boot. Later, a third unit triggers a fresh transaction that also requires the oneshot. What happens? *(Because the oneshot reverted to `inactive` after its first run — `RemainAfterExit=` was not set — systemd sees the requirement as currently unmet and re-runs the oneshot's `ExecStart=` a second time as part of the new transaction, which is very likely not intended for something like a one-time migration.)*

**3.** `Restart=on-failure` and `KillMode=control-group` are both set. An administrator runs `systemctl stop` on the unit. Does it restart? *(No — an explicitly requested stop is never treated as a failure for `Restart=` purposes, under any policy value including `on-failure`; this exception is unconditional and independent of `KillMode=`, which only governs *which processes* receive the stop signal, not whether the stop itself counts as a failure.)*

**4.** A unit hits its `StartLimitBurst=` and transitions to `failed`. The underlying bug causing the crashes is then fixed and deployed. Does the unit come back on its own? *(No — per Section 15, a `failed` unit past its start-limit requires an explicit `systemctl reset-failed` (or, on recent systemd, a plain `systemctl start`, which performs the reset implicitly) before automatic `Restart=` behavior resumes; the fix being deployed has no effect on the unit's already-tripped, latched failure state by itself.)*

**5.** A `Type=notify` daemon forks an internal worker process, and it's the worker — not the originally-launched process — that determines true readiness and calls `sd_notify(READY=1)`. `NotifyAccess=` is left at its default. What happens? *(Per Section 3.4, the default `NotifyAccess=main` only accepts notifications from the originally-launched process; the worker's `READY=1` is silently discarded, and the unit remains in `activating` until `TimeoutStartSec=` eventually fails the start — the fix is widening `NotifyAccess=` to `all` or `exec`.)*

**6.** A unit has two lines: `ConditionPathExists=/etc/webapp/feature-a.enabled` and `ConditionPathExists=/etc/webapp/feature-b.enabled`. Only `feature-a.enabled` exists on disk. Does the unit start? *(Yes — per Section 11, multiple `Condition*=` directives of the *same* type are OR'd together, not AND'd; either file being present is sufficient, which is easy to misread as requiring both.)*

**7.** The same unit instead has `ConditionPathExists=/etc/webapp/feature-a.enabled` and `AssertPathExists=/etc/webapp/feature-b.enabled`, and only `feature-a.enabled` is present. What happens? *(The `Condition*=` and `Assert*=` families are evaluated independently and both must pass, per Section 11's AND-across-different-directive-types rule; the missing `AssertPathExists=` target causes the start job to fail outright — logged and reported as a genuine failure — rather than being silently skipped the way a failing `Condition*=` alone would be.)*

---

## 19. Quick-Reference Table

| Directive | Section | Governs |
|---|---|---|
| `Type=` | 2 | What "started" means |
| `NotifyAccess=` | 3.4 | Which process(es) may send `sd_notify` messages |
| `Restart=` | 5.1 | Whether/when to auto-restart after exit |
| `RestartSec=` / `RestartSteps=` | 5.2 | Delay (fixed or backoff) between restart attempts |
| `StartLimitIntervalSec=` / `StartLimitBurst=` | 6 | Rate limit on restarts before giving up entirely |
| `StartLimitAction=` | 6 | Escalation (e.g., reboot) on exhausted start limit |
| `ExecCondition=` | 4.6 | Silent skip if unmet |
| `ExecStartPre=` | 4.1 | Loud start-failure if unmet |
| `ExecStartPost=` | 4.2 | Runs after readiness is reached |
| `ExecStop=` | 4.3 | Custom graceful-shutdown command |
| `ExecStopPost=` | 4.4 | Unconditional cleanup, success or failure |
| `ExecReload=` | 4.5 | `systemctl reload` behavior |
| `KillMode=` / `KillSignal=` / `FinalKillSignal=` | 8 | Exact stop-signal mechanics |
| `TimeoutStartSec=` / `TimeoutStopSec=` | 7 | Deadlines before failure/force-kill |
| `RemainAfterExit=` | 10 | Whether a unit stays `active` post-exit |
| `WatchdogSec=` | 3.3 | Ongoing liveness check via periodic `WATCHDOG=1` |
| `Environment=` / `EnvironmentFile=` | 11 | Process environment configuration |
| `User=` / `Group=` / `WorkingDirectory=` | 11 | Basic execution identity/context |

---

## 20. Glossary

**Readiness signal** — the specific event, defined by `Type=`, that causes systemd to consider a unit `active`.
**Watchdog ping** — a periodic `WATCHDOG=1` `sd_notify` message proving ongoing liveness, distinct from the one-time `READY=1` startup signal.
**Crash loop** — a service repeatedly failing and being restarted in quick succession, bounded by `StartLimitBurst=`/`StartLimitIntervalSec=`.
**Start-limit trip** — the terminal `failed` state reached when `StartLimitBurst=` is exceeded within `StartLimitIntervalSec=`, requiring explicit reset.
**Backoff** — the increasing delay between successive automatic restarts, configured via `RestartSteps=`/`RestartMaxDelaySec=`.
**Escalation** — the forced `SIGKILL` sent after `TimeoutStopSec=` elapses without a graceful exit.
**Transient unit** — a unit created on the fly via `systemd-run`, existing only in memory with no backing file on disk.
**Guarded execution** — the collective term for `Condition*=`/`Assert*=`/`ExecCondition=` checks that gate whether a unit's `ExecStart=` runs at all.
**Silent skip** — the outcome of a failed `Condition*=` check: the job is reported successful-but-skipped, with no failure recorded.
**Loud failure** — the outcome of a failed `Assert*=` check or a failed `ExecStartPre=`: the start job fails outright, identically to `ExecStart=` itself failing.

---

## 21. Pre-Deployment Checklist

Mirroring `02-Units-and-Dependencies.md` Section 18a, a short sequence worth running through before shipping a new or modified `.service` unit, specifically targeting the failure modes this document has covered:

1. **Confirm the `Type=` actually matches what the daemon does.** A daemon that double-forks needs `Type=forking`; one that calls `sd_notify` needs `Type=notify` (and `NotifyAccess=` widened if a worker process sends the notification, per Exercise 5); anything else defaults to `Type=exec` being the more precise, modern choice over `Type=simple`.
2. **If `Restart=` is anything other than `no`, confirm `StartLimitBurst=`/`StartLimitIntervalSec=` are deliberately set, not merely left at whatever the distribution default happens to be**, per Section 6.
3. **If `WatchdogSec=` is set, confirm — by reading the daemon's own source or documentation, not by assumption — that it actually calls `sd_notify(WATCHDOG=1)` internally.** An unimplemented watchdog is worse than no watchdog at all: it provides false confidence that liveness is being checked.
4. **Check whether `ExecStop=` is genuinely necessary**, per the Section 4.3 gotcha, or whether the default signal-based shutdown (governed by `KillMode=`/`KillSignal=`) would suffice with less custom code to maintain and potentially fail.
5. **Confirm secrets live in a restrictively-permissioned `EnvironmentFile=`, never inline in `Environment=`**, per Section 12's and Section 17's coverage of this specific, common mistake.
6. **After deployment, deliberately trigger a failure (or, for a low-risk service, an actual crash) once in a non-production environment and watch `journalctl -u` live**, confirming the restart/backoff/start-limit behavior matches what the unit file's directives predict — the worked timeline in Section 13 is a template for what to expect, and a mismatch between predicted and observed behavior at this stage is far cheaper to catch than during a real incident.

---

## 22. What's Ahead

`04-Unit-Files.md` steps back from `.service`-specific behavior to the complete unit-file directive reference across every unit type — specifiers (`%n`, `%i`, `%H`, and the rest), the complete `systemd.exec(5)` execution-context reference beyond the brief mention in Section 12, and templated/instantiated units in full, building directly on the `%i`-specifier mention in `02-Units-and-Dependencies.md` Section 15.

---

## References

- `systemd.service(5)` — the canonical directive reference this document expands on
- `systemd.exec(5)` — execution-context directives (`User=`, `Environment=`, and related)
- `systemd.kill(5)` — `KillMode=`/`KillSignal=` semantics in full
- `sd_notify(3)` — the full notify-protocol API reference
- `systemd-notify(1)` — the shell-callable notify tool used in Section 3
