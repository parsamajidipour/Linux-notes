# Linux PAM Deep Dive

An eleven-chapter, mechanism-level reference on **PAM — Pluggable Authentication Modules** — built from first principles at the library and API level, up through the configuration model, the stack evaluation algorithm, the module ecosystem, integration with NSS and directory services, and finally hardening, debugging, and real-world recovery.

This is not a collection of configuration snippets to paste. Snippets are everywhere and they are the reason so many systems have PAM stacks nobody in the organisation can explain. The goal here is that after reading this series you can open an unfamiliar `/etc/pam.d/sshd` on an unfamiliar distribution, read it top to bottom, and state precisely what will happen when a user types a password — including which module will be consulted first, what happens on each possible return value, and where the decision is recorded.

---

## Table of Contents

- [Why This Series Exists](#why-this-series-exists)
- [The One-Page Mental Model](#the-one-page-mental-model)
- [Scope and Non-Goals](#scope-and-non-goals)
- [Prerequisites](#prerequisites)
- [How to Read This Series](#how-to-read-this-series)
- [Chapter Index](#chapter-index)
- [Core Vocabulary](#core-vocabulary)
- [Files and Directories This Series Touches](#files-and-directories-this-series-touches)
- [Distribution Differences](#distribution-differences)
- [Test Environment and Safety](#test-environment-and-safety)
- [Conventions Used in These Notes](#conventions-used-in-these-notes)
- [Relationship to Other Sections in This Repository](#relationship-to-other-sections-in-this-repository)
- [Reference Material](#reference-material)
- [Status](#status)

---

## Why This Series Exists

### The problem PAM was invented to solve

Before PAM, authentication logic lived inside every program that needed it. `login` opened `/etc/passwd`, read the hashed password field, called `crypt()`, and compared strings. So did `su`. So did `ftpd`, `rlogind`, `passwd`, `xdm`, and every other privileged binary on the system. Each one carried its own copy of "how do I know who this person is."

That design had three consequences, and every one of them is still visible in the shape of PAM today.

**First, policy changes required recompilation.** When the industry moved from the traditional DES-based `crypt()` to MD5 hashes, and later to bcrypt, SHA-256, SHA-512, and yescrypt, every authenticating binary had to be rebuilt. When shadow passwords were introduced and the hash moved from `/etc/passwd` to `/etc/shadow`, the same thing happened again. A site that wanted to authenticate against a Kerberos KDC, or an LDAP directory, or a hardware token, had to obtain patched versions of every relevant program — or do without.

**Second, policy was inconsistent by construction.** There was no single place to state "accounts in this group may not log in between 22:00 and 06:00" or "lock an account after five failed attempts." Each program either implemented such a rule or it did not, and the set of programs that did was never the same as the set that mattered.

**Third, there was no separation between *authentication* and everything that surrounds it.** Verifying a credential is only one of four distinct questions a system must answer at login time. Is this account currently allowed to be used at all? Does the credential need to be changed before proceeding? What environment, limits, and resources must be set up for this session, and torn down afterwards? Monolithic programs blurred all four together.

### The answer

In 1995, Sun Microsystems published a design that decoupled *the program that needs authentication* from *the policy that decides it*, as OSF-RFC 86.0, "Unified Login with Pluggable Authentication Modules." The idea is simple to state and unusually well executed: a program should not implement authentication. It should ask a library. The library should consult a per-service, administrator-editable configuration file. That file should name a list of shared objects to load, in order, along with instructions for how to combine their answers.

Linux-PAM, the implementation used on essentially every Linux distribution, was started shortly afterwards by Andrew Morgan and follows that design closely. The result is that `sshd` on a modern system contains no password-checking logic whatsoever. It calls `pam_authenticate()`, and what happens next is entirely determined by a text file the administrator controls.

This is a genuinely elegant piece of systems design, and it is also the reason PAM is so easy to get catastrophically wrong. A configuration file that controls whether anyone can log in is a configuration file that can lock everyone out — including you, including root, including the person you will have to call at 3 AM. Roughly one chapter in ten of this series is about that reality.

---

## The One-Page Mental Model

If you retain nothing else from this README, retain this.

```
  ┌───────────────────────────────────────────────────────┐
  │  PAM-aware application:  sshd, sudo, login, su, cron  │
  │  gdm, systemd-logind, cockpit, vsftpd, screen …       │
  └────────────────────────┬──────────────────────────────┘
                           │  pam_start(), pam_authenticate(),
                           │  pam_acct_mgmt(), pam_open_session() …
                           ▼
  ┌───────────────────────────────────────────────────────┐
  │  libpam.so  —  the framework                          │
  │  • finds the service's config file                    │
  │  • loads the listed modules in order                  │
  │  • runs the stack evaluation algorithm                │
  │  • returns ONE final result to the application        │
  └────────────────────────┬──────────────────────────────┘
                           │  reads
                           ▼
  ┌───────────────────────────────────────────────────────┐
  │  /etc/pam.d/<service>   (falls back to /etc/pam.conf) │
  │                                                       │
  │  type      control      module           arguments    │
  │  auth      required     pam_unix.so      nullok       │
  │  account   required     pam_unix.so                   │
  │  password  requisite    pam_pwquality.so retry=3      │
  │  session   optional     pam_systemd.so                │
  └────────────────────────┬──────────────────────────────┘
                           │  dlopen()
                           ▼
  ┌───────────────────────────────────────────────────────┐
  │  Modules:  /lib/*/security/*.so  or  /usr/lib64/…     │
  │  pam_unix, pam_faillock, pam_pwquality, pam_limits,   │
  │  pam_access, pam_sss, pam_krb5, pam_u2f, …            │
  └───────────────────────────────────────────────────────┘
```

Four consequences follow directly from this diagram, and they are the four things people most often get wrong:

1. **The application does not decide.** If `sshd` rejects a login, `sshd` may not be the component that made the decision. Nine times out of ten the decision came from a module named in `/etc/pam.d/sshd`, and the diagnosis begins there.
2. **The configuration file is executable policy.** The lines are not settings. They are an ordered program with control flow. Order matters. A line moved by one position can invert the meaning of the stack.
3. **Modules are shared objects running inside a privileged process.** `pam_unix.so` is loaded into the address space of `sshd` running as root. A malicious or broken module is a full compromise, and file permissions on `/lib/*/security/` and on `/etc/pam.d/` are security-critical in the strongest sense.
4. **There are four independent stacks, not one.** `auth`, `account`, `password`, `session` are separate programs that happen to live in the same file. Passing the `auth` stack tells you nothing about whether the `account` stack will let you in.

---

## Scope and Non-Goals

**In scope:**

- Linux-PAM as shipped on current Debian/Ubuntu and RHEL/Fedora/Rocky/Alma family systems
- The complete configuration syntax, including the bracketed control-value syntax most guides skip
- The stack evaluation algorithm as actually implemented, not as informally described
- The module API from the module author's side, and the framework API from the application's side
- The commonly deployed module set, with the arguments that matter and the interactions between them
- Integration points: NSS, SSSD, LDAP, Kerberos, systemd-logind, MFA
- Debugging methodology and lockout recovery

**Explicitly out of scope:**

- OpenPAM (FreeBSD/macOS) beyond a short comparison in Chapter 1. The design is shared; the module set and some semantics are not.
- Building and operating a Kerberos KDC or an LDAP directory from scratch. Chapter 10 covers the PAM side of the integration and assumes the directory exists.
- SELinux and AppArmor policy authoring. `pam_selinux.so` is covered as a module; MAC policy itself belongs to a separate section of this repository.
- GUI-specific display-manager quirks beyond what is needed to explain the session stack.

---

## Prerequisites

You will get much more out of this series if the following are already comfortable. Each links to material elsewhere in this repository where it exists.

| Topic | Why it matters here | Where |
|---|---|---|
| UID/GID, `/etc/passwd`, `/etc/shadow`, `/etc/group` | Chapter 6 is largely about how `pam_unix` interacts with these | `Permissions Deep Dive`, chapters 2 and 3 |
| Password aging fields in shadow | Chapter 7 draws the line between PAM policy and shadow-utils policy | `Permissions Deep Dive` |
| `sudo` configuration and privilege transition | `sudo` is one of the four services traced end-to-end in Chapter 10 | `sudo internals` |
| SSH server configuration, `UsePAM`, `KbdInteractiveAuthentication` | The interaction between sshd's own auth methods and PAM is subtle and gets its own treatment | `SSH` |
| systemd units, `logind`, cgroups | Chapter 9 depends on understanding what a logind session actually is | `systemd` |
| syslog, journald, log facilities | Chapter 11 is unreadable without it | `Linux Logging` |
| Basic C and dynamic linking (`dlopen`, shared objects) | Only Chapter 5 requires this, and it is signposted | — |

If the C material is unfamiliar, Chapter 5 can be skipped on a first pass without breaking the sequence. Everything else assumes it and nothing else does.

---

## How to Read This Series

**Sequential (recommended).** The chapters build. Chapters 1–4 are foundational and everything later assumes them.

**By certification objective.** The series was structured so it maps cleanly onto the LPI syllabi, since that is a common reason to read it:

| Target | Chapters | Notes |
|---|---|---|
| LPIC-1 | 1, 2, 3, 4, 6, 7 | Enough to read a stack, understand the four types, and manage passwords |
| LPIC-2 | Add 8, 9, and the NSS half of 10 | Access control, resource limits, session management, directory basics |
| LPIC-3 303 Security | Add 5, the rest of 10, and 11 | Module internals, SSSD/Kerberos, MFA, hardening, audit |

**As a working reference.** Chapters 6 through 9 are organised by module and are meant to be re-opened rather than read once. Each module entry follows the same layout: what it does, which management groups it implements, its configuration files, the arguments that matter, its return values, its interactions with other modules, and its failure modes.

---

## Chapter Index

### 01 — Introduction and the PAM Problem
The pre-PAM world in concrete terms: what `login` actually did in 1990 and why that stopped working. The OSF-RFC 86.0 design and the specific problems each part of it solves. What "PAM-aware" means at the binary level — how to determine whether a program on your system uses PAM at all, using `ldd`, `objdump`, and package metadata, and why the answer is sometimes surprising (`sshd` uses it, but only for some authentication methods). Linux-PAM versus OpenPAM: the shared design and the divergences that will bite you if you move between Linux and BSD. Where `libpam.so`, `libpam_misc.so`, and the module directory live on each distribution family. The chapter closes by tracing a single successful `su` invocation at the highest level, as a map for everything that follows.

### 02 — Architecture and the Configuration Model
The three-layer architecture and where each layer's failures show up. `/etc/pam.d/` versus the legacy monolithic `/etc/pam.conf`, and the precedence rule between them. The line format: `type control module-path module-arguments`, including the leading-dash form that suppresses log noise when an optional module is not installed. The `other` service file and why its contents are one of the first things to check on an unfamiliar host. Aggregation files — `common-auth`, `common-account`, `common-password`, `common-session` on Debian; `system-auth` and `password-auth` on RHEL — and the important distinction between the two RHEL files. `@include` versus `substack` and why the difference is not cosmetic. The distribution-managed generation tools: `pam-auth-update` on Debian, `authselect` on RHEL 8+, and the rule that your hand edits will be silently overwritten if you fight them.

### 03 — The Four Management Groups
`auth`, `account`, `password`, `session` — what each one is genuinely responsible for, expressed as the question it answers. `auth`: can this principal prove identity, and what credentials should be established for it. `account`: independent of credentials, is this account permitted to be used right now — expiry, time-of-day, origin host, group membership. `password`: the mechanism for updating an authentication token, which is a separate flow with its own two-phase structure. `session`: what must be created before the service is used and destroyed afterwards. Which application call triggers which stack, and the frequently missed fact that `pam_setcred()` re-enters the `auth` stack for a different purpose than `pam_authenticate()` did. Why some services run stacks in an order that looks wrong until you know what the service is doing.

### 04 — Control Flags and Stack Evaluation
The chapter most of this series depends on. The four simple flags — `required`, `requisite`, `sufficient`, `optional` — stated precisely, including the difference between `required` and `requisite` that matters only in the presence of information leakage. `include` and `substack` as control values rather than module types, and the difference in how a jump behaves across a `substack` boundary. Then the bracketed syntax, `[value1=action1 value2=action2 ...]`, which is not an alternative notation but the real underlying mechanism: the four simple flags are defined in terms of it, and this chapter gives those definitions explicitly. The full set of return values a module may produce and the actions available — `ignore`, `bad`, `die`, `ok`, `done`, `reset`, and the numeric jump. How `libpam` accumulates a running result across the stack, and why a module late in the stack cannot always undo an earlier failure. Worked traces of real stacks, evaluated line by line, including one where moving a single line changes the security posture entirely.

### 05 — The PAM API and Module Internals
The framework from both sides. Application side: `pam_start()`, `pam_authenticate()`, `pam_acct_mgmt()`, `pam_setcred()`, `pam_chauthtok()`, `pam_open_session()`, `pam_close_session()`, `pam_end()`, and the handle that ties them together. Module side: the six `pam_sm_*` entry points and which management group each belongs to. The conversation function — the mechanism by which a module asks the *user* a question through an application that may be a terminal, an SSH channel, or a graphical greeter, using the four message styles. PAM items (`PAM_USER`, `PAM_SERVICE`, `PAM_TTY`, `PAM_RHOST`, `PAM_AUTHTOK`, …) and module data, and how `try_first_pass` and `use_authtok` are implemented on top of them. Then a small, complete, deliberately simple module written from scratch and dropped into a test stack — not because you will write modules often, but because everything in Chapters 6–9 becomes obvious once you have seen one from the inside.

### 06 — Core Authentication Modules
`pam_unix.so` in full: how it locates the hash, its interaction with `/etc/shadow` and the helper binary it uses when running unprivileged, the supported hashing algorithms and how the algorithm is encoded in the stored string, and the arguments that change its behaviour — `nullok`, `try_first_pass`, `use_first_pass`, `use_authtok`, `shadow`, `remember`, `rounds`. Then the small, sharp-edged modules: `pam_deny` and `pam_permit` as stack terminators, `pam_rootok` and why it appears at the top of `/etc/pam.d/passwd` and `chsh`, `pam_wheel` and group-restricted `su`, `pam_securetty` and its decline in modern distributions, `pam_faildelay`, `pam_listfile`, `pam_localuser`. For each: the exact return values it can produce, because Chapter 4's machinery is useless without them.

### 07 — Password Management and Quality
The `password` stack is the least understood of the four and the easiest to break. Its two-phase execution (`PAM_PRELIM_CHECK` and `PAM_UPDATE_AUTHTOK`) and why a module is called twice. `pam_pwquality` and every knob in `/etc/security/pwquality.conf`: `minlen`, `credit` parameters and how the credit system actually computes, `maxrepeat`, `maxsequence`, `dictcheck`, `usercheck`, `enforce_for_root`, `local_users_only`, `retry`. The historical `pam_cracklib` it replaced, and the fact that it has been removed from recent Linux-PAM releases, so material written against it may not apply to your system. `pam_pwhistory` and where old hashes are stored. The chained `use_authtok` idiom and what breaks when the chain is wrong. Finally, the boundary that causes the most confusion: password *aging* lives in shadow fields and is enforced in the `account` stack by `pam_unix`, while password *quality* lives in the `password` stack — two different subsystems that people routinely conflate.

### 08 — Account and Access Control Modules
Everything that answers "you are who you say you are, and you still may not proceed." `pam_access` and the syntax of `/etc/security/access.conf`, including its origin-matching rules for hosts, networks, and terminals. `pam_time` and `/etc/security/time.conf`. `pam_nologin` and the file that blocks non-root logins during maintenance. `pam_succeed_if` — powerful, widely used, and a common source of misconfiguration because of how its conditions interact with control flags. `pam_listfile` for arbitrary allow/deny lists. Then account lockout in depth: `pam_faillock`, its configuration in `/etc/security/faillock.conf`, the three-line `preauth`/`authfail`/`authsucc` idiom and exactly why all three lines are needed, where the tally is stored on disk, the `faillock` command for inspection and reset, and the denial-of-service consideration that lockout policy always carries. The legacy `pam_tally2`, now removed from current releases, is covered only far enough to let you read old configurations.

### 09 — Session Management
What actually happens between `pam_open_session()` and `pam_close_session()`. `pam_limits` and `/etc/security/limits.conf`: the hard/soft distinction, every limit type, the `limits.d` drop-in directory, and the critical modern caveat that systemd unit resource controls and cgroup limits operate independently of it — a conflict that produces "I set the limit and nothing changed" reports constantly. `pam_env` and `/etc/security/pam_env.conf` versus `/etc/environment`, and where each is read. `pam_systemd` and the creation of a logind session: what a session *is*, the scope and slice it lands in, `XDG_RUNTIME_DIR`, lingering, and what breaks when this module is absent. `pam_mkhomedir` for directory-backed users. `pam_keyinit` and the kernel keyring. `pam_namespace` for polyinstantiated directories. `pam_exec` as a general escape hatch, and the security review any use of it demands. `pam_umask`, `pam_motd`, and the state of `pam_lastlog` in current releases.

### 10 — Integration: NSS, Directories, and Real-World Flows
First, the distinction that resolves more confusion than any other in this domain: **NSS answers "who is this user and what are their attributes"; PAM answers "may this user authenticate and proceed."** They are separate subsystems with separate configuration, and a working NSS with a broken PAM (or the reverse) produces characteristic, recognisable symptoms. `/etc/nsswitch.conf`, the `passwd`, `group`, and `shadow` databases, and how `getent` lets you test one half in isolation. Then four complete traces, from process start to shell prompt, for `sshd`, `sudo`, `su`, and `login`, with the corresponding stack shown alongside. Then centralised identity: SSSD and `pam_sss`, direct LDAP, Kerberos and `pam_krb5`, and the caching behaviour that determines whether users can log in when the directory is unreachable. Finally multi-factor: `pam_google_authenticator`, `pam_u2f`, and `pam_yubico`, including the placement question — where in the stack a second factor belongs, and how it interacts with SSH public-key authentication, which bypasses much of the `auth` stack by design.

### 11 — Hardening, Debugging, and Troubleshooting
Method rather than recipes. Where PAM logs go on each distribution family, what each module writes, and how to correlate a rejection with the exact line that caused it. `pamtester` for exercising a stack without risking a real login. The `debug` argument and `pam_debug.so`. A systematic diagnostic procedure for "user cannot log in" that narrows to a single line in bounded time. Then recovery: the classic self-inflicted lockout, why keeping a second root session open is not optional while editing, and the escalating recovery ladder — other session, console, single-user mode, `rd.break`/`init=/bin/bash`, live media chroot. Then hardening: auditing an inherited stack for the specific patterns that are almost always wrong, file permissions and integrity monitoring on `/etc/pam.d/` and the module directory, `nullok` and why it should not survive into production, safe MFA rollout, and a review checklist. Finally, the small set of edits that have historically taken down production systems, so you recognise them before you make them.

---

## Core Vocabulary

These terms are used consistently and precisely throughout the series. Where the wider documentation is ambiguous, these notes pick one meaning and stay with it.

**Service** — the name PAM uses to select a configuration file, normally the name the application passed to `pam_start()`. Usually but not always the program name.

**Service file** — `/etc/pam.d/<service>`. Contains up to four stacks.

**Management group** (also *type*) — one of `auth`, `account`, `password`, `session`. The first field of a configuration line.

**Stack** — all lines in a service file sharing one management group, in file order. Evaluated as a unit.

**Control** — the second field. Either one of the four keywords, `include`, `substack`, or a bracketed list of `returnvalue=action` pairs.

**Module** — a shared object implementing one or more `pam_sm_*` functions.

**Item** — a piece of state stored on the PAM handle and readable by any module in the stack (`PAM_USER`, `PAM_RHOST`, `PAM_AUTHTOK`, …).

**Authentication token** — the credential itself, normally a password. Stored as `PAM_AUTHTOK`; the previous one as `PAM_OLDAUTHTOK`.

**Conversation** — the callback through which a module communicates with the user via the application.

**Stack result** — the single value `libpam` returns to the application after evaluating a stack. Not simply the last module's return value.

---

## Files and Directories This Series Touches

| Path | Purpose | Chapter |
|---|---|---|
| `/etc/pam.d/` | Per-service configuration | 2 |
| `/etc/pam.conf` | Legacy monolithic configuration | 2 |
| `/lib/*/security/`, `/usr/lib64/security/` | Module shared objects | 1, 2 |
| `/etc/security/pwquality.conf` | Password quality rules | 7 |
| `/etc/security/faillock.conf` | Lockout policy | 8 |
| `/etc/security/access.conf` | Origin-based access control | 8 |
| `/etc/security/time.conf` | Time-based access control | 8 |
| `/etc/security/limits.conf`, `limits.d/` | Resource limits | 9 |
| `/etc/security/pam_env.conf` | Session environment | 9 |
| `/etc/security/namespace.conf` | Polyinstantiated directories | 9 |
| `/etc/nsswitch.conf` | Name service resolution (not PAM) | 10 |
| `/etc/shadow` | Hashes and aging fields | 6, 7 |
| `/var/log/auth.log`, `/var/log/secure`, journal | Where the evidence is | 11 |

---

## Distribution Differences

The series is written against both major families. Where behaviour diverges, a note appears inline; the recurring differences are summarised here so they do not need repeating.

| | Debian / Ubuntu | RHEL / Fedora / Rocky / Alma |
|---|---|---|
| Aggregation files | `common-auth`, `common-account`, `common-password`, `common-session` | `system-auth`, `password-auth` |
| Management tool | `pam-auth-update` | `authselect` |
| Module directory | `/lib/<triplet>/security/` | `/usr/lib64/security/` |
| Auth log | `/var/log/auth.log` | `/var/log/secure` |
| Package | `libpam0g`, `libpam-modules` | `pam` |

A version note that matters more than it looks: several modules that appear throughout older documentation have been removed from recent Linux-PAM releases — `pam_tally2` and `pam_cracklib` among them, with `pam_lastlog` following. Before applying anything written more than a few years ago, check what you are actually running (`dpkg -l libpam0g` or `rpm -q pam`) and confirm the module exists on disk. A stack referencing a module that is not installed will fail in a way that depends on its control flag, which is exactly the kind of failure Chapter 4 exists to make predictable.

---

## Test Environment and Safety

> **Read this before running anything in this series.**

Every practical exercise assumes a **disposable virtual machine with a snapshot taken before you begin**. Not a container — several chapters involve `logind`, resource limits, and session creation, which behave differently or not at all in a container. Not a machine you need.

Three rules, all learned the same way:

1. **Keep a second root shell open, on a separate terminal, before editing any PAM file — and do not close it until you have verified a new login works.** A root shell that already exists is not re-authenticated. It is the difference between an inconvenience and a rebuild.
2. **Verify with a *new* session, from a *different* terminal.** The session you are in proves nothing.
3. **Back up the file you are about to edit**, in the same command, every time. `cp -a /etc/pam.d/sshd /root/sshd.bak`.

Useful tools for the exercises: `pamtester` (exercise a stack without a real login), `getent` (test NSS independently of PAM), `faillock` (inspect and reset lockout counters), `authselect`/`pam-auth-update` (distribution-managed configuration), and `ldd`/`objdump` (determine whether a binary uses PAM at all).

---

## Conventions Used in These Notes

- **Commands** are shown with the prompt indicating privilege: `$` for unprivileged, `#` for root.
- **Configuration lines** are shown exactly as they appear in the file, with the four fields aligned for readability. Real files are not always aligned; alignment is not significant.
- **`[distro]` notes** mark behaviour specific to one family.
- **`⚠` blocks** mark operations that can lock you out. They are used sparingly and mean it literally.
- **Return values** are given in full (`PAM_AUTH_ERR`, not "an error") because Chapter 4's evaluation model depends on the specific value.
- **Version-sensitive material** is flagged, with guidance on how to check your own system rather than a claim about what is current.
- Every chapter ends with a **verification section**: concrete commands that let you confirm you have understood the mechanism rather than merely read about it.

---

## Relationship to Other Sections in This Repository

PAM is the connective tissue of this repository, which is why it was written after the surrounding sections rather than before.

- **Permissions Deep Dive** establishes UID/GID and the identity model. PAM is what causes a process to *have* that identity in the first place.
- **sudo internals** covers privilege transition in depth. `sudo` consults PAM for authentication; that call is traced end-to-end in Chapter 10, and Chapter 6 explains what `pam_unix` does when it arrives.
- **SSH** covers the server and its own authentication methods. The interaction between SSH's native mechanisms and the PAM stack — particularly which parts of the stack public-key authentication skips — is a recurring theme in Chapters 10 and 11.
- **systemd** covers units, cgroups, and logind. Chapter 9's treatment of `pam_systemd` and the limits conflict assumes it.
- **Linux Logging** covers syslog and the journal. Chapter 11 is a direct application of it.
- **Linux Capabilities** covers the privilege model that PAM modules run inside; `pam_cap` appears in Chapter 9.

---

## Reference Material

Primary sources, in the order they are worth consulting:

- `man 8 pam`, `man 5 pam.conf`, `man 5 pam.d` — the authoritative syntax reference
- `man 3 pam` and the individual `pam_*` function pages — the application API
- `man 8 pam_<module>` for every module discussed — the per-module documentation is unusually good and is the correct answer to most argument questions
- The Linux-PAM System Administrators' Guide, Module Writers' Guide, and Application Developers' Guide, shipped with the source
- The Linux-PAM source tree itself, particularly the module sources, which are short and readable
- OSF-RFC 86.0, "Unified Login with Pluggable Authentication Modules" (1995) — the original design document, still the clearest statement of *why*

Where these notes and a man page disagree, the man page on your system wins, and the disagreement is worth reporting as an issue here.

---

## Status

| Chapter | Status |
|---|---|
| 01 — Introduction and the PAM Problem | planned |
| 02 — Architecture and the Configuration Model | planned |
| 03 — The Four Management Groups | planned |
| 04 — Control Flags and Stack Evaluation | planned |
| 05 — The PAM API and Module Internals | planned |
| 06 — Core Authentication Modules | planned |
| 07 — Password Management and Quality | planned |
| 08 — Account and Access Control Modules | planned |
| 09 — Session Management | planned |
| 10 — Integration: NSS, Directories, and Real-World Flows | planned |
| 11 — Hardening, Debugging, and Troubleshooting | planned |

Part of [Linux-notes](../) — a collection of notes written while exploring Linux.
