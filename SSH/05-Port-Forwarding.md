# Chapter 05: Port Forwarding

## 5.1 Where This Chapter Picks Up

Chapter 02, Section 2.5.2 made a claim this chapter now redeems in full: port forwarding is not a separate SSH feature bolted onto the protocol — it is channels, the same connection-layer mechanism that carries an interactive shell, applied to a different purpose. Chapter 04, Section 4.6.1 showed a working instance of exactly this (`ProxyJump` opening a `direct-tcpip` channel) without stopping to unpack the general mechanism. This chapter unpacks it fully: the three forwarding modes, the specific channel types each one opens, and — because this is where the security stakes actually are — what each mode does and does not change about the threat model established in Chapter 01.

## 5.2 The Core Idea, Stated Precisely

Every form of SSH port forwarding does one thing: it takes a TCP connection that would otherwise travel in the clear (or over a separate, unencrypted network path) and instead relays its bytes, in both directions, as payload inside an already-established, encrypted, authenticated SSH connection-layer channel. The forwarded connection's TCP handshake, its own header structure, its own traffic — none of that exists independently on the network between the two SSH endpoints. From the perspective of a network observer positioned between the SSH client and server, forwarded traffic is indistinguishable, at the transport-layer encryption level, from any other SSH channel traffic — it inherits precisely the confidentiality and integrity guarantees established in Chapter 02, Section 2.3, and precisely the same limitations (Chapter 01, Section 1.3.2: content is protected, connection metadata and traffic timing are not).

What differs between the three modes is not the mechanism carrying the bytes — that's identical in all three — but *which endpoint initiates the forwarded connection* and *where the forwarded connection's other end actually terminates.* This is the single organizing fact worth holding onto through the rest of this chapter; the three flags (`-L`, `-R`, `-D`) are three different answers to "who dials, and to where," not three different underlying protocols.

## 5.3 Local Forwarding (`-L`): The Client Dials Through the Server

```
ssh -L 8080:internal-db.corp:5432 user@bastion.example.org
```

Read this precisely, left to right: bind a listening socket on **the local machine**, port 8080. Any connection made to that local socket gets relayed, through the SSH connection to `bastion.example.org`, and from there onward to `internal-db.corp:5432` — a destination that `bastion` can reach but the original client, absent this tunnel, cannot (say, because `internal-db.corp` sits on a private network segment only reachable from inside the bastion's network).

Mechanically, tying this to Chapter 02, Section 2.5.2: when a connection arrives on the local `8080` listener, the client opens a `direct-tcpip` channel over the existing SSH transport, specifying `internal-db.corp:5432` as the channel's target address in the `SSH_MSG_CHANNEL_OPEN` message. The server, on receiving this, makes its own separate, ordinary TCP connection to `internal-db.corp:5432` and begins relaying bytes between that new TCP connection and the SSH channel. The client-side application (say, a database client pointed at `localhost:8080`) never knows a tunnel is involved — it's just talking to a normal-looking local TCP socket.

The precise trust boundary worth stating explicitly: `internal-db.corp:5432` sees a connection originating from `bastion.example.org`, not from your actual client machine — the server, from its own network's perspective, is the one dialing out. This matters operationally (IP-based access controls on the database, for instance, need to permit the bastion's address, not the original client's) and is a direct, concrete illustration of the general principle from Chapter 02, Section 2.5.2 that a `direct-tcpip` channel's open request specifies an arbitrary destination the *server* reaches — not necessarily one on the server itself.

## 5.4 Remote Forwarding (`-R`): The Server Dials Back Through the Client

```
ssh -R 9000:localhost:3000 user@public-host.example.org
```

This is the structural mirror image, and getting the direction right is the most common source of confusion with this flag. Here, a listening socket is bound on **the remote machine** (`public-host.example.org`), port 9000. Any connection arriving at that remote socket gets relayed back through the SSH tunnel to `localhost:3000` — meaning `localhost` *relative to the client*, i.e., something running on your own machine (a local development server, for instance).

Mechanically: the client, upon establishing the session, sends `SSH_MSG_GLOBAL_REQUEST` with request type `tcpip-forward`, asking the server to bind that listening socket on the server's own behalf. When a connection later arrives at that server-side socket, the server opens a `forwarded-tcpip` channel back to the client — the channel-open direction is *reversed* relative to local forwarding, even though it flows over the exact same underlying transport connection. The client, on receiving this channel-open request, makes its own local connection to `localhost:3000` and relays.

This is the mode most often used to expose something running only on a private development machine to the outside world via a public-facing server — and it is also, for exactly that reason, the mode with the sharpest security implications worth flagging now rather than deferring to Chapter 06: by default, OpenSSH binds the remote listening socket to `localhost` on the server side, meaning only processes on the server itself can reach it. Getting this wrong — via `GatewayPorts yes` in `sshd_config`, which permits the remote listener to bind to all interfaces rather than just loopback — turns a forwarding feature intended for the server's own local use into an open, unauthenticated network exposure of whatever the tunnel leads to, reachable by anyone who can reach the server's network interface. This single misconfigured directive is a genuinely common real-world exposure, precisely because the feature works perfectly and silently until `GatewayPorts` is toggled without fully reasoning through the consequence.

## 5.5 Dynamic Forwarding (`-D`): A General-Purpose SOCKS Proxy

```
ssh -D 1080 user@bastion.example.org
```

Local and remote forwarding both fix the ultimate destination at the moment the tunnel is created — the `internal-db.corp:5432` in Section 5.3's example is baked into the command itself. Dynamic forwarding removes that constraint: instead of a fixed destination, the client starts a **SOCKS proxy** (SOCKS4 and SOCKS5) listening locally on port 1080. Any SOCKS-aware application configured to use `localhost:1080` as its proxy can request a connection to *any* destination at connection time, and the SSH client opens a fresh `direct-tcpip` channel per request, with the destination taken from the application's SOCKS request rather than from anything fixed in the `ssh` command line.

This is architecturally still just Section 5.3's `direct-tcpip` mechanism — the only thing that changed is where the destination address comes from (a SOCKS negotiation, per-connection, rather than a value fixed in the `ssh` invocation). This is worth stating explicitly because it's easy to mistake `-D` for a fundamentally different feature; it is the same channel type, driven by a general-purpose local proxy instead of a single hardcoded target. This is the mechanism behind "SSH as a lightweight VPN" workflows — routing an entire browser's traffic through a SOCKS proxy pointed at `localhost:1080` sends every site the browser visits through the tunnel to the bastion, without needing a separate `-L` tunnel per destination.

## 5.6 X11 Forwarding: A Specialized Case of the Same Pattern

```
ssh -X user@remote-host
```

Worth a brief, precise mention because it's structurally identical to what's already been covered, using the fourth channel type named in Chapter 02, Section 2.5.2. `-X` causes the server to set a `DISPLAY` environment variable in the remote session pointing at a proxy X11 display it creates, and any remote application that opens a connection to that display gets relayed, via an `x11` channel, back to the client's actual local X server. It is, precisely, remote forwarding (Section 5.4) specialized to one particular protocol and application (the X Window System) rather than an arbitrary TCP destination.

`-Y` (trusted forwarding) differs from `-X` (untrusted forwarding) in a security-relevant way worth flagging given this series' authorization-vs-authentication distinction (Chapter 01, Section 1.3.3): untrusted mode applies X11 security extension restrictions limiting what the remote application can do to your local X session (it cannot, for instance, read keystrokes typed into other windows or access your clipboard) — trusted mode removes these restrictions entirely. Because a malicious or compromised remote application with trusted X11 access has a well-documented path to fairly complete compromise of the local desktop session, `-Y` should be treated as roughly equivalent, trust-wise, to running the remote application locally with your own privileges — a genuinely different risk posture from `-X`, not a mere convenience toggle.

## 5.7 Observing a Forwarded Channel Directly

Following the observation-over-assertion discipline (Chapter 01, Section 1.5), a local forward run with verbosity shows the mechanism directly:

```
ssh -vvv -L 8080:internal-db.corp:5432 user@bastion.example.org
```

After the standard handshake and authentication sequence already identified in Chapter 02, Section 2.6 and Chapter 03, Section 3.7, the moment a connection actually lands on the local `8080` listener produces lines like:

```
debug1: Connection to port 8080 forwarding to internal-db.corp port 5432 requested.
debug2: channel 2: new [direct-tcpip]
debug1: channel 2: open confirm rwindow 2097152 rmax 32768
```

The `new [direct-tcpip]` line is the exact channel-open event described mechanically in Section 5.3; the `open confirm` line, with its window and max-packet-size values, is the flow-control setup from Chapter 02, Section 2.5.3 applying identically to this forwarded channel as to any other. There is no separate forwarding-specific flow control — it's the same per-channel window mechanism already established, which is precisely why (per Chapter 02, Section 2.5.3) a slow or congested forwarded connection cannot stall an interactive shell running concurrently over the same SSH connection.

## 5.8 Summary and Bridge to Chapter 06

This chapter completed the claim first made in Chapter 02: port forwarding, in all three of its forms, is the connection layer's channel mechanism applied with a different destination, not a separate protocol feature. Local forwarding (`-L`) has the client dial through the server via `direct-tcpip`; remote forwarding (`-R`) has the server dial back through the client via `forwarded-tcpip`, registered with `tcpip-forward`, and carries the sharpest common misconfiguration risk (`GatewayPorts`) precisely because its default behavior is easy to reason about incorrectly; dynamic forwarding (`-D`) generalizes local forwarding into a SOCKS proxy where the destination is chosen per-connection rather than fixed in advance; and X11 forwarding is a specialized instance of the same pattern, where the trusted/untrusted distinction has real, non-cosmetic security consequences.

Chapter 06 turns from mechanism to discipline: having now covered the full architecture (Chapter 02), authentication (Chapter 03), configuration surface (Chapter 04), and channel-based forwarding (this chapter), Chapter 06 asks what a defensible hardening posture actually follows *as a consequence* of everything established so far — not as an independent checklist, but as the direct operational implications of the threat model from Chapter 01 applied against every mechanism covered since.
