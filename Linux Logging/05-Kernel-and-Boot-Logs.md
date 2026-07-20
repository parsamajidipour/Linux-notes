# Kernel and Boot Logs

Chapter 1, Section 3 established the foundational fact this entire chapter builds out in full: the kernel writes its own diagnostic output into an in-memory ring buffer, entirely independent of any userspace logging daemon, because no userspace process — including the daemons covered in Chapters 2 and 3 — exists yet at the earliest points in the boot sequence. This chapter covers that ring buffer's precise mechanism, the full anatomy of the boot sequence from the kernel's perspective, and the specific diagnostic techniques relevant to troubleshooting failures that occur before or during the window when the mechanisms covered in earlier chapters even become available.

---

## 1. The Kernel Ring Buffer: Precise Mechanism

### 1.1 What "Ring Buffer" Actually Means

A ring buffer (also called a circular buffer) is a fixed-size block of memory that, once full, begins **overwriting its oldest entries** as new entries are written, rather than growing indefinitely or requiring an active management process to periodically rotate or truncate it, the way Chapter 4's `logrotate` mechanism has to for flat files. This structural choice is worth understanding as a deliberate, direct consequence of the boot-order constraint Chapter 1 identified: the kernel needs somewhere to write diagnostic output starting from the very earliest moments of its own execution, with a bounded, statically-allocated amount of memory, and with no possibility of relying on any external process to manage or grow that storage — a fixed-size, self-managing circular buffer is precisely the structure that satisfies "always available, bounded memory footprint, requires zero external management" simultaneously.

### 1.2 Buffer Size and Configuration

The ring buffer's size is configurable, both at compile time (a kernel configuration option) and at boot time, via a kernel command-line parameter:

```
log_buf_len=1M
```

This can also be inspected and, within limits, adjusted at runtime for some kernel versions via `/sys/kernel/debug/tracing` mechanisms or, more commonly for straightforward inspection, checked via `dmesg`'s own reporting of buffer statistics. The practical, operational consequence worth flagging clearly: a **larger buffer retains more history before the oldest entries begin being overwritten**, which matters directly for boot-time diagnosis — a system with a verbose boot sequence (extensive hardware detection, many loaded kernel modules, verbose driver initialization messages) and a comparatively small ring buffer can, in principle, have its earliest boot messages already overwritten by the time an administrator gets a chance to inspect `dmesg` output, a genuine practical limitation worth being aware of specifically when diagnosing problems in the very earliest phase of system startup, and directly relevant to why Section 4's persistent boot-log mechanisms exist as a complement to the ring buffer's inherently volatile, size-bounded nature.

### 1.3 Why the Ring Buffer Is Necessarily Volatile

Directly connecting to Chapter 2, Section 2's volatile-versus-persistent distinction for journald: the kernel ring buffer is **always** volatile, in-memory storage, with no equivalent to journald's `Storage=persistent` option, and this is worth understanding as an unavoidable structural consequence rather than a missing feature the kernel simply hasn't implemented. The kernel itself has no built-in filesystem-writing capability at the point the earliest ring-buffer entries are generated — filesystem mounting is itself a *later* boot-sequence step (Section 3), meaning any mechanism for the kernel to persist its own log data to disk would require the kernel to already have working, mounted disk storage available at a point in the boot sequence *before* that storage has actually been mounted, a genuine chicken-and-egg structural impossibility the ring buffer's pure in-memory design entirely sidesteps by simply not depending on disk availability at all.

---

## 2. dmesg: The Direct Interface to the Ring Buffer

### 2.1 Basic Usage

```
dmesg                    # dump the entire current ring buffer contents
dmesg -w                 # follow mode, directly analogous to journalctl -f
dmesg -T                 # human-readable timestamps, rather than raw boot-relative seconds
dmesg -l err,crit,alert,emerg    # filter by severity, reusing the exact scale from Chapter 1, Section 6
dmesg -k                 # kernel messages only (relevant on systems where dmesg can also show userspace-injected messages)
```

### 2.2 Timestamp Format: A Detail Worth Precision

Raw `dmesg` output, without the `-T` flag, displays timestamps as **seconds since boot**, not wall-clock time:

```
[    4.213891] usb 1-1: new high-speed USB device number 2 using xhci_hcd
```

This is worth explaining precisely rather than treating as a cosmetic quirk, because it connects directly to Section 1.3's structural constraint: at the point the earliest ring-buffer entries are generated, the kernel may not yet have a reliably synchronized wall-clock time available at all (real-time clock reading and NTP synchronization are themselves later, and in NTP's case, distinctly post-boot, steps) — boot-relative seconds is a timestamp basis the kernel can compute unconditionally, from the moment it starts counting at its own initialization, entirely independent of whether any accurate wall-clock reference has been established yet. `dmesg -T` performs a *post-hoc* conversion, calculating an approximate wall-clock timestamp by working backward from the current system time and the recorded boot-relative offset — worth flagging as an approximation rather than a natively-recorded wall-clock value, with the specific, occasionally-relevant caveat that this conversion can be measurably inaccurate if the system clock has been adjusted (manually, or via a large NTP correction) at some point since boot, since the conversion calculation implicitly assumes the current clock reading and the boot-relative offset are consistently related throughout the entire uptime period, an assumption a significant clock adjustment can violate.

### 2.3 dmesg and journald's Kernel-Message Ingestion, Reconciled

Directly connecting to Chapter 2, Section 1.1's mention of journald reading from the kernel ring buffer as one of its several input sources: `dmesg` and `journalctl -k` (journald's own kernel-message-filtered view) will, on a running system, generally show substantially overlapping content, since both are ultimately sourced from the same underlying kernel messages — but they are **not** identical in scope or behavior, and the distinction is worth stating precisely. `dmesg` reads directly from the kernel's own ring buffer, live, at the moment it's invoked, and is therefore bounded by whatever the ring buffer currently retains (subject to Section 1.2's overwrite behavior); `journalctl -k`, by contrast, reads from journald's *own* stored copy of kernel messages, which — if journald is configured for persistent storage per Chapter 2, Section 2 — can retain kernel messages from **prior boots** as well, entirely unconstrained by the current, single ring buffer's fixed size and overwrite behavior, since journald copies each message out of the ring buffer into its own, separately-managed persistent storage at the time the message is generated, rather than continuing to depend on the ring buffer's own limited retention after that point. This is precisely why `journalctl -k -b -1` (kernel messages specifically from the previous boot, directly combining Chapter 2, Section 4.2's per-boot segmentation with a kernel-message filter) is possible at all, while the equivalent query against `dmesg` alone, which only ever reflects the *current* boot's ring buffer, structurally cannot be constructed — a genuinely important practical distinction when diagnosing a problem from a prior, already-completed boot session.

---

## 3. The Boot Sequence, From the Kernel's Perspective

Understanding the full boot sequence's rough shape is what makes sense of *where* different categories of boot-time messages originate, and precisely when the mechanisms covered in Chapters 2 and 3 actually become available to take over from the kernel's own, self-contained early logging.

### 3.1 The Ordered Phases

```
1. Firmware / bootloader (UEFI or BIOS, then GRUB or equivalent)
       — occurs entirely before the kernel itself is even loaded into memory;
         not kernel log content at all, though firmware-level logs may exist separately (Section 5)

2. Kernel initialization
       — the kernel decompresses and begins executing; ring buffer becomes active
         essentially immediately, since it requires nothing beyond the kernel's own
         already-running code and statically allocated memory

3. Hardware detection and driver initialization
       — the bulk of dmesg's most voluminous, familiar-looking content:
         device enumeration, driver binding, subsystem initialization messages

4. Root filesystem mount
       — the kernel mounts (or hands off to an initramfs which mounts) the root
         filesystem; this is the specific point at which disk-backed storage
         first becomes available at all during the boot sequence

5. init / systemd handoff
       — the kernel executes the configured init system (systemd, on most modern
         distributions) as PID 1; from this point forward, userspace processes
         begin starting, and the mechanisms covered in Chapters 2 and 3 become
         progressively available as journald and (if configured) rsyslog
         themselves start up as part of this same userspace startup sequence

6. Service startup
       — systemd starts the remaining configured services in dependency order;
         service-specific logging (Chapter 6's subject) begins as each service
         itself starts and begins producing output
```

### 3.2 The Critical Handoff Window

Phase 5 in this sequence deserves specific attention, because it's the precise, mechanical point where this chapter's subject matter and Chapter 2's subject matter meet. Everything generated during phases 1 through 4 exists **only** in the kernel ring buffer at the moment of generation, since no userspace logging daemon has started yet — journald itself is, after all, a userspace process, started by `systemd` as part of phase 5, not before it. Once journald *does* start, one of its first actions is precisely the kernel-message ingestion Section 2.3 described — reading the ring buffer's *entire current contents*, not merely messages generated from that point forward, and incorporating that full backlog into its own structured storage. This is why, on a system with journald running normally, `journalctl -b` (current boot) genuinely does include the very earliest kernel messages from phase 2 onward, despite journald itself not having existed as a running process at the time those specific messages were originally generated — the ring buffer's own persistence across the phase 2-through-5 gap is precisely what makes this retroactive ingestion possible at all, directly validating Section 1's framing of the ring buffer as the necessary bridge across exactly this specific, otherwise-unavoidable "no logging daemon exists yet" gap.

### 3.3 What Happens When the Handoff Fails

This is worth examining directly because it's precisely the failure category this chapter's diagnostic techniques exist for: if something goes wrong **during** phase 4 or 5 — a root filesystem that fails to mount, an init system that crashes or fails to start correctly — the system may never reach the point where journald (or rsyslog) is running at all, meaning **none** of Chapter 2 or Chapter 3's tooling is available for diagnosis, since the very daemons those chapters cover are themselves among the things that failed to start. This is precisely the scenario where the kernel ring buffer's boot-order-independent availability becomes not merely convenient but the *only* diagnostic resource actually available — and it's why the boot-time diagnostic techniques covered in Section 4 specifically don't depend on journald or rsyslog being operational at all, unlike essentially every other technique covered elsewhere in this series.

---

## 4. Diagnosing Boot Failures: Techniques That Don't Depend on a Running Logging Daemon

### 4.1 Serial Console and Kernel Command-Line Logging Parameters

For failures severe enough that the system doesn't even reach a normally usable state, the kernel supports several command-line parameters — set via the bootloader, typically GRUB — that increase the verbosity and destination options for early boot output, worth knowing as the first line of defense when standard, post-boot diagnostic tools simply aren't available because the system never got far enough to make them available:

```
console=ttyS0,115200    # direct kernel console output to a serial port,
                          # useful for remote/headless diagnosis via serial
                          # console access, entirely independent of any
                          # graphical or even standard virtual-console display

loglevel=7                # maximize kernel console verbosity (directly using
                          # Chapter 1, Section 6's severity scale — 7 corresponds
                          # to debug-level messages being displayed on console,
                          # not merely retained in the ring buffer)

systemd.log_level=debug   # analogous verbosity increase, but for systemd's
                          # own userspace startup logging specifically, once
                          # the boot sequence reaches phase 5
```

### 4.2 systemd-analyze: Diagnosing Slow or Failed Boots at the Service Level

Once phase 5 is reached, even if some individual service subsequently fails, `systemd` itself provides tooling specifically for boot-sequence diagnosis that sits conceptually between raw kernel-ring-buffer inspection and full journald-based service log analysis (Chapter 6's subject):

```
systemd-analyze              # total boot time breakdown, kernel vs userspace
systemd-analyze blame        # per-unit startup time, sorted, for finding what's slow
systemd-analyze critical-chain   # the dependency chain that determined total boot time
```

Worth flagging specifically why this belongs in a boot-focused chapter rather than deferred entirely to Chapter 6's service-logging material: these tools are specifically boot-sequence-aware in a way general service-log inspection isn't — `critical-chain` in particular directly answers "what specific sequence of service dependencies is actually responsible for how long this boot took," a question meaningfully different from "what did this specific service log," and one that requires systemd's own boot-sequence-tracking data, not merely the aggregated log content any individual service produced.

### 4.3 The Emergency and Rescue Targets

When boot fails badly enough that normal service startup can't proceed, `systemd` provides fallback targets specifically designed to drop into a minimal, diagnostic-capable state rather than either fully completing a broken boot or leaving the administrator with no interactive access at all:

```
systemctl isolate rescue.target      # minimal single-user-like state, most services stopped
systemctl isolate emergency.target   # even more minimal — root shell, filesystems not fully mounted
```

These targets are worth understanding as deliberately positioned along the boot-sequence spectrum Section 3.1 laid out — `emergency.target` intentionally stops *before* the full filesystem-mounting and service-startup machinery that might itself be the source of the boot failure being diagnosed, providing a stable, minimal foothold specifically so an administrator can use exactly the kernel-ring-buffer-based tools this chapter covers (which, per Section 1.3, require nothing beyond the kernel itself) to diagnose why the fuller boot sequence isn't completing successfully, without that diagnosis effort itself being blocked by the very failure under investigation.

---

## 5. Firmware-Level Logging: Beyond the Kernel's Own Scope

Worth a brief, precise mention because it represents the boundary of what even the kernel ring buffer itself can capture, extending Section 3.1's phase 1 note. Modern UEFI firmware maintains its own logging mechanism, entirely independent of and preceding the Linux kernel's own initialization — accessible, on systems that support it, through `mokutil`, firmware-specific diagnostic menus accessible before the bootloader even hands off to the kernel, or, once Linux is running, partially surfaced through mechanisms like:

```
dmesg | grep -i "efi\|acpi"
```

Which shows kernel-level messages *about* information the kernel received from firmware during its own initialization (Section 3.1, phase 2), not the firmware's own, separate internal log — worth understanding as a genuinely distinct boundary: firmware-level failures (a hardware initialization problem occurring before the kernel is even loaded at all) can, in the most severe cases, prevent the kernel from ever generating ring-buffer content in the first place, a failure category entirely outside the scope of anything Linux-level logging, including this entire chapter's material, can directly diagnose — worth knowing about specifically so a truly severe, pre-kernel boot failure isn't mistakenly approached with Linux-logging-focused diagnostic techniques that structurally cannot capture anything about a problem occurring before the kernel itself has even started running.

---

## 6. Practical Diagnostic Workflow: A Worked Sequence

Bringing this chapter's material together as an ordered, practical sequence, directly parallel in spirit to the permissions series' own diagnostic methodology chapters:

1. **If the system reaches a normal, interactive state at all**, start with `journalctl -b` and `journalctl -k -b`, per Section 2.3 — journald's persistent, structured storage of the current boot's kernel messages is generally the most convenient, richly-queryable starting point, assuming journald itself started successfully.
2. **If a specific prior boot is the concern** (a crash that occurred yesterday, say), `journalctl --list-boots` followed by `journalctl -b <offset>`, directly leveraging Chapter 2, Section 4.2's per-boot segmentation — a capability, per Section 2.3, that raw `dmesg` alone cannot provide at all, since it only ever reflects the single, current boot's ring buffer.
3. **If journald itself appears not to have captured expected kernel messages**, or if working on a system where journald's persistent storage isn't configured (Chapter 2, Section 2), fall back to raw `dmesg`, understanding its boot-relative timestamp format (Section 2.2) and its volatility (Section 1.3) — useful specifically for the current boot only, with no history beyond it.
4. **If the system fails to reach a normal interactive state at all**, per Section 3.3's failure category, move to `systemd-analyze` and the rescue/emergency targets (Section 4.2, 4.3), and, for failures severe enough that even these aren't reachable, kernel command-line parameters for serial console output and increased verbosity (Section 4.1), configured via bootloader access rather than from within a running system at all.
5. **If none of the above yield any kernel-level output whatsoever**, per Section 5's boundary, consider whether the failure is occurring at the firmware level, entirely before the Linux kernel's own initialization — a category this chapter's tools cannot directly address, requiring firmware-specific diagnostic approaches instead.

---

## 7. Common Misconceptions Worth Retiring Now

- **"dmesg and journalctl -k show exactly the same thing."** They largely overlap on a running system's current boot, but differ meaningfully in scope: `dmesg` is bounded by the ring buffer's fixed size and current-boot-only availability, while `journalctl -k`, with persistent storage configured, retains kernel messages across multiple boots, a capability `dmesg` structurally cannot offer.
- **"The kernel could persist its own log to disk if it were configured to, the same way journald can."** It cannot, as a structural matter — disk storage isn't mounted yet at the point the earliest, often most diagnostically valuable boot messages are generated, a genuine chicken-and-egg constraint the ring buffer's pure in-memory design specifically exists to work around.
- **"dmesg's timestamps are wall-clock time by default."** They're seconds since boot by default; `-T` performs an approximate, post-hoc conversion to wall-clock time, one that can be measurably inaccurate following a significant system clock adjustment during uptime.
- **"If journalctl and dmesg both show nothing useful, the boot problem is unfixable/undiagnosable."** It typically means the failure occurred at a point before or outside what either tool can capture — Section 4's bootloader-level and serial-console techniques, or, in the most severe cases, firmware-level diagnosis (Section 5), remain available even when neither of the standard Linux-level tools has anything to show.
- **"A larger ring buffer is strictly better with no downside."** A larger buffer retains more boot history before overwriting begins, genuinely useful for verbose boots, but it does consume a correspondingly larger, statically-allocated chunk of memory throughout the system's entire uptime, a real, if often small in absolute terms, resource trade-off worth being aware of rather than assuming is entirely free.

---

The next chapter turns from the kernel's own boot-time logging to the userspace side of the same overall pipeline: application and service log conventions — where well-behaved services should write output, the specific patterns `systemd` unit configuration expects for correct log capture into journald (directly building on this chapter's Section 3.2 handoff discussion), and the practical difference between services that integrate cleanly with the mechanisms this series has covered and those that don't.
