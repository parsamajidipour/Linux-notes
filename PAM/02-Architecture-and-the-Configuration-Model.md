# 02 — Architecture and the Configuration Model

Chapter 1 established that a text file decides who gets into your machine. This chapter is about that file: where the framework looks for it, what every field on every line means, how files pull in other files, which of them are generated behind your back, and what happens when any of it is wrong.

This is the least glamorous chapter in the series and one of the two most useful. Chapter 4 teaches you to evaluate a stack. This one teaches you to find the stack in the first place, which sounds trivial and routinely is not, because the file you are reading is frequently not the file being used.

By the end you should be able to take an unfamiliar machine, determine within a couple of minutes which files actually govern a given service, flatten them into a single ordered list, tell which of them are managed by a tool that will revert your edits, and recognise the four distinct ways a PAM configuration can be broken by their symptoms alone.

---

## 2.1 Three Layers, Four Failure Modes

The architecture is three layers deep: the application, the framework, the modules. That is a simple picture and it earns its keep in exactly one place, which is diagnosis. Each layer fails differently, and the symptoms are distinguishable if you know what to listen for.

**The application never calls PAM at all.** Nothing you write in `/etc/pam.d/` has any effect. Logs show the application making its own decision, with no `pam_*` annotations anywhere. This is the SSH-public-key case from Chapter 1, and it is also what you get when a program was built without PAM support. Symptom: your configuration changes are ignored completely, including changes that should obviously break things. The diagnostic is `ldd`, and the fact that it is a one-second check is why it belongs early in every investigation.

**The framework cannot find or read the configuration.** The service file is missing, or unreadable, or its permissions are wrong. The framework falls back to `other`, or fails outright. Symptom: behaviour that does not match the file you are looking at, often uniformly across every user. This is the failure mode that wastes the most time, because the file you are staring at is correct, and it is correct and irrelevant.

**The framework cannot load a module.** The module is named in the file but is not on disk, or is on disk but unloadable. Linux-PAM logs this clearly and then does something specific and important that we will get to in 2.3. Symptom: syslog messages containing `dlopen` and the word `faulty`.

**A module loads and returns a failure.** The ordinary case, and the only one of the four that is actually about policy. Symptom: a log line naming the module, the service, and the stack.

Keep the order in mind. When something is wrong, work down the layers rather than starting at the bottom, because the bottom is where the interesting configuration is and therefore where everyone starts, and three of these four failure modes will not be found there.

| Symptom | Layer | First check |
|---|---|---|
| Config changes have no effect whatsoever | Application | `ldd $(which prog) \| grep pam` |
| Behaviour does not match the file you are reading | Framework, file location | `strace -e trace=openat`, check `other` |
| `PAM unable to dlopen` in syslog | Framework, module loading | `ls` the module path |
| Log line naming a module and a stack | Module | Read that module's manual page |
| User does not exist as far as anything is concerned | Neither, it is NSS | `getent passwd <user>` |

That last row is not a PAM layer at all, and it is in the table because it is the most common misdiagnosis in the entire area. Chapter 10 covers why.

---

## 2.2 Where the Framework Looks

### The two locations

There are two configuration formats and the choice between them is not yours to make on any modern system.

`/etc/pam.conf` is the original monolithic form, one file containing every service's configuration, with the service name as an extra leading field on every line:

```
su    auth      sufficient  pam_rootok.so
su    auth      required    pam_unix.so
login auth      required    pam_unix.so
```

`/etc/pam.d/` is the directory form, one file per service, with the service name supplied by the filename rather than by a field:

```
# /etc/pam.d/su
auth  sufficient  pam_rootok.so
auth  required    pam_unix.so
```

The rule that matters: **if the directory `/etc/pam.d/` exists, `/etc/pam.conf` is ignored entirely.** Not merged. Not consulted as a fallback. Ignored. Since every mainstream Linux distribution ships `/etc/pam.d/`, `/etc/pam.conf` on your system is almost certainly either absent or a decorative file full of comments that has no effect on anything.

```
$ ls -ld /etc/pam.d/ && ls -l /etc/pam.conf 2>/dev/null
```

Occasionally somebody discovers `/etc/pam.conf`, edits it, and cannot work out why nothing changed. Now you know.

### How the service name is chosen

The service name comes from the first argument to `pam_start()`:

```c
pam_start("sshd", user, &conv, &pamh);
```

The framework takes that string and looks for `/etc/pam.d/<string>`. Two consequences worth internalising.

First, the service name is whatever the programmer passed, not the program name. They usually match by convention. They do not have to. If you cannot find the service file for a program, look at the strings in the binary or at the `strace` output from Chapter 1, rather than assuming the filename.

Second, one program can use different service names in different circumstances. `sudo` uses `sudo` for ordinary invocations and `sudo-i` for `sudo -i` on distributions that ship a separate file for it. `systemd` uses several. If you configure `/etc/pam.d/sudo` and observe no change, check whether the path you exercised went through a different service name.

### When the file does not exist

If `/etc/pam.d/<service>` is absent, the framework uses `/etc/pam.d/other`. This is the fallback policy for the whole system and it deserves its own section, which it gets in 2.6.

If neither exists, the framework denies and logs. This is the correct fail-safe behaviour and it means a system with an empty `/etc/pam.d/` is a system nobody can log into.

### Permissions

The framework will refuse to use a configuration file that is not a regular file owned by root, or that is writable by anyone other than root. This is a sensible check given the argument in Chapter 1 that write access to these files is equivalent to root.

Expected state:

```
$ ls -ld /etc/pam.d
drwxr-xr-x 2 root root 4096 /etc/pam.d

$ ls -l /etc/pam.d/sshd
-rw-r--r-- 1 root root 2133 /etc/pam.d/sshd
```

Directory `0755 root:root`, files `0644 root:root`. Anything group-writable or world-writable is a finding. Anything not owned by root is a bigger one.

Verify on your own system rather than trusting the paragraph above, since the exact strictness has varied across versions:

```
# find /etc/pam.d -type f ! -user root -o -type f -perm /022
```

Empty output is what you want.

### Watching the search happen

The technique from Chapter 1 applies directly and settles the question of which file is in use faster than any amount of reading:

```
$ strace -f -e trace=openat su - someuser 2>&1 | grep -E 'pam\.d|pam\.conf|security/'
```

You will see the service file opened, then each `@include` target opened in turn, then the modules. If the file you expected does not appear in that list, you have your answer, and the remaining work is finding out which file did.

---

## 2.3 The Line Format

Now the syntax itself. Four fields:

```
type  control  module-path  module-arguments
```

Whitespace-separated. The first three are mandatory; arguments are optional and many modules take none.

```
auth      required     pam_unix.so
session   optional     pam_systemd.so
password  requisite    pam_pwquality.so  retry=3 authtok_type=UNIX
```

Alignment is purely cosmetic. Real distribution files are inconsistently aligned and it means nothing.

### Comments and continuation

A `#` at the start of a line makes the whole line a comment. A backslash at the end of a line continues it onto the next, which is occasionally useful for long argument lists and mostly makes files harder to read.

```
auth  required  pam_unix.so \
      try_first_pass nullok
```

### Field one: type

One of `auth`, `account`, `password`, `session`. Case-insensitive, so `Auth` and `AUTH` work, though every real file uses lowercase and you should too.

Chapter 3 covers what each one means. For now, the structural fact: **all lines of the same type, in file order, form one stack, and the four stacks are independent.** Lines of different types can be interleaved in the file without changing anything. These two files are identical in behaviour:

```
auth     required  pam_unix.so          auth     required  pam_unix.so
account  required  pam_unix.so          session  required  pam_limits.so
session  required  pam_limits.so        account  required  pam_unix.so
```

Order matters *within* a type. Order between types is presentation only. Most files group by type because it reads better, and a few, including Debian's `su`, do not.

#### The leading dash

A type may be prefixed with `-`:

```
-session  optional  pam_systemd.so
```

This means: if the module cannot be loaded, skip it silently instead of logging an error. It is for modules that may legitimately be absent, typically because they come from an optional package.

Two things people get wrong about it. It changes logging and loading behaviour only; it has no effect on the control flag or on what happens when the module loads and fails. And it is not a comment character. `-session` is an active line.

### Field two: control

A keyword, or `include`, or `substack`, or a bracketed expression. This field is the whole subject of Chapter 4 and gets only a placeholder here: it tells the framework what to do with the module's return value.

Like the type field, the keywords are case-insensitive.

### Field three: module-path

Either a bare filename, resolved against the distribution's default module directory, or an absolute path.

```
auth  required  pam_unix.so                                    # resolved against default dir
auth  required  /usr/lib64/security/pam_unix.so                # absolute
auth  required  /opt/vendor/lib/pam_vendorauth.so              # absolute, outside the default dir
```

Bare names are overwhelmingly the norm and are what you should write, since they keep the file portable between the two distribution families whose module directories differ.

Absolute paths are legal, and the third example above is worth pausing on. A module can be loaded from anywhere the framework can read. If `/opt/vendor/lib/` is writable by a service account, that service account has root on every login. Vendor-supplied authentication modules that install outside the system directory are common enough to be worth checking for:

```
# grep -rn '^\s*[a-z-]*\s\+.*\s/' /etc/pam.d/ | grep -v '#'
```

Anything naming a path outside your distribution's module directory deserves an explanation.

#### The module directory itself

Worth a minute of your attention, because you will be checking things in it constantly.

```
$ ls /lib/x86_64-linux-gnu/security/     # Debian, Ubuntu (multiarch triplet)
$ ls /usr/lib64/security/                # RHEL family
```

Debian uses a multiarch path, which means the triplet in the middle differs by architecture: `aarch64-linux-gnu` on ARM64, `arm-linux-gnueabihf` on 32-bit ARM. Configuration that hardcodes `x86_64-linux-gnu` is not portable across your own fleet if it is mixed, which is another argument for bare module names. To find the directory without knowing the triplet:

```
$ dirname "$(dpkg -L libpam-modules | grep pam_unix.so)"
$ rpm -ql pam | grep pam_unix.so
```

Everything in there is named `pam_*.so` by convention. The convention is not enforced by anything, and a module with a different name will load perfectly well, which is worth remembering when auditing.

Three things you can learn about any module without documentation:

```
$ objdump -T /usr/lib64/security/pam_rootok.so | grep pam_sm_   # which stacks it serves
$ ldd /usr/lib64/security/pam_sss.so                            # what it depends on
$ rpm -qf /usr/lib64/security/pam_sss.so                        # which package owns it
```

The second is more interesting than it looks. `ldd` on a module tells you what it drags into your privileged process. A module linked against a large library stack is pulling all of that into `sshd`, and every one of those libraries is now part of your authentication path's attack surface. Compare `pam_rootok.so`, which depends on essentially nothing, against a vendor SSO module that pulls in an HTTP client, a JSON parser, and a TLS stack. Both are "just a module."

### Field four: module-arguments

Space-separated tokens passed to the module. The framework does not interpret them; each module defines its own. An argument that one module treats as meaningful may be silently ignored by another, and unknown arguments are typically logged rather than treated as errors.

```
auth  required  pam_unix.so  try_first_pass nullok
```

Arguments containing spaces can be enclosed in square brackets:

```
auth  required  pam_somemodule.so  prompt=[Enter your token: ]
```

A handful of argument names are conventional across many modules, and it is worth knowing them even though the semantics belong to each module individually:

`debug` — log verbosely. Almost universal. Chapter 11 uses it heavily.

`use_first_pass` — use the password already entered by an earlier module, and fail if there is not one. Do not prompt.

`try_first_pass` — use the password already entered if there is one, otherwise prompt.

`use_authtok` — in the `password` stack, use the new token set by a previous module rather than prompting for a new one. This is the chaining mechanism from Chapter 7.

`quiet` — suppress some log output.

`nullok` — accept an empty password. Chapter 6 explains why this should not exist on a production system.

The distinction between `use_first_pass` and `try_first_pass` catches people. The first fails if no earlier module collected a password; the second prompts. In a stack where the ordering changes, that difference turns into either an extra password prompt or an unexplained authentication failure.

### What happens when the syntax is wrong

Three distinct cases, with three distinct behaviours.

**A malformed line.** Logged, and skipped. The rest of the stack evaluates without it. The dangerous version of this is a mistyped control field that happens to still be valid, which is not a syntax error at all and will be discussed in Chapter 4.

**A module that cannot be loaded.** This one is important and the log message is distinctive:

```
sshd[2451]: PAM unable to dlopen(/lib/x86_64-linux-gnu/security/pam_faillock.so): \
            /lib/x86_64-linux-gnu/security/pam_faillock.so: cannot open shared object file: \
            No such file or directory
sshd[2451]: PAM adding faulty module: /lib/x86_64-linux-gnu/security/pam_faillock.so
```

Note the second line. The framework does not drop the line. It inserts a placeholder that returns `PAM_MODULE_UNKNOWN` whenever it is invoked. What that does to your stack depends entirely on the control flag on the line, which means a missing module can be harmless, can deny every login, or can silently open a hole, depending on a field you wrote for an entirely different reason.

This is the single most compelling argument for reading Chapter 4 before you start editing anything, and it is why the `-` prefix exists: on a line marked `-session`, an absent module is skipped rather than becoming a faulty placeholder.

**A file that cannot be read.** Falls through to the `other` behaviour, or denies. See 2.6.

Try the middle case deliberately, on a test machine, and watch what happens:

```
# cp -a /etc/pam.d/su /root/su.bak
# echo 'auth required pam_thismoduledoesnotexist.so' >> /etc/pam.d/su
# journalctl -f -t su &
$ su - someuser
```

> ⚠ Second root shell open first. `su` is a good service to experiment on precisely because breaking it does not lock you out of the machine. Do not run this experiment on `sshd` or `login`.

---

## 2.4 The Shape of a Service File

Putting the pieces together, here is what a complete, self-contained service file looks like with no includes at all:

```
auth       required    pam_env.so
auth       required    pam_unix.so       try_first_pass nullok
auth       required    pam_faillock.so   authfail

account    required    pam_unix.so
account    required    pam_nologin.so

password   requisite   pam_pwquality.so  retry=3
password   required    pam_unix.so       use_authtok sha512 shadow

session    required    pam_limits.so
session    required    pam_unix.so
session    optional    pam_systemd.so
```

Four stacks, plainly separated, nothing hidden. This is what a PAM configuration looks like when nobody has factored it.

Almost no file on your system looks like this, because factoring is exactly what distributions do, and the mechanism they use is the subject of the next section.

---

## 2.5 include, substack, and Aggregation

### Why factoring exists

If you want to change the local password hash algorithm on a system with thirty service files, and each file contains its own `pam_unix` line, you have thirty edits and thirty chances to miss one. That is the problem PAM was built to solve, reappearing one level up.

The answer is the same as before: put the shared part in one place and reference it. PAM offers three mechanisms for this and they are not interchangeable.

### `@include`

```
@include common-auth
```

This is a file-level directive. It is not a line with four fields; it does not have a type or a control. It inserts **every line of every type** from the named file at that point.

Its argument is a filename resolved relative to the configuration directory, so `@include common-auth` means `/etc/pam.d/common-auth`.

This is Debian's idiom. Look again at the `sshd` file from the README:

```
@include common-auth
account    required     pam_nologin.so
@include common-account
...
@include common-session
@include common-password
```

Each `@include` pulls in whatever is in the target. The target files happen to contain lines of only one type each, which is a convention rather than a requirement, and it is what makes the reading experience tolerable.

### `include` as a control value

```
auth  include  system-auth
```

This is an ordinary four-field line whose control value happens to be `include`. It pulls in **only the lines matching this line's type** from the named file.

That is a real difference. `@include common-auth` pulls everything in `common-auth`; `auth include system-auth` pulls only the `auth` lines from `system-auth`.

This is the RHEL idiom, and it is why RHEL service files repeat the include four times with different types:

```
auth      include  system-auth
account   include  system-auth
password  include  system-auth
session   include  system-auth
```

Both idioms achieve the same thing. Knowing which one you are reading tells you which distribution family's conventions you are in before you look at anything else.

### `substack`

```
auth  substack  system-auth
```

Syntactically identical to `include`. Semantically different in two ways, and both of them are about Chapter 4's machinery, so this section states the rules and Chapter 4 explains why they matter.

**A `die` or `done` inside a substack terminates the substack, not the whole stack.** With `include`, a module that terminates evaluation terminates everything and returns to the application. With `substack`, evaluation stops at the end of the substack and continues in the parent.

**Jumps cannot escape a substack, and the entire substack counts as one module for jump arithmetic in the parent.** A numeric jump inside a substack is bounded by it. And a `success=1` in the parent stack, on the line before a `substack`, skips the whole substack, not its first line.

That second rule is the one that bites. If you convert an `include` to a `substack` in a file that also uses numeric jumps, the arithmetic changes underneath you.

Use `substack` when you want the included policy to be a self-contained decision whose result feeds into a larger one. Use `include` when you want the lines textually spliced in. If you are unsure, `include` is what the distributions use, and matching your surroundings is worth more than cleverness in a file like this.

### The Debian layout

Four aggregation files, each holding one type:

```
/etc/pam.d/common-auth
/etc/pam.d/common-account
/etc/pam.d/common-password
/etc/pam.d/common-session
/etc/pam.d/common-session-noninteractive
```

The fifth is worth noting. `common-session-noninteractive` exists for services like `cron` that need session setup but should not get interactive things like MOTD display or mail checks. When you add a session module to `common-session` and it does not take effect for scheduled jobs, this is why.

### The RHEL layout

```
/etc/pam.d/system-auth
/etc/pam.d/password-auth
/etc/pam.d/fingerprint-auth
/etc/pam.d/smartcard-auth
/etc/pam.d/postlogin
```

Two of these do most of the work, and the split between them is the thing people miss.

`system-auth` is the policy for local, console-attached logins. It is the one that can reasonably reference fingerprint readers and smart cards, because there is a human at the machine.

`password-auth` is the policy for network services that authenticate with a password. `sshd` includes this one, not `system-auth`.

The practical consequence is direct: **on a RHEL-family system, a change made only to `system-auth` will not affect SSH logins.** Adding a second factor, tightening lockout policy, or changing the authentication source in `system-auth` alone leaves your remote access path untouched, and remote access is the path that matters. This is a genuinely common mistake and it fails in the safe-looking direction, which is why it survives so long.

`postlogin` is a shared tail included by several services, holding things that should run after everything else. `fingerprint-auth` and `smartcard-auth` are alternate authentication paths referenced by `system-auth` under some `authselect` profiles.

Check which one your SSH configuration uses:

```
$ grep -n 'auth\|include' /etc/pam.d/sshd
```

---

## 2.6 The `other` Fallback

When a PAM-aware application starts with a service name that has no file, the framework uses `/etc/pam.d/other`. Every service you have not configured is governed by it, including services installed by packages that forgot to ship a file, and including any service name an attacker can persuade a program to use.

The two families ship opposite defaults.

RHEL-family, traditionally:

```
auth      required  pam_deny.so
account   required  pam_deny.so
password  required  pam_deny.so
session   required  pam_deny.so
```

Unknown service, denied. Fail closed.

Debian-family, typically:

```
@include common-auth
@include common-account
@include common-password
@include common-session
```

Unknown service, standard local authentication. Fail open, in the sense that the service works rather than being denied.

Both are defensible. Denying by default is the safer posture and produces occasional confusing breakage when a package ships without a file. Falling back to normal authentication is friendlier and means an unconfigured service silently gets a policy nobody chose for it.

What you should not have is a permissive `other` you did not know about. Look at yours now:

```
$ cat /etc/pam.d/other
```

Then convince yourself of the behaviour rather than trusting the file, using a service name that does not exist:

```
$ pamtester nosuchservice "$USER" authenticate
```

On a fail-closed system this is refused. On a fail-open system it prompts for your password and succeeds. That one command tells you more about your system's default posture than reading the file does, because it exercises the real path.

The hardening recommendation, covered properly in Chapter 11: `other` should deny, unless you have a specific reason otherwise and have written that reason down.

---

## 2.7 Generated Configuration

Here is the fact that costs people the most time in this chapter's subject area:

**Several of the files in `/etc/pam.d/` are generated by a tool, and your edits to them will be silently reverted.**

Not immediately. Not with an error. Weeks later, during a package update or a routine configuration apply, with no obvious connection to whatever change you made in the meantime. Debugging that after the fact is genuinely unpleasant, because the evidence is a file that no longer contains something you are certain you wrote.

### Debian: pam-auth-update

The `common-*` files are owned by the `libpam-runtime` package and generated by `pam-auth-update`. Open one and the markers are right there:

```
# here are the per-package modules (the "Primary" block)
auth  [success=1 default=ignore]  pam_unix.so nullok
# here's the fallback if no module succeeds
auth  requisite                   pam_deny.so
# prime the stack with a positive return value if there isn't one already;
# this avoids us returning an error just because nothing sets a success code
auth  required                    pam_permit.so
# and here are more per-package modules (the "Additional" block)
# end of pam-auth-update config
```

Anything between those markers is generated. The inputs are profile files in `/usr/share/pam-configs/`:

```
$ ls /usr/share/pam-configs/
capability  krb5  mkhomedir  systemd  unix
```

Each describes a chunk of policy, its priority relative to other chunks, and which stacks it contributes to. `pam-auth-update` reads them, orders them by priority, and writes the `common-*` files.

Interactively:

```
# pam-auth-update
```

Non-interactively, which is what you want in configuration management:

```
# pam-auth-update --package
# pam-auth-update --enable mkhomedir
# pam-auth-update --disable krb5
```

To add policy of your own, write a profile in `/usr/share/pam-configs/` and let the tool integrate it. To add policy without fighting the tool at all, put it in the service file rather than in `common-*`, since service files are not generated.

### RHEL: authselect

The RHEL family goes further. Look at what those files actually are:

```
$ ls -l /etc/pam.d/system-auth /etc/pam.d/password-auth
lrwxrwxrwx 1 root root 26 /etc/pam.d/password-auth -> /etc/authselect/password-auth
lrwxrwxrwx 1 root root 24 /etc/pam.d/system-auth   -> /etc/authselect/system-auth
```

Symlinks. The real files live under `/etc/authselect/`, generated from a profile. If you edit through the symlink you are editing generated output, and `authselect` will tell you so:

```
# authselect check
Current configuration is not valid. It was probably modified outside authselect.
```

The normal workflow:

```
# authselect current                      # which profile is active
# authselect list                         # available profiles
# authselect list-features sssd           # what the profile can toggle
# authselect select sssd with-mkhomedir with-faillock
# authselect apply-changes
```

To make changes the tool will preserve, create a custom profile based on a stock one:

```
# authselect create-profile myorg --base-on sssd
# vi /etc/authselect/custom/myorg/system-auth
# authselect select custom/myorg
# authselect apply-changes
```

Now your edits live in a profile that `authselect` regenerates *from*, rather than in output it regenerates *over*.

### The rule

Before editing anything in `/etc/pam.d/`, determine whether it is generated:

```
# head -5 /etc/pam.d/common-auth              # Debian: look for the markers
# ls -l /etc/pam.d/system-auth                 # RHEL: is it a symlink?
# authselect check                             # RHEL: is it unmodified?
# dpkg -S /etc/pam.d/common-auth               # which package owns it
# rpm -qf /etc/pam.d/system-auth
```

Ten seconds, and it saves an incident.

### PAM under configuration management

If Ansible, Puppet, Salt, or anything similar manages these hosts, the same rule applies with a twist: your tooling is now a third party that can overwrite the same files, and it does not know about `pam-auth-update` or `authselect` unless you tell it.

Three patterns, in descending order of how well they work.

**Manage the inputs, not the outputs.** On Debian, ship a profile into `/usr/share/pam-configs/` and run `pam-auth-update --package`. On RHEL, ship a custom `authselect` profile and run `authselect select custom/yourprofile`. Your tooling and the distribution's tooling then agree about who owns what, and package updates do not fight you.

**Manage service files directly.** Service files are not generated, so templating `/etc/pam.d/sshd` is safe and idempotent. This is the right place for narrow, service-specific policy, and it is the pattern most organisations end up with because it is simple and it works.

**Template the aggregation files directly.** This works until the day a package update runs `pam-auth-update`, or someone runs `authselect apply-changes`, and the generated content and your template disagree. Then you have a fleet where the running configuration depends on the order in which two tools last executed. Avoid.

Whichever pattern you choose, two things belong in the playbook itself rather than in a runbook nobody reads: a validation step that runs `pamtester` against at least two services after the change, and a handler that fails loudly rather than continuing if that validation does not pass. A configuration management run that cheerfully deploys a broken `common-auth` to two hundred hosts is a different class of problem from breaking one machine by hand, and the failure is fast, simultaneous, and total.

---

## 2.8 Reading an Unfamiliar System

A procedure. It takes about five minutes and it is worth doing on any machine you inherit, before you need to.

**Step 1: what services exist.**

```
$ ls /etc/pam.d/
```

**Step 2: which are generated.** Debian: `grep -l 'pam-auth-update' /etc/pam.d/*`. RHEL: `ls -l /etc/pam.d/ | grep '\->'` and `authselect check`.

**Step 3: what the fallback is.** `cat /etc/pam.d/other`, then confirm with `pamtester nosuchservice "$USER" authenticate`.

**Step 4: which binaries are PAM-aware**, using the loop from Chapter 1, and note any that have no service file. Those are governed by `other`.

**Step 5: flatten the service you care about.** Includes make a file unreadable as written. Expand them:

```bash
#!/bin/bash
# pamflat — expand @include directives in a PAM service file
# usage: pamflat sshd
flatten() {
    local file=$1 depth=$2
    [ -r "$file" ] || { printf '%*s!! unreadable: %s\n' $((depth*2)) '' "$file"; return; }
    while IFS= read -r line; do
        case "$line" in
            \#*|'') continue ;;
            @include*)
                local target="/etc/pam.d/${line#@include }"
                printf '%*s>> %s\n' $((depth*2)) '' "$target"
                flatten "$target" $((depth+1))
                ;;
            *) printf '%*s%s\n' $((depth*2)) '' "$line" ;;
        esac
    done < "$file"
}
flatten "/etc/pam.d/${1:?service name required}" 0
```

```
$ ./pamflat sshd
```

Two limitations, both deliberate, both worth understanding rather than fixing.

It does not expand `include` and `substack` control values, only `@include`. Adding that is a good exercise and forces you to confront the type-filtering rule from 2.5, since `auth include system-auth` must pull only the `auth` lines.

It shows you the lines in file order, which is not evaluation order, because the four stacks are independent. Grouping the output by type is the next exercise, and after Chapter 4 you will want a third version that annotates each line with what happens on success and on failure.

**Step 6: check the module set.** For each module named, confirm it exists and confirm which stacks it can serve:

```
$ for m in $(grep -ho 'pam_[a-z0-9_]*\.so' /etc/pam.d/* | sort -u); do
      p=$(ls /lib/*/security/$m /usr/lib64/security/$m 2>/dev/null | head -1)
      [ -n "$p" ] && echo "OK   $m" || echo "MISS $m"
  done
```

Anything reported as missing is a faulty-module placeholder waiting to happen.

**Step 7: verify integrity**, with the commands from Chapter 1: `rpm -V pam`, `debsums -c libpam-modules`, and a look at the modification times in `/etc/pam.d/`.

---

## 2.9 Ownership, Permissions, and Change Control

Chapter 1 argued that write access to `/etc/pam.d/` is equivalent to root. Here is what that implies operationally, which mostly belongs to Chapter 11 but has to be said before you start editing.

The whole directory should be `root:root`, files `0644`, directory `0755`. Nothing group-writable. No file owned by a service account, ever, including files a vendor installer created.

```
# find /etc/pam.d /etc/security -type f \( ! -user root -o -perm /022 \)
# find /lib/*/security /usr/lib64/security -type f \( ! -user root -o -perm /022 \) 2>/dev/null
```

Both should return nothing.

Changes should be tracked. In practice this means one of three things: the files are managed by configuration management and the repository is the source of truth; or the directory is under version control on the host; or, at minimum, auditd is watching:

```
-w /etc/pam.d/          -p wa -k pam_config
-w /etc/security/       -p wa -k pam_config
```

The reason to say this in Chapter 2 rather than Chapter 11 is that you are about to start editing these files as part of working through the series, and the habits are easier to form now than to retrofit.

### A safe edit procedure

Six steps. They take under a minute and they are the difference between an experiment and an incident.

**1. Open a second root shell** in a separate terminal. Leave it there. Do not use it for anything. It is not a workspace, it is a fire exit.

**2. Determine the blast radius** using 2.12, and confirm the file is not generated using 2.7.

**3. Back up, in the same command that opens the editor:**

```
# cp -a /etc/pam.d/sshd /root/sshd.$(date +%F-%H%M%S).bak && vi /etc/pam.d/sshd
```

**4. Test without committing to a login.** `pamtester` exercises the stack in a process you can kill:

```
$ pamtester sshd "$USER" authenticate
$ pamtester -v sshd "$USER" authenticate acct_mgmt
```

If this fails, you have found the problem without having locked anybody out.

**5. Test with a real, new session, from a different terminal.** The session you are in proves nothing. For `sshd`, open a fresh connection while keeping the current one. For `login`, use a spare virtual console.

**6. Watch the logs while you do steps 4 and 5:**

```
# journalctl -f -t sshd -t su -t sudo
```

If any step fails, restore the backup from the shell you opened in step 1 and start again. If you skipped step 1, this is the paragraph you will remember.

One addition for anything touching an aggregation file: do steps 4 and 5 for at least two services, not one. The whole point of an aggregation file is that it affects many services, and a change that works for `sshd` and breaks `sudo` is a change that has removed your ability to fix it.

---

## 2.10 A Worked Example

Bring the chapter together on a concrete question: *what is the complete `auth` policy for SSH on this Debian machine?*

Start at the service file:

```
$ grep -n '^auth\|^@include\|^-auth' /etc/pam.d/sshd
1:@include common-auth
```

One line. Everything is in `common-auth`. Is that file generated?

```
$ head -3 /etc/pam.d/common-auth
#
# /etc/pam.d/common-auth - authentication settings common to all services
#
$ grep -n 'pam-auth-update' /etc/pam.d/common-auth
34:# end of pam-auth-update config
```

Generated. Note that, and do not plan to edit it directly.

```
$ grep -v '^#' /etc/pam.d/common-auth | grep -v '^$'
auth  [success=1 default=ignore]  pam_unix.so nullok
auth  requisite                   pam_deny.so
auth  required                    pam_permit.so
```

Three lines. Do the modules exist?

```
$ ls /lib/x86_64-linux-gnu/security/pam_{unix,deny,permit}.so
```

Yes. Does `sshd` actually consult this?

```
$ grep -i '^UsePAM\|^KbdInteractive\|^PasswordAuth\|^PubkeyAuth' /etc/ssh/sshd_config
UsePAM yes
PasswordAuthentication yes
```

So: password logins traverse those three lines; key-based logins skip them entirely and go straight to `account` and `session`.

Confirm empirically:

```
$ strace -f -e trace=openat pamtester sshd "$USER" authenticate 2>&1 | grep -E 'pam\.d|security/'
```

The answer to the original question is now: local Unix passwords, empty passwords accepted where the shadow entry permits, no lockout, no second factor, and none of it applies to key-based logins at all. That took under two minutes and did not require understanding what `[success=1 default=ignore]` means, which is Chapter 4's job.

Notice how much of the work was locating things rather than interpreting them. That is the normal ratio, and it is why this chapter exists.

---

## 2.11 The Service Files You Will Actually Meet

A stock server has twenty to forty files in `/etc/pam.d/` and you will spend your time in about eight of them. Here is what they govern, in rough order of how often they matter.

**`sshd`** — remote access. The most important file on a server, for the obvious reason. Note the Chapter 1 caveat: with key-based authentication the `auth` stack is not consulted, while `account` and `session` still are. On RHEL this file includes `password-auth`, not `system-auth`.

**`login`** — the console. The file that matters when everything else is broken, which is precisely why you should be careful with it. A mistake in `sshd` costs you remote access; a mistake in `login` costs you the console too, and at that point your options are single-user mode or a rescue image.

**`su`** — switching users. The best file to experiment in, because breaking it does not deny you anything you cannot get another way. Contains `pam_rootok` at the top and, usually commented out, `pam_wheel`.

**`sudo`** and sometimes **`sudo-i`** — privilege escalation. Remember that sudo's own timestamp caching sits in front of this, so a stack you think is not running is often a stack that was not asked. `sudo -k` before every test.

**`passwd`** — the `password` stack in isolation. Almost nothing else in this file matters. `pam_rootok` at the top is what lets root change another user's password without knowing the old one.

**`cron`** — scheduled jobs. No meaningful authentication, but the `account` stack decides whether an expired user's jobs run, and the `session` stack applies limits and environment. On Debian it pulls `common-session-noninteractive` rather than `common-session`, which is the answer to "why did my session module not apply to cron jobs."

**`systemd-user`** — the per-user systemd instance. Created by systemd, not by you, and easy to overlook. When user services fail to start with errors that look nothing like authentication, this file is a candidate.

**`polkit-1`** — used when a desktop or a service asks for authorisation through polkit. Mostly relevant on workstations.

**`runuser`** and **`runuser-l`** — like `su`, but used by service scripts to drop privilege without authenticating. Note that `runuser` deliberately does *not* authenticate, which makes it a useful thing to know exists when you are auditing what can become another user on a box.

**`chsh`, `chfn`, `chage`, `newusers`** — small utilities with small files, mostly `pam_rootok` plus a reference to the common policy.

**`gdm-password`, `gdm-autologin`, `lightdm`, `sddm`** — graphical login. Present only on desktops, and the session stacks in them are longer and more interesting than the server equivalents.

**`vsftpd`, `dovecot`, `smtp`, `vmware-*`, and vendor files** — whatever your packages installed. Every one of these is a way into the machine. When auditing, this group is where surprises live, because the files were written by the package maintainer with their service in mind and nobody has looked at them since.

A useful habit on a new machine: list the files, subtract the ones above, and read whatever remains. That residue is usually short and usually the interesting part.

---

## 2.12 Blast Radius

Before you edit, know how many services your edit affects. This is the single most useful discipline in this chapter and it takes one command.

Editing a service file affects one service:

```
$ vi /etc/pam.d/sshd          # affects: sshd
```

Editing an aggregation file affects everything that includes it:

```
$ grep -l 'common-auth' /etc/pam.d/*        # Debian
$ grep -l 'system-auth\|password-auth' /etc/pam.d/*   # RHEL
```

On a typical Debian server the first command returns fifteen to twenty-five files. That is your blast radius: every one of those services changes behaviour when you touch `common-auth`. Including `login`. Including `sshd`. Including, on many systems, `sudo`, which means a mistake can remove your ability to fix the mistake.

The decision rule that follows:

**Policy that should apply everywhere goes in the aggregation file.** Password quality, lockout, the authentication source. That is what those files are for, and applying such a policy per-service is how you end up with a fleet where nobody can say what the policy is.

**Policy that applies to one service goes in that service's file.** SSH-specific access restrictions, a second factor for remote access only, session settings for scheduled jobs. Putting these in `common-*` means they apply to `sudo` and `su` as well, which is rarely what anyone wanted and is occasionally dangerous.

**When in doubt, start narrow.** Put it in one service file, test it, then widen. Widening is a two-line change. Recovering a fleet where every login path broke simultaneously is not.

One more consideration specific to the generated files. On Debian, `common-auth` is generated, so service-file edits are also the path of least resistance for anything you want to survive `pam-auth-update`. On RHEL, `password-auth` and `system-auth` are symlinks into an `authselect` profile, so the equivalent advice is: use a custom profile for fleet-wide policy, use service files for anything narrower.

---

## 2.13 include Versus substack, Worked

Section 2.5 stated the rules. Here is why they matter, using the only mechanism from Chapter 4 you need in advance: `success=N` skips forward N modules of the same type.

Suppose `/etc/pam.d/mypolicy` contains:

```
auth  [success=1 default=ignore]  pam_unix.so
auth  requisite                   pam_deny.so
auth  required                    pam_permit.so
```

Three modules. Now a service file that uses it, with `include`:

```
auth  required                    pam_env.so
auth  include                     mypolicy
auth  optional                    pam_echo.so file=/etc/motd.auth
```

The framework splices the three lines in. The stack is five modules deep. A `success=1` on the first line of `mypolicy` skips one module and lands on `pam_permit.so`, as intended, because the arithmetic is over the flattened stack.

Now the same thing with `substack`:

```
auth  required                    pam_env.so
auth  substack                    mypolicy
auth  optional                    pam_echo.so file=/etc/motd.auth
```

The parent stack is now three modules deep, not five. The substack counts as one. Inside it, the jump arithmetic is over the substack's own three lines, so `success=1` still works as intended, and it cannot jump out into the parent.

The difference shows up when you add a jump in the parent:

```
auth  [success=1 default=ignore]  pam_localuser.so
auth  substack                    mypolicy
auth  required                    pam_deny.so
```

`success=1` here skips the entire substack and lands on `pam_deny.so`. Written with `include` instead, the same `success=1` would skip only the first line of the included file and land in the middle of `mypolicy`, in a state its author never intended.

That is the practical rule: **numeric jumps and `include` are a bad combination across file boundaries, because the target of the jump depends on the contents of another file.** If you find yourself writing one, use `substack`, or restructure so no jump crosses a boundary. Chapter 4 has more to say about numeric jumps in general, none of it enthusiastic.

The second difference, `die` and `done` being contained by a substack, follows the same shape. With `include`, a `requisite` failure inside the included file returns straight to the application. With `substack`, it terminates the substack and the parent continues with that result. Which of those you want depends on whether the included file is "part of this policy" or "a self-contained decision that feeds this policy," and that is a design question, not a syntax question.

---

## 2.14 When You Actually Meet pam.conf

Rare, but not never.

Minimal and embedded systems sometimes ship `/etc/pam.conf` alone, without the directory, because one file is simpler to manage in a read-only root filesystem. Some container base images do the same for size. And some commercial Unix software installs its own `pam.conf` and expects it to be read, which on a Linux host with `/etc/pam.d/` present it will not be.

The format is the four fields you already know plus a leading service name:

```
service  type  control  module-path  module-arguments
```

Everything else, the control values, the includes, the module resolution, works the same way.

The thing to check, if you find yourself on such a system, is whether the directory exists at all:

```
$ ls -d /etc/pam.d 2>/dev/null && echo "pam.d wins" || echo "pam.conf is live"
```

And the thing to remember, if you are debugging a vendor application that ships its own `pam.conf`: on your system, that file is decoration. The vendor's service needs a file in `/etc/pam.d/` instead, and translating one to the other is mechanical.

---

## 2.15 Failure Signature Reference

Keep this near Chapter 11's version, which covers the module layer in far more detail.

| What you see | Likely cause | Check |
|---|---|---|
| Edits to a file have no effect | Wrong file; service uses a different name; generated file reverted | `strace -e trace=openat`; `authselect check`; markers in `common-*` |
| `PAM unable to dlopen(...)` / `adding faulty module` | Module named but not installed | `ls` the module path; install the package or remove the line |
| Every login denied after an edit | Faulty module on a `required` line, or a jump running past the end of the stack | Compare against backup; Chapter 4 |
| Works locally, fails over SSH on RHEL | Change made in `system-auth` instead of `password-auth` | `grep include /etc/pam.d/sshd` |
| Works for interactive login, not for cron on Debian | Change made in `common-session`, not `common-session-noninteractive` | `grep include /etc/pam.d/cron` |
| Unknown service authenticates successfully | Permissive `/etc/pam.d/other` | `pamtester nosuchservice "$USER" authenticate` |
| Change reverted after a package update | Generated file | `dpkg -S`, `rpm -qf`, `authselect check` |
| Second factor added but key logins unaffected | SSH keys bypass the `auth` stack | Chapter 10 |
| Extra password prompt appeared | `try_first_pass` where `use_first_pass` was meant, or stack reordering | Read the arguments on each module |

---

## 2.16 Verification

Test machine, snapshot, second root shell. From here on the exercises modify files that decide whether people can log in.

**1. Establish which configuration format is live.**

```
$ ls -ld /etc/pam.d/ ; ls -l /etc/pam.conf 2>/dev/null
```

If both exist, state which one governs and why.

**2. Prove the service name is not the program name.**

Find a program whose PAM service name differs from its binary name. `sudo -i` is a good starting point. Use `strace` to confirm which file is opened.

**3. Trigger a faulty module and observe the placeholder.**

Append a line naming a nonexistent module to `/etc/pam.d/su`, with control `optional`. Attempt `su`. Then change the control to `required` and attempt again. Explain the difference in outcome using only what you have read so far, then check your explanation against Chapter 4 later.

**4. Compare `-` and no `-`.**

Repeat exercise 3 with `-auth` instead of `auth`. What changes in the logs? What changes in behaviour?

**5. Determine your fallback posture.**

```
$ cat /etc/pam.d/other
$ pamtester nosuchservice "$USER" authenticate
```

Do the file and the observed behaviour agree?

**6. Identify every generated file on the system.**

Debian: `grep -l 'end of pam-auth-update config' /etc/pam.d/*`. RHEL: `ls -l /etc/pam.d/ | grep '\->'` plus `authselect check`. Write the list down. These are the files you will not edit directly.

**7. Flatten a service.**

Run the `pamflat` script against `sshd`, `su`, and `cron`. Then extend it to handle `include` and `substack` control values with correct type filtering. This is the most valuable exercise in the chapter.

**8. Find the RHEL split in the wild.**

On a RHEL-family system, determine whether `sshd` uses `system-auth` or `password-auth`. Then work out which file a lockout policy would have to go in to cover both console and SSH.

**9. Audit module paths.**

```
# grep -rn '/.*\.so' /etc/pam.d/ | grep -v '^\s*#'
```

Is every absolute path inside your distribution's module directory? If not, who can write to the directory it names?

**10. Break it and fix it.**

Deliberately introduce each of the four failure modes from 2.1 on `su`, one at a time, and identify each one from the logs alone before looking at the file. Restore from your backup between attempts. This is the exercise that makes Chapter 11 easy.

**11. Measure your blast radius.**

```
$ grep -l 'common-auth' /etc/pam.d/*                     # Debian
$ grep -l 'system-auth\|password-auth' /etc/pam.d/*      # RHEL
```

Count the results. For each one, decide whether you would be comfortable with it changing behaviour as a side effect of an edit you made for a different reason. Then find one policy currently sitting in an aggregation file that should be in a service file, or the reverse, and justify moving it.

**12. Compare the dependency footprint of two modules.**

```
$ ldd /usr/lib64/security/pam_rootok.so
$ ldd /usr/lib64/security/pam_sss.so
```

Count the shared libraries each one pulls into a root process. If a third-party SSO or MFA module is installed on your system, run the same command against it and compare. Then answer honestly: does your organisation's software inventory account for those libraries as part of the authentication path?

---

## Where This Goes Next

You can now find the configuration, read a line, follow includes, and tell a generated file from a hand-maintained one. What you cannot yet do is say what a stack *means*.

Chapter 3 takes the four types and explains what each one is responsible for and when the framework runs it, which is the vocabulary Chapter 4 needs. Chapter 4 then supplies the evaluation algorithm, and at that point the three-line `common-auth` file you have looked at several times now will stop being a piece of trivia and start being something you can reason about.

One thing to carry forward from this chapter specifically: the `include` and `substack` distinction in 2.5 is stated there but not justified. It cannot be justified until you know what `die` and `done` do, and that is Chapter 4. When you get there, come back and reread 2.5. It will read differently.

---

## Further Reading for This Chapter

- `man 5 pam.d` — the authoritative reference for everything in 2.3 and 2.5
- `man 5 pam.conf` — the legacy format, and the same field descriptions
- `man 8 pam-auth-update` and `/usr/share/doc/libpam-runtime/` on Debian
- `man 8 authselect` and `man 5 authselect-profiles` on the RHEL family
- `man 8 pamtester`
- The Linux-PAM System Administrators' Guide, sections on configuration file syntax
