# rsyslog and Syslog

Chapter 2 covered `journald` as the structured, integrated logging daemon at the center of most modern distributions. This chapter covers the mechanism that predates it by decades and continues to coexist alongside it on the overwhelming majority of production systems: the syslog protocol lineage, and its dominant modern implementation, `rsyslog`. Understanding this chapter is what makes the "coexistence" relationship Chapter 1 and Chapter 2 both gestured toward concrete and mechanical, rather than a vague gesture at "legacy compatibility."

---

## 1. The Syslog Protocol: Origins and Core Model

### 1.1 A Protocol, Not Just a Daemon

It's worth being precise from the outset about a distinction that's easy to blur: **syslog is a protocol** — a defined message format and transport convention, standardized (in its modern form) as RFC 5424, with an older, looser convention documented retroactively as RFC 3164 — and `rsyslog` is one specific, widely deployed **implementation** of a daemon that speaks this protocol, not the protocol itself. Other implementations exist (`syslog-ng` being the most notable alternative), and understanding this separation matters because it explains why syslog-format log messages remain broadly interoperable across different tools and different decades of software, independent of which specific daemon happens to be running on any given system — the protocol's stability, not any one implementation's specifics, is what has kept syslog-format logging a durable, widely-supported convention since the 1980s.

### 1.2 The Facility/Severity Model

Chapter 1, Section 6 introduced the eight-level severity scale as a vocabulary shared across every logging mechanism this series covers — that scale originates directly from syslog, and this chapter is where its full context belongs. Syslog messages carry not only a severity level but also a **facility** — a coarse categorization of *what kind of system component* generated the message, entirely independent of how severe the specific event is:

| Facility number | Name | Typical source |
|---|---|---|
| 0 | kern | Kernel messages |
| 1 | user | Generic user-level processes |
| 2 | mail | Mail subsystem |
| 3 | daemon | System daemons generally |
| 4 | auth | Authentication/security (historically) |
| 5 | syslog | The syslog daemon's own internal messages |
| 6 | lpr | Printing subsystem |
| 7 | news | Usenet news (largely obsolete in modern usage) |
| 8 | uucp | Unix-to-Unix Copy (largely obsolete) |
| 9-15 | (reserved/clock/auth variants) | Cron, security auditing, and related |
| 16-23 | local0–local7 | Reserved for site-specific, administrator-defined use |

The facility/severity combination together forms what syslog calls the **priority**, encoded numerically as `facility * 8 + severity` — a single integer packing both dimensions, worth knowing exists as the underlying wire representation even though most practical configuration and querying work, covered in Section 3, references facility and severity by their symbolic names rather than working with the packed numeric form directly.

This two-dimensional categorization — facility for *source category*, severity for *how bad* — is worth contrasting directly with journald's field model from Chapter 2: syslog's facility/severity is a fixed, limited-cardinality classification baked into the protocol itself, while journald's structured fields (Chapter 2, Section 3) are an open-ended, arbitrary key-value system. This is a genuine, consequential difference in expressiveness, and it's part of why journald-native structured querying (Chapter 2, Section 5.2) can filter on dimensions — a specific `_SYSTEMD_UNIT`, a specific `_PID` — that syslog's facility/severity model has no native equivalent for at all; syslog messages can only be categorized along the two dimensions the protocol itself defines.

### 1.3 The `local0`–`local7` Facilities: A Deliberate Escape Hatch

Worth a specific mention because it's a genuinely useful, still-relevant pattern: the eight `local` facilities exist specifically because the protocol's designers anticipated that its fixed, predefined facility list wouldn't cover every organization's needs, and reserved this range explicitly for administrator- or application-defined categorization — a custom application might log under `local3`, for instance, purely by administrator convention, allowing that application's messages to be filtered, routed, or retained differently from the rest of the system's syslog traffic without requiring any change to the protocol itself. This remains a practical technique worth knowing, particularly in environments still relying heavily on facility-based routing rather than having fully migrated to structured, field-based filtering.

---

## 2. rsyslog's Architecture: Input, Processing, Output

`rsyslog`'s own architecture is best understood as a **pipeline**: messages enter through one or more configured input modules, pass through optional filtering and transformation rules, and exit through one or more configured output modules — a considerably more modular and extensible design than the original, much simpler syslog daemon implementations from decades earlier, worth understanding in this three-stage shape before looking at any specific configuration syntax.

### 2.1 Input Modules

```
module(load="imuxsock")   # Unix domain socket, /dev/log — local process logging
module(load="imklog")     # kernel log messages
module(load="imtcp")      # receive syslog messages over TCP, from remote hosts
module(load="imudp")      # receive syslog messages over UDP, from remote hosts
module(load="imjournal")  # read directly from the systemd journal
```

The `imuxsock` module deserves specific attention because it's the direct mechanical link back to Chapter 2, Section 1.1's mention of `/dev/log` — this is the same socket journald also listens on, and on a typical modern distribution, **only one of the two daemons actually binds `/dev/log` directly**, with the other receiving data through a different path — most commonly, journald owns `/dev/log` directly (since it starts earlier in boot and is more tightly integrated with `systemd`), and rsyslog instead uses `imjournal` to read data back out of the journal itself, rather than both daemons contending for the same socket. This exact arrangement — journald as the primary local collector, rsyslog reading from it via `imjournal` and then applying its own richer routing and long-term flat-file storage on top — is the specific, mechanical shape of the "coexistence" relationship Chapter 1 and Chapter 2 both referenced without fully detailing, and it's worth having this concrete picture in mind rather than a vague sense that the two "just work together somehow."

### 2.2 Rules: Selectors and Actions

The traditional, still widely used rsyslog configuration syntax pairs a **selector** (facility and severity criteria) with an **action** (what to do with matching messages):

```
mail.*                          /var/log/mail.log
*.emerg                         :omusrmsg:*
auth,authpriv.*                 /var/log/auth.log
local3.info                     /var/log/custom-app.log
kern.*;mail.none                 /var/log/kernel-not-mail.log
```

Reading this syntax precisely: `mail.*` selects every severity for the `mail` facility; `*.emerg` selects the `emerg` (emergency, severity 0) level across every facility; `auth,authpriv.*` combines two facilities in a single selector; `kern.*;mail.none` demonstrates the exclusion syntax, selecting all kernel messages while explicitly excluding the mail facility entirely from this particular rule — worth flagging since selector composition, including such exclusions, is a common source of subtle misconfiguration when multiple rules interact.

The `:omusrmsg:*` action target is worth explaining specifically: it directs matching messages to be delivered as a direct message to logged-in users' terminals (the `*` meaning all currently logged-in users) — a legacy but still-functional mechanism for ensuring genuinely emergency-level events get immediate, impossible-to-miss visibility, independent of whether anyone happens to be actively watching a log file or dashboard at that exact moment.

### 2.3 Modern RainerScript Syntax

Contemporary rsyslog configuration increasingly uses a more expressive syntax called RainerScript, which supports genuine conditional logic beyond the traditional selector/action pairing:

```
if $programname == 'sshd' and $syslogseverity <= 4 then {
    action(type="omfile" file="/var/log/ssh-warnings.log")
    stop
}
```

This is worth flagging specifically because it represents rsyslog's own answer to some of the expressiveness limitations Section 1.2 identified in the traditional facility/severity model — RainerScript's conditional expressions can reference message content, program name, and other properties well beyond the protocol's native two-dimensional categorization, narrowing at least part of the gap with journald's structured-field flexibility, though still fundamentally operating over parsed-out properties of what remains, ultimately, a text-based message format at its core, rather than a natively structured storage model the way journald's binary format is from the ground up.

### 2.4 Output Modules and Templates

Beyond simple flat-file output, rsyslog supports a range of output modules directly relevant to the centralized-logging material Chapter 9 develops in full:

```
module(load="omfwd")     # forward to a remote syslog server
module(load="ommysql")   # write directly into a MySQL database
module(load="omelasticsearch")  # write into an Elasticsearch index
```

Combined with **templates** — rsyslog's mechanism for controlling the exact output format of log entries, including structuring them as JSON rather than the traditional flat-line format — this output-module flexibility is precisely what allows rsyslog to serve as a genuine transport and transformation layer between local log collection and a wide variety of remote or structured storage backends, a role Chapter 9 examines in operational depth.

---

## 3. Legacy syslog Message Format Versus Modern RFC 5424

Worth a dedicated, precise comparison, because format inconsistency across the syslog ecosystem's long history is a genuine, practical source of parsing difficulty that Section 1.1's "protocol stability" framing shouldn't be read as glossing over entirely.

### 3.1 The Legacy (RFC 3164) Format

```
<34>Oct 11 22:14:15 mymachine su: 'su root' failed for lonvick on /dev/pts/8
```

The leading `<34>` is the packed priority value from Section 1.2's formula; the timestamp format that follows — `Oct 11 22:14:15` — carries no year and no timezone information at all, a genuinely significant limitation directly connecting back to Chapter 1, Section 7's timestamp-precision concerns: a log line in this format is fundamentally ambiguous about which year it belongs to without external context (typically, the file's own modification metadata or surrounding entries), and carries no timezone information whatsoever, making precise cross-host correlation (Chapter 9's concern) genuinely difficult without additional, out-of-band assumptions about the originating system's local timezone configuration.

### 3.2 The Modern (RFC 5424) Format

```
<34>1 2026-07-19T22:14:15.003Z mymachine su - ID47 - 'su root' failed for lonvick on /dev/pts/8
```

The `1` immediately after the priority bracket is an explicit format-version indicator; the timestamp is now full ISO 8601, including year, explicit UTC offset (`Z` here indicating UTC directly), and sub-second precision — directly resolving Section 3.1's ambiguity problem. RFC 5424 additionally introduces **structured data** fields (not shown in this minimal example, but supported as an optional bracketed segment), a genuine, if limited, syslog-protocol-native step toward the kind of structured key-value richness Chapter 2 covered as journald's core design principle — worth understanding as the syslog ecosystem's own, later, partial convergence toward structured logging's advantages, rather than structured logging being an idea unique to journald's specific design.

### 3.3 Why Both Formats Still Coexist in Practice

Despite RFC 5424's clear improvements, an enormous amount of still-deployed software, and a considerable fraction of rsyslog's own default configuration on many distributions, continues to use or accept the legacy RFC 3164 format, simply because of the protocol-stability property Section 1.1 identified — decades of existing tooling, parsing scripts, and downstream integrations were built against the older format's specific shape, and a wholesale, ecosystem-wide migration carries real compatibility cost, meaning any practical log-analysis or centralized-logging effort (Chapters 8 and 9) needs to be prepared to encounter and correctly handle both formats, often within the very same environment, rather than being able to assume a single, consistent format throughout.

---

## 4. Reliability: UDP Versus TCP Transport, and the Message-Loss Problem

This section directly previews a concern Chapter 9 develops at full operational depth, but the underlying mechanism belongs here, in rsyslog's own transport-layer material.

### 4.1 UDP's Historical Default, and Its Genuine Cost

Traditional syslog network transport, going back to its earliest implementations, used **UDP** — a connectionless, unacknowledged protocol offering no delivery guarantee whatsoever. A syslog message sent over UDP that's lost in transit — due to network congestion, a receiver-side buffer overflow, or any transient network issue — is simply, silently gone, with **no retransmission, no error reported back to the sender, and no trace on either end that the loss even occurred**. This was an acceptable trade-off in syslog's original design context (low message volume, simple local networks, an era where the marginal cost of occasional message loss was considered acceptable relative to the connection-management overhead TCP would have added), but it is a genuinely serious reliability gap for any modern deployment treating log data as something with real evidentiary, operational, or compliance value.

### 4.2 TCP as the Modern Standard for Anything That Matters

Modern rsyslog deployments, and the `imtcp`/`omfwd`-with-TCP configuration pairing specifically, are the standard, considered-correct choice whenever log delivery reliability actually matters — TCP's connection-oriented, acknowledged delivery model means a network disruption produces a detectable connection failure rather than silent, untraceable message loss, and rsyslog's own queuing mechanisms (Section 4.3) can then correctly buffer and retry delivery once connectivity is restored, rather than the data having already vanished irretrievably the moment the original transmission attempt failed.

### 4.3 rsyslog's Queuing Model

Directly relevant to reliability under network disruption, rsyslog supports configurable **action queues** — an in-memory or disk-backed buffer sitting between message reception and final output-module delivery, specifically designed to absorb temporary delivery failures without data loss:

```
action(type="omfwd" target="logserver.example.com" port="514" protocol="tcp"
    queue.type="linkedList"
    queue.filename="fwd_queue"
    queue.maxdiskspace="1g"
    queue.saveonshutdown="on"
    action.resumeRetryCount="-1"
)
```

The `queue.filename` and `queue.saveonshutdown` options together enable **disk-backed queue persistence** — meaning messages queued for forwarding but not yet successfully delivered survive not only a transient network outage but even an rsyslog restart or full system reboot, since the queue's contents are themselves written to disk rather than existing only in volatile memory, directly closing the specific gap Section 4.1 identified for UDP's original, no-recovery-possible failure mode. `action.resumeRetryCount="-1"` configures unlimited retry attempts, appropriate for a genuinely critical logging pipeline where message loss is considered unacceptable and the sending system should simply keep retrying indefinitely until the receiving end becomes reachable again, rather than giving up after some fixed, arbitrary number of attempts.

---

## 5. Integration With journald: The Full Picture

This section pulls together Section 2.1's `imjournal` mention and Chapter 2's material into the complete, concrete coexistence model, since understanding this precisely is the direct payoff of having covered both daemons in this series.

### 5.1 The Common Modern Arrangement

```
Application / Service
        │
        ▼
   journald  ◄────── kernel ring buffer, /dev/log, native API, systemd unit stdout/stderr
        │
        │  (imjournal module)
        ▼
    rsyslog  ──────► /var/log/*.log  (traditional flat files, faceted by facility/program)
        │
        │  (omfwd, TCP)
        ▼
  Remote log aggregation server  (Chapter 9)
```

In this common, though not universal, arrangement: journald acts as the primary, unified local collection point exactly as Chapter 2 described, retaining its own structured, indexed, potentially-persistent binary store; rsyslog reads from journald via `imjournal`, applies traditional facility/severity-based (or RainerScript-based) routing rules, and writes out to the familiar flat-file locations under `/var/log/` that a great deal of existing tooling, scripts, and administrator habit still expects; and rsyslog additionally forwards some or all of that same data onward to a remote, centralized aggregation point, using the reliable TCP-based transport and queuing mechanisms Section 4 detailed.

### 5.2 Why This Layered Arrangement, Rather Than Choosing One Daemon Exclusively

This is worth stating as an explicit design rationale rather than assuming it's simply historical inertia: journald provides the structured, boot-aware, tamper-evident (Chapter 2, Section 6) local storage and rich field-based querying that traditional flat files cannot natively offer; rsyslog provides the mature, flexible routing, transformation, and — critically — the reliable remote-forwarding transport that journald's own native forwarding capabilities historically have not matched in configurability or reliability guarantees. Rather than treating this as "old system versus new system, migrate away from the old one entirely," most production Linux deployments treat it as complementary layering, each mechanism doing the specific part of the overall logging pipeline it is genuinely better suited for — directly embodying the "multiple coexisting mechanisms, each with a distinct role" framing Chapter 1 established as this entire series' foundational premise, now made fully concrete with an actual, working example of exactly how and why that coexistence is structured the way it is.

---

## 6. Practical Configuration Verification

### 6.1 Testing Rule Matching Without Waiting for a Real Event

```
logger -p local3.warning "test message for custom-app routing"
```

`logger` is the standard command-line tool for injecting a syslog-formatted test message directly, at a specified facility and severity, without needing to wait for or artificially trigger some real application event — an essential, low-friction verification step any time a new selector/action rule (Section 2.2) or RainerScript condition (Section 2.3) has just been added, letting the administrator confirm the new rule actually matches and routes as intended before relying on it in production.

### 6.2 Syntax Validation

```
rsyslogd -N1
```

This runs rsyslog's own configuration-file syntax checker without actually starting the daemon or applying the configuration — a standard, low-risk verification step worth running as a matter of habit before restarting or reloading rsyslog with any configuration change, since a syntax error in the live configuration can, depending on the specific error and rsyslog version, range from a harmless fallback-to-defaults to a full daemon startup failure, either of which is considerably easier to diagnose and fix *before* a restart than after logging has already silently stopped functioning correctly in production.

---

## 7. Common Misconceptions Worth Retiring Now

- **"rsyslog and syslog are the same thing."** Syslog is a protocol; rsyslog is one specific, widely deployed implementation of a daemon that speaks it — the distinction matters because it's what explains syslog-format interoperability across decades of independently developed software.
- **"journald and rsyslog compete for the same role and only one should be running."** On most modern distributions they're deliberately layered, each handling a distinct part of the overall pipeline — journald as structured local collection, rsyslog as flexible routing and reliable remote forwarding — not redundant alternatives where one should simply be disabled.
- **"Syslog messages always carry reliable, unambiguous timestamps."** The legacy RFC 3164 format lacks both year and timezone information entirely; only the modern RFC 5424 format resolves this, and a great deal of still-deployed software continues to emit the older, ambiguous format.
- **"UDP-based syslog forwarding is just as reliable as TCP, only faster."** UDP syslog transport offers zero delivery guarantee and zero loss detection — a lost message vanishes completely silently, with no retry and no error on either end, a fundamentally different reliability profile from TCP, not merely a speed/reliability trade-off along one continuous scale.
- **"Facility and severity together can express as rich a categorization as journald's structured fields."** They cannot — facility/severity is a fixed, protocol-defined, two-dimensional classification, while journald's field model is genuinely open-ended and arbitrary, a real, structural expressiveness gap RainerScript narrows but does not fully close.

---

The next chapter turns to a concern relevant to both mechanisms covered so far: log rotation and retention — how `logrotate` manages traditional flat files, how journald's own native retention limits (previewed briefly in Chapter 2, Section 4.3) function, and the disk-exhaustion failure modes that inadequate configuration of either produces.
