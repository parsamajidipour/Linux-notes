# Application and Service Logs

Chapter 5 closed at the precise handoff point where the kernel's own boot-time logging gives way to userspace — the moment `systemd` starts as PID 1 and begins launching the services that make up a running system. This chapter picks up exactly there: how well-behaved services are expected to produce log output under `systemd`, the specific capture mechanisms this integrates with (directly connecting to Chapter 2's `journald` material), and what happens — and how to work around it — when an application doesn't follow these conventions at all.

---

## 1. The Two Broad Categories of Application Logging

Every piece of software running on a Linux system falls into one of two broad categories, worth naming precisely because the correct diagnostic and configuration approach differs meaningfully between them:

1. **`systemd`-managed services** — programs started and supervised by `systemd` as unit files, the dominant pattern for system services on any modern distribution, where `systemd` itself has direct, structural visibility into the process's lifecycle and, critically, its standard output and standard error streams.
2. **Independently-run applications** — programs that manage their own logging entirely outside `systemd`'s process supervision, writing directly to files, to the traditional syslog socket, or to some other destination of their own choosing, without `systemd` acting as an intermediary at all.

This chapter's material is organized around this distinction because the mechanisms available for capturing, routing, and troubleshooting log output are genuinely different for each category — and a significant fraction of real-world "why can't I find this application's logs" confusion traces directly back to not first correctly identifying which of these two categories a specific piece of software actually falls into.

---

## 2. systemd-Managed Services: stdout/stderr Capture

### 2.1 The Default Behavior

This is worth stating precisely because it's the single most important fact in this chapter, and it directly explains why so many services require zero explicit logging configuration to have their output correctly captured: **by default, every `systemd` unit's standard output and standard error streams are automatically captured by `journald`**, without the service's own code needing any awareness of `systemd`, `journald`, or logging infrastructure at all. A program that simply calls `printf()` or `fprintf(stderr, ...)`, exactly as it would if run interactively from a terminal, has that exact output captured, structured (per Chapter 2, Section 3's field model — tagged with `_SYSTEMD_UNIT`, `_PID`, and the other trusted fields), and made available through `journalctl` — a deliberate design choice specifically intended to make correct logging integration the *default*, zero-effort outcome for any reasonably well-behaved program, rather than something requiring explicit opt-in.

This is controlled by the `StandardOutput=` and `StandardError=` directives in a unit file, whose default value is `journal`:

```
[Service]
StandardOutput=journal
StandardError=journal
```

### 2.2 Alternative Standard Output Destinations

Worth knowing the full range of options, since specific deployment scenarios legitimately call for alternatives to the default:

```
StandardOutput=journal          # default — captured into journald, structured
StandardOutput=null              # discarded entirely — appropriate for genuinely
                                  # noisy, low-value output a specific deployment
                                  # has deliberately decided not to retain at all
StandardOutput=file:/var/log/myapp/custom.log   # direct raw file redirection,
                                  # bypassing journald's structured capture entirely
StandardOutput=append:/var/log/myapp/custom.log # like file:, but appending rather
                                  # than truncating on each service start
StandardOutput=socket             # for services using systemd's socket-activation
                                  # feature specifically, a more specialized case
                                  # outside this chapter's core scope
```

The `file:`/`append:` options are worth flagging specifically because choosing them means deliberately **opting out** of journald's structured capture (Chapter 2, Section 3) — a legitimate choice for applications with their own, already-established flat-file logging conventions that an administrator wants preserved unchanged, but worth understanding as a genuine trade-off: output redirected this way loses the trusted-field tagging, boot-segmentation (Chapter 2, Section 4.2), and structured-query capability that the `journal` default provides, falling back instead to needing Chapter 4's `logrotate`-based management, since journald's own native retention (Chapter 4, Section 4) only governs data actually stored within the journal itself, not files a service has been redirected to write independently.

### 2.3 The Syslog Identifier and Structured Metadata

Beyond raw stdout/stderr capture, unit files can supply additional metadata that becomes part of the structured journal entry, directly enriching the field model Chapter 2, Section 3 described:

```
[Service]
SyslogIdentifier=myapp
SyslogFacility=local3
```

`SyslogIdentifier` sets the `SYSLOG_IDENTIFIER` field, and directly, mechanically bridges into Chapter 3's syslog-facility world when this data is subsequently read by rsyslog via `imjournal` — this is precisely the field rsyslog's traditional facility/severity-based selector rules key off, when routing journal-sourced data through the layered pipeline Chapter 3, Section 5.1 diagrammed. This is worth understanding as a concrete, practical instance of that diagram's abstract "journald as unified collector, rsyslog as routing layer on top" relationship — `SyslogIdentifier` and `SyslogFacility`, set at the unit-file level, are exactly the mechanism by which a `systemd`-managed service's output becomes correctly, deliberately routable by rsyslog's traditional facility-based rules downstream, rather than that routing needing to somehow infer facility information from raw, unstructured stdout content alone.

---

## 3. Log Levels From Application Code: How Severity Actually Gets Set

### 3.1 The Default: Everything Is "Informational" Unless Told Otherwise

A detail worth flagging precisely because it surprises people who assume severity is somehow automatically inferred from message content: plain stdout/stderr output captured via the default `journal` mechanism (Section 2.1) is **not** automatically parsed or classified by severity based on its text content — a message containing the word "error" is not automatically tagged as `PRIORITY=3` merely because that word appears in it. By default, stdout is tagged at `PRIORITY=6` (informational) and stderr at `PRIORITY=3` (error) — a coarse, stream-based default, not a content-based classification — meaning genuinely fine-grained severity control requires the application itself to explicitly communicate it, via one of the mechanisms Section 3.2 covers, rather than relying on journald or systemd to correctly infer intended severity from arbitrary message text.

### 3.2 Explicit Severity: The sd_notify and Native Journal APIs

Applications that want genuinely accurate, per-message severity — rather than the coarse stdout-versus-stderr default — can link against `libsystemd` and call the native journal-submission API directly:

```c
#include <systemd/sd-journal.h>

sd_journal_print(LOG_WARNING, "Configuration value %s is deprecated", key);
```

This directly submits a structured entry with the specified priority and message, alongside whatever additional trusted fields journald independently attaches (Chapter 2, Section 3.2) — the correct, most precise mechanism for an application that genuinely wants to participate fully in journald's structured model rather than relying on stdout/stderr's coarse default classification. A simpler, shell-script-friendly equivalent exists via the standalone `systemd-cat` utility, or via `logger`'s own priority-setting flags (Chapter 3, Section 6.1), both of which achieve the same explicit-severity outcome without requiring a program to link against `libsystemd` directly.

### 3.3 A Practical Convention: The `<N>` Prefix

Worth knowing as a lightweight, code-free middle ground between the coarse stdout/stderr default and the full native API: journald recognizes a specific text convention, inherited from the kernel's own printk-level convention, where a line beginning with a bracketed priority number is parsed and applied as that line's specific severity, even when arriving via plain stdout capture:

```
<3>This specific line is tagged as priority 3 (error), overriding the stdout default
<6>This line remains at the default informational level
```

This is a genuinely useful technique for scripts or simple programs that want more precise severity tagging than the blunt stdout/stderr split provides, without requiring the additional complexity of linking against a native logging library at all — worth knowing about specifically because it's a low-effort improvement many application authors are simply unaware exists.

---

## 4. Independently-Run Applications: The Other Category

### 4.1 Why Some Applications Don't Follow the systemd-Integrated Pattern

Returning to Section 1's categorical distinction: a substantial amount of software, particularly older applications predating widespread `systemd` adoption, or applications deliberately designed to be platform-agnostic (not assuming any specific init system at all), manages its own logging entirely independently — writing directly to files under `/var/log/` using its own internal file-handling logic, or calling the traditional `syslog()` C library function directly (which, per Chapter 3, Section 2.1, ultimately reaches journald or rsyslog via the shared `/dev/log` socket regardless of whether the specific application has any `systemd`-awareness at all).

This isn't inherently a deficiency — it's worth stating precisely that the traditional `syslog()` API path, still fully functional and fully integrated into the mechanisms this entire series has covered, remains an entirely legitimate, well-supported logging approach, not a legacy pattern actively worth migrating away from purely for its own sake. The genuinely important distinction for diagnostic purposes is simply knowing *which* path a specific piece of software actually uses, since that determines where to actually look for its output.

### 4.2 Diagnostic Implication: Where to Actually Look

Directly connecting to Section 1's framing, the practical diagnostic question — "where does this specific application's log output actually live" — resolves differently depending on category:

- **`systemd`-managed, default `journal` output** → `journalctl -u <unit-name>`, per Chapter 2's full query model.
- **`systemd`-managed, redirected to `file:`/`append:`** → the specific file path configured in the unit file's `StandardOutput=` directive (Section 2.2), requiring inspection of the unit file itself to determine the actual location if it's not already known.
- **Independently-run, using `syslog()`** → wherever rsyslog's configured selector/action rules (Chapter 3, Section 2.2) route messages matching that application's facility and program name, requiring inspection of `/etc/rsyslog.conf` and its included configuration files to determine the actual destination.
- **Independently-run, writing directly to its own files** → wherever the application's own configuration or documentation specifies, entirely outside any of the mechanisms this series has covered, discoverable only through the application's own documentation or, failing that, tools like `lsof` (Section 5.2) to directly observe what file descriptors the running process actually has open.

### 4.3 Finding an Application's Actual Log Location When Undocumented

This is worth a dedicated, practical technique, since "consult the documentation" isn't always sufficient in practice — genuinely undocumented or poorly documented software's actual log destination can be determined directly, empirically, from the running process itself:

```
lsof -p <pid> | grep -i log
```

`lsof` (list open files) directly enumerates every file descriptor a running process currently has open, including log files it's actively writing to — a reliable, documentation-independent way to determine exactly where a specific running process's output is actually going, regardless of what any configuration file or documentation might claim, since it reflects the process's actual, current, real behavior rather than its stated or intended configuration. This is worth treating as a standing diagnostic technique specifically for the "independently-run, undocumented destination" case Section 4.2's last bullet describes, where no other mechanism this series has covered can directly answer the question.

---

## 5. Correlating Application-Level Events With System-Level Context

### 5.1 The Cross-Referencing Problem

A genuinely common, practically important scenario worth its own treatment: an application-level log entry (an error message, a specific transaction failure) needs to be understood *in the context of* what else was happening on the system at the exact same moment — was there a concurrent resource-exhaustion event, a related service restart, a kernel-level warning — a question that requires correlating across the very mechanism boundaries this entire series has spent five chapters establishing as structurally distinct.

### 5.2 journalctl as the Natural Correlation Point

This is precisely where journald's unified, multi-source collection model (Chapter 2, Section 1.1) delivers its most direct practical value: because kernel messages, `systemd`-managed service output, and (via `imjournal`, Chapter 3, Section 2.1) even rsyslog-routed traditional syslog data can all converge into the same underlying structured store, a single, time-bounded `journalctl` query can surface *everything* the journal has captured across every one of these sources, for a specific narrow time window, without needing to manually cross-reference separate tools or separate flat files at all:

```
journalctl --since "2026-07-19 14:32:00" --until "2026-07-19 14:33:00"
```

This single, unfiltered, tightly time-bounded query — deliberately *not* restricted to a specific unit or facility — is worth recognizing as a distinct, genuinely valuable diagnostic pattern in its own right, directly exploiting journald's role as a unification point (Chapter 2, Section 1) to answer "what else was happening at exactly this moment" in a way that would otherwise require manually opening and time-correlating several entirely separate log files by hand.

---

## 6. Best Practices for Application Authors

This closing section is deliberately prescriptive, aimed specifically at the "what should a well-behaved service actually do" question this chapter's material implies, worth stating explicitly as direct, actionable guidance rather than leaving as an exercise for the reader to infer from the preceding mechanism-level material alone.

- **Prefer stdout/stderr under `systemd`, and let the default `journal` capture handle it**, per Section 2.1 — this is the lowest-effort path to full structured-logging integration, requiring no logging-library dependency at all for straightforward cases.
- **Use explicit severity (Section 3.2 or 3.3) rather than relying on the coarse stdout-versus-stderr default** for any application where accurate severity-based filtering and alerting genuinely matters — the default binary split is a reasonable fallback, not a substitute for genuine, message-level severity accuracy.
- **Set `SyslogIdentifier` explicitly (Section 2.3)** rather than relying on whatever default identifier `systemd` derives from the unit file name, particularly for applications that might be deployed under varying unit names across different environments — an explicit identifier keeps downstream rsyslog routing rules (Chapter 3) stable and predictable regardless of unit-naming variation.
- **Avoid writing directly to files under `/var/log/` from application code unless there's a specific, deliberate reason to bypass journald entirely** — direct file-writing forfeits structured querying, boot-segmentation, and unified journald-based correlation (Section 5.2) for no benefit in the overwhelmingly common case, and additionally requires the application itself, or its packaging, to correctly handle Chapter 4's rotation concerns independently, rather than benefiting from journald's own native retention management.
- **Document the actual logging destination explicitly**, precisely to spare a future administrator the `lsof`-based empirical investigation Section 4.3 describes — a small effort at documentation time that directly prevents a genuinely time-consuming diagnostic exercise later.

---

## 7. Common Misconceptions Worth Retiring Now

- **"An application needs to specifically integrate with journald's API to have its logs captured correctly."** Plain stdout/stderr output from any `systemd`-managed service is captured automatically by default, structured and tagged with trusted fields, with zero application-side logging-library dependency required at all.
- **"Log severity is automatically inferred from message content, like the presence of the word 'error.'"** It is not — the default is a coarse stdout-versus-stderr split (informational versus error), and genuinely accurate, message-level severity requires either the native journal API, the `<N>` prefix convention, or an equivalent explicit mechanism.
- **"All application logs, regardless of how the application is run, end up queryable through journalctl."** Only true for `systemd`-managed services using the default `journal` output target — services explicitly redirected to `file:`/`append:`, and independently-run applications writing directly to their own files, fall entirely outside journalctl's reach and require the destination-specific inspection techniques Section 4.2 covers.
- **"Writing directly to syslog() rather than using systemd's native journal API is an outdated, inferior approach."** It remains a fully legitimate, well-integrated logging path, reaching the same underlying infrastructure via `/dev/log` — the meaningful distinction for diagnostic purposes is simply knowing which path a given application actually uses, not that one path is categorically obsolete.
- **"If documentation doesn't specify where an application logs to, there's no reliable way to find out."** `lsof -p <pid>`, per Section 4.3, directly and empirically reveals a running process's actual open file descriptors, including active log files, entirely independent of whatever documentation does or doesn't say.

---

The next chapter turns to a category of logging with a fundamentally different purpose than anything covered so far: security and audit logging — the Linux audit subsystem, `auditd`, and how security-relevant event tracking differs structurally, in both mechanism and intent, from the general-purpose operational logging this chapter and its predecessors have focused on.
