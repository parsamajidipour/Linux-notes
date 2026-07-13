# 11 — Common Misconfigurations

Chapter 10 ended by naming Class D — legitimate-but-dangerous grants — as the one
vulnerability class that lives entirely in *policy* rather than in `sudo`'s code.
This chapter is the operational catalog of that class. It collects the specific
`sudoers` patterns that administrators actually write, each of which parses
cleanly, satisfies `visudo -c`, expresses precisely what its author typed — and
silently grants a root shell.

The organizing discipline is constant. For each pattern we give the rule as
written, the exploit that defeats it, the invariant it breaks (in the vocabulary
of Chapter 10 — usually "grant a capability, not a convenience," sometimes
"whitelist not blacklist" or "isolate the command"), and the correct form. The
running lesson from Chapter 04 is the lens throughout: **a rule authorizes the
*most* its command can do, not what its author meant.** Every misconfiguration
below is a gap between those two.

## 1. From taxonomy to catalog

These are not exotic. They are the rules that appear when someone reasons "I just
need this user to do *one* administrative thing" and reaches for the nearest tool
without asking what else that tool can do as root. The catalog is worth
internalizing as a set of reflexes: when reviewing `sudoers`, certain binaries and
certain shapes should trigger immediate suspicion, and the sections below are that
list of triggers.

## 2. Bare interpreters and shells

**Pattern.** Granting a language interpreter, for a scripting or automation need:

```sudoers
parsa ALL = (root) /usr/bin/python3
deploy ALL = (root) /usr/bin/perl /opt/deploy/run.pl
```

**Exploit.** Every general-purpose interpreter can execute an arbitrary shell,
because executing arbitrary code is its entire purpose:

```console
$ sudo python3 -c 'import os; os.system("/bin/bash")'
# id
uid=0(root) gid=0(root) groups=0(root)
$ sudo perl -e 'exec "/bin/sh";'
# id
uid=0(root) ...
```

The `perl` example is worse than it looks: even though the rule *names a script*
(`run.pl`), listing the command with no argument constraints (or with a wildcard)
lets the user supply `-e '...'` instead, ignoring the intended script entirely.

**Broken invariant.** Grant a capability, not a convenience. An interpreter's
capability *is* arbitrary code execution; granting it as root is granting root.

**Correct form.** Never grant an interpreter as a general command. If a specific
script must run as root, grant *the script* — root-owned and non-writable (§7) —
and never the interpreter that could run any script:

```sudoers
# The script itself, locked down; not the interpreter.
deploy ALL = (root) /opt/deploy/run.sh
```

The same applies to `ruby`, `node`, `lua`, `php`, `gdb`, `awk` (`awk 'BEGIN
{system("/bin/sh")}'`), and any tool whose job is to run code you give it.

## 3. Editors and pagers

**Pattern.** Granting an editor to let a user modify a root-owned file, or a pager
to let them read one:

```sudoers
parsa ALL = (root) /usr/bin/vim /etc/nginx/nginx.conf
parsa ALL = (root) /usr/bin/less /var/log/secure
```

**Exploit.** Editors and pagers have shell escapes:

```console
$ sudo vim /etc/nginx/nginx.conf
:!/bin/bash                       # root shell from inside vim
$ sudo less /var/log/secure
!/bin/sh                          # root shell from inside less
```

Note the `vim` rule *did* constrain the argument to the intended file — and it is
still a full compromise, because the danger is not the file argument but the
editor's built-in ability to spawn a shell.

**Broken invariant.** Grant a capability, not a convenience — and note that even
argument-constraining does not help when the *program itself* is escapable.

**Correct form.** For editing, use **`sudoedit`** (Chapter 04 §11), which runs the
user's editor *as the user* and only writes back as root, so no root editor
process ever exists:

```sudoers
parsa ALL = (root) sudoedit /etc/nginx/nginx.conf
```

For reading, prefer a non-escapable tool or a purpose-built approach; granting
`less`/`more`/`man` as root is equivalent to granting a shell. `cat` is safer than
a pager for pure reading, but consider whether the user needs `sudo` at all versus
group-readable access (Chapter 02 §5).

## 4. Commands that exec other commands

**Pattern.** Granting an everyday utility that happens to have an
execute-a-command feature:

```sudoers
ops ALL = (root) /usr/bin/find /var/log -name '*.gz' -delete
backup ALL = (root) /bin/tar
mon ALL = (root) /usr/bin/systemctl status *
```

**Exploit.** Each of these can be steered into executing a shell:

```console
$ sudo find /var/log -name x -exec /bin/sh \; -quit
$ sudo tar -cf /dev/null /dev/null --checkpoint=1 --checkpoint-action=exec=/bin/sh
$ sudo systemctl status nginx          # output goes to a pager (less) → then:
!sh
```

`find`'s `-exec`, `tar`'s `--checkpoint-action`, `systemctl`'s pager, `git`'s
pager and hooks, `env`'s "run this program," `nice`/`timeout`/`xargs`/`stdbuf`'s
"wrap this command," `ssh`'s `ProxyCommand`/`LocalCommand`, `rsync`'s `-e`,
`tcpdump`'s `-z` postrotate — all are general execution primitives wearing the
costume of a specific tool.

**Broken invariant.** Grant a capability, not a convenience. These tools' capability
includes running other programs; as root, that is root.

**Correct form.** Recognize the class and avoid it where possible. If such a tool
is unavoidable, constrain its arguments as tightly as the tool allows and consider
`NOEXEC` (which makes the tool's own `exec*` calls fail — a real, if incomplete,
mitigation):

```sudoers
ops ALL = (root) NOEXEC: /usr/bin/find /var/log -name *.gz -delete
```

But treat `NOEXEC` as defense-in-depth, not a guarantee — some tools have escapes
it does not cover. The safest move is a purpose-built wrapper script (root-owned,
§7) that performs the narrow task without exposing the general tool.

## 5. Permissive wildcards

**Pattern.** Using a wildcard to cover a family of invocations:

```sudoers
web ALL = (root) /usr/bin/systemctl * nginx
sys ALL = (root) /bin/chown parsa\: /home/parsa/*
```

**Exploit.** Wildcards match more than the author pictured. `systemctl * nginx`
lets the user choose the verb — including `link`, `mask`, or options that change
behavior. Argument wildcards are especially dangerous because the user controls the
matched text. And path wildcards combined with a permissive command can reach
unintended targets:

```console
$ sudo /bin/chown parsa: /home/parsa/../../etc/shadow   # if the wildcard admits it
```

**Broken invariant.** Whitelist, not blacklist — and reason adversarially. A
wildcard is an implicit "any value here," which is a whitelist of *everything*.

**Correct form.** Avoid wildcards in security-sensitive positions. Enumerate the
exact invocations needed:

```sudoers
web ALL = (root) /usr/bin/systemctl restart nginx, \
                 /usr/bin/systemctl reload nginx, \
                 /usr/bin/systemctl status nginx
```

If a wildcard is truly unavoidable, assume the user will place the most dangerous
possible string in it and confirm the rule still holds.

## 6. `NOPASSWD` on the wrong commands

**Pattern.** Adding `NOPASSWD` for convenience or automation, on a command that is
escapable or broad:

```sudoers
parsa ALL = (root) NOPASSWD: /usr/bin/vim /etc/hosts
ci    ALL = (root) NOPASSWD: ALL
```

**Exploit.** `NOPASSWD` removes the authentication gate (Chapter 06), so *any
process running as the user* — including one an attacker obtained through an
unrelated bug — inherits the grant with no password friction. Combined with an
escapable command (§2–§5), it is passwordless root; combined with `ALL`, it is
unconditional root for anyone who can run as that user.

**Broken invariant.** `NOPASSWD` turns "a human who knows the password" into "any
code running as this user." It is only safe on commands that are safe *even to an
attacker*.

**Correct form.** Reserve `NOPASSWD` for genuinely non-interactive automation and
for commands with no escape and tight arguments. For a CI runner, grant the
specific deployment command, not `ALL`:

```sudoers
ci ALL = (root) NOPASSWD: /opt/deploy/run.sh
```

Never combine `NOPASSWD` with an interpreter, editor, pager, or exec-capable tool.

## 7. Writable targets and relative paths

**Pattern.** Granting a script that the user (or the world) can modify, or that
lives in a writable directory, or naming a command without an absolute path:

```sudoers
parsa ALL = (root) /home/parsa/bin/backup.sh     # in the user's own home!
team  ALL = (root) /opt/scripts/deploy.sh        # dir writable by the team?
parsa ALL = (root) backup                         # relative — resolved via PATH
```

**Exploit.** If the target file is writable by the user, they simply rewrite it:

```console
$ echo '/bin/bash' >> /home/parsa/bin/backup.sh
$ sudo /home/parsa/bin/backup.sh
# id → uid=0
```

If the *file* is not writable but its *parent directory* is, the user replaces the
file:

```console
$ mv /opt/scripts/deploy.sh /tmp/ ; printf '#!/bin/bash\n/bin/bash\n' > /opt/scripts/deploy.sh
$ chmod +x /opt/scripts/deploy.sh ; sudo /opt/scripts/deploy.sh
```

And a relative command name is resolved at policy-match/execution time in a way
that can be steered.

**Broken invariant.** The trusted side must actually *be* trusted. A command whose
contents or location the untrusted user controls is untrusted input executing as
root — Class A/D hybrid.

**Correct form.** The target and every directory in its path must be **root-owned
and not writable by anyone else**, and the path must be **absolute**:

```console
# ls -ld /opt/scripts /opt/scripts/deploy.sh
drwxr-xr-x 2 root root ... /opt/scripts
-rwxr-xr-x 1 root root ... /opt/scripts/deploy.sh
```

```sudoers
parsa ALL = (root) /opt/scripts/deploy.sh
```

Never grant a command that lives under a user-writable path (home directories,
`/tmp`, group-writable project dirs), and always specify the absolute path.

## 8. Negation traps: "ALL then blacklist"

**Pattern.** Granting broad access and trying to carve out exceptions:

```sudoers
parsa ALL = (root) ALL, !/usr/bin/passwd, !/usr/sbin/visudo
parsa ALL = (ALL, !root) /usr/bin/somecmd
```

**Exploit.** Command blacklists are bypassable because the goal, not the path, is
what matters. Denied `visudo`? Run a shell and edit the file by hand:

```console
$ sudo /bin/bash          # still allowed by ALL
# visudo                  # now editing sudoers directly
```

And the runas negation `(ALL, !root)` is the `CVE-2019-14287` trap (Chapter 04 §5,
Chapter 10 §5) — bypassable via `-u#-1`.

**Broken invariant.** Whitelist, not blacklist. A blacklist must anticipate every
path to the goal; the space is unbounded, so it always has holes.

**Correct form.** Grant only the specific commands needed and rely on default-deny
for everything else. Name allowed runas targets explicitly instead of negating:

```sudoers
parsa ALL = (root) /usr/bin/systemctl restart nginx
parsa ALL = (operator) /usr/bin/somecmd          # explicit target, no negation
```

## 9. Overly broad group grants

**Pattern.** The distribution's baseline admin rule, plus careless group
membership:

```sudoers
%sudo ALL=(ALL:ALL) ALL         # the intended full-admin grant
%developers ALL=(ALL) ALL       # a custom group given ALL "for convenience"
```

**Exploit.** There is no exploit needed — this *is* full root for every member of
the group. The misconfiguration is adding users to these groups without realizing
that group membership *is* the grant. A user added to `sudo`/`wheel` "just to run
one command" receives everything the group's rule allows.

**Broken invariant.** Least privilege. A broad group rule plus loose membership
grants far more than the per-user need.

**Correct form.** Understand that the left-hand group *is* the access-control list.
Grant scoped rules to purpose-specific groups, and keep `sudo`/`wheel` membership
to genuine full administrators:

```sudoers
%web-ops ALL = (root) /usr/bin/systemctl restart nginx, \
                      /usr/bin/systemctl reload nginx
```

Add users to `web-ops`, not to `sudo`, when their need is scoped.

## 10. Environment loosening

**Pattern.** Re-opening the environment defense (Chapter 07) for convenience:

```sudoers
Defaults env_keep += "LD_PRELOAD LD_LIBRARY_PATH"   # catastrophic
Defaults env_keep += "PYTHONPATH"                    # opens interpreter injection
parsa ALL = (root) SETENV: /usr/bin/python3          # SETENV + interpreter
Defaults !env_reset                                  # disables the whitelist entirely
```

**Exploit.** Preserving `LD_PRELOAD` lets the user inject a shared object into any
`sudo`-run dynamically-linked program (Chapter 07 §2–§3, recalling that the loader
will *not* strip it for the target). `PYTHONPATH` injects modules into any
`sudo`-run Python. `SETENV` on an interpreter hands back full environmental
control. Disabling `env_reset` reverts to a leaky blacklist.

**Broken invariant.** Whitelist, not blacklist; and grant a capability, not a
convenience.

**Correct form.** Keep `env_reset` on and `secure_path` set. Add to `env_keep` only
specific, non-dangerous variables with a written justification, and never `LD_*`,
`*PATH`, or interpreter-path variables. Never combine `SETENV` with an interpreter
or shell.

## 11. File and include hygiene

**Pattern.** Weak permissions or confusing includes in the policy files
themselves:

```console
$ ls -l /etc/sudoers.d/90-team
-rw-rw-r-- 1 root team 120 ...        # group- (or world-) writable policy!
```

```sudoers
#includedir /etc/sudoers.d            # the leading # is NOT a comment
```

**Exploit.** A writable `sudoers` drop-in means the user rewrites their own grant
to `ALL`. And misreading `#includedir` as a comment (it is a directive) leads to
believing rules are inactive when they are live, or vice versa.

**Broken invariant.** The trusted side must be trusted. Writable policy is
attacker-controlled policy.

**Correct form.** Policy files are mode `0440`, root-owned, edited only with
`visudo` (which enforces this and validates syntax). Audit `sudoers.d` for any file
not `0440 root:root`:

```console
# find /etc/sudoers.d -type f ! -perm 0440 -o ! -user root
```

## 12. Auditing for these patterns

Do not trust that `sudoers` is safe because it parses; check for the shapes above.

Render each user's effective grant and read it adversarially:

```console
# sudo -l -U parsa           # what can parsa ACTUALLY run, as whom?
```

For every command in the output, ask the Chapter 04 question — *what is the most
this lets them do?* — and match against this catalog: Is it an interpreter (§2)?
An editor or pager (§3)? An exec-capable tool (§4)? Does it use a wildcard (§5)? Is
it `NOPASSWD` (§6)? Then verify the target's integrity:

```console
# check the granted binary and its whole path for writability
$ ls -ld /opt/scripts /opt/scripts/deploy.sh
$ stat -c '%A %U %G %n' /opt/scripts/deploy.sh
```

And confirm the policy files themselves are locked down (§11). This three-step
audit — render the grant, classify each command against the catalog, verify target
and file integrity — catches the overwhelming majority of Class D
misconfigurations before an attacker does.

## 13. What this chapter established

- Class D misconfigurations are `sudoers` rules that parse cleanly yet grant a root
  shell, because **a rule authorizes the most its command can do, not what the
  author meant**. The catalog is a set of review reflexes.
- **Bare interpreters/shells** (`python3`, `perl`, `awk`, …) grant arbitrary code
  as root — never grant them; grant the specific root-owned script instead.
- **Editors and pagers** (`vim`, `less`, `man`, …) have shell escapes, even with
  the file argument constrained — use **`sudoedit`** for editing; avoid pagers as
  root.
- **Exec-capable tools** (`find -exec`, `tar --checkpoint-action`, `systemctl`
  pager, `env`, `git`, `ssh`, …) are general execution primitives in disguise —
  scope tightly, apply `NOEXEC` as partial mitigation, or wrap in a purpose-built
  script.
- **Permissive wildcards** are implicit "any value" whitelists — enumerate exact
  invocations and reason adversarially about every `*`.
- **`NOPASSWD`** turns "a human who knows the password" into "any code running as
  the user" — reserve it for safe, non-escapable, tightly-argued commands, never
  interpreters or `ALL`.
- **Writable targets / relative paths** make the target itself untrusted input —
  the binary *and every directory in its path* must be **root-owned, non-writable,
  absolute**.
- **"ALL then blacklist"** and **runas negation** are bypassable blacklists —
  whitelist specific commands and name runas targets explicitly.
- **Broad group grants** mean group membership *is* the grant — scope rules to
  purpose-specific groups and keep `sudo`/`wheel` to true admins.
- **Environment loosening** (`env_keep` of `LD_*`/`*PATH`, `SETENV` on
  interpreters, `!env_reset`) re-opens Chapter 07's class — keep `env_reset` on and
  loosen only with justification.
- **Weak policy-file permissions** make policy attacker-controlled — `0440
  root:root`, `visudo` only.
- Audit by **rendering the grant (`sudo -l -U`), classifying each command against
  this catalog, and verifying target and file integrity.**

The next chapter turns from preventing misconfigurations to diagnosing behavior.
*Debugging Sudo* covers the tools for tracing an invocation to ground truth — the
`sudo` debug subsystem and `sudo.conf` `Debug` lines, `sudo -l`/`-V`, `strace`, the
PAM and audit logs, and `sudoreplay` — so that when `sudo` does something
unexpected, you can locate *which* stage produced the behavior rather than guess.
