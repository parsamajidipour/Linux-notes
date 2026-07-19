# Extended Attributes and Capabilities

Chapter 7 closed by flagging two related but distinct topics deferred to this chapter: extended attributes, a general-purpose metadata mechanism sitting entirely outside the permission-bit and ACL model, and Linux capabilities, the fine-grained privilege-decomposition system previewed back in Chapter 6 as the modern alternative to coarse-grained SUID-root. This chapter covers both in full, because they are conceptually related — capabilities are, on modern Linux, frequently implemented and stored *as* a specific kind of extended attribute — but they solve genuinely different problems and deserve to be understood as two distinct mechanisms that happen to share underlying storage infrastructure.

---

## 1. Extended Attributes: A General-Purpose Metadata Layer

### 1.1 The Structural Gap Extended Attributes Fill

Every metadata field covered so far in this series — permission bits, ownership, the special bits, ACL entries — has a fixed, purpose-built home in the filesystem's inode structure or, for ACLs, a dedicated inode extension mechanism. But filesystems and the software that uses them routinely need to attach *other* kinds of metadata to files that have nothing to do with access control at all: a MIME type a desktop file manager wants to remember without re-detecting it every time, a checksum, a note about where a file originated, an SELinux security label (Chapter 9 territory), or, as this chapter will cover, an encoded capability set.

Rather than the kernel needing to grow a new, dedicated inode field for every conceivable future metadata need — an approach that doesn't scale, since inode structures are fixed-size and every new field permanently costs space on every single inode on the filesystem whether it's used or not — Linux provides **extended attributes (xattrs)**: an open-ended, arbitrary key-value store attached to each inode, alongside its traditional fields, that any program can read from or write to, subject to its own permission rules (covered in Section 1.4).

### 1.2 The Namespace Structure

Extended attribute names are not arbitrary free-form strings — they are namespaced, with the namespace prefix determining both the attribute's intended purpose and, critically, who is permitted to read or write it. The four standard namespaces:

| Namespace | Purpose | Access rules |
|---|---|---|
| `user.` | Arbitrary attributes set by ordinary user-space programs and users | Governed by ordinary file permission bits — if you can write the file, you can generally set `user.` attributes on it |
| `trusted.` | System-level metadata not meant for exposure to unprivileged processes | Requires `CAP_SYS_ADMIN` (Section 2 covers capabilities in full) — effectively root-only |
| `security.` | Used by kernel security modules — SELinux labels, POSIX capabilities (Section 2.4), and similar | Access governed by the specific security module in question, generally requiring elevated privilege to modify |
| `system.` | Used by the kernel itself for things intrinsically tied to filesystem implementation, most notably ACLs (Chapter 7's `getfacl`/`setfacl` data is actually stored as `system.posix_acl_access` and `system.posix_acl_default` xattrs under the hood) | Kernel and filesystem-managed, not intended for arbitrary direct manipulation by ordinary tools outside the mechanisms that own them |

This namespace structure is worth understanding as directly analogous, in spirit, to the ownership and permission concepts covered throughout this entire series: just as file permission bits partition *who* can touch file content, xattr namespaces partition *who* can touch specific categories of metadata, with the more privileged namespaces reserved for genuinely security-sensitive or kernel-managed data that ordinary user-space write access to a file's content should not automatically imply write access to.

It's worth explicitly connecting this back to Chapter 7's revelation: ACL data isn't stored in some entirely separate, ACL-specific structure conceptually distinct from everything else in this chapter — it is, mechanically, extended attribute data in the `system.` namespace, using the general-purpose xattr storage infrastructure this chapter describes. This is a genuinely useful unification to hold in mind: ACLs are not a structurally separate mechanism from extended attributes, but rather one specific, kernel-privileged *consumer* of the more general xattr mechanism this chapter introduces in its own right.

### 1.3 Setting and Reading Extended Attributes

```
$ setfattr -n user.comment -v "reviewed by parsa on 2026-07-19" file.txt
$ getfattr -n user.comment file.txt
# file: file.txt
user.comment="reviewed by parsa on 2026-07-19"
```

```
$ getfattr -d file.txt
# file: file.txt
user.comment="reviewed by parsa on 2026-07-19"
```

The `-d` flag to `getfattr` dumps every attribute the caller has permission to see, across whichever namespaces are readable — a useful first step when inspecting an unfamiliar file for any non-obvious metadata that might not be visible through `ls -l` or `getfacl` alone, since, as established, both permission bits and ACL data are visible through their own dedicated tools, but arbitrary `user.` or other-namespace attributes require `getfattr` specifically to discover at all.

### 1.4 Extended Attributes and Access Control: A Genuinely Subtle Point

This is worth stating precisely because it is easy to reason about incorrectly by analogy with file content: **write access to a file's `user.`-namespace extended attributes is governed by write permission on the file itself, per the traditional model from earlier chapters — but this is a Linux-specific convention, not a universal, filesystem-independent guarantee, and it means xattr write access piggybacks on, rather than being independently configurable from, the file's own content-write permission for the `user.` namespace specifically.** This matters practically because it means a file's `user.`-namespace attributes offer no independent confidentiality or integrity guarantee beyond whatever the file's own permission bits (or ACL, if present, per Chapter 7) already provide — anyone who can write the file's content can, in the ordinary case, also write its `user.` attributes, and anyone who can read it can generally read them.

### 1.5 A Practical Use Beyond Metadata Curiosity: Immutability

One extended-attribute-adjacent mechanism worth specific mention, because it genuinely interacts with and can override everything this series has covered about permission-based access control, is the **immutable flag**, set not via `setfattr` directly but via the related `chattr` tool (and inspected via `lsattr`):

```
$ chattr +i important_file.txt
```

The immutable attribute, once set, prevents the file from being modified, deleted, renamed, or linked to **by anyone, including root operating through ordinary file operations** — a genuinely different, stronger guarantee than anything the permission-bit or ACL model can express, precisely because it sits at a layer beneath and independent of the ordinary DAC permission-check algorithm this entire series has otherwise centered on. Removing the immutable flag itself requires the `CAP_LINUX_IMMUTABLE` capability (Section 2 covers the capability mechanism generally), which on a standard, non-hardened system, root effectively always holds — meaning immutability is best understood as raising the bar from "any process with appropriate DAC permission" to "specifically a process capable of first clearing this flag," rather than as an absolute, unconditional guarantee independent of privilege entirely. It is nonetheless a genuinely useful, meaningfully different layer of protection worth knowing about specifically because it is the first mechanism in this entire series that operates *underneath* rather than *within* the ordinary permission-check algorithm formalized back in Chapter 3.

---

## 2. Linux Capabilities: Decomposing Root

### 2.1 The Problem, Restated Precisely From Chapter 6

Chapter 6, Section 2.4 introduced the motivating problem this section now resolves in full: SUID's effective-UID-substitution mechanism grants a process the *entire* privilege set associated with root — every single one of root's abilities, all at once, for the process's whole execution — even when the actual task at hand needs only one narrow slice of that broad privilege, like binding to a low-numbered network port. This all-or-nothing granularity is a genuine security liability, because it means the "blast radius" of any exploitable flaw in a SUID-root program is the *entire* scope of what root can do on the system, regardless of how narrow the program's actual legitimate purpose is.

Linux capabilities are the kernel's direct answer: **root's traditionally undifferentiated privilege is decomposed into a large number of individually named, individually grantable, individually revocable units**, each governing one specific category of privileged operation. A process, or an executable file, can be granted exactly the specific capabilities it actually needs — and no others — rather than the effective-UID-based all-or-nothing substitution SUID relies on.

### 2.2 A Representative Sample of Capabilities

The full list numbers several dozen and continues to grow across kernel versions as new privileged operations are identified as worth decomposing; a representative sample, chosen specifically to illustrate the range and precision of the model, rather than as an exhaustive reference:

| Capability | Grants |
|---|---|
| `CAP_NET_BIND_SERVICE` | Bind to network ports below 1024, historically a root-only operation |
| `CAP_NET_RAW` | Use raw and packet sockets — needed by tools like `ping` for constructing raw ICMP packets |
| `CAP_CHOWN` | Bypass the ordinary restriction (Chapter 2, Section 6.2) that changing file ownership is root-only |
| `CAP_DAC_OVERRIDE` | Bypass file read/write/execute permission checks entirely — the closest single capability to "traditional root" for file-access purposes specifically |
| `CAP_DAC_READ_SEARCH` | Bypass file *read* and directory *search* permission checks specifically, without the broader write-bypass `CAP_DAC_OVERRIDE` grants |
| `CAP_SYS_ADMIN` | A notably broad, catch-all capability covering numerous administrative operations that haven't been granted their own dedicated, narrower capability — worth flagging specifically as the capability most similar in spirit to "still basically root" due to its breadth, and therefore a specific point of caution when auditing capability grants |
| `CAP_LINUX_IMMUTABLE` | Set or clear the immutable and append-only file attributes introduced in Section 1.5 |
| `CAP_SETUID` / `CAP_SETGID` | Change a process's own UID/GID — needed by any program that legitimately performs the privilege-dropping sequence described back in Chapter 2, Section 5.2 |
| `CAP_KILL` | Send signals to processes owned by other users, bypassing the ordinary same-UID-or-privileged restriction |

Reading through even this partial list should make the connection to earlier chapters concrete: `CAP_DAC_OVERRIDE` is, precisely, the kernel-level mechanism referenced back in Chapter 3's formalized decision algorithm as the "capability short-circuit" step that can bypass the entire owner/group/other evaluation sequence — this chapter is where that forward reference gets its full, named explanation.

### 2.3 The Per-Process Capability Sets

Mirroring the four-UID structure Chapter 2 detailed for user identity, a process's capability state is not a single flat set but several distinct sets, each serving a specific role in how capabilities can be gained, retained, or passed down through `exec()`:

| Set | Role |
|---|---|
| **Permitted** | The maximum set of capabilities the process is allowed to hold — a ceiling it cannot exceed regardless of what it might otherwise attempt to add to its effective set |
| **Effective** | The subset of the permitted set the kernel is *actually enforcing* checks against right now — directly analogous to the effective-UID concept from Chapter 2, in that a capability can be held in permitted but temporarily not active in effective, similar to how a saved UID can exist without being the currently active effective UID |
| **Inheritable** | The subset of capabilities that survive across an `exec()` call into a new program image, rather than being dropped — relevant specifically to how capabilities propagate through the same fork/exec process-creation model Chapter 2 described for ordinary credentials |
| **Ambient** (a more recent addition to the model) | Capabilities that propagate to child processes across `exec()` even for programs that are not themselves capability-aware, addressing practical difficulties the plain inheritable-set model had with ordinary, capability-unaware software in a process chain |

This layered structure exists for reasons directly parallel to Chapter 2's real/effective/saved UID structure — it allows a process to legitimately hold a broader *permitted* privilege ceiling while operating, most of the time, with a narrower *effective* set actually in force, activating specific capabilities only for the specific moments they're genuinely needed, and dropping them again afterward, a pattern of least-privilege operation the flat, single-value SUID effective-UID model from Chapter 6 has no equivalent mechanism for at all.

### 2.4 File Capabilities: The Modern Alternative to SUID

The specific mechanism that lets an *executable file* grant capabilities to whatever process runs it — directly analogous in purpose to SUID from Chapter 6, but operating through the fine-grained capability model instead of the coarse effective-UID substitution — is called a **file capability**, stored, precisely as Section 1.2 flagged, as a `security.capability` extended attribute on the file's inode.

```
$ setcap 'cap_net_bind_service=+ep' /usr/local/bin/mycustomserver
```

This grants the specific `CAP_NET_BIND_SERVICE` capability to any process that executes this specific binary — enough to bind to a privileged low-numbered port, and nothing more — without requiring the binary to be SUID-root, without granting it `CAP_DAC_OVERRIDE`, without granting it the ability to change ownership, kill other users' processes, or exercise any of root's dozens of other traditional abilities. This is the concrete, practical realization of Chapter 6's forward-looking claim that capabilities let a program request "only the narrow ability it needs" — here it is, expressed as an actual, runnable command, directly comparable to the `chmod 4755` SUID-granting invocation from Chapter 6 that it is designed to replace for exactly this class of use case.

Reading back the granted capability, mirroring `getfattr`'s role for ordinary extended attributes:

```
$ getcap /usr/local/bin/mycustomserver
/usr/local/bin/mycustomserver cap_net_bind_service=ep
```

### 2.5 Why File Capabilities Are the Preferred Modern Approach

It's worth drawing the direct comparison explicitly, because the security case for preferring file capabilities over SUID-root, wherever the capability model already supports the specific narrow privilege a program needs, is genuinely strong and directly traceable to everything Chapter 6 established about SUID's risk profile:

| Property | SUID-root (Chapter 6) | File capabilities |
|---|---|---|
| Privilege granularity | All of root's privilege, undifferentiated | One or a few specifically named capabilities |
| Blast radius of an exploitable flaw | Full root compromise | Limited to whatever narrow capability set was actually granted |
| Auditability | "Is this binary SUID-root, yes or no" — coarse | "Exactly which capabilities does this binary hold" — precise, per-capability |
| Applicable to non-executable identity elevation needs | No — SUID only affects process identity via `execve()` | Also no, for the same reason — but capabilities can additionally be granted directly to a running process's permitted/effective sets by a sufficiently privileged parent, without requiring a SUID-style file-based grant at all, a flexibility SUID structurally lacks |

This table's message is worth stating as a clear, actionable principle for anyone configuring or auditing privileged software on a modern system: **whenever a program's actual privileged need maps onto one or a small number of well-defined capabilities, file capabilities are the more secure, more auditable, and generally preferred mechanism over SUID-root** — and the continued presence of a SUID-root binary on a modern, well-maintained system, where a narrower capability-based alternative would suffice, is a legitimate, concrete finding in the kind of security audit Chapter 6 previewed and Chapter 9 will formalize.

---

## 3. Interaction With Earlier Chapters' Material

### 3.1 Capabilities and the Chapter 3 Decision Algorithm

Chapter 3's formalized `check_access()` algorithm included a "Step 0" capability short-circuit, deferred to this chapter for full explanation — it can now be stated precisely: before the ordinary owner/group/other evaluation sequence runs at all, the kernel checks whether the requesting process's *effective* capability set (Section 2.3) includes a capability that unconditionally covers the requested operation. `CAP_DAC_OVERRIDE`, held effectively, bypasses essentially the entire read/write permission-check sequence outright; `CAP_DAC_READ_SEARCH` does the same specifically for read and directory-search operations. This is the exact, complete mechanism by which "root can just ignore file permissions" — a fact every earlier chapter has referenced informally — is actually implemented at the kernel level: not as some separate, special-cased "if UID == 0" branch, but as an ordinary capability check, with root's UID-0 identity conventionally (via the permitted-set defaults processes acquire) holding the relevant capabilities, rather than the bypass being wired directly to the UID value itself.

### 3.2 Capabilities and SUID/SGID's Numeric Mode Digit

Chapter 6 covered the SUID and SGID bits as part of the traditional twelve-bit mode field, entirely independent of, and predating, the capability system covered in this chapter. It's worth being precise that these remain two genuinely separate mechanisms occupying separate storage — SUID/SGID live in the traditional mode field bits, while file capabilities live in the `security.capability` extended attribute, per Section 2.4 — and a single binary can, in principle, carry both simultaneously, though doing so is unusual and, given the entire point of this chapter's material, generally counter to the least-privilege reasoning that motivates choosing capabilities over SUID in the first place; a binary that both retains SUID-root *and* has specific file capabilities set has not actually reduced its blast radius at all, since SUID-root alone already grants everything the additional capabilities would.

### 3.3 Capabilities as the Modern Home for `passwd`-Style Problems

Revisiting Chapter 6's canonical motivating example directly: while `passwd` on most systems remains, historically, a SUID-root binary rather than having been migrated to a narrower capability-based grant, the underlying operation it needs — writing to `/etc/shadow` — doesn't map cleanly onto any single narrow standard capability the way network port binding does onto `CAP_NET_BIND_SERVICE`, which is a useful, honest illustration of a genuine limitation in the capability decomposition project: not every privileged operation has been, or necessarily can be, cleanly carved into a sufficiently narrow, individually-meaningful capability, and SUID-root, despite its coarser grain, remains a legitimate, still-necessary mechanism for operations that genuinely don't decompose well — a nuance worth holding onto rather than concluding capabilities have made SUID entirely obsolete across the board.

---

## 4. Practical Diagnostics

### 4.1 Auditing File Capabilities System-Wide

Directly parallel to Chapter 6's SUID/SGID discovery command, the equivalent audit for file capabilities:

```
getcap -r / 2>/dev/null
```

This recursively scans the filesystem for any file carrying a `security.capability` extended attribute, producing a complete inventory directly comparable in security-auditing purpose to Chapter 6's `find -perm -4000` command — both answer the same underlying question ("what on this system has been granted privilege beyond what its owning identity alone would provide") through the two different mechanisms this series has now covered in full, and a thorough audit, per Chapter 9, checks both.

### 4.2 Inspecting a Running Process's Capability Sets

```
$ grep Cap /proc/<pid>/status
CapInh: 0000000000000000
CapPrm: 0000000000003000
CapEff: 0000000000003000
CapBnd: 0000003fffffffff
CapAmb: 0000000000000000
```

Each line corresponds directly to one of the four (plus a fifth, the **bounding set** — an additional ceiling on the permitted set across the process's entire lifetime, not covered in Section 2.3's introductory table but worth mentioning here as the value shown on the `CapBnd` line) sets described in Section 2.3, displayed as a hexadecimal bitmask where each bit position corresponds to one specific named capability — a raw, low-level view worth knowing about specifically for the cases where `getcap`'s file-level view isn't sufficient and the actual, currently-active privilege state of a live process needs direct inspection.

---

## 5. Common Misconceptions Worth Retiring Now

- **"Extended attributes are the same thing as ACLs."** ACLs are one specific consumer of the more general extended-attribute storage mechanism (stored in the `system.` namespace); the `user.`, `trusted.`, and `security.` namespaces serve entirely different, unrelated purposes, including but not limited to capability storage, covered in this same chapter.
- **"root can always override the immutable flag through ordinary file operations."** It cannot, by design — the immutable flag operates beneath the ordinary permission-check layer entirely, and requires a process to specifically hold `CAP_LINUX_IMMUTABLE` and deliberately clear the flag first, rather than being overridable through any ordinary read/write/delete attempt regardless of privilege level.
- **"Capabilities replace SUID entirely; SUID is obsolete."** Capabilities are the preferred mechanism wherever a narrow, well-defined capability maps onto the actual need, but some genuinely privileged operations (Section 3.3's `passwd` example) don't decompose cleanly onto existing named capabilities, meaning SUID remains a legitimate, still-used mechanism in specific, real cases.
- **"A capability held in a process's permitted set is automatically being enforced/active."** It is not — only the *effective* set is actually consulted during privilege checks; permitted merely establishes the ceiling of what could be activated, mirroring the same real-versus-effective distinction Chapter 2 established for UIDs.
- **"`CAP_DAC_OVERRIDE` and traditional root (UID 0) are two entirely separate, unrelated privilege mechanisms."** They are deeply connected in practice — root's traditional permission-bypassing behavior, referenced informally throughout this entire series, is *implemented* via this and related capabilities being present in root's default permitted/effective sets, not via some separate UID-0-specific kernel code path.

---

The next chapter turns from mechanism to consequence: a dedicated security and hardening treatment that draws directly on every mechanism this series has covered — DAC's discretionary trust model from Chapter 1, the ownership and UID-reuse risks from Chapter 2, the directory-versus-file distinctions from Chapter 3, the recursive `chmod` and symlink hazards from Chapter 4, the SGID/umask collaboration pitfalls from Chapters 5 and 6, and the SUID/capability audit techniques previewed in this chapter and the last — assembled into a coherent, actionable hardening and misconfiguration-detection methodology.
