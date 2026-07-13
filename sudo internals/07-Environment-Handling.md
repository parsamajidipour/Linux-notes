# 07 — Environment Handling

Three chapters have now deferred to this one. Chapter 02 showed a setuid wrapper
destroyed by a poisoned `PATH`. Chapter 03 Stage 7 named "environment
construction" and moved on. Chapter 06 ended by pointing here. The reason so much
converges on the environment is that it is the single largest channel of
caller-controlled input into a privileged process, and — unlike command
arguments, which `sudo` at least scrutinizes against policy — the environment is
a sprawling, open-ended dictionary of strings, any one of which might change how
the executed program behaves.

This chapter is about how `sudo` dismantles the hostile environment it inherits
(Chapter 03 Stage 0) and manufactures a safe one for the command. It covers the
mechanism by which an environment variable becomes root code execution, a subtle
and widely-misunderstood fact about why the dynamic loader's own defenses do
**not** protect `sudo`'s target command, and then the concrete `sudoers`
machinery — `env_reset`, `env_keep`, `env_check`, `env_delete`, `secure_path` —
that closes the hole, along with the ways a permissive policy re-opens it.

## 1. The environment as attack surface

Recall the hand-off from Chapter 03 Stage 0: when your shell `execve`s `sudo`, it
passes `sudo` its **entire** environment as `envp`. Every variable your shell
held — hundreds of them, thousands of bytes — arrives in the `sudo` process,
which is already `euid 0`. None of it is trustworthy; all of it originates from
the unprivileged user requesting elevation.

The environment is uniquely dangerous among input channels for three reasons.
First, it is **inherited by default** across `execve` unless something
deliberately intervenes — so without action, `sudo` would pass the poison
straight through to the command it runs as root. Second, it is **interpreted by
code the program author never wrote**: the dynamic loader, the C library, the
shell, and the language runtime all consult environment variables *before*
`main()` runs or during ordinary library calls, so a variable can alter behavior
without the target program containing a single line that reads it. Third, it is
**huge and open-ended**: there is no fixed schema, so a defense cannot simply
validate known fields — it must decide a policy for the entire, unbounded space.

## 2. How an environment variable becomes code execution

To justify the severity, walk the concrete paths from "a string in the
environment" to "arbitrary code running as root." Each of these is a real class,
not a hypothetical:

- **`LD_PRELOAD`** — names shared objects the dynamic loader loads *before* all
  others, letting them override any symbol. Set `LD_PRELOAD=/tmp/evil.so` and a
  privileged dynamically-linked program calls your `evil.so`'s constructor as
  root, before `main`.
- **`LD_LIBRARY_PATH`** — prepends directories to the library search path, so a
  malicious `libc.so.6` in an attacker directory is loaded instead of the real
  one.
- **`LD_AUDIT`** — loads an "auditing" object into the link namespace, another
  pre-`main` code-execution vector.
- **`PATH`** — decides which binary a bare command name resolves to. The Chapter 02
  wrapper died here: a privileged program that runs `tar` (not `/usr/bin/tar`)
  runs the attacker's `tar` if `PATH` points at it.
- **`IFS`** — the shell's field separator. Historically, manipulating `IFS` before
  a privileged shell script ran could turn a call like `system("/bin/prog")` into
  execution of a differently-tokenized command.
- **`BASH_ENV` / `ENV`** — name a startup file the shell sources on non-interactive
  invocation. A privileged shell script starts by executing the attacker's file.
- **Interpreter path variables** — `PYTHONPATH`, `PERL5LIB`, `RUBYLIB`,
  `NODE_PATH`, `PYTHONSTARTUP`. If the privileged command is a script,
  these inject attacker-controlled modules or startup code into the interpreter
  running as root.
- **`TZ`, `LC_*`, `NLSPATH`, `TERMINFO`** — locale, timezone, message-catalog, and
  terminal databases parsed by libc/ncurses. These have historically enabled
  path-traversal and format-string style attacks through "harmless-looking"
  formatting variables.

The unifying observation: for a privileged process, a startling number of
environment variables are **not data but control** — they steer the loader, the
libc, the shell, or the runtime. That is why the environment cannot be passed
through; it must be treated as hostile and rebuilt.

## 3. Why the loader will not save you: `AT_SECURE` and the target

Here is the subtle point that most treatments get wrong, and it is the deepest
reason this chapter exists.

The dynamic loader *does* have a defense. When the kernel `execve`s a binary
whose execution elevates privilege — a setuid or setgid binary, or one gaining
file capabilities — it sets a flag, **`AT_SECURE`**, in the process's auxiliary
vector. glibc's loader reads this flag (`__libc_enable_secure`) and, in this
"secure-execution mode," **strips a hardcoded list of dangerous variables** —
`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and many others — before they can
take effect. This is why, in Chapter 02, a bare setuid wrapper was *not*
vulnerable to `LD_PRELOAD` (only to the `PATH`/`system()` path).

Now apply it to `sudo`. You might assume the same protection covers the command
`sudo` runs. It does not, and the reason is precise:

`sudo` elevates via the setuid bit on **the `sudo` binary**. By the time `sudo`
executes the *target* command (Chapter 03 Stage 9), it has **already transitioned
its credentials** (Stage 8) so that real, effective, and saved UIDs are all the
target's. The target command is then `execve`d as an **ordinary, non-setuid
binary** by a process that *already holds* those credentials. No privilege change
happens at that `execve`. Therefore the kernel does **not** set `AT_SECURE` for
the target, the loader does **not** enter secure-execution mode, and it **would
honor `LD_PRELOAD` and friends** if they were still present.

```text
execve("/usr/bin/sudo", ...)   ← setuid bit fires, uid change → AT_SECURE SET
                                  (loader protects sudo itself)
setresuid(0,0,0) / setgroups   ← sudo changes its own credentials
execve("/usr/bin/id", ...)     ← ordinary binary, NO uid change here
                                  → AT_SECURE NOT set  → loader honors env!
```

The consequence is stark: **the loader protects `sudo`, but not the command
`sudo` runs.** Nothing in the kernel or libc will strip `LD_PRELOAD` from the
target's environment. If `sudo` did not remove it, `sudo cat /etc/shadow` with a
preloaded object would run attacker code as root. So the sanitization is not
belt-and-suspenders redundancy with the loader — it is the *only* line of defense
for the target command. `sudo` must do it, in userspace, itself.

## 4. `sudo`'s answer: `env_reset` and the whitelist model

`sudo`'s defense is the `env_reset` option, **on by default** in every modern
distribution:

```console
$ grep env_reset /etc/sudoers
Defaults        env_reset
```

`env_reset` inverts the default inheritance. Instead of passing the caller's
environment through and deleting known-bad variables (a blacklist), it **discards
the environment entirely and rebuilds a minimal one** (a whitelist). The command
starts from near-nothing, and only explicitly-permitted variables are added back.

The manufactured environment consists of:

- a small set of variables `sudo` sets itself for the target: `HOME`, `SHELL`,
  `LOGNAME`, `USER`, and `USERNAME` reflecting the target user; `MAIL`;
- `PATH` set to the trusted `secure_path` (§6) rather than the caller's;
- `TERM` (needed for terminal-aware programs);
- the `SUDO_*` provenance variables — `SUDO_USER`, `SUDO_UID`, `SUDO_GID`,
  `SUDO_COMMAND` — recording who invoked `sudo`;
- plus any variables permitted by `env_keep` and `env_check` (§5).

The difference is directly observable. Compare the caller's environment to what a
command actually receives under `sudo`:

```console
$ export LD_PRELOAD=/tmp/evil.so
$ export EVIL=1
$ env | grep -E 'LD_PRELOAD|EVIL|PATH'
LD_PRELOAD=/tmp/evil.so
EVIL=1
PATH=/home/parsa/bin:/usr/bin:/bin
$ sudo env | grep -E 'LD_PRELOAD|EVIL|PATH|SUDO_'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
SUDO_COMMAND=/usr/bin/env
SUDO_USER=parsa
SUDO_UID=1000
SUDO_GID=1000
```

`LD_PRELOAD` and `EVIL` are **gone**. `PATH` has been **replaced** with
`secure_path`. And `sudo` has added provenance. The whitelist model means the
attacker cannot smuggle a variable through simply by choosing one `sudo`'s authors
did not anticipate — anything not on the keep list is dropped by default. This is
the same architectural lesson as Chapter 04's "default-deny beats blacklist,"
applied to the environment.

## 5. The four knobs: `env_keep`, `env_check`, `env_delete`, reset-off

`sudoers` exposes four options that tune the environment policy. Their
interactions matter.

**`env_keep`** — the whitelist preserved *through* `env_reset`. Variables listed
here survive the reset unchanged. Distributions ship a conservative default
(often `DISPLAY`, `XAUTHORITY`, `TERM`, `PATH`, color and locale hints). Adding to
`env_keep` is the main way administrators re-open risk: putting `LD_PRELOAD` or
`PYTHONPATH` in `env_keep` deliberately defeats the whole mechanism for that
variable. Treat every `env_keep` addition as a security decision.

```sudoers
Defaults  env_keep += "PROXY_URL NO_PROXY"      # deliberate, reviewed additions
```

**`env_check`** — a *conditional* whitelist. Variables here are preserved **only
if their value contains neither `%` nor `/`**. The `%` guard defends against
format-string vulnerabilities in programs that feed the value to a `printf`-style
call; the `/` guard defends against path-based attacks (a variable being
interpreted as a filename). Locale and formatting variables (`LC_*`, `LANG`, `TZ`
in some configs) live here — useful to preserve, but only when their value cannot
carry a payload.

**`env_delete`** — the *blacklist*, relevant only when `env_reset` is **off**. It
lists variables to strip from the otherwise-inherited environment.

**`env_reset` off** — the legacy inheritance mode: keep the caller's whole
environment except what `env_delete` removes. This is strictly more dangerous than
the default, for exactly the reason Chapter 04 gave: a blacklist must anticipate
every dangerous variable, and the space is open-ended, so the next dangerous
variable the blacklist does not know about sails through. **Leave `env_reset`
on.** The only defensible reason to disable it is a tightly-controlled,
non-interactive context, and even then a scoped `env_keep` is usually the better
tool.

## 6. `secure_path`: closing `PATH` injection for good

`PATH` deserves its own treatment because it was the exact vector that destroyed
the Chapter 02 wrapper. Under `env_reset`, `sudo` does not merely keep or drop the
caller's `PATH` — it **replaces** it with `secure_path` from `sudoers`:

```sudoers
Defaults  secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

Every command run through `sudo` resolves bare command names against this fixed,
administrator-controlled path, regardless of what the caller's `PATH` was. Replay
the Chapter 02 attack against a `sudo`-run command and it fails:

```console
$ cat > /tmp/tar <<'EOF'
#!/bin/bash
cp /bin/bash /tmp/rootbash; chmod 4755 /tmp/rootbash
EOF
$ chmod +x /tmp/tar
$ sudo PATH=/tmp:$PATH tar --version 2>/dev/null   # attempt to inject /tmp/tar
$ ls /tmp/rootbash
ls: cannot access '/tmp/rootbash': No such file or directory
```

The injected `/tmp` never enters the command's `PATH`, because `secure_path`
overrode it and the `PATH=` on the command line was rejected (setting environment
variables on the command line requires the `SETENV` permission, §8). The class of
bug that made hand-rolled wrappers a menace is closed centrally, once, by
`secure_path` — which is a large part of why "use `sudo`" is safer than "write
your own setuid tool."

## 7. `HOME`, and the config-file attack

`HOME` is subtler than the loader variables and is often overlooked. Countless
programs read per-user configuration from `$HOME` — `~/.bashrc`, `~/.gitconfig`,
`~/.vimrc`, `~/.my.cnf`, `~/.ssh/config`. If a command runs as root but with
`HOME` still pointing at the *invoking user's* home directory, it will read *that
user's* configuration files — as root. A user who cannot otherwise escalate can
plant a malicious `~/.something` and wait for an admin to run a `sudo` command
that reads it.

Concretely: `git` executed as root with `HOME=/home/parsa` reads
`/home/parsa/.gitconfig`, and `git`'s config can specify an external `pager` or
`core.editor` or aliases that run commands — now as root. The user controls their
own `.gitconfig`; if `HOME` is not reset, they control what root's `git` executes.

`sudo`'s options here:

- Under `env_reset`, `sudo` sets `HOME` for the target user by default in most
  configurations, so the command reads root's config, not the caller's.
- **`always_set_home`** forces `HOME` to the target's home unconditionally.
- **`set_home`** does so for `sudo -s`.
- If `HOME` is added to `env_keep`, the protection is deliberately removed and the
  config-file attack re-opens.

The takeaway: `HOME` is a control variable too, just an indirect one — it controls
*which configuration files a privileged program trusts*. Keep it reset to the
target.

## 8. User-requested preservation: `-E`, `SETENV`, `VAR=value`

Sometimes a user legitimately needs to carry a variable into the command (a proxy
URL, a build flag). `sudo` allows this, but only under policy control:

- **`sudo -E command`** (`--preserve-env`) asks to preserve the *entire* caller
  environment. `sudo` grants this **only** if policy permits — the `setenv`
  option, or a `SETENV:` tag on the rule (Chapter 04 §7). Without permission,
  `sudo` refuses.
- **`sudo --preserve-env=LIST command`** preserves only named variables, still
  subject to permission.
- **`sudo VAR=value command`** sets a specific variable, again gated by `SETENV`.

```console
$ sudo -E env | grep EVIL          # denied unless setenv is granted
sudo: sorry, you are not allowed to preserve the environment
```

The security posture is: environment preservation is a privilege, not a default.
Granting `SETENV` or `setenv` widely re-introduces every attack in §2, because it
hands the caller back control of the variable space. Grant it narrowly, to
specific commands, for specific variables, and never on a rule that runs an
interpreter or shell.

## 9. Inspecting the actual policy

Never guess the environment policy — read it. As root, `sudo -V` prints the
compiled and configured lists for the running system:

```console
# sudo -V | sed -n '/Environment variables to (check|remove|preserve)/,+3p'
Environment variables to check for safety:
        TZ
        LC_*
        ...
Environment variables to remove:
        LD_PRELOAD
        LD_LIBRARY_PATH
        IFS
        ...
Environment variables to preserve:
        DISPLAY
        PATH
        TERM
        ...
```

And `sudo -l` (Chapter 04 §12) shows the `Defaults` in effect for a user,
including `env_reset` and `secure_path`. When auditing a host, these two outputs
are the ground truth — not the raw `sudoers` text, because compiled defaults and
included files both contribute variables that the visible rules do not show.

## 10. Residual risks: even the whitelist can leak

`env_reset` is strong but not a guarantee, and a rigorous treatment must name its
edges:

- **`env_keep` additions are silent holes.** Every variable an administrator adds
  is one `sudo` no longer sanitizes. A well-meaning `env_keep += "PYTHONPATH"` to
  make a `sudo`-run Python tool find a module re-opens interpreter injection for
  *every* Python command run under `sudo`.
- **Preserved variables can still be dangerous even past `env_check`.** The `%`//
  guard catches format-string and path payloads, but not every abuse. A preserved
  variable that a specific target program treats as a command or a filename can be
  exploited within `env_check`'s allowances.
- **`SETENV`/`-E` grants transfer control back to the caller.** Any rule with these
  is only as safe as the command it runs; on an interpreter or shell, it is a full
  bypass.
- **`env_reset` off** discards the whole model. If you inherit a system with it
  disabled, treat every `sudo` grant as environment-poisonable until proven
  otherwise.

The pattern across all four is the same: the environment defense is a policy, and
like any policy it is only as tight as its exceptions. Chapter 10 returns to this
when it frames the trust boundary formally; here the operational rule is enough —
**keep `env_reset` on, keep `secure_path` set, add to `env_keep` only with a
specific justification, and never combine `SETENV` with a shell or interpreter.**

## 11. Security synthesis

The environment is the largest caller-controlled channel into a root process, and
much of it is *control* rather than *data* — steering the loader, libc, the
shell, and language runtimes before or during the target's execution. Crucially,
the kernel/loader secure-execution defense (`AT_SECURE`) protects `sudo` itself
but **not** the ordinary binary `sudo` execs after transitioning credentials, so
userspace sanitization is the only protection for the command. `sudo`'s
`env_reset` provides it with the right architecture — a **whitelist**: discard
everything, rebuild a minimal known-good environment, force `PATH` to
`secure_path`, reset `HOME` to the target, and add back only explicitly-permitted
variables. Every loosening — `env_keep` additions, `env_check` allowances,
`SETENV`/`-E`, or disabling `env_reset` — is a deliberate reduction of that
guarantee and must be justified per case.

## 12. What this chapter established

- The **environment is the largest caller-controlled input** to a privileged
  process, inherited by default across `execve`, interpreted by code the program
  author never wrote, and open-ended — so it cannot be validated field-by-field,
  only governed by policy.
- Many variables are **control, not data**: `LD_PRELOAD`/`LD_LIBRARY_PATH`/
  `LD_AUDIT` (loader injection), `PATH` (command resolution), `IFS`/`BASH_ENV`/`ENV`
  (shell), `PYTHONPATH`/`PERL5LIB`/… (interpreter injection), `TZ`/`LC_*`/`NLSPATH`
  (libc formatting). Each is a real path to root code execution.
- The loader's **`AT_SECURE` secure-execution mode protects `sudo` but not the
  command it runs**, because the target is `execve`d as an ordinary non-setuid
  binary *after* the credential transition — no privilege change, no `AT_SECURE`,
  no loader sanitization. `sudo` must strip the dangerous variables itself.
- **`env_reset`** (default on) implements a **whitelist**: discard the inherited
  environment and rebuild a minimal one, adding `SUDO_*` provenance and resetting
  `PATH`/`HOME` — demonstrably removing `LD_PRELOAD` and unknown variables.
- The knobs are **`env_keep`** (preserve through reset), **`env_check`** (preserve
  only if value has no `%` or `/`), **`env_delete`** (blacklist when reset is off),
  and **`env_reset` off** (legacy blacklist mode — avoid).
- **`secure_path`** replaces the caller's `PATH` entirely, closing the exact
  injection that defeated the Chapter 02 wrapper.
- **`HOME`** is an indirect control variable — it decides which config files a
  root program trusts — and must be reset to the target (`always_set_home`)
  rather than left pointing at the caller's home.
- User-requested preservation (**`-E`, `--preserve-env`, `VAR=value`**) is a
  **privilege gated by `SETENV`/`setenv`**, never a default, and is a full bypass
  when combined with an interpreter or shell.
- Inspect the real policy with **`sudo -V`** and **`sudo -l`**, not the raw
  `sudoers` text; and remember every loosening is a scoped reduction of the
  guarantee.

The next chapter reaches the technical core the whole series has been building
toward. *Privilege Transition* dissects Stage 8 in full: the exact syscalls
(`setgroups`, `setresgid`, `setresuid`), why their **order** is
security-critical, why `setresuid` and not `setuid`, and how a mistake in this
handful of calls is the difference between a correct credential change and a
process that an attacker can walk back up to root.
