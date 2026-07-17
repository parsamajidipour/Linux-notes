# Units and Dependencies

A complete, mechanism-level reference for every dependency-related directive systemd exposes, how the transaction engine actually resolves them into an execution plan, how implicit dependencies are injected without your knowledge, how ordering cycles are detected and broken, how socket- and resource-level relationships fold into the same graph, and how to read the diagnostic tools (`systemctl list-dependencies`, `systemd-analyze dot`, `systemd-analyze critical-chain`) that make this graph inspectable instead of theoretical.

`01-Introduction.md` established the core distinction between **requirement** ("do I need it to exist at all") and **ordering** ("when, relative to it"). This document assumes that distinction as known and goes substantially deeper: the full directive vocabulary, the algorithm systemd actually runs to turn declarations into an execution plan, worked failure scenarios with real log output, and enough repetition across different angles that you can *predict* — not guess — how a real multi-service stack will sequence itself at boot, under partial failure, and under manual intervention.

---

## 1. The Graph, Restated Precisely

Every unit systemd loads becomes a node in an in-memory dependency graph. Every dependency directive in a unit file becomes one or more **directed edges** in that graph — and critically, most dependency directives create edges **in both directions simultaneously**, with different semantics attached to each direction. This bidirectional-by-default behavior is the single most misunderstood mechanism in systemd, so it is worth stating precisely before touching individual directives.

When unit `A` declares `Wants=B`, systemd does two things:

1. It adds a **forward** edge: "when A is started, try to start B too."
2. It records the relationship on `B` as well, internally, so that tools like `list-dependencies --reverse` (Section 9) can answer "who wants me" without re-scanning every unit file on the system. This reverse bookkeeping is informational, not a separate requirement — `B` failing to load has no effect on `A`'s own transaction under `Wants=`, precisely because the forward edge itself was already declared soft.

`Requires=`, `Requisite=`, `BindsTo=`, `Conflicts=`, and `PartOf=` all follow the same shape — a semantically-typed forward edge, plus reverse bookkeeping — but each forward edge carries different failure-propagation rules, which is the actual substance the rest of this document works through directive by directive.

### 1.1 Units, Jobs, and Transactions — three distinct things

It's worth fixing three terms precisely, because they get used loosely even in casual systemd discussion and the imprecision causes real confusion:

- A **unit** is the static, loaded configuration object — the parsed result of a `.service`/`.target`/etc. file. It exists in systemd's memory whether or not anything is currently happening to it.
- A **job** is a pending or in-progress *operation* against a unit — "start webapp.service," "stop postgresql.service," "reload nginx.service." A unit can have at most one job active against it at a time; requesting a second, conflicting job against a unit that already has one queued triggers systemd's job-merging or job-replacement logic rather than simply queuing two operations.
- A **transaction** is the complete, closed set of jobs systemd computes and validates together in response to a single request — e.g., `systemctl start webapp.service` does not create a single job, it creates a transaction potentially containing dozens of jobs (starting `webapp.service` itself, plus every unit reachable via its requirement edges that isn't already in the desired state), which is verified as internally consistent *before any job in it actually runs*.

This three-way distinction matters because most of the mechanisms described later in this document — cycle detection, job merging, isolate transactions — are operations on the **transaction**, computed once, up front, not something systemd figures out incrementally as it goes.

### 1.2 Job types

Every job systemd queues has a type, and the type affects how conflicting/overlapping jobs against the same unit are reconciled:

| Job type | Effect |
|---|---|
| `start` | Bring the unit to `active` |
| `stop` | Bring the unit to `inactive`/`failed` cleanly |
| `restart` | `stop` followed by `start`, as one logical job |
| `reload` | Invoke `ExecReload=` without stopping the unit |
| `try-restart` | `restart`, but only if currently active |
| `verify-active` | A no-op check used internally to confirm a dependency is already satisfied without generating a redundant start |

`verify-active` deserves a specific mention: when systemd expands a transaction and finds a required unit is *already* active, it doesn't queue a redundant `start` job — it queues a lightweight `verify-active` job, which simply confirms the current state satisfies the dependency and otherwise does nothing. This is part of why re-running `systemctl start` against an already-running dependency chain is cheap and side-effect-free rather than restarting everything downstream.

### 1.3 Job Merging and Anti-Jobs

Building a transaction is not simply "union together every unit reachable via requirement edges and queue a start job for each." Two additional mechanics matter for correctly predicting what actually happens when a new request arrives against a system that already has units running or jobs pending.

**Job merging.** If, while expanding a transaction, systemd finds it needs to queue a `start` job for a unit that already has a `start` job pending from an earlier, still-in-flight request, it does not queue a second, redundant job — it merges the new request into the existing job. This is why issuing `systemctl start webapp.service` twice in rapid succession, before the first has finished, does not double-start anything or produce two competing supervisory jobs; the second request is folded into the first. Merging is not unconditional, though — a `start` request cannot merge with a pending `stop` job for the same unit; the two are contradictory, and this is precisely the scenario the next mechanic exists to resolve.

**Anti-jobs and transaction conflict resolution.** When a new transaction would require a job that directly contradicts a job already queued or in progress against the same unit — most commonly, a `stop` arriving while a `start` for the same unit is still pending — systemd has to decide how to reconcile them, and the default behavior (absent `--job-mode=fail`) is to **replace** the earlier, conflicting job with the new one, canceling whatever was in flight. This is the mechanism behind `systemctl restart` itself, conceptually: a `restart` request against a unit with no existing job is really "queue a stop, then queue a start after it," and if a `stop` is issued against a unit that's still mid-`start`, the in-progress start is cancelled in favor of immediately proceeding to stop once startup work that's already unavoidably in flight settles. `systemctl start --job-mode=fail webapp.service`, by contrast, disables this automatic replacement and instead makes the whole new transaction fail outright if it would conflict with something already queued — useful in automation contexts where silently superseding an in-flight operation is more dangerous than simply reporting a conflict and letting the caller retry.

---

## 2. Requirement-Class Directives (do I need it?)

These directives all answer the question "must this other unit exist / be running for me to be considered correctly up," but differ in how strictly, and in what happens on failure.

### 2.1 `Wants=`

The default, soft dependency. Declares that when this unit is started, systemd should *attempt* to start the listed unit(s) as well, but a failure of the wanted unit does not cause this unit's own start job to fail, and does not stop this unit from proceeding.

```ini
[Unit]
Wants=network-online.target
```

This is the correct choice for the overwhelming majority of real-world dependencies. If your service can tolerate the dependency being briefly unavailable (retrying its own connection internally, for instance), `Wants=` avoids letting one flaky dependency take down a chain of otherwise-healthy services. A useful mental test: if the unit you're depending on failing to start should be logged as a warning but should not prevent *your* unit from attempting to run, `Wants=` is correct. If it should prevent your unit from running at all, use `Requires=` instead.

**Gotcha:** `Wants=` alone gives you no ordering guarantee, as established in Section 3. A service that merely "wants" a cache but genuinely cannot function correctly if it starts *before* that cache (rather than merely running without one) needs `After=` added explicitly — `Wants=` by itself only guarantees an attempt was made somewhere in the same transaction, at an unspecified time relative to your own unit.

### 2.2 `Requires=`

A hard dependency. Starting this unit pulls in the required unit as part of the same transaction, and if the required unit **fails to start**, this unit's start job is also considered failed, and systemd will not proceed to start it. Note precisely what `Requires=` does *not* do on its own: it says nothing about order. Without an accompanying `After=`, systemd may start both units in parallel, meaning your process could begin executing before its hard dependency has actually finished initializing — it only guarantees the dependency was *attempted*, and that failure of the dependency fails you too.

```ini
[Unit]
Requires=postgresql.service
After=postgresql.service
```

This is why `Requires=` and `After=` are so often written together — omitting `After=` here is a common latent bug: everything appears fine because both units usually finish quickly enough in the order they happened to be scheduled, until the day `postgresql.service` is slow to start (a large WAL replay after an unclean shutdown, for instance) and `webapp.service` connects before the database is actually listening on its socket.

**Gotcha:** `Requires=` propagates failure only at **start time**. If `postgresql.service` starts successfully and `webapp.service` starts successfully, and *hours later* `postgresql.service` crashes, `webapp.service` is **not** automatically stopped — `Requires=` is not a standing runtime guarantee, only a start-time one. If you need the ongoing lifecycle coupling ("if this stops later, stop me too"), that is precisely what `BindsTo=` (Section 2.4) exists for, and the two are not interchangeable despite sounding similar.

### 2.3 `Requisite=`

A stricter variant of `Requires=`. Rather than *starting* the listed unit if it isn't already running, `Requisite=` checks whether it is **already active at the moment this unit's job runs**. If it is not, this unit's start job fails immediately, without systemd making any attempt to bring the dependency up.

```ini
[Unit]
Requisite=encrypted-data.mount
After=encrypted-data.mount
```

This is the correct tool when starting the dependency yourself would be meaningless or dangerous — for instance, a service that must run against an already-unlocked encrypted volume, where attempting to "start" the mount unit out of its proper sequence in the boot process could produce an inconsistent state rather than a helpful auto-start. `Requisite=` effectively says "I refuse to be the thing that triggers this dependency into existence — if it isn't already there, something upstream of me is broken, and I should fail loudly rather than paper over it."

**Gotcha:** `Requisite=` without `After=` is close to meaningless, because the check happens at whatever moment systemd gets around to evaluating this unit's job — without an explicit ordering constraint, that moment is not well-defined relative to the dependency's own startup, and you can get spurious failures if the two units happen to be scheduled such that the check runs before the dependency would have been ready anyway.

### 2.4 `BindsTo=`

Like `Requires=`, but with an additional, stronger lifecycle coupling: if the target unit **stops or fails at any point** — not just during this unit's startup, but any time later, even hours into both units running successfully — this unit is stopped as well, automatically, immediately, without any external transaction needing to request it.

```ini
[Unit]
BindsTo=dev-sdb1.device
After=dev-sdb1.device
```

This is the standard pattern for tying a unit's lifetime to a piece of hardware or a resource that can vanish out from under it — a device unit for removable media is the canonical example. If the drive is unplugged, the `.device` unit disappears (device units are entirely dynamic, generated by udev, not statically defined on disk), and anything `BindsTo=`'d to it is stopped rather than being left running against a resource that no longer exists, potentially spinning on I/O errors indefinitely.

**Practical example beyond hardware:** `BindsTo=` is also used to couple a helper/sidecar service tightly to the primary service it exists only to support — a log-shipping sidecar that has no purpose once the main application unit it's shipping logs *for* has stopped can `BindsTo=` that main unit, guaranteeing it's torn down in lockstep rather than lingering as an orphaned process shipping nothing.

### 2.5 `PartOf=`

A one-directional lifecycle coupling, narrower than `BindsTo=`. `PartOf=B` on unit `A` means: if `B` is **stopped or restarted**, `A` is stopped or restarted along with it — but the reverse is not true, and `A` failing has no effect on `B`, and starting `A` does not start `B`.

```ini
[Unit]
PartOf=webapp.service
```

Typical use: grouping several auxiliary units (a log-shipping sidecar, a metrics exporter) so that restarting the main application unit cleanly restarts its helpers too, without those helpers being able to independently affect the main unit, and without them being pulled in automatically if someone starts the main unit fresh (for that, you'd add `Wants=` or `Requires=` as well — `PartOf=` alone does not start anything; it only governs what happens on *stop*/*restart* of the unit it names).

**Comparison to `BindsTo=`:** the key difference is directionality and what triggers the coupling. `BindsTo=` reacts to the target *stopping for any reason, including an unexpected failure*, and is typically paired with resources that can disappear unexpectedly. `PartOf=` reacts specifically to an *administrative* stop/restart of the named unit, and is typically used to group sibling services under a conceptual "parent" for management convenience, without implying the parent's unexpected crash should be treated identically to a deliberate stop.

### 2.6 `Conflicts=`

The inverse of `Requires=`. If `A` `Conflicts=B`, then starting `A` will stop `B` if it's running, and vice versa — the two units are mutually exclusive within the graph. Every unit implicitly conflicts with `shutdown.target` by default (Section 4), which is what allows starting `shutdown.target` to cleanly terminate everything else on the system without every single unit file needing to hand-write shutdown behavior.

```ini
[Unit]
Conflicts=rescue.target
Before=rescue.target
```

`multi-user.target` and `rescue.target` conflict with each other by design — you cannot be booted into full multi-user mode and rescue mode simultaneously, and `systemctl isolate rescue.target` relies on exactly this mechanism (Section 8) to tear down the graphical/multi-user session cleanly before dropping to a rescue shell, rather than relying purely on "not in the dependency closure" to force the stop.

---

## 3. Ordering-Class Directives (when, relative to it?)

### 3.1 `Before=` and `After=`

Pure ordering constraints, carrying **no requirement semantics whatsoever**. `After=B` on unit `A` means only: "if both A and B are going to be started as part of the same transaction, start B first." It says nothing about whether B is started *at all* — that is entirely the job of the requirement-class directives above. `Before=` is simply the same constraint expressed from the other unit's perspective, and in practice `Before=B` on `A` is exactly equivalent to writing `After=A` on `B` — systemd treats them as two ways of writing the identical graph edge, and you'll see both styles depending on whether the "waiting" unit or the "waited-for" unit is the one being authored/edited.

```ini
[Unit]
After=network-online.target
Before=nginx.service
```

The single most repeated mistake in unit files is treating `After=` as if it implies `Requires=`. It does not, ever, under any circumstance. If `network-online.target` is not independently pulled into the transaction by *someone's* `Wants=`/`Requires=`, an `After=network-online.target` line with nothing else will simply be satisfied instantly (there being no unit to wait for in this transaction), and your service will start with no network guarantee at all. This is precisely why `network-online.target` is almost always seen paired: `Wants=network-online.target` \+ `After=network-online.target` together — `Wants=` ensures it's part of the transaction, `After=` ensures the ordering.

### 3.2 Default ordering when neither is specified

Two units with no `Before=`/`After=` relationship between them, directly or transitively, have **no defined relative order** — systemd is free to, and by default will, start them concurrently. This is not a fallback or a degenerate case; it is the entire mechanism by which systemd achieves parallel boot. Every ordering constraint you add is, in effect, a deliberate removal of parallelism, which is why unit authors are encouraged to add the *minimum* ordering necessary rather than defensively ordering everything relative to everything else — over-ordering is a real, common performance mistake, not merely a style preference.

### 3.3 Reload ordering: `PropagatesReloadTo=` interplay

Ordering directives govern start/stop transactions, but reload behavior (Section 5.3) travels along a *separate* declared edge, not along `Before=`/`After=`. A unit with no `PropagatesReloadTo=` declared will never have its `ExecReload=` triggered as a side effect of another unit's reload, no matter how tightly the two are ordered relative to each other at start time. This separation is deliberate — reload is meant to be a lightweight, narrowly-scoped operation, and conflating it with the full start/stop ordering graph would make reload transactions unpredictably expensive on large systems.

---

## 4. Implicit and Default Dependencies

Most of the dependency graph in a running system was never written by any unit-file author by hand — it's injected automatically by systemd itself, governed by the boolean `DefaultDependencies=` setting (default: `yes`) present on every unit.

With `DefaultDependencies=yes` (the default), systemd automatically adds, without anything in your `[Unit]` section requesting it:

- For most unit types: `After=sysinit.target` and `Requires=sysinit.target` — anchoring the unit to happen after early boot fundamentals (mounting filesystems, activating swap, loading kernel modules) are in place.
- `After=basic.target` for normal service units, anchoring them after the point at which sockets, timers, paths, and other low-level infrastructure units are available.
- An automatic `Conflicts=shutdown.target` and `Before=shutdown.target` — this is what guarantees that when the system is shutting down, every ordinary unit is stopped as part of that transaction, without every single service file needing to hand-write shutdown ordering.

Setting `DefaultDependencies=no` strips all of this out and is reserved for early-boot infrastructure units themselves (mount units for early filesystems, for instance) that would create ordering cycles if they waited on `sysinit.target`, given that `sysinit.target` itself depends on them being done first. You should essentially never set this to `no` in an application-level service unit — doing so removes the guarantee that your service is stopped cleanly during shutdown, among other implicit safety nets, and can leave processes running (and, worse, potentially writing to a filesystem) after systemd believes shutdown is complete.

### 4.1 Targets and the `.wants`/`.requires` symlink mechanism

`Target` units have their own layered implicit structure. `multi-user.target`, for example, doesn't just sit there — the units that are meant to run "in multi-user mode" declare `WantedBy=multi-user.target` in their own `[Install]` section, and it's the act of **enabling** them (Section 6) that creates the actual `Wants=` edge, as a symlink in `multi-user.target.wants/`, pointing back at each enabled unit. The target itself stays a clean, minimal file; the fan-out of "everything that should run" lives in the filesystem as a set of symlinks, one per enabled unit, which is also why `ls /etc/systemd/system/multi-user.target.wants/` is a fast, reliable way to see exactly what's wired into normal boot on a given machine, without needing to run any systemd tooling at all — it is directly inspectable with `ls`, `find`, or any configuration management tool.

### 4.2 Why implicit dependencies matter for debugging

A recurring source of confusion when troubleshooting (fully covered in `09-Troubleshooting.md`) is discovering an ordering relationship in `systemd-analyze dot` or `list-dependencies` output that does not correspond to anything written in the relevant unit file at all — it's an implicit edge from `DefaultDependencies=yes`, and understanding that this category of edge exists, and roughly what it contains, prevents a lot of "where did this dependency even come from" confusion when reading real graph output on a production system with dozens of interacting units.

---

## 5. Second-Order Directives

Beyond the core requirement/ordering pairs, several directives express relationships that don't fit neatly into either category.

### 5.1 `RequiresMountsFor=`

Given a filesystem path, systemd automatically computes which mount unit(s) that path depends on and adds the equivalent of `Requires=`+`After=` against each of them. This is more convenient and more correct than hand-deriving the mount unit's name yourself (mount unit names are the escaped form of the mount path, which becomes unwieldy for anything with special characters, and outright wrong if the path spans a mount you didn't know existed).

```ini
[Unit]
RequiresMountsFor=/srv/webapp/data
```

If `/srv/webapp/data` is a bind mount, a separate partition, or an NFS mount, this single line ensures the unit waits for whichever specific mount unit backs that path, without you needing to know or hardcode that unit's generated name. It also correctly handles the case where the path is backed by *multiple* nested mount points — systemd resolves the full chain automatically.

### 5.2 `OnFailure=` and `OnSuccess=`

Rather than describing what this unit depends on, these describe what should happen **as a consequence of this unit's own outcome** — a one-shot trigger, not a standing graph edge evaluated at start time.

```ini
[Unit]
OnFailure=alert-oncall.service
OnFailureJobMode=replace
```

When the unit this is attached to enters a `failed` state, systemd starts the listed unit(s) as a side effect. `OnFailureJobMode=` controls how that triggered job interacts with any existing transaction against the target — `replace` (the default) simply supersedes anything already queued; `fail` will refuse to trigger if it would conflict with an existing job, which matters if the alerting unit itself might already be mid-start for an unrelated reason. `09-Troubleshooting.md` covers building a minimal alerting unit around this directive, including passing the failed unit's name into the triggered unit via `%n`/`%i` specifiers.

### 5.3 `PropagatesReloadTo=` / `ReloadPropagatedFrom=`

Declares that reloading one unit (`systemctl reload`) should cause another to be reloaded as well. `ReloadPropagatedFrom=` is simply the same relationship declared from the receiving unit's perspective — equivalent, symmetric to `PropagatesReloadTo=` the same way `Before=`/`After=` are equivalent from opposite ends. As noted in Section 3.3, this is a genuinely separate edge type from ordering, and does not follow from any `Before=`/`After=`/`Requires=` relationship automatically existing between the two units.

### 5.4 `JoinsNamespaceOf=`

Specific to services using private namespacing directives (`PrivateTmp=`, `PrivateNetwork=`, covered fully in `08-Security-and-Hardening.md`). Declares that this unit should share the *same* private namespace as the listed unit, rather than each getting its own isolated one — used when two cooperating services need to see each other's private `/tmp` or private network namespace but nothing else on the system does. This also implicitly creates an ordering relationship, since the joining unit obviously needs the namespace-owning unit to have created that namespace first.

### 5.5 `Also=`

Purely an installation-time convenience, unrelated to runtime ordering. When you `systemctl enable` a unit that lists `Also=` in its `[Install]` section, the listed unit(s) are enabled or disabled alongside it automatically — commonly used to tie a `.socket` unit's enablement to its corresponding `.service`, so enabling one takes care of both, without an administrator needing to remember to run `enable` twice against two logically-paired units.

### 5.6 `StopWhenUnneeded=`

If set to `yes`, systemd will automatically stop this unit once nothing else in the graph currently depends on it anymore — turning it from an always-on unit into one that exists only as long as something needs it. Frequently paired with socket- or bus-activated units that should shut themselves down again once idle, closing the loop on the resource-efficiency argument made for activation mechanisms in `01-Introduction.md`: not only can a unit be started only when first needed, it can be stopped again once nothing needs it any longer, without any explicit timer or watchdog logic in the unit itself.

### 5.7 `RefuseManualStart=` / `RefuseManualStop=`

Prevents `systemctl start`/`stop` from being used directly against this unit by an administrator — the unit may only be started or stopped as a consequence of another unit's dependency graph. Used for units that only make sense as part of a larger orchestrated sequence and would leave the system in a broken state if triggered in isolation — a unit representing "phase two of a multi-phase migration" that must never be started ahead of "phase one" completing, for example.

### 5.8 `IgnoreOnIsolate=`

`systemctl isolate` (Section 8) stops every currently-active unit that is not part of the target being isolated to. Setting `IgnoreOnIsolate=yes` exempts a unit from that stop — useful for something that should keep running across an isolate transition regardless of which target you're switching to (an SSH session's own supporting units, for example, so that isolating to `rescue.target` doesn't sever your remote connection to perform the rescue work you presumably switched to rescue mode in order to do).

---

## 6. From `[Install]` to Actual Graph Edges

It's worth being explicit about a distinction glossed over in the introduction: the `[Unit]` section's dependency directives are **parsed every time the unit is loaded** and always active whenever the unit participates in a transaction. The `[Install]` section is entirely different — it is inert at runtime and only consulted by `systemctl enable`/`disable`, at which point it is translated into filesystem symlinks that *become* ordinary `Wants=`/`Requires=` edges from the target's perspective.

```ini
[Install]
WantedBy=multi-user.target
```

Running `systemctl enable webapp.service` against this unit creates:

```
/etc/systemd/system/multi-user.target.wants/webapp.service -> /etc/systemd/system/webapp.service
```

From that point forward, this symlink is functionally identical to `multi-user.target` having written `Wants=webapp.service` directly — systemd doesn't distinguish between a `Wants=` line inside a unit file and a `.wants/` symlink pointing at that unit; both produce the same graph edge. `RequiredBy=` works identically but produces a hard `Requires=` edge via a `.requires/` symlink instead, and is used far less often, for the same reason `Requires=` in general is used less often than `Wants=` — a failure of an auto-pulled dependency shouldn't usually be fatal to the target that pulled it in.

### 6.1 Why `[Install]` can't be "always on"

It's a reasonable question why `WantedBy=` requires an explicit `enable` step rather than simply always applying, the way `[Unit]`-section directives do. The answer is that `[Install]` directives express **administrator intent about autostart**, which is a decision distinct from the unit's own definition — the same unit file, shipped identically by a distribution package, needs to support "installed but not enabled" (present on disk, usable via manual `systemctl start`, but not wired into boot) as a genuinely different, common state from "enabled." Folding `WantedBy=` into unconditional `[Unit]`-section behavior would eliminate the ability to ship a unit without opinion about whether it autostarts.

---

## 7. Ordering Cycles: Detection and Resolution

Because ordering constraints form a graph, it is entirely possible for unit files — especially ones written independently by different package maintainers, or hand-edited drop-ins — to describe a **cycle**: A must start after B, B must start after C, C must start after A. Left unresolved, this has no valid execution order at all, since a topological sort is undefined on a graph containing a cycle.

systemd detects cycles during the transaction-building step, **before** starting anything, by attempting a topological sort of the relevant subgraph (conceptually similar to a depth-first search tracking the current recursion stack, flagging a cycle the moment a node is revisited while still "in progress"). When it finds one, it does not simply fail the entire boot — it applies a deterministic cycle-breaking heuristic: it identifies one edge in the cycle to discard (generally preferring to drop a `Wants=`-derived or otherwise weaker edge over a `Requires=`-derived one, and logging exactly which edge it removed), breaks the cycle at that point, and proceeds with the remainder of the graph intact.

You will see a log line resembling:

```
systemd[1]: Found ordering cycle on webapp.service/start
systemd[1]: Found dependency on cache.service/start
systemd[1]: Found dependency on webapp.service/start
systemd[1]: Job webapp.service/start deleted to break ordering cycle starting with webapp.service/start
```

This is not a message to ignore — a broken cycle means systemd silently discarded an ordering constraint you (or a package) wrote, and the unit that lost its edge may now start in an order you didn't intend, without any further warning at that point beyond this one log line at boot. The correct response is always to go fix the actual cyclical declaration, not to rely on systemd's heuristic resolving it the way you'd want every time — the specific edge chosen for deletion is a function of internal graph traversal order and is not something you should treat as a stable, predictable outcome across systemd versions.

### 7.1 A worked cycle example

Suppose three units, authored independently, each with a seemingly reasonable individual justification:

```ini
# a.service
[Unit]
After=b.service
```
```ini
# b.service
[Unit]
After=c.service
```
```ini
# c.service
[Unit]
After=a.service
```

Each single relationship reads as sensible in isolation — perhaps `c.service` was later modified to add `After=a.service` because someone noticed it occasionally raced with `a.service` and assumed ordering after it would help, without checking the existing chain. Combined, they form a strict cycle with no valid start order. Booting this system produces the cycle-break log sequence shown above, with systemd discarding one of the three edges (which one depends on internal graph traversal order and should not be relied upon as predictable) and proceeding — meaning the system boots "successfully" while silently running with an ordering guarantee the authors believed existed and does not.

### 7.2 Diagnosing a cycle before it happens

`systemd-analyze verify` parses a unit file (or the whole installed set) and reports structural problems, including potential ordering issues, without needing to actually boot:

```bash
systemd-analyze verify webapp.service
```

Running it with no arguments at all verifies every currently loaded unit and is a reasonable thing to run after any batch of unit-file changes, before reloading and restarting anything for real.

For a graphical view of the entire dependency graph — genuinely the fastest way to spot an unintended cycle by eye — `systemd-analyze dot` emits Graphviz DOT source:

```bash
systemd-analyze dot 'webapp.*' 'postgresql.*' | dot -Tsvg > deps.svg
```

Restricting the pattern (as above) is essential on any real system — running `systemd-analyze dot` with no filter against the full unit set of a typical server produces a graph with many hundreds of nodes and is unreadable; scoping to the units you actually care about, plus a wildcard for their immediate family, keeps the rendered graph legible. In the DOT output, `Before=`/`After=` edges are rendered as solid black arrows, while `Requires=`/`Wants=`-class edges are colored differently (green for `Requires=`, and so on), letting you visually separate "this is why the order is what it is" from "this is why this unit even exists in the transaction" at a glance.

---

## 8. `systemctl isolate` and Target Switching

`systemctl isolate <target>` is the direct mechanism by which `systemctl set-default`-style target switches actually happen at runtime: it starts the named target and everything it requires, and **stops every other currently active unit that is not, directly or transitively, a dependency of that target** (excluding units marked `IgnoreOnIsolate=yes`, per Section 5.8).

```bash
sudo systemctl isolate rescue.target
```

This is precisely how `rescue.target` manages to present a minimal, mostly-empty system state on demand: it isn't that `rescue.target` has some special "kill everything" flag — it's that the normal `multi-user.target`/`graphical.target` units are not in `rescue.target`'s dependency closure, and the generic isolate mechanism stops anything outside that closure as an ordinary consequence of the transaction. `Conflicts=` (Section 2.6) reinforces this for targets specifically, guaranteeing a clean mutual exclusion between runlevel-equivalent targets rather than relying solely on "not in the dependency set" to trigger a stop.

Only units marked `AllowIsolate=yes` (targets are, by default; most `.service` units are not) can be the destination of an `isolate` call — this exists specifically to prevent someone from accidentally "isolating" to an ordinary service unit and tearing down the rest of the system as a side effect of a typo, since the blast radius of an isolate transaction against the wrong unit is effectively "stop almost everything."

### 8.1 `isolate` versus `start`

It's worth contrasting explicitly: `systemctl start multi-user.target` on an already-booted `graphical.target` system will start whatever `multi-user.target` requires that isn't already running, but will **not** stop `graphical.target` or anything running under it — `start` only ever adds to the running set (plus, transitively, anything the newly-started units conflict with). `systemctl isolate multi-user.target` in the same situation *will* stop `graphical.target` and its dependents, because `isolate` additionally computes and executes the "stop everything outside the closure" half of the transaction that plain `start` never does. Conflating the two is a common and consequential mistake when scripting target transitions.

---

## 9. Reading `systemctl list-dependencies` Output

```bash
systemctl list-dependencies multi-user.target
```

produces an indented tree:

```
multi-user.target
● ├─sshd.service
● ├─rsyslog.service
● ├─cron.service
○ ├─bluetooth.target
● ├─basic.target
● │ ├─sysinit.target
● │ │ ├─dev-hugepages.mount
● │ │ ├─dev-mqueue.mount
● │ │ ├─kmod-static-nodes.service
● │ │ └─systemd-journald.socket
● │ ├─paths.target
● │ ├─slices.target
● │ ├─sockets.target
● │ └─timers.target
○ └─getty.target
```

Reading this correctly requires knowing what it is and is not showing:

- **This tree traverses `Wants=`/`Requires=`-class edges — not `Before=`/`After=` ordering.** It answers "what does this unit pull in," not "in what order do they start." Two sibling entries at the same indentation level tell you nothing about their relative start order — they may well start in parallel, and frequently do.
- **The bullet (`●`/`○`) indicates current active state**, not structural importance — a filled circle means the unit is currently active, a hollow one means it is not (commonly because it's conditionally excluded on this particular machine, like `bluetooth.target` on hardware with no Bluetooth adapter, via a `ConditionPathExists=`-style guard rather than because the dependency edge itself is absent).
- **By default the tree only expands `Requires=`/`Wants=` edges, one level of "does this unit itself have further dependencies" recursively** — pass `--all` to also include weaker/less common dependency types (`Requisite=`, `BindsTo=`, `PartOf=`) in the traversal, which by default are collapsed to keep the common-case tree readable.
- **`--reverse`** flips the direction entirely, answering "what depends on this unit" instead of "what does this unit depend on" — indispensable when you're trying to figure out why something you didn't expect got pulled into a boot:

```bash
systemctl list-dependencies --reverse network-online.target
```

- **`--plain`** disables the tree-drawing characters and nesting, useful when piping into another tool or when the box-drawing characters render badly in a particular terminal, or when you specifically want a flat list rather than a visual hierarchy for further text processing.

### 9.1 A reverse-lookup worked example

Suppose you're investigating why `network-online.target` — which does no work itself — is taking twelve seconds to be satisfied. `list-dependencies` in the forward direction against `network-online.target` will show you what it, in turn, depends on. But the more useful question is usually the reverse one: *who is actually waiting on it*, because that determines the real-world impact of its twelve seconds:

```bash
systemctl list-dependencies --reverse network-online.target
```

```
network-online.target
● ├─webapp.service
● ├─docker.service
● └─NetworkManager-wait-online.service
```

This confirms `webapp.service` and `docker.service` both genuinely block on this target, which is the concrete evidence you need before deciding whether twelve seconds here is an acceptable cost or a boot-time problem worth fixing — versus a scenario where `--reverse` shows nothing depends on it at all, in which case its twelve seconds, however large in isolation, has zero effect on your actual boot completion time.

---

## 10. `systemd-analyze`: The Boot and Graph Toolkit

Beyond `verify` and `dot` (Section 7.2), several more `systemd-analyze` subcommands are essential for reasoning about dependencies and boot timing in practice rather than in theory.

### 10.1 `systemd-analyze time`

The highest-level summary — total time spent in the kernel, initramfs, and userspace phases of boot:

```bash
systemd-analyze time
```

```
Startup finished in 3.912s (kernel) + 2.104s (initrd) + 18.662s (userspace) = 24.679s
graphical.target reached after 18.501s in userspace.
```

This is the number to watch before and after any change — everything else in this section exists to explain *why* this number is what it is.

### 10.2 `systemd-analyze blame`

Lists every unit that ran during boot, sorted by how long each one individually took to reach the "started" state:

```bash
systemd-analyze blame
```

```
33.417s systemd-udev-settle.service
12.203s NetworkManager-wait-online.service
 4.812s postgresql.service
 2.104s docker.service
 1.031s webapp.service
```

This tells you *which units are slow*, but critically **not** whether that slowness is actually on your boot's critical path — a slow unit that's running fully in parallel with everything else, with nothing waiting on it, doesn't delay boot completion at all, no matter how large its number here. `systemd-udev-settle.service` at the top of the list, in isolation, looks alarming; whether it actually matters depends entirely on whether anything with an `After=` on it is also on the critical path, which `blame` alone cannot tell you.

### 10.3 `systemd-analyze critical-chain`

This is the tool that answers the question `blame` cannot: what is the actual longest dependency chain that determined total boot time.

```bash
systemd-analyze critical-chain webapp.service
```

```
webapp.service +412ms
└─postgresql.service +2.1s
  └─network-online.target
    └─NetworkManager-wait-online.service +12.203s
      └─NetworkManager.service
        └─dbus.service
          └─basic.target
            └─sysinit.target
```

The `+Nms`/`+Ns` values represent time spent *after* the unit above it in the chain became active, before this unit itself finished — reading top to bottom, this is literally the sequence of "waited for this, which waited for this, which waited for this," and the sum of these deltas along this specific path is what actually gates when `webapp.service` was able to start. A unit can appear enormous in `blame` and never show up on the critical chain at all if nothing was actually blocked on it; conversely, a unit that took only a couple hundred milliseconds itself can dominate total boot time if it sits at the bottom of a long, serial ordering chain nothing could parallelize around. In the example above, `NetworkManager-wait-online.service`'s 12.2 seconds — not `postgresql.service`'s comparatively modest 2.1 — is the actual dominant cost on this specific critical path, even though both appear in `blame`'s output; fixing boot time here means addressing the network-wait step, not the database.

### 10.4 `systemd-analyze plot`

Renders an SVG timeline of every unit's start, showing overlaps (true parallelism) directly and visually, rather than requiring you to infer it from tree output:

```bash
systemd-analyze plot > boot.svg
```

Each unit is drawn as a horizontal bar spanning its actual wall-clock activation window; units running concurrently appear as overlapping bars at the same vertical time position, making genuine parallelism versus accidental serialization visually unambiguous in a way that neither `blame` nor `critical-chain`'s text output can convey as immediately.

### 10.5 `systemd-analyze dump`

Emits a large, exhaustive text dump of essentially everything systemd knows about every loaded unit and job — closer to a raw internal-state export than a human-curated report. Rarely the first tool reached for, but occasionally the only way to confirm a specific property's *actual* resolved value on a running system, as opposed to what's declared in the on-disk unit file (which may differ due to drop-ins, specifiers, or command-line overrides).

For diagnosing "why does boot take so long," the practical workflow is almost always: `time` for the top-line number, `critical-chain` to find the actual serial bottleneck path, `blame` to sanity-check which individual units are unusually slow in absolute terms, and `plot` to visually confirm where the real parallel/serial boundaries fall — in roughly that order, each tool narrowing the investigation the previous one opened.

---

## 11. Socket Activation and the Dependency Graph

`01-Introduction.md` introduced socket activation conceptually; here is how it specifically interacts with the requirement/ordering machinery covered above, because it changes the shape of the graph in a way that's easy to reason about incorrectly.

A `.socket` unit and its corresponding `.service` unit are, by convention (and by the `Also=` directive in the socket's `[Install]` section, Section 5.5), enabled together, but they are **separate nodes** in the dependency graph with an automatically-inserted relationship between them: the socket unit gets an implicit `Before=` on its service, and the service gets an implicit dependency ensuring the socket is available. Concretely, when something else in the graph declares `Requires=sshd.socket` (or the socket is simply started at boot because it's enabled), systemd binds the listening socket **immediately**, without waiting for `sshd.service` itself to start — the actual daemon process is deferred until first connection, or started eagerly in parallel with everything else, depending on configuration, but the *socket being bound and accepting connections* is not gated on the daemon's own startup time at all.

This means a unit that declares `After=sshd.socket` is guaranteed the socket is listening, but a unit that declares `After=sshd.service` is instead waiting on the *daemon process itself* having reached its own definition of "started" (Section-2/3-relevant `Type=` semantics, covered fully in `03-Service-Management.md`) — these are meaningfully different guarantees, and conflating them is a real source of subtle bugs when a unit actually only needed "something is listening on this port," which the socket unit alone already satisfies, and instead waited unnecessarily on full daemon initialization it didn't actually need.

```ini
[Unit]
# Only needs the socket to exist and be listening — does not
# need to wait for the daemon behind it to have finished its
# own internal startup sequence.
After=sshd.socket
```

### 11.1 A minimal socket-activated pair

To make the two-node structure concrete, here is a complete, minimal socket/service pair for a hypothetical on-demand echo service:

```ini
# /etc/systemd/system/echo.socket
[Unit]
Description=Echo service listening socket

[Socket]
ListenStream=127.0.0.1:9999
Accept=no

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/echo.service
[Unit]
Description=Echo service
Requires=echo.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/echo-server
```

Note that `echo.service` here deliberately has **no `[Install]` section at all** — it is never enabled directly, and nothing in `multi-user.target`'s closure pulls it in by name. It exists purely to be activated as a consequence of `echo.socket` receiving a connection. Enabling `echo.socket` (which, via boot, ends up wanting `sockets.target`) is sufficient for the whole pair to function: the socket binds at boot, sits idle consuming no CPU and no daemon process, and `systemd` starts `echo.service` — using the already-bound socket, handed to the new process via file-descriptor passing rather than the daemon binding the port itself — the moment a connection actually arrives. `systemctl status echo.service` will correctly show `inactive (dead)` for as long as the service has never been triggered, while `systemctl status echo.socket` shows `active (listening)` the entire time — two independently-inspectable states for what is, functionally, one logical service, which is precisely the separation of concerns Section 11's opening paragraph described in the abstract.

---

## 12. Slices and Resource-Control Edges

`.slice` units (`system.slice`, `user.slice`, `machine.slice`, and any custom slices you define) form their own, simpler layer of the same graph — every service is, by default, a member of `system.slice` unless explicitly assigned elsewhere via `Slice=`, and slice membership creates an implicit structural dependency: a service cannot be considered running independently of its slice existing, and stopping a slice — rare, but possible — stops everything within it, similar in spirit to `PartOf=` but built into the cgroup hierarchy itself rather than declared per-unit.

```ini
[Service]
Slice=webapp.slice
```

This assignment doesn't affect *startup ordering* the way the directives in Sections 2–3 do — slices aren't started "before" their members in any meaningful sequential sense, since a slice is essentially just a cgroup namespace node materializing on demand — but it does mean resource limits (`MemoryMax=`, `CPUQuota=`, fully covered in `08-Security-and-Hardening.md`) applied at the slice level apply hierarchically to every unit within it, and this containment relationship is visible in the same `systemd-cgls`/cgroup-tree tooling used to inspect ordinary process supervision in `01-Introduction.md`, Section 9.

---

## 13. A Fully Worked Multi-Service Example

To tie the directive reference to something concrete, consider a realistic three-tier stack: a web application, a PostgreSQL database it requires, and a Redis cache it merely wants (the app degrades gracefully, if slowly, without cache), all of which need the network, and the app additionally needs a specific data directory mounted.

```ini
# /etc/systemd/system/postgresql.service (simplified, distro-shipped in reality)
[Unit]
Description=PostgreSQL database server
After=network.target
Requires=postgresql-data.mount
After=postgresql-data.mount

[Service]
Type=notify
User=postgres
ExecStart=/usr/lib/postgresql/bin/postgres -D /var/lib/postgresql/data
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/cache.service
[Unit]
Description=Redis cache
After=network.target

[Service]
Type=notify
User=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/webapp.service
[Unit]
Description=Example web application
After=network-online.target postgresql.service cache.service
Wants=network-online.target cache.service
Requires=postgresql.service
RequiresMountsFor=/srv/webapp/uploads
OnFailure=alert-oncall.service

[Service]
Type=notify
User=webapp
ExecStart=/srv/webapp/bin/serve
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Walking the edges this produces:

- `webapp.service` **requires** `postgresql.service` — if the database fails to start, the app's start job fails too, and systemd will not proceed to launch it in a half-broken state.
- `webapp.service` only **wants** `cache.service` — a failed or absent Redis will not prevent the app from starting; it degrades rather than refuses to boot.
- `After=` on all three (`network-online.target`, `postgresql.service`, `cache.service`) guarantees ordering *in addition to* the requirement edges above — without these, `Requires=postgresql.service` alone would only guarantee the database was attempted, not that it went first.
- `RequiresMountsFor=/srv/webapp/uploads` adds an automatic requirement+ordering edge against whatever mount unit backs that specific path, without hardcoding its generated unit name.
- `postgresql.service` itself hard-requires and orders after its own data mount — meaning if that mount is missing, PostgreSQL refuses to start at all, which correctly cascades into `webapp.service`'s own start failing via the `Requires=postgresql.service` chain above, rather than the app coming up against a database running on an empty/wrong filesystem.
- `cache.service` has no dependency on `postgresql.service` and vice versa — with nothing ordering them relative to each other, systemd starts them **in parallel**, both proceeding concurrently as soon as `network.target` is reached, cutting real wall-clock boot time versus a hand-written script that would have run them one after another for no actual reason.
- `OnFailure=alert-oncall.service` fires only if `webapp.service` itself transitions to `failed` — it has no bearing on the startup graph above; it is a reactive trigger, not a dependency.

### 13.1 Failure scenario walkthrough

Now trace what happens concretely if `postgresql-data.mount` fails — say, the underlying disk is unavailable at boot.

1. `postgresql-data.mount` fails to activate. It has no ability to start; the mount job itself fails.
2. `postgresql.service` declared `Requires=postgresql-data.mount` — that requirement is now unmet, so `postgresql.service`'s own start job fails as a direct consequence, without systemd ever attempting to execute `ExecStart=` for it at all.
3. `webapp.service` declared `Requires=postgresql.service` — the same propagation happens one level up: `webapp.service`'s start job fails too, again without `ExecStart=` ever being invoked.
4. `cache.service`, having no dependency relationship to either of the above, is **unaffected** — it starts normally, on schedule, entirely independent of the database failure.
5. `webapp.service` transitions to `failed`, which triggers `OnFailure=alert-oncall.service` (Section 5.2) as a side effect — this is the mechanism that would actually notify someone the deployment is broken.

The corresponding `journalctl -b` output for this sequence looks approximately like:

```
systemd[1]: postgresql-data.mount: Mount process exited, code=exited status=32
systemd[1]: postgresql-data.mount: Failed with result 'exit-code'.
systemd[1]: Dependency failed for PostgreSQL database server.
systemd[1]: postgresql.service: Job postgresql.service/start failed with result 'dependency'.
systemd[1]: Dependency failed for Example web application.
systemd[1]: webapp.service: Job webapp.service/start failed with result 'dependency'.
systemd[1]: Starting alert-oncall.service...
```

Note the specific phrase `Job ... failed with result 'dependency'` — this is systemd's way of distinguishing "this unit's own `ExecStart=` ran and exited badly" (`result 'exit-code'`, as seen on the mount unit itself, the actual root cause) from "this unit never even got to run because something it required failed" (`result 'dependency'`, propagated up through the chain). `09-Troubleshooting.md` covers reading exactly this distinction as the first, fastest step in root-causing any multi-service failure — the *first* unit in the log sequence with `result 'exit-code'` (or `signal`, or `timeout`) rather than `result 'dependency'` is almost always the actual root cause, and everything logged after it in the same boot is downstream noise, not independent problems.

---

## 14. Common Anti-Patterns

**Ordering without requiring, when a requirement was actually intended.** Covered at length in Section 3.1 — always ask, for every `After=`, whether the corresponding `Wants=`/`Requires=` is also present, or whether its absence is a deliberate, considered choice.

**Requiring without ordering.** The mirror mistake: `Requires=postgresql.service` with no `After=postgresql.service` guarantees the database was *attempted* as part of the same transaction, but not that it goes first — under load, or after any change to relative startup timing, the two can and eventually will race.

**Blanket `Requires=` where `Wants=` was appropriate.** Over-using `Requires=` for soft/optional integrations creates a graph where a single non-critical unit failing (a metrics exporter, a log shipper) can cascade into failing your actual application's start job. Reserve `Requires=` for dependencies whose absence genuinely makes your unit meaningless to run at all.

**Confusing `Requires=` with an ongoing runtime guarantee.** As covered in the Section 2.2 gotcha, `Requires=` only governs the start-time transaction — it does not stop your unit if the dependency later crashes. If that ongoing coupling is what you actually want, use `BindsTo=` instead.

**Manually hardcoding a mount unit's escaped name instead of using `RequiresMountsFor=`.** Mount unit names are a mechanical escaping of the path (`/srv/webapp/uploads` becomes `srv-webapp-uploads.mount`), fragile to get right by hand and to keep in sync if the path ever changes; `RequiresMountsFor=` computes this correctly and automatically every time the unit is loaded.

**Setting `DefaultDependencies=no` outside of genuine early-boot infrastructure units.** As covered in Section 4, this opts an ordinary application unit out of the implicit shutdown-ordering safety net, among other things, for essentially no benefit at the application layer, and can leave processes running past the point systemd believes shutdown has completed.

**Assuming sibling entries in `list-dependencies` output start in a particular order.** As covered in Section 9, the tree reflects requirement edges, not start order — two sibling branches may be fully parallel, and reading a top-to-bottom sequence into that output is a reliable source of incorrect mental models about your own boot sequence.

**Ordering against a `.service` when only the corresponding `.socket` was actually needed.** As covered in Section 11, waiting on full daemon startup when you only needed "something is listening" costs real boot time for no benefit, and is a common oversight when a unit file is copy-adapted from one that genuinely did need the daemon itself to be initialized.

**Confusing `isolate` with `start`.** As covered in Section 8.1, only `isolate` tears down units outside the target closure — using `start` where `isolate` was intended silently leaves the previous target's units running alongside the new ones, which is rarely the desired outcome when the two are conflated in a script.

---

## 15. Dependencies on Templated (Instantiated) Units

Briefly, ahead of the full treatment in `04-Unit-Files.md`: template units (`getty@.service`, for example) use an `@` in their filename and are instantiated with a parameter, as in `getty@tty1.service`. Dependency directives referencing a template unit generally need to reference a **specific instance**, not the bare template — `After=getty@tty1.service`, not `After=getty@.service`, because the bare template with no instance argument is not itself a unit that can be started or waited on. The one significant exception is within the template file's own `[Unit]` section, where the specifier `%i` (the instance name) can be used to construct an instance-specific dependency dynamically, so that every instantiation of the template automatically depends on the correspondingly-named instance of some other template, without the template author needing to enumerate every possible instance in advance.

---

## 16. Historical Contrast: Why Event-Driven Ordering (Upstart) Was Abandoned

`01-Introduction.md` mentioned Upstart's event-driven model in passing; it's worth returning to now that the full graph mechanism has been laid out, because the contrast clarifies *why* systemd's declarative-graph approach specifically was chosen over the alternative that had actually shipped first.

Upstart jobs declared conditions like `start on (filesystem and net-device-up)` — the job began the moment the referenced *events* had all fired at least once, at some point, in any order, with no other job needing to have completed first in any structural sense. This is superficially similar to systemd's `Wants=`/`After=` pairing, but the crucial difference is that an Upstart job's start condition is evaluated against a **stream of events over time**, not a **static graph resolved before anything runs**. Two consequences followed directly:

- **No transaction-time validation.** systemd can detect an ordering cycle (Section 7) and every other structural graph problem *before starting a single process*, because the entire graph is known upfront. Upstart had no equivalent concept — a set of jobs with circular event dependencies simply never fired, and diagnosing why required reconstructing, after the fact, exactly which events had and hadn't occurred and in what order, rather than reading a single, static, pre-computed report.
- **Non-deterministic effective ordering under load.** Because event delivery timing itself could vary run to run (a slightly slower disk, a slightly different scheduling decision), the *effective* order jobs actually started in could vary between otherwise-identical boots, even though every individual job's stated conditions were unchanged. systemd's graph, by contrast, produces the same topological ordering constraints regardless of how fast any individual unit happens to start on a given boot — the *guarantees* are timing-independent even though wall-clock timing obviously still varies.

This is not a claim that event-driven models are unconditionally worse — they suit genuinely reactive, open-ended systems well — but for the specific problem of "deterministically bring a bounded set of known services up in a valid order, as fast as possible, with the ability to statically verify correctness before boot," the closed, pre-computable graph systemd uses is the better fit, and is the direct reason Ubuntu itself migrated from Upstart to systemd in 2015.

---

## 17. Quick-Reference Table

A single consolidated table of every directive covered in this document, for lookup once you already understand the underlying mechanics.

| Directive | Section | Class | Creates ordering? | Failure of target propagates? | Standing (post-start) coupling? |
|---|---|---|---|---|---|
| `Wants=` | 2.1 | Requirement | No | No | No |
| `Requires=` | 2.2 | Requirement | No | Yes, at start time only | No |
| `Requisite=` | 2.3 | Requirement | No | Yes, fails if not already active | No |
| `BindsTo=` | 2.4 | Requirement | No | Yes | Yes — stops if target stops later |
| `PartOf=` | 2.5 | Requirement | No | No (only stop/restart propagates) | Yes — restarts/stops in lockstep |
| `Conflicts=` | 2.6 | Requirement | No | N/A — mutual exclusion | Yes — starting one stops the other |
| `Before=` / `After=` | 3.1 | Ordering | Yes | N/A | No |
| `RequiresMountsFor=` | 5.1 | Requirement + ordering | Yes (implicit) | Yes | No |
| `OnFailure=` / `OnSuccess=` | 5.2 | Reactive trigger | No | N/A | No |
| `PropagatesReloadTo=` | 5.3 | Reload propagation | No | N/A | Yes, for reload only |
| `JoinsNamespaceOf=` | 5.4 | Namespace sharing | Yes (implicit) | N/A | Yes |
| `WantedBy=` / `RequiredBy=` | 6 | Install-time | No | Depends on resulting edge type | No |

---

## 18. Exercises

Working through the following against a real system, or purely on paper against the graph rules above, is a reasonable way to confirm this material has actually landed before moving on.

**1.** A unit declares only `After=redis.service`, with no `Wants=`/`Requires=` anywhere referencing it. `redis.service` is not enabled and nothing else pulls it in. Will `redis.service` be started as part of this unit's transaction? *(No — `After=` alone contributes no requirement edge; with nothing else pulling `redis.service` into the transaction, the ordering constraint is trivially satisfied and `redis.service` is never touched.)*

**2.** Two units, `A` and `B`, both declare `Requires=C`, and neither declares any ordering relative to the other. `C` fails to start. What happens to `A` and `B`? *(Both `A`'s and `B`'s start jobs fail, independently, each via its own `Requires=C` propagation — but `A` and `B` have no relationship to each other at all, so this is two separate failure propagations through `C`, not a failure propagating from `A` to `B` or vice versa.)*

**3.** A unit is `BindsTo=`'d to a `.device` unit representing a USB drive. The drive is running fine, then physically unplugged. What is the observable sequence of events? *(The `.device` unit is removed from the graph entirely, which — per `BindsTo=`'s Section 2.4 semantics — immediately triggers a stop job against the bound unit, without anything else needing to request it.)*

**4.** You add `After=cache.service` to `webapp.service`, but leave the existing `Wants=cache.service` in place, and `cache.service` is slow enough that it hasn't finished starting when `webapp.service`'s own `ExecStart=` would otherwise have been invoked. What actually happens? *(`webapp.service`'s start job waits until `cache.service`'s own job completes — successfully or not — before proceeding, because `After=` is now present; this is the fix for the "wants but doesn't order" gotcha described in Section 2.1.)*

**5.** You issue `systemctl start webapp.service`, and before it finishes, issue `systemctl stop webapp.service` from another terminal. What happens to the original start job? *(Per Section 1.3, the pending `start` job conflicts with the newly-requested `stop` job for the same unit; under default job-mode behavior the `stop` replaces the in-flight `start` — the unit proceeds toward being stopped rather than completing its startup, rather than the two requests being queued sequentially or the second being silently ignored.)*

**6.** A unit has `Wants=cache.service` and `After=cache.service`, but `cache.service` is masked (Section 10 of `01-Introduction.md`). What happens when the unit starts? *(A masked unit cannot be started by any means, including as a `Wants=` target — the attempt to start `cache.service` as part of the transaction fails silently from `Wants=`'s perspective, since `Wants=` failures never propagate; the ordering constraint in `After=` is trivially satisfied because there is nothing to actually wait for, and the dependent unit proceeds to start without the cache, exactly as if `cache.service` had failed for any other soft-dependency reason.)*

---

## 18a. Pre-Deployment Checklist

Before shipping a new or modified unit file with non-trivial dependencies, running through the following in order catches the overwhelming majority of the mistakes cataloged in Section 14, before they reach a production boot:

1. **Run `systemd-analyze verify` against the unit.** Catches syntax errors and a subset of structural problems immediately, with no risk to the running system.
2. **For every `After=`/`Before=` line, confirm a corresponding `Wants=`/`Requires=` exists — or confirm its absence is deliberate.** This is the single highest-value check given how common the Section 3.1 gotcha is in practice.
3. **For every `Requires=`, confirm a corresponding `After=` exists**, unless the lack of ordering is genuinely intentional (rare) — the Section 2.2 mirror-image gotcha.
4. **Run `systemctl list-dependencies --all <unit>` and read it against your own mental model of what should be pulled in.** Anything present that you didn't expect is worth tracing back to its source — often an implicit default dependency (Section 4) or a transitively-inherited edge from a dependency's own `[Unit]` section, not something wrong with your own file.
5. **If the unit participates in a chain more than two or three units deep, render it with `systemd-analyze dot` scoped to the relevant unit names**, and visually confirm there's no accidental cycle before it has a chance to be silently broken by systemd's own heuristic at actual boot time (Section 7).
6. **After deployment, check `systemd-analyze critical-chain` for the unit**, not just that it started successfully — a unit that works correctly but adds unnecessary seconds to every boot because of an overly conservative `After=` chain is a real, if less urgent, class of problem worth catching early rather than accumulating silently across many services over time.

---

## 19. Glossary

**Unit** — a loaded, static configuration object (`.service`, `.target`, etc.).
**Job** — a pending or in-progress operation (start/stop/reload/etc.) against a specific unit.
**Transaction** — the complete, validated set of jobs computed together in response to a single request.
**Edge** — a directed dependency or ordering relationship between two units in the graph.
**Closure** — the full set of units reachable from a given unit by following its requirement edges.
**Cycle** — a set of ordering edges that loop back on themselves with no valid start order.

---

## 20. What's Ahead

`03-Service-Management.md` picks up immediately where the worked example in Section 13 left off, going deep on exactly how systemd determines that `Type=notify` services in that example have actually finished starting (versus merely having been executed), the full set of `Restart=` policies and their interaction with the dependency graph on repeated failure, and how `ExecStartPre=`/`ExecStartPost=`/`ExecStop=`/`ExecStopPost=` fit into a service's lifecycle relative to the ordering guarantees established here.

---

## References

- `systemd.unit(5)` — the canonical directive reference this document expands on
- `systemd.special(7)` — documents the well-known target units and their implicit relationships
- `systemd-analyze(1)` — `verify`, `dot`, `blame`, `critical-chain`, `plot`, `time`, `dump` subcommands
- `systemctl(1)` — `list-dependencies`, `isolate` documentation
- `systemd.socket(5)` — socket-unit-specific ordering and activation semantics
