# Troubleshooting

A consolidated, systematic diagnostic methodology bringing together every failure-tracing technique this series has introduced piecemeal — the `result=` field taxonomy first touched in `02-Units-and-Dependencies.md`, the restart/watchdog timelines from `03-Service-Management.md`, the emergency-target diagnosis from `05-Boot-Process-and-Targets.md`, the complete `journalctl` query vocabulary from `06-journald-and-Logging.md`, and the hardening-induced failure modes from `08-Security-and-Hardening.md` — into one general-purpose method applicable to any unit failure, regardless of which layer of the stack actually caused it.

This document does not introduce a large volume of new directives the way most of this series has. Its value is organizational: a decision procedure for taking an observed symptom ("this unit isn't working") and narrowing it, systematically rather than by guesswork, down to a specific, correctly-identified root cause among the many possible failure classes the previous eight documents have each covered in their own separate context.

---

## 1. The General Diagnostic Method

Every troubleshooting scenario in this document follows the same four-step skeleton, regardless of which specific failure class it eventually turns out to be:

1. **Establish the actual, current symptom precisely** (Section 2) — not what's assumed to be wrong, but what `systemctl` and the journal actually report right now.
2. **Read the `result=` field** (Section 3) — the single fastest triage signal, narrowing the entire space of possible causes to one of a small number of well-defined categories before any deeper investigation begins.
3. **Follow the category-specific method** for whichever `result=` value was found (Sections 4–12, one per category) — each of which draws on the specific tooling the relevant earlier document in this series already established.
4. **Confirm the fix, and confirm it didn't introduce a new problem** — re-running the same `result=` check (Section 3) after any remediation, rather than assuming a fix worked because the immediate symptom appears to have cleared.

Skipping step 2 — jumping directly to a specific hypothesis based on the symptom's surface appearance alone — is the single most common inefficiency in troubleshooting a systemd-managed system, and this document's structure is built specifically to prevent that jump.

---

## 2. Step 1: Establish the Actual Symptom

```bash
systemctl status webapp.service
systemctl is-active webapp.service
systemctl is-failed webapp.service
systemctl show webapp.service --property=Result,ExecMainStatus,ExecMainCode
```

`systemctl status` remains the single richest starting point — active state, recent log excerpt, and cgroup process tree (`01-Introduction.md` Section 9) all in one view — but `is-active`/`is-failed` are worth knowing as scriptable, exit-code-bearing equivalents for automation, and `systemctl show --property=Result` is the most direct way to extract precisely the field Section 3 is built around, without needing to parse it back out of `status`'s own human-formatted text output.

### 2.1 Distinguishing "never started" from "started, then failed"

```bash
systemctl show webapp.service --property=ActiveEnterTimestamp,InactiveEnterTimestamp
```

A unit that never successfully entered `active` at all (`03-Service-Management.md` Section 1's state machine) presents differently from one that ran successfully for some period and then later failed — the former points toward a startup-time problem (Sections 5–7, 10), the latter toward either a runtime crash or an externally-triggered stop (Sections 5, 12). `ActiveEnterTimestamp` being empty/unset is the direct signal the unit never successfully reached `active` even once during its current invocation.

### 2.2 Reading `systemctl status` Field by Field

Since `status` is the very first command in this document's method, it's worth a complete, deliberate walkthrough of what each line actually reports, rather than treating it as an opaque block of text to skim:

```
● webapp.service - Example web application
     Loaded: loaded (/etc/systemd/system/webapp.service; enabled; preset: disabled)
     Active: failed (Result: exit-code) since Fri 2026-07-17 14:02:11 UTC; 3min ago
    Process: 4821 ExecStart=/srv/webapp/bin/serve (code=exited, status=1/FAILURE)
   Main PID: 4821 (code=exited, status=1/FAILURE)
        CPU: 812ms
```

The bullet (`●`) mirrors `02-Units-and-Dependencies.md` Section 9's `list-dependencies` convention — colored/filled to reflect current health at a glance, before reading any text at all. **`Loaded:`** confirms the unit file's own path, whether it's `enabled` (per `01-Introduction.md` Section 10's persistence-versus-current-state distinction — this says nothing about whether it's *currently running*), and its `preset` state — a detail not otherwise covered in this series, referring to distribution-level default-enablement policy, worth knowing exists but rarely the actual subject of an investigation. **`Active:`** is the line carrying this document's central `Result=` field directly in parentheses, plus a precise timestamp and relative-age — both worth cross-referencing against `06-journald-and-Logging.md` Section 5.2's `--since` filtering when pulling the surrounding log context. **`Process:`**/**`Main PID:`** report the specific `code=`/`status=` pairing Section 5.1–5.2 of this document build directly on — `code=exited` pairs with a numeric exit status (Section 5.1), while `code=killed` pairs with a signal name (Section 5.2), and this distinction is visible right here, in the very first command run, before any deeper `journalctl` investigation is even necessary. **`CPU:`** (and, for a still-active unit, additional lines covering `Tasks:`, `Memory:`, and the full cgroup tree, per `01-Introduction.md` Section 9's own worked example) rounds out the picture with resource-usage context directly relevant to Section 12's OOM-kill diagnosis, without needing a separate command.

---

## 3. Step 2: Read the `result=` Field — The Fastest Triage

Every unit failure carries a `Result=` property (visible via `systemctl show`, and echoed in the corresponding journal line as `Failed with result '...'`, a phrase this series has used in worked examples since `02-Units-and-Dependencies.md`). This one field is the fastest, most reliable triage signal available, because it categorizes the failure at the source, rather than requiring inference from symptoms alone.

| `result=` value | Meaning | Where covered |
|---|---|---|
| `exit-code` | The process itself exited with a non-zero status | Section 5 |
| `signal` | The process was terminated by a signal (including `SIGSYS` from a syscall filter, `SIGKILL` from a timeout escalation) | Sections 5, 10 |
| `timeout` | A `TimeoutStartSec=`/`TimeoutStopSec=` deadline was exceeded | Section 5 |
| `watchdog` | A `WatchdogSec=` liveness check was missed | Section 5 |
| `dependency` | A required unit failed to start, propagating failure upward | Section 4 |
| `start-limit-hit` | `StartLimitBurst=` was exceeded; automatic restarts have stopped | Section 5 |
| `oom-kill` | The kernel's out-of-memory killer terminated the process | Section 12 |
| `exec-condition` | An `ExecCondition=` evaluated false (a **skip**, not a true failure) | Section 5 |
| `resources` | systemd itself could not perform an operation needed to start the unit (e.g., unable to create a cgroup) | Section 6 |

### 3.1 Why this ordering matters

`dependency` is listed distinctly from every other value specifically because it changes the entire remainder of the investigation: a unit reporting `result=dependency` has **never actually attempted to run its own `ExecStart=` at all** — the fault lies entirely with whatever it depended on, and any time spent inspecting the *failed* unit's own configuration, logs, or code is time misdirected away from the actual root cause, which lies upstream. Every other value in this table indicates the unit's own start (or stop, or ongoing execution) was genuinely attempted and something about that specific attempt failed — a meaningfully different, and more locally-scoped, investigation.

---

## 4. Diagnosing `result=dependency` Failures

This is the general form of the method `02-Units-and-Dependencies.md` Section 13.1 first demonstrated at application-stack scale and `05-Boot-Process-and-Targets.md` Section 8.4 applied again at whole-boot scale.

### 4.1 The core method: find the first non-`dependency` failure

```bash
journalctl -b -p err --since "10 minutes ago"
```

A `result=dependency` cascade produces multiple journal lines, each reporting a *different* unit's own `dependency`-triggered failure, propagating upward through the graph exactly as `02-Units-and-Dependencies.md` Section 7 described. The correct method is **not** to investigate every failed unit in this cascade individually — it's to scan the same time window for the **first** entry carrying `result=exit-code`/`signal`/`timeout`/`oom-kill` (any value *other* than `dependency`), since that one entry is the actual root cause, and every `dependency`-labeled entry after it is downstream noise, already fully explained once the root cause itself is understood.

```bash
systemctl list-dependencies --reverse <the-unit-that-actually-failed>
```

Once the true root-cause unit is identified, `02-Units-and-Dependencies.md` Section 9's `--reverse` flag confirms the full downstream blast radius — every unit that depended, directly or transitively, on the one that actually failed — useful for confirming the cascade's scope matches what was actually observed, and for identifying anything else that might still be silently affected even if it hasn't yet surfaced its own symptom.

### 4.2 The `After=` without `Requires=`/`Wants=` trap, revisited

If the "root cause" unit identified via Section 4.1's method appears to have started successfully, yet something ordered `After=` it still failed as if the dependency were missing, revisit `02-Units-and-Dependencies.md` Section 3.1's core gotcha directly: an `After=` with no accompanying `Requires=`/`Wants=` provides no requirement guarantee at all, meaning the "dependency" was never actually a hard requirement in the graph's own terms — the failing unit's own `Requires=`/`Wants=` declarations (or their absence) are themselves worth auditing as part of this specific investigation branch, since the apparent dependency failure may actually be a race condition stemming from an ordering-only relationship that was mistakenly assumed to also be a requirement one.

---

## 5. Diagnosing Service-Level Failures (`exit-code`, `signal`, `timeout`, `watchdog`, `start-limit-hit`)

These five values all indicate the unit's own `ExecStart=` was genuinely attempted — the investigation is now scoped to `03-Service-Management.md`'s own directive family.

### 5.1 `exit-code`: the application itself reported failure

```bash
journalctl -u webapp.service -n 50
systemctl show webapp.service --property=ExecMainStatus
```

The specific numeric exit code (`ExecMainStatus`) is the first thing worth checking against the application's own documentation or source — many applications use specific, documented exit codes to indicate specific failure classes (a configuration-file parse error might exit `2`, a failed pre-flight check `78`, and so on, though the exact convention is entirely application-specific), and this single number frequently narrows the investigation immediately without needing to read the surrounding log context at all.

### 5.2 `signal`: terminated externally, not a clean exit

```bash
systemctl show webapp.service --property=ExecMainStatus
```

A `signal`-based failure reports the specific signal number rather than an exit code. Two signals deserve specific recognition, both introduced earlier in this series: `status=31/SYS` (`SIGSYS`) is `08-Security-and-Hardening.md` Section 5.4's syscall-filter-violation signature — worth checking immediately whether `SystemCallFilter=` was recently added or tightened on this unit before investigating anything else. `status=9/KILL` (`SIGKILL`) most commonly indicates either `03-Service-Management.md` Section 7.2's `TimeoutStopSec=` escalation (a graceful `SIGTERM` was sent first and ignored) or `08-Security-and-Hardening.md`'s `MemoryDenyWriteExecute=`/similar hard restriction being violated — distinguishing between these requires checking the immediately preceding journal lines for a `State 'stop-sigterm' timed out` message (indicating the timeout-escalation path) versus its absence (suggesting a more direct kill, worth cross-referencing against Section 10's hardening-specific diagnosis or Section 12's OOM-kill check instead).

### 5.3 `timeout`: a deadline was exceeded

```bash
journalctl -u webapp.service --grep "Timeout"
```

Distinguish which specific timeout fired: a start-time timeout (`03-Service-Management.md` Section 7.1) most commonly indicates either a genuinely slow startup sequence exceeding a too-tight `TimeoutStartSec=`, or — for a `Type=notify` service specifically — a daemon that never actually calls `sd_notify(READY=1)` at all, meaning no `TimeoutStartSec=` value, however generous, would ever resolve the underlying issue; confirming which of these two is the case means checking whether the process is still visibly running and doing apparently-useful work right up until the timeout fires (suggesting genuinely slow startup) versus sitting idle or already fully initialized well before the timeout (suggesting a missing or broken `sd_notify` call).

### 5.4 `watchdog`: a liveness ping was missed

Per `03-Service-Management.md` Section 3.3's mechanism, this specifically indicates the process was still technically running but stopped sending `WATCHDOG=1` — `03-Service-Management.md` Section 13.1's `systemd-cgls` cross-check technique, applied *before* the watchdog timeout actually fires if the investigation catches it live, remains the most direct way to confirm whether the process is genuinely deadlocked versus merely delayed.

### 5.5 `start-limit-hit`: automatic recovery has been exhausted

This is a terminal state, not an ongoing one — the unit will **not** self-recover regardless of whether the underlying cause is fixed, per `03-Service-Management.md` Section 6's mechanism. `systemctl reset-failed <unit>` is the required step before any fix takes effect, and this is worth checking as literally the first thing whenever a "the fix didn't work" report follows a `start-limit-hit` diagnosis — the fix may well have been correct, but without the explicit reset, systemd never attempts the corrected configuration at all.

---

## 6. Diagnosing `result=resources` Failures

This category is distinct from every other value in Section 3's table — it indicates systemd **itself** was unable to perform some operation necessary to start the unit, before the unit's own `ExecStart=` was even reached at all: failing to create the unit's cgroup, failing to set up a requested private namespace (`08-Security-and-Hardening.md` Section 3), or a similar infrastructure-level failure.

```bash
journalctl -u webapp.service -p err --since "5 minutes ago"
```

The journal entry for this category typically names the specific underlying system call or resource that failed directly — a `cgroup` creation failure pointing toward the cgroup filesystem itself being in an unexpected state (worth checking `08-Security-and-Hardening.md` Section 3.6's `ProtectControlGroups=` interaction if recently added, or a more fundamental host-level cgroup exhaustion/misconfiguration), or a namespace-setup failure pointing toward `08-Security-and-Hardening.md` Section 3's directive family conflicting with the host kernel's own available namespace support. This category is genuinely rarer in practice than Sections 4–5's, but worth recognizing distinctly specifically because the fix, when needed, is almost never in the unit file's own application-level configuration at all — it's in the host's own kernel/cgroup/namespace-support state.

### 6.1 A Worked `resources` Scenario

Concretely: a unit newly configured with `08-Security-and-Hardening.md` Section 3.3's `PrivateUsers=yes` fails to start on a host running an older kernel version lacking full, unprivileged user-namespace support (a genuine, if increasingly rare, constraint on some older or deliberately security-conservative kernel configurations that disable this specific kernel feature system-wide).

```
systemd[1]: webapp.service: Failed to set up mount namespacing: Operation not permitted
systemd[1]: webapp.service: Failed at step NAMESPACE spawning /srv/webapp/bin/serve
systemd[1]: webapp.service: Failed with result 'resources'.
```

The `Failed at step NAMESPACE` phrase is the specific signature confirming this is a `resources`-category failure rooted in namespace setup specifically, not an application-level problem at all — the application's own `ExecStart=` binary was never even reached, exactly as Section 3's table describes for this category generally. The fix here lies entirely outside the unit file: either the host kernel's own configuration needs to permit unprivileged user namespaces (a system-wide `sysctl` setting, `kernel.unprivileged_userns_clone`, on kernels where this is configurable at all), or, if that host-level change isn't feasible or desirable, `PrivateUsers=` itself needs to be removed from this specific unit's configuration, accepting the reduced containment Section 3.3 of `08-Security-and-Hardening.md` describes as the trade-off for compatibility with this particular host's constraints — a decision to make deliberately, not by simply removing directives until the error disappears without understanding why it was occurring.

---

## 7. Diagnosing Unit File and Syntax Problems

A unit that fails to load at all — rather than loading and then failing to start — presents differently from everything in Sections 4–6, and is worth its own explicit check early in any investigation where the unit's very existence or basic recognition seems to be in question.

```bash
systemctl status webapp.service    # "not-found" or "bad-setting" rather than a normal state
systemd-analyze verify webapp.service
systemctl cat webapp.service       # confirm the actually-merged, effective configuration
```

`systemd-analyze verify` (`02-Units-and-Dependencies.md` Section 7.2) catches structural problems — an invalid directive, a malformed section header — before the unit is ever loaded into a real transaction at all. `systemctl cat`, per `04-Unit-Files.md` Section 3.4's drop-in mechanics, is essential specifically when a unit *does* load but behaves unexpectedly despite the base file appearing correct — confirming the fully-merged result after every drop-in has been applied, since a drop-in's own `04-Unit-Files.md` Section 3.2 append-versus-override behavior is a common source of "the base file looks right, so why is it behaving differently" confusion that only inspecting the merged, effective configuration resolves.

### 7.1 The quoting and comment traps

If a unit loads without error but a specific `ExecStart=` argument appears to be received incorrectly by the launched process, revisit `04-Unit-Files.md` Section 8.4's quoting rules directly — single quotes carrying no special meaning to systemd's own parser, and a trailing `# comment` on the same line as a directive becoming part of that directive's literal value rather than being stripped, are both silent, non-error-producing corruptions that `systemd-analyze verify` will not catch, since the resulting configuration is syntactically valid, just not what its author intended.

---

## 8. Diagnosing Boot-Time Failures

Applying `05-Boot-Process-and-Targets.md`'s own dedicated diagnostic chapter as one branch of this document's broader method, for the specific case where the symptom is "the machine itself failed to boot to a normal state" rather than an individual unit failing on an otherwise-healthy, already-booted system.

```
[On console, or via journalctl -xb after reaching a shell]
```

The single most important triage question here is **which target was reached** — `05-Boot-Process-and-Targets.md` Section 8's `emergency.target`-versus-`rescue.target` distinction determines the entire remaining investigation: `emergency.target` (involuntary, per Section 8.2 of that document) points toward `sysinit.target`'s own prerequisite chain having failed — apply Section 4 of *this* document's `result=dependency` method directly, since the underlying mechanism is identical, just occurring earlier in the boot sequence than this document's other examples have generally assumed. A normal login prompt reached, but with one or more expected services visibly not running, is a materially different, narrower-scope investigation — apply Sections 4–7 of this document against the specific missing unit(s), the machine having otherwise booted successfully.

```bash
systemd.log_level=debug systemd.log_target=console rd.break
```

For a failure severe enough that no shell is ever reached at all, `05-Boot-Process-and-Targets.md` Section 10.1's worked debug-parameter combination remains the correct escalation, applied here as this document's own Section 8's final fallback when every other technique in this section assumes at least *some* diagnosable state was reached.

---

## 9. Diagnosing Logging Gaps

Sometimes the symptom itself is an *absence* of expected log data, rather than an observable failure — worth its own dedicated check, since an apparent silence can stem from several genuinely different causes covered across `06-journald-and-Logging.md`.

```bash
journalctl -u webapp.service --grep "Suppressed"
```

Check first for `06-journald-and-Logging.md` Section 11's rate-limiting suppression signature — an apparent gap during exactly a unit's worst period of misbehavior is very often the rate limiter itself, not genuine silence.

```bash
journalctl --namespace=<name> -u webapp.service
```

If the unit is configured with `06-journald-and-Logging.md` Section 12's `LogNamespace=`, an ordinary, unqualified `journalctl -u webapp.service` query is not merely filtered — it queries the wrong journal instance entirely, and will show nothing at all regardless of how much the unit has actually logged; confirming whether `LogNamespace=` is set on the unit (`systemctl show webapp.service --property=LogNamespace`) is worth checking early whenever a unit's logging appears entirely, rather than partially, absent.

```bash
systemctl show systemd-journald --property=ActiveState
journalctl --disk-usage
```

Finally, confirm `journald` itself is healthy and the persistent journal (`06-journald-and-Logging.md` Section 3.1) is actually configured and has available space — a `Storage=`-related misconfiguration or a disk-space exhaustion at the journal layer itself, rather than anything about the specific unit under investigation, is the least common but most fundamental possible explanation for an apparently complete absence of any logging whatsoever, across every unit rather than just the one initially suspected.

---

## 10. Diagnosing Timer-Related Failures

Applying `07-Timers-and-Scheduled-Tasks.md` Section 9.1's method as a distinct branch, for the specific symptom "a scheduled task didn't run when expected."

```bash
systemctl list-timers --all <name>.timer
systemctl status <name>.timer
systemctl status <name>.service
```

The critical first distinction, per `07-Timers-and-Scheduled-Tasks.md` Section 9's own guidance: check the **timer's** own status before assuming the problem lies in the triggered service — a disabled or masked timer produces no error signal at all, only a quiet absence of the expected recurring activity, and `list-timers --all` (surfacing disabled timers the default view omits) is the fastest way to rule this specific, silent cause out or in before investigating the triggered service's own logic at all.

If the timer itself is confirmed active and correctly scheduled, but the triggered service's own `result=` (Section 3) shows a failure, the investigation folds directly into Sections 4–7 of this document, applied against the triggered `.service` unit exactly as it would be for any directly-started service — the timer mechanism itself is, at that point, no longer the relevant layer.

---

## 11. Diagnosing Hardening-Induced Failures

Consolidating `08-Security-and-Hardening.md`'s own scattered diagnostic notes into one direct checklist, for the specific, common scenario where a unit worked correctly before a hardening pass and stopped working after one.

| Symptom | Likely directive | Section (this doc / 08) |
|---|---|---|
| `status=31/SYS`, `result=signal` | `SystemCallFilter=` too restrictive | 5.2 / 5.4 |
| Permission-denied write failures to a previously-writable path | `ProtectSystem=`/missing `ReadWritePaths=` | 7 / 2.1, 2.3 |
| Service can't reach the network at all | `PrivateNetwork=yes` set incorrectly | 5 / 3.2 |
| Service can't bind its configured port | Missing `AmbientCapabilities=CAP_NET_BIND_SERVICE` after removing root | 5 / 4.2–4.3 |
| Persistent data missing/inaccessible after a restart | `DynamicUser=yes` without matching `StateDirectory=` | 5 / 8.1 |
| Service fails only under genuine load, not in light testing | `TasksMax=`/`MemoryMax=` too tight for real workload | 12 / 7.1, 7.4 |

The general method, given this table: **first**, confirm via `systemctl cat` (Section 7) exactly which hardening directives are actually present on the unit — not merely which ones a recent change was *intended* to add, since a drop-in merge issue (Section 7's own caution) could mean the effective configuration differs from what was intended. **Second**, cross-reference the specific symptom against this table's left column. **Third**, apply `08-Security-and-Hardening.md` Section 1.3's own incremental-verification principle in reverse — temporarily removing (or loosening, per Section 5.2's `SystemCallErrorNumber=EPERM` technique) only the one specific suspected directive, confirming the functionality returns, before deciding on the correct, narrower permanent fix rather than removing the entire hardening pass wholesale to "make the error go away," which would discard every other, unrelated directive's own independent value along with it.

---

## 12. Diagnosing OOM Kills

A failure category not yet covered in depth elsewhere in this series, worth its own dedicated section given how easily it can be mistaken for an application-level crash.

```bash
systemctl show webapp.service --property=Result
# Result=oom-kill
journalctl -k --grep "Out of memory"
dmesg | grep -i "killed process"
```

An `oom-kill` result means the **kernel's** own out-of-memory killer terminated the process — either the traditional, system-wide OOM killer (triggered by genuine, whole-system memory exhaustion) or, more precisely and more commonly on a well-configured system, `08-Security-and-Hardening.md` Section 7.1's cgroup-scoped `MemoryMax=` enforcement, which invokes the OOM killer specifically and only against the offending unit's own cgroup once its configured ceiling is exceeded, rather than making a more disruptive, worse-informed system-wide choice.

```bash
systemctl show webapp.service --property=MemoryMax,MemoryCurrent
```

Comparing `MemoryCurrent` (the cgroup's actual peak usage, if still queryable shortly after the kill) against the configured `MemoryMax=` confirms whether this was a genuine, expected-behavior ceiling enforcement (the workload legitimately grew beyond a deliberately-set limit — worth revisiting whether the limit itself needs raising, or whether the workload has a genuine memory leak worth investigating on its own terms) versus a limit that was set without properly accounting for the application's actual real-world memory needs under production load, distinct diagnoses that call for genuinely different remediations — raising the limit in the latter case, investigating the application's own memory behavior in the former.

---

## 13. Diagnosing Ordering Cycles

Revisiting `02-Units-and-Dependencies.md` Section 7 with the fuller toolkit this series has since established, for the specific symptom "a unit or set of units behaves as if an ordering constraint I wrote is simply being ignored."

```bash
journalctl -b --grep "ordering cycle"
```

Per `02-Units-and-Dependencies.md` Section 7, a broken cycle logs the specific edge systemd chose to discard — search for this signature directly rather than assuming a missing ordering guarantee is a bug in systemd itself; it is far more commonly the deterministic, documented consequence of a genuine cycle among several units' own declared constraints.

```bash
systemd-analyze verify <unit>
systemd-analyze dot 'suspected-unit.*' 'related-unit.*' | dot -Tsvg > cycle-check.svg
```

`02-Units-and-Dependencies.md` Section 7.2's `dot`-based visual rendering remains the fastest way to actually *see* a suspected cycle among a handful of specifically-named units, scoped narrowly per that section's own guidance against rendering the entire system's graph unfiltered.

---

## 14. Reaching Beyond systemd's Own Tooling: `strace` and `ltrace`

Every technique in Sections 2–13 works entirely within systemd's own introspection surface. Occasionally, a root cause lies at a level of detail no `systemctl`/`journalctl`/`systemd-analyze` invocation can directly surface — the exact system call an application is blocking on, or the exact library call failing silently before the application's own logging even has a chance to report anything. `strace`, while not a systemd-native tool, integrates cleanly into this document's method as the natural next step once Sections 2–13's own tooling has narrowed the investigation as far as it can but hasn't yet reached a fully explained root cause.

```bash
sudo systemd-run --pty --same-dir --uid=webapp \
  strace -f -e trace=network,file /srv/webapp/bin/serve
```

Wrapping the actual `ExecStart=` command in `strace` via `systemd-run` (`03-Service-Management.md` Section 14), rather than modifying the real unit file directly, keeps the diagnostic run cleanly separated from the production unit's own configuration — `-f` follows child processes (relevant given this series' consistent emphasis on cgroup-wide process tracking, `01-Introduction.md` Section 9), and `-e trace=` scopes the trace to a specific syscall category rather than the entire, extremely verbose unrestricted trace, directly useful for confirming `08-Security-and-Hardening.md` Section 5.4's syscall-filter-violation hypothesis with full certainty — running the identical command *without* the unit's own `SystemCallFilter=` applied, observing exactly which syscall the unfiltered run makes that the filtered, production configuration would have blocked, closing the loop on Section 11's hardening-diagnosis table with direct, first-hand confirmation rather than inference from the `status=31/SYS` signature alone.

**A caution worth stating directly:** `strace` itself uses `ptrace()`, which several of `08-Security-and-Hardening.md`'s own directives (`RestrictNamespaces=` and, more directly, a `CapabilityBoundingSet=` excluding `CAP_SYS_PTRACE`, per that document's Section 4.2a table) can themselves block — meaning a heavily-hardened production unit may need its sandboxing directives *specifically and temporarily* loosened, in a dedicated diagnostic copy rather than the production unit itself, before `strace` can attach to it at all. This is a genuine, if narrow, tension between this document's Section 14 and `08-Security-and-Hardening.md`'s own recommendations — resolved in practice by running the diagnostic trace against a separate, unhardened `systemd-run`-launched copy of the same command, as the example above already does, rather than attempting to relax a production unit's hardening merely to enable a one-off diagnostic session against it.

---

## 15. The `systemd-analyze` Toolkit, Consolidated

A single reference table gathering every `systemd-analyze` subcommand this series has introduced across separate documents, since a troubleshooting session frequently needs to reach for more than one of these in sequence:

| Subcommand | Answers | Introduced |
|---|---|---|
| `verify` | Is this unit file structurally valid? | `02-Units-and-Dependencies.md` §7.2 |
| `dot` | What does the dependency graph actually look like? | `02-Units-and-Dependencies.md` §7.2 |
| `blame` | Which units took the longest to start, individually? | `02-Units-and-Dependencies.md` §10.2 |
| `critical-chain` | What is the actual serial bottleneck path? | `02-Units-and-Dependencies.md` §10.3 |
| `plot` | What did the boot timeline actually look like, visually? | `02-Units-and-Dependencies.md` §10.4 |
| `time` | What's the high-level kernel/initrd/userspace breakdown? | `05-Boot-Process-and-Targets.md` §9 |
| `calendar` | Does this `OnCalendar=` expression mean what I think it means? | `07-Timers-and-Scheduled-Tasks.md` §10 |
| `security` | What is this unit's aggregate hardening exposure? | `08-Security-and-Hardening.md` §9 |
| `dump` | What is systemd's complete internal state for this unit? | `02-Units-and-Dependencies.md` §10.5 |

---

## 16. A Master Decision Procedure

Consolidating Sections 1–13 into one linear procedure, suitable as a genuine first-response checklist for an unfamiliar unit failure:

1. `systemctl status <unit>` — establish the current state and grab the recent log excerpt (Section 2).
2. Check `Result=` via `systemctl show <unit> --property=Result` (Section 3).
3. **If `dependency`:** find the first non-`dependency` failure in the same time window (Section 4) and restart this procedure against *that* unit instead.
4. **If `exit-code`/`signal`/`timeout`/`watchdog`/`start-limit-hit`:** apply Section 5's specific sub-method for that value.
5. **If `resources`:** check host-level cgroup/namespace state rather than the unit's own configuration (Section 6).
6. **If the unit failed to load at all** (never reached any of the above): `systemd-analyze verify` and `systemctl cat` (Section 7).
7. **If the symptom is boot-level rather than a single unit:** apply Section 8's target-identification method first.
8. **If the symptom is an absence of expected logging:** apply Section 9's rate-limit/namespace/journald-health checks before concluding the unit itself produced no output.
9. **If the symptom is a missed scheduled task:** check the timer's own status before the triggered service's (Section 10).
10. **If the unit worked before a recent hardening change:** consult Section 11's symptom table directly.
11. **If `Result=oom-kill`:** compare configured limits against actual peak usage (Section 12).
12. **If an ordering constraint appears to be silently ignored:** search for the cycle-breaking log signature before assuming a configuration bug elsewhere (Section 13).
13. Once a root cause is identified and a fix applied, **re-run step 2** against the same unit to confirm the `Result=` now reflects success, rather than assuming the fix worked from the symptom's surface disappearance alone.

---

## 17. A Fully Worked Multi-Layer Incident

Bringing several of this document's sections together against one realistic, deliberately non-obvious scenario: `webapp.service` begins failing intermittently, several days after an unrelated hardening pass (`08-Security-and-Hardening.md`) was deployed, with no code or configuration change to the application itself in between.

**Step 1 (Section 2):** `systemctl status webapp.service` shows `failed`, with a recent restart having occurred.

**Step 2 (Section 3):** `systemctl show webapp.service --property=Result` returns `Result=signal`, `ExecMainStatus` showing `9` (`SIGKILL`) — ruling out `dependency` (Section 4) and `exit-code` (a clean application-level failure) immediately, narrowing to Section 5.2's signal-diagnosis branch.

**Step 3 (Section 5.2):** The signal is `SIGKILL`, not `SIGSYS` — ruling out a syscall-filter violation (`08-Security-and-Hardening.md` Section 5.4) as the direct cause, and prompting a check of the immediately preceding journal lines for a `TimeoutStopSec=`-escalation message.

**Step 4:** No `State 'stop-sigterm' timed out` message is present — ruling out Section 5.2's timeout-escalation explanation, and per that section's own guidance, prompting a check of Section 12's OOM-kill possibility instead.

**Step 5 (Section 12):** `journalctl -k --grep "Out of memory"` confirms a kernel OOM-kill event, timestamped to match. `systemctl show webapp.service --property=MemoryMax` reveals a `MemoryMax=512M` ceiling — present, but not something anyone on the team recalls setting deliberately.

**Step 6 (Section 11's method, applied in reverse):** `systemctl cat webapp.service` reveals the limit was introduced as part of the hardening pass several days prior (`08-Security-and-Hardening.md` Section 10's own Stage 4), not something wrong with the application's memory behavior at all — the actual root cause is that the value chosen during that hardening pass was based on the application's memory footprint *at the time*, and the application's genuine, legitimate memory needs have since grown (a larger in-memory cache, added under an unrelated, entirely reasonable feature change) past that now-stale ceiling.

**Step 7 (remediation and verification, per Section 16 step 13):** The `MemoryMax=` value is raised to reflect the application's current, legitimate needs (verified via `systemctl show webapp.service --property=MemoryCurrent` sampled under realistic load before finalizing the new ceiling), `systemctl daemon-reload` and `systemctl restart webapp.service` applied, and `systemctl show webapp.service --property=Result` re-checked after the change has been running under real traffic for a representative period, confirming `Result=success` rather than assuming the fix worked merely because the immediate restart succeeded.

This trace illustrates the core value of Section 1's four-step skeleton directly: at no point did the investigation need to guess — each step's `result=`/journal signature deterministically ruled out entire categories from Section 3's table, arriving at the correct, specific root cause (a resource-control ceiling that had simply gone stale relative to the application's own legitimate growth, not a bug, not a misconfiguration in the traditional sense) considerably faster than an unstructured investigation starting from "the app keeps crashing, let's check the code" would likely have managed, given that the actual cause had nothing to do with the application's own code at all.

### 17.1 A Second, Shorter Incident: The Dependency Cascade

Not every investigation needs Section 16's full seven-step depth — worth demonstrating the method's fast path too, for a more straightforward case. `webapp.service`, `cache.service`, and a third, previously-unmentioned `search-indexer.service` all report `failed` simultaneously, immediately after a scheduled maintenance window during which the underlying storage array was briefly reconfigured.

**Step 1–2 (Sections 2–3):** `systemctl show` against all three reports `Result=dependency` uniformly — immediately ruling out three separate, independent application-level investigations per Section 4.1's core guidance.

**Step 3 (Section 4.1):** `journalctl -b -p err --since "15 minutes ago"` surfaces a fourth unit, `srv-shared-data.mount`, with `Result=exit-code` — the actual root cause, timestamped immediately before all three `dependency` failures and clearly connected to the maintenance window's storage reconfiguration.

**Step 4:** Inspection of `srv-shared-data.mount`'s own failure reveals the underlying device UUID changed during the storage reconfiguration, and `/etc/fstab` (`04-Unit-Files.md` Section 7.2) was never updated to reflect the new UUID.

**Step 5 (remediation and verification):** `/etc/fstab` corrected, `systemctl daemon-reload` (re-running `systemd-fstab-generator`), `systemctl start srv-shared-data.mount` confirmed successful, followed by `systemctl start` against each of the three originally-failed units in turn, each now succeeding since their shared upstream dependency is finally healthy.

This second trace took four steps rather than seven specifically because Section 4.1's method — scan for the single non-`dependency` entry rather than investigating every failed unit — collapsed what could easily have become three parallel, redundant investigations (one per originally-visible failed unit) into one single, correctly-scoped one, arriving at a root cause entirely unrelated to any of the three services' own application code, in a domain (storage/mount configuration) none of their own individual logs would have pointed toward directly.

---

## 18. Common Anti-Patterns in Troubleshooting Itself

**Investigating every unit in a `result=dependency` cascade individually.** As covered in Section 4.1, this is strictly less efficient than finding the single, first non-`dependency` entry — every other entry in the cascade is already fully explained once that one root cause is understood.

**Assuming a hardening-adjacent failure means the entire hardening pass should be reverted.** As covered in Section 11, the correct response is identifying and adjusting the *one specific* directive responsible, per `08-Security-and-Hardening.md` Section 1.3's own incremental principle — a wholesale revert discards every other, unrelated directive's independent value along with the one actually at fault.

**Treating `start-limit-hit` as if the underlying fix alone resolves it.** As covered in Section 5.5, this is a terminal, latched state requiring an explicit `systemctl reset-failed` regardless of how correct the underlying fix is — a very common source of "I fixed it but it's still broken" confusion.

**Skipping the `result=` check and jumping directly to reading full application logs.** As covered in Section 1's core method, this discards the fastest available triage signal — a `dependency` or `oom-kill` result, both diagnosable in seconds via `systemctl show`, can otherwise cost a considerably longer, less-focused read through the full, undifferentiated log output before the same conclusion is eventually reached by inference instead.

**Concluding a unit is "silently producing no logs" without checking for rate limiting or namespace misconfiguration first.** As covered in Section 9, both are common, non-obvious explanations for an apparent logging gap that have nothing to do with the unit itself having actually stopped producing output.

**Confusing a timer's own health with its triggered service's health.** As covered in Section 10, checking only one of the two — commonly, only the triggered service, once a failure is suspected — can miss a silently-disabled timer entirely, or conversely miss a triggered service that's been failing on every single invocation despite the timer itself firing perfectly on schedule.

**Attempting a remediation before scope is actually established.** As covered in Section 20's fast-path checklist, applying a fix to the first failed unit noticed, before checking `systemctl --failed` for the true, full extent of an incident, risks addressing a downstream symptom of a `result=dependency` cascade (Section 4) while the actual root cause — often a different, not-yet-noticed unit entirely, as in Section 17.1's worked example — remains unaddressed and continues producing further, ongoing symptoms.

---

## 19. Exercises

**1.** `journalctl -b -p err` shows five different units, each with `result=dependency`, all within the same two-second window. What is the correct first action? *(Per Section 4.1, scan the same window for the single unit reporting a non-`dependency` result value — that one unit is the actual root cause, and investigating any of the other four individually before finding it is a wasted, redundant effort, since all five are explained by the same single upstream failure.)*

**2.** A unit's `journalctl` output shows `status=31/SYS` immediately before a `Failed with result 'signal'` line, one day after a `SystemCallFilter=` directive was added. Per this document's method, what should be checked before assuming the syscall filter is the cause? *(Per Section 5.2 and Section 7's caution about drop-in merges, confirm via `systemctl cat` that the *effective*, currently-merged `SystemCallFilter=` value actually matches what was intended — a drop-in ordering or override mistake could mean the deployed filter is stricter, or different, from what the change was believed to have applied, and jumping straight to "the filter is too strict" without confirming what filter is actually in effect risks fixing the wrong thing.)*

**3.** A `MemoryMax=` ceiling was set six months ago during an initial hardening pass. A unit begins hitting `result=oom-kill` today, with no application code change in the intervening period. Per Section 17's worked incident, what are the two genuinely distinct possible explanations, and how would an investigator distinguish between them? *(Either the application's legitimate memory needs have grown over time past a ceiling that was reasonable when originally set — distinguished by comparing current `MemoryCurrent` under realistic load against the historical value the ceiling was based on — or the application has a genuine memory leak that has only now grown large enough to exceed the ceiling — distinguished by observing whether memory usage climbs steadily and without bound over a single run's own lifetime, versus reaching a new, but stable, higher plateau consistent with legitimately increased steady-state usage.)*

**4.** A timer's `list-timers --all` output shows it as enabled and correctly scheduled, with a recent `LAST` timestamp matching the expected schedule precisely. The triggered service, however, has not produced any expected downstream effect (a file that should have been created is absent). Per Section 10's method, where should the investigation proceed next? *(Directly into Sections 4–7 of this document, applied against the *triggered service* itself, exactly as they would be for any directly-started unit — per Section 10, once the timer's own health is confirmed, the timer layer is no longer the relevant one, and the investigation should proceed as an ordinary service-level troubleshooting exercise rather than continuing to focus on the scheduling mechanism.)*

**5.** Three unrelated services fail simultaneously immediately after a storage maintenance window, all reporting `Result=dependency`. Per Section 17.1's worked incident, what is the single fastest action, and why is investigating each of the three individually a less efficient choice? *(Search the same time window for the one unit reporting a non-`dependency` result — per Section 4.1, all three are downstream symptoms of that single upstream failure, so investigating them individually means redundantly re-discovering the identical root cause up to three separate times rather than once.)*

**6.** An investigator wants to confirm, with full certainty, that a `SIGSYS` failure is specifically caused by `SystemCallFilter=` rather than some other cause coincidentally producing the same signal. What is the most direct way to obtain that certainty, and what caution applies? *(Per Section 14, running the identical command via `strace` under `systemd-run`, both with and without the suspected `SystemCallFilter=` applied, directly reveals whether the unfiltered run makes a syscall the filtered configuration would reject — the caution being that `strace` itself requires `ptrace()` access, which several of `08-Security-and-Hardening.md`'s own hardening directives can block, meaning the trace should be run against a separate, deliberately unhardened diagnostic copy rather than attempting to trace the hardened production unit directly.)*

---

## 20. The First Five Minutes: A Fast-Path Checklist

For an active, ongoing incident where minimizing time-to-diagnosis matters more than a complete, methodical pass through every section of this document, the following condensed sequence covers the highest-value checks first, each answerable in well under a minute:

1. `systemctl --failed` — list every currently-failed unit system-wide in one call, immediately revealing whether the actual scope of the incident is one unit or many (directly informing whether Section 4's cascade-triage method applies at all).
2. `systemctl show <unit> --property=Result` against each failed unit found in step 1 — sorting the failures into Section 3's categories before reading a single line of free-text log output.
3. If any unit shows `Result=dependency`: apply Section 4.1 immediately, narrowing the entire incident to whichever single unit does *not* show that value.
4. `journalctl --since "10 minutes ago" -p err` (system-wide, not yet scoped to any one unit) — a fast, broad scan for anything else notable in the same window that steps 1–3's unit-scoped checks might have missed, particularly relevant for Section 17.1-style incidents where the true root cause is a unit nobody initially suspected.
5. Only once steps 1–4 have established the scope and category: proceed into this document's full, category-specific sections (4–14) for the actual detailed remediation work.

This sequence is deliberately front-loaded with the checks that most efficiently *narrow scope*, per Section 1's own reasoning for placing the `result=` check before any deeper investigation — the goal in the first five minutes of an active incident is establishing exactly what is and isn't broken, and roughly why, not yet fixing anything, since a fix attempted before scope is correctly understood risks being misdirected at a downstream symptom rather than the actual root cause, exactly as Section 4.1 cautions against for the dependency-cascade case specifically.

---

## 21. Quick-Reference Table

| `result=` value | First action |
|---|---|
| `dependency` | Find the first non-`dependency` failure in the same window (§4) |
| `exit-code` | Check the specific numeric exit status against application docs (§5.1) |
| `signal` | Identify the specific signal — `SIGSYS`→hardening, `SIGKILL`→timeout or OOM (§5.2) |
| `timeout` | Distinguish genuinely-slow startup from a missing `sd_notify` call (§5.3) |
| `watchdog` | Cross-check with `systemd-cgls` for a genuine deadlock (§5.4) |
| `start-limit-hit` | `systemctl reset-failed` is required regardless of the underlying fix (§5.5) |
| `resources` | Check host-level cgroup/namespace state, not the unit file (§6) |
| `oom-kill` | Compare `MemoryCurrent` against `MemoryMax=` under real load (§12) |
| (unit won't load at all) | `systemd-analyze verify` and `systemctl cat` (§7) |

---

## 22. Glossary

**Triage** — the initial, fast categorization step (reading `result=`) that determines which deeper investigative branch to follow, before any detailed inspection begins.
**Root cause** — the single, first genuine failure in a chain of propagated or downstream symptoms, as distinct from every subsequent effect it produced.
**Cascade** — a set of `result=dependency` failures propagating upward through the graph from one single, actual root-cause unit.
**Terminal state** — a failure state (`start-limit-hit` being the running example) that will not self-resolve even once its underlying cause is fixed, requiring an explicit reset.
**Stale configuration** — a previously-correct setting (Section 17's `MemoryMax=` being the worked example) that has become incorrect not because it was ever wrong, but because circumstances around it have legitimately changed since it was set.
**Scope narrowing** — the process of establishing exactly which units and which category of failure an incident actually involves, before attempting any remediation, per Section 20's fast-path checklist.
**False lead** — a unit or symptom that appears related to an incident but is, on closer investigation, an independent downstream effect of the same root cause rather than a separate problem requiring its own fix.

---

## 23. What's Ahead

`10-References.md`, the final document in this series, consolidates the manual-page and further-reading references scattered across every preceding document's own closing section into one complete, organized bibliography, alongside a full cross-reference index mapping every directive covered throughout this series back to the specific document and section where it was introduced.

---

## References

- `systemd.exec(5)`, `systemd.service(5)`, `systemd.unit(5)` — the primary directive references this document's diagnostic branches ultimately resolve back into
- `journalctl(1)` — the complete query reference underlying Sections 4, 9, and 16's worked investigations
- `systemd-analyze(1)` — the consolidated toolkit reference in Section 14
- `systemd.exec(5)` §"PROCESS EXIT CODES" — the canonical `result=` value reference underlying Section 3's table
