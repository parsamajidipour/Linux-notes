# Sudo Internals

A rigorous, systems-level examination of how `sudo` actually works — from the
`setuid` bit on disk to the syscalls that reshape a process credential set in
the kernel.

This is not a usage guide. It does not explain how to add a line to
`/etc/sudoers` and move on. It is a study of the mechanism: the privilege model
`sudo` relies on, the plugin and policy architecture it is built from, the way
it negotiates with PAM, how it constructs a sanitized environment, and the exact
kernel-level transition that turns an unprivileged invocation into a privileged
one. Every claim here is meant to be verifiable — against source, against
`strace`, against the kernel's own documentation.

## Scope and intent

The goal of this series is to treat `sudo` as an object of study rather than a
tool of convenience. Most documentation answers the question *"how do I use
sudo?"*. This series answers a different set of questions:

- What problem does `sudo` solve that `su`, `setuid` binaries, and raw
  capabilities do not?
- What is the precise sequence of events between typing `sudo command` and
  that command running with elevated privilege?
- Where does the trust boundary sit, and what mechanisms enforce it?
- Why is `sudo` a recurring source of local privilege-escalation
  vulnerabilities, and what class of bug produces them?

The intended reader already knows Linux at the level of processes, file
permissions, and the shell. Familiarity with the Unix credential model
(real/effective/saved UIDs, supplementary groups) and with reading `strace`
output is assumed but reinforced where it matters.

## Method and conventions

The series follows a consistent discipline so that each note is reproducible and
falsifiable rather than anecdotal.

- **Source of truth.** Behavior is grounded in the sudo source tree, the
  relevant man pages (`sudo(8)`, `sudoers(5)`, `sudo_plugin(5)`), the Linux
  `credentials(7)` and `capabilities(7)` documentation, and the PAM
  specification — not in folklore.
- **Observation over assertion.** Where a claim can be demonstrated, it is
  demonstrated: with `strace`, `id`, `ps`, `getpcaps`, PAM debug output, or the
  `sudo` I/O and debug logs. Commands are shown exactly as run.
- **Credential notation.** The Unix credential triplet is written as
  `(ruid, euid, suid)` for user IDs and `(rgid, egid, sgid)` for group IDs.
  Transitions are shown explicitly, e.g. `(1000, 1000, 1000) → (1000, 0, 0)`.
- **Environment.** Unless stated otherwise, examples assume a modern Linux
  distribution with a recent `sudo` (1.9.x), `sudoers` as the active policy
  plugin, and PAM as the authentication backend. Version-sensitive behavior is
  flagged where it diverges.
- **Security framing.** Vulnerabilities are discussed by root cause — the flaw
  in the mechanism — not as a list of CVE numbers. CVEs are cited as concrete
  instances of a class (for example, `CVE-2021-3156` as a heap overflow in
  argument parsing, `CVE-2019-14287` as a UID-parsing logic flaw).

## Structure

Each chapter is a standalone note, but the series is ordered so that later
chapters build on the mechanism established earlier. The technical core is
Chapter 08 — the actual privilege transition — and the surrounding chapters
either lead up to it or examine its consequences.

| #  | Chapter                          | What it establishes                                                                 |
| -- | -------------------------------- | ----------------------------------------------------------------------------------- |
| 01 | Introduction                     | The problem space, terminology, and the questions the series answers.               |
| 02 | Why Sudo Exists                  | The gap between `su`, raw `setuid`, and capabilities that `sudo` fills.              |
| 03 | How Sudo Works                   | End-to-end control flow of a single invocation, at a high level.                    |
| 04 | The sudoers File                 | The policy language: aliases, rule matching, defaults, and evaluation order.        |
| 05 | Policy and Plugin Architecture   | The plugin API that separates policy, I/O logging, and the front-end.               |
| 06 | Authentication with PAM          | How `sudo` delegates identity verification and what the PAM stack actually decides. |
| 07 | Environment Handling             | Environment sanitization, `secure_path`, and why the environment is a threat.       |
| 08 | Privilege Transition             | The syscall-level credential change: `setresuid`, group handling, ordering.         |
| 09 | Logging and Auditing             | The audit trail: `sudoers` logging, I/O capture, syslog, and journald.              |
| 10 | Security Considerations          | Trust boundaries and the vulnerability classes that recur, with real cases.         |
| 11 | Common Misconfigurations         | Rules that silently grant more than intended, analyzed by why they fail.            |
| 12 | Debugging Sudo                   | The debug subsystem, `sudoreplay`, and tracing an invocation to ground truth.       |
| 13 | Best Practices                   | Hardening derived from the mechanism, not from checklists.                          |
| 14 | References                       | Primary sources: source, man pages, kernel docs, and advisories.                    |

## How to read this series

Read Chapters 01–03 in order to establish vocabulary and the overall control
flow. From there the chapters can be read independently, but anyone interested
in the security-critical core should treat **04 → 05 → 06 → 07 → 08** as a
single arc: policy decision, plugin dispatch, authentication, environment
construction, and finally the credential transition itself. Chapters 09–13 are
the operational and adversarial consequences of that arc.

## Status

**Work in progress.** Chapters are written and revised in order of dependency,
not necessarily in numeric order. Corrections that improve precision are the
whole point of this format — if a claim here disagrees with the source, the
source wins.
