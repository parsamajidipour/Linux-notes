# systemd-journald

Chapter 1 introduced `journald` as one of several coexisting logging mechanisms and flagged its structured, binary storage as architecturally consequential. This chapter delivers the full mechanism: how the journal actually stores data, the volatile-versus-persistent distinction that determines whether logs survive a reboot at all, the complete field model that makes structured querying possible, and the `journalctl` interface in the depth this series' style demands.

---

## 1. What journald Actually Is

`systemd-journald` is a system service, started early in the boot sequence by `systemd` itself, whose job is to **collect log data from multiple sources and write it into a structured, indexed, binary-format storage system** called the journal. It is not merely a file-writer in the traditional syslog sense — it is closer to a lightweight, append-only, indexed event database, purpose-built for log data specifically, and this distinction is the root of nearly every capability difference between `journalctl`-based querying and traditional flat-file log inspection.

### 1.1 The Sources journald Collects From

Directly extending Chapter 1, Section 4's source/transport/sink framing, journald acts as a transport for several distinct sources simultaneously:

- **The kernel ring buffer** (Chapter 5's subject) — journald reads kernel messages and incorporates them into the unified journal, though the ring buffer itself continues to exist and remains independently readable via `dmesg`, exactly as Chapter 1, Section 3 established; journald's kernel-message ingestion is additive, not a replacement for the ring buffer's own independent existence.
- **`systemd` unit stdout/stderr** — every service started under `systemd` has its standard output and standard error streams captured directly by journald by default, without the service itself needing to have any logging-library awareness at all (covered in full in Chapter 6's discussion of well-behaved service logging conventions).
- **The native journal API** (`sd_journal_print()` and related calls) — applications that want to submit *structured*, field-rich log entries directly, bypassing plain-text stdout capture entirely, can link against `libsystemd` and write directly into the journal's structured format.
- **The traditional syslog socket** (`/dev/log`) — journald listens on this socket as well, meaning applications written decades before journald existed, using the traditional `syslog()` C library call, continue to have their output captured without any modification, a deliberate backward-compatibility design choice.
- **The audit subsystem** (Chapter 7's subject) — audit events can also be routed into the journal, though the audit subsystem additionally maintains its own independent, specialized storage, covered fully in its own chapter.

This multi-source collection model is worth holding as the single most important structural fact about journald: it is a **unification point**, deliberately designed to gather data from every one of these historically separate origins into one queryable store, rather than being merely one more isolated logging mechanism sitting alongside the others.

---

## 2. Volatile Versus Persistent Storage: The Single Most Consequential Configuration Decision

This is the journald behavior most responsible for a specific, common and frustrating discovery — "my logs are gone after a reboot" — and it deserves to be explained precisely rather than treated as an inconvenient default to simply work around without understanding.

### 2.1 The Two Possible Storage Locations

Journald can store its data in one of two locations, controlled by the `Storage=` directive in `/etc/systemd/journald.conf`:

```
/run/log/journal/     — volatile: tmpfs-backed, memory, lost on reboot
/var/log/journal/     — persistent: disk-backed, survives reboot
```

`/run` is, on virtually every modern distribution, a `tmpfs` mount — a filesystem backed entirely by RAM, not by any persistent disk storage, meaning anything written there is genuinely, unrecoverably gone the moment the system loses power or reboots, in exactly the same way any other in-memory data structure would be. This is a deliberate design choice, not an oversight: writing to `tmpfs` is dramatically faster than writing to disk, and for a system where log persistence across reboots genuinely isn't a requirement (a minimal container, for instance, whose entire filesystem is itself ephemeral by design), volatile-only journal storage is both a reasonable and a resource-conscious default.

### 2.2 The Default Behavior, and Why It Surprises People

Journald's actual default behavior, worth stating precisely because it is more nuanced than either "always volatile" or "always persistent": if the directory `/var/log/journal/` **already exists** at journald's startup, it uses persistent, disk-backed storage there; if that directory does **not** exist, it falls back to volatile, `tmpfs`-backed storage under `/run/log/journal/` instead. This is why the single most common "fix" for the "my logs vanish on reboot" surprise is simply:

```
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
```

This doesn't require any configuration file edit at all in most cases — the mere *existence* of the directory, checked at journald's own startup, is what determines which storage mode gets used, a detail worth understanding precisely rather than assuming persistent storage requires an explicit configuration change, since on many distributions it requires nothing more than the directory's presence.

The `Storage=` directive itself can also be set explicitly to force one mode or the other regardless of directory existence:

```
Storage=volatile     # always /run, regardless of /var/log/journal existing
Storage=persistent    # always /var/log/journal, creating it if necessary
Storage=auto          # the default, existence-dependent behavior described above
Storage=none           # disable local journal storage entirely (e.g., pure forward-only configurations, relevant to Chapter 9)
```

### 2.3 Why This Design Choice Makes Sense

It's worth connecting this back to Chapter 1, Section 1's core tension between cheap/fast logging and durable/queryable storage. Volatile storage is journald's answer to workloads that need journald's rich structured-query capability *during* a system's uptime — active troubleshooting, live monitoring — without paying the ongoing disk I/O cost of persisting every single log entry, appropriate for systems where post-reboot historical log access genuinely isn't a requirement. Persistent storage trades that efficiency for the ability to review logs from before the most recent boot at all — including, critically, logs from a boot that ended in a crash, which is precisely the scenario where reviewing prior-boot logs is most valuable and volatile-only storage would have already discarded the exact evidence needed.

---

## 3. The Structured Field Model

This section is where Chapter 1, Section 5's structured-versus-unstructured distinction becomes concrete and mechanical, because understanding the actual field model is what makes `journalctl`'s query capabilities (Section 5) predictable rather than feeling like a list of memorized flag combinations.

### 3.1 Every Journal Entry Is a Set of Key-Value Fields

Unlike a traditional syslog line — a single string with an implicit, positionally-parsed structure (timestamp, then hostname, then program name, then message, all concatenated) — a journal entry is genuinely, internally a collection of named fields, each an independent key-value pair. A single entry might carry:

```
MESSAGE=Failed to start nginx.service
PRIORITY=3
_SYSTEMD_UNIT=nginx.service
_PID=4821
_UID=0
_GID=0
_COMM=systemd
_HOSTNAME=web01
_BOOT_ID=8f3e2a1c9b4d4e2a...
__REALTIME_TIMESTAMP=1721404800123456
__MONOTONIC_TIMESTAMP=48291023841
```

### 3.2 Trusted Versus Untrusted Fields

Worth calling out a distinction that has genuine security relevance, previewing themes Chapter 7 develops further: fields prefixed with a leading underscore (`_PID`, `_UID`, `_SYSTEMD_UNIT`, and others) are **trusted fields**, added directly by journald itself, based on information it independently verifies about the sending process (via the kernel's own credential-reporting mechanisms for the socket connection, not based on anything the sending process merely claims about itself). Fields without a leading underscore, like `MESSAGE` and `PRIORITY`, are supplied by the logging source itself and are **not independently verified** — a process can claim any `PRIORITY` value or write any `MESSAGE` content it likes, but it cannot forge its own `_PID` or `_UID`, since those are stamped by journald based on the actual, kernel-verified identity of the connection, exactly analogous in spirit to the permissions series' repeated distinction between what a process claims about itself and what the kernel independently verifies. This trusted/untrusted split is precisely why security-relevant filtering and analysis (Chapter 7, Chapter 8) should generally prefer trusted, underscore-prefixed fields wherever verifying actual origin matters, rather than relying on message content or self-reported fields that could, in principle, be spoofed by a compromised or malicious process.

### 3.3 Special Double-Underscore Fields

A small number of fields use a double-underscore prefix (`__REALTIME_TIMESTAMP`, `__MONOTONIC_TIMESTAMP`, `__CURSOR`) and represent metadata about the entry's storage itself rather than data about the logged event's content or origin. `__CURSOR` in particular deserves explicit mention: it's an opaque, stable identifier for a specific entry's exact position within the journal, and is the correct mechanism for resuming a query from a known point (`journalctl --after-cursor=...`), rather than attempting to resume based on timestamp alone, which — per Chapter 1, Section 7's clock-precision discussion — can be ambiguous when multiple entries share an identical timestamp at the precision available.

### 3.4 Why This Field Model Enables Genuinely Different Query Capability

The direct payoff of this entire structural model: querying "every log entry from this specific systemd unit, at this specific priority or worse, within this specific time range" is, under journald's structured model, a matter of filtering on the exact fields that directly represent those criteria (`_SYSTEMD_UNIT`, `PRIORITY`, and the timestamp range) — a precise, reliable operation. The equivalent query against an unstructured flat-text log file requires constructing a regular expression that happens to correctly match the specific textual convention that specific log's messages follow for representing unit name and severity — a fundamentally less reliable operation, since it depends entirely on the log's own text formatting having been consistent and unambiguous enough for the regex to correctly and completely capture the intended criteria, with no structural guarantee that it actually does.

---

## 4. Journal File Storage Internals

### 4.1 Binary, Not Plain Text

Journal files (with a `.journal` extension, stored under `/var/log/journal/<machine-id>/` in persistent mode) are **binary**, not human-readable plain text — a deliberate departure from the traditional syslog flat-file convention, and one that has real, worthwhile trade-offs to understand rather than treat as an obstacle. The binary format supports indexing (fast lookups by field value, without a full linear scan of the entire log), built-in optional compression, and, notably, **built-in support for tamper-evidence via Forward Secure Sealing** (Section 6), none of which a traditional append-only plain-text file structure can support natively.

The direct, practical consequence: journal files cannot be meaningfully inspected with `cat`, `grep`, or `tail` in any useful way — they require `journalctl` (or a compatible tool that understands the binary format) as the query interface, a genuinely different operational habit from traditional flat-file log inspection, and worth internalizing early rather than reaching instinctively for text tools that simply won't produce useful output against a `.journal` file.

### 4.2 Per-Boot Segmentation

Journal data is organized, in significant part, around **boot IDs** — a unique identifier generated fresh at every single boot, distinguishing which specific boot session any given entry belongs to. This directly enables one of `journalctl`'s most commonly used capabilities, previewed in Section 2.3's crash-diagnosis motivation:

```
journalctl -b            # current boot only
journalctl -b -1         # the previous boot
journalctl --list-boots  # enumerate every boot the journal has retained data for
```

This per-boot organization is precisely what makes reviewing "what happened during the boot that crashed, right up until the crash itself" a clean, well-defined query, rather than requiring the administrator to manually estimate a timestamp range and hope it correctly brackets the relevant boot session.

### 4.3 Size Management and Rotation

Journal files rotate and are subject to size and retention limits configured in `journald.conf`, previewing material Chapter 4 covers in full generality across both journald and traditional logrotate-based rotation:

```
SystemMaxUse=4G
SystemKeepFree=1G
MaxRetentionSec=1month
```

Worth flagging here specifically because it connects directly to Section 2's persistent-storage discussion: without sensible limits configured, a persistently-stored journal can, in principle, grow to consume a genuinely problematic fraction of available disk space over a long-uptime system's lifetime — precisely the kind of disk-exhaustion failure mode Chapter 4 examines as a dedicated topic, worth being aware of as a real operational risk specifically introduced by choosing persistent over volatile storage, rather than an entirely cost-free upgrade.

---

## 5. The journalctl Query Interface, in Depth

### 5.1 Basic Invocation Patterns

```
journalctl                          # entire journal, oldest to newest
journalctl -e                       # jump to the end, most recent entries
journalctl -f                       # follow mode, directly analogous to tail -f
journalctl -n 50                    # last 50 entries
journalctl --since "1 hour ago"     # relative time filtering
journalctl --since "2026-07-19 08:00:00" --until "2026-07-19 09:00:00"
```

### 5.2 Field-Based Filtering: The Direct Payoff of Section 3's Model

```
journalctl _SYSTEMD_UNIT=nginx.service
journalctl _UID=0
journalctl PRIORITY=3
journalctl _PID=4821
```

Multiple field filters on the same field are treated as a logical OR (matching entries with *any* of the specified values for that field); filters across *different* fields are combined as a logical AND — worth stating explicitly since this asymmetry, while logical once understood, is not the only reasonable interpretation a newcomer might assume, and getting it backward produces queries that silently return either far too much or far too little:

```
journalctl _SYSTEMD_UNIT=nginx.service _SYSTEMD_UNIT=postgresql.service
# entries from EITHER unit (OR, same field)

journalctl _SYSTEMD_UNIT=nginx.service PRIORITY=3
# entries from nginx.service AND at priority 3 (AND, different fields)
```

### 5.3 Priority Filtering

Directly using Chapter 1, Section 6's shared severity vocabulary:

```
journalctl -p err              # priority "err" (3) and everything more severe (0-3)
journalctl -p warning..err     # a specific range, warning (4) through err (3)
```

Worth noting explicitly: a single `-p LEVEL` argument, without a range, means "this level and everything *more* severe" (i.e., numerically lower, per Chapter 1's inverted-scale warning), not "exactly this level alone" — a default worth confirming precisely rather than assuming, since it directly affects how much data a seemingly narrow-looking filter actually returns.

### 5.4 Output Formats

```
journalctl -o json                # one JSON object per line
journalctl -o json-pretty         # human-readable, indented JSON
journalctl -o verbose             # every field, including trusted underscore-prefixed ones, fully expanded
journalctl -o cat                 # message text only, no metadata — closest to traditional flat-log appearance
```

The `-o json` family deserves specific attention because it is the direct bridge to Chapter 9's centralized-logging material — shipping journal data to an external aggregation system very commonly means piping or exporting journalctl's JSON output into whatever ingestion format the centralized system expects, making this output mode considerably more than a cosmetic display option.

### 5.5 Combining Filters With Boot and Time Scoping

```
journalctl -b -1 -p err --since "yesterday"
```

Every filter type covered above composes freely — boot scoping (Section 4.2), priority filtering (Section 5.3), time range (Section 5.1), and field matching (Section 5.2) are all simultaneously applicable in a single invocation, each narrowing the result set independently, directly reflecting the fact that every one of these is, under the hood, simply a filter against a specific field or fields in the structured model Section 3 established — there's no meaningful distinction, from the query engine's own perspective, between filtering on `_SYSTEMD_UNIT` explicitly and filtering on boot ID or priority via their own dedicated convenience flags; they're all field-level filters composed together.

---

## 6. Forward Secure Sealing: Tamper-Evidence

This is worth its own dedicated section because it's a genuinely distinctive journald capability with no direct equivalent in traditional flat-file syslog storage, and it previews security themes Chapter 7 and Chapter 9 both return to.

### 6.1 The Threat Model

Log data has obvious value to an attacker who has compromised a system and wants to cover their tracks — if log files can be freely edited or deleted by anyone with sufficient local privilege (including, in the worst case, an attacker who has achieved root), the logs' value as forensic evidence is fundamentally compromised, since there's no way to distinguish an authentic historical record from one that's been selectively edited after the fact.

### 6.2 The Mechanism, at a Conceptual Level

Forward Secure Sealing (FSS) uses a cryptographic scheme where journal entries are periodically "sealed" using a key that evolves over time in a specifically one-directional way — critically, **an attacker who compromises the current sealing key cannot use it to forge or modify entries from *before* the point of compromise**, because the key used to seal past entries is no longer derivable from the current key alone, only the reverse. This means that even a fully successful, root-level compromise happening *right now* cannot retroactively produce a falsified, cryptographically-valid seal for log entries written before the compromise occurred — an attacker can prevent *future* entries from being verifiably sealed, or corrupt the record going forward, but cannot silently rewrite history in a way that would pass verification against the seal.

### 6.3 Setup and Verification

```
journalctl --setup-keys
journalctl --verify
```

`--setup-keys` generates the initial sealing key pair (producing a "verification key" the administrator needs to securely store *separately* from the system itself, since a verification key stored on the same, potentially-compromised system provides no protection at all — precisely the kind of "the verification key must live outside the threat model's compromise scope" reasoning worth stating explicitly, since it's a easy detail to overlook and one that fully defeats the mechanism's purpose if gotten wrong); `--verify` checks the current journal's cryptographic seals against tampering.

Worth being precise about FSS's actual, limited scope: it detects and provides evidence of tampering — it does not prevent an attacker with sufficient privilege from deleting journal files outright, or from disabling FSS going forward from the point of compromise. It is a **detection**, not a **prevention**, mechanism, and its real security value is specifically in forensic and compliance contexts where being able to cryptographically demonstrate "this historical log data has not been altered since it was written" carries genuine evidentiary weight — a capability directly relevant to the audit and compliance themes Chapter 7 develops further.

---

## 7. Resource Controls and Rate Limiting

A detail worth flagging because it directly affects log completeness in high-volume scenarios, a genuinely common troubleshooting surprise ("why are some of my log entries missing"): journald applies **rate limiting** by default, per source, to prevent a single misbehaving or excessively verbose process from overwhelming the journal and consuming disproportionate disk or CPU resources.

```
RateLimitIntervalSec=30s
RateLimitBurst=10000
```

This default configuration permits up to the burst count of messages from a single source within the configured interval before journald begins actively dropping additional messages from that specific source (while, notably, still recording *that* suppression occurred, via a distinct "suppressed N messages" entry, rather than silently dropping data with zero trace at all). This is worth understanding precisely as a deliberate, configurable trade-off — protecting overall system stability and journal usability against a single runaway logging source, at the cost of potential incompleteness for that specific source during a burst — rather than assuming, incorrectly, that journald guarantees lossless capture of literally everything a source ever attempts to write under all circumstances.

---

## 8. Common Misconceptions Worth Retiring Now

- **"journald always persists logs across reboots."** Persistence depends entirely on whether `/var/log/journal/` exists (in the default `Storage=auto` mode) or on an explicit `Storage=persistent` setting — the out-of-the-box behavior on some systems is volatile-only, a common source of "my logs are gone" surprise.
- **"You can just `grep` a journal file directly."** Journal files are binary, not plain text; `journalctl` (or an equivalent tool that understands the format) is required for any meaningful inspection.
- **"All journal fields are equally trustworthy."** Underscore-prefixed fields are independently verified by journald itself based on kernel-reported connection credentials; non-underscore fields are simply whatever the source process claims, with no independent verification.
- **"Forward Secure Sealing prevents log tampering."** It detects tampering after the fact, cryptographically, for entries written before a compromise — it does not prevent deletion or prevent an attacker from disabling logging going forward from the point of compromise.
- **"A single `-p err` filter shows only entries at exactly the error level."** It shows error level and everything more severe (critical, alert, emergency) by default, per the inherited syslog severity scale from Chapter 1 — an explicit range is required to match one specific level in isolation.

---

The next chapter turns to `rsyslog` and the broader syslog protocol lineage — the traditional facility/severity model that predates journald by decades, its configuration syntax, and precisely how it coexists with and receives forwarded data from the journald mechanism this chapter has now covered in full.
