# Log Rotation and Retention

Chapters 2 and 3 each flagged, in passing, that unbounded log growth is a real operational risk — journald's persistent storage (Chapter 2, Section 4.3) and rsyslog's flat-file outputs (Chapter 3) both accumulate data indefinitely unless something actively manages that growth. This chapter is the full treatment of that management problem: how `logrotate` handles traditional flat files, how journald's own native retention mechanisms work as a parallel, independent system, and the specific failure modes — and their real operational consequences — that arise when either is misconfigured or absent entirely.

---

## 1. Why Rotation Is Necessary At All

### 1.1 The Core Problem: Logs Are Append-Only and Disk Is Finite

Every logging mechanism this series has covered so far shares one structural property worth stating explicitly because it's the entire reason this chapter needs to exist: logs are, by their very nature, **append-only and perpetually growing** for as long as the system generating them continues to run and the logging pipeline continues to function correctly. Unlike most other data on a filesystem, which tends to have a natural, bounded size determined by its own content, a log file's size is a direct function of *how long the system has been running and how much log volume it generates per unit time* — meaning, left entirely unmanaged, any log file will eventually consume all available disk space on whatever filesystem it lives on, given sufficient uptime.

### 1.2 The Disk-Exhaustion Failure Mode, Made Concrete

This isn't a theoretical concern — it's worth walking through precisely what happens when it occurs, because the failure cascade is genuinely severe and disproportionate to how mundane "forgot to configure rotation" sounds as a root cause. When a filesystem fills completely, **every process attempting to write to that filesystem begins failing**, not merely the logging pipeline itself — and because `/var/log` is, on most standard distribution layouts, either part of the root filesystem or a dedicated but still finite mount, a full `/var/log` can cascade into failures well beyond logging: database writes failing, temporary file creation failing, package manager operations failing, and, in a specifically vicious feedback loop, **the logging system itself failing to write the very log entries that would have explained what was going wrong**, precisely at the moment those entries would be most valuable for diagnosis. Systems have genuinely been rendered effectively unusable, requiring manual, often console-level intervention to recover, purely from unrotated logs consuming 100% of available disk space — a failure mode entirely preventable through the mechanisms this chapter covers, which is exactly why rotation is treated as a mandatory, not optional, part of any production logging configuration, rather than a nice-to-have optimization.

### 1.3 The Two Independent Retention Systems

Directly connecting to Chapters 2 and 3's separate storage models: because journald and traditional flat-file logging (via rsyslog or direct application writes) are structurally distinct storage mechanisms, they require **two independent rotation and retention systems**, configured separately, each unaware of the other's state. `logrotate` manages traditional flat files; journald manages its own binary storage through its own, entirely separate size and time limits, briefly previewed in Chapter 2, Section 4.3. A common, consequential misconfiguration mistake is tuning one of these two systems carefully while forgetting the other exists at all — worth flagging explicitly here, at the start of this chapter, since both halves need deliberate attention for a genuinely complete, disk-exhaustion-resistant logging configuration.

---

## 2. logrotate: Mechanism and Configuration

### 2.1 What logrotate Actually Does

`logrotate` is not a daemon — it's a program typically invoked periodically (via a `cron` job or, on `systemd`-based systems, a `systemd` timer unit, `logrotate.timer`), which reads a set of configuration files describing rotation rules for specific log files or directories, and performs the actual rotation work each time it runs, rather than running continuously and monitoring file sizes in real time. This periodic-invocation model is worth understanding precisely, since it directly explains a specific, occasionally-surprising behavior: a log file can, in principle, grow well beyond its configured size threshold between two scheduled `logrotate` runs, if the configured check interval (commonly daily) is long relative to how quickly a specific log is actually accumulating data — logrotate enforces its limits only at the moments it actually runs, not continuously.

### 2.2 The Rotation Mechanism Itself

At its core, rotation works by **renaming** the current log file, then signaling the writing application (or simply relying on the next write to create a fresh file), rather than by actively truncating or editing the file's content in place:

```
access.log        →  access.log.1
access.log.1       →  access.log.2
access.log.2       →  access.log.3
...
access.log.N-1     →  access.log.N  (or deleted, if N exceeds the configured retention count)
```

A fresh, empty `access.log` is then created (or the application is signaled to reopen its log file, discussed in Section 2.4), and the writing application continues appending to this new, empty file going forward, while the renamed `access.log.1` retains the exact historical content the file held at the moment of rotation.

### 2.3 A Representative Configuration

```
/var/log/nginx/access.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
```

Each directive here maps onto a specific, deliberate design decision worth understanding individually rather than treating as boilerplate:

- **`daily`** — the rotation check interval; alternatives include `weekly`, `monthly`, or `size 100M` (rotate based on accumulated size rather than elapsed time, worth considering specifically for high-volume logs where a fixed daily interval might allow excessive growth between checks, per Section 2.1's caution).
- **`rotate 14`** — retain 14 rotated generations before the oldest is deleted entirely, directly determining the log's total retention window in combination with the rotation interval (here, roughly two weeks of daily-rotated history).
- **`compress`** — apply gzip compression to rotated files, trading CPU time during rotation for substantially reduced disk consumption for retained historical logs, a trade-off almost always worth making for logs retained beyond the most recent generation or two.
- **`delaycompress`** — specifically defer compression of the *most recently* rotated file by one additional rotation cycle, leaving `access.log.1` uncompressed while `access.log.2` onward are compressed — worth understanding precisely why this exists, covered in Section 2.4, since it's directly connected to a subtlety in how some applications handle file-write continuity across a rotation event.
- **`missingok`** — don't treat a missing log file (perhaps because the service hasn't run yet, or was already cleaned up) as an error condition worth failing the entire rotation run over.
- **`notifempty`** — skip rotation entirely if the log file is currently empty, avoiding the accumulation of pointless, empty rotated-file generations.
- **`create 0640 www-data adm`** — directly invoking the permissions series' own material: the newly created, post-rotation log file is explicitly stamped with a specific mode and ownership, ensuring the fresh file doesn't inherit some unintended default permission state, and specifically worth flagging as a place where the earlier permissions series' Chapter 4/5 material (explicit numeric mode, umask interaction) becomes directly, practically relevant within the logging domain.
- **`postrotate` / `endscript`** — a script block executed once, after rotation, here reloading `nginx` — the precise reason this step exists is the subject of Section 2.4, and skipping it is one of the most common, consequential logrotate misconfiguration mistakes.

### 2.4 The Reopen Problem: Why postrotate Scripts Exist

This is worth explaining at the mechanism level, because understanding *why* the `postrotate` step matters is what prevents a genuinely common, easy-to-make mistake. When `logrotate` renames `access.log` to `access.log.1`, the *inode* the writing application (nginx, in this example) already has open — via a file descriptor it acquired when it first opened the log file for writing — **does not change**. Renaming a file, per the permissions series' own Chapter 3 material on directory-versus-inode operations, changes only the directory entry, not the underlying inode itself; the application's already-open file descriptor continues to reference the exact same inode, now accessible only via the new `access.log.1` name, entirely unaware that a rotation has occurred at all from the application's own perspective.

This means that, absent any further action, the application would continue writing to what is now `access.log.1` — the renamed, "old" file — indefinitely, while the freshly created `access.log` (per the `create` directive) sits perpetually empty, since nothing has told the running application to close its existing file descriptor and open a new one against the new file. This is precisely the problem the `postrotate` script exists to solve: signaling the application (via a reload, a `SIGHUP`, or an application-specific reopen mechanism) to close and reopen its log file handle, causing it to pick up the newly created file going forward, rather than continuing to write into what has effectively become an orphaned, no-longer-visible-by-its-original-name file.

This same mechanism directly explains `delaycompress`'s purpose from Section 2.3: if compression were applied immediately upon rotation, there's a real risk that the application hasn't yet processed its reopen signal (a race between the rename-and-signal sequence and the application's own signal-handling responsiveness) and is still writing to the just-renamed file at the exact moment compression begins — compressing a file that's still being actively written to is, at minimum, wasteful and, in some scenarios, can produce a genuinely corrupted or truncated compressed archive. Deferring compression by one full rotation cycle ensures the file being compressed is unambiguously no longer receiving writes, since a full additional rotation interval has elapsed since the reopen signal was sent.

### 2.5 copytruncate: The Alternative for Applications That Can't Reopen

Some applications, particularly simpler scripts or programs with no built-in signal-handling or reopen logic at all, have no mechanism by which `postrotate` can prompt them to release and reacquire their log file handle. For exactly this case, `logrotate` offers an alternative strategy:

```
copytruncate
```

Rather than renaming the file and creating a fresh one, `copytruncate` **copies** the current log file's content to the rotated destination, then **truncates the original file in place**, back to zero length — critically, this means the application's existing, already-open file descriptor remains valid and continues referring to the *same* file, which has simply had its content emptied out from beneath it, requiring no reopen signal at all. This is a genuinely useful fallback for exactly the class of application Section 2.4 describes, but it carries a real, worth-flagging trade-off: there is a small window between the copy operation completing and the truncation taking effect during which any data the application writes is lost entirely — neither captured in the rotated copy (which was already taken before that write occurred) nor preserved in the now-truncated original (which has been reset to empty) — a genuine, if generally narrow, data-loss risk that `postrotate`-based rotation, done correctly, does not share, since renaming preserves 100% of the pre-rotation content unconditionally with no such gap.

---

## 3. Retention Policy Design: Time, Size, and Compliance

### 3.1 The Trade-Off Space

Retention policy — how long log data should be kept before permanent deletion — sits at the intersection of several, sometimes competing concerns worth naming explicitly, since a well-reasoned retention policy is a deliberate balance across all of them rather than an arbitrary number:

- **Disk capacity** — the straightforward, mechanical constraint Section 1 opened with; more retention requires more storage, full stop.
- **Operational usefulness** — how far back in time troubleshooting and incident investigation genuinely tends to need to reach; a security incident discovered weeks after the fact needs log data from well before its discovery, while routine day-to-day debugging rarely needs anything beyond the last few days.
- **Compliance and legal requirements** — many regulatory frameworks (covered in more security-specific depth in Chapter 7) impose *minimum* retention periods for specific categories of log data, particularly security-relevant and authentication logs, meaning retention policy is, in regulated environments, not purely a technical or cost-driven decision at all, but a genuine compliance obligation with real legal consequence for under-retention.
- **Privacy and data-minimization obligations** — working in the opposite direction from the compliance point above, some regulatory frameworks (particularly around personal data) impose *maximum* retention periods or requirements to purge data once its operational purpose has been served, meaning a genuinely correct retention policy in some environments needs to satisfy both a floor and a ceiling simultaneously, for potentially different categories of log data within the same system.

### 3.2 Differentiated Retention by Log Category

A direct, practical consequence of Section 3.1's trade-off space: a single, uniform retention period applied blanket-wide across every log on a system is rarely the actually-correct policy. A mature logging configuration typically differentiates:

```
/var/log/auth.log     { rotate 365  ... }   # security-relevant, longer retention for compliance/forensics
/var/log/nginx/access.log { rotate 30 ... } # operational, moderate retention for troubleshooting
/var/log/app-debug.log { rotate 7  ... }    # high-volume, low-value-per-entry, short retention
```

This differentiation is worth understanding as the direct, practical application of Section 3.1's competing-concerns framework to real configuration decisions — security and authentication logs (directly previewing Chapter 7's material) generally warrant the longest retention given their compliance and forensic value, while high-volume, low-diagnostic-value debug output is a reasonable candidate for aggressive, short retention specifically because its storage cost-to-value ratio is poor relative to the other categories.

---

## 4. journald's Native Retention: A Parallel, Independent System

Directly returning to Section 1.3's warning, this section covers the second retention system every complete logging configuration needs to address, entirely separately from Section 2's `logrotate` material.

### 4.1 The Relevant Directives, in Full

```
[Journal]
SystemMaxUse=4G
SystemKeepFree=1G
SystemMaxFileSize=128M
SystemMaxFiles=100
RuntimeMaxUse=200M
MaxRetentionSec=1month
MaxFileSec=1week
```

Worth distinguishing precisely, since the `System*` and `Runtime*` prefixes correspond directly to Chapter 2, Section 2's persistent-versus-volatile storage distinction: `SystemMaxUse` and related `System*` directives govern the persistent journal under `/var/log/journal/`, while `RuntimeMaxUse` governs the volatile journal under `/run/log/journal/` — two independently configurable size ceilings, appropriate since the two storage locations have entirely different underlying capacity constraints (persistent storage bounded by disk capacity, volatile storage bounded by available RAM, a considerably more precious and typically much smaller resource on most systems).

`SystemMaxFileSize` and `MaxFileSec` govern individual journal *file* rotation — journald, like logrotate, doesn't keep writing indefinitely into one ever-growing file, but periodically rotates to a fresh journal file, governed by either a size or time threshold, whichever triggers first — while `SystemMaxUse` and `MaxRetentionSec` govern the *aggregate* retention ceiling across all retained files combined, with journald automatically deleting its own oldest files once either the aggregate size or aggregate time ceiling is exceeded, entirely independent of and without needing any external tool like `logrotate` to manage this on its behalf.

### 4.2 Why journald Manages Its Own Retention Rather Than Delegating to logrotate

This is worth explaining precisely, since a newcomer familiar with Section 2's `logrotate` model might reasonably wonder why journald doesn't simply use the same external, periodic-invocation tool for consistency. The direct, mechanism-level answer connects back to Chapter 2, Section 4.1's core fact: journal files are binary, indexed, structured storage, not append-only flat text — `logrotate`'s entire rename-and-recreate model assumes a writing application that can be signaled to simply reopen a plain file handle, per Section 2.4's mechanism, an assumption that doesn't transfer cleanly onto journald's considerably more structurally complex, indexed binary storage format, where "rotation" instead means finalizing one structured storage segment and beginning a fresh one, a journald-internal operation journald itself is far better positioned to manage correctly than an external, format-unaware tool could be.

### 4.3 Checking Actual Current Usage

```
journalctl --disk-usage
```

This directly reports the journal's current total on-disk footprint, worth checking specifically as a verification step any time `SystemMaxUse` or related limits are adjusted, or as a routine part of the disk-capacity monitoring Section 5 discusses more generally — a fast, authoritative answer to "how much space is the journal actually consuming right now," considerably more reliable than attempting to sum file sizes manually across `/var/log/journal/`'s directory structure by hand.

---

## 5. Monitoring and Alerting on Log-Related Disk Usage

This closing section connects Section 1's disk-exhaustion failure mode directly to a practical, preventive operational practice, worth treating as a standing recommendation rather than an afterthought.

### 5.1 Why Rotation Configuration Alone Isn't Sufficient Assurance

Even a correctly configured rotation and retention policy, covering both `logrotate` (Section 2) and journald (Section 4), doesn't fully eliminate disk-exhaustion risk on its own — a sudden, anomalous spike in log volume (a misbehaving application entering a tight error-logging loop, for instance, an entirely realistic scenario this exact chapter's own subject matter is meant to help diagnose after the fact) can, in principle, still exhaust available disk space *between* scheduled rotation runs, precisely per Section 2.1's periodic-invocation caveat, even with otherwise entirely sensible retention limits configured. This is worth stating explicitly because it's a genuine gap: rotation and retention policy manage *steady-state, expected* log growth correctly, but don't, by themselves, provide any protection against sudden, anomalous volume spikes occurring within a single rotation interval.

### 5.2 The Complementary Practice: Active Disk-Usage Monitoring

The correct complement, worth treating as a standing, independent operational practice rather than something rotation configuration substitutes for, is active monitoring of `/var/log`'s (and, separately, `/var/log/journal`'s, since the two may live on different filesystems depending on deployment) disk usage, with alerting thresholds set well below actual exhaustion — giving an administrator genuine advance warning and time to intervene (identifying and addressing a runaway logging source, or performing emergency manual rotation) well before the cascading failure mode Section 1.2 described actually occurs, rather than discovering the problem only once the filesystem has already filled completely and the cascade has already begun.

---

## 6. Common Misconceptions Worth Retiring Now

- **"logrotate runs continuously, checking file sizes in real time."** It's a periodically invoked tool, typically via a daily timer or cron job, checking and acting only at the moments it actually runs — a log can, in principle, grow well past its configured threshold between two scheduled invocations.
- **"Renaming a log file during rotation is enough; the application will automatically start writing to the new file."** Without a `postrotate` reopen signal (or `copytruncate`'s alternative approach), a running application's already-open file descriptor continues referencing the renamed, old file indefinitely, writing into what has become an effectively invisible, orphaned file, while the freshly created file sits empty.
- **"journald's retention is managed by logrotate, just like traditional flat files."** journald manages its own, entirely independent retention limits natively, precisely because its binary, structured storage format doesn't fit logrotate's rename-and-signal model at all — the two systems require separate, deliberate configuration.
- **"A single retention period is appropriate for all logs on a system."** Different log categories carry genuinely different operational, compliance, and privacy considerations (Section 3.1), and a mature configuration differentiates retention accordingly rather than applying one blanket policy uniformly.
- **"Configuring rotation and retention correctly eliminates all disk-exhaustion risk from logging."** It manages expected, steady-state growth, but doesn't by itself protect against a sudden, anomalous volume spike occurring within a single rotation interval — active disk-usage monitoring remains a necessary, independent complementary practice.

---

The next chapter turns to the kernel ring buffer and boot-time logging introduced briefly back in Chapter 1, Section 3 — the full mechanism of how `dmesg` works, why kernel messages exist entirely outside the rotation and retention systems this chapter has covered, and the specific diagnostic techniques relevant to boot-time and early-kernel troubleshooting.
