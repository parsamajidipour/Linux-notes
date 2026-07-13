# 08 — Privilege Transition

This is the chapter the series has been converging on since Chapter 01 first
wrote `(ruid, euid, suid)` and promised that "the whole point of `sudo` is to
engineer a controlled, policy-checked transition of that triplet." Every
preceding chapter was preparation: the credential model (01), why the transition
must be gated (02), where it sits in the pipeline (03), what policy authorizes it
(04–06), and how the environment is sanitized around it (07). Now we perform it.

Stage 8 of Chapter 03 is a handful of syscalls. That handful is the most
security-critical code in the entire flow, because a mistake here does not
produce an error message — it produces a process that *looks* like it dropped
privilege but has left a door open, and an attacker who reaches that process
walks back up to root. This chapter dissects those syscalls, the two ordering
rules that must never be violated, why `sudo` uses `setresuid` and not `setuid`,
and how the kernel enforces (and clears) privilege underneath.

## 1. Where we start and what we must reach

At the moment Stage 8 begins, the `sudo` process holds:

```
(ruid, euid, suid) = (1000, 0, 0)      # you, wearing root's effective identity
(rgid, egid, sgid) = (1000, 0, 0)
supplementary groups = root's (0, ...) or sudo's own set
```

It reached this state via the setuid bit (Chapter 01): real UID preserved at 1000
so `sudo` knew who was asking, effective and saved UID elevated to 0 so it had the
authority to decide and act. Now the policy plugin has returned a `command_info`
(Chapter 05) specifying the **target** credentials — `runas_uid`, `runas_gid`,
`runas_groups`. `sudo` must reshape its own credential set to *exactly* those
values, then `execve` the command, so the command runs as the target and nothing
of the original privilege remains reachable.

For `sudo command` (default target root) the target is `(0, 0, 0)`. For
`sudo -u www-data command` it is `(33, 33, 33)` with `www-data`'s groups. The
mechanism is identical; only the numbers differ. We will treat the drop to an
unprivileged target as the general case, because it is the one where mistakes are
catastrophic.

## 2. The credential set at the kernel level

In the kernel, a process's security context lives in a `struct cred`. The
UID-relevant fields are not one number but several:

- `uid` (real), `euid` (effective), `suid` (saved), `fsuid` (filesystem);
- `gid`, `egid`, `sgid`, `fsgid` — the group analogues;
- `group_info` — the supplementary group list;
- `cap_permitted`, `cap_effective`, `cap_inheritable`, `cap_ambient`,
  `cap_bset` — the capability sets.

The syscalls in this chapter do not mutate the live `cred` in place. Each prepares
a modified copy and asks the kernel to install it via `commit_creds()`, after the
kernel checks that the change is permitted. That permission check is the heart of
privilege: **a process may set a UID to arbitrary values only if it holds
`CAP_SETUID`; otherwise it may only shuffle among the real, effective, and saved
IDs it already has.** The analogous rule for group IDs and the supplementary list
requires `CAP_SETGID`. A `sudo` process at `euid 0` holds both capabilities — for
now. The words "for now" are the entire reason ordering matters.

## 3. The three syscalls

`sudo` performs the transition with three system calls (plus a helper that
computes the group list):

**`setgroups(size, list)`** — replaces the process's supplementary group list
with `list`. Requires `CAP_SETGID`. There is no "partial" form; it sets the whole
vector.

**`setresgid(rgid, egid, sgid)`** — sets the real, effective, and saved group IDs,
each explicitly (a value of `-1` leaves that one unchanged). Setting them to
arbitrary values requires `CAP_SETGID`.

**`setresuid(ruid, euid, suid)`** — sets the real, effective, and saved user IDs,
each explicitly. Setting them to arbitrary values requires `CAP_SETUID`. This is
the call that finally relinquishes root.

The helper is **`initgroups()`** (or the lower-level `getgrouplist()` +
`setgroups()`): given the target username, it looks up every group the target
belongs to — the primary group from `passwd` and all supplementary groups from
the group database (`/etc/group` and any `nsswitch` sources) — and installs that
exact set. This is why `sudo -u www-data id` shows *www-data's* groups, not yours
and not root's.

The `fsuid`/`fsgid` fields are not set explicitly; they track `euid`/`egid`
automatically, so once `setresuid`/`setresgid` run, the filesystem IDs follow.

## 4. Rule 1 — groups and GID before UID, always

The first non-negotiable rule: **set the supplementary groups and the GID while
still privileged, and change the UID last.** The order is:

```
setgroups(...)          # supplementary groups   — needs CAP_SETGID
setresgid(g, g, g)      # real/effective/saved GID — needs CAP_SETGID
setresuid(u, u, u)      # real/effective/saved UID — needs CAP_SETUID   (LAST)
```

The reason is mechanical, not stylistic. `setgroups` and `setresgid` (to
arbitrary values) both require `CAP_SETGID`. When a process drops its UID from 0
to a non-zero value, the kernel **clears its capabilities** (§11). So if you
changed the UID *first*:

```
setresuid(33, 33, 33)   # drop to www-data — CAP_SETGID is now GONE
setgroups(...)          # FAILS: EPERM — no CAP_SETGID
setresgid(33, 33, 33)   # FAILS: EPERM
```

The group changes fail, and — this is the dangerous part — if the program does
not check the return values, it proceeds believing it dropped privilege while
**still holding root's group memberships**. A process running as UID `33` but with
GID `0` and root's supplementary groups can read and write every file that is
group-accessible to `root`, `shadow`, `disk`, `sudo`, and so on. It is not root by
UID, but it is root by group — a partial, silent privilege retention that is often
just as exploitable.

Set groups and GID first, while `CAP_SETGID` is still in hand. Only then drop the
UID. `sudo` follows exactly this order, and you can watch it in the `strace` of
§7.

## 5. Rule 2 — `setresuid`, not `setuid`

The second non-negotiable rule: **use `setresuid` (all three IDs, explicit) — not
`setuid`, `seteuid`, or `setreuid`.** The reason is the saved UID and the
asymmetric, privilege-dependent semantics of the older calls.

`setuid(uid)` behaves differently depending on whether the caller is privileged:

- **Privileged** (`CAP_SETUID`): `setuid(uid)` sets **all** of real, effective,
  and saved to `uid`. Called with the target UID by a root process, it *does*
  perform a permanent drop.
- **Unprivileged**: `setuid(uid)` sets **only the effective** UID, and only to the
  real or saved value.

This asymmetry is a minefield. `seteuid(uid)` changes only the effective UID,
leaving the saved UID untouched. `setreuid(ruid, euid)` sets real and effective
and has its own baroque rules for when the saved UID is also updated. The net
effect is that it is easy — and historically common — to write a "drop privilege"
sequence that changes the effective UID to unprivileged while **leaving the saved
UID at 0**. The process now looks unprivileged: `id` reports the low UID, file
checks use it. But the saved UID is still `0`, and a single `seteuid(0)` restores
root, because a process may always set its effective UID *to its saved UID*.

`setresuid(u, u, u)` eliminates the ambiguity by making all three IDs explicit in
one call. There is no "depends on privilege," no untouched saved ID, no implicit
rule to misremember. After `setresuid(33, 33, 33)` succeeds, real, effective, and
saved are all `33` — there is **no** stashed `0` anywhere in the UID triplet, and
therefore no `seteuid(0)` that can bring root back. The door is not just closed;
it is removed.

## 6. The walk-back-up attack, demonstrated

Make the abstract concrete. Here is a program that drops privilege *incorrectly*
— the way a naive setuid wrapper (Chapter 02) might — and then an attacker
regaining root inside it:

```c
/* wrong_drop.c — setuid-root, drops privilege the WRONG way */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    /* setuid-root: start at (ruid=1000, euid=0, suid=0) */
    seteuid(1000);            /* BUG: only effective changes → (1000,1000,0) */

    /* ... program believes it is now unprivileged and runs "safe" code ... */
    /* if an attacker reaches this point via a bug in the "safe" code: */
    seteuid(0);               /* saved UID is still 0 → root RESTORED */

    printf("euid after regain: %d\n", geteuid());   /* prints 0 */
    return 0;
}
```

```console
$ cc -o wrong_drop wrong_drop.c && sudo chown root wrong_drop && sudo chmod 4755 wrong_drop
$ ./wrong_drop
euid after regain: 0
```

The "drop" was cosmetic. The saved UID never left `0`, so root was one call away
the entire time. Now the correct version:

```c
/* right_drop.c — permanent drop with setresuid */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    setresuid(1000, 1000, 1000);   /* all three → 1000; no saved 0 remains */
    if (seteuid(0) == 0)           /* attempt to regain root */
        printf("regained root!\n");
    else
        printf("cannot regain: %d\n", geteuid());  /* prints 1000 */
    return 0;
}
```

```console
$ ./right_drop
cannot regain: 1000
```

`seteuid(0)` now **fails** — there is no saved `0` to return to. This is exactly
the difference `sudo` guarantees by using `setresuid`: the command it runs cannot
climb back to the privilege `sudo` held, because that privilege was not merely set
aside, it was destroyed in the transition.

## 7. The full sequence `sudo` performs

Observed under `strace`, filtered to the credential calls, for a drop to
`www-data` (UID/GID 33):

```console
$ strace -f -e trace=setgroups,setresgid,setresuid,setuid,seteuid,execve \
      sudo -u www-data id 2>&1 | grep -E 'set|execve.*/id'
```

```text
execve("/usr/bin/sudo", ["sudo","-u","www-data","id"], ...) = 0
setgroups(1, [33])                = 0     # (a) target's supplementary groups
setresgid(33, 33, 33)             = 0     # (b) real/effective/saved GID
setresuid(33, 33, 33)             = 0     # (c) real/effective/saved UID — LAST
execve("/usr/bin/id", ["id"], ...) = 0    # (d) run the command as www-data
```

Read against the two rules: groups and GID (a, b) precede the UID change (c) —
Rule 1. All three IDs are set explicitly in single `setres*` calls, no `setuid`
or `seteuid` in sight — Rule 2. Then, and only then, `execve` (d) runs the target
as a fully-transitioned `www-data` process. The command that runs at (d) has
`(ruid, euid, suid) = (33, 33, 33)` and www-data's groups — no reachable path back
to UID 0.

For the default `sudo id` (target root), the numbers are `0` throughout and the
UID "change" is trivial (`euid` is already 0), but `sudo` still sets the real and
saved UIDs to 0 explicitly and installs root's group vector — the sequence is the
same shape.

## 8. Two cases: becoming root vs. dropping to an unprivileged user

It is worth separating the two directions because the security stakes differ.

**Target is root (`sudo command`).** The transition raises the *real* and *saved*
UIDs to 0 (effective already is). There is no "drop" here — the command becomes
fully root. The security work happened *earlier*: the policy check (04), the
authentication (06), and the environment sanitization (07). By Stage 8, the
decision to grant root has been made; the transition merely enacts it. The one
Stage-8 concern is correctness — installing root's groups, not leaving the
invoker's groups behind.

**Target is unprivileged (`sudo -u www-data command`).** This is a genuine
privilege drop, and it is where Rules 1 and 2 earn their keep. The command must
end up with *no* residual access to root or to the invoking user. Both rules
exist precisely to make this drop complete: Rule 1 ensures the group memberships
are the target's (not root's leaked through), Rule 2 ensures the UID triplet holds
no stashed privileged value.

The asymmetry is instructive: `sudo`'s reputation as "the tool to become root"
undersells it. The harder, more failure-prone job is the controlled drop to a
*lesser* identity, and that is where the transition machinery is really tested.

## 9. Permanent vs. temporary drop

There are two philosophies of privilege change, and `sudo` uses the stricter one.

A **temporary drop** lowers the effective UID while keeping the saved UID
privileged, so the process can later regain privilege — the daemon pattern from
Chapter 01 (`bind` as root, drop to handle clients, regain to rebind). It is the
right choice when a single long-lived process legitimately needs to oscillate.

A **permanent drop** sets real, effective, and saved all to the target, destroying
any path back. `sudo` does a **permanent** drop, because the command it runs
should *never* be able to reacquire the privilege `sudo` held. There is no
legitimate reason for `sudo -u www-data somecmd` to be able to become root again;
allowing it would defeat the entire point of naming a target. `setresuid(u,u,u)`
is exactly the permanent-drop primitive, which is a second reason `sudo` uses it.

The distinction is the crux of the §6 demonstration: `wrong_drop` accidentally did
a *temporary* drop (saved UID still 0) when it needed a permanent one, and that
accident was the vulnerability.

## 10. Supplementary groups: the quiet leak

The UID and GID get attention; the supplementary group list is where subtle leaks
hide. A process carries a *list* of group memberships beyond its primary group,
and every group-permission check consults that list. If `sudo` changed the UID and
primary GID to the target but **failed to reset the supplementary groups**, the
command would run with the *wrong* group memberships — either root's (if left from
`sudo`'s elevated state) or the invoker's.

Consider `sudo -u www-data cmd` where the invoker `parsa` is in the `sudo` and
`adm` groups. If the supplementary list were not reset, `cmd` would run as UID 33
but *still a member of `adm`*, able to read `adm`-group files it should never
touch. Conversely, leaving root's groups would grant `shadow`/`disk` access.

`sudo` prevents this by computing the **target's** group list via `initgroups`/
`getgrouplist` and installing it with `setgroups` (step (a) in §7) — replacing,
not augmenting, whatever was there. The result is that `sudo -u www-data id` shows
precisely www-data's groups:

```console
$ id                          # the invoker
uid=1000(parsa) gid=1000(parsa) groups=1000(parsa),27(sudo),4(adm)
$ sudo -u www-data id         # the target — a clean, complete replacement
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

No `sudo`, no `adm` — the leak is closed. (The `-P`/`preserve_groups` option
deliberately keeps the invoker's groups; it exists for narrow cases and should be
recognized as a loosening of exactly this protection.)

## 11. The kernel side: `commit_creds` and capability clearing

Underneath the syscalls, the kernel does more than copy numbers. When the UID
transition crosses the 0 → non-zero boundary, the kernel **clears the process's
capability sets**. Specifically, when the effective UID moves away from 0 the
effective capabilities are cleared, and when *all* of the real, effective, saved,
and filesystem UIDs become non-zero the **permitted** capabilities are cleared too
(absent `SECBIT_KEEP_CAPS`/`no_setuid_fixup` securebits).

This matters for two reasons. First, it is *why* Rule 1 exists: dropping the UID
clears `CAP_SETGID`, so any group change must happen before. Second, it means the
UID drop is not only about the UID — it also strips the raw kernel capabilities
that root implicitly held. A command dropped to `www-data` loses `CAP_DAC_OVERRIDE`,
`CAP_NET_ADMIN`, and the rest along with UID 0. The credential model of Chapter 01
and the capability model of the companion notes are thus tied together at this
exact point: the UID transition is also a capability transition. (For the
target-is-root case, capabilities are retained because the UIDs remain 0.)

`commit_creds()` performs the installation atomically after the capability check,
so there is no window in which the process holds a half-changed credential set
visible to other threads. The transition, once it succeeds, is coherent.

## 12. Verifying the transition

The definitive check is `/proc/self/status`, which exposes the full triplet the
way `id` (which shows only real and effective) does not:

```console
$ sudo -u www-data grep -E '^(Uid|Gid|Groups):' /proc/self/status
Uid:	33	33	33	33
Gid:	33	33	33	33
Groups:	33
```

All four UID fields (real, effective, saved, fsuid) are `33`; all four GID fields
are `33`; the supplementary list is just `33`. This is the signature of a correct,
complete, permanent transition to `www-data`: no residual `0`, no leaked
supplementary group. Compare against the `wrong_drop` signature, which would show
a saved UID of `0` — the tell-tale of an incomplete drop.

## 13. Failure modes and historical bugs

The transition is small, which makes its failure modes enumerable — and each has
produced real vulnerabilities across the ecosystem of privileged programs:

- **Dropping UID before groups** → `setgroups`/`setresgid` fail with `EPERM`; if
  unchecked, the process keeps privileged group memberships (§4). The "forgot to
  drop groups" bug.
- **Using `seteuid`/`setuid` instead of `setresuid`** → saved UID left privileged;
  root regainable via `seteuid(0)` (§5, §6). The "temporary drop mistaken for
  permanent" bug.
- **Not checking return values** → `setresuid` can fail (e.g. `RLIMIT_NPROC`
  exceeded for the target UID); an unchecked failure means the program runs its
  "unprivileged" code path still as root. The "assumed success" bug.
- **Leaving supplementary groups unset** → wrong group memberships leak into the
  command (§10). The "quiet group leak" bug.

`sudo`'s discipline — groups and GID first, `setres*` with all IDs explicit, return
values checked, target's group list installed — is precisely the checklist derived
from these failure modes. It is the same checklist a correct hand-rolled setuid
program would need, which is (again) why centralizing it in one audited tool beats
re-implementing it per wrapper.

Note that this transition concerns `sudo` correctly *becoming* the target. It does
**not** by itself contain a command whose grant is legitimate but dangerous — a
shell-escaping editor (Chapter 04) transitions perfectly and *then* gives a root
shell. Stage 8 guarantees the credentials are what policy said; it cannot
second-guess whether policy should have said it. That boundary is Chapter 10's.

## 14. What this chapter established

- Stage 8 reshapes `sudo`'s credential set from `(1000, 0, 0)` to the target's,
  then `execve`s the command, so it runs as the target with **no reachable path
  back** to the original privilege.
- The transition uses **`setgroups` → `setresgid` → `setresuid`**, plus
  `initgroups`/`getgrouplist` to compute the target's supplementary groups. The
  kernel checks each change against `CAP_SETUID`/`CAP_SETGID` and installs it via
  `commit_creds`.
- **Rule 1 — groups and GID before the UID.** Dropping the UID clears the
  capabilities (`CAP_SETGID`) needed to change groups; doing groups first, while
  still privileged, prevents a silent retention of root's group memberships.
- **Rule 2 — `setresuid`, not `setuid`/`seteuid`.** The older calls have
  asymmetric, privilege-dependent semantics that easily leave the **saved UID at
  0**, from which `seteuid(0)` regains root. `setresuid(u,u,u)` sets all three
  explicitly, destroying any stashed privilege — a **permanent** drop.
- The **walk-back-up attack** is not theoretical: a `seteuid`-based "drop" leaves
  root one call away, demonstrated live; the `setresuid` version makes
  `seteuid(0)` fail.
- **Becoming root** merely enacts an already-made decision; **dropping to an
  unprivileged target** is the harder, failure-prone case where both rules matter.
- The **supplementary group list** is a quiet leak vector; `sudo` *replaces* it
  with the target's via `setgroups`, so no invoker/root groups survive.
- At the kernel level, the UID drop across 0 → non-zero also **clears
  capabilities**, tying the UID transition to the capability model — the drop to
  `www-data` sheds root's kernel powers along with UID 0.
- The transition's failure modes (order, wrong syscall, unchecked returns, unset
  groups) are exactly the historical privilege-drop bug classes; `sudo`'s fixed
  sequence is the checklist that avoids them — but it guarantees only that the
  credentials match policy, not that the policy was safe.

The next chapter turns from *doing* the privileged thing to *recording* it.
*Logging and Auditing* covers how `sudo` writes the attributable trail promised in
Chapter 02 — syslog/journald event lines, the I/O logging plugin capturing full
sessions, and `sudoreplay` reconstructing them — so that every transition
performed here leaves evidence of who did what, as whom, and when.
