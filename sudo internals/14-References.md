# 14 — References

The README set a single discipline for this series: **the source is the source
of truth**, and if any claim here disagrees with it, the source wins. That
promise is only meaningful if the sources are named precisely enough to check.
This chapter is that list — not a bibliography for completeness, but the working
set of primary documents against which every claim in the preceding thirteen
chapters can be verified.

It is organized by the kind of authority each source carries: the `sudo` source
and its own manuals; the kernel documentation for the credential and capability
model; the PAM specification; and the security advisories for the CVEs used
throughout as concrete specimens of the vulnerability classes. Where a chapter
leaned on a particular document, it is noted, so a reader can go from a claim
back to its ground.

## 1. On using these sources

Two notes on method before the list.

- **Prefer the manual and the source over secondary explanation.** Blog posts
  and answers age; behavior is version-sensitive (Chapter 08's ordering,
  Chapter 09's 1.9-era `sudo_logsrvd`, Chapter 07's `AT_SECURE` interaction all
  depend on specific versions). When a secondary source and a man page
  disagree, the man page for *your installed version* wins — and the source
  tree wins over the man page.
- **Read man pages for the version you run.** `sudo --version` (or `sudo -V`,
  Chapter 12 §2) tells you which one. The behavior documented in
  `sudoers(5)` for 1.9.x is not identical to older releases; the series
  assumed a recent 1.9.x throughout, and a reader on an older `sudo` should
  read the matching manual.

## 2. The sudo source tree and manuals

The authoritative reference for everything `sudo` does. The manuals ship with
the package (`man sudo`, etc.) and are maintained alongside the code.

- **`sudo(8)`** — the front-end: command-line interface, options, and the
  overall invocation model. Grounds Chapters 01, 03, and the `sudo -l`/`-v`/`-V`
  usage throughout.
- **`sudoers(5)`** — the policy language: aliases, rule syntax, `Defaults`,
  matching and evaluation order, tags (`NOPASSWD`, `NOEXEC`, `LOG_*`,
  `SETENV`), and the environment (`env_reset`, `env_keep`, `secure_path`).
  The primary reference for Chapters 04, 07, 09, and 11.
- **`sudo_plugin(5)`** — the plugin API: the policy, I/O, audit, and
  approval plugin interfaces, the `open`/`check_policy`/`list` entry points,
  and the settings/user-info/command-info vectors. Grounds Chapter 05.
- **`sudoreplay(8)`** — listing and replaying I/O-logged sessions. Chapters
  09 and 12 §8.
- **`visudo(8)`** — the safe policy editor: syntax checking (`-c`) and the
  fail-closed edit workflow. Chapters 04, 11, 13.
- **`sudoedit`** (documented within `sudo(8)`) — editing privileged files
  without granting an editor; the correct answer to the shell-escape class.
  Chapters 10, 11, 13.
- **`sudo.conf(5)`** — the front-end configuration file: `Plugin` lines and,
  central to Chapter 12, the `Debug` directive (`<program> <logfile>
  <subsystem@priority>`). Chapters 03, 05, 12.
- **`sudo_logsrvd(8)`** and **`sudo_logsrv.proto`** — the remote log server and
  its protocol, the basis for off-host, tamper-resistant logging. Chapter 09
  §10.
- **The source tree itself** — `plugins/sudoers/` (policy, matching,
  environment, and I/O logging), `src/` (the front-end, exec, and pty/monitor
  logic), and `lib/util/` (including the debug subsystem). Cited by
  `file:line` in Chapter 12's trace reading, and the final authority behind
  every mechanism claim.

## 3. The Linux credential and capability model

The kernel documentation that grounds Chapter 08's privilege transition and
Chapter 01's credential notation. `sudo` reshapes credentials; these documents
define what those credentials *are* and how the syscalls behave.

- **`credentials(7)`** — the process credential model: real, effective, and
  saved user and group IDs (the `(ruid, euid, suid)` triplet the series uses),
  supplementary groups, and the rules governing transitions between them.
  The foundation of Chapters 01 and 08.
- **`capabilities(7)`** — the POSIX capability model referenced when
  contrasting `sudo`'s all-or-nothing root transition with finer-grained
  privilege. Chapters 01, 02.
- **`setresuid(2)`, `setresgid(2)`, `setgroups(2)`, `seteuid(2)`,
  `execve(2)`** — the exact syscalls of the credential transition, and the
  ones filtered for in the series' `strace` invocations. Their semantics —
  especially the group-before-user ordering and the checked return values —
  are the technical core of Chapter 08.
- **`execve(2)`** additionally — for the `AT_SECURE` flag and what the kernel
  does (and, crucially, does *not*) do for a setuid execution, the linchpin of
  Chapter 07's argument that userspace sanitization is the only defense for the
  target command.
- **`ptrace(2)`** — for the restriction on tracing setuid binaries that
  Chapter 12 §6 flagged as the reason `strace`-ing `sudo` requires privilege.

## 4. PAM — Pluggable Authentication Modules

The specification and manuals behind Chapter 06. `sudo` delegates identity
verification entirely to PAM; these define what it delegates to.

- **The Linux-PAM documentation** (the System Administrators' Guide and Module
  Writers' Guide) — the `auth`, `account`, `session`, and `password` stacks;
  control flags (`required`, `sufficient`, `requisite`, `optional`); and the
  conversation mechanism `sudo` uses to prompt for a password. Chapter 06.
- **`pam.conf(5)` / `pam.d`** — the configuration format, and specifically
  `/etc/pam.d/sudo`, the file whose contents *are* `sudo`'s authentication
  strength (Chapter 06 §13, Chapter 13 §4). The `debug` module option used in
  Chapter 12 §7 is documented here and in the individual module pages.
- **`pam_unix(8)`**, **`pam_deny(8)`**, and related module manuals — the
  specific modules whose behavior Chapter 06 traced, including the
  fall-through-to-`pam_deny` pattern whose removal turns a failed check into a
  success.
- **`crypt(3)`** — the password-hashing interface underlying `pam_unix`'s
  verification, referenced in Chapter 06's account of what actually checks a
  secret.

## 5. Security advisories — the CVE specimens

Chapter 10 was explicit that CVEs are cited as **concrete instances of a
class**, not collected for their own sake. Each below is the specimen for a
root-cause class; the advisory and the corresponding sudo security page are the
primary sources for the mechanism, not the summary in secondary press.

- **`CVE-2021-3156` ("Baron Samedit")** — Class A, memory-unsafe handling of
  untrusted input: a heap buffer overflow in `sudo`'s command-line argument
  un-escaping, reachable *before authentication* by *any local user*, executing
  as *root*. The canonical demonstration that `sudo`'s privilege-first
  architecture turns a parsing bug into a root exploit. Chapters 01, 10.
- **`CVE-2019-14287`** — Class B, logic error in policy interpretation: a runas
  specification of `-u '#-1'` (or `#4294967295`) parsed to UID `0`, letting a
  user explicitly forbidden root (`(ALL, !root)`) run as root anyway. The
  specimen for why runas must be whitelisted, never blacklisted. Chapters 10,
  11, 13.
- **`CVE-2023-22809`** — Class B, logic error via `sudoedit`: attacker-supplied
  editor environment variables could extend the list of files edited with
  privilege beyond those the policy authorized. Chapter 10.

For each, the primary sources are the official **sudo security advisories**
(published on the sudo project's website alongside the fix), the **CVE/NVD**
record, and the **patch commit** in the source tree — which, per the series'
discipline, shows the actual defective code and its correction rather than a
narrative of it.

## 6. Supporting references

Documents cited in passing that ground specific mechanisms.

- **`fnmatch(3)`** — the pattern-matching function behind `sudoers` wildcards,
  relevant to Chapter 04's matching semantics and Chapter 11 §5's warning that
  a `*` is an implicit "any value" whitelist.
- **`environ(7)`** — the process environment model underlying Chapter 07.
- **`ld.so(8)`** — the dynamic loader, and its own handling of `LD_*`
  variables under `AT_SECURE`, which Chapter 07 contrasted with the target
  command's lack of equivalent protection.
- **`ptmx(4)` / `pty(7)`** — the pseudo-terminal mechanism behind the
  pty/monitor execution model (Chapter 03 §7), I/O logging capture (Chapter 09
  §6), and the `use_pty` terminal-injection defense (Chapter 10 §10).
- **`syslog(3)` / `journald`** and **`auditd`(8) / `ausearch`(8) /
  `aureport`(8)** — the logging sinks and the independent kernel audit view
  that Chapter 09 §4, §11 relied on for the event trail and its corroboration.

## 7. How to verify a claim in this series

Concretely, the path from any assertion here back to ground:

1. **A policy-language claim** (a rule matches, a `Defaults` behaves a certain
   way) → `sudoers(5)` for your version, then `sudo -l -U <user>` to see the
   *resolved* reality (Chapters 04 §12, 12 §5), then the `sudoers` matching
   source if they disagree.
2. **A credential-transition claim** (which UID/GID is set, in what order) →
   `credentials(7)` and the `setres*(2)` man pages for semantics, then
   `strace -f -e trace=setresuid,setresgid,setgroups,execve` to observe it
   (Chapters 01, 08).
3. **An environment claim** (what is preserved or stripped) → `sudoers(5)` on
   `env_reset`/`env_keep`/`secure_path`, `sudo -V` for the active env policy,
   and `execve(2)`/`ld.so(8)` on `AT_SECURE` (Chapter 07).
4. **An authentication claim** (what proves identity, what gate failed) →
   `/etc/pam.d/sudo`, the relevant `pam_*` manuals, and the `authpriv` log or
   `pam_unix.so debug` (Chapters 06, 12 §7).
5. **A logging claim** (what is recorded, where, how tamper-resistant) →
   `sudoers(5)` logging `Defaults`, `sudoreplay(8)`, `sudo_logsrvd(8)`, and the
   `authpriv`/journal/`auditd` sinks (Chapter 09).
6. **A vulnerability claim** (a class, a specimen, a root cause) → the sudo
   security advisory, the CVE record, and the patch commit for that CVE
   (Chapters 10, 11).

That path — assertion, to manual, to observation, to source — is the entire
method of the series compressed into a procedure. It is what "the source wins"
means in practice.

## 8. Closing note

This series set out to treat `sudo` as an object of study rather than a tool of
convenience: to trace the exact route from a `setuid` bit on disk to a reshaped
credential set in the kernel, and to explain *why* `sudo` is built the way it is
and *where* that design meets its limits. The references above are not an
appendix to that account but its foundation — every mechanism described, every
transition observed, and every vulnerability class named is checkable against
one of them.

If a claim in these fourteen chapters is ever contradicted by the source it
cites, the source is right and the chapter is wrong. That is not a disclaimer;
it is the standard the series was written to be held to.
