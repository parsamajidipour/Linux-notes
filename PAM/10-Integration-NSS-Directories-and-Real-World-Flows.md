# 10 — Integration: NSS, Directories, and Real-World Flows

Every chapter from 6 through 9 has been building stacks using `pam_unix` and locally stored credentials, with repeated forward references to "directory-backed accounts," "SSSD," and "the SSH-key-bypass" that the series will "handle in Chapter 10." This is that chapter.

Four things happen here. First, NSS — the name service switch — gets the treatment it has deserved since Chapter 1's mention and Chapter 2's diagnostic table both put `getent passwd <user>` before anything in `/etc/pam.d/` as the first troubleshooting step: a full explanation of what NSS is, what it is not, and why its boundary with PAM is the single most productive distinction to hold for diagnosing login problems. Second, the directory-backed modules — `pam_sss`, `pam_krb5`, and the LDAP layer underneath — get their module-reference treatment, structured the same way Chapters 6 through 9 structured the local modules. Third, multi-factor authentication modules get placed correctly, which requires understanding both what they do and which stack traversals they actually affect versus which ones they silently miss. Fourth, four complete service traces — `sshd`, `sudo`, `su`, and `runuser` — bring every group from every preceding chapter together in the way Chapter 1's shallow `su` trace first promised.

### A short scenario, to set the frame

An infrastructure team migrates from local accounts to Active Directory-backed authentication via SSSD, following all the documented steps: SSSD configured and joined to the domain, `nsswitch.conf` updated, `authselect select sssd` run on every host. Testing on a staging server is clean — directory users log in, groups resolve, everything works. Two weeks after production rollout, a P1 ticket arrives: nobody can log in to one production server, and the error message is simply "Authentication failure."

The investigation that follows takes longer than it should because it begins with PAM. The PAM configuration on the affected server is identical to staging. The `authselect` profile is the same. The `/etc/pam.d/` files are bit-for-bit identical. Only twenty minutes later does someone run `getent passwd <user>` directly on the affected server — and gets nothing back. `systemctl status sssd` shows SSSD running, but `sssctl domain-status AD` shows the domain as offline. The server's hostname was added to a DNS suffix list that resolved correctly on staging but not in production, and SSSD could not locate the domain controller. NSS was returning nothing; PAM never had a chance to fail or succeed; twenty minutes were spent looking in the wrong half of the system.

The two-command discipline from 10.1 would have resolved this in thirty seconds.

---

## 10.1 NSS: The Boundary That Most PAM Diagnoses Miss

### The one sentence that saves the most time

**NSS answers "who is this user and what are their attributes." PAM answers "may this user authenticate and proceed."** They are separate subsystems, configured in different files, and either one can be broken while the other works perfectly.

This is a sentence worth repeating to yourself at the start of every login troubleshooting session, because the most common time-wasting pattern in this domain is spending twenty minutes editing `/etc/pam.d/` on a problem that `getent passwd <user>` would have resolved in one second.

### What NSS is

The Name Service Switch (`/etc/nsswitch.conf`) is the lookup infrastructure that maps a username to a UID, a UID to a username, a group name to a GID, and so on — everything `getpwnam()`, `getgrgid()`, and their relatives return. The switch part: for each database (`passwd`, `group`, `shadow`, `hosts`, etc.), the configuration file lists sources in order, and the lookup tries each source until one answers.

```
$ cat /etc/nsswitch.conf
passwd:         files sss
group:          files sss
shadow:         files sss
```

`files` is `/etc/passwd`, `/etc/group`, `/etc/shadow`. `sss` is SSSD. `ldap` would be direct LDAP. `compat` is a historical NIS-adjacent mode. The list for `passwd` is what determines whether `getpwnam("parsa")` can even find the user at all — before PAM is ever consulted.

### The diagnostic that comes first

```
$ getent passwd parsa
$ getent shadow parsa    # as root
$ getent group developers
```

If `getent passwd` returns nothing, the user does not exist as far as the system is concerned. PAM cannot authenticate a user it cannot find; `pam_unix` will return `PAM_USER_UNKNOWN`, and the login will fail. This failure is a NSS problem, not a PAM problem, and the correct diagnostic is:

1. Is the appropriate NSS source listed for `passwd` in `nsswitch.conf`?
2. Is that source available and responding? (`sssd` running? LDAP reachable?)
3. Is the account actually present in that source?

None of those questions have anything to do with `/etc/pam.d/`, and editing PAM configuration to address them accomplishes nothing.

Conversely, if `getent passwd parsa` returns a valid entry and the login still fails, PAM is involved, and Chapter 4's module-level diagnosis applies.

### NSS lookup mechanics

Worth going one level deeper than the `nsswitch.conf` line, because the "each source tried in order until one answers" description obscures some important details about what "answers" means.

Each source is tried until one returns a definitive result. A definitive result includes both a hit (`NOTFOUND` is not a definitive failure in this context for all configurations) and a negative ("this user definitely does not exist in this source") — the difference matters when sources are layered. The `[SUCCESS=return NOTFOUND=continue]` style annotations in `nsswitch.conf` allow fine-grained control over which results cause a stop and which cause a fallthrough, using the same bracketed-expression logic as Chapter 4's PAM control flags, for exactly the same reason: distinguishing "no match" from "definitive refusal."

```
passwd: files [SUCCESS=return NOTFOUND=continue] sss
```

This says: check local files first; if found, stop; if not found in files, continue to SSSD. The default without annotations is generally equivalent on most configurations, but explicit annotations become valuable when the two sources might have conflicting entries for the same username — a situation to avoid by convention but worth handling explicitly in environments that cannot guarantee uniqueness.

`strace` on a login process is the most direct way to see what NSS actually does:

```
$ strace -f -e trace=openat,connect su - parsa 2>&1 | grep -E 'sssd|passwd|shadow|nss'
```

You will see the `nsswitch.conf` being read, the `libnss_*.so` modules being loaded, and the socket connections to SSSD or other network sources. This is substantially more informative than reading `nsswitch.conf` alone, particularly when the question is "why is SSSD not being consulted even though it is listed."

### The specific case of `compat` and `ldap` sources

Two NSS sources deserve mention alongside `files` and `sss` because they appear in older documentation and occasionally in inherited configurations: `compat` and `ldap`.

`compat` is a legacy NIS-compatible format that extends `files` with `+` and `-` tokens for NIS map inclusion. On most current deployments it means the same as `files`, with some old NIS integration syntax that modern systems ignore. Seeing `passwd: compat` on a modern system typically indicates an old configuration file that was never updated; it usually works but may surprise administrators expecting standard `files` behaviour. Worth replacing with `files` explicitly if the system has no actual NIS dependency.

`ldap` — `libnss-ldap` or `nss-pam-ldapd` — is the direct-LDAP NSS backend, predating SSSD. It is still deployed, less common than SSSD on new systems, and has the notable characteristic of performing an LDAP lookup on virtually every user-attribute lookup on the system — every `ls -l`, every shell `ps`, every `id` call for a directory-backed account triggers an LDAP lookup. This has performance implications under load and availability implications when the directory is down, since `getent passwd` for a directory user will block until the LDAP timeout expires. SSSD's caching layer eliminates this problem, which is one of the primary reasons SSSD displaced `libnss-ldap` in modern deployments.

Understanding which NSS backend is in use matters for PAM integration because the fallback behaviour differs: `libnss-ldap` with a down directory will typically time out, whereas SSSD with a down directory will serve from cache or fail fast, depending on cache configuration. A PAM stack tuned for SSSD's fast-fail `PAM_AUTHINFO_UNAVAIL` behaviour may behave very differently with `libnss-ldap` underneath, where the "unavailable" signal arrives after a configurable timeout that defaults to something the user will experience as a hang.



`pam_unix`'s `auth` role reads the hash directly from the shadow file — or delegates to `unix_chkpwd` if it cannot — rather than going through NSS's `shadow` lookup. For directory-backed accounts where `pam_sss` or `pam_krb5` is doing the authentication, PAM reads from the directory rather than local shadow, and the NSS `shadow` entry for that user is either absent or a placeholder. Chapter 6's `pam_unix` section was deliberately careful not to overclaim here: the distinction between "NSS resolves the account" and "PAM verifies the credential" is exactly the one this section is drawing, and the two can involve completely different backend systems.

A user whose NSS `passwd` entry comes from SSSD but whose PAM credential check is handled by `pam_unix` against a local shadow entry is a configuration that can exist but typically represents a misconfiguration or a migration state — worth being aware of as a possibility when the diagnosis shows "SSSD returning user attributes, but `pam_unix` rejecting the password," since the two are pulling from different sources that may disagree.

### The two-command discipline

Before touching any PAM configuration in a login troubleshooting session:

```
$ getent passwd <user>              # resolves?
$ pamtester <service> <user> authenticate   # then PAM error?
```

If the first command fails, stop there. The second command is irrelevant until the user resolves. This two-step sequence, applied consistently, is probably the single highest-value diagnostic practice this entire series contains, and yet it is the step most commonly skipped — partly because editors reach for configuration files before diagnostic tools, and partly because the failure message from a failed login (incorrect password, connection closed, access denied) gives no obvious signal as to which half of the system produced it. The two-command discipline eliminates that ambiguity in about five seconds.

---

## 10.2 `pam_sss`

### What it does

Delegates authentication, account checks, password changes, and session setup to SSSD — the System Security Services Daemon — which in turn communicates with one or more configured identity providers: Active Directory, FreeIPA, LDAP, or Kerberos.

### Which groups it serves

All four, with entry points for each, making it the closest directory-backed equivalent to `pam_unix` in terms of scope.

### Why SSSD rather than direct LDAP

A reasonable question, since `pam_ldap` exists and predates SSSD. SSSD addresses several problems that direct LDAP access from every PAM invocation creates:

**Caching.** SSSD caches recent authentication results and user attributes, so an LDAP or Kerberos outage does not immediately lock every user out, as long as they have authenticated recently. The cache lifetime is configurable, and the off-network behaviour — whether cached credentials suffice, and for how long — is one of the most operationally significant things to know about an SSSD configuration:

```
$ sssctl user-checks <username>
$ sssctl cache-expire -u <username>
$ sssctl cache-remove
```

**A single connection.** Rather than every PAM invocation opening its own LDAP connection, SSSD maintains a persistent connection pool, dramatically reducing the load on the directory server from a busy authentication host.

**Separation of mechanisms.** PAM talks to SSSD over a local socket; SSSD talks to the directory. This means PAM's interaction with the directory is isolated to one process, which can be monitored, restarted, and debugged independently.

### Arguments

`pam_sss` itself is deliberately thin — the actual policy configuration lives in `/etc/sssd/sssd.conf` rather than in module-line arguments, following the same principle as `authselect`-generated stacks on RHEL: the PAM module is a shim, and the behaviour is configured elsewhere.

`forward_pass` — after a successful authentication, make the credential available to subsequent modules via `PAM_AUTHTOK`, enabling chained authentication with other mechanisms in the same stack.

`use_first_pass` and `try_first_pass` — the same token-reuse semantics from Chapter 6, applied here to the directory-backed credential.

`retry=N` — attempt count before permanent failure.

### Return values

`PAM_SUCCESS` on authentication success; `PAM_AUTH_ERR` on credential failure; `PAM_AUTHINFO_UNAVAIL` when SSSD is unreachable or the directory cannot be contacted — this last value is the one Chapter 4's trace 5 was built around, and it is the specific value to target in a `[authinfo_unavail=ignore]` fallback rule if local credentials should survive a directory outage.

### Interactions

With `/etc/sssd/sssd.conf`, which determines the actual behaviour far more than the PAM module's own arguments do. With `pam_unix` in the same stack via the routing idioms from Chapter 4's RHEL traces — `pam_localuser` or `pam_succeed_if` routing local users through `pam_unix` and directory users through `pam_sss`, per 8.6b's routing table from Chapter 8.

### The SSSD provider architecture

Worth understanding briefly, because it explains why `pam_sss`'s own manual page is so thin: the module is genuinely a thin client, and the intelligence lives elsewhere.

SSSD is structured as a set of providers. Each domain in `sssd.conf` has an `id_provider` (which backend handles user and group lookups — the NSS side), an `auth_provider` (which backend handles credential verification), and optionally an `access_provider` (which backend handles access control beyond what PAM itself already provides). These can be the same backend or different ones:

```
[domain/example.com]
id_provider = ldap            # NSS attributes come from LDAP
auth_provider = krb5          # credentials verified via Kerberos
access_provider = ldap        # access control via LDAP group membership
```

This configuration is common in Active Directory environments: LDAP provides the user attributes (UID, GID, home directory, etc.) that NSS needs, while Kerberos handles the actual credential verification, and LDAP provides group-based access control. The PAM layer sees only `pam_sss`, which serialises all of this through SSSD's PAM responder; the three-provider split is entirely inside SSSD and invisible to PAM. When a login fails on this configuration, the failure may originate in the LDAP provider (account not found), the Kerberos provider (wrong password), or the access provider (not in the allowed group) — and diagnosing which one requires SSSD's own logs, not PAM's, per this chapter's debugging discussion in 10.2.

### Failure modes

SSSD not running:

```
$ systemctl status sssd
$ journalctl -u sssd -n 50
```

Cache stale or corrupted, causing users to fail even when the directory is reachable:

```
$ sssctl user-checks <username>
```

The `pam_authinfo_unavail` case handled as `die` rather than `ignore`, causing a directory outage to lock out all directory-backed users immediately — a configuration decision with major operational consequences worth stating explicitly and testing against a simulated outage before relying on it:

```
$ systemctl stop sssd
$ pamtester sshd <directory-user> authenticate
```

### Reading SSSD's own logs

When `pam_sss` produces unexpected results and the PAM logs provide little detail — which is common, because the actual directory interaction happens in the SSSD daemon process rather than in the PAM module itself — SSSD's own debug logging is the right place to look. Enable it temporarily at a high level:

```
$ sssctl debug-level 7
```

or, for persistent logging through `sssd.conf`:

```
[domain/example]
debug_level = 7
```

then watch `/var/log/sssd/sssd_<domain>.log` during a failed authentication. The log at level 7 includes the full authentication exchange — what was sent to the directory, what came back, and at which point SSSD decided to return `PAM_AUTH_ERR` versus `PAM_AUTHINFO_UNAVAIL` — which is substantially more diagnostic than the PAM log alone. The two logs together, PAM's `(service:auth)` annotation telling you what `pam_sss` returned, and SSSD's own log telling you why it decided to return that, cover essentially every failure mode this module can produce.

One more diagnostic worth knowing: `sssctl user-checks <username>` performs a simulated authentication check through SSSD's own evaluation path, completely independently of PAM, and reports what SSSD would return for that user. If this command reports success but PAM still fails, the problem is between SSSD and PAM — likely in the socket communication or in the module arguments — not in SSSD's own logic.

---

## 10.3 `pam_krb5`

### What it does

Authenticates against a Kerberos KDC directly, without SSSD as an intermediary, and can obtain a ticket-granting ticket as part of the `auth`-stack's `setcred` pass per Chapter 3's discussion of the second traversal.

### Which groups it serves

`auth` and, to a limited degree, `session` for the credential-establishment role.

### Kerberos authentication flow, briefly

Rather than checking a password against a locally stored hash, `pam_krb5` encrypts a timestamp with the key derived from the user's password and sends it to the KDC; if the KDC can decrypt it, the password was correct, and it issues a TGT. The significant difference from `pam_unix`: **the password is never directly compared to anything stored locally**, and **a correct password against the KDC does not require a local shadow entry**. This changes the NSS/PAM boundary picture somewhat — an account must still resolve via NSS (`getent passwd <user>` must succeed) for a login to complete, but the shadow entry is irrelevant to Kerberos authentication.

The ticket-granting ticket obtained here is what `pam_setcred(PAM_ESTABLISH_CRED)` in the second `auth`-stack traversal actually manages — storing it in the credential cache for the session to use for subsequent service access. This is the mechanism behind single-sign-on: a user who authenticates via Kerberos at login has a ticket that authorises them to access other Kerberos-protected services without further credential prompts, provided those services are configured to accept Kerberos and the ticket's lifetime has not expired.

### Arguments

`minimum_uid=` — skip users below this UID, avoiding trying to authenticate system accounts against the KDC. This argument is also the reason Chapter 4's Kerberos-enabled `common-auth` stack had `success=2` rather than `success=1` — the UID filter means this module declines for some users via `PAM_IGNORE`, and the jump arithmetic needs to account for that specific return value appearing in the flow.

`ccache_dir=`, `ccache_type=` — where to put the resulting ticket cache, typically `/tmp/krb5cc_<uid>` or a session-scoped path under `/run/user/<uid>/`, the latter preferred for security (scoped to a logind session, cleaned up on session close per Chapter 9's `pam_systemd` discussion) but requiring that `pam_systemd` has already run and set `XDG_RUNTIME_DIR` before this module's `pam_setcred` pass — yet another session-stack ordering consideration of the kind Chapter 9 covered generally.

`debug`, the usual.

### Diagnosing Kerberos-specific failures

Kerberos failures produce distinctive errors that PAM's own log does not always capture fully, since the error detail lives in the Kerberos library:

```
$ kinit parsa@EXAMPLE.COM        # try the KDC directly, bypassing PAM
$ klist                           # confirm the TGT was obtained
$ kdestroy                        # clean up
```

If `kinit` succeeds and PAM authentication still fails for the same user, the problem is in how `pam_krb5` is configured — wrong `minimum_uid`, wrong realm, wrong ccache path — rather than in Kerberos itself. If `kinit` also fails, the problem is Kerberos or network-level: KDC unreachable, clock skew (Kerberos requires clocks within 5 minutes by default), or account not present in the KDC's database. The two-tool discipline from 10.1 applies here in the same form: bypass the layer under investigation before concluding the configuration is the problem.

### Return values

`PAM_SUCCESS` on successful KDC exchange; `PAM_AUTH_ERR` on failed authentication; `PAM_AUTHINFO_UNAVAIL` when the KDC is unreachable, matching the Chapter 4 fallback idiom's target value precisely.

### Interactions

With `pam_sss`, which is the modern preferred alternative on most enterprise systems because SSSD can itself handle Kerberos, providing caching and a cleaner separation of concerns. `pam_krb5` sees more use on systems that do not want SSSD for whatever reason, or on systems authenticating against a KDC that SSSD's own provider code does not support cleanly. On a system using both SSSD and direct Kerberos, the two may end up contesting for the same credential cache location, worth checking explicitly rather than assumed harmless.

---

## 10.4 Multi-Factor Authentication Modules

Three modules, one common placement question, one common placement mistake. The modules themselves are relatively simple; the complexity is in where they go and which login paths they actually protect.

The chapter prefix worth stating once before the individual modules: from the `required`/`sufficient` distinction this series established thoroughly in Chapter 4, the most common second-factor misconfiguration is exactly as simple as it sounds — `sufficient` on the password module, followed by `required` on the second-factor module, means the second factor is enforced only when the password fails, which is backwards from what anyone intends. Chapter 4's trace 7 built this out explicitly, and the reminder here is deliberate: a second-factor module set up incorrectly is not merely ineffective, it can be actively misleading in a security posture review, since the module is present and running and producing log entries, none of which signals to a reviewer that it is functioning as a bypass rather than an enforcing layer.

### `pam_google_authenticator`

A TOTP/HOTP second factor, using the same algorithm as Google Authenticator, FreeOTP, and most other standards-based authenticator apps. The user enrols with `google-authenticator` (the tool shipped alongside the module), which creates a per-user secret file, conventionally in `~/.google_authenticator`. At login time the module prompts for the six-digit code.

Stack placement, correctly:

```
auth  required  pam_google_authenticator.so
auth  required  pam_unix.so
```

Both lines `required`, and the second-factor line *first* — meaning a failed TOTP check records a failure immediately, and the subsequent `pam_unix` password check, if it succeeds, cannot undo it. "Required" means "and," and both factors must succeed in a single attempt for the stack to produce success. There is no value in putting the TOTP check first versus second when both are `required`, but the convention of second-factor first keeps the policy ordering legible: the unusual condition (token) is checked before the standard one (password), which tends to produce slightly more useful error messages when only one factor fails.

Stack placement, incorrectly but commonly:

```
auth  sufficient  pam_unix.so
auth  required    pam_google_authenticator.so
```

The second form, covered as trace 7 in Chapter 4, means a correct password alone satisfies the `sufficient` line and terminates the stack successfully without ever reaching the second factor. `required` on both, in the order shown in the first example, is a genuine "and" requirement: both password and token must succeed.

### `pam_u2f`

FIDO/U2F hardware token support — YubiKeys and similar devices. The user enrols the device with `pamu2fcfg`, which records the device's credential in a file the module checks at authentication time:

```
$ pamu2fcfg -u parsa >> /etc/u2f_mappings    # system-wide mapping file
# or
$ pamu2fcfg -u parsa >> ~/.config/Yubico/u2f_keys    # per-user
```

From a stack-configuration standpoint, it is placed identically to `pam_google_authenticator`, with the same `required`/`sufficient` distinction applying. The physical difference is that U2F requires touching the hardware key, which produces a user-presence confirmation the TOTP code does not — a meaningful security property against remote credential reuse, but also a meaningful limitation for any environment where users cannot reliably reach their hardware key during a login (server access without a USB device present, for instance).

### `pam_yubico`

Yubikey OTP validation, using either local validation or the Yubico cloud service. Broadly similar in stack placement to the preceding two; the specific difference worth noting is that YubiKey OTP validation by default contacts an external service, which introduces a network dependency and potential latency during authentication that the purely local TOTP module does not have. For an air-gapped environment or one with strict network controls, `pam_yubico`'s offline validation mode — using a local challenge-response configuration rather than cloud-based OTP checking — is the alternative worth investigating.

### The SSH-key-bypass, finally complete

Every time this series has mentioned "the SSH-key-bypass concern" since Chapter 1, it has been deferring to this chapter. Here, with all four management groups and their module-level detail now covered, is the complete, precise statement:

SSH public-key authentication bypasses the `auth` stack entirely. `pam_authenticate()` is not called. The second-factor modules above live in `auth`. **A second factor added only to the `auth` stack provides zero protection against SSH key-based logins.**

The correct placement for a second factor that must protect key-based logins is the `account` stack, which SSH always traverses regardless of authentication method, per Chapter 3's canonical service-call table:

```
account  required  pam_google_authenticator.so
```

But this creates its own problem: the TOTP prompt in the `account` stack fires even for users who have not enrolled, which breaks logins for those users immediately. A graduated rollout needs either a graceful-failure mode in the module (if supported by the specific version — check the current module's manual page for a `nullok` or equivalent option), or an explicit per-user or per-group carve-out:

```
account  [success=ok default=ignore]  pam_succeed_if.so  user in enrolled-users-group
account  required                     pam_google_authenticator.so
account  required                     pam_unix.so
```

Where `enrolled-users-group` contains only users who have completed enrolment, this stack enforces the second factor for enrolled users and silently skips it for everyone else — a staged rollout path that does not require touching individual accounts, only group membership.

The complementary point for SSH-specific configuration: `sshd_config`'s `AuthenticationMethods` directive can require that both public-key authentication and keyboard-interactive succeed before a login completes, making the keyboard-interactive channel available for a second-factor prompt even alongside key-based auth, without needing to move the second-factor module to the `account` stack at all:

```
AuthenticationMethods publickey,keyboard-interactive
```

This is the `sshd`-side answer to the same problem; the PAM-side and `sshd`-side approaches are not mutually exclusive, and in a high-security environment both are worth considering. The `sshd_config` approach limits second-factor bypass to the `sshd` service specifically; the `account`-stack approach applies across all services, including `sudo` and anything else traversing the same stack.

### MFA and `sudo`

Worth naming explicitly since it is a common gap: a second factor placed in `/etc/pam.d/sshd` does not protect `sudo`, and vice versa. If the threat model includes an attacker with a stolen password using it for privilege escalation rather than direct SSH access, the second factor must be in `/etc/pam.d/sudo` or the aggregation file it includes — specifically, and separately from wherever it was placed for SSH. Running `pamtester sudo "$USER" authenticate` with a missing or failed second-factor condition is the five-second check that confirms whether it is actually enforced for this path.

---

## 10.5 Four Service Traces

The full traces promised in Chapter 1. Each covers all four management groups, the full sequence of application calls from Chapter 3's canonical table, and the specific modules that run in each group on a representative distribution stack. Stack contents are representative rather than canonical — the exact modules present depend on distribution, version, and configuration. The goal is the shape, not the exact set of lines.

### Trace 1: `sshd`, password authentication

User authenticates with a password over SSH to a RHEL-family system with SSSD configured and `pam_faillock` enabled.

**Application: `sshd`** calls `pam_start("sshd", ...)`, sets `PAM_RHOST` to the client IP and `PAM_TTY` to the pseudo-terminal, calls the four stacks in canonical order per Chapter 3's sequence table.

**`auth` stack:**
1. `pam_env.so` — loads environment from `/etc/environment` and distribution-specific additions
2. `pam_faillock.so preauth` — checks whether the account is currently locked; returns failure here if so, recording it as `required`, and the rest of the auth stack executes but the outcome is already determined
3. `pam_succeed_if.so uid >= 1000` and `pam_localuser.so` — routing: local users jump to `pam_unix`, directory users jump to `pam_sss`, per Chapter 4's trace 4
4. `pam_unix.so` (for local users) or `pam_sss.so` (for directory users) — credential check, via the mechanism specific to each: hash comparison against shadow for local, directory exchange for directory-backed
5. `pam_faillock.so authfail` — records failure if the credential check failed; this line is reachable because the credential-check lines use `sufficient`-equivalent control flags per Chapter 8's ordering dependency discussion
6. `pam_deny.so` — final terminator, reached only if nothing above produced a success

The annotated log lines look like this for a successful local password login:

```
pam_env(sshd:auth): environment variable(s) read
pam_faillock(sshd:auth): user not locked
pam_unix(sshd:auth): authentication success; logname= uid=0 euid=0 tty=ssh ruser= rhost=10.0.1.5 user=parsa
```

And for a failed directory-backed login:

```
pam_faillock(sshd:auth): user not locked
pam_sss(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=10.0.1.5 user=parsa
pam_faillock(sshd:auth): Consecutive login failures for user parsa
```

Reading these alongside the service trace is the exercise that makes the annotation format, referenced throughout this series since Chapter 3, fully concrete.

**`account` stack:**
1. `pam_faillock.so` — checks lockout state, the line Chapter 8's opening scenario showed mattering specifically for key-based logins
2. `pam_succeed_if.so uid >= 1000` routing, then `pam_unix.so` for aging/expiry checking per Chapter 8's `pam_unix` account-role section
3. `pam_sss.so` for directory account validity checks — group membership, account status flags in the directory, anything the directory knows about this account that goes beyond the PAM credential

**`pam_setcred(PAM_ESTABLISH_CRED)`:** re-traverses the `auth` stack for credential issuance, calling `pam_sm_setcred()` in each module per Chapter 3's discussion. For `pam_sss`, this may establish a Kerberos TGT if the SSSD domain is configured with Kerberos as the authentication backend, separate from LDAP. For `pam_unix`, this is essentially a no-op.

**`session` stack:**
1. `pam_selinux.so close` — SELinux context, pre-open pass (on SELinux-enabled systems)
2. `pam_loginuid.so` — sets audit identity; this fires exactly once per login, per Chapter 9's immutability discussion
3. `pam_systemd.so` — registers session with logind, allocates cgroup scope, sets `XDG_RUNTIME_DIR`
4. `pam_limits.so` — applies `limits.conf` to the session; the cgroup-based limits from systemd's user slice are a parallel mechanism, not the same one
5. `pam_env.so` — loads session environment from `pam_env.conf` and `/etc/environment`
6. `pam_motd.so`, `pam_mail.so` — informational only, typically `optional`
7. `pam_selinux.so open` — SELinux context, post-open pass

The user gets a shell. On exit, `pam_close_session()` and `pam_setcred(PAM_DELETE_CRED)` tear down what was built — logind session destroyed, cgroup scope dissolved, ticket cache cleaned up.

### Trace 2: `sshd`, key-based authentication

Same system, same user, but authenticating with a public key.

The key difference: `sshd` validates the key itself, against `authorized_keys`, *before calling PAM at all* for authentication. When it does call PAM, it passes `PAM_SILENT` on `pam_authenticate()` and — on most configurations — never actually prompts for anything through the conversation function. The `auth` stack nominally runs, but the modules in it that prompt for a credential — `pam_unix`, `pam_sss` — find `PAM_AUTHTOK` empty; they may return `PAM_IGNORE` or handle the missing token in various ways depending on their arguments, but the actual security decision was made outside PAM entirely.

The log tells this story:

```
Accepted publickey for parsa from 10.0.1.5 port 53212 ssh2
pam_loginuid(sshd:session): set loginuid to 1001
pam_systemd(sshd:session): ...
```

Note what is absent: any `(sshd:auth)` lines. The auth stack produced nothing logged, because `sshd` handled authentication before PAM was consulted. The session lines are still there, because session always runs.

`account` and `session` run exactly as trace 1 — this is the entire basis of Chapter 8's "account-stack restrictions apply regardless of auth method" principle. A user locked by `pam_faillock`, denied by `pam_access`, or with an expired account will be refused at the `account` stack, even with a valid key. `pam_faillock`'s `preauth` in `auth` would have checked lockout, but so does the `account`-stack line — that is the redundancy that makes lockout work for both paths.

Second-factor modules placed only in `auth` are skipped entirely by this path. The `account`-stack alternative or `sshd_config`'s `AuthenticationMethods` is required to close the gap.

### Trace 3: `sudo`

User invokes `sudo <command>`.

**Before PAM is called at all:** `sudo` checks its timestamp file. If the file is valid and not expired, `sudo` may skip `pam_authenticate()` entirely and go directly to `pam_acct_mgmt()` and the privilege escalation. This is why "is my second-factor module not running for sudo" is frequently answered by `sudo -k` (invalidating the timestamp) followed by a retry. The second factor does run when there is no valid timestamp — it just appears not to run when there is one.

**`auth` stack:** `sudo`'s service name is `sudo`, and its service file is `/etc/pam.d/sudo`, which may differ from `sshd` in significant ways. On RHEL-family systems, `/etc/pam.d/sudo` typically includes `system-auth`, not `password-auth`, which means changes made only in `password-auth` (for example, adjusting the SSSD profile) do not affect `sudo` authentication — a specific, named gap worth checking if sudo and SSH behave differently on the same user.

**`session`:** `sudo`'s session-stack usage varies by build. The key module to confirm is `pam_loginuid` — when present, it preserves the original loginuid through a `sudo` invocation, so audit logs attribute actions to the original human rather than to root. When absent, the loginuid changes to root (or to whichever target account `sudo` escalates to), and the accountability chain from the original login to the privileged action is broken in the audit log.

### Trace 4: `runuser`

A service script or system tool drops privilege from root to a service account using `runuser`.

**`auth` stack:** `runuser` deliberately does not authenticate. Its service file's `auth` stack is typically a single `pam_rootok.so` line marked `sufficient`, which succeeds immediately if the caller is root — which it always is for `runuser`. No password is ever requested, no second factor applies.

**`account` stack:** This is the part that matters and is occasionally overlooked. `pam_acct_mgmt()` still runs, and the full account-check stack applies: expiry, `pam_access` origin rules, lockout state. A service account with an expired account-level expiry — per Chapter 8's `pam_unix` account-role discussion — will fail here. This is correct and occasionally surprising to administrators who assume `runuser` bypasses these checks because it bypasses authentication.

**`session` stack:** Applies fully. `pam_loginuid` here sets the audit login UID to the *service account*'s UID, not to root — the process now running as the service account should be attributed to that account in the audit log, not to whatever root session started it. Compare with trace 3: `sudo` preserves the human's original loginuid; `runuser` sets a fresh one for the target account. Both behaviours are correct for their respective use cases and follow directly from when and how `pam_loginuid` runs in each service's stack.

---

## 10.6 Trace: `su`, the Full Version

Chapter 1 traced `su` at a shallow level as the first concrete illustration of PAM working at all. Chapter 3 referenced the canonical call sequence. Now that every group has been covered through Chapters 6 through 9, the same trace done properly — the version Chapter 1 promised but deferred.

User runs `su - parsa` from a shell.

**The key difference from `sshd`:** `su` is setuid root, so it starts with effective UID 0 regardless of who invoked it. The original invoking user's identity is the *real* UID. `pam_rootok` checks the real UID; if the caller is already root (real UID 0), the auth stack short-circuits immediately via the `sufficient` flag, and no password is ever requested. For non-root callers, the check fails and the stack continues to the credential check.

**`auth` stack:**

```
auth  sufficient  pam_rootok.so          # root? short-circuit
auth  required    pam_unix.so            # everyone else: password check
```

Plus on distributions with `pam_wheel`, an intermediate line restricting the su attempt to group members before even reaching the password prompt — the group check happens in `auth`, per the `auth`-versus-`account` principle, because this module is genuinely about whether the caller's identity permits the attempt, not whether the target account is usable.

The conversation function here is backed by the terminal the calling user is sitting at — `su` is one of the few programs that explicitly links `libpam_misc` for `misc_conv()` rather than implementing its own, since it is by definition interactive and always has a terminal.

**`account` stack:** Checks whether the *target* account (`parsa`) is usable, not whether the invoking user has permission. Account expiry, password aging, and `pam_nologin` all apply here for the target user — not the caller. This is the correct behaviour and the point that occasionally confuses people who expect `account` to check the caller's privilege level: it checks whether the account being switched into may be used, which is a property of that account, not of whoever is invoking `su`.

**`pam_setcred(PAM_ESTABLISH_CRED)`:** Issues credentials for the target user `parsa`. With Kerberos in the stack, this would obtain a TGT for `parsa`, not for the original caller.

**`session` stack:** Sets up the session as `parsa`:

- `pam_loginuid.so` — sets the loginuid to `parsa`'s UID, replacing whatever was there from the original login. This is the `su` behaviour, contrasted with `sudo`'s behaviour of preserving the original loginuid. Actions taken in a shell obtained via `su - parsa` are attributed in the audit log to `parsa`, not to the human who typed the command — a meaningful difference in environments where auditability is a requirement, and a known, documented consequence of how `pam_loginuid` works in `su`'s stack specifically.
- `pam_limits.so`, `pam_env.so`, and the rest of the session-construction modules set up `parsa`'s environment, not the caller's.

**The `- ` flag matters here:** `su - parsa` (with the dash) invokes `parsa`'s login shell as a login shell, re-running all of `parsa`'s shell startup files and the full PAM session stack. `su parsa` (without the dash) does less: it changes identity but keeps the current environment and shell, and the PAM session stack may not run fully depending on how `su` is built. The difference is visible in `loginctl list-sessions` and in whether `pam_systemd` registers a new session entry.

This trace, read alongside trace 1 and trace 3, makes the service-specific differences visible: each program makes its own choices about which stacks to traverse, in which order, with which flags, and the resulting behaviour for the same PAM stack can legitimately differ between them for reasons that have nothing to do with `/etc/pam.d/`.

## 10.7 The Offline Login Problem

One operational question deserves its own treatment before the hardening checklist, because getting it wrong produces a specific, unhappy user experience: **what happens when a directory-backed user tries to log in and the directory is unreachable?**

The answer depends entirely on two configuration decisions, both covered in earlier chapters but worth bringing together here:

**SSSD caching behaviour** — whether SSSD is configured to serve cached credentials for offline authentication, and how long those credentials remain valid. Configured in `/etc/sssd/sssd.conf`:

```
[domain/example]
cache_credentials = true
offline_credentials_expiration = 7    # days
```

**The `pam_authinfo_unavail` action** in the surrounding PAM stack — per Chapter 4's trace 5 and Chapter 10.2's return-value table, `PAM_AUTHINFO_UNAVAIL` means "cannot reach the directory," not "wrong password." A stack that maps this to `die` locks out all directory-backed users immediately when the directory goes down. A stack that maps it to `ignore` falls through to whatever comes next, which could be nothing (a deny) or a local-account fallback.

```
auth  [success=done authinfo_unavail=ignore default=die]  pam_sss.so
auth  required                                            pam_unix.so
```

Per Chapter 4's exact trace of this pattern: directory reachable and rejects → dies (correct). Directory unreachable → ignored, falls through to `pam_unix` for local credentials. Directory reachable and accepts → done (success).

The combination of SSSD caching with `authinfo_unavail=ignore` provides the most graceful offline behaviour: directory users with recent cached credentials can still log in via the SSSD cache, and local accounts can still log in via `pam_unix`, even when the directory is completely dark. The residual risk — a user with stale or expired cached credentials being unable to log in during a directory outage — is an operational trade-off worth stating explicitly to stakeholders before it becomes an incident.

---

## 10.8 A Hardening Checklist for Integration

**1. Has `getent passwd <user>` been confirmed to work for every user category that needs to log in**, before any PAM-level troubleshooting is started, per 10.1's two-command discipline?

**2. Is the `pam_authinfo_unavail=` action in any directory-backed `auth` stack explicitly set and tested against a simulated directory outage**, per 10.7?

**3. Is SSSD caching configured appropriately for the operational tolerance of a directory outage**, per 10.7?

**4. Does the second-factor placement actually cover all login paths**, specifically including key-based SSH, per 10.4's complete statement of the SSH-key-bypass — tested with a real key, not only with password authentication?

**5. For any service offering shell access, is `pam_loginuid` present in the `session` stack**, per Chapter 9's audit command, so that subsequent sudo/su transitions remain attributable in the audit log?

**6. Are `pam_faillock`'s three-invocation pattern and its `account`-stack line both present on every service offering remote access**, per Chapter 8's opening scenario — tested with the key-bypass specifically, not only with password attempts?

**7. Does `sudo`'s service file contain whatever second-factor or restriction modules are intended to protect privileged-command escalation**, not only the files for `sshd` and `login`?

**8. Is SSSD itself monitored for availability**, with an alert that fires before users start calling support? A PAM configuration that depends on SSSD is a configuration whose reliability is bounded by SSSD's availability, and that dependency is worth making visible in the monitoring layer rather than only discovered when logins start failing.

---

## 10.9 Verification

**1. Run the two-command diagnostic sequence from 10.1 against a known-failing login**, confirming it distinguishes NSS failure from PAM failure correctly before both are fixed.

**2. Trace a directory-backed login from `getent` through `pamtester` through the actual login**, confirming each step produces a consistent picture and the log annotations match what the service traces in 10.5 predict.

**3. Simulate a directory outage and observe the fallback behaviour**, per 10.7 — stopping SSSD with `systemctl stop sssd` and confirming whether cached credentials, local credentials, or no credentials work, against your actual stack.

**4. Confirm the SSH-key-bypass applies to your second factor**, per 10.4 — add the second-factor module to `auth` only, attempt a key-based login while the second-factor condition would fail, and confirm the login still succeeds (demonstrating the bypass), then implement the `account`-stack or `AuthenticationMethods` mitigation and confirm it closes it.

**5. Reproduce trace 1 and trace 2 on a real system**, reading the logs alongside the trace tables in 10.5, confirming each module named in the trace appears in the log with the correct `(service:type)` annotation.

**6. Confirm trace 4's `pam_loginuid` behaviour**, per the final paragraph of 10.5's trace 4: run a command via `runuser` as a service account and confirm the loginuid in `/proc/$!/loginuid` reflects the service account's UID, not root's. Then compare with `sudo`: escalate to the same account via `sudo su - <user>` and check the loginuid again, confirming the difference in behaviour between the two paths.

**7. Complete the hardening checklist from 10.8 against your own environment**, treating each item as a concrete test rather than an inspection.

**8. Compare `sssctl user-checks` against `pamtester` for a directory-backed user.**

```
$ sssctl user-checks <username>
$ pamtester sshd <username> authenticate
```

If one succeeds and the other fails, identify which layer is the problem before attempting to fix anything. This is the layered-diagnostic discipline from 10.1, applied at its most precise: SSSD's own view of the user's authenticability, versus the PAM view of the combined stack's result.

**9. Trace the `su` trace from 10.6 and compare loginuids.**

```
$ cat /proc/self/loginuid                    # before su
$ su - <another-user> -c 'cat /proc/self/loginuid'    # after su
$ sudo -u <another-user> cat /proc/self/loginuid       # via sudo instead
```

Confirm the su trace sets a new loginuid for the target user, and the sudo trace preserves the invoking user's loginuid, per 10.6's final paragraph, by running both comparisons with the same target account.

**10. Verify SSSD is in your monitoring stack**, not merely in your audit checklist. Confirm that an alert would fire if `sssd` stopped without `systemctl restart sssd` — either through the monitoring system checking the unit status or through a synthetic login-test that would produce an alert on failure. A PAM integration that is correctly configured and unmonitored is still an outage waiting to be discovered reactively, and the monitoring gap is worth closing at the same time as the configuration gap — both represent the same underlying failure to treat authentication infrastructure with the same operational rigour as any other critical service dependency.

---

## Where This Goes Next

Chapter 11, the final chapter in the series, closes the loop the README opened: hardening, debugging, and the systematic approach to diagnosing PAM problems — not as a catalogue of failures to avoid, but as the practitioner-facing distillation of everything Chapters 1 through 10 have been building. Chapter 4's algorithm, Chapter 9's `pam_loginuid`, Chapter 8's `pam_faillock` three-invocation pattern, Chapter 7's `use_authtok` chain — all of it comes into the debugging procedure as tools for locating the specific line in the specific stack that produced the specific result observed in the log.

One thread this chapter leaves specifically for Chapter 11: the logging annotations that this chapter's traces have referred to throughout — `(sshd:auth)`, `(sudo:session)`, and so on — are the primary signal in a PAM diagnosis, and Chapter 11's diagnostic procedure is built around reading them accurately rather than starting from the application's own error message, which Chapter 4 first established as less informative than it looks.

This chapter, positioned between the module-reference chapters and the final diagnostic chapter, is the one where the full stack becomes visible as a system rather than a collection of individual decisions. Every configuration choice from Chapters 6 through 9 — which modules are in which stacks, in which order, with which control flags — interacts with the integration layer covered here, and the service traces in 10.5 and 10.6 are the place where those interactions are visible all at once rather than in isolation. Returning to those traces periodically, as familiarity with the individual chapters deepens, is one of the more productive uses of this material after a first read — the same trace reads differently once the session-stack modules from Chapter 9 are understood concretely, and differently again once a real SSSD configuration like the three-provider architecture in 10.2 is running in an environment you administer.

One last observation that this chapter, positioned between the module reference chapters (6 through 9) and the final diagnostic chapter (11), is uniquely placed to make: every module this series has covered, from `pam_rootok` through `pam_sss`, ultimately produces one of the return values from Chapter 4's table, and Chapter 4's algorithm is what the framework does with it. The integration in Chapter 10 is more complex than any individual module chapter, but it is not architecturally different — it is the same framework, the same four groups, the same evaluation algorithm, with more modules in each stack and more moving parts between the PAM layer and the underlying identity source. Keeping that continuity in view is what makes Chapter 11's debugging methodology applicable to the simple cases from Chapter 4's traces and to the complex, multi-source, multi-factor cases from this chapter equally, without needing a fundamentally different approach for each. Chapter 11's debugging methodology includes a brief treatment of what to do when NSS is partially broken — when `getent passwd` works from the command line but fails in some specific calling context, or when account attributes resolve inconsistently across repeated calls because a cache is populated from an inconsistent intermediate state. These edge cases are rarer than the straightforward NSS-or-PAM binary that 10.1 describes, but they exist, and Chapter 11 gives them the practical treatment they deserve alongside the cleaner diagnostic paths this chapter has described. The core point from Chapter 4 that every module produces one of a small set of return values, and Chapter 4's algorithm is what the framework does with them, applies as much to the directory-backed modules in this chapter as to the local modules in Chapters 6 through 9 — the integration is more complex, but not architecturally different, and Chapter 11's methodology works for both.

---

## Further Reading for This Chapter

- `man 5 nsswitch.conf` — the authoritative reference for the switch configuration, including the bracketed success/continue/notfound/unavail action syntax this chapter referenced in passing
- `man 8 getent` — the diagnostic tool at the centre of 10.1's two-command discipline
- `man 8 pam_sss` — the module's own page, covering arguments not described in `sssd.conf`
- `man 5 sssd.conf` — where most of `pam_sss`'s actual policy lives, including the three-provider split this chapter's 10.2 described and the cache configuration central to 10.7
- `man 8 sssctl` — the SSSD control and diagnostic tool; `sssctl user-checks`, `sssctl domain-status`, and `sssctl cache-expire` are the three commands this chapter returns to most often
- `man 8 pam_krb5`
- `man 8 kinit`, `man 1 klist`, `man 1 kdestroy` — the Kerberos command-line tools for bypassing PAM and testing the KDC directly, per 10.3's diagnostic recommendation
- `man 8 pam_google_authenticator`, `man 8 pam_u2f`, `man 8 pam_yubico` — for the second-factor modules' full argument sets, including graceful-failure modes relevant to the staged-rollout discussion in 10.4
- The OpenSSH manual, specifically `man 5 sshd_config`'s `AuthenticationMethods` directive, for the server-side half of the SSH-key-bypass mitigation this chapter completed
- The SSSD upstream documentation at `sssd.io` and the `sssd-users` mailing list archives — the two best sources for SSSD behaviour that is version-specific or distribution-specific and not reliably covered in any single manual page
- FreeIPA documentation, for the specific patterns when the IPA provider replaces the AD/LDAP configuration described in this chapter's worked examples

This chapter's material ages faster than any other in the series — SSSD releases frequently, distribution-specific defaults shift, and new second-factor modules appear regularly. The sources above, particularly the upstream SSSD documentation and the `sssctl` manual page, are the places to check before trusting anything written here more than one or two major releases ago, consistent with the version-churn discipline established in Chapter 1 and maintained throughout.
