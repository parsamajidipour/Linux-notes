# 03 — How Sudo Works

Chapters 01 and 02 established *what* privilege is and *why* `sudo` must exist.
This chapter opens the machine. It traces a single invocation — `sudo systemctl
restart nginx` — from the keypress in your shell to the moment `nginx` restarts,
and back to the exit status landing in `$?`.

The goal here is the **skeleton**: the full control flow, correctly ordered, with
each joint named. The detail behind each joint — how `sudoers` is parsed
(Chapter 04), how plugins are dispatched (05), how PAM decides (06), how the
environment is rebuilt (07), how credentials actually change (08), how the audit
trail is written (09) — is deferred. What matters now is that you can hold the
entire lifecycle in your head as one continuous pipeline, and know exactly which
later chapter fills in each stage.

We will build the skeleton twice: first as a narrated walkthrough, then as a
single annotated `strace`/`ps` observation that shows the whole thing happening
for real.

## 1. The lifecycle at a glance

A `sudo` invocation is a pipeline with a fixed order. Reordering any two stages
would be a security bug, and several historical CVEs are exactly "this happened
before that."

```
  shell
    │  execve("/usr/bin/sudo", ["sudo","systemctl","restart","nginx"], envp)
    ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ setuid bit fires  →  euid: 1000 → 0        (kernel, at exec) │
  ├─────────────────────────────────────────────────────────────┤
  │ 1. front-end init: parse argv, split sudo-opts from command │
  │ 2. read /etc/sudo.conf, load plugins (policy, I/O, audit)   │
  │ 3. policy_plugin->open(): gather user/host/settings info    │
  │ 4. policy_plugin->check_policy(): evaluate sudoers rules    │
  │ 5. authentication (PAM conversation) — prove the invoker    │
  │ 6. build command_info: argv, envp, runas ids, cwd, umask... │
  │ 7. environment construction / sanitization                 │
  │ 8. credential transition: setgroups, setresgid, setresuid  │
  │ 9. execute: execve(target) directly, or via a pty monitor  │
  │ 10. wait, relay signals, capture exit status               │
  └─────────────────────────────────────────────────────────────┘
    │  exit status of nginx restart
    ▼
  shell:  $? set
```

Notice the shape: `sudo` is privileged (`euid 0`) from the very first line of its
own code, decides *whether* to proceed, decides *who to become*, changes into
that identity, and only *then* runs your command. The privilege comes first; the
authorization check is a gate the already-privileged process imposes on itself.

## 2. Stage 0 — the shell hands off

Before `sudo` runs at all, your shell does ordinary work. When you type:

```console
$ sudo systemctl restart nginx
```

the shell tokenizes the line, resolves `sudo` via `PATH` to `/usr/bin/sudo`,
`fork()`s, and in the child calls `execve()` with three things:

- **path**: `/usr/bin/sudo`
- **argv**: `["sudo", "systemctl", "restart", "nginx"]`
- **envp**: the shell's *entire* current environment

That third item is the crux of the whole trust problem from Chapter 02. The
shell hands `sudo` every environment variable it holds — `PATH`, `LD_PRELOAD`,
`TERM`, `IFS`, thousands of bytes of caller-controlled data. All of it is
untrusted. Stage 7 exists precisely to deal with this.

From the process table, the hand-off looks like this — the shell is the parent,
`sudo` is the child that replaced the forked copy:

```console
$ ps -o pid,ppid,euid,cmd --forest
  PID  PPID EUID CMD
 3010  3005 1000 -bash
 5120  3010    0  \_ sudo systemctl restart nginx
```

The child's `EUID` is already `0`. The shell never elevated anything — the
kernel did, at `execve` time, because of the setuid bit. This is Stage 0's only
lesson: **by the time `sudo`'s `main()` runs, it is already root, and it is
already holding a hostile environment.**

## 3. Stage 1 — front-end initialization and argv splitting

`sudo`'s architecture separates a small, policy-agnostic **front-end** (the
`sudo` binary) from **plugins** that implement policy, I/O logging, and auditing.
The front-end knows nothing about `sudoers`; it knows how to load plugins and how
to drive the generic plugin API. (This separation is Chapter 05's whole subject;
here we just see it engage.)

The front-end's first job is to parse its *own* command line and separate two
things that live in one argv:

- options that belong to `sudo` itself — `-u user`, `-g group`, `-i`, `-s`,
  `-E`, `-n`, and so on;
- the **command** to eventually run, with its own arguments.

For `sudo -u www-data systemctl restart nginx`, the front-end must recognize `-u
www-data` as *its* option (target user) and `systemctl restart nginx` as the
command. The boundary matters: everything after the recognized options is the
command line and is passed through, not interpreted by `sudo`.

This parsing runs while `euid == 0`. That fact is the reason argument-handling
bugs in `sudo` are so severe: the code separating options from command, escaping
metacharacters, and sizing buffers is *already privileged*. `CVE-2021-3156`
(Baron Samedit) lived exactly here — a miscalculation while un-escaping
backslashes in the command arguments overflowed a heap buffer, in code reached
before any policy check or password prompt. Stage 1 is privileged code touching
untrusted input; that is the definition of an attack surface.

## 4. Stage 2 — reading `sudo.conf` and loading plugins

The front-end reads `/etc/sudo.conf` to learn which plugins to load. On a default
system it looks like this:

```console
$ grep -v '^#' /etc/sudo.conf | grep -v '^$'
Plugin sudoers_policy sudoers.so
Plugin sudoers_io sudoers.so
Plugin sudoers_audit sudoers.so
```

Three plugin *roles* are configured, all satisfied here by one shared object,
`sudoers.so`:

- **policy** (`sudoers_policy`) — decides whether the command is allowed and, if
  so, produces the execution parameters. This is the brain.
- **I/O logging** (`sudoers_io`) — optionally records the terminal input/output
  of the session for later replay (`sudoreplay`).
- **audit** (`sudoers_audit`) — receives structured audit events.

You can see the loaded plugins in `sudo -V` as root:

```console
# sudo -V | grep -iA6 'plugin'
Sudoers policy plugin version 1.9.15p5
Sudoers file grammar version 50
Sudoers I/O plugin version 1.9.15p5
Sudoers audit plugin version 1.9.15p5
```

The important architectural point: the front-end at this stage still knows
nothing about `sudoers` syntax. It has loaded a `.so` that exposes a fixed set of
function pointers (`open`, `check_policy`, `list`, `close`, ...). Everything
`sudoers`-specific lives behind that interface. If you replaced `sudoers.so` with
an LDAP-backed or JSON-backed policy plugin, Stages 0–2 would be byte-for-byte
identical. That is the payoff of the plugin split.

## 5. Stage 3 — the policy plugin opens

The front-end now calls the policy plugin's `open()` entry point, handing it
everything it has gathered:

- **user info**: the invoking user's real UID/GID (recall: preserved by the
  setuid bit, so `sudo` knows *who* is asking), the controlling terminal, the
  current working directory, the hostname.
- **settings**: `sudo`'s parsed options (`-u`, `-i`, `-n`, etc.).
- **the environment**: the raw, untrusted `envp` from Stage 0.
- **the command and its arguments**.

The plugin uses this to load and parse its policy source. For `sudoers.so` that
means reading `/etc/sudoers` (and any `@includedir`, typically
`/etc/sudoers.d/`), parsing the grammar, and building the in-memory rule set it
will evaluate. Parse errors surface here — a syntax error in `sudoers` makes
`open()` fail and aborts the whole invocation, which is why `visudo` exists to
validate before you save (Chapter 04).

## 6. Stage 4 — the policy decision

With the rules in memory, the plugin evaluates whether *this invoker* may run
*this command* as *this target user* on *this host*. Chapter 04 details the
matching algorithm — alias expansion, rule ordering, "last match wins", the
`Defaults` mechanism. At the skeleton level, three outcomes are possible:

1. **Allowed.** The plugin will proceed to produce execution parameters.
2. **Allowed without authentication.** A `NOPASSWD` rule matched; Stage 5 is
   skipped.
3. **Denied.** The plugin returns failure; `sudo` logs the denial and exits
   non-zero. This is the source of the familiar line:

```console
$ sudo systemctl restart nginx
[sudo] password for parsa:
parsa is not allowed to run '/usr/bin/systemctl restart nginx' as root on host.
This incident will be reported.
```

You can inspect the decision without running anything using `sudo -l`, which
drives the policy plugin's `list` entry point rather than `check_policy`:

```console
$ sudo -l
User parsa may run the following commands on host:
    (root) /usr/bin/systemctl restart nginx
    (root) NOPASSWD: /usr/local/sbin/run-backup
```

That output *is* the policy decision, rendered. The first rule requires
authentication; the second does not.

## 7. Stage 5 — authentication

If the matched rule requires a password (i.e. not `NOPASSWD`) and no valid
timestamp ticket exists, the plugin authenticates the **invoker**. On Linux this
is a PAM conversation: `sudo` acts as a PAM application against the `sudo`
service (`/etc/pam.d/sudo`), and the PAM stack runs its configured modules —
`pam_unix` for the shadow password, `pam_faillock` for lockout, possibly
`pam_google_authenticator`, `pam_u2f`, `pam_sss`, and so on. Chapter 06 dissects
this stack module by module.

Two skeleton-level facts matter here and recur throughout the series:

- **The identity tested is the invoker's, not the target's.** This is the clean
  break from `su` established in Chapter 02. `sudo` proves *you* are you, then
  becomes someone else.
- **Success is cached as a timestamp.** On success, `sudo` records a timestamp
  ticket (under `/run/sudo/ts/<user>` on modern systems). While it is valid
  (default `timestamp_timeout`, commonly 15 minutes) subsequent invocations skip
  Stage 5. This is why the *second* `sudo` in a burst rarely asks again.

Crucially, authentication runs *after* the policy match. `sudo` does not ask for
a password and then check whether you were allowed; it checks whether you are
allowed and asks for a password only if the matching rule demands one. The order
is policy → authentication, never the reverse.

## 8. Stage 6 — building `command_info`

Once the command is approved (and authenticated if required), the policy plugin
hands the front-end a structured description of *exactly how* to run the command.
This structure — internally `command_info` — is the plugin's output contract, and
it contains, among other things:

- the fully-qualified command path and final argv;
- the **target credentials**: runas UID/GID and the supplementary group list to
  install;
- the **constructed environment** (`envp`) the command should receive — the
  result of Stage 7's sanitization;
- the working directory, umask, `nice` value, resource limits;
- flags controlling execution: whether to allocate a pty, whether to log I/O,
  whether to preserve groups, `noexec`, and so on.

Everything downstream — the credential change and the exec — is driven by this
structure. The front-end does not re-derive any of it; it *applies* what the
policy plugin decided. This is the contract boundary: policy decides, front-end
enforces.

## 9. Stage 7 — environment construction

Before the command runs, `sudo` builds the environment it will receive. By
default this is aggressively restrictive: the untrusted `envp` from Stage 0 is
**not** passed through. Instead `sudo` starts from a minimal, known-good set and
adds back only what policy permits.

Concretely, by default `sudo`:

- resets `PATH` to the trusted `secure_path` from `sudoers`, defeating the
  `PATH`-injection class that destroyed the hand-rolled wrapper in Chapter 02;
- removes variables known to be dangerous to privileged programs
  (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `IFS`, and others), governed by `env_delete`
  and the `env_reset` default;
- preserves only a small whitelist (`env_keep` — often `TERM`, `DISPLAY`, a few
  others);
- sets `SUDO_USER`, `SUDO_UID`, `SUDO_GID`, `SUDO_COMMAND`, and typically
  `HOME`, `MAIL`, `LOGNAME`, `USER` for the target.

Chapter 07 is devoted to the exact rules (`env_reset`, `env_keep`, `env_check`,
`env_delete`, `secure_path`) and their failure modes. At the skeleton level, the
lesson is: **the environment the command receives is manufactured by `sudo`, not
inherited from you.** This is the second half of the trust-boundary enforcement,
the first half being the credential transition that follows.

## 10. Stage 8 — the credential transition

This is the heart of the entire series, detailed in Chapter 08. Here we only
locate it in the pipeline and name the syscalls.

`sudo` currently runs as `(ruid=1000, euid=0, suid=0)` — you, wearing root's
effective identity. To run the command *as the target user* (root in our
example, but it could be `www-data`), it must reshape both its group and user
credentials, in a specific, security-critical order:

```
setgroups(...)     install the target's supplementary group list
setresgid(g,g,g)   set real/effective/saved GID to target group
setresuid(u,u,u)   set real/effective/saved UID to target user  (LAST)
```

Two ordering rules are non-negotiable and Chapter 08 explains why each is a
vulnerability if violated:

- **Groups before the UID change.** Once you drop the UID, you may lose the
  privilege required to change groups. So supplementary and primary groups are
  set *while still privileged*.
- **UID change last, and via `setresuid` (all three IDs at once), not
  `setuid`.** Setting all of real, effective, and saved simultaneously closes the
  "saved UID still holds 0" door discussed in Chapter 01 — after the transition
  there is no stashed root to climb back to.

For the default `sudo command` (target = root) the "transition" to `euid 0` is
trivial because `euid` is already 0; the meaningful work is setting the *real*
and *saved* IDs to 0 and installing root's groups. For `sudo -u www-data ...` the
transition is a genuine drop from root down to an unprivileged account.

## 11. Stage 9 — executing the command

With credentials, environment, cwd, and umask all set per `command_info`, `sudo`
runs the command with `execve()`. But *how* it runs depends on whether `sudo`
needs to sit between your terminal and the command.

**Direct model (no pty, no I/O logging).** In the simplest case `sudo` does not
need to observe the command's I/O. It still typically **forks**: the child does
the credential transition and `execve`s the target, while the parent `sudo`
process stays alive to wait for the child, relay signals, and report the exit
status. (`sudo` cannot simply `execve` and replace itself if it must still do
bookkeeping like clearing the timestamp on certain signals or reporting status
faithfully.)

**Monitor / pty model (I/O logging or `use_pty`).** When I/O logging is enabled,
or a pseudo-terminal is required, `sudo` allocates a new pty and forks a
**monitor** process. The command runs as the session leader on the pty; the
monitor relays data between the real terminal and the pty, feeding a copy to the
I/O logging plugin (this is what `sudoreplay` later replays). This is why, under
I/O logging, `ps` shows `sudo` still present as a parent while the command runs
underneath it:

```console
# ps -o pid,ppid,euid,cmd --forest
  PID  PPID EUID CMD
 3010  3005 1000 -bash
 5120  3010    0  \_ sudo systemctl restart nginx
 5121  5120    0      \_ systemctl restart nginx
```

`sudo` (5120) has forked the actual command (5121). The target command runs with
the transitioned credentials; `sudo` remains as its parent to manage it.

The choice between models is driven entirely by `command_info` flags from
Stage 6 — another instance of "policy decides, front-end enforces."

## 12. Stage 10 — wait, signals, and exit status

The final stage is faithful teardown. The parent `sudo` process:

- **waits** for the command to terminate;
- **relays signals**: if you press Ctrl-C, the `SIGINT` must reach the command
  (or, under a pty, be delivered through the terminal correctly), and signals the
  command sends must be handled sanely;
- **propagates the exit status**: `sudo` exits with a status derived from the
  command's, so that `$?` in your shell reflects the command, not `sudo` itself.

```console
$ sudo systemctl restart nginx
$ echo $?
0
$ sudo sh -c 'exit 42'
$ echo $?
42
```

The exit status flows back through `sudo` unchanged. To the shell, `sudo` is
transparent to the result. Note the distinction: an exit status originating from
`sudo`'s *own* failure (e.g. authentication failure → 1, command not allowed → 1)
is different from a status *forwarded* from the command; Chapter 12 shows how to
tell them apart when debugging.

## 13. The whole pipeline, observed

The narration above is verifiable in one shot. Here is a single `strace`,
filtered to the load-bearing syscalls, annotated stage by stage. Reading it top
to bottom *is* the chapter:

```console
$ strace -f -e trace=execve,openat,setresuid,setresgid,setgroups \
      sudo -u www-data id 2>&1 | grep -vE 'ENOENT|\.so'
```

```text
# Stage 0/1: shell execs sudo; setuid bit already fired (euid 0)
execve("/usr/bin/sudo", ["sudo","-u","www-data","id"], 0x7ffe...) = 0

# Stage 2: read plugin configuration
openat(AT_FDCWD, "/etc/sudo.conf", O_RDONLY)            = 4

# Stage 3/4: policy plugin loads and evaluates sudoers
openat(AT_FDCWD, "/etc/sudoers", O_RDONLY)              = 5
openat(AT_FDCWD, "/etc/sudoers.d", O_RDONLY|O_DIRECTORY)= 5

# Stage 5: authentication via PAM (reads shadow etc.)  [omitted: many opens]
openat(AT_FDCWD, "/etc/pam.d/sudo", O_RDONLY)           = 6

# Stage 8: credential transition — groups first, gid, then uid LAST
setgroups(1, [33])                                      = 0
setresgid(-1, 33, -1)                                   = 0
setresuid(-1, 33, -1)                                   = 0

# Stage 9: execute the target command as www-data (uid/gid 33)
execve("/usr/bin/id", ["id"], 0x55...)                 = 0
```

Every stage of §1's diagram appears, in order, in real syscalls: the entry
`execve`, the config read, the policy read, the PAM read, the ordered credential
change, and the final `execve` of the target. The five lines of the credential
transition and target exec are the exact same five lines promised as "the thesis
of the series" back in Chapter 01 — now situated in the full pipeline that
produces them.

## 14. Where the detail lives

This chapter is a map; the territory is the rest of the series. The pointer table:

| Stage in this chapter                | Detailed in |
| ------------------------------------ | ----------- |
| 3–4  Policy source, matching         | 04 — The sudoers File |
| 2–3  Plugin API, front-end/plugin split | 05 — Policy and Plugin Architecture |
| 5    PAM conversation                | 06 — Authentication with PAM |
| 7    Environment sanitization        | 07 — Environment Handling |
| 8    Credential transition syscalls  | 08 — Privilege Transition |
| 9–10 Logging, I/O capture, replay    | 09 — Logging and Auditing |
| 1,4  Where untrusted input meets root| 10 — Security Considerations |

## 15. What this chapter established

- A `sudo` invocation is a **fixed-order pipeline**: exec (setuid fires) →
  front-end init and argv split → load plugins → policy `open` → policy decision
  → authentication → build `command_info` → environment construction → credential
  transition → execute → wait/relay/report.
- `sudo` is **privileged from its first instruction** (`euid 0` via the setuid
  bit) and holds a **hostile environment** the entire time; authorization is a
  gate the already-root process imposes on itself, and environment sanitization
  plus the credential change are how it enforces the trust boundary.
- The design is **front-end + plugins**: a policy-agnostic front-end drives a
  policy plugin that returns a `command_info` contract; the front-end *enforces*
  what the plugin *decides*. Stages 0–2 are identical regardless of policy
  backend.
- Order is security-critical: **policy match precedes authentication**, and in
  the credential transition **groups precede the GID change, and the UID change
  comes last via `setresuid`**.
- Execution uses a **direct fork/wait model** or a **pty+monitor model** depending
  on whether I/O must be observed; either way `sudo` faithfully relays signals and
  propagates the command's exit status.
- The entire pipeline is **observable** in a single filtered `strace`, and every
  stage maps to a later chapter for its full treatment.

The next chapter descends into Stage 4 — the policy itself. *The sudoers File*
takes the one line `parsa ALL=(root) /usr/bin/systemctl restart nginx` and
explains the complete grammar behind it: aliases, the host/runas/command tuple,
`Defaults`, rule ordering and "last match wins", and the ways a rule can silently
grant far more than its author intended.
