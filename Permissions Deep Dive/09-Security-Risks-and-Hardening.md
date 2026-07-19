# Security Risks and Hardening

Every previous chapter in this series has, at points, flagged a specific risk and deferred its full treatment here. This chapter collects those threads into a coherent whole: not a generic "security best practices" checklist, but a systematic walk through the permission model this series has built, chapter by chapter, examined specifically for where it fails, how it gets misconfigured in practice, and what a disciplined hardening methodology looks like when it's built on genuine mechanism-level understanding rather than memorized rules.

---

## 1. The Root Vulnerability of DAC Itself

Chapter 1 introduced Discretionary Access Control's defining philosophy — the owner of a resource decides who else can access it — and flagged that this assumes a baseline of trust reasonable for 1970s timesharing systems but fragile on a modern, internet-exposed, multi-tenant machine. This chapter opens by making that fragility concrete.

### 1.1 The Confused Deputy Problem

DAC's fundamental weakness is that it controls access based on *who is running a process*, not on *what that process is actually trying to do or on whose behalf*. A privileged program that has been tricked — through a bug, a malicious input, or a poorly considered feature — into performing an action on behalf of an untrusted party, while operating with the *program's own* elevated privilege rather than the untrusted party's actual privilege, is called a **confused deputy**, and it is the underlying structural pattern behind an enormous fraction of real-world privilege-escalation vulnerabilities.

Every mechanism this series has covered for granting elevated privilege — SUID (Chapter 6), file capabilities (Chapter 8), even a SUID-root binary correctly performing its intended narrow function — creates exactly this risk profile: a piece of software that legitimately holds more privilege than the user invoking it, and whose entire security rests on that software correctly refusing to be misused for anything beyond its intended narrow purpose. This is precisely why Chapter 6 and Chapter 8 both emphasized, independently, that the kernel's contribution to safety ends at "grant the elevated identity or capability" — everything after that is the responsibility of the specific program's own code, and no amount of correct kernel-level permission enforcement can compensate for an exploitable flaw in a privileged program's own logic. Mandatory Access Control systems — SELinux, AppArmor, briefly mentioned in Chapter 1 and returned to in Section 6 of this chapter — exist specifically to provide an additional, policy-enforced layer that can constrain even a compromised privileged program's behavior, precisely because DAC alone has no answer to the confused-deputy problem once a legitimately privileged program has itself been compromised.

---

## 2. World-Writable Directories and the Sticky Bit Gap

Chapter 6, Section 4 covered the sticky bit's mechanism in detail — restricting deletion in shared directories to each file's own owner. This section covers the *auditing* side: finding directories that are world-writable but lack this protection, a genuinely common and genuinely dangerous misconfiguration.

### 2.1 The Audit Command

```
find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null
```

Breaking this down precisely, because each flag maps directly onto material from earlier chapters: `-perm -0002` finds directories with the world-write bit set (per Chapter 4's numeric mode table, `2` in the other position); `! -perm -1000` excludes any of those that also have the sticky bit set (per Chapter 6's `1` in the leading digit); `-xdev` restricts the search to the starting filesystem, avoiding traversal into separately mounted filesystems (network shares, removable media) where the finding might not be actionable or relevant in the same way. The result is a precise list of exactly the dangerous combination Chapter 6 identified: directories where any local user can delete or rename any other user's files, with no protection at all.

### 2.2 Why This Keeps Happening in Practice

World-writable directories without sticky bits are rarely created deliberately with malicious intent — they far more commonly arise from administrators or installation scripts reaching for `chmod 777` as a blunt "just make it work" fix for a permission error, without understanding (per this entire series' material) *why* the error occurred in the first place, and without the follow-up knowledge that `1777`, not `777`, is the actually-safe version of "let everyone write here" for any genuinely shared directory. This is worth internalizing as a broader pattern this whole chapter returns to repeatedly: a large fraction of real-world permission misconfigurations trace back not to malice but to someone reaching for the most permissive fix available under time pressure, without the mechanism-level understanding this series has built to recognize *why* that fix is dangerous and what the correctly-scoped alternative actually is.

---

## 3. The SUID/SGID Inventory as an Attack Surface Map

Chapter 6, Section 6 previewed the discovery command; this section builds it into a complete methodology.

### 3.1 Establishing and Maintaining a Baseline

```
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec ls -la {} \; > suid_sgid_baseline.txt
```

The critical operational practice this command enables is **baseline comparison over time**, not a single one-off snapshot. An unexpected *new* entry appearing in this list between two scheduled audits — a binary that wasn't SUID or SGID last week but is now — is one of the more reliable, low-noise indicators of either a serious misconfiguration introduced by a careless administrative action, or, in a genuinely adversarial context, an attacker who has already achieved some level of access establishing a SUID-root binary as a **persistence and privilege-re-escalation mechanism**: having gained temporary elevated access through some other means, an attacker plants a SUID-root shell or utility so that even after their original access vector is closed, any unprivileged foothold they retain can trivially re-escalate through the planted binary. This is precisely why file-integrity monitoring tools (AIDE, Tripwire, and similar) treat the SUID/SGID bit state of monitored files as a specifically flagged, high-priority attribute to track for unexpected changes, not merely an incidental part of a broader file-hash comparison.

### 3.2 Evaluating Each Entry: Necessity and Scope

A raw inventory is only the first step; the actual hardening work is evaluating each entry against two questions, both directly drawing on Chapter 6 and Chapter 8's material:

**Is this SUID/SGID grant still necessary at all?** Software is regularly installed with SUID-root binaries that a specific deployment never actually needs the corresponding privileged functionality from — a mail transfer agent's SUID components on a system that never sends local mail, for instance. Removing SUID from a binary that isn't providing any function the specific deployment relies on is a straightforward, low-risk hardening action, and worth treating as the first triage question for every baseline entry.

**Could this specific grant be replaced with a narrower file capability instead?** Directly applying Chapter 8's comparison table: any SUID-root binary whose actual privileged need maps cleanly onto one or a small number of named capabilities is a strong candidate for migration away from SUID-root entirely, per Chapter 8, Section 2.5's reasoning — reducing that specific binary's blast radius from "full root compromise if exploited" down to "compromise limited to whatever narrow capability was actually granted." This migration isn't always straightforward — Chapter 8, Section 3.3 already flagged that not every privileged operation decomposes cleanly onto existing capabilities — but it is worth evaluating deliberately for every entry rather than assuming SUID is simply an immutable given for any specific piece of software.

---

## 4. Symlink and TOCTOU Attacks, Revisited in Full

Chapter 3, Section 4.3 introduced symlink attacks and TOCTOU races in brief, flagging this chapter for the complete treatment. This section delivers it.

### 4.1 The Precise Mechanics of a TOCTOU Race

**TOCTOU** — time-of-check to time-of-use — describes any vulnerability arising from a gap between when a privileged process *verifies* some property of a filesystem object and when it subsequently *acts* on that same path, during which an attacker can alter what that path actually refers to. The canonical, concrete pattern, worth walking through explicitly because the abstract description alone often doesn't convey how mechanically simple the exploitation actually is:

```
# Privileged process's flawed logic:
if (access("/tmp/predictable_filename", W_OK) == 0) {
    // time gap — attacker acts here
    fd = open("/tmp/predictable_filename", O_WRONLY);
    write(fd, sensitive_data, ...);
}
```

Between the `access()` check succeeding and the subsequent `open()` call, an attacker who can predict the filename (a genuinely common situation for temporary files with non-random, predictable naming conventions, historically a widespread and severe class of bug) races to delete the original file and replace it with a symlink pointing to a sensitive target the attacker doesn't otherwise have write access to — say, `/etc/shadow` or a SUID-root binary's configuration file. If the race succeeds, the privileged process's subsequent `open()` follows the newly substituted symlink (per Chapter 3, Section 4.1's material on symlinks having no meaningful permission bits of their own — access is governed by resolving through to the target) and writes attacker-controlled data to an attacker-chosen, otherwise-protected location, entirely through a process that was operating with full legitimate privilege the whole time and never had any single one of its own permission checks actually violated.

### 4.2 Why This Is a Permission-Model Problem, Not Just a Coding Bug

It's worth being precise about why this belongs in a permissions-focused hardening chapter rather than being purely a general software-correctness topic: the vulnerability is exploitable *specifically* because of two permission-model facts this series has established. First, Chapter 3 established that creating a new directory entry (including a symlink) is governed purely by the containing directory's write permission, with no check against what the symlink is permitted to point to — meaning any user with write access to a shared temp directory can create a symlink pointing literally anywhere their own read/write privilege would otherwise allow them to reference directly. Second, Chapter 3 also established that symlink resolution is transparent — the kernel doesn't distinguish "the privileged process intended to write to this specific file" from "the privileged process is being redirected through a substituted symlink" at the point of `open()`; both look identical from the kernel's perspective. Both of these are correct, intentional, necessary permission-model behaviors on their own — the vulnerability arises entirely from privileged software failing to account for the fact that both behaviors, taken together, mean a predictable path in a shared, writable location cannot be trusted to still refer to the same object between a check and a subsequent use.

### 4.3 Mitigations, Mapped to Mechanisms Already Covered

- **Atomic operations instead of check-then-act.** Using `O_EXCL` with `open()` (fail if the file already exists, rather than checking existence separately first) closes the gap entirely for file-creation cases, by making the existence-check and the creation a single, indivisible kernel operation rather than two separate steps with a gap between them.
- **Unpredictable filenames.** `mkstemp()` and equivalent APIs generate randomized, hard-to-predict temporary filenames specifically to defeat an attacker's ability to pre-stage a malicious symlink at a known path before the legitimate process ever creates its file.
- **Per-user private temporary directories**, rather than a single shared `/tmp` for all users, eliminate the shared-namespace precondition the entire attack class depends on — if an attacker has no write access to the directory a privileged process's temp files live in, they cannot plant a substitute symlink there in the first place, independent of any race-timing consideration at all. Some modern distributions default to exactly this pattern (per-user, private, namespace-isolated temp directories) specifically as a structural mitigation against this entire vulnerability class, rather than relying on every individual piece of software to correctly implement atomic, race-free temp-file handling on its own.
- **The `O_NOFOLLOW` flag**, which causes `open()` to fail explicitly if the target path turns out to be a symlink at all, useful specifically for privileged code that has a legitimate reason to operate on a predictable path but should never, under any circumstance, follow a symlink found there.

---

## 5. UID Reuse and Orphaned Ownership as a Standing Risk

Chapter 2, Section 7 introduced this scenario in detail. It belongs in this hardening chapter as a concrete, actionable checklist item rather than merely a conceptual curiosity: any identity-provisioning process that reuses freed UIDs, rather than allocating from a strictly monotonically increasing counter, creates a standing risk that a newly onboarded user silently inherits ownership of — and therefore access to — every file a previous, unrelated UID-holder left behind. The audit action directly follows from Chapter 2's material: periodically scanning for files owned by UIDs that no longer resolve to any current `/etc/passwd` (or NSS-backed) entry —

```
find / -xdev -nouser -o -nogroup 2>/dev/null
```

— surfaces exactly the orphaned-ownership files Chapter 2 described, giving an administrator the opportunity to deliberately reassign or clean them up *before* a UID-recycling provisioning process has the chance to silently hand them to an unrelated new user, rather than discovering the problem only after that handoff has already occurred.

---

## 6. Where DAC's Reach Ends: MAC as the Necessary Complement

Section 1.1 flagged the confused-deputy problem as fundamentally beyond what DAC alone can solve. This closing conceptual section situates Mandatory Access Control systems precisely relative to everything this series has covered, because understanding *exactly* what MAC adds — rather than treating it as a vaguely "more secure" alternative — is the correct way to reason about when and why a hardened deployment layers it on top of the DAC model this entire series has been about.

### 6.1 The Precise Difference

Every mechanism covered in this series — permission bits, ACLs, even capabilities — shares one structural property Chapter 1 identified at the very start: they are all forms of **discretionary** control, meaning the resource's owner (or a sufficiently privileged process acting with that owner's effective identity) determines access, and a compromised or malicious process running with legitimate ownership or sufficient capability can, within the bounds this series has described, do essentially anything that identity's DAC permissions allow — there is no additional, independent check asking "should this specific process, given what it *is* and what it's *supposed to do*, actually be allowed to perform this specific action right now, regardless of what its nominal owner-based DAC permissions say."

MAC systems add exactly that independent check. SELinux, to take the most widely deployed example, assigns every process and every file a **security context** (a type, a role, a domain — layered well beyond this series' scope, but conceptually parallel to how this series' own material layered ownership, permission bits, ACLs, and capabilities on top of each other), and enforces a centrally defined **policy** governing which contexts are permitted to interact with which other contexts in which ways — a policy that applies *even to root*, and even to a process running with every capability this series' Chapter 8 described, because MAC's enforcement point sits entirely outside and independent of the DAC/capability layer this series has otherwise focused on.

### 6.2 Why This Directly Answers the Confused-Deputy Problem

Return to Section 1.1's confused-deputy scenario: a legitimately privileged, SUID-root or capability-holding program, exploited through some flaw in its own logic, tricked into performing an action on an untrusted party's behalf. Under DAC alone, once that program's exploit succeeds, its full legitimate privilege — everything its effective UID or granted capabilities allow — is available to whatever the attacker manages to make it do next, precisely because DAC has no concept of "this process is only *supposed* to touch these specific files, for these specific purposes," only "this process's identity has, or doesn't have, permission for this specific request," evaluated in isolation from any notion of the program's intended, narrower purpose.

A correctly configured MAC policy constrains a web server's process, for instance, to only the specific files, network operations, and other resources its security context is defined to need — even if that web server process is later exploited and coerced into attempting something well within its raw DAC/capability privilege (say, if it happens to be running with broad filesystem access under its Unix identity), the MAC policy's independent, narrower check can still block the actual attempted action, because MAC evaluates against the program's defined, intended role rather than merely against what its DAC identity nominally permits. This is the precise, mechanism-level answer to why "defense in depth" specifically means layering MAC on top of DAC rather than either being sufficient in isolation — each closes a gap the other structurally cannot.

---

## 7. A Consolidated Hardening Checklist

This closing section draws every thread from this chapter, and by extension every preceding chapter, into a single, ordered, actionable sequence — the practical payoff of the entire series' mechanism-level approach.

1. **Audit world-writable directories lacking the sticky bit** (Section 2) — close the shared-directory deletion gap Chapter 6 identified.
2. **Establish and periodically re-run a SUID/SGID baseline** (Section 3.1) — detect unexpected new privileged binaries, whether from misconfiguration or genuine compromise.
3. **Evaluate every SUID/SGID binary for necessity and for capability-based migration potential** (Section 3.2) — shrink the system's overall privileged-binary attack surface deliberately, per Chapter 8's blast-radius reasoning.
4. **Run a parallel capability audit** (`getcap -r /`, per Chapter 8, Section 4.1) — the SUID/SGID inventory alone no longer captures the complete privileged-binary picture on any modern system making use of file capabilities.
5. **Review any custom or in-house software handling shared, predictable-path temporary files for TOCTOU vulnerability patterns** (Section 4) — a code-review concern this chapter reframes as a direct, mechanism-level consequence of the permission facts Chapter 3 established.
6. **Scan for orphaned-ownership files and review UID-provisioning practices for recycling risk** (Section 5) — a Chapter 2 concern, made concrete as a standing periodic audit item.
7. **Review `umask` defaults, particularly for any service accounts or daemons, against `UMask=` unit-file directives** (Chapter 5, Section 4.2) — ensure privileged services aren't inheriting an unexamined, potentially over-permissive ambient default.
8. **Audit ACL-bearing files for correct mask configuration and for backup/replication tooling that correctly preserves them** (Chapter 7, Sections 4 and 7.3) — confirm the richer access-control layer isn't silently degrading during routine operational processes.
9. **Consider whether a MAC layer (SELinux, AppArmor) is warranted for the deployment's actual threat model** (Section 6) — recognize explicitly that this entire checklist, and everything this series has covered up through this point, remains fundamentally discretionary, and evaluate whether the specific deployment's exposure justifies the additional, independent policy layer MAC provides on top of it.

---

## 8. Common Misconceptions Worth Retiring Now

- **"A correctly configured permission system is sufficient security on its own."** DAC, no matter how correctly every individual permission bit, ACL entry, and capability grant is configured, cannot solve the confused-deputy problem — a legitimately privileged program's own exploitable flaws remain a gap no amount of correct DAC configuration closes, which is precisely why MAC exists as a genuinely necessary complement in higher-threat deployments, not a redundant extra layer.
- **"`chmod 777` is a reasonable quick fix when something isn't working."** It is very often a symptom-masking action that trades a confusing error message for a genuine, standing security hole — particularly on directories, where the correct fix (per Section 2) is almost always a more specifically scoped permission or ownership adjustment, with `1777` at most, and only when genuinely universal write access is the actual requirement.
- **"Symlink attacks are an obscure, largely historical concern."** They remain a directly exploitable pattern any time privileged software performs check-then-act operations against predictable paths in shared, writable locations — a live concern for any custom or legacy software audit, not merely a historical footnote.
- **"SUID/SGID auditing is a one-time setup task."** Its actual security value comes specifically from *repeated, baseline-compared* auditing over time, since a newly appeared entry between two audits is a materially more actionable and urgent signal than a static, one-time inventory alone provides.
- **"Root is a single, monolithic privilege level, so capability-based hardening doesn't meaningfully change a system's risk profile as long as root exists at all."** This dramatically understates the value capabilities and MAC both provide — even on a system where root exists, correctly scoped capabilities (Chapter 8) and MAC policy (Section 6) both meaningfully shrink what any *specific, individually compromised* process or program can actually achieve, which is the entire, concrete point of defense in depth.

---

The final chapter in this series turns from prevention to diagnosis: a complete troubleshooting methodology for real-world permission-denied scenarios, walking through the full diagnostic sequence — from the basic `check_access()` algorithm formalized in Chapter 3, through ACL masks, capability short-circuits, and MAC policy denials this chapter has now introduced — assembled into the systematic, elimination-based approach an experienced administrator actually uses when a permission error's root cause isn't immediately obvious.
