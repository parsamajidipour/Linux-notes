# Symbolic and Numeric Modes

Chapters 1 through 3 built the complete conceptual model of what permissions are, who they apply to, and how the kernel evaluates them. This chapter turns to the practical layer sitting directly on top of that model: the two notations used to *express* permission state — numeric (octal) and symbolic — and the single tool that manipulates both, `chmod`. The goal here is not a shallow list of example invocations. It is a precise account of what each notation actually represents at the bit level, why both forms continue to coexist rather than one having fully replaced the other, and the specific, sometimes surprising behavioral differences between them that matter in real scripts and real incident postmortems.

---

## 1. Why Two Notations Exist At All

It would be reasonable to ask why Unix settled on two entirely different ways of expressing the same nine (or twelve, including special bits) bits of state, rather than standardizing on one. The answer is that the two notations are not actually redundant — they solve two different problems, and understanding *which* problem each one solves is the fastest way to know which one to reach for in any given situation.

**Numeric mode is absolute and complete.** A numeric mode like `754` fully specifies the entire resulting permission state in one value, with no dependency on what the previous state was. This makes it ideal for scripting, configuration management, and any context where you want a guaranteed, deterministic end state regardless of starting conditions.

**Symbolic mode is relative and selective.** A symbolic expression like `u+x` or `go-w` describes a *transformation* — add this, remove that — applied on top of whatever the current state happens to be, without requiring you to know or restate the bits you don't want to change. This makes it ideal for interactive use and for scripts that need to modify one specific aspect of a file's permissions without disturbing everything else, a capability numeric mode does not offer at all without first reading the current state.

Both notations map onto the exact same underlying 12-bit field described in Chapter 1's inode mode diagram (nine permission bits plus SUID, SGID, and sticky). Neither is more "real" than the other at the kernel level — `chmod` translates whichever notation you provide into the same raw mode value before issuing the same underlying `chmod()`/`fchmod()` system call either way.

---

## 2. Numeric (Octal) Mode in Full Precision

### 2.1 The Bit-to-Digit Mapping, Derived, Not Memorized

Chapter 1 introduced the basic mapping — `r=4`, `w=2`, `x=1` — but it is worth deriving *why* those specific values, because understanding the derivation makes the entire numeric system trivially memorable rather than requiring rote recall.

Each permission triad is exactly three bits, and three bits can represent any value from 0 to 7 — which is precisely why octal (base 8) is the natural notation for this, rather than an arbitrary historical choice. The three bit positions within a triad, from most to least significant, are read, write, execute:

```
bit position:   2    1    0
permission:     r    w    x
value:          4    2    1
```

Any combination of the three permissions within one triad is simply the sum of the values for the bits that are set — because each bit position is a distinct power of two (4, 2, 1), every combination from 0 through 7 is unique and unambiguous:

| Octal digit | Binary | Symbolic | Meaning |
|---|---|---|---|
| 0 | `000` | `---` | No permissions |
| 1 | `001` | `--x` | Execute only |
| 2 | `010` | `-w-` | Write only |
| 3 | `011` | `-wx` | Write and execute |
| 4 | `100` | `r--` | Read only |
| 5 | `101` | `r-x` | Read and execute |
| 6 | `110` | `rw-` | Read and write |
| 7 | `111` | `rwx` | Full permissions |

A full three-digit numeric mode like `754` is simply this table applied three times in a row — once for owner, once for group, once for other — each digit completely independent of the others:

```
7  5  4
│  │  └── other:  r--        (4)
│  └───── group:  r-x        (5)
└──────── owner:  rwx        (7)
```

### 2.2 The Fourth Digit: Special Bits

Numeric mode optionally supports a **leading fourth digit**, which encodes the three special permission bits covered in full in Chapter 6 (SUID, SGID, sticky). The same additive logic applies:

| Value | Meaning |
|---|---|
| 4 | SUID |
| 2 | SGID |
| 1 | Sticky bit |

A mode of `4755` sets SUID in addition to the standard `rwxr-xr-x` triad. When the leading digit is omitted (a plain three-digit mode like `755`), it is not left unspecified — it is explicitly set to `0`, clearing any special bits that may have previously been set. This is a detail worth internalizing precisely because it is a common source of unintended security regressions: running `chmod 755 file` on a file that previously had SUID set (`4755`) silently and completely strips the SUID bit, since three-digit numeric mode is absolute over the *entire* mode field it addresses, not just the triads it visually appears to describe. Chapter 6 returns to this specific pitfall in its own security-hardening discussion, but the mechanism belongs here, in the notation chapter, because it is fundamentally a notation fact, not a special-bits fact.

### 2.3 Numeric Mode Is Absolute — The Property That Defines Its Use Cases

This is the property flagged in Section 1 and worth restating precisely: `chmod 640 file` sets the mode to *exactly* `rw-r-----`, full stop, regardless of what the file's permissions were a moment before. There is no notion of "add" or "remove" in numeric mode — every invocation fully overwrites the entire relevant portion of the mode field.

This absoluteness is precisely why numeric mode is the standard choice in infrastructure-as-code, configuration management tools (Ansible's `mode:` parameter, Terraform provisioners, Dockerfile `COPY --chmod`), and any deployment pipeline where the goal is a guaranteed, reproducible end state applied identically regardless of the file's prior history — you never have to reason about what state a file was in before the `chmod` ran, because the numeric mode fully determines the result independent of history.

---

## 3. Symbolic Mode in Full Precision

Symbolic mode's syntax is more expressive than numeric mode's fixed three-or-four-digit structure, but that expressiveness comes with more moving parts to understand correctly. The general grammar is:

```
[ugoa...][+-=][rwxXst...][,...]
```

Broken into its three components:

### 3.1 Who: The Target Selector

| Symbol | Targets |
|---|---|
| `u` | Owner (user) |
| `g` | Group |
| `o` | Other |
| `a` | All three (equivalent to `ugo`, and also the default if no selector is given at all) |

Multiple selectors can be combined without a separator: `ug+x` applies to both owner and group simultaneously. Omitting the selector entirely defaults to `a` — but with one important caveat covered in Section 3.4 regarding how `umask` interacts with an omitted selector, which is *not* simply "identical to explicitly writing `a`" in every case.

### 3.2 Operator: What Kind of Change

| Symbol | Effect |
|---|---|
| `+` | Add the specified permission(s) to the existing set, leaving everything else untouched |
| `-` | Remove the specified permission(s) from the existing set, leaving everything else untouched |
| `=` | Set the specified permission(s) exactly, clearing anything not listed for the targeted category |

The `+` and `-` operators are what give symbolic mode its defining relative property — they are explicitly deltas applied against whatever the current state is, never touching bits outside the specific ones named. The `=` operator is a middle ground: absolute *within the targeted category* (owner, group, or other — whichever `who` selector was used), but still leaves untouched categories that weren't selected completely alone, unlike numeric mode's full-field absoluteness.

### 3.3 What: The Permission Letters

Beyond the basic `r`, `w`, `x` already covered, symbolic mode supports several additional letters worth knowing precisely:

| Symbol | Meaning |
|---|---|
| `r`, `w`, `x` | Standard read, write, execute |
| `X` (capital) | Execute, **but only if the target is a directory, or already has execute set for at least one of owner/group/other** |
| `s` | SUID (when applied to `u`) or SGID (when applied to `g`) — covered fully in Chapter 6 |
| `t` | Sticky bit — covered fully in Chapter 6 |

The capital `X` deserves particular attention because it solves a genuinely common, otherwise-awkward problem, and its existence signals a real, considered design intent rather than notational trivia. Consider recursively applying execute permission across a directory tree containing a mix of regular files and subdirectories — you want subdirectories to remain traversable (execute needed) and any files that were already executable to remain so, but you do *not* want to make ordinary, non-executable data files (documents, images, config files) suddenly executable, which a naive recursive `chmod -R +x` would do indiscriminately. `chmod -R a+X` solves exactly this: it adds execute to every directory unconditionally, and to files only if they already have execute set for somebody, leaving genuinely non-executable regular files untouched. This single letter is a direct, purpose-built answer to a specific, recurring administrative need, not a generic feature added for symmetry.

### 3.4 Combining Multiple Clauses

Symbolic expressions can chain multiple `who+/-/=what` clauses with commas, applied left to right as a single logical operation against the file:

```
chmod u+x,g-w,o=r file
```

This simultaneously adds execute for owner, removes write for group, and sets other to exactly read-only — three independent transformations expressed as one invocation, each respecting its own operator's relative-or-absolute semantics precisely as described in Section 3.2, computed against the file's original state before any of the three clauses were applied (not applied sequentially against each other's intermediate results in a way that would make ordering matter — all three read the same starting state).

---

## 4. The Interaction Between Symbolic Mode and `umask` — a Preview

Chapter 5 is dedicated entirely to `umask`, but one specific interaction needs to be flagged here, in the notation chapter, because it is a genuine behavioral difference between numeric and symbolic mode that catches people off guard and is easy to state precisely once you know to look for it.

**When `chmod` is used to set the mode of a newly created file (as opposed to modifying an existing one), and no explicit selector is given in symbolic mode, the default `a` selector's effective result is filtered through the process's `umask`.** This is different from directly applying to an *existing* file via an interactive `chmod` call without a selector, where `umask` plays no role at all — `umask` is exclusively a creation-time filter, applied by the kernel when a new inode's initial mode is computed, never consulted during a subsequent, explicit `chmod` call against an already-existing file.

The detail worth flagging specifically for this chapter's purposes: this means the *effective* result of "no selector given" in symbolic mode can differ from what a literal reading of "defaults to `a`, meaning all three categories" would suggest, in the narrow context of file creation specifically — because `umask`'s subtractive filtering (covered fully in Chapter 5) still applies on top of whatever a program requests as its "default" creation mode, and many creation-time defaults *are* effectively unrestricted requests (`666` for files, `777` for directories) that rely entirely on `umask` to bring them down to a sane, restrictive default. This chapter's job is only to flag the seam where these two mechanisms meet; Chapter 5 covers the full mechanics of that filtering process.

---

## 5. Recursive Application: `-R` and Its Genuine Hazards

Both numeric and symbolic mode support the `-R` (recursive) flag, applying the requested change to a directory and everything nested beneath it. This is convenient, and also the single most common source of real, damaging permission misconfiguration incidents in production systems, for a reason worth stating precisely rather than just as a generic warning.

### 5.1 The Core Hazard: One Numeric Mode Cannot Correctly Fit Both Files and Directories

Numeric mode's absoluteness (Section 2.3), which is exactly what makes it valuable for deterministic, reproducible configuration, becomes a liability under `-R` specifically because files and directories legitimately need *different* execute-bit treatment — directories almost always need execute permission to remain traversable at all (Chapter 3, Section 3.3), while ordinary data files usually should not be executable. A single recursive numeric mode like `chmod -R 644 project/` correctly sets sane, non-executable permissions on every regular file, but simultaneously strips execute permission from every directory in the tree, making the entire tree unable to be traversed at all — including by the very owner who ran the command, since, as Chapter 3 established, directory execute bits govern name resolution regardless of who's asking.

This is precisely the problem the capital `X` letter from Section 3.3 exists to solve, and it is worth stating as the standard, correct idiom for this exact recursive scenario:

```
chmod -R u=rwX,g=rX,o=rX project/
```

This sets read (and, for directories or already-executable files, execute) consistently across the tree while never granting execute to genuinely non-executable regular files — the correct general-purpose recursive permission-normalization pattern, and one of the clearest illustrations in this entire chapter of why symbolic mode's extra expressiveness (specifically the conditional `X`) is not merely a stylistic alternative to numeric mode, but solves a problem numeric mode structurally cannot solve in a single invocation.

### 5.2 Recursive Application and Symlinks

A second, independently important hazard: by default, `chmod -R` **does** traverse into symbolic links that point to directories, in some implementations and configurations, which can result in a recursive permission change unintentionally escaping the intended directory tree entirely and modifying an entirely separate part of the filesystem that happens to be symlinked in from within the tree being processed. GNU `chmod` specifically defaults to *not* following symlinks during recursive traversal (following Chapter 3's general principle that symlink permissions are largely inert and operations instead target the containing directory or the resolved target explicitly), but this behavior has historically varied across different `chmod` implementations and explicit flags (`-H`, `-L`, `-P` on some systems) exist specifically to control it. The operational lesson, independent of any specific implementation's default: recursive permission changes against a directory tree containing symlinks deserve a deliberate check of what those symlinks point to before running, precisely because Chapter 3 established that symlinks can point anywhere the creating process had permission to reference, entirely independent of the directory structure they visually appear to sit within.

---

## 6. Verifying Intended State: Reading Modes Back Correctly

A chapter on setting permissions is incomplete without equal attention to correctly reading them back, because a permission change that "looks right" in a quick glance is a common source of false confidence.

### 6.1 `ls -l`'s Symbolic Output, Read Precisely

```
-rwsr-xr-x
```

Reading this correctly requires noticing details a quick glance skips: the fourth character (owner's execute position) is a lowercase `s`, not `x` — indicating SUID is set *and* owner execute is also set (an uppercase `S` in that position would indicate SUID set *without* owner execute, an unusual and generally suspicious combination worth flagging specifically, since a SUID bit only has practical effect on an executable file — a SUID-set, non-executable file is inert as far as the SUID mechanism goes, and its presence in that state often indicates either an intentional no-op or a misconfiguration). Chapter 6 covers the full special-bit display conventions (the equivalent `t`/`T` distinction for the sticky bit, and `s`/`S` for SGID in the group position) in complete detail; this chapter's job is to flag that `ls -l`'s single-character-per-position display genuinely does encode more than the basic nine letters might suggest, and reading it accurately requires knowing to look for the case distinction.

### 6.2 `stat` for Unambiguous Numeric Confirmation

Where `ls -l`'s symbolic output requires careful reading to avoid misinterpreting the special-bit case distinctions above, `stat --format='%a' file` returns the unambiguous full numeric mode (including the special-bits digit) directly, which is why scripts and automated configuration-verification tooling should generally prefer parsing `stat` output over attempting to parse `ls -l`'s symbolic column — a well-known general Unix scripting principle (avoid parsing `ls` output programmatically) that has direct, specific relevance to permission verification given how easy the symbolic column is to misread even by an experienced human, let alone a naive parsing script.

---

## 7. `chmod` and Ownership Boundaries: Who Can Run It At All

This chapter has focused on notation, but it is worth closing the loop with the permission-to-run-`chmod`-itself question, connecting back to Chapter 2's ownership material. Only the file's owner, or a process holding the `CAP_FOWNER` capability (root, by default, and any process specifically granted that narrower capability — Chapter 8 covers this), may change a file's mode. Unlike the group-ownership nuance from Chapter 2 (where a non-root owner has a *restricted* ability to reassign group ownership to a group they belong to), there is no equivalent partial permission structure for `chmod` itself — mode-changing is an all-or-nothing owner (or capability-holder) privilege, with no intermediate "you can change some bits but not others" tier built into the base DAC model. This is worth noting specifically because ACLs, covered in Chapter 7, do introduce a more granular permission-management delegation model — but the base `chmod` mechanism covered in this chapter remains strictly owner-or-privileged throughout.

---

## 8. Practical Reference: Common Modes and Their Rationale

This closing section is a deliberately curated reference table — not an exhaustive list, but the small set of modes that recur constantly in real system administration, each annotated with *why* that specific value is the conventional choice rather than just what it decodes to, since understanding the rationale is what lets you correctly generalize to situations not explicitly listed.

| Mode | Symbolic | Typical use | Rationale |
|---|---|---|---|
| `644` | `rw-r--r--` | Ordinary data files | Owner can edit; everyone else can read but not modify — the standard default for non-sensitive, non-executable content |
| `600` | `rw-------` | Private files (SSH private keys, credential files) | No access whatsoever outside the owner; many programs (`ssh`, for instance) actively refuse to use key files with looser permissions, treating it as a security misconfiguration |
| `755` | `rwxr-xr-x` | Executable programs, traversable directories | Owner has full control; everyone else can run/traverse but not modify — the standard default balancing usability and integrity |
| `700` | `rwx------` | Private directories | No access outside the owner, including listing — used for home directories and any directory whose mere contents-list should stay confidential |
| `750` | `rwxr-x---` | Group-shared, non-public directories | Collaborators in the owning group can traverse and read; no access for anyone else — a common pattern for project directories under the user-private-group convention from Chapter 2 when deliberate group sharing is desired |
| `4755` | `rwsr-xr-x` | SUID executables (covered fully in Chapter 6) | Grants temporary elevated execution identity while remaining broadly executable and non-writable by non-owners |
| `1777` | `rwxrwxrwt` | World-writable shared directories with sticky bit (`/tmp` is the canonical example) | Everyone can create files; the sticky bit (Chapter 6) restricts deletion to each file's own owner, closing the directory-write-governs-deletion gap flagged in Chapter 3 |

---

## 9. Common Misconceptions Worth Retiring Now

- **"Numeric and symbolic mode are just two ways of writing the same thing, interchangeable in every context."** They share the same underlying target representation, but numeric mode is absolute over the entire addressed field while symbolic `+`/`-` are genuinely relative — a difference with real behavioral consequences, not merely stylistic ones.
- **"Omitting the leading digit in numeric mode leaves existing special bits untouched."** It does not — a three-digit numeric mode explicitly zeroes any previously set SUID/SGID/sticky bits, a frequent source of accidental privilege regression.
- **"`chmod -R 755` is always a safe, standard way to fix a tree of permission problems."** It indiscriminately makes every regular file executable, which is very often not desired — the conditional `X` idiom from Section 5.1 is the generally correct recursive tool for this job instead.
- **"Reading `ls -l`'s output tells you everything at a glance."** The uppercase-versus-lowercase distinction in the special-bit positions carries meaningful information (bit set with vs. without the underlying execute bit) that a casual reading easily misses; `stat --format='%a'` is the unambiguous alternative for anything script-verified.
- **"Any user who owns a file's parent directory can change that file's mode."** They cannot — `chmod` permission is governed by ownership of the *file itself* (or the `CAP_FOWNER` capability), completely independent of directory ownership, which governs a different set of operations entirely, as established in Chapter 3.

---

The next chapter turns to `umask` — the creation-time filtering mechanism referenced but not yet fully explained in Section 4 of this chapter — covering exactly how default permissions are computed for newly created files and directories, how `umask` interacts with process inheritance across shells and daemons, and the specific pitfalls that arise when `umask` and SGID directory inheritance (introduced briefly in Chapter 2) interact with each other.
