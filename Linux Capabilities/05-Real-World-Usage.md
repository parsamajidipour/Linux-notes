# Real-World Usage

Linux Capabilities become truly valuable when viewed outside of kernel theory.

Modern Linux systems rarely grant unrestricted root access to long-running services.
Instead, services are designed around the Principle of Least Privilege and receive only
the capabilities required to complete their tasks.

This chapter explores how capabilities are used by real software and modern
infrastructure platforms.

---

# 1. Web Servers

A web server such as Nginx or Apache typically needs to listen on TCP ports 80 or 443.

Historically, this required root because ports below 1024 are privileged.

Instead of keeping the server permanently privileged, administrators can grant only:

```bash
sudo setcap cap_net_bind_service=+ep /usr/sbin/nginx
```

Now the binary can bind to privileged ports without running as full root.

Benefits:

- Smaller attack surface
- Reduced privilege escalation impact
- Easier auditing
- Compliance with least privilege

---

# 2. ping

Older Linux distributions shipped `ping` as a SUID-root executable.

That meant any memory corruption bug immediately executed with root privileges.

Modern systems generally assign:

```text
cap_net_raw=ep
```

The binary receives permission to create raw sockets and nothing more.

Verify:

```bash
getcap /usr/bin/ping
```

---

# 3. tcpdump

Packet capture requires raw socket access.

Instead of running tcpdump entirely as root:

```bash
sudo setcap cap_net_raw,cap_net_admin=ep /usr/sbin/tcpdump
```

This grants only the networking privileges needed.

Administrators should remember that packet capture may expose credentials and sensitive traffic, so even these capabilities deserve careful review.

---

# 4. systemd

systemd integrates deeply with Linux Capabilities.

Example:

```ini
[Service]
User=www-data
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
```

Here:

- the service does not run as root
- only one capability is available
- privilege escalation through execve() is restricted

systemd also supports dropping capabilities entirely through an empty
`CapabilityBoundingSet=`.

---

# 5. Docker

Containers are often described as "isolated root."

This is misleading.

By default Docker removes many dangerous capabilities before the container starts.

Inspect:

```bash
docker run --rm alpine capsh --print
```

Adding one capability:

```bash
docker run --cap-add=NET_ADMIN ...
```

Removing one:

```bash
docker run --cap-drop=NET_RAW ...
```

Granting `--privileged` effectively restores a broad set of kernel privileges and should be avoided unless absolutely necessary.

---

# 6. Kubernetes

Kubernetes exposes capabilities through the Pod Security Context.

Example:

```yaml
securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
```

A secure baseline is:

1. Drop every capability.
2. Add back only what the workload genuinely requires.

This pattern dramatically reduces container attack surface.

---

# 7. Rootless Containers

Rootless Docker and Podman rely heavily on user namespaces.

Inside the container a process may appear to be UID 0 while lacking authority over host resources.

Capabilities remain scoped to the container's user namespace.

This distinction explains why "root inside the container" is not equivalent to "root on the host."

---

# 8. Security Auditing

During security reviews, inspect:

```bash
getcap -r / 2>/dev/null
```

Pay particular attention to interpreters and highly programmable tools.

Examples deserving careful investigation include binaries carrying:

- CAP_SYS_ADMIN
- CAP_SETUID
- CAP_SETGID
- CAP_DAC_OVERRIDE
- CAP_SYS_PTRACE

A capability on Python, Perl, Bash, or another interpreter can become an immediate privilege-escalation primitive.

---

# 9. CI/CD and Build Systems

Modern CI runners often execute as non-root users.

Instead of granting full administrative access, specific capabilities may be assigned to helper binaries responsible for networking, image building, or diagnostics.

Reducing privileges limits the impact of compromised pipelines.

---

# 10. VPN and Networking Software

Software such as VPN clients, routing daemons and network management agents frequently requires:

- CAP_NET_ADMIN
- CAP_NET_RAW

Granting additional capabilities like CAP_SYS_ADMIN simply because "it works" is poor operational practice.

---

# 11. Common Anti-Patterns

Avoid these patterns:

- Running every service as root
- Using `--privileged` containers by default
- Assigning CAP_SYS_ADMIN when a narrower capability exists
- Forgetting to review file capabilities after software installation
- Granting capabilities to general-purpose interpreters

---

# 12. Practical Checklist

Before deploying a service ask:

- Does it really need root?
- Which capability is actually required?
- Can the capability be removed after initialization?
- Can the Bounding Set be reduced?
- Should `NoNewPrivileges=yes` be enabled?
- Are namespaces, seccomp and LSM policies also restricting the process?

Capabilities are only one layer of Linux security.
The strongest deployments combine them with namespaces, seccomp, AppArmor or SELinux, read-only filesystems and minimal container images.

---

# Summary

Linux Capabilities are not an academic kernel feature.

They are used every day by web servers, container runtimes, packet analyzers, service managers, orchestration platforms and cloud infrastructure.

Correctly applied, they replace unnecessary root privileges with narrowly scoped permissions, reducing both attack surface and the impact of compromise while preserving required functionality.
