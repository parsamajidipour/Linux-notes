# How Linux Capabilities Work

Linux Capabilities are not merely metadata attached to an executable.

They are part of the Linux kernel's credential subsystem and are evaluated during every privileged operation.

To understand Capabilities correctly, it is necessary to understand how the kernel represents process identity.

---

## From User IDs to Credentials

Every process has traditional UNIX credentials such as:

- Real UID
- Effective UID
- Saved UID
- Real GID
- Effective GID

Modern Linux extends this model through a kernel object named `struct cred`.

Instead of storing privilege information directly inside the process descriptor, the kernel stores it in a credential structure that can be safely shared, copied, and replaced.

---

## The Credential Object

Each task (`task_struct`) contains a pointer to its credentials.

Conceptually:

```
task_struct
      |
      +----> struct cred
                 |
                 +-- UID/GID
                 +-- Capability Sets
                 +-- Securebits
                 +-- LSM Security Context
```

Whenever the kernel must determine whether a privileged operation is allowed, it consults the process credentials rather than asking a simple question such as "Is this process root?"

---

## Capability Checks

Kernel subsystems rarely test for UID 0 directly.

Instead they invoke capability checks.

Conceptually:

```
if (process_has_capability(CAP_NET_ADMIN))
        allow_operation();
else
        return -EPERM;
```

This makes authorization far more granular than the traditional UNIX privilege model.

---

## Capability Sets

A process does not simply "have capabilities."

Linux maintains multiple capability sets that serve different purposes during execution.

The most important are:

- Permitted
- Effective
- Inheritable
- Bounding
- Ambient

Each set participates in privilege transitions during `execve()`.

These sets will be discussed in detail in the next chapter.

---

## File Capabilities

Executable files may also carry capabilities.

These are stored as extended filesystem attributes (`security.capability`).

When such a binary is executed, the kernel calculates the resulting process capabilities according to a well-defined algorithm instead of blindly granting full root privileges.

This is one of the major reasons modern distributions no longer rely on SUID for many utilities.

---

## Privilege Transitions

Whenever a process executes a new program through `execve()`, Linux recalculates its credentials.

The resulting privilege depends on several factors:

- Current capability sets
- File capabilities
- Securebits
- Bounding set
- Ambient capabilities
- User IDs

Understanding this transition is essential for container runtimes, service managers and security auditing.

---

## Why This Design Matters

Separating privilege into credential objects provides flexibility, improves security, and enables modern isolation technologies.

Containers, namespaces, systemd services and cloud workloads all depend on this model to grant only the minimum privileges required by each process.

The following chapter explores every capability set in detail and explains how they interact during process execution.
