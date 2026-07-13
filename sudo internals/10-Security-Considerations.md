# 10 — Security Considerations

The series has, until now, been descriptive: this is how `sudo` works, stage by
stage. This chapter is evaluative. It steps back from the mechanism and asks the
harder question — *where does `sudo` go wrong, and why do the same kinds of
failure keep recurring?*

The answer is that `sudo`'s entire job is to sit astride a **trust boundary**, and
every serious `sudo` vulnerability is, at root, untrusted input crossing that
boundary into privileged execution. The specific CVEs the series has met in
passing — the argument-parsing overflow, the runas `-1` bypass, the environment
leaks, the shell escapes — are not a grab-bag of unrelated bugs. They are
instances of a small number of recurring root causes. This chapter formalizes the
boundary, then works through those root causes as a taxonomy, using the real
vulnerabilities as concrete specimens of each class.

## 1. From mechanism to judgment

A recurring theme has been that `sudo` is **privileged from its first
instruction** (Chapter 01): the setuid bit elevates `euid` to 0 before any of
`sudo`'s own code runs. This is the single fact that makes `sudo` dangerous. In an
ordinary program, a parsing bug is a crash; in `sudo`, the same parsing bug
executes with root's authority, because the parser is *already* root. Every
security consideration in this chapter descends from that architectural reality:
`sudo` is a large body of C code that processes attacker-controlled input while
holding the highest privilege on the system.

Judged against that reality, the question is not "is `sudo` bug-free" — no program
of its size and privilege is — but "does its architecture minimize the input that
reaches privileged code, validate early, and fail closed." The taxonomy below is
really a scorecard for how well each part of the design meets that bar, and where
it has historically failed.

## 2. The trust boundary, formalized

Recall the two sides from Chapter 02, now stated precisely.

**The untrusted side** — everything the invoking user controls, all of which
enters the `sudo` process:

- the **command-line arguments** (`argv`) — including the command and its
  parameters;
- the **environment** (`envp`) — hundreds of caller-set variables (Chapter 07);
- the **current working directory**, the **umask**, **resource limits**
  (`rlimits`), and **file descriptors** inherited across `execve`;
- the **controlling terminal** and its state;
- for `sudoedit`, the user-controlled **editor** selection.

**The trusted side** — everything the administrator controls, which carries
`sudo`'s authority:

- the **policy** (`/etc/sudoers`, `sudoers.d`);
- the **PAM configuration** and modules (Chapter 06);
- the **plugins** and `sudo.conf` (Chapter 05);
- the **target credentials** the transition installs (Chapter 08);
- the **audit sinks** (Chapter 09).

`sudo`'s correctness is a single invariant: **untrusted input must never corrupt,
bypass, or leak into privileged execution.** Stated formally, if we call the
untrusted input `U` and the privileged execution `P`, every `sudo` vulnerability
is a case where `U` influenced `P` in a way the policy did not authorize — whether
by corrupting `P`'s memory, by tricking `P`'s logic, by contaminating `P`'s
environment, or by exploiting a grant that let `U` reach `P` legitimately but
dangerously. The taxonomy is simply an enumeration of *how* `U` reaches `P`.

## 3. A taxonomy of root causes

Five recurring classes account for essentially every `sudo` security failure the
series has touched:

- **Class A — Memory-unsafe handling of untrusted input.** `U` corrupts `P`'s
  memory. Specimen: `CVE-2021-3156` (Baron Samedit).
- **Class B — Logic errors in policy interpretation.** `U` tricks `P` into a
  decision the policy did not intend. Specimens: `CVE-2019-14287` (runas `-1`),
  `CVE-2023-22809` (`sudoedit` editor injection).
- **Class C — Environment leakage.** `U` contaminates `P`'s execution context.
  Specimen: the entire `LD_*`/`PATH`/`HOME` class of Chapter 07.
- **Class D — Legitimate-but-dangerous grants.** `U` reaches `P` through a grant
  that policy *did* authorize but should not have. Specimen: shell escapes from
  editors/pagers/interpreters (Chapter 04). *This is a policy failure, not a
  `sudo` bug.*
- **Class E — Confused deputy over shared resources.** `U` abuses a resource `P`
  shares with the unprivileged session. Specimen: terminal injection via `TIOCSTI`,
  mitigated by `use_pty`.

We take each in turn.

## 4. Class A — untrusted input reaching privileged code

The most severe `sudo` vulnerabilities are memory-safety bugs in the code that
parses attacker input, because that code runs as root. The canonical example is
**`CVE-2021-3156`**, disclosed in 2021 and nicknamed **Baron Samedit** — a pun on
`sudoedit`.

The bug lived in `sudo`'s argument processing. When `sudo` builds the command from
`argv`, it un-escapes backslash-escaped characters into a heap buffer. Under
`sudoedit` (and shell modes), a flaw in that un-escaping loop meant that an
argument ending in a single, unescaped backslash caused the loop to read and write
**past the end of the buffer** — a classic heap buffer overflow, with
attacker-controlled contents.

Three properties made it devastating, and each maps to a theme of this series:

- **It was reachable before authentication.** The vulnerable parsing runs in
  Stage 1 (Chapter 03), *before* the policy check and *before* the password
  prompt. An attacker did not need to authenticate to reach it.
- **It required no `sudoers` entry.** *Any* local user could trigger it, even one
  with no `sudo` privileges at all — because the parsing happens before the policy
  plugin decides whether the user is allowed anything.
- **It ran as root.** By Chapter 01's architecture, the parser is already `euid 0`,
  so corrupting its heap yielded root code execution.

It affected a decade of `sudo` releases (1.8.2 through 1.9.5p1) and was fixed in
1.9.5p2. The root-cause lesson is exactly the one Chapter 01 foreshadowed:
**because `sudo` is privileged-first, every line of code that touches untrusted
input before the policy gate is root-critical.** The defense is architectural —
minimize such code, write it memory-safely, validate lengths, and treat the
pre-authentication parser with the paranoia due to something that is simultaneously
the most exposed and the most privileged part of the program.

## 5. Class B — logic errors in policy interpretation

The second class is subtler: the memory is safe, but `sudo`'s *logic* reaches a
decision the administrator did not intend. Two specimens.

**`CVE-2019-14287` — the runas `-1` bypass** (Chapter 04 §5). A rule of the form
`user ALL=(ALL, !root) cmd` intends "any target except root." But `sudo -u '#-1'`
(or `#4294967295`) was mishandled: the runas UID `-1`/`4294967295` resolved to
`0`, i.e. root — the exact target the `!root` negation forbade. No memory was
corrupted; the *parsing of a UID string* combined with a *blacklist* (`!root`) to
produce an authorization the policy author explicitly tried to deny. Root cause: a
logic/parsing error at the boundary where user-supplied identifiers meet a
negation-based policy. Fixed in 1.8.28.

**`CVE-2023-22809` — `sudoedit` editor injection.** `sudoedit` lets a user edit a
file as root by running *their own* editor as *themselves* (Chapter 04 §11), with
the editor chosen from the user-controlled `EDITOR`/`VISUAL`/`SUDO_EDITOR`
environment variables. A flaw in how `sudo` combined that user-controlled editor
string with the list of files to edit allowed an attacker to inject an extra `--`
and additional file arguments into the command line — so a user permitted to
`sudoedit` *one specific file* could edit *arbitrary* files as root. This is Class
B sitting exactly on the seam between Chapter 07 (a user-controlled environment
variable) and Chapter 04 (policy that meant to restrict which file). Affected
1.8.0–1.9.12p1, fixed 1.9.12p2.

The unifying root cause of Class B: **wherever `sudo` parses a user-supplied
identifier, path, or string and folds it into a policy decision, an error in that
folding is an authorization bypass.** Two design mitigations recur — prefer
**whitelists over blacklists** (naming allowed runas targets defeats the `-1`
trick), and treat every user-controlled string that participates in a decision as
adversarial (the editor variable should never have been able to extend the file
list).

## 6. Class C — environment leakage

Chapter 07 was, in effect, a full treatment of one root-cause class, so it needs
only to be located in the taxonomy here. Environment leakage is `U` contaminating
`P`'s execution context: `LD_PRELOAD`/`LD_LIBRARY_PATH` injecting code into the
loader, `PATH` hijacking command resolution, `HOME` redirecting which config files
root trusts, interpreter path variables poisoning a scripted command.

Its defining subtlety — the one that elevates it above "just strip some variables"
— is the `AT_SECURE` fact from Chapter 07 §3: the kernel/loader secure-execution
mode protects `sudo` itself but **not** the command `sudo` runs, because the target
is `execve`d as an ordinary binary after the credential transition. So userspace
sanitization (`env_reset` + `secure_path`) is the *only* defense for the target,
and any loosening (`env_keep` additions, `SETENV`, `env_reset` off) re-opens the
class. The root cause is the same shape as the others: untrusted input (the
environment) influencing privileged execution (the command's runtime) unless
`sudo` actively severs the channel.

## 7. Class D — legitimate-but-dangerous grants

Class D is categorically different from A, B, and C, and the difference is the most
important conceptual point in the chapter: **these are not `sudo` bugs.** `sudo`
works exactly as designed; the *policy* authorized something dangerous.

The specimen is the shell escape (Chapter 04 §11). A rule `parsa ALL = /usr/bin/vim`
is faithfully honored: `sudo` checks the policy (allowed), authenticates, sanitizes
the environment, transitions credentials correctly (Chapter 08 does its job
perfectly), and `execve`s `vim` as root. Then the user types `:!/bin/bash` and has
a root shell. Every mechanism functioned; the trust boundary was not breached by
`U` — it was *opened by the administrator* who granted a program with a shell
escape.

This is why Chapter 04 insisted that a rule authorizes a *capability*, not an
*intention*. The catalog of tools with escapes (editors, pagers, `find`, `tar`,
`awk`, `env`, interpreters, and many more) is large and public. Class D failures
cannot be fixed in `sudo`'s code because there is no bug in `sudo`'s code; they are
fixed in *policy*:

- grant specific commands with specific arguments, never bare interpreters or
  editors;
- use **`sudoedit`** instead of granting a root editor;
- apply **`NOEXEC`** to blunt (not eliminate) escapes where a broader grant is
  unavoidable;
- prefer least-privilege targets (`-u` a service account rather than root) so an
  escape yields a lesser identity.

Class D is the reason the logging of Chapter 09 matters even when `sudo` is
flawless: the event log shows the *authorized* editor invocation, and only I/O
logging reveals the shell escape *inside* it. The mechanism is correct; the
vigilance must be at the policy layer.

## 8. Class E — the confused deputy over shared resources

The last class exploits a resource `sudo`'s command shares with the unprivileged
session — most notably the **terminal**. Historically, a command run by `sudo`
inherited the invoking user's controlling tty. A hostile program running under
`sudo` could use the **`TIOCSTI`** ioctl to push characters into that terminal's
input queue *as if typed*. After `sudo` exited, those injected characters would be
read by the user's shell — and executed with the user's identity, or used to drive
a follow-on `sudo`. It is a confused-deputy attack: the shared terminal is a
channel between the privileged command and the unprivileged session that should
not exist.

The mitigation, now **default in modern `sudo`**, is **`use_pty`**: the command is
run on its own pseudo-terminal (the pty+monitor model of Chapter 03), so it never
has a handle on the real terminal and cannot inject into it. `sudo` enabling
`use_pty` by default — together with kernel-level restrictions on `TIOCSTI` — closes
the class. The root-cause lesson generalizes beyond the tty: **a privileged
process must not share mutable resources with the unprivileged session that
launched it**, whether that resource is a terminal, an inherited file descriptor,
or a signal-delivery relationship. Isolation (a fresh pty, closing inherited fds
via `closefrom`) is the structural fix.

## 9. Why `sudo` is inherently high-risk

Stepping fully back: `sudo` concentrates several risk factors that would each,
alone, demand caution, and it combines them.

- It is **setuid-root**, so it runs privileged for every invocation by design.
- It is **large** — tens of thousands of lines of C — so its attack surface is
  broad and its parsing is non-trivial.
- It is **written in a memory-unsafe language**, so Class A bugs are always
  possible.
- It processes **richly structured untrusted input** (arguments, environment,
  policy files, editor selections) **before** and **during** privileged operation.
- It is **ubiquitous**, so any bug is universally exploitable and highly valued.

None of this means `sudo` is unsafe to use — the alternatives (Chapter 02) are
worse, and its architecture (privilege-first but policy-gated, whitelisting
environments, permanent credential drops) reflects hard-won lessons. But it does
mean the honest security posture is *defense in depth around* `sudo`, not faith in
its perfection: restrict who may run it at all, keep it patched (Class A bugs are
found periodically and are always critical), write tight policy (Class D), keep
environment sanitization strict (Class C), and log off-host (Chapter 09) so that
even a successful exploit leaves evidence.

## 10. Defensive principles derived from the classes

The taxonomy yields a compact set of principles, each earned by a class:

- **Minimize privileged code touching untrusted input** (Class A). The
  pre-authentication parser is the highest-risk code in the program; it must be
  small, length-checked, and ideally memory-safe. Keep `sudo` patched.
- **Whitelist, never blacklist** (Classes B and C). Name allowed runas targets,
  allowed commands, allowed environment variables. `(ALL, !root)` and "grant `ALL`
  then deny a few" both fail because blacklists have holes; `env_reset` succeeds
  because it whitelists.
- **Grant capabilities, not conveniences** (Class D). Every rule authorizes the
  *most* its command can do. No interpreters, no editors (use `sudoedit`), specific
  arguments, least-privilege targets.
- **Isolate the privileged command** (Class E). Own pty (`use_pty`), closed
  inherited descriptors (`closefrom`), no shared mutable resources with the caller.
- **Fail closed** (all classes). Default-deny in policy, refuse on parse error
  (`visudo`), reject unsafe `sudo.conf`, abort on failed credential change
  (Chapter 08's checked return values).
- **Assume breach; keep evidence** (Chapter 09). Off-host, tamper-resistant logging
  so that even a successful Class A/B/D exploit is recorded where the attacker
  cannot erase it.

These are not `sudo`-specific truisms; they are the general principles of building
a trust boundary, specialized to the one `sudo` implements. Read backwards, they
also explain the design decisions of every prior chapter: `env_reset` is
"whitelist"; `setresuid` is "fail closed / no residual privilege"; `sudoedit` is
"grant capability not convenience"; `use_pty` is "isolate"; `sudo_logsrvd` is "keep
evidence."

## 11. What this chapter established

- `sudo`'s security reduces to **one invariant**: untrusted input (`U` — arguments,
  environment, cwd, fds, terminal, editor selection) must never corrupt, bypass, or
  leak into privileged execution (`P`). Every vulnerability is a violation of it.
- Failures fall into **five recurring root-cause classes**:
  - **A — memory-unsafe handling of untrusted input**: `CVE-2021-3156` (Baron
    Samedit), a heap overflow in argument un-escaping, reachable **before
    authentication**, by **any local user**, running as **root** — the direct
    consequence of `sudo`'s privilege-first architecture.
  - **B — logic errors in policy interpretation**: `CVE-2019-14287` (runas `-1`
    defeating `!root`) and `CVE-2023-22809` (`sudoedit` editor-variable injection
    extending the file list) — bypasses where user-supplied strings fold wrongly
    into a decision.
  - **C — environment leakage**: the Chapter 07 class, defined by `AT_SECURE`
    *not* protecting the target, making userspace `env_reset`/`secure_path` the
    only defense.
  - **D — legitimate-but-dangerous grants**: shell escapes — **not `sudo` bugs**
    but policy failures; the mechanism works perfectly and the administrator opened
    the boundary. Fixed in policy (specific commands, `sudoedit`, `NOEXEC`,
    least-privilege targets), not code.
  - **E — confused deputy over shared resources**: terminal injection via
    `TIOCSTI`, closed by the now-default **`use_pty`** isolating the command on its
    own pseudo-terminal.
- `sudo` is **inherently high-risk** — setuid-root, large, memory-unsafe,
  parsing rich untrusted input while privileged, and ubiquitous — so the correct
  posture is **defense in depth around it**, not trust in its perfection.
- The classes yield concrete **defensive principles** — minimize privileged code on
  untrusted input, whitelist over blacklist, grant capabilities not conveniences,
  isolate the command, fail closed, keep off-host evidence — which are exactly the
  design rationales behind `env_reset`, `setresuid`, `sudoedit`, `use_pty`, and
  `sudo_logsrvd` from earlier chapters.

The next chapter makes Class D concrete and operational. *Common Misconfigurations*
catalogs the specific `sudoers` patterns that silently over-grant — bare
interpreters, permissive wildcards, `NOPASSWD` on the wrong commands, negation
traps, writable targets — analyzing each by *which invariant it breaks* and how to
write the rule correctly instead.
