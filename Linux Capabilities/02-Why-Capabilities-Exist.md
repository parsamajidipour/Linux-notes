# Why Capabilities Exist

For decades, UNIX followed a remarkably simple privilege model.

A process either executed with **superuser privileges (root)** or it did not.

This binary model was easy to understand and straightforward to implement. However, as Linux evolved into the foundation of web servers, cloud platforms, embedded devices, mobile systems, and container infrastructure, its limitations became increasingly apparent.

---

## The Problem with the Traditional Root Model

The root account possesses unrestricted authority over the operating system.

A root process can:

- Bypass file permission checks
- Modify kernel parameters
- Load and unload kernel modules
- Configure networking
- Mount filesystems
- Change ownership of any file
- Kill arbitrary processes
- Access sensitive system resources

In many situations, software requires only **one** of these privileges.

Granting every administrative privilege simply to obtain one permission violates the **Principle of Least Privilege**, a foundational concept in computer security.

> A process should have only the permissions necessary to perform its intended function—nothing more.

---

## A Practical Example

Consider an HTTP server.

Its only requirement during startup may be binding to TCP port 80.

Historically, ports below 1024 were considered privileged and required root privileges.

To satisfy this single requirement, administrators often started the entire web server as root.

Although many servers later dropped privileges, a vulnerability before that transition—or an implementation mistake—could expose the entire operating system.

Linux Capabilities eliminate this unnecessary trust.

Instead of granting full administrative authority, the kernel can grant only:

- `CAP_NET_BIND_SERVICE`

The process gains the ability to bind to privileged ports while remaining restricted in every other area.

---

## Decomposing Root

Beginning with Linux 2.2, the kernel introduced **Capabilities**.

Rather than representing privilege as one enormous permission called *root*, administrative power was divided into multiple independent capabilities.

Each capability represents a narrowly scoped operation.

Examples include:

| Capability | Purpose |
|------------|---------|
| `CAP_NET_BIND_SERVICE` | Bind to privileged network ports |
| `CAP_NET_RAW` | Create raw sockets |
| `CAP_SYS_TIME` | Modify the system clock |
| `CAP_CHOWN` | Change file ownership |
| `CAP_SYS_PTRACE` | Trace or debug other processes |

This model allows applications to receive only the permissions they genuinely require.

---

## Security Benefits

Reducing privileges has direct security advantages.

If an application is compromised, an attacker inherits only the capabilities available to that process.

This significantly limits the potential impact of exploitation.

Modern Linux security therefore focuses not only on **who** executes a process, but also **which specific privileges** that process possesses.

This shift has become essential in environments where thousands of services execute simultaneously.

---

## Why It Matters Today

Linux Capabilities are deeply integrated into modern infrastructure.

They influence how:

- Docker launches containers
- Kubernetes isolates workloads
- systemd manages services
- Security policies are enforced
- Privilege escalation is prevented
- Cloud-native applications reduce attack surface

Without Capabilities, many of the security guarantees expected from modern container platforms would be considerably more difficult to achieve.

---

## Looking Ahead

Understanding *why* Capabilities exist provides the foundation for everything that follows.

The next chapter explores **how the Linux kernel actually represents privilege**, how process credentials are stored, and how capabilities become part of the kernel's security model.
