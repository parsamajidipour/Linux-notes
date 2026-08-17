# 08 — Account and Access Control Modules

Every module in this chapter answers a version of one question: not "is this credential correct" but "may this account be used, here, now, by this means." Chapter 3 drew the line precisely — the `account` group runs after authentication and is entirely indifferent to whether the password was right. This chapter is the module-level reference for that line.

Read together, this chapter's modules cover the two dimensions almost every real-world access policy actually needs beyond bare identity: *where* an attempt is coming from and *when* it is permitted, plus the two forms of hard blocking — system-wide maintenance and per-account lockout — that override both dimensions entirely when triggered. Nearly every organisational access policy this author has encountered decomposes into some combination of these, which is part of why this chapter, more than Chapters 6 or 7, tends to map directly onto a written security policy document a compliance team would recognise on sight.

It covers `pam_access` and origin-based restriction, `pam_time` and time-of-day restriction, `pam_nologin` and system-wide maintenance blocking, `pam_succeed_if` and `pam_listfile` revisited specifically in their `account`-stack role, and — at the centre of the chapter — `pam_faillock`, the module every previous chapter has referenced without showing whole. Its three-line `preauth`/`authfail`/`authsucc` idiom, whose ordering dependency Chapter 4 explained mechanically and whose cross-invocation state Chapter 5 built in miniature, finally gets assembled here into the complete, working mechanism.

### A short scenario, to set the frame

Consistent with the opening scenarios in Chapters 6 and 7.

A security team, following a credential-stuffing incident against a public-facing SSH bastion, mandates account lockout after five failed attempts. An administrator implements `pam_faillock` correctly — threshold, window, and unlock time all set per the mandate, verified with a deliberate five-failed-attempts test that locks the account exactly as expected. The finding is closed.

Eighteen months later, during an unrelated investigation, someone notices that the same bastion accepts SSH connections from a contractor's account using a public key, and that this specific account was locked by `pam_faillock` two weeks earlier following a genuine credential-stuffing attempt against it — and yet the key-based connections during that locked window succeeded without any indication in the logs that a lock was even in effect. The `pam_faillock` configuration was never wrong in the sense the original test checked: password-based logins against the locked account were, and remained, correctly denied throughout. But the `preauth`/`authfail` pair lived entirely in the `auth` stack, and per Chapter 1's finding — repeated at the module level in Chapter 5, and now the organising principle of this chapter's section 8.5 — key-based authentication does not traverse `auth` at all. The lockout that closed the original finding never covered the authentication method that mattered most for this specific bastion, because nobody's test happened to use a key.

Hold this scenario through 8.6 and 8.9 specifically, where the `account`-stack `pam_faillock` line — the one that closes exactly this gap — gets the attention its apparent simplicity tends to make people skip.

---

## 8.1 Why This Group Gets Misconfigured Silently

Worth restating from Chapter 4 before the module reference begins, because it governs how you should read every section that follows. A mistake in the `auth` stack tends to be loud — a locked-out login is noticed within minutes by the person it happened to. A mistake in the `account` stack tends to be silent — a restriction that fails to apply produces no error, no denied login, nothing distinguishable from the restriction never having existed. Every module in this chapter is, in that specific sense, higher-stakes to get wrong than it looks, because the wrong-direction failure is invisible by default and the right-direction failure is loud enough that nobody ships it.

The practical consequence: every worked example and verification exercise in this chapter tests the *violation* case explicitly — attempts to log in from a disallowed host, at a disallowed time, on a locked account — rather than only confirming that legitimate use still works. A stack that lets legitimate users through is not evidence the restriction functions; only a deliberate violation attempt is.

One more framing point specific to this group, distinguishing it from the two chapters preceding it: `auth` and `password` are both, in a real sense, about a single event — one credential check, one password change. `account` is evaluated on every single login attempt through every single service that calls `pam_acct_mgmt()`, regardless of how that attempt was authenticated, which per Chapter 3 is essentially all of them. This makes `account` simultaneously the group with the broadest coverage of any restriction placed correctly within it, and the group where a single misconfigured line has the broadest simultaneous impact — a `pam_access` rule that accidentally denies an entire subnet affects every service on the box at once, not just one, since every one of those services' `account` stacks consults the same shared `access.conf` through the same module.

---

## 8.2 `pam_access`

### What it does

Restricts login based on the origin of the attempt — remote host, local terminal, or network — matched against rules in a configuration file, independent of which user is authenticating or what credential they present.

### Which groups it serves

`account` only.

```
$ objdump -T /usr/lib64/security/pam_access.so | grep pam_sm_
```

Confirm on your own system; a `pam_access` line anywhere but `account` is a placement error of exactly the kind Chapter 3 and Chapter 6 both warned about.

### The configuration file

`/etc/security/access.conf` by default, though an alternate path can be given via the `accessfile=` module argument. Each line has the form:

```
permission : users : origins
```

`permission` is `+` (allow) or `-` (deny). `users` is a comma-separated list of usernames, `@groupname` for group membership, or `ALL`. `origins` is a comma-separated list of hostnames, IP addresses or CIDR ranges, `LOCAL` for local sessions with no remote host recorded, tty names, or `ALL`.

Rules are evaluated top to bottom, and **the first matching rule wins** — this is the module's own internal evaluation, separate from and prior to whatever the surrounding PAM stack's control flag does with the module's eventual single return value. It is worth being precise about this two-layer structure: `access.conf` has its own first-match semantics inside the module, and the module as a whole then produces one `PAM_SUCCESS` or `PAM_PERM_DENIED` that Chapter 4's stack-level algorithm evaluates in the ordinary way. Confusing the two — assuming the *stack's* control flag governs which access.conf rule "wins" — is a common misreading.

### A worked ruleset

```
+ : root : LOCAL
+ : parsa,priya : 192.168.10.0/24
- : ALL : ALL
```

Root may log in only locally. `parsa` and `priya` may log in from the specified subnet. Everyone else, from anywhere, is denied — the final catch-all line, and its absence is one of the most common `pam_access` mistakes: without an explicit trailing deny, any origin not matched by an earlier rule is implicitly permitted, which silently defeats the entire point of an allow-list-style ruleset. Read that sentence again; it is worth its own line in any audit checklist.

### Arguments

`accessfile=/path` — use an alternate rules file.

`fieldsep=` — change the field separator from `:`, occasionally needed when `:` conflicts with IPv6 address syntax elsewhere in a rule.

`noaudit` — suppress detailed audit-subsystem logging for this module specifically, distinct from ordinary syslog output.

`debug` — the usual verbose-logging convention from Chapter 5.

### Return values

`PAM_SUCCESS` if a matching `+` rule is found (or no rule denies, if the ruleset has no catch-all); `PAM_PERM_DENIED` if a matching `-` rule is found.

### Interactions

Depends entirely on `PAM_RHOST` and `PAM_TTY` being set correctly by the application, per Chapter 5's item-setting discussion — a service that never calls `pam_set_item()` with the remote host cannot be meaningfully restricted by origin, and `pam_access` will effectively see every attempt as originating from nowhere. This is worth checking directly rather than assumed, especially for less common or custom PAM-aware applications:

```
$ strace -f -e trace=write pamtester sshd "$USER" acct_mgmt 2>&1 | grep -i rhost
```

or, more directly, adding `debug` to the module line and checking what it logged as the matched origin for a known remote connection.

### Failure modes

The missing-catch-all mistake above is the most common. A close second: rules ordered so that a broad `+` rule appears before a narrower `-` rule intended to carve out an exception — since the first match wins, the broad allow fires first and the intended exception never has a chance to apply. Order matters here exactly the way it matters in a PAM stack itself, and for the same underlying reason: first-match, not best-match.

### A larger worked ruleset, tiered by trust level

The single-tier example above is enough to demonstrate the mechanism; real organisational policy is usually layered, and it is worth seeing a more realistic version to internalise how the first-match rule actually behaves under real complexity.

```
# Administrators: unrestricted, from anywhere, including the VPN and office network
+ : @admins : ALL

# Break-glass emergency account: office network only, never remote
+ : emergency : 10.0.1.0/24
- : emergency : ALL

# Contractors: office network and VPN range only
+ : @contractors : 10.0.1.0/24, 10.8.0.0/16

# Service accounts: only from the specific hosts that legitimately run them
+ : svc-backup : backup-host-01.internal, backup-host-02.internal
+ : svc-monitoring : monitoring-host.internal

# Everyone else, from the office network or VPN, no further restriction
+ : ALL : 10.0.1.0/24, 10.8.0.0/16

# Deny everything not explicitly matched above
- : ALL : ALL
```

Trace the `emergency` account specifically, since it demonstrates something the single-tier example did not: two rules for the same user, the first an allow scoped to a specific network, the second an unconditional deny. Because `pam_access` evaluates first-match, an attempt from `10.0.1.5` matches the first `emergency` rule and is permitted; an attempt from anywhere else falls through the first rule (no match) and reaches the second, `- : emergency : ALL`, which matches and denies. This two-line pattern — a narrow allow immediately followed by a broad deny for the same principal — is the standard idiom for "permitted only under this specific narrow condition, denied otherwise," and it depends entirely on the narrow allow being listed first, exactly as the ordering warning above states.

Also worth noting: the service-account rules are listed before the general "everyone else" rule, even though a service account would also technically match `@contractors` or the general catch-all if those came first — first-match again, and it is the reason more specific rules conventionally precede more general ones in a well-organised `access.conf`, mirroring the same discipline good firewall rule-writing uses for exactly the same underlying reason.

---

## 8.3 `pam_time`

### What it does

Restricts login based on time of day and day of week, matched against rules in `/etc/security/time.conf`.

Worth situating relative to something more familiar: this is conceptually similar to what a `cron`-adjacent scheduling tool restricts, but operating in the opposite direction — rather than controlling when a job *runs*, it controls when a *login* is permitted, and unlike `cron`'s own scheduling syntax, `time.conf`'s day-and-time notation is specific to this module and does not follow `crontab`'s five-field convention, which is worth knowing before assuming any familiarity with one transfers directly to the other.

### Which groups it serves

`account` only.

### The configuration file

```
services;ttys;users;times
```

Four semicolon-separated fields: `services` (which PAM service names this rule applies to, `*` for all), `ttys`, `users`, and `times` — a day-and-time specification using single-letter day codes (`Mo`, `Tu`, `We`, `Th`, `Fr`, `Sa`, `Su`, `Wk` for weekdays, `Wd` for weekend, `Al` for all) followed by an `HHMM-HHMM` range.

```
sshd;*;contractors;Wk0800-1800
```

Members of the `contractors` group may use `sshd` only on weekdays between 08:00 and 18:00, in whatever timezone the system clock is set to — worth stating explicitly, since a rule written by someone working in a different timezone than the server's configured one is a very easy way to enforce a policy that does not match anyone's actual intent.

A line beginning with `!` before a field negates it — `!Sa,Su` means "not Saturday or Sunday," a common way to express weekday-only rules more explicitly than `Wk`.

### Arguments

Historically minimal; the module's behaviour is controlled almost entirely through the rules file rather than module-line arguments.

### Return values

`PAM_SUCCESS` if within an allowed window (or if no rule applies to this service/user/tty combination — the default, absent any matching rule, is permissive); `PAM_PERM_DENIED` if a matching rule's window excludes the current time.

### Interactions

Independent of `pam_access` — the two modules check entirely different attributes and are commonly used together, one line each, both in the `account` stack, with no interaction between them beyond both contributing to the same stack evaluation per Chapter 4.

### Failure modes

The permissive-by-default behaviour noted above is itself worth internalising as a failure mode in waiting: a `time.conf` with no rule matching a given service, user, and tty combination does not deny that combination, it silently permits it regardless of time. This is the mirror image of `pam_access`'s missing-catch-all problem, and it means an incomplete `time.conf` — one that covers the services or users an administrator thought of but not all of them — provides less protection than its presence suggests. Auditing this file means checking what is *not* covered as much as what is.

Timezone mismatches, per the worked example above, are the second most common practical failure, and they are worth testing directly against the server's actual clock rather than assumed correct from the rule's face value:

```
$ date
$ timedatectl status 2>/dev/null || cat /etc/timezone
```

### A worked trace across a midnight boundary

`time.conf`'s `HHMM-HHMM` ranges do not require the start to be numerically smaller than the end, and it is worth tracing a range that crosses midnight explicitly, since it is a common real-world need — an overnight operations shift — and a common source of off-by-one confusion when written by hand.

```
sshd;*;oncall;2200-0600
```

Read naively, `2200-0600` looks like it might mean "from 22:00 to 06:00 the next calendar day," and that reading happens to be correct — the module interprets a range where the end time is numerically smaller than the start as wrapping across midnight, covering 22:00 through 23:59 of one day and 00:00 through 06:00 of the next as a single continuous window. The mistake worth guarding against is writing `0600-2200` when the intent was the overnight window — that specifies the *daytime* hours instead, the exact inverse of what an on-call overnight policy would need, and it is a purely textual, easily overlooked inversion. Test any midnight-crossing rule explicitly at a timestamp just before and just after the boundary:

```
# date -s "23:55:00" && pamtester sshd oncall-user acct_mgmt   # just before local midnight
# date -s "00:05:00" && pamtester sshd oncall-user acct_mgmt   # just after
```

on a test machine where adjusting the clock is safe to do — never on a system with other time-dependent services running, and always restored to correct time immediately afterward via NTP resynchronisation, since a manually set clock drifts and interferes with everything else that depends on accurate time.

### Interaction with `pam_access`, in combination

The two modules compose naturally when a policy has both a spatial and a temporal dimension — contractors permitted from the office network, but only during business hours, is two separate `account`-stack lines rather than an attempt to express both conditions in either module's own syntax:

```
account  required  pam_access.so
account  required  pam_time.so
account  required  pam_unix.so
```

Both `required`, per this chapter's general observation in 8.8 that `account` stacks lean toward all-`required` composition — a contractor login must satisfy both the origin rule and the time rule independently, and per Chapter 4's algorithm, two `required` lines with no jump between them simply both have to succeed, in either order, for the stack to proceed. There is no meaningful ordering advantage between these two specific lines the way there was a genuine efficiency argument for placing `pam_faillock` first in 8.8 — both are comparably cheap, local-file checks with no network round-trip.

---

## 8.4 `pam_nologin`

### What it does

Blocks non-root logins system-wide when a specific file exists, displaying that file's contents as the reason.

### Which groups it serves

Both `auth` and `account`, depending on distribution and version, though `account` is the more common and more semantically correct placement given this chapter's overall framing — whether an account may be used right now is exactly this module's question, not whether a credential is valid.

### The mechanism

```
# echo "System undergoing scheduled maintenance until 0400 UTC." > /etc/nologin
```

The presence of `/etc/nologin` (or `/run/nologin` on systems using that convention instead) blocks any non-root login attempt through a service whose stack includes this module, displaying the file's content as the rejection message. Root is always exempt, unconditionally, which is the entire operational point — an administrator performing maintenance needs to be able to get back in.

```
# rm /etc/nologin
```

Removing the file restores normal access immediately.

### Arguments

`file=/path` — use an alternate path instead of the default.

`successok` — a less commonly used variant altering exactly when the block applies relative to other checks; consult your version's manual page, since this has shifted across releases.

### Return values

`PAM_SUCCESS` for root, or for a non-root user when the file is absent; `PAM_AUTH_ERR` (in `auth`) or `PAM_PERM_DENIED`/similar (in `account`) for a non-root user when the file is present.

### Interactions

Simple and largely self-contained; its main interaction worth noting is with automation. A configuration management run or a deployment script that authenticates as a non-root service account during a maintenance window will be blocked by this exact mechanism, which is usually the correct behaviour but occasionally an unwelcome surprise if the automation was not written with `/etc/nologin` in mind — worth testing deliberately before relying on this mechanism as part of a maintenance runbook, rather than discovering the interaction during an actual maintenance window under time pressure.

### Failure modes

Forgetting to remove the file after maintenance concludes is the overwhelmingly common one, and it is worth building the removal into whatever process creates the file in the first place — a maintenance script that sets `/etc/nologin` at the start and unconditionally removes it at the end, including on an error exit path, rather than relying on a human to remember a manual cleanup step.

### The systemd-adjacent variant

Worth flagging for anyone working primarily on systemd-managed hosts: `systemctl` itself understands and can set a comparable maintenance flag through `systemctl --no-block start` combined with certain runlevel-adjacent targets on some configurations, and `/run/nologin` specifically (as opposed to `/etc/nologin`) is the path some distributions' own maintenance and shutdown tooling create automatically during a system halt sequence, briefly, as part of normal shutdown — meaning a `pam_nologin` deny observed in logs immediately around a reboot may be entirely expected shutdown behaviour rather than an administrator-set maintenance flag, and worth distinguishing before treating it as a finding:

```
$ ls -la /etc/nologin /run/nologin 2>/dev/null
$ journalctl -t systemd-user-sessions 2>/dev/null | tail
```

`systemd-user-sessions` is specifically the service responsible for managing `/run/nologin` automatically during boot and shutdown transitions on many current distributions, distinct from any file an administrator sets by hand at `/etc/nologin` — worth checking which path (or both) is populated before assuming a `pam_nologin` denial has a human-initiated cause.

---

## 8.5 `pam_succeed_if` and `pam_listfile`, in Their `account` Role

Both modules were introduced in Chapter 6 in their more common `auth`-stack routing role. Both are equally at home in `account`, and it is worth revisiting them briefly here specifically because their meaning shifts subtly with the group they sit in — per Chapter 3's framing, a condition evaluated in `auth` is contributing to an identity decision, while the identical condition evaluated in `account` is contributing to a usage-permission decision, and reading a stack correctly means noticing which group a given line belongs to before interpreting what a match or non-match implies.

### `pam_succeed_if` in `account`

```
account  required  pam_succeed_if.so  service in sshd:sudo quiet
```

A condition restricting which services this account rule applies to, using the `service` attribute rather than the `uid` conditions seen in Chapter 6's routing examples — the same expression syntax, applied to a different attribute, doing a fundamentally different job: not routing between authentication mechanisms, but gating whether this account may proceed for this specific service.

### `pam_listfile` in `account`

Chapter 6's deny-list worked example used `auth`; the identical configuration works unchanged in `account`, and the choice between the two groups for a `pam_listfile`-based restriction is worth making deliberately rather than by habit. An `auth`-stack `pam_listfile` restriction is bypassed by any authentication method that skips `auth` entirely — SSH public-key authentication, per Chapter 1's finding, repeated at the module level in Chapter 5's verification exercise 9. An `account`-stack placement is not bypassed this way, since `account` runs regardless of which `auth` mechanism succeeded. **For any access restriction where bypass via key-based authentication would be a problem, `account` is the correct group, not `auth`** — this is worth treating as close to an unconditional rule, and it is the single most consequential piece of practical guidance in this chapter for anyone auditing an existing configuration.

---

## 8.6 `pam_faillock`

The module this whole series has been building toward. Chapter 3 introduced its dual `auth`/`account` role. Chapter 4 explained, mechanically, why its three invocations must be ordered exactly as they are. Chapter 5 built a miniature version of its cross-invocation coordination mechanism from scratch. This section assembles all of it into the complete, working module.

### What it does

Tracks authentication failures per account over time and, once a configurable threshold is crossed within a configurable window, locks the account against further attempts for a configurable duration — genuine memory across separate login attempts, the specific capability Chapter 6 and Chapter 7 both closed by noting was still missing from every module covered up to that point.

### Which groups it serves

Both `auth` and `account`, and — this is the detail that makes the module work at all — it is invoked **three separate times** in a correctly configured stack, twice in `auth` and once in `account`, each invocation passing a different argument that tells the module which of its three roles it is playing on that particular call.

```
$ objdump -T /usr/lib64/security/pam_faillock.so | grep pam_sm_
pam_sm_authenticate
pam_sm_acct_mgmt
```

Two entry points, three configuration-line appearances — the module argument (`preauth`, `authfail`, or `authsucc`) selects the behaviour within `pam_sm_authenticate()` for the first two, while the third, `authsucc`, is conventionally still invoked through the `auth` entry point despite its name describing a success-handling role, because it needs to run in the same stack traversal as the failure-recording line to correctly clear the counter on a successful subsequent attempt. Consult your specific version's manual page for the exact current convention, since this is an area where Linux-PAM's own documentation has been refined across releases as the module's design matured.

### The three-line idiom, assembled

```
auth     required                              pam_faillock.so  preauth  silent  deny=5  unlock_time=900
auth     [success=1 default=ignore]             pam_unix.so      try_first_pass
auth     [default=die]                          pam_faillock.so  authfail deny=5  unlock_time=900
auth     required                               pam_permit.so

account  required                               pam_faillock.so
account  required                               pam_unix.so
```

This is deliberately simplified from the RHEL-generated stack Chapter 4's section 4.11 decoded — real distributions interleave this with directory-authentication fallback, `pam_succeed_if` UID routing, and other modules this series has covered separately. The simplified version here isolates `pam_faillock`'s own logic against a single credential mechanism so the three roles are visible without the surrounding routing noise; 8.7 below reconstructs the fuller, realistic version with a directory fallback included.

**Line 1, `preauth`.** Runs before any credential is checked. Its job: consult the current failure count for this account. If the account is already locked — the threshold was crossed by a previous attempt within `unlock_time` — this line itself returns a failure, and because it is `required`, that failure is recorded per Chapter 4's algorithm and the stack proceeds toward denial regardless of whether the password about to be checked is correct. This is the mechanism behind the specific, sometimes confusing symptom of a *correct* password being rejected on a locked account — the credential is never even meaningfully evaluated in a practical sense, because the account-level lock already determined the outcome.

**Line 2, `pam_unix`.** The actual credential check, marked with a bracketed `success=1` jump. On success, it jumps forward one `auth`-type line, skipping line 3's `authfail` entirely and landing on line 4's terminator, priming a success exactly as the `common-auth` terminator pattern did in Chapter 4. On failure, `default=ignore` means this line's own failure is discarded — deliberately, since the *real* record of failure for lockout purposes is `authfail`'s job on the next line, not this line's own bare `PAM_AUTH_ERR`.

**Line 3, `authfail`.** Reached only when line 2 failed and its jump did not fire. Its control, `[default=die]`, means it terminates the stack immediately after recording the failure — and this is the line that actually increments the counter. If the increment crosses `deny=`, the lockout is recorded here, with the specific timestamp and duration `preauth` will check on the next attempt.

This is also where Chapter 4's exercise 14 ordering dependency lives, stated precisely now that the mechanism is fully assembled: if line 2's control were `requisite` instead of the bracketed jump shown here, a wrong password would terminate the stack at line 2, before line 3 ever ran, and the failure would never be recorded — lockout would silently stop counting while every other part of the configuration continued to look correct on inspection. The bracketed jump on line 2 is not a stylistic choice; it is the specific mechanism that makes line 3 reachable on the failure path at all.

**Line 4, `pam_permit.so`.** The terminator, reached only via line 2's successful jump, exactly matching the `common-auth` pattern from every trace since Chapter 4.

**The `account`-stack `pam_faillock` line**, with no argument, is the module's third role: on every account-stage check, confirm the account is not currently in a locked state, independent of whatever happened in the `auth` stack during this specific attempt. This is what makes the lock apply even to authentication paths that skip `auth` entirely — a locked account should not be usable via SSH public key either, and per Chapter 3's finding that `account` is not skippable the way `auth` is, this line is what actually enforces that.

### Configuration file

`/etc/security/faillock.conf` holds the parameters more commonly than module-line arguments on current versions, mirroring the `pwquality.conf`-versus-module-argument pattern from Chapter 7 — and subject to the same precedence caution: a module-line argument, where present, generally overrides the file, so auditing one without the other risks an incomplete picture, exactly as Chapter 7 warned for `pwquality.conf`.

```
$ grep -v '^#\|^$' /etc/security/faillock.conf
```

Key parameters: `deny=` (attempts before lockout), `unlock_time=` (seconds before an automatic unlock, `0` for permanent until manually cleared), `fail_interval=` (the window within which failures count toward the threshold — an old failure outside this window does not contribute), `even_deny_root` (without it, root is exempt from lockout entirely, mirroring `pam_pwquality`'s `enforce_for_root` default from Chapter 7 and worth the same deliberate decision), `root_unlock_time=` (a separate, often longer unlock time specifically for root when `even_deny_root` is set), `silent` (suppress informational messages to the user attempting to log in, avoiding disclosure of account-lock state to an unauthenticated party — a genuine, non-cosmetic security consideration, since telling an attacker "this account is now locked" confirms the account's existence and recent targeting).

Two parameters worth a specific word of caution, since their names invite a reasonable but wrong assumption. `deny=` counts consecutive failures for a *specific account*, not attempts from a *specific origin* — an attacker distributing guesses for one account across many source IPs is still counted correctly, since the counter keys on the username, not the client address, which is the correct design for what this module is trying to prevent but occasionally surprises people expecting IP-based throttling instead. And `fail_interval=`, not `unlock_time=`, is the parameter that controls how far back a failure remains relevant to the count — confusing the two is a common source of a lockout policy behaving more or less strictly than intended.

### The `faillock` command

Inspection and administration, independent of editing any configuration file:

```
$ faillock --user parsa
$ faillock --user parsa --reset
```

The first shows the current failure count, timestamps of recent failures, and lock status for the named account. The second clears it. Both operate on the same underlying state the `preauth`/`authfail` lines read and write, and both are the correct tool for investigating or resolving a lockout — editing files under `/var/run/faillock/` or wherever the backend stores state directly, rather than through this command, is unsupported and version-fragile.

### Where the state lives

```
$ ls /var/run/faillock/ 2>/dev/null || ls /var/log/faillock/ 2>/dev/null
```

Per-user files, one per account with any recorded failure history, holding the timestamped attempt records `faillock`'s inspection command reads. Location has shifted across Linux-PAM releases — worth confirming on your specific system rather than assumed from an older reference, consistent with this series' running caution about version churn.

### Return values

From `pam_sm_authenticate()` in its `preauth` role: `PAM_SUCCESS` if not currently locked, `PAM_AUTH_ERR` or a lockout-specific value if locked. In its `authfail` role: always records the failure and returns a failure code, since by definition this line only runs after an actual authentication failure occurred earlier in the stack. In its `authsucc` role: clears the counter and returns success. From `pam_sm_acct_mgmt()`: `PAM_SUCCESS` if not locked, appropriate failure otherwise.

### Interactions

With `pam_unix` (or any other `auth`-stack credential module) via the specific ordering and control-flag requirements detailed above — this is the chapter's most concentrated illustration of Chapter 4's general principle that a module's placement and control flag are as much a part of "correct configuration" as the module's own arguments. With `pam_faildelay` from Chapter 6, complementarily rather than redundantly, per that chapter's dedicated discussion of the relationship. With the audit subsystem, since lockout events are exactly the kind of security-relevant state change Chapter 1's attack-surface discussion flagged as worth monitoring independently of the PAM logs themselves.

### Failure modes

**The `requisite`-instead-of-`sufficient` ordering mistake**, per Chapter 4's exercise 14 — changing the credential-check line's control flag so a failure terminates the stack before `authfail` is reached, silently disabling lockout while the configuration continues to look complete and correct on inspection.

**`even_deny_root` unset when a compliance or threat-model requirement assumes lockout applies universally** — the same silent-permissive-default pattern this chapter has now shown repeatedly across `pam_access`, `pam_time`, and now here.

**`unlock_time=0` (permanent lockout) combined with no operational process for clearing locks**, producing a support burden every time a legitimate user mistypes a password enough times — a genuine trade-off between security posture and operational cost that is worth making deliberately rather than inheriting from a distribution default without consideration.

**A denial-of-service angle worth naming explicitly**, since Chapter 8's own subject matter makes it directly relevant: an attacker who knows or can guess valid usernames can deliberately trigger lockout against them without ever needing a correct password, denying service to the legitimate account holder. This is not a flaw in `pam_faillock` so much as an inherent property of any lockout mechanism, and it is worth weighing explicitly against the credential-stuffing protection lockout provides — there is no configuration that eliminates this tension entirely, only ways to tune where the balance sits, primarily via `deny=`, `fail_interval=`, and `unlock_time=` together.

---

## 8.7 `pam_unix`'s `account` Role, Revisited

Chapter 6 covered `pam_unix` primarily from the `auth` side, with its `account`-role behaviour noted only briefly — that it reads the shadow aging fields and can return `PAM_ACCT_EXPIRED` or `PAM_NEW_AUTHTOK_REQD`. Worth a fuller look here, in this chapter specifically, since it is genuinely an `account`-stack module in this role and belongs alongside `pam_access`, `pam_time`, and `pam_faillock` conceptually even though its manual page treats all four of its group-roles as one undifferentiated module.

`pam_unix` in `account` checks three distinct conditions from the shadow entry, and it is worth being able to name all three separately rather than treating "account stuff" as one lump:

**Account expiry** — the shadow `expire` field, an absolute date after which the account cannot be used regardless of password state. This is the field `chage -E` sets, and it is a hard boundary distinct from password aging — an account can have a perfectly current, unexpired password and still be refused here if the account itself has passed its expiry date, which is the correct behaviour for a temporary contractor account provisioned with a known end date.

**Password expiry (hard)** — the combination of `max` (maximum password age) and `inactive` (grace period after expiry before the account is disabled entirely). Once both have elapsed with no password change, this behaves similarly to account expiry — a hard refusal — but it is a different field and represents a different administrative decision, a policy about credential freshness rather than an account's intended lifetime.

**Password expiry (soft)** — `max` alone, elapsed but still within the `inactive` grace window. This is the `PAM_NEW_AUTHTOK_REQD` case from Chapter 3's forced-change trace, revisited fully in Chapter 7 — not a refusal, but a requirement that the `password` stack run before the login can proceed.

```
$ chage -l parsa
Last password change                                   : Jan 15, 2026
Password expires                                        : Apr 15, 2026
Password inactive                                        : May 15, 2026
Account expires                                          : never
```

Reading this output against the three conditions above: this account's password will trigger the soft-expiry `password`-stack requirement on April 15, will become a hard refusal if no change happens by May 15, and has no account-level expiry at all — a fairly typical shape for a regular employee account with password rotation policy but no fixed end date, contrasted with the `emergency`-style or contractor accounts from 8.2's worked ruleset, which would more commonly have an actual `Account expires` date set.

The reason this belongs in this chapter's frame rather than only Chapter 6's or Chapter 7's: **`pam_unix`'s `account`-role checks are not bypassed by key-based authentication**, exactly like every other module in this chapter and for the identical underlying reason established in 8.5 — `account` is not skippable. An expired contractor account cannot be revived by switching to key-based SSH any more than a `pam_access`-restricted one can, and it is worth explicitly confirming this is true on your own systems rather than assumed, using the same testing discipline this chapter has applied throughout:

```
$ chage -E $(date -d yesterday +%Y-%m-%d) contractor-test-account
$ ssh -i contractor-test-key contractor-test-account@host
```

The key-based attempt should be refused at the `account` stage, with `pam_unix`'s `(service:account)` annotation in the logs, exactly matching the pattern this chapter's opening scenario showed failing to hold for a `pam_faillock` configuration that lived only in `auth`.

---

## 8.8 The `account`-Stack Modules, Side by Side

Consistent with the comparison table Chapter 6 built for its own small structural modules, here is one gathering every `account`-capable module this chapter and Chapter 6 together have covered, since reading them side by side clarifies which question each one is actually answering.

| Module | Checks | Configuration | Bypassed by SSH keys? |
|---|---|---|---|
| `pam_unix` (account role) | Account and password expiry | `/etc/shadow` via `chage` | No |
| `pam_access` | Origin (host, network, tty) | `/etc/security/access.conf` | No |
| `pam_time` | Time of day, day of week | `/etc/security/time.conf` | No |
| `pam_nologin` | System-wide maintenance flag | Presence of `/etc/nologin` | No |
| `pam_faillock` | Cross-attempt failure lockout | `/etc/security/faillock.conf` | No, **if** the `account`-stack line is present |
| `pam_succeed_if` | Arbitrary attribute condition | Inline expression | No |
| `pam_listfile` | Membership in a maintained file | Arbitrary file | No |

The rightmost column is, deliberately, "No" for every row — which is precisely 8.5's rule stated as a table rather than prose: everything in this chapter, correctly placed in `account`, shares the one property that makes `account` the right group for access restriction in the first place. The single caveat, on `pam_faillock`'s row, is not a property of the module but a warning about incomplete configuration — exactly this chapter's opening scenario, and exactly why 8.11's hardening checklist puts the `account`-stack line's presence as its own separate, explicit item rather than assuming it follows automatically from the `auth`-stack pair being configured correctly.

---

## 8.9 Reconstructing the Full RHEL Stack

Chapter 4's section 4.11 decoded a real, generated `password-auth` from a RHEL-family system with lockout enabled, focused on the jump arithmetic. Return to it now with this chapter's `pam_faillock` treatment in hand, reading the same nine lines specifically for what each `pam_faillock` invocation contributes:

```
1  auth  required                              pam_env.so
2  auth  required                              pam_faillock.so preauth silent deny=5 unlock_time=900
3  auth  [default=1 ignore=ignore success=ok]  pam_succeed_if.so uid >= 1000 quiet
4  auth  [default=1 ignore=ignore success=ok]  pam_localuser.so
5  auth  sufficient                            pam_unix.so nullok
6  auth  requisite                             pam_succeed_if.so uid >= 1000 quiet_success
7  auth  sufficient                            pam_sss.so forward_pass
8  auth  required                              pam_faillock.so authfail deny=5 unlock_time=900
9  auth  required                              pam_deny.so
```

Line 2 is this chapter's `preauth` role, running before either candidate credential mechanism (local `pam_unix` on line 5, or directory `pam_sss` on line 7) is attempted — a single lockout check covering both paths, which is exactly right, since an account should not be gettable-around by trying whichever credential mechanism happens not to be currently rate-limiting it. Line 8 is `authfail`, positioned after both mechanisms have had their chance and reached only if neither succeeded, per lines 5 and 7 both being `sufficient` — precisely the ordering requirement from 8.6, now visible in a real generated stack rather than only in the simplified illustration.

Note what is absent from this specific nine-line fragment: an `authsucc` invocation, and the `account`-stack `pam_faillock` line. Both exist elsewhere in the fuller generated file this fragment was drawn from — `authselect`-generated stacks place them according to the profile's own convention, and confirming their presence in the complete file, rather than assuming this `auth`-stack fragment is the whole story, is worth doing explicitly:

```
$ grep -n faillock /etc/pam.d/password-auth /etc/pam.d/system-auth 2>/dev/null
```

A `preauth` and `authfail` with no corresponding `account`-stack line is an incomplete implementation of the mechanism — lockout would still work for the specific paths in this `auth` stack, but any authentication route that reaches this service's `account` stack without traversing this exact `auth` stack first would not be checked against the lock at all, which per 8.5's `pam_listfile` discussion is precisely the kind of gap that matters for SSH key-based authentication specifically.

---

## 8.10 Assembling a Complete `account` Stack

Bringing every module in this chapter together, consistent with the assembly exercises in Chapters 6 and 7:

```
account  required  pam_faillock.so
account  required  pam_nologin.so
account  required  pam_access.so
account  required  pam_time.so
account  required  pam_unix.so
```

Order here matters less than in the `auth` stacks Chapter 4 spent so much time on, precisely because every line is `required` and none is `sufficient` or a numeric jump — per Chapter 4's algorithm, a stack composed entirely of `required` lines produces the same final result regardless of order, since every failure is recorded regardless of position and no line can rescue a prior failure. This is worth stating as a general principle: **an `account` stack, more often than an `auth` stack, can reasonably be "all `required`, order for readability,"** because the group's purpose — a conjunction of independent conditions that must all hold — maps naturally onto that flag rather than needing the routing and fallback logic that makes `auth` stacks reach for `sufficient` and numeric jumps so often.

The one exception worth flagging: `pam_faillock` first is a convention worth keeping regardless of the order-independence argument above, since it is the cheapest check (a local counter lookup, no file parsing or network round-trip) and there is a minor efficiency argument, plus a security-adjacent one, for failing fast on an already-locked account before spending any effort evaluating origin or time rules that are irrelevant to an account that will be denied regardless.

---

## 8.11 A Hardening Checklist for the `account` Stack

Consistent with Chapter 7's format.

**1. Does every restriction-bearing module sit in `account` rather than `auth`**, per 8.5's rule about key-based authentication bypass? Audit specifically for `pam_access`, `pam_time`, `pam_succeed_if`, and `pam_listfile` lines currently in `auth` that are functioning as access restrictions rather than routing logic.

**2. Does every list-based or rule-based module in this chapter have an explicit, tested catch-all?** Per 8.2's `pam_access` and 8.3's `pam_time` discussions — both fail permissive by default in the absence of a matching rule, and both need a deliberate final rule to close that gap.

**3. Is `pam_faillock`'s `authfail` line actually reachable on a failure path**, per 8.6 and Chapter 4's exercise 14? Test directly rather than inspecting the control flags alone.

**4. Is the `account`-stack `pam_faillock` line present**, not only the two `auth`-stack invocations, per 8.9's gap analysis?

**5. Is `even_deny_root` (or the `pam_access`/`pam_time` equivalent scope decisions) set deliberately, one way or the other, with the choice documented?**

**6. Is `/etc/nologin` cleanup built into whatever process sets it**, per 8.4, rather than relying on manual removal?

**7. Has the actual violation case been tested for every module in this stack** — a login attempted from a disallowed origin, at a disallowed time, on a locked account — rather than only the legitimate-use case, per 8.1's framing for this entire chapter?

**8. Has `pam_access`'s ruleset been checked specifically for the ordering mistake in 8.2** — a broad allow appearing before a narrower deny intended as an exception, which the first-match rule silently defeats?

**9. Does account expiry, per 8.7, actually get exercised by a real test rather than only inspected in `chage -l` output** — a genuinely expired throwaway account, attempted against both a password and a key-based login path, confirming the refusal in both cases per the SSH-key-bypass concern this chapter has returned to repeatedly?

---

## 8.12 Verification

Test machine, snapshot, second root shell. Several of these exercises deliberately lock out or deny a test account — confirm you are working against a throwaway account and not your own primary access before running them, and keep the second root shell genuinely uninvolved in any of the test paths.

**1. Confirm `pam_access`'s missing-catch-all failure mode.**

Build a ruleset with only `+` rules and no final `-  ALL : ALL`. Attempt a login from an origin matching none of the explicit rules and confirm it succeeds despite not being explicitly permitted — the permissive-default behaviour described in 8.2, demonstrated rather than taken on faith.

**2. Confirm `pam_time`'s timezone sensitivity.**

Write a rule restricting a test account to a narrow time window, then compare the server's actual configured timezone against the timezone you assumed when writing the rule. Deliberately introduce a mismatch and confirm the enforced window is not the one you intended.

**3. Test `pam_nologin` including root's exemption.**

Create `/etc/nologin`, confirm a non-root test account is blocked and shown the file's content, and confirm root is unaffected. Remove the file and confirm normal access returns immediately.

**4. Build the three-line `pam_faillock` idiom from scratch and break it deliberately.**

Following 8.6, build the four-line `auth`-stack portion plus the two `account`-stack lines. Fail a login five times against `deny=5` and confirm lockout with `faillock --user`. Then change line 2 (the actual credential check) from its bracketed jump to plain `requisite`, reset the counter, and fail five times again — confirm the counter does not increment, reproducing Chapter 4's exercise 14 with the full mechanism now built out rather than abstractly described.

**5. Confirm the `account`-stack `pam_faillock` line's specific role.**

With the `auth`-stack portion from exercise 4 working correctly and an account currently locked, attempt authentication through a path that would otherwise succeed via `auth` bypass — a configured SSH key, for instance — and confirm the `account`-stack line still denies it, per 8.5's and 8.9's point about this being the specific gap an incomplete implementation leaves open.

**6. Run the RHEL reconstruction from 8.9 against a real generated stack**, if you have access to a RHEL-family system, confirming both the `authsucc` invocation and the `account`-stack line are present in the complete file rather than only the `auth`-stack fragment.

**7. Complete the hardening checklist from 8.11 against a real `account` stack you administer**, testing the violation case for each item per 8.1's framing rather than only confirming legitimate use continues to function.

**8. Deliberately trigger the denial-of-service angle from 8.6's failure-modes discussion.**

Against a throwaway account with a known username, fail authentication `deny=` times using an incorrect password, without ever attempting the correct one, and confirm the legitimate credential is now also refused. This is not a bug to fix — it is 8.6's point, made concrete, about the inherent tension in any lockout mechanism.

**9. Distinguish administrator-set from system-set maintenance blocking, per 8.4's systemd-adjacent note.**

On a systemd-managed test machine, watch `/run/nologin` around a normal reboot, confirming it appears and disappears automatically as part of the shutdown and boot sequence with no administrator action. Then separately create `/etc/nologin` by hand outside any reboot and confirm the two paths behave identically from `pam_nologin`'s perspective despite one being system-managed and the other administrator-managed — the distinction matters for interpreting logs, not for the module's actual enforcement behaviour, which treats both paths the same way.

**10. Complete the three new hardening-checklist items from 8.11 against a real system**, specifically the `pam_access` ordering check and the account-expiry SSH-key test, both of which exercise the SSH-key-bypass theme this chapter has returned to in nearly every section — by this point in the chapter, that repetition should feel less like restatement and more like the same underlying fact surfacing in a new module each time, which is the intended effect.

---

## Where This Goes Next

You now have the complete `account`-group reference: origin, time, system-wide maintenance blocking, and — the module this chapter and every one before it has been building toward — genuine cross-attempt lockout via `pam_faillock`, assembled from the mechanical pieces Chapter 4 and Chapter 5 built in isolation. The rule from 8.5 is worth carrying forward above all the others in this chapter: any restriction that must hold regardless of authentication method belongs in `account`, never only in `auth`, because `auth` is exactly the stack a sufficiently capable authentication method can skip. This chapter's opening scenario is the concrete cost of forgetting that rule, and 8.7's revisiting of `pam_unix` from Chapter 6 exists specifically to show the same principle holding for a module you have already met, not only for the ones introduced fresh in this chapter.

Chapter 9 moves to the `session` group — resource limits, environment, the logind session lifecycle Chapter 3 introduced abstractly, and the modules that build and tear down everything around a login once identity and permission have both been settled. Where this chapter has been about deciding *whether*, Chapter 9 is about constructing *what*. One structural connection worth anticipating: `pam_faillock`'s state, examined in full in this chapter, is genuinely persistent across separate login attempts in a way most modules in this series are not; Chapter 9's `session` modules are, by contrast, almost entirely about state that exists only for the duration of one login and is deliberately discarded afterward — the two chapters sit at opposite ends of a spectrum from "remembers everything, forever, across every attempt" to "remembers nothing beyond the current session's own lifetime," and it is worth noticing which end of that spectrum any given module you encounter sits closer to, since it is a genuinely useful heuristic for guessing a module's likely group before checking its manual page.

---

## Further Reading for This Chapter

- `man 8 pam_access` and `man 5 access.conf`
- `man 8 pam_time` and `man 5 time.conf`
- `man 8 pam_nologin`
- `man 8 pam_faillock` and `man 5 faillock.conf` — read in full at least twice, once for the module's own arguments and once specifically tracing the three-role invocation pattern this chapter assembled
- `man 8 faillock`, the administration command, distinct from the module's own manual page
- `man 8 pam_succeed_if`, `man 8 pam_listfile`, revisited from Chapter 6 specifically for the `account`-role distinction in 8.5
- `man 8 pam_unix`, revisited a second time from this chapter's 8.7, specifically for its account-role return values and the three distinct expiry conditions distinguished there
- `man 8 chage`, for setting and inspecting the aging fields 8.7 reads
- `man 8 systemd-user-sessions`, for the `/run/nologin` automation referenced in 8.4
- The Linux-PAM source, `modules/pam_faillock/`, for anyone who worked through Chapter 5 and wants to see the real cross-invocation state mechanism the miniature version there was modelled on
- Your own distribution's generated `account`-stack lines, decoded once more using 8.9's technique, the same closing exercise the two preceding chapters have each recommended for their own module sets
