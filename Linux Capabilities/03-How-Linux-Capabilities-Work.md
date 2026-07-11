# How Linux Capabilities Work

Linux Capabilities are not merely metadata attached to an executable.

They are part of the Linux kernel's credential subsystem and are evaluated during almost every privileged operation the kernel performs.

To understand Capabilities correctly, it is necessary to understand how the kernel represents process identity, how a capability is physically represented as a set of bits, and what actually happens when the kernel decides whether an operation is permitted.

---

## From User IDs to Credentials

Every process has traditional UNIX credentials:

- Real UID / Real GID
- Effective UID / Effective GID
- Saved set-UID / Saved set-GID
- Filesystem UID / GID
- Supplementary group list

Modern Linux gathers all of this — plus capabilities, securebits, keyrings, and the LSM security context — into a single kernel object named `struct cred`.

Instead of storing privilege information directly inside the process descriptor, the kernel stores it in a reference-counted credential structure that can be safely shared between tasks, copied on change, and replaced atomically. This design is what makes privilege transitions safe on a preemptible, multi-core kernel: a task never mutates its live credentials in place, it prepares a new `struct cred` and commits it.

---

## The Credential Object

Each task (`task_struct`) contains a pointer to its credentials. Conceptually:

```text
task_struct
      |
      +----> struct cred
                 |
                 +-- uid / gid / euid / egid / suid / sgid / fsuid / fsgid
                 +-- cap_inheritable   (CapInh)
                 +-- cap_permitted     (CapPrm)
                 +-- cap_effective     (CapEff)
                 +-- cap_bset          (CapBnd)
                 +-- cap_ambient       (CapAmb)
                 +-- securebits
                 +-- user_namespace *
                 +-- LSM security blob
```

Two details matter here. First, the capability sets live *inside* the credential object, right next to the UIDs — capabilities are credentials, not a bolted-on afterthought. Second, every credential is tied to a **user namespace** (`user_namespace *`). A capability is always meaningful *relative to a namespace*, which is the entire reason "root in a container" can be powerless on the host.

Whenever the kernel must determine whether a privileged operation is allowed, it consults these credentials rather than asking a simple question such as "Is this process root?"

---

## How a Capability Is Represented

A capability set is not a list of names — it is a bitmask. Each capability has a fixed integer number, and its presence in a set is a single bit.

```c
/* include/uapi/linux/capability.h (abridged) */
#define CAP_CHOWN            0
#define CAP_DAC_OVERRIDE     1
#define CAP_DAC_READ_SEARCH  2
#define CAP_FOWNER           3
/* ... */
#define CAP_NET_BIND_SERVICE 10
#define CAP_NET_RAW          13
#define CAP_SYS_ADMIN        21
#define CAP_SYS_MODULE       16
/* ... */
#define CAP_LAST_CAP         CAP_CHECKPOINT_RESTORE   /* 40 on current kernels */
```

Because `CAP_LAST_CAP` is `40`, a full capability set needs 41 bits, which is why the kernel represents each set as a 64-bit value. This is exactly what you see when reading `/proc/<PID>/status`:

```text
CapBnd: 000001ffffffffff
```

`0x000001ffffffffff` has bits `0` through `40` set — every currently defined capability. Decode it with libcap rather than counting bits by hand:

```bash
capsh --decode=000001ffffffffff
```

The mapping from name to bit is the reason two capabilities can be combined into one mask (`cap_net_raw,cap_net_admin`) and why the kernel can test membership with a single bitwise AND.

---

## Capability Checks

Kernel subsystems rarely test for UID 0 directly. Instead they call into the capability layer. The most common entry points are:

```c
capable(CAP_NET_ADMIN);            /* check against the initial user namespace  */
ns_capable(ns, CAP_NET_ADMIN);     /* check against a specific user namespace   */
```

Both eventually reach the Linux Security Module hook `security_capable()`, and from there the default implementation in `security/commoncap.c`:

```c
/* simplified control flow */
if (cap_effective_has(current_cred(), CAP_NET_ADMIN))
        allow_operation();
else
        return -EPERM;
```

The check is made against the **effective** set, evaluated in the relevant user namespace. Two consequences follow directly from this:

- Holding a capability in *permitted* but not *effective* means the kernel will deny the operation until the process raises it into effective.
- A capability is only useful against resources owned by a user namespace the process actually has authority over — holding `CAP_NET_ADMIN` in a nested namespace does nothing to the host's network stack.

This is far more granular than the traditional UNIX model, and it is why "the process is root" is an incomplete answer to "can the process do X?"

---

## Capability Sets

A process does not simply "have capabilities." Linux maintains five per-thread sets, each answering a different question:

| Set | `/proc` name | Question it answers |
|---|---|---|
| Permitted | `CapPrm` | Which capabilities *may* the thread make effective? |
| Effective | `CapEff` | Which capabilities are active *right now*? |
| Inheritable | `CapInh` | Which capabilities survive `execve()` of a marked file? |
| Bounding | `CapBnd` | What ceiling limits capabilities gained via a file? |
| Ambient | `CapAmb` | Which capabilities survive an *ordinary* `execve()`? |

Each set participates in privilege transitions during `execve()`. Their interaction is subtle enough to deserve its own chapter — the next one covers every set in detail and works through the exact transformation formula.

---

## File Capabilities

Executable files may also carry capabilities. These are stored as an extended filesystem attribute named `security.capability`:

```bash
getcap /usr/bin/ping
```

```text
/usr/bin/ping cap_net_raw=ep
```

```bash
getfattr -n security.capability /usr/bin/ping
```

The xattr is a small binary structure (VFS capability format v2, or v3 when the file capability is scoped to a non-initial user namespace, added in Linux 4.14). It encodes three things:

- a **permitted** set the file grants,
- an **inheritable** set the file contributes,
- and an **effective flag** — a single bit.

The effective flag is important. If it is set (`=ep`), the kernel automatically copies the file's permitted capabilities into the new process's effective set, so the program works without being capability-aware. If it is clear (`=p`), the capabilities land in permitted only, and the program must raise them into effective itself using libcap. This is why some binaries "have" a capability yet still fail until they explicitly enable it.

When such a binary is executed, the kernel calculates the resulting process capabilities according to a well-defined algorithm instead of blindly granting full root privileges. This is one of the major reasons modern distributions no longer rely on SUID for utilities like `ping`.

> Note: the `nosuid` mount option strips file capabilities during `execve()`, exactly as it strips the SUID bit. A binary with file capabilities on a `nosuid` filesystem silently receives none of them — a classic source of "it works here but not there."

---

## Privilege Transitions

Whenever a process executes a new program through `execve()`, Linux recalculates its credentials from scratch. The resulting privilege depends on several inputs at once:

- The current Permitted, Effective, Inheritable, and Ambient sets
- The file's permitted, inheritable, and effective-flag data
- The Bounding set (which caps the file-granted contribution)
- The securebits flags
- The `no_new_privs` flag
- The traditional UID/GID transition (SUID/SGID)

The kernel combines these to produce the new process's sets. Getting this transition right is the heart of understanding capabilities: it is where inheritable becomes useful, where the bounding set enforces its ceiling, and where ambient capabilities survive an ordinary exec. The full formula — with worked examples — is the subject of the next chapter.

---

## Why This Design Matters

Separating privilege into reference-counted credential objects, keying every capability to a user namespace, and recalculating everything on `execve()` gives the kernel three properties that the old root model could never provide:

- **Flexibility** — privilege can be granted, bounded, and dropped one bit at a time.
- **Safety** — credential changes are atomic and never mutate a live, shared structure.
- **Isolation** — the same capability means different things in different namespaces, which is what makes containers a real boundary.

Containers, namespaces, systemd services, and cloud workloads all depend on this model to grant only the minimum privilege each process requires.

The following chapter explores every capability set in detail and explains precisely how they interact during process execution.
