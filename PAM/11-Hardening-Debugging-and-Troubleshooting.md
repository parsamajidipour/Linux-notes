# 11 — Hardening, Debugging, and Troubleshooting

Ten chapters ago the README made a promise: by the end of this series you should be able to open an unfamiliar `/etc/pam.d/sshd` on an unfamiliar machine and say precisely what will happen when someone types a password. This chapter is about what happens when what you thought would happen and what actually happens do not agree.

It is also the series's hardening reference — a distillation of the checklist items scattered across Chapters 6 through 10 into one place, so that an audit of an inherited PAM configuration has a single starting point rather than eleven.

### A short scenario, to close the loop

Every chapter from 6 through 10 opened with a scenario showing a specific, plausible way a correctly-written piece of PAM configuration produced an incident anyway — not through obvious error, but through the interaction of individually reasonable decisions. This chapter closes that pattern with the scenario that ties them together: an on-call engineer, paged at 3 AM because nobody can SSH into a production host, opens a terminal and has exactly one minute before the page escalates to their manager.

Every fact this engineer needs is somewhere in Chapters 1 through 10. The two-command discipline from Chapter 10 (`getent passwd`, then `pamtester`) is what separates an NSS problem from a PAM problem in five seconds instead of twenty minutes. The `(service:type)` annotation from Chapter 3, read correctly per this chapter's 11.2a, is what separates "the account is locked" from "the password is wrong" without needing to open a single configuration file. The escalation ladder in 11.4 is what turns "I locked myself out" from a incident report into a two-minute recovery. None of this is new information — it is the same ten chapters, reorganised around the one question that actually matters during an incident: what do I check, in what order, to get to the answer fastest.

This chapter is that reorganisation.

---

## 11.1 Where the Evidence Is

Everything useful about what PAM decided, and why, is in the logs. Not in `/etc/pam.d/`. Not in the application's error message. The logs.

The reason is simple and was established in Chapter 3: every well-behaved PAM module annotates its log output with `(service:type)`, telling you exactly which management group produced the message, which is exactly the first piece of information you need to know which section of which file to look at. The application's own error message tells you the outcome. The PAM log tells you which module produced it.

**Debian and Ubuntu:**

```
$ tail -f /var/log/auth.log
$ journalctl -f _SYSLOG_IDENTIFIER=sshd _SYSLOG_IDENTIFIER=su
```

**RHEL, Fedora, Rocky, Alma:**

```
$ tail -f /var/log/secure
$ journalctl -f -t sshd -t sudo -t su
```

Both families: everything goes to the journal, and `journalctl` is the reliable way to see it:

```
$ journalctl -f -u sshd -t pam_unix -t pam_faillock -t pam_sss
```

### Reading an annotation

```
sshd[4521]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=10.0.1.5 user=parsa
```

Decode the parenthesis: service `sshd`, management group `auth`. This tells you: open `/etc/pam.d/sshd` (or its includes), look at the `auth` stack, find `pam_unix`. Everything you need to locate the decision is in those six characters.

The same line from `pam_unix(sshd:account)` would mean a completely different problem in a completely different part of the file. The type field is the filter.

### What `pamtester` is for

```
$ pamtester -v sshd parsa authenticate
$ pamtester -v sshd parsa authenticate acct_mgmt
$ pamtester -v su parsa authenticate
```

`pamtester` exercises a stack without a real login — no session opened, no real consequences, but the full module stack runs in the same context as if a real application had called it. The `-v` flag prints the return value the framework produced. Use it whenever you want to verify a stack change before testing it with a real login, and always before declaring anything fixed.

A common technique: `pamtester` with a deliberately wrong password to confirm that a denial actually fires, not just that a correct credential succeeds. A stack with a misconfiguration that happens to work for the happy path — `sufficient` where `required` was meant, a numeric jump that lands past the quality check — will pass a correct-credential test and fail a wrong-credential test in exactly the wrong direction.

```
$ pamtester sshd parsa authenticate    # correct password
$ pamtester sshd parsa authenticate <<< wrong    # deliberate failure
```

If the second invocation somehow succeeds (on a stack with a `pam_permit` in the wrong place, for instance), the stack has a serious problem. If it fails for the wrong reason — the wrong module named in the error — the stack is doing the right thing via the wrong path. Both patterns matter, and neither appears in a test that only checks the success case.

### Timestamps matter

The `(service:type)` annotation pairs with a timestamp that lets you correlate across log sources — the PAM log, SSSD's debug output, the audit log, the application's own log. When diagnosing a complex failure:

```
$ journalctl -f _COMM=sshd --since "2 minutes ago"
$ grep "$(date '+%H:%M')" /var/log/sssd/sssd_AD.log | head -20
$ ausearch -k pam_config -ts "2 minutes ago" 2>/dev/null
```

All three at the same timestamp. The union of what each one tells you is the complete picture. The PAM log tells you what the module returned; the SSSD log tells you why SSSD returned it; the audit log tells you what files were touched before this sequence started, in case the session is failing because someone edited a configuration right before the attempt.

### Log retention, briefly

Worth a short note since it affects whether the diagnostic techniques in this chapter are even possible after the fact. Default `journald` retention on many distributions is time- or size-bounded and can rotate out evidence of an authentication incident within days on a busy host. For any environment where post-incident PAM diagnosis matters — which is essentially every production environment — confirm retention is adequate before an incident, not during one:

```
$ journalctl --disk-usage
$ cat /etc/systemd/journald.conf | grep -i 'maxuse\|maxfile\|retention'
```

A retention policy of at least 90 days for authentication-relevant logs is a reasonable baseline for most compliance frameworks; longer for regulated environments. If logs are shipped to a central SIEM or log aggregator, the retention question shifts there, and it is worth confirming the shipping pipeline actually captures the `(service:type)`-annotated PAM lines specifically, not just the application's own summary line — a common gap in log-shipping configurations that filter by facility or application name without checking that the PAM-specific detail survives the filter.

---

## 11.2 A Systematic Diagnostic Procedure

The procedure that narrows to a specific line in bounded time, independent of how complex the stack is.

### Step 1: Is the user even resolvable?

```
$ getent passwd <user>
$ getent shadow <user>    # as root, for local users
```

If the first command returns nothing, stop. Every subsequent step is irrelevant until NSS resolves the account. Per Chapter 10's two-command discipline: NSS failure looks identical to PAM failure at the application level, and they have completely different remedies.

### Step 2: Can PAM authenticate the user at all?

```
$ pamtester <service> <user> authenticate
```

If this fails, the failure is in the `auth` stack. Read the `(service:auth)` annotation in the output and open that specific stack. If this succeeds but the actual login still fails, the failure is in `account`, `session`, or the application itself.

### Step 3: Does the account check pass?

```
$ pamtester <service> <user> acct_mgmt
```

If this fails, read the `(service:account)` annotation. Common causes: `pam_unix` reporting expiry, `pam_access` denying the origin, `pam_faillock` reporting lockout, `pam_nologin` finding `/etc/nologin`.

### Step 4: Does the session open?

```
$ pamtester <service> <user> open_session
```

If this fails after steps 2 and 3 pass, the problem is in the `session` stack. `pam_loginuid` can fail if the process is a container without write access to `/proc/self/loginuid`; `pam_systemd` can fail if logind is not running; a `pam_exec` script can fail for any reason. Read the `(service:session)` annotation.

### Step 5: Is the application itself behaving correctly?

If all three PAM stacks pass in `pamtester` and the login still fails, the application is making a decision outside PAM. `sshd`'s `AllowUsers`/`DenyUsers` directives, `sudo`'s `sudoers`, a TCP wrapper, a firewall rule — all of these can deny a login that PAM would have permitted. `sshd_config` and `/etc/hosts.allow`/`/etc/hosts.deny` are the first places to check.

### Step 6: Is the application even calling PAM?

A subtler version of step 5: the application is PAM-aware (confirmed by `ldd`), but for this specific invocation it is not consulting the PAM stack at all. The key cases from Chapter 1, restated here as diagnostics:

`sshd` with public-key authentication does not call `pam_authenticate()`. If `pamtester` passes for the `auth` stack but a key-based login is failing, the failure is not in the `auth` stack — it is in the `account` or `session` stack, or in `sshd_config`.

`sudo` with a valid timestamp does not call `pam_authenticate()`. `sudo -k` clears the timestamp; then test again.

Non-interactive SSH commands — `ssh host 'some_command'` — may or may not source a full PAM session stack depending on `sshd_config`'s `UsePAM` setting and which PAM session modules require interactive output. A command that works interactively and fails non-interactively is often a `pam_env`/environment problem rather than an authentication problem.

The diagnostic for all of these: `strace -f -e trace=openat,connect` on the application during a failing invocation, watching which files it opens and which network connections it makes, confirms whether the stack traversal actually happened at the point you assume it did.

### The decision tree

```
login fails
│
├── getent passwd <user> → nothing
│   └── NSS problem: check nsswitch.conf, SSSD status, directory connectivity
│
├── pamtester ... authenticate → fails
│   └── auth stack: read (service:auth) annotations
│       ├── pam_faillock(auth): locked → faillock --user --reset
│       ├── pam_unix(auth): failure → password, shadow, unix_chkpwd
│       ├── pam_sss(auth): authinfo_unavail → SSSD/directory connectivity
│       └── no module named: jump off end, missing terminator (Chapter 4)
│
├── pamtester ... acct_mgmt → fails
│   └── account stack: read (service:account) annotations
│       ├── pam_unix(account): expired → chage -l, chage to fix
│       ├── pam_faillock(account): locked → faillock --user --reset
│       ├── pam_access(account): denied → access.conf rule
│       └── pam_nologin: /etc/nologin exists → remove it
│
├── pamtester ... open_session → fails
│   └── session stack: read (service:session) annotations
│       ├── pam_loginuid: container without /proc access
│       ├── pam_systemd: logind not running
│       └── pam_exec: script failure
│
└── pamtester passes, login still fails
    ├── application-level decision outside PAM
    │   ├── sshd: AllowUsers, DenyUsers, MaxSessions, AuthorizedKeysFile
    │   ├── sudo: sudoers, NOPASSWD/timestamp
    │   └── firewall/TCP wrappers
    └── application not calling PAM for this invocation
        ├── sshd + key: auth stack skipped per Chapter 1
        ├── sudo + timestamp: authenticate skipped
        └── strace openat to confirm
```

---

## 11.2a The Application Summary Versus the PAM Log

Worth a dedicated section, since the confusion between these two views of the same event is the single most common time-wasting pattern in PAM diagnosis.

When `sshd` refuses a login, it writes something like:

```
sshd[4521]: Failed password for parsa from 10.0.1.5 port 52811 ssh2
```

This is `sshd`'s own summary of the outcome. It is not necessarily accurate about the *reason*. `sshd` reports "failed password" whenever PAM returns a failure from `pam_authenticate()`, regardless of which module in the `auth` stack produced that failure — a `pam_faillock` lockout, a `pam_access` origin denial that was placed in `auth` instead of `account`, a `pam_unix` shadow-read failure, or a pure `pam_deny` terminator all produce the same "failed password" message from `sshd`.

The accurate information is in the line immediately before `sshd`'s summary, usually from the specific module:

```
sshd[4521]: pam_faillock(sshd:auth): user parsa is locked out
sshd[4521]: Failed password for parsa from 10.0.1.5 port 52811 ssh2
```

The second line is what `sshd` reported to the user and what most administrators look at first. The first line is what actually happened. The discipline of reading the PAM-annotated lines before the application's own summary is the highest-value habit this series teaches, and it applies in exactly the same way to `sudo`'s "user parsa is not allowed to run sudo on host" and to `su`'s "Authentication failure" and to every other application that layers its own diagnostic summary on top of PAM's more specific one.

The practical effect: never start a PAM investigation from the application's error message. Start from the PAM annotations. If no PAM annotations appear at all for an event you know should have produced them, the first question is whether the application is even calling PAM — which brings back Chapter 1's `ldd` check, and Chapter 2's `strace openat` technique, to confirm the application actually traverses the stack you are reading.



## 11.3 Debugging Verbose Output

When `pamtester` and log annotations are not enough — usually when a module is failing silently on a misconfigured argument — add debug output.

### The `debug` argument

Every standard Linux-PAM module accepts `debug` as a module argument, producing verbose syslog output at `LOG_DEBUG` level. Add it temporarily:

```
auth  required  pam_unix.so  debug
```

Then watch the log:

```
$ journalctl -f -t sshd PRIORITY=7
```

Or on older systems:

```
$ tail -f /var/log/auth.log | grep DEBUG
```

Remove the `debug` argument when done. It exposes information about authentication decisions that should not be in logs indefinitely, and on high-volume systems it generates substantial noise.

### `pam_debug.so`

A dedicated debug module that prints every item in the current PAM handle to syslog when it runs:

```
auth  optional  pam_debug.so  auth=success acct=success
```

The arguments specify what return value it produces, letting it be placed at any position in a stack to observe the items at that point without affecting the outcome.

### Inserting markers

Chapter 4's tracing technique: `pam_echo` writes a message to the user, `pam_exec` writes to a file or log, both can be placed between any two lines to confirm which lines are actually reached:

```
auth  optional  pam_exec.so  /bin/sh -c 'echo "reached line N" >> /tmp/pamtrace.log'
auth  [success=1 default=ignore]  pam_unix.so  nullok
auth  optional  pam_exec.so  /bin/sh -c 'echo "after jump" >> /tmp/pamtrace.log'
```

The marker lines must be `optional` so they cannot affect the outcome; the log file must be writable by root; and both marker lines and the log file must be removed when the investigation is complete. Never leave `pam_exec` or open log files in production configuration. This technique is deliberately the most invasive one in this section, and it should be the last one reached for, after `pamtester`'s verbose output and the `debug` argument have both been exhausted — reserved for the specific case where a stack's behaviour genuinely cannot be explained any other way.

---

## 11.3a PAM in Containers

A brief treatment, because PAM in a container environment produces a specific and distinctive class of failure that does not appear in any of the preceding chapters' test environments.

**`pam_loginuid` fails in unprivileged containers.** Writing to `/proc/self/loginuid` requires that the calling process be running with sufficient privilege to set the audit login UID. In an unprivileged container — a Podman rootless container or a Docker container without `SYS_ADMIN` — this write fails, and on a `required` line, that failure denies the login. The fix is either to run the container with sufficient capability for audit UID operations, to remove `pam_loginuid` from the `session` stack for containerised services, or to switch to a `-` prefixed type (per Chapter 2) that suppresses the error if the module is unavailable:

```
-session  required  pam_loginuid.so
```

The `-` prefix on the type field does not help here since the module loads fine — the failure is at runtime, not at load time. The correct solution is either privilege adjustment or a conditional skip, commonly handled by checking whether the write to `/proc/self/loginuid` would succeed before attempting it, which some versions of the module do automatically and others do not. Check your installed version's manual page.

**`pam_systemd` often does nothing useful in containers.** `systemd-logind` typically does not run inside containers, and `pam_systemd` either fails silently (on `optional`) or fails noisily (on `required`). For containerised services, marking it `optional` (its common default on Debian) is correct; for any container that needs the logind-session properties `pam_systemd` provides, you need a fully initialised systemd inside the container, which is a substantially different container design.

**SSSD may or may not be available.** Whether a container can reach an SSSD instance depends on how it is deployed — whether the SSSD socket is bind-mounted into the container, whether NSS is configured identically inside and outside. These are deployment-specific questions with no universal answer, but the symptom — `getent passwd` returning nothing inside the container for a directory user — is always the first diagnostic step, per Chapter 10.1.

The overall advice for containerised PAM: treat the container environment as a stripped-down system that may lack several of the privileged kernel features that some PAM modules depend on. Audit which modules in your stack depend on features not available in the container context, and either provide them or replace those modules with equivalents that degrade gracefully. This is a specific application of a general theme the whole series has emphasised: a module's behaviour is not solely a property of its configuration line, but of the environment it runs in, and a stack that is entirely correct in one environment can fail in a different one for reasons the configuration file alone does not reveal.



## 11.4 Recovering From a Broken Configuration

The inevitable happens: a misconfiguration locks everyone out. Here is the escalation ladder, from least disruptive to most.

### Level 1: A second root shell you kept open

You remembered Chapter 2's lab discipline. An existing root shell is not re-authenticated — it survives any PAM configuration change, no matter how catastrophic. Restore the backup you made before editing:

```
# cp /root/sshd.bak /etc/pam.d/sshd
```

Verify with a new terminal before closing the backup session.

If you are reading this section because you did not keep a second root shell open: the remaining levels apply, and each one costs more time, more access requirements, or more downtime than the one before it — which is the entire argument for the discipline in the first place.

### Level 2: Another session on the same machine

A different user who is already logged in, or a different root session from a different terminal. `su` to root from there. If PAM is broken for `su` too (you edited `common-auth` or a shared aggregation file), try `runuser` as root, which bypasses authentication entirely.

### Level 3: Physical or virtual console

SSH may be broken while the console still works, if the breakage is in `/etc/pam.d/sshd` specifically and the console service file is different. Console access requires physical presence or IPMI/KVM access for virtual machines.

### Level 4: Single-user mode / rescue target

```
# On GRUB, add to the kernel line:
systemd.unit=rescue.target
# or, older style:
single
```

Rescue mode on a systemd system drops you to a root shell with a minimal environment. Network may not be available; the filesystem is mounted read-write; PAM is not involved.

```
# After entering rescue:
# cp /root/sshd.bak /etc/pam.d/sshd
# systemctl reboot
```

### Level 5: `rd.break` and early userspace

On systems using an initramfs, breaking into early userspace before the main filesystem is mounted, then chrooting in:

```
# GRUB kernel line additions:
rd.break enforcing=0
```

This drops you to a shell before the main system is mounted at `/sysroot`:

```
# mount -o remount,rw /sysroot
# chroot /sysroot
# cp /root/sshd.bak /etc/pam.d/sshd
# exit
# reboot
```

### Level 6: Live media chroot

Boot from a live USB or rescue ISO, mount the system's filesystems, and chroot:

```
# mount /dev/sda1 /mnt
# mount --bind /dev /mnt/dev
# mount --bind /proc /mnt/proc
# mount --bind /sys /mnt/sys
# chroot /mnt
# cp /root/sshd.bak /etc/pam.d/sshd
# exit
# umount -R /mnt
# reboot
```

### Documenting the recovery

Whichever level was needed, the recovery is not complete until the cause is understood and recorded. A configuration restored from backup without understanding why the previous version broke everything is a configuration that will break the same way again, possibly during the next change window, possibly by a different person unaware of the earlier incident. The minimum record worth keeping:

```
What broke: <one sentence>
Root cause: <the specific line and mechanism, per Chapter 4's algorithm>
Recovery level used: <1-6, per this section>
Time to recovery: <duration>
Prevention: <what changes to process or configuration prevent recurrence>
```

This is a small amount of overhead immediately after a stressful incident, and it is precisely the kind of record that turns an isolated incident into an organisational learning event rather than a repeat performance. The "prevention" line is the one most often skipped and most valuable — per this chapter's own maintenance checklist in 11.8, a recovery without a corresponding process change is a recovery that has fixed the symptom without addressing why the second root shell was not open, or why the jump count was not verified, or whichever specific step in the runbook from 11.8 was the one actually skipped.

### The common lockout patterns and how to avoid them

Three patterns produce the overwhelming majority of self-inflicted PAM lockouts, each avoidable with one specific precaution.

**Editing `common-auth` or an aggregation file** without keeping a backup session. The blast radius is every service, simultaneously, which means the session you would use to fix it is also affected. The precaution: always have a root session open *on a different terminal* before touching any aggregation file, and test with `pamtester` against multiple services before closing it.

**Changing a jump count (`success=N`) without recounting.** The new line count does not match the old jump target; the stack terminates without establishing a success; total denial, nothing in the logs. The precaution: Chapter 4's counting rules, applied by hand, with the count written as a comment on the jump line.

**Removing a module that `sufficient` lines above it depend on.** If `pam_permit.so` — the terminator that the `success=1` jump in Debian's `common-auth` lands on — is deleted because it appears redundant, every login fails silently. The precaution: before removing any module, trace Chapter 4's algorithm to confirm whether any other line's jump target depends on it.

None of these are exotic. All three have taken down production systems. All three are recoverable from level 1 if you kept a second shell; all three require a reboot if you did not.

---

## 11.5 Auditing an Inherited Configuration

A complete audit of a PAM configuration you did not write, from first principles. Each item is a question to answer from the configuration itself, confirmed by testing where noted. Run through all twenty in order the first time; on subsequent quarterly reviews, the items most likely to have drifted — lockout configuration, second-factor placement, and the `nullok`/`pam_exec` checks — are worth prioritising if time is limited, since they represent the highest-consequence findings per the failure-signature table in 11.9.

### Foundation

**1. Does every PAM-aware service have a configuration file?** Per Chapter 2:

```
$ for f in /usr/bin/* /usr/sbin/*; do
    [ -f "$f" ] && ldd "$f" 2>/dev/null | grep -q libpam && echo "$f"
  done | while read b; do
    s=$(basename "$b")
    [ -f "/etc/pam.d/$s" ] && echo "OK $s" || echo "MISSING $s"
  done
```

Any service reporting MISSING falls back to `other`; audit what `other` contains.

**2. What does `other` contain?** `cat /etc/pam.d/other`. Confirm with `pamtester nosuchservice "$USER" authenticate`.

**3. Which files are generated?** Per Chapter 2: Debian markers in `common-*`, RHEL symlinks, `authselect check`. Do not plan to edit generated files directly.

**4. Are file permissions correct?**

```
# find /etc/pam.d /etc/security -type f ! -user root -o -perm /022
# find /lib/*/security /usr/lib64/security -type f ! -user root -o -perm /022 2>/dev/null
```

No output expected. Any output is a finding.

**5. Does the module set match the package baseline?**

```
# rpm -V pam                   # RHEL
# debsums -c libpam-modules    # Debian
```

Investigate any deviation — it may be a legitimate distribution patch, or it may not be.

### Authentication

**6. Is `nullok` present anywhere it should not be?**

```
$ grep -rn nullok /etc/pam.d/ | grep -v '^\s*#'
```

Cross-reference with:

```
# awk -F: '($2 == "") {print $1}' /etc/shadow
```

An account with an empty shadow field and `nullok` in the stack for a network-facing service is an authentication bypass.

**7. Is lockout configured and actually working?** Per Chapters 6 and 8:

```
$ grep -rn faillock /etc/pam.d/
```

Three invocations expected: `preauth` in `auth`, `authfail` in `auth`, and a bare `account`-stack line. Confirm all three are present. Confirm the `authfail` line is reachable after an authentication failure — Chapter 4's ordering requirement. Confirm the `account`-stack line is present — Chapter 8's scenario.

**8. Are second-factor modules placed correctly?** Per Chapter 10:

```
$ grep -rn 'u2f\|authenticator\|yubico' /etc/pam.d/
```

For each result, determine which stack it is in (`auth` or `account`) and test with a key-based SSH login to confirm whether it applies. If it is only in `auth` and the threat model requires protection against key-based logins, this is a finding.

### Account and access

**9. Do access restrictions sit in `account`, not `auth`?**

```
$ grep -n 'pam_access\|pam_time\|pam_succeed_if\|pam_listfile' /etc/pam.d/*
```

For each result, verify the management group (the first field). Any of these in `auth` that are intended as access restrictions rather than routing logic should be in `account`.

**10. Is there a catch-all deny in `access.conf`?**

```
$ tail -5 /etc/security/access.conf
```

If the last non-comment line is not `- : ALL : ALL`, the ruleset is permissive by default for unmatched origins.

**11. Is account expiry actually working?**

```
$ chage -E $(date -d yesterday +%Y-%m-%d) audit-test-account
$ pamtester sshd audit-test-account acct_mgmt
$ chage -E -1 audit-test-account    # restore
```

Confirm the expired account is refused. Confirm a key-based SSH attempt to the same account also fails.

### Password

**12. Is `use_authtok` present on every module after the first in the `password` stack?**

```
$ awk '$1=="password"' /etc/pam.d/common-password 2>/dev/null /etc/pam.d/system-auth 2>/dev/null
```

Per Chapter 7's demonstration: without `use_authtok` on `pam_unix`, quality rules are bypassed silently.

**13. Is `enforce_for_root` set in `pwquality.conf`?**

```
$ grep enforce_for_root /etc/security/pwquality.conf
```

If absent, root changes passwords without quality checks.

**14. Is the hash algorithm and cost appropriate?**

```
# awk -F: '{split($2,a,"$"); if(a[2]) print $1, "$" a[2] "$"}' /etc/shadow | head
```

Verify the algorithm matches policy, and verify `rounds=` (or equivalent cost for yescrypt) is explicitly set rather than left at the compiled-in default.

### Session

**15. Is `pam_loginuid` present on every service offering shell access?**

```
$ grep -L pam_loginuid $(grep -l 'session' /etc/pam.d/*)
```

Any result offering a shell is an accountability gap in the audit trail.

**16. Is lingering audited against disabled accounts?** Per Chapter 9:

```
$ for u in $(loginctl list-users --no-legend | awk '{print $2}'); do
    linger=$(loginctl show-user "$u" -p Linger --value 2>/dev/null)
    locked=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
    echo "$u  linger=$linger  passwd_status=$locked"
  done | grep 'linger=yes'
```

Each result deserves individual review.

**17. Is every `pam_exec` line explained?**

```
$ grep -rn pam_exec /etc/pam.d/
```

Every result needs a named owner and stated purpose. An unexplained `pam_exec` is the highest-severity finding in a PAM audit, per Chapter 1's attack-surface discussion.

### Integration

**18. Does `getent passwd` work for every user category?** Per Chapter 10.

**19. Is SSSD or the directory service monitored?** A correct PAM configuration backed by an unmonitored directory service is an outage waiting to be discovered reactively.

**20. Is the offline-login behaviour tested?** Stop the directory service and confirm what happens. Per Chapter 10's offline-login section.

---

## 11.5a Comparing Against a Known-Good State

The 20-item audit in 11.5 answers "is this currently correct." A different and complementary question is "did this change unexpectedly." The two questions have different answers and require different tools.

For comparing a current configuration against a saved baseline — what a system looked like immediately after provisioning, or after the last verified-correct audit — `diff` is the simplest possible tool and the right one for this specific job:

```
$ diff -r /root/pam-baseline/ /etc/pam.d/
$ diff -r /root/security-baseline/ /etc/security/
```

The baseline is whatever you captured after the last verified-good state. For a system under configuration management (Ansible, Puppet, Salt), the rendered configuration from the CM run is the baseline, and divergence from it is detectable by comparing CM's expected state against the actual files — most CM tools have a `--check` or `--diff` mode that does exactly this without making changes:

```
$ ansible-playbook site.yml --check --diff -l hostname
```

For a system not under configuration management, building a baseline manually at commissioning time and storing it in a protected location is the minimum viable alternative:

```
# At commissioning, after verification:
# cp -r /etc/pam.d/ /root/pam-baseline-$(date +%F)/
# cp -r /etc/security/ /root/security-baseline-$(date +%F)/
```

The value of this is not redundancy with auditd — the auditd rules catch *when* something changed; the baseline comparison catches *what* the delta is, which is the thing you need to report after an incident, not during detection. Both are complementary; neither substitutes for the other.

---

## 11.5b What Attackers Do With PAM Access

Worth a short, direct treatment, because the defensive measures in 11.5 and 11.6 are easier to take seriously once the specific offensive techniques are named. All of these are documented, occurring in the wild, and detectable by the controls this series has described.

**Inserting a `sufficient pam_permit.so` at the top of a service's `auth` stack.** One line, no binary modified, total authentication bypass for that service. Detectable by the `pam_config` auditd rule and the AIDE check on `/etc/pam.d/`. Preventable by restricting write access to that directory to the absolute minimum necessary — the root account, and no service accounts.

**Replacing or modifying `pam_unix.so`** with a version that verifies the password correctly and also logs it, sends it over the network, or writes it to a file. No configuration change needed. Detectable only by the AIDE hash check on the module directory and by the package integrity check. This is one of the better-known post-exploitation persistence techniques specifically because it is so difficult to detect without file integrity monitoring — nothing in the functional behaviour of the system changes.

**Adding a `pam_exec` line** that runs a backdoor script. One configuration line, no binary change, arbitrary code execution at root during every authentication. Detectable by the `pam_config` auditd rule and the `pam_exec` audit item in 11.5's checklist. Preventable by monitoring write access to `/etc/pam.d/` and by regularly running the `grep -rn pam_exec /etc/pam.d/` audit.

**Disabling lockout** by removing the `authfail` line from a service's `auth` stack or by changing the `required`/`sufficient` flags to prevent it from being reached. Makes brute-force attacks feasible on the service. Detectable by the `pam_config` auditd rule. Preventable by the same monitoring, and by the lockout-functionality test in 11.7's quarterly checklist.

The theme across all four: the controls in this chapter (auditd rules, AIDE, the `pam_exec` audit, file permissions, package integrity) are not just compliance checkboxes. They are the detection layer for a specific, documented class of attack that otherwise leaves no obvious trace in system logs. A PAM configuration that is monitored for changes and whose modules have verified integrity is meaningfully harder to use as a persistence mechanism than one where neither is true. The monitoring costs thirty minutes to set up; the absence of monitoring costs an incident timeline that starts weeks later and runs backward from an unexplained access event, with far less evidence available to reconstruct what actually happened than would exist if the controls in 11.5 and 11.6 had been in place from the start.



## 11.6 The Auditd Rules

The audit rules that make ongoing change detection possible, rather than relying on periodic spot-checks. Add to `/etc/audit/rules.d/pam.rules`:

```
# PAM configuration files
-w /etc/pam.d/            -p wa -k pam_config
-w /etc/security/         -p wa -k pam_config

# PAM module directory
-w /usr/lib64/security/   -p wa -k pam_modules
-w /lib/x86_64-linux-gnu/security/ -p wa -k pam_modules

# Faillock state
-w /var/run/faillock/     -p wa -k pam_faillock_state

# SSSD configuration
-w /etc/sssd/sssd.conf    -p wa -k sssd_config
```

```
# augenrules --load
# service auditd restart
```

Query after suspicious activity:

```
$ ausearch -k pam_config -ts today
$ ausearch -k pam_modules -ts today
```

These rules catch file modifications. They do not catch in-memory attacks or modifications that bypass the audit syscall path. For a higher-assurance environment, supplement with a file-integrity tool (AIDE, Tripwire, OSSEC) covering the same paths with cryptographic hashes checked out-of-band, per the AIDE-specific walkthrough below.

### File integrity monitoring, specifically for PAM

Beyond event-based audit rules, periodic hash-based integrity checking gives a different kind of assurance: not just "did something change" but "does this file match the baseline we established when the system was in a known-good state." The two approaches are complementary.

For AIDE:

```
# In /etc/aide.conf, ensure these paths are covered:
/etc/pam.d/                 CONTENT_EX
/etc/security/              CONTENT_EX
/usr/lib64/security/        CONTENT_EX
/lib/x86_64-linux-gnu/security/ CONTENT_EX

# After configuring:
# aide --init        # establish the baseline
# aide --check       # compare current state against baseline
```

The baseline should be established immediately after the system is provisioned and its PAM configuration verified — not after any extended period of operation where the "good" state is uncertain. Run `aide --check` at whatever frequency your threat model demands; weekly for a standard server, daily for a high-value target, and always immediately after any planned PAM configuration change, so the new state becomes the next baseline rather than a persistent, unexplained diff.

A difference reported by `aide --check` in the module directory requires investigation before any other diagnostic step, per Chapter 1's point that a modified module is a full compromise of the authentication path. The expected outcome of that investigation is one of: a known, package-delivered module update (verify against the package manager), a legitimate admin-deployed module (verify it was documented and intentional), or an unexplained modification (treat as a security incident, not a configuration problem, and escalate accordingly rather than attempting to resolve it as routine drift).

---

## 11.7 Modules That Have Changed or Disappeared

This is the version-churn note that Chapter 1 introduced as a running discipline and that Chapter 7 applied to `pam_cracklib`/`pam_pwquality` specifically. In the hardening context, it means something concrete: a module named in an audit finding may no longer be the right answer, and a "missing" module may have been intentionally removed. Worth applying this lens to every item in 11.5's checklist before acting on a finding.

The changes that matter most for a hardening audit in 2025–2026:

**`pam_tally2`** has been removed from Linux-PAM. Any configuration still referencing it should have been migrated to `pam_faillock`. A stack referencing a removed module gets a faulty-placeholder per Chapter 2, and the placeholder's control flag determines whether the login silently succeeds or silently fails — neither is the intended behaviour.

**`pam_cracklib`** has been removed in favour of `pam_pwquality` on most current distributions. Same concern: a reference to a missing module gets a placeholder.

**`pam_lastlog`** has been removed from some distributions' default sets. Whether its absence is a problem depends on whether your environment actually relies on the "last login" banner for anything operational or compliance-related.

**`pam_unix`'s `remember=`** argument should be considered deprecated in environments that have `pam_pwhistory` available, per Chapter 7. The two can coexist but should not, and the redundancy is easy to miss in an audit.

The diagnostic for all of these: `ls /lib/*/security/ | grep -E 'pam_(tally2|cracklib|lastlog)'`. If a module listed in `/etc/pam.d/` does not appear in this output, the configuration needs attention. The fix is never "remove the module from the configuration without replacing its function" unless you have explicitly decided the function is no longer needed. The fix is migration: `pam_tally2` to `pam_faillock`, `pam_cracklib` to `pam_pwquality`, `pam_lastlog` to whatever records last-login information in your environment now (typically utmp/wtmp tooling rather than PAM).

This section will itself age, in exactly the way it describes other sections of this document aging — the specific modules named here are current as of this series's writing, and a reader working through this material some years later should treat this list as a starting point for the same `ls`-and-cross-reference technique rather than as an exhaustive, permanently accurate inventory. The technique outlives the specific examples.



## 11.8 A Maintenance Checklist

For recurring reviews — quarterly is common; monthly is appropriate for high-compliance environments.

**Monthly:**
- Run `ausearch -k pam_config -ts 30daysago` — did anything change unexpectedly?
- Run the `nullok` check (item 6) and the `pam_exec` check (item 17).
- Run the lingering audit (item 16) against the current list of disabled accounts.
- Confirm SSSD and logind are running and healthy, and that the monitoring covering them would actually alert if either stopped.

**Quarterly:**
- Run the full 20-item audit checklist from 11.5.
- Test the lockout mechanism with a deliberate failed-attempts sequence.
- Test offline-login behaviour.
- Confirm the second factor covers key-based SSH where required.
- Verify package integrity: `rpm -V pam` or `debsums -c libpam-modules`.
- Compare against the known-good baseline per 11.5a, and update the baseline once the current state is reverified.

**On every account offboarding:**
- Check and disable lingering: `loginctl disable-linger <user>`, per Chapter 9's lingering audit.
- Check for active background processes: `loginctl user-status <user>`.
- Confirm the `account`-stack restrictions (expiry, access rules) actually refuse both password and key-based logins, not only whichever one was tested when the restriction was first configured.

**On every PAM configuration change:**
- Backup before editing, every time, without exception.
- Keep a second root shell open throughout.
- Test with `pamtester` before testing with a real login.
- Test the violation case, not only the success case.
- If the change touches an aggregation file, test every service that includes it.
- Leave the change in the audit trail.

### A minimal change runbook

Worth having this written down somewhere accessible, rather than reconstructed from memory during an actual change window, since the steps above compress into a short, linear sequence that is easy to follow under pressure precisely because it is short:

```
1. State the intended change and the expected outcome in one sentence.
2. Open a second root shell. Confirm it works. Do not close it.
3. Identify blast radius: which services does this file affect? (Chapter 2, 2.12)
4. Back up: cp -a <file> <file>.$(date +%F-%H%M%S).bak
5. Make the change.
6. Test with pamtester: success case AND failure case, for every affected service.
7. Test with a real login from a new session, on at least one affected service.
8. If anything fails: restore from the backup shell, not the shell that was
   testing the change.
9. If everything passes: document what changed and why, close the second
   root shell.
```

Step 6's insistence on testing both cases is the single item on this list most often skipped under time pressure, and it is the one this entire series has returned to more than any other — a stack that passes the success case and silently fails the violation case is, per Chapter 4's repeated warning, worse than a stack that fails obviously, because it produces false confidence rather than an actionable error.

---

## 11.9 The Failure Signatures, Collected

A reference for the specific symptoms this series has named throughout, collected in one place.

| Symptom | Cause | First check |
|---|---|---|
| Total denial, correct password, nothing in logs | Jump off end of stack (Chapter 4, trace 6) | Count lines between `success=N` and target |
| Total denial after config change | Faulty module placeholder on `required` line | `journalctl grep "faulty module"` |
| Config change has no effect | Editing a generated file, or wrong service name | `authselect check`, `strace -e trace=openat su` |
| Correct password, connection closes | `account` stack denial | Read `(service:account)` annotations |
| MFA module not running for SSH keys | Second factor only in `auth` (Chapter 10) | Move to `account` or use `AuthenticationMethods` |
| Lockout not counting failures | `authfail` unreachable due to `requisite` on auth module | Chapter 4 exercise 14 |
| Lockout not applying to key-based SSH | `account`-stack `pam_faillock` line absent | `grep faillock /etc/pam.d/<service>` |
| Resource limits not taking effect | Systemd cgroup limits overriding `limits.conf`, or service not PAM-spawned | `systemctl show user-$(id -u).slice | grep Max` |
| Quality rules not enforced | Missing `use_authtok` on `pam_unix` in `password` stack | Chapter 7, trace the password stack |
| `sudo` timestamp bypass | Second factor only applies when timestamp is expired | `sudo -k` before testing |
| User exists but cannot log in and `pamtester` works | Application-level restriction (sshd `AllowUsers`, sudoers, firewall) | `sshd_config`, `sudoers -l` |
| User does not exist | NSS, not PAM | `getent passwd <user>` first |
| Lingering process after account lockout | `session`-stack decision (lingering) independent of `account`-stack lockout | `loginctl disable-linger` |
| Environment variable not visible to a service | Set via the wrong mechanism (pam_env.conf vs /etc/environment vs shell startup) | Chapter 9, three-mechanism table |
| Second factor bypassed via SSH key | Placed only in `auth`, not `account` | Chapter 10, complete SSH-key-bypass statement |
| Directory outage locks out all remote users | `authinfo_unavail` mapped to `die` instead of `ignore` | Chapter 4 trace 5, Chapter 10.7 |
| Loginuid unexpectedly changed or unchanged across a privilege transition | Different services set loginuid differently (`su` vs `sudo` vs `runuser`) | Chapter 10, trace comparison |

Every row in this table traces back to a specific chapter and a specific mechanism covered there in depth. The table is a shortcut for someone who has already read the relevant chapter and needs a fast reminder, not a substitute for understanding the mechanism behind each row — a symptom matched to a cause without understanding why that cause produces that symptom is a coincidence waiting to mislead you the next time the same symptom has a different root cause.

---

## 11.10 Verification

The final verification exercises in the series — designed to confirm the diagnostic ability this chapter teaches rather than the configuration knowledge the preceding chapters covered.

**1. Produce each symptom in the table at 11.8 on a test machine**, deliberately, and confirm you can diagnose each one from the logs alone before looking at the configuration. This is the inverse of the chapter's preceding exercises — rather than building a configuration and confirming it works, break a known-good configuration in each of the ways listed and confirm the diagnostic procedure from 11.2 leads to the right place within two minutes for each.

**2. Run the complete 20-item audit from 11.5 against a real system you administer**, treating each item as a concrete test. Write down the results. Any item that cannot be tested (because the relevant module is absent or the service is not deployed) is still worth noting — an explicit "not applicable because..." is more useful than a blank, because it documents the reasoning rather than leaving a future auditor to wonder.

**3. Set up the auditd rules from 11.6 and then make a change to `/etc/pam.d/sshd`**. Confirm the change appears in `ausearch -k pam_config`. Then make a change to the module directory (even a harmless `touch`) and confirm it appears in `ausearch -k pam_modules`.

**4. Reproduce a complete lockout-and-recovery cycle**: lock an account via `pam_faillock` by deliberate failed attempts, confirm it is refused for both password and key-based logins, inspect the state with `faillock --user`, and clear it with `faillock --user --reset`. Then reproduce the same cycle without the `account`-stack `pam_faillock` line, and confirm the key-based lockout is ineffective — this is Chapter 8's opening scenario, run rather than read.

**5. Break a configuration at each level of 11.4's escalation ladder** (on a test VM), and practice the recovery from each level. Level 1 (second root shell), level 4 (single-user mode), and level 6 (live media chroot) are the three worth practising at least once before relying on them in a real incident. The others follow the same pattern.

**6. Reproduce 11.2a's misreading pattern deliberately.** Make `pam_faillock` lock an account, then attempt a login and read `sshd`'s application-level log line. Confirm it says "Failed password" rather than "Account locked." This is the specific, named misread that has cost people investigation time in every environment this series was developed against — see it once as a deliberate exercise, and you will not be fooled by it under pressure.

**7. Establish an AIDE baseline, per 11.6, on a test machine.** Then modify one file in `/etc/pam.d/` and one module in the security directory, and run `aide --check`. Confirm both modifications are detected. Then restore the originals and confirm they are no longer reported. This completes the monitoring picture from auditd (event-based, real-time) through AIDE (hash-based, periodic), which together cover the realistic detection surface for the attack techniques in 11.5b.

**8. Check for removed-module references, per 11.7**, on a production system you administer. If any are found, treat the finding seriously — the faulty-module placeholder behaviour Chapter 2 described is making some decision right now in your authentication stack, and the decision it is making depends on the control flag of a line that was written for a different module with different return values.

---

## Where the Series Ends

You have the complete mechanism. The configuration model from Chapter 2. The four groups from Chapter 3, with their boundaries and the call sequences that cross them. The evaluation algorithm from Chapter 4, which is what makes stacks readable rather than mystical. The API from Chapter 5, which makes modules comprehensible rather than opaque. The module reference across Chapters 6 through 9, which gives the mechanism names. The integration layer from Chapter 10, which connects the mechanism to the real world of directories and second factors and services that make their own decisions alongside PAM's. And now the diagnostic method, which makes all of it usable under the specific conditions where the mechanism has stopped doing what you expected.

The README, at the very start, offered one measure of whether the series had done its job: the ability to open an unfamiliar `/etc/pam.d/sshd` and say precisely what will happen when someone types a password. That is now a matter of applying Chapter 4's algorithm to whatever you find — flattening the file per Chapter 2's `pamflat` technique, sorting by type per Chapter 3, tracing per Chapter 4, looking up any unfamiliar module in the relevant chapter of 6 through 10, and confirming with `pamtester` per this chapter's procedure.

The part the README did not promise, but this chapter delivers: knowing what to do when what should happen and what does happen are different. That is 11.2's systematic procedure, 11.4's recovery ladder, 11.5's audit checklist, and 11.9's symptom table — the practitioner half of a reference that started with history and theory and ends here.

One closing thought, worth carrying forward past this series entirely. PAM is thirty years old, and the design decisions traced back to OSF-RFC 86.0 in Chapter 1 — separating policy from mechanism, making authentication pluggable, decomposing a login into four independent questions — are still, thirty years later, the correct way to think about the problem. Every technology this series has connected PAM to along the way — SSSD, systemd, cgroups, FIDO2 hardware tokens, yescrypt — arrived after PAM and was integrated into it rather than replacing it, because the underlying architecture had room for each of them without needing to be redesigned. That is a rare property in software, and it is worth appreciating on its own terms, independent of whatever specific configuration problem brought you to read this series in the first place.

---

## Further Reading for This Chapter

- `man 8 pamtester`
- `man 8 faillock`, the administration command for inspecting and clearing lockout state
- `man 8 ausearch`, `man 8 auditctl`, `man 5 audit.rules`
- `man 8 augenrules`
- `man 8 aide` or the equivalent file-integrity tool for your environment
- `man 8 pam_debug`
- `man 5 journald.conf`, for the log-retention material in 11.1
- The Linux-PAM debugging documentation, typically found under `/usr/share/doc/libpam-doc/` or at `linux-pam.org`
- Your organisation's own incident response and change management runbooks — the templates in 11.7 and 11.8 are starting points, not replacements for whatever process your environment already requires
- Your own generated configuration — after all eleven chapters, the single most productive thing to read is the real files on the real system you administer, with everything this series has covered available to interpret them
