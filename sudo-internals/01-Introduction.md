# 01 — Introduction

Every time you type `sudo`, a short-lived, unprivileged process reaches across
one of the most important trust boundaries in the operating system and comes
back running as `root`. That crossing is not magic and it is not a single flag.
It is a precise, auditable sequence of decisions and syscalls, each of which can
be observed, and each of which — if it is wrong — becomes a privilege-escalation
vulnerability.

This chapter builds the vocabulary and the mental model that the rest of the
series depends on. If you already think of privilege in Unix as "root or
not-root," this chapter's main job is to dismantle that idea and replace it with
the real thing: a small set of numeric credentials attached to every process,
which the kernel consults on every privileged operation.

## 1. What "privilege" actually is

There is a persistent myth that Linux has two states — root and everyone else —
and that a program is either "running as root" or not. This is false in a way
that matters. Privilege in a Unix-like system is not a boolean; it is a
**credential set** carried by each process, and the kernel evaluates it
per-operation.

For a running process, the security-relevant credentials include:

- A set of **user IDs**: real, effective, saved, and (on Linux) filesystem.
- A set of **group IDs**: real, effective, saved, and filesystem.
- A list of **supplementary groups**.
- On modern Linux, a set of **capabilities** — a decomposition of `root`'s
  historically all-or-nothing power into discrete bits (covered in the
  companion Capabilities notes and revisited in Chapter 08).

You can read most of this for any process. For your shell:

```console
$ id
uid=1000(parsa) gid=1000(parsa) groups=1000(parsa),27(sudo),100(users)
```

The kernel keeps the fuller picture in `/proc`:

```console
$ grep -E '^(Uid|Gid|Groups):' /proc/self/status
Uid:	1000	1000	1000	1000
Gid:	1000	1000	1000	1000
Groups:	27 100
```

The four numbers on the `Uid:` line are, in order, **real / effective / saved /
filesystem**. Right now they are identical, because nothing has changed them.
The entire subject of this series is what happens to those four numbers between
the moment you press Enter on `sudo` and the moment your command runs.

## 2. The three user IDs (and the fourth)

The reason there is more than one UID is historical but not obsolete: it exists
precisely so that a privileged program can *temporarily* hold power and then set
it aside safely. Understanding each ID is the prerequisite for understanding
`sudo` at all.

**Real UID (`ruid`)** — who you *are*. It records the identity that started the
process and does not change on its own. It is used for accounting ("whose job is
this?") and, importantly, for deciding who is allowed to send signals to whom.

**Effective UID (`euid`)** — who the kernel *treats you as* for most permission
checks. When a program opens a file, creates a process, or performs almost any
privileged action, the kernel looks at the `euid` (and effective/supplementary
groups), not the real one. This is the ID that a `setuid` program elevates.

**Saved set-user-ID (`suid`)** — a *stash*. When a `setuid` program starts, the
kernel copies the elevated `euid` into the `suid`. This lets a careful program
**drop** privilege (set `euid` down to the unprivileged `ruid`) to do risky work
safely, and later **regain** it (restore `euid` from the stashed `suid`). Without
a saved UID, dropping privilege would be a one-way door.

**Filesystem UID (`fsuid`)** — a Linux-specific ID used specifically for
filesystem access checks. It normally tracks `euid` automatically and you rarely
touch it directly; it exists for an old NFS-daemon edge case. For our purposes:
assume `fsuid == euid` unless something deliberately changes it.

Throughout this series these are written as a triplet: `(ruid, euid, suid)`. A
normal login shell sits at `(1000, 1000, 1000)`. The whole point of `sudo` is to
engineer a controlled, policy-checked transition of that triplet.

### Why "saved UID" is not academic

Consider a privileged network daemon that must bind to port 80 (which requires
privilege) but should not run privileged while handling untrusted client data. A
correctly written daemon does this:

```
start:                 (0, 0, 0)          # started as root
bind port 80           # allowed, euid == 0
drop privilege:        (0, 1000, 0)  →  set euid to unprivileged user
                       # note: suid still holds 0
handle clients         # a bug here runs as uid 1000, not root
regain if needed:      (0, 0, 0)          # restore euid from saved suid
```

The `suid` is what makes the last step possible. This exact pattern — drop to do
work, keep the ability to come back — is central to how `sudo` reasons about
privilege, and it is also where a whole family of bugs lives: programs that
*think* they dropped privilege but left the saved UID at `0`, letting an attacker
who gains code execution simply set `euid` back to `0`. Chapter 08 shows why
`setuid()` is the wrong call for this and `setresuid()` is the right one.

## 3. Where the privilege comes from: the setuid bit

None of the above explains where a `sudo` process gets its power in the first
place. The answer is a single bit in the file's mode, set on the `sudo`
executable itself.

```console
$ ls -l "$(command -v sudo)"
-rwsr-xr-x 1 root root 277936 Apr  1  2024 /usr/bin/sudo
```

Read that mode carefully. The owner is `root`. In the owner's execute position,
where you would expect `x`, there is an **`s`** — the **set-user-ID bit**. This
is the pivot of the entire mechanism.

When you `execve()` a file that has the setuid bit set, the kernel does not run
it with *your* effective UID. It runs it with the **file owner's** UID. Because
`sudo` is owned by `root`, executing it produces a process whose credentials
have already jumped:

```
before execve (your shell):   (1000, 1000, 1000)
after  execve (sudo running):  (1000, 0,    0)
                                 ^     ^     ^
                                 |     |     saved  = 0  (stashed)
                                 |     effective = 0  (now root)
                                 real  = 1000 (still you)
```

Note what *did not* change: your **real** UID is still `1000`. This is deliberate
and crucial. `sudo` knows who invoked it (`ruid = 1000`) precisely because the
real UID is preserved — that is how it can look you up in the policy and decide
whether you are allowed to proceed. It becomes root (`euid = 0`) so that it *can*
read `/etc/sudoers`, talk to PAM, write audit logs, and ultimately set the target
credentials. The setuid bit is not the end of the story — it is the bootstrap
that gives `sudo` enough privilege to make a decision.

You can confirm the jump directly. This is `sudo` inspecting its own credentials
the instant it starts, before it does anything else:

```console
$ sudo grep -E '^(Uid|Gid):' /proc/self/status
Uid:	1000	0	0	0
Gid:	1000	0	0	0
```

Real UID `1000` (you). Effective UID `0` (root). Saved UID `0`. The setuid bit
did that, at `execve` time, before a single line of `sudo`'s own logic ran.

## 4. So what is sudo, mechanically?

With the model in place, `sudo` can be defined precisely. `sudo` is a
**setuid-root policy engine**. Its job is not "to become root" — the setuid bit
already did that. Its job is to answer a question and then act on the answer:

> *Given that user X (identified by the preserved real UID) wants to run command
> C as target user Y, does policy permit it — and if so, transition the process
> credentials to Y and execute C.*

Every stage of the series maps onto part of that sentence:

| Stage                    | What it decides / does                                  | Chapter |
| ------------------------ | ------------------------------------------------------- | ------- |
| Identify the invoker     | Uses the preserved real UID; loads plugins.             | 03, 05  |
| Consult policy           | Evaluates `sudoers` rules for X → (C as Y).             | 04      |
| Verify identity          | Authenticates X via PAM (password, etc.).               | 06      |
| Build a safe environment | Strips/rebuilds the environment before running C.       | 07      |
| Transition credentials   | Sets `(ruid, euid, suid)` and groups to target Y.       | 08      |
| Record what happened     | Writes the audit trail: syslog, I/O logs.               | 09      |

Two consequences of this definition are worth stating now because they surprise
people:

1. **`sudo` runs as root long before you type your password.** By the time the
   password prompt appears, `euid` is already `0`. Authentication is a *policy*
   requirement enforced by a root process, not a technical gate on becoming
   root. This is why a bug in `sudo`'s argument parsing (before authentication)
   can be catastrophic — the vulnerable code is already running as root. This is
   exactly the shape of `CVE-2021-3156` (Baron Samedit): a heap overflow reached
   *before* any password check, in code already at `euid = 0`.

2. **The target is not necessarily root.** `sudo -u www-data command`
   transitions to `www-data`, not `root`. The mechanism is a general credential
   transition; `root` is just the default target. This is why `sudo` is better
   understood as controlled *identity change* than as "run as admin."

## 5. The trust boundary

The single most useful idea to hold onto is that `sudo` sits astride a **trust
boundary**, and almost every `sudo` vulnerability is a failure to keep untrusted
input on the correct side of it.

On the untrusted side: everything the invoking user controls — the command-line
arguments, the environment variables, the terminal, the current working
directory, file descriptors, resource limits. All of it originates from a user
who, by assumption, does *not* already have the privilege they are requesting.

On the trusted side: the policy in `/etc/sudoers`, the PAM configuration, the
audit sinks, and the target credentials — all of which are controlled by the
administrator.

`sudo`'s correctness depends entirely on treating the first set as hostile while
operating with the second set's authority. When that fails, the results are the
canonical `sudo` CVEs:

- **Untrusted argument reaches privileged code before validation** →
  `CVE-2021-3156`, a heap buffer overflow in argv escaping.
- **Untrusted UID string parsed with a permissive rule** →
  `CVE-2019-14287`, where `sudo -u '#-1'` was interpreted as UID `0`, letting a
  user forbidden from running as root do exactly that.
- **Untrusted environment leaking into the executed command** → the entire
  reason Chapter 07 exists.

We are not cataloguing CVEs for their own sake. Each one is a specific instance
of the general failure the trust boundary is meant to prevent, and each maps
cleanly onto one of the mechanisms this series dissects.

## 6. What we can observe (and how)

This series insists on observation over assertion, so it is worth naming the
instruments up front. Nearly every claim in later chapters is demonstrated with
one of these:

- `id` and `/proc/<pid>/status` — the credential set of a process at rest.
- `strace -f -e trace=%process,setresuid,setresgid,setgroups sudo ...` — the
  actual syscalls `sudo` issues, including the credential transition itself.
- `getpcaps <pid>` and `/proc/<pid>/status` (Cap* lines) — the capability set.
- `sudo -l` — how `sudo` reports its own policy decision for the current user.
- `sudo` debug logging (Chapter 12) and `sudoreplay` — `sudo`'s own view of what
  it did, at whatever verbosity we ask for.

A first taste, tying the whole chapter together — watching the credential
transition happen at the syscall level:

```console
$ strace -f -e trace=setresuid,setresgid,setgroups,execve \
      sudo -u nobody id 2>&1 | grep -E 'setres|setgroups|execve.*/id'
execve("/usr/bin/sudo", ["sudo", "-u", "nobody", "id"], 0x7ffe...) = 0
setgroups(1, [65534])                   = 0
setresgid(-1, 65534, -1)                = 0
setresuid(-1, 65534, -1)                = 0
execve("/usr/bin/id", ["id"], 0x55...)  = 0
```

Read top to bottom, that is the entire thesis of the series in five lines:
`sudo` is entered via `execve` (setuid bit fires, `euid → 0`), it sets the
supplementary and effective group to `nobody`'s (`65534`), sets the effective
UID to `nobody`'s, and finally `execve`s the target command, which now runs as
`nobody`. Every one of those lines has a chapter behind it explaining why it is
exactly the way it is — and what goes wrong when it isn't.

## 7. What this chapter established

- Privilege in Linux is a **per-process credential set**, not a root/non-root
  boolean.
- Each process carries **real, effective, and saved** user and group IDs, written
  here as `(ruid, euid, suid)`; `euid` drives most checks, `ruid` records
  identity, `suid` is the stash that makes dropping and regaining privilege safe.
- `sudo` gets its power from the **setuid bit** on a root-owned binary, which
  elevates `euid` to `0` at `execve` time while preserving `ruid` — so `sudo`
  knows *who* is asking while having the authority to *act*.
- `sudo` is therefore a **setuid-root policy engine**: identify → decide →
  authenticate → sanitize → transition → audit.
- It sits on a **trust boundary**; nearly every `sudo` vulnerability is untrusted
  input crossing that boundary into privileged code.

The next chapter, *Why Sudo Exists*, asks the obvious follow-up: if the setuid
bit alone can elevate privilege, why do we need `sudo` at all — and why not `su`,
a hand-written setuid wrapper, or raw capabilities? Answering that precisely is
what justifies every piece of machinery in the chapters that follow.
