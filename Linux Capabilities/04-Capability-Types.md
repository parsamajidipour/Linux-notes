# Capability Types

Linux does not attach a single boolean value such as `privileged=true` to a process.

Instead, every thread carries several **capability sets**. Each set answers a different question:

- Which capabilities may this thread use now?
- Which capabilities may it make effective later?
- Which capabilities may survive execution of another program?
- Which capabilities can no longer be regained?
- Which capabilities should pass through an ordinary `execve()`?

Understanding these sets is the key to understanding Linux Capabilities as a whole.

A capability name such as `CAP_NET_ADMIN` does not fully describe the privilege state of a process. The important question is:

> In which set does that capability exist?

The same capability may be present in the permitted set, absent from the effective set, blocked by the bounding set, and still present in the inheritable set. These combinations produce very different behavior.

---

## 1. The Five Per-Thread Capability Sets

Modern Linux exposes five capability sets for a thread:

| Kernel / `/proc` name | Common name | Main purpose |
|---|---|---|
| `CapPrm` | Permitted | Maximum capabilities the thread may make effective |
| `CapEff` | Effective | Capabilities currently used by kernel permission checks |
| `CapInh` | Inheritable | Capabilities eligible for inheritance through specially marked executables |
| `CapBnd` | Bounding | Ceiling that limits capabilities gained through file privilege |
| `CapAmb` | Ambient | Capabilities preserved across ordinary, non-privileged `execve()` calls |

These values are visible in:

```bash
grep '^Cap' /proc/$$/status
```

Example:

```text
CapInh: 0000000000000000
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 000001ffffffffff
CapAmb: 0000000000000000
```

The hexadecimal values are bit masks. Each bit represents one capability number.

To decode them:

```bash
capsh --decode=000001ffffffffff
```

Or inspect a running process more directly:

```bash
getpcaps <PID>
```

Capabilities are technically a **per-thread** property. Threads in the same process normally begin with identical credentials, but the kernel model is thread-oriented, and a thread can alter its own capability sets independently under the applicable rules.

---

# 2. Effective Set

The **Effective set** contains the capabilities that are active right now.

When a kernel subsystem performs a capability check, it generally checks the thread's effective set in the relevant user namespace.

Conceptually:

```c
if (capable(CAP_NET_ADMIN))
        allow_operation();
else
        return -EPERM;
```

At a high level, `capable(CAP_NET_ADMIN)` succeeds only if `CAP_NET_ADMIN` is effective for the caller in the namespace that governs the resource.

Examples of operations guarded by effective capabilities include:

- Binding to a privileged port
- Creating certain raw sockets
- Changing network configuration
- Mounting filesystems
- Changing system time
- Tracing another process
- Loading kernel modules

A capability that exists only in the permitted set but not in the effective set is **not currently active**.

For example:

```text
Permitted: CAP_NET_RAW
Effective: none
```

The thread is authorized to activate `CAP_NET_RAW`, but kernel checks requiring `CAP_NET_RAW` still fail until it is moved into the effective set.

This distinction allows capability-aware programs to follow a safer pattern:

1. Start with a capability permitted.
2. Keep it ineffective during normal execution.
3. Temporarily enable it before a privileged operation.
4. Disable it immediately afterward.

Conceptually:

```text
CAP_NET_ADMIN permitted, not effective
        |
        | enable briefly
        v
CAP_NET_ADMIN permitted and effective
        |
        | perform operation
        v
CAP_NET_ADMIN permitted, not effective
```

This reduces the time window in which a vulnerability can abuse the privilege.

## Effective Is Usually a Subset of Permitted

A thread cannot normally place a capability into its effective set unless that capability is already present in its permitted set.

The core invariant is:

```text
Effective ⊆ Permitted
```

Therefore:

```text
CAP_SYS_TIME in Effective
CAP_SYS_TIME absent from Permitted
```

is not a valid stable capability state.

The permitted set acts as the authorization reservoir; the effective set selects which authorized capabilities are currently active.

## Inspecting the Effective Set

```bash
grep '^CapEff:' /proc/self/status
```

Using `capsh`:

```bash
capsh --print
```

A common output fragment may look like:

```text
Current: cap_chown,cap_dac_override,cap_fowner,...=ep
```

The suffixes have specific meanings:

- `e` — effective
- `p` — permitted
- `i` — inheritable

Thus:

```text
cap_net_bind_service=ep
```

means the capability is present in both the effective and permitted sets.

---

# 3. Permitted Set

The **Permitted set** defines the capabilities that a thread is allowed to make effective.

It is the upper limit for the thread's effective set.

A thread may drop capabilities from its permitted set. However, once a capability is removed, the thread usually cannot restore it by itself unless a later privileged `execve()` legitimately grants it again and the bounding, namespace, file capability, and security rules allow that transition.

This gives the permitted set a crucial security role:

> Removing a capability from Permitted is stronger than merely disabling it in Effective.

Compare these two states:

### State A

```text
Permitted: CAP_NET_ADMIN
Effective: none
```

The process cannot currently perform `CAP_NET_ADMIN` operations, but capability-aware code may enable it later.

### State B

```text
Permitted: none
Effective: none
```

The process cannot simply reactivate `CAP_NET_ADMIN`, because it no longer possesses authorization to do so.

For long-running daemons, a robust privilege-dropping sequence often removes unnecessary capabilities from both sets:

```text
Effective
Permitted
Bounding
Ambient
```

Dropping only from Effective may create a false sense of security.

## Why Keep a Capability Permitted but Ineffective?

Some programs need privilege only during narrow portions of execution.

For example, a network daemon may need to:

- Reconfigure an interface during startup
- Drop the privilege during normal request handling
- Temporarily reacquire it during a controlled reload

A capability-aware daemon can retain `CAP_NET_ADMIN` in Permitted while toggling it in Effective.

This is more precise than continuously operating with the capability active.

## Irreversible Drops

Applications should treat dropping from Permitted as potentially irreversible within the current execution context.

The exact possibility of regaining a capability depends on:

- The executable being run
- File capabilities
- Set-user-ID behavior
- Bounding set
- `no_new_privs`
- Securebits
- User namespace
- LSM policy
- Current UID transitions

A secure design should not assume that a dropped capability can later be recovered.

---

# 4. Inheritable Set

The **Inheritable set** is frequently misunderstood.

Its name suggests that it automatically passes capabilities from a parent process to a child. That is not an accurate mental model.

Ordinary process creation through `fork()` or `clone()` already copies credentials to the child. The inheritable set primarily matters during **program execution through `execve()`**.

The inheritable set specifies capabilities from the current thread that may contribute to the new permitted set when the executed file explicitly marks those same capabilities as inheritable.

The relevant path is conceptually:

```text
Process Inheritable ∩ File Inheritable
                  |
                  v
        New Process Permitted
```

Therefore, a capability in the process inheritable set is not enough by itself.

A matching file capability must participate in the transition.

## Why Inheritable Exists

Imagine a privileged launcher that wants a trusted helper program to receive a specific capability.

The launcher may place a capability in its inheritable set, while the helper executable is marked to accept that capability through its file inheritable mask.

Only the intersection contributes:

```text
P(inheritable) & F(inheritable)
```

If either side lacks the capability, it does not pass through this path.

## Inheritable Does Not Mean Effective

A capability may be inheritable while remaining absent from both Effective and Permitted after a particular execution.

The inheritable set is not consulted directly by most privileged kernel operations.

It is transition metadata.

For example:

```text
Inheritable: CAP_NET_RAW
Effective:   none
```

does not allow the thread to create a raw socket.

## Why It Is Rarely Used Directly

The inheritable model is awkward for many real-world service-launching scenarios because both the launching process and target file must cooperate.

Historically, this made it difficult to preserve capabilities across execution of ordinary unprivileged programs, scripts, shells, and interpreter chains.

Linux later introduced the Ambient set to solve this specific usability problem.

## Restrictions on Raising Inheritable Capabilities

A thread cannot arbitrarily add every capability to its inheritable set.

The kernel applies restrictions involving:

- The thread's existing authority
- `CAP_SETPCAP`
- The bounding set
- Securebits
- Namespace context

A particularly important rule is that a capability removed from the bounding set cannot normally be newly added to the inheritable set.

## Common Misconception

Incorrect:

> Inheritable contains everything a child process inherits.

More accurate:

> Inheritable contains capabilities that may participate in a future `execve()` transition when the target executable explicitly supports that inheritance path.

---

# 5. Bounding Set

The **Bounding set** is a capability ceiling.

It limits which capabilities a thread and its descendants may gain through privileged executable files during `execve()`.

For modern kernels, the bounding set is maintained per thread and inherited across `fork()` and preserved across `execve()`.

A capability removed from the bounding set cannot be restored to that thread's bounding set.

This makes it one of the strongest tools for permanently reducing privilege potential.

## Bounding Is Not the Same as Permitted

The permitted set describes what the thread currently owns.

The bounding set limits what the thread may gain through certain future execution transitions.

Example:

```text
Permitted: CAP_NET_RAW
Bounding:  CAP_NET_RAW
```

The thread currently possesses the capability and may potentially keep or regain it under valid rules.

Another state:

```text
Permitted: none
Bounding:  CAP_NET_RAW
```

The capability is not currently owned, but it remains within the future privilege ceiling.

Another state:

```text
Permitted: none
Bounding:  none
```

The capability is absent now and blocked from being gained through the file-permitted path.

## The Critical `execve()` Role

The simplified file-permitted contribution is:

```text
File Permitted ∩ Bounding
```

A file may carry `CAP_SYS_ADMIN` in its permitted file capability mask, but if the executing thread's bounding set does not contain `CAP_SYS_ADMIN`, that file cannot grant it through this path.

Conceptually:

```text
Executable requests CAP_SYS_ADMIN
                |
                v
Bounding set contains it?
        /               \
      yes               no
      |                  |
may contribute      capability blocked
```

## Permanently Dropping from Bounding

A thread can remove a capability from its bounding set with:

```c
prctl(PR_CAPBSET_DROP, capability, 0, 0, 0);
```

This requires the appropriate authority, including `CAP_SETPCAP` in the thread's user namespace.

Once removed, the capability cannot be re-added to that bounding set.

From the shell, tools such as `setpriv`, `capsh`, systemd, Docker, and container runtimes can manipulate the bounding set.

Examples:

```bash
setpriv --bounding-set=-net_raw command
```

```bash
capsh --drop=cap_net_raw -- -c 'command'
```

## Bounding Set and Containers

Container engines construct a reduced bounding set before launching the container payload.

This prevents processes inside the container from gaining dangerous capabilities merely by executing files that carry file capabilities or set-user-ID privilege.

A container running as UID 0 is therefore not automatically equivalent to host root. Its authority is constrained by:

- User namespace
- Capability sets
- Bounding set
- Seccomp
- LSM policy
- Mount namespace
- Other namespace boundaries
- Runtime configuration

However, dangerous bounding-set choices can substantially weaken container isolation.

## Important Nuance

The bounding set masks the **file permitted** path during `execve()`.

It should not be reduced to the inaccurate statement:

> Bounding directly intersects with every capability set at all times.

The exact transformation rules matter. The inheritable path has distinct semantics, and existing capabilities are not automatically erased merely because an oversimplified diagram says `Permitted ⊆ Bounding`.

Modern security tooling should nevertheless reduce both Permitted and Bounding because they control different parts of current and future privilege.

---

# 6. Ambient Set

The **Ambient set** was added in Linux 4.3.

Its purpose is to preserve selected capabilities across execution of ordinary, non-privileged programs.

Before Ambient capabilities, passing capabilities through chains such as:

```text
service manager
    -> shell
        -> script
            -> interpreter
                -> application
```

was difficult unless each executable had suitable file capability metadata.

Ambient capabilities provide a controlled mechanism for a non-root process to carry capabilities across ordinary `execve()` calls.

## The Ambient Invariant

A capability can be ambient only when it is also present in both Permitted and Inheritable:

```text
Ambient ⊆ Permitted ∩ Inheritable
```

If the capability is removed from Permitted or Inheritable, it is automatically removed from Ambient.

This invariant prevents Ambient from becoming an independent source of privilege.

## Effect During `execve()`

When a thread executes a **non-privileged** file, Ambient capabilities are:

- Added to the new Permitted set
- Added to the new Effective set
- Preserved in the new Ambient set

Conceptually:

```text
Old Ambient
     |
     +----> New Permitted
     |
     +----> New Effective
     |
     +----> New Ambient
```

This is why Ambient capabilities are useful for launching ordinary binaries without modifying those binaries on disk.

## What Counts as a Privileged File?

For Ambient behavior, a privileged executable is generally one that gains privilege through mechanisms such as:

- Set-user-ID
- Set-group-ID
- File capabilities

Executing such a program clears the Ambient set.

This prevents ambient privilege from being unexpectedly combined with another privilege-granting mechanism.

## Raising Ambient Capabilities

The kernel interface uses `prctl()` operations such as:

```c
prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_NET_BIND_SERVICE, 0, 0);
```

The capability must already be present in:

- Permitted
- Inheritable

It must also be allowed by the relevant securebits state.

Tools can simplify the process:

```bash
setpriv \
  --inh-caps=+net_bind_service \
  --ambient-caps=+net_bind_service \
  command
```

Exact syntax and initial privilege requirements depend on the environment and tool version.

## Why Ambient Can Be Dangerous

Ambient capabilities propagate through ordinary execution chains.

If a privileged service launches an attacker-controlled helper, plugin, shell, or script while retaining Ambient capabilities, that child may receive the same active privilege.

Therefore:

- Keep Ambient empty unless truly needed.
- Clear it before executing untrusted code.
- Audit shell and interpreter execution.
- Avoid broad Ambient sets on network-facing daemons.
- Combine Ambient with a reduced Bounding set.

Ambient capabilities solve an important usability problem, but they also increase the importance of understanding process execution paths.

---

# 7. File Capability Sets

Executable files may store capability metadata in the `security.capability` extended attribute.

A file capability record conceptually contains:

- File Permitted
- File Inheritable
- Effective flag
- Version information
- In namespaced file capabilities, a root user namespace identifier

Inspect file capabilities with:

```bash
getcap /path/to/binary
```

Recursively:

```bash
getcap -r / 2>/dev/null
```

Assign capabilities with:

```bash
sudo setcap cap_net_bind_service=ep /path/to/server
```

Remove them:

```bash
sudo setcap -r /path/to/server
```

## File Permitted

The file permitted mask contributes capabilities through:

```text
File Permitted ∩ Thread Bounding
```

These capabilities may enter the new process's Permitted set during `execve()`.

## File Inheritable

The file inheritable mask selects which capabilities from the old thread's Inheritable set may enter the new Permitted set:

```text
Thread Inheritable ∩ File Inheritable
```

Despite the naming, the file inheritable mask does not mean:

> Give these capabilities to whoever runs the file.

Instead, it means:

> Accept these capabilities from the caller's inheritable set.

## File Effective Flag

The file capability effective component is a flag rather than an independent per-capability mask in the same sense as the permitted and inheritable masks.

When set, the capabilities calculated into the new Permitted set are also placed into the new Effective set.

This is why output commonly appears as:

```text
/usr/bin/ping cap_net_raw=ep
```

The `p` indicates file-permitted membership and `e` indicates that the effective flag is enabled.

## Security of File Capabilities

File capabilities are less broad than set-user-ID root, but they are not automatically safe.

A dangerous interpreter or general-purpose executable with a powerful file capability may provide an immediate privilege-escalation path.

Examples requiring serious scrutiny include capabilities such as:

- `CAP_SETUID`
- `CAP_SETGID`
- `CAP_DAC_OVERRIDE`
- `CAP_DAC_READ_SEARCH`
- `CAP_SYS_ADMIN`
- `CAP_SYS_PTRACE`
- `CAP_SYS_MODULE`
- `CAP_NET_ADMIN`
- `CAP_SYS_CHROOT`

The risk depends on what the executable can be made to do.

Granting a narrow capability to a narrowly designed binary can be reasonable.

Granting the same capability to Python, Perl, Ruby, a shell, a debugger, an editor, an archive utility, or a programmable network tool can be equivalent to granting a broad privilege-escalation primitive.

---

# 8. Capability Transformation During `execve()`

The most important capability transition occurs when a thread executes a new program.

Use the following notation:

```text
P(...)   = capability set of the thread before execve()
P'(...)  = capability set after execve()
F(...)   = capability metadata on the executable file
```

The main sets are:

```text
P(inheritable)
P(permitted)
P(effective)
P(bounding)
P(ambient)

F(inheritable)
F(permitted)
F(effective)
```

A simplified modern transformation model is:

```text
P'(ambient)   = privileged_file ? 0 : P(ambient)

P'(permitted) =
    (P(inheritable) ∩ F(inheritable))
    ∪
    (F(permitted) ∩ P(bounding))
    ∪
    P'(ambient)

P'(effective) =
    F(effective) ? P'(permitted) : P'(ambient)

P'(inheritable) = P(inheritable)

P'(bounding) = P(bounding)
```

This notation is useful, but several details must be remembered:

- Set-user-ID-root compatibility behavior may cause the kernel to conceptually treat file capability masks as populated.
- Securebits can disable or alter traditional UID 0 special handling.
- `no_new_privs` can suppress privilege gains from set-user-ID, set-group-ID, and file capabilities.
- LSMs may further restrict execution.
- User namespaces determine where a capability is meaningful.
- Namespaced file capability versions add namespace-specific behavior.
- Filesystem mount options and extended-attribute support matter.

## Reading the Formula

The new Permitted set may receive capabilities from three paths.

### Path 1: Inheritable Cooperation

```text
Old Process Inheritable ∩ File Inheritable
```

Both caller and executable agree on the capability.

### Path 2: File-Granted Capability

```text
File Permitted ∩ Old Bounding
```

The executable requests the capability, while Bounding determines whether the transition is allowed.

### Path 3: Ambient Propagation

```text
New Ambient
```

Ambient capabilities pass through an ordinary non-privileged executable.

The new Effective set then depends on:

- The file effective flag
- The Ambient set

## Example A: File Capability

Assume:

```text
Old Inheritable: none
Old Bounding:    CAP_NET_BIND_SERVICE
Old Ambient:     none

File Permitted:  CAP_NET_BIND_SERVICE
File Effective:  enabled
```

After `execve()`:

```text
New Permitted: CAP_NET_BIND_SERVICE
New Effective: CAP_NET_BIND_SERVICE
```

The program can immediately bind to a privileged port.

## Example B: Bounding Blocks the File

Assume the same file, but:

```text
Old Bounding: none
```

Then:

```text
File Permitted ∩ Bounding = none
```

The file cannot grant `CAP_NET_BIND_SERVICE` through the file-permitted path.

## Example C: Ambient Through an Ordinary Program

Assume:

```text
Old Permitted:   CAP_NET_BIND_SERVICE
Old Inheritable: CAP_NET_BIND_SERVICE
Old Ambient:     CAP_NET_BIND_SERVICE
```

The target file has:

```text
No set-user-ID
No set-group-ID
No file capabilities
```

After execution:

```text
New Permitted:   CAP_NET_BIND_SERVICE
New Effective:   CAP_NET_BIND_SERVICE
New Inheritable: CAP_NET_BIND_SERVICE
New Ambient:     CAP_NET_BIND_SERVICE
```

## Example D: Ambient Meets a Privileged File

Assume the same initial process executes a file carrying any capability metadata.

The Ambient set is cleared:

```text
New Ambient: none
```

The resulting Permitted and Effective sets are then calculated using the privileged-file transition rules.

---

# 9. Securebits and Capability Sets

Securebits are per-thread flags that alter how capabilities interact with UID transitions and execution.

They are not capability sets, but they strongly influence capability behavior.

Important securebits include:

- `SECBIT_KEEP_CAPS`
- `SECBIT_NO_SETUID_FIXUP`
- `SECBIT_NOROOT`
- `SECBIT_NO_CAP_AMBIENT_RAISE`

Most also have a corresponding locked form that prevents further changes.

Inspect them with:

```bash
capsh --print
```

## `SECBIT_KEEP_CAPS`

Normally, changing effective and real UIDs away from 0 can clear capability state according to UID transition rules.

`SECBIT_KEEP_CAPS` permits retaining the Permitted set across certain UID changes.

Important nuance:

- It does not automatically make retained capabilities Effective.
- It is cleared by `execve()`.
- Programs often need to re-enable selected Effective capabilities afterward.

## `SECBIT_NO_SETUID_FIXUP`

This disables the kernel's traditional automatic capability adjustments caused by switching between UID 0 and nonzero UIDs.

It is useful for capability-native applications that want explicit control rather than legacy root compatibility behavior.

## `SECBIT_NOROOT`

This disables the special capability treatment traditionally associated with UID 0 during execution.

It helps create a model where root is not automatically treated as possessing all capabilities.

## `SECBIT_NO_CAP_AMBIENT_RAISE`

This prevents raising capabilities into the Ambient set.

Its locked variant can permanently enforce this decision for the process tree.

---

# 10. `no_new_privs`

`no_new_privs` is not a capability set, but it is essential when reasoning about capability transitions.

A thread can set it using:

```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
```

Once set, it cannot be unset and is inherited by descendants.

Its central guarantee is that `execve()` will not grant privileges that the caller did not already possess.

In practice, it suppresses privilege gains from mechanisms such as:

- Set-user-ID
- Set-group-ID
- File capabilities

This is widely used by:

- Seccomp sandboxes
- Container runtimes
- Browser sandboxes
- systemd hardening
- Unprivileged isolation tools

A process may still retain or rearrange capabilities it already possesses subject to the normal rules, but it cannot use a privileged executable to gain new authority beyond its existing state.

Inspect it with:

```bash
grep '^NoNewPrivs:' /proc/<PID>/status
```

---

# 11. Capabilities and User Namespaces

Capabilities are evaluated relative to a **user namespace**.

A process may possess `CAP_SYS_ADMIN` inside a child user namespace without possessing `CAP_SYS_ADMIN` in the initial user namespace.

This distinction is fundamental to containers.

A capability in a user namespace authorizes operations only over resources governed by that namespace or by non-user namespaces owned by it.

For example, a process may be able to:

- Change the hostname in a UTS namespace owned by its user namespace
- Configure interfaces in a network namespace owned by its user namespace
- Mount certain namespace-scoped filesystems under applicable rules

Yet remain unable to:

- Load host kernel modules
- Change the host system clock
- Mount arbitrary host block devices
- Administer resources owned by the initial user namespace

Therefore:

```text
CAP_SYS_ADMIN inside a container
```

is not automatically identical to:

```text
CAP_SYS_ADMIN on the host
```

However, it remains extremely powerful within the scope it governs, and kernel attack surface exposed through namespace operations can still create serious risk.

Capability auditing must always ask:

> In which user namespace is this capability effective, and which resource's owning user namespace is consulted?

---

# 12. Common Capability-State Patterns

## Pattern 1: Fully Unprivileged Process

```text
Permitted:   none
Effective:   none
Inheritable: none
Ambient:     none
Bounding:    reduced or nonempty
```

The process has no active or retained capabilities.

A nonempty Bounding set means future file-based privilege might still be possible unless other controls prevent it.

## Pattern 2: Capability-Aware Daemon

```text
Permitted:   CAP_NET_ADMIN
Effective:   none
Inheritable: none
Ambient:     none
Bounding:    CAP_NET_ADMIN
```

The daemon retains authorization but activates the capability only when required.

## Pattern 3: File-Capability Program

File:

```text
cap_net_bind_service=ep
```

After execution:

```text
Permitted: CAP_NET_BIND_SERVICE
Effective: CAP_NET_BIND_SERVICE
```

Subject to Bounding, `no_new_privs`, namespace, and other rules.

## Pattern 4: Ambient Service Launcher

```text
Permitted:   CAP_NET_BIND_SERVICE
Effective:   CAP_NET_BIND_SERVICE
Inheritable: CAP_NET_BIND_SERVICE
Ambient:     CAP_NET_BIND_SERVICE
Bounding:    CAP_NET_BIND_SERVICE
```

The capability survives ordinary execution chains.

This is useful but must be carefully constrained.

## Pattern 5: Container Root with Reduced Capabilities

```text
UID:         0 inside container
Permitted:   runtime-defined subset
Effective:   runtime-defined subset
Bounding:    runtime-defined subset
Ambient:     usually empty
```

UID 0 exists, but its practical authority is reduced by capability and namespace boundaries.

## Pattern 6: Permanently Sandboxed Process

```text
Permitted:   none
Effective:   none
Inheritable: none
Ambient:     none
Bounding:    none or aggressively reduced
NoNewPrivs:  1
```

This is close to a capability-minimized process tree, although filesystem permissions, LSM policy, seccomp, namespaces, and open file descriptors must still be considered.

---

# 13. Practical Inspection Workflow

A reliable capability audit should examine more than `getcap -r /`.

## Step 1: Inspect the Process

```bash
grep -E '^(Uid|Gid|Cap|NoNewPrivs|Seccomp):' /proc/<PID>/status
```

## Step 2: Decode Capability Masks

```bash
capsh --decode=<hex-mask>
```

## Step 3: Use libcap Tools

```bash
getpcaps <PID>
capsh --print
```

## Step 4: Inspect Executable Metadata

```bash
getcap /proc/<PID>/exe
getfattr -n security.capability /path/to/file
```

## Step 5: Inspect the Bounding Set

```bash
grep '^CapBnd:' /proc/<PID>/status
```

## Step 6: Inspect Ambient State

```bash
grep '^CapAmb:' /proc/<PID>/status
```

## Step 7: Check Namespaces

```bash
lsns -p <PID>
readlink /proc/<PID>/ns/user
```

Compare against PID 1 or the host shell:

```bash
readlink /proc/1/ns/user
readlink /proc/self/ns/user
```

## Step 8: Inspect Service Configuration

For systemd:

```bash
systemctl cat <service>
systemctl show <service> \
  -p CapabilityBoundingSet \
  -p AmbientCapabilities \
  -p NoNewPrivileges \
  -p SecureBits \
  -p User
```

## Step 9: Inspect Container Runtime Configuration

Docker:

```bash
docker inspect <container>
```

Look for:

- `CapAdd`
- `CapDrop`
- `Privileged`
- User namespace configuration
- Security options

Inside the container:

```bash
grep '^Cap' /proc/1/status
capsh --print
```

---

# 14. Common Mistakes

## Mistake 1: Treating Capability Presence as Active Privilege

A capability in Permitted is not necessarily Effective.

Always inspect both.

## Mistake 2: Assuming Inheritable Means Child Inheritance

It primarily participates in `execve()` with file inheritable metadata.

It is not a simple parent-to-child privilege list.

## Mistake 3: Ignoring Bounding

A file capability may appear correctly configured but be blocked by the process bounding set.

## Mistake 4: Ignoring Ambient

A process may appear to execute an ordinary unprivileged binary, yet Ambient capabilities can make the new program privileged.

## Mistake 5: Looking Only at UID

UID 0 may be heavily constrained.

A nonzero UID may possess powerful capabilities.

Inspect credentials, namespaces, LSMs, seccomp, and open resources together.

## Mistake 6: Assuming File Capabilities Are Always Safer Than SUID

They are more granular, but a dangerous capability on a flexible executable can still provide full compromise.

## Mistake 7: Confusing Host and Namespace Capability

Capabilities are meaningful in relation to a user namespace and the resource being controlled.

## Mistake 8: Dropping Only Effective

The process may later reactivate the capability from Permitted.

## Mistake 9: Dropping Only Permitted

A broad Bounding set may leave future privilege acquisition paths available.

## Mistake 10: Forgetting Existing Open File Descriptors

Dropping capabilities does not revoke access already represented by open file descriptors, mapped memory, sockets, or other acquired kernel objects.

Privilege dropping must happen before opening sensitive resources whenever possible.

---

# 15. Security Invariants Worth Memorizing

The following mental rules are more useful than memorizing command syntax:

```text
Effective ⊆ Permitted
```

```text
Ambient ⊆ Permitted ∩ Inheritable
```

```text
File Permitted is limited by Bounding during execve()
```

```text
Inheritable requires cooperation between process and file
```

```text
Ambient survives only ordinary non-privileged execve()
```

```text
Dropping from Bounding is irreversible for that process tree
```

```text
Capabilities are evaluated in a user-namespace context
```

```text
no_new_privs blocks privilege gain through execve()
```

```text
UID 0 alone does not describe actual privilege
```

These invariants form a practical framework for analyzing capability behavior.

---

# 16. A Compact Mental Model

Think of the five sets as five different security questions.

### Effective

> What can I use right now?

### Permitted

> What am I allowed to activate?

### Inheritable

> What privilege am I willing to pass through a cooperating executable?

### Bounding

> What privilege have I permanently ruled out from future file-based acquisition?

### Ambient

> What privilege should survive execution of ordinary unprivileged programs?

File capabilities then answer:

> What privilege is this executable allowed to introduce or accept during `execve()`?

Together, these rules replace the simplistic root/non-root model with a precise privilege-transition system.

---

# 17. Summary Table

| Set | Active in permission checks? | Preserved across ordinary `execve()`? | Can influence new Permitted? | Main security role |
|---|---:|---:|---:|---|
| Effective | Yes | Recalculated | Indirectly | Active authority |
| Permitted | No, not by itself | Recalculated | Yes | Maximum activatable authority |
| Inheritable | No | Yes | Yes, with file inheritable | Cooperative inheritance |
| Bounding | No | Yes | Limits file-permitted path | Future privilege ceiling |
| Ambient | Becomes effective after ordinary exec | Yes, for non-privileged files | Yes | Propagation through ordinary programs |

---

# 18. Final Perspective

The capability sets are not redundant copies of the same information.

Each set exists because privilege has a lifecycle:

```text
Privilege may be granted
Privilege may be held in reserve
Privilege may be activated
Privilege may cross execve()
Privilege may be permanently blocked
Privilege may be constrained to a namespace
```

Linux Capabilities model every stage separately.

This complexity is the price of replacing the unrestricted root model with fine-grained privilege control.

Once the distinction between Effective, Permitted, Inheritable, Bounding, Ambient, and file capabilities becomes clear, many seemingly confusing behaviors in systemd, Docker, Kubernetes, container runtimes, SUID transitions, and privilege-escalation research become predictable.

The next chapter applies this model to real-world Linux software and infrastructure, including `ping`, web servers, packet-capture tools, systemd units, Docker containers, and Kubernetes workloads.
