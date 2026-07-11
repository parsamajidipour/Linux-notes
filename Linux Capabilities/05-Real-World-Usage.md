# Real-World Usage

Linux Capabilities become truly valuable when viewed outside of kernel theory.

Modern Linux systems rarely grant unrestricted root access to long-running services. Instead, services are designed around the Principle of Least Privilege and receive only the capabilities required to complete their tasks. This chapter walks through how capabilities appear in software you almost certainly already run, with the actual commands and output you would see on a real system.

---

# 1. Web Servers

A web server such as Nginx or Apache typically needs to listen on TCP ports 80 or 443. Historically, this required root because ports below 1024 are privileged.

Instead of keeping the server permanently privileged, grant only the one capability that binding needs:

```bash
sudo setcap cap_net_bind_service=+ep /usr/sbin/nginx
getcap /usr/sbin/nginx
```

```text
/usr/sbin/nginx cap_net_bind_service=ep
```

Now the binary can bind privileged ports without running as full root. In practice the cleaner approach is to let the service manager grant the capability at launch rather than stamping it onto the binary (covered in section 4), because a file capability applies to *every* invocation of that binary, not just the service.

Benefits:

- Smaller attack surface — a compromise yields one capability, not root
- No privilege-dropping code that can be gotten wrong
- Easier auditing (`getcap` shows exactly what the binary may do)
- Compliance with least privilege

---

# 2. ping

Older Linux distributions shipped `ping` as a SUID-root executable. That meant any memory-corruption bug in `ping` executed with full root privileges — a poor trade for a diagnostic tool.

Modern systems generally assign a single capability instead:

```bash
getcap /usr/bin/ping
```

```text
/usr/bin/ping cap_net_raw=ep
```

`CAP_NET_RAW` grants the ability to open raw sockets (needed to craft ICMP echo requests) and nothing else. A flaw in `ping` now yields raw-socket access, not a root shell. On some distributions `ping` uses the `ping_group_range` sysctl instead and carries no capability at all — worth checking before assuming.

---

# 3. tcpdump

Packet capture requires raw socket access, and interface manipulation may require network administration:

```bash
sudo setcap cap_net_raw,cap_net_admin=ep /usr/sbin/tcpdump
getcap /usr/sbin/tcpdump
```

```text
/usr/sbin/tcpdump cap_net_raw,cap_net_admin=ep
```

This grants only the networking privileges needed rather than full root. Note a real security caveat: packet capture can expose credentials, session tokens, and sensitive traffic. Even a narrowly scoped capability deserves review — `CAP_NET_RAW` on a shared host is not harmless, because it lets a process sniff traffic it should never see. Many distributions instead put analysts in a `wireshark`/`pcap` group and set the capability on `dumpcap`, keeping raw capture behind group membership.

---

# 4. systemd

systemd integrates capabilities directly into unit files, and this is usually the right place to manage them — no file capability, applied only to this service:

```ini
[Service]
User=www-data
ExecStart=/usr/sbin/nginx -g "daemon off;"
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
```

Here the service runs as an unprivileged user, only one capability is ever available, and privilege escalation through `execve()` is blocked. The `AmbientCapabilities=` line is what actually delivers the capability to a non-root process across exec — without it, a non-root service would hold nothing.

Verify the running result:

```bash
systemctl show nginx -p CapabilityBoundingSet -p AmbientCapabilities -p NoNewPrivileges
```

```text
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
```

To drop *all* capabilities from a service that needs none, set an empty bounding set:

```ini
CapabilityBoundingSet=
```

---

# 5. Docker

Containers are often described as "isolated root." This is misleading. By default Docker does **not** give a container full root — it starts the container with a reduced set and drops everything else before your process runs.

The default retained set is roughly these fourteen capabilities:

```text
CHOWN            DAC_OVERRIDE     FOWNER          FSETID
KILL             SETGID           SETUID          SETPCAP
NET_BIND_SERVICE NET_RAW          SYS_CHROOT      MKNOD
AUDIT_WRITE      SETFCAP
```

Inspect what a container actually holds:

```bash
docker run --rm alpine sh -c 'apk add -q libcap; capsh --print' | grep Current
```

Add or remove individual capabilities rather than reaching for full privilege:

```bash
docker run --cap-add=NET_ADMIN ...     # grant one extra capability
docker run --cap-drop=NET_RAW ...      # remove one from the default set
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE ...   # start from nothing
```

The `--privileged` flag effectively restores a broad set of kernel privileges (and disables other protections). It should be treated as a last resort, not a troubleshooting shortcut — most "`--privileged` fixed it" situations are solved by adding one specific capability.

---

# 6. Kubernetes

Kubernetes exposes capabilities through the container `securityContext`:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
```

The secure baseline is a two-step pattern:

1. **Drop `ALL`** capabilities.
2. **Add back** only what the workload genuinely requires.

Pairing this with `allowPrivilegeEscalation: false` (which sets `no_new_privs`) and `runAsNonRoot: true` closes the most common escalation paths. The Kubernetes "restricted" Pod Security Standard enforces exactly this shape, which is why dropping `ALL` is the expected default in hardened clusters.

---

# 7. Rootless Containers

Rootless Docker and Podman rely heavily on **user namespaces**. Inside the container a process may appear to be UID 0, while that UID 0 is mapped to an ordinary unprivileged UID on the host:

```bash
cat /proc/self/uid_map
```

```text
         0      100000      65536
```

This mapping means "UID 0 inside maps to host UID 100000." Capabilities held inside the container are scoped to the container's user namespace, so "root inside the container" carries no authority over host-owned resources. A process can hold `CAP_NET_ADMIN` in its own namespace and still be unable to touch the host's interfaces, because the host network is owned by a namespace it has no power over. This single distinction is why rootless containers are a meaningful security improvement.

---

# 8. Security Auditing

During a review — offensive or defensive — enumerate file capabilities across the filesystem:

```bash
getcap -r / 2>/dev/null
```

```text
/usr/bin/ping cap_net_raw=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/sbin/tcpdump cap_net_raw,cap_net_admin=ep
```

Pay particular attention to interpreters and highly programmable tools. A capability on `python`, `perl`, `ruby`, `bash`, or a similar general-purpose binary is an immediate privilege-escalation primitive, because the attacker fully controls what the capable process does. Binaries carrying any of the following deserve manual investigation:

- `CAP_SYS_ADMIN`
- `CAP_SETUID` / `CAP_SETGID`
- `CAP_DAC_OVERRIDE` / `CAP_DAC_READ_SEARCH`
- `CAP_SYS_PTRACE`
- `CAP_SYS_MODULE`

A single unexpected line in `getcap -r /` output has been the whole finding in more than one privilege-escalation report.

---

# 9. CI/CD and Build Systems

Modern CI runners often execute as non-root users, which raises real capability questions: building container images, mounting overlay filesystems, or configuring networking may each need a specific capability. The right move is to grant that one capability to the helper responsible for it — not to run the whole pipeline privileged.

Rootless build tools such as Buildah and Kaniko exist precisely to avoid `--privileged` build agents. Reducing privilege here matters because a compromised pipeline typically has broad reach into source, secrets, and deployment credentials; limiting what its build steps can do to the host contains that reach.

---

# 10. VPN and Networking Software

Software such as VPN clients, routing daemons, and network-management agents frequently and legitimately requires:

- `CAP_NET_ADMIN` — to create tunnel interfaces, set routes, manage the firewall
- `CAP_NET_RAW` — to send and receive crafted packets

These are appropriate grants for this class of software. The anti-pattern is reaching for `CAP_SYS_ADMIN` "because it works" when a narrower networking capability would do. `CAP_SYS_ADMIN` is a near-root grant; using it to fix a networking problem trades a precise privilege for an enormous one.

---

# 11. Common Anti-Patterns

Avoid these, all of which quietly recreate the problems capabilities were meant to solve:

- Running every service as root out of habit
- Using `--privileged` containers by default or as a debugging crutch
- Assigning `CAP_SYS_ADMIN` when a narrower capability exists
- Forgetting to review file capabilities after installing software
- Granting capabilities to general-purpose interpreters
- Adding capabilities during troubleshooting and never removing them

---

# 12. Practical Checklist

Before deploying a service, ask:

- Does it really need root, or just one capability?
- Which capability is *actually* required? (Confirm with `strace`, not guesswork.)
- Can the capability be dropped after initialization?
- Can the Bounding set be reduced to that one capability?
- Should `NoNewPrivileges=yes` be enabled?
- Are namespaces, seccomp, and an LSM also restricting the process?

Capabilities are only one layer of Linux security. The strongest deployments combine them with namespaces, seccomp, AppArmor or SELinux, read-only filesystems, and minimal container images.

---

# Summary

Linux Capabilities are not an academic kernel feature. They are used every day by web servers, container runtimes, packet analyzers, service managers, orchestration platforms, and cloud infrastructure.

Correctly applied, they replace unnecessary root privileges with narrowly scoped permissions — reducing both attack surface and the impact of compromise while preserving the functionality each service genuinely needs.
