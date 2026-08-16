# 01 — Introduction and the PAM Problem

Every system that lets people in has to answer the same question at some point: is this person who they claim to be. On Unix, the answer to that question lived inside individual programs for about twenty years, and then it moved out. This chapter is about why it moved, what it moved into, and what that decision means for the machine in front of you today.

We are going to spend most of the chapter in the past, which may seem like an odd choice for a technical reference. The reason is practical. PAM's design is a direct, point-by-point response to a specific set of failures, and almost every part of it that looks arbitrary stops looking arbitrary once you know which failure it was answering. The four management groups, the per-service configuration files, the stacking, the fact that modules are shared objects rather than external processes: none of these are aesthetic choices. Each one is there because something concrete was broken.

By the end of this chapter you should be able to explain what problem PAM solves, determine whether any given program on your system participates in it, describe where all its pieces live on disk, and trace a single `su` invocation from the shell you typed it in to the shell it hands back. The trace is deliberately shallow here. Chapter 10 repeats it at full depth, and the two together are meant to bracket everything in between.

---

## 1.1 The System Before PAM

### The password file

Start with the data structure, because everything else follows from it. A line in `/etc/passwd` on an early Unix system looked like this:

```
parsa:x8dK2mQvR7pLs:1001:1001:Parsa Majidipour:/home/parsa:/bin/sh
```

Seven colon-separated fields: login name, encrypted password, UID, GID, GECOS comment, home directory, shell. The second field is the one that matters here. Thirteen characters. That string was the entire authentication state for the account.

The file was world-readable, and it had to be, because programs running as ordinary users needed the other six fields constantly. `ls -l` needs to map UID 1001 to `parsa`. `finger` reads the GECOS field. `login` needs the shell path. There was no way to hide field two without hiding the rest, and hiding the rest would have broken most of userspace.

That decision, world-readable hashes, was defensible in 1975 and indefensible by 1985, and undoing it took the better part of a decade. We will come back to it.

### What login actually did

The authentication logic in `login` was roughly this:

```c
struct passwd *pw = getpwnam(username);
if (pw == NULL)
        goto fail;

char *typed = getpass("Password: ");
char *hashed = crypt(typed, pw->pw_passwd);

if (strcmp(hashed, pw->pw_passwd) != 0)
        goto fail;

/* success: set up the session by hand */
setgid(pw->pw_gid);
initgroups(pw->pw_name, pw->pw_gid);
setuid(pw->pw_uid);
chdir(pw->pw_dir);
execl(pw->pw_shell, pw->pw_shell, NULL);
```

Eight lines of real work. `getpwnam()` reads the passwd database. `getpass()` turns off terminal echo and reads a line. `crypt()` does the hashing, using the first two characters of the stored value as the salt, which is why the stored value can be passed to it directly. `strcmp()` compares.

It is worth appreciating how clean this is before criticising it. There is no indirection, no configuration, nothing to misconfigure. Read the code and you know exactly what the system will do. That property is genuinely valuable and PAM gives it up in exchange for flexibility, which is a trade rather than a free improvement.

### crypt(3), briefly

The `crypt()` of that era was a modified DES construction. The details matter more than you might expect, because several of them created constraints that shaped the next twenty years.

The password was truncated to eight characters. Not rejected, not warned about: truncated, silently. Characters nine onward were discarded. Only the low seven bits of each character were used, so the effective keyspace was 56 bits at absolute best, and vastly less in practice because people choose words.

The salt was two characters drawn from a 64-character alphabet, giving 4096 possible values, twelve bits. Its purpose was to make precomputed dictionaries impractical and to ensure that two users with the same password had different stored strings. Twelve bits was adequate against a 1979 attacker and trivial against a 1995 one.

The output was thirteen characters: the two salt characters followed by eleven characters encoding the result. Fixed width. Several programs assumed that width, which is a detail that will matter shortly.

The algorithm ran DES twenty-five times, deliberately, to be slow. On a PDP-11 that was slow. The idea of tunable cost, of a hash whose work factor could be raised as hardware improved, arrives much later with bcrypt, and its absence here is exactly why the whole ecosystem had to migrate.

The modification to DES is worth one sentence, because it is a nice piece of history: the algorithm perturbs DES's expansion permutation using the salt, which had the side effect of making stock DES hardware useless for cracking passwords. That was deliberate. In 1979 the expensive fast implementations of DES were in silicon, and the design made sure they could not be pointed at `/etc/passwd`. The defence held for about a decade and then general-purpose CPUs got fast enough that it did not matter, which is a pattern worth noticing: a cost-based defence with no tuning parameter has a shelf life set by Moore's law, and every password hash designed since has had one.

### And every other program did the same

`login` was not special. Any program that needed to verify a user carried its own version of that logic:

`su`, `passwd`, `chsh`, `chfn`, `xdm`, `xlock`, `ftpd`, `rlogind`, `rshd`, `telnetd`, `uucico`, `imapd`, `popd`, `lpd` on some systems, plus whatever vendor-specific daemons your machine shipped with, plus every commercial application that wanted to check a Unix password.

The code was similar in each. It was never identical. Some checked for an expired account and some did not. Some handled the empty-password case one way and some another. Some had subtle bugs in the terminal handling that leaked the password into a process listing. Each was maintained separately, by different people, on different schedules.

That is the situation PAM was designed to fix. Now let us be precise about what was actually wrong with it, because "code duplication is bad" is not the interesting part.

---

## 1.2 Three Failures

### 1.2.1 Changing policy meant changing programs

The first migration was the shadow file.

Once password cracking became practical, a world-readable file full of hashes stopped being acceptable. The fix was to move field two into `/etc/shadow`, readable only by root, and leave an `x` placeholder behind. Sensible. It also broke every single program in the list above, because they had all been reading `pw->pw_passwd` and now that field contained a literal `x`.

Fixing them was not just a recompile against a new libc. A program that needs to read `/etc/shadow` needs privilege it previously did not need. `login` already ran as root, so it was fine. `xlock` did not, and giving a screen locker root privilege to check a password is a poor trade. The eventual answer, on Linux, is a small setgid helper binary that does the comparison on behalf of an unprivileged caller. You can still see it:

```
$ ls -l /usr/sbin/unix_chkpwd
-rwxr-sr-x 1 root shadow 35112 /usr/sbin/unix_chkpwd
```

Setgid `shadow`, not setuid root. That binary exists because of this exact problem, and `pam_unix` still uses it today when it finds itself running in a process that cannot read the shadow file directly. Chapter 6 covers it properly.

Shadow was migration one. The hash algorithm migrations followed, and there have been several. Modern Linux systems encode the algorithm in the stored string itself, using what is usually called the modular crypt format:

| Prefix | Algorithm | Notes |
|---|---|---|
| *(none)* | DES-crypt | 13 characters, 8-char password limit |
| `$1$` | MD5-crypt | Ported from FreeBSD, no longer appropriate |
| `$2a$`, `$2b$`, `$2y$` | bcrypt | Tunable cost, common on BSD, available on Linux |
| `$5$` | SHA-256-crypt | Configurable rounds |
| `$6$` | SHA-512-crypt | Long the RHEL-family default |
| `$y$` | yescrypt | Memory-hard, current Debian and Ubuntu default |
| `$gy$` | gost-yescrypt | yescrypt with GOST hashing |
| `$7$` | scrypt | Memory-hard, less commonly deployed |

Look at your own system:

```
# awk -F: '{print $1, substr($2,1,4)}' /etc/shadow | head
```

Every one of those transitions, under the pre-PAM model, would have meant patching and rebuilding every authenticating program on the system. Not once. Each time.

Now widen the frame. It was not only the local hash format that changed. Sites wanted to authenticate against NIS, then against Kerberos, then against LDAP directories, then against RSA SecurID tokens, then against smart cards, then against one-time-password systems, and today against U2F and FIDO2 hardware. Under the old model each of those requires a patched version of every authenticating binary, obtained from somewhere, maintained forever. In practice, sites got a patched `login` and a patched `ftpd` from their vendor and everything else kept using local passwords, which meant the security policy the organisation believed it had and the one it actually had were different documents.

### 1.2.2 There was nowhere to put a policy

Take a rule that any real organisation might want:

> Contractors may only log in between 08:00 and 18:00, only from the office network, and only to the build servers.

Where does that go? There is no file. There is no configuration syntax. There is no subsystem whose job it is to hold rules of that shape. The only way to enforce it is to modify every program capable of starting a session, and you have no reliable way to enumerate that set.

What sites did instead was accumulate ad hoc, per-program mechanisms, and the fossils are still on your disk:

`/etc/ftpusers` — a list of accounts `ftpd` refuses. Understood only by `ftpd`.

`/etc/securetty` — terminals on which root may log in. Understood only by `login`, and now largely gone from modern distributions.

`/etc/nologin` — a file whose existence blocks non-root logins. Honoured by `login`, and by other programs only if they were written to check.

`/etc/shells` — the list of shells `chsh` will accept, also consulted by some FTP daemons, for reasons of convention rather than design.

Restricted shells, wrapper scripts, `.k5login`, per-daemon allow files, creative permissions on the binaries themselves.

Every one of these is a single-purpose file understood by a single program. None composes with any other. Adding a new rule meant adding a new file and a new program that knows about it, and the rule applied only where somebody remembered to implement it.

It is worth walking through how a site would actually have attempted the contractor rule, because the failure mode is instructive. You would start by giving contractors a restricted shell, so that even if they got in they could do less. Then you would add a wrapper: replace their shell with a script that checks the clock and the source address, and either execs the real shell or exits. Then you would discover that `ftpd` never runs the login shell, so FTP bypasses the check entirely, and you would add the contractors to `/etc/ftpusers`. Then someone would point out that `rsh` also bypasses it, and that `cron` jobs run outside the check by design, and that the wrapper only sees the environment `login` gave it, which on some paths does not include the source address at all.

Six weeks later you have four mechanisms, none of which agree, no way to tell which services are covered, and no way to answer an auditor's question about what the policy actually is. Every one of those mechanisms lives in a different place and is maintained by a different convention.

The relevant part of PAM's design is that `/etc/security/access.conf` is one file, consulted by one module, and that module can be added to any service's stack. The rule and the enforcement point are separated. That is the whole idea, and the reason it matters is not elegance, it is that the question "which services enforce this rule" acquires an answer you can read off a filesystem.

### 1.2.3 Four questions treated as one

This is the subtlest of the three and the one that shapes PAM's structure most directly.

"Can this user log in" is not one question. It is at least four, and they are independent:

**Can they prove they are who they say?** The credential check. This is what everyone means by authentication.

**Is this account allowed to be used right now?** Completely separate. The password can be perfectly correct while the account is expired, or disabled, or restricted to certain hours, or barred from this particular host. Nothing about verifying a credential tells you anything about this.

**Does the credential need replacing before we continue?** A third question with a third answer, and one with awkward control flow, because the answer "yes" means an entire interactive subprocedure has to run before the login can proceed.

**What has to exist around this session?** Resource limits, environment variables, a home directory if one does not exist, an audit identity, a kernel keyring, a place in the process hierarchy. And all of it has to be torn down afterwards.

Monolithic programs mashed all four into one function, which is why software of that era behaved so unevenly around the edges. Expired accounts that could still log in through one service and not another. Forced password changes that looped forever because the program that forced them had no way to actually change the password. Sessions with no resource limits because the program that started them had never heard of resource limits.

PAM's four management groups, `auth`, `account`, `password`, `session`, are exactly this decomposition. Not four ways of doing one thing. Four separate things that had been incorrectly treated as one. Chapter 3 covers each in depth, and it is worth carrying the origin story with you when you get there, because the boundaries between them make far more sense as a list of previously conflated concerns than as an arbitrary taxonomy.

---

## 1.3 The Proposal

In October 1995, Sun Microsystems published OSF-RFC 86.0, "Unified Login with Pluggable Authentication Modules," authored by Vipin Samar and Roland Schemers. It is short, readable, and worth an hour of your time. The design it describes is what runs on your machine right now, with remarkably few changes in thirty years.

The core proposition:

> An application that needs authentication should not implement authentication. It should call a library. The library should consult a per-service configuration file, which names shared objects to load and rules for combining their results.

Four design goals follow from that, and each maps onto one of the failures above.

**The administrator chooses the mechanism, not the programmer.** Policy lives in a text file, editable at runtime, with no compilation step. This kills failure 1.2.1 directly. Migrating from SHA-512 to yescrypt, or adding Kerberos, becomes an edit rather than a rebuild.

**The application does not know or care what mechanism is used.** `sshd` calls `pam_authenticate()` and receives a result. Whether that result came from a local hash comparison, a Kerberos exchange, or a hardware token challenge is genuinely invisible to it. This is what makes the first goal possible: if applications could see the mechanism they would grow dependencies on it.

**Mechanisms stack.** Not a choice between local passwords and LDAP, but an ordered list, with rules for combining results. Try local, fall back to the directory. Require a password *and* a hardware token. Check the password, then check the time of day, then check the source host. This is what replaces the pile of single-purpose files from 1.2.2 with something composable.

**The four concerns are separated at the API level.** Not by convention, not by documentation, but by having four distinct sets of entry points that the framework invokes independently. This is the answer to 1.2.3, and it is enforced rather than suggested.

There is a cost, and the RFC is honest about it. Modules are shared objects loaded into the address space of a privileged process. `pam_unix.so` runs inside `sshd`, which is running as root. There is no isolation, no sandbox, no privilege boundary between the framework and a module. A module that is malicious, or merely buggy, has the full privilege of the calling process. This makes the module directory and `/etc/pam.d/` two of the most security-sensitive locations on the filesystem, a point Chapter 11 returns to at length.

Adoption was quick. Solaris shipped PAM in 2.6. Andrew Morgan started Linux-PAM in 1996, following the RFC closely, and it became the standard implementation across Linux distributions well before the end of the decade. HP-UX and AIX grew their own implementations. FreeBSD eventually took a different route, which we will get to in 1.6.

### A rough timeline

Useful for orientation, and for calibrating how much to trust a given piece of documentation you find online.

| Period | What happened |
|---|---|
| 1970s | DES-crypt and world-readable `/etc/passwd` |
| Mid 1980s | Password cracking becomes practical on commodity hardware |
| Late 1980s | Shadow passwords appear; every authenticating binary needs rework |
| Early 1990s | NIS, Kerberos, and token vendors each require patched binaries |
| Oct 1995 | OSF-RFC 86.0 published |
| 1996 | Linux-PAM started by Andrew Morgan |
| 1997 | Solaris 2.6 ships PAM |
| Late 1990s | MD5-crypt (`$1$`) displaces DES-crypt on Linux |
| Early 2000s | Linux-PAM becomes universal across distributions |
| 2003 | OpenPAM ships in FreeBSD 5.0 |
| Mid 2000s | SHA-256 and SHA-512 crypt (`$5$`, `$6$`) arrive |
| ~2010 onward | SSSD displaces direct LDAP and Kerberos modules for enterprise identity |
| ~2011 onward | `pam_systemd` and logind reshape the session stack |
| ~2020 onward | yescrypt (`$y$`) becomes the Debian and Ubuntu default; `pam_faillock` replaces `pam_tally2`; FIDO2 modules become common |

Anything written before roughly 2015 will predate both systemd's involvement in the session stack and the shift to SSSD, which together account for most of what a modern stack contains. That is worth remembering when a highly-rated answer from 2011 does not match your system.

---

## 1.4 The Pieces on Disk

Enough history. Here is what is actually installed on your machine.

### The library

```
$ ls -l /lib/x86_64-linux-gnu/libpam*
lrwxrwxrwx 1 root root      15 libpam.so.0 -> libpam.so.0.85.1
-rw-r--r-- 1 root root   64000 libpam.so.0.85.1
lrwxrwxrwx 1 root root      20 libpam_misc.so.0 -> libpam_misc.so.0.82.1
-rw-r--r-- 1 root root   14000 libpam_misc.so.0.82.1
lrwxrwxrwx 1 root root      16 libpamc.so.0 -> libpamc.so.0.82.1
```

Three libraries, and they do different jobs.

`libpam.so` is the framework. Everything in this series that talks about "the framework" or "libpam" means this file. It reads configuration, loads modules, runs the evaluation algorithm, and returns results to applications.

`libpam_misc.so` is a Linux-specific convenience library. Its most used export is `misc_conv()`, a ready-made conversation function that reads from and writes to a terminal. Applications that talk to users through a terminal can use it instead of writing their own. It is not part of the standard, and portable code does not rely on it. Chapter 5 explains what a conversation function is and why one is needed.

`libpamc.so` handles the binary prompt protocol, used by a small number of modules that need to exchange structured data with a client rather than text with a human. You will probably never touch it.

### The modules

```
$ ls /usr/lib/x86_64-linux-gnu/security/     # Debian, Ubuntu
$ ls /usr/lib64/security/                    # RHEL family
```

A stock install has thirty to fifty of these. They are ordinary shared objects, and you can inspect them like any other:

```
$ file /usr/lib64/security/pam_unix.so
$ objdump -T /usr/lib64/security/pam_unix.so | grep pam_sm_
```

That second command is worth running now, before you understand what the output means, because it is the most direct evidence that the model in the README is real:

```
0000000000005a10 g    DF .text  pam_sm_authenticate
0000000000006220 g    DF .text  pam_sm_setcred
0000000000006250 g    DF .text  pam_sm_acct_mgmt
00000000000068c0 g    DF .text  pam_sm_open_session
0000000000006a30 g    DF .text  pam_sm_close_session
0000000000007150 g    DF .text  pam_sm_chauthtok
```

Six functions. That is the entire module interface. `pam_unix.so` implements all six, which is why it can appear in all four stacks. Most modules implement fewer, and running the same command against them tells you immediately which management groups a module is capable of participating in. That is a genuinely useful diagnostic and almost nobody knows about it.

### The configuration

```
/etc/pam.d/           per-service configuration, one file per service
/etc/pam.conf         legacy monolithic form, usually absent or empty
/etc/security/        configuration files belonging to individual modules
```

`/etc/security/` is worth a look now:

```
$ ls /etc/security/
access.conf  faillock.conf  group.conf  limits.conf  limits.d/
namespace.conf  namespace.d/  opasswd  pam_env.conf  pwquality.conf
sepermit.conf  time.conf
```

None of these are read by the framework. Each belongs to a specific module and is read by that module when it runs. `pam_access` reads `access.conf`. `pam_limits` reads `limits.conf` and `limits.d/`. Knowing which file belongs to which module means knowing which stack line to look at when a setting in one of them is not taking effect, which is a surprisingly large fraction of PAM troubleshooting.

### The packages

| | Debian, Ubuntu | RHEL family |
|---|---|---|
| Library | `libpam0g` | `pam-libs`, or `pam` on older releases |
| Modules | `libpam-modules` | `pam` |
| Helper binaries | `libpam-modules-bin` | `pam` |
| Configuration management | `libpam-runtime` | `authselect` |

```
$ dpkg -l | grep libpam
$ rpm -qa | grep -E '^pam|authselect'
```

Note that Debian splits configuration management into its own package. `libpam-runtime` is what provides `pam-auth-update`, and it owns the `common-*` files. That ownership is why hand-editing them is a losing strategy, which Chapter 2 covers.

---

## 1.5 What "PAM-aware" Actually Means

A program participates in PAM if it calls into `libpam`. That is the whole definition, and it has a concrete, checkable consequence: the program links against the library.

### Checking a single binary

```
$ ldd /usr/sbin/sshd | grep -i pam
        libpam.so.0 => /lib/x86_64-linux-gnu/libpam.so.0 (0x00007f...)
```

Present. `sshd` is PAM-aware. Compare:

```
$ ldd /usr/bin/ls | grep -i pam
$
```

Nothing, as expected. `ls` has no business authenticating anyone.

For more detail, look at which symbols the binary actually imports:

```
$ objdump -T /usr/sbin/sshd | grep -i ' pam_'
```

or equivalently:

```
$ nm -D /usr/sbin/sshd | grep ' U pam_'
```

The `U` means undefined, meaning imported from elsewhere. The set of PAM functions a program imports tells you which parts of the framework it uses. A program that imports `pam_authenticate` but not `pam_open_session` is doing credential checking without session management, and that is a meaningful thing to know about it.

### Surveying the whole system

```
$ for f in /usr/bin/* /usr/sbin/* /bin/* /sbin/*; do
      [ -f "$f" ] && ldd "$f" 2>/dev/null | grep -q 'libpam\.so' && echo "$f"
  done
```

On a typical server this returns somewhere between fifteen and forty binaries. Read the list. It is a fair summary of every way into the machine, and it is worth knowing by heart for a system you are responsible for.

Then compare it against the service files:

```
$ ls /etc/pam.d/
```

The two lists will not match, and the mismatches are informative. A service file with no corresponding binary is usually a leftover from a removed package, harmless but untidy. A PAM-aware binary with no service file is the more interesting case, because that program will fall back to `/etc/pam.d/other`, and what happens then depends entirely on what `other` contains. On a Debian system `other` typically includes the `common-*` files, which means a service with no file of its own gets standard local authentication. On RHEL-family systems `other` is traditionally four `pam_deny` lines, which means such a service is denied outright. Two defensible designs with very different consequences. Check yours:

```
$ cat /etc/pam.d/other
```

### Watching it happen at runtime

Link-time inspection tells you a program *can* use PAM. It does not tell you that a given invocation *did*. For that, watch the process open files:

```
$ strace -f -e trace=openat su - someuser 2>&1 | grep -E 'pam|security'
```

You will see the service file being opened, then each module in it being loaded:

```
openat(AT_FDCWD, "/etc/pam.d/su", O_RDONLY|O_CLOEXEC) = 4
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/security/pam_rootok.so", O_RDONLY|O_CLOEXEC) = 5
openat(AT_FDCWD, "/etc/pam.d/common-auth", O_RDONLY|O_CLOEXEC) = 5
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/security/pam_unix.so", O_RDONLY|O_CLOEXEC) = 5
...
```

That output is the model from the README rendered as system calls. The config file is opened, the includes are followed, the modules are `dlopen`ed in the order they appear. Nothing hidden, nothing inferred.

Two things this technique is uniquely good for. First, it settles arguments about which file a service is actually reading, which is occasionally not the one you think, especially where symlinks or `authselect` profiles are involved. Second, it catches the case where a module named in the configuration does not exist on disk: you will see the open fail with `ENOENT`, and that failure is the root cause of a class of confusing behaviour that Chapter 4 explains the consequences of.

You can go one level finer with `ltrace` and watch the framework call into the modules, though on most distributions the symbols are stripped enough to make this less rewarding than it sounds. `strace` on `openat` is the practical tool.



**`sshd` links against PAM, but public key authentication does not run the `auth` stack.** This catches almost everybody once. With `UsePAM yes` in `sshd_config` and a user authenticating by key, the credential check happens entirely inside `sshd` against `authorized_keys`. PAM's `auth` stack is not consulted. The `account` and `session` stacks still run, so account expiry, `pam_access` rules, resource limits, and logind session creation all still apply. The practical consequence is significant: a second factor added to the `auth` stack does nothing at all for key-based logins, and people deploy MFA this way and believe they are covered when they are not. Chapter 10 deals with this properly.

**`sudo` uses PAM, and also does not.** It calls PAM to verify your password. It also maintains its own timestamp files so that it does not ask again for a few minutes, and that caching is entirely sudo's, invisible to PAM. A PAM stack that appears not to be running is often just sudo not asking, because your timestamp is still valid. `sudo -k` clears it, and you should get into the habit of running it before testing anything.

**`cron` authenticates nobody and still uses PAM.** There is no password to check for a scheduled job. But an expired account's jobs should not run, and a job still needs resource limits and an environment. So `cron` uses the `account` and `session` stacks and skips `auth` almost entirely. This is the clearest possible demonstration that PAM is not an authentication system with some extras attached.

**`systemd` has PAM service files you did not create.** `/etc/pam.d/systemd-user` is used when a user session's systemd instance starts. If it is missing or broken, user services fail in ways that look nothing like an authentication problem.

**`passwd` uses PAM only for the `password` stack.** It calls `pam_chauthtok()` and nothing else that matters. This is why password quality rules live where they do and why `pam_rootok` sits at the top of `/etc/pam.d/passwd`: root changing another user's password should not be prompted for that user's old password.

### Programs that do not use PAM

Some deliberately do not. Database servers with their own user tables, application servers with their own credential stores, anything that authenticates against something other than the system's notion of a user. That is fine and often correct. The thing to be aware of is that such programs are outside every policy you configure in PAM. Your lockout policy, your password quality rules, your time restrictions: none of them apply. When you are asked whether the organisation enforces some authentication policy "everywhere," the honest answer requires knowing this list too.

---

## 1.6 Linux-PAM and OpenPAM

If you work only on Linux you can skim this section. If you touch FreeBSD, NetBSD, or macOS, read it, because the two implementations are similar enough to lull you and different enough to hurt.

OpenPAM was written by Dag-Erling Smørgrav, primarily for FreeBSD, appearing in FreeBSD 5.0. NetBSD and macOS use it as well. It implements the same OSF-RFC design and the same four management groups, and a person fluent in one implementation can read the other's configuration without difficulty.

The differences that matter in practice:

**Module search paths differ.** OpenPAM systems typically look in `/usr/lib` and `/usr/local/lib` for modules; Linux-PAM uses a dedicated `security/` subdirectory. A configuration file that names a module by bare filename will resolve differently, or not at all.

**Policy file search order differs.** OpenPAM searches several locations including `/usr/local/etc/pam.d/`, which has no Linux equivalent and exists because of the ports and packages split in the BSD world.

**The module set overlaps far less than the configuration syntax suggests.** `pam_unix` exists on both. Beyond that, a great deal of what you will use on Linux is Linux-specific, because it is bound to Linux-specific kernel and userspace facilities: `pam_systemd`, `pam_selinux`, `pam_cap`, `pam_faillock`, `pam_loginuid`, `pam_namespace`, `pam_keyinit`. There is no BSD equivalent for most of these and there cannot be, because the things they configure do not exist there.

**Some API surface differs.** OpenPAM introduced `pam_get_authtok()` and a set of `openpam_*` extensions; Linux-PAM later grew a compatible `pam_get_authtok()`, so the two have converged somewhat, but a module written against one implementation's extensions will not build against the other without work. This matters if you get as far as Chapter 5.

**Default policies differ substantially.** BSD systems ship a very different `/etc/pam.d/` than any Linux distribution.

The practical rule is short: do not transplant PAM configuration between Linux and BSD. Read the target system's own files and its own manual pages. The concepts transfer completely; the configuration does not transfer at all.

| | Linux-PAM | OpenPAM |
|---|---|---|
| Primary platforms | Linux | FreeBSD, NetBSD, macOS |
| First release | 1996 | 2003 (FreeBSD 5.0) |
| Module location | `/lib/*/security/`, `/usr/lib64/security/` | `/usr/lib/`, `/usr/local/lib/` |
| Policy locations | `/etc/pam.d/`, `/etc/pam.conf` | those plus `/usr/local/etc/pam.d/` |
| Convenience library | `libpam_misc` with `misc_conv()` | `openpam_ttyconv()` |
| Extensions | `pam_get_authtok()`, `pam_syslog()` | `openpam_*` family |
| Systemd, SELinux, capability modules | yes | not applicable |

---

## 1.7 A First Trace: `su`

Time to make this concrete. Here is what happens when you type `su - parsa` on a Linux system, at the level of "which component does what." Details are deliberately omitted; Chapter 10 supplies them.

Here is a representative `/etc/pam.d/su` from a Debian system, trimmed of comments:

```
auth       sufficient  pam_rootok.so
# auth     required    pam_wheel.so
session    required    pam_env.so readenv=1
session    required    pam_env.so readenv=1 envfile=/etc/default/locale
session    optional    pam_mail.so nopen
session    required    pam_limits.so
@include common-auth
@include common-account
@include common-session
```

And here is the sequence:

**1. The shell execs `su`.** `su` is setuid root, so the process starts with effective UID 0 and real UID still yours. It needs that privilege to read `/etc/shadow` and to change identity later.

**2. `su` calls `pam_start()`.**

```c
retval = pam_start("su", target_user, &conv, &pamh);
```

Four arguments. The service name, which is what selects `/etc/pam.d/su`. The target username. A pointer to the conversation structure, which is how modules will later ask you questions. And a pointer that receives the handle carrying state for the rest of the transaction. Note that the service name is a string `su` chose. It is conventionally the program name but nothing enforces that.

**3. `su` calls `pam_authenticate()`.** The framework reads the file, loads the `auth` modules in order, and runs them.

`pam_rootok.so` runs first. It succeeds if the real UID is 0 and fails otherwise. It is marked `sufficient`, so if you are already root, the stack ends here, successfully, with no password prompt. That single line is why root can `su` to anyone without a password, a behaviour most people know about without knowing where it comes from.

If you are not root, `pam_rootok` fails, `sufficient` means the failure is ignored, and evaluation continues.

`pam_wheel.so` is commented out on Debian by default. Uncommented, it restricts `su` to members of a specific group. This is a policy that used to require a patched `su` and is now one line in a text file, which is the entire point of the exercise.

Then `@include common-auth` pulls in the shared authentication lines, which on Debian is the three-line `pam_unix` jump idiom shown in the README. `pam_unix` needs a password, and here is the part worth slowing down for: it does not read the terminal. It calls the conversation function that `su` passed in back at step 2, with a message of type `PAM_PROMPT_ECHO_OFF`. `su` handles the terminal interaction and returns the string. The module never touches a file descriptor.

This is the mechanism that makes the same module work under `sshd`, under a graphical greeter, and under a program driving it from a script. Chapter 5 is largely about it.

`pam_unix` hashes what you typed with the salt from the stored value, compares, returns `PAM_SUCCESS` or `PAM_AUTH_ERR`. The framework combines results across the stack and hands one value back to `su`.

**4. `su` calls `pam_acct_mgmt()`.** Now the `account` stack. Is the account expired? Is the password past its maximum age? Is there an `/etc/nologin`? Note the ordering: this happens *after* authentication, and it can still refuse. If you have ever seen a correct password produce a refusal, this is usually where it came from.

A distinct return value, `PAM_NEW_AUTHTOK_REQD`, means the account is fine but the password must be changed before proceeding. `su` handles that by calling `pam_chauthtok()`, running the `password` stack, and only then continuing. Chapter 7 covers that flow.

**5. `su` calls `pam_setcred(pamh, PAM_ESTABLISH_CRED)`.** This traverses the `auth` stack again, but calls a different function in each module: `pam_sm_setcred()` rather than `pam_sm_authenticate()`. For `pam_unix` this does almost nothing. For a Kerberos module it obtains a ticket-granting ticket. This second pass is a common source of "why did that module run twice" confusion and is explained in Chapter 3.

**6. `su` calls `pam_open_session()`.** The `session` stack. `pam_env` sets environment variables. `pam_limits` applies `limits.conf`. `pam_mail` checks for mail. On a system with `pam_systemd` in the stack, logind creates a session object, allocates a scope in the cgroup hierarchy, and sets `XDG_RUNTIME_DIR`.

**7. `su` changes identity.** `initgroups()`, `setgid()`, `setuid()`, in that order. Order matters enormously: dropping UID before GID would leave the process unable to change its GID, since that requires privilege it just gave away. This is standard privilege-dropping discipline and has nothing to do with PAM, but it is where PAM's work stops mattering and the kernel's credential model takes over. The Permissions Deep Dive section covers this ground.

**8. `su` execs the shell.** You have a prompt.

**9. When the shell exits**, `su` calls `pam_close_session()` and then `pam_end()`. Session modules undo their work. The logind session goes away.

Nine steps. Four PAM stacks, one of them traversed twice for different reasons. One text file that determined nearly all of it.

Now run it yourself with the logs open:

```
# journalctl -f -t su &
$ su - someuser
```

You will see `pam_unix(su:session): session opened for user someuser` and the corresponding close on exit. Read the service and stack in those parentheses. That annotation is the single most useful thing in PAM's log output, and Chapter 11 leans on it heavily.

---

## 1.8 What PAM Does Not Do

Boundaries, because misplaced expectations cause more wasted time than any technical difficulty.

**PAM does not do authorization after the session starts.** Once you have a shell, PAM is finished. Whether you can read a file is a matter of file permissions, capabilities, and MAC policy. Whether you can run a command as root is `sudoers`. PAM decides whether a session begins and what it looks like at birth. It has no ongoing role.

**PAM is not NSS.** `/etc/nsswitch.conf` and the name service switch answer "who is this user, what is their UID, what groups are they in." PAM answers "may they authenticate and proceed." Different subsystems, different configuration, different failure modes. A user who does not resolve at all is an NSS problem, and no amount of editing stacks will help. `getent passwd <user>` distinguishes the two in one second and belongs at the start of every troubleshooting session. Chapter 10 devotes real space to this because it is the single most common misdiagnosis in the area.

**PAM does not define the shadow file format or the aging rules.** Those belong to shadow-utils and to libcrypt. `pam_unix` reads and honours them. It did not invent them, and `chage` modifies them without going through PAM at all.

**PAM is not transport security.** It has no view on whether the connection carrying the password is encrypted. That is entirely the application's problem.

**PAM is not the only authentication path into your system.** Section 1.5 lists programs that bypass it. So do SSH keys for the `auth` stack. So does anything using its own credential store.

---

## 1.9 Why Shared Objects?

The RFC could have chosen differently, and understanding what it rejected explains several of PAM's rough edges.

**Option one: put every mechanism in libc.** Have `getpwnam()` and a new `checkpassword()` handle all schemes internally, selected by a configuration file. No new architecture, no plugin loading. This fails immediately on the same problem as before: adding a mechanism means shipping a new libc, which is the single most disruptive component to upgrade on a Unix system. It also means every mechanism ever supported is linked into every process on the machine, forever.

**Option two: a separate authentication daemon.** Applications talk to it over a socket. The daemon holds all the mechanism code and all the privilege. This has a real advantage that PAM gives up: isolation. A crash in the LDAP code takes down the daemon, not `sshd`. A memory corruption bug in a mechanism does not automatically become code execution inside a root process.

It also has serious problems, and in 1995 they were decisive. IPC portability across the Unix landscape of that era was poor. The daemon becomes a single point of failure for every login on the machine, including the one you need in order to fix the daemon. There is a bootstrap question that has no clean answer: what authenticates the console login that starts before the daemon does. And the trust problem does not disappear, it relocates, because the application must now trust an answer that arrived over a socket, and something must authenticate the socket.

**Option three: shared objects loaded into the caller.** The application keeps its own privilege and its own process. Mechanism code is loaded on demand from a directory the administrator controls. No IPC, no daemon lifecycle, no bootstrap problem, and each application's failures are its own.

This is what PAM chose, and NSS made the same choice at about the same time for the same reasons. The two subsystems are architecturally parallel: a switch file, a set of shared objects with a fixed entry point convention, loaded into the calling process.

Here is where it gets interesting. Modern systems have quietly reintroduced option two, layered on top of option three. `pam_sss.so` is a very thin module whose real job is to talk to the SSSD daemon over a socket. The mechanism code, the LDAP client, the Kerberos logic, the credential cache, lives in a separate process with its own lifecycle. The module is a shim. The same pattern appears with `pam_systemd` and logind, and with the newer userdb work.

So the architecture on a current enterprise Linux box is: application, framework, thin module, socket, daemon. Both designs, stacked. This is not a criticism of either. It is worth knowing because it changes where you look when things break. When `pam_sss` is in the stack and logins hang, the interesting state is in `sssd`'s logs and cache, not in `/etc/pam.d/`, and the PAM configuration may be entirely correct while nothing works. Chapter 10 covers this in detail.

---

## 1.10 The Cost: PAM as Attack Surface

The design decision in 1.9 has a security consequence that deserves stating plainly, early, and once, because it changes how you should treat several directories.

**A PAM module is arbitrary code running in a root process, loaded from a path named in a text file.**

Consider what that means for an attacker who has achieved root once and wants to keep it. A modified `pam_unix.so` that verifies passwords correctly and also appends them to a file is a credential logger with root privilege that triggers on every login on the system. It survives password changes. It captures credentials for accounts that never touch that host again. And it hides well: there are no setuid bits to notice, no new listening ports, no unusual processes, no cron entries. It is a shared object in a directory full of shared objects, and it works perfectly, which means nobody investigates.

This is not theoretical. Trojaned PAM modules are a documented, recurring persistence technique, and they have been found in the wild for many years.

The configuration side is worse, in the sense of being easier. Consider a single added line:

```
auth  sufficient  pam_permit.so
```

Placed at the top of a stack, that grants access to anyone, with any password, or none. No binaries modified. Nothing for a file integrity checker that only watches executables to notice. A stock module doing exactly what it is documented to do. One line in a text file, and the machine is open.

The conclusions follow directly:

**Write access to `/etc/pam.d/` is equivalent to root.** Not "a step toward root." Equivalent. Treat any process or account with write access there accordingly.

**Write access to the module directory is equivalent to root on every future login.** Same reasoning, worse consequences, since it persists across reinstalls of the configuration.

**These paths belong in your integrity monitoring**, and if they are not there today, that is a finding worth raising. At minimum:

```
# rpm -V pam                          # RHEL family: verify against package
# rpm -Va | grep -E 'security|pam'
# debsums -c libpam-modules libpam0g   # Debian family
# find /etc/pam.d/ -type f -printf '%T+ %p\n' | sort
# ls -la /usr/lib64/security/ | head -40
```

Package verification is the fastest first pass. A module whose checksum no longer matches its package is either a legitimately patched vendor build or a serious problem, and distinguishing the two takes about a minute.

For continuous monitoring, audit rules covering both paths:

```
-w /etc/pam.d/            -p wa -k pam_config
-w /etc/security/         -p wa -k pam_config
-w /usr/lib64/security/   -p wa -k pam_modules
```

These belong in your auditd configuration alongside the rules for `/etc/sudoers` and `/etc/ssh/sshd_config`. The Linux Logging section of this repository covers the mechanics; Chapter 11 covers what to look for in the output.

One more consideration for later. `pam_exec.so` runs an arbitrary program, as root, in the middle of an authentication decision. It is a legitimate module with legitimate uses, and it is also a fully general backdoor that looks like ordinary configuration. Any occurrence of it in a stack you did not write yourself deserves a careful look at what it runs and who can write to that path. Chapter 9 covers the module; Chapter 11 covers reviewing it.

---

## 1.11 Verification

Do these on a test machine. Each takes under a minute and confirms a specific claim from this chapter.

**1. Find the PAM-aware programs on your system.**

```
$ for f in /usr/bin/* /usr/sbin/* /bin/* /sbin/*; do
      [ -f "$f" ] && ldd "$f" 2>/dev/null | grep -q 'libpam\.so' && echo "$f"
  done
```

Are there any you did not expect? Does each have a file in `/etc/pam.d/`?

**2. Identify your hash algorithm.**

```
# awk -F: '$2 ~ /^\$/ {split($2,a,"$"); print $1, "$" a[2] "$"}' /etc/shadow
```

Match the prefix against the table in 1.2.1. Is it what your organisation's policy says it should be?

**3. Determine which stacks a module can participate in.**

```
$ objdump -T /usr/lib64/security/pam_rootok.so | grep pam_sm_
$ objdump -T /usr/lib64/security/pam_unix.so   | grep pam_sm_
```

`pam_rootok` should export one or two functions. `pam_unix` should export all six. Predict before you run it.

**4. Read your fallback policy.**

```
$ cat /etc/pam.d/other
```

Does an unknown service get denied, or does it get standard authentication? Is that the behaviour you want?

**5. Confirm the setgid helper exists and understand why.**

```
$ ls -l /usr/sbin/unix_chkpwd
$ ls -l /etc/shadow
```

Given the ownership and mode of `/etc/shadow`, explain why the helper is setgid rather than setuid. Compare Debian's `0640 root:shadow` with the RHEL family's `0000 root:root` and work out why both are safe.

**6. Watch a login end to end.**

```
# journalctl -f -t su -t sshd -t sudo
```

Then log in from another terminal, `su` to another user, and run something under `sudo`. Read every line that appears. You will not understand all of it yet. Note the ones you do not, and check back after Chapter 4.

**7. Prove that key-based SSH skips the `auth` stack.**

Add a `pam_echo` or `pam_exec` line to `/etc/pam.d/sshd`'s `auth` stack that writes something visible, then log in once with a password and once with a key.

**8. Watch the framework load its modules.**

```
$ strace -f -e trace=openat su - someuser 2>&1 | grep -E 'pam\.d|security'
```

Compare the sequence of opens against the contents of `/etc/pam.d/su`. Do the includes appear where you expect? Is any module opened that you did not see named in the file?

**9. Verify the integrity of your PAM installation.**

```
# rpm -V pam            # RHEL family
# debsums -c libpam-modules libpam0g   # Debian family
```

Silence means everything matches its package. Anything else deserves an explanation before you continue reading.

**10. Audit `/etc/pam.d/` for the obvious.**

```
# grep -rn 'pam_permit\|pam_exec\|nullok' /etc/pam.d/
```

Every hit should have a reason you can articulate. On a stock system there will be a few legitimate ones, and knowing which are normal on your distribution is the point of the exercise. Come back to this after Chapter 11 and see whether your answers have changed.

> ⚠ Second root shell open before you do this, and a snapshot before that. The lab rules in the README apply from here on and will not be repeated in every chapter.

---

## Where This Goes Next

You now have the shape of the system: an application, a framework, a configuration file, and a set of shared objects. Chapter 2 takes the configuration file apart. Every field, every syntactic form, the precedence rules between `/etc/pam.d/` and `/etc/pam.conf`, the aggregation idioms each distribution family uses, and the generation tools that will quietly overwrite your work if you fight them.

One thing to carry forward. The trace in 1.7 skipped over the most important mechanism in the whole system: how the framework decides what a stack's result is, given several modules each returning their own value. That is Chapter 4, and it is the chapter everything else depends on. Chapters 2 and 3 exist to give you the vocabulary for it.

A second thing, less obvious. Almost everything in this chapter was history and orientation, and none of it required touching a running system. That changes immediately. From Chapter 2 onward the material is about files that decide whether anyone can log in, and the lab discipline in the README stops being advice and starts being the difference between an evening and a rebuild. If you have not set up a snapshot-capable test machine yet, do that before continuing. You will not get value out of Chapter 4 by reading it, only by evaluating stacks on a system you are willing to break.

---

## Further Reading for This Chapter

- OSF-RFC 86.0, "Unified Login with Pluggable Authentication Modules," Samar and Schemers, 1995
- `man 8 pam` for the framework overview
- `man 3 pam_start`, `man 3 pam_authenticate`, `man 3 pam_end` for the calls in the `su` trace
- `man 3 crypt` and `man 5 crypt` for the modular crypt format
- `man 5 shadow` and `man 5 passwd` for the file formats
- `man 8 unix_chkpwd` for the setgid helper
- Morgan and Kukuk, *The Linux-PAM System Administrators' Guide*, shipped with the source
