# Chapter 06: Hardening

## 6.1 Why This Chapter Is Not a Checklist

Most hardening guides are lists: turn this off, turn that on, here are forty directives. That format has a real cost — it produces compliance without understanding, which means the moment a new situation falls outside the list's exact wording, the reader has no principle to fall back on. This chapter takes a different approach, consistent with the discipline established in Chapter 01, Section 1.5: every recommendation here is derived, explicitly, from a specific mechanism covered in Chapters 02 through 05, tied back to a specific claim in the threat model (Chapter 01, Section 1.3). If you understand *why* each of these follows from what you already know, you can extend the reasoning to situations this chapter doesn't explicitly name — which is the actual goal, not the directive list itself.

## 6.2 Deriving Policy from the Threat Model

Recall Chapter 01, Section 1.3.3's list of things SSH does *not* protect against. That list is, read carefully, already a hardening agenda — it names exactly the gaps that configuration and operational discipline need to close, because the protocol itself structurally cannot close them.

### 6.2.1 The Compromised-Endpoint Gap → Minimize What a Compromised Credential Can Do

Chapter 01 established that SSH secures a channel between two points and says nothing about the trustworthiness of either point. The direct policy consequence: since you cannot get the protocol to guarantee endpoint integrity, the defensible posture is to minimize the blast radius of a single compromised credential — treating "assume some key, somewhere, will eventually be compromised" as the design constraint, not an edge case.

This is precisely why Chapter 03, Section 3.3.5's certificate infrastructure and Chapter 04, Section 4.5's per-key `authorized_keys` restrictions matter operationally, not just architecturally: a certificate with a short validity period (`ssh-keygen -s ca-key -V +1d -n deploy-user deploy-key.pub`) bounds the compromise window even if a private key is copied off a compromised machine — the certificate expires and re-authentication against the CA is required, whereas a raw key in `authorized_keys` remains valid indefinitely until an administrator manually notices and removes it. Similarly, a heavily restricted automation key (`command=`, `from=`, no forwarding — Chapter 04, Section 4.5) that can only run one fixed script from one fixed network is a fundamentally smaller asset to an attacker than an unrestricted interactive key, even before considering revocation at all.

### 6.2.2 The TOFU Gap → Replace Leap-of-Faith with a Verifiable Anchor

Chapter 01, Section 1.3.3 and Chapter 03, Section 3.3.5 together already made the structural case: TOFU is a genuine, acknowledged limitation, not an oversight, and the direct fix is removing the "leap of faith" step entirely rather than training users to click through it more carefully (which doesn't scale and doesn't actually verify anything). Two concrete mechanisms follow directly:

**SSH certificates for host keys**, the mirror image of Chapter 03, Section 3.3.5's user-certificate discussion: a host certificate, signed by a CA the client already trusts, is verified cryptographically on first contact — there is no first-contact prompt at all, because trust was already established transitively through the CA, not through blind acceptance of whatever key the server happens to present.

**SSHFP DNS records**, which publish a host key's fingerprint in DNS itself (`sshfp` resource record type), letting the client check the offered key against a DNS-published value automatically (`VerifyHostKeyDNS yes` client-side) rather than relying on out-of-band verification that, in practice, essentially never happens. This is meaningfully weaker than certificate-based trust if DNS itself isn't secured with DNSSEC (an attacker capable of forging DNS responses can forge the SSHFP record too), but it closes the gap against a purely on-path network attacker who has no DNS-manipulation capability — worth understanding as a partial mitigation with a specific, statable limitation, not an unconditional fix.

### 6.2.3 The Password-Weakness Gap → Make Public-Key Authentication the Actual Floor, Not the Aspiration

Chapter 03, Section 3.5 built the structural case for why password authentication is weaker by design, not merely by convention. The corresponding configuration is exactly what Chapter 04, Section 4.3 covered:

```
PasswordAuthentication no
KeyboardInteractiveAuthentication no
PubkeyAuthentication yes
```

with the explicit caveat from Chapter 04, Section 4.3 restated because it's the single most common way this hardening step silently fails: disabling `PasswordAuthentication` alone, while leaving `KeyboardInteractiveAuthentication` enabled with a PAM stack that falls through to password verification, does not achieve the intended outcome. Verify the *effective* configuration with `sshd -T` (Chapter 04, Section 4.8) rather than assuming the directive you set is the directive that's actually enforced — this is the observation-over-assertion discipline applied directly to your own hardening work, not just to understanding the protocol.

Where password authentication genuinely cannot be eliminated (certain legacy integration requirements), `AuthenticationMethods` chaining (Chapter 04, Section 4.3.1) at minimum ensures a stolen or guessed password alone is insufficient — requiring it in combination with a public key or a second factor converts a single-point-of-failure credential into one factor of a multi-factor requirement.

### 6.2.4 The Authentication/Authorization Conflation → Enforce Least Privilege After Login, Not Just At the Door

Chapter 01, Section 1.3.3 drew a sharp line between proving identity and constraining what that identity can subsequently do. Hardening that stops at authentication and ignores this line leaves a wide-open door the moment any single credential succeeds. The mechanisms already introduced across this series compose directly into a least-privilege posture:

```
PermitRootLogin no
```

removes root as a directly authenticatable identity (Chapter 04, Section 4.7), forcing privilege escalation through a separately-logged `sudo` call — a distinct, auditable authorization event rather than something bundled invisibly into the authentication step itself.

Per-key restrictions (Chapter 04, Section 4.5) and `Match`-block scoping (Chapter 04, Section 4.4) let a single server enforce meaningfully different authorization envelopes for different identities and different credentials belonging to the same identity — the automation account that can only run one script is not merely a convention, it's a specific, server-enforced constraint independent of whatever that account's password or other keys might be capable of.

## 6.3 Reducing Exposed Attack Surface

A separate, complementary line of reasoning, less about the authentication mechanism itself and more about limiting what an unauthenticated attacker can even reach or learn:

```
MaxAuthTries 3
LoginGraceTime 30
```

Both already introduced in Chapter 04, Section 4.7 — worth restating their derivation here: `MaxAuthTries` bounds online guessing (the direct mitigation to Chapter 03, Section 3.5's guessing-susceptibility argument), and `LoginGraceTime` bounds how long an attacker can hold an unauthenticated connection open, closing a resource-exhaustion angle that has nothing to do with credential strength at all.

A frequently debated but lower-impact measure: changing the listening port away from 22. It's worth being precise about what this does and doesn't accomplish, given Chapter 02, Section 2.3.1's observation that the version banner is plaintext and trivially fingerprintable regardless of port — a nonstandard port does not meaningfully increase resistance against a targeted attacker (a full port scan finds it in seconds), but it does measurably reduce log noise from the constant, automated, opportunistic scanning traffic that continuously probes port 22 across the entire internet. This is a noise-reduction and log-clarity measure, not a genuine security control, and presenting it as the latter to a stakeholder overstates what it actually buys you.

## 6.4 Algorithm Selection: Closing the Downgrade Gap From Chapter 02

Chapter 02, Section 2.3.3 identified the exact mechanism of a downgrade attack: if a weak algorithm sits anywhere in either side's offered list, the intersection rule can select it. The direct hardening response is restricting the server's own offered lists to exclude weak algorithms entirely, so they're never available to be selected regardless of what a client offers:

```
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512
```

Two things worth noting precisely rather than treating this as a copy-paste block. First, the `-etm` (encrypt-then-MAC) suffix on the MAC algorithms is a deliberate, non-cosmetic choice: encrypt-then-MAC computes the MAC over the ciphertext rather than the plaintext, which is now broadly understood in the cryptographic literature to be the structurally sounder ordering compared to the older encrypt-and-MAC or MAC-then-encrypt constructions, because it lets the integrity check reject a tampered packet before any decryption is attempted on it at all. Second, restricting these lists too aggressively can break compatibility with older clients or devices that only support algorithms you've now excluded — this is precisely the version-sensitivity concern flagged generally in Chapter 01, Section 1.4, and the correct process is checking `ssh -Q` output (Chapter 02, Section 2.3.2) against your actual client population, not applying a hardening guide's list unconditionally.

## 6.5 A Worked Example: Reading a Hardened Configuration as a Set of Traceable Decisions

Rather than presenting a final config block as something to trust on authority, here is one, with every line traceable to a specific piece of reasoning already established in this series:

```
# Attack-surface reduction — Section 6.3
MaxAuthTries 3
LoginGraceTime 30

# Authentication floor — Section 6.2.3, Chapter 03 §3.5, Chapter 04 §4.3
PasswordAuthentication no
KeyboardInteractiveAuthentication no
PubkeyAuthentication yes

# Authorization, not authentication — Section 6.2.4, Chapter 01 §1.3.3
PermitRootLogin no

# Algorithm floor — Section 6.4, Chapter 02 §2.3.3
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Least privilege for automation — Section 6.2.1, Chapter 04 §4.5
Match User backup-agent
    AuthenticationMethods publickey
    ForceCommand /usr/local/bin/backup-only.sh
```

The point of laying it out this way is that every single directive answers a "why" question with a pointer to a specific mechanism, not to "best practice" as an unexamined authority. This is deliberately the opposite of a checklist copied without understanding — and it's the actual, durable value of having gone through Chapters 02 through 05 in mechanism-first depth before arriving here.

## 6.6 Summary and Bridge to Chapter 07

This chapter did not introduce new protocol mechanism — it derived operational policy directly from the threat model (Chapter 01) applied against every mechanism covered since: minimizing blast radius given the compromised-endpoint gap; closing the TOFU gap with certificates or SSHFP; making public-key authentication an actually-enforced floor rather than an aspiration undermined by an unnoticed `keyboard-interactive` fallback; separating authorization from authentication with `PermitRootLogin no` and per-key restrictions; reducing attack surface with connection and retry limits; and closing the downgrade gap identified all the way back in Chapter 02 by restricting the server's own offered algorithm lists.

Chapter 07 turns to the inverse skill: when something goes wrong — a connection hangs, authentication fails unexpectedly, a forwarded port doesn't work — how do you diagnose it using the exact same observation tools (`ssh -vvv`, `sshd -ddd`, `sshd -T`) this series has used throughout, now organized around specific failure symptoms and which layer (Chapter 02's transport, authentication, or connection layer) each symptom actually points to.
