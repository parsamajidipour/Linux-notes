# Chapter 02: SSH Protocol Architecture

## 2.1 Why Three Layers?

The SSH protocol is not a single monolithic protocol. It is three distinct protocols stacked on top of one another, each with its own RFC. This design decision is not incidental, and understanding why it exists is a prerequisite for everything else in this chapter.

The three foundational documents are:

- **RFC 4253** — Transport Layer Protocol
- **RFC 4252** — User Authentication Protocol
- **RFC 4254** — Connection Protocol

And the document that holds the conceptual umbrella over all three:

- **RFC 4251** — SSH Protocol Architecture

Why this separation? Because each layer has a distinct responsibility, and if they were merged into one, replacing or upgrading any single one independently would be impossible. The transport layer is responsible for the confidentiality and integrity of the channel — ensuring that what passes between you and the server cannot be read or tampered with by anyone else. The authentication layer is responsible for proving you are who you claim to be. The connection layer is responsible for multiplexing several independent data streams (an interactive shell, a port tunnel, a file transfer) over that single secure, authenticated channel.

The practical consequence of this separation is something you've likely experienced without thinking about it: when the key-exchange algorithm on your server gets upgraded, your authentication mechanism (say, public key) stays untouched. When you migrate from password to public-key authentication, your existing connection-layer channels — like port forwards — keep working unchanged. This layer independence is why the protocol, first formalized in RFC 4251 in 2006, has remained viable to this day.

One terminological note: strictly speaking, only the third layer (RFC 4254) is officially called a "protocol" (the *Connection Protocol*), but in practice — and in this document — we refer to all three as "layers," because architecturally they behave as layers: each one rides on top of the output of the layer beneath it.

## 2.2 Execution Order: When Is Each Layer Active?

Before diving into the details of each layer, let's map out the timeline — without this roadmap, the details in each section lack context.

When you run:

```
ssh user@host
```

the following sequence occurs:

1. A **TCP** connection is established on port 22 (or whatever port is configured). This is outside the SSH protocol itself — it's the TCP/IP transport layer, not the SSH transport layer. This distinction matters because both are called "transport," yet they are entirely different concepts.

2. **Protocol Version Exchange** — both sides exchange a readable, plaintext (unencrypted) string announcing the protocol version and software.

3. **Key Exchange** — negotiation over algorithms, followed by the actual key-exchange execution, which produces a shared symmetric key. This is still part of the SSH transport layer.

4. From this point forward, all traffic is encrypted. Even the authentication request itself is sent inside the encrypted channel.

5. The **user authentication layer** activates — the client proves who it is.

6. After successful authentication, the **connection layer** activates — channels open (shell, command execution, tunnel, etc.).

One thing hidden in this sequence that deserves emphasis: steps 1 and 2 are unencrypted. This means any network observer can determine which server you're connecting to and which SSH software version you're running — a fact that is itself an attack surface, which we return to in Chapter 06.

## 2.3 The Transport Layer — The Heart of the Architecture

### 2.3.1 Protocol Version Exchange

The very first bytes exchanged are a plaintext string with a fixed format. Per RFC 4253, this string must begin with the pattern:

```
SSH-protoversion-softwareversion
```

For instance, an **OpenSSH 9.6** server typically sends something like:

```
SSH-2.0-OpenSSH_9.6
```

You can observe this directly with **netcat**, without even reaching the encryption layer:

```
nc target_host 22
```

The server you connect to immediately sends this string and waits for a similar response from you. This is one of the few points in the entire protocol that is fully plaintext and readable — and precisely for that reason, it's the first target of network scanners doing version fingerprinting. In Chapter 06 we'll see why hiding this banner (a practice some guides recommend) doesn't actually add real security — it only slightly raises the difficulty of identification.

### 2.3.2 Key Exchange: The Problem That Must Be Solved

Before explaining the mechanism, let's precisely define the problem: two parties who, up to this moment, share no secret at all, and who are communicating over a channel that anyone might be listening to, must arrive at a shared symmetric encryption key — in such a way that an eavesdropper, even with a complete transcript of the conversation, cannot reconstruct that key.

The classical solution to this problem is **Diffie-Hellman** key exchange, and SSH uses modern variants of it. In OpenSSH 9.x, the default and preferred algorithm is:

```
curve25519-sha256
```

This is an elliptic-curve-based key exchange (**ECDH** — Elliptic Curve Diffie-Hellman), not classical Diffie-Hellman over large prime numbers. The practical difference for you: equivalent security with much smaller keys, and faster computation.

You can list every key-exchange algorithm your installed version supports directly from the binary itself:

```
ssh -Q kex
```

This prints a list whose order is the client's default preference order — the first entry is the first proposal the client offers the server.

### 2.3.3 The Algorithm Negotiation Mechanism

A detail that most simplified explanations skip: before the actual key exchange runs, both sides exchange a message called

```
SSH_MSG_KEXINIT
```

in which each side announces its complete list of accepted algorithms (in priority order) for each of the following categories:

- Key exchange algorithm
- Host key signature algorithm
- Symmetric cipher (separately per direction)
- Message authentication (MAC) algorithm
- Compression algorithm

The selection rule is simple: for each category, the client's first choice that also appears in the server's list is selected. This means that if an old server still supports `diffie-hellman-group14-sha1`, and your client also has it in its list (even at low priority), negotiation can end up settling on that weaker algorithm — not because anyone "chose" it, but because that's what the intersection rule produces. This is precisely where **downgrade attacks** live, a topic we return to in Chapter 06.

You can watch this negotiation with your own eyes. Run:

```
ssh -vvv user@host
```

In the output, you'll see lines like this (abbreviated):

```
debug2: KEX algorithms: curve25519-sha256,...
debug2: host key algorithms: ssh-ed25519,...
debug2: ciphers ctos: chacha20-poly1305@openssh.com,...
debug1: kex: algorithm: curve25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
```

The first and second lines are the client's proposed lists. The `kex: algorithm` and `kex: host key algorithm` lines are the final negotiated result — i.e., what will actually be used.

### 2.3.4 The Actual Key Exchange and Session Key Derivation

Once algorithms are agreed upon, the real Diffie-Hellman exchange (or its elliptic-curve variant) executes. The result is a **shared secret**, which both sides arrive at independently, without the secret itself ever being transmitted over the network — this is the fundamental property of Diffie-Hellman.

But this shared secret isn't used directly as an encryption key. Per RFC 4253, Section 7.2, from this shared secret combined with a hashed value called the **exchange hash H** (which itself incorporates both version banners, both KEXINIT messages, and the server's host key), **six** distinct keys are derived:

- Client-to-server encryption key
- Server-to-client encryption key
- Client-to-server initialization vector (IV)
- Server-to-client initialization vector
- Client-to-server MAC key
- Server-to-client MAC key

Why six separate keys instead of one shared key? Because reusing one key in two different directions (client-to-server and server-to-client), even under the same algorithm, opens up an additional class of cryptographic attack surface that is eliminated entirely by fully separating the keys. This is a general principle of applied cryptography: keys are separated by role, not by session.

Another important detail: the `H` mentioned above, once computed during the first key exchange, is also stored as the **Session Identifier** and remains fixed for the entire lifetime of that TCP session — even if key exchange later re-runs (**re-keying**). This identifier plays a central role in public-key authentication signatures in Chapter 03 — it's precisely this identifier that prevents **replay attacks**.

### 2.3.5 Host Key Verification — Where Trust Begins

During that same key-exchange step, the server sends its host public key and produces a signature over the exchange hash `H` using its private host key. The client verifies this signature against the received public key.

But this mathematical verification only proves that "the party on the other end possesses the private key corresponding to the sent public key" — not that "this public key belongs to the server you intended to connect to." These are two entirely different claims, and the gap between them is exactly what the

```
known_hosts
```

file fills. The first time you connect to a new host, you see this message:

```
The authenticity of host 'target' can't be established.
```

This means: the math checked out, but identity has not yet been verified — these are two completely separate layers of trust, and recognizing this distinction is a prerequisite for understanding Chapter 03.

You can query a host key's type and fingerprint independently of a full connection attempt, using just a scan:

```
ssh-keyscan -t ed25519 target_host
```

## 2.4 The User Authentication Layer — Architectural Overview (Detailed in Chapter 03)

From this point forward, all exchanges happen inside the encrypted channel. The authentication layer (RFC 4252) is, architecturally, a simple state machine running over this same channel.

The client requests authentication with a specific method (`publickey`, `password`, `keyboard-interactive`, ...). The server either accepts, or rejects and simultaneously announces the list of remaining permitted methods. This cycle continues until success or disconnection.

One architectural point that must be established here, because Chapter 03 builds on it: every public-key authentication message includes a signature computed over a combination of the **session identifier** (the same `H` from Section 2.3.4) and the request contents. This means public-key authentication is inherently bound to the underlying transport-layer session — a valid signature in one session is useless in another. The full mechanism, and its comparison with `password` and `keyboard-interactive`, is the subject of Chapter 03.

## 2.5 The Connection Layer — Multiplexing Over One Channel

### 2.5.1 The Multiplexing Problem

After successful authentication, you have one encrypted, authenticated channel available. But a typical SSH session needs more than one "stream" of data: an interactive shell, perhaps a port tunnel simultaneously, perhaps a file transfer. The connection layer (RFC 4254) solves exactly this problem: how to fit several independent streams over a single TCP connection, without each one needing its own separately-encrypted connection.

The solution is the concept of a **Channel**.

### 2.5.2 A Channel's Lifecycle

Every channel begins with the message

```
SSH_MSG_CHANNEL_OPEN
```

which specifies the channel type. The most important channel types you'll encounter in OpenSSH:

- `session` — for shell, command execution, or a subsystem (like `sftp`)
- `direct-tcpip` — for **Local Port Forwarding** (i.e., `ssh -L`)
- `forwarded-tcpip` — for **Remote Port Forwarding** (i.e., `ssh -R`)
- `x11` — for **X11 Forwarding**

The other side responds with either

```
SSH_MSG_CHANNEL_OPEN_CONFIRMATION
```

or

```
SSH_MSG_CHANNEL_OPEN_FAILURE
```

Each channel has a numeric local identifier on each side (client and server number independently), and subsequent messages reference this identifier to route data to the correct channel.

An important point that directly connects to Chapter 05: opening a `direct-tcpip` channel (i.e., a tunnel) has no fundamental protocol-level difference from opening a `session` channel (i.e., a shell). Both are just another channel type at the same connection layer. This is precisely the point made in the README document: "port forwarding is channels in action, not a separate feature."

### 2.5.3 Flow Control: Why One Slow Channel Doesn't Slow the Rest

Each channel has an independent **Window Size** — the amount of data the sender is permitted to send without receiving acknowledgment from the other side. When this window fills up, sending on that specific channel pauses until the other side reopens the window with

```
SSH_MSG_CHANNEL_WINDOW_ADJUST
```

The practical significance of this mechanism: because flow control operates at the individual channel level, not at the level of the whole TCP connection, one slow or blocked channel (say, a port tunnel connected to a sluggish service) cannot stall every other channel — including your interactive shell. This is exactly why you can run a heavy `scp` transfer and an interactive shell simultaneously over one SSH connection without the shell freezing (as long as the underlying TCP connection itself doesn't become the bottleneck).

### 2.5.4 Requests on a Channel

After a `session` channel opens, the actual action (running a shell, running a specific command, or running a subsystem) is requested via a separate

```
SSH_MSG_CHANNEL_REQUEST
```

The most common request types:

- `pty-req` — request allocation of a pseudo-terminal
- `shell` — run the user's default interactive shell
- `exec` — run a specific command and return its output
- `subsystem` — run a predefined subsystem, the most common example being **sftp**

This separation explains why

```
ssh host command
```

and

```
ssh host
```

(no command) take two different code paths on the server: the first is an `exec` request, the second is a `shell` request (usually preceded by a `pty-req`). It also explains why `sftp` isn't a separate protocol — it's a subsystem riding on the same `session` channel. Precisely for this reason, `sftp` inherits all of SSH's security and encryption benefits for free.

## 2.6 Direct Observation: Reading a Complete Handshake

Let's map the theory above onto a real execution. The following command logs a complete connection with maximum detail:

```
ssh -vvv user@target_host
```

If you follow the output from the start, this sequence should line up exactly with Sections 2.2 through 2.5:

1. Lines `debug1: Connecting to` and `debug1: Local version string` — the version banner exchange stage (Section 2.3.1)

2. Multiple lines like `debug2: KEX algorithms`, `debug2: host key algorithms`, and similar — both sides' `KEXINIT` messages (Section 2.3.3)

3. The line `debug1: kex: algorithm: curve25519-sha256` — the final negotiation result

4. The line `debug1: Server host key: ssh-ed25519` along with a fingerprint — host key verification (Section 2.3.5)

5. Lines `debug1: SSH2_MSG_NEWKEYS sent` and `received` — the exact moment new keys activate and everything from here on is encrypted

6. Lines `debug1: Authentications that can continue` and `debug1: Next authentication method: publickey` — the start of the authentication layer (Section 2.4)

7. Finally, lines `debug1: Entering interactive session` and `debug2: channel 0: open` — the `session` channel opening (Section 2.5.2)

Suggested exercise: run this command against one of your own servers and match each line to one of these seven stages. This exercise erases the gap between "reading about the protocol" and "watching the protocol run" — exactly the observation-first discipline established in the README document.

To see the same process from the server side, if you have server access, you can run a temporary instance of `sshd` with maximum verbosity (on a port other than the primary one, to avoid conflicts):

```
sudo /usr/sbin/sshd -ddd -p 2222
```

This command's output shows the same sequence from the server's point of view and complements the `ssh -vvv` output.

## 2.7 Summary and Bridge to Chapter 03

In this chapter, we examined SSH's three-layer architecture from the bottom up:

The **transport layer** builds a confidential channel with integrity guarantees, through version banner exchange, algorithm negotiation, actual Diffie-Hellman execution (or its elliptic-curve variant), and host key verification. This layer's output is six derived keys and a fixed session identifier (`H`) that plays a central role in the next chapter.

The **authentication layer** proves the user's identity over this confidential channel — and we saw that this proof is inherently bound to the session identifier of the underlying layer.

The **connection layer** provides multiple independent streams (channels) over that single channel, each with its own flow control — and we saw that shells, command execution, the `sftp` subsystem, and port tunnels are all just different types of one unified concept: the channel.

Chapter 03 picks up exactly where Section 2.4 left off: how each authentication method (`publickey`, `password`, `keyboard-interactive`, `GSSAPI`) actually works, why public-key authentication is architecturally superior to passwords (not just more convenient), and how `authorized_keys` and `known_hosts` files together form an asymmetric trust relationship.


