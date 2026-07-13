# 12 — Debugging Sudo

Chapter 11 closed with a promise: this chapter turns from preventing
misconfigurations to diagnosing behavior. Everything from Chapter 03 onward has
described a pipeline — front-end parsing, `sudo.conf` plugin loading, policy
evaluation, PAM authentication, environment construction, the pty/monitor
exec, and finally the credential transition of Chapter 08. A bug report like
*"sudo isn't working"* could originate at any one of those stages, and the
symptom the user sees — a denial, a password prompt that shouldn't appear, a
command that silently does the wrong thing — rarely names the stage on its
own. Debugging `sudo` is, before anything else, an exercise in **staged
elimination**: narrowing a vague complaint down to the one link in the chain
that actually produced it.

This chapter covers the instruments named back in Chapter 01 §6 and used
piecemeal throughout the series — `sudo -l`/`-V`, the `sudo` debug subsystem
and its `sudo.conf` `Debug` lines, `strace`, the PAM and audit logs, and
`sudoreplay` — and organizes them into a single method: which tool answers
which question, and in what order to reach for them.

## 1. The pipeline as a diagnostic map

Recall the stages from Chapter 03:

```text
┌────────────────────────────────────────────────────────────┐
│ 1. front-end parses argv, resolves invoking user/group      │
│ 2. read /etc/sudo.conf, load plugins (policy, I/O, audit)   │
│ 3. policy plugin (sudoers) evaluates the rule                │
│ 4. PAM authenticates and checks the account                  │
│ 5. environment is sanitized and constructed (Chapter 07)     │
│ 6. pty/monitor exec's the command (Chapter 03 §7)             │
│ 7. credential transition: setresuid/setresgid (Chapter 08)   │
└────────────────────────────────────────────────────────────┘
```

Every symptom maps to one or more of these stages, and every diagnostic tool
in this chapter is scoped to a subset of them:

- **Stage 3 (policy)** — `sudo -l`, and the `sudoers.so` plugin's own debug
  output.
- **Stage 4 (PAM)** — the `authpriv` log (Chapter 06 §13), PAM's own debug
  flags.
- **Stages 1–7, sudo's internal logic** — the `sudo` debug subsystem.
- **Stages 5–7, ground truth below sudo's own reporting** — `strace`.
- **After the fact, what actually happened inside an allowed command** —
  `sudoreplay` (Chapter 09).

The rest of this chapter walks these in roughly the order you should reach for
them: cheapest and least invasive first, `strace` last, because it is the only
tool here that requires re-running the failure under instrumentation rather
than reading a trail `sudo` already left behind.

## 2. The first two questions: `sudo -l` and `sudo -V`

Before touching any debug flag, two commands already covered in Chapters
04, 05, and 07 answer the two most common questions and cost nothing:

```console
$ sudo -l -U parsa      # what does the POLICY say parsa may do, resolved?
# sudo -V | head -20    # what sudo binary, what plugins, what compiled-in
                         # defaults (secure_path, plugin dir, ...) are active?
```

`sudo -l` (Chapter 04 §12) renders the *effective* policy decision — it
answers "is this a rule problem" without running anything. `sudo -V`
(Chapters 03 §4, 05 §2, 07 §9) answers a different, easily-overlooked
question: *is this even the sudo you think it is* — the right version, the
right plugin set, the right compiled-in `secure_path`. A surprising fraction
of "sudo is behaving strangely" reports are actually "a different `sudo` than
expected is on `$PATH`," or a plugin version mismatch after a package
upgrade. Both checks belong before any deeper instrumentation, because they
can dissolve the mystery in one command.

If both look correct — the policy grants what you expect, and the binary and
plugins are the right ones — the problem lives inside a stage that `-l` and
`-V` cannot see into, and it is time for the debug subsystem.

## 3. The debug subsystem: `sudo.conf` `Debug` lines

`sudo` and its plugins have an internal, compiled-in tracing facility,
independent of the event log from Chapter 09. It is off by default and is
enabled per program, in `/etc/sudo.conf`, with a `Debug` directive:

```text
Debug sudo        /var/log/sudo_debug.log     all@warn
Debug sudoers.so  /var/log/sudoers_debug.log  all@info
```

The syntax is `Debug <program> <logfile> <subsystem@priority>[,...]`. Each
field matters:

- **`<program>`** — which binary or plugin object the line applies to: `sudo`
  itself, `sudoers.so` (the policy/I-O/audit plugin from Chapter 05),
  `visudo`, or `sudoreplay`. Each gets its **own** `Debug` line and, typically,
  its own log file — a hang in the policy plugin and a hang in the front-end
  produce traces in two different places.
- **`<logfile>`** — where the trace is written. Not `authpriv`, not the
  `sudoers` event log — a dedicated file, because debug output is far higher
  volume and a different kind of artifact than either.
- **`<subsystem@priority>`** — a comma-separated list scoping the trace.
  **Subsystems** correspond to internal modules — `main`, `args`, `plugin`,
  `perms`, `exec`, `pty`, `conv` (the password conversation), `netif`,
  `event`, `util`, among others — and `all` matches every subsystem.
  **Priorities**, from quietest to loudest, are `crit`, `err`, `warn`,
  `notice`, `diag`, `info`, `trace`, `debug`.

`all@warn` is cheap enough to leave on semi-permanently — it only logs
warnings and worse. `all@debug` is the opposite: every function entry and
exit, in every subsystem, which is enormous and — as §11 stresses — sensitive.
The discipline that pays off is **scoping**: pick the subsystem that owns the
stage you suspect (`perms` for credential-set problems, `plugin` for loading
issues, `exec`/`pty` for the child process) rather than reaching for `all` by
default.

## 4. Anatomy of a debug log line

A trace line, once enabled, looks like this (fields separated for
readability; a real line is one row):

```text
Jul 12 09:14:02.148734 sudo[5120] <- sudoers_policy_check @ ./policy.c:412
Jul 12 09:14:02.148740 sudo[5120] -> sudoers_lookup @ ./match.c:88
Jul 12 09:14:02.148791 sudo[5120] <- sudoers_lookup @ ./match.c:210 := DENY
```

Reading it:

- **Timestamp, with microseconds** — traces are fine-grained enough to order
  events within a single invocation, which matters when several subsystems
  interleave.
- **`sudo[5120]`** — the PID, ties every line in a trace to one process, and
  correlates directly with the PID in the event log line from Chapter 09.
- **`->` / `<-`** — function entry and exit. A well-scoped trace reads like a
  call stack unrolled in time: you can see exactly which internal function
  made the decision, and — on exit — often the return value that decision
  produced.
- **`@ file:line`** — the exact source location, because this facility is
  built for developers and power users reading against the `sudo` source tree
  (README's "source of truth" discipline), not for casual inspection.

The entry/exit pairing is what makes this more useful than the event log for
one specific class of question: *not* "was the command allowed," which
`sudo -l` and the event log already answer, but "**why**, mechanically, did
the policy engine decide that" — which rule matched, which alias resolved to
what, in what order.

## 5. A worked failure, read through the trace

A realistic case: `parsa` reports that a rule which looks correct —

```sudoers
Host_Alias   WEBSERVERS = web01, web02
parsa ALL = (root) NOPASSWD: /usr/bin/systemctl restart nginx
```

wait — the rule *is* `ALL`, so host shouldn't matter, but say the actual
rule in question was scoped:

```sudoers
parsa WEBSERVERS = (root) NOPASSWD: /usr/bin/systemctl restart nginx
```

and `parsa` gets `Sorry, user parsa is not allowed to execute ... on this
host` on `web01` itself. `sudo -l -U parsa` confirms the rule is present and
looks right. This is exactly the case the debug subsystem earns its keep on:
scope the trace to the matching subsystem and re-run.

```text
Debug sudoers.so /var/log/sudoers_debug.log match@info
```

```console
# sudo systemctl restart nginx
$ tail -f /var/log/sudoers_debug.log
...
match.c:140 hostname resolved as "web01"
match.c:151 comparing against alias WEBSERVERS: "web01.internal.example.com"
match.c:158 no match: web01 != web01.internal.example.com
```

The trace shows the exact comparison that failed: `sudo` resolved the local
hostname as the **short name**, but the `Host_Alias` was written with the
**FQDN**. This is a real, common failure mode — hostname resolution behavior
(short vs. fully-qualified) depends on `/etc/hosts`, DNS, and `Defaults
fqdn`/`host_lookup` settings covered in Chapter 04 — and it is invisible from
`sudo -l`, which renders the *rule* correctly; the rule is not wrong, the
runtime comparison is what fails. Only a trace of the matching function
exposes the exact strings being compared. The fix — align the alias to
whatever form `hostname` actually resolves to, or add both forms — falls out
directly once the mismatch is visible, rather than guessed at.

## 6. Below sudo's own account: `strace`

The debug subsystem reports what `sudo`'s own code believes is happening. For
some failures, that is not far enough down — you need the kernel's version of
events, independent of `sudo`'s self-reporting. This is where `strace`, used
throughout the series (Chapters 01, 03, 08) to verify the credential
transition, earns its place as the diagnostic of last resort.

Two examples of things a debug trace can't distinguish but `strace` can:

**"Command not found" vs. a policy problem.** A vague failure to execute
could be a missing binary, a `PATH`/`secure_path` mismatch (Chapter 07), or a
permissions problem on the target itself:

```console
$ strace -f -e trace=execve,openat,access sudo /opt/tools/deploy.sh 2>&1 | tail -5
access("/opt/tools/deploy.sh", X_OK)   = -1 ENOENT (No such file or directory)
```

`ENOENT` on `access` settles it immediately: the path in the `sudoers` rule
does not exist on this host, full stop — not a policy denial, not a PAM
failure, a stale or environment-specific path.

**Confirming the credential transition actually happened as designed.**
Chapter 08's whole argument rests on an exact `setresuid`/`setresgid`
ordering; if a privilege-related bug is suspected, the filtered `strace` from
that chapter —

```console
$ strace -f -e trace=setresuid,setresgid,setgroups,execve sudo -u www-data id
```

— is still the most direct way to confirm what credentials the child process
actually received, independent of anything `sudo` chose to log about itself.

**A necessary caveat.** `sudo` is a `setuid-root` binary (Chapter 01), and the
kernel deliberately restricts `ptrace` attachment to setuid programs run by an
unprivileged user — `strace`-ing `sudo` as a non-root user commonly fails or
produces a truncated trace for exactly this reason. In practice, meaningful
`strace` output on `sudo` itself requires running the trace as root (`sudo
strace -f sudo ...`), which is one more reason this tool sits at the bottom
of the list: it requires privilege the earlier tools do not.

## 7. PAM's own trail

Chapter 06 §13 already showed the baseline: PAM modules log to `authpriv`
alongside `sudo`'s own event log, and reading which subsystem emitted which
line is the starting point.

```console
# journalctl -t sudo --no-pager | tail -2
Apr 12 11:02:17 host sudo[6210]: pam_unix(sudo:auth): authentication failure;
    logname=parsa uid=1000 euid=0 tty=/dev/pts/3 ruser=parsa rhost= user=parsa
Apr 12 11:02:21 host sudo[6212]:  parsa : TTY=pts/3 ; PWD=/home/parsa ;
    USER=root ; COMMAND=/usr/bin/systemctl restart nginx
```

Debugging further than that one line means turning on the PAM module's own
verbosity, which is configured in `/etc/pam.d/sudo` — a different file from
`sudo.conf`, because PAM debugging is PAM's facility, not `sudo`'s:

```text
# /etc/pam.d/sudo
auth    required pam_unix.so debug
account required pam_unix.so debug
```

With `debug` set, `pam_unix` logs which step of its own logic failed —
password comparison, account expiry, or a locked account — rather than the
single opaque "authentication failure" line. This is the tool for the
specific misdiagnosis Chapter 06 §13 warned about: a `sudoers` denial and a
PAM `account` rejection (a locked or expired account, distinct from a wrong
password) produce superficially similar user-facing errors but come from
different subsystems, fixed in different files, and only the PAM debug trail
tells them apart.

## 8. `sudoreplay`: reconstructing what actually happened

Everything so far diagnoses why `sudo` made a *decision*. A different class
of question is what a user *did* once a command was allowed — the territory
of Chapter 09's I/O logging. As a debugging tool rather than an audit tool,
`sudoreplay` answers reports like "the deploy script behaved strangely
yesterday" when the person reporting it can no longer reconstruct their own
steps:

```console
$ sudoreplay -l | grep parsa                 # list parsa's recorded sessions
$ sudoreplay 000042                          # play back session 000042
$ sudoreplay -s 3 000042                     # play back at 3x speed
```

This only works if I/O logging (`log_output`/`log_input`, Chapter 09 §6) was
already on for the relevant rule at the time — it cannot retroactively
recover a session that wasn't captured. Deployments that expect to debug
interactive `sudo` usage after the fact, not just audit it, are a reason to
enable I/O logging proactively on high-risk rules rather than only after an
incident.

## 9. Symptom, stage, tool: a quick-reference map

| Symptom                                              | Likely stage         | Reach for                                   |
| ----------------------------------------------------- | --------------------- | -------------------------------------------- |
| `... is not allowed to run ...` on a rule that looks right | Policy match (3)  | `sudo -l -U`, then `sudoers.so` trace (`match@info`) |
| Unexpected password prompt, or none where one was expected | Policy `Defaults`/tags (3) | `sudo -l -U`, `sudoers.so` trace (`defaults@info`) |
| `Sorry, try again` / silent auth failure               | PAM `auth` (4)        | `authpriv` log, `pam_unix.so debug`          |
| Allowed, but the account seems "not usable"           | PAM `account` (4)     | `pam_unix.so debug` on the `account` stack   |
| Command runs but with wrong/missing environment vars   | Environment (5)       | `sudo -V` (env policy), `sudo` trace (`env@info`) |
| `command not found` / wrong binary runs                | Exec (6)              | `strace -e trace=access,execve`              |
| Wrong effective UID/GID in the child                    | Credential transition (7) | `strace -e trace=setresuid,setresgid,setgroups`, `id` in the child |
| "It did something odd, what exactly did they run?"     | After the fact         | `sudoreplay` (needs I/O logging enabled beforehand) |

This table is the practical payoff of §1's staging: given a symptom, it names
the stage almost certainly responsible and the cheapest tool that inspects
it, so debugging starts with a hypothesis instead of `all@debug` and a page
of noise.

## 10. A complete diagnosis, worked end-to-end

Put the method together on a single report: *"`deploy` can't restart nginx on
`web01` anymore; it worked yesterday."*

1. **`sudo -l -U deploy`** on `web01` shows the rule is present, unchanged —
   ruling out an accidental `sudoers` edit.
2. **`sudo -V`** shows the `sudoers` plugin version is unchanged, but the
   compiled `secure_path` line differs from `web02` — a hint, not yet a
   diagnosis, since the rule itself doesn't depend on `PATH`.
3. Scoped `sudoers.so` trace (`match@info`, §5's technique) on a reproduction
   shows the alias comparison succeeding this time — hostname isn't it.
4. The PAM log shows no `auth` failure at all — `sudo` never got that far.
5. `strace -f -e trace=access,execve` on the reproduction shows
   `access("/usr/bin/systemctl", X_OK) = -1 EACCES` — the binary's
   permissions changed, most likely by a package update overnight.

The chain of tools didn't just find the fix; it excluded four other plausible
causes — a stale rule, a PATH problem, a hostname mismatch, an auth failure —
each in one cheap step, before the one tool that could see stage 6 confirmed
the real cause. That ordering, cheap-and-broad before expensive-and-narrow, is
the method this chapter has been building toward.

## 11. Gaps and honest limits

- **Debug logs are a liability, not just an instrument.** `all@debug`
  captures function arguments, which can include command lines and — as
  Chapter 09 §9 warned about I/O logs — anything typed into them. Debug
  logging should be scoped, temporary, and protected like any other
  sensitive log, not left permanently at high verbosity.
- **Verbosity has a cost independent of sensitivity.** `all@debug` on a busy
  host produces enormous volume and measurable overhead; it is a tool for an
  active investigation, not a standing configuration.
- **`sudo`'s debug trace only reports what `sudo`'s own code believes.** It
  cannot catch a case where `sudo`'s internal state is correct but the
  kernel's enforcement diverges from it — that gap is exactly what `strace`
  is for (§6), and no amount of `sudo`-side tracing substitutes for it.
- **`strace` needs privilege to be trustworthy on a setuid binary** (§6) —
  which makes it the least accessible tool here, ironically, on systems
  locked down enough that only administrators can run it in the first place.
- **`sudoreplay` cannot recover what wasn't captured.** It is a debugging aid
  only for sessions where I/O logging was already active; it has no
  retroactive power.

None of these limits argue against using the tools — they argue for the
ordering in §9 and §10: start cheap and non-invasive, and reach for `strace`
and `all@debug` only once the cheaper instruments have narrowed the search,
not as a first move.

## 12. What this chapter established

- Debugging `sudo` is **staged elimination** against the pipeline from
  Chapter 03: front-end, `sudo.conf`/plugins, policy, PAM, environment, exec,
  credential transition — each stage has its own tool.
- **`sudo -l`** and **`sudo -V`** are the free first checks: effective policy,
  and confirmation that the running binary, plugins, and compiled defaults
  are what you think they are.
- The **debug subsystem**, enabled per-program in **`/etc/sudo.conf`** via
  **`Debug <program> <logfile> <subsystem@priority>`**, produces a
  function-level trace (entry/exit, `@ file:line`) of `sudo`'s own logic —
  scope it to a subsystem (`match`, `perms`, `exec`, `plugin`, …) rather than
  reaching for `all@debug` by default.
- **`strace`**, filtered to the relevant syscalls, is the tool of last resort
  for ground truth the kernel enforces independently of what `sudo` reports
  about itself — but tracing a setuid `sudo` reliably requires privilege.
- **PAM's own `debug` option** (in `/etc/pam.d/sudo`, not `sudo.conf`)
  distinguishes an `auth` failure from an `account` rejection — two different
  subsystems that otherwise look alike from the user's seat.
- **`sudoreplay`** (Chapter 09) doubles as a debugging tool for
  "what actually happened" reports, but only for sessions I/O logging was
  already capturing.
- The symptom-to-stage-to-tool table (§9) and the worked example (§10) turn
  the method into a habit: cheap and broad before expensive and narrow, and
  every tool scoped to the one stage it can actually see.
- Debug output is itself sensitive and costly at high verbosity — an
  investigative setting, not a standing one.

The next chapter turns from diagnosing `sudo` to configuring it well from the
start. *Best Practices* draws hardening guidance directly from the mechanism
this series has built — the trust boundary of Chapter 10, the misconfiguration
catalog of Chapter 11, and the observability this chapter just covered — rather
than from a generic checklist.
