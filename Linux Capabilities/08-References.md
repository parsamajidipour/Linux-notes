# References

This guide is based on the design of the Linux kernel, its official documentation, the manual pages, and long-standing community resources.

The goal of this section is not simply to list links, but to identify the authoritative sources that explain how Linux Capabilities are designed, implemented, and used — and to say *what each source is good for*, so you can go directly to the right one for the question you have.

---

# Official Kernel Documentation

The Linux kernel documentation is the primary reference whenever you are researching capability *behavior*. When a secondary source disagrees with the kernel, the kernel wins.

Relevant areas of `Documentation/` and the tree include:

- **Credentials** — how `struct cred` represents identity and privilege.
- **User namespaces** — how capabilities are scoped, and why container-root differs from host-root.
- **VFS / filesystems** — how the `security.capability` xattr is stored and read.
- **Security modules (LSM)** — how capability checks interact with SELinux, AppArmor, and the default `commoncap` logic.
- **Process management** — how credentials are recalculated across `fork()` and `execve()`.

---

# Manual Pages

Linux capabilities are documented thoroughly by the man-pages project. These are the fastest authoritative answer for API and semantics questions:

| Page | What it covers |
|---|---|
| `man 7 capabilities` | The definitive overview: every set, the `execve()` transformation, file capabilities, ambient rules |
| `man 2 capget` / `man 2 capset` | The raw syscalls for reading and setting capability sets |
| `man 2 prctl` | `PR_CAP_AMBIENT`, `PR_SET_NO_NEW_PRIVS`, `PR_SET_SECUREBITS`, and related controls |
| `man 2 execve` | How credentials and capabilities change on program execution |
| `man 7 user_namespaces` | How capabilities behave inside nested user namespaces |
| `man 7 credentials` | The full UNIX credential model capabilities extend |
| `man 7 namespaces` | The namespace types and how privilege maps across them |
| `man 5 proc` | The `/proc/<PID>/status` `Cap*` fields and their meaning |
| `man 2 setuid` / `man 2 setresuid` | UID transitions and their interaction with capabilities |
| `man 3 cap_from_text` | libcap's capability text format (`cap_net_raw=ep`, etc.) |

Of these, `man 7 capabilities` is the single most important document in the entire topic. If you read only one reference, read that one.

---

# libcap

The official userspace library and toolset for Linux Capabilities. The command-line tools are what you will use daily:

| Tool | Purpose |
|---|---|
| `capsh` | Explore capability state, decode masks (`--decode=`), print current caps (`--print`) |
| `getcap` | Read file capabilities (`getcap -r /` to scan) |
| `setcap` | Set or remove file capabilities |
| `getpcaps` | Read the capabilities of a running process by PID |

Reading the libcap source is an excellent way to see exactly how capability manipulation is performed from userspace, and how the text format maps onto the kernel's bitmasks.

---

# Kernel Source Files

For implementation-level questions, these files are where the real answers live:

| File | What it reveals |
|---|---|
| `include/uapi/linux/capability.h` | The canonical list of capability numbers and `CAP_LAST_CAP` |
| `include/linux/cred.h` | The `struct cred` definition — where the capability sets physically live |
| `kernel/cred.c` | How credentials are prepared, committed, and reference-counted |
| `security/commoncap.c` | The default capability logic: `cap_capable()` and the `execve()` transformation |
| `security/security.c` | The LSM dispatch layer that routes `security_capable()` |
| `fs/exec.c` | The `execve()` path where credentials are recalculated |
| `kernel/sys.c` | `prctl()` handling, including ambient and securebits operations |

Reading `security/commoncap.c` alongside `man 7 capabilities` is the fastest way to turn the prose model into a precise, code-level understanding — the transformation formula in the man page maps almost line-for-line onto this file.

---

# Community and Long-Form Resources

**LWN.net** has published extensive, high-quality coverage of capabilities, user namespaces, credential management, and container security over many years. Its strength is *explaining why* a kernel change was made, which makes it an ideal companion to the reference documentation. Search its archives for the specific mechanism you are studying (ambient capabilities, user namespaces, `no_new_privs`) rather than relying on any single article.

For container-specific behavior, the **OCI Runtime Specification** and the documentation of Docker, Podman, and Kubernetes describe how each platform maps capabilities onto its own configuration surface.

---

# Books

| Book | Author(s) | Why it helps |
|---|---|---|
| *The Linux Programming Interface* | Michael Kerrisk | The clearest book-length treatment of capabilities and the credential model (Kerrisk also maintains the man-pages) |
| *Understanding the Linux Kernel* | Bovet & Cesati | Background on process credentials and kernel authorization |
| *Linux Kernel Development* | Robert Love | A readable introduction to kernel subsystems and the process model |
| *Container Security* | Liz Rice | How capabilities, namespaces, and seccomp combine into container isolation |
| *Linux Device Drivers* | Corbet, Rubini, Kroah-Hartman | Useful when a capability question touches device access |

For the capability model specifically, *The Linux Programming Interface* is the standout — its chapter on capabilities is effectively an extended, worked version of `man 7 capabilities`.

---

# Related Security Technologies

Capabilities never operate alone. To understand real systems, study how they interact with:

- **seccomp** — syscall-level filtering that can block operations a capability would otherwise allow
- **SELinux** / **AppArmor** — mandatory access control that runs *in addition to* capability checks
- **User namespaces** — the scoping mechanism that makes container-root safe
- **systemd** — the service manager's `CapabilityBoundingSet=`, `AmbientCapabilities=`, and `NoNewPrivileges=` directives
- **Docker / Kubernetes / OCI** — how orchestration platforms express capability policy

Together these form the modern Linux privilege model; capabilities are one layer within it.

---

# Suggested Reading Order

**If you are new to the topic:**

1. `man 7 capabilities`
2. *The Linux Programming Interface* — the capabilities chapter
3. Kernel documentation on credentials and user namespaces
4. libcap tools (`capsh`, `getcap`, `setcap`) — hands-on
5. `security/commoncap.c` — to connect prose to code

**If you are doing security research:**

1. `security/commoncap.c` — the transformation and check logic
2. `kernel/cred.c` and `include/linux/cred.h`
3. The `execve()` path in `fs/exec.c`
4. Container runtime source (runc / crun) for how caps are applied at container start
5. Published escalation techniques for specific capabilities, to understand real-world impact

---

# Final Thoughts

Linux Capabilities are not an isolated feature. They sit at the intersection of process credentials, user namespaces, `execve()`, containers, service managers, Linux Security Modules, and kernel authorization. A complete understanding comes only from studying these systems together rather than in isolation.

Whenever secondary sources disagree with implementation details, the Linux kernel source and its official documentation should always take precedence.
