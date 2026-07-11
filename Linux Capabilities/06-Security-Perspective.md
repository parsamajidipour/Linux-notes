# Security Perspective

Linux Capabilities were introduced to reduce the risks associated with the traditional
all-powerful root account. They are therefore a security feature first and a convenience
feature second.

Understanding capabilities from a security perspective requires thinking like both
a defender and an attacker.

---

# 1. The Principle of Least Privilege

Every additional capability expands the attack surface of a process.

Instead of asking:

> Does this application need root?

Ask:

> Which exact kernel operations must this application perform?

If the answer is "bind to TCP port 443", then `CAP_NET_BIND_SERVICE` may be sufficient.
Granting `CAP_SYS_ADMIN` would violate the principle of least privilege.

---

# 2. Why Attackers Love Capabilities

From an attacker's point of view, capabilities are valuable because they often provide
privileged kernel operations without requiring full root access.

During a privilege-escalation assessment, one of the first checks is:

```bash
getcap -r / 2>/dev/null
```

Interesting binaries deserve manual review.

Particular attention should be paid to interpreters, scripting engines, archive tools,
debuggers and network utilities.

---

# 3. Dangerous Capabilities

Some capabilities are relatively narrow.

Others expose broad portions of kernel functionality.

The following deserve careful review in almost every environment.

## CAP_SYS_ADMIN

Often described as the "new root."

It controls a very large collection of unrelated administrative operations.

If a process truly requires CAP_SYS_ADMIN, review that design carefully.

## CAP_SETUID / CAP_SETGID

Allow manipulation of process identities.

Incorrectly assigned, they can become direct privilege-escalation primitives.

## CAP_DAC_OVERRIDE

Allows bypassing discretionary file permission checks.

Applications possessing this capability may access files that ordinary users cannot.

## CAP_SYS_PTRACE

Enables tracing and debugging of other processes.

This can expose credentials, cryptographic material and sensitive application state.

## CAP_SYS_MODULE

Allows loading and unloading kernel modules.

Kernel code execution effectively compromises the entire operating system.

---

# 4. File Capabilities and Privilege Escalation

File capabilities are safer than indiscriminate SUID usage, but they are not harmless.

Example:

```text
/usr/bin/python3  cap_setuid=ep
```

If Python possesses CAP_SETUID, an attacker may be able to execute arbitrary code and
change process credentials.

The problem is not Python itself.

The problem is granting a general-purpose interpreter a powerful capability.

The same concern applies to:

- Perl
- Ruby
- Bash
- BusyBox
- Tar
- Editors with shell escape features
- Debuggers

Always evaluate both:

1. The capability.
2. What the executable is capable of doing.

---

# 5. Containers

Containers frequently run with reduced capability sets.

However, mistakes are common.

Poor examples include:

- `docker run --privileged`
- Adding CAP_SYS_ADMIN "because it fixes the problem"
- Adding every capability during troubleshooting and forgetting to remove them

A secure deployment should:

- Drop all capabilities by default.
- Add back only the minimum required.
- Combine capability reduction with seccomp, namespaces and an LSM.

---

# 6. Auditing Existing Systems

A practical audit usually includes:

```bash
getcap -r / 2>/dev/null
```

```bash
capsh --print
```

```bash
grep '^Cap' /proc/<PID>/status
```

```bash
systemctl show <service> \
  -p CapabilityBoundingSet \
  -p AmbientCapabilities \
  -p NoNewPrivileges
```

The objective is to identify excessive privilege, not simply to list capabilities.

---

# 7. Common Defensive Practices

- Avoid CAP_SYS_ADMIN whenever possible.
- Remove capabilities immediately after initialization if they are no longer required.
- Prefer file capabilities over SUID where appropriate.
- Review newly installed packages for unexpected file capabilities.
- Keep Ambient capabilities empty unless explicitly required.
- Reduce the Bounding set for long-running services.
- Enable `NoNewPrivileges=yes` for services that never need to gain additional privilege.
- Review capability assignments during security assessments and change management.

---

# 8. Capabilities Are Only One Layer

Capabilities reduce privilege.

They do not replace:

- File permissions
- User namespaces
- seccomp
- AppArmor
- SELinux
- Read-only filesystems
- Mandatory authentication
- Secure coding practices

A secure Linux system combines multiple layers of defense.

Capabilities should be viewed as one component of a broader defense-in-depth strategy.

---

# Security Checklist

Before deploying a privileged service:

- Does it really require this capability?
- Is there a narrower capability available?
- Can the capability be removed after startup?
- Is the Bounding set reduced?
- Is `NoNewPrivileges` enabled?
- Is the executable programmable or scriptable?
- Are seccomp and LSM policies also in place?
- Has the service been tested without unnecessary capabilities?

---

# Summary

Linux Capabilities significantly reduce the risks associated with unrestricted root
access, but only when they are used correctly.

Overly broad capability assignments recreate many of the same security problems that
Capabilities were designed to solve.

For defenders, capabilities are a mechanism for reducing attack surface.

For attackers, they are valuable indicators of potential privilege-escalation paths.

Understanding both perspectives is essential for building and auditing secure Linux
systems.
