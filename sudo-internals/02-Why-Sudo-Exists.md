# 02 — Why Sudo Exists

The previous chapter ended on a deliberately provocative point: the `setuid` bit
alone can elevate privilege. If a single bit on a root-owned binary is enough to
run code as `root`, then `sudo` — with its policy language, its PAM integration,
its plugins, its audit logs, its tens of thousands of lines of C — looks like an
enormous amount of machinery bolted onto a mechanism that already works.

This chapter argues that every piece of that machinery is load-bearing. It does
so by taking the problem `sudo` solves and attacking it with every *simpler*
tool first — the shared root password, `su`, a hand-written `setuid` wrapper,
Unix groups, and modern Linux capabilities — and showing precisely where each
one breaks. What remains standing after all of them fail is the exact shape of
`sudo`.

The method here is subtractive. We are not going to praise `sudo`. We are going
to try to *avoid* it, fail in instructive ways, and let the requirements fall out
of the failures.

## 1. The problem, stated precisely

Strip away the tooling and the actual requirement is a sentence that
administrators have needed to satisfy since multi-user Unix existed:

> *Allow specific, named users to perform specific privileged actions — and
> nothing more — while recording who did what, without handing out the keys to
> the whole system.*

Unpack that sentence and it contains at least six distinct requirements, each of
which a real solution must satisfy simultaneously:

1. **Selective grant.** Privilege goes to *named* principals, not to everyone
   and not to "whoever knows the password."
2. **Least privilege.** A user granted the ability to restart a web server
   should not thereby gain the ability to read every file on the system. The
   grant must be scoped to *actions*, not to *identities wholesale*.
3. **Authentication of the requester.** The system must confirm that the person
   invoking privilege is who they claim to be — and, critically, it should test
   *their* identity, not the identity of the account they are trying to reach.
4. **Accountability.** After the fact, an auditor must be able to answer "who ran
   this command, as whom, when, and from where." A privileged action with no
   attributable origin is a security hole by definition.
5. **Controlled context.** The elevated action must not inherit hostile state —
   a poisoned environment, a hijacked `PATH`, an unexpected working directory —
   from the unprivileged caller.
6. **Revocability.** Removing a person's privilege must be a small, local,
   reversible change — not a password rotation that affects everyone.

Hold these six requirements in mind. They are the rubric. Every candidate
solution below satisfies some of them and fails others, and `sudo` is simply the
first design that satisfies all six at once.

## 2. Approach zero: share the root password

The most primitive solution is to give the privileged users the `root` password
and let them log in as `root` (or `su` to it) when they need to.

```console
$ su -
Password:
# whoami
root
```

It works, in the narrow sense that the privileged action becomes possible. It
also fails the rubric almost completely, and it is worth being explicit about
*why*, because each failure is a requirement that `sudo` will later have to meet.

**It fails selective grant and least privilege together.** A shared root password
is not a grant to *do a thing*; it is a grant to *be root*, permanently and
totally. The user who needed to restart one service can now read `/etc/shadow`,
overwrite the bootloader, and delete every home directory. There is no scope.

**It fails authentication in a subtle but fatal way.** The password being tested
is `root`'s, not the user's. The system learns "someone who knows the root
password is here." It never learns *which* human that was. Ten administrators
sharing one password are, to the system, indistinguishable.

**That indistinguishability destroys accountability.** When the audit log records
a destructive command run by `uid 0`, there is no way to trace it back to a
person. The log says `root did it`. Everyone is root; no one is anyone.

**It fails revocability catastrophically.** To revoke one person's access you
must change the root password — which revokes *everyone's* access simultaneously
and forces a re-distribution of the new secret. Offboarding one contractor
becomes a coordinated password rotation across the whole team.

Approach zero establishes the two deepest requirements by violating them:
**authenticate the individual, and attribute actions to the individual.** A
shared secret can do neither, because a shared secret erases individuality by
design.

## 3. `su`: the direct ancestor

`su` ("substitute user") is the tool `sudo`'s name deliberately echoes, and it is
the closest primitive ancestor. It is itself a `setuid`-root binary:

```console
$ ls -l "$(command -v su)"
-rwsr-xr-x 1 root root 71912 Mar 23  2024 /usr/bin/su
```

`su` switches the current shell's identity to another user, defaulting to
`root`. `su -` (or `su -l`) additionally simulates a full login: it runs the
target's login shell, resets the environment, and changes to the target's home
directory.

```console
$ id
uid=1000(parsa) gid=1000(parsa) groups=1000(parsa),27(sudo)
$ su -
Password:
# id
uid=0(root) gid=0(root) groups=0(root)
# pwd
/root
```

`su` is a genuine improvement over the raw shared password in exactly one place:
combined with a policy that restricts *who may run it* (historically the `wheel`
group), it can gate access. But measured against the full rubric it still fails
on almost every axis, and the failures are structural rather than incidental.

**`su` still authenticates the target, not the invoker.** By default, `su -`
prompts for the *root* password. This inherits approach zero's core flaw
directly: to let ten admins use `su`, root's password must be known to all ten.
`su` narrows *who can attempt* the switch but not *what secret is required*, and
the required secret is still a shared one.

> There is a mitigation — PAM's `pam_wheel.so` can restrict `su` to the `wheel`
> group, and some configurations authenticate the invoking user. But this is
> layering policy on top of a tool that was not designed to carry it, and it
> still cannot express *per-command* policy, which is the next failure.

**`su` is all-or-nothing.** Once the switch happens, you have a full shell as the
target user. There is no way, within `su` itself, to say "this person may run
*only* `systemctl restart nginx` as root." `su` grants an identity, not an
action. Least privilege is unreachable by construction: the unit of grant is a
whole shell.

**`su`'s accountability is coarse.** The audit trail records that a user invoked
`su` and became root. What they *did* inside that root shell is not attributed by
`su` — it is a root session, and every command inside it is simply "root." You
learn that a door was opened, not what walked through it.

```console
# journalctl -t su --no-pager | tail -1
Apr 12 09:14:02 host su[4821]: (to root) parsa on pts/3
```

That single log line is the entire record: `parsa` became `root` on `pts/3`. The
subsequent `rm -rf`, `cat /etc/shadow`, or `curl | sh` inside that shell leaves
no `su`-attributable trace.

So `su` advances the rubric by one step — with external PAM policy it can gate
*who* — while leaving four requirements unmet: it authenticates the wrong
principal, it cannot scope to actions, it cannot attribute individual commands,
and it offers no per-user revocation independent of the shared target secret.

## 4. Hand-rolled `setuid` wrappers

The next instinct of a competent engineer is to reach past `su` and build exactly
the narrow grant they need. "I don't want to give anyone root. I just want the
backup operators to run *one script* as root. I'll write a tiny `setuid` wrapper
that does only that."

This is the most instructive failure in the entire chapter, because it *looks*
like it satisfies least privilege — and it opens a privilege-escalation hole
almost every time it is attempted by hand.

### 4.1 The kernel will not let you shortcut with a script

The first attempt is usually a shell script:

```console
$ cat /usr/local/bin/backup
#!/bin/bash
tar czf /backups/home.tgz /home
$ sudo chown root:root /usr/local/bin/backup
$ sudo chmod 4755 /usr/local/bin/backup
$ ls -l /usr/local/bin/backup
-rwsr-xr-x 1 root root 54 Apr 12 09:20 /usr/local/bin/backup
```

The `setuid` bit is set. And yet:

```console
$ ./backup
$ id -u        # inside the script, if we check: still 1000, not 0
```

The Linux kernel **deliberately ignores the `setuid` bit on interpreted
scripts** — any file beginning with a `#!` shebang. This is not a bug; it is a
decades-old security decision. A `setuid` script has an unavoidable race between
the kernel opening the script to read the interpreter and the interpreter
re-opening the script to read it, and the semantics of interpreter argument
handling are exploitable. So the kernel refuses. To get a `setuid` effect you
must compile a real binary.

### 4.2 The compiled wrapper — and its attack surface

So the engineer writes C:

```c
/* backup.c — a "minimal" setuid wrapper. It is not safe. */
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    /* We are setuid-root: euid == 0 here. */
    system("tar czf /backups/home.tgz /home");
    return 0;
}
```

```console
$ cc -o backup backup.c
$ sudo chown root:root backup
$ sudo chmod 4755 backup
$ ls -l backup
-rwsr-xr-x 1 root root 16240 Apr 12 09:31 backup
```

Now it *works*: running `./backup` produces a root-owned tarball. It even looks
like least privilege — the operator can run exactly one action as root and gets
no shell. Requirement 2 appears satisfied.

It is also a textbook local privilege-escalation vulnerability, and the exploit
takes three lines.

### 4.3 Exploiting the wrapper: PATH injection

The flaw is `system("tar ...")`. `system()` runs its argument through
`/bin/sh -c`, and the shell resolves `tar` using the `PATH` environment
variable — which is controlled entirely by the *unprivileged caller*. Nothing in
the wrapper pins `tar` to an absolute path. So the attacker supplies their own
`tar`:

```console
$ cat > /tmp/tar <<'EOF'
#!/bin/bash
cp /bin/bash /tmp/rootbash
chmod 4755 /tmp/rootbash
EOF
$ chmod +x /tmp/tar
$ PATH=/tmp:$PATH ./backup            # the wrapper finds /tmp/tar first
$ /tmp/rootbash -p
rootbash-5.2# id
uid=1000(parsa) euid=0(root) gid=1000(parsa) egid=0(root) groups=...
```

The wrapper, running as root, executed the attacker's `tar`, which copied a shell
and made it `setuid`-root. The operator who was supposed to be able to run *only*
a backup now has a root shell. Least privilege was an illusion; the wrapper
handed over everything.

This single class of bug — a privileged program trusting caller-controlled
environment or `PATH` — has produced an enormous share of Unix local
root exploits. And PATH is only one entry in a long list: the environment also
carries `IFS`, locale variables, `TMPDIR`, and (for dynamically linked binaries
that are *not* in secure-execution mode) `LD_PRELOAD` and `LD_LIBRARY_PATH`. A
correct wrapper would have to reset `PATH` to a known-safe value, scrub the
entire environment, use absolute paths for every executable, avoid `system()`
and `popen()` entirely in favor of `execve()` with a controlled `envp`, drop
privileges correctly with `setresuid()`, and validate every argument.

Note that the dynamic loader *does* help here: for `setuid` binaries it enters
secure-execution mode (`AT_SECURE`) and ignores `LD_PRELOAD`/`LD_LIBRARY_PATH`.
But that mitigation does nothing for the `PATH` attack above, because the poison
enters through the shell that `system()` spawns, not through the loader.

### 4.4 Why hand-rolled wrappers fail as a *class*

The point is not that this particular wrapper was written badly. The point is
that **every** privileged wrapper must independently and correctly re-solve the
same hard problems — environment sanitization, safe process execution, argument
validation, correct privilege handling — and each wrapper is a fresh, standalone
attack surface. An organization with fifty such tasks has fifty setuid binaries,
each one an independent chance to get it catastrophically wrong, with:

- **No central policy.** The grants are scattered across the filesystem as mode
  bits. There is no single place to read "who can do what."
- **No authentication.** The wrapper runs the instant it is invoked; it never
  confirms the caller is who they should be. Anyone who can execute the file gets
  its privilege.
- **No auditing.** Unless each wrapper hand-writes logging, there is no record of
  invocations.
- **No revocation story.** Removing access means finding and un-setting the bit,
  or deleting the binary, per host, by hand.

Hand-rolled wrappers satisfy the *shape* of least privilege while failing
authentication, accountability, controlled context, and central revocability —
and they do it while multiplying attack surface. This failure is the strongest
positive argument for `sudo`: it is, in essence, **one correctly written,
heavily audited setuid-root program that solves the environment/execution/
privilege problems once, so that fifty individual engineers do not each solve
them wrong.**

## 5. Unix groups and file permissions

A different instinct avoids `setuid` entirely: use the permission model that Unix
already has. If a set of users needs to read the system logs, put them in the
`adm` group and make the logs group-readable. If they need block-device access,
the `disk` group exists.

```console
$ sudo usermod -aG adm parsa
$ ls -l /var/log/syslog
-rw-r----- 1 root adm 1048576 Apr 12 09:40 /var/log/syslog
```

This is genuinely the right tool for a specific shape of problem: **granting
access to specific *objects* (files, devices) by group ownership.** Where the
privileged action reduces to "read/write these files," groups are simpler,
faster, and safer than `sudo`, because no privilege transition happens at all —
the user simply *is* a member of a group that owns the resource.

But most administrative actions are not expressible as file permissions, and the
group model has hard limits against the rubric:

**Granularity is by object, not by action.** Group membership grants access to
everything that group owns, statically. You cannot say "member may *append* to
the log via one specific tool but not read the whole file," and you certainly
cannot say "member may run *this command* as root." Many groups are also
dangerously broad by side effect: membership in `disk` grants raw read/write to
block devices, which is trivially root-equivalent (read `/dev/sda`, extract
`/etc/shadow`; write it, rewrite anything).

**Some actions inherently require privilege that no group confers.** Binding a
port below 1024, loading a kernel module, changing another process's namespace,
setting the system clock — these are not "access to a file." They require actual
elevated capability, which group membership does not provide.

**No authentication or per-action audit.** Group membership is ambient: once
you're in the group, every access is silent and unattributed beyond normal file
auditing.

Groups satisfy selective grant and (for object access) least privilege
elegantly, and they are the correct answer when the task truly is file access.
They cannot express command-level policy, cannot confer non-file privilege, and
carry no authentication or command audit. They are a complement to `sudo`, not a
substitute for it.

## 6. Capabilities: decomposing `root`

The most modern and most serious alternative is Linux **capabilities**. Since
kernel 2.2, the monolithic power of `uid 0` has been split into ~40 discrete
units — `CAP_NET_BIND_SERVICE` (bind low ports), `CAP_NET_ADMIN` (configure
networking), `CAP_SYS_TIME` (set the clock), `CAP_DAC_OVERRIDE` (bypass file
permission checks), and so on. Capabilities can be attached directly to an
executable file, so a program can be granted *exactly* the privilege it needs
without being `setuid`-root at all.

The canonical example is a web server that must bind port 80 but otherwise needs
no privilege:

```console
$ sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/myserver
$ getcap /usr/local/bin/myserver
/usr/local/bin/myserver cap_net_bind_service=ep
$ ls -l /usr/local/bin/myserver          # note: NOT setuid
-rwxr-xr-x 1 root root 2400160 Apr 12 09:50 /usr/local/bin/myserver
```

Now `myserver` can bind port 80 while running as an unprivileged user, holding
*only* the one capability, with no `setuid` bit anywhere. This is a strict
improvement over `setuid`-root for that use case: the blast radius of a
compromise is one capability instead of all of root.

Capabilities are essential and the companion Capabilities notes cover them in
depth. But they are **not a replacement for `sudo`**, and understanding why
sharpens the definition of what `sudo` is.

**Capabilities describe *kind of power*, not *who / when / which command*.** A
file capability is a static property of a binary: anyone who can execute the file
gets the capability. There is no notion of "user X may invoke this, user Y may
not." Identity is absent. To reintroduce identity you need... a policy engine
that checks the caller — which is `sudo`.

**Granularity is per-capability, and several capabilities are root-equivalent.**
The decomposition is real but coarse at the top: `CAP_DAC_OVERRIDE` bypasses all
file permission checks; `CAP_SETUID` lets a process become any UID including 0;
`CAP_SYS_ADMIN` is so broad it is nicknamed "the new root." Granting one of
these is functionally granting root. Capabilities give you a scalpel for the
*narrow* cases and a sledgehammer for the broad ones, with little in between —
and no way to say "only for this specific command line."

**No authentication.** A file capability fires the moment the binary runs. There
is no password prompt, no PAM stack, no confirmation that the invoker is
authorized. The capability *is* the authorization, and it is attached to a file
that anyone with execute permission can run.

**No built-in audit or revocation policy.** Capabilities are xattrs on files.
There is no central record of "who used this capability when," and revocation
means editing file attributes, per host, per binary.

Capabilities and `sudo` are complementary, and in fact modern `sudo` can *use*
capabilities — it can transition a command into a state holding only a specified
capability set rather than full root, giving you `sudo`'s identity/policy/audit
front-end with capabilities' least-privilege back-end. That combination is the
state of the art, and it only exists because each tool supplies what the other
lacks: capabilities supply fine-grained *power*, `sudo` supplies *identity,
policy, authentication, and accountability* around it.

## 7. What only `sudo` provides

Lay the candidates against the six-part rubric and the pattern is unmistakable.

| Requirement            | Shared pw | `su`       | setuid wrapper | Groups     | Capabilities | `sudo` |
| ---------------------- | --------- | ---------- | -------------- | ---------- | ------------ | ------ |
| Selective grant        | ✗         | partial\*  | ✓              | ✓          | partial      | ✓      |
| Least privilege        | ✗         | ✗          | ✓ (fragile)    | object-only| ✓ (coarse)   | ✓      |
| Authenticate *invoker* | ✗         | ✗          | ✗              | n/a        | ✗            | ✓      |
| Accountability / audit | ✗         | coarse     | ✗              | ✗          | ✗            | ✓      |
| Controlled context     | ✗         | ✗          | ✗ (DIY)        | n/a        | n/a          | ✓      |
| Revocability           | ✗         | shared     | manual         | ✓          | manual       | ✓      |

\* `su` can gate *who may attempt* via `pam_wheel`, but not per-command.

`sudo` is the only column that is filled top to bottom, and it earns each mark
with a specific mechanism that the rest of this series dissects:

**Centralized, declarative policy (`/etc/sudoers`).** Instead of scattering mode
bits and capabilities across the filesystem, `sudo` reads one policy source that
expresses grants as `who → (which commands) as (which target user) on (which
hosts)`. The backup operator's grant becomes a single readable line, and the
answer to "what can this person do?" is `sudo -l`.

```sudoers
# One line replaces the entire dangerous setuid wrapper of §4:
backup  ALL=(root) NOPASSWD: /usr/bin/tar czf /backups/home.tgz /home
```

**Authentication of the *invoker*.** `sudo` verifies *your* identity — your
password, your token, your fingerprint via PAM (Chapter 06) — never the target
account's. Ten administrators need zero shared secrets; each proves they are
themselves. This is the single cleanest break from every predecessor in this
chapter.

**Command-level least privilege.** The grant is scoped to commands (optionally
to exact arguments), and the target user is explicit and need not be root
(`sudo -u www-data ...`). The unit of privilege is an action, not an identity.

**Accountability by construction.** Every invocation is logged with the real
identity of the invoker, the command, the target, the terminal, and the time —
and optionally the full I/O of the session, replayable with `sudoreplay`
(Chapter 09). The audit answers "who, what, as whom, when, from where" without
the operator having to build logging by hand.

```console
Apr 12 09:14:02 host sudo[5120]: parsa : TTY=pts/3 ; PWD=/home/parsa ;
    USER=root ; COMMAND=/usr/bin/systemctl restart nginx
```

That log line does what neither `su` nor a wrapper could: it names the human,
the exact command, and the target — a full attribution.

**Controlled execution context.** `sudo` sanitizes the environment (Chapter 07),
resets `PATH` to a trusted `secure_path`, and constructs the target environment
deliberately — solving, *once and correctly*, the exact class of bug that made
the §4 wrapper exploitable. The `PATH`-injection attack that defeated the
hand-rolled wrapper simply does not reach a command run under a properly
configured `sudo`.

**Fine-grained revocation.** Removing a grant is deleting a line from `sudoers`.
No password rotation, no hunting for mode bits, no coordinated re-distribution of
a secret. Offboarding one person touches only that person's rules.

**A usability property that turns out to be a security property: caching.**
`sudo` records a short-lived authentication timestamp (the "ticket," configurable
via `timestamp_timeout`, commonly 15 minutes) so a burst of privileged commands
does not require re-typing a password each time. This is not merely convenience:
it directly reduces the temptation to keep a permanent root shell open, which is
the behavior `su` encourages and which is far more dangerous than a series of
attributable, individually logged `sudo` invocations.

## 8. A worked scenario: the backup operator

To make the abstract concrete, take one realistic requirement and run it through
every approach:

> The user `backup` must be able to run the system backup — and nothing else — as
> `root`. Every run must be attributable. The grant must be removable in seconds.

- **Shared root password.** `backup` becomes fully root and can do anything;
  runs are attributed to "root"; revoking means changing root's password for
  everyone. *Fails 2, 3, 4, 6.*
- **`su`.** Same shared-secret and full-root problems; the backup happens inside
  an unattributed root shell. *Fails 2, 3, 4, 6.*
- **`setuid` wrapper.** Scoped to the one action — until `PATH=/tmp:$PATH`
  turns it into a root shell (§4.3). No auth, no audit. *Fails 3, 4, 5;
  "satisfies" 2 only until exploited.*
- **Groups.** There is no group that means "may run the backup as root." The
  action is not file access. *Not expressible.*
- **Capabilities.** You could grant the backup binary `CAP_DAC_READ_SEARCH` to
  read every file — but that is a static grant to *anyone* who runs the binary,
  with no identity check and no audit, and `CAP_DAC_READ_SEARCH` is itself
  root-equivalent for reads. *Fails 3, 4; over-grants.*
- **`sudo`.** One line:
  `backup ALL=(root) NOPASSWD: /usr/local/sbin/run-backup`. Scoped to one
  command, as root, attributed in the logs on every run, removable by deleting
  the line. Environment sanitized so no `PATH` trick reaches the script. *Passes
  the entire rubric.*

Only the last approach satisfies the requirement as stated. That is not a
coincidence and it is not marketing: it is the direct consequence of `sudo` being
the one design built to satisfy all six requirements at once, rather than a tool
that happens to make privilege possible.

## 9. What this chapter established

- The real requirement `sudo` addresses is a six-part rubric: **selective grant,
  least privilege, authentication of the invoker, accountability, controlled
  context, and revocability** — all at once.
- **Shared passwords** and **`su`** authenticate the *target* account and grant a
  *whole identity*, destroying least privilege and individual accountability;
  revocation means rotating a shared secret.
- **Hand-rolled `setuid` wrappers** appear to give least privilege but force every
  author to independently re-solve environment sanitization and safe execution;
  the near-universal result is a `PATH`/environment injection bug — demonstrated
  live in §4.3 — that hands back full root. Their deeper failure is having *no*
  central policy, authentication, audit, or revocation.
- **Groups** are the correct tool for *object* access and nothing more; they
  cannot express command-level policy or confer non-file privilege.
- **Capabilities** correctly decompose root's *power* and are complementary to
  `sudo`, but they carry no identity, authentication, audit, or per-command
  policy — and several individual capabilities are themselves root-equivalent.
- **`sudo`** is the only design that satisfies the full rubric, and it does so by
  being *one* correctly written setuid-root policy engine — centralizing policy,
  authenticating the invoker, scoping to commands, auditing every invocation,
  sanitizing the environment, and making revocation a one-line edit.

Having justified *why* the machinery exists, the series can now open the machine.
The next chapter, *How Sudo Works*, traces a single invocation end to end at a
high level — from the `execve` that fires the setuid bit, through plugin load,
policy evaluation, authentication, and environment construction, to the final
credential transition — establishing the skeleton that Chapters 04 through 09
then flesh out one joint at a time.
