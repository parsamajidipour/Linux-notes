# 05 — Policy and Plugin Architecture

Chapter 03 kept insisting on a phrase: *"the front-end knows nothing about
`sudoers`."* Chapter 04 then spent its entire length inside `sudoers` — the
grammar, the matching, the over-grants. This chapter reconciles the two. It
dissects the boundary between them: the **plugin API**, a small C contract of
function pointers through which the policy-agnostic `sudo` front-end talks to a
pluggable policy engine, of which `sudoers` is merely the default implementation.

Understanding this boundary changes how you read every earlier chapter. The
"policy decision" of Chapter 03 Stage 4 is a function call across an ABI. The
`command_info` structure mentioned in passing is the *return value* of that call
— a formal contract describing exactly how the front-end must run the command.
And the reason `sudo` can be backed by LDAP, by a database, by a Python script,
or by a corporate approval workflow is that all of them are just different code
sitting behind the same handful of function pointers.

## 1. Why a plugin architecture exists

Before `sudo` 1.8 (2011), the policy logic and the `sudo` executable were one
program: `sudoers` parsing was compiled directly into the binary. That worked but
fused two very different concerns — *the mechanism of safely elevating and
executing a command* and *the policy of deciding whether to* — into a single
codebase. Any site that wanted a different policy source had to patch `sudo`
itself.

The 1.8 rewrite split them along a stable interface. The front-end retained the
security-critical, hard-to-get-right mechanism: parsing its own arguments,
managing the pty, performing the credential transition, relaying signals,
propagating exit status. The policy — "may this user run this command as this
target?" — moved behind a plugin API. `sudoers` became `sudoers.so`, the first
and default *policy plugin*, but no longer a privileged position in the code.

The payoff is separation of concerns with a security dividend: the mechanism is
written once, audited heavily, and shared by every policy backend; a new policy
source is a new plugin, not a fork of `sudo`. The cost — and it is a real one,
taken up in §13 — is that a plugin is arbitrary code the front-end loads and runs
as root.

## 2. `sudo.conf` — declaring the plugins

The front-end learns which plugins to load from `/etc/sudo.conf`. Each `Plugin`
line names a **symbol** to load and the **shared object** to load it from:

```console
$ grep -v -e '^#' -e '^$' /etc/sudo.conf
Plugin sudoers_policy sudoers.so
Plugin sudoers_io sudoers.so
Plugin sudoers_audit sudoers.so
```

The syntax is `Plugin <symbol_name> <path.so> [options...]`. The first token is
the name of a C symbol exported by the object; the second is the object to
`dlopen()`. The default configuration loads three symbols, all from the single
`sudoers.so`, because the `sudoers` implementation happens to provide a policy
role, an I/O role, and an audit role in one object.

Relative `.so` paths are resolved under a compiled-in plugin directory (commonly
`/usr/libexec/sudo/` or `/usr/lib/sudo/`). Options after the path are passed to
the plugin as its `plugin_options[]` — this is how, for example, the Python
plugin is told which Python module and class to load (§11).

`sudo -V` as root lists what actually loaded, with each plugin's version:

```console
# sudo -V | sed -n '/Plugin/,+8p'
Sudoers policy plugin version 1.9.15p5
Sudoers file grammar version 50
Sudoers I/O plugin version 1.9.15p5
Sudoers audit plugin version 1.9.15p5
```

## 3. The four plugin roles

The API defines four kinds of plugin, distinguished by a `type` field in each
plugin's structure. Each answers a different question in the lifecycle of
Chapter 03:

- **Policy plugin** (`SUDO_POLICY_PLUGIN`) — *may this run, and if so, how?* It
  makes the authorization decision and produces the `command_info` execution
  contract. Exactly **one** policy plugin is active. `sudoers` is the default.
- **I/O logging plugin** (`SUDO_IO_PLUGIN`) — *record (or filter) the session's
  input and output.* Zero or more may be loaded. `sudoers` provides one; it is
  what `sudoreplay` later replays (Chapter 09).
- **Audit plugin** (`SUDO_AUDIT_PLUGIN`, added in 1.9) — *receive a structured
  event for every accept, reject, and error.* Zero or more. Useful for shipping
  decisions to a SIEM independent of the policy backend.
- **Approval plugin** (`SUDO_APPROVAL_PLUGIN`, added in 1.9) — *after policy
  approves, independently veto or allow.* Zero or more, each consulted in turn;
  any one can reject. This is where "second-factor," "business-hours-only," or
  "requires a change ticket" gating belongs, cleanly separated from the policy
  that decides base eligibility.

(There is also a fifth, narrower kind — the **group provider plugin**,
`sudoers_group_plugin` — which lets `sudoers` resolve `%:`-style non-Unix groups.
It plugs into `sudoers`, not the front-end, so it is a sub-plugin of the policy
layer.)

The division is meaningful: **policy decides eligibility, approval adds
orthogonal gates, I/O observes, audit records.** A site can swap the policy
plugin without touching auditing, or add an approval plugin without modifying
policy at all.

## 4. How a plugin talks to the user: the conversation callback

Before the structures, one shared mechanism. A plugin frequently needs to
interact with the user — prompt for a password, print an error, ask a question.
It must not do this by calling `printf` or reading `stdin` directly, because the
front-end owns the terminal (and may be mediating it through a pty). Instead the
front-end passes each plugin two function pointers at `open()` time:

- a **conversation function** (`sudo_conv_t`) — for prompts and replies, including
  *no-echo* prompts for passwords;
- a **printf-like function** (`sudo_printf_t`) — for informational and error
  output.

When `sudoers` prompts `[sudo] password for parsa:`, it is calling the
conversation function the front-end handed it, not writing to the tty itself. The
front-end thus retains control of the terminal and can enforce policy like
`use_pty` uniformly. This indirection is small but it is the reason password
prompts behave correctly under I/O logging, over SSH, and inside a pty.

## 5. The policy plugin contract

A policy plugin is a C structure of function pointers exported under the symbol
named in `sudo.conf`. Reduced to its essentials:

```c
struct policy_plugin {
    unsigned int type;        /* SUDO_POLICY_PLUGIN */
    unsigned int version;     /* SUDO_API_VERSION    */

    int  (*open)(unsigned int version, sudo_conv_t conversation,
                 sudo_printf_t plugin_printf,
                 char * const settings[],     /* front-end settings   */
                 char * const user_info[],    /* who is invoking      */
                 char * const user_env[],     /* the untrusted env    */
                 char * const plugin_options[],
                 const char **errstr);
    void (*close)(int exit_status, int error);
    int  (*show_version)(int verbose);

    int  (*check_policy)(int argc, char * const argv[],
                         char *env_add[],           /* IN: cmdline env */
                         char **command_info[],     /* OUT: how to run */
                         char **argv_out[],         /* OUT: argv       */
                         char **user_env_out[],     /* OUT: env        */
                         const char **errstr);

    int  (*list)(int argc, char * const argv[], int verbose,
                 const char *list_user, const char **errstr);
    int  (*validate)(const char **errstr);
    void (*invalidate)(int remove);
    int  (*init_session)(struct passwd *pwd,
                         char **user_env_out[], const char **errstr);
    /* ... register_hooks, deregister_hooks, debug_files ... */
};
```

Each function maps onto something already seen:

- **`open`** — Chapter 03 Stage 3. The front-end calls it once, handing over the
  invoking user's info, the untrusted environment, and the plugin's own options.
  `sudoers.so` uses this call to read and parse `/etc/sudoers`. A parse error is
  reported here and aborts the invocation.
- **`check_policy`** — Chapter 03 Stage 4. The authorization decision. It takes
  the command (`argv`) and returns, through output pointers, the verdict *and* —
  on success — the full execution contract. This is the single most important
  call in the API.
- **`list`** — backs `sudo -l` / `sudo -l -U user` (Chapter 04 §12). Same policy
  data, rendered for a human instead of executed.
- **`validate`** / **`invalidate`** — back `sudo -v` (refresh the timestamp
  ticket) and `sudo -k` / `-K` (drop it). These are the timestamp operations from
  Chapter 03 Stage 5, exposed as explicit entry points.
- **`init_session`** — a hook to set up the session (e.g. PAM session management,
  `pam_open_session`) just before the command runs.

The front-end never inspects `sudoers` syntax; it calls these functions and acts
on their return values. That is the entire meaning of "the front-end knows
nothing about `sudoers`."

## 6. The inputs — `settings`, `user_info`, `user_env`

`open()` receives three `NULL`-terminated arrays of `"key=value"` strings. They
are the plugin's entire picture of the world, and they are worth knowing because
they are exactly the data a policy decision is allowed to depend on.

**`settings[]`** — the front-end's parsed options and flags: things like
`runas_user=`, `runas_group=`, `prompt=`, `set_home=`, `implied_shell=`,
`login_class=`, `preserve_environment=`, `debug_flags=`, `progname=`, the
network addresses of the host, and so on. These are `sudo`'s own command-line
choices, normalized.

**`user_info[]`** — who is invoking, straight from the front-end: `user=`,
`uid=`, `euid=`, `gid=`, `egid=`, `groups=`, `pid=`, `ppid=`, `cwd=`, `tty=`,
`host=`, `lines=`, `cols=`. Note `uid=` here is the **real** UID preserved by the
setuid bit (Chapter 01) — this is *how* the plugin knows which user to look up in
`sudoers`.

**`user_env[]`** — the complete, untrusted environment inherited from the caller
(Chapter 03 Stage 0). The policy plugin sees it because policy may *depend* on it
(and must decide what to keep), but everything from Chapter 02's trust-boundary
discussion applies: this array is hostile input.

A policy decision is a pure-ish function of these three arrays plus the command.
That framing is useful for reasoning about `sudoers`: if a behavior is not
derivable from `settings`, `user_info`, `user_env`, and the command, `sudoers`
cannot be keying on it.

## 7. The output — `command_info`, the enforcement contract

When `check_policy` approves, it fills `command_info[]` with a `NULL`-terminated
array of `"key=value"` strings that tell the front-end *exactly* how to run the
command. This is the formal version of the structure named in Chapter 03 Stage 6.
A representative (abbreviated) set:

```text
command=/usr/bin/id
runas_uid=33
runas_gid=33
runas_groups=33
runas_euid=33
runas_egid=33
cwd=/home/parsa
umask=022
use_pty=true
set_utmp=true
iolog_path=/var/log/sudo-io/00/00/01
noexec=false
closefrom=3
sudoedit=false
```

Every downstream stage of Chapter 03 is *driven* by these keys:

- `runas_uid` / `runas_gid` / `runas_groups` → the credential transition of
  Stage 8 (`setresuid`, `setresgid`, `setgroups`). The policy plugin *decides*
  the target IDs; the front-end *applies* them.
- `use_pty`, `iolog_path` → whether Stage 9 uses the pty+monitor model and where
  I/O logs go.
- `cwd`, `umask`, `noexec`, `closefrom` → the execution context.
- `command`, and the separate `argv_out[]` → what actually gets `execve`'d.

`argv_out[]` and `user_env_out[]` are returned alongside `command_info` and are
the final argv and environment — the environment being the *sanitized* result of
Chapter 07, computed inside the policy plugin. So the environment the command
receives is manufactured by the policy plugin and returned across this boundary;
the front-end installs it verbatim.

This is the precise sense of "policy decides, front-end enforces." The trust
boundary between untrusted input and privileged execution is *also* the plugin
API boundary: hostile data goes *in* through `user_env`/`argv`, a vetted plan
comes *out* through `command_info`/`argv_out`/`user_env_out`, and the front-end
executes only the plan.

## 8. The I/O logging plugin

An I/O plugin observes — and can filter — the data flowing between the terminal
and the command. Its structure adds per-stream log callbacks:

```c
struct io_plugin {
    unsigned int type;        /* SUDO_IO_PLUGIN */
    unsigned int version;
    int  (*open)(...);
    void (*close)(int exit_status, int error);
    int  (*show_version)(int verbose);
    int  (*log_ttyin) (const char *buf, unsigned int len, const char **errstr);
    int  (*log_ttyout)(const char *buf, unsigned int len, const char **errstr);
    int  (*log_stdin) (const char *buf, unsigned int len, const char **errstr);
    int  (*log_stdout)(const char *buf, unsigned int len, const char **errstr);
    int  (*log_stderr)(const char *buf, unsigned int len, const char **errstr);
    int  (*change_winsize)(unsigned int lines, unsigned int cols,
                           const char **errstr);
    int  (*log_suspend)(int signo, const char **errstr);
    /* ... */
};
```

The front-end, running the command under a pty (Chapter 03 Stage 9), feeds every
chunk of terminal input to `log_ttyin` and every chunk of output to `log_ttyout`
before it reaches its destination. `sudoers`'s I/O plugin writes these to the
timestamped `iolog_path` from `command_info`, producing the record `sudoreplay`
reconstructs.

Two consequences worth noting:

- The `log_*` callbacks' **return value can control the stream** — a plugin can
  signal that data should be withheld or that the command should be terminated.
  So an I/O plugin is not purely passive; it can *enforce*, e.g. killing a session
  that types a forbidden string. This is powerful and rarely used, but it is in
  the contract.
- I/O logging is why a pty exists at all for many invocations. Observing a
  command's terminal I/O requires sitting between the real terminal and the
  command, which is exactly what the pty+monitor model provides.

## 9. The audit plugin

Added in 1.9, the audit plugin receives a structured event for the *outcome* of
each invocation, regardless of which policy plugin produced it:

```c
struct audit_plugin {
    unsigned int type;        /* SUDO_AUDIT_PLUGIN */
    unsigned int version;
    int  (*open)(...);
    void (*close)(int status_type, int status);
    int  (*accept)(const char *plugin_name, unsigned int plugin_type,
                   char * const command_info[], char * const run_argv[],
                   char * const run_envp[], const char **errstr);
    int  (*reject)(const char *plugin_name, unsigned int plugin_type,
                   const char *audit_msg, char * const command_info[],
                   const char **errstr);
    int  (*error)(const char *plugin_name, unsigned int plugin_type,
                  const char *audit_msg, char * const command_info[],
                  const char **errstr);
    int  (*show_version)(int verbose);
    /* ... */
};
```

Exactly one of `accept`, `reject`, or `error` fires per invocation, carrying who
made the decision (`plugin_name`), the command, and — for accepts — the full
`command_info`. Because it is decoupled from the policy plugin, an audit plugin
gives you a single, uniform event stream even if you later swap `sudoers` for a
different policy backend. Chapter 09 uses this seam.

## 10. The approval plugin

Also from 1.9, the approval plugin is the most conceptually interesting addition,
because it cleanly separates *eligibility* from *authorization to proceed right
now*:

```c
struct approval_plugin {
    unsigned int type;        /* SUDO_APPROVAL_PLUGIN */
    unsigned int version;
    int  (*open)(...);
    void (*close)(void);
    int  (*check)(char * const command_info[], char * const run_argv[],
                  char * const run_envp[], const char **errstr);
    int  (*show_version)(int verbose);
    /* ... */
};
```

The front-end calls each loaded approval plugin's `check()` **after** the policy
plugin has already approved and produced `command_info`, but **before** the
command runs. Any approval plugin returning failure vetoes the command. This lets
you layer orthogonal controls without touching `sudoers`:

- a plugin that permits privileged commands only during a maintenance window;
- a plugin that requires a matching approved change-ticket number;
- a plugin that demands a hardware-token tap as a second factor.

Each is independent, composable, and swappable. Policy answers "is `parsa`
eligible to restart nginx as root?"; approval answers "…and is it OK to do that
at 3 a.m. without a ticket?" Keeping these separate is good design and is only
possible because the API models them as distinct roles.

## 11. Writing plugins in a higher-level language

`sudo` 1.9 ships a bridge plugin, `python_plugin.so`, that lets you implement any
of the four roles in Python instead of C. You declare it in `sudo.conf` and point
it at a module and class:

```console
# /etc/sudo.conf
Plugin python_policy python_plugin.so \
    ModulePath=/etc/sudo/plugins/my_policy.py \
    ClassName=MyPolicyPlugin
```

The Python class implements the same contract as the C struct — `check_policy`,
`list`, etc. — as methods:

```python
# /etc/sudo/plugins/my_policy.py  (illustrative skeleton)
import sudo

class MyPolicyPlugin(sudo.Plugin):
    def check_policy(self, argv, env_add):
        command = argv[0]
        # ... decide ...
        if not self._allowed(command):
            return (sudo.RC.REJECT, (), ())
        command_info = ("command=" + command, "runas_uid=0", "runas_gid=0")
        return (sudo.RC.ACCEPT, command_info, argv)
```

This does not change any of the semantics of the preceding sections — the Python
object is still called across the same boundary, still returns a `command_info`
contract, still runs inside the front-end. It only lowers the barrier to writing
a custom policy, audit, or approval backend from "write and compile a C shared
object" to "write a Python class." The security caveat of §13 applies with full
force: that Python runs as root.

## 12. Versioning and the ABI

Each plugin structure carries a `version` field encoding a major and minor number
(`SUDO_API_VERSION`). The front-end checks compatibility at load time: a
**major** version mismatch means the ABI is incompatible and the plugin is
refused; a **minor** difference is tolerated (newer fields are simply absent on
older plugins). This is ordinary shared-library discipline, but it matters for
`sudo` specifically because a plugin is loaded into a root process — silently
running an ABI-mismatched plugin could misinterpret pointers, so the front-end
fails closed instead.

## 13. The security weight of the architecture

Every convenience in this chapter carries the same underlying fact: **a plugin is
code that the setuid-root front-end loads and executes with `euid = 0`.** The
plugin API is a mechanism for running third-party (or your own) code as root, by
design. Three consequences follow.

**`sudo.conf` and the plugin objects are as trusted as `sudo` itself.** If an
attacker can modify `/etc/sudo.conf` to point at a malicious `.so`, or can
replace a legitimate plugin object, they get code execution as root the next time
anyone runs `sudo`. These files must be root-owned and not writable by anyone
else; `sudo` checks the ownership and permissions of `sudo.conf` and refuses
unsafe configurations, but the plugin objects themselves live under the same
must-be-trusted requirement as any root-run binary.

**A buggy policy plugin is a privilege-escalation bug even if it never intends
harm.** Because it produces `command_info` — including `runas_uid` and the
sanitized environment — a plugin that mis-sanitizes the environment or miscomputes
the runas IDs reintroduces exactly the Chapter 02 wrapper vulnerabilities, now at
the policy layer. The heavy auditing that `sudoers.so` receives is the reason to
prefer it over a hastily written custom plugin.

**The Python bridge widens the attack surface it exposes.** A Python policy
plugin runs a Python interpreter as root, reading a `.py` file from disk. That
file, its module search path, and any imports must be as tightly controlled as a
root-owned C binary — a writable `my_policy.py` is a root shell.

The plugin architecture is therefore a study in the trade this whole series keeps
circling: flexibility bought with trust. It makes `sudo` a general, replaceable
policy engine — and it does so by handing plugins the very privilege `sudo`
exists to guard.

## 14. What this chapter established

- Since 1.8, `sudo` is a **policy-agnostic front-end** plus **plugins**; `sudoers`
  is the default *policy plugin* (`sudoers.so`), not a privileged position in the
  code. The split isolates the hard, security-critical mechanism from the
  swappable policy.
- Plugins are declared in **`/etc/sudo.conf`** as `Plugin <symbol> <object>
  [options]`; there are four roles — **policy** (exactly one), **I/O logging**,
  **audit** (1.9), and **approval** (1.9) — plus the group-provider sub-plugin.
- Plugins never touch the terminal directly; they use the front-end's
  **conversation** and **printf** callbacks, which is why prompts behave correctly
  under ptys, SSH, and I/O logging.
- The policy plugin's **`check_policy`** is the authorization call: it takes the
  command and untrusted environment and returns the verdict plus **`command_info`**
  — the formal contract (`runas_uid`, `use_pty`, `iolog_path`, sanitized env, …)
  that drives every downstream stage of Chapter 03. **Policy decides, front-end
  enforces**, and that boundary *is* the trust boundary.
- **I/O plugins** observe and can filter session streams; **audit plugins**
  receive one uniform accept/reject/error event per invocation; **approval
  plugins** add orthogonal, composable vetoes after policy approval. All four can
  be written in **Python** via `python_plugin.so`.
- The architecture's power is bought with trust: **plugins run as root**, so
  `sudo.conf` and every plugin object must be root-owned and unwritable by others,
  a buggy plugin is a privilege-escalation bug, and the Python bridge runs an
  interpreter as root.

The next chapter descends into the one stage this chapter kept deferring to a
callback — authentication. *Authentication with PAM* opens the conversation
function's other end: how `sudoers` proves the invoker's identity by driving the
PAM stack, what each module in `/etc/pam.d/sudo` actually decides, and how the
whole exchange returns a yes/no that gates the command.
