# Chapter 07: Troubleshooting

## 7.1 Why Troubleshooting Is a Layer-Identification Problem

Every diagnostic method in this chapter rests on one fact established across Chapters 02 through 05 and worth stating as the organizing principle of everything that follows: SSH's three-layer architecture (Chapter 02, Section 2.1) means a failure has a *layer* — transport, authentication, or connection — and that layer is almost always identifiable from where in the handshake sequence (Chapter 02, Section 2.6) the failure occurs. The practical consequence: effective troubleshooting is not pattern-matching an error message against a list of known fixes; it's locating precisely which of the three layers stopped working, because that determines an entirely different, non-overlapping set of possible causes. A transport-layer failure can never be fixed by an authentication-layer change, and vice versa — treating this chapter as a decision tree organized by layer, rather than by symptom text, is the actual skill being taught here.

## 7.2 The Diagnostic Baseline: Reading `ssh -vvv` as a State Machine

Chapter 02, Section 2.6 walked a complete, successful handshake through seven identifiable stages. That same walk-through is now the diagnostic tool: run

```
ssh -vvv user@host
```

and find the **last** stage that completed before output stops or an error appears. This single act — locating the last successful checkpoint against Chapter 02's seven-stage map — does most of the diagnostic work before you've even read a specific error message, because it immediately tells you which of the three layers (Chapter 02, Section 2.1) never got the chance to run at all.

## 7.3 Transport-Layer Failures: Nothing Got Encrypted

### 7.3.1 Symptom: Connection Hangs Before Any Version String Appears

If `ssh -vvv` produces no `debug1: Local version string` / remote version line at all, and simply hangs, the failure is occurring *before* Chapter 02, Section 2.3.1 — meaning it's not an SSH problem yet, it's a TCP/IP-and-below problem: a firewall silently dropping the packets, a routing failure, or the daemon not listening at all.

```
ssh -o ConnectTimeout=5 -vvv user@host
```

bounds how long you wait for confirmation. Distinguishing "nothing is listening" from "something is silently dropping the traffic" from the client alone is not always possible; from a position with server access, confirm the daemon is actually bound and listening:

```
sudo ss -tlnp | grep sshd
```

If this shows nothing, the fix is entirely outside SSH's configuration — `sshd` isn't running, or it's bound to an interface or port other than the one you're connecting to.

### 7.3.2 Symptom: `REMOTE HOST IDENTIFICATION HAS CHANGED`

This is not a transport-layer failure in the sense of broken cryptography — it's Chapter 02, Section 2.3.5's host-key verification doing exactly its designed job: the key the server just presented does not match the key recorded in your `known_hosts` for that host. Per Chapter 01, Section 1.3.2, this is precisely the class of active-impersonation attempt the mechanism exists to catch — **but** it is far more commonly caused by an entirely benign event: the server was rebuilt, reimaged, or its host key was legitimately regenerated, and nobody updated `known_hosts`.

The diagnostic step that actually distinguishes these two possibilities is not skipping the check — it's independently verifying the *new* key's fingerprint through some channel other than the SSH connection itself (a configuration management system's record of the host key, a cloud provider's console output, an out-of-band message from whoever rebuilt the host):

```
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

run *on the server*, compared against what the client received (visible in the `ssh -vvv` output's `Server host key` line, Chapter 02, Section 2.6, stage 4). Only once this out-of-band comparison confirms the new key is legitimate should the stale entry be removed:

```
ssh-keygen -R host -f ~/.ssh/known_hosts
```

Removing the offending line without this verification step is exactly the TOFU-erosion pattern flagged in Chapter 01, Section 1.3.3 and Chapter 06, Section 6.2.2 — technically resolves the symptom, structurally defeats the protection.

### 7.3.3 Symptom: `no matching key exchange method found` / `no matching cipher found`

This error appears immediately after the `KEXINIT` exchange (Chapter 02, Section 2.3.3) and means, precisely, that the intersection of the client's offered algorithm list and the server's offered algorithm list, for some category, is empty — there is no algorithm both sides are willing to use. Given Chapter 02, Section 2.3.3's exact description of the negotiation rule, this is not really an "error" in the sense of something broken; it's a correct, working refusal to fall back to a mutually acceptable but disallowed weaker algorithm. This most often surfaces when Chapter 06, Section 6.4's algorithm-restriction hardening has been applied to a server that then needs to serve an older client (or vice versa).

The error message itself typically lists what was offered; compare directly against what each side is willing to use:

```
ssh -Q kex          # client's supported list, Chapter 02 §2.3.2
sudo sshd -T | grep -i kexalgorithms   # server's effective list, Chapter 04 §4.8
```

The fix is never to blindly widen the list back to include weak algorithms — that reverses Chapter 06's hardening rationale entirely. It's to identify the specific modern algorithm both the (possibly outdated) client and server genuinely support, and add only that one, narrowly, rather than restoring the full legacy list.

## 7.4 Authentication-Layer Failures: The Handshake Succeeded, Identity Didn't

If `ssh -vvv` output shows `SSH2_MSG_NEWKEYS sent` and `received` (Chapter 02, Section 2.6, stage 5) but then fails, the transport layer worked completely — the channel is confidential and integrity-protected. Every remaining failure mode is now scoped to Chapter 03's mechanism, not Chapter 02's.

### 7.4.1 Symptom: `Permission denied (publickey)`

Locate exactly where in Chapter 03's mechanism this occurred by reading the lines immediately preceding the failure:

**If `debug1: Offering public key: ...` never appears at all for the key you expect** — the client never attempted to offer that key. Check, in order: is the key actually loaded (`ssh-add -l`), and if using `IdentityFile`, is `IdentitiesOnly yes` (Chapter 04, Section 4.6.2) perhaps restricting the offer to a *different* key than the one you're expecting, silently, because an agent-loaded key or a different `IdentityFile` entry is taking priority.

**If `Offering public key` appears but is followed immediately by the server declining, without `Server accepts key`** — the server's `authorized_keys` for that account does not contain this exact public key. This is a Chapter 03, Section 3.6 problem, not a cryptography problem: verify the exact key material (`ssh-keygen -lf ~/.ssh/id_ed25519.pub` compared against the fingerprint the server would need in its `authorized_keys`), and independently verify file permissions — `sshd` silently refuses to honor an `authorized_keys` file (or its containing `.ssh` directory, or the user's home directory) that is group- or world-writable, a security default that has nothing to do with the key's validity and everything to do with preventing a key from being planted by another user on a shared system.

**If `Server accepts key` appears but is followed by failure rather than `Authentication succeeded`** — this is rare and specifically points to Chapter 03, Section 3.3.1's signature step itself failing verification, most commonly caused by a corrupted or mismatched private key file, or (occasionally) a session identifier mismatch from a proxy or middlebox subtly interfering with the transport session — worth checking `ssh -vvv` for any unexpected renegotiation or connection reset immediately before this point.

### 7.4.2 Symptom: Server Lists Fewer Methods Than Expected

If `debug1: Authentications that can continue:` shows only `password`, when you expected `publickey` to be offered, this is a server-side policy fact, not a client-side problem — `sshd -T` (Chapter 04, Section 4.8) on the server will show `PubkeyAuthentication no`, or a `Match` block (Chapter 04, Section 4.4) scoped to your specific user or source address overriding the global setting in a way the flat file's linear text doesn't make obvious. This is precisely why Chapter 04, Section 4.8 introduced `sshd -T -C` — reasoning about `Match` precedence by eye against a long configuration file is exactly the failure mode that tool exists to eliminate.

### 7.4.3 Symptom: Authentication Succeeds But Then Immediately Disconnects

If `Authentication succeeded` appears (Chapter 03, Section 3.7) but the session terminates immediately afterward rather than reaching Chapter 02, Section 2.6's final stage (`channel 0: open`), the failure has moved into the connection layer — often a `ForceCommand` (Chapter 04, Section 4.4) or shell-startup script on the server exiting immediately, which is not an SSH protocol failure at all but a server-side account or script configuration issue. Server-side logs (`journalctl -u ssh` or `/var/log/auth.log`, depending on distribution) at this point are more informative than continuing to add client-side verbosity, precisely because the client has nothing more to observe — its half of the protocol already succeeded.

## 7.5 Connection-Layer Failures: Authenticated, But a Specific Channel Doesn't Work

### 7.5.1 Symptom: Interactive Shell Works, But a Port Forward Doesn't

Given Chapter 02, Section 2.5's channel independence, an interactive shell succeeding definitively rules out every transport- and authentication-layer cause — the problem is scoped entirely to Chapter 05's forwarding mechanism. Check, precisely in this order, matching Chapter 05's mechanics:

For a **local** forward (`-L`, Chapter 05, Section 5.3): is the local listener actually bound (`ss -tlnp` on the client, checking the requested local port)? If yes, the issue is likely the *server's* ability to reach the ultimate destination — remember the forwarded connection originates from the server's network position, not the client's (Section 5.3's trust-boundary point), so a destination unreachable from the server but reachable from the client will fail even though the tunnel itself is healthy.

For a **remote** forward (`-R`, Chapter 05, Section 5.4): the single most common cause, per Chapter 05, Section 5.4's explicit warning, is `GatewayPorts` defaulting to binding the remote listener to loopback only — if you expect the forwarded port to be reachable from other hosts and it isn't, this default (working as designed, not broken) is almost certainly why. Verify with `ss -tlnp` *on the server side* whether the listener is bound to `127.0.0.1` or `0.0.0.0`.

### 7.5.2 Symptom: `channel N: open failed: connect failed`

This message, appearing after successful authentication, is the server explicitly reporting that it could not complete Chapter 05's mechanism — for a local forward, this means the server tried and failed to reach the specified destination (Section 5.3's second TCP connection, from server to final target). This is not an SSH-layer failure at all once you recognize it structurally — it's an ordinary network-reachability failure being faithfully reported through the SSH channel-open-failure message rather than being an SSH problem in itself. Diagnose it as you would diagnose any TCP connectivity issue *from the server's network position specifically*, since that's where the failing connection attempt actually originates.

## 7.6 Server-Side Observation: Completing the Picture `-vvv` Cannot

Client-side verbosity shows what the client experiences; several failure classes are only fully visible from the server's own logging. Where you have server access and client-side diagnosis alone hasn't isolated the issue:

```
sudo sshd -ddd -p 2222
```

already introduced in Chapter 02, Section 2.6, run on an alternate port to avoid disrupting the production listener, gives you the server's side of exactly the same handshake — genuinely necessary for authentication-layer failures where the client-visible error (`Permission denied (publickey)`) is deliberately generic (a security property, not an oversight — the protocol intentionally avoids telling a failed client *which specific reason* it failed for, to avoid handing an attacker a user-enumeration or key-enumeration oracle), while the server's own log, in contrast, will state the specific reason plainly: wrong key, bad permissions, account restrictions, or a `Match`-block policy denial.

## 7.7 Summary: The Diagnostic Principle, Restated

Every technique in this chapter reduces to one move, repeated: locate the last successfully-completed stage in Chapter 02, Section 2.6's seven-stage handshake map, which identifies the failing layer; then apply that specific layer's mechanism (Chapter 02 for transport, Chapter 03 for authentication, Chapter 05 for connection-layer channels) to narrow further, using `ssh -vvv`, `sshd -ddd`, and `sshd -T` — the same three observation tools used to verify claims throughout this entire series — now pointed at a failure instead of a success. There is no separate troubleshooting toolkit; there is only the same mechanism-first understanding built across Chapters 02 through 05, applied in reverse.

This closes the technical core of the series. Chapter 08 (References) consolidates the primary sources — the RFCs, man pages, and specific tool invocations — cited throughout, organized for lookup rather than narrative reading.
