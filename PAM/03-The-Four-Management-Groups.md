# 03 — The Four Management Groups

Chapter 2 taught you to find the configuration and read a line. The first field of that line is a word: `auth`, `account`, `password`, or `session`. This chapter is about what those words mean.

That sounds like a small subject and it is not. The four groups are the decomposition described in Chapter 1, the one that pulled apart four questions that pre-PAM software had mashed together. Getting them clear is what lets you look at a stack and know what it is for, and more importantly what it is *not* for. A great deal of misconfiguration in the wild consists of putting a perfectly good module in a perfectly reasonable-looking place where it does nothing at all.

There is also a second subject hiding in here that almost no documentation covers well: the state that flows between the four stacks. They are independent in the sense that each is evaluated separately, and they are emphatically not independent in the sense of sharing nothing. A password collected in `auth` is available in `password`. State stored by a module in one stack is retrievable by the same module in another. Understanding what carries over and what does not is what makes `try_first_pass`, `use_authtok`, and the three-line `pam_faillock` idiom comprehensible rather than magical.

By the end of this chapter you should be able to name which stack any given module belongs in, explain what happens when it is in the wrong one, describe the two calls that traverse the `auth` stack and why they differ, and read the shape of a service file to infer what the application is doing with it.

---

## 3.1 Why Four

Start with the decomposition, restated as four questions asked in sequence about one login attempt:

1. **Can this principal prove they are who they claim to be?**
2. **Independently of that, is this account permitted to be used right now?**
3. **Does the credential need to be replaced before we go any further?**
4. **What must be built around this session, and torn down afterwards?**

They are genuinely independent. The answer to any one of them constrains none of the others.

A correct password with an expired account: question 1 says yes, question 2 says no. A correct password on an account whose password aged out yesterday: 1 says yes, 2 says "yes, but first", and 3 becomes mandatory. A key-based SSH login: question 1 is skipped entirely by the application, 2 and 4 still apply. A cron job: 1 is irrelevant, 2 and 4 both matter. A `runuser` invocation from a service script: 1 is deliberately skipped, and depending on the file, 2 and 4 may still run.

Every one of those combinations is normal and every one of them appears on a running system. A design that treats them as one question cannot express any of them.

The four groups map onto the four questions exactly:

| Group | Question | Framework call | Module function |
|---|---|---|---|
| `auth` | Who are you, and what credentials do you get? | `pam_authenticate()`, `pam_setcred()` | `pam_sm_authenticate()`, `pam_sm_setcred()` |
| `account` | May this account be used now? | `pam_acct_mgmt()` | `pam_sm_acct_mgmt()` |
| `password` | Change the credential. | `pam_chauthtok()` | `pam_sm_chauthtok()` |
| `session` | Build and tear down the session. | `pam_open_session()`, `pam_close_session()` | `pam_sm_open_session()`, `pam_sm_close_session()` |

Six module functions, four groups. Two of the groups have two functions because they have two directions: `auth` both establishes and refreshes credentials, and `session` both opens and closes. That asymmetry is the source of most of what is interesting in this chapter.

Note also what the table implies about modules. Nothing forces a module to implement all six functions. `pam_rootok` implements one. `pam_unix` implements all six and can therefore appear in all four stacks, doing something different in each. Chapter 2's `objdump` trick tells you which is which:

```
$ objdump -T /usr/lib64/security/pam_limits.so | grep pam_sm_
0000000000002a30 g    DF .text  pam_sm_open_session
0000000000002a40 g    DF .text  pam_sm_close_session
```

Two functions, both `session`. `pam_limits` in an `auth` stack is not a policy decision, it is a line that does nothing.

### The independence, demonstrated

The claim that the stacks are independent is easy to state and easy to under-appreciate, so here it is as a table. One account, one machine, five scenarios, and the outcome of each stack:

| Scenario | `auth` | `account` | `password` | `session` |
|---|---|---|---|---|
| Normal password login | pass | pass | not run | runs |
| Wrong password | fail | not reached | not run | not run |
| Right password, account expired | pass | fail | not run | not run |
| Right password, password aged out | pass | `NEW_AUTHTOK_REQD` | runs | runs |
| SSH key login, account expired | skipped by app | fail | not run | not run |
| `cron` job, account expired | not run | fail | not run | not run |
| `cron` job, healthy account | not run | pass | not run | runs |

Two rows are worth calling out.

Row five is the one that surprises people who assume key-based SSH bypasses PAM entirely. It bypasses `auth`. It does not bypass `account`, which is why account expiry still works for key logins, and why the correct place for an access restriction is `account`.

The last two rows are the reason `cron` has a PAM file at all. There is no authentication to do and there is still a policy decision to make, on every scheduled job, forever.

---

## 3.2 The `auth` Group

### What it is for

Verifying that the principal is who they claim to be, and establishing credentials for them.

That is two things, and the second one is the part people miss. We will take them in order.

### `pam_authenticate()`

The application calls it:

```c
retval = pam_authenticate(pamh, 0);
```

The framework walks the `auth` stack calling `pam_sm_authenticate()` in each module, combines the results per Chapter 4's algorithm, and returns one value.

What modules do here: prompt for and verify a password, verify a token, perform a Kerberos exchange, check a hardware key, check whether the caller is already root, check group membership as a precondition for even trying, impose a delay after failure.

What they do *not* do here: decide whether an account is allowed to be used. That is `account`. The distinction is not pedantic. A module that denies in `auth` when it should deny in `account` produces the wrong failure code, which produces the wrong log message, which produces a bad diagnosis.

Common return values:

| Value | Meaning |
|---|---|
| `PAM_SUCCESS` | Credential verified |
| `PAM_AUTH_ERR` | Credential wrong |
| `PAM_USER_UNKNOWN` | No such user, as far as this module is concerned |
| `PAM_AUTHINFO_UNAVAIL` | Cannot check right now: directory unreachable, file missing |
| `PAM_CRED_INSUFFICIENT` | The application does not have enough privilege to check |
| `PAM_MAXTRIES` | Too many attempts |
| `PAM_IGNORE` | This module has no opinion; do not count it |
| `PAM_ABORT` | Something is badly wrong; stop everything |

The distinction between `PAM_AUTH_ERR` and `PAM_AUTHINFO_UNAVAIL` is worth dwelling on. The first means "this password is wrong." The second means "I could not tell you whether it is wrong." A stack that treats those identically will fail closed when your LDAP server hiccups, which may be what you want; a stack that distinguishes them can fall back to local authentication when the directory is down, which is usually what an enterprise wants. Expressing that difference requires the bracketed control syntax from Chapter 4, and this is one of its best justifications.

`PAM_IGNORE` is the other one to know. It means the module declines to participate, and the framework does not fold it into the running result at all. `pam_succeed_if` returns it constantly. `pam_localuser` uses it to say "this is not a local user, not my business." A module returning `PAM_IGNORE` on a `required` line does not cause failure, which is exactly why the value exists.

### `pam_setcred()`, and why modules run twice

Here is the part that confuses everyone the first time.

```c
retval = pam_setcred(pamh, PAM_ESTABLISH_CRED);
```

This traverses the **same `auth` stack**, in the **same order**, calling a **different function** in each module: `pam_sm_setcred()` rather than `pam_sm_authenticate()`.

The purpose is different. Authentication asked "is this really them." Credential establishment says "they are in, now give them whatever credentials this mechanism issues."

For `pam_unix`, that means essentially nothing; there is no local credential to issue beyond the UID the application is about to assume. For a Kerberos module it means obtaining a ticket-granting ticket and putting it in a credential cache. For AFS-style modules it meant acquiring tokens. For `pam_sss` it can mean populating a credential cache from the directory.

Four flags select the direction:

| Flag | Meaning |
|---|---|
| `PAM_ESTABLISH_CRED` | Create credentials for this session |
| `PAM_DELETE_CRED` | Destroy them, at logout |
| `PAM_REINITIALIZE_CRED` | Refresh existing credentials, typically after a fork or identity change |
| `PAM_REFRESH_CRED` | Extend the lifetime of existing credentials |

So the sequence in a login program is `pam_authenticate()`, then `pam_acct_mgmt()`, then `pam_setcred(PAM_ESTABLISH_CRED)`, and at the end `pam_setcred(PAM_DELETE_CRED)`.

Three practical consequences:

**A module in the `auth` stack executes at least twice per login.** If it logs on every invocation, you see it twice. This is normal. Before you go looking for a duplicated line in your configuration, check whether what you are seeing is `authenticate` followed by `setcred`.

**A module can succeed in one pass and fail in the other.** Authentication succeeds and credential establishment fails when, for example, the KDC verified the password but the credential cache cannot be written. The login then fails after apparently succeeding, which looks bizarre until you know these are separate calls.

**Applications get the ordering wrong.** The documented expectation is that `pam_setcred(PAM_ESTABLISH_CRED)` happens after `pam_acct_mgmt()` and before `pam_open_session()`. Not every application does it in that order, and some skip `pam_setcred()` entirely. If a credential-issuing module behaves differently under one program than another, this is the first thing to check, and `strace` or the module's `debug` output will tell you.

### What belongs in `auth`

Verification of identity, and only that. Concretely: `pam_unix`, `pam_sss`, `pam_krb5`, `pam_ldap`, `pam_u2f`, `pam_google_authenticator`, `pam_yubico`, plus the structural helpers `pam_deny`, `pam_permit`, `pam_rootok`, and the gatekeepers `pam_wheel`, `pam_securetty`, `pam_faildelay`, `pam_faillock`.

That last one is interesting and is covered in Chapter 8. `pam_faillock` appears in *both* `auth` and `account`, doing different work in each, which is a good illustration of why the groups exist.

### Which groups can talk to the user

A constraint that is never stated explicitly anywhere and explains a whole family of bugs.

Modules communicate with the user through the conversation function, which the application supplied at `pam_start()`. Any module in any group *can* call it. Whether there is a human on the other end is a different question, and it depends on the group.

`auth` runs while the application is still interacting with whoever is trying to log in. Prompting works.

`password` likewise: a token change is inherently interactive, and the whole stack is built around prompting.

`account` runs after authentication, when the application may still have a channel open, and modules here conventionally do not prompt. They report a decision. A module that prompts in the `account` stack will work under `login` and behave unpredictably elsewhere.

`session` is the problem case. It runs for services with no user attached at all. `cron` opens a session for a scheduled job at 3 AM. `systemd-user` opens one during boot. There is nobody to answer a prompt, and the conversation function supplied by such an application will typically return an error or an empty response.

This is the mechanism behind a specific and confusing symptom: **a module that works perfectly for interactive logins and hangs or fails for cron jobs and system services.** The module is prompting. Interactively, you answer it. Non-interactively, nothing does.

If you are adding anything to a `session` stack that might ask a question, test it under `cron` before you trust it. The same applies to `pam_exec` running a script that reads from standard input, which is a mistake people make once.

---

## 3.3 The `account` Group

### What it is for

Deciding whether this account may be used, right now, in these circumstances. Independently of whether the credential was correct.

Say the second half out loud a few times. It is the whole point of the group and it is the thing people forget.

### The call

```c
retval = pam_acct_mgmt(pamh, 0);
```

One call, one function per module, no second pass. Simpler than `auth` in every respect except its consequences.

### What gets checked here

**Account expiry.** The shadow file's expiry field. The account exists, the password is right, and the account was scheduled to stop working last Tuesday.

**Password aging.** The maximum age and inactive fields. This is where "your password has expired" is detected, and note carefully that it is detected in `account`, not in `password`. The `password` stack is what runs to *fix* it. Chapter 7 draws this boundary in detail because it is the single most confused point in the whole subject.

**Origin restrictions.** `pam_access` checking the source host, network, or terminal against `access.conf`. `pam_time` checking the clock against `time.conf`.

**Membership and arbitrary conditions.** `pam_succeed_if`, `pam_listfile`.

**System-wide blocks.** `pam_nologin`, which refuses non-root logins while `/etc/nologin` exists.

**Lockout state.** `pam_faillock`, in its `account` role, reporting that the account is currently locked out.

Common return values:

| Value | Meaning |
|---|---|
| `PAM_SUCCESS` | Proceed |
| `PAM_ACCT_EXPIRED` | The account itself has expired |
| `PAM_NEW_AUTHTOK_REQD` | Fine, but the password must be changed first |
| `PAM_PERM_DENIED` | Not permitted, for a policy reason |
| `PAM_AUTH_ERR` | Generic refusal |
| `PAM_USER_UNKNOWN` | Not known to this module |
| `PAM_IGNORE` | No opinion |

### `PAM_NEW_AUTHTOK_REQD`, the handoff

This value is the seam between two groups and it is worth tracing.

The `account` stack returns `PAM_NEW_AUTHTOK_REQD`. That is not a failure. It means the account is usable but the credential must be replaced before the login continues. A well-written application responds by calling:

```c
retval = pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK);
```

which runs the `password` stack in its "forced change" mode, and then continues to `pam_setcred()` and `pam_open_session()` as normal.

An application that does not handle this value has two options, both bad: treat it as success and let a user in with an expired password, or treat it as failure and lock the user out with no way to change it. Both have shipped, historically. If you ever meet a service where password expiry means "you can never log in again," this is why.

### The characteristic symptom

Correct username, correct password, and the connection closes.

The `auth` stack passed. The `account` stack refused. The logs will name a module and the string `(service:account)`, and once you know to read that annotation you will diagnose this class of problem in about ten seconds:

```
sshd[3312]: pam_access(sshd:account): access denied for user `parsa' from `203.0.113.9'
sshd[3312]: Failed password for parsa from 203.0.113.9 port 55214 ssh2
```

The second line is `sshd` reporting the overall outcome in its own vocabulary, and it says "failed password," which is simply wrong. The password was fine. The first line is the truth. This mismatch between what the application reports and what actually happened is a recurring theme, and it is why Chapter 11 insists on reading the PAM-annotated lines rather than the application's summary.

---

## 3.4 The `password` Group

### What it is for

Changing an authentication token. Nothing else. This stack does not run during a normal login at all, unless the `account` stack asked for it.

### The call

```c
retval = pam_chauthtok(pamh, 0);                          /* ordinary change */
retval = pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK); /* forced change */
```

`passwd` makes the first call. A login program handling `PAM_NEW_AUTHTOK_REQD` makes the second. The flag tells modules to only change tokens that are actually expired, which matters when several mechanisms are stacked and only one of them has expired.

### Two phases

Here is the structural feature that makes this group different from the other three.

**Each module in the `password` stack is called twice**, and the framework walks the whole stack twice:

**Pass one, `PAM_PRELIM_CHECK`.** Every module is asked: are you ready and able to change this token? Do not change anything yet. A module talking to a directory checks that the directory is reachable and that it has permission. A quality module may check nothing at all in this pass.

**Pass two, `PAM_UPDATE_AUTHTOK`.** Only if pass one succeeded across the stack. Now every module actually performs the change.

The reason is atomicity, and it is a genuinely good piece of design. Consider a system where a password must be updated in both the local shadow file and an LDAP directory. Without a preliminary pass, you change the local one, then discover the directory is unreachable, and now the user's credentials differ between two systems with no way to roll back. With the preliminary pass, the failure is detected before anything has been written.

It is a two-phase commit, in a subsystem nobody thinks of as a distributed system.

### What this means for configuration

Three things follow, and all three cause real problems.

**A module that ignores the phase argument will change things twice**, or change things during the check pass. Badly written third-party modules do this. The symptom is bizarre: password changes that appear to work but leave the account in a strange state.

**Quality checking and token setting are different modules, and the order matters.** The canonical stack:

```
password  requisite  pam_pwquality.so  retry=3
password  required   pam_unix.so       use_authtok sha512 shadow
```

`pam_pwquality` runs first, prompts for and validates the new password, and stores it as the token. `pam_unix` runs second with `use_authtok`, meaning "do not prompt, use the token the previous module set."

Remove `use_authtok` and `pam_unix` prompts for its own new password, independently, and never sees the one that was validated. The user is prompted twice, and the second password, the one actually stored, is never quality checked. The stack looks like it enforces a policy. It does not. Chapter 7 covers this at length because it is common and because it fails silently in the permissive direction.

**`requisite` rather than `required` on the quality module is deliberate.** If quality checking fails, there is no reason to continue into the module that would perform the change. Chapter 4 explains the distinction properly.

Common return values:

| Value | Meaning |
|---|---|
| `PAM_SUCCESS` | Changed, or ready to change |
| `PAM_AUTHTOK_ERR` | The new token is unacceptable |
| `PAM_AUTHTOK_RECOVERY_ERR` | Could not obtain the old token |
| `PAM_AUTHTOK_LOCK_BUSY` | The password database is locked; try later |
| `PAM_AUTHTOK_DISABLE_AGING` | Aging is disabled for this account |
| `PAM_TRY_AGAIN` | Preliminary check failed; not ready |
| `PAM_PERM_DENIED` | Not allowed to change this token |
| `PAM_USER_UNKNOWN` | Not known to this module |

`PAM_TRY_AGAIN` is specific to this group and is what a module returns from the preliminary pass to abort the whole operation cleanly.

### The forced-change flow, end to end

Worth tracing once, because it crosses three groups and is where most people's mental model has a gap.

A user whose password aged out yesterday connects over SSH:

1. `sshd` calls `pam_authenticate()`. The `auth` stack runs. The password is correct, so this returns `PAM_SUCCESS`. Nothing here noticed the age.
2. `sshd` calls `pam_acct_mgmt()`. `pam_unix` in the `account` stack reads the shadow aging fields, sees the password is past its maximum age, and returns `PAM_NEW_AUTHTOK_REQD`.
3. `sshd` sees that value and calls `pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK)`.
4. The `password` stack runs, both phases. `pam_pwquality` prompts for a new password and validates it. `pam_unix` with `use_authtok` writes it and resets the aging fields.
5. `sshd` continues to `pam_setcred()` and `pam_open_session()`.

Five steps, four PAM calls, three different stacks, and the user experiences it as "it asked me to change my password."

Now the failure modes, each of which you will meet:

**Step 3 not implemented by the application.** The user is either let in with an expired password or refused with no path forward. Not a configuration problem.

**Step 4 has no working `password` stack.** The change fails, so the login fails, permanently, and the user cannot fix it because fixing it requires logging in. The recovery is an administrator resetting the password with `passwd` as root, which uses a different service file and may work fine.

**Step 4's quality policy rejects everything the user tries.** With `retry=3` they get three attempts and then the login fails. This is not a bug, and it is worth thinking about before setting an aggressive `pwquality` policy on a fleet whose users will hit it at the worst possible moment.

**Step 2 uses `broken_shadow` or a misconfigured aging field.** Aging is silently not enforced. Worth checking if your compliance position depends on it.

---

## 3.5 The `session` Group

### What it is for

Everything that must exist around the service while it runs, created before and destroyed after.

On a modern Linux system this is the largest stack in most service files, and it does more work than the other three combined.

### The calls

```c
retval = pam_open_session(pamh, 0);
/* ... the service runs ... */
retval = pam_close_session(pamh, 0);
```

Two calls, two module functions, and a symmetry that is more aspirational than real, as we will see.

### What happens here

**Resource limits.** `pam_limits` reads `limits.conf` and applies `setrlimit()`. Chapter 9 covers the important caveat about systemd's parallel mechanism.

**Environment.** `pam_env` sets variables from `pam_env.conf` and `/etc/environment`.

**Kernel session identity.** `pam_loginuid` writes `/proc/self/loginuid`, which is the immutable audit identity that follows every process descended from this login. This is what makes `auditd` able to attribute an action to a human even after five `sudo` transitions. It is a small module doing something disproportionately important.

**The logind session.** `pam_systemd` registers the session with `systemd-logind`, which creates a session object, places the processes in a scope under a user slice, sets `XDG_RUNTIME_DIR`, and manages the lifecycle. This is where "a session" stops being an abstraction and becomes a kernel cgroup with a name.

**Keyring.** `pam_keyinit` creates a session keyring.

**Home directory.** `pam_mkhomedir` creates one if it does not exist, which matters for directory-backed users whose home was never provisioned locally.

**Namespaces.** `pam_namespace` sets up polyinstantiated directories.

**Cosmetics and notification.** `pam_motd`, `pam_mail`, `pam_lastlog` where it still exists.

**Security context.** `pam_selinux`, in two invocations, `close` before and `open` after, which is why you see it twice in the Debian `sshd` file from the README.

Return values are simple: `PAM_SUCCESS`, `PAM_SESSION_ERR`, `PAM_BUF_ERR`, `PAM_ABORT`, `PAM_IGNORE`.

### Four things called "session"

Part of why this group is confusing is that the word means four different things on a modern system, and they do not have the same lifetime.

**The PAM session.** Bounded by `pam_open_session()` and `pam_close_session()`. Exists only inside the application's process. This is the only one PAM itself owns.

**The logind session.** Created by `pam_systemd` calling into `systemd-logind`. Has an ID, a state, a seat, a scope in the cgroup tree, and a `XDG_RUNTIME_DIR`. Outlives the PAM session if processes remain and `KillUserProcesses` is off. This is what `loginctl` shows you.

**The kernel session keyring and audit session ID.** `pam_keyinit` creates the first; `pam_loginuid` writes the audit login UID, from which the kernel derives a session identifier that follows every descendant process. Neither is destroyed by `close_session`; both end when the last process holding them exits.

**The utmp record.** The traditional "who is logged in" database, written by the application or by `pam_lastlog` style modules. Historically the only notion of session, still consulted by `who` and `w`, and routinely out of sync with all three of the above.

```
$ loginctl list-sessions          # logind's view
$ who                             # utmp's view
$ cat /proc/self/loginuid         # the audit identity
$ keyctl show @s 2>/dev/null      # the session keyring
```

Run those four commands in one terminal and compare. On a healthy interactive login they agree. On a `tmux` session that survived a logout, or a service that forked oddly, they will not, and knowing which one you are actually asking about is the difference between a diagnosis and a shrug.

The one that matters most for security work is the audit login UID, because it is the identity that survives every subsequent `sudo` and `su`, and it is set exactly once, in the `session` stack, by one small module. If `pam_loginuid` is missing from a service's stack, actions taken through that service cannot be attributed to a human in the audit log. That is worth checking on any service that offers shell access.



The model says: open, run, close. Reality is messier, and the messiness produces a specific class of operational problem worth knowing about.

**Processes that outlive their session.** You start `tmux`, log out, log back in. The `close_session` for the first login ran while `tmux` was still alive. What happens to it depends on `KillUserProcesses` in `logind.conf` and on whether the process escaped the session scope. This is the mechanism behind the perennial "my background job died when I logged out" and its opposite, "these processes have been running under a session that ended three weeks ago."

**Applications that fork.** `sshd` forks a privileged monitor and an unprivileged worker. The `close_session` is issued by the monitor after the worker exits. If the monitor is killed, the close never happens. Leaked logind sessions are usually this.

**Applications that never close.** Some programs call `pam_open_session()` and simply exit without the matching close, either through bugs or through crashes. Every session module's cleanup is skipped. `loginctl list-sessions` on a long-running box will often show sessions with no processes, and that is what they are.

```
$ loginctl list-sessions
$ loginctl session-status 47
```

**Order on close is not reversed automatically.** The framework walks the stack in the same order for `close_session` as for `open_session`. Modules that need teardown ordering have to handle it themselves. This surprises people who expect stack discipline.

The practical advice: treat `close_session` as best-effort. Design session-stack policy so that a missed close is untidy rather than dangerous. If a module's open grants something that its close revokes, and the close may not run, you have a security property that depends on well-behaved applications.

---

## 3.6 Who Calls What

The application decides which stacks to use. Nothing forces it to use all four, and the choices are informative.

### The canonical sequence

A full-featured login program does this:

```c
pam_start("login", user, &conv, &pamh);
pam_set_item(pamh, PAM_TTY,   tty);
pam_set_item(pamh, PAM_RHOST, remote_host);

pam_authenticate(pamh, 0);                       /* auth stack     */
retval = pam_acct_mgmt(pamh, 0);                 /* account stack  */

if (retval == PAM_NEW_AUTHTOK_REQD)
        pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK);   /* password stack */

pam_setcred(pamh, PAM_ESTABLISH_CRED);           /* auth stack, second pass */
pam_open_session(pamh, 0);                       /* session stack  */

/* ... run the shell ... */

pam_close_session(pamh, 0);                      /* session stack  */
pam_setcred(pamh, PAM_DELETE_CRED);              /* auth stack, third pass  */
pam_end(pamh, retval);
```

Read that sequence a couple of times. It is the skeleton of every trace in Chapter 10, and the ordering of `acct_mgmt` before `setcred` and `setcred` before `open_session` is the part applications get wrong.

Note also the two `pam_set_item()` calls before anything else. The application supplies context that modules will need: which terminal, which remote host. `pam_access` cannot enforce an origin rule if the application never told PAM what the origin was. When an origin-based rule mysteriously does not fire under one service but works under another, an unset `PAM_RHOST` is a strong candidate.

### When applications get the sequence wrong

The sequence above is what the documentation expects. Real applications deviate, and the deviations produce symptoms that look like configuration problems and are not.

**Skipping `pam_setcred()` entirely.** Perfectly fine on a system where no module issues credentials, and broken the day you add Kerberos. The symptom is that authentication succeeds and the user has no ticket, so every subsequent network operation prompts again or fails. Nothing in the PAM configuration is wrong.

**Calling `pam_open_session()` before `pam_setcred()`.** Session modules that expect credentials to exist find none. `pam_mkhomedir` against a directory-backed home, for instance, may need the credential to reach the file server.

**Not handling `PAM_NEW_AUTHTOK_REQD`.** Covered in 3.3. Either the user gets in with an expired password or they can never get in at all.

**Never setting `PAM_RHOST` or `PAM_TTY`.** The application knows the remote host and does not tell PAM. Origin-based rules in `access.conf` then match against an empty value, and behave differently from the same rule under a service that does set it. When a `pam_access` rule works for `sshd` and not for some other network service, this is the usual reason.

**Calling `pam_end()` without `pam_close_session()`.** Session teardown never runs. See 3.5.

The diagnostic for all of these is the same and it is worth internalising: **when a policy behaves differently under two services with identical stacks, the difference is in the applications, not the configuration.** Compare what each program calls, using `strace`, the module's `debug` output, or the source. Chapter 10 does this for four services in detail.



Approximate, and worth verifying on your own system rather than trusting a table in a document:

| Service | `auth` | `account` | `password` | `session` |
|---|---|---|---|---|
| `login` | yes | yes | on demand | yes |
| `sshd`, password auth | yes | yes | on demand | yes |
| `sshd`, key auth | skipped | yes | on demand | yes |
| `su` | yes | yes | on demand | yes |
| `sudo` | yes | yes | rarely | varies by build |
| `passwd` | rarely | rarely | yes | no |
| `cron` | minimal | yes | no | yes |
| `runuser` | deliberately skipped | yes | no | yes |
| `systemd-user` | no | yes | no | yes |

Three rows repay attention.

**`sshd` with key authentication** is the one from Chapter 1. The `auth` stack does not run. Everything else does. A second factor in `auth` therefore protects password logins only.

**`runuser` deliberately does not authenticate.** It exists so that service scripts can drop privilege without a password. Its service file typically has `auth sufficient pam_rootok.so` and nothing meaningful after it. When auditing what can become another user on a box, this belongs on the list next to `su` and `sudo`.

**`passwd` uses essentially only the `password` stack.** Its `auth` and `account` lines exist mostly so that `pam_rootok` can let root skip the old-password prompt.

### Reading the shape

Because different applications use different subsets, you can infer a lot about a program from the shape of its service file.

A file with a long `session` stack and a trivial `auth` stack is doing session setup for something that authenticates elsewhere or not at all. A file with a substantial `auth` stack and no `session` lines is a credential checker that does not start a session, such as a screen locker. A file with only `password` lines is a token-changing utility.

Try it. Look at three files you have never opened and predict what each program does before checking:

```
$ for f in /etc/pam.d/*; do
      printf '%-24s' "$(basename "$f")"
      for t in auth account password session; do
          printf '%s=%-3d' "${t:0:4}" "$(grep -c "^-\?$t" "$f")"
      done
      echo
  done | sort
```

That output is a map of your system's authentication surface, one line per service, and it takes four seconds to produce.

---

## 3.7 What Flows Between the Stacks

The four stacks are evaluated independently. They are not isolated. Understanding what carries over is what makes several otherwise mysterious idioms legible.

### The handle

Everything hangs off the `pam_handle_t` created by `pam_start()` and destroyed by `pam_end()`. One handle spans all four stacks for one transaction. State attached to it persists across `pam_authenticate()`, `pam_acct_mgmt()`, `pam_chauthtok()`, and `pam_open_session()`.

### Items

Items are named pieces of state readable, and sometimes writable, by any module in any stack:

| Item | Set by | Notes |
|---|---|---|
| `PAM_SERVICE` | framework | The service name from `pam_start()` |
| `PAM_USER` | application or module | Can be changed by a module mid-transaction |
| `PAM_USER_PROMPT` | application or module | The string used when asking for a username |
| `PAM_TTY` | application | Terminal name |
| `PAM_RUSER` | application | Requesting user, for remote services |
| `PAM_RHOST` | application | Remote host |
| `PAM_CONV` | application | The conversation function |
| `PAM_AUTHTOK` | modules only | The current authentication token |
| `PAM_OLDAUTHTOK` | modules only | The previous one, during a change |
| `PAM_XDISPLAY`, `PAM_XAUTHDATA` | application | X11 context |

The two token items are restricted: applications cannot read or write them, only modules can. That restriction is the reason an application can be entirely unaware of what credential was used, which is the whole architectural point from Chapter 1.

Three consequences worth holding onto:

**`try_first_pass` and `use_first_pass` are implemented on top of `PAM_AUTHTOK`.** The first module to prompt stores what it collected. Later modules with those arguments read it instead of prompting. There is no framework magic; it is one item and a convention.

**`use_authtok` in the `password` stack is the same mechanism**, applied to the new token rather than the old one. `pam_pwquality` validates a new password and stores it; `pam_unix` with `use_authtok` reads it. That is the entire chaining mechanism.

**A module can change `PAM_USER`.** A module in `auth` can decide the user is actually someone else, and everything downstream, including `account` and `session`, operates on the new value. This is legitimate and rare, and it is worth knowing about because it makes "the logs say a different username than I typed" a real possibility rather than a bug.

### Module data

Beyond items, a module can attach arbitrary private data to the handle:

```c
pam_set_data(pamh, "my_module_state", ptr, cleanup_fn);
pam_get_data(pamh, "my_module_state", &ptr);
```

Keyed by a string, private to the module, destroyed by the cleanup function at `pam_end()`.

This is how a module coordinates with itself across stacks. `pam_faillock` uses exactly this: the `preauth` invocation in the `auth` stack records state, and the `authfail` or `authsucc` invocation later reads it to decide whether to increment or clear the tally. When Chapter 8 explains why all three `pam_faillock` lines are needed and why their order is fixed, the underlying reason is this mechanism.

### What does not flow

The `password` stack does not automatically know whether authentication succeeded. The `session` stack does not know which module authenticated. The framework does not pass a "how did we get here" summary between stacks. Anything a module needs from an earlier stack it must have stored itself, or read from an item.

This is why a module that needs to coordinate across stacks appears in both, and why seeing the same module name in two different stacks is a signal to read its manual page rather than a sign of redundancy.

---

## 3.8 Getting the Group Wrong

Four mistakes, in descending order of frequency.

### Module in a stack it does not implement

```
auth  required  pam_limits.so
```

`pam_limits` implements only session functions. The framework cannot resolve `pam_sm_authenticate` in it, logs an unresolved-symbol error, and the line behaves as an unknown module, which per Chapter 4 depends on the control flag.

The insidious part is that this often produces no visible symptom. On a `required` line it may fail every login, which you will notice. On an `optional` line it does nothing at all, silently, and the administrator believes limits are being applied.

Check before you write:

```
$ objdump -T /usr/lib64/security/pam_limits.so | grep pam_sm_
```

### Policy in `auth` that belongs in `account`

```
auth  required  pam_time.so
```

`pam_time` does implement an account function and will not implement an auth one, so this specific line fails loudly. But the general error, expressing "may this account be used" as an authentication condition, is common with `pam_succeed_if`, which implements several groups and will happily run wherever you put it.

The consequences are real. A restriction placed in `auth` is skipped entirely for SSH key logins. Placed in `account`, it applies to them. If you have a time-of-day restriction or a group restriction that must cover all login paths, `account` is the only place it works.

This is worth stating as a rule: **access restrictions belong in `account`, not `auth`, because `auth` is skippable and `account` is not.**

### Session setup in `auth`

Less common, and usually caught immediately because the module does not implement the function.

### An empty stack

Subtle, and worth an experiment. What happens when a service file has no lines of a given type at all, and the application calls that stack?

The framework has nothing to evaluate. It does not treat this as permissive. It logs something along the lines of "no modules loaded for `account' service" and returns an error, which the application will usually surface as a failure.

Verify it yourself rather than taking the paragraph on faith, because this is exactly the kind of behaviour that has varied across versions:

```
# cat > /etc/pam.d/emptytest <<'EOF'
auth  required  pam_permit.so
EOF
$ pamtester emptytest "$USER" authenticate     # should pass
$ pamtester emptytest "$USER" acct_mgmt        # account stack is empty — what happens?
```

The practical upshot: when you write a service file by hand, write all four stacks, even if some of them are a single `pam_permit.so` line with a comment explaining why. An omitted stack is not a neutral stack.

---

## 3.9 Diagnostic Patterns

The four groups give you a fast triage procedure, because the log annotation names the stack.

Every well-behaved module logs in the form `module(service:type)`:

```
sshd[3312]: pam_unix(sshd:auth): authentication failure; ... user=parsa
sshd[3312]: pam_access(sshd:account): access denied for user `parsa' from `203.0.113.9'
passwd[4410]: pam_pwquality(passwd:password): The password fails the dictionary check
sshd[3312]: pam_unix(sshd:session): session opened for user parsa
```

Read the parenthesis first. It tells you the service and the group, and the group tells you which stack to open and which half of this chapter applies.

| Annotation | What was being decided | Where to look |
|---|---|---|
| `(service:auth)` | Credential verification | The `auth` stack; Chapter 6 |
| `(service:account)` | Whether the account may be used | The `account` stack; Chapter 8 |
| `(service:password)` | A token change | The `password` stack; Chapter 7 |
| `(service:session)` | Session setup or teardown | The `session` stack; Chapter 9 |

And the triage question that comes from this chapter specifically: **does the observed failure match the group that reported it?** A password rejection reported from `account` means the module is in the wrong stack or is being used for the wrong purpose. A "session opened" line for a login you believe failed means the failure happened after PAM finished, in the application.

One more pattern. If you see a module log twice with `(service:auth)`, count before assuming duplication. Once for `pam_authenticate`, once for `pam_setcred`. Three times, and one of them is at logout, is `PAM_DELETE_CRED`.

---

## 3.10 One Module, Four Groups: `pam_unix`

The best way to make the decomposition concrete is to watch a single module do four different jobs. `pam_unix` implements all six functions, appears in all four stacks on nearly every system, and does something genuinely different in each.

```
$ objdump -T /usr/lib64/security/pam_unix.so | grep -o 'pam_sm_[a-z_]*' | sort
pam_sm_acct_mgmt
pam_sm_authenticate
pam_sm_chauthtok
pam_sm_close_session
pam_sm_open_session
pam_sm_setcred
```

All six. Now take them one group at a time.

### In `auth`

```
auth  required  pam_unix.so  try_first_pass
```

`pam_sm_authenticate` obtains the password, either from `PAM_AUTHTOK` if an earlier module stored one and `try_first_pass` is set, or by prompting through the conversation function. It looks up the stored hash, calls into libcrypt with the stored value as the salt, compares, and returns `PAM_SUCCESS` or `PAM_AUTH_ERR`.

If the process cannot read `/etc/shadow` directly, it invokes the setgid helper from Chapter 1 rather than failing.

`pam_sm_setcred` in this module does essentially nothing and returns success. There is no Unix credential to issue beyond the UID the application is about to assume. This is worth knowing because it means the second traversal of the `auth` stack is, on a plain local-password system, almost a no-op, and the log lines it produces are noise.

### In `account`

```
account  required  pam_unix.so
```

`pam_sm_acct_mgmt` reads the shadow file's aging fields. Not the hash: the dates.

It checks whether the account expiry date has passed, in which case `PAM_ACCT_EXPIRED`. It checks whether the password has exceeded its maximum age plus the inactive window, in which case the account is dead in a different way. And it checks whether the password has simply exceeded its maximum age, in which case `PAM_NEW_AUTHTOK_REQD` and the handoff from 3.3 begins.

Nothing here involves a password being typed. The user could have authenticated by SSH key and this stack still runs and still enforces aging, which is exactly the property that makes `account` the right place for restrictions.

### In `password`

```
password  required  pam_unix.so  use_authtok sha512 shadow
```

`pam_sm_chauthtok` runs twice, per 3.4.

In the preliminary pass it verifies that a change is possible: that the caller is permitted, that the old token is available or that `pam_rootok` earlier in the stack made that unnecessary, that the password database is not locked.

In the update pass it takes the new token, hashes it with the configured algorithm, writes the shadow entry, and updates the aging fields. With `use_authtok` it takes that token from `PAM_AUTHTOK`; without, it prompts for its own, which is the silent-failure case from 3.4.

Its arguments here also select the hash: `sha512`, `yescrypt`, `rounds=`. Changing your system's hash algorithm is a change to this line, in this stack, and nowhere else.

### In `session`

```
session  required  pam_unix.so
```

`pam_sm_open_session` and `pam_sm_close_session` do the least interesting work of the six: they log. `session opened for user parsa` and `session closed for user parsa` come from here.

That is genuinely all. And yet those two lines are among the most useful in the whole log, because they bracket a login in time and they carry the service annotation. Chapter 11 uses them as the anchor for correlating everything else.

### The point

Four stacks, four jobs, one shared object, one manual page. When you read `man 8 pam_unix`, the arguments are documented together and it is not obvious which apply to which group. Now it is: `nullok` and `try_first_pass` are `auth` concerns, `sha512` and `remember` are `password` concerns, `broken_shadow` affects `account`, and `session` takes essentially nothing.

Most module manual pages are organised this way. Reading them with the four groups in mind is the difference between a page that seems like a jumble of options and one that is straightforwardly structured.

---

## 3.11 Verification

Test machine, snapshot, second root shell.

**1. Map your system's stack usage.**

Run the counting loop from 3.6. Identify the service with the longest `session` stack, the one with the longest `auth` stack, and any service that has lines in only one group. Explain each.

**2. Determine which groups each module can serve.**

```
$ for m in /usr/lib64/security/pam_{unix,limits,rootok,access,pwquality,systemd}.so; do
      echo "== $(basename $m)"
      objdump -T "$m" 2>/dev/null | grep -o 'pam_sm_[a-z_]*' | sort -u
  done
```

Predict each result before running it.

**3. Observe the double traversal of the `auth` stack.**

Add `debug` to a `pam_unix` line in `/etc/pam.d/su`, then `su` to another user with `journalctl -f -t su` running. Count the invocations and match each to `pam_authenticate` or `pam_setcred`.

**4. Produce an `account` denial and read the annotation.**

Add a temporary rule to `/etc/security/access.conf` denying your own user, ensure `pam_access` is in the `account` stack of a service you can safely test, and observe the difference between what the application reports and what PAM logs.

> ⚠ Do this on `su`, not on `sshd` or `login`. Remove the rule immediately afterwards.

**5. Break `use_authtok` and observe the silent failure.**

On a test account, configure the `password` stack with `pam_pwquality` followed by `pam_unix` *without* `use_authtok`. Change the password and count the prompts. Then set a password that violates your quality policy and confirm it is accepted. Restore `use_authtok` and repeat.

This exercise is the most important one in the chapter. A policy that appears to be enforced and is not is worse than no policy, because it produces confident, wrong answers to audit questions.

**6. Observe the two-phase password change.**

Add `debug` to both modules in a test `password` stack and change a password. You should see each module invoked twice. Identify which invocation is the preliminary check.

**7. Put a module in the wrong stack.**

Add `auth required pam_limits.so` to `/etc/pam.d/su`. Attempt `su`. Read the log. Then change `required` to `optional` and repeat. Explain the difference using Chapter 2's faulty-module behaviour.

**8. Test the empty stack.**

Run the `emptytest` experiment from 3.8. Record the actual behaviour of your Linux-PAM version, since this is version-sensitive.

**9. Confirm that `account` covers key-based SSH and `auth` does not.**

Place a restriction in the `account` stack of `sshd` that will deny you, and confirm it applies to a key-based login. Then move the same restriction to `auth` and confirm it does not.

> ⚠ This one genuinely can lock you out of SSH. Second root shell, and a console you can reach.

**10. Find the session leaks.**

```
$ loginctl list-sessions
$ loginctl session-status <id>
```

Are there sessions with no processes, or with a state that does not match reality? Correlate against `journalctl -t systemd-logind`. Explain them using 3.5.

**11. Compare the four notions of session.**

In one terminal, run the four commands from 3.5's "Four things called session." Then start `tmux`, detach, log out, log back in, and run them again. Which of the four now disagree, and why? Check `KillUserProcesses` in `/etc/systemd/logind.conf` before you predict the answer.

**12. Audit `pam_loginuid` coverage.**

```
$ grep -L pam_loginuid $(grep -l 'session' /etc/pam.d/*)
```

For each service in the result that can give someone a shell, decide whether actions taken through it would be attributable to a human in the audit log. This is a real finding on more systems than it should be.

**13. Read one module manual page four times.**

Open `man 8 pam_unix` and, using 3.10, sort every documented argument into the group it belongs to. Any argument you cannot place is one to look up properly. Repeat with `man 8 pam_succeed_if`, which implements several groups and whose arguments behave differently in each.

---

## Where This Goes Next

You now know what each group is for, which calls traverse which stack, and what state carries between them. What you still cannot do is say what a stack *decides*, given several modules each returning a value.

That is Chapter 4, and it is the chapter everything up to now has been preparing for. It supplies the evaluation algorithm, the full return-value and action vocabulary, and the definitions of the four control keywords in terms of the underlying bracketed syntax. After it, the three-line `common-auth` file you have now looked at in three separate chapters will finally be something you can reason about rather than recognise.

Two things from this chapter feed directly into it. First, the return values in the four tables above are the left-hand side of every bracketed control expression, so knowing which module produces which value is what makes those expressions writable. Second, `PAM_IGNORE` behaves unlike every other return value in the evaluation algorithm, and 3.2 is where you met it.

---

## Further Reading for This Chapter

- `man 3 pam_authenticate`, `man 3 pam_setcred`, `man 3 pam_acct_mgmt`, `man 3 pam_chauthtok`, `man 3 pam_open_session`, `man 3 pam_close_session`
- `man 3 pam_get_item` and `man 3 pam_set_item` for the item table
- `man 3 pam_set_data` and `man 3 pam_get_data` for module-private state
- `man 3 pam_sm_authenticate` and siblings, for the module side of each group
- `man 5 logind.conf`, particularly `KillUserProcesses`, for the session lifetime material in 3.5
- `man 8 loginctl`
- The Linux-PAM Module Writers' Guide, which documents the return values of each group more completely than any manual page
