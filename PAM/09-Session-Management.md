# 09 — Session Management

Every module up to this point has been about a decision: is this credential correct, may this account be used, may this token be changed. This chapter is about something structurally different — not a decision at all, but construction and teardown. By the time the `session` stack runs, identity and permission have both already been settled. What is left is building the environment a login actually lives in, and dismantling it afterward.

Chapter 3 introduced this group's asymmetry: `pam_open_session()` and `pam_close_session()` are meant to bracket a login cleanly, and in practice frequently do not, because processes fork, outlive their originating session, or escape it entirely. This chapter is the module-level reference for what actually gets built in that bracket — resource limits, environment, the kernel audit identity, the logind session object with its cgroup scope, the keyring, polyinstantiated directories — and for the specific, recurring ways each of these fails to tear down cleanly when reality does not cooperate with the clean open-then-close model the API suggests.

### A short scenario, to set the frame

Consistent with the opening scenarios in Chapters 6 through 8.

A team investigating a suspicious background process eventually traces it to a contractor's account, offboarded and disabled three months earlier through the ordinary account-lockout process from Chapter 8 — the `account` stack correctly refuses any new login attempt on that account, and has since the day it was disabled, verified at the time with exactly the kind of violation test this series has insisted on throughout. And yet a process, still running, still consuming resources, still nominally owned by that account, has been alive the entire three months. Nothing in Chapters 6 through 8 explains this — every module covered there is about whether a *new* login may proceed, and this is not a new login. It is a `systemd --user` service, started under a lingering-enabled session before the account was disabled, that Chapter 8's lockout mechanisms were never designed to reach, because they operate entirely upstream of where this process's continued existence is actually decided.

The account was correctly locked. The lockout was correctly tested. And the process kept running anyway, because `session`-stack decisions — in this specific case, whether lingering was enabled — determine facts about a login that persist independently of whether the account that started it can still log in again. Hold this scenario through 9.5 specifically, where lingering gets the full treatment its quiet operational consequences deserve.

---

## 9.1 Why This Group Reads Differently From the Other Three

Worth stating plainly before the module reference, because it changes how you should approach reading a `session` stack compared to how Chapters 6 through 8 taught you to read the other three.

`auth`, `account`, and `password` are all, fundamentally, about a yes-or-no question resolved through Chapter 4's evaluation algorithm — every module in those three chapters returns success or failure, and the stack's job is combining those into one verdict. `session` modules mostly do not make decisions in that sense. `pam_limits` does not ask "should this session be permitted," it asks "what resource ceilings apply to it," and it answers that question by calling `setrlimit()`, not by returning a value the framework meaningfully evaluates one way or the other. Most `session` failures are not policy rejections; they are operational failures — a file that could not be created, a scope that could not be registered with logind, a keyring that could not be allocated — and this is precisely why Chapter 4 observed that most `session`-stack lines are `optional`: a failure to display the message of the day should not deny a login, and neither, in most configurations, should a failure to create a home directory that already exists.

This does not mean nothing in `session` matters for Chapter 4's algorithm — `pam_limits` and `pam_loginuid` are commonly `required`, and a `required` failure here does deny the login, per the ordinary evaluation rules. But the *character* of what is being evaluated has shifted, from "is this permitted" to "did this construction step succeed," and reading a `session` stack means asking, module by module, which kind of line you are looking at.

---

## 9.2 `pam_limits`

### What it does

Reads resource limit rules from `/etc/security/limits.conf` and the `limits.d/` drop-in directory, and applies them via `setrlimit()` to the session being opened.

### Which groups it serves

`session` only.

```
$ objdump -T /usr/lib64/security/pam_limits.so | grep pam_sm_
```

Confirm this shows only session-role functions — a `pam_limits` line in `auth` or `account`, per Chapter 3's warning about modules placed where they cannot function, does nothing at all.

### The configuration format

```
domain  type  item  value
```

`domain` is a username, `@groupname`, `%groupname` (equivalent on most versions), a UID/GID range, or `*` for everyone. `type` is `soft` (the enforced limit a process can raise up to `hard`, without additional privilege) or `hard` (the ceiling, raisable only by root). `item` is the specific resource: `nofile` (open file descriptors), `nproc` (processes), `fsize`, `cpu`, `as` (address space), `memlock`, `stack`, `core`, `priority`, `nice`, `rtprio`, and several others.

```
*                soft    nofile          4096
*                hard    nofile          65536
@developers      soft    nproc           2048
root             -       nofile          unlimited
```

A `-` in the `type` field sets both soft and hard simultaneously, as shown on the `root` line. This shorthand is worth using deliberately rather than by habit — writing two separate lines for the same domain and item, one `soft` and one `hard`, is equally valid and occasionally clearer to a reader unfamiliar with the shorthand, at the cost of doubling the line count for every domain that needs both set to the same value.

### The soft/hard distinction, precisely

Worth being exact about this, since "soft" and "hard" invite an intuitive but slightly wrong reading. The **soft** limit is what actually constrains the process from the moment the shell starts — this is the number `ulimit -n` reports by default. The **hard** limit is the ceiling that soft limit can be raised to, by the process itself, without needing elevated privilege — `ulimit -n 65536` succeeds if the hard limit is `65536` or higher, and fails otherwise. Root, or a process with the appropriate capability, can raise the hard limit itself; an ordinary user cannot exceed their own hard ceiling regardless of what they request, a distinction worth being able to state precisely in exactly these terms, since "soft" and "hard" as plain English words do not by themselves convey which one is the enforced value and which is the raisable ceiling.

```
$ ulimit -Sn   # current soft limit
$ ulimit -Hn   # current hard ceiling
```

A common, reasonable pattern is a moderate default soft limit with a considerably higher hard limit, letting well-behaved applications that know to raise their own limits do so, while naive applications that never call `setrlimit()` themselves still get a sane, conservative default.

### `limits.d/`

Drop-in files under `/etc/security/limits.d/`, processed in lexical filename order, in addition to `limits.conf` itself. This exists for the same reason `pam.d/` itself exists — package-installed limits, such as a database server's recommended `nofile` increase, can be dropped in without editing the central file:

```
$ ls /etc/security/limits.d/
```

Worth checking for conflicting entries across multiple files, since the *last* matching rule for a given domain/item pair generally wins across the combined set — an easy thing to get wrong when several packages each drop in their own file targeting the same user or group.

### Arguments

`conf=/path` — an alternate configuration file.

`debug` — the usual convention.

`change_uid` — apply limits before the UID switch happens rather than after, relevant to some specific privilege-transition orderings.

### The critical caveat: systemd and cgroups

This is the single most important thing to know about this module on any current system, and it is worth restating from Chapter 3 with the full weight it deserves here.

`pam_limits` calls the traditional POSIX `setrlimit()` API — the same mechanism `ulimit` in a shell exposes. On a systemd-managed system, resource control increasingly happens through an entirely separate mechanism: cgroup-based accounting and limits, configured through systemd unit files (`MemoryMax=`, `TasksMax=`, `CPUQuota=`, and similar directives) or through `systemd-logind`'s own per-user slice configuration. **These two mechanisms do not consult each other.** Setting `nproc` in `limits.conf` has no effect on a `TasksMax=` cgroup limit applied to the same user's systemd slice, and raising `TasksMax=` does not raise the `nproc` ceiling `pam_limits` enforced via `setrlimit()`. A process can be constrained by whichever of the two mechanisms is more restrictive, and diagnosing "I set the limit and nothing changed" requires checking both:

```
$ ulimit -a                                          # the setrlimit/pam_limits view
$ systemctl show user-$(id -u).slice | grep -i max    # the cgroup/systemd view
$ systemctl show user-$(id -u).slice | grep -i tasks
```

This is not a bug in either mechanism; they were designed independently, for different purposes, at different points in Linux's history, and the coexistence is a known, documented seam rather than an oversight — but it is a seam that generates a steady stream of confused support tickets, and it is worth having the two-command check above memorised rather than rediscovered under pressure each time.

### A worked diagnostic

Concretely, here is what the confused-ticket scenario looks like and how to resolve it in practice, since the abstract caveat above is easier to apply once seen against a real symptom.

An administrator raises `nofile` for a database service account in `limits.conf`, restarts the service, and the service still reports "too many open files" under load. The first instinct is to re-check the syntax of the `limits.conf` line, which is usually correct — the mistake is rarely there. The actual cause, in the overwhelming majority of cases on a current systemd-managed system, is that the service in question is started as a systemd unit, not through a login shell that traverses `pam_limits` at all, and systemd units have their own resource-limit directives, `LimitNOFILE=` among them, set in the unit file itself, entirely independent of `/etc/security/limits.conf`:

```
$ systemctl show myservice.service | grep -i LimitNOFILE
```

If this shows a value lower than what was set in `limits.conf`, that is the actual ceiling in effect — `limits.conf` was never consulted for this process at all, because the process was never spawned through a PAM-aware login path in the first place. The fix is a `LimitNOFILE=` directive in the unit file or a drop-in, not a change to `limits.conf`. This is subtly different from, but closely related to, the `pam_limits`-versus-cgroup seam described above: it is the same underlying "two independent resource-control mechanisms" problem, manifesting here as "which mechanism even applies to this process at all" rather than "which of two applicable limits wins."

The general diagnostic habit worth taking from both cases: before adjusting `limits.conf`, confirm the process in question was actually started through a path that traverses PAM's `session` stack at all. A great many production services are not, and `limits.conf` is silently irrelevant to them regardless of how correctly it is written.

### Return values

Largely operational rather than policy-driven, per 9.1 — `PAM_SUCCESS` in the ordinary case; failure values are possible but, on an `optional` line (the common configuration), rarely visible in practice since the framework discards them per Chapter 4.

### Interactions

With systemd's own slice-based resource control, per the caveat above — not a PAM-level interaction at all, but essential context for interpreting this module's apparent effect or lack of one. With `pam_faildelay` and `pam_faillock` from Chapters 6 and 8 not at all — entirely different stacks, entirely different concerns, mentioned here only because a common mistake is assuming any resource-adjacent module belongs in the same conceptual bucket.

### Failure modes

Assuming `limits.conf` is authoritative on a systemd-managed system without checking the cgroup view, per the caveat above — by far the most common. A `limits.d/` drop-in from one package silently overridden by a later-loading drop-in from another, per the lexical-ordering note above.

---

## 9.3 `pam_env`

### What it does

Sets environment variables for the session, read from `/etc/security/pam_env.conf` and, depending on arguments and version, `/etc/environment`.

### Which groups it serves

`session` only.

### The configuration format

```
VARIABLE  [DEFAULT=value]  [OVERRIDE=value]
```

```
PATH        DEFAULT=/usr/local/bin:/usr/bin:/bin
EDITOR      DEFAULT=vim
SSH_ORIGIN  DEFAULT=unknown  OVERRIDE=${PAM_RHOST}
```

`DEFAULT` sets the value if the variable is not already set in the environment being constructed. `OVERRIDE` sets it unconditionally, and — as the third example shows — can reference PAM items directly, letting an environment variable be populated from context the application supplied, such as the remote host from Chapter 5's item table.

### The `SSH_ORIGIN` example, traced

Worth tracing that third example line explicitly, since it is a genuinely useful pattern and the item-substitution syntax is easy to skim past without registering what it actually does.

```
SSH_ORIGIN  DEFAULT=unknown  OVERRIDE=${PAM_RHOST}
```

At session-open time, this module reads the `PAM_RHOST` item — the same one `pam_access` consults in Chapter 8, set by the application per Chapter 5's item-setting discussion — and if it holds a value, sets `SSH_ORIGIN` to that value, unconditionally overriding anything else. If `PAM_RHOST` is unset or empty, because the application never called `pam_set_item()` for it, the `OVERRIDE` substitution effectively contributes nothing and the `DEFAULT` of `unknown` applies instead. The practical result: any script or application later in the session that reads `$SSH_ORIGIN` from its environment gets a genuinely useful record of where the login came from, populated automatically, with no application-level code required beyond reading one environment variable — a considerably lighter-weight integration than parsing `sshd`'s own logs after the fact for the same information.

```
$ echo $SSH_ORIGIN
```

after a remote login, confirming the substitution actually occurred, is worth doing once as a sanity check before relying on this pattern for anything operationally significant — per the general discipline this series has applied throughout, a configuration line that looks correct and a configuration line that behaves correctly are not automatically the same claim, and this one depends on an upstream application behaviour (setting `PAM_RHOST`) that this module itself has no way to verify or enforce.

### `pam_env.conf` versus `/etc/environment` versus shell startup files

This is the question worth answering precisely, since three different mechanisms all claim to set "the environment" and they are read at genuinely different points, by genuinely different code, with genuinely different scope.

**`/etc/security/pam_env.conf`**, read by this module, during `session` stack processing — before any shell has started, applying to the environment the login process itself will hand off to whatever it execs next.

**`/etc/environment`**, on many distributions also read by `pam_env` itself (via the `readenv=1` module argument, commonly present in default stacks) — a simpler `KEY=value` format with no default/override distinction, intended as a genuinely system-wide baseline independent of shell choice.

**Shell startup files** (`/etc/profile`, `~/.bashrc`, `~/.profile`, and similar) — read by the shell itself, after PAM has already finished and the login process has already exec'd into that shell. These are not PAM's concern at all, and a variable set here is invisible to anything that does not go through this specific shell's startup sequence — a cron job, for instance, or a non-interactive SSH command execution, neither of which sources `.bashrc` in the ordinary case.

The practical diagnostic this table implies: "I set an environment variable and a service doesn't see it" needs an answer to "which of these three did I actually set it in, and does the code path in question actually read from there." A variable set in `.bashrc` is invisible to a `cron` job; a variable set only via `pam_env.conf` for a service whose stack does not include this module is equally invisible, regardless of how carefully the syntax was written.

### Arguments

`conffile=/path` — alternate configuration file.

`readenv=1` — also process `/etc/environment` in the simpler format, commonly set in distribution default stacks.

`user_readenv=1 envfile=~/.pam_environment` — process a per-user environment file, a mechanism some distributions have deprecated in favour of other approaches; check your specific version's manual page, since this is another area where behaviour has shifted across releases.

### Return values

`PAM_SUCCESS` in essentially all ordinary cases; failures are rare and generally reflect a malformed configuration file rather than a policy decision.

### Interactions

With `PAM_RHOST` and other items, per the `OVERRIDE` example above — this module is a direct, visible consumer of the item mechanism Chapter 5 built, and a good place to see it working concretely if the abstract API discussion there felt distant from anything practical.

### Failure modes

Assuming a variable set here is visible to a non-interactive service, per the three-mechanism confusion above. A malformed line silently skipped rather than erroring loudly, which is worth testing directly rather than assumed correct from the file's syntax alone:

```
$ env | grep EDITOR
```

after a fresh login, compared against what `pam_env.conf` claims to set.

---

## 9.4 `pam_loginuid`

### What it does

Sets the kernel's audit login UID (`/proc/self/loginuid`) for the session, a value that — unlike the ordinary UID, which changes freely with `setuid()` calls throughout a process's life — is set exactly once, at login, and is immutable for every process descended from that point forward.

### Which groups it serves

`session` only.

### Why this module is disproportionately important for its size

It is a small module — essentially, one system call, one value written, no configuration file, almost no arguments worth discussing. Its importance is entirely in what that one value enables: **every subsequent `sudo`, every `su`, every privilege transition a process descended from this login makes, is still attributable, in the kernel audit log, to the human who originally logged in** — not to whichever account the process happens to be running as at the moment of a given action. Ordinary UID tracking is insufficient for this, because ordinary UID changes with every `setuid()` call and a sufficiently long chain of privilege transitions loses the original identity entirely if audit relies on UID alone. `loginuid` does not change across those transitions, by kernel design, specifically to preserve exactly this chain of accountability.

```
$ cat /proc/self/loginuid
$ sudo cat /proc/self/loginuid
```

Run both, as the same user, and confirm the value is identical — `sudo` changes the effective and real UID of the resulting process, but not the loginuid, and this is the entire point.

### Arguments

Minimal; current versions take essentially no configuration-relevant arguments beyond the usual `debug`.

### Return values

`PAM_SUCCESS` on ordinary operation; failure is rare and generally indicates a kernel or permission problem rather than a policy outcome.

### Interactions

With `auditd` directly — every audit log entry the kernel produces for a process's actions carries this value, and Chapter 11's discussion of correlating log entries with a specific human depends entirely on this module having run correctly. With `pam_faillock` from Chapter 8, indirectly — lockout events, when logged through the audit subsystem rather than only syslog, are attributed using this same mechanism.

### Failure modes

**Absence from a service's `session` stack**, more than any misconfiguration within the module itself — a service offering shell or command access whose stack does not include `pam_loginuid` produces actions that cannot be attributed to a human in the audit trail, no matter how thorough the audit rules configured elsewhere are. Chapter 5's verification exercise on this exact point (auditing which services lack this module) is worth repeating here, now with the full module reference behind it rather than only the forward reference Chapter 3 offered:

```
$ grep -L pam_loginuid $(grep -l 'session' /etc/pam.d/*)
```

Any service in that output offering shell or command execution is a genuine accountability gap, worth resolving rather than left as a historical accident of which distribution package first generated the file.

---

## 9.5 `pam_systemd`

### What it does

Registers the session with `systemd-logind`, creating the logind session object, allocating it a scope within the user's slice in the cgroup hierarchy, setting `XDG_RUNTIME_DIR`, and managing the session's place in the broader systemd-managed lifecycle of the machine.

### Which groups it serves

`session` only.

### What a "session," concretely, becomes because of this module

Chapter 3 introduced the distinction between the several things called "session" on a modern system. This module is the specific mechanism behind the second of those — the logind session, as opposed to the bare PAM session bounded by `pam_open_session()`/`pam_close_session()`, or the kernel audit session `pam_loginuid` establishes, or the traditional utmp record.

```
$ loginctl list-sessions
$ loginctl session-status <id>
```

A logind session has an ID, a type (`tty`, `x11`, `wayland`, and others), a state, a seat if applicable, and — critically for the systemd-cgroup relationship in 9.2's caveat — a scope unit, visible as its own entry in the cgroup hierarchy, under the user's own slice:

```
$ systemctl status session-<id>.scope
$ systemd-cgls
```

This scope is what systemd's own resource-control directives, when applied to `user-<uid>.slice` or to the session scope specifically, actually constrain — the concrete cgroup object on the other side of 9.2's `pam_limits` caveat.

### `XDG_RUNTIME_DIR`

One of this module's most immediately visible effects: a per-user, tmpfs-backed directory, typically `/run/user/<uid>/`, created for the duration of the session and used by a large fraction of modern desktop and even server-side tooling for sockets, temporary files, and IPC — D-Bus session buses, for instance, conventionally live here.

```
$ echo $XDG_RUNTIME_DIR
$ ls -la /run/user/$(id -u)/
```

A login whose stack lacks `pam_systemd` will not have this variable set, and any application assuming its presence will fail or fall back to a less clean alternative — worth knowing as a diagnostic starting point when an application complains about a missing runtime directory on a minimal or custom-built PAM stack.

### Lingering

By default, a user's systemd resources — their slice, and anything running in it — are torn down once their last session closes. **Lingering**, enabled per-user with `loginctl enable-linger <user>`, keeps the user's systemd instance and slice alive even with no active session, which is what allows a user's own `systemd --user` services to keep running after they log out — a backup job, a long-lived personal daemon, anything managed through a user-level systemd unit rather than a system-level one.

```
$ loginctl enable-linger parsa
$ loginctl show-user parsa | grep Linger
```

Worth understanding the security dimension explicitly: an account with lingering enabled can have processes running, and consuming resources, indefinitely with no active login at all — a state worth including in any account-lifecycle review, particularly for an account that has since been disabled or locked via the mechanisms in Chapter 8, since lockout at the `account`-stack level does not retroactively stop already-running lingering processes.

### Auditing lingering across an entire system

Since this chapter's opening scenario turns on exactly this gap, it is worth a dedicated worked audit rather than only the single-command check above.

```
$ loginctl list-users
$ for u in $(loginctl list-users --no-legend | awk '{print $2}'); do
      linger=$(loginctl show-user "$u" -p Linger --value 2>/dev/null)
      locked=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
      echo "$u  linger=$linger  passwd_status=$locked"
  done
```

Read the output specifically for the combination this chapter's opening scenario describes: `linger=yes` paired with a locked or expired account status. Any such pairing is worth investigating individually — `loginctl user-status <user>` will show whether any lingering-enabled processes are actually currently running for that account, and if so, the account-lifecycle process that disabled the account evidently did not include a step for this, which is a process gap worth closing at the offboarding procedure level, not just for this one account.

```
$ loginctl user-status <user>
$ loginctl disable-linger <user>
```

The second command, run against any account that should not have lingering enabled, is the direct remediation — worth pairing with whatever process disables an account in the first place, exactly the way 8.4's discussion of `/etc/nologin` cleanup recommended building removal into the same script that sets the flag, applied here to the inverse problem of a persistent grant that outlives the decision that should have revoked it.

### What breaks when this module is absent

A service whose `session` stack lacks `pam_systemd` will not have a logind session created at all — no entry in `loginctl list-sessions`, no `XDG_RUNTIME_DIR`, no cgroup scope. For a minimal service that genuinely has no need for any of this — a purely batch-oriented automation account, for instance — this may be entirely appropriate and is not automatically a misconfiguration. For an interactive service, the symptom is a login that appears to work but where a wide range of desktop-adjacent or IPC-dependent tooling behaves oddly or fails outright, often with error messages that do not obviously point back to a missing PAM module at all.

### Arguments

Minimal in typical use; `debug` as usual, plus some version-specific options controlling exact session-type detection, worth checking against your installed version's manual page rather than assumed uniform.

### Return values

Largely operational, per 9.1's framing — `PAM_SUCCESS` in the ordinary case; a failure here typically indicates `systemd-logind` itself is not running or not reachable, which on a systemd-managed system is a much larger problem than this one PAM module.

### Interactions

With `pam_limits`, per 9.2's caveat — this module is the other half of that story, the side that actually creates the cgroup scope systemd-level resource directives apply to. With `pam_loginuid`, complementarily rather than redundantly — audit identity and logind session identity are two entirely separate kernel and userspace concepts that happen to both matter for the same login, tracked through entirely different mechanisms.

### Failure modes

Absence on an interactive service producing the diffuse, hard-to-diagnose symptom described above, rather than a clean, attributable error. Lingering enabled on an account that should not have persistent background processes, per the security note above, and left unaudited.

---

## 9.6 `pam_mkhomedir`

### What it does

Creates a user's home directory, from a skeleton template, if it does not already exist at session-open time.

### Which groups it serves

`session` only.

### Purpose

Specifically useful for directory-backed accounts — users authenticated via SSSD, LDAP, or Kerberos per the forward references in Chapters 6 and 7 to Chapter 10's fuller treatment — whose accounts exist in a central directory but whose home directories were never separately provisioned on any individual machine they might log into. Without this module, such a user's first login on a new host fails or lands them in an unusable, non-existent home directory; with it, the directory is created transparently on first use.

### Arguments

`skel=/etc/skel` — the template directory to copy from, defaulting to the conventional path most distributions already populate with sensible starting dotfiles.

`umask=0022` — the permission mask applied to the newly created directory and its contents.

### Return values

`PAM_SUCCESS` whether the directory already existed or was successfully created; failure if creation was attempted and failed, for instance due to insufficient permissions on the parent directory or a full filesystem.

### Interactions

With NSS and the directory-integration material properly covered in Chapter 10 — this module's entire reason for existing is a consequence of how directory-backed accounts work, and it will come up again there with fuller context.

### Failure modes

Silent non-creation on a permissions problem with the parent directory, worth testing directly on a throwaway directory-backed or manually simulated account rather than assumed to work:

```
# rm -rf /home/newuser 2>/dev/null
$ pamtester sshd newuser open_session
$ ls -ld /home/newuser
```

A skeleton directory that has drifted from what current policy actually wants new users to start with — worth periodically auditing `/etc/skel` itself, since it is easy to forget this module copies whatever is there at the moment of first login, not some canonical, actively-maintained ideal.

### Diagnosing a silent creation failure

Worth a concrete diagnostic sequence, since "silent" is precisely the failure mode most worth having a checklist for, consistent with this chapter's `optional`-line theme.

```
$ ls -ld /home
$ stat -c '%U:%G %a' /home
```

If the parent directory is not writable by whatever privilege context the `session` stack's `pam_mkhomedir` invocation runs under — commonly root, but worth confirming rather than assumed on a system with unusual privilege-separation configuration — creation fails, and on an `optional` line, per Chapter 4's algorithm, that failure is simply discarded. The user's login proceeds, lands in a non-existent or inaccessible home directory, and the resulting shell behaviour — commonly an immediate error or an unexpected fallback to `/`— is the only visible symptom, with nothing in the ordinary PAM logs pointing specifically back to this module unless `debug` was already enabled before the failure occurred. This is a strong argument for enabling `debug` on this specific line permanently in any environment where directory-backed accounts and first-time logins are common enough that this failure mode is a realistic operational risk, rather than only turning it on reactively after a user has already reported a broken login.

---

## 9.7 The Four Notions of Session, Mapped to Modules

Chapter 3 introduced four distinct things called "session" on a modern system — the PAM session, the logind session, the kernel audit session, and the traditional utmp record — as a way of explaining why the word is so often a source of confusion. With this chapter's module reference now largely assembled, it is worth an explicit table connecting each notion to the specific module responsible for it, since the abstract distinction from Chapter 3 becomes considerably more concrete once each has a named piece of code behind it.

| Notion | Bounded by | Module responsible | Inspection command |
|---|---|---|---|
| PAM session | `pam_open_session()` / `pam_close_session()` | The framework itself, not any one module | No direct inspection — exists only within the calling process |
| Logind session | Registration with `systemd-logind` | `pam_systemd`, per 9.5 | `loginctl list-sessions` |
| Kernel audit session | `/proc/self/loginuid`, immutable once set | `pam_loginuid`, per 9.4 | `cat /proc/self/loginuid` |
| utmp record | Traditional login accounting | Historically `pam_lastlog` and application-level `utmp` writes, per 9.8 below | `who`, `w`, `last` |

The practical value of this table is diagnostic. When someone says "the session," the first useful question is which of these four rows they actually mean, since a problem with one has no necessary bearing on the others — a process can have a perfectly intact audit identity via `pam_loginuid` while having no logind session at all, per 9.5's description of what happens when `pam_systemd` is absent or fails, and both of those can be entirely fine while the utmp record is stale or missing due to an unrelated application-level bug. Chapter 3's original point — that these four notions can and do disagree with each other on a real system — is precisely why this table exists as a diagnostic tool rather than only an explanatory one: when four things called "session" give four different answers, knowing which module owns which answer is what lets you resolve the disagreement rather than simply note that it exists.

Run all four inspection commands after one ordinary interactive login and confirm they tell a consistent story; this is worth doing once on a system you administer as a baseline, specifically so that a future disagreement between them — like this chapter's opening scenario, where the logind/lingering row kept a process alive independent of what the account-lockout mechanisms in Chapter 8 had already correctly decided — is recognisable as a disagreement rather than mistaken for a single, simple "session" behaving inconsistently for no reason.

---

## 9.8 `pam_keyinit`, `pam_namespace`, and the Remaining Small Modules

Consistent with Chapter 6's treatment of several small `auth`-stack modules together, a briefer pass through the remaining `session`-stack modules worth knowing by name, each doing one specific, narrow thing.

### `pam_keyinit`

Creates a new session keyring, the kernel facility used by `request-key`-based subsystems (certain filesystem encryption schemes, some Kerberos credential caching implementations) to store cryptographic material scoped to a session's lifetime. `force` (module argument) discards any inherited keyring rather than reusing one; `revoke` invalidates the keyring on session close rather than leaving it to be garbage-collected. Absence of this module does not break ordinary password-based logins, but breaks any subsystem specifically relying on a properly scoped session keyring — worth checking for if such a subsystem is in use and behaving unexpectedly.

### `pam_namespace`

Implements polyinstantiated directories — different users, or the same user in different security contexts (relevant on SELinux-enabled systems), getting genuinely separate instances of a directory such as `/tmp`, configured via `/etc/security/namespace.conf`, rather than sharing one. This is a meaningfully more advanced and more rarely deployed mechanism than anything else in this chapter, generally seen on systems with specific multi-level-security or strict per-user isolation requirements rather than as a general-purpose default.

### `pam_umask`

Sets the process umask for the session, from `/etc/login.defs` or module arguments, ensuring newly created files get consistent, policy-appropriate default permissions regardless of what umask value a user's shell startup files might otherwise set or fail to set.

### `pam_motd`

Displays the message of the day, from `/etc/motd` or, on distributions using the dynamic-MOTD mechanism, from `/run/motd.dynamic` generated by a separate script run elsewhere. Purely informational, essentially always `optional`, and about as close to a purely cosmetic module as this series encounters.

### `pam_mail`

Checks for new mail and displays a notification, reading the traditional mail spool location. Largely a holdover from an era of universal local mail delivery, still present in most distribution default stacks out of inertia more than active current utility on most modern deployments, and safe to remove entirely on a system with no local mail delivery configured.

### `pam_lastlog`

Where still present — recall Chapter 1's version-churn note that this module's status has shifted across recent Linux-PAM releases — records and optionally displays the time and origin of the previous login, the traditional source of the "Last login: ..." banner. Worth checking whether it is present and functioning at all on a current system before assuming this banner's absence indicates a configuration problem rather than a version change:

```
$ ls /lib/*/security/pam_lastlog.so /usr/lib64/security/pam_lastlog.so 2>/dev/null
```

### `pam_cap`

Sets Linux capabilities (in the `CAP_*` sense — this repository's own Linux Capabilities section covers the underlying kernel mechanism in depth) for the session, from `/etc/security/capability.conf`, allowing specific accounts to be granted specific narrow privileges without full root, in a manner conceptually adjacent to but mechanically distinct from `sudo`.

---

## 9.9 `pam_exec`

### What it does

Executes an arbitrary external program during whichever stack it is placed in — most commonly `session`, though nothing prevents its use elsewhere, which is itself worth flagging.

### Which groups it serves

All four, mechanically — it is not restricted to `session` the way most of this chapter's other modules are, though `session` is by far its most common and most defensible placement.

### Why this module gets its own security-focused treatment here

Every other module in this chapter does one specific, bounded thing, implemented in compiled code that has been through the same scrutiny as the rest of Linux-PAM. `pam_exec` does whatever the script or binary it invokes does, with the full privilege of the calling process — per Chapter 1's foundational point about modules being arbitrary code running in a root process, `pam_exec` is the module that makes that abstract risk into something concretely, deliberately configurable by an administrator, on purpose, as a feature.

```
session  optional  pam_exec.so  /usr/local/bin/notify-login.sh
```

This is legitimate and common — logging a login event to an external system, triggering a notification, integrating with something PAM has no dedicated module for. It is also, unchanged in form, exactly what a backdoor disguised as ordinary configuration looks like, which is precisely Chapter 1's attack-surface warning made concrete: a single line, no binary modified, nothing for a file-integrity monitor watching only executables to notice.

### Arguments

`stdout` — pass the invoked program's standard output back into the PAM conversation, allowing it to display messages to the user.

`quiet` — suppress the module's own logging of the invocation.

`seteuid` — run the invoked program as the target user rather than as whatever privilege the calling process currently holds, relevant when the script should not need full privilege.

`expose_authtok` — pass the authentication token to the invoked program's standard input, a specific and sensitive capability worth treating with particular caution, since it means the external script receives the actual password.

### The environment inheritance path

Worth naming explicitly since it is a specific and non-obvious risk: whatever the invoked program does, it does with the environment and privilege context of the calling process at that point in the stack — which, per Chapters 3 and 5, can include values derived from PAM items the application supplied, such as `PAM_RHOST`. A script trusting values from this environment without validation is a script trusting client-supplied data inside a privileged context, precisely the kind of pattern this series has flagged as risky in several other places, now appearing again at the point where PAM configuration meets arbitrary external code directly.

### Return values

The invoked program's exit status maps to `PAM_SUCCESS` (exit 0) or a failure value (non-zero), which the surrounding stack's control flag then evaluates in the ordinary way per Chapter 4 — meaning a script that exits non-zero for an unrelated, unintended reason (a missing dependency, a permissions problem on a `required` line) can deny a login exactly as if the module itself had failed, a class of failure worth including in any troubleshooting checklist for a stack you know includes `pam_exec`.

### Interactions

With whatever the invoked script itself interacts with — by design, unbounded, and this is exactly the point: `pam_exec` is PAM's deliberate escape hatch into arbitrary integration, and its interactions cannot be enumerated the way a purpose-built module's can.

### Failure modes

Every failure mode from Chapter 5's module-bug catalogue applies to the invoked script exactly as it would to a compiled module — a script that hangs waiting for input that will never come under a non-interactive caller, per Chapter 3's conversation-function discussion; a script trusting unvalidated environment data; a script whose failure path is untested and denies logins for reasons entirely unrelated to its intended purpose. And, distinctly, the deliberate-misuse case: any `pam_exec` line encountered in an inherited or unfamiliar configuration deserves the same scrutiny Chapter 1 recommended for the module directory itself — read exactly what it runs, confirm who can write to that path, and treat an unexplained occurrence as a finding rather than routine configuration.

```
$ grep -rn pam_exec /etc/pam.d/
```

Every result needs an owner who can explain what it does and why.

---

## 9.10 Assembling and Reading a Complete `session` Stack

Bringing this chapter's modules together against a realistic Debian `common-session` plus `sshd`'s own additions, in the shape first shown in the README and revisited throughout this series:

```
session  required   pam_env.so   readenv=1
session  required   pam_limits.so
session  required   pam_unix.so
session  optional   pam_systemd.so
session  optional   pam_mail.so   standard noenv
session  optional   pam_motd.so   motd=/run/motd.dynamic
session  required   pam_loginuid.so
```

Read this the way 9.1 recommended: sort each line into "decision" versus "construction," and within construction, "required for a functioning session" versus "cosmetic or best-effort." Doing this sort explicitly, line by line, on a stack you administer is a more useful exercise than it might sound — most administrators can recite what each module in a familiar stack does, but far fewer have consciously separated that knowledge into the two categories this chapter has spent its length establishing, and the separation is what actually drives sound control-flag decisions when a stack needs editing.

`pam_loginuid` and `pam_limits`, both `required` — genuine, if unusual for this group, hard requirements; per this chapter's earlier discussions, their absence has serious consequences (Chapter 11's audit trail; potential resource exhaustion) even though neither is making an access-control decision in the sense Chapters 6 through 8 covered. `pam_env`, also `required` here though its own failure modes are rare enough that this is mostly a formality. `pam_systemd`, `pam_mail`, `pam_motd`, all `optional` — construction that enriches the session but whose absence should not deny a login, exactly matching Chapter 4's general observation about why `session` stacks lean so heavily on `optional`.

Trace what happens if `pam_systemd` fails, per Chapter 4's algorithm: `optional` maps failure to `ignore`, the failure is discarded, and the stack continues — the user gets a shell, but per 9.5, without a logind session, without `XDG_RUNTIME_DIR`, and any tooling depending on either will behave oddly. This is exactly the "diffuse, hard-to-diagnose symptom" 9.5 described, now visible as a direct consequence of this stack's specific control-flag choices rather than an abstract possibility. It is worth performing this same trace-by-hand exercise against your own generated `common-session`, since the specific set of `optional` versus `required` lines, and therefore the specific set of failures that would deny a login versus merely degrade it, varies between distributions and is not something to assume matches the illustrative stack above.

---

## 9.11 A Hardening and Correctness Checklist for the `session` Stack

Consistent with the checklist format of the two preceding chapters, adapted for this group's different character.

**1. Is `pam_loginuid` present on every service offering shell or command access?** Per 9.4's audit command, repeated from Chapter 5.

**2. Has the `pam_limits`/systemd-cgroup seam, per 9.2, actually been checked with both commands** — `ulimit -a` and the `systemctl show` equivalents — rather than assumed consistent from `limits.conf` alone?

**3. Are `limits.d/` drop-ins from different packages checked for conflicts**, per 9.2's lexical-ordering note?

**4. Does every environment variable a downstream service depends on actually flow through a mechanism that service's own PAM stack traverses**, per 9.3's three-mechanism distinction — not assumed set simply because it appears correctly in `pam_env.conf`?

**5. Is lingering, per 9.5, enabled only where a deliberate, documented reason exists**, and audited against currently disabled or locked accounts specifically?

**6. Does every `pam_exec` line in every stack on this system have a known owner and a stated purpose**, per 9.9's grep command and its warning?

**7. Has `/etc/skel`, per 9.6, actually been reviewed recently**, rather than assumed to still reflect current policy?

**8. For any service where `pam_systemd` is `optional` and its absence would produce a meaningfully broken (rather than merely diminished) experience, has that specific failure been tested directly**, per 9.10's trace, rather than assumed to be a harmless `optional` line like the others around it?

**9. Has the lingering audit from 9.5 been run against every disabled or locked account on this system**, specifically checking for the combination of `linger=yes` and a locked or expired account status that this chapter's opening scenario turned on?

---

## 9.12 Verification

Test machine, snapshot, second root shell.

**1. Reproduce the `pam_limits`/systemd seam directly.**

Set a restrictive `nproc` limit in `limits.conf` for a test user, log in, and confirm `ulimit -u` reflects it. Then set a *more* restrictive `TasksMax=` on that user's systemd slice via `systemctl set-property user-<uid>.slice TasksMax=10` (or the drop-in equivalent) and confirm processes are constrained by the systemd limit even where `ulimit -u` reports a higher number — demonstrating 9.2's caveat concretely rather than accepting it as a claim.

**2. Distinguish the three environment-setting mechanisms from 9.3.**

Set the same variable name to three different values via `pam_env.conf`, `/etc/environment`, and `~/.bashrc` respectively. Log in interactively and note which value is visible in the shell. Then run a command non-interactively via `ssh host command` (which does not source `.bashrc` in the ordinary case) and note which value, if any, is visible there — confirming the scope differences stated in 9.3 rather than assumed.

**3. Confirm `pam_loginuid`'s immutability across a privilege transition.**

Run `cat /proc/self/loginuid`, then `sudo cat /proc/self/loginuid`, then `sudo su - someuser -c 'cat /proc/self/loginuid'`. Confirm the value is identical across all three despite the process's effective and real UID changing at each step.

**4. Audit `pam_loginuid` presence system-wide, per 9.4.**

```
$ grep -L pam_loginuid $(grep -l 'session' /etc/pam.d/*)
```

For each result offering shell or command access, treat it as a finding per this chapter's framing, and correct it.

**5. Observe a logind session and its cgroup scope directly.**

After an interactive login, run `loginctl session-status` for the current session, then `systemctl status` on the corresponding scope unit, then `systemd-cgls`, confirming you can trace the same session through all three views and connecting each to the specific piece of 9.5's description it corresponds to.

**6. Enable and audit lingering.**

```
$ loginctl enable-linger testuser
```

Start a long-lived `systemd --user` service as that user, log out completely, and confirm the service is still running. Then lock the account via a Chapter 8 mechanism and confirm the lingering process is *not* automatically stopped — demonstrating the account-lifecycle gap 9.5 flagged explicitly. Finally, run the full audit loop from 9.5 against every account on the test system and confirm it correctly identifies the deliberately created gap.

**7. Trigger `pam_mkhomedir` and inspect the result.**

Following 9.6's worked example, confirm a home directory is created from the current `/etc/skel` contents on first login for an account with no pre-existing home directory.

**8. Audit every `pam_exec` line on a real system.**

```
$ grep -rn pam_exec /etc/pam.d/
```

For each result, read the invoked script or binary in full, and confirm it does not trust unvalidated PAM-item-derived environment data without at least being aware that it is doing so, per 9.8's specific warning.

**9. Deliberately break `pam_systemd` and observe the diffuse failure mode.**

Comment out the `pam_systemd` line in a test service's `session` stack (leaving it `optional` elsewhere unaffected), log in, and confirm `XDG_RUNTIME_DIR` is unset and `loginctl list-sessions` shows nothing for this login — then attempt to use something depending on either, such as a D-Bus session tool, and observe the failure mode directly rather than only reading 9.5's description of it.

**10. Complete the hardening checklist from 9.10 against a real system**, treating each item as a genuine audit step rather than a read-through, per this entire series' running insistence on testing rather than inspecting.

---

## Where This Goes Next

You now have the complete `session`-group reference, and with it, the full module-level picture across all four management groups this series set out to cover starting in Chapter 3. The character of this chapter's material — construction and teardown rather than decision — is worth holding onto as a genuinely different mode of reading than Chapters 6 through 8 required, and 9.1's opening framing is worth revisiting any time an unfamiliar `session`-stack module needs sorting into "decision" or "construction" before its manual page is even opened. This chapter's opening scenario is worth carrying forward specifically alongside that framing: a correctly enforced `account`-stack decision, from Chapter 8, said nothing at all about a `session`-stack construction decision — lingering — made months earlier and never revisited. The four groups genuinely are independent in the sense Chapter 3 first established, and this chapter's scenario is what that independence costs an organisation when only three of the four groups get regular audit attention.

Chapter 10 shifts scope entirely — not another management group, since all four are now covered, but the integration layer underneath everything this series has discussed: NSS and its precise, frequently confused boundary with PAM; SSSD, LDAP, and Kerberos as the directory-backed alternatives to the purely local `pam_unix`-centred stacks this and the preceding three chapters mostly assumed; and second-factor and hardware-token modules, placed correctly against the SSH-key-bypass concern this chapter and Chapter 8 have both returned to repeatedly. Four complete service traces — `sshd`, `sudo`, `su`, `runuser` — bring every group from Chapters 6 through 9 together in the way Chapter 1's single shallow `su` trace first promised back at the very start of this series. One thread this chapter leaves specifically for Chapter 10 to pick up: `pam_mkhomedir` in 9.6 was framed almost entirely around directory-backed accounts without yet explaining what a directory-backed account actually is at the NSS level — that gap closes there.

---

## Further Reading for This Chapter

- `man 8 pam_limits` and `man 5 limits.conf`
- `man 5 systemd.resource-control`, for the cgroup-side counterpart to `pam_limits` covered in 9.2's central caveat
- `man 8 pam_env` and `man 5 pam_env.conf`
- `man 8 pam_loginuid`
- `man 8 pam_systemd`, `man 1 loginctl`, `man 5 logind.conf`
- `man 8 pam_mkhomedir`
- `man 8 pam_keyinit`, `man 8 pam_namespace`, `man 5 namespace.conf`, `man 8 pam_umask`, `man 8 pam_motd`, `man 8 pam_mail`, `man 8 pam_lastlog` (if present on your version), `man 8 pam_cap`, `man 5 capability.conf`
- `man 8 pam_exec` — read in full, specifically the security considerations section if your version's manual page includes one
- `man 5 systemd-user-sessions.service` and the lingering documentation under `man 1 loginctl`
- `man 1 who`, `man 1 w`, `man 1 last`, for the traditional utmp-based view referenced in 9.7's four-notions table
- Your own distribution's generated `common-session` or equivalent, sorted using 9.1's decision-versus-construction framing, the same closing exercise the three preceding chapters have each recommended for their own module sets

This chapter, like Chapters 6 through 8 before it, is meant to be reopened as a reference rather than read start to finish a second time — the next time a `session`-stack module needs explaining or a login environment is behaving unexpectedly, 9.1's decision-versus-construction framing and 9.7's four-notions table are the two sections worth consulting first, before any manual page.
