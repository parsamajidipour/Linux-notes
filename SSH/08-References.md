# Chapter 08: References

This chapter consolidates the primary sources and tool invocations used throughout the series, organized for lookup rather than narrative reading. Each entry notes where in the series it was introduced and why it mattered there.

## 8.1 Primary RFCs

**RFC 4251 — The Secure Shell (SSH) Protocol Architecture.**
The umbrella document defining the three-layer model. Introduced in Chapter 02, Section 2.1 as the conceptual frame for the entire series; referenced again in Chapter 01, Section 1.2 for the SSH-1/SSH-2 distinction.

**RFC 4252 — The Secure Shell (SSH) Authentication Protocol.**
Defines the `SSH_MSG_USERAUTH_*` message family, the `none`-method reconnaissance behavior, and the `partial success` mechanism underlying multi-factor chaining. Core source for Chapter 03 in full; Section 7 of this RFC specifically defines the exact byte string signed in public-key authentication (Chapter 03, Section 3.3.1); Section 8 covers password authentication (Chapter 03, Section 3.5).

**RFC 4253 — The Secure Shell (SSH) Transport Layer Protocol.**
Defines version-string exchange, `KEXINIT` negotiation, key exchange and the six-key derivation, and host key verification. Core source for Chapter 02, Section 2.3 in full; Section 7.2 specifically defines the exchange hash `H` and key derivation (Chapter 02, Section 2.3.4).

**RFC 4254 — The Secure Shell (SSH) Connection Protocol.**
Defines channel types, the channel open/confirm/failure message flow, window-based flow control, and channel requests (`pty-req`, `shell`, `exec`, `subsystem`). Core source for Chapter 02, Section 2.5 and, by extension, all of Chapter 05's forwarding mechanisms, which are instances of this RFC's channel model.

**RFC 4256 — Generic Message Exchange Authentication for the Secure Shell Protocol (SSH).**
Defines `keyboard-interactive` as a generic, server-driven challenge-response protocol, distinct in structure from the single-field `password` method. Source for Chapter 03, Section 3.4's distinction, and the basis for the `AuthenticationMethods` MFA-chaining discussion in Chapter 04, Section 4.3.1.

## 8.2 Man Pages Referenced

| Page | Covers | First referenced |
|---|---|---|
| `man ssh` | Client invocation, `-L`/`-R`/`-D`/`-X`/`-Y` flags | Ch. 02, §2.6; Ch. 05 throughout |
| `man ssh_config` | Client-side directives, `Host`/`Match` blocks | Ch. 04, §4.2.2, §4.6 |
| `man sshd_config` | Server-side directives, `Match` block permitted keywords | Ch. 04 throughout; Ch. 06 throughout |
| `man sshd` | Daemon invocation, `-d`/`-t`/`-T` flags | Ch. 02, §2.6; Ch. 04, §4.8 |
| `man ssh-keygen` | Key generation, `-s` certificate signing, `-l` fingerprinting, `-R` known_hosts removal | Ch. 03, §3.3.3, §3.3.5; Ch. 07, §7.3.2 |
| `man ssh-keyscan` | Host key retrieval without a full connection | Ch. 02, §2.3.5 |
| `man authorized_keys` (within `sshd` man page, `AUTHORIZED_KEYS FILE FORMAT` section) | Per-key restriction options (`command=`, `from=`, `no-port-forwarding`, etc.) | Ch. 04, §4.5 |

## 8.3 Diagnostic and Observation Commands, Indexed by Purpose

This index exists because the series' central discipline (Chapter 01, Section 1.5) is observation over assertion — every one of these was used at least once to verify a claim rather than assert it.

**Inspecting supported algorithms locally, without any network connection:**
```
ssh -Q kex          # key exchange algorithms — Ch. 02 §2.3.2
ssh -Q key          # public key / signature algorithms — Ch. 03 §3.3.3
```

**Watching a live handshake:**
```
ssh -vvv user@host              # client-side, all three layers — Ch. 02 §2.6; Ch. 03 §3.7; Ch. 05 §5.7
sudo sshd -ddd -p 2222          # server-side mirror of the same handshake — Ch. 02 §2.6; Ch. 07 §7.6
```

**Querying a host key without a full authenticated session:**
```
ssh-keyscan -t ed25519 target_host    # Ch. 02 §2.3.5
ssh-keygen -lf keyfile                # fingerprint of a local key or known_hosts entry — Ch. 07 §7.3.2
```

**Validating and inspecting server configuration before it takes effect:**
```
sudo sshd -t                                          # syntax check only — Ch. 04 §4.8
sudo sshd -T                                          # full effective config dump — Ch. 06 §6.2.3; Ch. 07 §7.4.2
sudo sshd -T -C user=U,host=H,addr=A                  # effective config for a specific Match context — Ch. 04 §4.8; Ch. 07 §7.4.2
```

**Generating and managing keys:**
```
ssh-keygen -t ed25519 -C "comment"                    # modern key generation — Ch. 03 §3.3.3
ssh-keygen -s ca-key -V +1d -n principal key.pub       # short-lived certificate signing — Ch. 06 §6.2.1
ssh-add -l                                             # list keys currently loaded in agent — Ch. 07 §7.4.1
ssh-keygen -R host -f ~/.ssh/known_hosts               # remove a stale/changed host entry — Ch. 07 §7.3.2
```

**Inspecting listening sockets (not SSH-specific, but used throughout for network-level confirmation):**
```
sudo ss -tlnp | grep sshd       # confirm the daemon is actually listening — Ch. 07 §7.3.1
ss -tlnp                        # confirm a local port-forward listener is bound — Ch. 07 §7.5.1
```

**Raw protocol observation below the SSH layer itself:**
```
nc target_host 22               # observe the plaintext version-string exchange directly — Ch. 02 §2.3.1
```

## 8.4 Key `ssh_config` / `sshd_config` Directives, Indexed by Concern

| Concern | Directive(s) | Chapter |
|---|---|---|
| Method availability | `PubkeyAuthentication`, `PasswordAuthentication`, `KeyboardInteractiveAuthentication` | Ch. 04 §4.3 |
| MFA / method chaining | `AuthenticationMethods` | Ch. 04 §4.3.1; Ch. 06 §6.2.3 |
| Conditional policy | `Match User` / `Match Address` / `Match Group` | Ch. 04 §4.4 |
| Forced command / authorization scoping | `ForceCommand` | Ch. 04 §4.4; Ch. 06 §6.5 |
| Root login policy | `PermitRootLogin` | Ch. 04 §4.7; Ch. 06 §6.2.4 |
| Guessing / resource-exhaustion mitigation | `MaxAuthTries`, `LoginGraceTime` | Ch. 04 §4.7; Ch. 06 §6.3 |
| Idle session handling | `ClientAliveInterval`, `ClientAliveCountMax` | Ch. 04 §4.7 |
| Algorithm floor (downgrade mitigation) | `KexAlgorithms`, `Ciphers`, `MACs`, `HostKeyAlgorithms` | Ch. 06 §6.4 |
| Remote-forward exposure | `GatewayPorts` | Ch. 05 §5.4; Ch. 07 §7.5.1 |
| Host-key DNS verification | `VerifyHostKeyDNS` | Ch. 06 §6.2.2 |
| Bastion routing (client-side) | `ProxyJump` | Ch. 04 §4.6.1 |
| Explicit key selection (client-side) | `IdentityFile`, `IdentitiesOnly` | Ch. 04 §4.6.2; Ch. 07 §7.4.1 |
| Connection reuse (client-side) | `ControlMaster`, `ControlPath`, `ControlPersist` | Ch. 04 §4.6.3 |

## 8.5 A Note on Using This Chapter

This reference is deliberately not a substitute for the earlier chapters — every entry above is a pointer back into a specific mechanism explained in depth elsewhere in the series, not a standalone definition. Where a directive or command's *behavior* is in question, the man page is authoritative; where its *purpose within a broader design* is in question, the cross-referenced chapter section is the place to return to. This mirrors the series' founding methodological commitment from Chapter 01, Section 1.5: primary sources for what a mechanism does, reasoned architecture for why it exists.

---

*This closes the series. The eight chapters, taken together, trace one continuous argument: three independently-motivated security properties (Chapter 01) require three architecturally separate protocol layers (Chapter 02); those layers are configured, not merely described, through specific directives (Chapter 04) built on specific authentication mechanisms (Chapter 03) and specific channel semantics (Chapter 05); a defensible security posture (Chapter 06) is what falls out of applying the threat model rigorously against that architecture, not an independent checklist; and diagnosing failure (Chapter 07) is the same layer-first reasoning run in reverse.*
