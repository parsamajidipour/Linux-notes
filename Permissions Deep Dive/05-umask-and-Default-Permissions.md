# umask and Default Permissions

Chapter 4 closed by flagging a seam between symbolic mode and creation-time behavior, deferring the full explanation to this chapter. This chapter is that full explanation: exactly how `umask` works at the bit level, why it is subtractive rather than additive, how it propagates through process inheritance, and — critically — the specific, well-documented ways it interacts with (and can be completely overridden by) mechanisms introduced in earlier chapters, particularly SGID directory inheritance from Chapter 2 and the special bits fully covered in Chapter 6.

By the end of this chapter, "why did this new file end up with these exact permissions" should never again be a mystery — it should be a deterministic computation you can trace by hand.

---

## 1. The Problem `umask` Solves

Every earlier chapter has treated permission bits as something explicitly set, either at creation via a program's request or afterward via `chmod`. But this raises an immediate practical question: when a brand-new file is created — by a text editor, by `touch`, by a program's `open(O_CREAT)` call — where do its *initial* permission bits come from, before anyone has run `chmod` on it at all?

The naive answer — "the program decides" — is technically true but operationally unsatisfying, because it would mean every single program that ever creates a file needs to independently encode sound, security-conscious default permission logic, and needs to be individually reconfigured if an administrator or user wants a different default across the whole system. This is precisely the problem `umask` solves: it provides a single, process-inherited, centrally adjustable **filter** that automatically restricts the permissions of every newly created file or directory, regardless of what permissive default the creating program itself requested — without requiring that program to have any awareness of the user's preferred security posture at all.

---

## 2. The Core Mechanism: Subtractive, Not Additive

This is the single fact about `umask` most responsible for confusion among people first learning it, so it is worth stating with maximum precision before anything else: **`umask` does not specify what permissions a new file gets. It specifies which permissions to strip away from whatever the creating program requested.**

### 2.1 The Two Inputs to Every Creation-Time Permission Computation

Every time a new filesystem object is created, its final permission bits are the result of combining exactly two independent inputs:

1. **The requested mode** — a value the *creating program* supplies, baked into its own source code, reflecting what that specific program considers a sensible default for the type of object it's creating. This is not user-configurable in the moment; it is a property of the program itself.
2. **The process's `umask`** — a per-process bitmask, inherited from the shell or parent process, that the kernel applies as a filter against the requested mode.

The two conventional requested-mode defaults, used almost universally across Unix tooling by long-standing convention, are:

```
Files:       666  (rw-rw-rw-, requesting read/write for everyone, deliberately never including execute)
Directories: 777  (rwxrwxrwx, requesting full access for everyone)
```

It's worth pausing on why files conventionally request `666` rather than `777`: creating a file with an executable bit by default would mean *every* newly created file — text documents, config files, downloaded data — would be immediately runnable as a program the instant it was created, which is a meaningfully more dangerous default than simply being readable and writable. Directories, by contrast, essentially always need their execute bit for basic traversability (Chapter 3), so requesting `777` at the directory level is not analogously dangerous in the same direct sense — though as this chapter will show, `umask` still typically restricts it down considerably in practice.

### 2.2 The Actual Bitwise Computation

The kernel computes the final mode using this formula, applied independently to each of the nine permission bit positions:

```
final_mode = requested_mode AND (NOT umask)
```

In plain terms: for every bit position where `umask` has a `1`, that bit is forced to `0` in the final result, regardless of what the requested mode asked for. For every bit position where `umask` has a `0`, the requested mode's bit passes through unchanged. This is why `umask` is described as *subtractive* — it can only ever remove permissions from the requested default, never add permissions the requesting program didn't already ask for. A `umask` bit set to `1` at a given position means "always deny this," and there is no mechanism by which `umask` alone can grant a bit the requesting program's own default didn't already include.

### 2.3 A Fully Worked Example

Take the near-universal default `umask` value of `022`, and walk through both the file and directory cases explicitly, bit by bit, since seeing the actual binary math removes any remaining ambiguity about what "subtractive" means in practice.

**Directories**, requested mode `777`:

```
  requested:    111 111 111   (777)
  umask:        000 010 010   (022)
  NOT umask:    111 101 101
  -----------------------------------
  AND result:   111 101 101   =  755  (rwxr-xr-x)
```

**Files**, requested mode `666`:

```
  requested:    110 110 110   (666)
  umask:        000 010 010   (022)
  NOT umask:    111 101 101
  -----------------------------------
  AND result:   110 100 100   =  644  (rw-r--r--)
```

This single computation is the complete, precise explanation for why `umask 022` — by a wide margin the most common default across Linux distributions — produces the extremely familiar `755` for new directories and `644` for new files that every experienced Linux user has memorized without necessarily having worked through why those specific numbers result from that specific umask.

### 2.4 Why the Formula Is `AND (NOT umask)` and Not Simple Subtraction

It's worth being precise that this is a bitwise `AND` against the *complement* of the umask value, not arithmetic subtraction, because the two would only coincidentally produce the same result and thinking of it as subtraction can lead to incorrect reasoning in less common cases. The `AND`-with-complement formulation is what correctly captures "this bit is forced off regardless of the request, all other bits pass through unchanged" — the actual semantic `umask` provides — whereas naive subtraction would behave incorrectly (including going negative or affecting unrelated bit positions) the moment a umask bit is set at a position where the requested mode's corresponding bit was already zero.

---

## 3. Reading and Setting `umask`

### 3.1 Viewing the Current Value

```
$ umask
0022
```

The leading `0` here is the special-bits digit from Chapter 4's numeric mode discussion — `umask` supports filtering the SUID/SGID/sticky positions too, though this is rarely used deliberately in practice and is worth flagging mainly so its presence in the four-digit output isn't mistaken for an error. `umask -S` gives the symbolic equivalent, expressed as the permissions that *remain granted* after filtering — the inverse framing from the raw mask itself, which some administrators find more intuitive to reason about directly:

```
$ umask -S
u=rwx,g=rx,o=rx
```

### 3.2 Setting a New Value for the Current Shell

```
$ umask 077
```

This restricts new files and directories to owner-only access by default (working through Section 2.3's formula with `077` instead of `022` gives `700` for directories and `600` for files) — a common hardening choice for shells operating in security-sensitive contexts, or for individual users who want a maximally private default posture without needing to remember to `chmod` every new file manually.

Like any process-local state, a `umask` change made interactively in a shell session only affects that shell and its future children — it does not persist across sessions, and does not retroactively affect files already created. Persistent, session-independent changes require modifying shell startup files (`~/.bashrc`, `~/.profile`, or equivalent), system-wide login configuration (`/etc/profile`, `/etc/login.defs`'s `UMASK` setting), or PAM configuration for the broadest possible scope — each representing a different layer at which the default can be overridden, discussed next.

---

## 4. Inheritance: How `umask` Propagates Through the Process Tree

This section connects directly back to Chapter 2's discussion of credential inheritance via `fork()`/`exec()`, because `umask` follows the exact same inheritance model, and understanding that parallel is what makes `umask` propagation predictable rather than mysterious.

### 4.1 `umask` Is Process State, Inherited on `fork()`

`umask` is stored per-process (technically, it lives in the same broader process credential and attribute structure area conceptually adjacent to the `struct cred` fields covered in Chapter 1, though tracked as separate kernel state specifically for this purpose) and is copied to a child process at `fork()` time, exactly like every other inherited process attribute. A child can subsequently change its *own* `umask` via the `umask()` system call without affecting its parent — the value is copied, not shared, at the moment of forking, meaning changes after that point are entirely local to whichever process makes them.

This is precisely why setting `umask` in an interactive shell only affects commands run *from* that shell afterward, and why a background daemon started long before a user's `umask` change won't retroactively pick up the new value — it already forked its own process tree with whatever `umask` was in effect at its own launch time, and nothing that happens in an unrelated shell afterward can reach back and modify already-running processes' inherited state.

### 4.2 The Practical Chain: Where a Daemon's `umask` Actually Comes From

This inheritance model has a real, frequently underappreciated operational consequence: a long-running service's effective `umask` — and therefore the default permissions of every file it creates throughout its entire runtime — is determined by whatever was in effect at the moment it was launched, tracing back through its entire parent chain:

```
systemd (or init) → default umask, often 022 unless overridden
   └── service unit's own UMask= setting, if specified, overrides the inherited value
         └── the daemon process itself, inheriting whichever value applied
               └── every file the daemon ever creates, for its entire lifetime
```

Modern init systems like systemd provide an explicit `UMask=` directive in unit files specifically to make this inherited value deliberate and auditable rather than an accident of whatever happened to be configured in the launching shell's environment at boot time — a considerably more reliable and reproducible approach than relying on shell startup file ordering, which is why production service configuration should generally set `UMask=` explicitly in the unit file rather than depending on inherited shell state, especially for services whose file-creation defaults have genuine security implications (a service creating credential files, session tokens, or other sensitive output benefits enormously from an explicit, auditable `UMask=0077` rather than trusting whatever the ambient environment happened to provide).

---

## 5. Common `umask` Values and Their Rationale

| umask | Resulting file mode | Resulting directory mode | Typical context |
|---|---|---|---|
| `022` | `644` | `755` | The overwhelming default across most distributions — private write access, public read/traverse |
| `002` | `664` | `775` | Common in group-collaborative environments (often paired with user-private-groups from Chapter 2 and SGID directories from Section 6) — allows group members write access by default |
| `077` | `600` | `700` | Maximally private — no access outside the owner at all, common for security-sensitive shells, credential-handling services, or individual users prioritizing privacy over convenience |
| `027` | `640` | `750` | A middle ground — group gets read access but not write, other gets nothing; common for moderately sensitive shared systems |

The `022` versus `002` distinction is worth dwelling on specifically because it is the single most consequential `umask` decision most organizations make, and it maps directly onto the DAC philosophy discussion from Chapter 1: `022` treats group membership the same as "everyone else" for write purposes (only the owner gets default write access), while `002` extends default write trust to the group category as well. Neither is objectively correct — the right choice depends entirely on whether the deployment's group structure represents genuine, deliberate collaboration boundaries (in which case `002` is a reasonable, even desirable default, especially combined with the user-private-group convention ensuring the *group* in question is a real, intentional collaboration group rather than an overly broad catch-all) or whether groups are used more loosely, in which case `022`'s more conservative default write restriction is the safer choice.

---

## 6. `umask`'s Blind Spot: SGID Directory Inheritance

This section covers an interaction that genuinely surprises people, connecting directly back to Chapter 2's brief mention of SGID-driven group inheritance and Chapter 3's directory-permission material, and it is worth understanding precisely because it is the most common source of "why isn't `umask` behaving the way I expect" confusion in real, group-collaborative environments.

### 6.1 The Setup: SGID Directories

Chapter 2, Section 6.1 mentioned that a directory with its SGID bit set causes new files created within it to inherit the *directory's* group ownership rather than the creating process's own primary group. This is a deliberate mechanism (fully detailed in Chapter 6) for maintaining consistent group ownership across a shared collaboration directory regardless of which specific team member creates any given file.

### 6.2 What `umask` Does and Does Not Affect Here

The critical clarification: SGID directory inheritance and `umask` operate on **completely independent aspects** of a newly created file's metadata, and it is a common mistake to conflate them. SGID inheritance affects only the **group ownership** field (Chapter 2's material) — it says nothing whatsoever about the **permission bits** themselves. `umask` continues to apply to the permission bits exactly as described throughout this chapter, entirely unaffected by whether the parent directory has SGID set or not.

This means a very common, well-intentioned misconfiguration looks like this: an administrator sets up a shared collaboration directory with SGID correctly, expecting it to fully solve group collaboration — new files do correctly inherit the shared group ownership — but if the creating users' `umask` is still the conservative default `022`, new files still end up with only `644` (or `755` for directories), meaning the group has *read* access via the correctly inherited group ownership, but not *write* access, because `022`'s group-write-denying bit is still being applied regardless of SGID. The files are owned by the right group, but that group still can't collaboratively edit them, defeating a significant part of the original intent.

The correct, complete fix for a genuinely collaborative SGID directory therefore requires **both** mechanisms deliberately configured together: SGID on the directory (for correct group *ownership* inheritance) **and** a `umask` of `002` rather than `022` for the users working in that directory (for correct group *write permission* by default) — neither mechanism alone produces the desired collaborative behavior; they address genuinely separate metadata fields that happen to both need adjusting to achieve the combined goal. This is worth stating as an explicit, memorable operational rule:

> **SGID controls who a new file's group *is*. `umask` controls what that group (and owner, and everyone else) is *permitted to do* with it. A correctly functioning shared collaboration directory needs both configured deliberately — one does not imply or compensate for the other.**

---

## 7. `umask` and Explicit Program Behavior: Programs That Ignore It (Partially)

A final, important nuance: `umask` filters the *default* mode a program requests at creation time, but it has no bearing whatsoever on modes a program (or a user via `chmod`) sets *explicitly* after the fact, or on programs that deliberately bypass the conventional `666`/`777` request pattern for specific, security-conscious reasons of their own.

A concrete, widely encountered example: `ssh-keygen`, when generating a new private key file, explicitly requests mode `600` at creation time rather than relying on the conventional `666`-filtered-by-umask pattern — a deliberate design choice specifically because private key material is sensitive enough that the tool's authors chose not to trust the ambient `umask` (which could, in principle, be set more permissively than `022` in some misconfigured environment) to provide adequate protection. In a case like this, `umask`'s filtering is effectively moot, because the requested mode (`600`) is already at least as restrictive as any reasonable `umask` would produce from a `666` request — `umask`'s `AND (NOT umask)` formula can only ever restrict further, and a permissive `umask` (say, `000`) would still leave `ssh-keygen`'s explicitly requested `600` completely untouched, since there's nothing further for a permissive mask to strip away from an already-restrictive request.

This is a useful closing illustration of `umask`'s actual scope: it is a *default-adjusting* mechanism for programs that rely on conventional, permissive creation requests, not a system-wide override capable of loosening or tightening permissions that a program has deliberately and explicitly specified for security-relevant reasons of its own. Security-conscious software correctly treats explicit mode specification, rather than reliance on `umask` filtering, as the more robust approach for genuinely sensitive file types — a pattern worth recognizing when auditing or writing software that creates security-relevant files of its own.

---

## 8. Diagnosing Unexpected Permission Results: A Worked Methodology

This closing section ties the chapter together as a practical troubleshooting sequence, useful whenever a newly created file's permissions don't match expectations — a genuinely common real-world debugging scenario this chapter's material directly resolves.

**Step 1 — Confirm the actual resulting permissions**, using `stat` rather than a casual `ls -l` glance, per Chapter 4's recommendation, to get an unambiguous numeric reading.

**Step 2 — Check the umask in effect at creation time**, in the exact shell or process context the file was actually created from — remembering, per Section 4, that a long-running daemon's relevant `umask` is whatever was inherited at its own launch, not whatever the current interactive shell happens to show.

**Step 3 — Determine the requesting program's default request mode.** For most standard tools this is the conventional `666`/`777` pattern, but some programs (per Section 7) deliberately request something more restrictive, in which case umask math against the conventional defaults won't explain the observed result at all — the explicit request itself needs to be identified, often via documentation or, for open-source tools, the actual `open()`/`creat()` call in source.

**Step 4 — If group ownership also looks unexpected, check independently for SGID on the parent directory**, per Section 6, remembering that this is an entirely separate mechanism from `umask` and needs to be diagnosed separately rather than assumed to be explained by the same permission-bit math.

Working through these four steps in order resolves the overwhelming majority of "why does this file have these permissions" confusion, because it systematically separates the two genuinely independent mechanisms (creation-time permission-bit filtering via `umask`, and group-ownership inheritance via SGID) that are easy to conflate but need to be reasoned about entirely separately, as Section 6 established.

---

## 9. Common Misconceptions Worth Retiring Now

- **"`umask 022` means new files get mode `022`."** The opposite is closer to true — `022` is what gets *subtracted*, not what results. The resulting file mode is `644`, not `022`, a distinction that trips up nearly everyone on first encounter.
- **"`umask` can grant permissions a program didn't request."** It cannot, structurally — the `AND (NOT umask)` formula can only ever remove bits from the requested mode, never add ones the program's own default didn't already include.
- **"Changing `umask` retroactively affects existing files."** It affects only files created *after* the change, in the same or child process tree — it has no bearing whatsoever on already-existing files' permissions.
- **"A daemon's file-creation permissions follow whatever `umask` the administrator currently has set in their interactive shell."** They follow whatever `umask` was inherited at the daemon's own launch time, tracing back through its actual parent process chain — not whatever an unrelated, currently-open shell happens to show.
- **"Setting SGID on a shared directory is sufficient, by itself, for full group collaboration."** SGID alone only fixes group *ownership* inheritance; without also adjusting `umask` to `002` (or otherwise ensuring group-write bits are present), the group ends up with correctly-inherited ownership but no write access, which is very often not the intended outcome.

---

The next chapter turns to the special permission bits referenced throughout this one but not yet fully explained — SUID, SGID, and the sticky bit — covering the exact mechanism by which each one alters standard permission evaluation, the historical and modern security implications of SUID specifically, and the sticky bit's role in solving the shared-directory deletion gap first identified back in Chapter 3.
