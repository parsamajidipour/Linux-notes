# Ownership, UID, GID, and Identity

Chapter 1 established that the kernel never checks a username — it checks numbers. This chapter goes underneath that statement and answers the question it immediately raises: where do those numbers come from, how do they get attached to a running process, and what actually happens, mechanically, between the moment you type a username at a login prompt and the moment a `struct cred` with populated UID and GID fields is sitting inside a running shell. Ownership — the `chown`/`chgrp` side of the picture — is the second half of this chapter, because ownership is simply the inverse operation: attaching those same numeric identities to a file instead of a process.

Everything in this chapter is prerequisite knowledge for Chapter 3 onward. Permission bits are meaningless without a correct model of what identity actually is on a Linux system, and "identity" turns out to be a far more layered, negotiated, and occasionally fragile concept than the simple `whoami` output suggests.

---

## 1. Identity Is a Resolved Artifact, Not a Stored Fact

The single most important reframing this chapter offers is this: **a username is not stored anywhere as an authoritative identity.** What is stored, authoritatively, is a number. The username is a *label* that a resolution process — historically a flat-file lookup, now potentially a directory service query — maps onto that number, on demand, every single time a human-readable name is needed.

This might sound like a pedantic distinction, but it has direct, practical consequences that show up constantly in real system administration:

- Delete a user's entry from `/etc/passwd` while their files remain on disk, and `ls -l` will print a raw UID instead of a name. The files did not lose their owner — the *label* for that owner simply stopped resolving.
- Two systems that assign the same UID to two *different* human users (a common mistake in unsynchronized user provisioning across machines, or in container images built independently) will silently treat files as belonging to "the same person," because the kernel has no concept of a person — only of a number.
- NFS, one of the oldest network filesystem protocols still in wide use, transmits raw UID/GID numbers over the wire with no username information at all, which is why UID/GID synchronization between NFS client and server has historically been such a persistent operational headache — the protocol was built entirely around the kernel's own numeric model, with no accommodation for the human-facing label layer.

Holding this framing firmly in mind — number is truth, name is a view — makes the rest of this chapter's mechanics much easier to reason about.

---

## 2. `/etc/passwd`: The Canonical Local Identity Database

On any Linux system without a network directory service, `/etc/passwd` is the authoritative source that maps usernames to UIDs, and it is worth understanding its structure precisely rather than approximately, because several fields carry implications for the permission model.

A typical line looks like this:

```
parsa:x:1000:1000:Parsa Majidipour,,,:/home/parsa:/bin/bash
```

Each colon-separated field carries specific meaning:

| Field | Name | Meaning |
|---|---|---|
| 1 | Username | The human-readable login name |
| 2 | Password placeholder | Historically the hashed password; on modern systems always `x`, signaling the real hash lives in `/etc/shadow` |
| 3 | UID | The numeric user ID — the actual value the kernel uses |
| 4 | GID | The numeric ID of this user's **primary group** |
| 5 | GECOS | Free-form comment field, historically used for full name, office, phone extension |
| 6 | Home directory | Where the user's session starts, and where `$HOME` is set from |
| 7 | Login shell | The program executed after successful authentication |

Field 3, the UID, is the entire identity as far as the kernel is concerned. Everything else in this line — including the username itself in field 1 — exists purely for the convenience of userspace tools and humans.

### 2.1 Why the Password Hash Moved to `/etc/shadow`

This is worth a brief digression because it is directly relevant to a permission concept covered in Chapter 1: `/etc/passwd` must be world-readable, because an enormous number of unprivileged programs need to resolve UIDs to usernames constantly (`ls`, `ps`, `id`, and effectively every program that prints ownership information). A world-readable file containing password hashes is a severe security liability — early Unix systems that stored hashes directly in `/etc/passwd` were trivially vulnerable to offline dictionary attacks by any local user who could simply read the file.

The fix, introduced as "shadow passwords," split the file in two: `/etc/passwd` keeps everything that legitimately needs to be world-readable, and `/etc/shadow` — restricted to root-only read access, mode `640` or stricter, owned by root with group `shadow` on many distributions — holds the actual hash and the password aging metadata. This split is itself a clean illustration of the permission model from Chapter 1 being applied deliberately: the *sensitivity* of a piece of data determines which file it belongs in, because file-level permission granularity is the only lever available to control who can read it.

### 2.2 System UIDs vs. Regular User UIDs

Not all UIDs are created equal in intent, even though the kernel treats every number identically. Distributions reserve numeric ranges by convention, not by kernel enforcement:

```
0            → root, always
1–999        → system accounts (daemons, service accounts) on most modern distros
   (older distros historically used 1–99 or 1–499 for this range)
1000+        → regular human user accounts, starting point set by /etc/login.defs
65534        → conventionally "nobody" — an intentionally unprivileged, unowned identity
```

These ranges are pure convention, enforced by tools like `useradd` reading `/etc/login.defs` (`UID_MIN`, `UID_MAX`, `SYS_UID_MIN`, `SYS_UID_MAX`), not by the kernel. Nothing stops an administrator from manually assigning UID 50000 to a system daemon — it would function identically. The convention exists purely to keep human-managed accounts and package-managed service accounts from colliding, and to make range-based auditing possible (e.g., "flag any process running with UID under 1000 that isn't a known system service").

The `nobody` account deserves specific mention because it recurs throughout later chapters, particularly the security-hardening chapter. It exists as a deliberately privilege-less identity: a UID that owns nothing, belongs to no meaningful group, and is used as the "safe" identity to drop into when a process's actual required identity is irrelevant or when a completely unprivileged sandbox identity is needed — for instance, NFS historically mapped root requests from remote clients onto `nobody` specifically to prevent a remote root from acting as local root, a technique called **root squashing**, covered in more depth in Chapter 9.

---

## 3. `/etc/group`: Group Identity and the Primary/Supplementary Split

Chapter 1 introduced the fact that a process's group identity is not a single value but a *set* — a primary GID plus a list of supplementary GIDs. This section covers exactly how that set gets constructed.

### 3.1 The `/etc/group` File Format

```
sudo:x:27:parsa,ali
docker:x:999:parsa
developers:x:1002:parsa,sara,ali
```

Fields, again colon-separated:

| Field | Name | Meaning |
|---|---|---|
| 1 | Group name | Human-readable label |
| 2 | Password placeholder | Almost always unused (`x`), group passwords are a largely obsolete feature |
| 3 | GID | Numeric group identity |
| 4 | Member list | Comma-separated usernames who belong to this group **as a supplementary group** |

Notice something important here: this file's member list does *not* include users whose **primary** group is this GID. Primary group membership is recorded exclusively in field 4 of `/etc/passwd` (the GID field), not here. A user whose primary group is `developers` (GID 1002 in the example above) will not appear in the member list unless they *also* have it listed as a supplementary membership — which would be redundant and is not how the tools populate it.

This split between primary and supplementary membership is one of the more commonly misunderstood aspects of the identity model, so it is worth stating as an explicit rule:

> **A user's full effective group set at any moment is: (1) their single primary GID, sourced from `/etc/passwd`, plus (2) every GID for which their username appears in that group's member list in `/etc/group`.**

Both of these sources are consulted together to build the final supplementary group list a process actually carries, via a mechanism covered in detail in Section 5.

### 3.2 Why Primary Group Exists as a Distinct Concept

A reasonable question: if a user can belong to arbitrarily many supplementary groups, why does the primary group concept need to exist at all — why not just have one flat set?

The primary group serves a specific, narrow purpose that supplementary groups do not: it is the group identity used **by default when new files are created**, absent any other override (such as a directory's SGID bit, covered fully in Chapter 6). When a process calls `creat()` or `open()` with the `O_CREAT` flag, the kernel needs *one* GID to stamp onto the new inode's group-ownership field — it cannot stamp all of a user's supplementary groups simultaneously, because an inode has exactly one owning group. The primary GID is the answer to "which one." This is why historically, before the widespread adoption of "user private groups" (Section 3.3), administrators had to think carefully about what a user's primary group should be — it directly determined the default sharing behavior of every file they created.

### 3.3 User Private Groups

Most modern distributions follow a convention called **user private groups (UPG)**: every user gets their own dedicated primary group, named identically to their username, with no other members. `parsa` gets primary group `parsa` (GID 1000, matching UID 1000, though this parity is convention, not a requirement), and nobody else is ever added to it.

The reasoning behind this convention connects directly back to the default-ownership behavior from Section 3.2. Under the older convention — where many users shared a single broad primary group like `users` — every file any user created by default had its group-read/write bits potentially exposing it to every other user in that shared group, unless the creator remembered to `chmod` it down manually. UPG flips the default to maximally private: since a user's private group has no other members, files they create are, by default, group-accessible to no one but themselves, and *deliberate* sharing happens by explicitly setting group ownership to a real, multi-member collaboration group (like `developers` in the example above) — an active choice rather than an accidental default.

---

## 4. Beyond Flat Files: The Name Service Switch

Everything above describes identity resolution on a standalone machine using flat files. Production environments — especially anything centrally managed across many machines — very often source identity from elsewhere: LDAP directories, Active Directory via Winbind or SSSD, NIS (still occasionally found in older environments), or cloud-provider identity services. The mechanism that makes this pluggable without requiring every single program on the system to know about every possible identity backend is called the **Name Service Switch (NSS)**, configured through `/etc/nsswitch.conf`.

A relevant excerpt:

```
passwd:         files sss
group:          files sss
shadow:         files sss
```

This tells the C library's identity-resolution functions (`getpwnam()`, `getpwuid()`, `getgrnam()`, `getgrgid()`, and their friends) to check local flat files first, then fall through to SSSD (System Security Services Daemon) if the entry isn't found locally — SSSD in turn might be backed by LDAP, Active Directory, or another directory service entirely.

The critical point for this chapter's purposes: **regardless of backend, the end result the kernel receives is always the same — a plain numeric UID and GID.** LDAP might store rich identity attributes, group hierarchies, and organizational metadata, but by the time a login session actually spawns a process, all of that richness has been flattened down to the exact same `struct cred` numeric fields described in Chapter 1. This is precisely why identity backend choice is, from the kernel's perspective, completely invisible — the permission model doesn't change one bit whether identity came from `/etc/passwd` or a corporate Active Directory forest three network hops away. It only ever sees numbers.

This also explains a genuinely dangerous class of misconfiguration worth flagging here and returning to in Chapter 9: if NSS is misconfigured or a directory service becomes unreachable during a critical resolution (for instance, during boot, before network connectivity is established), lookups can silently fail or fall back in unexpected ways, sometimes resulting in numeric UIDs being displayed raw, or — in poorly written software that doesn't handle resolution failure defensively — identity checks being skipped or defaulted incorrectly. Systems relying on network-backed identity resolution for security-critical paths need to account for resolution failure as a first-class case, not an edge case.

---

## 5. From Login Prompt to Running Shell: How Credentials Actually Get Attached

This section walks the full mechanical sequence, because understanding *when* each credential field gets populated — and by which specific piece of software — is what makes later material on SUID, privilege dropping, and daemon security actually click instead of feeling like memorized trivia.

### 5.1 Authentication via PAM

Modern Linux authentication is mediated by **PAM (Pluggable Authentication Modules)**, a framework that decouples "how do we verify this person is who they claim to be" from the specific program doing the asking (login prompt, `sudo`, `ssh`, a graphical display manager, and so on all delegate to PAM rather than implementing authentication logic themselves).

PAM's job, for our purposes, ends at authentication and *session setup* — it verifies a password (or other factor) against whatever backend `/etc/pam.d/` configures, and it invokes session modules that perform setup work like mounting a home directory, setting resource limits, or writing to `/var/log/lastlog`. PAM itself does not directly set the numeric UID/GID on the eventual shell process — that happens slightly later, in the specific program managing the login session (`login`, `sshd`, `su`, `sudo`, or a display manager), once PAM reports success.

### 5.2 UID/GID Assignment and `initgroups()`

Once authentication succeeds, the session-managing program looks up the authenticated username via `getpwnam()`, retrieving the UID and primary GID from `/etc/passwd` (or whatever NSS backend resolves it). It then needs to populate the *full* supplementary group list — not just the primary GID — before dropping into the target identity. This is the job of a specific, deliberately named library call: **`initgroups()`**.

`initgroups()` scans `/etc/group` (or the equivalent NSS-backed source) for every group containing the target username in its member list, and constructs the full supplementary GID array from that scan. This is the exact mechanism that turns the flat-file relationships described in Section 3.1 into the actual in-kernel supplementary group list a process will carry.

The sequence of system calls that actually applies these credentials to the process, in the conventional order, is:

```
initgroups(username, primary_gid)   // populate supplementary group list
setgid(primary_gid)                 // set the real/effective GID
setuid(uid)                         // set the real/effective UID — done LAST
```

The ordering here is not arbitrary, and it is worth understanding *why* `setuid()` must come last, because getting this order wrong is a classic, security-relevant privilege-dropping bug that has appeared in real-world CVEs across various pieces of software over the years. `setgid()` and `initgroups()` both typically require elevated privilege to execute (an unprivileged process cannot arbitrarily change its own GID or populate an arbitrary supplementary group list). If a program calls `setuid()` first — dropping from root down to the unprivileged target UID — it immediately loses the privilege required to perform the subsequent `setgid()` and `initgroups()` calls, resulting in a process that has correctly dropped its UID but retains root's original group memberships, a partial, inconsistent privilege drop that can leave unintended access in place. The correct order fixes group identity *while still privileged*, and only relinquishes user identity — the final, most consequential privilege — last.

### 5.3 The Shell Process Inherits, It Does Not Re-Resolve

Once the login-managing program has set these credentials and calls `exec()` to replace itself with the user's configured login shell, that shell — and every subsequent process it forks (every command run interactively, every background job, every child of a child) — simply **inherits** the credential set via the standard `fork()`/`exec()` process creation model. Credentials are not re-resolved from `/etc/passwd` on every command; they are copied down the process tree from the point of initial assignment.

This is why `su` and `sudo` exist as distinct, deliberate re-authentication and re-credentialing events — they are the specific points where a *new* credential resolution happens mid-session, rather than simple inheritance. `su - otheruser` re-runs essentially the same PAM-driven identity resolution sequence described above, for a new target user, and replaces the current shell's credentials (subject to root's ability to do so, or `otheruser`'s password if not running as root) rather than merely inheriting the invoking shell's identity.

---

## 6. Ownership: The Object Side of Identity

Everything above concerns how identity gets attached to *processes*. Ownership is the mirror concept — how identity gets attached to *files* — and it is a much shorter topic mechanically, because the machinery is simpler, but it carries its own set of deliberate restrictions worth understanding precisely.

### 6.1 What Gets Stamped at File Creation

When a new inode is created, the kernel stamps it with:

- **Owning UID** — taken from the creating process's effective UID (`euid`), *not* real UID. This distinction matters for SUID programs: if a SUID binary creates a file while its effective UID is elevated, the new file is owned by the elevated identity, not by the user who actually invoked the program.
- **Owning GID** — this one has two possible sources depending on context, and the distinction is a frequent point of confusion:
  - By default, taken from the creating process's effective GID (typically the primary GID from Section 3.2).
  - If the **parent directory** has its SGID bit set (introduced briefly in Chapter 1, covered fully in Chapter 6), the new file instead inherits the *parent directory's* group ownership, regardless of the creating process's own GID. This mechanism exists specifically to support shared collaboration directories where files should consistently belong to a project group rather than whichever individual happened to create them.

### 6.2 `chown` and `chgrp`: Who Is Allowed to Change Ownership

This is where the DAC philosophy from Chapter 1 becomes concretely asymmetric, and it is worth stating precisely because the asymmetry is deliberate security policy, not an oversight.

**Changing the owning UID of a file (`chown user file`) is restricted to the superuser on virtually all standard Linux configurations.** An ordinary, non-root user cannot give a file away to another user, even a file they themselves own. This restriction exists specifically to prevent disk quota evasion: without it, a user who has exhausted their disk quota could `chown` files to another user's identity, offloading the accounting for that storage while retaining physical possession of the data (since the file's permissions, not just its ownership, determine actual access). It also prevents a user from being able to construct a scenario where they trick another user into "owning" a maliciously crafted file, which could have implications if that other user's tooling behaves differently based on ownership assumptions.

**Changing the owning GID of a file (`chgrp group file`) is permitted for a non-root owner, but only to a group the user is themselves a member of.** This is a meaningfully more permissive rule than the UID case, and the reasoning follows directly from the DAC philosophy: since group membership is itself something the user already legitimately possesses, letting them assign their own files to a group they belong to does not grant them anything they didn't already have access to via that membership — it is a reorganization of their own resources within their own existing privilege boundary, not a privilege escalation. Assigning a file's group to a group the user does *not* belong to, however, is restricted, for symmetrical reasoning to the UID restriction: it would let a user hand off accounting or apparent grouping to a collective they have no legitimate claim to.

The kernel enforces both of these rules via the same underlying check pattern: the `chown()`/`fchown()` system call implementation verifies the caller's effective UID against the target file's current owner and the requested new owner/group, consulting the `CAP_CHOWN` capability (Chapter 8 covers Linux capabilities in full) to determine whether the unrestricted, root-level version of the operation is permitted, falling back to the restricted "only to a group I belong to" logic otherwise.

### 6.3 What Changing Ownership Does *Not* Do

A detail worth stating explicitly because it trips people up in practice: `chown` and `chgrp` change *only* the ownership metadata fields on the inode. They have zero effect on the permission bits themselves. A file that was `rwx------` (owner-only, full access) before a `chown` remains exactly `rwx------` after — the *meaning* of "owner" has changed to point at a new UID, but the bits granting owner-level access are untouched. This is occasionally the source of real security incidents: an administrator moves a sensitive file to a new owner assuming this "locks it down" to the new owner, without realizing the group and other permission bits — which were never touched by the `chown` — may still be granting broad access exactly as they did before.

---

## 7. UID/GID Reuse and the Orphaned-Ownership Problem

Because ownership is stored as a bare number with no cryptographic or otherwise unforgeable binding to a specific "real" identity, UID reuse creates a persistent, easy-to-overlook class of problem across the lifecycle of any long-running system.

Consider this sequence, which is not hypothetical — it is a documented, recurring pattern in real system administration:

1. User `alice`, UID 1005, is deleted from the system after leaving an organization. Her home directory and any files she owned elsewhere on shared storage are left in place, still tagged internally with UID 1005 — because deleting the `/etc/passwd` entry does not touch the filesystem.
2. Months later, a new employee is onboarded and provisioned a fresh account. If the provisioning tooling doesn't deliberately avoid reusing recently-freed UIDs, the new account can be assigned UID 1005 — the same number that used to mean `alice`.
3. The new user, without doing anything wrong or unusual, now silently owns every file that used to belong to `alice`, because ownership was never actually "hers" at the kernel level — it was always just the number 1005, and she is, as far as the kernel is concerned, indistinguishable from whoever holds that number now.

This is precisely why well-run identity provisioning systems maintain a **monotonically increasing UID counter that is never reused**, even after accounts are deleted, rather than recycling the lowest available free number — a practice that trades a small amount of numeric space efficiency for the elimination of an entire class of accidental privilege inheritance. Chapter 9 revisits this exact scenario as a concrete hardening checklist item, but it belongs here conceptually because it is a direct, unavoidable consequence of identity being *purely* numeric — there is no secondary, unforgeable check the kernel performs to confirm that "UID 1005" still refers to the same conceptual person it did a year ago.

---

## 8. Practical Diagnostics: Inspecting Identity From the Command Line

This section is deliberately hands-on, because the concepts above are only fully internalized once you've traced them through real tool output. Every command below maps directly onto a mechanism described earlier in this chapter.

### 8.1 `id` — The Full Credential Snapshot

```
$ id
uid=1000(parsa) gid=1000(parsa) groups=1000(parsa),27(sudo),999(docker),1002(developers)
```

This single line is a human-readable printout of essentially the entire relevant slice of a process's `struct cred`: effective UID with resolved name, effective (primary) GID with resolved name, and the full supplementary group list — exactly the set constructed by `initgroups()` during login, as described in Section 5.2.

`id` also supports inspecting a specific user without needing to be logged in as them:

```
$ id alice
uid=1005(alice) gid=1005(alice) groups=1005(alice),27(sudo)
```

This queries the identity database directly (via NSS) rather than reading any running process's live credentials — a useful distinction when diagnosing whether a *stale* login session's group memberships are out of sync with a *recently updated* `/etc/group` file, a scenario covered next.

### 8.2 `groups` — Supplementary Membership Only

```
$ groups
parsa sudo docker developers
```

A narrower view than `id`, listing only the resolved group names without UID/GID numbers or the owner/group distinction spelled out explicitly.

### 8.3 The Stale Session Trap

A scenario every Linux user eventually encounters and finds confusing without this chapter's model: an administrator adds a currently logged-in user to a new group —

```
# usermod -aG developers parsa
```

— and the user immediately tries to access a file that should now be accessible via that new group membership, only to get a permission denied error. The `/etc/group` file has, in fact, been updated correctly. The problem is Section 5.2's mechanism: `initgroups()` populates a process's supplementary group list **once, at login time**. A running shell's credentials are fixed at the moment they were assigned; they do not dynamically re-read `/etc/group` on every access attempt. The fix requires triggering a *new* credential resolution — logging out and back in, or starting a fresh session via `su - parsa` or an equivalent re-login mechanism, which reruns `initgroups()` against the now-updated group file and picks up the new membership.

### 8.4 `getent` — Querying the Resolved Identity Database Directly, Backend-Agnostic

```
$ getent passwd parsa
parsa:x:1000:1000:Parsa Majidipour,,,:/home/parsa:/bin/bash

$ getent group developers
developers:x:1002:parsa,sara,ali
```

`getent` is worth highlighting specifically because it queries through the same NSS layer described in Section 4 — it will return correct results whether the underlying source is `/etc/passwd`, LDAP, SSSD, or any other configured backend, making it the reliable diagnostic tool of choice in environments where identity is not purely local-flat-file-based, unlike directly `cat`-ing `/etc/passwd`, which only shows the local slice of the picture.

### 8.5 `stat` — Reading Raw Ownership Off an Inode

```
$ stat notes.txt
  File: notes.txt
  Size: 4096            Blocks: 8          IO Block: 4096   regular file
Device: 259,2   Inode: 1182746     Links: 1
Access: (0644/-rw-r--r--)  Uid: ( 1000/   parsa)   Gid: ( 1000/   parsa)
```

Note the parenthesized dual display on the `Uid`/`Gid` lines: the raw numeric value alongside the resolved name, printed side by side specifically because `stat` (like `ls -l`) performs exactly the `getpwuid()`/`getgrgid()` resolution step described throughout this chapter, and gracefully falls back to the bare number if resolution fails — the direct, visible confirmation of the "number is truth, name is a view" framing this chapter opened with.

---

## 9. Common Misconceptions Worth Retiring Now

- **"Deleting a user deletes their files."** It does not. Deleting an `/etc/passwd` entry removes the *label*; the underlying UID stays stamped on every inode that referenced it, now displaying as a raw number until either the files are reassigned or the UID is reused by someone else.
- **"A user's group membership updates live."** It does not, for already-running sessions. `initgroups()` runs once at login; changes to `/etc/group` only take effect for *new* sessions started after the change.
- **"Any user can give their files to anyone they like."** Only group ownership can be reassigned by a non-root owner, and only to a group they already belong to. UID ownership transfer is root-only on standard configurations.
- **"Changing a file's owner also tightens or loosens its permissions."** `chown`/`chgrp` touch only the ownership metadata fields; the permission bits themselves are completely unaffected and must be managed separately.
- **"Primary group and supplementary groups are functionally the same thing, just organized differently."** They are not interchangeable: only the primary GID is used as the default group stamp on newly created files (absent SGID inheritance), which is precisely why the user-private-group convention (Section 3.3) exists as a deliberate default-privacy mechanism.

---

The next chapter builds directly on this foundation, moving from *who* a process or file is identified as, into the full operational depth of *what* that identity is permitted to do to files and directories — covering symlink-specific edge cases, special file types, and mount-level permission restrictions that go well beyond the introductory triad-matching model from Chapter 1.
