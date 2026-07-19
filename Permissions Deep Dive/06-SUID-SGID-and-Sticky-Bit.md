# SUID, SGID, and Sticky Bit

Every previous chapter in this series has referenced the three special permission bits in passing — Chapter 1 introduced them as occupying the fourth digit of the mode field, Chapter 2 previewed SGID's role in group inheritance, Chapter 3 flagged the deletion gap the sticky bit closes, and Chapter 4 warned about the fourth numeric digit being silently zeroed. This chapter is where all of those forward references get paid off in full — the precise mechanism of each bit, why each one exists as a deliberate answer to a specific problem the base DAC model cannot otherwise solve, and the security implications that make this chapter, alongside Chapter 9, the most operationally consequential material in the series.

---

## 1. Why Special Bits Exist At All: The Problem With Pure DAC

Chapter 1 established that ordinary Discretionary Access Control evaluates a fixed triad — owner, group, other — against a fixed set of three operations — read, write, execute. This model is complete and self-consistent, but it has a structural limitation worth stating precisely: **a process's privilege, under pure DAC, is entirely and permanently determined by who invoked it.** There is no mechanism, within the base model covered through Chapter 5, for a process to *temporarily* operate with a different identity than the one that launched it — and a significant number of legitimate, everyday operations genuinely require exactly that.

Consider the canonical example, revisited throughout this chapter: changing your own login password. The password hash lives in `/etc/shadow`, which — as Chapter 2 established — must be unreadable and unwritable by ordinary users, because its exposure would be a severe security failure. Yet every ordinary user legitimately needs the ability to modify their own entry in that file when running `passwd`. Pure DAC offers no way to satisfy both requirements simultaneously: either `/etc/shadow` is writable by ordinary users (unacceptable), or ordinary users cannot run `passwd` successfully at all (unworkable).

The three special bits are the historical and modern answers to variations of this exact tension — each one a narrow, purpose-built mechanism for temporarily or contextually altering the ordinary identity-determines-privilege relationship, in a controlled, auditable way, without requiring a wholesale redesign of the base permission model.

---

## 2. SUID: Set User ID on Execution

### 2.1 The Mechanism, Precisely

When the SUID bit is set on an executable file, and that file is run via `execve()`, the kernel sets the resulting process's **effective UID** to the file's **owner UID**, rather than the invoking user's own UID — while leaving the **real UID** unchanged, tracking who actually launched the process, exactly per the four-UID model Chapter 2 established.

This is the precise mechanical answer to the `passwd` problem above: the `passwd` binary is owned by `root` and has SUID set. When an ordinary user runs it, the resulting process's real UID remains the invoking user's own UID (so the process still "knows" and can be held accountable for who launched it), but its effective UID becomes `0` — root — for the entire duration of that specific process's execution. With root's effective UID, the process can now open and write to `/etc/shadow`, per Chapter 3's permission-check algorithm, which evaluates against effective UID, not real UID. The `passwd` program's own internal logic is then responsible for restricting *what* it actually allows the now-root-privileged process to do — specifically, verifying the user's current password and only permitting them to change their own entry, not arbitrary entries — because the SUID mechanism itself grants no such fine-grained restriction; it only grants the elevated identity, and the program's own code is entirely responsible for using that elevation narrowly and correctly.

This last point deserves emphasis because it is the source of essentially every SUID-related security vulnerability that has ever existed: **SUID is a blunt, all-or-nothing identity-elevation mechanism. It grants the elevated identity for the process's entire execution, and every ounce of "only do the narrow, safe thing with this elevated privilege" logic has to be correctly implemented by the program itself.** A SUID-root binary with any exploitable flaw — a buffer overflow, an unsafe environment variable trust, a command injection vulnerability, or simply badly designed functionality that does more than the minimum necessary while privileged — is effectively a root-privilege-escalation vulnerability for any user able to run it, precisely because the kernel's own contribution to safety here ends at "grant effective UID equal to file owner"; everything else is the program's responsibility, not the kernel's.

### 2.2 Setting and Recognizing SUID

Per Chapter 4's numeric notation, SUID is the `4` in the leading fourth digit: `chmod 4755 file`. In symbolic notation, it is `u+s`: `chmod u+s file`.

In `ls -l` output, SUID displays in the owner's execute position:

```
-rwsr-xr-x   →  SUID set, AND owner execute is also set (lowercase s)
-rwSr-xr-x   →  SUID set, but owner execute is NOT set (uppercase S)
```

The uppercase-versus-lowercase distinction flagged in Chapter 4 is worth fully explaining here, in context: SUID only has any practical effect on a file that is also executable, since the entire mechanism is triggered by `execve()`. A SUID bit set on a non-executable file is inert — it cannot be "activated" by anything, since there's no execution event for the kernel to intercept and apply the effective-UID substitution to. `ls -l` uses the uppercase `S` specifically to flag this otherwise-easy-to-miss inert configuration, which in practice most often indicates either a deliberate no-op, a leftover from a previous configuration change, or — worth flagging as a genuine audit signal — a potential misconfiguration worth double-checking, since there's rarely a legitimate reason to have SUID set without execute.

### 2.3 Why SUID Directories Do Nothing

A detail worth stating explicitly because it occasionally causes confusion by analogy with SGID (Section 3, where directory-level SGID very much does something): **SUID has no defined effect when set on a directory.** Directories are never `execve()`'d — Chapter 3 established that the directory execute bit means something entirely different (traversal, not program execution) — so there is no execution event for SUID's effective-UID substitution to attach to. Setting SUID on a directory is simply inert, similar to setting it on a non-executable file, and is not a recognized or meaningful configuration in standard Linux behavior.

### 2.4 The Historical Decline of SUID-Root and the Rise of Capabilities

It's worth situating SUID within its broader historical trajectory, because understanding *why* its usage has been deliberately shrinking over time is directly relevant to how you should think about it in a modern security context, and previews Chapter 8's material.

The core problem Section 2.1 already identified — SUID grants full, undifferentiated root privilege to the entire process, for its entire execution, with correctness resting entirely on the program's own internal restraint — has, over the decades, been recognized as a fundamentally coarse-grained and therefore risky mechanism. A program that needs only one narrow root-level ability (binding to a low-numbered network port below 1024, for instance, an operation historically restricted to root) has, under classic SUID, no way to request *only* that narrow ability — it must be granted full, undifferentiated root effective UID, with every other root-level ability along for the ride, unused but still present as attack surface if the program has any exploitable flaw at all.

**Linux capabilities**, covered in full in Chapter 8, exist specifically to address this by decomposing "what root can do" into dozens of individually grantable, individually revocable named privileges (`CAP_NET_BIND_SERVICE` for low port binding, `CAP_DAC_OVERRIDE` for bypassing file permission checks, and many others). A program needing only low-port-binding capability can, on a modern system, be granted `CAP_NET_BIND_SERVICE` specifically — via file capabilities, an alternative to SUID covered fully in the next chapter — without ever running with anything resembling full root effective UID at any point, dramatically shrinking the consequences of any single exploitable flaw in that program. This is why, on modern, well-hardened systems, SUID-root binaries have become progressively rarer over time, reserved for cases that genuinely need broad privilege or where narrower capability-based alternatives haven't been adopted by the specific software in question — and why auditing a system's SUID-root inventory (a concrete technique covered in Chapter 9) is a standard, high-value hardening exercise: every SUID-root binary present represents a piece of software whose entire codebase needs to be trusted not to contain any privilege-escalation-exploitable flaw, a considerably higher bar than software running with only the specific narrow capabilities it actually needs.

---

## 3. SGID: Set Group ID

SGID's behavior genuinely bifurcates depending on whether it's applied to an executable file or a directory — two meaningfully different mechanisms sharing one bit, which is worth understanding as two related but distinct topics rather than a single unified one.

### 3.1 SGID on Executable Files: The Group Analogue of SUID

Applied to an executable file, SGID behaves exactly analogously to SUID, but for group identity rather than user identity: the resulting process's **effective GID** becomes the file's **owning group**, rather than the invoking user's own primary or supplementary group set. This is a less commonly encountered pattern than SUID-root in practice, but it follows identical reasoning — a program needing group-level access to some resource (a shared game high-score file historically being a classic textbook example, or more realistically, a program needing access to a specific device group like `dialout` for serial port access) can be granted that access via SGID on the binary itself, rather than requiring every user who runs it to be individually added to the relevant group.

The same coarse-grained-privilege caution from Section 2.1 applies here in parallel: an SGID binary elevates group identity for its entire execution, with correctness of restricted use resting on the program's own internal logic, exactly mirroring SUID's risk profile at the group-privilege level rather than the user-privilege level.

### 3.2 SGID on Directories: Inheritance, Not Elevation

This is the usage Chapter 2 previewed, and it is a **completely different mechanism** despite sharing the same bit and the same name — worth stating explicitly because conflating the two SGID behaviors (file-execution elevation versus directory-creation inheritance) is a common source of confusion.

When SGID is set on a **directory**, it has no effect at all on execution (directories aren't executed, exactly as established for SUID in Section 2.3). Instead, it alters what happens when **new files or subdirectories are created inside it**: rather than the new object taking the *creating process's* effective GID as its group ownership (the ordinary behavior, per Chapter 2), it instead takes the **parent directory's own group ownership**, regardless of what group the creating process itself belongs to.

Critically, and this is the detail that makes SGID directories genuinely powerful for collaboration rather than a one-time effect: **subdirectories created inside an SGID directory also inherit the SGID bit itself**, not just the group ownership — meaning the inheritance propagates recursively through an entire directory tree created under the original SGID directory, without needing to manually re-apply SGID at every nesting level. A file created three levels deep inside a tree that started as a single SGID directory still inherits the correct, consistent group ownership, precisely because each intermediate directory, having itself been created inside an SGID parent, was itself stamped with SGID at creation time, continuing the chain.

This is the exact mechanism Chapter 5, Section 6 discussed in the context of `umask` interaction — worth restating the combined rule from that chapter here, in its proper home:

> **SGID on a directory ensures every new file and subdirectory created within it — and within any subdirectory subsequently created inside it — consistently belongs to the same group, regardless of which individual team member creates it. It says nothing about what that group is permitted to *do* with the file; that remains entirely governed by ordinary permission bits, filtered through whatever `umask` the creating process has in effect, exactly as Chapter 5 detailed.**

### 3.3 Setting and Recognizing SGID

Numeric: `chmod 2755 file_or_dir` (the `2` in the leading digit). Symbolic: `chmod g+s file_or_dir`.

Display in `ls -l` mirrors SUID's convention, in the group execute position:

```
-rwxr-sr-x   →  SGID set, AND group execute is also set (lowercase s)
-rwxr-Sr-x   →  SGID set, but group execute is NOT set (uppercase S — inert for file-execution purposes, though this distinction is irrelevant for the directory-inheritance use case, which never depended on execute in the first place, only on the SGID bit itself)
```

Worth flagging precisely: the uppercase/lowercase distinction's rationale (inert without execute) fully applies to SGID's *file-execution* behavior from Section 3.1, but does **not** apply to SGID's *directory-inheritance* behavior from Section 3.2 — a directory's SGID bit drives inheritance regardless of the directory's own execute bit state (which, per Chapter 3, is virtually always set anyway for any usable directory, making this a largely theoretical distinction in the directory case, but worth understanding precisely rather than over-generalizing the inert-without-execute rule from the file case onto the directory case where it doesn't actually govern the relevant behavior).

---

## 4. The Sticky Bit

### 4.1 The Problem It Solves, Precisely Restated

Chapter 3, Section 8.1 established a fact worth restating verbatim because the sticky bit is the direct, purpose-built answer to it: **deleting or renaming a file is governed entirely by write-and-execute permission on its *parent directory*, with no permission check whatsoever against the file's own bits or its own owner.** This means that in any directory writable by multiple users — a shared, world-writable directory like `/tmp` being the canonical, universal example every Linux system has — any user with write access to that directory can delete or rename *any other user's* files within it, regardless of who owns those individual files or how restrictively they're permissioned, simply because deletion checks the directory, not the file.

This is a genuinely serious problem for any shared, broadly-writable directory: without some additional restriction, a system's shared temporary-file space would allow any local user to maliciously or accidentally delete or rename any other user's temporary files, a real and exploitable denial-of-service and data-integrity concern on any genuinely multi-user system.

### 4.2 The Mechanism

The sticky bit, set on a directory, adds exactly one additional restriction on top of the ordinary directory-permission rules from Chapter 3: **within a sticky directory, a file can only be deleted or renamed by the file's own owner, the directory's owner, or a privileged process (root, or a process holding the relevant capability) — even if the directory's own write permission would otherwise allow any user to perform that operation.**

This is a narrow, surgical addition to the permission model — it does not change who can *create* files in the directory (ordinary directory write-and-execute permission still governs that, exactly as Chapter 3 described), and it does not change read or execute behavior for the directory at all. It exclusively adds an ownership check specifically to the deletion/rename operation, closing precisely the gap Section 4.1 identified without altering anything else about how the directory functions.

### 4.3 Setting and Recognizing the Sticky Bit

Numeric: `chmod 1777 dir` (the `1` in the leading digit — and note this is commonly combined with otherwise fully-open `777` base permissions specifically *because* the sticky bit is what makes fully-open write access to a shared directory safe against the cross-user deletion problem, which is precisely why `/tmp` conventionally carries exactly this `1777` combination). Symbolic: `chmod +t dir`.

Display in `ls -l` occupies the **other** category's execute position — a placement worth noting since it's the one special bit that doesn't sit in the owner or group position:

```
drwxrwxrwt   →  sticky bit set, AND other execute is also set (lowercase t)
drwxrwxrwT   →  sticky bit set, but other execute is NOT set (uppercase T)
```

The lowercase/uppercase logic follows the identical pattern established for SUID and SGID — indicating whether the underlying execute bit (needed for basic directory traversal by the "other" category, per Chapter 3) happens to also be present. Since a sticky directory intended for genuine multi-user use virtually always needs execute permission for "other" anyway (otherwise most users couldn't traverse into it at all), the lowercase `t` is by far the more commonly encountered form in practice — the uppercase `T` case, sticky-without-other-execute, is unusual enough to be worth investigating if encountered, similarly to the SUID/SGID inert-configuration flags discussed above.

### 4.4 A Note on Sticky Bit's Historical Origin

Worth a brief mention because the name itself is a holdover from an entirely different original meaning: the sticky bit's name derives from a much older Unix behavior, unrelated to today's deletion-restriction semantics, where setting it on an *executable* caused the kernel to retain ("stick") the program's in-memory text segment in swap space after the process exited, intended as a performance optimization for frequently-run programs on early systems with limited memory. That original meaning is long obsolete on Linux and has had no effect for decades — the bit was simply repurposed for its current, entirely different directory-deletion-restriction meaning, which is the only meaning relevant to any modern system. This is worth knowing purely so encountering the name "sticky bit" in older documentation or historical context doesn't create confusion about what it actually does on any system in current use.

---

## 5. All Three Bits Together: A Consolidated Reference

| Bit | Numeric | Symbolic | On a file | On a directory |
|---|---|---|---|---|
| SUID | 4 | `u+s` | Effective UID becomes file owner's UID during execution | No defined effect (inert) |
| SGID | 2 | `g+s` | Effective GID becomes file's group during execution | New entries inherit the directory's group; inheritance propagates to subdirectories |
| Sticky | 1 | `+t` | No standard effect on modern Linux (historical swap-retention behavior, obsolete) | Only the owner (of the file, or the directory) may delete/rename entries, regardless of directory write permission |

A single file or directory can carry any combination of these three bits simultaneously — they occupy independent bit positions within the same fourth numeric digit (Chapter 4, Section 2.2), and nothing prevents, for instance, a directory from being both SGID (for group-ownership inheritance) and sticky (for deletion protection) at once — indeed, this specific combination is a common, deliberate pattern for genuinely secure shared collaboration directories, worth calling out as a concrete, composed example: `chmod 3775 shared_project/` sets both SGID and sticky (2 + 1 = 3 in the leading digit) alongside `rwxrwxr-x` base permissions, producing a directory where group members share consistent group ownership on everything they create (SGID), can all write into the directory freely (base group-write bit), but cannot delete or rename each other's individual files (sticky) — a precise, deliberate combination of three separate mechanisms from across this chapter and Chapter 2, each solving one distinct piece of the overall collaborative-directory requirement.

---

## 6. Security Auditing Implications: A Preview of Chapter 9

This chapter's material is directly actionable from a security standpoint, and it's worth previewing the specific audit technique Chapter 9 will develop in full, since the underlying mechanism is entirely this chapter's content.

Locating every SUID and SGID file on a system is a standard, high-value security audit step, precisely because — per Section 2.1's core caution — every such file represents software whose entire codebase must be trusted not to contain any privilege-escalation-exploitable flaw, and the set of such files on any given system is often larger, and less carefully tracked, than administrators expect (accumulated through package installations, forgotten manual configuration changes, or occasionally, in a genuinely adversarial context, planted deliberately by an attacker who has already achieved some level of access, as a persistence mechanism for re-escalating privilege later). The basic discovery command, worth introducing here as the direct, practical payoff of this chapter's mechanism-level material:

```
find / -perm -4000 -o -perm -2000 -type f 2>/dev/null
```

This searches for any file, anywhere on the filesystem, with either the SUID (`-4000`) or SGID (`-2000`) bit set — the `-perm -N` syntax specifically meaning "at least these bits are set," appropriate here since we want to catch SUID/SGID files regardless of what their base `rwx` bits happen to be. Chapter 9 builds this into a complete hardening and monitoring methodology, including baseline comparison over time to detect newly appeared SUID/SGID files as a potential compromise indicator — but the command's meaning, and why it's worth running at all, is entirely explained by this chapter's material on what these two bits actually do and why their presence constitutes meaningful attack surface.

---

## 7. Common Misconceptions Worth Retiring Now

- **"SUID and SGID always mean the same thing regardless of whether they're on a file or a directory."** SUID is inert on directories; SGID means something entirely different — group-ownership inheritance rather than execution-time identity elevation — when applied to a directory versus a file, despite sharing the same bit and name.
- **"The sticky bit affects who can read or write a file within the directory."** It affects exactly one thing: who is permitted to delete or rename entries, layered on top of, not replacing, the ordinary directory permission rules from Chapter 3.
- **"An SUID or SGID binary is inherently dangerous and should always be removed."** Many are legitimate and necessary (`passwd`, `sudo`, `ping` historically). The danger is specifically in *unaudited or unnecessary* SUID/SGID binaries, particularly ones not from trusted, actively maintained sources — the mechanism itself is a deliberate, legitimate tool, not an inherent flaw, though its coarse-grained nature is exactly why narrower capability-based alternatives (Chapter 8) are increasingly preferred for new software.
- **"Setting SGID on a directory retroactively changes the group ownership of files already inside it."** It does not — it only affects the group ownership stamped onto *newly created* entries going forward; pre-existing files require an explicit `chgrp` (Chapter 2) to bring them in line.
- **"SGID directory inheritance also grants the group write access automatically."** It does not, a point Chapter 5 already established in the `umask` context and worth reinforcing here in SGID's own dedicated chapter — group ownership inheritance and group write permission are governed by entirely separate mechanisms (SGID versus base permission bits filtered by `umask`), both needing deliberate configuration for full collaborative behavior.

---

The next chapter moves beyond the traditional nine-bit-plus-special-bits model entirely, introducing POSIX Access Control Lists — the mechanism that breaks past this series' recurring structural limitation of exactly three fixed categories (owner, group, other) by allowing arbitrary, per-user and per-group permission entries on a single file, and examining precisely how ACL evaluation interacts with, and in some cases overrides, everything this chapter and its predecessors have established about traditional permission-bit evaluation.
