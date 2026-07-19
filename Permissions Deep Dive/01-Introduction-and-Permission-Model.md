# Introduction and Permission Model

A mechanism-level examination of what Linux permissions actually are, where they live in the kernel, why the model looks the way it does, and the vocabulary that every later chapter in this series depends on. This is not a "chmod 755 means read-write-execute" tutorial. It is the conceptual and structural foundation — the thing you need to understand *before* symbolic modes, ACLs, capabilities, or SUID binaries make any real sense.

---

## 1. What a Permission Actually Is

Most explanations of Linux permissions start with the wrong question. They start with "what does `rwx` mean" instead of "what problem is the kernel actually solving." To build a correct mental model, you have to start with the second question.

At its core, a Unix-like operating system is a resource-sharing system. Multiple untrusted or semi-trusted principals — users, and the processes acting on their behalf — share a single machine: the same CPU, the same memory, and critically, the same filesystem. The permission system exists to answer one question, asked billions of times per second on every running system:

> Given this specific process, acting with this specific identity, is it allowed to perform this specific operation on this specific object, right now?

That question is answered by the kernel, not by any userspace tool. `ls -l`, `chmod`, `chown` — none of these enforce anything. They are simply programs that read or write metadata. The actual enforcement happens deep inside the kernel's filesystem layer, at the moment a process issues a system call such as `open()`, `read()`, `write()`, `unlink()`, or `execve()`. Every permission check in this entire series ultimately reduces to a single kernel-level decision made inside that system call path.

This matters because it reframes everything that follows. A permission is not a property of a file the way its size or name is. A permission is a *rule set* attached to a file that the kernel consults during an *access attempt*. No access attempt, no check, no enforcement. This is why, for instance, a process that already has a file descriptor open can often continue reading or writing even after the file's permissions have changed — the check happened once, at `open()` time, not continuously.

---

## 2. The Three Actors in Every Permission Decision

Every access control decision in the traditional Unix model involves exactly three actors:

1. **The subject** — a process, always identified by a set of numeric credentials (not a username string).
2. **The object** — typically a file, directory, device node, socket, or other filesystem entity, each represented internally by an inode.
3. **The operation** — read, write, or execute, mapped onto whatever that verb means for the specific object type.

Everything else in the permission model — ownership, groups, ACLs, capabilities — is refinement layered on top of this triad. If you can hold this triad clearly in your head, the rest of the model becomes mechanical rather than mysterious.

### 2.1 The Subject Is Never a Username

This is the single most important correction to make early. When you type `whoami` and see `parsa`, you are looking at a *userspace convenience* — a string looked up from `/etc/passwd` based on a number. The kernel does not know or care about the string `parsa`. Every process the kernel schedules carries a `struct cred` (in Linux kernel source) containing numeric identifiers:

```
uid_t   uid;    // real user ID
uid_t   euid;   // effective user ID
uid_t   suid;   // saved user ID
uid_t   fsuid;  // filesystem user ID
gid_t   gid;    // real group ID
gid_t   egid;   // effective group ID
gid_t   sgid;   // saved group ID
gid_t   fsgid;  // filesystem group ID
kernel_cap_t cap_effective;  // capability sets
kernel_cap_t cap_permitted;
kernel_cap_t cap_inheritable;
```

Usernames exist purely so humans don't have to memorize numbers. This is why deleting a user from `/etc/passwd` does not remove their files — the files are tagged with a UID, and if that UID no longer resolves to a name, tools like `ls -l` simply print the raw number instead. The ownership metadata never referenced a name in the first place.

### 2.2 The Object Is an Inode, Not a Path

A path like `/home/parsa/notes.txt` is a lookup route, not the object itself. The actual object — the thing that carries permission bits, ownership, timestamps, and a pointer to the data blocks — is the **inode**. Multiple paths (hard links) can point to the same inode, and all of them share the exact same permissions, because permissions are stored on the inode, not on the directory entry.

This single fact explains a lot of behavior that otherwise looks inconsistent:

- Renaming a file does not change its permissions, because rename only touches directory entries, never the inode's permission bits.
- Two hard links to the same file always report identical permissions, ownership, and size — because `ls -l` is describing the inode, and there is only one inode.
- Deleting a file while a process has it open does not actually free the inode until the last file descriptor referencing it is closed — the inode's reference count, not the directory entry, governs its lifetime.

### 2.3 The Operation Depends on Object Type

The letters `r`, `w`, and `x` are reused across very different object types, and their meaning shifts each time. This is one of the most common sources of confusion for people first learning the model, so it deserves to be stated explicitly and precisely, rather than assumed.

**For a regular file:**

| Bit | Meaning |
|---|---|
| `r` | Permission to read the file's byte content via `read()` |
| `w` | Permission to modify the file's byte content via `write()` or truncate it |
| `x` | Permission to execute the file as a program, or invoke it via an interpreter shebang line |

**For a directory**, the meaning is entirely different, because a directory is not a container of bytes to a human reader — it is a mapping table from names to inode numbers:

| Bit | Meaning |
|---|---|
| `r` | Permission to list the names of entries inside the directory (`ls`, `readdir()`) |
| `w` | Permission to add, remove, or rename entries inside the directory — **not** permission to edit the contents of files inside it |
| `x` | Permission to enter the directory and resolve names within it — i.e., to `cd` into it or traverse through it as part of a longer path |

The directory case is the one that trips up almost everyone at least once, so it is worth internalizing as a standalone rule:

> **Deleting or renaming a file is a write operation on its *parent directory*, not on the file itself.**

This is why a file can be `chmod 000` (no permissions at all) and still be deletable by its owner — deletion never consults the file's own permission bits, only the parent directory's write and execute bits. Conversely, a file can be world-readable and world-writable, yet undeletable by anyone but the directory owner, if the parent directory lacks write permission for that user. This single rule resolves a large fraction of "why can I/can't I delete this file" confusion that appears throughout production systems.

The execute bit on a directory deserves particular attention because it behaves unlike execute on anything else. It does not mean "run this directory as a program" — directories are never executable in that sense. It means "permission to pass through this directory while resolving a path." A directory can be readable (you can list its contents) without being executable (you cannot `cd` into it or access anything inside it by name), and this combination is occasionally used intentionally, though it is unusual and easy to misconfigure.

---

## 3. Discretionary Access Control: The Foundational Philosophy

The traditional Unix permission model belongs to a category security researchers call **Discretionary Access Control**, or DAC. The defining property of DAC is this:

> The owner of a resource has the discretion to grant or restrict access to it, and that discretion is itself a privilege the owner exercises freely, without any centralized policy authority approving each decision.

This stands in direct contrast to **Mandatory Access Control** (MAC), the model used by systems like SELinux and AppArmor, where a centrally defined security policy constrains what *even the owner* is permitted to do, regardless of their preference. Chapter 9 of this series covers the security implications of DAC in depth, but the philosophical distinction needs to be introduced here because it explains *why* the base Unix model looks the way it does.

DAC assumes a baseline level of trust: if you own a resource, the system trusts your judgment about who else should touch it. This was a reasonable assumption for the multi-user academic and research timesharing systems Unix was designed for in the early 1970s, where all users were, in some sense, colleagues on the same machine. It becomes a much more fragile assumption on a modern internet-facing server running dozens of network-exposed services under a mix of trusted and semi-trusted identities — which is exactly why later chapters build MAC systems, capabilities, and namespaces on top of this base layer rather than replacing it.

Two consequences follow directly from the DAC philosophy, and both will resurface constantly throughout this series:

1. **Ownership itself is a privilege boundary.** The owner of a file can grant permissions freely up to the limits of their own privilege — but changing *ownership* of a file to another user is, on most modern Linux systems, restricted to the superuser. This asymmetry exists specifically to prevent a user from disowning a file to escape disk quota accounting, or from being tricked into acquiring ownership of a malicious file through a `chown` they didn't request.

2. **Root exists as an escape hatch from DAC, not as a participant in it.** The permission bits are checks against *non-privileged* processes. A process running with effective UID 0 bypasses almost all discretionary permission checks entirely, by design. This is not a bug in the model — root is deliberately positioned outside the discretionary system, which is precisely why the drift toward capability-based fine-grained privilege (covered in Chapter 8) exists: to let systems function without needing that total bypass for every privileged operation.

---

## 4. The Permission Triad: Owner, Group, Other

Every regular Unix file or directory carries exactly nine permission bits, arranged as three sets of three:

```
   Owner      Group      Other
  r  w  x    r  w  x    r  w  x
```

Each set answers the same access question — read, write, execute — but for a different relationship between the requesting process and the file:

- **Owner (user)** — the UID that matches the file's stored owner UID.
- **Group** — a process whose GID (or one of its supplementary GIDs) matches the file's stored group GID, and who is not the owner.
- **Other** — everyone else: any process whose UID and GID set do not match either of the above.

### 4.1 The Kernel's Actual Decision Order

This is a detail glossed over in most introductory material, and it has real consequences. The kernel does not check all three sets and take the most permissive result. It checks them in a strict, short-circuiting order, and the *first matching category wins* — even if a later category would have granted more access.

The algorithm, simplified, is:

```
if (process_euid == inode_uid):
    use the OWNER permission bits
    (even if they are more restrictive than group/other)
elif (process_egid in [inode_gid, supplementary GIDs]):
    use the GROUP permission bits
else:
    use the OTHER permission bits
```

The consequence that surprises people the most: **if you own a file, the owner bits are what govern your access — full stop.** If you `chmod 077 file` (no owner permissions, full group and other permissions) and you are the owner, you are locked out of your own file, even though "everyone else" on the system has full access to it. The kernel never falls through to check group or other permissions once the owner match succeeds. This is a direct consequence of the strict, ordered, first-match evaluation — not a special case or an inconsistency.

### 4.2 Supplementary Groups

A process's group identity is not limited to a single GID. Every process also carries a **supplementary group list** — additional GIDs inherited from the user's account configuration (visible via `id` or `/etc/group`) that participate in the group-matching step above. This is why a user can belong to a dozen groups simultaneously and have group-level access to files owned by any of them, not just their single "primary" group. Chapter 2 covers the full mechanics of UID/GID resolution, `/etc/passwd`, `/etc/group`, and how supplementary groups are populated into a process's credentials at login time.

---

## 5. Numeric and Symbolic Representation — A Preview

The nine permission bits are almost always displayed and manipulated in one of two equivalent forms, both of which get a full dedicated treatment in Chapter 4. Introduced briefly here so the rest of this document is legible:

**Symbolic form**, as shown by `ls -l`:

```
-rwxr-xr--
```

Read left to right: a leading character for file type (`-` for regular file, `d` for directory, `l` for symlink, and so on), followed by three permission triads for owner, group, and other respectively.

**Numeric (octal) form**, used with `chmod`:

```
754
```

Each digit is the sum of `r=4`, `w=2`, `x=1` for that triad. `7 = rwx`, `5 = r-x`, `4 = r--`. This numeric encoding is not an arbitrary convenience — it maps directly onto the actual bit layout the kernel stores in the inode's mode field, which is why `chmod 754` and `chmod u=rwx,g=rx,o=r` produce byte-for-byte identical results on disk.

---

## 6. Where Permission Bits Actually Live: The Inode Mode Field

The nine permission bits, along with the file type and three additional special bits (SUID, SGID, sticky — covered fully in Chapter 6), are packed into a single field inside the inode called the **mode**. On Linux, this is a 16-bit value, though only the lower 12 bits are relevant to permissions and special bits; the upper bits encode the file type (regular file, directory, symlink, device, socket, FIFO).

```
 15                     12 11 10  9  8  7  6  5  4  3  2  1  0
+------------------------+---+---+---+------+------+------+
|      file type (4)     |SUID|SGID|STK|rwx-owner|rwx-grp|rwx-other|
+------------------------+---+---+---+------+------+------+
```

This is why every `stat()` system call returns a single `st_mode` field that simultaneously tells you both "this is a directory" and "owner can read/write/execute" — they are the same 16-bit integer, just different bit ranges within it. Tools like `stat` and `ls` decode this one field into the human-readable strings you're used to seeing; the kernel itself only ever manipulates the raw integer.

---

## 7. Process Credentials: Why There Are Four Kinds of UID

Section 2.1 listed four UID fields carried by every process: real, effective, saved, and filesystem. Introducing *why* each one exists belongs here, in the foundational chapter, because every later discussion of SUID binaries, privilege dropping, and daemon security assumes you already have this model.

- **Real UID (`uid`)** — identifies who actually launched the process. This does not change across `exec()` calls and is what tools like `ps` show as the process owner in the "real" sense — it answers "who is accountable for this process existing."

- **Effective UID (`euid`)** — the identity actually used for permission checks against files and most other kernel objects. In the overwhelming majority of processes, `uid == euid`, and the distinction is invisible. The distinction becomes critical the moment a SUID binary is executed: the real UID stays as the invoking user, but the effective UID becomes the file owner's UID for the duration of execution, granting temporary elevated access. This single mechanism is the entire basis of how `passwd`, `sudo`, `ping`, and similar tools historically granted ordinary users controlled access to operations they otherwise couldn't perform.

- **Saved UID (`suid`)** — a "memory" of what the effective UID was immediately after `exec()`, allowing a process that has voluntarily dropped privileges (lowered its effective UID) to later restore them, without needing to re-invoke a SUID binary. This exists specifically to support software that needs to toggle between privileged and unprivileged states multiple times during its own lifetime, rather than permanently discarding privilege the first time it drops it.

- **Filesystem UID (`fsuid`)** — a Linux-specific addition, not present in classic Unix, used exclusively for filesystem access checks, decoupled from the UID used for signal-sending and other process-level permission checks. It exists to close a narrow but real security gap for privileged server processes (historically, NFS servers) that need to perform filesystem operations on behalf of a client identity without becoming fully vulnerable to that client sending them a signal.

The GID side of the credential structure mirrors this exact same four-way split for group identity, for the same underlying reasons.

This four-field structure is not incidental complexity — it is the direct mechanism that makes controlled, temporary privilege elevation possible without requiring every privileged operation to run as full root for its entire lifetime. Chapter 6 returns to this in detail when covering SUID and SGID executable bits specifically.

---

## 8. What This Series Covers, and the Order It Builds In

This introduction establishes the vocabulary and mental model; the chapters that follow build outward from it in a deliberate order, each depending on the ones before it:

- **Chapter 2** goes deep on UID/GID resolution, identity storage in `/etc/passwd` and `/etc/group`, how login populates a process's credential set, and the difference between primary and supplementary groups in practice.
- **Chapter 3** covers file and directory permission semantics in much greater operational depth than this introduction, including edge cases around symlinks, special files, and mount-level restrictions.
- **Chapter 4** is a complete reference on symbolic and numeric mode manipulation, covering every `chmod` syntax form and the subtleties of relative versus absolute mode changes.
- **Chapter 5** examines `umask`, default permission computation, and how it interacts with process inheritance and `setuid` daemons.
- **Chapter 6** is a full treatment of SUID, SGID, and the sticky bit — the three special permission bits only briefly mentioned here.
- **Chapter 7** introduces POSIX Access Control Lists, the mechanism that breaks past the fundamental three-actor limitation of the traditional model.
- **Chapter 8** covers extended attributes and Linux capabilities, the modern replacement for "all-or-nothing root" privilege escalation.
- **Chapter 9** is a dedicated security and hardening chapter, examining real-world misconfiguration patterns and their exploitation.
- **Chapter 10** closes the series with troubleshooting methodology and real-world diagnostic scenarios, applying everything from the previous nine chapters to actual incidents.

---

## 9. Common Misconceptions Worth Retiring Now

A short list of beliefs that feel intuitive but are incorrect, each of which this chapter has already implicitly corrected — collected here as a explicit checkpoint before moving forward:

- **"Permissions are checked continuously while a file is open."** They are checked at the moment of the access system call (notably `open()`), not continuously. A process can retain access to an already-open file descriptor even after permissions change.
- **"File permissions control whether a file can be deleted."** Deletion is governed by the *parent directory's* write and execute permissions, not the file's own mode bits.
- **"If you own a file, you always have full access to it."** Ownership determines *which* permission triad applies to you — it does not guarantee that triad is permissive. Owner bits can be more restrictive than group or other bits, and the kernel will still apply them exclusively.
- **"Usernames are what the kernel checks."** The kernel operates exclusively on numeric UIDs and GIDs; usernames are a userspace-only convenience layer.
- **"Root can do literally anything, permission bits included, because it's a special case of DAC."** More precisely: root operates largely *outside* DAC checks rather than winning them, which is a distinction that becomes important once capabilities (Chapter 8) start subdividing what "root" actually means into narrower, revocable privileges.

Everything from here forward assumes these five points as settled, correct background. The next chapter picks up directly at the identity layer — how a UID and GID are assigned to a login session in the first place, and how that identity propagates into every process spawned from it.
