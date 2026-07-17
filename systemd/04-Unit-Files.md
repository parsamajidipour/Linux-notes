# Unit Files

A complete, mechanism-level reference for unit-file syntax and structure across every unit type — not just `.service`, which `03-Service-Management.md` covered in isolation. This document is the specifier reference (`%i`, `%n`, `%H`, and the rest), the full `systemd.exec(5)` execution-context directive set, the templated/instantiated-unit mechanism in complete detail, the drop-in override system, the `[Unit]`/`[Install]` sections comprehensively, and a tour of the non-service unit types — `.mount`, `.automount`, `.swap`, `.path`, `.device` — that `01-Introduction.md` only named in passing.

Everything in `02-Units-and-Dependencies.md` and `03-Service-Management.md` assumed you already knew how to read a unit file's basic shape. This document is where that assumption is finally cashed out in full — every directive class, every escaping rule, every place a template's `%i` can and cannot be used.

---

## 1. Specifiers: The Complete Reference

A **specifier** is a `%`-prefixed, two-character sequence that systemd expands at unit-load time, before any directive value is used — distinct from a shell variable (which is expanded by the shell, if any, at execution time) and distinct from an environment variable (resolved by the launched process itself). Specifiers are systemd's own, narrower substitution mechanism, usable inside unit file directive values directly.

| Specifier | Expands to |
|---|---|
| `%n` | The full unit name, including its type suffix (`webapp.service`) |
| `%N` | The unit name with the type suffix stripped (`webapp`) |
| `%p` | The "prefix" — for a template instance, the part before the `@` |
| `%i` | The instance name of a template unit, unescaped (raw form) |
| `%I` | The instance name of a template unit, with escaping *undone* — see Section 2.2 |
| `%f` | The unescaped instance name, prefixed with `/`, treating the instance as a path |
| `%h` | The home directory of the user the unit runs as |
| `%H` | The system's hostname |
| `%u` | The username the unit runs as |
| `%U` | The numeric UID the unit runs as |
| `%t` | The runtime directory (`/run`, or `$XDG_RUNTIME_DIR` for a user-instance unit) |
| `%S` | The state directory root (`/var/lib`, or the user equivalent) |
| `%C` | The cache directory root (`/var/cache`, or the user equivalent) |
| `%L` | The log directory root (`/var/log`, or the user equivalent) |
| `%E` | The configuration directory root (`/etc`, or the user equivalent) |
| `%T` | The temporary directory (`/tmp`, or a private one if `PrivateTmp=` is set) |
| `%V` | The volatile temporary directory (`/var/tmp` equivalent) |
| `%m` | The machine ID (from `/etc/machine-id`) |
| `%b` | The boot ID of the current boot |
| `%%` | A literal `%` character |

### 1.1 Why specifiers exist rather than shell expansion

It would be tempting to assume `ExecStart=/usr/bin/tool --host=$HOSTNAME` works the way it would in a shell script — it does not, because `ExecStart=` and similar `Exec*=` directives are **not** passed through a shell at all by default (Section 9 covers exactly what does and doesn't get shell treatment). systemd parses the command line itself, word-splitting on whitespace with its own quoting rules (Section 8), and no shell ever sees the string. Specifiers exist precisely to provide *some* dynamic substitution capability in that shell-less context — `%H` for the hostname, `%h` for a home directory — without requiring every unit that needs this kind of value to wrap its `ExecStart=` in an explicit `/bin/sh -c '...'` invocation merely to get variable expansion.

### 1.2 A worked example combining several specifiers

```ini
[Service]
ExecStart=/usr/local/bin/backup.sh --host=%H --state-dir=%S/%N --log=%L/%N.log
```

For a unit named `backup.service` running as root on a host named `db-primary`, this resolves at load time to:

```
/usr/local/bin/backup.sh --host=db-primary --state-dir=/var/lib/backup --log=/var/log/backup.log
```

Note this resolution happens **once, when the unit is loaded** — not on every invocation of `ExecStart=` were it (hypothetically) re-evaluated per restart. If the hostname changes while the system is running, a currently-loaded unit's already-resolved `ExecStart=` string does not change; only a subsequent `daemon-reload` (which re-parses and re-resolves every unit file) would pick up the new value.

### 1.3 Availability by unit type

Not every specifier is meaningful for every unit type. `%i`/`%I`/`%p`/`%f` are only meaningful for **instantiated** units (Section 2) — used in a non-template unit, they expand to nothing (an empty string), which is a genuinely common source of confusion when a directive silently loses a piece of its expected value because the unit turned out not to actually be a template instance the way its author assumed. `%h`/`%u`/`%U` depend on `User=` being set at all; on a unit with no `User=` directive (running as root, the implicit default), they resolve to root's own home directory, username, and UID respectively — not an error, but occasionally a source of surprise when a directory path built from `%h` unexpectedly points at `/root` rather than a nonexistent, more specific user's home.

---

## 2. Templated (Instantiated) Units in Full

`02-Units-and-Dependencies.md` Section 15 and `03-Service-Management.md` Section 9.1 both previewed this mechanism from their own angles. This section is the complete, standalone treatment.

### 2.1 Template vs. instance vs. bare template

A **template unit** is a file whose name contains a literal `@` immediately before the type suffix, with nothing between the `@` and the suffix — `worker@.service`, `getty@.service`. This file, on its own, is not directly startable; think of it as a class definition rather than an object. An **instance** is created by inserting a specific string between the `@` and the suffix at the moment you reference the unit — `worker@emails.service`, `getty@tty1.service` — and it is *this* fully-qualified name that actually gets started, stopped, enabled, and tracked as its own independent unit, per `03-Service-Management.md` Section 9.1's isolation guarantee.

Critically, **the instance string is arbitrary at the point of use** — nothing in `worker@.service` itself enumerates which instances are valid; `systemctl start worker@anything-you-type.service` will load the template, substitute `anything-you-type` wherever `%i` appears, and attempt to start it, succeeding or failing based on whether that particular instance name makes sense to whatever the `ExecStart=` command actually does with it. This open-endedness is a deliberate design choice — it's what allows `systemd-run`-style dynamic instance creation and configuration-driven scaling (spinning up a new queue worker by simply choosing a new instance name, with no unit-file change required) — but it also means there is no built-in validation preventing `systemctl start worker@does-not-exist.service` from being attempted; any rejection of an invalid instance name has to come from the launched command itself failing meaningfully.

### 2.2 `%i` versus `%I`: the escaping distinction

Instance names frequently need to represent values — file paths, in particular — that contain characters (`/`) not valid in a unit filename. systemd handles this with a systematic **escaping** transformation: a `/` becomes `-` in the instance portion of a unit name, and other special characters are escaped using a `\xHH`-style hexadecimal encoding, the same general scheme used for the mount-unit auto-naming mentioned in `02-Units-and-Dependencies.md` Section 5.1.

```
systemd-escape --path /srv/webapp/uploads
# outputs: srv-webapp-uploads
```

Given a unit `backup@.service` started as `backup@srv-webapp-uploads.service`:

- **`%i`** expands to the raw, still-escaped instance string: `srv-webapp-uploads`.
- **`%I`** expands to the *unescaped*, original form: `/srv/webapp/uploads`.

```ini
[Service]
ExecStart=/usr/local/bin/backup.sh --source=%I
```

Using `%i` here by mistake would pass the literal, useless string `srv-webapp-uploads` to `--source=`, rather than the actual path `/srv/webapp/uploads` the unit's author intended — a subtle, easy-to-make error precisely because `%i` and `%I` differ by a single letter's capitalization and, for instance names that happen not to contain any characters needing escaping in the first place, behave identically, making the bug invisible until an instance name that actually requires escaping is used for the first time, often well after the template was written and believed tested.

`systemd-escape` (and its inverse, `systemd-escape --unescape`) is the command-line tool implementing this exact transformation, worth reaching for directly when constructing instance names in scripts or automation rather than hand-deriving the escaped form, for the same reliability reason `RequiresMountsFor=` (`02-Units-and-Dependencies.md` Section 5.1) is preferred over hand-deriving a mount unit's name.

### 2.3 `%p` versus `%N` on an instance

For an instantiated unit `worker@emails.service`, `%p` expands to `worker` (the template's own prefix, before the `@`), while `%N` expands to the full, specific instance name including its instance portion, `worker@emails` (suffix stripped, per Section 1's table) — these answer different questions ("what template is this an instance of" versus "what specific unit is this"), and conflating them is a real, if less common, source of the same class of bug as the `%i`/`%I` confusion above.

### 2.4 `DefaultInstance=`

Placed in a template's `[Install]` section, `DefaultInstance=` provides the instance name used when the *bare template itself* is enabled without an explicit instance being specified — `systemctl enable worker@.service` (note: no instance in this specific invocation) uses `DefaultInstance=`'s value to determine what gets actually wired into the target's `.wants/` directory.

```ini
[Install]
WantedBy=multi-user.target
DefaultInstance=default
```

This is a narrow convenience for templates that have one obviously "primary" instance alongside potentially several secondary ones — `getty@.service`'s own distribution-shipped configuration is the canonical real-world example, defaulting to `tty1` so that `systemctl enable getty@.service` unambiguously wires up the primary console login prompt without the administrator needing to specify `getty@tty1.service` explicitly for the common case, while `getty@tty2.service` and further instances remain available to be enabled individually and explicitly by name for additional virtual consoles.

### 2.5 Per-instance configuration via drop-ins

Section 3 covers the general drop-in mechanism, but it's worth flagging here specifically: a drop-in directory can target either the **bare template** (`worker@.d/override.conf`, applying to every instance) or a **specific instance** (`worker@emails.d/override.conf`, applying only to that one) — giving you a genuine two-level configuration hierarchy, template-wide defaults overridable per instance, without duplicating the entire unit file for each instance that needs one directive tweaked.

### 2.6 Instances and the Dependency Graph

Every dependency directive from `02-Units-and-Dependencies.md` applies to a template instance exactly as it would to any ordinary unit — `worker@emails.service` can be the target of another unit's `Requires=`, can itself declare `After=redis.service`, and participates in ordering-cycle detection identically. What's worth stating explicitly, because it's easy to assume otherwise, is that **a dependency directive naming a bare template, with no instance, does not resolve to "any instance" or "all instances"** — `Requires=worker@.service` is not valid the way `Requires=worker@emails.service` is, because, per Section 2.1, the bare template is not itself a startable unit at all, merely a pattern one is instantiated from. A unit that needs to depend on *every currently-enabled* instance of a template has no single directive that expresses this directly; the closest native mechanism is enabling each needed instance individually against a shared target (`WantedBy=worker-pool.target` on the template, with `worker-pool.target` itself declared `After=`/`Wants=`'d by whatever needs to wait on the pool as a whole), rather than any single wildcard-style dependency edge against the template name itself.

This also means `%i`/`%I` specifier resolution (Section 2.2) happens **per instance, independently** — a `Requires=` line in the template that itself references another templated unit using `%i` (`Requires=cache@%i.service` inside `worker@.service`, for instance, wiring each worker instance to a correspondingly-named cache instance) produces a genuinely different, instance-specific graph edge for each instantiation: `worker@emails.service` requires `cache@emails.service`, `worker@thumbnails.service` requires `cache@thumbnails.service`, and so on, each pair independent of the others despite originating from the identical template source line — a useful pattern for keeping a set of parallel per-instance resource pairs correctly wired without hand-writing a separate unit file for each.

---

## 3. The Drop-In Override Mechanism in Full

`01-Introduction.md` Section 6 introduced `systemctl edit` and drop-in directories briefly, as a way to override a distribution-shipped unit without editing the packaged file directly. This section is the complete mechanical treatment.

### 3.1 The directory convention

For any unit `foo.service`, systemd looks for a directory named `foo.service.d/` alongside the unit's own search paths (`/etc/systemd/system/foo.service.d/`, `/run/systemd/system/foo.service.d/`, and so on, following the same precedence tiers as `02-Units-and-Dependencies.md` Section 6's discussion of unit file locations). Every `.conf` file inside that directory is parsed and merged **on top of** the base unit file, in filename-sort order — meaning `10-timeouts.conf` is applied before `20-restart-policy.conf`, a convention (numeric prefixes) worth adopting deliberately once a unit accumulates more than one drop-in, so the merge order is self-documenting from the directory listing alone.

### 3.2 Merge semantics: append versus override

This is the single most important mechanical detail, and it differs by directive type:

- **List-like directives** (`Wants=`, `After=`, `Environment=`, and most others that can sensibly appear multiple times) **append** — a drop-in's `Wants=extra.service` adds to, rather than replaces, whatever `Wants=` lines the base unit file already specified.
- **Single-value directives** (`Type=`, `Restart=`, `ExecStart=` in most `Type=` values that only permit one) **override** — a drop-in's `Restart=always` fully replaces the base file's `Restart=on-failure`, not merges with it in any sense.

```ini
# /etc/systemd/system/webapp.service.d/override.conf
[Service]
Restart=always
Environment=EXTRA_FLAG=1
```

Given a base `webapp.service` with `Restart=on-failure` and `Environment=LOG_LEVEL=info`, the merged, effective configuration has `Restart=always` (overridden) and **both** `Environment=LOG_LEVEL=info` and `Environment=EXTRA_FLAG=1` in effect simultaneously (appended) — a detail easy to get backwards if you assume all directives behave uniformly one way or the other.

### 3.3 Explicitly clearing a directive

Because list-like directives append by default, there needs to be a way to actually **remove** an inherited value rather than only ever adding to it — this is done with an empty assignment, which systemd treats as a reset instruction wiping every prior value of that specific directive accumulated so far, before any further lines re-populate it.

```ini
# /etc/systemd/system/webapp.service.d/override.conf
[Service]
ExecStart=
ExecStart=/srv/webapp/bin/serve --new-flag
```

The bare `ExecStart=` on its own line clears whatever `ExecStart=` the base unit file (and any earlier-sorted drop-in) had already specified; the following line then supplies an entirely new value. Omitting the clearing line and simply writing a new `ExecStart=` would, for most `Type=` values that only accept a single `ExecStart=`, actually produce a configuration error (`Type=simple`/`notify`/`exec`/`forking`/`dbus`/`idle` do not accept more than one `ExecStart=` — only `Type=oneshot` does, per `03-Service-Management.md` Section 2.3) rather than silently overriding, making the explicit-clear idiom effectively mandatory when a drop-in needs to change `ExecStart=` for any non-`oneshot` service.

### 3.4 `systemctl edit` mechanics

```bash
systemctl edit webapp.service
```

opens `$EDITOR` on a fresh (or existing) file at the drop-in path described in Section 3.1, and — critically — runs `systemctl daemon-reload` automatically once the editor exits successfully, so the change takes effect without a separate manual step. `systemctl edit --full webapp.service` instead opens a complete, standalone copy of the unit (seeded from the currently-effective, merged configuration) directly in `/etc/systemd/system/`, fully shadowing the original per the precedence rules in `02-Units-and-Dependencies.md` Section 6, rather than layering a drop-in on top of it — appropriate when the change is substantial enough that thinking in terms of "the whole unit, as I want it" is clearer than "specific overrides layered on someone else's base."

`systemctl edit --stdin webapp.service` (recent systemd versions) accepts the drop-in content piped directly via standard input, useful for scripted/automated drop-in creation without needing an interactive editor session at all.

### 3.5 Reverting

```bash
systemctl revert webapp.service
```

Removes every administrator-created drop-in and any `--full` override for the named unit, restoring the distribution-packaged version exactly, followed by an automatic `daemon-reload` — the clean undo for both mechanisms in Section 3.4, without needing to manually track down and delete the relevant files under `/etc/systemd/system/` yourself.

---

## 4. `systemd.exec(5)`: The Complete Execution Context Reference

`03-Service-Management.md` Section 12 introduced `Environment=`/`EnvironmentFile=`/`User=`/`Group=`/`WorkingDirectory=` briefly. This is the full reference — these directives are shared across every unit type that launches a process (`.service`, `.socket`'s `ExecStartPre=`, `.mount`, and others), which is why they live in their own manual page, `systemd.exec(5)`, separate from `systemd.service(5)`.

### 4.1 Identity

```ini
[Service]
User=webapp
Group=webapp
SupplementaryGroups=docker
```

`User=`/`Group=` set the Unix identity the process runs as — accepting either a name or a numeric ID. `SupplementaryGroups=` adds additional group memberships beyond the primary `Group=`, useful when a service needs access governed by a secondary group (membership in `docker`'s group to access its socket, for instance) without that group becoming its primary one.

```ini
[Service]
DynamicUser=yes
```

`DynamicUser=yes` has systemd allocate a **transient, unique UID/GID** for the unit's entire lifetime, created at start and removed at stop — no static entry in `/etc/passwd` at all. This is a genuinely strong isolation improvement for services with no legitimate need for a persistent, named system account: since the UID doesn't persist across the service's own lifetime, any file left behind with that ownership after the service stops becomes orphaned and inaccessible to anything running under a *different* dynamically-allocated UID the next time the service starts, meaningfully limiting the blast radius of a compromised process trying to leave a persistent foothold via file ownership. `08-Security-and-Hardening.md` covers this alongside the broader sandboxing directive set it's typically deployed together with.

### 4.2 Filesystem Context

```ini
[Service]
WorkingDirectory=/srv/webapp
UMask=0027
```

`WorkingDirectory=` sets the process's current working directory at launch — relevant for any code that opens files using relative paths. `UMask=` sets the file-creation mask, governing default permissions on any file the process creates — `0027` here means group has no write and others have no access at all by default, a common hardening baseline tighter than the historical Unix default of `0022`.

`RootDirectory=`/`RootImage=` (a directory to `chroot()` into, or a disk image to mount as root, respectively) and the `ReadOnlyPaths=`/`ReadWritePaths=`/`InaccessiblePaths=`/`ProtectSystem=`/`ProtectHome=` family of namespace-based restrictions are functionally filesystem-context directives too, but `08-Security-and-Hardening.md` is where they receive full treatment, since their primary purpose is sandboxing rather than routine execution configuration — they're mentioned here only so their category is placed correctly relative to the directives this document does cover in depth.

### 4.3 Environment, Complete

```ini
[Service]
Environment=LOG_LEVEL=info CACHE_TTL=300
Environment="QUOTED_VALUE=has a space"
EnvironmentFile=/etc/webapp/base.env
EnvironmentFile=-/etc/webapp/optional-overrides.env
PassEnvironment=HTTP_PROXY
UnsetEnvironment=TERM
```

`Environment=` accepts multiple `KEY=VALUE` pairs on one line, space-separated, with quoting (Section 8) required for any value that itself contains whitespace. Multiple `Environment=` lines accumulate, per Section 3.2's append rule. `EnvironmentFile=` — as covered in `03-Service-Management.md` Section 11 — loads external `KEY=VALUE` files; prefixing the path with `-` (as in the second example above) makes a *missing* file non-fatal, allowing an optional, environment-specific overrides file that may or may not exist on any given deployment target without that absence itself causing a start failure.

`PassEnvironment=` is a distinct, less commonly needed mechanism: it takes a variable from **systemd's own environment** (PID 1's environment, which is largely the environment the kernel/initramfs handed it at boot, not generally rich) and passes it through to the launched process — relevant mainly in narrow cases where something genuinely needs to inherit from the init process's own environment rather than having a value explicitly set via `Environment=`/`EnvironmentFile=`. `UnsetEnvironment=` does the reverse — explicitly removing a variable that would otherwise be inherited or set, useful for stripping something a parent context sets that the launched process should specifically not see.

### 4.4 Scheduling and Priority

```ini
[Service]
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=4
CPUSchedulingPolicy=other
CPUAffinity=0-3
```

`Nice=` sets the traditional Unix scheduling niceness (-20 highest priority to 19 lowest), directly analogous to the `nice` command. `IOSchedulingClass=`/`IOSchedulingPriority=` do the same for I/O scheduling priority specifically, relevant for services whose disk I/O should yield to more latency-sensitive work sharing the same storage. `CPUSchedulingPolicy=` selects among the kernel's scheduling policies (`other` — the default, standard time-sharing; `batch`; the real-time `fifo`/`rr` policies, which require corresponding `CPUSchedulingPriority=` and carry real risk of starving other processes if misused, appropriate only for genuinely latency-critical workloads that have been deliberately designed with real-time scheduling in mind). `CPUAffinity=` pins the process to a specific set of CPU cores, occasionally useful for NUMA-sensitive workloads or deliberately isolating a noisy-neighbor service to cores other applications don't share.

### 4.5 Resource Limits (`Limit*=`)

systemd exposes the traditional Unix `rlimit` mechanism (the same family `ulimit` configures interactively in a shell) as unit-file directives, applied at process launch rather than requiring a wrapper script:

| Directive | Corresponds to (`ulimit` flag) |
|---|---|
| `LimitCPU=` | `-t`, CPU time |
| `LimitFSIZE=` | `-f`, file size |
| `LimitDATA=` | `-d`, data segment size |
| `LimitSTACK=` | `-s`, stack size |
| `LimitCORE=` | `-c`, core dump size |
| `LimitNOFILE=` | `-n`, open file descriptors |
| `LimitNPROC=` | `-u`, number of processes |
| `LimitMEMLOCK=` | `-l`, locked memory |
| `LimitAS=` | `-v`, virtual address space |

```ini
[Service]
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
```

`LimitNOFILE=` is the one most commonly adjusted in practice — the default open-file-descriptor limit on many distributions is too low for a busy network service handling many concurrent connections, each typically consuming one file descriptor, and raising it here is the standard, correct fix, applied cleanly at the unit level rather than requiring a `/etc/security/limits.conf` entry that only takes effect for interactively-launched (PAM-mediated) sessions and would not apply to a systemd-launched daemon at all. `LimitCORE=0` is a common hardening choice, disabling core dump generation entirely for a service where a crash dump could contain sensitive in-memory data (credentials, user content) that shouldn't be persisted to disk as a side effect of a crash.

**Note on precedence with resource-control (`slice`-level) directives** covered in `02-Units-and-Dependencies.md` Section 12: `Limit*=` directives are the traditional per-process rlimit mechanism, while `MemoryMax=`/`CPUQuota=`/etc. (fully treated in `08-Security-and-Hardening.md`) are the newer, cgroup-based resource-control mechanism — the two systems coexist, are enforced independently, and are not interchangeable; a process can be well within its `LimitAS=` virtual-memory rlimit while still being killed by a cgroup-level `MemoryMax=` breach, because the kernel enforces each via an entirely separate mechanism.

### 4.6 Standard I/O and Logging

```ini
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=webapp
SyslogFacility=daemon
SyslogLevelPrefix=yes
```

`StandardOutput=`/`StandardError=` control where a process's stdout/stderr streams are routed — `journal` (the default for most services, feeding directly into `journald`, the mechanism underlying every `journalctl -u` example throughout this series), `null` (discarded), `inherit` (from the unit's own configured input), `tty` (a specific terminal device, via an accompanying `TTYPath=`), `socket` (relevant specifically for socket-activated units, piping output back through the activating connection), or `file:/path/to/file` (a plain file, bypassing the journal's structured storage entirely — rarely preferable to the default given the indexing and metadata `journald` provides, per `06-journald-and-Logging.md`, but occasionally required for compatibility with an external log-processing pipeline that specifically expects a flat file).

`SyslogIdentifier=` sets the tag under which the unit's output appears (relevant when a process's own default identifier, typically its binary name, isn't the label you'd want appearing in log queries), and `SyslogFacility=`/`SyslogLevelPrefix=` govern classic syslog-compatibility metadata attached to journal entries, relevant primarily when forwarding to a traditional syslog daemon alongside or instead of using the journal natively.

### 4.7 Managed Directories: `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=`

A recurring, historically awkward problem: a service needs a dedicated directory under `/run`, `/var/lib`, `/var/cache`, or `/var/log` to exist, owned by the correct user, before it starts — traditionally solved with an `ExecStartPre=mkdir -p ...` line (as in several examples earlier in this series) or an entirely separate `tmpfiles.d` configuration file. systemd provides a dedicated, more precise mechanism for exactly this:

```ini
[Service]
User=webapp
RuntimeDirectory=webapp
StateDirectory=webapp
CacheDirectory=webapp
LogsDirectory=webapp
```

Each of these directives has systemd itself create the corresponding subdirectory (`/run/webapp`, `/var/lib/webapp`, `/var/cache/webapp`, `/var/log/webapp` respectively) immediately before `ExecStart=` runs, owned by whatever `User=`/`Group=` the unit specifies, with permissions systemd manages directly rather than relying on the launched process's own `umask` and a separate `mkdir` step getting the ownership right. `RuntimeDirectory=`'s contents are additionally cleaned up automatically when the service stops (mirroring `/run`'s own tmpfs-backed, boot-scoped lifetime), while `StateDirectory=`/`CacheDirectory=`/`LogsDirectory=` persist across restarts and reboots, matching the different lifetime semantics their respective parent directories already imply.

This is meaningfully more precise than the `ExecStartPre=mkdir -p` idiom used in earlier worked examples in this series specifically because it ties the directory's existence to the *unit's own declared identity* rather than a separately-authored shell command that has to be kept in sync by hand — a rename of the service, or a change to `User=`, doesn't require remembering to also update a separate `mkdir`/`chown` invocation, since the directory name and ownership are derived from the same `RuntimeDirectory=webapp`/`User=webapp` declaration already present. For any new unit going forward, these directives are the preferred idiom over the `ExecStartPre=`-based directory-creation pattern used illustratively in `02-Units-and-Dependencies.md` and `03-Service-Management.md`'s worked examples — those examples predate this section deliberately, to first establish `ExecStartPre=` on its own terms, before introducing the more specialized, purpose-built alternative here.

### 4.8 `OOMScoreAdjust=`

Adjusts how aggressively the Linux kernel's out-of-memory killer targets this specific process relative to others, on the traditional `-1000` (never kill) to `1000` (kill first) scale.

```ini
[Service]
OOMScoreAdjust=-500
```

A negative value here for a genuinely critical service (a database, relative to a disposable batch worker sharing the same machine) expresses a considered priority the kernel's OOM killer will respect under real memory pressure, rather than the kernel choosing among competing processes with no information about which one the administrator would actually prefer sacrificed first. This is a coarser, kernel-level counterpart to `systemd-oomd` (`01-Introduction.md` Section 3's table), which additionally makes cgroup-aware decisions using systemd's own accounting rather than relying purely on the kernel's traditional, per-process heuristic.

### 4.9 A Preview of Namespacing: `PrivateTmp=`

One further execution-context directive is worth introducing here, ahead of its full treatment alongside the rest of the sandboxing directive family in `08-Security-and-Hardening.md`, because it directly explains a term used without definition in `02-Units-and-Dependencies.md` Section 5.4's `JoinsNamespaceOf=` discussion.

```ini
[Service]
PrivateTmp=yes
```

With this set, the process sees its own, isolated `/tmp` and `/var/tmp` — a private mount namespace containing directories no other unit (and no interactively-logged-in user) can see or write to, despite the process itself still simply opening paths under `/tmp/whatever` as if it were the ordinary, shared directory. This closes off an entire class of local, `/tmp`-based information disclosure or symlink-attack vulnerability, at the cost of exactly the coordination problem `JoinsNamespaceOf=` exists to solve: two units that legitimately *do* need to share a `/tmp` (a primary daemon and a sidecar that inspects temp files the daemon produces) must explicitly opt one into the other's namespace via `JoinsNamespaceOf=`, since `PrivateTmp=yes` on both, independently, would otherwise give each its own separate, mutually invisible private `/tmp`, breaking the coordination silently rather than loudly. `08-Security-and-Hardening.md` covers the full namespacing family this belongs to — `PrivateDevices=`, `PrivateNetwork=`, `ProtectHome=`, and the rest — in complete depth; it's introduced here only far enough to make the earlier `JoinsNamespaceOf=` reference concrete rather than abstract.

---

## 5. `[Unit]` Section, Complete

`02-Units-and-Dependencies.md` covered the dependency and ordering directives of `[Unit]` in exhaustive detail. The remaining, non-dependency directives:

```ini
[Unit]
Description=Example web application
Documentation=https://example.com/docs man:webapp(8)
SourcePath=/etc/legacy-webapp.conf
```

`Description=` is the single-line, human-readable summary shown throughout `systemctl status`/`list-units` output — worth writing genuinely descriptively rather than merely restating the unit's own filename, since it's the text an operator scanning `systemctl list-units` under incident pressure actually reads. `Documentation=` accepts one or more space-separated URIs (web URLs, or `man:`/`info:`-scheme references to local manual pages) surfaced in `systemctl status` output, giving a direct path from "this service is failing" to "here is where its documentation lives" without the operator needing to already know where to look. `SourcePath=` is largely informational/generator-related, recording where a dynamically-generated unit (Section 7's `.mount` generator being one source of these) was originally derived from, for traceability.

The `Condition*=`/`Assert*=` family, introduced in `03-Service-Management.md` Section 11 in the context of services, is in fact a `[Unit]`-section mechanism available to **every** unit type, not services specifically — a `.mount` unit can just as validly carry a `ConditionPathExists=` guard as a `.service` can, and the silent-skip-versus-loud-failure distinction established there applies identically regardless of unit type.

---

## 6. `[Install]` Section, Complete

`02-Units-and-Dependencies.md` Section 6 covered `WantedBy=`/`RequiredBy=` and the resulting symlink mechanism. The remaining directives:

```ini
[Install]
WantedBy=multi-user.target
Alias=webapp.service
Also=webapp-metrics.service
```

`Alias=` lets a unit be `enable`d under an additional name, creating a second symlink pointing at the same unit file — used sparingly, mainly for compatibility scenarios where a renamed unit needs to remain reachable under its historical name for a transition period, without duplicating the unit file's actual content.

**A concrete `Alias=` scenario:** suppose `webapp.service` is being renamed to `checkout-service.service` as part of a broader naming-convention cleanup, but existing automation, dashboards, and muscle-memory `systemctl` invocations across the organization still reference the old name.

```ini
# /etc/systemd/system/checkout-service.service
[Unit]
Description=Checkout service (formerly webapp.service)

[Install]
WantedBy=multi-user.target
Alias=webapp.service
```

Running `systemctl enable checkout-service.service` in this configuration creates **two** symlinks in `multi-user.target.wants/` — one for `checkout-service.service` itself, and one named `webapp.service`, both pointing at the identical underlying unit file. `systemctl status webapp.service` and `systemctl status checkout-service.service` both work, both report on the same running unit, and both are functionally the same unit as far as the dependency graph is concerned — anything elsewhere in the system with `Requires=webapp.service` continues resolving correctly against the renamed file without needing to be updated in lockstep with the rename. This is deliberately a transitional mechanism, not a permanent one: `Alias=` papers over a rename, but leaves two names for the same underlying thing in active use, and cleanup work updating all remaining `webapp.service` references to the new canonical name, followed by removing the `Alias=` line entirely, is the expected eventual endpoint rather than something to leave in place indefinitely.

`Also=`, covered from a service-pairing angle in `02-Units-and-Dependencies.md` Section 5.5, generalizes beyond socket/service pairs — any set of units that should always be enabled or disabled together as a single administrative action can be grouped this way, regardless of whether any runtime dependency edge (`Requires=`, `Wants=`) exists between them at all; `Also=` is purely an installation-time convenience, entirely orthogonal to the runtime graph.

`DefaultInstance=`, covered fully in Section 2.4 above, is the remaining `[Install]`-section directive, relevant specifically to template units.

**A structural note worth restating plainly:** `[Install]` is inert at runtime, full stop — a unit with no `[Install]` section at all can still be started perfectly normally via `systemctl start`, and can still be pulled in as a dependency via another unit's `Wants=`/`Requires=` (`03-Service-Management.md` Section 14's `echo.service`, deliberately given no `[Install]` section, demonstrated exactly this). `[Install]` only matters for the specific, narrow question of "what happens when an administrator runs `enable`/`disable` against this unit's own name directly" — a question entirely separate from whether the unit can be used at all.

---

## 7. Non-Service Unit Types

### 7.1 `.mount`

Represents a filesystem mount point, and is the mechanism `02-Units-and-Dependencies.md` Section 5.1's `RequiresMountsFor=` resolves against under the hood.

```ini
# /etc/systemd/system/srv-webapp-data.mount
[Unit]
Description=Webapp data volume

[Mount]
What=/dev/disk/by-uuid/1234-5678
Where=/srv/webapp/data
Type=ext4
Options=noatime,nofail

[Install]
WantedBy=multi-user.target
```

The unit's **filename is not arbitrary** — it must be the escaped form of the `Where=` path (Section 2.2's escaping mechanism again), `srv-webapp-data.mount` for `/srv/webapp/data`, and systemd will refuse to load a `.mount` unit whose filename doesn't match its own `Where=` directive. In practice, most `.mount` units on a running system are not hand-authored at all — they're generated automatically at boot by `systemd-fstab-generator`, translating each line of the traditional `/etc/fstab` into an equivalent `.mount` unit, which is what allows `/etc/fstab` to remain the familiar, primary interface for most simple mount configuration while still participating fully in the same dependency graph, ordering, and `systemctl status`/`RequiresMountsFor=` machinery as any other unit — `fstab` and native `.mount` units are two authoring interfaces converging on the identical underlying mechanism, not two competing systems.

### 7.2 The `fstab` correspondence, concretely

It's worth seeing this translation explicitly once, since so much existing mount configuration in the wild is still expressed as `fstab` lines rather than native `.mount` units. Given this line in `/etc/fstab`:

```
UUID=1234-5678  /srv/webapp/data  ext4  noatime,nofail  0  2
```

`systemd-fstab-generator` produces, at every boot, an in-memory unit functionally equivalent to:

```ini
# generated — not present as a static file on disk
[Unit]
Description=/srv/webapp/data
Documentation=man:fstab(5) man:systemd-fstab-generator(8)
SourcePath=/etc/fstab
Before=local-fs.target

[Mount]
What=/dev/disk/by-uuid/1234-5678
Where=/srv/webapp/data
Type=ext4
Options=noatime,nofail

[Install]
WantedBy=local-fs.target
```

The `nofail` mount option specifically translates into the generated unit being ordered `Before=local-fs.target` and wanted by it, **without** a corresponding `Requires=` — mirroring exactly the `Wants=`-versus-`Requires=` soft-dependency distinction from `02-Units-and-Dependencies.md` Section 2.1: a failed `nofail` mount doesn't block `local-fs.target`, and transitively doesn't block boot, whereas an ordinary `fstab` entry without `nofail` generates a genuine `Requires=` edge, and a failed mount there **does** block the target it's wanted by, correctly modeling the traditional `fstab` semantics of "this filesystem is mandatory for the system to be considered fully up" within the native unit graph. This is a useful concrete illustration of a principle stated abstractly in `02-Units-and-Dependencies.md`: two seemingly different configuration surfaces (a legacy flat-file format and a modern declarative unit) can compile down to the identical graph representation, with the same requirement/ordering rules governing both without exception.

### 7.3 `.automount`

Pairs with a `.mount` unit the same structural way a `.socket` pairs with a `.service` (`02-Units-and-Dependencies.md` Section 11) — the mount point is registered with the kernel's autofs mechanism immediately, appearing in the filesystem hierarchy, but the actual mount operation is deferred until the path is first accessed.

```ini
# /etc/systemd/system/mnt-usb.automount
[Unit]
Description=Automount USB drive on access

[Automount]
Where=/mnt/usb

[Install]
WantedBy=multi-user.target
```

This is the mechanism behind, for instance, an NFS mount that shouldn't block boot waiting on a potentially-unavailable remote server: the mount point exists and is visible immediately, but the actual network mount operation — and any associated delay or failure — only happens (and only blocks whatever process triggered it) the first time something genuinely accesses `/mnt/usb`, rather than unconditionally during every boot regardless of whether anything ends up needing it that particular session.

### 7.4 `.swap`

Represents a swap device or file, structurally close to `.mount` — same filename-must-match-target convention, same fstab-generator relationship for entries already present in `/etc/fstab`.

```ini
[Swap]
What=/swapfile
Priority=10
```

`Priority=` governs the traditional Linux multi-swap priority ordering (higher values preferred first) when more than one swap unit is active simultaneously — relevant on systems balancing swap across, for instance, both a fast NVMe-backed swap file and a slower fallback device.

### 7.5 `.path`

Watches a filesystem path for a specific kind of change and triggers another unit (by convention, the identically-prefixed `.service`) when it occurs — a lightweight, inotify-based alternative to a polling loop.

```ini
# /etc/systemd/system/spool-watcher.path
[Path]
PathExistsGlob=/var/spool/webapp/*.job
Unit=process-job.service

[Install]
WantedBy=multi-user.target
```

| Directive | Triggers when... |
|---|---|
| `PathExists=` | The path exists (checked at activation and on subsequent changes) |
| `PathExistsGlob=` | Any path matching the glob pattern exists |
| `PathChanged=` | The path's content changes (on file close after a write) |
| `PathModified=` | The path is modified (fires more eagerly than `PathChanged=`, on every write, not just on close) |
| `DirectoryNotEmpty=` | A watched directory transitions from empty to non-empty |

`Unit=` names the unit to actually start on trigger; if omitted, it defaults to the identically-named `.service` unit (`spool-watcher.path` would default to triggering `spool-watcher.service`), mirroring the socket/service default-pairing convention. This is meaningfully more resource-efficient than a `.timer`-driven polling script for genuinely event-driven, arrival-based work — `07-Timers-and-Scheduled-Tasks.md` covers `.timer` units for the complementary, genuinely time-based scheduling case, and the choice between the two unit types should track whether the actual trigger condition is "time has passed" or "something arrived/changed," not personal preference between the two mechanisms.

### 7.6 `.device`

Represents a kernel device object, and is unusual among the unit types covered in this document in that **you essentially never author one directly** — `.device` units are generated dynamically by `systemd-udevd` as it processes kernel device events, named after the device's sysfs path (escaped, per Section 2.2's convention) — `dev-sda1.device` for `/dev/sda1`, for instance. Their entire purpose within the graph is to serve as dependency/ordering targets for other units — the `BindsTo=dev-sdb1.device` example in `02-Units-and-Dependencies.md` Section 2.4 — appearing and disappearing dynamically as hardware is attached and removed, with the unit's mere existence in the graph, at any given moment, being itself the signal "this device is currently present."

udev rules can attach systemd-relevant metadata to a device via specially-named udev properties — `SYSTEMD_WANTS=`, for instance, letting a udev rule declare that a specific unit should be started automatically the moment a matching device appears, without needing a separately-authored `.path` unit polling for it — the two mechanisms (path units and udev-property-driven device activation) solve overlapping problems from different layers, path units watching the filesystem generically, device-triggered activation integrating directly with the kernel's own hotplug event stream for actual hardware.

### 7.7 `.slice` and `.scope`, Revisited

`02-Units-and-Dependencies.md` Section 12 introduced `.slice` units as cgroup grouping nodes; `.scope` units were mentioned in `03-Service-Management.md` Section 14 as the mechanism `systemd-run --scope` uses to wrap an externally-started process tree under systemd's tracking after the fact. Both are structurally simple relative to the unit types above — a `.slice` unit file typically contains little beyond resource-control directives (`08-Security-and-Hardening.md`'s subject) and `[Unit]`-section metadata, with no `Exec*=` directives at all, since a slice does no work of its own; a `.scope` unit, similarly, is never started via `ExecStart=` — it exists specifically to describe a process tree systemd did not itself launch, and is created exclusively via the `systemd-run --scope` mechanism or the equivalent low-level D-Bus API, never by loading a `.scope` file from disk the way every other unit type in this document is loaded.

---

## 8. Unit File Syntax Mechanics

A brief, precise treatment of the parsing rules themselves, since several of the gotchas across this series trace back to a misunderstanding here.

### 8.1 Sections and keys

`[SectionName]` headers, `Key=Value` pairs beneath them, one per line. Section order within the file is irrelevant to parsing — `[Install]` appearing before `[Unit]` parses identically to the conventional ordering — though the conventional `[Unit]`/`[Service (or type-specific)]`/`[Install]` ordering used throughout this series is worth keeping purely for human readability and consistency with every distribution-shipped unit you'll ever read alongside your own.

### 8.2 Comments

Lines beginning with `#` or `;` (both are accepted, interchangeably) are comments, ignored entirely during parsing. There is no inline/trailing comment syntax — `ExecStart=/usr/bin/foo # a comment` does **not** work as you might expect from many other config formats; the `# a comment` portion becomes part of the literal command-line value being parsed, not a comment stripped before parsing, a mistake that silently corrupts the directive's actual value rather than producing any parse error.

### 8.3 Line continuation

A trailing backslash (`\`) at the end of a line continues that logical line onto the next, useful for keeping a long `ExecStart=` command or a long list of dependency units readable across multiple physical lines in the source file without affecting how systemd actually parses the resulting single logical value:

```ini
ExecStart=/usr/local/bin/tool \
    --flag-one=value \
    --flag-two=another-value
```

### 8.4 Quoting inside directive values

Within `Exec*=` directive values specifically (Section 4.6 of `03-Service-Management.md`'s `$MAINPID` example notwithstanding), systemd performs its own word-splitting and quoting, distinct from — and not to be confused with — shell quoting rules, since (per Section 1.1) no shell is actually involved by default. Double quotes group a value containing whitespace into a single argument; a backslash escapes a literal quote character where one is genuinely needed within a quoted value. Single quotes carry **no special meaning** to systemd's own parser the way they would to a POSIX shell — a common, easy mistake for anyone bringing shell-scripting habits directly into unit-file authoring, where `ExecStart=/usr/bin/echo 'hello world'` does not group `hello world` into one argument the way it would in an actual shell invocation, but instead passes the literal characters `'hello` and `world'`, single quotes included, as two separate arguments.

### 8.5 When a shell genuinely is involved

If a directive's value actually needs shell features — globbing, pipes, variable expansion beyond what specifiers (Section 1) provide, conditional logic — the standard idiom is explicitly invoking a shell as the command itself:

```ini
ExecStart=/bin/sh -c 'echo "Starting at $(date)" >> /var/log/webapp-starts.log'
```

Here, `/bin/sh` is the actual program systemd launches (word-split and quoted per systemd's own rules, Section 8.4, up to the point where the single-quoted shell script argument begins), and everything within the single-quoted argument is then handed, as one literal string, to the shell itself for its *own*, separate parsing and execution — the two parsing layers (systemd's own, and the shell's, once invoked) are sequential and distinct, not merged into one combined grammar, and keeping that boundary clear is the fastest way to reason correctly about a unit file mixing both.

### 8.6 Escaping Rules for Unit Names, Systematically

Section 2.2 introduced unit-name escaping in the specific context of template instances derived from paths; the underlying rule is more general and worth stating completely, since it governs every mechanically-generated unit name encountered across this series — mount units (Section 7.1), device units (Section 7.6), and any template instance built from an arbitrary string.

| Input character(s) | Escaped as |
|---|---|
| `/` | `-` |
| A leading `.` | `\x2e` |
| Any byte not in `[A-Za-z0-9:_.\-]` | `\xHH` (two-digit hex of the byte's value) |

```bash
systemd-escape 'my service/data'
# my\x2dservice-data
```

Note the asymmetry in that example: the literal `-` character already present in the input is itself escaped (to `\x2d`, its hex code) precisely *because* plain `-` is the substitution systemd uses for `/` — without escaping a pre-existing `-`, the transformation would not be reversible, and `systemd-escape --unescape` could not distinguish an original `/` from an original `-` in the source string. This reversibility requirement — that `systemd-escape --unescape` applied to any escaped output exactly reconstructs the original input, with no ambiguity — is the actual design constraint the whole scheme is built around, and is why the escaping is more thorough than might seem necessary at first glance for the common case of simple paths with no embedded hyphens.

`systemd-escape --template=worker@.service 'my queue'` combines both operations in one call — escaping the given string *and* wrapping it into a specific template's instance-name position — producing `worker@my\x20queue.service` directly, the exact unit name to use in a subsequent `systemctl start` call, sparing the need to manually concatenate the escaped instance string with the template's own prefix and suffix.

---

## 9. A Fully Worked Example: Templated Service with Drop-In Customization

Bringing every mechanism in this document together: a templated worker service, one specific instance customized via a drop-in, demonstrating specifier resolution, the append/override merge distinction, and the explicit-clear idiom in combination.

```ini
# /etc/systemd/system/worker@.service
[Unit]
Description=Queue worker for %I
After=network-online.target redis.service
Wants=network-online.target
Requires=redis.service

[Service]
Type=notify
User=webapp
Environment=QUEUE_NAME=%I
ExecStart=/srv/webapp/bin/worker --queue=%I --log-tag=%N
Restart=on-failure
RestartSec=2s
StartLimitIntervalSec=60s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
DefaultInstance=default
```

```ini
# /etc/systemd/system/worker@exports.service.d/override.conf
[Service]
# The exports queue does heavier, slower work than other queues —
# give it a longer restart backoff and a higher file-descriptor
# ceiling, without touching the shared template every other
# instance also uses.
ExecStart=
ExecStart=/srv/webapp/bin/worker --queue=%I --log-tag=%N --slow-mode
RestartSec=10s
LimitNOFILE=32768
```

Enabling and starting three instances:

```bash
systemctl enable --now worker@emails.service
systemctl enable --now worker@thumbnails.service
systemctl enable --now worker@exports.service
```

`worker@emails.service` and `worker@thumbnails.service` run with the template's own unmodified `RestartSec=2s` and default file-descriptor limit, each with `%I` resolving to `emails` and `thumbnails` respectively, correctly threading through `Description=`, `Environment=QUEUE_NAME=`, and `ExecStart=`'s `--queue=` flag identically via the same specifier. `worker@exports.service` picks up the drop-in in Section 3's directory-and-precedence sense — its `ExecStart=` is fully replaced (the explicit-clear idiom from Section 3.3, necessary here because `Type=notify` permits only one `ExecStart=`) with a version adding `--slow-mode`, while `RestartSec=` is overridden to a longer `10s`, and `LimitNOFILE=` is newly introduced by the drop-in, present in no form in the base template at all. Every other directive in the base template — the full `[Unit]` section's dependency graph, `Type=notify`, `Restart=on-failure`, `StartLimitBurst=5` — applies to `worker@exports.service` entirely unchanged, exactly as `03-Service-Management.md` Section 9.1 predicted: the failure/restart machinery from that document required no special adaptation to work correctly across both the templated and the per-instance-customized case.

---

## 10. Common Anti-Patterns

**Confusing `%i` and `%I` for any instance name containing escaped characters.** As covered in Section 2.2, this bug is invisible for simple instance names and only manifests once an instance name requiring real escaping is used — write template units assuming `%I` is needed from the start whenever the instance conceptually represents a path or any value that could plausibly contain a `/`, rather than discovering the distinction the first time a path-like instance is actually used.

**Adding a bare `# comment` at the end of an `Exec*=` line.** As covered in Section 8.2, this silently corrupts the directive's value rather than being stripped as a comment — comments belong on their own dedicated lines only.

**Assuming single quotes group arguments the way they would in a shell.** As covered in Section 8.4, systemd's own `Exec*=` parsing has no concept of single-quote grouping; reach for double quotes, or an explicit `/bin/sh -c` wrapper (Section 8.5) if genuine shell semantics are required.

**Forgetting the explicit-clear idiom when a drop-in needs to change `ExecStart=`.** As covered in Section 3.3, a bare re-declaration without first clearing produces a configuration error for every `Type=` except `oneshot` — the `ExecStart=` \+ new value two-line pattern is required, not optional convenience.

**Hand-deriving a `.mount` unit's filename instead of matching it exactly to the escaped `Where=` path.** As covered in Section 7.1, systemd validates this correspondence and refuses to load a mismatched unit — reach for `systemd-escape --path` (Section 2.2) rather than manually working out the escaping by hand.

**Assuming a specifier re-resolves dynamically at runtime.** As covered in Section 1.2, specifier expansion happens once, at unit load time — a unit relying on `%H` to reflect a hostname change made after the unit was last loaded needs an explicit `daemon-reload` before that change is reflected, not merely the passage of time or the unit's own next restart.

**Writing `Requires=worker@.service` against a bare template.** As covered in Section 2.6, this is not a valid way to express "depend on every instance" — bare templates aren't startable units at all, and this pattern either fails to load or silently does nothing useful, depending on systemd version, rather than producing the fan-out dependency the author likely intended.

**Reaching for `ExecStartPre=mkdir -p` out of habit rather than the purpose-built directory directives.** As covered in Section 4.7, `RuntimeDirectory=`/`StateDirectory=`/`CacheDirectory=`/`LogsDirectory=` handle ownership and lifetime correctly and automatically, tied to the unit's own declared identity — a hand-written `mkdir` step is one more thing to keep in sync manually if the unit's `User=` or name ever changes, and gets the resulting directory's lifetime semantics wrong by default (an `ExecStartPre=`-created directory under `/var/lib` doesn't automatically get `StateDirectory=`'s well-defined persistence guarantees, and one under `/run` doesn't automatically get `RuntimeDirectory=`'s automatic cleanup on stop).

**Setting `PrivateTmp=yes` on two cooperating units without `JoinsNamespaceOf=`.** As covered in Section 4.9, each unit independently gets its own, mutually invisible private `/tmp` — a coordination break that fails silently (each side sees an empty or unexpected `/tmp`, with no error indicating why) rather than loudly, making it a genuinely time-consuming class of bug to trace back to its actual cause without already knowing this specific interaction to look for.

---

## 11. Exercises

**1.** A template `sync@.service` has `ExecStart=/usr/bin/rsync -a %I /backup/`, and is started as `sync@srv-data.service` (the escaped form of `/srv/data`). Using `%i` instead of `%I` by mistake, what does the resulting command line actually attempt to sync? *(Per Section 2.2, `%i` would expand to the literal, still-escaped string `srv-data` — `rsync -a srv-data /backup/` — attempting to sync a file or directory literally named `srv-data` in the current working directory, not the intended `/srv/data` path at all.)*

**2.** A drop-in adds `Wants=metrics-exporter.service` to a unit whose base file already has `Wants=network-online.target`. What is the resulting, effective set of `Wants=` targets? *(Per Section 3.2, list-like directives append rather than override — the effective configuration wants both `network-online.target` and `metrics-exporter.service`, not just the drop-in's own line.)*

**3.** A `.path` unit has `PathExistsGlob=/var/spool/jobs/*.job` with no explicit `Unit=` directive, and is named `job-watcher.path`. What unit does it trigger? *(Per Section 7.5, an omitted `Unit=` defaults to the identically-prefixed `.service` unit — `job-watcher.service` — mirroring the socket/service default-pairing convention from `02-Units-and-Dependencies.md`.)*

**4.** A unit file has `ExecStart=/usr/bin/tool --name='my tool'` (single quotes). How many arguments does `tool` actually receive for that portion of the command line, and what are they? *(Per Section 8.4, systemd's own parser does not treat single quotes as grouping — `tool` receives two separate arguments: `--name='my` and `tool'`, quote characters included literally, almost certainly not the author's intent.)*

**5.** A `.mount` unit file is saved as `data-volume.mount` with `Where=/srv/data`. Will systemd load it successfully? *(No — per Section 7.1, a `.mount` unit's filename must be the escaped form of its own `Where=` path; `/srv/data` escapes to `srv-data`, so the file must be named `srv-data.mount`, and systemd will refuse to load the mismatched `data-volume.mount` as written.)*

**6.** A service sets `RuntimeDirectory=webapp` and `User=webapp`, with no `ExecStartPre=mkdir` line anywhere. Where does `/run/webapp` come from, and what happens to it when the service stops? *(Per Section 4.7, systemd itself creates `/run/webapp`, owned by the `webapp` user, immediately before `ExecStart=` runs — no `mkdir` step is needed at all — and because `RuntimeDirectory=` mirrors `/run`'s own transient lifetime, its contents are automatically removed once the service stops, unlike the persistent `StateDirectory=`/`CacheDirectory=`/`LogsDirectory=` counterparts.)*

**7.** An `/etc/fstab` line for `/data` has no `nofail` option. The underlying device is missing at boot. What happens to `local-fs.target`, and transitively, to boot? *(Per Section 7.2, without `nofail` the generated `.mount` unit is pulled in via a genuine `Requires=` edge rather than the soft `Wants=` `nofail` produces — the missing device causes the mount to fail, which per `02-Units-and-Dependencies.md` Section 2.2's requirement-propagation rules fails `local-fs.target`'s own start job in turn, which is what actually blocks normal boot and typically drops the system into an emergency shell rather than proceeding, exactly modeling traditional `fstab` semantics where a non-`nofail` entry is treated as mandatory.)*

**8.** Why is a literal `-` character in an input string escaped to `\x2d` by `systemd-escape`, rather than left as-is, given that `-` is already a perfectly valid unit-name character? *(Per Section 8.6, `-` is the substitution used for an original `/` — leaving a pre-existing `-` unescaped would make the transformation ambiguous and irreversible, since `systemd-escape --unescape` would have no way to tell whether a `-` in the escaped output represents an original `/` or an original, literal `-`.)*

**9.** Two units, `primary.service` and `sidecar.service`, both set `PrivateTmp=yes` independently, with no `JoinsNamespaceOf=` between them. `sidecar.service` is supposed to process files `primary.service` writes to `/tmp`. What actually happens? *(Per Section 4.9, each unit gets its own separate, mutually invisible private `/tmp` — `sidecar.service` never sees the files `primary.service` writes, with no error raised on either side, since from each unit's own perspective its `/tmp` behaves entirely normally; the fix is adding `JoinsNamespaceOf=primary.service` to `sidecar.service` so the two share one private namespace instead of each getting its own.)*

---

## 12. Pre-Deployment Checklist

Mirroring the checklists in `02-Units-and-Dependencies.md` Section 18a and `03-Service-Management.md` Section 21, adapted to unit-file authoring specifically:

1. **For any template unit, write out by hand what `%i` and `%I` resolve to for at least one instance name that actually requires escaping** (a path-derived instance, not merely a simple word) — per Section 2.2, this is the single fastest way to catch a `%i`/`%I` mix-up before it ships, since the bug is invisible for any instance name that happens not to need escaping.
2. **Run the unit through `systemd-analyze verify` after any drop-in change**, not only after base-file changes — a drop-in with a subtly wrong section header (a directive accidentally placed under `[Unit]` when it belongs under `[Service]`, for instance) fails silently from a casual read but is caught immediately by verification.
3. **For any drop-in touching a single-value directive `Exec*=` line, confirm the explicit-clear idiom (Section 3.3) is present** before the replacement value — its absence is a configuration error for every `Type=` except `oneshot`, per `03-Service-Management.md` Section 2.3.
4. **Run `systemctl cat <unit>` after applying a drop-in and read the fully merged result**, rather than trusting your own mental model of how the override and base file combine — this is the authoritative, resolved view, and per Section 3.2 the append-versus-override distinction is easy to misjudge for a directive you don't work with often.
5. **For any `.mount` unit, confirm the filename is the exact `systemd-escape --path` output for its own `Where=` value** before assuming a load failure is caused by anything else — per Section 7.1, this specific mismatch is a common, easy-to-overlook cause of an otherwise-inexplicable "unit not found" or load error.
6. **Prefer `RuntimeDirectory=`/`StateDirectory=`/`CacheDirectory=`/`LogsDirectory=` over an `ExecStartPre=mkdir` line for any new unit**, per Section 4.7 — reserve `ExecStartPre=` for setup these directives genuinely can't express.

---

## 13. Quick-Reference Table

| Directive / Mechanism | Section | Purpose |
|---|---|---|
| `%n` / `%N` / `%p` | 1 | Unit name, name without suffix, template prefix |
| `%i` / `%I` | 1, 2.2 | Raw / unescaped instance name |
| `%h` / `%u` / `%U` | 1 | Home directory / username / UID of `User=` |
| `%t` / `%S` / `%C` / `%L` / `%E` | 1 | Runtime / state / cache / log / config directory roots |
| `DefaultInstance=` | 2.4 | Instance used when the bare template is enabled |
| `*.d/*.conf` drop-ins | 3 | Layered, mergeable overrides without editing the base file |
| Empty `Key=` line | 3.3 | Explicitly clears a list-like directive before re-populating it |
| `systemctl edit` / `edit --full` / `revert` | 3.4, 3.5 | Create, fully replace, or remove overrides |
| `User=` / `Group=` / `DynamicUser=` | 4.1 | Process identity |
| `Environment=` / `EnvironmentFile=` / `PassEnvironment=` | 4.3 | Process environment |
| `Nice=` / `IOSchedulingClass=` / `CPUAffinity=` | 4.4 | Scheduling priority |
| `LimitNOFILE=` and the `Limit*=` family | 4.5 | Traditional rlimit resource limits |
| `StandardOutput=` / `StandardError=` / `SyslogIdentifier=` | 4.6 | Where process output is routed |
| `Description=` / `Documentation=` | 5 | Human-facing metadata |
| `WantedBy=` / `RequiredBy=` / `Alias=` / `Also=` | 6 | `[Install]`-section enablement wiring |
| `.mount` / `.automount` / `.swap` / `.path` / `.device` | 7 | Non-service unit types |

---

## 14. Glossary

**Specifier** — a `%`-prefixed sequence expanded by systemd itself at unit-load time, distinct from shell or environment variables.
**Template unit** — a unit file named with a bare `@` before its suffix, not directly startable, serving as a pattern for instances.
**Instance** — a specific, fully-qualified unit created by substituting a string into a template's `@`, tracked as an independent unit.
**Drop-in** — a `.conf` file in a `*.d/` directory that layers additional or overriding configuration onto a base unit file.
**Explicit-clear idiom** — a bare `Key=` line in a drop-in, used to reset a list-like directive before supplying new values.
**Escaping** — the systematic transformation of characters like `/` into `-` (or `\xHH` sequences) to form valid unit-name components.
**Generator** — a program (`systemd-fstab-generator` being the running example) that produces in-memory units dynamically at boot from a non-native configuration source.
**Managed directory** — a directory whose existence, ownership, and lifetime systemd itself handles via `RuntimeDirectory=`/`StateDirectory=`/`CacheDirectory=`/`LogsDirectory=`, rather than an ad hoc `ExecStartPre=` step.
**Private namespace** — a per-unit, isolated view of part of the filesystem (or other kernel namespace) established via directives like `PrivateTmp=`, invisible to other units unless explicitly joined via `JoinsNamespaceOf=`.

---

## 15. What's Ahead

`05-Boot-Process-and-Targets.md` moves from unit-file authoring to the full boot sequence itself — the kernel-to-initramfs-to-`sysinit.target`-to-`default.target` chain, where in that sequence the mount-unit generation described in Section 7.1 actually happens, and how emergency and rescue paths (briefly introduced in `01-Introduction.md` Section 8) are reached when a step in that chain fails.

---

## References

- `systemd.unit(5)` — `[Unit]`/`[Install]` sections, specifiers, general syntax
- `systemd.exec(5)` — the complete execution-context directive reference
- `systemd.service(5)`, `systemd.mount(5)`, `systemd.automount(5)`, `systemd.swap(5)`, `systemd.path(5)`, `systemd.device(5)` — per-type directive references
- `systemd-escape(1)` — the escaping/unescaping tool referenced throughout Section 2.2
- `systemd.syntax(7)` — the formal grammar underlying Section 8's parsing rules
