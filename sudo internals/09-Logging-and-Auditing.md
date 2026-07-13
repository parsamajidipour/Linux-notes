# 09 — Logging and Auditing

Chapter 02 argued that a privileged action with no attributable origin is a
security hole by definition, and named accountability as one of the six
requirements only `sudo` satisfies in full. Chapter 08 then performed the
privilege transition — the moment a named human's authority becomes a root
process. This chapter closes the loop: it is about the evidence that transition
leaves behind, so that after the fact an auditor can answer *who ran what, as
whom, from where, when* — and, with I/O logging, *exactly what they did once they
had the privilege.*

Logging is not a bolt-on to `sudo`; it is one of the three plugin roles
(Chapter 05) and one of the original justifications for the tool's existence. This
chapter covers the three layers of evidence `sudo` produces — the one-line event
record, the full-session I/O capture, and the structured audit stream — where each
is stored, how `sudoreplay` reconstructs a session, and the two hard problems any
serious deployment must confront: the *sensitivity* of what gets captured, and the
*tamper-resistance* of logs on a host whose whole point is that people become root
on it.

## 1. From doing to recording

Every `sudo` invocation that reaches a decision produces a log event, whether the
decision was allow or deny, whether or not a password was required. This is
deliberate and important: `NOPASSWD` skips *authentication*, not *logging*. A
command run without a password prompt is still recorded with the same fidelity as
one that required authentication. The audit trail is independent of the
authentication gate, because accountability and authentication answer different
questions — "who did it" versus "did they prove who they are" — and the first must
hold even when the second is waived.

## 2. Three layers of evidence

`sudo` records at three levels of detail, each answering a progressively deeper
question:

- **Event logging** — one line per invocation: *who, what, as whom, where, when,
  and allowed-or-denied.* This is the baseline, always on, and goes to syslog by
  default.
- **I/O logging** — the full terminal session: every byte the user typed and every
  byte the command printed, time-stamped, replayable. Off by default; enabled per
  policy. This answers "what did they actually *do* inside that root shell."
- **The audit plugin stream** — a structured `accept`/`reject`/`error` event
  (Chapter 05 §9) decoupled from the policy backend, suitable for feeding a SIEM
  uniformly.

The three are complementary. Event logging tells you a root `bash` was launched;
I/O logging tells you what was typed into it; the audit stream carries both into
your central pipeline in a machine-parseable shape.

## 3. Event logging: the one-line record

The baseline record is a single line emitted the moment `sudo` accepts a command.
Its canonical form:

```text
Apr 12 09:14:02 host sudo[5120]: parsa : TTY=pts/3 ; PWD=/home/parsa ;
    USER=root ; COMMAND=/usr/bin/systemctl restart nginx
```

Every field is an accountability answer:

- **`parsa`** — the invoker, by their real identity (the preserved real UID from
  Chapter 01). This is the field `su` could not give you (Chapter 02): the *human*,
  not "root."
- **`TTY=pts/3`** — the controlling terminal, tying the action to a session.
- **`PWD=/home/parsa`** — the working directory at invocation.
- **`USER=root`** — the *target* identity the command ran as. Note it is not
  always root; `sudo -u www-data` records `USER=www-data`.
- **`COMMAND=...`** — the fully-qualified command and its arguments, exactly as
  approved.
- The timestamp and hostname come from syslog.

This single line is the difference between "someone with root did this" and
"`parsa`, on `pts/3`, in this directory, at this second, ran this exact command as
root." It is the accountability requirement, satisfied in one line, on every
invocation.

## 4. Where events go: syslog, journald, logfile

By default `sudo` sends events to **syslog** using the `authpriv` facility — the
facility reserved for security/authorization messages, which is routed to a
protected file. On Debian/Ubuntu that is `/var/log/auth.log`; on Red Hat-family
systems, `/var/log/secure`. Because these systems run `journald`, the same events
are captured in the journal:

```console
# journalctl -t sudo --no-pager | tail -3
Apr 12 09:14:02 host sudo[5120]:  parsa : TTY=pts/3 ; PWD=/home/parsa ;
    USER=root ; COMMAND=/usr/bin/systemctl restart nginx
```

The relevant `sudoers` `Defaults` tune this:

```sudoers
Defaults  syslog=authpriv          # facility (default)
Defaults  syslog_goodpri=notice    # priority for allowed commands
Defaults  syslog_badpri=alert      # priority for denials — noisier on purpose
Defaults  logfile=/var/log/sudo.log # ALSO (or instead) log to a dedicated file
Defaults  log_year, log_host       # include year and hostname in the file format
```

Setting `logfile` gives `sudo` its own log independent of syslog, which is useful
when you want `sudo` events isolated from the noise of the general auth log. The
deliberately higher priority for denials (`alert` vs `notice`) means failed or
unauthorized attempts stand out — a monitoring system can alert on `authpriv.alert`
and catch someone probing what they are allowed to run.

## 5. Reject records and what they reveal

Denials are logged as prominently as accepts, and their text names the *reason*:

```text
host sudo[5130]: parsa : command not allowed ; TTY=pts/3 ; PWD=/home ;
    USER=root ; COMMAND=/bin/cat /etc/shadow
host sudo[5131]: intruder : user NOT in sudoers ; TTY=pts/2 ;
    PWD=/tmp ; USER=root ; COMMAND=/bin/bash
```

The first is an authenticated, authorized user attempting something *outside*
their grant (Chapter 04's default-deny in action). The second is a user with no
`sudoers` entry at all. Both are security-relevant in different ways: the first may
be a user testing the edges of their privilege; the second may be a compromised
account. Reject logging turns the default-deny of the policy engine into
*visible* denials — you not only prevent the action, you record the attempt.

## 6. I/O logging: capturing the whole session

Event logging records *that* a command ran; it cannot record what happened inside
an interactive one. `sudo bash` logs one line — a root shell was launched — and
then goes blind to everything typed in that shell. I/O logging closes this gap by
capturing the terminal session itself.

It is enabled by policy, globally or scoped (Chapter 04 §7):

```sudoers
Defaults  log_output                     # capture what the command prints
Defaults  log_input                      # capture what the user types
Defaults!/usr/bin/vi  !log_output        # scope: don't capture noisy editors
admins ALL=(ALL) LOG_INPUT: LOG_OUTPUT: ALL   # via tag, per rule
```

Mechanically, this is the `sudoers_io` plugin from Chapter 05: with I/O logging on,
`sudo` runs the command under a pseudo-terminal (Chapter 03's pty+monitor model)
and feeds every chunk of terminal input to the plugin's `log_ttyin` and every
chunk of output to `log_ttyout` before it reaches its destination. The pty is what
makes capture possible — `sudo` sits between the real terminal and the command,
seeing the full bidirectional stream.

(A related default worth noting: modern `sudo` enables **`use_pty`** by default even
without I/O logging, because running the command on its own pty prevents a class of
terminal-injection attack where a command left running on `sudo`'s own tty could
push characters back into it. Chapter 10 revisits this; here the point is that the
pty infrastructure I/O logging relies on is increasingly present anyway.)

## 7. The on-disk shape of an I/O log

I/O logs are written under `iolog_dir` (default `/var/log/sudo-io`) in a
sequence-numbered directory tree. Each session gets its own directory:

```console
# ls /var/log/sudo-io/00/00/01/
log  timing  ttyin  ttyout  stdin  stdout  stderr
```

The pieces:

- **`log`** — session metadata (in modern `sudo`, JSON): the invoking user, the
  target, the command, the cwd, the tty name, and the start time. This is what
  `sudoreplay -l` reads to describe a session.
- **`timing`** — a stream of timing records: for each chunk of I/O, which stream it
  belonged to and how long to wait before it. This is what lets `sudoreplay`
  reproduce the session *in real time*, pauses and all.
- **`ttyin` / `ttyout`** — the raw terminal input and output.
- **`stdin` / `stdout` / `stderr`** — the standard streams, when not a tty.

The data files are compressed (zlib) by default. The session identifier — the
`00/00/01` path — is also emitted into the event log line as a `TSID=` field when
I/O logging is on, tying the one-line record to its full capture:

```text
host sudo[5140]: parsa : TTY=pts/3 ; PWD=/home/parsa ; USER=root ;
    TSID=000001 ; COMMAND=/bin/bash
```

That `TSID=000001` is the handle you hand to `sudoreplay`.

## 8. `sudoreplay`: reconstructing a session

`sudoreplay` turns an I/O log back into a viewable session. List what has been
captured, optionally filtered:

```console
# sudoreplay -l
Apr 12 09:20:11 : parsa : USER=root ; TTY=/dev/pts/3 ; CWD=/home/parsa ;
    TSID=000001 ; COMMAND=/bin/bash
# sudoreplay -l user parsa command bash        # search by user and command
```

Then replay a session by its ID:

```console
# sudoreplay 000001
```

This reproduces the session **in real time** — you watch the root `bash` session
play back exactly as it happened, every command typed and every byte of output, at
the original pace (the `timing` file drives the timing). Options adjust playback:

```console
# sudoreplay -s 10 000001     # replay at 10x speed
# sudoreplay -m 2  000001     # cap idle gaps at 2 seconds (skip long pauses)
```

The security value is direct: for the `sudo bash` that event logging saw as a
single opaque line, `sudoreplay` shows the *entire* root session — every file
edited, every command run, every mistake or malice. It is the difference between
knowing a door was opened and having a recording of everything done on the other
side.

## 9. The sensitivity of I/O logs

I/O logging's power is also its hazard, and a rigorous treatment must state it
plainly: **I/O logs capture everything typed, including secrets.**

`sudo` avoids logging its *own* password prompt — the password you type to `sudo`
is read through the no-echo conversation path (Chapter 06) and is not written to
the I/O log. But `sudo` cannot know about secrets typed into the *command* it ran.
If a captured root session runs `mysql -p` and the admin types the database
password at MySQL's prompt, that password lands in `ttyin`. If they paste an API
key, edit a file containing credentials, or type another system's password, it is
all in the log.

Two consequences follow:

- **I/O logs are among the most sensitive files on the system.** They are a
  time-ordered transcript of privileged sessions, potentially studded with
  plaintext secrets. They must be owned by root, unreadable by anyone else, and —
  ideally — shipped off-host (§10) so that access to them is itself audited.
- **I/O logging is not a substitute for secret hygiene.** The presence of session
  recording is an argument *for* using non-interactive credential mechanisms
  (files with tight permissions, secret managers) rather than typing secrets into
  prompts, precisely because the prompts get logged.

The privacy dimension is real too: I/O logs record administrators' complete
keystroke activity. Deployments should treat enabling I/O logging as a policy
decision with legal and ethical weight, not merely a technical toggle.

## 10. Tamper resistance: `sudo_logsrvd` and remote logging

There is a structural problem at the heart of local `sudo` logging: the logs live
on a host whose entire purpose is that people become **root** on it. A user who
legitimately (or illegitimately) obtains root can edit `/var/log/auth.log`, delete
the `sudo-io` directory, and erase the very evidence of what they did. Local logs
document the honest and catch the careless, but they cannot bind a root-capable
adversary who thinks to cover their tracks.

`sudo` 1.9 addresses this with **`sudo_logsrvd`**, a dedicated log server that
receives both event and I/O logs from `sudo` clients over the network, protected
by TLS. Clients are pointed at it in `sudoers`:

```sudoers
Defaults  log_servers = logserver.example.com:30344
Defaults  log_output, log_input
```

With this in place, the authoritative copy of each session lives on a **separate
host** that the audited user has no privilege on. A local root can still scrub the
local logs, but the remote server already holds the record — including the
transcript of the session in which they tried. This is the standard architecture
for meaningful `sudo` auditing: local logging for convenience, a remote
`sudo_logsrvd` (or a syslog forwarder shipping `authpriv` off-host) for integrity.
Without off-host logging, "the audit trail" is only as trustworthy as the goodwill
of whoever holds root.

## 11. Structured output and system integration

For ingestion into monitoring and SIEM systems, line-oriented syslog text is
awkward to parse reliably. `sudo` 1.9 can emit **JSON**-formatted event logs, both
to a logfile and to `sudo_logsrvd`:

```sudoers
Defaults  log_format = json
```

A JSON event carries the same fields as the one-line record — invoker, target,
command, tty, cwd, timestamp, TSID, accept/reject — as structured keys, so a
pipeline can index and query them without fragile regex parsing.

Two further integration points:

- **The audit plugin** (Chapter 05 §9) delivers `accept`/`reject`/`error` events
  decoupled from `sudoers`, giving a uniform stream even across policy backends. It
  is the clean seam for shipping `sudo` decisions into a central system.
- **Linux `auditd`.** On systems running the kernel audit framework, the `execve`
  that runs the command (and `sudo`'s own audit integration) surface as audit
  records searchable with `ausearch`/`aureport`. This correlates `sudo`'s own logs
  with the kernel's independent view of process execution — two sources that a
  tampering adversary would have to defeat separately.

## 12. A complete trail, worked

Put the layers together for a realistic question: *who restarted nginx last night,
and what else did they do while root?*

1. **Event log** places the action and the human:

   ```text
   host sudo[7001]: oncall : TTY=pts/5 ; PWD=/home/oncall ; USER=root ;
       TSID=000042 ; COMMAND=/bin/bash
   ```

   `oncall` opened a root shell at this time, session `000042`.

2. **`sudoreplay 000042`** reconstructs the session — showing that inside that
   shell they ran `systemctl restart nginx`, then also edited
   `/etc/nginx/nginx.conf`, then tailed a log. The single opaque "ran bash" line
   becomes a full account.

3. **The remote `sudo_logsrvd` copy** confirms the transcript was not altered
   locally, because the authoritative record is off-host.

4. **`auditd`** independently corroborates the `execve` of `/bin/bash` and the
   editor, from the kernel's vantage.

This is the accountability Chapter 02 demanded, delivered concretely: not "root did
something," but a named human, an exact time, a full transcript, and independent,
tamper-resistant corroboration.

## 13. Gaps and honest limits

A rigorous chapter names what the trail does *not* guarantee:

- **Without a pty, I/O capture is partial.** I/O logging depends on the command
  running under a pty; for non-interactive or backgrounded commands the terminal
  capture is limited to the standard streams. The richest capture assumes an
  interactive, pty-backed session.
- **Local logs are not tamper-proof.** As §10 stressed, only off-host logging
  meaningfully binds a root-capable adversary. A deployment relying solely on
  local `/var/log` has convenience, not integrity.
- **I/O logs can contain secrets** (§9) — they are evidence *and* liability, and
  must be protected accordingly.
- **Logging records the transition, not the wisdom of the grant.** If policy
  allowed a shell-escaping editor (Chapter 04), the log faithfully records the
  editor invocation — and the shell escape happens *inside* it, visible only via
  I/O logging, not from the event line. The event log shows what was *authorized*;
  only session capture shows what was *done* with it.

These limits are not reasons to skip logging; they are the boundary conditions for
reading it correctly and for designing a deployment (off-host, pty-backed,
secret-aware) where the trail actually means what it appears to mean.

## 14. What this chapter established

- `sudo` logging realizes the **accountability** requirement of Chapter 02, and is
  independent of authentication: **`NOPASSWD` skips the password, not the log.**
- Evidence comes in **three layers**: the always-on **event log** (one line: who,
  what, as-whom, where, when, allow/deny), optional **I/O logging** (the full
  replayable session), and the structured **audit plugin** stream.
- Event logs go to **syslog** (`authpriv` → `/var/log/auth.log` or
  `/var/log/secure`) and the **journal** by default, tunable via `logfile`,
  `syslog*`, and priority `Defaults`; **denials are logged prominently** with their
  reason, turning default-deny into visible attempts.
- **I/O logging** (`log_input`/`log_output`, or `LOG_*` tags) runs the command
  under a **pty** and captures both directions; logs live under **`iolog_dir`**
  (`/var/log/sudo-io`) as per-session directories of metadata (`log`), `timing`,
  and stream files, keyed by a **`TSID`** that also appears in the event line.
- **`sudoreplay`** lists and reconstructs sessions in real time (or scaled),
  turning an opaque "ran bash" into a full transcript of the root session.
- I/O logs are **highly sensitive** — they capture secrets typed into sub-commands
  (though not `sudo`'s own password prompt) — and must be tightly protected.
- Local logs are **not tamper-proof** on a host where users become root;
  **`sudo_logsrvd`** (1.9) ships event and I/O logs to a **remote server over TLS**,
  giving an off-host authoritative record that a local root cannot erase.
- **JSON logging**, the **audit plugin**, and **`auditd`** correlation provide
  structured, SIEM-friendly, independently-corroborated trails.
- The trail's limits are real: partial without a pty, tamper-resistant only when
  off-host, secret-bearing, and faithful to what was *authorized* rather than
  whether the grant was *wise* — the last point handing directly to the next
  chapter.

The next chapter steps back from the mechanism to judge it. *Security
Considerations* frames the whole `sudo` design as a trust boundary and works
through the vulnerability classes the series has met in passing — argument
parsing (`CVE-2021-3156`), runas logic (`CVE-2019-14287`), environment leakage,
and the shell-escape grants that this chapter's logs can record but not prevent —
as instances of a small number of recurring root causes.
