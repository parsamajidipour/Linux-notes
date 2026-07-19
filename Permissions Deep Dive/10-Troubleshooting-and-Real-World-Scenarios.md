# Troubleshooting and Real-World Scenarios

This closing chapter is deliberately different in shape from everything before it. Chapters 1 through 9 built a complete mechanism-level model, layer by layer — DAC fundamentals, identity, the permission triad, notation, defaults, special bits, ACLs, capabilities, and hardening. This chapter assumes that entire model as background and turns it into a working diagnostic tool: a systematic method for taking an unexplained "permission denied" and tracing it, deterministically, to its actual root cause — plus a set of fully worked, realistic scenarios that exercise the full stack this series has built.

The goal is not to give you a list of things to try. It is to give you an *ordered elimination sequence* that always converges on the true cause, because at every step you know precisely what mechanism you're ruling in or out and why.

---

## 1. The Full Diagnostic Sequence

Every permission failure on a Linux system traces back to exactly one of the mechanisms this series has covered, evaluated in a specific order that mirrors the kernel's own layered enforcement — capability short-circuits, then DAC, then ACL refinement, then MAC policy, then mount-level restriction. A correct diagnostic walks this same order, because checking steps out of order wastes time re-litigating layers that were never the actual cause.

```
1. Identify the exact operation and exact path being denied
2. Confirm the requesting process's actual identity (UID/GID/supplementary groups)
3. Walk the full path, checking directory execute permission at every ancestor
4. Check the target's own owner/group/other bits against the matched category
5. Check for a non-trivial ACL and its mask
6. Check for capability requirements or absence
7. Check for MAC policy denial (SELinux/AppArmor)
8. Check for mount-level restrictions
9. Check for special bits (immutable, sticky) producing non-obvious behavior
```

Each numbered step below expands this into the specific commands and reasoning, tied directly back to the chapter that established the underlying mechanism.

### Step 1 — Identify the Exact Operation and Path

This sounds trivial but is worth stating precisely, because a vague symptom report ("I can't access my file") conflates operations that check entirely different things, per Chapter 3: reading content, writing content, deleting, renaming, and traversing all have different governing rules. The very first diagnostic action is pinning down: is this a read, a write, an execute, a delete, or a traversal failure — and against which exact path? Error messages and `strace` output (Section 1.9) are the most reliable source for this, since a human description of "can't access" is frequently imprecise about which specific operation actually failed.

### Step 2 — Confirm Actual Requesting Identity

Per Chapter 2's entire model, never assume the identity you expect is the identity actually in effect. `id` run *as the actual failing process's context* — not as whichever shell you happen to be debugging from — is the ground truth:

```
$ sudo -u targetuser id
uid=1005(alice) gid=1005(alice) groups=1005(alice),27(sudo)
```

This step alone resolves a surprising fraction of real cases, particularly the stale-session trap from Chapter 2, Section 8.3 — a user recently added to a group whose *current* session predates that change still carries the old, pre-update supplementary group list, and no amount of staring at `/etc/group`'s current, correct contents will explain a failure rooted in a stale, already-resolved session.

### Step 3 — Walk the Full Path

Per Chapter 3, Section 3.5, a single missing execute bit anywhere in the ancestor chain breaks everything beneath it, and the resulting error can look, superficially, like it's about the deep target file when the actual failure is several levels up. `namei -l` is the direct tool for this, walking the entire path and printing permissions for every component in one pass:

```
$ namei -l /home/parsa/projects/private/notes.txt
f: /home/parsa/projects/private/notes.txt
drwxr-xr-x root   root   /
drwxr-xr-x root   root   home
drwx------ parsa  parsa  parsa
drwxr-xr-x parsa  parsa  projects
drwx------ parsa  parsa  private
-rw-r--r-- parsa  parsa  notes.txt
```

In this example, `private`'s `700` permissions immediately explain why any user other than `parsa` fails to reach `notes.txt`, regardless of how permissive the file's own `644` bits look in isolation — a direct, visual confirmation of Chapter 3's full-chain requirement, and a single command that would have saved considerable confusion in any diagnostic session that instead started by staring only at the target file's own permissions.

### Step 4 — Check Owner/Group/Other Against the Matched Category

Once path traversal is confirmed clear, apply Chapter 3's formalized `check_access()` algorithm by hand, precisely: which category does the identity from Step 2 actually match — owner, group, or other — and, critically, per Chapter 1's repeated warning, remember that **the first match wins even if it's more restrictive than a later category would have been.** A file that's `rwx------` for its owner but `rwxrwxrwx` for group and other still denies the owner nothing except what the owner triad itself grants, which is `rwx` — full access — so this specific configuration isn't actually a trap; but a `------rwxrwx` configuration (unusual, but worth knowing to check for) genuinely would deny the owner while granting everyone else access, precisely because owner-category matching happens first and exclusively.

### Step 5 — Check for a Non-Trivial ACL

The `+` suffix on `ls -l` output (Chapter 7, Section 7.2) is the fast visual check; `getfacl` is the authoritative one. This step specifically catches the class of failure Chapter 7, Section 4.2 flagged — a `chmod` that looked like it should have granted access, but actually only adjusted the mask, silently capping down named entries the traditional mode-string view doesn't fully represent.

### Step 6 — Check for Missing (or Unexpectedly Present) Capabilities

Relevant specifically when the failing operation is something a normal DAC-permitted user genuinely cannot do regardless of file permissions — binding a low port, for instance — where the actual fix is a capability grant (Chapter 8, Section 2.4) rather than any file-permission adjustment at all, a distinction worth confirming early since no amount of `chmod` or `chown` will ever resolve a fundamentally capability-gated operation.

### Step 7 — Check for MAC Policy Denial

This is the step most commonly skipped by administrators who learned permissions only through the DAC model this series spent nine chapters on, and it is precisely the gap Chapter 9, Section 6 exists to close conceptually. On a system with SELinux in enforcing mode, a process can hold every correct DAC permission this entire series has covered and still be denied, because MAC evaluates independently and additionally, not as a subset of DAC. The diagnostic signature is worth recognizing precisely: a "permission denied" error occurring despite `namei -l`, `getfacl`, and `id` all checking out completely clean is close to a definitive signal that the actual cause sits outside everything this series' Chapters 1 through 8 covered, and `journalctl` or `dmesg` filtered for `avc: denied` (SELinux's audit log signature) is the correct next diagnostic action, not further re-scrutiny of DAC permissions that have already been confirmed correct.

### Step 8 — Check for Mount-Level Restrictions

Per Chapter 3, Section 9 — a `noexec` mount silently defeats execution regardless of a file's own `755` bits looking entirely correct; `mount | grep <path>` or checking `/proc/mounts` directly for the relevant mount point's options is the fast confirmation.

### Step 9 — Check Special Bits Producing Non-Obvious Behavior

Per Chapter 8, Section 1.5 — the immutable flag (`lsattr`) blocks writes and deletes with an error that can look, on cursory inspection, like an ordinary permission failure, despite every DAC, ACL, and capability check being entirely correct; this is worth checking specifically whenever a write or delete fails despite Steps 1 through 8 all appearing to permit it.

---

## 2. Worked Scenario One: "I Can't Delete This File, But I Own It"

**Symptom:** A user reports that `rm myfile.txt` fails with "Operation not permitted," despite `ls -l myfile.txt` showing they are the file's owner with full `rwx` permission on it.

**Diagnosis, following the sequence:** Step 4 looks clean — the user is the owner, and owner bits grant full access. This immediately should redirect attention away from the file's own bits entirely, per Chapter 3's core repeated lesson that deletion is a *directory* operation. Running `namei -l` on the containing directory reveals:

```
drwxrwxrwt root parsa shared_uploads
```

The trailing `t` — sticky bit set (Chapter 6, Section 4.3) — combined with the directory being owned by `root`, not the user attempting the deletion. Per Chapter 6, Section 4.2's precise mechanism, a sticky directory restricts deletion to the file's *own* owner, the *directory's* owner, or a privileged process — and the user in this scenario, despite owning the file itself, does not own the containing directory. Wait — but the mechanism explicitly permits deletion by the *file's own owner* regardless of directory ownership, so this specific combination should actually succeed. The real diagnostic value here is in correctly ruling this out: if the user genuinely owns the file, sticky bit alone doesn't explain the denial, and the correct next step is re-verifying Step 2 — is the process actually running with the UID the user expects, or has some intermediate mechanism (a `sudo` wrapper, a SUID launcher, a container namespace remapping UIDs) resulted in the deleting process's *effective* UID not actually matching the file's stored owner UID at all, despite `ls -l`'s human-readable name display appearing to match superficially. In the actual resolved case, the file had been created by a different process running under a UID that happened to *resolve to the same displayed username* in one identity backend but not the one the `rm` command's shell was actually resolving against — a NSS/SSSD misconfiguration (Chapter 2, Section 4) causing inconsistent UID resolution across different parts of the system, where the numeric UID stamped on the file didn't actually match the numeric UID the current shell's identity resolved to, despite both displaying the same username string. `stat --format='%u' myfile.txt` compared directly against `id -u` (raw numeric comparison, bypassing any name-resolution ambiguity entirely) is what actually surfaces this class of mismatch unambiguously.

**Lesson:** Never trust displayed usernames as confirmation of UID match, per Chapter 2's foundational "number is truth, name is a view" framing — always drop to raw numeric comparison when ownership-based reasoning isn't producing the expected result.

---

## 3. Worked Scenario Two: A Web Application Can't Write Its Own Upload Directory

**Symptom:** A web application, running as a dedicated service account `www-data`, fails to write files to `/var/www/app/uploads/`, despite the directory showing `drwxrwxr-x www-data www-data`.

**Diagnosis:** Step 4 looks entirely correct — the directory is owned by the exact user the process runs as, with group-write permission that would even cover a group match, and the owner category (which matches first, per Chapter 1's ordered-match rule) grants full `rwx` regardless. This is a case where Steps 1 through 4 all check out cleanly, correctly pointing the diagnosis toward Steps 5 through 9.

Step 5 (`getfacl`) reveals a non-trivial ACL:

```
user::rwx
user:deploy:rwx
group::r-x
mask::r-x
other::r-x
```

Here is the actual root cause, and it is a direct, worked illustration of Chapter 7, Section 4.2's central warning: an earlier deployment script had run a well-intentioned `chmod 775` against the directory, intending to grant group write access — but because the directory already carried named ACL entries (from an earlier, separate `setfacl` configuration granting the `deploy` user direct access), that `chmod` call didn't set the owning group's entry directly; it set the **mask**, which is displayed here as `r-x`, capping every named entry's effective permission down to read-and-execute regardless of what each entry's own nominal permissions state. The `user::` owner entry is unaffected by the mask (per Chapter 7, Section 5's precise algorithm — the mask never applies to the owner or true-other entries), which is exactly why the directory's own base permissions displayed by `ls -l` looked entirely correct and non-suspicious, while the actual, effective, ACL-mediated write access for the running process was silently capped.

**Fix:** `setfacl -m mask::rwx uploads/` restores the mask to a non-restrictive ceiling, or, more robustly, auditing the deployment script to use `setfacl` rather than `chmod` against directories already known to carry named ACL entries, avoiding the redefinition trap entirely going forward.

**Lesson:** Whenever `ls -l`'s traditional columns look entirely correct but behavior doesn't match, the `+` suffix (or its absence, worth double-checking rather than assuming) is the very next thing to check, per Section 1's Step 5 — this exact scenario is precisely why that step exists in the sequence at all, positioned deliberately after the traditional DAC check rather than folded into it.

---

## 4. Worked Scenario Three: A Cron Job's Output File Has the Wrong Group

**Symptom:** A nightly cron job, running as user `parsa`, creates a log file that different team members need to be able to append notes to, but the resulting file consistently ends up owned by group `parsa` (the user's private group, per Chapter 2, Section 3.3) rather than the intended `ops-team` group, despite the containing directory having been explicitly configured with SGID and group ownership `ops-team`.

**Diagnosis:** This looks, at first glance, like a contradiction of Chapter 6, Section 3.2's SGID inheritance guarantee — new files in an SGID directory should inherit the *directory's* group, not the creating process's own primary group, unconditionally. The correct diagnostic move is verifying the actual, current state of the directory rather than trusting a description of how it was "configured" at some point in the past:

```
$ stat --format='%A %G' /var/log/nightly_reports/
drwxr-xr-x ops-team
```

The `stat` output immediately reveals the actual root cause: the directory's `%A` field shows `drwxr-xr-x` — **no `s` in the group-execute position at all**. The SGID bit, despite having been set correctly at some point (per the scenario's description), is no longer present. Tracing further, the team's deployment automation had, at some later point, run a recursive `chmod -R 755` across the entire log directory tree as part of a routine permission-normalization script — and per Chapter 4, Section 2.2's precisely-flagged hazard, a three-digit numeric mode (`755`, with no leading fourth digit) **explicitly zeroes any previously set special bits**, silently stripping the SGID configuration that had been correctly set up during initial deployment, with no warning or error at the time it happened.

**Fix:** Re-apply SGID (`chmod g+s /var/log/nightly_reports/`), and, more durably, correct the automation script to use a leading-digit-preserving invocation (`chmod -R 2755`, or a symbolic form that doesn't touch the special-bits digit at all) going forward, so routine permission normalization doesn't continue silently undoing deliberate SGID configuration on every run.

**Lesson:** This scenario is a direct, worked confirmation of a warning issued all the way back in Chapter 4 — the interaction between routine, seemingly-unrelated permission maintenance (a generic recursive `chmod` intended only to fix ordinary rwx bits) and special-bit configuration is a genuine, recurring, easy-to-overlook operational hazard, not a theoretical edge case, and any automation that runs recursive numeric `chmod` against directory trees known to rely on SGID or SUID configuration needs explicit awareness of this interaction.

---

## 5. Worked Scenario Four: A SUID Binary Stopped Working After a Filesystem Migration

**Symptom:** A legitimate, previously-functioning SUID-root utility begins failing to elevate privilege after its containing filesystem is migrated to a new mount point during a storage upgrade, despite `ls -l` continuing to show the correct `rwsr-xr-x` permissions on the binary itself.

**Diagnosis:** Per Section 1's Step 8, this is a mount-level restriction, not a DAC or special-bit misconfiguration — the file's own permission bits, confirmed correct by the symptom description itself, were never the actual problem. Checking the new mount's options:

```
$ mount | grep /opt/tools
/dev/sdb1 on /opt/tools type ext4 (rw,nosuid,relatime)
```

The `nosuid` mount option, per Chapter 3, Section 9's table, disables the effect of SUID/SGID bits for any executable on that specific mount, entirely independent of and overriding whatever the file's own mode bits correctly specify — a deliberate, common hardening default applied to newly provisioned storage, particularly storage intended for general data rather than trusted system binaries, that in this case was applied without the deploying team realizing this specific mount point also happened to host a legitimate, necessary SUID utility.

**Fix:** Either relocate the SUID binary to a mount without `nosuid` (generally the preferred fix, since `nosuid` on general data storage is usually correct, security-conscious policy that shouldn't be casually disabled just to accommodate one relocated binary), or, if the mount genuinely needs to host this specific trusted binary, remount without `nosuid` specifically for that mount, accepting the broader security trade-off deliberately and consciously rather than as an unexamined side effect.

**Lesson:** Mount-level restrictions are easy to overlook specifically because they leave the file's own permission display entirely, correctly unchanged — `ls -l` and even `getfacl`/`getcap` all show a completely accurate, unmodified picture of the file's own configuration, and the actual restriction is invisible unless you specifically think to check the mount itself, which is exactly why Step 8 exists as a distinct, deliberate item in the sequence rather than being assumed to be covered by ordinary file-level inspection.

---

## 6. Worked Scenario Five: Everything Checks Out, and It's Still Denied

**Symptom:** A newly containerized service fails to read a configuration file that DAC permissions, ACLs, and mount options all confirm should be fully accessible to it.

**Diagnosis:** This is the scenario Section 1's Step 7 exists for, and it is deliberately included here as this chapter's final worked example because it is the case most likely to cause an experienced administrator — one who has genuinely internalized Chapters 1 through 8's DAC-centric model thoroughly — to get stuck circling the same, already-correct DAC checks repeatedly, precisely because every one of them keeps coming back clean. `journalctl -t audit` (or the equivalent SELinux audit log location for the specific distribution) reveals:

```
type=AVC msg=audit(...): avc: denied { read } for pid=... comm="myservice" name="config.yml" ... scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:user_home_t:s0 tclass=file
```

This is a MAC policy denial, exactly per Chapter 9, Section 6's mechanism — the containerized process's security context (`container_t`) is not permitted, under the system's SELinux policy, to access files carrying the `user_home_t` context, entirely independent of the fact that DAC permissions, verified extensively in earlier steps, would otherwise permit the read without any issue. **This is not a bug or an inconsistency; it is MAC functioning exactly as designed** — an additional, independent, policy-driven restriction that intentionally does not care what DAC alone would permit, precisely the "defense in depth" property Chapter 9 described in full.

**Fix:** Either relabel the configuration file to a context the container's policy permits (`chcon` or a persistent `semanage fcontext` rule), or adjust the container's security context/policy itself if the access is genuinely intended and the current policy is simply misconfigured for this specific, legitimate use case — never simply disabling SELinux enforcement wholesale as a blanket fix, which discards the entire additional protective layer Chapter 9 argued for, for the sake of resolving one specific, narrowly-scoped access need.

**Lesson, closing the entire series:** The complete diagnostic sequence in Section 1 exists precisely because permission failures on a modern, properly hardened system are no longer explainable purely through the DAC model this series spent its first eight chapters building — that model remains the essential, foundational layer, and the overwhelming majority of real-world permission issues genuinely are resolved within it, but a truly complete mental model, the kind this closing chapter has tried to instill through fully worked, realistic cases, holds DAC, ACLs, capabilities, mount restrictions, and MAC policy simultaneously in view, checking each in the deliberate order Section 1 establishes, rather than exhausting DAC-only reasoning and concluding, incorrectly, that an unexplained denial must indicate some deeper mystery rather than simply the next layer in the sequence this entire series has now covered in full.

---

## 7. Closing Note on This Series

This ten-chapter series began with a single reframing in Chapter 1 — a permission is not a static property of a file, but a rule the kernel consults at the moment of an access attempt — and has built outward from that single idea through every layer a real, modern Linux deployment actually has to contend with: identity resolution, the full object-type-specific meaning of the permission triad, the two notations for expressing it, the creation-time default mechanism, the three special bits, the ACL system that breaks past the traditional triad's structural limit, the capability system that decomposes root itself, the concrete misconfigurations and attack patterns that arise from all of the above, and finally, in this chapter, the disciplined diagnostic method that ties every one of those mechanisms into a single, ordered, reliable troubleshooting sequence.

The throughline across all ten chapters has been consistent: precision over memorized rules. Every chapter has favored deriving *why* a given rule holds — from first principles, from the kernel's actual data structures, from the specific historical problem a mechanism was built to solve — over simply stating the rule as given. That approach is what makes the full model actually usable in the messy, layered, real-world scenarios this final chapter has walked through, rather than merely recitable in the clean, isolated form each individual chapter necessarily presented its own material in.
