# Access Control Lists

Every chapter up to this point has operated within a single, unbroken structural constraint: exactly three permission categories per file — owner, group, other — as established in Chapter 1 and never violated since. This constraint is not a limitation of imagination; it is baked into the twelve-bit mode field itself, which simply has no room to express a fourth category, let alone an arbitrary number of them. This chapter covers the mechanism that breaks past that constraint entirely: POSIX Access Control Lists, which allow a single file to carry permission entries for any number of specific users and groups, well beyond the traditional triad.

---

## 1. The Structural Problem ACLs Solve

Consider a genuinely common real-world requirement that the traditional model, no matter how creatively applied, cannot satisfy: a file needs to be readable by its owner, read-write for one specific collaborator who is not in the owner's primary group, read-only for a second collaborator in a completely different group, and inaccessible to everyone else. The traditional triad offers exactly one group slot — there is no way to grant one specific outside user read-write access and a different specific outside user read-only access using only owner/group/other, short of creating a bespoke group for every unique permission combination ever needed, which becomes operationally unmanageable at any real scale (a system with even a modest number of users needing varied, overlapping sharing arrangements would require a combinatorial explosion of narrowly-scoped groups, each existing for exactly one sharing relationship).

This is precisely the gap ACLs close: they allow arbitrary, per-user and per-group permission entries to be attached directly to a single file or directory, without requiring the group structure itself to be redesigned around every specific sharing need. Chapter 2's group-based model remains fully intact and continues to function underneath ACLs — ACLs are an *addition* layered on top of the traditional model, not a replacement for it, and understanding that layering relationship precisely is the core of this chapter.

---

## 2. ACL Structure: Named Entries Beyond the Triad

A POSIX ACL is a list of entries, each pairing a **qualifier** (who this entry applies to) with a **permission set** (what they're granted). The qualifier types available are:

| Qualifier | Meaning |
|---|---|
| `user::` | The file owner — the traditional owner triad, now expressed as an ACL entry |
| `user:name:` | A **named** additional user, beyond the owner |
| `group::` | The file's owning group — the traditional group triad, as an ACL entry |
| `group:name:` | A **named** additional group, beyond the owning group |
| `mask::` | A ceiling that caps the *effective* permissions of every named-user and named-group entry (covered fully in Section 4) |
| `other::` | Everyone not covered by any of the above — the traditional other triad |

Notice something structurally important in this list: the traditional owner, group, and other categories from every previous chapter are not discarded or bypassed by ACLs — they are simply re-expressed as the `user::`, `group::`, and `other::` entries, which remain mandatory, always-present entries in any ACL. Every file, whether it has additional named entries or not, technically has at least these three base entries; a "traditional," ACL-free file is simply one whose ACL consists of exactly these three entries and nothing more — which is why viewing a perfectly ordinary file's ACL with `getfacl` (Section 5) shows familiar output even for files that have never had `setfacl` run against them at all.

---

## 3. Setting and Reading ACLs

### 3.1 `setfacl` — Adding and Modifying Entries

```
setfacl -m u:sara:rw file.txt
```

This grants the specific named user `sara` read-write access to `file.txt`, entirely independent of whatever group she may or may not share with the file's owner. The `-m` flag means "modify" — add or update this specific entry without disturbing the rest of the ACL, a relative operation conceptually similar to symbolic `chmod`'s `+`/`-` behavior from Chapter 4, though the underlying syntax and semantics are ACL-specific rather than reusing `chmod`'s exact grammar.

```
setfacl -m g:developers:rx file.txt
```

Analogously, this grants the *group* `developers` (distinct from the file's own owning group) read-and-execute access — precisely the "second, independent group slot" capability Section 1 identified as impossible under the traditional model.

Multiple entries can be set in a single invocation, comma-separated:

```
setfacl -m u:sara:rw,g:developers:rx,u:ali:r file.txt
```

### 3.2 `getfacl` — Reading the Complete ACL

```
$ getfacl file.txt
# file: file.txt
# owner: parsa
# group: parsa
user::rw-
user:sara:rw-
group::r--
group:developers:r-x
mask::rwx
other::r--
```

This output format is worth reading carefully, entry by entry, because it directly mirrors the qualifier structure from Section 2: the `# owner:` and `# group:` comment lines report the traditional ownership metadata (exactly as Chapter 2 described), while the entries below represent the full ACL — the mandatory `user::`, `group::`, and `other::` entries alongside the additional named `user:sara:` and `group:developers:` entries this specific file has had explicitly added.

---

## 4. The Mask: A Ceiling on Named Entries, Not a Fourth Category

The `mask::` entry visible in the `getfacl` output above is the single most misunderstood element of the entire ACL system, and it deserves careful, precise treatment, because getting it wrong produces genuinely confusing, seemingly-inconsistent behavior in practice.

### 4.1 What the Mask Actually Does

The mask is **not** a permission category applied to any specific identity, the way owner/group/other are. It is instead a **ceiling** — an upper bound — applied to the *effective* permissions of every named-user entry and every named-group entry (as well as the traditional owning-group entry, when any named entries are present at all), computed as a bitwise AND between each entry's own listed permissions and the mask value.

Concretely: if `sara`'s entry grants `rw-`, but the file's `mask::` is set to `r--`, then `sara`'s **effective** permission is `r--` — the write bit her own named entry lists is capped away by the more restrictive mask, even though her entry, read in isolation, appears to grant it. This is precisely why `getfacl`, when a named entry's nominal permissions exceed the mask, prints an explicit `#effective:` annotation showing the actually-applied result:

```
user:sara:rw-      #effective:r--
```

### 4.2 Why the Mask Exists: Backward Compatibility With `chmod`

The reasoning behind the mask's existence connects directly back to Chapter 4's material and is worth stating precisely, because it is not an arbitrary design choice — it solves a genuine compatibility problem. Before ACLs existed, the "group" position in a traditional `ls -l` / `chmod` mode string had one single, unambiguous meaning: the permissions granted to the owning group. Once a file can carry an arbitrary number of *additional* named-user and named-group entries, that single group-position digit in `chmod`'s traditional numeric or symbolic notation can no longer meaningfully represent all of those entries simultaneously — there's no way for a single three-bit value to summarize a potentially large, heterogeneous list of named entries.

The mask is the resolution to this: on a file with an ACL, the group position historically displayed by `ls -l` and manipulated by traditional `chmod` is **redefined to represent the mask value**, not the owning group's own entry directly. This means that running a traditional `chmod g=rx file.txt` on a file that already has named ACL entries doesn't change what the owning group specifically can do in isolation — it changes the *mask*, which in turn re-caps every named entry's effective permissions simultaneously. This is precisely why administrators who are unaware a file has an ACL can be surprised when a seemingly ordinary `chmod` command has a much broader effect than expected, silently capping down access for every named `setfacl` entry the file carries, not just the owning group — a direct, practical consequence of the mask mechanism worth understanding precisely rather than treating as unpredictable "ACL weirdness."

### 4.3 Recomputing the Mask Automatically

By default, `setfacl` automatically recomputes the mask to the union (bitwise OR) of every named entry's permissions whenever an entry is added or modified, unless the mask is explicitly set with its own `-m m::` clause — meaning, in ordinary usage, the mask tends to "just work" as an unobtrusive maximum-permissive ceiling that rarely actually restricts anything unless deliberately narrowed, or unless a subsequent traditional `chmod` (per Section 4.2) narrows it as a side effect. It is nonetheless worth explicitly verifying the mask via `getfacl` whenever named entries appear to not be taking effect as expected — the mask is, in the overwhelming majority of real troubleshooting cases involving "why isn't this ACL entry working," the actual root cause.

---

## 5. ACL Evaluation Order: How the Kernel Actually Decides

This section formalizes the ACL-aware version of Chapter 3's kernel decision algorithm — the exact sequence the kernel follows when a file carries a non-trivial ACL (more than just the three mandatory base entries), because the presence of named entries genuinely changes the evaluation order compared to the traditional-only case.

```
function check_access_with_acl(process, inode, requested_op):

    if process.euid == inode.uid:
        return evaluate(acl.user_owner_entry, requested_op)   # user:: entry

    if a named "user:UID:" entry exists matching process.euid:
        effective = named_user_entry AND acl.mask
        return evaluate(effective, requested_op)

    if process.egid == inode.gid
       or any named "group:GID:" entry matches process's supplementary GIDs:
        # collect ALL matching group entries (owning group AND any named group entries)
        combined = union of every matching group entry's permissions
        effective = combined AND acl.mask
        return evaluate(effective, requested_op)

    return evaluate(acl.other_entry, requested_op)
```

Several details in this formalized sequence are worth calling out explicitly, because each resolves a specific point of confusion relative to the traditional-only algorithm from Chapter 3:

**Named-user entries take priority over group-based entries, but not over the owner match.** If the requesting process's effective UID matches the file's actual owner, the `user::` entry governs, exactly as in the traditional model — a named `user:owner_name:` entry, even if one happened to exist naming the owner explicitly (an unusual but not forbidden configuration), would not be separately consulted, since the owner match via `user::` takes precedence in the evaluation order.

**Multiple matching group-category entries are combined, not evaluated exclusively.** This is a genuine departure from the traditional model's strict "first matching category wins, only one triad's bits apply" rule from Chapter 3. Under ACLs, if a process's supplementary groups match *both* the file's traditional owning group *and* one or more named group entries, **all** of those matching entries' permissions are combined (via union) before the mask is applied — a meaningfully different, more permissive-by-default aggregation behavior than the traditional model's strict single-category selection, worth understanding precisely since it means adding a permissive named group entry can grant access to users who are also, coincidentally, members of the file's own more restrictive owning group, in a way the traditional model's exclusive-category logic would never have permitted.

**The mask applies to every named entry and to the combined group result, but never to the owner (`user::`) or other (`other::`) entries.** This asymmetry is deliberate and worth stating explicitly: the mask exists specifically to provide a single, `chmod`-compatible ceiling over the *variable, potentially-large* set of named entries a file might carry (Section 4.2's compatibility rationale), a concern that simply doesn't apply to the always-exactly-one owner entry or always-exactly-one other entry, which retain their traditional, unmasked, direct meaning throughout.

---

## 6. Default ACLs: Directory-Level Inheritance

Section 3 covered ACLs applied to individual files. This section covers a distinct, directory-specific feature — **default ACLs** — which serve a role for named ACL entries directly analogous to the role SGID (Chapter 6, Section 3.2) serves for group ownership: automatic propagation to newly created entries, without requiring every single new file to have `setfacl` run against it individually and manually.

### 6.1 Setting a Default ACL

```
setfacl -d -m g:developers:rwx shared_project/
```

The `-d` flag marks this entry as a **default** entry rather than an **access** entry — access entries (Section 3) govern access to the directory itself, exactly as covered so far, while default entries govern what ACL gets automatically applied to anything newly created *inside* the directory. A directory can, and typically does, carry both simultaneously: its own access ACL governing direct access to the directory, and a separate default ACL template that gets copied onto every new child.

### 6.2 The Inheritance Mechanism, Precisely

When a new file or subdirectory is created inside a directory carrying a default ACL, the new object's **access ACL is initialized from the parent's default ACL**, rather than starting as a bare traditional-only ACL. For newly created subdirectories specifically, the parent's **default ACL is also copied onto the new subdirectory as its own default ACL**, causing the propagation to continue recursively through the tree — precisely mirroring SGID's recursive directory-to-subdirectory inheritance behavior from Chapter 6, but for the full richness of named ACL entries rather than merely the single group-ownership field SGID governs.

This is worth stating as an explicit, combined operational picture, connecting directly back to Chapter 6's SGID material and Chapter 5's `umask` material, because a genuinely well-configured collaborative directory in a modern environment typically layers **all three** mechanisms deliberately together: SGID (for consistent group *ownership*, Chapter 6), a considered `umask` (for base permission-bit defaults, Chapter 5), and a default ACL (for any named-user or named-group access beyond what the base owner/group/other triad alone could express) — each mechanism solving a genuinely distinct piece of the overall "new files in this shared directory should automatically have sensible, complete access control" requirement, none of them substituting for or automatically implying the others.

### 6.3 Interaction With `umask` at Creation Time

Default ACLs and `umask` interact in a way worth stating precisely, because it resolves an otherwise-confusing overlap between two mechanisms that both, in some sense, govern "what permissions does a new file get." When a directory has a default ACL, newly created files within it derive their initial permissions primarily from the default ACL's entries rather than from the traditional `umask`-filtered computation described in Chapter 5 — but `umask` is not entirely bypassed; it still filters the mask entry of the resulting new ACL in an analogous way to how it would filter a traditional mode, meaning `umask`'s influence persists, just applied one level differently (against the ACL mask rather than directly against the traditional group bits) when a default ACL is present, rather than governing the outcome directly and exclusively as it does for ACL-free directories.

---

## 7. ACLs and the Traditional Tools: What Still Works, What Changes

### 7.1 `chmod` Still Works, With the Caveat From Section 4.2

Traditional `chmod` remains fully functional on ACL-bearing files, but — as already established — its effect on the "group" position is redefined to mean "set the mask," not "set the owning group's own entry directly," once any named ACL entries are present. This is not a limitation exactly, but it is a semantic shift worth remembering any time traditional `chmod` and ACLs are used together on the same file, which is an entirely normal and expected combination in practice, not something to be avoided — the two mechanisms are designed to coexist, provided the mask-redefinition behavior is understood rather than assumed away.

### 7.2 `ls -l`'s `+` Indicator

Files carrying a non-trivial ACL (any named entries beyond the three mandatory base ones) are flagged by `ls -l` with a trailing `+` after the traditional permission string:

```
-rw-rw-r--+ 1 parsa parsa 4096 Jul 19 10:00 file.txt
```

This `+` is the single, reliable, at-a-glance signal that a file's *actual, effective* access control is broader or more complex than the traditional nine-character string alone represents — and it is worth treating its absence or presence as a standing habit-forming check: any time `ls -l` output needs to be trusted as a complete description of who can access a file, the presence of a trailing `+` is the cue that `getfacl` needs to be consulted for the real, complete picture, since the traditional columns alone are, in that case, actively incomplete rather than merely simplified.

### 7.3 Copying and Archiving: ACLs Do Not Always Survive

A genuinely important operational caution, worth stating explicitly because it is a common source of silent, unintended access-control loss: not every file-copying or archiving tool preserves ACLs by default. Plain `cp` without the `-p` (or `--preserve=all`) flag, and many older or minimally-configured archiving and backup tools, copy only the traditional mode bits and ownership, silently dropping any named ACL entries in the process — meaning a file carefully configured with specific named-user and named-group access can, if copied or backed up carelessly, be restored or duplicated with only its traditional triad intact and every named entry gone, with no error or warning at all. `rsync` requires an explicit `-A` (or the encompassing `-a` combined with the right options depending on version) to preserve ACLs; `tar` requires equivalent explicit ACL-preservation flags or extended-attribute support to be enabled. This is worth treating as a standing checklist item for any backup, migration, or replication process handling files that carry meaningful ACL configuration — verifying ACL preservation explicitly, rather than assuming standard file-copying behavior captures the complete access-control picture established throughout this chapter.

---

## 8. When ACLs Are the Right Tool, and When They Are Not

This closing section is deliberately opinionated in a narrow, practical sense, because ACLs, despite solving a genuine structural gap, are not universally the right solution to every sharing requirement, and understanding when the traditional model (potentially combined with SGID, per Chapter 6) is preferable is as important as knowing ACLs exist at all.

**ACLs are the right tool when:** access requirements are genuinely heterogeneous and don't map cleanly onto a small, stable set of groups — a handful of specific external collaborators needing access to a handful of specific files, access grants that change frequently on a per-individual basis, or situations where creating a dedicated group for every unique sharing relationship would produce group-management overhead disproportionate to the actual need.

**The traditional model, likely combined with a well-chosen group structure and SGID, remains preferable when:** the access pattern is stable and maps naturally onto a small number of well-defined roles — "everyone on the backend team," "everyone in the finance department" — where creating and maintaining a real, meaningful group is not overhead but is in fact the more auditable, more comprehensible long-term solution. ACLs scattered across many individual files, each with their own bespoke set of named entries, are considerably harder to audit holistically ("who can access what") than a smaller number of well-organized groups with traditional permissions, precisely because ACL entries are inherently per-file rather than centrally, uniformly managed the way group membership is (Chapter 2) — a genuinely important operational trade-off, not merely a stylistic preference, and one worth weighing deliberately rather than reaching for ACLs as a default whenever the traditional triad feels momentarily insufficient for a specific, possibly one-off, sharing need.

---

## 9. Common Misconceptions Worth Retiring Now

- **"ACLs replace the traditional owner/group/other model."** They extend it — the traditional triad remains present as the mandatory `user::`, `group::`, and `other::` entries, and continues to function exactly as described throughout every earlier chapter for files that never receive any additional named entries.
- **"The mask is a fourth permission category, like a second 'other.'"** It is not a category at all — it's a ceiling applied to named entries and the combined group result, never a permission grant in its own right, and never applied to the owner or true-other entries.
- **"Running `chmod g=rx` on an ACL file changes only the owning group's access."** Once named entries exist, it redefines the mask, simultaneously re-capping every named entry's effective permissions — a broader effect than the traditional-model-only mental model would predict.
- **"If a process matches both the owning group and a named group entry, only one of those entries' permissions applies, exactly like the traditional exclusive-category model."** Under ACLs, matching group-category entries are combined via union before the mask is applied — a genuinely more permissive aggregation behavior than Chapter 3's strict single-category-wins rule.
- **"Copying a file with a normal `cp` or a default backup tool preserves its full access control."** Many common tools silently drop ACL entries unless explicitly configured to preserve them, a real and easy-to-overlook data-integrity gap for any access-control-sensitive file.

---

The next chapter moves to a related but structurally distinct expansion of the base permission model: extended attributes and Linux capabilities — covering how capabilities decompose "what root can do" into individually grantable privileges (previewed in this series' SUID discussion in Chapter 6), and how extended attributes provide a general-purpose metadata mechanism used not only for capabilities but for immutability flags, security labels, and other file-level properties that sit entirely outside the permission-bit and ACL model this chapter and its predecessors have covered.
