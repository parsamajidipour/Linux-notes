# Linux Capabilities

> **A comprehensive guide to understanding one of the most important security mechanisms in modern Linux.**

Most people learn Linux security through a simple idea:

* You are **root**.
* Or you are **not**.

While this explanation is useful for beginners, it no longer reflects how modern Linux actually manages privileges.

Since **Linux 2.2**, the kernel has gradually moved away from the traditional all-or-nothing root model by introducing **Linux Capabilities**—a fine-grained privilege system that divides the enormous power of the superuser into dozens of independent permissions.

Today, this mechanism forms the foundation of privilege management across the Linux ecosystem.

It is used by:

* Docker
* Kubernetes
* systemd
* Podman
* LXC/LXD
* Cloud Platforms
* OCI Runtimes
* Modern Linux Services

Whether you're deploying production servers, building container platforms, auditing Linux systems, or researching privilege escalation, understanding Linux Capabilities is no longer optional.

It is essential.

---

## What You'll Learn

This repository explains Linux Capabilities from the ground up.

It begins with the security problems that existed in the traditional UNIX privilege model before gradually moving toward the internal implementation inside the Linux kernel.

Throughout this guide you'll learn:

* Why Linux Capabilities were introduced
* How Linux represents process credentials
* How the kernel performs capability checks
* The purpose of every capability set
* How `execve()` recalculates privileges
* How file capabilities work
* The role of Bounding and Ambient capabilities
* Capability management inside Docker and Kubernetes
* Capability-related privilege escalation techniques
* Capability auditing and troubleshooting
* Security best practices for production environments

The goal is not to memorize commands.

The goal is to understand **how privilege actually works inside Linux**.

---

## Repository Structure

```text
linux-capabilities/

README.md

01-Introduction.md

02-Why-Capabilities-Exist.md

03-How-Linux-Capabilities-Work.md

04-Capability-Types.md

05-Real-World-Usage.md

06-Security-Perspective.md

07-Troubleshooting-and-Best-Practices.md

08-References.md
```

---

## Who Is This Guide For?

This guide is written for:

* Linux Engineers
* System Administrators
* DevOps Engineers
* Platform Engineers
* Cloud Engineers
* Security Researchers
* Penetration Testers
* Bug Bounty Hunters
* Students interested in Linux Internals

No previous knowledge of Linux Capabilities is required.

However, familiarity with basic Linux concepts such as users, groups, permissions, and processes will make the material easier to follow.

---

## Learning Philosophy

This repository intentionally avoids becoming a simple command reference.

Instead of focusing on *how to type commands*, it focuses on *why Linux behaves the way it does*.

Understanding the design decisions behind Linux Capabilities makes it significantly easier to reason about:

* Containers
* Namespaces
* systemd
* Process Credentials
* `execve()`
* Kernel Authorization
* Linux Security

The concepts presented here remain valuable regardless of Linux distribution or userspace tooling.

---

## References

Every chapter is based on authoritative sources, including:

* Linux Kernel Documentation
* Linux Kernel Source Code
* Linux man-pages Project
* libcap
* LWN.net
* The Linux Programming Interface
* Linux Kernel Development
* Container Security documentation

Where implementation details matter, the Linux kernel itself should always be considered the ultimate source of truth.

---

## License

This project is intended to be an educational resource for the Linux community.

Contributions, corrections, and technical discussions are always welcome.
