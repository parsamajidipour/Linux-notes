# Troubleshooting and Best Practices

Understanding Linux Capabilities is only half of the challenge.

In production environments, administrators spend far more time answering questions such as:

- Why doesn't this capability work?
- Why is my process still getting `EPERM`?
- Why did Docker remove this capability?
- Why did `execve()` drop my privileges?
- Why does this binary work on one server but fail on another?

This chapter focuses on practical troubleshooting techniques and operational best practices.

---

# 1. Start with Process Credentials

Never begin by inspecting the executable.

Start with the running process.

```bash
grep -E '^(Uid|Gid|Cap|NoNewPrivs|Seccomp):' /proc/<PID>/status
```

Important fields:

- CapInh
- CapPrm
- CapEff
- CapBnd
- CapAmb
- NoNewPrivs

Decode masks:

```bash
capsh --decode=<hex-mask>
```

or

```bash
getpcaps <PID>
```

---

# 2. Verify File Capabilities

Inspect the executable:

```bash
getcap /path/to/binary
```

Inspect recursively:

```bash
getcap -r / 2>/dev/null
```

Remove an incorrect assignment:

```bash
sudo setcap -r /path/to/binary
```

Remember that file capabilities are stored as the
`security.capability` extended attribute.

---

# 3. Confirm the Bounding Set

Many privilege problems originate from the Bounding set.

Inspect it:

```bash
grep '^CapBnd:' /proc/<PID>/status
```

A capability absent from the Bounding set cannot normally be gained
through the file-permitted path during `execve()`.

---

# 4. Check `NoNewPrivileges`

A surprisingly common cause of confusion.

```bash
grep '^NoNewPrivs:' /proc/<PID>/status
```

If enabled, privilege gains from mechanisms such as:

- set-user-ID
- set-group-ID
- file capabilities

are restricted.

systemd example:

```ini
NoNewPrivileges=yes
```

---

# 5. Inspect Namespaces

A process may possess a capability inside one user namespace while
lacking authority over host resources.

Useful commands:

```bash
lsns -p <PID>
```

```bash
readlink /proc/<PID>/ns/user
```

Always determine:

- Which user namespace owns the resource?
- Which user namespace owns the process?

---

# 6. Check systemd Configuration

View the effective service configuration:

```bash
systemctl cat <service>
```

Useful properties:

```bash
systemctl show <service> \
-p CapabilityBoundingSet \
-p AmbientCapabilities \
-p NoNewPrivileges \
-p User \
-p SecureBits
```

---

# 7. Check Container Runtime Settings

Docker:

```bash
docker inspect <container>
```

Review:

- CapAdd
- CapDrop
- Privileged
- SecurityOpt
- User namespace configuration

Inside the container:

```bash
capsh --print
```

```bash
grep '^Cap' /proc/1/status
```

---

# 8. Understand Common Error Codes

## EPERM

Usually indicates that a capability check failed or an LSM denied the
operation.

## EACCES

Often related to filesystem permissions rather than capabilities.

Always distinguish between permission bits, ACLs, LSM policy and
capability checks.

---

# 9. Debug with `strace`

Example:

```bash
strace -f ./application
```

Look for:

- EPERM
- EACCES
- execve()
- prctl()
- capset()
- capget()

This frequently reveals the exact syscall that failed.

---

# 10. Common Mistakes

### Granting CAP_SYS_ADMIN

Avoid using it as a universal solution.

### Running Everything as Root

Usually unnecessary.

### Forgetting Ambient Capabilities

Unexpected privilege propagation may occur.

### Ignoring Existing Open File Descriptors

Dropping capabilities does not revoke resources already opened.

### Trusting UID Alone

Always inspect the complete credential state.

---

# 11. Best Practices

## Follow Least Privilege

Grant only the capabilities required.

## Drop Capabilities Early

If a capability is only required during initialization,
remove it immediately afterward.

## Reduce the Bounding Set

Prevent future privilege acquisition whenever possible.

## Keep Ambient Empty

Use Ambient capabilities only when there is a clear operational need.

## Avoid Programmable Binaries

Do not grant powerful capabilities to:

- Python
- Perl
- Bash
- Ruby
- Editors
- Archive tools

unless absolutely necessary.

## Combine Multiple Security Layers

Capabilities should work alongside:

- seccomp
- SELinux or AppArmor
- Namespaces
- Read-only filesystems
- Non-root execution
- Minimal container images

---

# 12. Production Audit Checklist

Before deploying a service verify:

- [ ] Runs as a non-root user whenever possible.
- [ ] Only required capabilities are granted.
- [ ] Bounding set is minimized.
- [ ] Ambient capabilities are justified.
- [ ] No unnecessary file capabilities exist.
- [ ] `NoNewPrivileges` is enabled where appropriate.
- [ ] Container is not started with `--privileged`.
- [ ] CAP_SYS_ADMIN is avoided unless technically required.
- [ ] Service has been tested after privilege reduction.
- [ ] Capability assignments are documented.

---

# Quick Troubleshooting Flow

```text
Operation fails
      |
      v
Check syscall (strace)
      |
      v
Inspect process capabilities
      |
      v
Inspect file capabilities
      |
      v
Inspect Bounding Set
      |
      v
Check NoNewPrivileges
      |
      v
Check namespaces
      |
      v
Review LSM / seccomp / filesystem permissions
```

---

# Summary

Capability-related problems are rarely caused by a single setting.

Successful troubleshooting requires examining:

- Process credentials
- File capabilities
- Bounding set
- Ambient capabilities
- Namespace context
- Service manager configuration
- Container runtime configuration
- LSM policy
- seccomp
- Traditional UNIX permissions

The best security posture is achieved not by granting more privilege,
but by understanding precisely why privilege is required in the first place.
