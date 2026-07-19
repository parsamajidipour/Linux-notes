# File and Directory Permissions

Chapter 1 introduced the permission triad and the basic read/write/execute semantics at a conceptual level. Chapter 2 established how the *identities* on either side of a permission check — the process and the inode — actually get their numeric values. This chapter goes back to the permission bits themselves and treats them with the operational depth this series promised: every object type the bits apply to, every edge case that trips up experienced administrators, and the exact algorithm the kernel runs on every single access attempt.

By the end of this chapter you should be able to look at any `ls -l` line, for any file type, and predict with certainty what a given process can and cannot do to it — including the cases that the simplified "rwx means read-write-execute" mental model gets wrong.

---

## 1. The Full Object Type Inventory

Chapter 1 focused on regular files and directories because they are the objects most permission discussions center on. But the permission triad — and the kernel's enforcement of it — applies uniformly across every filesystem object type Linux recognizes. `ls -l`'s leading character encodes which type you're looking at:

| Symbol | Type | Where it commonly appears |
|---|---|---|
| `-` | Regular file | Ordinary data — text, binaries, archives |
| `d` | Directory | Name-to-inode mapping table |
| `l` | Symbolic link | A stored path string, resolved at access time |
| `b` | Block device | Disk-like devices, addressable in fixed-size blocks (`/dev/sda`) |
| `c` | Character device | Stream-like devices (`/dev/tty`, `/dev/null`) |
| `p` | Named pipe (FIFO) | Inter-process communication via the filesystem namespace |
| `s` | Socket | Unix domain sockets bound to a filesystem path |

Every one of these carries the same nine-bit owner/group/other structure. What differs, sometimes dramatically, is what each bit *means* for that specific type — and this chapter's core purpose is to walk through every one of those meanings precisely, because generic tutorials almost universally stop at regular files and directories, leaving the remaining types as a source of confusion when they actually matter (which, for device files and sockets in particular, is often in security-sensitive contexts).

---

## 2. Regular Files, Revisited With Precision

Chapter 1 gave the basic table. This section fills in the operational detail that table glossed over.

### 2.1 Read (`r`)

Grants permission to invoke `read()` against an open file descriptor referencing this inode, and — critically, a detail that surprises people — grants permission to `open()` the file for reading in the first place; the `open()` call itself performs a permission check before a descriptor is even handed back. Read permission on a regular file has no bearing on metadata visibility (you can `stat()` a file's size and timestamps with only directory-level search permission on its parent, covered in Section 4); it strictly governs access to the byte content.

### 2.2 Write (`w`)

Grants permission to `write()` to the file, and to truncate it (via `truncate()`, `ftruncate()`, or the `O_TRUNC` flag on `open()`). A subtlety worth calling out explicitly: write permission on a file governs *modifying its content*, but it does **not** govern deleting the file, renaming it, or moving it to another location within the same directory — those are directory-level operations, covered fully in Section 4. This is the single most commonly misunderstood fact about file permissions in the entire model, important enough that Chapter 1 flagged it and this chapter repeats it deliberately: a file can be completely unwritable (`chmod 444`) and yet trivially deletable by anyone with write access to its parent directory, because deletion never touches the file's own write bit.

### 2.3 Execute (`x`)

Grants permission to run the file as a program via `execve()`, either as a native binary or, via the kernel's shebang-line handling, as a script interpreted by whatever program the first line specifies (`#!/bin/bash`, `#!/usr/bin/env python3`, and so on). A file lacking execute permission cannot be run directly, even if it is perfectly readable and its content is a valid, syntactically correct script — attempting to run it produces a "permission denied" error at the `execve()` system call level, distinct from and prior to any error the interpreter itself might raise.

One frequently misunderstood interaction: running a script by explicitly invoking its interpreter (`bash script.sh` or `python3 script.py`) does **not** require execute permission on the script file itself — only read permission, since in that case the interpreter is the thing being `execve()`'d, and the script is merely a file it opens and reads. This is a commonly (mis)used workaround, and it is worth understanding precisely why it works rather than treating it as a trick: the kernel's execute-permission check applies specifically to the `execve()` target, and in this invocation pattern, the `execve()` target is the interpreter binary, not the script.

---

## 3. Directories: The Type Most Often Misunderstood

Chapter 1 stated the core directory rule — a directory is a name-to-inode mapping table, and its permission bits govern operations on that table, not on the files "inside" it in any content sense. This section works through every practical consequence of that model in detail.

### 3.1 Read (`r`) — Listing, Nothing More

Read permission on a directory grants the ability to enumerate the names stored in it — what `ls` (without `-l`) or the `readdir()` family of calls retrieve. It grants **no** information about the *files themselves* — not their permissions, not their sizes, not their content. Retrieving that additional metadata for each entry (which is what `ls -l` does, and why `ls -l` performs one `stat()` call per entry) requires *execute* permission on the directory as well, covered next, because `stat()`-ing a named entry requires resolving that name, which is an execute-permission operation.

### 3.2 Write (`w`) — Modifying the Mapping Table

Write permission on a directory grants the ability to add new entries (creating files, creating subdirectories, creating symlinks, hard-linking existing files into this directory), remove existing entries (deleting files, `rmdir`-ing empty subdirectories), and rename entries within the directory or move entries into/out of it. Every one of these operations is fundamentally a modification to the parent directory's internal name-to-inode table — not a modification to the target inode itself, which is precisely why write permission on the *file being deleted* is irrelevant to whether the deletion succeeds.

This directory-write-governs-deletion rule has one further wrinkle worth stating precisely: deleting a file requires write **and** execute permission on the directory containing it — write, because you're modifying the table; execute, because removing a specific named entry requires being able to resolve that name in the first place (covered next). Simply having write permission without execute permission on a directory is a rare and largely non-functional combination for this reason.

### 3.3 Execute (`x`) — Traversal and Name Resolution

This is the bit whose meaning departs furthest from any intuitive reading of the word "execute," and it is worth building a precise, standalone mental model for it rather than trying to analogize it to file execution.

Execute permission on a directory grants the ability to **resolve a specific, already-known name within it** — to pass through it as part of a longer path, or to look up metadata (via `stat()`) for a named entry inside it. Crucially, this is *independent* of read permission: a directory can have execute permission without read permission, meaning a process can access `/some/dir/knownfile.txt` directly (if it already knows that exact filename) but cannot run `ls /some/dir` to discover what files exist there in the first place.

This "search-only" configuration — execute without read — is a deliberate, real pattern, not a curiosity. It shows up in scenarios like:

- A directory of user home directories where each user's own subdirectory needs to be traversable by the web server or system processes needing to reach specific known files (like `~/.ssh/authorized_keys` for SSH key-based auth) without granting the ability to enumerate the full list of usernames on the system.
- Shared "drop box" style directories where a process needs to reach a specific, pre-agreed file path without being able to browse the directory's full contents.

The precise rule, stated as cleanly as possible:

> **Execute permission on every directory component in a path is required to resolve that path at all — regardless of what operation you intend to perform once you get there.** Read permission on a directory only affects whether you can *enumerate unknown names*; it plays no role in resolving a name you already know.

### 3.4 Putting the Three Bits Together: A Worked Table

| `rwx` value | Can list contents? | Can access known file by name? | Can create/delete entries? |
|---|---|---|---|
| `---` (0) | No | No | No |
| `r--` (4) | Yes | No (can't resolve into it) | No |
| `-wx` (3) | No | Yes | Yes (if also has `x` for resolution, which it does here) |
| `r-x` (5) | Yes | Yes | No |
| `rwx` (7) | Yes | Yes | Yes |
| `-w-` (2) | No | No | Effectively no — write without execute cannot resolve names to remove |

The `-wx` row deserves a moment's attention because it is genuinely useful and appears deliberately in real configurations: a "write-only, no listing" drop directory, where processes can create new files (mail-drop style spool directories are a classic historical example) or, having been told an exact filename by some other channel, delete a specific entry, but cannot enumerate what else is present — useful for maintaining confidentiality of what other users or processes have dropped into a shared location.

### 3.5 Full Path Resolution Requires Execute on Every Ancestor

A single missing execute bit anywhere along a path breaks resolution of everything beneath it, regardless of how permissive the bits are elsewhere in the chain. Accessing `/home/parsa/projects/notes.txt` requires execute permission on `/`, `/home`, `/home/parsa`, and `/home/parsa/projects` — four separate checks, each independently enforced — before the permission bits on `notes.txt` itself are even consulted. This is why a single overly-restrictive intermediate directory (a project directory accidentally `chmod`'d to `600` instead of `700`, for instance) can silently break access to everything nested beneath it, producing "permission denied" errors that look, superficially, like they should be about the deeply nested target file, when the actual failure occurred several levels higher in the path.

This full-chain requirement is also the underlying mechanism behind a commonly used, legitimate security pattern: restricting a specific user's effective filesystem visibility by controlling execute permission on a small number of well-chosen ancestor directories, rather than needing to lock down every individual file beneath them.

---

## 4. Symbolic Links: Permissions That Almost Don't Exist

Symbolic links are, structurally, one of the simplest objects in the filesystem: an inode whose entire "content" is a stored path string, resolved fresh on every access. Their permission behavior follows directly from that simplicity, but it is different enough from regular files and directories that it warrants dedicated treatment.

### 4.1 Symlink Permission Bits Are (Almost) Never Consulted

On Linux, the permission bits stored on a symlink's own inode are, by long-standing convention and kernel behavior, effectively ignored during normal access — nearly always displayed as `rwxrwxrwx` by tools like `ls -l` regardless of what was actually stamped at creation time, and the kernel does not perform a meaningful permission check against them when resolving the link. What actually governs access is:

1. The permission bits (and full directory-chain resolution rules from Section 3.5) governing **reading the symlink's target path itself** — which is controlled by the *directory containing the symlink*, exactly as any other filename resolution would be.
2. The full permission chain of the **target path** the symlink points to, checked as if the symlink had been transparently substituted for its target and resolution continued from there.

In other words: a symlink does not carry meaningful access control of its own. It is a redirection, and the kernel's permission enforcement happens entirely against the directory holding the symlink (for resolving the link itself) and the ultimate target path (for whatever operation is actually being attempted).

### 4.2 Ownership of a Symlink vs. Ownership of Its Target

A detail that surprisingly often matters in practice: a symlink has its *own* independent owner and group, set at creation time to the creating process's identity, exactly as any other new inode would be — completely independent of the ownership of whatever file it points to. `chown`-ing a symlink by default actually changes the ownership of its *target* (following the link, which is the default behavior of most tools including `chown` itself, unless the `-h`/`--no-dereference` flag is explicitly used to operate on the symlink inode itself rather than through it). This dereference-by-default behavior across most file-manipulating tools is a frequent source of "why did chown-ing this symlink change ownership of a completely different file" confusion, and it is worth remembering as a deliberate design choice: tools default to treating symlinks as transparent redirections precisely because that is what they exist to be, in the overwhelming majority of use cases.

### 4.3 Dangling Symlinks and Symlink Ownership as an Attack Surface

A symlink whose target does not (or no longer) exists is called "dangling" — it resolves as a valid directory entry but any attempt to actually open the target fails. Dangling symlinks are permission-relevant in a specific, security-critical way: because *any* user with write access to a shared, world-writable directory (a classic example being `/tmp`) can create a symlink there pointing anywhere else on the filesystem their own read/write permissions allow, symlinks in shared directories have historically been a vector for a class of attacks generally called **symlink attacks** or **TOCTOU (time-of-check to time-of-use) races** involving predictable filenames in world-writable locations — a privileged process checks whether a file exists or has certain properties, an attacker swaps in a symlink to a sensitive target in the narrow window before the process actually opens it, and the privileged process ends up operating on the attacker-chosen target instead of the file it intended to touch. This exact class of vulnerability is covered in operational depth in Chapter 9; it is introduced here because it is fundamentally a consequence of the permission facts established in this section — that creating a symlink is governed purely by the *containing directory's* write permission, with no permission check whatsoever on what the link is allowed to point to.

---

## 5. Device Files: Permissions Gating Hardware Access

Character and block device files (`/dev/sda`, `/dev/tty`, `/dev/null`, and so on) are, from a permission-model standpoint, treated almost identically to regular files: the same nine-bit triad, the same owner/group/other check sequence. What differs is entirely in *what the operations mean* once permission is granted.

Read and write permission on a block device like `/dev/sda1` gate raw, unmediated access to the underlying storage — bypassing the filesystem layer entirely. A process with read access to a raw block device can read every byte of every file on that partition regardless of the individual files' own permissions, because it is reading beneath the filesystem abstraction, not through it. This is precisely why raw block device nodes are, by default, only accessible to root or a narrowly scoped group (historically `disk` on many distributions) — granting a regular user read access to `/dev/sda1` is functionally equivalent to granting them read access to every file on that partition, permission bits notwithstanding, because the filesystem-level permission enforcement described throughout this series happens at a layer entirely above raw block access.

Character devices carry the same principle with device-specific consequences: write access to `/dev/mem` (where available and not disabled by kernel hardening) is effectively equivalent to unrestricted physical memory access; read access to an input device node under `/dev/input/` can expose raw keystrokes. This is why udev rules — the modern mechanism controlling device node ownership and permissions as hardware is dynamically detected — are treated as a security-sensitive configuration surface, not merely a convenience layer; incorrect device permissions can trivially undermine the entire filesystem-level permission model this series otherwise describes, simply by offering a lower-level path to the same underlying data.

---

## 6. Named Pipes and Sockets: Permissions on Communication Endpoints

FIFOs (named pipes) and Unix domain sockets are unusual among filesystem objects in that they do not represent stored data at all — they are communication endpoints that merely have a *name* in the filesystem namespace, used purely as a rendezvous point for unrelated processes to find each other and establish a connection.

Permission bits on a FIFO gate who can `open()` it for reading or writing to participate in the pipe — governing who can join the communication channel, not any notion of stored content, since a FIFO has none. The same directory-resolution rules from Section 3 apply identically to locating the FIFO's path in the first place.

Unix domain sockets follow a closely related but historically inconsistent pattern worth flagging explicitly: while a socket file does carry permission bits, and `bind()`-ing a socket to a filesystem path does create an inode subject to normal ownership rules (owned by the creating process, permissions influenced by `umask`, covered in Chapter 5), *connecting* to an existing socket has, on Linux, historically been permission-checked somewhat inconsistently across kernel versions and configurations compared to how strictly regular file access is checked — a nuance that has led many production systems handling sensitive local IPC (inter-process communication) to layer additional access control on top of raw socket file permissions, rather than relying on them as the sole gate. This is a case where understanding the permission model's edges — where the clean, uniform triad-based story genuinely gets murkier — matters as much as understanding the clean cases.

---

## 7. The Complete Kernel Decision Algorithm, Formalized

Chapter 1 gave a simplified version of the kernel's decision sequence. This section formalizes it completely, incorporating every detail this chapter and the previous one have established, because the full, precise algorithm is what actually explains every edge case a working administrator eventually runs into.

```
function check_access(process, inode, requested_op):

    # Step 0 — capability short-circuit (full treatment in Chapter 8)
    if process has an applicable CAP_* capability
       that covers requested_op unconditionally:
        return GRANTED

    # Step 1 — owner match
    if process.euid == inode.uid:
        return evaluate(inode.owner_bits, requested_op)

    # Step 2 — group match (primary OR any supplementary GID)
    if process.egid == inode.gid
       or inode.gid in process.supplementary_gids:
        return evaluate(inode.group_bits, requested_op)

    # Step 3 — fallback
    return evaluate(inode.other_bits, requested_op)
```

A handful of properties of this algorithm are worth stating as explicit, memorable rules, because each one resolves a specific class of real-world confusion:

- **Category matching is exclusive and ordered.** The first matching category (owner, then group, then other) is used, full stop — the kernel never combines or takes the most permissive result across categories. This is the formal restatement of Chapter 1's "owner bits govern even if they're more restrictive" rule.
- **Group matching checks the full supplementary set, not just the primary GID.** A process matches the group category if *any* of its GIDs — primary or supplementary — equals the inode's group. This is why a user in ten different groups can gain group-level access to files owned by any one of them, exactly as Chapter 2's identity model would predict.
- **Capabilities can short-circuit the entire triad-matching process.** Chapter 8 covers this fully, but it belongs in this formalized algorithm because it is the modern mechanism by which "root-like" privilege gets granted for specific operations without falling through to the ordinary DAC check at all — a process holding, for instance, `CAP_DAC_OVERRIDE` bypasses file permission checks entirely, regardless of what category it would otherwise have matched.
- **`requested_op` is resolved against type-specific semantics.** "Evaluate the bits for this operation" means something different for a directory's write bit than a regular file's write bit, as this entire chapter has detailed — the algorithm's *structure* is uniform across object types, but the meaning plugged into `requested_op` is not.

---

## 8. Multi-Step Operations and Compound Checks

Several everyday operations are not single permission checks but a *sequence* of checks against multiple objects, and understanding the full sequence explains failures that otherwise look inconsistent.

### 8.1 Moving/Renaming a File Within the Same Filesystem

`mv oldname newname` (when both are on the same filesystem, allowing an efficient in-place rename rather than a copy-and-delete) requires:

- Write **and** execute permission on the directory currently containing `oldname` (removing the old entry).
- Write **and** execute permission on the directory that will contain `newname` (adding the new entry) — which may be the same directory, for a simple rename, or a different one, for a move.
- No permission check whatsoever against the file's own bits, or against its owner — consistent with everything Section 3 established about deletion and renaming being purely directory-level operations.

A specific, frequently surprising consequence: a completely unwritable, root-owned file can be renamed or moved by any user who has write access to its containing directory, because renaming, like deleting, is a directory-table operation, not a file-content operation. The file's own restrictive permissions offer no protection against this at all — only its parent directory's permissions do. This exact fact motivates the **sticky bit**, covered fully in Chapter 6, which exists specifically to close this gap in shared, world-writable directories.

### 8.2 Copying a File

`cp source dest` is, by contrast, genuinely a content operation and requires read permission on `source` and — for the destination — the same directory-write-and-execute requirements as creating any new file, plus, if `dest` already exists, write permission on the existing `dest` inode itself (since copying onto an existing file is a content-overwrite, a `write()`-class operation, not a directory-table operation). This is a useful contrast case to hold alongside Section 8.1's rename example precisely because the two operations look superficially similar to a casual user but check completely different things.

### 8.3 Hard-Linking

Creating a hard link (`ln existing new_name`) links a *new directory entry* to an *already-existing inode*, without duplicating any data. This requires write and execute permission on the directory that will contain `new_name`, but — notably — does **not** require any permission on the target inode itself beyond it existing and being on the same filesystem (hard links cannot cross filesystem boundaries, a constraint covered in Chapter 2's inode discussion). This is another clean illustration of the "operations on names live in directory permission space, operations on content live in inode permission space" divide that runs through this entire chapter.

---

## 9. Mount-Level Restrictions: Permissions Above the Filesystem Layer

Everything discussed so far concerns per-inode permission bits. Linux additionally supports restrictions applied at the **mount point** level, which interact with, and can override, the underlying filesystem's own permission bits — worth introducing here because they are easy to forget about when permission bits alone don't explain observed behavior.

| Mount option | Effect |
|---|---|
| `noexec` | Disables execution of any binary or script located on this mount, regardless of the file's own execute bit |
| `nosuid` | Disables the effect of SUID/SGID bits (Chapter 6) for any executable on this mount |
| `nodev` | Disables interpretation of device files located on this mount as actual devices |
| `ro` | Mounts the filesystem read-only, overriding any individual file's write bit |

These are commonly applied to mount points where untrusted or semi-trusted content is expected to reside — `/tmp`, removable media, user-uploaded file storage mounted as a separate filesystem — specifically because per-file permission bits alone are considered an insufficient guarantee in those contexts: a `noexec` mount, for instance, defends against a scenario where an attacker manages to write an executable file with permissive bits into a directory, by making the *mount itself* refuse to execute anything there regardless of what the individual file's own bits say. This is a direct, practical illustration of defense in depth applied specifically to the permission model — an additional, coarser-grained layer of restriction sitting above the fine-grained, per-inode layer this chapter has otherwise focused on, covered further as a hardening technique in Chapter 9.

---

## 10. Common Misconceptions Worth Retiring Now

- **"A file's write permission controls whether it can be deleted."** It does not, at all — deletion is governed entirely by the parent directory's write and execute bits, a rule repeated throughout this chapter because it is the single most consequential correction to the naive model.
- **"Read permission on a directory is enough to access files inside it by name."** It is not — execute permission is what governs name resolution; read permission only governs *enumeration* of unknown names.
- **"Symlink permissions matter."** They almost never do, in practice — access is governed by the containing directory (for the link itself) and the target path's own full permission chain (for whatever the link points to).
- **"chown on a symlink changes the symlink's own ownership."** By default, most tools dereference and change the *target's* ownership instead; explicit no-dereference flags are required to operate on the link inode itself.
- **"Renaming or moving a file requires permission on the file."** It requires permission on both directories involved in the operation — the file's own bits are not consulted at all for this specific operation.
- **"Device file permissions are just like regular file permissions, with lower stakes."** They frequently gate access to raw, filesystem-bypassing hardware operations, making misconfigured device permissions capable of undermining the entire rest of the permission model in one step.

---

The next chapter moves from *reading* permission state to actively *manipulating* it — a complete reference on symbolic and numeric `chmod` syntax, including relative modifications, multi-target operations, and the subtleties of how each form interacts with a process's `umask`, which the following chapter after that covers as a dedicated topic in its own right.
