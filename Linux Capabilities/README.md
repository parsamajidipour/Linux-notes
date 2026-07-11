# Linux Capabilities

> **A comprehensive guide to understanding one of the most important security mechanisms in modern Linux.**

Most people learn Linux security through a single idea:

- You are **root**.
- Or you are **not**.

While that explanation is useful for beginners, it no longer reflects how modern Linux actually manages privilege.

Since **Linux 2.2**, the kernel has moved away from the all-or-nothing root model by introducing **Linux Capabilities** — a fine-grained privilege system that divides the enormous power of the superuser into dozens of independent permissions.

Today this mechanism underpins privilege management across the Linux ecosystem. It is used by:

- Docker
- Kubernetes
- systemd
- Podman
- LXC/LXD
- Cloud platforms
- OCI runtimes
- Modern Linux services

Whether you are deploying production servers, building container platforms, auditing Linux hosts, or researching privilege escalation, understanding Linux Capabilities is no longer optional — it is essential.

---

## Quick Start

See it for yourself in three commands. Your own shell's capability state:

```bash
grep '^Cap' /proc/self/status
```

A file that carries a capability instead of being SUID-root:

```bash
getcap /usr/bin/ping
# -> /usr/bin/ping cap_net_raw=ep
```

Decode any capability mask into names:

```bash
capsh --decode=000001ffffffffff
```

Those three commands cover the whole subject in miniature: capabilities live on **processes** (via `/proc`), on **files** (via `getcap`), and are represented as **bitmasks** (decoded by `capsh`). Everything in this guide expands on those three facts.

---

## The Five Capability Sets at a Glance

| Set | `/proc` name | Question it answers |
|---|---|---|
| Permitted | `CapPrm` | Which capabilities *may* the thread make effective? |
| Effective | `CapEff` | Which capabilities are active *right now*? |
| Inheritable | `CapInh` | Which capabilities survive `execve()` of a marked file? |
| Bounding | `CapBnd` | What ceiling limits capabilities gained via a file? |
| Ambient | `CapAmb` | Which capabilities survive an *ordinary* `execve()`? |

Chapter 04 explains each set in depth, along with the exact rules for how they change on `execve()`.

---

## What You'll Learn

This repository explains Linux Capabilities from the ground up — starting with the security problems in the traditional UNIX model, then moving into the kernel's internal implementation.

- Why Linux Capabilities were introduced
- How Linux represents process credentials (`struct cred`)
- How the kernel performs a capability check in practice
- The purpose of every capability set
- How `execve()` recalculates privilege
- How file capabilities are stored and evaluated
- The role of the Bounding and Ambient sets
- Capability management in Docker and Kubernetes
- Capability-based privilege-escalation techniques and defenses
- Capability auditing and troubleshooting
- Security best practices for production

The goal is not to memorize commands. It is to understand **how privilege actually works inside Linux**.

---

## Repository Structure

```text
Linux Capabilities/
├── README.md
├── 01-Introduction.md                     Two-level myth, first look, short history
├── 02-Why-Capabilities-Exist.md           The root problem, SUID, root vs capabilities
├── 03-How-Linux-Capabilities-Work.md      struct cred, bit representation, the check path
├── 04-Capability-Types.md                 The five sets and the execve() transformation
├── 05-Real-World-Usage.md                 nginx, ping, tcpdump, systemd, Docker, K8s
├── 06-Security-Perspective.md             Dangerous capabilities, escalation, defense
├── 07-Troubleshooting-and-Best-Practices.md   A method for when a capability "should" work
└── 08-References.md                       Annotated authoritative sources
```

---

## Who Is This Guide For?

- Linux and platform engineers
- System administrators
- DevOps and cloud engineers
- Security researchers and penetration testers
- Bug bounty hunters
- Students of Linux internals

No prior knowledge of capabilities is required. Familiarity with basic Linux concepts — users, groups, permissions, and processes — will make the material easier to follow.

---

## Learning Philosophy

This repository intentionally avoids being a command reference. Instead of focusing on *how to type commands*, it focuses on *why Linux behaves the way it does*.

Understanding the design decisions behind capabilities makes it far easier to reason about containers, namespaces, systemd, process credentials, `execve()`, and kernel authorization. Those concepts remain valuable regardless of distribution or userspace tooling.

---

## References

Every chapter is grounded in authoritative sources, including:

- Linux kernel documentation and source
- The Linux man-pages project (especially `man 7 capabilities`)
- libcap
- LWN.net
- *The Linux Programming Interface*
- *Container Security*

Where implementation details matter, the Linux kernel itself is always the ultimate source of truth. See `08-References.md` for the annotated list.

---

## License

This project is an educational resource for the Linux community. Contributions, corrections, and technical discussion are welcome.
