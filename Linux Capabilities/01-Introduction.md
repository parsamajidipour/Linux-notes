# Introduction

Most people think Linux has only two privilege levels.

Either you are **root**, or you are **not**.

For many years, this explanation was good enough. It is simple, easy to teach, and appears to match how Linux behaves from a user's perspective. Type a command, get *permission denied*, prepend `sudo`, and the command succeeds. From the outside, privilege really does look binary.

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

Even if you have never explicitly configured capabilities, you are almost certainly using software that depends on them right now.

---

## A First Look

Before any theory, it is worth seeing capabilities directly. They are not abstract — every running process exposes its capability state through `/proc`:

```bash
grep '^Cap' /proc/self/status
```

```text
CapInh: 0000000000000000
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 000001ffffffffff
CapAmb: 0000000000000000
```

Those five hexadecimal masks describe the complete privilege state of the process — far more information than "root or not root." An unprivileged shell holds no effective capabilities, yet its **bounding set** (`CapBnd`) still lists every capability the kernel currently defines.

Files carry capabilities too. On many modern systems, `ping` is no longer a SUID-root binary:

```bash
getcap /usr/bin/ping
```

```text
/usr/bin/ping cap_net_raw=ep
```

Instead of running with full root authority, `ping` receives exactly one privilege: the ability to open raw sockets. A bug in `ping` no longer means a bug with root — it means a bug with `CAP_NET_RAW`, and nothing else. That single line is the entire idea of this guide in miniature.

---

## Why Does This Matter?

Consider a simple web server.

Its primary responsibility is serving HTTP requests over TCP port 80.

Historically, binding to any port below **1024** required root privileges.

This created an obvious security problem.

If the web server needed root merely to listen on port 80, it also inherited every other privilege available to the superuser: the ability to read any file, load kernel modules, change the system clock, reboot the machine, and trace any process on the system.

Clearly, none of these permissions are necessary for serving web pages.

This violates the **Principle of Least Privilege**: a process should possess only the permissions it actually requires — nothing more.

The traditional escape from this problem was the "start as root, then drop privileges" pattern: the server would bind port 80 while root, then call `setuid()` to a low-privilege account. This works, but it has two weaknesses. First, there is always a window — however short — during which the full-root process is running attacker-reachable code. Second, dropping privileges correctly is surprisingly easy to get wrong, and a single mistake leaves a root process exposed.

Capabilities remove the need to ever hold full root at all:

```bash
sudo setcap cap_net_bind_service=+ep /usr/sbin/nginx
```

The process gains the ability to bind privileged ports while remaining restricted in every other area. There is no root window to protect and no privilege-dropping code to get wrong.

---

## From Unlimited Power to Fine-Grained Privileges

Instead of one enormous privilege called *root*, Linux defines dozens of independent capabilities. On a current kernel there are 41 of them (numbered `0` through `CAP_LAST_CAP`, which is `40`).

A representative sample:

| Capability | Grants |
|---|---|
| `CAP_NET_BIND_SERVICE` | Binding to TCP/UDP ports below 1024 |
| `CAP_NET_RAW` | Creating raw and packet sockets |
| `CAP_NET_ADMIN` | Configuring interfaces, routes, firewalls |
| `CAP_SYS_TIME` | Setting the system clock |
| `CAP_SYS_PTRACE` | Tracing and inspecting arbitrary processes |
| `CAP_SYS_MODULE` | Loading and unloading kernel modules |
| `CAP_DAC_OVERRIDE` | Bypassing file read/write/execute permission checks |
| `CAP_SYS_ADMIN` | A large, loosely related set of administrative operations |

Processes receive only the capabilities they need, reducing the impact of vulnerabilities and limiting potential damage after compromise. A compromised process that holds only `CAP_NET_BIND_SERVICE` cannot read `/etc/shadow`, cannot load a rootkit, and cannot attach a debugger to another process — regardless of what the attacker's code tries to do.

---

## Beyond Root

Linux Capabilities do not replace the root account.

Instead, they redefine how privilege is represented inside the kernel.

The classic check that many people imagine the kernel performing —

```c
if (uid == 0)
        allow();
```

— is largely a myth in modern code paths. Instead, kernel subsystems ask a much narrower question:

```c
if (capable(CAP_NET_ADMIN))
        allow();
else
        return -EPERM;
```

Privilege becomes a collection of individual permissions rather than a single unrestricted identity. Even UID 0 is, under the hood, simply a UID that the kernel *starts* with a full capability set — and that set can be reduced, bounded, or removed entirely. A "root" process stripped of its capabilities can be less privileged than an ordinary user.

This model is fundamental to modern Linux security and is used extensively by Docker, Kubernetes, systemd, container runtimes, and cloud infrastructure. It is precisely why "root inside a container" is not the same as "root on the host."

---

## A Short History

Capabilities did not arrive all at once. The model was built incrementally over two decades, and each addition solved a specific limitation of what came before:

| Milestone | Kernel | What it added |
|---|---|---|
| POSIX 1003.1e draft | — | The conceptual model (the standard was never ratified, but Linux adopted its vocabulary) |
| Initial capabilities | 2.2 (1999) | Per-process capability sets; root's power split into discrete bits |
| File capabilities | 2.6.24 (2008) | Capabilities stored on executables via the `security.capability` xattr, reducing reliance on SUID |
| `no_new_privs` | 3.5 (2012) | A one-way flag that blocks a process (and its children) from gaining privilege through `execve()` |
| Ambient capabilities | 4.3 (2015) | A way to preserve capabilities across an ordinary, non-SUID `execve()` — critical for capability-aware service launchers |

Knowing this timeline explains a lot of otherwise confusing behavior. Ambient capabilities, for example, exist because the original inheritable set could not solve a real operational problem on its own. The design is a series of answers to concrete failures, not a single grand plan.

---

## What You Will Learn

Throughout this guide we move from introductory concepts to kernel internals:

- Why the traditional root model became a liability at scale
- How the kernel represents identity through `struct cred`
- Every capability set — Permitted, Effective, Inheritable, Bounding, Ambient — and how they interact
- Exactly how `execve()` recalculates privilege
- How file capabilities are stored and evaluated
- How capabilities behave inside user namespaces and containers
- How capabilities become privilege-escalation primitives, and how to defend against that
- Practical troubleshooting when a capability "should work" but doesn't

The goal is not to memorize commands. It is to build a mental model accurate enough that capability behavior becomes predictable rather than surprising — whether you are hardening a service, auditing a host, or reasoning about a container escape.
