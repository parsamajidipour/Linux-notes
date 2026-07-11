# Why Capabilities Exist

For decades, UNIX followed a remarkably simple privilege model.

A process either executed with **superuser privileges (root)** or it did not.

This binary model was easy to understand and straightforward to implement. It also matched the hardware and threat environment of early UNIX: a small number of trusted users on a shared minicomputer. As Linux evolved into the foundation of web servers, cloud platforms, embedded devices, mobile systems, and container infrastructure — environments where untrusted code runs constantly and a single host may run thousands of services — the limitations of that model became increasingly apparent.

---

## The Problem with the Traditional Root Model

The root account possesses unrestricted authority over the operating system.

A root process can:

- Bypass every file permission check
- Modify kernel parameters
- Load and unload kernel modules
- Configure networking and firewalls
- Mount and unmount filesystems
- Change ownership of any file
- Kill arbitrary processes
- Trace and inspect any other process
- Access raw devices and physical memory

In many situations, software requires only **one** of these privileges.

Granting every administrative privilege simply to obtain one permission violates the **Principle of Least Privilege**, a foundational concept in computer security.

> A process should have only the permissions necessary to perform its intended function — nothing more.

The danger is not theoretical. When a root process is compromised, the attacker does not inherit the privilege the program *needed* — they inherit the privilege the program *held*. A web server that only ever needed to bind a port hands an attacker the ability to read every secret on the machine, install a kernel rootkit, and pivot to every other service. The gap between "privilege required" and "privilege granted" is precisely the blast radius of a compromise.

---

## The SUID Problem

Before capabilities, the standard way to give an ordinary user a single privileged ability was the **set-user-ID (SUID)** bit. A binary owned by root with the SUID bit set runs as root regardless of who launches it:

```bash
ls -l /usr/bin/passwd
```

```text
-rwsr-xr-x 1 root root 59976 /usr/bin/passwd
```

The `s` in the permission string means every user who runs `passwd` briefly becomes root — necessary, because updating `/etc/shadow` requires write access no ordinary user has. This works, but it is a blunt instrument with real consequences:

- **All-or-nothing.** The binary gets *complete* root authority, even if it only needs to write one file. A memory-corruption bug in a SUID-root program is an instant local root exploit.
- **Huge historical attack surface.** SUID binaries have been one of the most productive sources of local privilege escalation in UNIX history precisely because a single flaw yields full root.
- **Hard to audit.** Every SUID binary on a system is a potential root vector, and their number tends to grow silently as packages are installed.

Capabilities were designed, in large part, to retire this pattern. A file capability grants a binary one narrow privilege instead of the entire root identity — the same goal SUID served, without handing over the keys to the kernel.

---

## A Practical Example

Consider an HTTP server.

Its only requirement during startup may be binding to TCP port 80.

Historically, ports below 1024 were considered privileged and required root privileges. To satisfy this single requirement, administrators often started the entire web server as root.

Although many servers later dropped privileges by calling `setuid()` after binding, the design still carried risk. A vulnerability triggered *before* that transition — or a bug in the privilege-dropping logic itself — could expose the entire operating system. The "drop after bind" pattern is a mitigation layered on top of a fundamentally over-privileged start.

Linux Capabilities eliminate this unnecessary trust. Instead of granting full administrative authority, the kernel can grant only:

```bash
sudo setcap cap_net_bind_service=+ep /usr/sbin/nginx
getcap /usr/sbin/nginx
```

```text
/usr/sbin/nginx cap_net_bind_service=ep
```

The process gains the ability to bind to privileged ports while remaining restricted in every other area. There is no root startup phase to protect, and no privilege-dropping code that can fail.

---

## Decomposing Root

Beginning with Linux 2.2, the kernel introduced **Capabilities**.

Rather than representing privilege as one enormous permission called *root*, administrative power was divided into multiple independent capabilities. Each capability represents a narrowly scoped operation, and the kernel checks for the specific one relevant to each privileged action:

| Capability | Purpose |
|------------|---------|
| `CAP_NET_BIND_SERVICE` | Bind to privileged network ports (below 1024) |
| `CAP_NET_RAW` | Create raw and packet sockets |
| `CAP_NET_ADMIN` | Manage interfaces, routing, and firewall rules |
| `CAP_SYS_TIME` | Modify the system clock |
| `CAP_CHOWN` | Change file ownership |
| `CAP_DAC_OVERRIDE` | Bypass discretionary file permission checks |
| `CAP_SYS_PTRACE` | Trace or debug other processes |
| `CAP_SYS_MODULE` | Load and unload kernel modules |
| `CAP_KILL` | Send signals to any process |

This model allows applications to receive only the permissions they genuinely require. It also makes the *cost* of a privilege visible: granting `CAP_SYS_MODULE` is obviously granting the ability to run arbitrary kernel code, in a way that "just run it as root" never made explicit.

---

## Root vs Capabilities

The shift is easiest to see side by side:

| Concern | Traditional root | Capability model |
|---|---|---|
| Granularity | One privilege (all) | ~41 independent privileges |
| Blast radius on compromise | Entire system | Only the granted capability |
| Privilege for one task | Full root | A single capability |
| Auditing | "Is it SUID/root?" | "Which capabilities, in which sets?" |
| Revocability | Drop all-or-nothing | Drop individually, permanently if desired |
| Container isolation | Weak (root is root) | Root can be stripped per container |

The important conceptual change is that privilege stops being an *identity* ("this is a root process") and becomes a *set of permissions* ("this process may do exactly these things"). That reframing is what everything else in this guide builds on.

---

## Security Benefits

Reducing privileges has direct, measurable security advantages.

If an application is compromised, an attacker inherits only the capabilities available to that process. A remote code execution flaw in a service holding a single narrow capability is a serious bug — but it is not a system takeover. This is the difference between an incident and a catastrophe.

Modern Linux security therefore focuses not only on **who** executes a process, but also **which specific privileges** that process possesses. Two processes both running as UID 0 can have wildly different real authority depending on their capability sets, their bounding set, and the user namespace they live in.

This shift has become essential in environments where thousands of services execute simultaneously on shared infrastructure, each with a different, minimal privilege requirement.

---

## Why It Matters Today

Linux Capabilities are deeply integrated into modern infrastructure. They determine how:

- Docker launches containers (dropping most capabilities by default)
- Kubernetes isolates workloads through the Pod security context
- systemd confines services with `CapabilityBoundingSet=` and `AmbientCapabilities=`
- Rootless containers give "container root" without host root
- Security policies enforce least privilege at scale
- Privilege escalation is contained after an initial compromise

Without Capabilities, many of the security guarantees expected from modern container platforms would be considerably more difficult — in some cases impossible — to achieve. A container runtime that could only offer "full root or no root" would not be a viable isolation boundary.

---

## Looking Ahead

Understanding *why* Capabilities exist provides the foundation for everything that follows.

The next chapter explores **how the Linux kernel actually represents privilege** — how process credentials are stored in `struct cred`, how the kernel performs a capability check in practice, and how capabilities become a concrete part of the kernel's security model rather than an abstract policy.
