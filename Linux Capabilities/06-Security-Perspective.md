# Security Perspective

Linux Capabilities were introduced to reduce the risks associated with the traditional all-powerful root account. They are therefore a security feature first and a convenience feature second.

Understanding capabilities from a security perspective requires thinking like both a defender and an attacker. A defender asks "how little privilege can this service run with?" An attacker asks "which of these narrow privileges can I turn into full control?" Both questions have the same answer set — which is exactly why capability auditing sits at the center of Linux privilege-escalation work.

---

# 1. The Principle of Least Privilege

Every additional capability expands the attack surface of a process. Instead of asking:

> Does this application need root?

ask:

> Which exact kernel operations must this application perform?

If the answer is "bind to TCP port 443," then `CAP_NET_BIND_SERVICE` is sufficient and `CAP_SYS_ADMIN` would be a gross violation of least privilege. The discipline is to start from *nothing* and add back only what a failing syscall proves is required — never to start from root and trim.

---

# 2. Why Attackers Love Capabilities

From an attacker's point of view, capabilities are valuable because they grant privileged kernel operations *without* the obvious red flag of a root process. A service running as an unprivileged user with one carefully chosen capability can look hardened while still offering a direct path to root.

During a privilege-escalation assessment, one of the first enumeration steps is:

```bash
getcap -r / 2>/dev/null
```

The mindset when reading that output: a capability is dangerous in proportion to *what the capable binary can be made to do*. The same capability on a single-purpose daemon may be safe, and on a scriptable interpreter may be an instant root shell. Interpreters, scripting engines, archive tools, editors with shell escapes, and debuggers deserve the closest look.

---

# 3. Dangerous Capabilities

Some capabilities are narrow. Others expose broad portions of kernel functionality and turn into privilege escalation the moment they land on the wrong binary. The following deserve careful review in almost every environment. Each entry explains *why* it is dangerous and how to reason about it — not to weaponize it, but so that an auditor recognizes the risk on sight.

## CAP_SYS_ADMIN

Often called "the new root." It gates a large, unrelated collection of operations — mounting filesystems, many `prctl()` calls, various device operations, and more. Its breadth alone makes it hard to reason about. In containers it is the classic escape enabler: with mount privileges, a misconfigured cgroup v1 `release_agent` can be abused to run a host-side program. If a process "requires" `CAP_SYS_ADMIN`, treat that as a design smell and look for the narrower capability that actually covers the need.

## CAP_SETUID / CAP_SETGID

Allow a process to change its own (and others') UID/GID at will. On any programmable binary this is a direct root primitive: the process can simply set its UID to 0. This is the single most reliable capability-based escalation, which is why `CAP_SETUID` on an interpreter is treated as equivalent to giving that interpreter SUID-root.

## CAP_DAC_OVERRIDE

Bypasses discretionary file read/write/execute permission checks. A process holding it can write files it has no business writing — `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, a root cron file — each of which converts to root through ordinary means. It effectively neutralizes standard filesystem permissions.

## CAP_DAC_READ_SEARCH

Bypasses read and directory-search permission checks, and — importantly — enables `open_by_handle_at()`. On container hosts this has been used (the "Shocker" technique) to read arbitrary files on the host filesystem, including sensitive material outside the container's intended view. Read-only sounds mild until it includes every secret on the box.

## CAP_SYS_PTRACE

Enables tracing and inspecting other processes. An attacker can attach to a more-privileged process and read its memory (credentials, keys, tokens) or inject code into it. Where `ptrace` scope is not otherwise restricted, this is a route to whatever the target process can do.

## CAP_SYS_MODULE

Allows loading and unloading kernel modules. This is the most decisive capability of all: loading a module means executing attacker-controlled code in the kernel, which is total compromise of the machine. There is no meaningful "contained" version of kernel code execution.

## Others worth flagging

- `CAP_CHOWN` / `CAP_FOWNER` — change ownership / bypass ownership checks, enabling manipulation of sensitive files.
- `CAP_SYS_RAWIO` — raw I/O and access to physical memory devices; a path around most software protections.
- `CAP_MKNOD` — create device nodes, potentially granting direct access to block devices.
- `CAP_BPF` / `CAP_PERFMON` (Linux 5.8+) — powerful kernel introspection surfaces that split off pieces of the old `CAP_SYS_ADMIN`; narrower, but still sensitive.

---

# 4. File Capabilities and Privilege Escalation

File capabilities are safer than indiscriminate SUID usage, but they are not harmless. The canonical example:

```bash
getcap /usr/bin/python3
```

```text
/usr/bin/python3 cap_setuid=ep
```

If a general-purpose interpreter carries `CAP_SETUID`, an attacker who can run it can simply set their UID to 0 and drop into a root shell. This is well-documented, standard privilege-escalation knowledge (it appears in essentially every capability reference and enumeration guide) precisely *because* it is such a common misconfiguration.

The problem is not Python. The problem is granting a program that runs arbitrary user-supplied code a powerful capability. The same concern applies to:

- Perl, Ruby, Node, PHP
- Bash and other shells
- BusyBox
- `tar`, `zip`, and other archivers with command-execution features
- Editors with shell-escape (`vim`, `nano` variants)
- Debuggers such as `gdb`

Always evaluate **two** things together:

1. The capability granted.
2. What the executable can be made to do.

A narrow capability on a single-purpose binary can be fine. The same capability on a programmable one is usually a finding.

---

# 5. Containers

Containers frequently run with reduced capability sets, which is good — but mistakes are common and expensive:

- `docker run --privileged` (restores broad privilege and disables other protections)
- Adding `CAP_SYS_ADMIN` "because it fixes the problem"
- Adding many capabilities during troubleshooting and forgetting to remove them
- Assuming "root inside the container" is safely contained when the container is *not* in a user namespace

A secure deployment should:

- Drop `ALL` capabilities by default.
- Add back only the minimum the workload proves it needs.
- Prefer a user namespace so container-root maps to an unprivileged host UID.
- Combine capability reduction with seccomp, a read-only root filesystem, and an LSM (AppArmor or SELinux).

A capability that is contained by a user namespace is far less dangerous than the same capability in a container sharing the host's initial namespace — the namespace context is as important as the capability itself.

---

# 6. Auditing Existing Systems

A practical audit combines process-level and file-level inspection:

```bash
# File capabilities across the filesystem
getcap -r / 2>/dev/null

# What a specific process actually holds
grep '^Cap' /proc/<PID>/status
getpcaps <PID>

# What a service is configured to hold
systemctl show <service> \
  -p CapabilityBoundingSet \
  -p AmbientCapabilities \
  -p NoNewPrivileges

# What a container holds
docker inspect <container> --format '{{.HostConfig.CapAdd}} {{.HostConfig.CapDrop}} {{.HostConfig.Privileged}}'
```

The objective is not to *list* capabilities — it is to identify **excess** privilege: a capability present that the workload does not need, or a broad capability standing in for a narrow one.

---

# 7. Common Defensive Practices

- Avoid `CAP_SYS_ADMIN` wherever a narrower capability exists.
- Drop capabilities immediately after initialization if they are only needed at startup.
- Prefer file capabilities over SUID where a file grant is unavoidable.
- Review newly installed packages for unexpected file capabilities.
- Keep the Ambient set empty unless a launcher genuinely needs it.
- Reduce the Bounding set for long-running services to cap future privilege gains.
- Enable `NoNewPrivileges=yes` for services that never need to gain privilege via `execve()`.
- Re-review capability assignments during change management, not just at first deploy.

---

# 8. Capabilities Are Only One Layer

Capabilities reduce privilege. They do not replace:

- File permissions and ACLs
- User namespaces
- seccomp syscall filtering
- AppArmor / SELinux
- Read-only filesystems
- Sound authentication
- Secure coding

A capability grant is a ceiling on damage, not a guarantee of safety. A secure Linux system layers these mechanisms so that defeating one does not defeat all of them — capabilities as one component of defense in depth.

---

# Security Checklist

Before deploying a privileged service:

- Does it really require this capability, or a narrower one?
- Can the capability be dropped after startup?
- Is the Bounding set reduced to the minimum?
- Is `NoNewPrivileges` enabled?
- Is the target executable programmable or scriptable? (If so, is the capability truly safe on it?)
- Is the container in a user namespace?
- Are seccomp and an LSM also in place?
- Has the service been tested with capabilities *removed* to confirm what it actually needs?

---

# Summary

Linux Capabilities significantly reduce the risks of unrestricted root access — but only when used correctly. Overly broad assignments recreate the very problems capabilities were designed to solve, and a single powerful capability on a programmable binary can be a complete escalation path.

For defenders, capabilities are a mechanism for shrinking attack surface and containing compromise. For attackers, unexpected capability grants are among the highest-value findings on a Linux host. Understanding both perspectives — mechanism and misuse — is what makes it possible to build and to audit secure systems.
