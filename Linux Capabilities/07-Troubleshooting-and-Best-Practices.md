# Troubleshooting and Best Practices

Understanding Linux Capabilities is only half of the challenge. In production, administrators spend far more time answering questions such as:

- Why doesn't this capability work?
- Why is my process still getting `EPERM`?
- Why did Docker remove this capability?
- Why did `execve()` drop my privileges?
- Why does this binary work on one server but fail on another?

This chapter is a systematic method for answering those questions, followed by the operational best practices that prevent them.

---

# 1. Start with Process Credentials

Never begin by inspecting the executable. Start with the running process — the credentials it actually holds are the ground truth:

```bash
grep -E '^(Uid|Gid|Cap|NoNewPrivs|Seccomp):' /proc/<PID>/status
```

```text
Uid:    33      33      33      33
Gid:    33      33      33      33
CapInh: 0000000000000000
CapPrm: 0000000000000400
CapEff: 0000000000000400
CapBnd: 0000000000000400
CapAmb: 0000000000000400
NoNewPrivs:     1
Seccomp:        2
```

Decode any mask instead of counting bits:

```bash
capsh --decode=0000000000000400
```

```text
0x0000000000000400=cap_net_bind_service
```

Or read a live process directly:

```bash
getpcaps <PID>
```

Reading the five sets together tells you most of the story: a capability in `CapPrm` but missing from `CapEff` means "held but not active"; a capability missing from `CapBnd` means "cannot be gained here at all."

---

# 2. Verify File Capabilities

Only after checking the process, inspect the executable:

```bash
getcap /path/to/binary
```

```text
/path/to/binary cap_net_raw=ep
```

Scan the whole filesystem when auditing:

```bash
getcap -r / 2>/dev/null
```

Remove an incorrect assignment:

```bash
sudo setcap -r /path/to/binary
```

File capabilities are stored as the `security.capability` extended attribute, so anything that strips xattrs — copying across filesystems, restoring from an archive that does not preserve them, or building an image incorrectly — silently removes them.

---

# 3. Confirm the Bounding Set

Many privilege problems originate from the Bounding set. A capability absent from `CapBnd` cannot be gained through the file-permitted path during `execve()`, no matter what the file grants:

```bash
grep '^CapBnd:' /proc/<PID>/status
```

If the bounding set has been reduced (common in containers and hardened systemd units), a `setcap`'d binary can carry a capability the process is simply not allowed to receive.

---

# 4. Check `NoNewPrivileges`

A surprisingly common cause of confusion. When `no_new_privs` is set, the kernel refuses to grant privilege through set-user-ID, set-group-ID, or file capabilities during `execve()`:

```bash
grep '^NoNewPrivs:' /proc/<PID>/status
```

```text
NoNewPrivs:     1
```

If this reads `1`, a `setcap`'d helper launched by the process will *not* pick up its file capabilities — by design. This trips people up constantly: the binary is configured correctly, the file capability is present, and it still does nothing, because the parent set `no_new_privs`. systemd sets it via:

```ini
NoNewPrivileges=yes
```

and Kubernetes via `allowPrivilegeEscalation: false`.

---

# 5. Inspect Namespaces

A process may hold a capability inside one user namespace while lacking authority over host-owned resources. The capability is real; the target is simply owned by a namespace the process has no power over.

```bash
lsns -p <PID>
readlink /proc/<PID>/ns/user
```

Always determine two things:

- Which user namespace owns the *resource* being acted on?
- Which user namespace owns the *process*?

If they differ, a capability held by the process does nothing to that resource.

---

# 6. Check systemd Configuration

View the effective unit and the resolved properties:

```bash
systemctl cat <service>

systemctl show <service> \
  -p CapabilityBoundingSet \
  -p AmbientCapabilities \
  -p NoNewPrivileges \
  -p User \
  -p SecureBits
```

A frequent failure: a non-root service with `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` but *no* `AmbientCapabilities=` line. The bounding set permits the capability, but nothing places it in the process's effective set, so it never actually holds it.

---

# 7. Check Container Runtime Settings

```bash
docker inspect <container>
```

Review `CapAdd`, `CapDrop`, `Privileged`, `SecurityOpt`, and user-namespace configuration. Then confirm from inside:

```bash
capsh --print
grep '^Cap' /proc/1/status
```

If the container was built or run with a reduced bounding set (or `--security-opt no-new-privileges`), file capabilities inside will not behave as they would on a normal host.

---

# 8. A Worked Failure: "setcap succeeded but the binary still fails"

This is the single most common capability puzzle. Walk it in order:

1. **`no_new_privs` is set** on the process or an ancestor — file capabilities are ignored on exec. Check `NoNewPrivs` in `/proc`.
2. **The filesystem is mounted `nosuid`** — `nosuid` strips file capabilities on `execve()` exactly as it strips SUID. Check with `findmnt <mountpoint>`.
3. **The effective flag is not set** — a binary tagged `cap_net_raw=p` (permitted only, no `e`) receives the capability in permitted but must raise it into effective itself. If the program is not capability-aware, use `=ep`.
4. **The capability is outside the bounding set** — reduced `CapBnd` blocks the file-permitted path.
5. **xattrs were lost** — the binary was copied or restored without preserving `security.capability`; re-check with `getcap`.

Nine times out of ten the answer is item 1 or item 2.

---

# 9. Understand Common Error Codes

## EPERM

Usually means a capability check failed — or an LSM (SELinux/AppArmor) or seccomp filter denied the operation. Capabilities are only one of several gates that can return `EPERM`.

## EACCES

More often a traditional filesystem permission problem (mode bits or ACLs) than a capability issue.

Always distinguish between permission bits, ACLs, LSM policy, seccomp, and capability checks — they fail differently and are fixed differently.

---

# 10. Debug with `strace`

When the cause is unclear, find the exact failing syscall:

```bash
strace -f -e trace=network,process ./application 2>&1 | grep -E 'EPERM|EACCES'
```

```text
socket(AF_PACKET, SOCK_RAW, ...) = -1 EPERM (Operation not permitted)
```

That one line names the operation (`AF_PACKET` raw socket) and therefore the missing capability (`CAP_NET_RAW`). Watch especially for `EPERM`/`EACCES` returns on `socket()`, `bind()`, `mount()`, `ptrace()`, `setuid()`, and the capability syscalls `capset()`/`capget()`/`prctl()`. Letting `strace` tell you which capability is needed is far more reliable than guessing and granting broadly.

---

# 11. Common Mistakes

- **Granting `CAP_SYS_ADMIN`** as a universal fix — almost always the wrong tool.
- **Running everything as root** out of habit rather than need.
- **Forgetting Ambient capabilities** — they propagate across ordinary `execve()` and can leak privilege into child programs unexpectedly.
- **Ignoring open file descriptors** — dropping a capability does not close resources already opened while it was held.
- **Trusting UID alone** — always inspect the complete credential state, not just whether the process is "root."

---

# 12. Best Practices

**Follow least privilege.** Grant only the capabilities a failing syscall proves are required.

**Drop capabilities early.** If a capability is only needed during initialization, remove it immediately afterward.

**Reduce the Bounding set.** Prevent future privilege acquisition wherever a service will never need more.

**Keep Ambient empty.** Use ambient capabilities only when a launcher genuinely must pass one through an ordinary exec.

**Avoid programmable binaries.** Do not grant powerful capabilities to Python, Perl, Ruby, Bash, editors, or archive tools unless truly unavoidable — they turn a narrow grant into arbitrary privileged execution.

**Combine multiple layers.** Capabilities should work alongside seccomp, SELinux/AppArmor, namespaces, read-only filesystems, non-root execution, and minimal images.

---

# 13. Production Audit Checklist

- [ ] Runs as a non-root user whenever possible.
- [ ] Only required capabilities are granted (confirmed via `strace`, not assumption).
- [ ] Bounding set is minimized.
- [ ] Ambient capabilities are justified and documented.
- [ ] No unexpected file capabilities exist (`getcap -r /`).
- [ ] `NoNewPrivileges` is enabled where appropriate.
- [ ] Container is not started with `--privileged`.
- [ ] `CAP_SYS_ADMIN` is avoided unless technically unavoidable.
- [ ] Service has been tested *after* privilege reduction.
- [ ] Capability assignments are documented in change control.

---

# Quick Troubleshooting Flow

```text
Operation fails
      |
      v
strace -> identify the failing syscall and errno
      |
      v
Inspect process capabilities (/proc/PID/status)
      |
      v
Check NoNewPrivs  and  nosuid mount
      |
      v
Inspect file capabilities (getcap)
      |
      v
Check the Bounding set
      |
      v
Check the namespace context
      |
      v
Review LSM / seccomp / filesystem permissions
```

---

# Summary

Capability problems are rarely caused by a single setting. Successful troubleshooting means examining process credentials, file capabilities, the bounding set, ambient capabilities, namespace context, service-manager and container configuration, LSM policy, seccomp, and traditional UNIX permissions — usually in that order, starting from the running process and the failing syscall.

The strongest security posture is not achieved by granting more privilege when something fails, but by understanding precisely *why* a privilege is required in the first place — and granting only that.
