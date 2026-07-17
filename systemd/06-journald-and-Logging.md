# journald and Logging

A complete, mechanism-level reference for `systemd-journald`: the binary journal format and why it exists, persistence and rotation configuration, the structured-field model underlying every `journalctl` query used throughout this series, the complete `journalctl` query syntax, cross-unit and cross-boot correlation, syslog forwarding and remote journal shipping, integrity verification, rate limiting, and the message catalog — assembled into one worked incident investigation that ties the whole reference together.

Every prior document in this series used `journalctl -u <unit>` as a black box, trusting that it would show "the log." This document is where that trust is finally justified in full — what's actually being queried, how it's stored, what guarantees it provides, and the complete vocabulary for asking it more precise questions than a bare `-u` filter ever could.

---

## 1. Why a Structured Journal, Not Flat Text

`01-Introduction.md` Section 2.5 named journald's design goal in passing: every process launched by systemd has its output captured automatically, with structured metadata attached, rather than each daemon implementing its own log rotation, syslog integration, or file handling independently. It's worth returning to this now with the actual mechanism in view.

### 1.1 The problem with flat-text logs

A traditional syslog-style log line is, fundamentally, one string: a timestamp, a hostname, a process tag, and a free-text message, concatenated and written to a file. Extracting structured meaning from it — "show me every message from this specific unit, at this specific priority, within this specific ten-minute window, correlated with a specific systemd job" — requires parsing that string back apart, with a parser that has to guess at a format convention that varies daemon to daemon, and that provides no guarantee the fields you're trying to extract were even recorded in the first place.

### 1.2 The journal's actual approach

`journald` instead stores each log entry as a genuinely structured record — a set of `FIELD=value` pairs — from the moment it's received, not reconstructed after the fact by parsing free text. `MESSAGE=` carries the human-readable text a flat-text log would have shown as its entire content, but it sits alongside dozens of other fields (Section 5) recorded automatically and precisely, without any parsing or guessing required to extract them later. This is the single fact that makes every `journalctl` filter used throughout this series — `-u webapp.service`, `-p err`, `--since` — a query against exact, reliably-present structured data, not a best-effort regex against unstructured text.

---

## 2. Journal File Internals

### 2.1 Storage locations and the volatile/persistent distinction

Journal files live in one of two locations, and which one is active has direct consequences for what survives a reboot:

```
/run/log/journal/<machine-id>/     # volatile — tmpfs-backed, lost at reboot
/var/log/journal/<machine-id>/     # persistent — survives across reboots
```

Whether `/var/log/journal/` is actually used at all is governed by `Storage=` in `journald.conf` (Section 3), and this is precisely the mechanism `05-Boot-Process-and-Targets.md` Section 2.3 referenced without full explanation: an initramfs-phase log fragment, generated before the real root (and, transitively, `/var/log/journal/` on it) is even mounted, necessarily lives only in the initramfs's own volatile, memory-resident journal instance — and whether any of it survives into the post-`switch-root` persistent journal depends on whether the specific initramfs build is configured to hand that in-memory journal data off to the real journal once it becomes available, a detail that genuinely varies by distribution and initramfs configuration rather than being a fixed, universal guarantee.

### 2.2 The binary format, structurally

Each machine-id-scoped journal directory contains a series of `.journal` files, individually size- or time-bounded (Section 3.3), each internally organized as a set of hash tables and B-tree-like indexes over the structured fields described in Section 1.2 — this is what makes a query like `journalctl _SYSTEMD_UNIT=webapp.service` fast even against a journal containing millions of entries across many services: the query is answered via an index lookup on the `_SYSTEMD_UNIT` field directly, not a linear scan through every entry checking whether each one happens to mention `webapp.service` somewhere in a free-text line, which would be the only option available against a traditional flat-text log of comparable size.

### 2.3 Corruption resilience

Because entries are written incrementally and each file carries internal integrity metadata, a journal file that's truncated mid-write (a hard power loss during active logging, for instance) is designed to remain readable up to the last successfully-flushed entry, rather than the entire file becoming unparseable — `journalctl` surfaces a truncation with an explicit warning (`Journal file ... corrupted, ignoring file` or similar, depending on the specific damage) rather than silently either failing outright or silently losing entries with no indication anything was lost at all. Section 9 covers the stronger, cryptographic verification mechanism (`journalctl --verify` and sealing) built on top of this same underlying, incrementally-structured file format.

### 2.4 Compression and Access Pattern

Individual field values above a size threshold are transparently compressed (XZ, LZ4, or ZSTD depending on build-time configuration and `journald.conf`'s `Compress=` setting) as they're written — a large `MESSAGE=` value (a multi-line stack trace, for instance) is stored compressed on disk and transparently decompressed at query time, without this being visible to or requiring any special handling by anything issuing a `journalctl` query. Small, frequently-repeated values (short `SYSLOG_IDENTIFIER=` tags, `_SYSTEMD_UNIT=` names) fall below the compression threshold and are stored directly, since compression overhead would exceed any space saved for values already this small.

The files themselves are accessed via `mmap()` rather than being read sequentially into memory wholesale — meaning `journalctl` can efficiently query a journal file far larger than available RAM, since the kernel's own page cache handles bringing in only the specific regions actually touched by a given query's index traversal (Section 2.2), rather than the querying process needing to load the entire file's contents upfront regardless of how narrow the actual query is.

### 2.5 Priority Levels, Completely

`PRIORITY=` (Section 4.2) uses the traditional syslog severity scale, worth a complete reference table here since every `-p` filter throughout Section 5 depends on it:

| Numeric | Name | Typical meaning |
|---|---|---|
| 0 | `emerg` | System is unusable |
| 1 | `alert` | Action must be taken immediately |
| 2 | `crit` | Critical condition |
| 3 | `err` | Error condition — the most common `-p` threshold in practice |
| 4 | `warning` | Warning condition |
| 5 | `notice` | Normal but significant condition |
| 6 | `info` | Informational message |
| 7 | `debug` | Debug-level message, typically the most voluminous |

`journalctl -p` accepts either form interchangeably — `-p err` and `-p 3` are identical — and `-p warning..err` (Section 5.1's range syntax) is inclusive of both named endpoints, correctly resolving `warning` (4) as the numerically *less* severe bound and `err` (3) as the more severe one despite the reversed reading-order relative to the numeric scale, since the range syntax is defined in terms of severity ordering, not raw numeric direction.

---

## 3. Persistence and Rotation Configuration

`/etc/systemd/journald.conf` (plus `/etc/systemd/journald.conf.d/*.conf` drop-ins, following the identical layered-override convention `04-Unit-Files.md` Section 3 established for unit files) is where journal behavior is actually configured — worth noting explicitly that this is a **daemon-level** configuration file, not a unit file, since `systemd-journald` is itself one of the satellite daemons `01-Introduction.md` Section 3's component table enumerated, not PID 1 itself.

### 3.1 `Storage=`

```ini
[Journal]
Storage=persistent
```

| Value | Behavior |
|---|---|
| `volatile` | Only `/run/log/journal/` is used; nothing survives a reboot |
| `persistent` | `/var/log/journal/` is used (created if absent); survives reboots |
| `auto` (default on most distributions) | Uses `/var/log/journal/` **if it already exists**, falling back to volatile-only otherwise — meaning persistence is opt-in via simply creating the directory, without needing to edit this file at all |
| `none` | Logging is effectively disabled at the storage layer; entries are processed for live forwarding (Section 8) only, never written to disk at all |

The `auto` default's behavior — `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix=/var/log/journal` being the standard, minimal way to opt a fresh installation into persistence — is worth knowing explicitly, since "my logs don't survive a reboot" on a freshly-installed system is very often not a misconfiguration at all, but simply the documented `auto` default behaving exactly as designed on a system where nobody has yet created the persistent directory.

### 3.2 Size and retention limits

```ini
[Journal]
SystemMaxUse=2G
SystemKeepFree=500M
RuntimeMaxUse=200M
MaxRetentionSec=1month
MaxFileSec=1week
```

`SystemMaxUse=`/`RuntimeMaxUse=` cap the total disk space the persistent/volatile journal is permitted to consume respectively, independent of each other, since they govern genuinely separate storage locations (Section 2.1). `SystemKeepFree=` is a distinct, complementary constraint — rather than a fixed cap on journal size, it guarantees a minimum amount of free space is preserved on the underlying filesystem *regardless* of how large `SystemMaxUse=` would otherwise permit the journal to grow, protecting against the journal itself being the cause of a filesystem filling up entirely and taking down unrelated services that also need free space to function.

`MaxRetentionSec=` bounds how long any entry is kept, purely by age, independent of the size-based limits — an entry older than this is eligible for deletion during rotation even if the total journal size is nowhere near `SystemMaxUse=`'s ceiling. `MaxFileSec=` governs how large an individual `.journal` file (Section 2.2) is permitted to grow before a new one is rolled over, distinct from the *total* size cap — smaller individual files rotate and can be independently compressed/archived more granularly, at the cost of a very slightly higher per-file indexing overhead relative to fewer, larger files.

### 3.3 Rotation mechanics

Rotation — closing the currently-active `.journal` file and beginning a new one — happens automatically whenever any of the size/time/age limits above are reached, and can also be triggered manually:

```bash
journalctl --rotate
```

useful specifically before a `journalctl --vacuum-*` operation (Section 3.4), since an actively-being-written-to file is generally not a candidate for vacuuming regardless of its age or the configured limits — rotating first ensures the vacuum operation has a clean, fully-closed set of archived files to actually work against.

### 3.4 Manual space reclamation

```bash
journalctl --vacuum-size=1G     # shrink until total usage is at or below 1G
journalctl --vacuum-time=2weeks # delete anything older than 2 weeks
journalctl --vacuum-files=5     # keep only the 5 most recent archived files
```

These are one-time, immediately-executed operations, distinct from the standing, automatically-enforced `journald.conf` limits from Section 3.2 — useful for an immediate, manual space reclamation need (a filesystem unexpectedly nearing capacity) without waiting for or permanently changing the configured automatic rotation policy.

---

## 4. Structured Fields, Completely

Every journal entry carries a set of fields; this section is the vocabulary reference every `journalctl` filter throughout this series, and the rest of this document, draws from.

### 4.1 Trusted fields (kernel/journald-supplied, prefixed `_`)

These are fields the logging process **cannot forge or override** — recorded directly by the kernel or by `journald` itself, based on facts about the actual, verified sending process, not anything the process's own log message claims about itself.

| Field | Meaning |
|---|---|
| `_PID` | The sending process's PID |
| `_UID` / `_GID` | The sending process's real UID/GID |
| `_COMM` | The sending process's executable name (`comm`, from `/proc`) |
| `_EXE` | The full path to the sending process's executable |
| `_CMDLINE` | The sending process's full command line |
| `_SYSTEMD_UNIT` | The systemd unit the sending process belongs to — the field every `journalctl -u` invocation throughout this series has actually been querying under the hood |
| `_SYSTEMD_CGROUP` | The full cgroup path, tying directly back to the cgroup-based process tracking established in `01-Introduction.md` Section 9 |
| `_SYSTEMD_INVOCATION_ID` | A unique ID for this specific *invocation* (one particular start-to-stop lifecycle) of the unit — covered fully in Section 6 |
| `_BOOT_ID` | Identifies which specific boot this entry was logged during — the field `-b` (Section 5.2) filters on |
| `_HOSTNAME` | The machine's hostname at the time of logging |
| `_MACHINE_ID` | The persistent machine identifier from `/etc/machine-id` |
| `_TRANSPORT` | How the entry reached journald — `stdout`, `syslog`, `kernel`, `journal` (native `sd_journal_send` calls), `audit` |

### 4.2 Untrusted fields (client-supplied)

| Field | Meaning |
|---|---|
| `MESSAGE` | The actual human-readable log text |
| `PRIORITY` | Syslog-standard severity, 0 (`emerg`) through 7 (`debug`) |
| `SYSLOG_IDENTIFIER` | The tag a process identifies itself with — settable via `03-Service-Management.md` Section 4.6's `SyslogIdentifier=` |
| `SYSLOG_FACILITY` | Traditional syslog facility code, relevant mainly for forwarding (Section 8) |
| `MESSAGE_ID` | A UUID identifying a specific *class* of message, the mechanism the catalog system (Section 12) is built on |
| `CODE_FILE` / `CODE_LINE` / `CODE_FUNC` | Source-location metadata, when the logging library supplies it |

The trusted-versus-untrusted distinction matters directly for log-based security reasoning: `_PID`/`_UID`/`_SYSTEMD_UNIT` and the rest of Section 4.1's fields are facts journald itself verified against the actual sending process via the kernel, and cannot be spoofed by a malicious or buggy process claiming to be something it isn't; `MESSAGE`/`SYSLOG_IDENTIFIER` and Section 4.2's fields are exactly what the process itself chose to send, and a compromised or malfunctioning process can put arbitrary, misleading content into them — a distinction worth keeping in mind before treating a `SYSLOG_IDENTIFIER` value as equivalent in trustworthiness to the corresponding `_SYSTEMD_UNIT` field for the same entry.

### 4.3 Custom application fields

A process can attach arbitrary additional fields beyond the standard set via the native `sd_journal_send()` API (or, from a shell script, `systemd-cat`), by convention using uppercase names:

```c
sd_journal_send("MESSAGE=Order processed", "PRIORITY=6",
                 "ORDER_ID=48213", "CUSTOMER_TIER=premium", NULL);
```

```bash
journalctl ORDER_ID=48213
```

This is a genuinely different capability from a flat-text log line merely *containing* the order ID somewhere in its message text — `ORDER_ID=48213` here is an indexed, exact-match-queryable field (Section 2.2's indexing mechanism applies to custom fields identically to built-in ones), not a substring that has to be regex-matched out of free text, and is the mechanism that lets application-level log correlation (Section 13's worked example makes direct use of this) work with the same precision and query performance as the unit-level correlation every earlier `journalctl -u` example in this series has relied on.

### 4.4 `systemd-cat`: Structured Logging from Shell Scripts and Ad Hoc Commands

Not every process is a compiled binary linking against `libsystemd` and calling `sd_journal_send()` directly. `systemd-cat` bridges the gap for shell scripts, one-off commands, and anything else that only knows how to write to stdout/stderr:

```bash
systemd-cat --identifier=backup-job /usr/local/bin/backup.sh
```

This runs `backup.sh`, capturing its stdout/stderr and forwarding each line into the journal as a proper structured entry — `SYSLOG_IDENTIFIER=backup-job` (Section 4.2) set as requested, `_TRANSPORT=stdout`, and the full set of trusted fields (Section 4.1) correctly populated based on the actual, verified spawned process, exactly as if `backup.sh` had been launched as an ordinary systemd-managed unit rather than an ad hoc command. This is directly useful for `03-Service-Management.md` Section 4.5's `ExecReload=`-style shell one-liners and any `ExecStartPre=`/`ExecStartPost=` script that would otherwise write to a plain file or be silently swallowed — piping such a script's own internal, more granular logging through `systemd-cat` (or having the script call `logger` in journal-aware mode, a closely related, even more lightweight alternative for single-line messages) brings it into the same unified, queryable stream as everything else covered in this document, rather than requiring a separate, ad hoc file to remember to check.

```bash
echo "Cache warmed: 4200 entries" | systemd-cat --identifier=webapp-cache --priority=info
```

Piping directly into `systemd-cat`, as shown here, is the standard idiom for a single, one-off structured log line from within a larger shell script, without needing to wrap that entire script's execution in `systemd-cat` at the top level.

---

## 5. `journalctl`: The Complete Query Reference

### 5.1 Unit and priority filtering

```bash
journalctl -u webapp.service               # by unit — filters on _SYSTEMD_UNIT
journalctl -u webapp.service -u postgresql.service   # multiple units, OR'd
journalctl -p err                          # this priority and everything more severe
journalctl -p warning..err                 # a specific priority range
```

`-p` accepts either a single threshold (matching that severity and everything numerically more severe, since `PRIORITY` runs 0=most severe to 7=least) or an explicit range — `-p err` alone is by far the more common form, used as the very first filter in almost any incident investigation, per Section 14.

### 5.2 Time and boot filtering

```bash
journalctl --since "2026-07-17 09:00:00"
journalctl --since "1 hour ago" --until "30 minutes ago"
journalctl -b                              # current boot only
journalctl -b -1                           # the previous boot
journalctl -b 0                            # equivalent to -b, current boot
journalctl --list-boots                    # enumerate every boot the journal knows about
```

`--since`/`--until` accept both absolute timestamps and systemd's own relative-time grammar (`"1 hour ago"`, `"yesterday"`, `"-15min"`); `-b`'s numeric argument is **relative to the current boot**, not an absolute boot index — `-1` always means "one boot before this one," regardless of how many total boots the journal actually contains, while `--list-boots` shows the actual `_BOOT_ID` values (Section 4.1) and their corresponding relative offsets, useful when you need to reference a specific historical boot by its real ID rather than a relative offset that would shift meaning on a subsequent, later query.

### 5.3 Field-based matching, generally

Any field from Section 4 can be used as a direct match expression, not merely the ones with dedicated short flags:

```bash
journalctl _SYSTEMD_UNIT=webapp.service     # equivalent to -u webapp.service
journalctl _UID=1000
journalctl _TRANSPORT=kernel                # equivalent to -k
journalctl SYSLOG_IDENTIFIER=sudo
```

Multiple `FIELD=value` expressions on one command line are combined with **logical AND** by default across *different* field names, but **OR** among repeated instances of the *same* field name — mirroring exactly the same asymmetric combination rule `04-Unit-Files.md` Section 11 established for `Condition*=` directives: `journalctl _SYSTEMD_UNIT=webapp.service _UID=1000` requires both conditions to hold simultaneously, while `journalctl _SYSTEMD_UNIT=webapp.service _SYSTEMD_UNIT=cache.service` matches entries from *either* unit.

```bash
journalctl _SYSTEMD_UNIT=webapp.service + _SYSTEMD_UNIT=postgresql.service
```

An explicit `+` between two match expressions forces an OR relationship even *across* different field names, overriding the default-AND-across-fields rule — the one piece of this syntax that genuinely requires memorizing rather than following intuitively from the field-matching examples above.

### 5.4 Output formats

```bash
journalctl -o json                # one JSON object per line
journalctl -o json-pretty         # human-readable, indented JSON
journalctl -o short-iso           # ISO-8601 timestamps instead of the default locale-formatted ones
journalctl -o verbose             # every field, trusted and untrusted, for each entry
journalctl -o cat                 # MESSAGE= only, no metadata at all
```

`-o json`/`-o json-pretty` are the standard bridge into external tooling — piping into `jq` for further structured filtering/aggregation that goes beyond what `journalctl`'s own match-expression syntax (Section 5.3) can directly express, without needing to first parse a human-formatted text line back apart the way a flat-text log would require. `-o verbose` is the direct, fastest way to discover exactly which fields a specific entry actually carries — including custom application fields (Section 4.3) — when you don't already know the full field vocabulary a particular process is using.

### 5.5 Following, tailing, and paging

```bash
journalctl -f                     # follow, like `tail -f`
journalctl -f -u webapp.service   # follow, filtered to one unit
journalctl -n 50                  # last 50 entries
journalctl -e                     # jump to the end, in the pager
journalctl -r                     # reverse order, newest first
```

### 5.6 Free-text search

```bash
journalctl --grep "connection refused"
journalctl --grep "connection refused" -u webapp.service --case-sensitive
```

`--grep` is explicitly the fallback for when you don't yet know which structured field would let you ask the precise question directly — genuinely useful, but worth recognizing as a **linear-scan, unindexed** operation, unlike the field-match queries in Section 5.3, which are answered via the indexes described in Section 2.2. A `--grep` search across a large, multi-week persistent journal is meaningfully slower than an equivalent field-match query, and combining `--grep` with a narrowing field/time filter first (`-u webapp.service --since yesterday --grep "..."`) rather than searching the entire journal unfiltered is the standard, faster idiom.

### 5.7 `-x`: Explanatory Output

```bash
journalctl -xb
```

Appends, where available, an extended explanation drawn from the message catalog (Section 12) for entries that have one — this is precisely the flag the console's own boot-failure guidance in `05-Boot-Process-and-Targets.md` Section 8.4 pointed toward, and is why that section's advice was specifically "`journalctl -xb`" rather than a bare `journalctl -b`: the `-x` catalog lookup is what turns a terse `Failed with result 'exit-code'` line into an entry additionally annotated with a longer, human-authored explanation of what that specific failure class generally means and what's typically worth checking next.

---

## 6. Correlating Logs Across Units and Boots

### 6.1 `_SYSTEMD_INVOCATION_ID`

Every time a unit is started — including an automatic `Restart=`-triggered relaunch, per `03-Service-Management.md` Section 5 — systemd assigns a fresh, unique invocation ID, exposed to the launched process via the `INVOCATION_ID` environment variable and recorded on every journal entry that process produces as `_SYSTEMD_INVOCATION_ID`.

```bash
systemctl show webapp.service --property=InvocationID
journalctl _SYSTEMD_INVOCATION_ID=<the-id-from-above>
```

This is the precise tool for a question `-u webapp.service` alone cannot answer: "show me only the logs from *this specific* run of the service, not the six other times it's restarted today" — directly relevant to `03-Service-Management.md` Section 13's crash-loop worked example, where distinguishing which specific restart cycle's log entries belong together, rather than viewing the entire day's interleaved history across every restart, is exactly the precision `_SYSTEMD_INVOCATION_ID` filtering provides.

### 6.2 Cross-boot correlation with `_BOOT_ID`

Section 5.2 covered `-b`'s relative-offset convenience; the underlying `_BOOT_ID` field is what actually makes cross-boot log continuity possible at all — every entry, from every boot the persistent journal (Section 3.1) still retains, carries this field, meaning a query like `journalctl _SYSTEMD_UNIT=webapp.service` with no `-b` restriction at all searches across **every retained boot simultaneously**, correctly distinguishing which entries belong to which specific boot via this field even as it presents them in one combined, chronologically-ordered stream.

### 6.3 Cursors: stable position references

```bash
journalctl --show-cursor
# ... entries ..., ending with: -- cursor: s=af92...;i=...;b=...
journalctl --after-cursor="s=af92...;i=...;b=..."
```

A **cursor** is an opaque, stable reference to an exact position in the journal — more precise than a timestamp (which can't distinguish between multiple entries logged within the same clock tick) and more durable than a numeric offset (which shifts as new entries are added and old ones rotated away). This is the mechanism external log-shipping and monitoring tooling relies on to reliably resume "where it left off" after a restart of its own, without either re-processing already-seen entries or missing ones logged in the gap — directly relevant to Section 9's remote-journal shipping, which uses cursors internally for exactly this resumability guarantee.

---

## 7. Kernel and Audit Messages

```bash
journalctl -k                     # equivalent to _TRANSPORT=kernel
journalctl -k -b -1               # kernel messages from the previous boot
```

`-k` filters to messages received via the kernel's own logging ring buffer — the same underlying source `dmesg` reads from, now unified into the same queryable, structured journal as every other transport, with the same field-based filtering (Section 5.3) available against it. This is directly relevant to `05-Boot-Process-and-Targets.md` Section 1.1's kernel-phase discussion: kernel messages logged before `journald` itself is even running are buffered by the kernel independently and ingested into the journal once `journald` starts, which is how `-k -b -1`-style historical kernel-message queries remain possible after the fact, rather than that earliest phase of boot being unrecoverable from the journal entirely.

Audit subsystem messages (`_TRANSPORT=audit`), when the kernel's audit framework is active, are similarly ingested and queryable through the identical mechanism — security-relevant events (permission denials tracked by SELinux/AppArmor, for instance) appearing in the same unified journal stream and queryable with the same syntax as an ordinary application log entry, rather than requiring a separate tool with its own, different query language.

---

## 8. Forwarding to Traditional Syslog

```ini
# /etc/systemd/journald.conf
[Journal]
ForwardToSyslog=yes
```

With this enabled, every entry journald receives is *also* forwarded, live, to a traditional syslog socket (`/dev/log`), where a conventional syslog daemon (`rsyslog`, `syslog-ng`) — if one is installed and running — picks it up and applies its own, independent processing: routing to flat-text files under `/var/log/`, forwarding to a remote syslog collector over the network, or any other rule a traditional `rsyslog.conf` configuration expresses. This is **not** an either/or replacement of the native journal — both the structured journal (Section 2) and the forwarded flat-text syslog stream are populated simultaneously from the identical set of underlying entries, and the choice of which to actually query for a given task is a separate decision from whether forwarding is enabled at all: `journalctl`'s structured, indexed queries (Section 5) remain available regardless of whether `ForwardToSyslog=` is also active in parallel.

`ForwardToKMsg=`, `ForwardToConsole=`, and `ForwardToWall=` are sibling directives following the identical pattern for other output destinations — the kernel's own message buffer, a specific console device, and an immediate `wall`-style broadcast to every logged-in terminal respectively, each independently toggleable, each operating as an additional parallel destination rather than a replacement for the native journal.

**Why forwarding remains common despite the journal's own capabilities:** existing organizational log-aggregation infrastructure very often already expects a traditional syslog stream as its ingestion format, and `ForwardToSyslog=` is the lowest-friction way to feed that existing pipeline from a systemd-based host without re-architecting the aggregation side — the native journal's structured richness (Section 4) is, in that specific scenario, available locally for direct `journalctl` investigation on the host itself, while the forwarded, flattened syslog stream serves the separate, pre-existing centralized-aggregation need.

### 8.1 journald Versus Classic Syslog, Side by Side

Worth consolidating the comparison implicit throughout Sections 1–8 into one direct table, for reference:

| Concern | journald (native) | Traditional syslog (`rsyslog`/`syslog-ng`) |
|---|---|---|
| Storage format | Structured, indexed binary (Section 2.2) | Flat text |
| Query precision | Exact field matches (Section 5.3), fast even at scale | Regex/`grep` against text, slower at scale |
| Custom structured fields | Native (Section 4.3) | Requires embedding structured hints in free text by convention |
| Per-process trusted metadata | Kernel-verified (Section 4.1) | Self-reported by the sending process only |
| Rotation/retention | Native, size- and age-based (Section 3) | Typically handled by a separate tool (`logrotate`) |
| Remote shipping | Native, field-preserving (Section 9) | Native, but flattens structure on receipt |
| Ecosystem maturity for centralized aggregation | Newer, growing (Section 9) | Extremely mature, near-universal ingestion support |

The realistic operational pattern for most production environments, given this comparison, is not choosing one exclusively but running both in parallel exactly as Section 8's `ForwardToSyslog=yes` configuration enables — native journal locally, for the query precision and structured-field richness this document has covered in depth, with syslog forwarding feeding whatever existing, mature centralized-aggregation pipeline the organization already has in place, rather than treating the choice as one-or-the-other.

### 8.2 The Cost of Dual Logging

It's worth being explicit that `ForwardToSyslog=yes` is not free — every entry is now written twice, once to the native journal and once via the forwarding path, meaning both the disk I/O and CPU cost (for the compression described in Section 2.4, on the journal side, plus whatever the receiving syslog daemon's own processing involves) are paid twice per entry. On a host already near its I/O capacity limits, this is a genuine, measurable cost worth weighing against the benefit — a common middle ground is enabling forwarding only for `warning`-severity and above (via the receiving syslog daemon's own filtering rules, since `journald` itself forwards everything indiscriminately and expects the syslog side to apply its own severity filtering) rather than forwarding the full, high-volume `debug`/`info` firehose to a system that may not need or want that volume centrally aggregated at all.

---

## 9. Remote Journal Shipping

Distinct from syslog forwarding (Section 8), systemd provides its own native mechanism for shipping the **structured** journal itself — fields and all, not a syslog-flattened version of it — to a remote collector, preserving the full field-level query capability from Section 4/5 on the receiving end too.

```bash
# On the sending host:
systemctl edit systemd-journal-upload.service
```
```ini
[Journal Upload]
URL=https://log-collector.example.com:19532
```

`systemd-journal-upload.service`, once configured and enabled, streams journal entries to a `systemd-journal-remote` instance running on the collector, over HTTPS, using the cursor mechanism from Section 6.3 internally to track upload progress and correctly resume after any interruption without gaps or duplication. The receiving `systemd-journal-remote` instance writes the incoming entries into its own, ordinary journal file structure — meaning the exact same `journalctl` query syntax covered throughout Section 5 works identically against the aggregated, centrally-collected journal on the collector host as it does against a single host's local journal, including field-based matches against custom application fields (Section 4.3), a capability a syslog-flattened aggregation pipeline generally cannot offer with the same precision, since the structure those fields represented was discarded at the point of flattening.

### 9.1 A Worked Multi-Host Query

Extending Section 13's incident-investigation scenario to a fleet of several `webapp.service` instances across different hosts, all shipping to one `systemd-journal-remote` collector: because `_HOSTNAME` (Section 4.1) is recorded on every entry regardless of which host originated it, and the collector's own journal directory structure preserves this distinction per originating machine, a single query on the collector can answer a question no individual host's own local journal could answer alone:

```bash
journalctl -D /var/log/journal/remote/ _SYSTEMD_UNIT=webapp.service ORDER_ID=48213
```

This locates every entry, across the *entire fleet*, mentioning a specific `ORDER_ID=` custom field (Section 4.3), regardless of which specific host actually processed that order — directly relevant for an application distributing work across multiple identical service instances, where a single request's full processing trail might span more than one host, and reconstructing that trail from separately-collected, per-host flat-text logs would require manually correlating timestamps across differently-clocked machines rather than a single, precise field-match query against one already-aggregated, structured source. `-D` here points `journalctl` at a specific journal directory explicitly, rather than the default local-machine journal location — the mechanism that makes querying the collector's own, separately-stored aggregate journal possible from the same familiar command-line tool used throughout this document for local queries.

---

## 10. Journal Verification

```bash
journalctl --verify
```

Checks the internal integrity of the on-disk journal files — detecting truncation, corruption, or (with sealing enabled, below) tampering — beyond the basic incremental-corruption resilience described in Section 2.3, which handles *accidental* truncation gracefully but says nothing about deliberate, malicious modification of already-written entries.

### 10.1 Forward Secure Sealing (FSS)

```bash
journalctl --setup-keys
```

Generates a sealing key pair and enables **Forward Secure Sealing** — a cryptographic mechanism periodically embedding verification tokens into the journal stream itself, structured such that an attacker who compromises the system and obtains the *current* sealing key still cannot retroactively forge or alter *already-written* historical entries without that tampering being detectable by `journalctl --verify` using the separately-stored verification key. This is a meaningfully stronger guarantee than ordinary file permissions alone provide — file permissions can prevent an unprivileged process from altering the journal, but do nothing against an attacker who has actually obtained root, whereas FSS's forward-secrecy property specifically targets exactly that stronger threat model, at the cost of needing to securely store the separately-generated verification key somewhere the compromised host itself doesn't have ongoing access to, since a verification key left on the same host is itself vulnerable to the same compromise it's meant to help detect.

---

## 11. Rate Limiting

```ini
# /etc/systemd/journald.conf
[Journal]
RateLimitIntervalSec=30s
RateLimitBurst=10000
```

Per-service (tracked internally by `_SYSTEMD_UNIT`) rate limiting protects against a single misbehaving or compromised process flooding the journal — and, transitively, consuming disk I/O and the size limits from Section 3.2 — with an unbounded volume of log entries in a short window. When a unit exceeds `RateLimitBurst=` entries within `RateLimitIntervalSec=`, further entries from that specific unit are dropped (not queued for later delivery) until the window resets, and journald records a summary entry noting how many were suppressed:

```
systemd-journald[512]: Suppressed 4821 messages from webapp.service
```

This is directly relevant to interpreting an investigation where a unit's own logging appears to have an unexplained gap during exactly the period it was misbehaving most severely — per this mechanism, that gap can be the rate limiter itself, having suppressed exactly the flood of repetitive entries a crash loop or tight error-retry cycle would tend to produce, and the `Suppressed N messages` summary line is the signal to look for confirming this specific explanation for a gap, rather than assuming the unit simply stopped logging for that window for some other reason.

---

## 12. Journal Namespaces

`03-Service-Management.md` Section 16 discussed running systemd itself inside a container as an occasional, deliberate choice. When that's done, or when strong log isolation between groups of units on a single host is otherwise desired, `LogNamespace=` provides a dedicated mechanism distinct from the private-filesystem namespacing (`PrivateTmp=` and its wider family) covered in `04-Unit-Files.md` Section 4.9.

```ini
[Service]
LogNamespace=webapp-isolated
```

A unit with `LogNamespace=` set is served by an **entirely separate instance** of `systemd-journald` — its own rate-limiting counters (Section 11), its own `Storage=`/size-limit configuration (Section 3), and its own on-disk journal files, isolated from the host's default, main journal instance. `journalctl --namespace=webapp-isolated` queries that specific, isolated instance directly, using the identical query syntax from Section 5 throughout — the namespace boundary affects *where* the journal data lives and is administered, not the query language used to read it.

This is a meaningfully stronger isolation guarantee than merely filtering the default journal by `_SYSTEMD_UNIT=` after the fact: a genuinely misbehaving unit generating an extreme volume of log data, isolated into its own `LogNamespace=`, can exhaust *its own* namespace's size limits and rate-limiting budget without that flood having any effect on the shared, default journal's own limits and budget — directly relevant on a shared, multi-tenant-style host where one workload's logging behavior shouldn't be able to degrade another, entirely unrelated workload's own log retention or query performance, a guarantee simple field-based filtering against one shared journal instance cannot provide on its own.

---

## 13. The Message Catalog

`MESSAGE_ID` (Section 4.2) is the mechanism underlying `-x`'s (Section 5.7) extended-explanation output — a UUID identifying a specific, well-known *class* of message (not a specific instance of it), cross-referenced against catalog files (`/usr/lib/systemd/catalog/*.catalog`, plus any custom ones under `/etc/systemd/catalog/`) containing longer, human-authored explanatory text for that message class.

```
# excerpt from a catalog file
-- 8607e01a5eb0409eb2e9a13e6afa3c0f
Subject: Ordering cycle found
The system has found an ordering cycle among several units, and had to
sever the cycle at an arbitrary point rather than resolve it correctly...
```

This is precisely the mechanism behind `02-Units-and-Dependencies.md` Section 7's ordering-cycle log excerpt being *the kind of message* that, viewed with `-xb` rather than a bare boot query, would surface additional catalog-sourced explanatory text beyond the terse log lines alone — the catalog system is the general-purpose infrastructure that specific example (and the boot-failure guidance in `05-Boot-Process-and-Targets.md` Section 8.4) both draw on without either document having previously named the underlying mechanism explicitly. Application authors can ship their own catalog entries alongside custom `MESSAGE_ID`s (Section 4.3) attached to their own `sd_journal_send()` calls, extending the same `-x`-triggered explanatory-lookup behavior to their own application-specific, recurring message classes.

---

## 14. A Fully Worked Incident Investigation

Bringing this document's reference material together into one continuous investigative sequence, picking up directly where `03-Service-Management.md` Section 13's watchdog-triggered crash-loop scenario left off — now investigated using the full `journalctl` vocabulary rather than a single, already-known-correct query.

**Step 1 — establish the time window and severity floor:**

```bash
journalctl -u webapp.service --since "1 hour ago" -p warning
```

Per Section 5.1/5.2, this narrows immediately to only the unit and time window of interest, at `warning` severity or worse — deliberately avoiding an unfiltered, full-verbosity dump as the starting point, consistent with Section 5.6's general guidance to narrow before broadening.

**Step 2 — identify the specific invocation that actually failed:**

```bash
journalctl -u webapp.service -p err --since "1 hour ago" -o verbose | grep _SYSTEMD_INVOCATION_ID
```

Per Section 6.1, this isolates which specific restart cycle's invocation ID is associated with the actual error-level entries, distinguishing it from the five other, healthy invocations covering the same hour that a bare `-u` query without this step would have interleaved together.

**Step 3 — pull the complete, isolated log for that one invocation:**

```bash
journalctl _SYSTEMD_INVOCATION_ID=5f3a...
```

This reproduces, precisely, only the entries belonging to the one failing run identified in Step 2 — exactly the `Watchdog timeout`/`Killing process`/`Failed with result 'watchdog'` sequence `03-Service-Management.md` Section 13 walked through, now arrived at via a general investigative method rather than presented as an already-known example.

**Step 4 — check whether the flood of retries triggered rate limiting:**

```bash
journalctl -u webapp.service --since "1 hour ago" --grep "Suppressed"
```

Per Section 11, confirming whether any entries were dropped during the incident is essential before concluding the retrieved log is complete — a crash loop producing thousands of near-identical error lines per second is exactly the scenario `RateLimitBurst=` exists to guard against, and an investigation that doesn't check for this can wrongly conclude a unit "went quiet" during exactly its worst period, when in fact the entries were being generated and simply suppressed at the source.

**Step 5 — correlate against the dependency it was calling into:**

```bash
journalctl -u postgresql.service --since "1 hour ago" -p warning
```

Since `webapp.service` `Requires=postgresql.service` (the running example throughout `02-Units-and-Dependencies.md` and `03-Service-Management.md`'s worked scenarios), checking the dependency's own log for the identical window is the natural next step — confirming or ruling out whether the watchdog-triggered deadlock in `webapp.service` correlates with something independently visible in `postgresql.service`'s own log (a slow query, a connection-pool exhaustion warning) during the same window, which `journalctl`'s time-range filtering (Section 5.2) makes a matter of re-running the identical `--since`/`--until` bounds against a second unit, rather than a manual cross-referencing exercise against two separately-formatted flat-text log files.

**Step 6 — export the isolated findings for a postmortem document:**

```bash
journalctl _SYSTEMD_INVOCATION_ID=5f3a... -o json > incident-2026-07-17-webapp.json
```

Per Section 5.4, exporting the precisely-isolated set of entries from Step 3 as structured JSON — rather than a copy-pasted flat-text terminal capture — preserves every field (Section 4) for whoever writes or reviews the eventual postmortem, including fields that might not have seemed relevant during the initial live investigation but could matter on closer, later review.

---

## 15. Common Anti-Patterns

**Assuming `--grep` is as fast as a field-match query.** As covered in Section 5.6, `--grep` is an unindexed linear scan; reaching for it as the *first* filter against an unbounded time range on a large journal is meaningfully slower than narrowing with `-u`/`--since`/`-p` first and reserving `--grep` for the remaining, already-narrowed result set.

**Confusing `-b -1` with an absolute boot index.** As covered in Section 5.2, the numeric argument to `-b` is relative to the *current* boot, not a fixed, absolute position — a script that hardcodes `-b -3` expecting it to always refer to the same specific historical boot will silently refer to a different boot on every subsequent invocation as new boots occur; `--list-boots`' actual `_BOOT_ID` values are the stable reference for that use case.

**Assuming a unit's silence during an incident means it logged nothing.** As covered in Section 11, rate limiting can produce exactly this appearance during the specific window an incident investigation cares about most — always check for a `Suppressed N messages` summary line before concluding an apparent gap reflects genuine silence rather than suppression.

**Relying on `Storage=auto`'s default behavior without realizing persistence is opt-in.** As covered in Section 3.1, a fresh installation with no `/var/log/journal/` directory created loses its entire journal on every reboot by design, not by misconfiguration — worth deliberately deciding for any production system rather than discovering the gap during a post-reboot investigation that unexpectedly finds nothing from before the restart.

**Treating `SYSLOG_IDENTIFIER` or other untrusted fields as equivalent in reliability to `_SYSTEMD_UNIT`.** As covered in Section 4.2's trusted/untrusted distinction, a compromised or buggy process can put arbitrary content into its own self-reported fields — security-relevant filtering and correlation should prefer the kernel-verified `_`-prefixed fields wherever the two could plausibly diverge.

**Enabling `ForwardToSyslog=` under the assumption it replaces the native journal.** As covered in Section 8, both destinations are populated in parallel from the identical source — disabling or ignoring the native journal on the mistaken belief the syslog-forwarded copy is now the authoritative one discards the structured-field richness (Section 4) the forwarded, flattened copy does not preserve.

**Forgetting that `journalctl` queries the default namespace only, by default.** As covered in Section 12, a unit's `LogNamespace=`-isolated entries are simply absent from an ordinary, unqualified `journalctl` invocation — not filtered out, but never queried in the first place — which can read as "this unit isn't logging at all" to an investigator unaware the namespace mechanism is in play, when `journalctl --namespace=<name>` against the correct namespace would show the entries immediately.

---

## 16. Exercises

**1.** A query `journalctl _SYSTEMD_UNIT=webapp.service _SYSTEMD_UNIT=cache.service _UID=1000` is run. What does it actually match? *(Per Section 5.3's asymmetric combination rule, repeated instances of the same field OR together while different fields AND — this matches entries where `_UID=1000` **and** the unit is *either* `webapp.service` or `cache.service`, not entries matching all three conditions simultaneously, which would be impossible since a single entry can't have two different `_SYSTEMD_UNIT` values at once.)*

**2.** A service crash-loops fifteen times in two minutes, each crash logging an identical, multi-line stack trace. A subsequent `journalctl -u` query for that window shows only three of the fifteen stack traces. What is the most likely explanation, and how would you confirm it? *(Per Section 11, `RateLimitBurst=`/`RateLimitIntervalSec=` suppression is the most likely cause given the exact-repetition pattern — confirming it is a matter of searching the same window for a `Suppressed N messages` summary line, per Section 14's corresponding anti-pattern entry, rather than assuming the other twelve crashes simply weren't logged for some unrelated reason.)*

**3.** Two hosts each run `webapp.service`, and an incident potentially spans both. `ForwardToSyslog=` is enabled on both, feeding a shared, traditional syslog aggregator. Is querying that central syslog aggregator, or setting up `systemd-journal-remote` (Section 9), the better approach for correlating custom `ORDER_ID=` fields (Section 4.3) across both hosts? *(`systemd-journal-remote`, per Section 9 — the syslog-forwarded stream has flattened custom structured fields into plain message text by the time it reaches the aggregator, losing the indexed, exact-match queryability `ORDER_ID=48213`-style filtering depends on, while native remote journal shipping preserves the full field structure all the way to the centralized collector.)*

**4.** `journalctl --verify` reports no corruption on a system where Forward Secure Sealing was never set up. Does this rule out deliberate, malicious tampering with historical entries by an attacker who briefly had root? *(No — per Section 10.1, ordinary `--verify` without FSS detects accidental corruption/truncation (Section 2.3's incremental-resilience guarantee) but provides no cryptographic protection against a sufficiently privileged attacker deliberately rewriting already-stored entries; only FSS's forward-secure sealing, with the verification key stored somewhere the compromised host itself never had access to, provides a guarantee against that specific, stronger threat model.)*

**5.** An investigation needs "every entry from `webapp.service`, from any boot, ever retained" — no `-b` restriction at all. Does the resulting output correctly distinguish which entries came from which boot? *(Yes — per Section 6.2, every entry carries `_BOOT_ID` regardless of whether the query itself filters on it, so an unrestricted, all-boots query still presents entries that can be correctly attributed to their originating boot, either visually via `journalctl`'s own boot-change markers in its default output or precisely via an explicit `-o verbose`/`-o json` inspection of the `_BOOT_ID` field itself.)*

**6.** A host runs several genuinely independent workloads under one systemd instance, and one of them occasionally logs extremely heavily. The operator wants that workload's logging volume to never affect the retention or query performance of the other workloads' logs. What is the most direct native mechanism for this? *(`LogNamespace=`, per Section 12 — assigning the heavy-logging workload's units their own dedicated journal instance with independent rate-limiting and size-limit configuration isolates its impact entirely, which per-unit `_SYSTEMD_UNIT=` query filtering against one shared journal instance cannot achieve, since the shared instance's own size/rate limits are still consumed in common regardless of which unit's entries are being filtered for at query time.)*

**7.** `ForwardToSyslog=yes` is enabled, and the receiving syslog daemon applies no severity filtering of its own, forwarding everything onward to a remote, centralized aggregator. A `debug`-level service is later added, logging at high volume. What is the most likely operational consequence, per Section 8.2's discussion? *(Every `debug`-level entry is now written three times over — to the native journal, to the local syslog daemon, and onward to the remote aggregator — meaningfully increasing local I/O, network egress, and remote storage/ingestion cost proportional to that one newly-added service's logging volume; the standard mitigation is applying severity filtering at the syslog-forwarding stage specifically, rather than relying on the receiving aggregator alone to discard unwanted volume after it's already been transmitted.)*

---

## 17. Operational Checklist

Mirroring the checklists established across this series, adapted to journal configuration and logging-related changes specifically:

1. **Before assuming a production system's logs will survive a reboot, explicitly verify `Storage=persistent` is set, or that `/var/log/journal/` already exists**, per Section 3.1 — the `auto` default's opt-in-by-directory-existence behavior is easy to assume is already handled when it in fact was never explicitly configured.
2. **Set `SystemMaxUse=`/`MaxRetentionSec=` deliberately rather than relying on unbounded defaults**, per Section 3.2 — an unconfigured journal on a verbose system can consume more disk than anticipated well before any alerting on general disk usage would catch it specifically as a journal-growth problem rather than an undifferentiated "disk filling up" alert.
3. **For any new custom-field logging (Section 4.3/4.4), confirm the field names are genuinely stable and won't be casually renamed later** — a query or dashboard built against `ORDER_ID=` breaks silently, with no error, if a later code change renames the field to `OrderID=` or similar, since journald has no schema-enforcement mechanism catching this kind of drift at write time.
4. **If `ForwardToSyslog=` is enabled, deliberately decide on severity filtering rather than forwarding everything by default**, per Section 8.2 — especially before adding a new, high-volume `debug`-level service to a host with forwarding already active.
5. **For any multi-tenant or shared host running genuinely independent workloads, consider `LogNamespace=` deliberately rather than relying purely on `_SYSTEMD_UNIT=` filtering for isolation**, per Section 12 — the isolation `LogNamespace=` provides is structural (independent rate limits and size caps), not merely a query-time convenience.
6. **If Forward Secure Sealing (Section 10.1) is a genuine security requirement, confirm the verification key is actually stored somewhere the protected host itself cannot reach** — a verification key left alongside the sealed journal on the same host provides no meaningful protection against the specific compromise scenario FSS exists to detect.

---

## 18. Quick-Reference Table

| Command / Directive | Section | Purpose |
|---|---|---|
| `Storage=` | 3.1 | Whether the journal persists across reboots at all |
| `SystemMaxUse=` / `MaxRetentionSec=` | 3.2 | Size- and age-based rotation limits |
| `journalctl --vacuum-*` | 3.4 | Immediate, manual space reclamation |
| `_SYSTEMD_UNIT`, `_PID`, `_UID` | 4.1 | Kernel/journald-verified, unforgeable fields |
| `MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER` | 4.2 | Client-supplied, unverified fields |
| `-u` / `-p` / `--since`/`--until` / `-b` | 5.1–5.2 | Core unit/severity/time/boot filters |
| `FIELD=value`, `+` | 5.3 | General structured-field matching and OR-override |
| `-o json` / `-o verbose` | 5.4 | Machine-readable / full-field output |
| `--grep` | 5.6 | Unindexed free-text fallback search |
| `-x` | 5.7 | Catalog-sourced explanatory annotations |
| `_SYSTEMD_INVOCATION_ID` | 6.1 | Isolate one specific start-to-stop run of a unit |
| `--show-cursor` / `--after-cursor` | 6.3 | Stable, resumable position references |
| `ForwardToSyslog=` | 8 | Parallel, flattened forwarding to traditional syslog |
| `systemd-journal-upload`/`-remote` | 9 | Native, field-preserving remote journal shipping |
| `--verify` / `--setup-keys` (FSS) | 10 | Corruption detection / tamper-evident sealing |
| `RateLimitBurst=` / `RateLimitIntervalSec=` | 11 | Per-unit flood protection |
| `MESSAGE_ID` / catalog files | 12 | The mechanism behind `-x`'s extended explanations |

---

## 19. Glossary

**Structured field** — a `FIELD=value` pair attached to a journal entry at write time, indexed and precisely queryable, as opposed to text embedded in a free-form message.
**Trusted field** — a `_`-prefixed field recorded by the kernel or journald itself, unforgeable by the logging process.
**Invocation ID** — a unique identifier for one specific start-to-stop lifecycle of a unit, distinguishing one restart cycle's logs from another's.
**Cursor** — an opaque, stable reference to an exact journal position, used for reliable resumption by external consumers.
**Rate limiting** — per-unit suppression of excessive log volume within a configured window, to protect storage and I/O from a flooding process.
**Forward Secure Sealing (FSS)** — a cryptographic mechanism making retroactive tampering with historical journal entries detectable, even by an attacker holding the current signing key.
**Message catalog** — a set of files mapping `MESSAGE_ID` values to longer, human-authored explanatory text, surfaced via `journalctl -x`.
**Journal namespace** — an entirely separate, independently-configured `journald` instance serving a specific subset of units, isolating their rate limits and storage from the host's default journal.
**Transport** — the mechanism by which an entry reached journald (`stdout`, `kernel`, `syslog`, `journal`, `audit`), recorded in the `_TRANSPORT` field.

---

## 20. What's Ahead

`07-Timers-and-Scheduled-Tasks.md` moves to `.timer` units — the native, cron-equivalent scheduling mechanism briefly named in `02-Units-and-Dependencies.md` Section 1 (unit types table) and referenced again in `04-Unit-Files.md` Section 7.4's `.path`-versus-time-based-triggering distinction — covering calendar and monotonic timer syntax, persistence across missed runs, and how a `.timer` unit's own activity is itself queried through exactly the `journalctl` vocabulary this document has just established.

---

## References

- `systemd-journald.service(8)`, `journald.conf(5)` — the daemon and its complete configuration reference
- `journalctl(1)` — the complete query-syntax reference this document expands on
- `systemd.journal-fields(7)` — the canonical list of standard structured fields
- `sd_journal_send(3)` — the native API for custom structured logging
- `systemd-journal-remote(8)`, `systemd-journal-upload(8)` — native remote journal shipping
- `catalog(7)` — the message catalog file format underlying `-x`
