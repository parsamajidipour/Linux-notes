# 06 — Authentication with PAM

Chapter 03 placed authentication at Stage 5 and moved on. Chapter 05 revealed
that when `sudoers` prompts `[sudo] password for parsa:`, it does so through a
conversation callback the front-end handed it — it never touches the terminal
directly. This chapter follows that prompt all the way down: into **PAM**, the
Pluggable Authentication Modules framework, which is what actually decides
whether the invoker is who they claim to be.

The central thing to understand is that **`sudo` does not authenticate anyone**.
It delegates. `sudo` does not read `/etc/shadow`, does not hash a password, does
not know about hardware tokens or one-time codes. It hands PAM a service name and
a way to talk to the user, and PAM — driven by a text configuration the
administrator controls — runs a stack of modules that collectively return one
bit: yes or no. Everything interesting about "how does `sudo` check my password"
is really "how does the PAM stack for the `sudo` service behave," and that is a
property of `/etc/pam.d/sudo`, not of `sudo` itself.

## 1. The problem PAM solves

Before PAM, every program that needed to authenticate a user — `login`, `su`,
`ftpd`, `sudo` — contained its own copy of "read the password, hash it, compare
against `/etc/passwd`." Changing the authentication method (say, adding shadow
passwords, or Kerberos, or a smartcard) meant patching and recompiling every one
of those programs. Authentication policy was scattered across the source of a
dozen unrelated tools.

PAM inverts this. It defines a stable API between **applications** that need
authentication and **modules** that implement authentication mechanisms. An
application (like `sudo`) says "authenticate the user for my service"; PAM
consults the administrator's configuration for that service and runs whatever
modules are listed — `pam_unix` for shadow passwords, `pam_sss` for LDAP/AD,
`pam_google_authenticator` for TOTP, `pam_u2f` for FIDO keys — combining their
verdicts. The application never knows or cares which mechanism was used.

For `sudo` this is exactly the right shape. `sudo`'s job (Chapter 02) is policy
and privilege transition, not cryptography. Authentication is a separable concern,
and PAM is where it was separated to.

## 2. `sudo` as a PAM application: the service name

Every PAM application authenticates against a named **service**, and the service
name selects a configuration file under `/etc/pam.d/`. `sudo`'s service is,
unsurprisingly, `sudo`:

```console
$ cat /etc/pam.d/sudo
#%PAM-1.0

session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0
@include common-auth
@include common-account
@include common-session-noninteractive
```

(There is a separate `sudo-i` service for `sudo -i`, the login-shell form, so the
two can differ.) Internally, `sudoers` begins the exchange by calling
`pam_start("sudo", invoking_user, &conv, &pamh)`, where the service name `"sudo"`
is what points PAM at this file, `invoking_user` is *whose* identity will be
tested (§10 revisits this), and `conv` is the conversation callback from
Chapter 05.

The `@include` lines pull in shared stacks — `common-auth`, `common-account`,
`common-session-noninteractive` — that many services reuse. This is why editing
`common-auth` affects `sudo`, `login`, and much else at once, and why the
`sudo`-specific file is usually short: the real work is in the included common
stacks.

## 3. The four management groups (and the three `sudo` uses)

PAM organizes modules into four independent **management groups**, each answering
a different question. Every line in a PAM config begins with the group it belongs
to:

- **`auth`** — *Are you who you say you are?* Verify identity: prompt for and
  check a password, a token, a fingerprint.
- **`account`** — *Even if authenticated, may this account do this now?* Validity
  and authorization: is the account expired, locked, time-restricted?
- **`password`** — *Change the authentication token.* Used when setting or
  updating a password. **`sudo` does not use this group** — it authenticates, it
  does not change passwords.
- **`session`** — *Set up and tear down the session around the command.* Tasks
  that bracket the privileged command: setting resource limits, environment,
  logging session open/close, systemd registration.

`sudo` exercises three of the four: `auth` (prove the invoker), `account`
(confirm the account is permitted), and `session` (bracket the command). It
touches `password` never. Keeping these groups distinct in your head is essential
to reading a PAM config, because a single module like `pam_unix.so` appears in
several groups doing entirely different jobs — checking the password under `auth`,
checking account expiry under `account`, recording the session under `session`.

## 4. The stack and its control flags

Within a management group, modules form a **stack**, executed top to bottom. Each
line's second field is a **control flag** that decides how that module's result
folds into the group's overall verdict. The four classic flags:

- **`required`** — must succeed. If it fails, the group ultimately fails, **but
  the rest of the stack still runs** (the failure is remembered and returned at
  the end). This delays the failure so an attacker cannot tell *which* module
  rejected them.
- **`requisite`** — must succeed, and if it fails, **control returns immediately**;
  the rest of the stack is abandoned. Faster, but leaks which stage failed.
- **`sufficient`** — if it succeeds (and no earlier `required` has failed), the
  group **succeeds immediately** and stops. If it fails, its result is ignored and
  the stack continues.
- **`optional`** — its result matters only if it is the *only* module in the group.

Modern configs increasingly use the general form that these four are shorthand
for — a bracketed list of `value=action` pairs:

```pam
auth    [success=1 default=ignore]    pam_unix.so nullok
auth    requisite                     pam_deny.so
auth    required                      pam_permit.so
```

Here `[success=1 default=ignore]` means: on `success`, **skip the next 1 module**;
on any other result, `ignore` this module and continue. Trace the three lines:

- `pam_unix` succeeds → skip 1 → jump over `pam_deny` → land on `pam_permit`
  (which always succeeds) → **authenticated**.
- `pam_unix` fails → `ignore` → fall through to `pam_deny` (which always fails,
  `requisite`) → **rejected immediately**.

This `[success=1 default=ignore] … pam_deny … pam_permit` idiom is the modern
replacement for the old `sufficient`/`required` pairing, and you will see it
everywhere in Debian/Ubuntu common stacks. Reading it fluently is the skill this
section is really teaching, because the security of the whole exchange lives in
these flags: a single `pam_permit.so` placed early with the wrong flag can make
authentication a formality.

## 5. Reading a real `/etc/pam.d/sudo`

Put the pieces together on a typical Debian/Ubuntu system. `/etc/pam.d/sudo`
includes three common stacks; here is what each contributes.

**`common-auth`** — the identity check:

```pam
auth    [success=1 default=ignore]    pam_unix.so nullok
auth    requisite                     pam_deny.so
auth    required                      pam_permit.so
auth    optional                      pam_cap.so
```

The core is `pam_unix.so`: it prompts (via the conversation function) and checks
the password against `/etc/shadow` (§8). A hardened system inserts
`pam_faillock.so` here to count failures and lock out after a threshold.

**`common-account`** — is the account allowed:

```pam
account [success=1 new_authtok_reqd=done default=ignore] pam_unix.so
account requisite    pam_deny.so
account required     pam_permit.so
```

`pam_unix.so` in the `account` group checks whether the account or its password
has expired — a different job than the same module did in `auth`.

**`common-session-noninteractive`** — bracketing the command:

```pam
session [default=1]  pam_permit.so
session requisite    pam_deny.so
session required     pam_permit.so
session optional     pam_umask.so
session required     pam_unix.so
```

Session modules run just before the command and again after it. `pam_limits.so`
(often present) applies `ulimit` settings here; `pam_env.so` — seen at the top of
`/etc/pam.d/sudo` itself — sets environment variables. This is the PAM half of
the environment story that Chapter 07 completes.

## 6. The conversation: where the password prompt comes from

Recall from Chapter 05 that a plugin talks to the user only through the
front-end's conversation function. PAM is built around the same idea. When
`sudoers` calls `pam_start`, one of the arguments is a `struct pam_conv`
containing a conversation callback. When a module like `pam_unix` needs to ask for
a password, it does **not** read `stdin`; it calls back into the application's
conversation function with a `PAM_PROMPT_ECHO_OFF` message ("prompt, but do not
echo what is typed").

So the chain for a single password prompt is:

```
pam_unix  →  PAM conv callback  →  sudoers' conversation  →  front-end conv
          →  the terminal (echo off)  →  user types  →  reply flows back up
```

The `PAM_PROMPT_ECHO_OFF` is why your password does not appear on screen, and the
front-end being at the end of the chain is why the prompt works correctly under a
pty, over SSH, and while I/O logging. The prompt text (`[sudo] password for
parsa:`) is itself governed by `sudo`'s `prompt` setting, passed down to the
module. Every layer here is delegation: `sudo` → `sudoers` → PAM → module, and
the reply threads all the way back.

## 7. The authentication flow, call by call

The full PAM exchange `sudoers` performs, in order:

```c
pam_start("sudo", invoking_user, &conv, &pamh);   /* select /etc/pam.d/sudo   */
pam_authenticate(pamh, 0);                         /* run the auth stack       */
pam_acct_mgmt(pamh, 0);                             /* run the account stack    */
/* --- command approved; if establishing a session: --- */
pam_setcred(pamh, PAM_ESTABLISH_CRED);             /* establish credentials     */
pam_open_session(pamh, 0);                          /* run session-open stack    */
/*        ... the privileged command runs here ...        */
pam_close_session(pamh, 0);                         /* run session-close stack   */
pam_setcred(pamh, PAM_DELETE_CRED);
pam_end(pamh, status);                              /* tear down                 */
```

- **`pam_authenticate`** drives the `auth` stack from §5 — this is where the
  password prompt happens and where `pam_unix` (or an MFA module) renders its
  verdict. If it returns failure, `sudo` reports the authentication failure and
  the command never runs.
- **`pam_acct_mgmt`** drives the `account` stack: even a correct password does not
  help if the account is expired or locked.
- **`pam_setcred`** / **`pam_open_session`** correspond to the `init_session` hook
  from Chapter 05 — establishing per-session credentials (e.g. a Kerberos ticket)
  and running session-open modules (`pam_limits`, `pam_env`, `pam_systemd`).
- After the command, the session is closed and PAM torn down.

Only `pam_authenticate` and `pam_acct_mgmt` gate whether the command runs; the
session calls shape the *context* it runs in. This maps cleanly onto Chapter 03:
Stage 5 is `pam_authenticate` + `pam_acct_mgmt`; the session calls sit at the
boundary of Stage 8/9.

## 8. Where the password is actually checked

Follow the password to ground. `pam_unix.so`, invoked under `auth`, must compare
what the user typed against the stored hash. The stored hash lives in
`/etc/shadow`, one line per user:

```console
# grep '^parsa:' /etc/shadow
parsa:$y$j9T$Q4x...<hash>...:19700:0:99999:7:::
```

The `$y$` prefix identifies the hashing scheme (`yescrypt` on modern Debian;
`$6$` would be `sha512crypt`). `pam_unix` reads this line, extracts the salt from
the stored field, hashes the entered password with the same scheme and salt via
`crypt(3)`, and compares. Equal hash → password correct.

Two access-control details matter:

- **`/etc/shadow` is readable only by root** (mode `0640`, owner `root`, group
  `shadow`). `sudo` is running at `euid 0` during authentication (Chapter 01), so
  `pam_unix` inside the `sudo` process can read `shadow` directly. For a
  *non-root* PAM application, `pam_unix` instead invokes the setuid/setgid helper
  `unix_chkpwd` to check the password without exposing the hash. In `sudo`'s case
  the direct read is available because `sudo` is already privileged.
- **`sudo` never sees the hash or the plaintext comparison.** All of it happens
  inside `pam_unix`. `sudo` receives only PAM's final return code. This is the
  separation of concerns paying off: the credential-checking code is in one
  audited module, not duplicated into `sudo`.

## 9. Account and session management

Authentication proves identity; it does not by itself authorize. The `account`
stack (`pam_acct_mgmt`) is where PAM enforces things orthogonal to "is the
password right":

- account or password **expiry** (`pam_unix` account checks the shadow aging
  fields);
- **time-of-day** restrictions (`pam_time.so`);
- **group gating** (`pam_wheel.so`, restricting to a group);
- external directory policy (`pam_sss.so` consulting AD/LDAP).

A user with a perfectly valid password can still be refused here — expired
account, outside permitted hours, not in the required group. This is a distinct
gate from `sudoers`' own policy (Chapter 04): `sudoers` decides *what commands*,
PAM's account stack decides *whether the account is presently usable at all*. Both
must pass.

The `session` stack brackets the command with setup and teardown — resource
limits via `pam_limits.so`, environment via `pam_env.so`, systemd session
registration via `pam_systemd.so`, and session logging. These feed directly into
the execution context of Chapter 03 Stage 9.

## 10. Whose password? `rootpw`, `targetpw`, and friends

A defining property of `sudo` (Chapter 02) is that it authenticates the
**invoker**, not the target. That is the default because `sudoers` calls
`pam_start` with the *invoking* user's name. But `sudoers` exposes `Defaults` that
change *which* identity PAM verifies:

```sudoers
Defaults  rootpw       # verify ROOT's password instead of the invoker's
Defaults  targetpw     # verify the TARGET user's password
Defaults  runaspw      # verify the runas user's password
```

Each changes the user handed to `pam_start`, and thus whose shadow entry
`pam_unix` checks. These are mostly of historical or special-case interest, and
`rootpw`/`targetpw` partly re-introduce the shared-secret problems Chapter 02
criticized in `su` — so the invoker-authenticates default is almost always the
right one. But knowing the knobs exist explains configurations you may encounter
where `sudo` unexpectedly asks for a *different* password than your own: some
`Defaults` line flipped the identity passed into PAM.

## 11. The timestamp: PAM runs once, then `sudo` remembers

If PAM ran on every `sudo` invocation, a burst of ten commands would mean ten
password prompts. It does not, because of `sudo`'s **timestamp** mechanism — and
it is important to see that this cache is **`sudo`'s, not PAM's**.

On a successful `pam_authenticate`, `sudo` records a timestamp ticket (under
`/run/sudo/ts/<user>` on modern systems). On the next invocation, before touching
PAM, `sudo` checks for a valid, unexpired ticket; if one exists (default
`timestamp_timeout`, commonly 15 minutes), it **skips the authentication stack
entirely**. PAM is not consulted; no module runs.

```console
$ sudo -v          # refresh the timestamp (validate) — may prompt
$ sudo -k          # invalidate the timestamp (kill) — next sudo re-authenticates
$ sudo -K          # remove the timestamp entirely
```

`sudo -v`/`-k`/`-K` are the `validate`/`invalidate` policy-plugin entry points
from Chapter 05, surfaced as flags. The consequence for reasoning about security:
the "did `sudo` ask for a password" behavior depends on **two independent
systems** — the PAM stack (what happens *when* it authenticates) and the sudo
timestamp (*whether* it authenticates this time). A confusing "why didn't it ask
for my password?" is usually a valid timestamp, not a PAM change.

## 12. Extending the stack: lockout and MFA

Because authentication is entirely a property of the PAM stack, hardening `sudo`'s
authentication means editing PAM, not `sudo`. Two common additions:

**Failure lockout** — insert `pam_faillock.so` into the `auth` stack to count
consecutive failures and lock the account after a threshold, blunting online
password guessing:

```pam
auth    required    pam_faillock.so preauth  deny=5 unlock_time=900
auth    [success=1 default=ignore]  pam_unix.so nullok
auth    [default=die]  pam_faillock.so authfail deny=5 unlock_time=900
auth    requisite   pam_deny.so
auth    required    pam_permit.so
```

**Multi-factor** — add a second-factor module so `sudo` requires a token *and* a
password:

```pam
auth    required    pam_unix.so
auth    required    pam_google_authenticator.so   # TOTP second factor
# or: pam_u2f.so for a FIDO/U2F hardware key
```

With both `required`, the user must satisfy both — password *and* one-time code —
before `pam_authenticate` returns success. `sudo` itself is unchanged; it still
just calls `pam_authenticate` and reads the result. This is the whole point of
the PAM abstraction: an entire second authentication factor is added to `sudo`
without a line of `sudo` configuration, purely by editing its PAM stack. (Note the
overlap with Chapter 05's approval plugins: a second factor can be imposed either
here in PAM's `auth` stack or as an approval plugin — two different layers that
can each demand it.)

## 13. Security considerations

**The PAM stack runs while `sudo` is root.** Every module in `/etc/pam.d/sudo`
and its included stacks executes inside the `sudo` process at `euid 0`. A
malicious or vulnerable PAM module is a root-level compromise, and the module
files (`/lib/*/security/*.so`) and configs (`/etc/pam.d/*`, `/etc/security/*`)
must be root-owned and unwritable by others — exactly the requirement Chapter 05
placed on plugins, for the same reason.

**Control flags are load-bearing.** The difference between a secure and a broken
`sudo` can be a single flag. A `pam_permit.so` reachable in the `auth` group
before any real check means anyone authenticates. Removing `pam_deny.so` from the
fall-through can turn a failed check into a success. When reviewing a system's
`sudo` security, the `auth` stack's flags deserve as much scrutiny as any
`sudoers` rule.

**Authentication is separate from authorization.** PAM's `auth` proves *who*;
`sudoers` decides *what* (Chapter 04); PAM's `account` decides *whether the
account is usable*. All three are independent gates. A common misdiagnosis is
treating a `sudoers` denial as an authentication failure or vice versa — they come
from different subsystems and are fixed in different files.

**The password may not be the invoker's.** As §10 showed, `rootpw`/`targetpw`
change whose secret is checked. A configuration using them inherits the
shared-secret weaknesses `sudo` was built to avoid.

**Debugging leaves a trail in the auth log.** PAM modules log to the `authpriv`
syslog facility — `/var/log/auth.log` on Debian/Ubuntu, `/var/log/secure` on
Red Hat — and to the journal:

```console
# journalctl -t sudo --no-pager | tail -2
Apr 12 11:02:17 host sudo[6210]: pam_unix(sudo:auth): authentication failure;
    logname=parsa uid=1000 euid=0 tty=/dev/pts/3 ruser=parsa rhost= user=parsa
Apr 12 11:02:21 host sudo[6212]:  parsa : TTY=pts/3 ; PWD=/home/parsa ;
    USER=root ; COMMAND=/usr/bin/systemctl restart nginx
```

The first line is PAM (`pam_unix(sudo:auth)`) reporting a bad password; the second
is `sudoers` reporting a *successful, authorized* command. Reading which subsystem
emitted which line is the first step of Chapter 12's debugging.

## 14. What this chapter established

- **`sudo` does not authenticate — it delegates to PAM.** It reads no `shadow`,
  hashes no password, knows no mechanism; it hands PAM a service name (`sudo`, →
  `/etc/pam.d/sudo`) and a conversation callback, and receives one bit back.
- PAM has four **management groups**; `sudo` uses **`auth`** (prove identity),
  **`account`** (is the account usable), and **`session`** (bracket the command),
  and never **`password`**.
- Within a group, modules form a **stack** governed by **control flags**
  (`required`/`requisite`/`sufficient`/`optional`, and the general
  `[value=action]` form); the security of the whole exchange lives in these flags
  and their order.
- The password prompt reaches the terminal through a **delegation chain** —
  module → PAM conv → `sudoers` conv → front-end — with `PAM_PROMPT_ECHO_OFF`
  suppressing echo; the actual check happens inside **`pam_unix`** against
  **`/etc/shadow`** via `crypt(3)`, which `sudo` can read directly because it is
  already `euid 0`.
- **Authentication, `sudoers` authorization, and account validity are three
  independent gates** in three subsystems; all must pass, and they are diagnosed
  in different places.
- Which identity is authenticated is the **invoker** by default, changeable via
  `rootpw`/`targetpw`/`runaspw` — usually a mistake to change.
- The "did it ask for a password" behavior also depends on **`sudo`'s own
  timestamp** cache (separate from PAM), managed by `sudo -v`/`-k`/`-K`.
- Hardening `sudo`'s authentication (**lockout via `pam_faillock`, MFA via
  `pam_google_authenticator`/`pam_u2f`**) is done by editing the **PAM stack**,
  not `sudo` — and every module runs as root, so control flags and module files
  are as security-critical as `sudoers` itself.

The next chapter returns to something both this chapter and Chapter 03 kept
gesturing at: the environment. *Environment Handling* dissects how `sudo`
dismantles the hostile environment inherited from the caller and constructs a
safe one for the command — `env_reset`, `env_keep`, `env_check`, `secure_path` —
and the ways a permissive environment policy quietly re-opens the trust boundary.
