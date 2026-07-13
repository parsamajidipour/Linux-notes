# 13 — Best Practices

Every prior chapter ended by handing something to the next. This one collects
what all of them handed forward. It is deliberately the *last* substantive
chapter, because a best-practices note written first is a checklist — a list of
rules to obey without knowing why — and this series has spent twelve chapters
earning the right to write one that isn't. Each recommendation here is a
**consequence of a mechanism already established**, and is stated with a
pointer back to the chapter that justifies it. The test for including a
practice was simple: if it can't be traced to something the series demonstrated
about how `sudo` actually works, it doesn't belong here.

The organizing claim of the whole series — that `sudo` sits astride a **trust
boundary** (Chapter 10), and that untrusted input must never corrupt, bypass,
or leak into privileged execution — is the single principle every practice
below specializes. Read this chapter as that one invariant, applied
concretely to policy, environment, authentication, logging, and operations.

## 1. Why "best practices," derived rather than listed

The defensive principles at the end of Chapter 10 — minimize privileged code
on untrusted input, whitelist over blacklist, grant capabilities not
conveniences, isolate the command, fail closed, keep off-host evidence — are
the spine. Chapter 11 turned one of them (grant capabilities not conveniences)
into an operational catalog. Chapter 12 gave the tools to verify that a
configuration behaves as intended. This chapter closes the loop: it states the
hardening posture for a real deployment, with each item labeled by the class
or chapter it descends from, so that the *reason* travels with the rule. A
practice you understand the mechanism behind is one you can adapt when your
situation differs from the default; a practice you merely memorized is one you
apply wrongly the moment conditions change.

## 2. Policy: grant capabilities, not conveniences

This is the Class D principle (Chapters 10, 11), and it is the single
highest-leverage area because it is the one failure class that lives entirely
in *policy* rather than in `sudo`'s code — meaning it is entirely within the
administrator's power to prevent, and no patch will save a deployment that
gets it wrong.

- **Grant specific commands with specific arguments, never bare
  interpreters, shells, editors, or pagers** (Chapter 11 §2–3). An
  interpreter's capability *is* arbitrary code execution; granting it as root
  is granting root. If a script must run privileged, grant the root-owned,
  non-writable *script* — never the interpreter that could run any script.
- **Use `sudoedit`, never `sudo vim`** (Chapters 11 §3, 10 §10). Editors have
  shell escapes even with the filename constrained; `sudoedit` edits a copy as
  the user and writes back with privilege, keeping the editor itself
  unprivileged.
- **Enumerate exact invocations; reason adversarially about every `*`**
  (Chapter 11 §5). A wildcard is an implicit "any value" whitelist. Ask what
  the worst string matching that pattern can do, not what you intended it to
  match.
- **Name runas targets explicitly; never blacklist them** (Chapters 10 §3,
  11 §8). `(ALL, !root)` is the shape that `CVE-2019-14287` defeated with
  `-u '#-1'`. Whitelist the accounts a user may become; do not try to subtract
  the dangerous ones from `ALL`.
- **Reserve `NOPASSWD` for safe, non-escapable, tightly-argued commands**
  (Chapter 11 §6). `NOPASSWD` converts "a human who knows the password" into
  "any code running as that user"; it belongs on `systemctl restart nginx`,
  never on an interpreter or `ALL`.

The verification habit from Chapters 04 and 12 is the safety net:
**`sudo -l -U <user>`** renders what a user can *actually* run, resolved — audit
by reading that, not the raw file.

## 3. Environment: keep the whitelist closed

This is the Class C principle (Chapters 07, 10). The kernel's `AT_SECURE`
protects the dynamic loader but *not* the target command, so userspace
sanitization is the only defense — and its default posture is correct.

- **Leave `env_reset` on** (Chapter 07). It whitelists a minimal environment
  rather than blacklisting known-dangerous variables; the whitelist is the
  reason `LD_PRELOAD` and friends can't reach the target.
- **Loosen `env_keep` only with an explicit, written justification**
  (Chapters 07, 11 §9). Every variable you preserve is untrusted input you are
  choosing to pass into privileged execution. Preserving `LD_*` or `*PATH`
  re-opens the exact class `env_reset` closes.
- **Rely on `secure_path`, don't fight it** (Chapters 07, 12 §2). The
  compiled-in `secure_path` is why a caller's `PATH` can't redirect a rule's
  command to a planted binary. If a rule needs a nonstandard directory, add it
  to `secure_path` deliberately rather than preserving the user's `PATH`.
- **Avoid `SETENV` on anything that can execute code** (Chapter 11 §9).
  Letting the caller set the environment of an interpreter is equivalent to
  letting them set `LD_PRELOAD`.

## 4. Authentication: understand what PAM is deciding

This descends from Chapter 06: `sudo` does not authenticate, it delegates to
PAM, and the `auth`, `account`, `session`, and `password` stacks each decide
something different.

- **Review the `auth` stack's control flags as carefully as any `sudoers`
  rule** (Chapter 06 §13). A misplaced `sufficient` or a removed `pam_deny.so`
  fall-through can turn a failed check into a success. The strength of `sudo`'s
  authentication is entirely the strength of `/etc/pam.d/sudo`.
- **Prefer the invoker's own credential; be wary of `rootpw`/`targetpw`**
  (Chapter 06 §10). These change *whose* secret is checked and reintroduce the
  shared-secret weakness `sudo` was built to avoid (Chapter 02).
- **Treat authentication and authorization as separate gates** (Chapter 06
  §13). They come from different subsystems, fail differently, and are fixed in
  different files — a distinction Chapter 12 §7 showed how to diagnose.
- **Remember `NOPASSWD` waives authentication, not accountability** (Chapters
  06, 09 §1). It skips the password gate; it does not skip the log. Its risk is
  authorization, not audit.

## 5. The command's isolation and integrity

This is the Class E principle (Chapter 10 §10) and the file-integrity
requirement from Chapter 11 §7.

- **Keep `use_pty` on** (Chapters 09 §6, 10). Running the command on its own
  pseudo-terminal closes the `TIOCSTI`/terminal-injection class where a command
  could push characters back into `sudo`'s own tty. It is a default worth
  preserving, and it is also what makes I/O logging possible.
- **Every granted command — and every directory in its path — must be
  root-owned, non-writable by others, and absolute** (Chapter 11 §7). If the
  target or any parent directory is writable, the target itself is untrusted
  input, and the grant becomes an arbitrary-code grant regardless of how tight
  the rest of the rule is.

## 6. Logging: assume breach, keep off-host evidence

This is the "keep evidence" principle (Chapters 09, 10) and it is the one that
holds even after every other control has failed.

- **Log off-host** (Chapter 09 §10). Local logs live on a machine whose whole
  purpose is that people become root on it; a root-capable adversary can erase
  them. `sudo_logsrvd` (or a syslog forwarder shipping `authpriv` off the
  host) is what makes the audit trail bind someone who can reach root. Without
  it, "the audit trail" is only as trustworthy as the goodwill of whoever holds
  root.
- **Enable I/O logging on high-risk rules deliberately, before an incident**
  (Chapters 09 §6, 12 §8). It is the only layer that records what happened
  *inside* an allowed interactive command — and `sudoreplay` can only
  reconstruct sessions that were being captured at the time.
- **Treat I/O logs as among the most sensitive files on the system**
  (Chapter 09 §9). They are time-ordered transcripts of privileged sessions,
  potentially studded with secrets typed into sub-commands. Owned by root,
  unreadable by others, ideally off-host.
- **Emit structured (JSON) logs for SIEM ingestion, and correlate with
  `auditd`** (Chapter 09 §11). Two independent views of the same execution
  are two things a tampering adversary must defeat separately.

## 7. Patching and the code you cannot see

This descends directly from Class A (Chapter 10 §3): `sudo` is a large,
memory-unsafe, setuid-root program that parses attacker-controlled input while
already privileged, so a parsing bug is a root exploit.

- **Keep `sudo` patched, and treat `sudo` advisories as critical by default**
  (Chapter 10 §9). Class A bugs — `CVE-2021-3156` is the canonical specimen —
  are reachable *before authentication* by *any local user* and run *as root*.
  They surface periodically and there is no configuration that mitigates a
  memory-corruption bug in the pre-auth parser; only the patch does.
- **Minimize who can invoke `sudo` at all.** The pre-authentication parser is
  the highest-risk code in the program (Chapter 10 §10); every account that
  cannot run `sudo` is an account that cannot reach that code. Membership in
  `sudo`/`wheel` is itself a grant (Chapter 11 §10) — keep it to real
  administrators, and scope everyone else to purpose-specific groups and tight
  rules.

## 8. Protect the trusted side itself

Chapter 10 §2 drew the line between the untrusted side (what the user controls)
and the trusted side (what the administrator controls). The trusted side is
only trustworthy if it is actually protected from the untrusted side.

- **`/etc/sudoers` and `sudoers.d`: `0440 root:root`, edited only with
  `visudo`** (Chapter 11 §11). `visudo` fails closed on a parse error, so a
  syntax mistake can never leave a broken policy that fails *open*. Writable
  policy is attacker-controlled policy.
- **`/etc/sudo.conf` and every plugin `.so` must be root-owned and
  unwritable** (Chapter 05 §12). They are as trusted as `sudo` itself; a
  writable `sudo.conf` pointing at a malicious plugin is a full compromise, and
  `sudo` refuses to load plugins from unsafe locations for exactly this reason.
- **`/etc/pam.d/sudo` is part of the trusted side too** (Chapter 06). Its
  permissions and contents deserve the same protection as `sudoers`.

## 9. Verify, don't assume

This is the operational discipline of Chapter 12, restated as standing habit
rather than incident response.

- **Audit policy by rendering it, not reading it** (Chapters 04 §12, 11 §12).
  `sudo -l -U <user>` shows the resolved reality; the raw file shows intent,
  and Chapter 12 §5 demonstrated they can differ at runtime (hostname
  resolution, alias expansion).
- **Confirm the binary and its defaults with `sudo -V`** (Chapter 12 §2).
  Know which `sudo`, which plugins, and which compiled `secure_path` are
  actually active — surprisingly often the source of "strange" behavior.
- **When behavior surprises you, trace the stage, don't guess** (Chapter 12).
  The debug subsystem, PAM debug, `strace`, and `sudoreplay` each answer for a
  specific stage; the symptom-to-tool map exists so debugging starts from a
  hypothesis.

## 10. A minimal hardened baseline

Pulling the practices into one concrete shape — not a template to paste
blindly, but an illustration of the posture:

```sudoers
# --- Defaults: the safe posture, mostly already default -------------------
Defaults  env_reset                       # Chapter 07: whitelist the environment
Defaults  secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults  use_pty                         # Chapter 10: isolate on own pty
Defaults  log_input, log_output           # Chapter 09: capture sessions...
Defaults  log_servers=logserver.example.com:30344   # ...and ship them off-host
Defaults  log_format=json                 # Chapter 09: SIEM-friendly
Defaults  passwd_timeout=1, timestamp_timeout=5      # short auth windows

# --- Grants: specific commands, specific targets, no interpreters ---------
Cmnd_Alias WEB_CTL = /usr/bin/systemctl restart nginx, \
                     /usr/bin/systemctl reload nginx
Runas_Alias WEB = www-data

webops  ALL = (root) NOPASSWD: WEB_CTL     # narrow, non-escapable, argued
deploy  ALL = (WEB)  /opt/deploy/run.sh    # the script, not the interpreter
```

```console
# /etc/sudoers and drop-ins:
$ ls -l /etc/sudoers /etc/sudoers.d /etc/sudo.conf
-r--r----- 1 root root ...  /etc/sudoers        # 0440 root:root
# verify what it actually grants, per user:
$ sudo -l -U deploy
$ sudo -l -U webops
```

Every line above is a practice from a prior chapter, and every one can be
justified by pointing at the mechanism it defends. That traceability is the
whole point: this baseline is not "the secure config" to be copied, but a
worked demonstration of *deriving* a config from the invariant.

## 11. What not to do — the anti-patterns, one place

For symmetry with Chapter 11's catalog, the recurring mistakes, each already
dissected:

- `user ALL=(ALL) /usr/bin/python3` — interpreter as root (Class D). Grant the
  script.
- `user ALL=(ALL) NOPASSWD: ALL` — waives auth on *everything* (Classes B, D).
- `(ALL, !root)` — blacklisted runas, defeated by `-1` (Class B).
- `Defaults !env_reset` or broad `env_keep` of `LD_*`/`*PATH` — re-opens
  Class C.
- Writable command target, relative path, or writable parent directory —
  makes the target untrusted (Class D/§5).
- Editing `sudoers` with a plain editor instead of `visudo`; world-readable or
  writable `sudoers`/`sudo.conf` — attacks the trusted side (§8).
- Local-only logging on a host where users become root — no integrity
  (Chapter 09 §10).
- Running an out-of-date `sudo` — leaves Class A open with no config
  mitigation (§7).

## 12. What this chapter established

- Best practices for `sudo` are not a checklist but **the trust-boundary
  invariant of Chapter 10, specialized** to policy, environment,
  authentication, isolation, logging, patching, and operations — each practice
  labeled by the mechanism that justifies it.
- **Policy (Class D):** grant specific commands and arguments, never
  interpreters/shells/editors/pagers; `sudoedit` not `sudo vim`; whitelist
  runas targets; reserve `NOPASSWD` for safe commands; audit with `sudo -l -U`.
- **Environment (Class C):** keep `env_reset` on, loosen `env_keep` only with
  justification, rely on `secure_path`, avoid `SETENV` on code-runners.
- **Authentication (Chapter 06):** scrutinize the PAM `auth` stack's flags,
  avoid `rootpw`/`targetpw`, keep authentication and authorization distinct,
  and remember `NOPASSWD` waives the password but not the log.
- **Isolation & integrity (Classes E/§5):** keep `use_pty`; every command and
  every directory in its path root-owned, non-writable, absolute.
- **Logging (Chapter 09):** off-host (`sudo_logsrvd`) for integrity, I/O
  logging enabled proactively on high-risk rules, logs treated as highly
  sensitive, structured output plus `auditd` correlation.
- **Patching (Class A):** keep `sudo` current — pre-auth memory bugs have no
  config mitigation — and minimize who can invoke it at all.
- **The trusted side (Chapters 05, 06, 11):** `sudoers`/`sudo.conf`/`pam.d`
  protected as `0440 root:root`, `visudo`-only, plugins from safe locations.
- **Verification (Chapter 12):** render policy rather than read it, confirm the
  binary with `sudo -V`, and trace the stage rather than guess when behavior
  surprises you.
- The **hardened baseline** (§10) is a *derivation*, not a template: every line
  traces to a mechanism, which is what lets it be adapted rather than merely
  copied.

The final chapter is not another argument but the series' foundation made
explicit. *References* collects the primary sources every claim here was
grounded in — the `sudo` source tree, the man pages, the kernel's
`credentials(7)`/`capabilities(7)` documentation, the PAM specification, and
the advisories for the CVEs used as specimens — so that, per the README's
discipline, any disagreement between this series and the source can be
settled by the source.
