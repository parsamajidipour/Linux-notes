# Security and Hardening

A complete, mechanism-level reference for systemd's sandboxing and resource-control directive family: filesystem namespacing (`ProtectSystem=`, `ProtectHome=`, and the read-only/inaccessible-path directives), the full private-namespace family previewed in `04-Unit-Files.md` Section 4.9, privilege restriction (`NoNewPrivileges=`, capability bounding), system-call filtering via seccomp, memory and execution protections, the cgroup-v2 resource-control mechanism first named in `02-Units-and-Dependencies.md` Section 12, `DynamicUser=` in full depth, and `systemd-analyze security`'s automated exposure scoring — assembled into one incremental worked hardening pass over the `webapp.service` running example this series has used throughout.

Every prior document in this series named a piece of this directive family in passing and deferred its full treatment here — `PrivateTmp=` in `04-Unit-Files.md`, `DynamicUser=` in `03-Service-Management.md` and `04-Unit-Files.md`, resource-control slices in `02-Units-and-Dependencies.md`. This document is where each of those threads is finally picked back up and given the depth it was deliberately withheld until this point.

---

## 1. The Threat Model: What Sandboxing Actually Defends Against

Before cataloging individual directives, it's worth being precise about what problem this entire directive family solves, because the value of each specific directive only makes sense against a clear threat model.

### 1.1 The scenario these directives address

A service, however carefully written, may contain a vulnerability — a memory-safety bug in a parsing library, an injection flaw, a dependency with a known CVE — that an attacker can exploit to achieve arbitrary code execution **within that process**. The question every directive in this document answers, in its own specific dimension, is: *given that an attacker has achieved code execution inside this one process, what can they actually do next?* A service running with no sandboxing at all, as the traditional Unix model has always permitted, can — subject only to its own Unix user's permissions — read arbitrary files that user can read, write to arbitrary paths that user can write, see and potentially interfere with other processes' network traffic and IPC, load kernel modules if running as root, and generally use the full scope of what that Unix identity is authorized to do, entirely unconstrained beyond that one boundary.

Every directive in this document narrows that scope — sometimes drastically — so that a successful exploit inside the sandboxed process is contained to a meaningfully smaller blast radius than "everything this Unix user could ever do," even without needing to fix the underlying vulnerability itself, which may not yet be known or may not yet have a patch available.

### 1.1a A Concrete Scenario

To make Section 1.1's abstract framing tangible: suppose `webapp.service`'s underlying application depends on a third-party library later found to have a deserialization vulnerability, allowing an attacker who can reach the application's request-handling code to achieve arbitrary code execution within the process — the exact class of vulnerability no directive in this document does anything to *prevent*, since it's a flaw in the application's own logic, not a containment gap. The question is what that same attacker can do *next*, and the answer depends entirely on which of this document's directives were applied beforehand:

- **Unhardened baseline:** the attacker, running as whatever Unix user `webapp.service` was configured with, can read any file that user can read (potentially including other applications' configuration or credentials on a shared host), write anywhere that user can write, open arbitrary network connections, and — if the exploited process happens to run as root, a genuinely common historical default for many real-world deployments — do essentially anything at all on the host.
- **With Section 2's filesystem namespacing alone:** the attacker's file-write reach is now confined to whatever narrow set of paths `ProtectSystem=strict` plus explicit `ReadWritePaths=`/`StateDirectory=` exceptions actually permit — reading most of the rest of the filesystem, and writing anywhere outside that narrow set, both fail outright regardless of the exploited process's nominal Unix identity.
- **With Section 4's privilege restriction added:** even if the exploited process somehow still runs as (or briefly escalates to) something resembling root within its own namespace, `CapabilityBoundingSet=` has already removed the specific capabilities that would let that nominal privilege actually translate into meaningful additional access — loading a kernel module, overriding arbitrary file permissions, and similar escalation paths are foreclosed regardless of the UID the process technically holds.
- **With Section 5's syscall filtering added on top:** even an attacker who has found a way around the restrictions above still cannot invoke any syscall outside the configured `@system-service`-plus-exceptions surface — closing off entire categories of further kernel-level attack surface (loading modules via a lower-level syscall path than the capability check alone would catch, for instance) the earlier layers didn't individually address.

No single layer here is what "stops the attack" — the deserialization vulnerability itself remains exploitable regardless of any of this document's directives. What changes, layer by layer, is how much the attacker can actually *accomplish* once they're executing code inside the process — precisely Section 1.2's defense-in-depth principle, made concrete against one specific, realistic vulnerability class rather than left purely abstract.

### 1.2 Defense in depth, not a single silver bullet

No single directive in this document is sufficient on its own — the value comes from **layering** several independent restrictions, such that an attacker circumventing or working around any one of them still faces the remainder. `ProtectSystem=` (Section 2) alone doesn't prevent a network-based attack; `RestrictAddressFamilies=` (Section 6) alone doesn't prevent a malicious child process from being spawned; combined, each closes off a different avenue, and the practical security posture of a hardened unit is the product of everything applied together, not any single directive in isolation. Section 9's `systemd-analyze security` scoring reflects exactly this cumulative view, rather than treating any one directive as individually decisive.

### 1.3 The cost side of the trade-off

Every directive in this document also has the potential to **break legitimate functionality** if applied without understanding what the service actually needs — `ProtectHome=yes` on a service that genuinely needs to read a configuration file under a user's home directory will simply fail, not degrade gracefully, and `SystemCallFilter=` (Section 5) misconfigured to exclude a syscall the service's own runtime genuinely requires produces an immediate, hard failure rather than a security improvement. This document's worked example (Section 11) is deliberately structured as an **incremental** hardening pass for exactly this reason — applying restrictions one at a time, verifying the service still functions correctly after each addition, rather than applying the entire directive family at once and then debugging which one broke something.

---

## 2. Filesystem Namespacing

### 2.1 `ProtectSystem=`

```ini
[Service]
ProtectSystem=strict
```

| Value | Effect |
|---|---|
| `false` (default) | No restriction |
| `true` | `/usr` and `/boot`/`/efi` mounted read-only within the unit's private mount namespace |
| `full` | `true`, plus `/etc` also mounted read-only |
| `strict` | The **entire** filesystem hierarchy mounted read-only, except paths explicitly exempted via `ReadWritePaths=` (Section 2.3) |

`strict` is the strongest, and — for a service whose actual writable needs are well understood and narrow (a handful of specific data/log/cache directories, ideally already declared via `04-Unit-Files.md` Section 4.7's `StateDirectory=`/`CacheDirectory=`/`LogsDirectory=`, which remain writable under `strict` automatically since systemd itself manages their exemption) — the generally-recommended default to reach for first, narrowing back to `full` or `true` only if a specific, legitimate need for broader write access is discovered during the verification step Section 1.3 described.

### 2.2 `ProtectHome=`

```ini
[Service]
ProtectHome=yes
```

| Value | Effect |
|---|---|
| `no` (default) | No restriction |
| `yes` | `/home`, `/root`, and `/run/user` become entirely inaccessible |
| `read-only` | The same paths become read-only rather than fully inaccessible |
| `tmpfs` | The same paths are replaced with an empty, private `tmpfs` — appearing to exist but containing nothing |

For the overwhelming majority of system services — a web application, a database, a background worker — there is no legitimate reason to access any interactively-logged-in user's home directory at all, making `ProtectHome=yes` (the strictest, fully-inaccessible option) an easy, low-risk default for nearly any service in this series' running examples, `webapp.service` included.

### 2.3 `ReadOnlyPaths=`, `ReadWritePaths=`, `InaccessiblePaths=`

These three directives provide fine-grained exceptions layered on top of the broader `ProtectSystem=`/`ProtectHome=` settings, or usable entirely independently of them:

```ini
[Service]
ProtectSystem=strict
StateDirectory=webapp
ReadWritePaths=/srv/webapp/uploads
InaccessiblePaths=/proc/sysrq-trigger /proc/sys/kernel/core_pattern
```

`ReadWritePaths=` carves out a specific exception to an otherwise-read-only filesystem (per `ProtectSystem=strict` here) — the standard pattern for a path `StateDirectory=`/`CacheDirectory=`/`LogsDirectory=` doesn't already cover automatically. `ReadOnlyPaths=` does the reverse — forcing a specific path read-only even in an otherwise more permissive configuration. `InaccessiblePaths=` goes further than read-only, making the specified path **appear not to exist at all** within the unit's private mount namespace — the standard tool for blocking access to specific, individually-dangerous pseudo-filesystem entries (`/proc/sysrq-trigger`, capable of triggering an immediate kernel-level system action; specific `/proc/sys/kernel/` tunables) that a broader `ProtectKernelTunables=` (Section 3) might not exhaustively cover for every conceivable dangerous path, or where an administrator wants an explicit, self-documenting exception beyond whatever the coarser directive's own default exclusion list provides.

### 2.4 `RootDirectory=` and `RootImage=`, Revisited

`04-Unit-Files.md` Section 4.2 named these only in passing. `RootDirectory=` performs a traditional `chroot()`-style confinement to a specified directory, while `RootImage=` mounts an entire disk image file as the unit's root filesystem — both provide a considerably stronger containment boundary than the path-level exceptions in Section 2.3, at the cost of needing to actually maintain a separate, self-contained root filesystem tree or image for the unit to run against, which is genuinely more operational overhead than the other directives in this section, and is more commonly seen in container-adjacent or genuinely security-critical deployments than in routine application hardening.

---

## 3. The Broader Private-Namespace Family

`04-Unit-Files.md` Section 4.9 introduced `PrivateTmp=` as a preview. This section covers its siblings — each following the identical underlying pattern of "the process sees its own, isolated view of some kernel-managed resource, indistinguishable from the real thing from inside the process, but invisible to and unaffected by everything else on the system."

```ini
[Service]
PrivateTmp=yes
PrivateDevices=yes
PrivateNetwork=no
PrivateUsers=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
```

### 3.1 `PrivateDevices=`

Restricts the unit's view of `/dev` to a minimal, private set — the standard pseudo-devices (`/dev/null`, `/dev/zero`, `/dev/random`, and similar) remain present, while access to raw block devices, hardware device nodes, and similar physically-meaningful devices is removed entirely. Appropriate for essentially any service that doesn't specifically need direct hardware access — a web application has no legitimate need to open a raw disk device node, and `PrivateDevices=yes` removes that capability from the attack surface entirely, regardless of whether the specific application code was ever written with the intention of touching hardware directly.

### 3.2 `PrivateNetwork=`

Gives the unit its own, entirely isolated network namespace — no network interfaces at all beyond loopback, unless explicitly configured otherwise via `04-Unit-Files.md` Section 5.4's `JoinsNamespaceOf=` sharing a namespace with a specifically-designated networking-capable companion unit. This is a strong, sometimes disruptive restriction — a service genuinely needing outbound or inbound network connectivity (which describes `webapp.service` throughout this series' own running example) cannot have `PrivateNetwork=yes` set at all without breaking its actual function, making this directive's applicability genuinely narrower than most of the rest of this section's family — appropriate for a batch job or internal tool that performs no networking whatsoever, not a blanket default.

### 3.3 `PrivateUsers=`

Maps the unit's view of user/group IDs into a private, isolated user namespace — the process's own `UID 0` (root, if it happens to be running as root) inside this namespace does **not** correspond to genuine host-level root at all, meaning even a full privilege-escalation exploit achieving apparent root *within* the sandboxed process's own namespace still lacks genuine host-level root privileges outside of it. This is one of the single strongest containment mechanisms in this document specifically because it defends against privilege escalation *within* the process itself, not merely restricting what an already-unprivileged process can reach — a meaningfully different, and often more valuable, guarantee than most of the other directives in this section provide individually.

### 3.4 `ProtectKernelTunables=` and `ProtectKernelModules=`

`ProtectKernelTunables=yes` makes the kernel-tunable portions of `/proc/sys` and `/sys` read-only within the unit's namespace — preventing a compromised process from altering system-wide kernel behavior (network stack parameters, various security-relevant `sysctl` values) even if it's otherwise privileged enough that it could. `ProtectKernelModules=yes` goes further, removing the capability to load or unload kernel modules entirely, regardless of the process's own nominal privilege level — directly relevant against an attacker attempting to load a malicious kernel module as an escalation path beyond mere userspace process compromise.

### 3.5 `ProtectKernelLogs=`

Removes access to the kernel's own logging interfaces (`/dev/kmsg`, and the `syslog()` system call's kernel-log-reading mode) — preventing a compromised process from either reading potentially sensitive kernel-log content or injecting forged entries into it, tying directly back to `06-journald-and-Logging.md` Section 7's kernel-message ingestion: an attacker with this access removed cannot pollute or read the very `_TRANSPORT=kernel` stream that document's diagnostic workflows rely on.

### 3.6 `ProtectControlGroups=`

Makes the cgroup filesystem hierarchy (`/sys/fs/cgroup/`) read-only within the unit's namespace — directly relevant given how central cgroups are to the process-supervision model `01-Introduction.md` Section 9 established: without this protection, a sufficiently privileged compromised process could, in principle, directly manipulate its own or even sibling units' cgroup configuration, interfering with the resource-control and supervision guarantees Section 7 of this document (and the entirety of `03-Service-Management.md`) depend on.

### 3.7 `ProtectClock=` and `ProtectHostname=`

`ProtectClock=yes` removes the capability to alter the system's real-time clock or its `CLOCK_REALTIME`-adjacent settings — relevant given how much of `06-journald-and-Logging.md` and `07-Timers-and-Scheduled-Tasks.md`'s own correctness assumptions depend on a trustworthy system clock; a compromised process able to freely adjust the clock could disrupt log timestamp ordering or timer scheduling as a secondary attack vector beyond whatever its primary compromise objective was. `ProtectHostname=yes` similarly removes the capability to change the system's hostname, a comparatively minor but essentially cost-free restriction to apply given how rarely any ordinary service has a legitimate need to alter it.

---

## 4. Privilege Restriction

### 4.1 `NoNewPrivileges=`

```ini
[Service]
NoNewPrivileges=yes
```

Prevents the process, and everything it subsequently executes, from gaining **any** additional privileges beyond what it started with — specifically blocking the traditional Unix `setuid`/`setgid`/file-capability escalation mechanisms from taking effect for anything this process (or its children) execute from this point forward. This is one of the lowest-cost, highest-value directives in this entire document: it's difficult to imagine a legitimate reason an ordinary application service would need to execute a `setuid` binary to gain elevated privileges mid-execution, making `NoNewPrivileges=yes` close to a safe, near-universal default, and it's frequently listed as the very first directive added in an incremental hardening pass precisely because it's so rarely the directive that breaks something during the verification step Section 1.3 described.

### 4.2 `CapabilityBoundingSet=`

Linux capabilities decompose the traditional monolithic "root can do anything" model into dozens of individually-grantable privileges (`CAP_NET_BIND_SERVICE` — binding a port below 1024; `CAP_SYS_ADMIN` — a notoriously broad, catch-all capability; `CAP_NET_RAW` — raw socket access; and many more). `CapabilityBoundingSet=` restricts which of these capabilities the unit's process — and anything it execs — can **ever** hold, regardless of what its nominal Unix UID would otherwise permit.

```ini
[Service]
User=webapp
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

This combination is the standard, precise idiom for the extremely common "needs to bind a low port, but should otherwise run entirely unprivileged" case — rather than the traditional, coarser alternative of simply running the entire process as root merely to bind port 443 and hoping the application drops privileges correctly and completely on its own afterward, `CapabilityBoundingSet=` restricts the *ceiling* of what the process could ever hold to just this one specific capability, while `AmbientCapabilities=` (Section 4.3) is what actually grants it despite the process running as the unprivileged `webapp` user throughout its entire lifetime, never touching root at all even momentarily.

### 4.3 `AmbientCapabilities=`

Distinct from `CapabilityBoundingSet=`'s ceiling-setting role, `AmbientCapabilities=` actually **grants** specific capabilities to a process that isn't running as root at all — historically, capabilities were only available to a process already running as UID 0 (or via `setuid`/file-capability mechanisms `NoNewPrivileges=` in Section 4.1 specifically blocks), and `AmbientCapabilities=` is the modern mechanism letting an ordinary, always-unprivileged `User=webapp`-run process hold a narrow, specific capability like `CAP_NET_BIND_SERVICE` without ever running as root, even transiently, at any point in its lifecycle — a meaningfully stronger guarantee than the traditional "start as root, then drop privileges" pattern, which has a real, if brief, window where the process genuinely does hold full root before its own code executes the drop.

### 4.3a A Working Reference of Common Capabilities

The full capability list runs to several dozen entries; the following covers the ones an ordinary application service is most likely to genuinely need, versus the ones almost never legitimately required outside of system-level tooling itself:

| Capability | Grants | Typical legitimate need |
|---|---|---|
| `CAP_NET_BIND_SERVICE` | Binding ports below 1024 | A service fronting its own TLS termination directly, without a reverse proxy |
| `CAP_NET_RAW` | Raw socket creation | Tools performing low-level network diagnostics (ICMP ping implementations, packet capture) |
| `CAP_CHOWN` | Changing file ownership arbitrarily | Rarely needed by application code directly; more common in provisioning/setup tooling |
| `CAP_DAC_OVERRIDE` | Bypassing file read/write/execute permission checks | Almost never legitimately needed by well-behaved application code — its presence is a strong hardening-review flag |
| `CAP_SYS_ADMIN` | An extremely broad, historically catch-all set of administrative operations | Almost never needed by an ordinary application service; its presence on a unit is worth specific scrutiny during any hardening review |
| `CAP_SYS_PTRACE` | Attaching to and inspecting other processes | Debugging/profiling tools specifically, not ordinary application logic |
| `CAP_SETUID`/`CAP_SETGID` | Changing the process's own UID/GID | Directly conflicts with the entire point of `NoNewPrivileges=` (Section 4.1) if granted alongside it — worth treating as mutually exclusive in practice |

`CAP_SYS_ADMIN` in particular is worth flagging as a specific red flag during any hardening review of an existing, unfamiliar unit file — its breadth is broad enough that a unit granting it has, in practice, restored a meaningful fraction of full root's own privilege scope, undermining much of the value the rest of this document's directive family would otherwise provide; encountering it on a unit during a review is a strong signal to investigate specifically *why* it was added, since the actual underlying need is very often narrower than this single, overly broad capability suggests and can frequently be satisfied by one of the more specific capabilities in this table instead.

### 4.4 `User=`/`DynamicUser=`, Revisited in the Security Context

`04-Unit-Files.md` Section 4.1 covered `User=`/`DynamicUser=` primarily as an identity/execution-context directive. In the security context specifically: running as a dedicated, unprivileged, single-purpose `User=` (or, stronger still, `DynamicUser=yes`, covered fully in Section 8) is foundational to nearly every other directive in this document actually mattering — a service still running as root gains comparatively little additional protection from `ProtectSystem=strict` or the capability restrictions above, since root's own broad, default privilege set overlaps substantially with exactly what those directives are trying to narrow; the security value of this entire directive family compounds specifically *on top of* an already-unprivileged base identity, not as a substitute for establishing one.

### 4.5 `RemoveIPC=`

```ini
[Service]
RemoveIPC=yes
```

Ensures any System V or POSIX IPC objects (shared memory segments, semaphores, message queues) owned by the unit's user are cleaned up when the unit stops — relevant specifically for `DynamicUser=`-based units (Section 8), where a dynamically-allocated UID's leftover IPC objects could otherwise persist and potentially be accessed by whatever UID happens to be dynamically allocated that same numeric value in some future, unrelated unit's own lifecycle, a narrow but genuine cross-unit information-leakage or resource-squatting concern this directive closes off directly.

---

## 5. System Call Filtering

### 5.1 The seccomp mechanism

The Linux kernel's `seccomp` (secure computing mode) facility allows a process to restrict which system calls it — and anything it execs — is permitted to invoke at all, with the kernel itself enforcing the restriction and returning an error (or terminating the process, depending on configuration) for anything outside the permitted set, entirely independent of whatever the process's own Unix privileges would otherwise allow. systemd's `SystemCallFilter=` is a high-level, unit-file-native interface onto this same underlying kernel mechanism, sparing the unit author from needing to hand-write the considerably lower-level BPF filter program seccomp actually consumes internally.

### 5.2 `SystemCallFilter=`

```ini
[Service]
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
```

Rather than requiring an exhaustive, hand-enumerated list of every individual syscall a given application legitimately needs — an genuinely difficult, error-prone exercise for any non-trivial application — systemd ships curated **syscall groups**, each representing a coherent category of related functionality:

| Group | Covers |
|---|---|
| `@system-service` | The broad set generally appropriate for an ordinary, non-privileged system service |
| `@network-io` | Socket and network-related calls |
| `@file-system` | File and directory operations |
| `@process` | Process creation and management |
| `@privileged` | Calls that only make sense for a genuinely privileged process — a strong candidate for explicit exclusion |
| `@raw-io` | Direct hardware I/O port access — almost never legitimately needed by an application service |
| `@reboot` | The `reboot()` family — legitimately needed by almost nothing outside init-adjacent tooling itself |
| `@swap` | Swap-management calls — similarly narrow in legitimate applicability |

```ini
[Service]
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @raw-io @reboot @swap
```

The second line here demonstrates the **negation** syntax — a leading `~` inverts the listed groups into an explicit *deny* list applied on top of whatever the first, positive `SystemCallFilter=` line already established, following the identical append-rather-than-override accumulation logic `02-Units-and-Dependencies.md` Section 3.2 established for list-like directives generally, applied here specifically to build up a filter through successive, individually-readable positive-and-negative layers rather than one single, monolithic expression.

`SystemCallErrorNumber=EPERM` governs what a filtered-out syscall attempt actually returns to the calling process — rather than the default, harsher `SIGSYS`-based process termination, returning an ordinary `EPERM` ("permission denied") error lets an application's own existing error-handling code path potentially degrade gracefully (logging a warning and continuing without whatever the blocked functionality would have provided) rather than crashing outright the instant it happens to touch a filtered syscall, which is frequently the more operationally desirable failure mode for a syscall restriction that's more defense-in-depth than an expected, routinely-triggered condition.

### 5.3 `SystemCallArchitectures=`

```ini
[Service]
SystemCallArchitectures=native
```

Restricts which CPU instruction-set architectures' syscall tables are even permitted to be invoked — `native` restricts to only the architecture the system is actually running on, closing off a specific, somewhat obscure but real attack technique where an exploit on a 64-bit system attempts to invoke the *32-bit* syscall table (still present in the kernel for compatibility on many systems) specifically because that older, less-scrutinized syscall table has historically had a track record of security-relevant differences and bugs relative to its 64-bit counterpart — a narrow but essentially free-to-apply restriction for any unit that doesn't specifically need to run 32-bit compatibility binaries.

### 5.4 Diagnosing a Syscall Filter Violation

An overly restrictive `SystemCallFilter=` is one of Section 1.3's cautioned-against costs made concrete — worth knowing precisely how it presents, since the failure mode is not always an obvious, self-explanatory error message from the application itself. With `SystemCallErrorNumber=` unset (the stricter, kernel-default behavior), a filtered syscall attempt terminates the process immediately via `SIGSYS`, which surfaces in the journal as an ordinary signal-based failure, not a filter-specific message:

```
systemd[1]: webapp.service: Main process exited, code=killed, status=31/SYS
systemd[1]: webapp.service: Failed with result 'signal'.
```

`status=31/SYS` is the specific signature to recognize here — `SIGSYS` is signal number 31, and its presence, particularly on a unit that was recently modified to add or tighten `SystemCallFilter=`, is a strong, specific indicator that a syscall the application genuinely needs was inadvertently excluded, rather than a generic application crash. The standard remediation sequence: temporarily set `SystemCallErrorNumber=EPERM` (Section 5.2) rather than removing the filter entirely, which converts the hard kill into a recoverable error the application's own error handling may partially surface, then correlate the timing of the failure against the application's own logging (`06-journald-and-Logging.md`'s full query vocabulary applies directly here) to identify which specific operation was attempted immediately prior, narrowing down which syscall group actually needs to be added back — `strace`, run against a non-hardened, otherwise-identical test instance of the same unit, is the more surgical tool for identifying the exact syscall by name once the general area of functionality has been narrowed this way.

---

## 6. Memory, Execution, and Namespace Restrictions

```ini
[Service]
MemoryDenyWriteExecute=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

### 6.1 `MemoryDenyWriteExecute=`

Prevents the process from creating a memory mapping that is simultaneously writable and executable — a foundational mitigation against an entire, historically extremely common class of memory-corruption exploit technique (writing attacker-controlled shellcode into a buffer, then executing it directly from that same, writable memory region). Legitimate applications essentially never need this combination — the exceptions are specifically JIT-compiling runtimes (some language VMs, certain database query engines) that genuinely do write machine code to memory and then execute it as a core part of their normal operation, for which this directive would need to be deliberately omitted or the JIT-generating component specifically exempted, making this a directive worth checking against the actual runtime in use before applying blindly, though for the overwhelming majority of ordinary application services (`webapp.service`'s own running example included, assuming no JIT-compiling language runtime is in play) it's safe, high-value, and essentially free.

### 6.2 `LockPersonality=`

Prevents the process from changing its own execution-domain "personality" (a Linux kernel mechanism historically used for compatibility with other Unix-like ABIs) — a narrow, rarely-legitimately-needed capability whose restriction closes off a further, relatively obscure exploitation-hardening bypass technique, at essentially zero cost to any ordinary application.

### 6.3 `RestrictRealtime=`

Prevents the process from requesting real-time CPU scheduling (`03-Service-Management.md` Section 4.4's `CPUSchedulingPolicy=fifo`/`rr` values) — appropriate for any service that has no legitimate need for real-time scheduling guarantees, closing off a potential denial-of-service angle where a compromised or simply misbehaving process could otherwise starve the rest of the system of CPU time by granting itself real-time priority.

### 6.4 `RestrictNamespaces=`

Prevents the process from creating **new** kernel namespaces of its own — relevant specifically against a compromised process attempting to escape or work around the very containment this document's own namespace-based directives (Sections 2–3) establish, by creating a fresh namespace of its own within which those restrictions might not automatically propagate. Can be set to `yes` (blocking all namespace creation) or scoped to specific namespace types the unit's legitimate function genuinely requires creating (`RestrictNamespaces=~user` to block only user-namespace creation specifically, for instance, while leaving others available).

### 6.5 `RestrictSUIDSGID=`

Prevents the process from creating new files with the `setuid`/`setgid` bits set — closing off a specific, classic Unix privilege-escalation persistence technique (planting a `setuid` root binary as a foothold for later, separate re-exploitation) that would otherwise remain available even under several of this document's other restrictions.

### 6.6 `RestrictAddressFamilies=`

Restricts which socket address families (`AF_INET`/`AF_INET6` for ordinary IPv4/IPv6 networking, `AF_UNIX` for local IPC, `AF_NETLINK` for kernel-userspace communication, and many more obscure ones) the process can create sockets in at all — for `webapp.service`'s own running example, `AF_INET AF_INET6 AF_UNIX` covers ordinary network service and local IPC needs entirely, while closing off the considerably larger remaining space of address families essentially no ordinary web application has any legitimate reason to touch, narrowing the kernel-level attack surface a network-facing exploit could pivot into.

---

## 7. Resource Control: cgroup-v2, in Full

`02-Units-and-Dependencies.md` Section 12 introduced `.slice` units and named `MemoryMax=`/`CPUQuota=` only in passing, deferring full treatment here. These directives, distinct from everything in Sections 2–6 above, are not primarily about containing a *compromised* process's blast radius — they're about preventing a merely *misbehaving* (buggy, or legitimately just resource-hungry under unusual load) process from starving the rest of the system, a related but genuinely different concern from this document's Section 1 threat model, addressed via the same underlying cgroup mechanism `01-Introduction.md` Section 9 established for process tracking.

### 7.1 Memory

```ini
[Service]
MemoryHigh=400M
MemoryMax=512M
```

`MemoryMax=` is a hard ceiling — the kernel's own out-of-memory killer is invoked specifically against this cgroup once it's exceeded, rather than the system-wide OOM killer making a more generic, potentially worse-informed choice among competing processes system-wide. `MemoryHigh=`, set below `MemoryMax=`, is a **soft** throttling point — exceeding it causes the kernel to apply increasing memory-reclaim pressure specifically against this cgroup (reclaiming page-cache pages, throttling allocations) without an outright kill, giving a service a chance to shed load or otherwise recover before the harder `MemoryMax=` ceiling is actually reached — the two directives working together as a graduated response rather than a single, binary threshold.

### 7.2 CPU

```ini
[Service]
CPUQuota=150%
CPUWeight=200
```

`CPUQuota=` is an absolute ceiling, expressed as a percentage of one CPU core — `150%` permits this unit's cgroup to consume at most the equivalent of one and a half cores' worth of CPU time, even on an otherwise entirely idle machine with many more cores available, a hard cap rather than a relative share. `CPUWeight=` (default `100`, on a scale where higher values receive proportionally more CPU time *relative to other cgroups* only during genuine contention) is a fundamentally different mechanism — it does nothing at all on an idle system where no other cgroup is competing for CPU time, only affecting the *relative* allocation once genuine contention actually occurs, making the two directives complementary rather than redundant: `CPUQuota=` bounds worst-case consumption unconditionally, while `CPUWeight=` shapes fair-sharing behavior specifically under contention.

### 7.3 I/O

```ini
[Service]
IOWeight=200
IOReadBandwidthMax=/dev/sda 50M
IOWriteBandwidthMax=/dev/sda 20M
```

`IOWeight=` mirrors `CPUWeight=`'s relative, contention-only behavior applied to disk I/O bandwidth instead of CPU time. `IOReadBandwidthMax=`/`IOWriteBandwidthMax=` are absolute, per-device throughput ceilings — directly useful for preventing a single unit's I/O-heavy operation (a backup job, notably, tying directly back to `07-Timers-and-Scheduled-Tasks.md`'s own worked backup-timer example) from saturating shared storage bandwidth to the point of starving every other unit's own I/O needs during the window it's actively running.

### 7.4 `TasksMax=`

```ini
[Service]
TasksMax=512
```

Caps the total number of processes/threads the unit's cgroup is permitted to contain simultaneously — a direct, effective guard against a fork-bomb-style failure mode (whether from a genuine bug or a successful exploit attempting exactly this as a denial-of-service technique), where an uncontrolled process consumes the kernel's entire process-table capacity system-wide; capping it per-unit contains that failure mode to just this one unit's own cgroup rather than allowing it to exhaust a shared, system-wide resource other, entirely unrelated units also depend on.

---

## 8. `DynamicUser=`, Revisited in Full Depth

`04-Unit-Files.md` Section 4.1 introduced `DynamicUser=yes` briefly. It's worth a complete treatment here, at the point in this series where its actual security rationale can be stated against the full threat model established in Section 1.

```ini
[Service]
DynamicUser=yes
StateDirectory=webapp
```

Recall the core mechanism: systemd allocates a fresh, transient UID/GID for the unit's entire lifetime, with no static `/etc/passwd` entry — created at start, released at stop. Combined with `StateDirectory=` (`04-Unit-Files.md` Section 4.7), any persistent data the service needs to write survives correctly across restarts (since `StateDirectory=`'s own contents persist independent of the specific dynamically-allocated UID that happened to own them at any given moment, with systemd itself handling the ownership re-assignment transparently across restarts), while the UID itself does not persist as a fixed, guessable, or otherwise-reusable identity between invocations.

### 8.1 Why this specifically matters against Section 1's threat model

A traditional, static system account (`useradd --system webapp`) is a **permanent, standing** identity — any file anywhere on the filesystem that happens to be owned by that UID remains accessible to any future process also running as that same, fixed UID, indefinitely, including a process entirely unrelated to the original service that merely happens to later be configured with the identical static username. `DynamicUser=yes`'s transient allocation means a compromised process that manages to leave a malicious file behind, owned by its dynamically-allocated UID, finds that UID released and not guaranteed to be reused by anything at all once the unit stops — and even in the case where it happens to be reallocated to some *other*, unrelated dynamic-UID unit's own future invocation, `RemoveIPC=`'s IPC-specific cleanup (Section 4.5) and the generally narrow, `StateDirectory=`-scoped writable footprint `ProtectSystem=strict` (Section 2.1) already encourages combine to minimize what a leftover, unexpectedly-reused UID could actually still access.

### 8.2 Combining `DynamicUser=` with the rest of this document

`DynamicUser=yes` is best understood as the identity-layer foundation Section 4.4 described — it composes directly and cleanly with every other directive in this document rather than substituting for any of them: `ProtectSystem=strict` still narrows the writable filesystem footprint of whatever dynamic UID happens to be active at any given moment; `CapabilityBoundingSet=`/`AmbientCapabilities=` still govern what that dynamic UID's process can ever hold; `SystemCallFilter=` still restricts its syscall surface identically regardless of whether the UID backing the process is static or dynamic. The worked example in Section 11 applies `DynamicUser=yes` as one layer within a broader, cumulative hardening pass, not as a standalone substitute for the rest of this document's directive family.

---

## 9. `systemd-analyze security`: Automated Exposure Scoring

```bash
systemd-analyze security webapp.service
```

```
  NAME                                        DESCRIPTION                                     EXPOSURE
✓ PrivateNetwork=                              Service has no access to the host's network      
✗ User=/DynamicUser=                           Service runs as root                           0.4
✗ CapabilityBoundingSet=~CAP_SYS_ADMIN          Service has CAP_SYS_ADMIN                       0.3
✓ ProtectHome=                                 Service has no access to home directories
...
→ Overall exposure level for webapp.service: 6.8 MEDIUM
```

`systemd-analyze security` inspects a unit's **currently-configured** directives from this entire document and produces both a per-check pass/fail (`✓`/`✗`) breakdown and one consolidated exposure score (0, minimal exposure, through 10, maximal exposure) — a direct, automated way to get a rough, aggregate read on a unit's hardening posture without manually cross-referencing every directive in Sections 2–8 by hand against what's actually present in the unit file.

### 9.1 What the score is and is not

The score is a **heuristic aggregate**, weighted according to systemd's own judgment of each individual check's relative security significance — a genuinely useful starting point and regression-detection tool (comparing a unit's score before and after a hardening pass, or catching a score *regression* if a later, unrelated change accidentally removes a previously-applied restriction), but not a certification or a substitute for the kind of considered, threat-model-aware reasoning Section 1 described. A unit could score well while still containing a directly exploitable vulnerability entirely orthogonal to anything this scoring mechanism measures (a SQL injection flaw, for instance, which no combination of the directives in this document does anything to prevent, since it's an application-logic flaw, not a containment gap this entire directive family addresses). Treat the score as one useful, automatable signal among several, not as the sole measure of whether a unit is "secure."

### 9.2 `--no-pager` and scripting

```bash
systemd-analyze security --no-pager webapp.service | grep EXPOSURE
systemd-analyze security --json=pretty webapp.service
```

The `--json=` output mode is the standard integration point for incorporating this scoring into an automated CI/CD pipeline's own hardening-regression check — failing a build or deployment specifically if a unit's exposure score crosses some organizationally-chosen threshold, or if a specific, individually-critical check (`NoNewPrivileges=`, say) regresses from passing to failing, catching an accidental hardening rollback before it reaches production rather than relying on a human noticing during code review.

---

## 10. A Fully Worked Example: Incremental Hardening of `webapp.service`

Applying Section 1.3's incremental-verification principle directly, starting from the plain, unhardened `webapp.service` this series has used as its running example since `01-Introduction.md`, and layering in this document's directives in deliberate, individually-verifiable stages.

**Baseline (from `03-Service-Management.md` Section 13):**

```ini
[Service]
Type=notify
User=webapp
WorkingDirectory=/srv/webapp
ExecStart=/srv/webapp/bin/serve
Restart=on-failure
```

**Stage 1 — cheap, essentially risk-free additions:**

```ini
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictRealtime=yes
```

Per Section 1.3, this stage is deployed and verified first — restarting `webapp.service` and confirming, via `systemctl status` and a functional smoke test against the application itself, that nothing has broken, before proceeding. This stage alone, in practice, resolves the large majority of a typical `systemd-analyze security` score improvement, since these specific directives are broadly applicable to almost any ordinary service with essentially no legitimate functionality depending on the capabilities they remove.

**Stage 2 — namespace and writable-path exceptions, requiring the application's actual filesystem needs to be known:**

```ini
StateDirectory=webapp
CacheDirectory=webapp
LogsDirectory=webapp
ReadWritePaths=/srv/webapp/uploads
PrivateDevices=yes
PrivateTmp=yes
RestrictNamespaces=yes
```

This stage requires actually knowing `webapp.service`'s genuine writable-path needs — arrived at either from documentation, from the application's own source, or empirically by first deploying `ProtectSystem=strict` alone and observing exactly which specific write attempts fail in the resulting journal output (`06-journald-and-Logging.md`'s own query vocabulary directly applicable here: `journalctl -u webapp.service -p err` immediately after this stage's deployment surfaces any permission-denied failures pointing precisely at whichever path still needs an explicit `ReadWritePaths=` exception).

**Stage 3 — privilege and syscall-surface restriction:**

```ini
DynamicUser=yes
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @raw-io @reboot @swap @debug
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryDenyWriteExecute=yes
```

Note `CapabilityBoundingSet=` here is set to an **empty** value — since `webapp.service`, per this series' own running example, has never needed to bind a privileged low port (having always run behind a reverse proxy handling the actual public-facing 443/80 binding, an assumption worth stating explicitly since a different deployment topology binding those ports directly would instead need Section 4.2's `AmbientCapabilities=CAP_NET_BIND_SERVICE` pairing), an entirely empty bounding set is achievable, removing every capability without exception, the strongest available position on this specific axis.

**Stage 4 — resource-control ceiling, closing out the pass:**

```ini
MemoryHigh=400M
MemoryMax=512M
CPUQuota=200%
TasksMax=256
```

**Final verification:**

```bash
systemd-analyze security webapp.service
journalctl -u webapp.service --since "10 minutes ago" -p warning
```

Confirming both the aggregate exposure score's improvement (Section 9) and, per Section 1.3's core principle, that no functional regression was introduced at any stage — the four-stage structure itself, rather than applying every directive from Sections 2–8 in one single, un-staged deployment, is what makes root-causing any single stage's specific breakage (were one to occur) a matter of reviewing that one stage's small, recently-added directive set, rather than an undifferentiated debugging exercise against dozens of simultaneously-introduced changes.

---

## 11. Common Anti-Patterns

**Applying `ProtectHome=yes` or `PrivateNetwork=yes` as a blanket default without checking actual applicability.** As covered in Sections 2.2 and 3.2, the former is nearly always safe for an ordinary service, while the latter is only appropriate for a genuinely network-independent unit — conflating the two risk profiles and applying both indiscriminately is a common source of an immediate, easily-avoidable functional break for any service that does, in fact, need network access.

**Deploying the entire directive family in one single, un-staged change.** As covered in Section 1.3 and demonstrated by Section 10's four-stage structure, this makes root-causing whichever specific directive broke functionality (if any did) a considerably harder, undifferentiated debugging exercise than it needs to be.

**Treating `systemd-analyze security`'s numeric score as a certification rather than a heuristic.** As covered in Section 9.1, the score says nothing about application-logic vulnerabilities entirely outside this directive family's own scope — a high (good) score is not evidence of general security, only evidence of reasonable containment configuration specifically within the dimensions this tool measures.

**Running as a static, permanent system account when `DynamicUser=yes` would suffice.** As covered in Section 8.1, a standing, reusable UID carries a genuine, if often overlooked, persistence-and-cross-contamination risk relative to the transient-allocation alternative, for services with no specific, static-UID-dependent requirement (a fixed UID some external system explicitly expects, for instance) forcing the traditional approach instead.

**Setting `MemoryDenyWriteExecute=yes` on a JIT-compiling runtime without accounting for its actual requirements.** As covered in Section 6.1, this specific directive directly conflicts with how JIT compilation fundamentally works — applying it blindly to every service regardless of runtime produces an immediate, hard failure for exactly the class of application this exception matters for, rather than the graceful, no-op-if-unnecessary behavior most of this document's other directives exhibit when applied to a service that simply doesn't happen to need the specific capability being restricted.

**Confusing `CPUQuota=`'s absolute ceiling with `CPUWeight=`'s relative, contention-only behavior.** As covered in Section 7.2, setting only `CPUWeight=` produces no effect at all on an otherwise-idle machine, which can read as the directive simply "not working" to an administrator expecting an absolute cap — the two serve genuinely different purposes and are not interchangeable.

---

## 12. Exercises

**1.** A service has `ProtectSystem=strict` with no accompanying `ReadWritePaths=` or `StateDirectory=`, and its own application code attempts to write a log file directly to `/var/log/webapp-custom.log`. What happens? *(Per Section 2.1, `ProtectSystem=strict` makes the entire filesystem hierarchy read-only except explicitly exempted paths — the write attempt fails with a permission error, since `/var/log/webapp-custom.log` was never declared via `LogsDirectory=`, `ReadWritePaths=`, or any other exemption mechanism; the fix is either redirecting the application's logging through the native journal per `06-journald-and-Logging.md`, or adding an explicit `LogsDirectory=`/`ReadWritePaths=` exception for that specific path.)*

**2.** A service sets `AmbientCapabilities=CAP_NET_BIND_SERVICE` but omits `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` entirely (leaving the bounding set at its unrestricted default). Does the service successfully bind a privileged port? *(Yes — the two directives serve different roles per Section 4.2/4.3: `AmbientCapabilities=` alone is sufficient to actually grant the capability to an unprivileged process; `CapabilityBoundingSet=` is what narrows the *ceiling*, and its omission here doesn't prevent the grant, it only means the bounding set remains broader than strictly necessary — a missed hardening opportunity, not a functional break.)*

**3.** `DynamicUser=yes` is set on a service with no `StateDirectory=` at all, and the application writes persistent data directly to a hardcoded `/var/lib/webapp-data/` path it creates itself at startup. What is the likely long-term consequence? *(Per Section 8, without `StateDirectory=` telling systemd to manage ownership continuity across the dynamically-allocated UID's changes between restarts, the directory ends up owned by whatever UID happened to be dynamically allocated during the run that created it — a *subsequent* restart, receiving a different dynamically-allocated UID, may then be unable to write to that same directory at all, since it no longer owns it; the fix is declaring `StateDirectory=webapp` so systemd itself handles the ownership re-assignment correctly across the UID rotation.)*

**4.** `systemd-analyze security` reports a low (good) exposure score for a service, and separately, that service is found to have a SQL injection vulnerability in its own request-handling code. Does the low exposure score indicate this vulnerability shouldn't exist? *(No — per Section 9.1, the scoring mechanism measures containment-directive configuration only, entirely orthogonal to application-logic vulnerabilities like SQL injection; a well-hardened unit can still contain arbitrary application-level flaws the scoring tool has no visibility into at all, since sandboxing directives constrain what a compromised process can *do*, not whether the application's own logic can be *exploited* in the first place.)*

**5.** A backup job's unit has `IOReadBandwidthMax=/dev/sda 50M` set, and during a nightly run, other units on the same machine performing disk I/O against `/dev/sda` are observed to run measurably faster than usual during exactly that window. Is this consistent with the directive's documented behavior? *(Yes — per Section 7.3, `IOReadBandwidthMax=` caps only *this specific unit's* read throughput against the named device; it does nothing to guarantee bandwidth *for* other units, but by capping this one unit's own consumption, more of the shared device's total bandwidth capacity is left available for everything else contending for it during the same window, which is precisely the intended, if secondary, benefit of applying a per-unit ceiling to a historically resource-hungry job like a backup.)*

**6.** A unit is found during a security review to have `AmbientCapabilities=CAP_SYS_ADMIN`, inherited from a much older configuration nobody can immediately explain the reason for. Per this document's own guidance, what is the appropriate next step? *(Per Section 4.2a's specific flag on `CAP_SYS_ADMIN`, the appropriate step is treating this as a priority investigation item — determining what specific, narrower functionality the original author was actually trying to enable, and very likely replacing the broad grant with one of the considerably narrower capabilities from the reference table that actually covers the genuine underlying need, rather than either leaving an unexplained broad grant in place or removing it blindly without confirming nothing legitimately depends on it.)*

**7.** A unit's journal shows `Main process exited, code=killed, status=31/SYS` immediately after a `SystemCallFilter=` was added to its configuration. What is the most direct, surgical next diagnostic step? *(Per Section 5.4, temporarily setting `SystemCallErrorNumber=EPERM` converts the hard kill into a potentially more informative, recoverable error surfaced through the application's own logging, and running `strace` against a non-hardened, otherwise-identical test instance of the same unit is the most direct way to identify the specific excluded syscall by name, rather than guessing at which syscall group to broaden based on the terse `status=31/SYS` signature alone.)*

---

## 13. Pre-Deployment Checklist

Mirroring the checklists established across this series, adapted to hardening changes specifically — genuinely higher-stakes than most other configuration changes in this series, since an overly aggressive hardening pass fails closed (breaking functionality) while an insufficiently aggressive one fails open (leaving unnecessary exposure), and distinguishing which failure mode a given change risks is itself part of the review:

1. **Apply this document's directive family incrementally, in verifiable stages, per Section 1.3 and Section 10's worked structure** — never as one single, un-staged deployment, regardless of how confident the reviewer is that every directive is individually correct.
2. **Run `systemd-analyze security` before and after each stage**, per Section 9, treating a regression in the aggregate score (not just individual check failures) as worth investigating even when the unit otherwise appears to be functioning correctly.
3. **For any `SystemCallFilter=` addition, deploy first with `SystemCallErrorNumber=EPERM` rather than the harsher default kill behavior**, per Section 5.4, specifically to make an incorrectly-excluded syscall's failure mode more diagnosable during the initial verification window, tightening to the stricter default only once the filter itself has been confirmed correct under real load.
4. **Before applying `ProtectSystem=strict`, identify the service's actual writable-path needs empirically if not already documented** — per Section 10's Stage 2, deploying `ProtectSystem=strict` alone first and reading the resulting `journalctl -u <unit> -p err` output for permission-denied failures is a reliable way to discover the genuine, complete set of `ReadWritePaths=`/`StateDirectory=` exceptions needed, rather than guessing upfront and iterating reactively against production failures.
5. **Treat any unit found holding `CAP_SYS_ADMIN` or `CAP_DAC_OVERRIDE` during a review as a specific investigation priority**, per Section 4.2a, rather than a routine item — these two capabilities in particular tend to indicate either a genuine, narrow need that could be served by a more specific capability instead, or a historical grant nobody has revisited since.
6. **Confirm `DynamicUser=yes` is paired with `StateDirectory=` (or an equivalent explicit ownership-continuity mechanism) for any unit that writes persistent data**, per Section 8 and Exercise 3 — omitting this pairing is a delayed-onset failure mode that may not surface until the *second* or *third* restart, well after initial deployment appeared to succeed.

---

## 14. Quick-Reference Table

| Directive | Section | Restricts |
|---|---|---|
| `ProtectSystem=` / `ProtectHome=` | 2.1–2.2 | Broad filesystem read-only/inaccessible defaults |
| `ReadWritePaths=` / `InaccessiblePaths=` | 2.3 | Fine-grained exceptions to the above |
| `PrivateDevices=` / `PrivateNetwork=` / `PrivateUsers=` | 3.1–3.3 | Isolated views of devices, network, and UID/GID space |
| `ProtectKernelTunables=` / `ProtectKernelModules=` / `ProtectKernelLogs=` | 3.4–3.5 | Kernel-level configuration and logging surfaces |
| `NoNewPrivileges=` | 4.1 | `setuid`/file-capability privilege escalation |
| `CapabilityBoundingSet=` / `AmbientCapabilities=` | 4.2–4.3 | The ceiling and grant of Linux capabilities |
| `SystemCallFilter=` / `SystemCallArchitectures=` | 5 | The seccomp-enforced syscall surface |
| `MemoryDenyWriteExecute=` | 6.1 | Writable+executable memory mappings |
| `RestrictNamespaces=` / `RestrictSUIDSGID=` | 6.4–6.5 | Namespace creation and `setuid`/`setgid` file creation |
| `RestrictAddressFamilies=` | 6.6 | Which socket address families can be used |
| `MemoryMax=` / `MemoryHigh=` | 7.1 | cgroup-enforced memory ceiling and soft throttle point |
| `CPUQuota=` / `CPUWeight=` | 7.2 | Absolute CPU ceiling versus contention-relative share |
| `TasksMax=` | 7.4 | Total process/thread count within the unit's cgroup |
| `DynamicUser=` | 8 | Transient, non-persistent UID/GID allocation |
| `systemd-analyze security` | 9 | Automated, heuristic exposure scoring |

---

## 15. Glossary

**Blast radius** — the scope of what a successful exploit inside a sandboxed process can actually reach or affect, the core quantity this entire document's directive family works to minimize.
**Defense in depth** — the principle that several independent, layered restrictions provide stronger containment together than any single restriction alone.
**Capability** — one of several dozen individually-grantable subdivisions of traditional Unix root privilege, restricted via `CapabilityBoundingSet=` and granted via `AmbientCapabilities=`.
**seccomp** — the kernel facility restricting which system calls a process may invoke, exposed via `SystemCallFilter=`.
**Exposure score** — `systemd-analyze security`'s heuristic, aggregate 0–10 rating of a unit's hardening-directive configuration.
**Dynamic allocation** — the transient, non-persistent UID/GID assignment `DynamicUser=yes` provides, existing only for the unit's own current invocation lifetime.
**Fail closed / fail open** — whether an overly aggressive restriction breaks legitimate functionality (closed) versus an insufficiently aggressive one leaves unnecessary exposure (open), the two risk directions any hardening change must be weighed against.
**Incremental hardening pass** — applying this document's directive family in verifiable stages, per Section 1.3, rather than as one single, undifferentiated change.

---

## 16. What's Ahead

This document concludes the architectural and configuration-focused portion of this series. `09-Troubleshooting.md` shifts to systematic diagnosis — bringing together the failure-tracing methods introduced piecemeal throughout this series (`02-Units-and-Dependencies.md` Section 13.1's `result 'dependency'` propagation, `03-Service-Management.md` Section 13's restart/watchdog timelines, `05-Boot-Process-and-Targets.md` Section 8.4's emergency-target diagnosis, `06-journald-and-Logging.md`'s full query vocabulary) into one consolidated, general-purpose diagnostic methodology, including how a hardening directive from this document itself — an overly restrictive `SystemCallFilter=` or a missing `ReadWritePaths=` exception — presents and is correctly identified as the root cause of an otherwise-mysterious unit failure.

---

## References

- `systemd.exec(5)` — the complete sandboxing-directive reference this document expands on
- `systemd.resource-control(5)` — the complete cgroup-based resource-control directive reference
- `capabilities(7)` — the Linux capabilities mechanism underlying Section 4
- `seccomp(2)` — the kernel facility underlying `SystemCallFilter=`
- `systemd-analyze(1)` — the `security` subcommand's complete reference
- `user_namespaces(7)` — the kernel mechanism underlying `PrivateUsers=`
