# 04 — The sudoers File

Chapter 03 reached Stage 4 — the policy decision — and deliberately left it as a
black box: "the plugin evaluates whether this invoker may run this command as
this target user on this host." This chapter opens that box. It is the complete
grammar and evaluation model of `/etc/sudoers`: the anatomy of a rule, the four
fields and every form each can take, aliases, the `Defaults` mechanism, the
"last match wins" evaluation order, and — most importantly for a security
reference — the precise ways a syntactically valid rule silently grants far more
than its author intended.

`sudoers` is a small declarative language with a deceptively simple surface and a
large blast radius. A single misplaced wildcard, a single overly broad command,
a single interpreter left runnable, and the least-privilege guarantee from
Chapter 02 collapses back into full root. Reading `sudoers` correctly is
therefore not a syntax exercise; it is a security skill.

## 1. Where the policy lives, and why you never edit it directly

The primary policy file is `/etc/sudoers`, owned by root, mode `0440` (read-only,
even for root), and it is not meant to be opened in an ordinary editor:

```console
$ ls -l /etc/sudoers
-r--r----- 1 root root 1671 Apr 12 10:02 /etc/sudoers
```

Modern `sudoers` almost always ends with an include directive that pulls in a
directory of drop-in files:

```console
$ tail -1 /etc/sudoers
@includedir /etc/sudoers.d
```

```console
$ ls /etc/sudoers.d
90-cloud-init-users  README
```

`@includedir` reads every file in the directory (skipping those with a `.` or a
`~` in the name, and those that are not regular files) and parses them as part of
the policy. This is the correct place to add site-specific rules: one file per
concern, so package updates to `/etc/sudoers` never collide with your changes.
(The older syntax `#includedir` means the same thing — the `#` there is *not* a
comment, a genuine trap for readers.)

You must edit these files with **`visudo`**, never directly. `visudo` does two
things a plain editor cannot:

- It **locks** the file so two administrators cannot corrupt it with concurrent
  edits.
- It **validates the grammar before saving**. A syntax error in `sudoers` makes
  the policy plugin's `open()` fail (Chapter 03, Stage 3), which can lock every
  user — including you — out of `sudo` entirely. `visudo` refuses to install a
  file that would not parse.

```console
$ sudo visudo -f /etc/sudoers.d/90-backup     # edit a drop-in safely
$ sudo visudo -c                              # check syntax of everything
/etc/sudoers: parsed OK
/etc/sudoers.d/90-backup: parsed OK
```

The `-c` (check) mode is worth wiring into any automation that writes `sudoers`:
generate the file, run `visudo -c -f newfile`, and only move it into place if it
parses. A malformed `sudoers` is one of the few ways to truly brick
administrative access to a host.

## 2. The anatomy of a rule

The core of `sudoers` is the **user specification** — the line that grants
privilege. Its full form is:

```sudoers
user    host = (runas_user:runas_group) [TAG:] command
```

Read as a sentence: *"`user`, when logged in on `host`, may run `command` as
`runas_user` (with group `runas_group`), subject to `TAG`."* A concrete example,
the one from Chapter 03:

```sudoers
parsa   ALL = (root) /usr/bin/systemctl restart nginx
```

`parsa`, on any host (`ALL`), may run exactly `/usr/bin/systemctl restart nginx`
as `root`. Four independent fields — **who, where, as-whom, what** — and the
security of the rule depends on all four being as narrow as the requirement
demands and no wider. We take them one at a time.

A single line may also list multiple comma-separated commands, multiple hosts,
and multiple users, and a user may have several lines. The evaluation model in
§10 defines how these combine.

## 3. Field 1 — the user (who is granted)

The first field names *who* the rule applies to. It is a comma-separated list
whose elements can be:

- **a login name**: `parsa`
- **a Unix group**, prefixed with `%`: `%wheel`, `%sudo`, `%admin` — the rule
  applies to every member of that group;
- **a group by GID**, prefixed with `%#`: `%#27`;
- **a user by UID**, prefixed with `#`: `#1000` (matches the user with UID 1000
  regardless of name);
- **a netgroup**, prefixed with `+`: `+servers` (from NIS/`getnetgrent`);
- **a non-Unix group** (from a group provider plugin), prefixed with `%:`;
- **`ALL`**, matching every user;
- any of the above **negated** with `!`.

The group forms are how most distributions grant baseline admin rights. Debian
and Ubuntu ship:

```sudoers
%sudo   ALL=(ALL:ALL) ALL
```

and add administrators to the `sudo` group. Red Hat-family systems use `%wheel`
similarly. That one line is why "add the user to the `sudo`/`wheel` group" is the
canonical way to grant admin — it is not a special mechanism, just membership in
a group named on the left of a very broad rule.

The negation forms exist but are treacherous, and their trouble is the same as in
the command and runas fields: negation in a list does not compose the way people
expect, and `ALL, !something` patterns are a recurring source of bypass (§11 and
`CVE-2019-14287`).

## 4. Field 2 — the host

The second field restricts the rule to particular hosts. It matters because
`sudoers` is designed to be a **single file distributed to many machines** — the
same policy file on every server, with host fields deciding which rules apply
where. Its elements can be:

- **a hostname**: `web01`
- **`ALL`**: every host (by far the most common in single-machine setups);
- **an IP address or network**: `192.168.10.0/24`, matching the host's own
  addresses;
- **a `Host_Alias`** (§8);
- negated forms with `!`.

On a standalone machine the host field is almost always `ALL`, and it is easy to
forget it is doing anything. But in a fleet with one shared `sudoers`, the host
field is a real access control:

```sudoers
# The same file on every host; each rule applies only where it should.
dbadmin   db-servers   = (root) /usr/bin/systemctl restart postgresql
webadmin  web-servers  = (root) /usr/bin/systemctl restart nginx
```

`dbadmin` gets no privilege on the web tier and vice versa, from one policy
source. Getting the host field wrong (e.g. `ALL` where you meant a specific
group) grants a rule everywhere — a quiet over-grant that a single-host test will
never reveal.

## 5. Field 3 — the runas specification (as whom)

The parenthesized field controls the **target identity** — the credentials the
command will run with after Chapter 08's transition. Its full form is
`(user_list:group_list)`, and both parts are optional in ways that carry meaning:

- `(root)` — may run as `root`, with root's default group.
- `(www-data)` — may run as `www-data`. Invoked with `sudo -u www-data ...`.
- `(:staff)` — may keep the current user but run with group `staff`
  (`sudo -g staff ...`).
- `(operator:staff)` — may run as user `operator` and group `staff`.
- `(ALL)` or `(ALL:ALL)` — may run as **any** user and/or group. This is
  extremely broad and deserves suspicion whenever you see it.

If the runas field is omitted entirely, the default target is `root` only. So
`parsa ALL = /usr/bin/id` means "as root," identically to `parsa ALL = (root)
/usr/bin/id`.

The runas field is the site of one of the most instructive `sudoers` CVEs.
Consider a rule meant to let a user run a command as *anyone except root*:

```sudoers
parsa   ALL = (ALL, !root) /usr/bin/somecmd
```

The intent is clear: any target user is fine, but not `root`. Before `sudo`
1.8.28, this could be bypassed:

```console
$ sudo -u '#-1' /usr/bin/somecmd      # or  -u '#4294967295'
```

The UID `-1` (and its unsigned twin `4294967295`) was mishandled: the runas UID
parsing treated it specially and it resolved to `0`, i.e. `root` — the exact
target the `!root` negation was supposed to forbid. This is `CVE-2019-14287`, and
its lesson is precise: **negated `ALL` in the runas field is not a safe way to
express "everyone but root."** It is a blacklist where a whitelist was needed,
and the blacklist had a hole. Prefer naming the allowed targets explicitly.

## 6. Field 4 — the command specification

The command field is where most real damage is done, because it is where the
gap between "what the author typed" and "what actually gets authorized" is widest.

A command is specified by **absolute path**, optionally followed by arguments:

```sudoers
parsa ALL = /usr/bin/systemctl restart nginx
```

The matching rules for arguments are the single most important thing in this
chapter:

- **Command listed with specific arguments** → the invocation's arguments must
  match. `/usr/bin/systemctl restart nginx` authorizes exactly that; `sudo
  systemctl restart postgresql` does *not* match and is denied.
- **Command listed with no arguments** → **any** arguments are allowed.
  `parsa ALL = /usr/bin/systemctl` lets `parsa` run `systemctl` with *any*
  subcommand, including `systemctl mask --now everything` or editing units — a
  vastly broader grant than "restart nginx."
- **Command listed with `""` (empty string)** → **only** the command with **no**
  arguments is allowed. `parsa ALL = /usr/bin/systemctl ""` permits bare
  `systemctl` and nothing else.
- **`ALL`** as the command → **every** command, i.e. effectively full root. This
  is what `%sudo ALL=(ALL:ALL) ALL` grants.

The difference between listing a command *with* arguments and *without* is the
difference between "restart nginx" and "administer all of systemd." It is
extremely common to see rules that intend the former and, by omitting the
arguments, grant the latter.

Wildcards make this sharper. `sudoers` supports shell-style wildcards in paths
and arguments, matched with `fnmatch(3)` — **not** regular expressions. They are
powerful and routinely broader than intended:

```sudoers
# "let them manage services" — but this matches restart, stop, mask, and more
parsa ALL = /usr/bin/systemctl * nginx
```

A wildcard in the argument position matches whatever the invoker supplies there.
Reason about wildcards adversarially: assume the user will place the
most dangerous possible string in every wildcard slot, and ask whether the rule
still holds. If `/usr/bin/systemctl * nginx` can be driven to something harmful
by choosing the `*`, the rule is too loose.

There is also a special safe form for editing files, **`sudoedit`** (invoked as
`sudo -e` or `sudoedit`), which is discussed in §11 because it is the correct
answer to a very common over-grant.

## 7. Tags

Between the runas spec and the command, a rule may carry **tags** that modify how
the command runs. Each tag applies to the current command and all following
commands on the line until overridden by its opposite. The important ones:

- **`NOPASSWD:` / `PASSWD:`** — skip / require authentication. `NOPASSWD` is a
  convenience with real risk: it removes the "prove you are you" gate for that
  command, so anyone who can get a shell as the invoking user inherits the grant
  with no further check. Reserve it for genuinely non-interactive automation and
  for commands that are safe even to an attacker.
- **`NOEXEC:` / `EXEC:`** — disallow / allow the command from executing further
  programs. `NOEXEC` uses a preloaded library to make `exec*` family calls fail
  in the target, which blunts shell-escape attacks from within an allowed program
  (though it is not a complete sandbox).
- **`SETENV:` / `NOSETENV:`** — allow / forbid the user overriding the
  environment on the command line (`sudo VAR=x ...`). Granting `SETENV` re-opens
  the environment trust problem from Chapter 07; use it sparingly.
- **`LOG_INPUT:` / `LOG_OUTPUT:`** and their negations — force I/O logging on or
  off for the command (Chapter 09).

A tag combines with the command it precedes:

```sudoers
backup ALL = (root) NOPASSWD: /usr/local/sbin/run-backup
parsa  ALL = (root) NOEXEC: /usr/bin/less /var/log/syslog
```

The second line is a defense-in-depth attempt: `less` has a shell-escape
(`!sh`), so `NOEXEC` is added to try to prevent `less` from spawning a shell.
Whether that fully closes the hole is exactly the kind of question Chapter 10
takes up; the tag is a mitigation, not a proof.

## 8. Aliases

For anything beyond a handful of rules, listing users, hosts, and commands
inline becomes unmaintainable. `sudoers` provides four **alias** types — named
lists you define once and reference by name:

```sudoers
User_Alias   ADMINS    = parsa, sara, #1002
Runas_Alias  DBUSER    = postgres, operator
Host_Alias   DB_TIER   = db01, db02, 10.0.5.0/24
Cmnd_Alias   SVC_CTL   = /usr/bin/systemctl start *, \
                         /usr/bin/systemctl stop *, \
                         /usr/bin/systemctl restart *
```

Once defined, rules read almost like English:

```sudoers
ADMINS   DB_TIER = (DBUSER) SVC_CTL
```

*"The admins, on the database tier, may run the service-control commands as the
database users."* Aliases are alias names in **UPPERCASE** by convention (the
grammar does not require it, but readability does).

`Cmnd_Alias` is the most security-relevant of the four, because it centralizes
the command-matching decisions from §6. A single loose entry in a widely
referenced `Cmnd_Alias` — say, a bare `/usr/bin/systemctl` with no arguments —
silently loosens every rule that uses it. Audit `Cmnd_Alias` definitions the way
you would audit the rules themselves.

## 9. Defaults

The `Defaults` mechanism sets `sudo`'s many options. A bare `Defaults` line
applies globally; qualified forms scope the setting to a user, host, command, or
runas target:

```sudoers
Defaults              env_reset                 # global: sanitize the env
Defaults              secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
Defaults              timestamp_timeout=15      # ticket lifetime, minutes
Defaults:parsa        timestamp_timeout=0       # this user re-auths every time
Defaults>root         !set_home                 # when running AS root
Defaults@web01        log_year, logfile=/var/log/sudo.log   # on this host
Defaults!/usr/bin/id  !authenticate             # for this command
```

The qualifier sigils are worth memorizing because they change *whom the setting
applies to*:

- `Defaults:user` — when *this user* runs `sudo`;
- `Defaults@host` — on *this host*;
- `Defaults>runas` — when running *as this target*;
- `Defaults!command` — for *this command*.

Many defaults are security-critical and appear in every hardened `sudoers`:
`env_reset` (Chapter 07), `secure_path`, `requiretty`/`use_pty`, `logfile`,
`passwd_tries`, `timestamp_timeout`. A `Defaults` line is easy to skim past, but
`Defaults !env_reset` or a wide `secure_path` can undermine the whole policy —
these lines deserve the same scrutiny as the rules.

## 10. Evaluation — order and "last match wins"

Given all the rules, aliases, and defaults, how does `sudo` decide? The
evaluation model has one rule that surprises almost everyone and is responsible
for a whole class of misconfigurations:

> Among all rules that match the current (user, host, runas, command) tuple,
> **the last matching rule wins.**

Not the first. Not the most specific. The last one, in file order (with included
files parsed at the point of their `@includedir`). This has a critical
consequence for how you write deny rules:

```sudoers
# INTENT: parsa may run anything EXCEPT edit the sudoers file.
parsa ALL = (root) ALL
parsa ALL = (root) !/usr/sbin/visudo
```

Because the last match wins, this ordering *works*: the negation comes after the
broad grant, so an attempt to run `visudo` matches the second (deny) rule last
and is refused. Reverse the two lines and the protection vanishes — the broad
`ALL` would match last and re-allow `visudo`.

But even correctly ordered, this pattern is fragile, and Chapter 11 explains why:
a "grant ALL, then blacklist a few binaries" policy is a blacklist, and
blacklists of commands are almost always bypassable. `visudo` denied?
`parsa ALL=(root) ALL` still allows a plain `sudo bash`, from which the user
edits `sudoers` by hand. The negation blocked one path to a goal while leaving
the goal wide open. **Deny-by-exception on top of `ALL` is a design smell**; the
robust shape is to grant only the specific commands needed and deny by default
(which is `sudo`'s behavior when nothing matches).

When *no* rule matches, the default is deny — `sudo` refuses and logs the
attempt. Least privilege is the ground state; every grant is an explicit
addition.

## 11. The silent over-grant — how rules leak privilege

This section is the reason the chapter exists. A `sudoers` rule can be perfectly
valid, parse cleanly under `visudo -c`, express exactly what its author typed —
and still hand the user a root shell. The mechanisms:

**1. Bare commands (no arguments).** As §6 showed, `parsa ALL = /usr/bin/vim`
does not mean "let parsa use vim on some file." It means "let parsa run vim as
root with any arguments," and vim has a shell escape:

```console
$ sudo vim
:!/bin/bash                 # spawns a root shell from inside vim
# id
uid=0(root) ...
```

The user was granted an editor and received a root shell. The same is true of
`less`, `more`, `man`, `awk`, `find`, `tar`, `git`, `nmap`, `env`, most
interpreters, and dozens of other everyday tools — the public catalog of these
escapes is large. **Any rule that grants an interpreter, editor, pager, or a tool
with an `--exec`/`-c`/shell-escape feature is equivalent to granting `ALL`.**

**2. Commands that run other commands.** Some grants are obviously general once
you look:

```sudoers
parsa ALL = (root) /usr/bin/find     # find . -exec /bin/sh \; → root shell
parsa ALL = (root) /usr/bin/env      # env /bin/sh            → root shell
parsa ALL = (root) /bin/tar          # tar --checkpoint-action=exec=... → shell
```

Each of these is a full-root grant wearing the costume of a specific tool.

**3. Wildcards that match too much.** `parsa ALL = /usr/bin/systemctl * nginx`
looks scoped to nginx, but the `*` lets the user choose the verb — `mask`,
`link`, or an option that changes behavior. Argument wildcards should be treated
as attacker-controlled.

**4. Granting an editor to edit a root file — use `sudoedit` instead.** The
common need "let this user edit `/etc/nginx/nginx.conf` as root" is almost always
solved wrongly by granting an editor:

```sudoers
# WRONG: gives a root editor, i.e. a root shell via the editor's escape.
parsa ALL = (root) /usr/bin/vim /etc/nginx/nginx.conf
```

The correct construct is `sudoedit`, which never runs an editor as root at all:

```sudoers
# RIGHT: sudoedit copies the file out, runs the USER's editor as the USER,
#        then writes the result back as root. No root editor process exists.
parsa ALL = (root) sudoedit /etc/nginx/nginx.conf
```

```console
$ sudoedit /etc/nginx/nginx.conf     # editor runs as parsa; file saved as root
```

`sudoedit` closes the escape entirely because the privileged part is only the
copy-back, and the editor — the thing with the shell escape — runs unprivileged.

**5. `NOPASSWD` on anything reachable by an attacker.** `NOPASSWD` turns "a
person who knows the password" into "any process running as this user." Combined
with any of the above, it removes even the friction of a password prompt from a
privilege escalation.

The through-line: **a `sudoers` rule authorizes a *capability*, not an
*intention*.** The author intends "restart nginx"; the rule authorizes "run
systemctl as root with these arguments," and if the arguments (or the binary)
permit more, more is authorized. Reading `sudoers` for security means reading
each rule as an attacker would — asking, for every grant, "what is the most this
lets me do?" rather than "what did they mean by it?"

## 12. Verifying — `sudo -l` and `visudo -c`

Two commands turn `sudoers` from a thing you hope is right into a thing you
check.

`visudo -c` validates syntax across `/etc/sudoers` and all included files, as in
§1. Run it after every change and in any pipeline that writes policy.

`sudo -l` renders the *effective* decision for a user — the policy plugin's
`list` entry point (Chapter 03, Stage 4) — collapsing all rules, aliases, and
defaults into the actual grant:

```console
$ sudo -l -U parsa            # as an admin, inspect what parsa may do
Matching Defaults entries for parsa on host:
    env_reset, secure_path=/usr/sbin\:/usr/bin\:/sbin\:/bin,
    timestamp_timeout=15

User parsa may run the following commands on host:
    (root) /usr/bin/systemctl restart nginx
    (root) sudoedit /etc/nginx/nginx.conf
    (root) NOPASSWD: /usr/local/sbin/run-backup
```

`sudo -l -U <user>` is the audit tool: it shows the resolved reality, not the
source text, so it catches over-grants that are hard to see in the raw file
(e.g. a broad `Cmnd_Alias` expanding into a rule). Making it a habit — "what does
`sudo -l` actually say this user can do?" — is the single most effective check
against the silent over-grants of §11.

## 13. What this chapter established

- Policy lives in `/etc/sudoers` and `/etc/sudoers.d/` (via `@includedir`), is
  mode `0440`, and must be edited with **`visudo`**, which locks the file and
  refuses to save a version that would not parse — a malformed `sudoers` can
  lock out all administrative access.
- A rule has four independent fields — **who, where, as-whom, what** —
  `user host = (runas) [TAG:] command`; security depends on all four being as
  narrow as the requirement and no wider.
- The **command field** is the highest-risk: a command with no arguments allows
  *any* arguments; `""` allows only none; `ALL` allows everything; wildcards use
  `fnmatch(3)` and must be reasoned about adversarially.
- The **runas field**'s negation (`ALL, !root`) is a blacklist with holes —
  `CVE-2019-14287` bypassed it via `-u#-1`; name allowed targets explicitly
  instead.
- **Aliases** (`User_/Runas_/Host_/Cmnd_Alias`) centralize lists; a loose
  `Cmnd_Alias` loosens every rule that uses it. **`Defaults`** set options
  globally or scoped by `:user`, `@host`, `>runas`, `!command`, and several are
  security-critical.
- Evaluation is **last match wins**, so deny rules must follow the grants they
  restrict — but "grant `ALL`, then blacklist" is a design smell that is almost
  always bypassable; grant specific commands and rely on default-deny.
- The core hazard is the **silent over-grant**: a valid rule authorizes a
  *capability*, not an *intention*. Editors, pagers, interpreters, and
  exec-capable tools are equivalent to `ALL`; the correct pattern for file
  editing is **`sudoedit`**, not granting a root editor.
- **`visudo -c`** checks syntax and **`sudo -l -U user`** renders the effective
  grant — use both to verify policy rather than trusting the source text.

The next chapter moves from the *content* of the policy to the *machinery that
reads it*. *Policy and Plugin Architecture* dissects the plugin API the front-end
used in Chapter 03 to load `sudoers.so` — the function-pointer contract
(`open`, `check_policy`, `list`, `close`, the I/O and audit hooks) that lets
`sudo` treat policy as replaceable, and that makes `sudoers` just one
implementation among possible many.
