# Chapter 03: Authentication

## 3.1 Where This Chapter Picks Up

Chapter 02, Section 2.4 established the architectural skeleton of the authentication layer: a simple state machine, running entirely inside the already-encrypted transport channel, in which the client proposes a method and the server accepts, rejects, or partially accepts while announcing what remains available. It also established one fact that everything in this chapter depends on: every authentication attempt is cryptographically bound to the **session identifier** — the exchange hash `H` fixed during the very first key exchange (Chapter 02, Section 2.3.4).

This chapter answers the question Chapter 02 deliberately deferred: *how, precisely, does each authentication method work, and why does the protocol's own structure make some of them stronger than others?*

## 3.2 The Authentication Protocol's Message Structure

RFC 4252 defines authentication as a request-response cycle using three core message types:

```
SSH_MSG_USERAUTH_REQUEST
SSH_MSG_USERAUTH_FAILURE
SSH_MSG_USERAUTH_SUCCESS
```

Every `SSH_MSG_USERAUTH_REQUEST` carries four fields regardless of method: the username being claimed, the name of the service being requested (almost always `ssh-connection`, i.e., "I intend to use the connection layer next"), the authentication method name (`publickey`, `password`, `keyboard-interactive`, `none`, ...), and then method-specific data that varies by which method is named.

A detail worth making explicit because it surprises people reading a packet capture for the first time: the very first authentication request a well-behaved client typically sends uses the method name `none`. This is not an attempt to skip authentication — it is a reconnaissance request, allowed precisely so the client can learn, from the resulting `SSH_MSG_USERAUTH_FAILURE`, which methods the server is willing to accept for that specific username, before wasting a round trip on a method the server won't permit. The failure message's payload includes exactly this: a comma-separated list of acceptable method names. This is what produces the familiar verbose-mode line:

```
debug1: Authentications that can continue: publickey,password
```

### 3.2.1 Partial Success and Method Chaining

A detail RFC 4252 supports but that default configurations rarely surface: `SSH_MSG_USERAUTH_FAILURE` includes a boolean field, `partial success`. A server can be configured (via `AuthenticationMethods` in OpenSSH) to require *multiple* methods to succeed in sequence before authentication is considered complete — for example, a valid public key **and** a subsequent one-time code via `keyboard-interactive`. Each intermediate success returns `SSH_MSG_USERAUTH_FAILURE` with `partial success = true` and an updated list of remaining required methods, rather than `SSH_MSG_USERAUTH_SUCCESS`. This mechanism is the protocol-level foundation for multi-factor SSH authentication, and it's worth understanding now because Chapter 04 configures it directly.

## 3.3 Public-Key Authentication

### 3.3.1 What Is Actually Being Proven

The property public-key authentication proves is precise, and stating it precisely matters: *the party on the other end of this specific transport-layer session possesses the private key corresponding to a public key it is presenting.* Nothing more, nothing less. Whether that public key *should* be trusted to grant access is a separate question, answered entirely by whether the server's `authorized_keys` file lists it — a point of policy, not cryptography.

The proof itself is a digital signature. When the client attempts `publickey` authentication, it constructs a signature over a specific, precisely defined byte string — not over arbitrary data, and this precision is the entire point. Per RFC 4252, Section 7, the signed data is the concatenation of:

- the session identifier (the exchange hash `H` from Chapter 02, Section 2.3.4)
- the message type byte for `SSH_MSG_USERAUTH_REQUEST`
- the username, service name, method name (`publickey`), and the public key blob itself

The client signs this construction with the private key and sends the signature as part of the request. The server, holding the corresponding public key (from `authorized_keys`), independently reconstructs the exact same byte string (it also knows the session identifier — it derived the same `H` during its own key exchange) and verifies the signature against it.

### 3.3.2 Why Binding to the Session Identifier Is the Whole Point

This is worth dwelling on precisely because it's easy to read past as an implementation detail when it is, in fact, the mechanism that makes the entire scheme secure against a specific class of attack.

Because the session identifier is unique to a single transport-layer session (freshly derived from an ephemeral key exchange, per Chapter 02, Section 2.3.4) and never repeats across sessions, a valid signature captured from one session — even by an attacker with full visibility into that session's authentication exchange — is cryptographically meaningless in any other session. This defeats **replay attacks**: an attacker cannot record a legitimate authentication exchange and later replay it against the same server, because the replayed signature would be over a session identifier that no longer matches the new session's freshly-derived `H`. Contrast this with a naive scheme that signed only the username and a nonce chosen by the server — such a scheme would need the server to track every nonce it has ever issued to prevent reuse; binding to the session identifier instead gets this property essentially for free, as a structural consequence of how the transport layer already works.

### 3.3.3 Key Types in Practice

OpenSSH 9.x supports several public-key algorithms; you can enumerate what your build supports directly:

```
ssh -Q key
```

The two you will encounter almost universally in current deployments:

**`ssh-ed25519`** — an EdDSA signature scheme over Curve25519, and the OpenSSH-recommended default for new keys since OpenSSH 6.5 (2014). Practical advantages over RSA: much shorter keys for equivalent security margin, deterministic signatures (no dependency on a secure random number generator at signing time, which removes an entire historical class of RSA/DSA implementation vulnerability caused by weak or reused per-signature randomness), and faster signing and verification.

**`rsa-sha2-256` / `rsa-sha2-512`** — RSA signatures, retained primarily for interoperability with older systems and hardware (e.g., some hardware security modules and legacy network devices) that don't yet support elliptic-curve schemes. Worth noting explicitly: the older `ssh-rsa` signature scheme, which used SHA-1, is disabled by default in OpenSSH 9.x for signature verification, specifically because of SHA-1's now well-documented collision weaknesses — this is exactly the kind of version-sensitive default flagged in Chapter 01, Section 1.4.

Generating a modern key:

```
ssh-keygen -t ed25519 -C "descriptive-comment"
```

### 3.3.4 The Private Key Never Leaves the Client — and Why That's the Actual Security Boundary

It is worth stating plainly what is, in practice, the single most consequential structural property of public-key authentication: at no point in the protocol does the private key — or any data computed from it other than the signature itself — cross the network. The server never possesses, receives, or needs to receive the private key. This means a server compromise does not, by itself, hand an attacker your private key (contrast this directly with password authentication, discussed in Section 3.5, where the server necessarily sees the password itself during verification, if only transiently).

The practical consequence: the security of public-key authentication reduces entirely to the security of the private key's storage on the client. This is precisely why `ssh-keygen` defaults to prompting for a passphrase to encrypt the private key file at rest, and why hardware-backed key storage (security keys via FIDO2, or platform-specific secure enclaves) represents a strictly stronger position than an unencrypted key file — the private key, in those schemes, never exists in plaintext form outside dedicated hardware even on the client itself.

### 3.3.5 Certificate-Based Authentication: Solving the Distribution Problem

Everything above describes authentication with a *raw* public key, which has a real operational limitation at scale: every server that should trust a given user needs that user's exact public key listed in its own `authorized_keys` file, and every client that should trust a given server needs that server's exact host key in its `known_hosts`. In an environment with many hosts and many users, this is an `O(hosts × users)` distribution problem, and it's exactly what makes the TOFU gap discussed in Chapter 01, Section 1.3.3 operationally common — administrators managing hundreds of hosts routinely find themselves training users to simply accept new host key prompts, quietly eroding the protection that mechanism was meant to provide.

OpenSSH's answer is **SSH certificates**, generated with `ssh-keygen -s`. Structurally, an SSH certificate is a public key plus a set of signed metadata — validity period, principal names it's valid for, and optional restrictions — all signed by a separate certificate authority (CA) keypair. Critically, this is authentication infrastructure than the transport layer's own trust mechanism, layered as policy on top: a host or user need only trust the CA's public key once, and every certificate that CA signs is automatically trusted without any further per-host or per-user key distribution. This converts an `O(hosts × users)` distribution problem into an `O(1)` trust anchor (the CA key) plus a certificate issuance workflow — a substantially different operational and security posture, and the direct structural fix for the TOFU gap. Chapter 06 covers CA-based deployment in operational detail; the point to establish here is *why* certificates exist, not merely that the flag is available.

## 3.4 `keyboard-interactive` and Multi-Factor Authentication

`keyboard-interactive` (RFC 4256) is frequently misunderstood as being synonymous with password authentication, because in its most common configuration it visually looks identical — a prompt appears, you type something, you press enter. Architecturally, it is not the same mechanism at all.

`password` authentication is a single, fixed request-response exchange with one field: the password. `keyboard-interactive`, by contrast, is a generic, server-driven challenge-response protocol: the server sends one or more named prompts, the client displays them and collects responses, and this can repeat across multiple rounds before the server issues a final accept or reject. Nothing in the protocol constrains what a "prompt" must be — it can be a static password prompt, a one-time-code prompt from a TOTP or hardware-token backend, a PAM-driven prompt chain, or a sequence of several different prompts in series. This is precisely why `keyboard-interactive` is the mechanism most commonly used to bolt PAM-based multi-factor authentication (e.g., a TOTP module) onto SSH: the protocol was designed from the start to support an open-ended, server-controlled conversation rather than one fixed field.

The practical corollary: disabling `PasswordAuthentication` in `sshd_config` without also disabling `KeyboardInteractiveAuthentication` (or ensuring its PAM backend doesn't fall through to password verification) is a common misconfiguration that leaves password-equivalent authentication reachable through a different named door — a concrete example of why understanding the protocol-level distinction, not just the configuration directive names, matters for actually securing a system. Chapter 06 returns to this exact misconfiguration pattern.

## 3.5 Password Authentication, and Why It's Architecturally Weaker — Not Just Less Convenient

It's worth being precise about *why* password authentication is weaker, in protocol terms, rather than simply asserting it as received wisdom.

`password` authentication (RFC 4252, Section 8) sends the password itself — as a UTF-8 string, inside the already-encrypted transport channel — to the server, which then verifies it against the system's own credential store (typically via PAM). Three structural properties follow directly from this:

**The server sees the plaintext password, even if only transiently.** This is a direct contrast with Section 3.3.4: public-key authentication never requires the server to possess or handle the secret; password authentication structurally requires exactly that, every single time. A compromised or malicious server — or a compromised PAM module on an otherwise legitimate server — can trivially log every password it receives. This is not a hypothetical; it is a standard technique in `sshd` honeypot deployments used for exactly this kind of credential harvesting research.

**The secret is human-chosen, not cryptographically generated.** A private key's effective security parameter is its key length and algorithm, chosen by the cryptographic scheme itself and, for `ed25519`, fixed at a strong default. A password's effective security parameter is its entropy, which is chosen by a human being and is, empirically and overwhelmingly, far lower than the security margin a modern key exchange or signature scheme provides — this is the concrete instantiation of the point raised abstractly in Chapter 01, Section 1.3.3: encryption of the channel says nothing about the strength of what's placed inside it.

**Passwords are inherently susceptible to offline and online guessing in a way keys are not.** A stolen `authorized_keys` file grants an attacker nothing without the corresponding private key, which never left the client. A stolen or guessed password grants immediate, complete authentication — there is no equivalent "half of the secret is useless without the other half" property.

None of this means password authentication is cryptographically broken at the transport level — the password genuinely is protected in transit by the same transport-layer encryption covering everything else in the session (Chapter 02, Section 2.3). The weakness is structural and sits entirely on the authentication-layer side of the boundary established in Chapter 01, Section 1.3.1: password authentication is exactly as strong as the password, and no stronger, whereas public-key authentication's strength is set by the cryptographic scheme rather than by human memory.

## 3.6 `authorized_keys` and `known_hosts`: Two Halves of an Asymmetric Trust Relationship

Chapter 01, Section 1.3.3 introduced the TOFU gap in the context of host key verification generally. It's worth now stating precisely, and side by side, what each of these two files actually represents, because they are frequently discussed as if they were symmetric counterparts when structurally they are not.

**`known_hosts`** (client-side) answers the question *"is the server I'm talking to who I expect?"* It is a list the client maintains of server public keys it has previously seen and accepted, checked automatically on every subsequent connection (Chapter 02, Section 2.3.5). Its trust model, absent certificates, is Trust On First Use — the exact gap detailed in Chapter 01.

**`authorized_keys`** (server-side) answers a different question: *"which client public keys am I willing to accept for this account?"* It is a list the server administrator maintains, and — critically — it is populated deliberately and out-of-band by an administrator, not accepted automatically on first contact the way a host key can be. This is a meaningful asymmetry: the server side of the relationship generally does *not* suffer from a TOFU-style gap, precisely because adding an entry to `authorized_keys` is, by design, an explicit administrative act rather than an automatic response to a first connection attempt.

`authorized_keys` also supports per-key restriction options (`command=`, `no-port-forwarding`, `from=`, and others) that constrain what a given key is permitted to do even after successful authentication — a mechanism that sits at the boundary between authentication and authorization (Chapter 01, Section 1.3.3) and that Chapter 04 covers in configuration depth.

## 3.7 Observing an Authentication Exchange Directly

Consistent with the observation-over-assertion discipline established in Chapter 01, Section 1.5, run:

```
ssh -vvv user@host
```

and, following the transport-layer sequence already identified in Chapter 02, Section 2.6, look specifically for this authentication-layer sub-sequence:

```
debug1: SSH2_MSG_SERVICE_ACCEPT received
debug1: Authentications that can continue: publickey
debug1: Next authentication method: publickey
debug1: Offering public key: ...
debug1: Server accepts key: ...
debug1: Authentication succeeded (publickey).
```

The `Offering public key` line is the client presenting the public key and, if the server indicates it's an acceptable candidate, the actual signature over the session identifier (Section 3.3.1) is computed and sent — note that OpenSSH by default first sends an unsigned probe naming the candidate key, and only computes the (comparatively expensive) signature if the server confirms that key is worth attempting, an efficiency optimization that avoids signing on every offered key when a client holds several. `Server accepts key` confirms the server found that key in `authorized_keys`; `Authentication succeeded` confirms the signature verified correctly against the session identifier.

## 3.8 Summary and Bridge to Chapter 04

This chapter grounded the authentication layer's abstract state machine (Chapter 02, Section 2.4) in concrete mechanism: the precise byte string a public-key signature covers and why binding it to the session identifier defeats replay attacks; the generic, server-driven challenge-response structure of `keyboard-interactive` and why it — not `password` — is the natural home for multi-factor authentication; the structural (not merely conventional) reasons password authentication is weaker; the certificate-based trust model as a direct architectural fix for the distribution problem underlying the TOFU gap; and the genuine asymmetry between `known_hosts` and `authorized_keys` as two different halves of trust, not mirror images of each other.

Chapter 04 moves from protocol mechanism to configuration: how `sshd_config` and `ssh_config` actually expose and constrain everything covered in this chapter — method ordering, `AuthenticationMethods` chaining, per-key restrictions in `authorized_keys`, and the practical directives that turn the architectural properties established here into an enforced server policy.
