# Introduction

Most people think Linux has only two privilege levels.

Either you are **root**, or you are **not**.

For many years, this explanation was good enough. It is simple, easy to understand, and appears to match how Linux behaves from a user's perspective.

In reality, modern Linux is significantly more sophisticated.

Since Linux 2.2, the kernel no longer treats privilege as a single all-or-nothing attribute. Instead, it decomposes the enormous power traditionally associated with the root user into a collection of independent privileges known as **Linux Capabilities**.

Rather than granting unrestricted administrative access to an entire process, the kernel can grant only the specific privilege required for that process to perform its intended task.

This seemingly small design decision fundamentally changed how privilege management works across the Linux ecosystem.

Today, Linux Capabilities influence nearly every modern infrastructure platform:

- Docker
- Kubernetes
- systemd
- Podman
- LXC/LXD
- OpenShift
- Cloud-native workloads
- Container runtimes
- Security hardening
- Privilege separation

Even if you have never explicitly configured capabilities, you are almost certainly using software that depends on them.

---

## Why Does This Matter?

Consider a simple web server.

Its primary responsibility is serving HTTP requests over TCP port 80.

Historically, binding to any port below **1024** required root privileges.

This created an obvious security problem.

If the web server needed root merely to listen on port 80, it also inherited every other privilege available to the superuser.

Clearly, none of these permissions are necessary for serving web pages.

This violates the Principle of Least Privilege: a process should possess only the permissions it actually requires.

Linux Capabilities solve this problem by decomposing root privileges into fine-grained permissions.

---

## From Unlimited Power to Fine-Grained Privileges

Instead of one enormous privilege called *root*, Linux defines dozens of independent capabilities.

Examples include:

- `CAP_NET_BIND_SERVICE`
- `CAP_NET_RAW`
- `CAP_SYS_TIME`
- `CAP_SYS_PTRACE`
- `CAP_SYS_MODULE`

Processes receive only the capabilities they need, reducing the impact of vulnerabilities and limiting potential damage after compromise.

---

## Beyond Root

Linux Capabilities do not replace the root account.

Instead, they redefine how privilege is represented inside the kernel.

Privilege becomes a collection of individual permissions rather than a single unrestricted identity.

This model is fundamental to modern Linux security and is used extensively by Docker, Kubernetes, systemd, container runtimes, and cloud infrastructure.

---

## What You Will Learn

Throughout this guide we will move from introductory concepts to kernel internals, covering capability sets, process credentials, `execve()`, file capabilities, namespaces, containers, privilege escalation, and security best practices.

The goal is not to memorize commands, but to build a deep understanding of how Linux manages privilege.
