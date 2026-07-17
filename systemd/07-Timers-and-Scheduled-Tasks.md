# Timers and Scheduled Tasks

A complete, mechanism-level reference for `.timer` units: the full calendar-event grammar behind `OnCalendar=`, the monotonic timer family (`OnBootSec=`, `OnUnitActiveSec=`, and the rest), catching up on missed runs via `Persistent=`, precision and thundering-herd controls (`AccuracySec=`, `RandomizedDelaySec=`), timer-to-service pairing conventions, waking the system from suspend, and the complete diagnostic toolkit — `systemctl list-timers`, `systemd-analyze calendar`, and the `journalctl` vocabulary from `06-journald-and-Logging.md` applied specifically to scheduled-task investigation.

`02-Units-and-Dependencies.md` Section 1 first named `.timer` as one of the eleven unit types without detail. `04-Unit-Files.md` Section 7.4 drew the boundary between it and `.path` units — time-based triggering versus event-based triggering. This document is where `.timer` itself, deferred until this point specifically so it could draw on the dependency, service-lifecycle, and journal machinery every prior document established, finally receives its complete treatment.

---

## 1. Why systemd Timers Over `cron`

### 1.1 What `cron` provides, and where it stops

Traditional `cron` reads `crontab` files — a compact, five-field time expression followed by a command — and executes matching commands at the specified wall-clock times, via its own independent daemon (`crond`), entirely outside systemd's own unit/dependency/supervision model. This has served adequately for decades of simple scheduled-task needs, but leaves several genuine gaps once a scheduled task's requirements grow past the simplest case:

- **No dependency awareness.** A `cron` job scheduled for 2:00 AM has no way to express "but only if the database is actually up" — it simply runs at 2:00 AM regardless, and any failure due to an unmet precondition looks identical, from `cron`'s own perspective, to any other failure.
- **No process supervision.** `cron` launches a process and, much like SysVinit's own historical limitation (`01-Introduction.md` Section 1.3), has no cgroup-based tracking of what that process actually spawns, no `Restart=`-equivalent recovery policy, and no reliable way to terminate a runaway job's full process tree.
- **No native structured logging.** A `cron` job's output is, by convention, mailed to the owning user or redirected manually within the crontab entry itself — not automatically captured into any centralized, queryable log the way every unit's output flows into the journal per `06-journald-and-Logging.md`.
- **No missed-run handling.** If the machine is powered off at the scheduled time, the job simply doesn't run, with no built-in mechanism to detect and catch up on the miss once the machine is back — Section 5 covers systemd's own, genuinely different answer to this specific gap.

### 1.2 What a `.timer` unit actually is

A `.timer` unit is, structurally, nothing more than **another unit that participates in the same dependency graph, ordering, and job-transaction machinery** every other unit type in this series has used — its entire distinguishing feature is a `[Timer]` section describing *when* it should trigger another unit's start job, using either calendar-based or monotonic (elapsed-time-based) expressions. Because it's an ordinary unit, everything `02-Units-and-Dependencies.md` established about `Requires=`/`After=`, and everything `03-Service-Management.md` established about the triggered unit's own `Type=`/`Restart=`/timeout behavior, applies to a timer-triggered service identically to a directly-started one — a scheduled backup job can `Requires=postgresql.service` exactly as `webapp.service` did throughout this series' running example, something a standalone `cron` daemon, operating entirely outside systemd's graph, structurally cannot express at all.

---

## 2. Timer Unit Anatomy

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Daily backup timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=backup.service

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Backup job
Requires=postgresql.service
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh
```

This pairing — a `.timer` unit and a same-prefixed `.service` unit — mirrors precisely the socket/service pairing convention `02-Units-and-Dependencies.md` Section 11 established, and `Unit=` (Section 7) follows the identical default-pairing-by-name convention `04-Unit-Files.md` Section 7.4 documented for `.path` units. `WantedBy=timers.target` is the enablement convention specifically for timers — `timers.target` being the same synchronization point `05-Boot-Process-and-Targets.md` Section 4 placed within `basic.target`'s own closure, meaning an enabled timer is scheduled and active from very early in boot, well before the `multi-user.target` fan-out where the actual triggered service (`backup.service` here) would typically live.

### 2.1 The two timer families

`[Timer]` accepts two structurally distinct families of directive, distinguished by what they measure time *relative to*:

- **Calendar timers** (`OnCalendar=`, Section 4) — trigger at specific, absolute wall-clock date/time expressions, the direct conceptual equivalent of a `cron` schedule.
- **Monotonic timers** (`OnBootSec=`, `OnStartupSec=`, `OnActiveSec=`, `OnUnitActiveSec=`, `OnUnitInactiveSec=`, Section 3) — trigger a fixed *duration* after some reference event (boot, the timer's own activation, or the triggered unit's own last start/stop), with no fixed wall-clock time involved at all.

A single `.timer` unit can combine multiple directives from either or both families — each one, independently, computes its own next-trigger time, and the timer as a whole fires at whichever computed time comes soonest, recalculating after each firing.

---

## 3. Monotonic Timers in Full

### 3.1 `OnBootSec=`

Triggers a fixed duration after the **system itself** booted, referencing the boot sequence `05-Boot-Process-and-Targets.md` covered in full.

```ini
[Timer]
OnBootSec=15min
```

Fires once, fifteen minutes after boot — useful for a task that should run early in a machine's uptime but genuinely needs some settling time first (network fully established, initial cache warming elsewhere completed) rather than firing at the earliest possible moment `timers.target`'s own position in the boot sequence (Section 2) would otherwise allow.

### 3.2 `OnStartupSec=`

Nearly identical to `OnBootSec=`, but measured from **systemd's own startup** rather than the kernel-level boot event — a distinction that only actually diverges from `OnBootSec=` in the (relatively rare) case of a `systemd --user` instance (a per-user manager, distinct from the system-wide PID 1 this entire series has otherwise focused on), where "startup" refers to that user manager's own launch, which can occur well after the underlying machine's own boot, at whatever point that specific user's first session begins.

### 3.3 `OnActiveSec=`

Triggers a fixed duration after the **timer unit itself** was activated (started) — the most literal, general-purpose "run N seconds/minutes from now" primitive, independent of boot or the triggered unit's own history.

```ini
[Timer]
OnActiveSec=5min
```

### 3.4 `OnUnitActiveSec=` and `OnUnitInactiveSec=`

These two are qualitatively different from the three above — rather than referencing a boot-related or timer-related event, they reference the **triggered unit's own** last activation or deactivation, creating a genuinely self-referential, recurring schedule.

```ini
[Timer]
OnUnitActiveSec=1h
Unit=cache-refresh.service
```

This fires exactly one hour after `cache-refresh.service` **last successfully started** — meaning if that service itself took eight minutes to actually complete its work, the *next* firing is scheduled relative to when it *started*, not when it finished, one hour later regardless of how long any individual run took, as long as it's shorter than the interval itself. `OnUnitInactiveSec=`, its counterpart, instead measures from when the triggered unit last **stopped** — meaningfully different for a long-running or variable-duration job: `OnUnitInactiveSec=1h` guarantees a full hour of genuine gap *between* one run finishing and the next one starting, regardless of how long each individual run took, which `OnUnitActiveSec=` does not guarantee if a run's own duration approaches or exceeds the configured interval.

### 3.5 Combining monotonic directives for a repeating schedule

```ini
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Unit=health-check.service
```

This is the standard idiom for "run shortly after boot, then repeatedly thereafter" — `OnBootSec=` handles the very first firing, and once that first run completes, `OnUnitActiveSec=`'s self-referential mechanism takes over for every subsequent firing, without needing `OnBootSec=` and `OnUnitActiveSec=` to somehow coordinate explicitly; each directive simply computes its own next-trigger time independently, per Section 2.1's combination rule, and the timer fires at whichever is soonest at any given moment.

---

## 4. Calendar Event Syntax in Full

`OnCalendar=` is the direct, and considerably more expressive, systemd-native counterpart to a traditional `crontab` line.

### 4.1 The grammar, structurally

```
OnCalendar=<weekday> <year>-<month>-<day> <hour>:<minute>:<second>
```

Every component beyond the base pattern is optional and has sensible defaults — a bare `OnCalendar=*-*-* 02:00:00` omits the weekday entirely (meaning every day), and `OnCalendar=18:00` (omitting the date portion entirely) means every day at 18:00:00, with seconds defaulting to `00`.

### 4.2 Wildcards, ranges, lists, and steps

| Syntax | Meaning | Example |
|---|---|---|
| `*` | Any value | `*-*-* 03:00:00` — every day at 3 AM |
| `a,b,c` | A list of specific values | `Mon,Wed,Fri *-*-* 09:00:00` |
| `a..b` | An inclusive range | `Mon..Fri *-*-* 09:00:00` |
| `a/n` | Every `n`th value starting from `a` | `*-*-* 0/4:00:00` — every 4 hours, on the hour |
| `~` (on day-of-month) | Counted from the **end** of the month | `*-*-~1 23:59:00` — the last day of every month |

```bash
OnCalendar=Mon..Fri *-*-* 09,17:00:00
```

Read left to right: weekday range `Mon..Fri`, any year/month/day (`*-*-*`), and — via the comma-list applied to the hour field — both `09:00:00` and `17:00:00`, meaning this fires twice on every weekday, at 9 AM and 5 PM, with no need for two separate timer units or two separate `OnCalendar=` lines to express what is, structurally, one single combined expression.

### 4.3 Multiple `OnCalendar=` lines

Exactly as Section 2.1 described for combining timer families generally, multiple `OnCalendar=` lines within one `[Timer]` section are **additive**, not overriding — each computes its own next occurrence independently, and the timer fires at whichever comes first:

```ini
[Timer]
OnCalendar=Mon..Fri *-*-* 08:00:00
OnCalendar=Sat,Sun *-*-* 10:00:00
```

This expresses "weekdays at 8 AM, weekends at 10 AM" as two separate, individually-simple expressions, rather than requiring one single, more convoluted expression attempting to encode the entire compound schedule in one line.

### 4.4 Special, named shortcuts

systemd provides several pre-defined aliases for extremely common patterns, expanding to the equivalent full `OnCalendar=` expression internally:

| Shortcut | Equivalent to |
|---|---|
| `minutely` | `*-*-* *:*:00` |
| `hourly` | `*-*-* *:00:00` |
| `daily` (or `midnight`) | `*-*-* 00:00:00` |
| `weekly` | `Mon *-*-* 00:00:00` |
| `monthly` | `*-*-01 00:00:00` |
| `yearly` (or `annually`) | `*-01-01 00:00:00` |
| `quarterly` | `*-01,04,07,10-01 00:00:00` |
| `semiannually` | `*-01,07-01 00:00:00` |

```ini
[Timer]
OnCalendar=daily
```

These shortcuts are worth reaching for directly wherever they fit exactly, both for their own readability and because they match, by construction, exactly the same expressions administrators reading the unit file are already likely to recognize on sight — a bare `OnCalendar=daily` communicates intent slightly faster to a future reader than the fully-expanded `*-*-* 00:00:00`, even though the two are functionally identical.

### 4.5 Time zone handling

By default, `OnCalendar=` expressions are evaluated in the system's own local time zone — meaningfully relevant for anything touching a daylight-saving-time transition, where a fixed wall-clock time can, on the two transition days per year, either not exist at all (the "spring forward" gap) or occur twice (the "fall back" repeat). An explicit time zone can be appended:

```ini
OnCalendar=*-*-* 02:00:00 UTC
```

Pinning to `UTC` explicitly sidesteps DST-transition ambiguity entirely for a task where the *exact* wall-clock trigger time matters precisely and consistently year-round (a task coordinated against a remote system that itself operates in UTC, for instance) — at the cost of that trigger time then drifting relative to local wall-clock time by one hour across each DST transition, from a local observer's own perspective, which is the correct, deliberate trade-off for that specific use case but the wrong default for a task that should always fire at "2 AM, whatever 2 AM locally means today."

### 4.5a A Worked DST Transition

To make Section 4.5's abstract description concrete: consider `OnCalendar=*-*-* 02:30:00`, evaluated in a local time zone observing a "spring forward" transition where clocks jump directly from 01:59:59 to 03:00:00.

On that specific transition day, **02:30:00 never occurs at all** — it's inside the skipped hour. systemd's handling here is to treat the literal wall-clock target as simply not existing for that one occurrence and fire, instead, at the next time that genuinely does exist which satisfies the expression — in practice, the *following* day's 02:30:00, since there is no valid local time matching the expression on the transition day itself. A task depending on firing *every single day without exception*, where a skipped occurrence on the transition day is genuinely unacceptable, needs to either pin to `UTC` (Section 4.5) — sidestepping the local skip entirely, at the cost of the trigger's local-wall-clock meaning shifting by an hour twice a year — or select a trigger time outside the typical 1–3 AM transition window most time zones use, where this specific ambiguity simply doesn't arise.

The "fall back" transition, where clocks repeat an hour (`01:59:59` occurring, then time reverting to `01:00:00` and counting up through the same hour a second time), has the opposite characteristic: `02:30:00` on that day occurs validly, but only **once**, and systemd's own internal clock-handling correctly fires the timer once for that single valid occurrence rather than twice merely because the wall-clock hour was repeated at the kernel/libc level — the timer mechanism operates against the system's own monotonic and CLOCK_REALTIME notions correctly, not against a naive re-scan of "does the wall-clock display 02:30:00 right now," which would be the failure mode a less careful implementation might exhibit.

### 4.6 A Common-Patterns Library

Rather than deriving each expression from the grammar rules in Section 4.2 from scratch every time, the following table covers the patterns that account for the large majority of real-world scheduling needs, worth having as a direct reference:

| Intent | Expression |
|---|---|
| Every 15 minutes | `*-*-* *:00,15,30,45:00` |
| Every 15 minutes (step syntax) | `*-*-* *:0/15:00` |
| Every 4 hours, on the hour | `*-*-* 0/4:00:00` |
| Business hours only, every hour, weekdays | `Mon..Fri *-*-* 09..17:00:00` |
| First Monday of every month at 6 AM | `Mon *-*-1..7 06:00:00` (combined with an `ExecCondition=` checking the actual date, since `OnCalendar=` alone cannot express "first" directly — see Section 4.7) |
| Last day of every month, 11:59 PM | `*-*-~1 23:59:00` |
| Every weekday at 5-minute past each hour | `Mon..Fri *-*-* *:05:00` |
| Twice yearly, start of Q1 and Q3 | `*-01,07-01 00:00:00` (equivalent to the `semiannually` shortcut) |
| Every second Tuesday (approximate, via day-range) | Not directly expressible — see Section 4.7 |

### 4.7 Expressions `OnCalendar=` Cannot Directly Express

It's worth being explicit about the grammar's actual limits rather than implying it can express literally any conceivable schedule: **ordinal weekday patterns** ("the first Monday," "the second Tuesday," "the last Friday") have no direct, single-expression representation in `OnCalendar=`'s grammar — Section 4.2's `~` syntax handles counting from the end of the *month* by day-of-month number, not counting a specific *weekday occurrence* within the month. The standard workaround combines a broader `OnCalendar=` firing (every Monday, say) with an `ExecCondition=` (`03-Service-Management.md` Section 11) on the triggered service that checks the actual date and exits non-zero — triggering Section 11's "silent skip," not a failure — on every Monday that isn't specifically the first one of its month:

```ini
[Service]
ExecCondition=/usr/bin/test $(date +%d) -le 7
ExecStart=/usr/local/bin/first-monday-report.sh
```

This pattern — a broader, easily-expressed `OnCalendar=` combined with an `ExecCondition=` narrowing to the actual, more specific intended occasions — is the general-purpose escape hatch for any scheduling requirement the calendar grammar itself cannot directly represent, leaning on `03-Service-Management.md` Section 11's guarded-execution mechanism rather than attempting to force an inherently ordinal requirement into a grammar that fundamentally operates on absolute date/time fields.

---

## 5. `Persistent=`: Catching Up on Missed Runs

This is the direct, mechanism-level answer to Section 1.1's "no missed-run handling" gap in traditional `cron`.

```ini
[Timer]
OnCalendar=daily
Persistent=true
```

With `Persistent=true`, systemd records the **last time this timer actually fired**, persisted to disk (surviving reboots), and — critically — checks that record against the current time the *next* time the timer unit itself is loaded (typically, at the next boot). If the timer's most recent scheduled firing was missed entirely — the machine was powered off at 2 AM when a daily backup was due, for instance — the triggered unit is started **immediately** upon the timer next being loaded, rather than silently skipping straight to waiting for the *next* scheduled occurrence.

### 5.1 What `Persistent=true` does not do

It's worth being precise about the boundary here: `Persistent=true` catches up on **at most one** missed occurrence, not every individual occurrence that was missed during an extended outage — a machine powered off for four days, with a daily timer configured, catches up with exactly one immediate run upon the next boot, not four queued, back-to-back runs compensating for each individual missed day. This is a deliberate design choice: for the overwhelming majority of scheduled-task use cases (a daily report, a periodic cleanup), running once to "catch up to current" is the actually-desired behavior, not replaying every individually-missed occurrence — a task genuinely requiring that stronger guarantee needs its own explicit application-level tracking of exactly which specific occurrences were processed, which is outside anything the timer mechanism itself provides.

### 5.2 When `Persistent=` is and isn't appropriate

`Persistent=true` is the correct default for most administrative/maintenance scheduled tasks — a backup, a cleanup job, a report generation — where "eventually, once, close to the missed time" genuinely satisfies the task's actual purpose. It is generally **inappropriate** for a task whose entire value is tied to firing at a *specific* moment for reasons beyond mere "eventually get around to it" — a task coordinated to occur simultaneously with an external event at a fixed time has no benefit from firing late, and a `Persistent=true`-triggered catch-up run, well after that coordinated moment has passed, could in some cases be actively counterproductive rather than merely delayed-but-still-useful.

---

## 6. Precision and Thundering-Herd Controls

### 6.1 `AccuracySec=`

systemd deliberately does **not** guarantee millisecond-precise firing for an `OnCalendar=`/monotonic timer by default — `AccuracySec=` (default `1min`) defines a window within which systemd is free to fire the timer at any point, batching nearby timer events together for power and wake-up efficiency rather than waking the CPU from a low-power state for each individually-scheduled timer at its own, separately-precise moment.

```ini
[Timer]
OnCalendar=*-*-* 02:00:00
AccuracySec=1s
```

Tightening `AccuracySec=` to `1s` here trades away some of that batching efficiency in exchange for firing much closer to the literal, exact 2:00:00 boundary — appropriate specifically for a task where near-exact timing genuinely matters (again, coordination with an external, time-sensitive event), and inappropriate as a blanket default applied to every timer regardless of actual need, since the aggregate effect of many timers all individually demanding tight accuracy is precisely the reduced power-efficiency and increased wake-up frequency the default, looser `AccuracySec=` exists to avoid across the system as a whole.

### 6.2 `RandomizedDelaySec=`

A distinct, complementary mechanism: rather than narrowing the firing window like `AccuracySec=`, `RandomizedDelaySec=` deliberately **widens** it, adding a randomized, per-activation delay up to the specified maximum on top of the otherwise-computed trigger time.

```ini
[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=30min
```

This is the direct, systemd-native tool against the classic **thundering herd** problem: if this exact unit file, or one very similar to it, is deployed identically across a large fleet of machines, an unmodified `OnCalendar=*-*-* 03:00:00` fires on literally every machine simultaneously, at the exact same instant — potentially overwhelming a shared downstream dependency (a database every instance's backup job connects to, a shared network storage target) with a simultaneous flood of load at precisely 3:00:00 sharp. `RandomizedDelaySec=30min` spreads that same fleet's actual firing times randomly across a thirty-minute window following the nominal 3 AM trigger, each machine independently choosing its own random offset, smoothing what would otherwise be an instantaneous load spike into a gradually-arriving one — directly analogous to, and a considerably more precise tool than, the traditional `cron`-administrator convention of manually staggering different machines' crontab entries by a few arbitrary minutes each to achieve roughly the same effect by hand.

### 6.3 Combining both

```ini
[Timer]
OnCalendar=*-*-* 03:00:00
AccuracySec=1min
RandomizedDelaySec=30min
```

These two directives operate on entirely independent axes and combine cleanly: `AccuracySec=` governs how tightly systemd honors the *computed* trigger time once that time is reached, while `RandomizedDelaySec=` is what actually shifts what that computed trigger time *is*, per-activation, before `AccuracySec=`'s own precision window even applies to it — together, "fire at approximately 3:00–3:30 AM, each occurrence within about a minute of its own randomly-chosen moment within that window."

---

## 7. Timer-to-Unit Pairing

### 7.1 The default convention

Exactly as `04-Unit-Files.md` Section 7.4 established for `.path` units, an omitted `Unit=` directive in a `.timer` unit defaults to the identically-prefixed `.service` — `backup.timer` triggers `backup.service` automatically, with no explicit `Unit=` line needed, mirroring the socket/service pairing convention from `02-Units-and-Dependencies.md` Section 11 one further time across yet another pair of unit types built on the identical underlying "one unit's activation triggers a different, specifically-named unit's start job" mechanism.

### 7.2 Explicit pairing and shared triggered units

```ini
# nightly-full.timer
[Timer]
OnCalendar=Sun *-*-* 02:00:00
Unit=backup.service

# hourly-incremental.timer
[Timer]
OnCalendar=hourly
Unit=backup.service
```

An explicit `Unit=` allows multiple, differently-scheduled timers to trigger the **same** underlying service — here, `backup.service` itself might branch its own internal logic (via an environment variable or command-line flag distinguishing "full" from "incremental," set differently by each timer via a drop-in, per `04-Unit-Files.md` Section 3, or via the triggered unit inspecting which specific timer most recently fired) rather than needing two entirely separate, largely-duplicated service unit files merely to support two different schedules against otherwise-identical underlying logic.

### 7.3 `Type=oneshot` as the standard triggered-unit pattern

The overwhelming majority of timer-triggered services are `Type=oneshot` (`03-Service-Management.md` Section 2.3) — a task that runs to completion and exits, rather than a long-running daemon. `RemainAfterExit=` is generally **not** set for a timer-triggered oneshot, specifically because the timer mechanism itself, not the service's own `active`/`inactive` status, is what represents "has this run recently" — a timer-triggered `backup.service` reverting to `inactive` immediately after each run is the expected, correct behavior, letting the *next* scheduled timer firing start it fresh each time without any lingering `active` state needing to be cleared first.

---

## 8. `WakeSystem=`: Timers That Wake From Suspend

```ini
[Timer]
OnCalendar=*-*-* 04:00:00
WakeSystem=true
```

On hardware supporting it (via the kernel's own RTC-alarm wake mechanism), `WakeSystem=true` allows a timer's scheduled firing to actually **wake the machine from suspend** to run the triggered unit, rather than the timer simply being skipped (or delayed until the next actual wake, whenever that happens to occur) while the system is suspended. This is directly relevant to laptop-class and similarly power-managed hardware, where a scheduled maintenance task (an overnight backup, say) would otherwise never run at all on a machine that's routinely suspended overnight rather than left fully powered on — without `WakeSystem=true`, such a timer either never fires during the suspended window, or fires only once the machine happens to be woken for an unrelated reason (a user opening the lid), at which point it behaves as an ordinary, `Persistent=`-style catch-up (Section 5) rather than a precisely-timed wake.

**Gotcha:** `WakeSystem=true` requires corresponding hardware and firmware RTC-wake support, and — precisely because it can force a battery-powered device out of a low-power suspend state — should be reserved deliberately for genuinely important scheduled tasks, not applied as a blanket default across every timer on a laptop-class machine, where the resulting battery-life impact of frequent, unnecessary wake-ups would be a real, easily-overlooked cost.

---

## 9. `systemctl list-timers`: Reading Timer Status

```bash
systemctl list-timers
```

```
NEXT                        LEFT     LAST                         PASSED   UNIT              ACTIVATES
Fri 2026-07-18 02:00:00 UTC 9h left  Thu 2026-07-17 02:00:00 UTC  15h ago  backup.timer      backup.service
Fri 2026-07-18 00:00:00 UTC 7h left  Thu 2026-07-17 00:00:00 UTC  17h ago  logrotate.timer   logrotate.service
```

Reading this output correctly: **`NEXT`/`LEFT`** show the *computed* next trigger time and countdown — already accounting for any `RandomizedDelaySec=` (Section 6.2) that's applicable, meaning the displayed time is the actual, specific moment this particular activation will fire, not merely the nominal, un-randomized schedule. **`LAST`/`PASSED`** show when the timer most recently actually fired, and how long ago — directly useful for spotting a timer that's fallen silent unexpectedly (a `PASSED` value far exceeding what the configured interval should ever allow indicates the timer itself has stopped firing, worth investigating via the mechanism in Section 11, separately from whether the *triggered service* itself is succeeding). **`UNIT`/`ACTIVATES`** show the timer's own name alongside the specific unit it's paired with, per Section 7's conventions — directly surfacing the pairing relationship without needing a separate `systemctl cat` inspection to confirm it.

```bash
systemctl list-timers --all       # include inactive/disabled timers too
systemctl status backup.timer      # the timer unit's own status specifically
systemctl status backup.service    # the most recent triggered run's own status
```

`systemctl status backup.timer` and `systemctl status backup.service` answer genuinely different questions, worth keeping distinct: the former reports on the *scheduling mechanism itself* (is the timer active, when does it next fire), while the latter reports on the *most recent execution* of the triggered work (did the last backup actually succeed, what was its exit code) — a healthy, correctly-firing timer paired with a service that's been silently failing on every single triggered run is an entirely plausible, and genuinely dangerous-if-unnoticed, state that only checking the service's own status, not merely the timer's, would reveal.

### 9.1 Diagnosing a Timer That Stopped Firing

Applying the `list-timers` output from earlier in this section concretely: a `PASSED` value climbing well beyond the configured interval — `logrotate.timer` showing `3 days ago` against a configured `OnCalendar=daily`, for instance — is the direct signal something has gone wrong with the *scheduling* itself, distinct from the triggered service merely failing (which would still show a recent, on-schedule `LAST`/`PASSED` value, just paired with a failed exit status on the service side). The standard investigative sequence:

```bash
systemctl status logrotate.timer          # is the timer unit itself even active/enabled?
systemctl list-timers --all logrotate.timer   # confirm it wasn't disabled or masked
journalctl -u logrotate.timer --since "1 week ago"   # any load/parse errors logged
                                                        # against the timer unit itself?
```

A timer that was accidentally `disable`d (per `01-Introduction.md` Section 10's `enable`/`disable` mechanics, applying identically to `.timer` units as to any other unit type) simply stops being wired into `timers.target`'s closure at the next boot, and — unlike a failed service, which produces an obvious `failed` status and journal entries — a disabled timer produces no error at all, just a quiet, ongoing absence of the expected recurring activity, making `systemctl list-timers --all` (Section 9's `--all` flag, surfacing disabled/inactive timers the default view omits) the fastest way to confirm whether "stopped firing" actually means "was disabled" rather than some more complex failure requiring deeper investigation.

### 9.2 Ad Hoc, One-Off Scheduling with `systemd-run`

`03-Service-Management.md` Section 14 introduced `systemd-run` for launching transient, unit-file-free services directly from the command line. The identical mechanism extends to timers:

```bash
systemd-run --on-calendar="*-*-* 22:00:00" --unit=one-off-maintenance \
  /usr/local/bin/maintenance-task.sh
```

This creates a transient `.timer` unit (paired with a correspondingly transient `.service`, following exactly Section 7's pairing convention) that exists purely in systemd's in-memory state, firing once at the specified calendar expression and then cleaning itself up — the direct, lowest-ceremony tool for a genuinely one-off, non-recurring scheduled task (a single maintenance window scheduled for later tonight, decided on the fly) where authoring and deploying a permanent `.timer`/`.service` unit-file pair, per Section 2's full pattern, would be disproportionate ceremony for something that's never meant to recur or be reused.

```bash
systemd-run --on-active=30min --unit=delayed-cleanup /usr/local/bin/cleanup.sh
```

`--on-active=` here maps directly onto Section 3.3's `OnActiveSec=` monotonic directive, applied the same way `--on-calendar=` maps onto `OnCalendar=` — the full monotonic-versus-calendar distinction from Section 2.1 applies identically to `systemd-run`'s own timer-creation flags, not merely to statically-authored unit files.

---

## 10. `systemd-analyze calendar`: Validating and Previewing Expressions

Before committing an `OnCalendar=` expression to a deployed unit file, `systemd-analyze calendar` parses and previews it directly:

```bash
systemd-analyze calendar "Mon..Fri *-*-* 09,17:00:00"
```

```
  Original form: Mon..Fri *-*-* 09,17:00:00
Normalized form: Mon..Fri *-*-* 09,17:00:00
    Next elapse: Fri 2026-07-18 09:00:00 UTC
       (in UTC): Fri 2026-07-18 09:00:00 UTC
       From now: 14h left
```

This is the direct, fastest way to catch an expression that parses successfully but doesn't actually mean what its author intended — a subtly wrong range or step value producing a "Next elapse" far from what was expected is immediately visible here, before the unit is ever deployed and left to silently fire at the wrong times, potentially for a considerable stretch before anyone notices the discrepancy against the intended schedule.

```bash
systemd-analyze calendar --iterations=5 "*-*-01 00:00:00"
```

`--iterations=` extends the preview beyond just the single next occurrence, listing several consecutive future firing times in sequence — particularly useful for validating an expression involving `~` (Section 4.2's counted-from-end-of-month syntax) or multiple combined `OnCalendar=`-style lists, where seeing several actual concrete future dates in a row is a considerably more reliable confirmation than mentally simulating the grammar's rules by hand.

---

## 11. Querying Timer Activity via `journalctl`

Every mechanism `06-journald-and-Logging.md` established applies directly to investigating timer behavior, since both the `.timer` unit itself and its triggered `.service` produce ordinary journal entries via the identical `_SYSTEMD_UNIT` field (`06-journald-and-Logging.md` Section 4.1).

```bash
journalctl -u backup.timer --since "1 week ago"
journalctl -u backup.service --since "1 week ago" -p err
```

The first query surfaces the *scheduling* mechanism's own activity — confirming the timer itself has actually been firing on schedule, independent of whether each triggered run succeeded. The second, applying `06-journald-and-Logging.md` Section 5.1's `-p err` severity filter to the *triggered service* specifically, is the direct tool for confirming whether every scheduled run actually completed successfully, or surfacing exactly which specific occurrences failed and why — combining these two, per-unit queries is the standard first move for any "did my backups actually run correctly this week" investigation, considerably more precise than scanning a traditional `cron`-mailed-output inbox by hand.

```bash
journalctl -u backup.service _SYSTEMD_INVOCATION_ID=$(systemctl show backup.service --property=InvocationID --value)
```

Applying `06-journald-and-Logging.md` Section 6.1's invocation-ID isolation technique here pulls the log for **only the single most recent triggered run**, cleanly separated from the accumulated history of every previous week's daily firings — directly useful when a fresh, just-completed run's own log needs to be reviewed in isolation, without last week's entries for the same, repeatedly-triggered service cluttering the view.

---

## 12. Migrating From `cron`: A Direct Comparison

| `cron` concept | systemd equivalent | Section |
|---|---|---|
| A `crontab` line's five time fields | `OnCalendar=` expression | 4 |
| `@reboot` | `OnBootSec=0` (or `OnStartupSec=0`) | 3.1–3.2 |
| Manually staggering machines to avoid simultaneous load | `RandomizedDelaySec=` | 6.2 |
| Mailed job output | Native journal, queried via `journalctl -u` | 11 |
| No missed-run handling | `Persistent=true` | 5 |
| `crontab -l` | `systemctl list-timers` | 9 |
| Editing a shared, flat `/etc/crontab` (or per-user crontabs) | Individually versioned, separately-authored `.timer`/`.service` unit file pairs | 2 |
| No dependency awareness | `Requires=`/`After=` on the triggered `.service`, per `02-Units-and-Dependencies.md` | 2 |

### 12.1 What genuinely gets more complex, not just different

It's worth being even-handed rather than presenting this purely as a strict improvement in every dimension: a single-line `crontab` entry (`0 2 * * * /usr/local/bin/backup.sh`) is considerably more compact to write than the two-file, multi-section `.timer`/`.service` pairing this document has used throughout — for a genuinely simple, standalone scheduled task with no dependency requirements, no need for structured logging beyond what a redirected output file already provides, and no fleet-wide thundering-herd concern, plain `cron` remains a legitimate, lower-ceremony choice, and the systemd-native approach's genuine advantages (Section 1.1's gaps) matter proportionally more as a task's actual requirements grow past that simplest case — dependency awareness, supervision, structured correlation with the rest of a system's logging, and fleet-scale timing coordination being exactly the dimensions where `cron`'s simplicity stops being sufficient on its own.

### 12.2 A Complete Worked Conversion

To make Section 12's comparison table concrete, here is one realistic `crontab` line converted fully into its systemd-native equivalent, with each piece of the original entry's *implicit* behavior made explicit in the process.

The original `cron` entry:

```
# crontab -e, as the 'backup' user
0 2 * * * /usr/local/bin/backup.sh >> /var/log/backup-cron.log 2>&1
```

Read literally, this says only "run at 2:00 AM daily, as whichever user's crontab this is, redirecting output to a manually-chosen log file" — everything else (does the backup script's own dependency exist yet, what happens if the machine is off at 2 AM, what happens if two consecutive runs somehow overlap, how do you know whether last night's run actually succeeded without manually checking that log file) is either silently unhandled or left to the script's own internal logic to address, if it addresses it at all.

The systemd-native equivalent, with each of those previously-implicit or unhandled concerns now explicit:

```ini
# backup.timer
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=backup.service

[Install]
WantedBy=timers.target
```

```ini
# backup.service
[Unit]
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=backup
ExecStart=/usr/local/bin/backup.sh
```

The user context (`User=backup`) that was merely *implicit* in whose `crontab` the original line lived in is now an explicit, auditable directive on the service unit itself, per `04-Unit-Files.md` Section 4.1; the ad hoc `>> /var/log/backup-cron.log 2>&1` redirection is replaced entirely by the native journal (`06-journald-and-Logging.md`), queryable via `journalctl -u backup.service` with the full structured-field precision that document established, rather than a flat file an administrator has to remember exists and manually rotate; the previously entirely-unhandled "what if the machine was off at 2 AM" gap is closed by `Persistent=true` (Section 5); and the previously entirely-implicit "does the network actually need to be up first" assumption — true in practice for most backup scripts pushing to remote storage, but never stated anywhere in the original one-line `cron` entry — is now an explicit `Requires=network-online.target`/`After=network-online.target` pair, visible to anyone reading the unit file rather than buried as an unstated assumption in the script's own error-handling (or lack thereof).

---

## 13. A Fully Worked Example: A Complete Backup Timer

Bringing every mechanism in this document together into one realistic, fully-specified pair:

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Nightly database backup timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
AccuracySec=1min
RandomizedDelaySec=20min
Unit=backup.service

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Database backup job
Requires=postgresql.service
After=postgresql.service
OnFailure=alert-oncall.service

[Service]
Type=oneshot
User=backup
ExecStartPre=/usr/bin/mkdir -p /var/backups/webapp
ExecStart=/usr/local/bin/backup.sh
TimeoutStartSec=30min
```

Tracing this configuration against the document as a whole: `OnCalendar=*-*-* 02:00:00` (Section 4.1) establishes the nominal nightly trigger; `Persistent=true` (Section 5) guarantees a missed night — the machine happening to be rebooting for a kernel update at exactly 2 AM, say — is caught up with a single run shortly after the machine returns, rather than silently skipping straight to the following night; `RandomizedDelaySec=20min` (Section 6.2) is deliberately included even for a single machine running this configuration, on the reasoning that if this same unit file is later deployed identically across additional replica hosts (a realistic, common evolution for what starts as a single-machine configuration), the thundering-herd protection is already correctly in place from the start rather than needing to be retrofitted later; `Requires=postgresql.service`/`After=postgresql.service` on the triggered service (Section 1.2's core advantage over plain `cron`) guarantees the backup never runs against a database that isn't actually up; `OnFailure=alert-oncall.service` (`02-Units-and-Dependencies.md` Section 5.2) ensures a failed backup run — rather than being silently noted only in a log nobody happens to check — actively notifies someone; and `TimeoutStartSec=30min` (`03-Service-Management.md` Section 7.1) bounds how long a single run is permitted to take before being considered a failure in its own right, guarding against a hung backup process silently blocking the *next* night's `OnUnitActiveSec=`-style (were it used instead of a fixed calendar time) scheduling indefinitely — though, since this specific example uses a fixed `OnCalendar=` rather than `OnUnitActiveSec=`, the more directly relevant benefit here is simply ensuring a hung run is detected and terminated rather than silently consuming resources indefinitely until manually noticed.

### 13.1 Verifying the configuration end to end

```bash
systemd-analyze calendar "*-*-* 02:00:00"      # confirm the expression means what's intended
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer
systemctl list-timers backup.timer              # confirm it's scheduled, and see the actual
                                                  # randomized next-fire time
sudo systemctl start backup.service              # manually trigger one run immediately,
                                                  # to validate the underlying job itself
                                                  # works, independent of waiting for 2 AM
journalctl -u backup.service -n 50               # review that manual run's own output
```

This sequence — validate the expression, enable the timer, then separately and manually trigger the *service* directly (not the timer) to test the actual underlying logic without waiting for the real scheduled time — is the standard verification workflow for any newly-authored timer/service pair, exercising every layer (calendar-expression correctness, enablement, and the triggered unit's own actual behavior) independently before trusting the combination to run correctly, unattended, at its real scheduled time.

---

## 14. Common Anti-Patterns

**Assuming `Persistent=true` replays every individually-missed occurrence.** As covered in Section 5.1, it catches up on at most one — a task genuinely requiring full replay of every missed occurrence during an extended outage needs its own explicit, application-level tracking beyond what the timer mechanism alone provides.

**Applying `WakeSystem=true` as a blanket default on battery-powered hardware.** As covered in Section 8's gotcha, this carries a genuine battery-life cost and should be reserved for scheduled tasks whose importance specifically justifies forcing a wake from suspend, not applied indiscriminately.

**Deploying an identical, un-randomized `OnCalendar=` timer unit file across a large, identically-configured fleet.** As covered in Section 6.2, this is the direct setup for a thundering-herd load spike against whatever shared resource every instance's triggered task touches — `RandomizedDelaySec=` costs nothing to include even on a single machine and should be a near-default inclusion for any timer unit file that might plausibly be deployed to more than one host later, per the worked example's own reasoning in Section 13.

**Checking only `systemctl status backup.timer`, never `backup.service`, when validating "is my backup working."** As covered in Section 9, the timer's own healthy, on-schedule firing says nothing about whether each triggered run actually succeeded — a timer firing perfectly on schedule against a service that's been failing on every single invocation is an easy, dangerous blind spot for an investigation that only checks the scheduling layer.

**Setting `RemainAfterExit=yes` on a timer-triggered `Type=oneshot` service without a specific reason.** As covered in Section 7.3, the timer mechanism itself, not the triggered service's own lingering `active` state, is what represents "has this run recently" for a repeating scheduled task — an unnecessary `RemainAfterExit=yes` here mainly just changes what `systemctl status` reports between runs, without providing any benefit the timer's own `list-timers`-visible `LAST`/`PASSED` fields (Section 9) don't already provide more precisely.

**Tightening `AccuracySec=` aggressively on every timer as a matter of course.** As covered in Section 6.1, the default, looser accuracy window exists specifically to batch nearby wake-ups for system-wide power efficiency — reserve a tight `AccuracySec=` for the specific timers whose actual purpose genuinely requires near-exact firing, not as a general-purpose "more precise must be better" default applied uniformly.

**Assuming an `OnCalendar=` expression can directly encode an ordinal weekday pattern.** As covered in Section 4.7, "the first Monday of the month" and similar ordinal patterns have no single-expression representation in the calendar grammar — attempting to force one via an overly clever combination of ranges and steps produces an expression that either doesn't mean what was intended or is far harder to verify correct via `systemd-analyze calendar` (Section 10) than the straightforward broader-trigger-plus-`ExecCondition=` pattern Section 4.7 describes.

---

## 15. Exercises

**1.** A timer has `OnUnitActiveSec=1h` against a service that, on one particular occasion, takes ninety minutes to complete due to unusually heavy load. When does the next occurrence fire? *(Per Section 3.4, `OnUnitActiveSec=` measures from when the unit last *started*, not when it finished — the next occurrence was already due thirty minutes before this unusually long run even completed, meaning it fires essentially immediately once the overrunning run finishes, rather than waiting a full hour from that completion; a task needing a guaranteed minimum *gap* between runs regardless of individual run duration should use `OnUnitInactiveSec=` instead.)*

**2.** An identical `OnCalendar=*-*-* 03:00:00` timer unit file, with no `RandomizedDelaySec=`, is deployed to two hundred servers, each performing a backup to the same shared network storage target. What is the likely operational consequence at 3:00:00 AM? *(Per Section 6.2, all two hundred instances fire simultaneously, at the identical instant, producing a sudden, concentrated load spike against the shared storage target rather than a smoothly-distributed one — the direct thundering-herd scenario `RandomizedDelaySec=` exists specifically to prevent, and its absence here is a straightforward, easily-fixed configuration gap once identified.)*

**3.** A machine is suspended at 1:55 AM and does not wake again, for unrelated reasons, until 9:00 AM. A timer configured with `OnCalendar=*-*-* 02:00:00`, `Persistent=true`, and no `WakeSystem=` is on this machine. What happens at 9:00 AM? *(Per Sections 5 and 8, without `WakeSystem=true` the machine simply doesn't wake for the timer at all — but per `Persistent=true`'s own mechanism, once the machine *does* eventually wake, for whatever unrelated reason, and the timer unit is reloaded/re-evaluated, it detects the missed 2 AM occurrence and fires the triggered unit immediately at that point, at 9:00 AM, rather than waiting for the following night's 2 AM.)*

**4.** A `.timer` unit's `[Timer]` section has both `OnCalendar=daily` and `OnBootSec=15min`, with no other directives. On a machine that reboots at 6 PM, several hours after that day's `OnCalendar=daily` midnight firing already occurred, when does the timer next fire? *(Per Section 2.1's combination rule, each directive computes its own next-trigger time independently, and the timer fires at whichever is soonest — `OnBootSec=15min` computes 6:15 PM, which is sooner than the *following* midnight `OnCalendar=daily` occurrence, so the timer fires at 6:15 PM on the reboot day, with the next `OnCalendar=daily` occurrence after that following normally at the subsequent midnight.)*

**5.** An administrator wants to confirm an `OnCalendar=` expression is correct before deploying it, without creating and enabling an actual timer unit first. What is the direct tool for this? *(`systemd-analyze calendar`, per Section 10 — parsing and previewing the expression's next occurrence (and, with `--iterations=`, several subsequent ones) entirely independent of any actual deployed unit, catching a subtly wrong expression before it's ever running unattended against real production scheduling.)*

**6.** A `logrotate.timer` configured for `OnCalendar=daily` shows `LAST` as four days ago in `systemctl list-timers`, but no corresponding `failed` status or journal error is visible anywhere. What is the most likely explanation, and how would it be confirmed? *(Per Section 9.1, an accidentally-disabled timer produces no error at all — it simply stops being part of the active schedule — so the most likely explanation is that the timer was disabled or masked at some point; `systemctl list-timers --all` and `systemctl status logrotate.timer` would confirm this immediately by showing its enabled/active state, a check worth performing before assuming a more complex failure is responsible for the apparent gap.)*

**7.** An administrator needs a genuinely one-off task to run in exactly two hours, with no intention of ever reusing the schedule. Is authoring a `.timer`/`.service` unit-file pair, per Section 2's full pattern, the most proportionate tool? *(No — per Section 9.2, `systemd-run --on-active=2h` creates a transient, self-cleaning timer directly from the command line for exactly this genuinely-one-off case, without the ongoing-maintenance overhead of two permanent, disk-resident unit files for a schedule that was never meant to recur.)*

---

## 16. Pre-Deployment Checklist

Mirroring the checklists established across this series, adapted to timer configuration specifically:

1. **Run `systemd-analyze calendar` against any new or modified `OnCalendar=` expression before deploying it**, per Section 10 — confirming the previewed next occurrence (and several subsequent ones, via `--iterations=`) genuinely matches the intended schedule, rather than discovering a subtly wrong range or step value only after it's been silently firing incorrectly in production for some period.
2. **For any timer plausibly deployed to more than one host, include `RandomizedDelaySec=` from the start**, per Section 6.2 and the worked example's own reasoning in Section 13 — retrofitting thundering-herd protection after a fleet-wide deployment has already caused a load-spike incident is considerably more disruptive than including it preemptively.
3. **Deliberately decide on `Persistent=` rather than leaving it at its unset default**, per Section 5 — for the common case of administrative/maintenance tasks, `Persistent=true` is very often the actually-desired behavior, and its absence is easy to overlook until the first missed-occurrence-during-downtime incident reveals the gap.
4. **Verify the triggered service's own dependency directives (`Requires=`/`After=`) independently of the timer's own schedule**, per Section 1.2 — a correctly-firing timer against a service missing its own necessary `Requires=postgresql.service`-style guard is exactly the SysVinit-era race condition systemd's dependency graph exists to prevent, and the timer mechanism itself provides no protection against this if the triggered service's own unit file omits it.
5. **Test the triggered service directly via `systemctl start <service>`, independent of waiting for the real scheduled time**, per Section 13.1 — validating the underlying job's actual correctness separately from validating the scheduling mechanism around it, so a failure discovered later can be immediately attributed to one or the other rather than requiring re-investigation of both simultaneously.
6. **After deployment, confirm via `systemctl list-timers` that the displayed `NEXT` time — which already accounts for `RandomizedDelaySec=` — falls within the actually-intended window**, per Section 9, rather than only checking the nominal, un-randomized `OnCalendar=` expression's own literal value.

---

## 17. Quick-Reference Table

| Directive | Section | Purpose |
|---|---|---|
| `OnCalendar=` | 4 | Absolute, wall-clock-based scheduling |
| `OnBootSec=` / `OnStartupSec=` | 3.1–3.2 | Fixed duration after system/manager startup |
| `OnActiveSec=` | 3.3 | Fixed duration after the timer itself activated |
| `OnUnitActiveSec=` / `OnUnitInactiveSec=` | 3.4 | Self-referential, recurring relative to the triggered unit's own last start/stop |
| `Persistent=` | 5 | Catch up on one missed occurrence after downtime |
| `AccuracySec=` | 6.1 | How tightly the computed trigger time is honored |
| `RandomizedDelaySec=` | 6.2 | Thundering-herd protection via per-activation jitter |
| `Unit=` | 7 | Explicit timer-to-service pairing, overriding the default same-prefix convention |
| `WakeSystem=` | 8 | Permit waking the machine from suspend to fire |
| `systemctl list-timers` | 9 | Scheduling status: next/last fire time, pairing |
| `systemd-analyze calendar` | 10 | Validate and preview an `OnCalendar=` expression |

---

## 18. Glossary

**Calendar timer** — a timer expression anchored to absolute wall-clock date/time, the direct analogue of a `cron` schedule.
**Monotonic timer** — a timer expression anchored to elapsed duration since a reference event (boot, activation, or the triggered unit's own history), with no fixed wall-clock component.
**Thundering herd** — the load-spike problem of many independent instances all triggering simultaneously against a shared resource, mitigated by `RandomizedDelaySec=`.
**Missed occurrence** — a scheduled firing that did not happen because the system was powered off or the timer unit wasn't loaded at the scheduled moment, addressed by `Persistent=`.
**Wake alarm** — the RTC-level hardware mechanism `WakeSystem=true` relies on to rouse a suspended machine at a scheduled time.
**Transient timer** — a `.timer` unit created on the fly via `systemd-run`, existing only in memory with no backing file on disk, mirroring `03-Service-Management.md` Section 14's transient services.
**DST transition** — the twice-yearly daylight-saving-time shift, producing either a skipped or a repeated local hour, with distinct, correct handling for each case described in Section 4.5a.

---

## 19. What's Ahead

`08-Security-and-Hardening.md` covers the sandboxing and resource-control directive family previewed in passing throughout this series — `PrivateTmp=` (`04-Unit-Files.md` Section 4.9), `DynamicUser=` (`04-Unit-Files.md` Section 4.1), the full namespacing directive set, and the `MemoryMax=`/`CPUQuota=` cgroup-based resource-control mechanism first named in `02-Units-and-Dependencies.md` Section 12 — including `systemd-analyze security`'s automated exposure scoring, applied to worked examples across both the service units from `03-Service-Management.md` and the timer-triggered units this document has just established.

---

## References

- `systemd.timer(5)` — the complete `[Timer]`-section directive reference
- `systemd.time(7)` — the full calendar and time-span expression grammar
- `systemd-analyze(1)` — the `calendar` subcommand's complete option reference
- `systemctl(1)` — `list-timers` output-field documentation
