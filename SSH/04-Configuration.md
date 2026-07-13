# Chapter 04: Configuration

## 4.1 Where This Chapter Picks Up

Chapters 02 and 03 established mechanism: what the protocol does and why. This chapter establishes how that mechanism becomes enforced policy on a real system. The central claim worth stating up front, because it reframes how to read everything that follows: **`sshd_config` and `ssh_config` are not two halves of one configuration file — they configure two different endpoints of an asymmetric relationship, and confusing which directive belongs to which side is one of the most common sources of "my config isn't doing anything" confusion.**

`ssh_config` (client-side, either globally in `/etc/ssh/ssh_config` or per-user in `~/.ssh/config`) governs what the client *proposes and prefers* when initiating a connection. `sshd_config` (server-side, `/etc/ssh/sshd_config`) governs what the server *permits and enforces*. A client preference can always be overridden by server policy — if `sshd_config` forbids password authentication, no client-side configuration can make it work. This asymmetry matters because it tells you, for any given security requirement, which file actually needs to carry the guarantee: enforcement belongs on the server; convenience belongs on the client.

## 4.2 Configuration File Structure and Precedence

Both `ssh_config` and `sshd_config` share a directive syntax (`Keyword value`, one per line, `#` for comments) but differ meaningfully in how precedence works — and this difference is a frequent source of misconfiguration.

### 4.2.1 `sshd_config`: First Match Wins, Globally

`sshd_config` is read top to bottom. For any given directive, the **first** occurrence encountered applies globally, unless it appears inside a `Match` block (Section 4.4), in which case it applies only when that block's condition holds for the connecting session. This "first match wins" behavior is the opposite of what many administrators intuitively expect from a config file, and it has a direct practical consequence: general directives should be placed *before* any `Match` blocks, because a `Match` block's directive, once matched, cannot be overridden by a later global directive appearing further down the file — the block already had its chance to set the value and any subsequent line for that same keyword outside a matching block is simply ignored for that keyword.

### 4.2.2 `ssh_config`: First Match Also Wins, but Per-Host

The client-side file has the same "first obtained value wins" rule, but its primary organizing mechanism is `Host` (and, since OpenSSH 7.3, `Match`) blocks — sections that apply only when the target hostname matches a pattern. Because the file is still read top to bottom and first match wins, **specific `Host` blocks must precede general ones** for the specific values to take effect; a general `Host *` block placed first would "win" every directive before a more specific block further down ever gets a chance.

```
Host jump
    HostName bastion.example.org
    User admin
    IdentityFile ~/.ssh/id_ed25519_bastion

Host *
    ServerAliveInterval 60
    AddKeysToAgent yes
```

Here, connecting to `ssh jump` picks up the specific block's `HostName`, `User`, and `IdentityFile`, and *also* inherits `ServerAliveInterval` and `AddKeysToAgent` from the `Host *` block below it — because those two keywords were never set by the specific block, the general block's values are the first (and only) ones encountered for them. This inheritance behavior — specific blocks don't need to repeat what a later general block already provides — is what makes `Host *` a practical place for defaults rather than a redundant catch-all.

## 4.3 The Method-Ordering Directives, Mapped to Chapter 03's Mechanism

Chapter 03 described the authentication layer's method negotiation abstractly. Here is exactly which directives control it:

```
PubkeyAuthentication yes
PasswordAuthentication no
KeyboardInteractiveAuthentication no
```

Recall from Chapter 03, Section 3.4 the specific misconfiguration this section exists to prevent: setting `PasswordAuthentication no` while leaving `KeyboardInteractiveAuthentication` at its default (commonly `yes`) does **not** disable password-equivalent login if the PAM stack backing `keyboard-interactive` itself falls through to password verification (which, on many default Linux PAM configurations, it does via `pam_unix`). This is not a hypothetical edge case — it is the single most common reason an administrator believes password authentication is disabled when it structurally is not. The correct hardening posture, absent a deliberate MFA setup that legitimately needs `keyboard-interactive`, is to disable both explicitly, or to constrain what `keyboard-interactive` is permitted to do via `AuthenticationMethods` (Section 4.3.1) rather than leaving it as an unconstrained fallback.

### 4.3.1 `AuthenticationMethods`: Configuring Chapter 03's Partial-Success Chaining

This directive is the direct configuration surface for the `partial success` mechanism described in Chapter 03, Section 3.2.1:

```
AuthenticationMethods publickey,keyboard-interactive
```

This does not mean "accept either publickey or keyboard-interactive" — the comma here means sequential composition, not alternation. It requires a client to complete `publickey` authentication successfully **and then** complete a subsequent `keyboard-interactive` exchange (typically backed by a PAM module prompting for a TOTP code) before `SSH_MSG_USERAUTH_SUCCESS` is ever sent. This is genuine multi-factor authentication enforced at the protocol level, not merely at the shell or application level — an attacker who somehow obtains the private key still cannot complete authentication without the second factor, and vice versa.

Multiple alternative chains can be specified, space-separated, each comma-joined internally:

```
AuthenticationMethods publickey,keyboard-interactive publickey,password
```

This permits either chain to independently satisfy the requirement — the server accepts the first fully-completed chain a client manages to walk.

## 4.4 `Match` Blocks: Conditional Policy Without Duplicate Files

A frequent operational need is applying a different policy to a subset of connections — a specific user, a specific source network, a specific group — without maintaining an entirely separate `sshd_config`. `Match` blocks solve this directly:

```
Match User backup-agent
    PasswordAuthentication no
    AuthenticationMethods publickey
    ForceCommand /usr/local/bin/backup-only.sh

Match Address 10.0.0.0/8
    PermitRootLogin no

Match Group admins
    AuthenticationMethods publickey,keyboard-interactive
```

Match criteria can combine (`Match User deploy Address 10.0.0.0/8` requires both), and everything from the `Match` line until the next `Match` line or end of file belongs to that block. Only a specific, restricted subset of directives is permitted inside a `Match` block (this is intentional — `sshd_config` does not allow, for instance, changing `Port` conditionally, since the listening socket is established before any connection-specific matching could occur); consult `man sshd_config` for the exact permitted list, since it has grown across OpenSSH versions.

The `ForceCommand` directive in the example above is worth connecting back to Chapter 01, Section 1.3.3's distinction between authentication and authorization: successfully authenticating as `backup-agent` proves identity, but `ForceCommand` is what constrains what that identity is subsequently *permitted to do* — regardless of what shell command the client actually requested (Chapter 02, Section 2.5.4), the server substitutes the forced command instead. This is authorization policy, enforced entirely server-side, independent of and in addition to whatever authentication method succeeded.

## 4.5 Per-Key Restrictions in `authorized_keys`

Chapter 03, Section 3.6 mentioned that `authorized_keys` supports restriction options without detailing them. The full mechanism: each line in `authorized_keys` can be prefixed with comma-separated options before the key type and key material:

```
command="/usr/local/bin/rsync-wrapper.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,from="203.0.113.0/24" ssh-ed25519 AAAA... deploy-key
```

Reading this precisely: this specific key, even if it authenticates successfully, is only accepted from source addresses in `203.0.113.0/24` (`from=`); regardless of what command the client requests, the server runs `rsync-wrapper.sh` instead (`command=`, functioning identically to `ForceCommand` but scoped to this one key rather than a whole `Match` block); and the key is barred from opening any of the connection-layer channel types covered in Chapter 02, Section 2.5.2 for port forwarding, X11, or agent forwarding, regardless of what the client attempts to request when opening those channel types.

This is a materially finer-grained authorization mechanism than anything achievable via `Match` blocks alone, because it's bound to the specific credential rather than to the authenticated identity generally — the same user account can hold one unrestricted key for interactive login and one heavily restricted key (distributed to an automated system) that can do nothing but run one fixed command from one fixed network range. This pattern — one identity, multiple keys with different privilege scopes attached directly to each key — is the practical mechanism Chapter 06 builds on when discussing least-privilege access design for automation and service accounts.

## 4.6 The Client Side: `ssh_config` for Real Multi-Host Operational Complexity

### 4.6.1 `ProxyJump`: Structural Support for Bastion Architectures

Environments where hosts are only reachable via an intermediate jump host (a bastion) used to require manual `ProxyCommand` invocations of `nc` or `ssh -W`. OpenSSH 7.3 introduced a direct, first-class directive:

```
Host internal-db
    HostName 10.0.5.20
    User dbadmin
    ProxyJump bastion.example.org
```

Architecturally, `ProxyJump` establishes a full SSH connection to the jump host first, then opens a `direct-tcpip` channel (Chapter 02, Section 2.5.2) through that already-authenticated session to reach the final target's port 22, and layers a second, independent, fully end-to-end-encrypted SSH session on top of that channel to the actual destination. It's worth being precise about what this means for the trust model: the bastion host can see that a connection is being relayed through it and to where, but — because the second SSH session is itself independently negotiated, authenticated, and encrypted between the client and the final destination — the bastion does not see the content of the inner session, and a compromised bastion does not, by itself, expose the inner session's traffic. It can, however, observe connection metadata (Chapter 01, Section 1.3.2) for every hop it relays.

### 4.6.2 `IdentityFile` and `IdentitiesOnly`: Controlling Which Key Gets Offered

Recall from Chapter 03, Section 3.7 that OpenSSH probes candidate keys before signing. By default, if an `ssh-agent` is running, the client will attempt every key loaded in the agent, in the order the agent holds them, before falling back to keys listed via `IdentityFile`. In environments with many loaded keys, this can cause a server enforcing connection or authentication attempt limits (`MaxAuthTries`, discussed below) to reject the connection before the intended key is ever tried. `IdentitiesOnly yes`, paired with an explicit `IdentityFile`, restricts the client to offering only the specified key(s), bypassing agent enumeration entirely:

```
Host production
    HostName prod.example.org
    IdentityFile ~/.ssh/id_ed25519_prod
    IdentitiesOnly yes
```

### 4.6.3 Connection Multiplexing: `ControlMaster`

A distinct performance and operational feature, worth understanding architecturally rather than as a black box: `ControlMaster` allows a single already-authenticated transport-layer connection (Chapter 02) to be reused for multiple subsequent logical SSH sessions to the same host, via a local Unix domain socket, entirely avoiding repeating the transport and authentication layer handshakes for each new session:

```
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 10m
```

Each new `ssh` invocation to the same host, while the control socket is alive, opens as a new *connection-layer channel* (Chapter 02, Section 2.5) multiplexed over the existing transport and authentication state, rather than performing a fresh key exchange and authentication cycle. This is a direct, practical illustration of exactly the layer independence argued for in Chapter 02, Section 2.1: because the connection layer's multiplexing is architecturally separate from the transport and authentication layers beneath it, reusing an already-established lower-layer session for new upper-layer channels is a natural extension of the architecture, not a bolted-on optimization.

## 4.7 Directives That Directly Reduce Attack Surface

A short set of directives worth flagging here because they connect directly to the threat model established in Chapter 01, Section 1.3, even though a full hardening treatment is deferred to Chapter 06:

```
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
```

`MaxAuthTries` bounds the number of authentication attempts (across all methods) permitted before the server terminates the connection — a direct mitigation against the online-guessing weakness of password authentication discussed in Chapter 03, Section 3.5, though it applies uniformly regardless of which method is being attempted. `LoginGraceTime` bounds how long an unauthenticated connection is permitted to remain open at all, closing off a class of resource-exhaustion behavior where an attacker opens many connections and simply never completes authentication. `ClientAliveInterval`/`ClientAliveCountMax` configure the server to probe for a still-responsive client and terminate sessions that have gone silent — relevant to session hygiene rather than authentication security per se, but a common component of a defensible configuration baseline. `PermitRootLogin no` removes root as an authenticatable username entirely, forcing privilege escalation to occur through a separately-authenticated, separately-logged `sudo` invocation instead — an authorization-layer control, in the sense of Chapter 01, Section 1.3.3, not an authentication-layer one.

## 4.8 Validating Configuration Before It Takes Effect

Consistent with the observation-over-assertion discipline (Chapter 01, Section 1.5), never reload `sshd` on a remote system without first validating syntax — a malformed `sshd_config` that fails to reload can leave you locked out with no working listener:

```
sudo sshd -t
```

This performs a full syntax and semantic check of the configuration file without binding to a socket or affecting the running daemon. For inspecting what a specific `Match` context actually resolves to — genuinely useful given how easily `Match` block precedence can produce a different effective configuration than the file's linear text suggests — OpenSSH provides:

```
sudo sshd -T -C user=deploy,host=client.example.org,addr=203.0.113.5
```

This prints the fully resolved, effective configuration as it would apply to a connection matching those specific criteria — the single most reliable way to confirm a `Match` block is actually producing the policy you intended, rather than reasoning about precedence by eye against a long file.

## 4.9 Summary and Bridge to Chapter 05

This chapter translated Chapters 02 and 03's protocol mechanism into enforceable configuration: the asymmetric division of responsibility between `ssh_config` and `sshd_config`; the first-match-wins precedence model that governs both, and why it inverts naive intuition about how config files usually behave; the exact directives (`PasswordAuthentication`, `KeyboardInteractiveAuthentication`, `AuthenticationMethods`) that configure Chapter 03's method negotiation and partial-success chaining; `Match` blocks and per-key `authorized_keys` restrictions as two different granularities of authorization policy layered on top of authentication; `ProxyJump` and `ControlMaster` as client-side features that are direct, practical consequences of the connection layer's architectural independence established in Chapter 02; and the validation tools (`sshd -t`, `sshd -T -C`) that make configuration changes verifiable rather than a matter of hoping the precedence rules were applied correctly by eye.

Chapter 05 takes up exactly the client-side and connection-layer material introduced briefly here — `ProxyJump` and the underlying `direct-tcpip` channel type — and develops it fully: local, remote, and dynamic port forwarding, precisely as channels in action (Chapter 02, Section 2.5.2) rather than as a separate feature bolted onto the protocol.
