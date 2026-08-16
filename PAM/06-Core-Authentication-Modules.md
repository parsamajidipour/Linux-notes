# 06 — Core Authentication Modules

Chapters 1 through 5 built the machinery: the configuration model, the four groups, the evaluation algorithm, the API underneath it all. This chapter and the three after it are the payoff — a reference to the modules you will actually meet, organised the way you will actually need them.

This one covers the modules that decide, or help decide, whether a credential is correct. `pam_unix` first and at length, because it is the module you will meet on every system you touch and because understanding it thoroughly makes every other module in this chapter easier to read. Then the small, sharp single-purpose modules that structure a stack rather than checking a password: `pam_deny`, `pam_permit`, `pam_rootok`, `pam_wheel`, `pam_securetty`, `pam_faildelay`, `pam_listfile`, `pam_localuser`.

Every module gets the same treatment, on purpose: what it does, which entry points it implements, its arguments, its return values mapped against Chapter 4's algorithm, what it interacts with, and how it fails. That consistency is what makes this chapter and the three after it work as reference material you reopen rather than prose you read once.

### A short scenario, to set the frame

Before the reference material, a scenario worth holding in mind while reading it, because it ties several of this chapter's modules together the way they actually appear on a running system.

A new hire is provisioned on a Debian server. Their account is created by a script that, due to a bug, leaves the shadow password field empty rather than setting a temporary hash. Nobody notices, because the account works — anyone can log into it with any password, or none, since `common-auth` on this system, like nearly every Debian default, includes `nullok`. Three weeks later, a security review runs `awk -F: '($2=="") {print $1}' /etc/shadow`, from this chapter's own verification section, and finds the account. Nothing in `/etc/pam.d/` was misconfigured. `pam_unix` did exactly what its arguments told it to do. The distribution's default stack did exactly what it has always done. And a production account had no meaningful password requirement for three weeks, invisibly, because two individually defensible defaults — a permissive provisioning script and a permissive `nullok` argument — combined in a way neither one alone would have caused.

This is the shape of nearly every real incident involving the modules in this chapter: not a single dramatic misconfiguration, but two or three individually reasonable defaults meeting in a way nobody specifically decided. Keep it in mind through the module-by-module material that follows, and revisit it after 6.1's `nullok` discussion specifically.

---

## 6.1 `pam_unix`

### What it does

Verifies a password against the traditional Unix credential store — `/etc/passwd` and `/etc/shadow` — and, in the other three groups, manages the aging fields and performs the actual hash update when a password changes.

It is the module most systems still authenticate against by default, directly or as a fallback behind a directory service, and it is the module every other authentication module in this series will be compared to.

### Which groups it serves

All four, as confirmed in Chapter 3:

```
$ objdump -T /usr/lib64/security/pam_unix.so | grep -o 'pam_sm_[a-z_]*' | sort
pam_sm_acct_mgmt
pam_sm_authenticate
pam_sm_chauthtok
pam_sm_close_session
pam_sm_open_session
pam_sm_setcred
```

### How it finds the hash

`pam_sm_authenticate()` calls `pam_get_user()` to determine the username, then looks it up. If the calling process can read `/etc/shadow` directly — because it is running as root, or with appropriate group membership — it reads the hash straight from there. If it cannot, it falls back to the setgid helper described in Chapter 1 and exercised at the module level in Chapter 5:

```
$ ls -l /usr/sbin/unix_chkpwd
-rwxr-sr-x 1 root shadow 35112 /usr/sbin/unix_chkpwd
```

The candidate password is passed to the helper, which performs the comparison and returns success or failure without ever handing the hash itself back to the caller. This is the privilege-separation pattern from Chapter 5's `pam_sm_authenticate` sketch, and it is worth confirming on your own system with `strace` when the opportunity arises:

```
$ strace -f -e trace=execve pamtester login "$USER" authenticate 2>&1 | grep chkpwd
```

### The hash format

Covered in Chapter 1's table of modular crypt prefixes. `pam_unix` does not choose the algorithm at authentication time; it reads whatever prefix is stored and dispatches to the matching implementation in libcrypt. This means a system can have users hashed with several different algorithms simultaneously, most commonly during a migration, and `pam_unix` handles all of them transparently at the `auth` stage. It is only at the `password` stage, when a new hash is written, that the configured algorithm argument takes effect.

### Arguments

The arguments split cleanly along the group boundaries established in Chapter 3, and organising them that way is more useful than the alphabetical listing most manual pages use.

**Relevant to `auth`:**

`nullok` — accept an empty stored password as a match for an empty typed password. Without it, an account with an empty hash field cannot authenticate through this module at all, regardless of what the user types. Covered at length in 6.1's hardening discussion below.

`try_first_pass` — if an earlier module in the same stack collected a password and stored it in `PAM_AUTHTOK`, use that rather than prompting again. Prompt only if nothing was stored. This is the mechanism built explicitly in Chapter 5.

`use_first_pass` — like `try_first_pass`, but fail rather than prompt if nothing was stored.

`nodelay` — skip the module's own built-in delay on failure. Rarely used; `pam_faildelay`, covered later in this chapter, is the more common and more controllable way to manage this.

`broken_shadow` — do not treat an unreadable shadow entry as a hard authentication error; useful on systems where some accounts are intentionally missing shadow entries, and worth being suspicious of on a hardened system, since it can mask a permissions problem that should be visible.

**Relevant to `account`:**

Most of the account-side behaviour has no dedicated argument; it reads the aging fields directly. `broken_shadow` also softens account-stage errors for the same class of missing-entry situations.

**Relevant to `password`:**

`use_authtok` — do not prompt for a new password; take it from `PAM_AUTHTOK`, which an earlier module (typically `pam_pwquality`) has already validated and stored. This is the chaining mechanism from Chapter 3's forced-change trace, restated here as the module argument that implements it.

`sha256`, `sha512`, `yescrypt`, `md5`, `bigcrypt`, `blowfish` (support varies by distribution and version) — select the algorithm used when writing a new hash. Absent any of these, the module falls back to the distribution's compiled-in default, which per Chapter 1's timeline is `$y$` (yescrypt) on current Debian and Ubuntu and `$6$` (SHA-512) on the RHEL family, though this has changed over the series' history and is worth confirming rather than assuming:

```
# grep -i crypt /etc/login.defs 2>/dev/null
# authselect current 2>/dev/null   # RHEL: hashing is sometimes selected here instead
```

`rounds=N` — the cost parameter for algorithms that support one (SHA-256, SHA-512; yescrypt uses a different cost mechanism controlled by its own parameters and largely not tunable through this argument). Higher is slower to compute and slower to attack; there is no universally correct value, and Chapter 11's hardening checklist returns to this.

`remember=N` — keep the last N hashes to prevent immediate password reuse. On current Linux-PAM this functionality has been split out to a dedicated module, `pam_pwhistory`, covered in Chapter 7; `pam_unix`'s own `remember=` continues to work on many systems for backward compatibility but new configuration should prefer the dedicated module.

`shadow` — historically selected shadow-file operation over legacy `/etc/passwd`-only operation; on essentially every current system this is the only mode available and the argument is a no-op retained for compatibility. You will still see it in nearly every distribution's default stack, out of habit more than necessity.

### Return values

| Value | When |
|---|---|
| `PAM_SUCCESS` | Hash matched |
| `PAM_AUTH_ERR` | Hash did not match |
| `PAM_USER_UNKNOWN` | No such account |
| `PAM_AUTHINFO_UNAVAIL` | Could not read the shadow entry and the helper failed or was unavailable |
| `PAM_CRED_INSUFFICIENT` | Caller lacks the privilege to check this account at all |
| `PAM_NEW_AUTHTOK_REQD` | (from `pam_sm_acct_mgmt`) password aged out |
| `PAM_ACCT_EXPIRED` | (from `pam_sm_acct_mgmt`) account expiry date passed |
| `PAM_AUTHTOK_ERR` | (from `pam_sm_chauthtok`) could not write the new hash |

Note `PAM_AUTHINFO_UNAVAIL` in the list. It is genuinely produced by this module, not only by network-backed ones, in the specific case where shadow is unreadable and the helper cannot be invoked or fails for a reason unrelated to the password itself — a distinction worth remembering when you reach for the fallback idiom from Chapter 4's trace 5, since it is not exclusively a directory-service pattern.

### The `nullok` question

Worth its own subsection because it is the single most consequential argument this module takes, and it is routinely present in distribution defaults for reasons that have nothing to do with your production posture.

An account with an empty password field in shadow is not the same as an account with no password at all — it typically means the account requires no password, if `nullok` is honoured, or is locked, if the field instead contains `!` or `*` rather than being genuinely empty. Distribution default stacks ship with `nullok` present, largely because the historical default behaviour without it — treating a truly empty field as an unconditional authentication failure regardless of what is typed — was considered surprising for certain administrative and recovery scenarios.

On a production system, this argument should almost never be present, and its absence should be verified rather than assumed:

```
$ grep -n pam_unix /etc/pam.d/common-auth /etc/pam.d/system-auth /etc/pam.d/password-auth 2>/dev/null
```

If it is there, the practical question is whether any account on the system actually has an empty shadow field, since the argument is inert without one:

```
# awk -F: '($2 == "") {print $1}' /etc/shadow
```

An empty result means the argument is currently harmless but still a live risk the moment any account's password field is cleared by mistake — during a botched account provisioning script, for instance. Chapter 11's hardening checklist treats removing `nullok` from production stacks as close to a default recommendation, with the caveat, consistent with this whole series, of testing the change against your specific stack before deploying it broadly.

### A worked hardening pass

Bringing several of this section's threads together, here is what tightening `pam_unix`'s `auth` line on a production system actually looks like in practice, starting from a typical distribution default and ending at a defensible one.

Starting point, Debian default:

```
auth  [success=1 default=ignore]  pam_unix.so nullok
```

Step one, per the `nullok` discussion above: confirm no account currently depends on an empty shadow field, then remove it.

```
auth  [success=1 default=ignore]  pam_unix.so
```

Step two: decide whether `try_first_pass` belongs here. On a system where `pam_unix` is the only or first `auth` module, it has nothing to reuse and the argument is inert; on a system with a directory service or MFA module ahead of it in the stack, adding `try_first_pass` avoids a redundant second prompt for users who already typed a password once.

```
auth  [success=1 default=ignore]  pam_unix.so try_first_pass
```

Step three, separately, in the `password` stack: confirm the hashing algorithm matches organisational policy rather than trusting the distribution default silently, and set `rounds=` deliberately if the algorithm supports it and the default cost is not one you have evaluated:

```
password  required  pam_unix.so  use_authtok sha512 rounds=100000 shadow
```

None of these three steps involves anything not already covered in this section. The exercise is assembling them into a deliberate, reviewed change rather than leaving the distribution default in place indefinitely on the assumption that "default" means "adequate" — a assumption this chapter's opening scenario showed is not always safe.



With `pam_faillock` in the `auth` and `account` stacks — `pam_unix`'s `PAM_AUTH_ERR` is what a correctly placed `pam_faillock` `authfail` line is reacting to, per Chapter 4's discussion of the ordering dependency.

With NSS, indirectly and importantly: `pam_unix` reads shadow directly rather than going through the NSS `shadow` database lookup path for the hash comparison itself, but `pam_get_user()` and account resolution more broadly interact with NSS's `passwd` database. Chapter 10 draws this distinction precisely; for now, the practical consequence is that a user who does not resolve via `getent passwd` will not be found by `pam_unix` either, and that failure will look like an authentication problem when it is an NSS problem.

### Failure modes

**Wrong password.** `PAM_AUTH_ERR`, logged plainly, the ordinary case.

**Shadow unreadable and helper missing or broken.** `PAM_AUTHINFO_UNAVAIL`, which on a `required` line behaves as any other failure per Chapter 4, but which should prompt you to check the helper binary and its permissions rather than assume the password itself is wrong.

**Account genuinely has no shadow entry at all** (present in `passwd` but absent from `shadow`) — behaves differently depending on `broken_shadow` and distribution specifics; worth testing explicitly rather than assuming, since this is exactly the kind of edge case where documentation across distributions has historically disagreed.

**`nullok` present, field genuinely empty, unintended.** Silent authentication bypass for that one account. Covered above.

### Verification

```
$ pamtester login "$USER" authenticate
$ awk -F: '($2 == "") {print $1}' /etc/shadow
$ grep -n pam_unix /etc/pam.d/common-auth 2>/dev/null /etc/pam.d/system-auth 2>/dev/null
$ man 8 pam_unix
```

---

## 6.2 `pam_deny`

### What it does

Unconditionally fails, in every group it implements. Nothing to configure, nothing to check.

### Which groups it serves

All four.

```
$ objdump -T /usr/lib64/security/pam_deny.so | grep -o 'pam_sm_[a-z_]*' | sort
pam_sm_acct_mgmt
pam_sm_authenticate
pam_sm_chauthtok
pam_sm_close_session
pam_sm_open_session
pam_sm_setcred
```

### Purpose

Structural, not diagnostic. Its entire role is to be the stack terminator in the `sufficient`/`requisite` idioms covered exhaustively in Chapter 4: something that guarantees a definite failure if reached, so that a chain of `sufficient` alternatives has a hard floor rather than falling through to the framework's own must-fail default silently. You have seen it in every worked trace in Chapter 4 and in the RHEL `password-auth` breakdown in that chapter.

### Arguments

None.

### Return values

Always the failure value appropriate to whichever entry point was called — `PAM_AUTH_ERR` from `pam_sm_authenticate`, `PAM_PERM_DENIED` from several others, consistently a failure in every case.

### Interactions

None beyond its position in the stack, which is the entire point. `requisite pam_deny.so` versus `required pam_deny.so` matters per Chapter 4's keyword distinction — `requisite` stops immediately, `required` continues but the outcome is the same either way since nothing later can override a recorded failure.

### Failure modes

None in the ordinary sense — it cannot fail to fail. The only "failure mode" worth naming is a configuration one: reaching `pam_deny.so` when you did not intend to, which is a stack-logic bug rather than a module bug, and is exactly what several of Chapter 4's traces walked through.

---

## 6.3 `pam_permit`

### What it does

Unconditionally succeeds, in every group it implements. The mirror image of `pam_deny`.

### Which groups it serves

All four.

### Purpose

The other half of the terminator pattern: primes a stack with a definite success when nothing else has, which is precisely the role it plays at the bottom of Debian's `common-auth` in every trace from Chapter 4. Its presence there is not decoration — remove it, per Chapter 4's trace 1, and the file returns the framework's must-fail default even on a correct password.

### Arguments

None.

### Return values

Always success.

### Interactions

Same as `pam_deny`: purely positional, and its meaning is entirely a function of where it sits and what control flag governs it.

### Failure modes

The dangerous one is not a fault in the module — it is placing it somewhere it grants access unintentionally. `auth sufficient pam_permit.so` placed anywhere reachable without a preceding, effective check is an unconditional bypass. Grepping for it, per Chapter 1's attack-surface discussion, belongs in any configuration audit:

```
$ grep -rn 'pam_permit' /etc/pam.d/ | grep -v '^\s*#'
```

Every hit needs an explanation. The two legitimate ones you will usually find are the Debian terminator pattern and a deliberately permissive `other` file per Chapter 2 — anything else deserves scrutiny.

---

## 6.4 `pam_rootok`

### What it does

Succeeds if the calling process's real UID is 0, fails otherwise. That is the entire module.

### Which groups it serves

```
$ objdump -T /usr/lib64/security/pam_rootok.so | grep -o 'pam_sm_[a-z_]*'
pam_sm_authenticate
```

One entry point.

### Purpose

Lets root skip authentication for operations that would otherwise prompt — changing another user's password with `passwd`, or `su`-ing to any account without being asked for that account's password. It is the module behind the specific, well-known behaviour that root can `su` to anyone with no prompt, traced in Chapter 1's first walkthrough of `su`.

### Arguments

None documented in current versions; historically none of consequence.

### Return values

`PAM_SUCCESS` if real UID is 0; `PAM_AUTH_ERR` (or equivalent) otherwise, allowing the stack to continue to whatever module actually checks a credential for non-root callers.

### Interactions

Placement is everything, and this is the module Chapter 4 used to introduce the `sufficient` keyword concretely, in the `su` trace. It is placed first and marked `sufficient` so that a root caller short-circuits the rest of the `auth` stack; anyone else falls through to `pam_unix` or whatever follows.

### Failure modes

The near-universal one: someone changes `sufficient pam_rootok.so` to `required`, intending to tighten something, and instead breaks root's ability to `su` without a password, because now `pam_rootok`'s failure for a non-root caller is recorded and nothing later can override it per Chapter 4's algorithm. This is a real, documented category of self-inflicted lockout distinct from the jump-arithmetic failures in Chapter 4, arising purely from misunderstanding what the keyword does.

The opposite mistake — placing it somewhere it should not be, such as a network-facing service where "already root" should never be a meaningful authentication bypass — is rarer but worth checking for on any internet-facing service:

```
$ grep -l pam_rootok /etc/pam.d/*
```

Every result should be a local privilege-transition utility (`su`, `passwd`, `chsh`, `chfn`) and never a network service.

---

## 6.5 `pam_wheel`

### What it does

Restricts access based on membership in a designated group, conventionally `wheel`, though the group name is configurable.

### Which groups it serves

`auth` only.

### Purpose

The traditional Unix mechanism for restricting `su` to a specific set of trusted users, independent of and complementary to `sudo`. It answers a narrower question than `sudo` does: not "can this user run this specific command as root" but "can this user attempt to become root at all via `su`."

### Arguments

`group=name` — which group to check; defaults to `wheel` if omitted, though the compiled-in default group can vary by distribution and is worth confirming rather than assuming:

```
$ man 8 pam_wheel | grep -A2 'group='
```

`deny` — invert the logic: deny members of the group rather than requiring membership. Rare, and worth double-checking with `pamtester` after configuring, since inverted logic is exactly the kind of thing that is easy to get backwards under pressure.

`use_uid` — check the real UID's group membership rather than the name being authenticated to, relevant to some `su` invocation patterns.

`trust` — a variant behaviour where membership alone is sufficient to succeed without further prompting, rather than merely being a precondition for being prompted at all. Read the manual page carefully before using this; the difference between "must be in the group to be asked for a password" and "being in the group is itself sufficient" is a meaningful security distinction and easy to configure backwards.

### Return values

`PAM_SUCCESS` if the membership condition (or its inverse, under `deny`) holds; `PAM_AUTH_ERR` or `PAM_PERM_DENIED` otherwise, plus `PAM_IGNORE` in some situations where the module determines it has nothing useful to say, per its manual page.

### Interactions

Sits in `/etc/pam.d/su`, commented out by default on most distributions, as seen in Chapter 1's example file. Complementary to, and independent of, `sudo`'s own group-based authorization in `/etc/sudoers`. It is worth being explicit with anyone you are training that `pam_wheel` and a `sudoers` `%wheel` entry are two entirely separate mechanisms, checked by two entirely separate subsystems, that happen to conventionally reference the same group name — a change to one does not affect the other.

### Failure modes

Uncommenting it without first confirming who is actually in the target group is the standard mistake, and it is entirely self-inflicted lockout territory:

```
$ getent group wheel
```

Confirm your own account is listed before enabling enforcement, on a test machine, with a second root shell open, per the lab discipline that has applied since Chapter 2.

### A worked example: restricting `su` without touching `sudo`

A common request: allow only a specific group to use `su` at all, while leaving `sudo` policy in `/etc/sudoers` completely untouched, since the two are independent per this section's interactions note.

```
# groupadd suusers
# usermod -aG suusers parsa
```

```
auth  sufficient  pam_rootok.so
auth  required    pam_wheel.so  group=suusers
auth  [success=1 default=ignore]  pam_unix.so
auth  requisite   pam_deny.so
auth  required    pam_permit.so
```

Trace it, briefly, using Chapter 4's algorithm: root's `su` still short-circuits everything via the first line's `sufficient`. A non-root member of `suusers` passes the second line and proceeds to the normal password check. A non-root, non-member fails the second line under `required`, the failure is recorded, and — because `required` continues rather than terminating — evaluation proceeds through the rest of the stack, but per Chapter 4's rule that a recorded failure cannot be overridden, nothing later can rescue it, including a subsequently correct password. This is worth confirming with `pamtester` rather than taking on faith, since it is exactly the kind of behaviour that is easy to state confidently and get backwards under pressure.

---

## 6.6 `pam_securetty`

### What it does

Restricts root logins to a list of terminals considered "secure," historically read from `/etc/securetty`.

### Which groups it serves

`auth` only.

### Purpose

A defence from an era when physical console access and remote access were both commonly mediated through the same `login` program on the same set of terminal device files, and the concern was preventing root from logging in directly over a network-attached terminal line, forcing an unprivileged login followed by `su` instead — which at least produces an audit trail linking the action to a named individual.

### Arguments

Historically minimal; current versions may support a `tty_group` variant and other minor options, worth checking against your installed version's manual page rather than assumed from memory of an older release.

### Current relevance

Worth being direct about: this module's practical relevance on a modern Linux deployment is much reduced from its historical position, and many current distributions no longer include `/etc/securetty` in a default install, no longer enforce it by default for SSH (where `PermitRootLogin` in `sshd_config` is now the primary, and more granular, control), and in some cases have removed the module from the default stack entirely. It has not disappeared from every system, and where it is present it still does what it always did, but it should not be assumed present or assumed to be doing meaningful work without checking:

```
$ grep -l pam_securetty /etc/pam.d/*
$ cat /etc/securetty 2>/dev/null
```

If both come back empty or absent on a system where you had assumed console-based root-login restriction was in force, the actual control you are relying on is elsewhere — most likely `sshd_config`'s `PermitRootLogin`, or simply that `root` has no valid password and only key-based or `su`-mediated access exists.

The broader lesson, applicable well beyond this one module: a control's *historical* presence in a default stack is not evidence of its *current* effectiveness, and distributions do periodically retire or de-emphasise mechanisms as the surrounding threat model and typical deployment shape shift — physical console access on a cloud instance means something different than it did on a machine sitting in a locked room, and `pam_securetty`'s entire design assumes the latter. Treat any control inherited from an older hardening guide or an older colleague's institutional knowledge the way this section treated `pam_securetty`: verify it is actually present and actually doing something on the specific system in front of you, rather than trusting the name of the control alone.

### Return values

`PAM_SUCCESS` if the terminal is listed (or if the module determines the check does not apply, such as for a non-root user); `PAM_AUTH_ERR` for a root login attempt on an unlisted terminal.

### Interactions

None beyond its place in the `auth` stack.

### Failure modes

Believing it is enforcing a restriction it is not, per the current-relevance note above. This belongs on the same audit checklist as the `other` fallback check from Chapter 2 and the `nullok` check earlier in this chapter — a stated security assumption that needs to be verified against the actual running configuration rather than trusted from institutional memory.

---

## 6.7 `pam_faildelay`

### What it does

Sets the delay imposed after a failed authentication attempt, before the failure message is returned to the caller.

### Which groups it serves

`auth` only.

### Purpose

A basic throttle against rapid-fire password guessing at the single-attempt level, distinct from and complementary to the attempt-counting and lockout behaviour of `pam_faillock`, covered in Chapter 8. Where `pam_faillock` answers "how many failures before this account is locked," `pam_faildelay` answers "how long does each individual failure take to report," which matters for the pure computational cost of brute-forcing even before any lockout threshold is reached.

### Arguments

`delay=N` — the delay in microseconds. A typical distribution default is in the range of two to three seconds, expressed as a number like `2000000` or `3000000`.

### Return values

Always `PAM_SUCCESS` — the module does not make an authentication decision; it only sets a timing parameter that affects how the framework's own final response to the application is paced.

### Interactions

Its effect is on the overall timing of the `auth` stack's response, which connects back to the timing-side-channel discussion in Chapter 4's justification for `required` over `requisite` in network-facing `auth` stacks: `pam_faildelay` is one of the concrete tools available for managing that timing behaviour deliberately rather than leaving it as an accidental byproduct of stack composition.

### Failure modes

Rarely misconfigured in a dangerous direction, since its failure modes are inconvenience rather than security bypass — a delay set too long is an operational annoyance on high-volume legitimate authentication (bulk automated jobs authenticating repeatedly, for instance), and one set too short provides negligible throttling value. Worth tuning deliberately rather than leaving at distribution default if your threat model or your legitimate traffic pattern is unusual.

### Relationship to `pam_faillock`

Worth stating explicitly since the two are easy to conflate given how closely related their purposes sound. `pam_faildelay` operates on every single failed attempt, unconditionally, for as long as the module is present in the stack — it has no memory of previous attempts and no concept of a threshold. `pam_faillock`, covered fully in Chapter 8, counts failures per account over time and imposes an escalating consequence — typically a temporary lock — once a threshold is crossed. They compose naturally: `pam_faildelay` raises the cost of every single guess uniformly, while `pam_faillock` raises the cost of guessing repeatedly against one account specifically. A stack using only one of the two is missing half of a reasonably complete throttling posture, and it is worth checking which, if either, your production stacks actually include:

```
$ grep -l pam_faildelay /etc/pam.d/sshd /etc/pam.d/login 2>/dev/null
$ grep -l pam_faillock /etc/pam.d/sshd /etc/pam.d/login 2>/dev/null
```

---

## 6.8 `pam_listfile`

### What it does

Generic allow/deny logic against an arbitrary file, checking a specified PAM item's value against the file's contents.

### Which groups it serves

Most commonly `auth` and `account`, though it can appear in any stack depending on what is being gated.

### Purpose

The general-purpose tool for "allow or deny based on membership in this list," where the list is a plain text file you maintain directly, without needing a dedicated module for the specific attribute being checked. It predates, and remains more flexible in some respects than, some of the more specialised modules covered in Chapter 8.

### Arguments

`item=` — which PAM item to check: `user`, `tty`, `rhost`, `ruser`, `group`, `shell`.

`sense=allow` or `sense=deny` — whether presence in the file means the check passes or fails.

`file=/path/to/file` — the file to check against.

`onerr=succeed` or `onerr=fail` — what to do if the file cannot be read at all, which is a distinct case from the checked value simply not being found in it.

`apply=` — restrict the check to a specific user or group, letting one `pam_listfile` line apply conditionally.

### A worked example

Denying login to a specific list of usernames maintained by hand:

```
auth  required  pam_listfile.so  onerr=fail item=user sense=deny file=/etc/security/denied-users
```

Every name in `/etc/security/denied-users`, one per line, is refused; everyone else is unaffected, and if the file cannot be read the module fails closed per `onerr=fail`, which per Chapter 4's algorithm on a `required` line is the conservative choice — better to deny everyone than to silently permit everyone because a file went missing.

### Return values

`PAM_SUCCESS` or a failure value depending on the outcome of the list check and the `sense` direction; `PAM_SERVICE_ERR` or similar when `onerr=fail` triggers due to an unreadable file.

### Interactions

Frequently layered alongside `pam_access` (Chapter 8) for origin-based rules and `pam_succeed_if` (also Chapter 8) for attribute-based conditions; the choice between them is largely about which syntax fits the specific rule most naturally, since their capabilities overlap considerably for simple cases.

### Failure modes

`onerr=succeed` on a `sense=deny` line is the dangerous combination worth specifically checking for: if the deny-list file becomes unreadable — permissions changed, disk issue, file deleted — the module fails open and nobody on the list is denied anymore, silently, exactly the kind of `account`-stack failure Chapter 4 warned reads as loud in `auth` but silent in `account`. Since `pam_listfile` is frequently used in `account` for this reason, this specific combination deserves explicit attention in any hardening review.

### The inverse: an allow-list

The mirror configuration, restricting a service to a known set of accounts rather than excluding a known set, is equally common and worth seeing side by side with the deny example so the `sense` argument's effect is unambiguous:

```
account  required  pam_listfile.so  onerr=fail item=user sense=allow file=/etc/security/allowed-vpn-users
```

Here the safe failure direction reverses: `onerr=fail` combined with `sense=allow` means an unreadable file denies everyone, which is still the conservative choice, but note that it is conservative for the opposite reason from the deny-list case — there, `onerr=fail` protected against silently admitting people who should be excluded; here, it protects against silently admitting *everyone* because the allow-list could not be consulted. In both cases `onerr=fail` is the safer setting, but it is worth being able to state, for any given `pam_listfile` line, exactly what "failing safe" means for that specific line, rather than treating `onerr=fail` as generically synonymous with security. A line that is supposed to restrict access almost always wants `onerr=fail`; a line that exists purely to add a convenience exception on top of an otherwise-working stack may reasonably want `onerr=succeed`, since failing to read an optional exceptions file should not take down the whole service.

---

## 6.9 `pam_localuser`

### What it does

Succeeds if the user being authenticated exists in the local `/etc/passwd`, fails or ignores otherwise depending on configuration and version.

### Which groups it serves

`auth` and `account`, most commonly `auth`.

### Purpose

The routing module behind the RHEL-style idiom traced in Chapter 4: distinguishing "this is a local account, use `pam_unix`" from "this is not a local account, try the directory instead." Its role only makes sense in combination with numeric jumps or bracketed control values, since its job is specifically to steer the flow of the stack rather than to make a final authentication decision on its own.

### Arguments

`file=/path` — check against an alternate passwd-format file rather than `/etc/passwd`, rarely used outside specialised setups.

### Return values

`PAM_SUCCESS` if found locally; `PAM_USER_UNKNOWN` if not, sometimes mapped by the calling stack to `PAM_IGNORE` via `default=ignore` or a numeric jump, per the RHEL trace in Chapter 4.

### Interactions

This is the module from Chapter 4's trace 4, and rereading that trace with this module's description in hand is worth doing now that you have both pieces — the numeric jump on the `pam_localuser` line is what routes a directory user around `pam_unix` entirely and into `pam_sss`, without ever attempting, and failing, a local lookup first.

Worth noting: not every distribution's generated stack uses `pam_localuser` for this routing decision. Some use `pam_succeed_if` with a UID comparison alone, per 6.11, on the reasoning that local versus directory accounts can be distinguished by UID range without needing to check `/etc/passwd` membership directly. Which approach a given generated stack uses is a matter of that distribution's own convention, and it is worth checking rather than assuming either is universal — `authselect list-features` on a RHEL-family system, or simply reading the generated file, will show you which mechanism is actually in play.

### Failure modes

Rare in isolation; almost every failure involving this module is actually a failure in the surrounding jump arithmetic per Chapter 4, not in the module's own logic, since its job is narrow and well-defined. If a local user is unexpectedly routed to a directory service, or a directory user is unexpectedly checked against `pam_unix` first, the numeric jump around this line is the first thing to recount.

---

## 6.10 The Small Modules, Side by Side

Six single-purpose modules have now been covered — `pam_deny`, `pam_permit`, `pam_rootok`, `pam_wheel`, `pam_securetty`, `pam_faildelay` — plus `pam_listfile` and `pam_localuser`, which sit somewhere between "single-purpose" and "small general tool." They are easy to conflate with each other precisely because they are all small, so a side-by-side comparison earns its place before adding `pam_succeed_if` to the pile.

| Module | Groups | Configurable? | Typical placement | Typical control |
|---|---|---|---|---|
| `pam_deny` | all 4 | no | terminator | `required` or `requisite` |
| `pam_permit` | all 4 | no | terminator | `required` |
| `pam_rootok` | `auth` | no | first, in `su`/`passwd` | `sufficient` |
| `pam_wheel` | `auth` | group name, sense | after `pam_rootok` in `su` | `required` |
| `pam_securetty` | `auth` | terminal list | early, `login`/console services | `required` |
| `pam_faildelay` | `auth` | delay only | anywhere, timing-only | `required` (harmless either way) |
| `pam_listfile` | any | file, item, sense | routing or gating | varies with `sense` |
| `pam_localuser` | `auth`, `account` | alt. passwd file | routing, paired with jumps | bracketed, for routing |

Two columns are worth studying. "Configurable?" separates the modules that are pure structure — `pam_deny` and `pam_permit` take no arguments at all and their entire behaviour is their position — from everything else, which has at least one knob that changes what "correct" configuration looks like. And "typical control" is a reminder, not a rule: every module in this table has appeared in this chapter or in Chapter 4 under a control flag different from the one listed here, because the flag is a property of the stack's intent, not of the module.

---

## 6.11 `pam_succeed_if`

### What it does

Evaluates an arbitrary condition against PAM items and passwd/group attributes — UID ranges, group membership, service name, terminal, shell — without needing a maintained list file the way `pam_listfile` does. Where `pam_listfile` checks membership in an external file, `pam_succeed_if` checks a condition expressed directly in the configuration line itself.

### Which groups it serves

Any of the four, since its checks are generic; overwhelmingly seen in `auth` in practice, for the routing role shown in Chapter 4's RHEL traces.

### Purpose

The general-purpose conditional used throughout RHEL-family generated stacks to route between authentication paths based on UID, and increasingly common in hand-written stacks anywhere a quick attribute check is needed without standing up a separate list file.

### Syntax and arguments

Unlike most modules, its configuration is a small expression language rather than a flat list of `key=value` arguments:

```
auth  [default=1 ignore=ignore success=ok]  pam_succeed_if.so  uid >= 1000 quiet
```

The expression after the module path is the condition. Supported left-hand attributes include `uid`, `gid`, `user`, `group`, `service`, `shell`, `quiet_fail`, and several others documented in the manual page; comparison operators include `=`, `!=`, `<`, `<=`, `>`, `>=`, and `in` for group-membership-style checks. `quiet` suppresses logging on both success and failure; `quiet_fail` (as seen in Chapter 4's trace 4, `quiet_success`) suppresses logging on one side only.

### Return values

`PAM_SUCCESS` if the condition holds, `PAM_AUTH_ERR` or similar if it does not — and, importantly, whichever failure code it produces is frequently mapped through a bracketed expression to `ignore` rather than `bad`, precisely because in the RHEL routing idiom a failed condition here does not mean "deny this login," it means "this login does not match this particular path, try the next one." Reading a `pam_succeed_if` line's outcome in isolation, without also reading its control field, will give you the wrong impression of what a failure means here more often than for almost any other module in this chapter.

### Interactions

The routing partner of `pam_localuser`, as seen throughout Chapter 4's trace 4; the two are frequently used together, with `pam_succeed_if` handling numeric conditions (UID thresholds) and `pam_localuser` handling the specific "is this a local account" question, since the latter is not simply reducible to a UID range on every system.

### Failure modes

The expression syntax is easy to get subtly wrong — a missing `quiet` floods logs with routing noise on every login; a UID threshold that does not match your actual local-vs-directory UID allocation scheme routes the wrong users down the wrong path silently, which per Chapter 4's `account`-stack-is-silent principle can go unnoticed for a long time if the "wrong" path still happens to work for most affected users by coincidence.

---

## 6.12 A Note on What This Chapter Deliberately Excludes

Three categories of authentication module exist and are not covered here, on purpose, because each belongs more naturally elsewhere in this series.

**Directory and network authentication** — `pam_sss`, `pam_krb5`, `pam_ldap`. These share the shape of `pam_unix` in the `auth` group (verify a credential, return success or failure) but their operational concerns — caching, connectivity, fallback behaviour — are inseparable from the NSS and directory-integration material in Chapter 10, and covering them here would mean either an incomplete treatment now or a duplicated one later.

**Hardware and multi-factor modules** — `pam_u2f`, `pam_google_authenticator`, `pam_yubico`. These are functionally authentication modules in exactly the sense this chapter covers, but the interesting questions about them are almost entirely about stack placement relative to a first factor, and about the SSH-key-bypass interaction from Chapter 1 — again, Chapter 10's territory, where the placement question can be answered against the full picture of what a login path actually traverses.

**Lockout-adjacent authentication behaviour** — `pam_faillock`'s `auth`-stage `preauth` invocation, briefly mentioned in Chapters 3, 4, and 5, is deliberately deferred to Chapter 8 in full, since splitting its treatment across two chapters would separate the `preauth` half from the `authfail`/`authsucc` halves that give the whole module its meaning, and Chapter 4's ordering discussion already depends on seeing all three together.

If you came to this chapter specifically to configure one of these, the pointer above should save you the time of searching this chapter for something it intentionally does not contain.

One more scoping note, since it will matter for how you read Chapters 7 through 9: this chapter's modules are overwhelmingly stateless from one login attempt to the next. `pam_unix` does not remember that it rejected the same password five minutes ago; `pam_wheel` does not track how often a given account has tried and failed to satisfy its group check. That statelessness is precisely what makes the modules in this chapter simple to reason about in isolation, and precisely what makes them insufficient on their own against sustained guessing — which is exactly the gap `pam_faillock`, with its cross-invocation state built on the `pam_set_data()`/`pam_get_data()` mechanism from Chapter 5, exists to fill. Chapter 8 covers it in full; this chapter's `pam_faildelay` treatment in 6.7 is the only place state-adjacent behaviour appears here, and even that is a fixed per-attempt delay rather than genuine memory across attempts.



## 6.13 Reading `man 8 pam_unix` With This Chapter in Hand

A short closing exercise, worth doing once before moving to Chapter 7. Open the manual page for `pam_unix` on your own system and sort every argument it documents into the three groups this chapter organised them by: `auth`, `account`, `password`. Nearly every manual page in the Linux-PAM distribution lists its arguments in one undifferentiated block, alphabetically or by rough importance, without stating which management group each one is relevant to — that grouping is something you now have to supply yourself, from having read Chapter 3 and this chapter together.

This is not busywork. It is the specific skill this whole series has been building toward at the module level: a manual page tells you *what* an argument does; knowing *which stack* it matters in is what lets you place it correctly, and misplacement — an argument that only affects `password`-stage behaviour written on a line that is never reached during a normal login — is a real, silent category of misconfiguration distinct from anything covered in Chapter 4, because the syntax is entirely valid and the module loads and runs correctly. It simply never has the opportunity to do what its argument asked, because the line it is on is not part of the stack where that argument matters.

---

## 6.14 Failure Signature Reference

Consistent with the reference tables at the end of Chapters 2 and 4, and meant to be read alongside them rather than in place of them.

| Symptom | Likely module | Check |
|---|---|---|
| Correct password rejected, `(auth)` in logs | `pam_unix` | `pamtester`, confirm shadow readable, check `nullok` and helper binary |
| Password accepted with nothing typed | `pam_unix` | `nullok` present plus an empty shadow field — 6.1 |
| Root cannot `su` without a password prompt | `pam_rootok` misconfigured | Confirm `sufficient`, not `required` — 6.4 |
| Non-wheel user can `su` | `pam_wheel` absent or commented out | `grep pam_wheel /etc/pam.d/su` |
| Believed-restricted root console login succeeds unexpectedly | `pam_securetty` absent, removed, or superseded by `sshd_config` | 6.6's current-relevance note |
| Deny-list stops working after a file change | `pam_listfile` with `onerr=succeed` on a `sense=deny` line | 6.8 |
| Local users routed to directory service, or vice versa | Jump arithmetic around `pam_localuser` | Recount per Chapter 4 |
| Login unexpectedly routed down the wrong branch of a UID-based stack | `pam_succeed_if` condition wrong, or its control field maps failure to the wrong action | 6.11 |
| Total denial, no module named | Missing terminator or off-the-end jump | Chapter 4, trace 6 |

---

## 6.15 Verification

Test machine, snapshot, second root shell.

**1. Confirm `pam_unix`'s privilege-separation path.**

```
$ strace -f -e trace=execve pamtester login "$USER" authenticate 2>&1 | grep -i chkpwd
```

Run once as an unprivileged user driving `pamtester` against a service where the calling context cannot read shadow directly, and once where it can (as root). Confirm the helper is invoked in the first case and not necessarily in the second.

**2. Audit for `nullok` and empty shadow fields.**

```
$ grep -rn nullok /etc/pam.d/
# awk -F: '($2 == "") {print $1}' /etc/shadow
```

Cross-reference the two results and decide, per 6.1, whether `nullok` should be removed from any production stack on this system.

**3. Confirm the `pam_rootok` / `sufficient` relationship.**

On a test `su` service, change `sufficient pam_rootok.so` to `required` and attempt `su` as root to another user. Predict the outcome using Chapter 4's algorithm before testing. Restore it.

**4. Enable `pam_wheel` correctly.**

```
$ getent group wheel
```

Confirm your test user's membership, uncomment the `pam_wheel` line in a test copy of `/etc/pam.d/su`, and confirm both a member and a non-member's behaviour with `pamtester` before considering it verified.

**5. Determine your system's actual root-console posture.**

```
$ grep -l pam_securetty /etc/pam.d/*
$ cat /etc/securetty 2>/dev/null
$ grep -i PermitRootLogin /etc/ssh/sshd_config
```

Write down, in one sentence, what actually prevents or permits root from logging in directly on this system, citing the specific mechanism rather than assuming one.

**6. Build and test a `pam_listfile` deny rule.**

Implement the worked example from 6.8 against a throwaway service and a test username. Confirm the deny works, then make the list file unreadable (`chmod 000`) and confirm the `onerr=fail` behaviour denies everyone rather than silently permitting everyone. Change to `onerr=succeed` and confirm the opposite, dangerous behaviour, so you have seen both firsthand.

**7. Trace `pam_localuser` routing.**

If you have access to a RHEL-family system with SSSD configured, or can simulate one, add `debug` to both `pam_localuser` and the `pam_unix`/`pam_sss` lines around it, and confirm which path a local account and a directory account each take, matching against Chapter 4's trace 4.

**8. Complete the manual-page sorting exercise from 6.13.**

Do it for `pam_unix` and for at least one other module from this chapter. Note any argument you cannot confidently place, and look up its behaviour specifically rather than guessing.

**9. Read a `pam_succeed_if` expression cold.**

Take the line from Chapter 4's trace 4 — `pam_succeed_if.so uid >= 1000 quiet_success` — and, without rereading that trace, predict what happens for a UID-500 system account and a UID-2000 human account. Then confirm with `pamtester` against a copy of that stack, using `debug` in place of `quiet_success` so you can see the module's own log output.

**10. Confirm the ignore-versus-bad distinction for `pam_succeed_if`.**

Build a two-line test stack: `pam_succeed_if.so` with a condition that will fail for your test user, controlled first by a bracket mapping its failure to `ignore`, then by a bracket mapping it to `bad`. Confirm with `pamtester` that the same failed condition produces a passing stack in the first case (assuming a `pam_permit.so` follows) and a failing one in the second. This is 6.11's point about reading the control field alongside the module, made concrete.

**11. Audit your throttling posture.**

Run the `grep` commands from 6.7's `pam_faillock` relationship note against every network-facing service on a system you administer. For any service missing both modules, decide — and write down — whether that is an intentional decision or an oversight, per this chapter's opening scenario about defaults combining unintentionally.

---

## Where This Goes Next

You now have a working reference for the modules that decide identity and the small modules that structure the decision around them. Read together, this chapter's dozen-plus modules cover the great majority of what actually appears in a typical `auth` stack on a machine that is not talking to a directory service — which means most standalone servers, most development machines, and a meaningful fraction of production hosts even at organisations that do use directory integration elsewhere in their fleet. Chapter 7 stays in similar territory but shifts to the `password` stack specifically — `pam_pwquality`, `pam_pwhistory`, and the two-phase mechanics from Chapter 3 made concrete against real modules, including the `use_authtok` chaining this chapter has referenced repeatedly without yet showing broken.

One thing to carry forward specifically: `pam_unix`'s `nullok` and `pam_listfile`'s `onerr=succeed` are this chapter's two clearest examples of a pattern Chapter 4 named and Chapter 11 will return to at length — a setting that is not wrong on the day it is written, but becomes wrong the moment an unrelated condition changes elsewhere on the system, silently, with no configuration edit at all. Auditing for these is not a one-time task. Keep the opening scenario in mind as the reason why: neither the provisioning script's bug nor the `nullok` argument was, by itself, the incident.

---

## Further Reading for This Chapter

- `man 8 pam_unix` — read in full, then again using the grouping exercise in 6.13
- `man 8 pam_deny`, `man 8 pam_permit`, `man 8 pam_rootok`, `man 8 pam_wheel`, `man 8 pam_securetty`, `man 8 pam_faildelay`, `man 8 pam_listfile`, `man 8 pam_localuser`, `man 8 pam_succeed_if`
- `man 8 unix_chkpwd`, referenced first in Chapter 1 and exercised directly here
- `man 5 shadow`, for the aging fields `pam_unix` reads in its `account` role
- The Linux-PAM source, `modules/pam_unix/`, for anyone who worked through Chapter 5 and wants to see the real privilege-separation implementation rather than the simplified sketch given there
- Your own distribution's generated `common-auth` or `system-auth`/`password-auth`, read once more with every module in this chapter now identifiable by name and purpose rather than by position alone

This chapter's material is meant to be reopened, not read start to finish a second time — the next time a stack in front of you names `pam_wheel` or `pam_listfile` and you cannot immediately recall its arguments, this is where to come back to.
