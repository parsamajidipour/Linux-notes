# Chapter 1: Introduction and the Networking Stack

## 1. What this chapter is actually for

Before writing a single line about `sk_buff` structures or NAPI polling loops, it's worth being honest about a problem: almost everyone who has worked with Linux for more than a few months already "knows" networking. They know that `ip addr` shows interfaces, that `ip route` shows where packets go, that a firewall is `iptables` or `nftables`, that DNS is "the thing that turns names into IPs." This knowledge is real, and it's enough to run a server for years without incident.

It is also almost entirely operational knowledge — a catalog of commands and their observed effects — rather than a model of the underlying machine. The distinction matters the moment something behaves in a way the catalog didn't predict: a connection that hangs instead of failing cleanly, a route that exists but isn't used, a firewall rule that matches in `iptables -L` but doesn't seem to apply, a DNS query that times out on one host and not an identical one next to it. At that point, operational knowledge runs out, and what's needed is a model of *why* the system behaves as it does at the mechanism level.

This series builds that model, one layer at a time, across eleven chapters. This first chapter has a narrower job: to lay out the shape of the whole stack so that later chapters have something to hang onto. Every subsystem discussed here in a paragraph gets a full chapter later. Nothing here should be treated as complete — treat it as a map that will be filled in as the walk continues, not a self-contained tutorial in miniature.

## 2. The layering model, and why the OSI diagram misleads more than it helps

Every networking course starts with the seven-layer OSI model: Physical, Data Link, Network, Transport, Session, Presentation, Application. It's a genuinely useful conceptual tool for talking about protocols in the abstract, and it's a terrible map of how Linux — or any real operating system — is actually built.

The practical reason is that the OSI model describes a *protocol* layering, while an operating system implements a *code* layering, and the two don't line up cleanly. The kernel has no distinct "Session" or "Presentation" layer as executable code; those concerns, to the extent they exist at all, are handled inside application libraries (TLS is arguably presentation-layer work, and it lives entirely in userspace, often in OpenSSL or a language runtime, never inside the kernel). Conflating the theoretical model with the actual implementation is how people end up confused about where, physically, in a running system, a given piece of packet-handling logic executes.

What Linux actually implements is closer to a four-layer model, and it's worth naming the layers the way the kernel source and the community actually think about them:

```
+-----------------------------------------------------+
| Application layer  (userspace processes)             |
|   - uses sockets: socket(), connect(), send(), recv() |
+-----------------------------------------------------+
| Transport layer     (kernel: TCP, UDP, SCTP...)       |
|   - net/ipv4/tcp.c, net/ipv4/udp.c                    |
+-----------------------------------------------------+
| Network layer       (kernel: IPv4, IPv6, routing)     |
|   - net/ipv4/ip_input.c, net/ipv4/route.c             |
+-----------------------------------------------------+
| Link layer          (kernel: device drivers, Ethernet)|
|   - drivers/net/*, net/ethernet/                      |
+-----------------------------------------------------+
```

This four-layer split (sometimes called the TCP/IP model, though that name undersells how much *more* than TCP/IP now lives in it — this same skeleton carries IPsec, GRE, VXLAN, WireGuard, and dozens of other protocols) maps directly onto directories in the kernel source tree, onto the fields of a captured packet, and onto the mental checklist a competent engineer runs through when debugging: is this a cable/driver problem, an addressing/routing problem, a connection-state problem, or an application-logic problem? That checklist *is* the four-layer model, used as a diagnostic tool rather than a taxonomy for a whiteboard.

One clarification worth making immediately, because it trips people up later: "layer" in this context describes a role, not a fixed piece of hardware or a single function call. A single physical packet, as it moves through the kernel, is examined and modified by code belonging to multiple layers in sequence, in the same execution context, often within the same interrupt handler. The layers are a way of organizing *what the code does*, not a description of physically separate stages with queues between them (although, as later chapters show, there genuinely are queues at certain layer boundaries — that's a separate and important fact, not the definition of layering itself).

### 2.1 A worked example: what "layers" means for a single ping

Consider the `ping` command issuing an ICMP echo request. Tracing it through the model:

- **Application layer**: the `ping` binary constructs an ICMP echo request payload and calls into a raw socket (`socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)`).
- **Network layer**: the kernel's IPv4 code wraps that payload in an IP header — source address, destination address, TTL, protocol number `1` for ICMP — and consults the routing table to decide which interface and next hop to use.
- **Link layer**: the kernel wraps the resulting IP packet in an Ethernet frame (source MAC, destination MAC — resolved via ARP if not already cached), and hands it to the network interface driver.
- The driver places the frame into a hardware transmit ring, and the NIC serializes it onto the wire as electrical or optical signals.

Notice there's no "Transport layer" step in this example — ICMP doesn't use TCP or UDP, and that's precisely the kind of thing the OSI seven-layer picture obscures by implying every packet marches through all seven layers in strict sequence. Real protocols use the layers they need. ICMP rides directly on IP. ARP doesn't use IP at all — it operates at the link layer, resolving IP addresses to MAC addresses before an IP packet can even be framed for Ethernet.

### 2.2 A brief note on where this design came from

The four-layer split isn't a Linux invention — it traces back to the original ARPANET/TCP-IP work and, more directly, to the BSD Unix socket implementation of the early 1980s, which is why the API surface discussed in section 4 is still called "Berkeley sockets" in older texts. Linux's networking stack, when it was first written in the early-to-mid 1990s, deliberately followed the BSD socket API for compatibility — a huge body of existing networked software already assumed that API — while building an entirely independent implementation underneath it. This is worth knowing because it explains an otherwise odd fact: the *interface* (the socket API) has barely changed in forty years, while the *implementation* underneath it has been rewritten and re-optimized continuously, including major overhauls to routing (the transition to the modern FIB/trie-based lookup), to packet filtering (ipchains → iptables → nftables, each a near-total rewrite), and to the transmit/receive path (NAPI, and more recently XDP and io_uring-based networking). The stability of the socket API is precisely what has allowed the internals to be rebuilt repeatedly without breaking existing applications — a design lesson that recurs throughout the kernel generally, not just in networking.

### 2.3 A second worked example: a TCP connection, traced through both directions

The ICMP example in 2.1 was chosen because it's simple — no transport-layer state machine involved. It's worth also tracing a TCP connection, because the round trip exposes something the one-way ICMP example can't: what happens when a layer on the sending side has a corresponding, matching piece of logic on the *receiving* side.

Client issues `connect()` to a server on port 443:

1. **Client, application layer**: `connect()` is called; control passes into the kernel.
2. **Client, transport layer**: TCP allocates connection state (a `struct sock` in `SYN_SENT`), picks an initial sequence number, and constructs a SYN segment.
3. **Client, network layer**: IP wraps the SYN segment with a header addressed to the server, consulting the routing table for the outbound interface and next hop.
4. **Client, link layer**: the segment is framed for Ethernet (or whatever the outbound `net_device` requires) and handed to the driver for transmission.
5. **Wire.**
6. **Server, link layer**: the server's NIC receives the frame, the driver hands it to the kernel, which strips the link-layer framing.
7. **Server, network layer**: IP processing determines the packet is destined for this host's address and hands it up to the transport layer based on the protocol field.
8. **Server, transport layer**: TCP finds (or fails to find) a listening socket bound to port 443. If found, and assuming the listen backlog isn't full, it allocates new connection state in `SYN_RECV`, and constructs a SYN-ACK.
9. Steps 3–4 repeat in reverse for the SYN-ACK heading back to the client, then steps 6–7 repeat on the client to deliver it to the client's transport layer, which moves the client's connection state from `SYN_SENT` to `ESTABLISHED` and sends the final ACK.
10. The server, on receiving that ACK, moves its own connection state from `SYN_RECV` to `ESTABLISHED`.

Only at the end of this exchange — three one-way trips across the link and network layers, each carrying a transport-layer control segment — do both ends agree the connection is open. This is the mechanical reality behind "TCP three-way handshake," and it's worth noticing that every one of the four layers from section 2 did real work in both directions: nothing about this process happens exclusively at one layer.

## 3. Where this lives inside the kernel: the "net" subsystem

The Linux kernel's networking code lives predominantly under `net/` in the kernel source tree, with device drivers under `drivers/net/`. It helps to know the shape of this even before opening a single file, because chapter 2 onward will be pointing at specific pieces of it constantly.

```
net/
    core/        - protocol-independent infrastructure
                   (sk_buff management, netdev registration,
                    the neighbour subsystem, generic socket layer)
    ipv4/        - IPv4, TCP, UDP, ICMP, IGMP
    ipv6/        - IPv6 and its protocol family
    netfilter/   - the packet-filtering/mangling framework
                   underneath iptables and nftables
    sched/       - traffic control: queueing disciplines, classifiers
    bridge/      - Ethernet bridging
    unix/        - AF_UNIX sockets (local IPC, not "networking"
                   in the wire sense, but implemented through the
                   same socket layer)
    xfrm/        - IPsec transform framework
    wireless/    - Wi-Fi (802.11) subsystem
    ...
drivers/net/
    ethernet/    - wired NIC drivers, organized by vendor
    wireless/    - Wi-Fi NIC drivers
    can/         - Controller Area Network (automotive/industrial)
    ...
```

The important structural fact here — one that recurs throughout the whole series — is that `net/core/` exists specifically to hold code that doesn't belong to any one protocol. The socket buffer (`sk_buff`) that carries packet data around is defined and managed in `net/core/skbuff.c`, and it is protocol-agnostic: the same `sk_buff` structure carries an IPv4 TCP segment, an IPv6 UDP datagram, or a raw Ethernet frame. Protocol-specific code (in `net/ipv4/`, `net/ipv6/`, etc.) operates *on* `sk_buff`s that `net/core/` allocates, tracks, and eventually frees. Chapter 2 spends significant time on exactly this structure, because understanding its lifecycle is the single highest-leverage piece of knowledge for understanding everything that happens to a packet inside the kernel.

### 3.1 The lifecycle of a `net_device`, briefly

It's useful to know, even in outline, that a `net_device` has a registration lifecycle, because several confusing behaviors trace back to it. When a driver detects hardware (at boot, or when a USB NIC is plugged in), it calls `register_netdev()`, which adds the device to the kernel's global list of network devices, assigns it an ifindex (the numeric identifier `ip link` shows as the leading number — `2: eth0` means ifindex 2), and fires a `NETDEV_REGISTER` notification that other subsystems (routing, Netfilter, userspace via netlink) can react to. A device can exist in a registered-but-down state (`ip link show` will report it without the `UP` flag) — registration and being administratively "up" are different things, which is why `ip link set eth0 up` is a separate, necessary step after a device merely appears. Virtual devices (`veth`, bridges, VLANs, WireGuard interfaces) go through the exact same registration path as physical ones; the only difference is what code creates them (a driver responding to hardware detection, versus `ip link add` triggering a virtual driver's creation path). This uniform lifecycle is another instance of the same theme from section 5: physical and virtual devices are, to the rest of the kernel, the same kind of object.

### 3.2 Reading netdev statistics directly

Because `net_device` state is exposed broadly, it's worth forming the habit of reading it directly rather than only through summarized tools:

```
$ cat /proc/net/dev
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 91234      812    0    0    0     0          0         0    91234      812    0    0    0     0       0          0
  eth0: 8213942123 6234221 0    3    0     0          0       112 923841233  4123211    0    0    0     0       0          0
```

The `drop` column under Receive here — `3` for `eth0` — means the driver or kernel discarded three incoming frames without delivering them further up the stack, for reasons this file alone doesn't disaggregate (could be a full receive ring, a memory allocation failure, or several other causes covered in chapter 2). A steadily climbing drop count under sustained load is one of the first things worth checking when throughput seems lower than expected, precisely because it's evidence of loss happening *before* TCP or the application ever gets a chance to notice — from an application's perspective a dropped frame just looks like normal network loss to be retransmitted, giving no direct signal that the drop happened locally, on this machine's own NIC, rather than somewhere out on the path.

## 4. The socket: where application code actually touches the network

From the application programmer's side, almost everything about networking reduces to one abstraction: the socket. It's worth being precise about what a socket *is*, because "socket" gets used loosely to mean several different but related things.

At the POSIX API level, a socket is a file descriptor — an integer returned by `socket()` that the rest of the standard I/O machinery (`read()`, `write()`, `close()`, `select()`, `poll()`, `epoll()`) can operate on, because in Linux, as in Unix generally, "everything is a file" extends to network endpoints. This is not merely a cute design philosophy; it has a concrete payload: it means a network connection can be multiplexed in an event loop alongside disk files, pipes, and terminals using the exact same `epoll_wait()` call, without the kernel needing a separate polling mechanism for network I/O.

At the kernel implementation level, a socket is represented by a `struct socket` (the generic, protocol-independent view) wrapping a `struct sock` (the protocol-specific state — for a TCP socket this is actually a `struct tcp_sock`, which itself embeds a `struct inet_connection_sock`, which embeds a `struct inet_sock`, which embeds the base `struct sock`). This nesting is not incidental complexity; it's how the kernel gets code reuse across protocol families without a scripting-language-style inheritance mechanism: each layer of the `struct sock` embedding adds the state relevant to its layer, and generic code can operate on the outer, common fields without knowing about the specific protocol's extensions.

A minimal example makes the API concrete. This is roughly what happens, at the system-call level, when a program opens a TCP connection:

```c
int fd = socket(AF_INET, SOCK_STREAM, 0);       // create the socket
struct sockaddr_in addr = {
    .sin_family = AF_INET,
    .sin_port   = htons(443),
    .sin_addr   = { inet_addr("93.184.216.34") },
};
connect(fd, (struct sockaddr *)&addr, sizeof(addr));  // initiate TCP handshake
write(fd, request, request_len);                 // send data
read(fd, response_buf, sizeof(response_buf));    // receive data
close(fd);                                        // tear down
```

Each of these five calls crosses from userspace into the kernel via a system call trap, and each one touches a different part of the stack:

- `socket()` allocates the `struct socket`/`struct sock` pair and associates it with a file descriptor in the calling process's file descriptor table.
- `connect()` on a `SOCK_STREAM` socket triggers the TCP three-way handshake: the kernel's TCP code constructs a SYN segment, IP wraps it, the link layer frames it, and the process **blocks** (by default) until the handshake either completes or times out — meaning this single call can involve the process sleeping while multiple packets cross the network and interrupts fire on their return.
- `write()` copies the given bytes into kernel socket buffers and hands them to TCP for segmentation and eventual transmission — it does *not* mean the bytes have left the machine, only that the kernel has accepted responsibility for them, which is a distinction that becomes very important in chapter 5 when the subject is buffering and backpressure.
- `read()` blocks until data is available in the socket's receive buffer, then copies it into the userspace buffer.
- `close()` triggers the TCP connection-termination sequence and eventually releases the kernel-side resources.

Every later chapter that touches TCP, UDP, or the socket API is really elaborating on some part of what just happened in those five lines.

## 5. Interfaces: the kernel's notion of "a network"

A `struct net_device` (commonly abbreviated `netdev` in kernel discussions and in tool output — `ip link` output literally lists netdevs) is the kernel's representation of anything that can send or receive packets: a physical Ethernet NIC, a Wi-Fi adapter, a loopback pseudo-device, a VLAN sub-interface, a bridge, a `veth` pair endpoint, a WireGuard tunnel interface, a TUN/TAP device used by a VPN client. All of these — despite being wildly different in what physically happens when a packet is "sent" — implement the same `net_device` interface, meaning higher layers of the stack can treat a WireGuard tunnel and a physical Ethernet card identically for the purposes of, say, attaching an IP address or adding a route.

This uniformity is worth dwelling on because it explains something that surprises people the first time they encounter it: from `ip route` or `iptables`, a container's virtual `veth` interface, a hardware NIC, and a VPN tunnel are visually and operationally indistinguishable. That's not an accident or a limitation — it's the entire design point of the `net_device` abstraction, and it's what makes namespaces, containers, and virtual networking possible at all (the subject of chapter 7).

```
$ ip link show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 ...
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
3: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 ...
4: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
5: veth3a2f1c@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
```

Five entries, four fundamentally different underlying mechanisms (loopback is pure software, `eth0` is a physical NIC driven by a driver talking to real hardware, `wg0` is a cryptographic tunnel that exists only as kernel state, `br0` is a software Ethernet switch, `veth3a2f1c` is one end of a virtual point-to-point Ethernet cable whose other end lives in a different network namespace) — and `ip link` shows them through one uniform lens, because the kernel itself treats them through one uniform lens.

### 5.1 Why the same abstraction covers wildly different devices

It's worth pausing on *why* the kernel bothers unifying loopback, physical NICs, bridges, and tunnels under one structure rather than giving each its own bespoke interface, because the answer explains a lot of downstream design. If routing, Netfilter, and `qdisc` (traffic control) code each had to special-case "is this a physical device or a virtual one," every one of those subsystems would need to know about every new virtual device type ever invented — and new types (VXLAN, WireGuard, gtp, macvlan, ipvlan) keep appearing. Instead, each virtual device type implements a small, well-defined set of operations (`ndo_start_xmit` to transmit a packet being the most important one — "ndo" stands for "net device operations") and the kernel core code calls through that operation table uniformly. A WireGuard interface's `ndo_start_xmit` encrypts and encapsulates before sending; a bridge's version looks up a MAC address table and re-delivers internally; a physical NIC driver's version writes to hardware registers. All of it is invoked the same way by everything above it.

### 5.2 MTU: a property that belongs to the device, and why it matters early

One `net_device` property worth introducing now, because it resurfaces in nearly every later chapter, is the Maximum Transmission Unit (MTU) — the largest frame payload a given device will transmit. A physical Ethernet NIC typically defaults to 1500 bytes; a WireGuard tunnel interface typically needs a smaller MTU (often 1420 or so) precisely because its own packets are themselves encapsulated inside an outer UDP/IP packet, consuming some of the 1500-byte budget on the physical interface underneath. Getting this wrong — setting a tunnel's MTU too high relative to what the underlying physical path can carry — produces a specific, well-known symptom: small packets (a DNS query, an SSH login) work fine, while anything large enough to need fragmentation (loading a substantial web page, or in the worst case, ordinary large TCP transfers if fragmentation or PMTU discovery is also blocked by a misconfigured firewall somewhere in the path) hangs or times out. This particular failure signature — "small stuff works, big stuff hangs" — is common enough, and mysterious enough to someone encountering it for the first time, that it's worth being able to recognize by name; chapter 8 returns to it in detail when covering tunnels specifically.

## 6. Addresses and routing: how the kernel decides where a packet goes

An IP address, in the kernel's data model, is not intrinsically "the identity of a machine" — it's a property attached to a `net_device`, tracked as an `struct in_ifaddr` (IPv4) or `struct inet6_ifaddr` (IPv6) hanging off that device. A single `net_device` can have zero, one, or many addresses attached (`ip addr add 10.0.0.5/24 dev eth0`, run twice with different addresses, gives `eth0` two addresses simultaneously) — a fact that becomes directly relevant later when discussing why a server can legitimately answer for several IPs on one physical interface.

Given a packet that needs to leave the machine, the kernel has to answer: *which interface, and via which next-hop address?* That's the job of the routing subsystem — the Forwarding Information Base (FIB) — and the tool most people reach for is `ip route`:

```
$ ip route show
default via 192.168.1.1 dev eth0
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.42
10.8.0.0/24 dev wg0 proto kernel scope link src 10.8.0.2
```

This says, in order of specificity: anything destined for `10.8.0.0/24` goes out `wg0`; anything destined for `192.168.1.0/24` goes out `eth0` directly (same broadcast domain, no next hop needed); everything else falls through to the default route, which sends it to `192.168.1.1` via `eth0` for that router to figure out from there. The routing lookup itself is a longest-prefix match against this table — the most specific matching route wins, which is precisely why a `/24` for the VPN subnet takes priority over the `/0` default route for traffic actually destined into that subnet, without any explicit priority configuration being needed.

This is a genuinely deep subsystem — chapter 3 covers policy routing (multiple routing tables, selected by rules rather than just destination), and chapter 2 covers what happens to a packet in the kernel *before* it ever reaches this routing decision. For now, the point is narrower: routing is a per-packet decision, made fresh (subject to caching optimizations) for every packet the kernel needs to forward or originate, based on a table that reflects the administrator's (or a routing daemon's) configuration of the FIB.

### 6.1 Multiple tables and policy routing, previewed

The single routing table shown above (`ip route show`, with no table specified) is actually just the default one — Linux supports up to 255 separate routing tables, selected by rules evaluated in priority order (`ip rule show`), a mechanism called policy routing. A common real use: a machine with two internet-facing connections, where traffic that *arrived* on one connection needs to have its *replies* routed back out the same connection (rather than the default route), even if the default route would otherwise be shorter or preferred — because otherwise return traffic from an asymmetric path gets dropped by upstream ingress filtering that expects symmetric routing. This is deferred fully to chapter 3, but it's worth knowing now that "the routing table" understates what's actually available, because otherwise the single-table model in this chapter risks being over-generalized as the whole picture.

### 6.2 Tracing a route in practice

The routing table describes what *should* happen; `traceroute` (or `mtr` for a live, continuously-updating version) is how to observe what a packet's path actually looks like hop by hop, by exploiting IP's Time-To-Live field: each router along the path decrements TTL by one, and a packet arriving with TTL reaching zero triggers an ICMP "Time Exceeded" reply from whichever router discarded it. Sending successive probes with TTL = 1, 2, 3, ... and recording who replies to each maps out the whole path:

```
$ traceroute example.com
 1  192.168.1.1 (192.168.1.1)  0.412 ms
 2  10.20.0.1 (10.20.0.1)  3.114 ms
 3  203.0.113.1 (203.0.113.1)  8.220 ms
 4  * * *
 5  93.184.216.34 (93.184.216.34)  14.902 ms
```

Hop 4 showing three asterisks doesn't necessarily mean that router is unreachable or the path is broken there — it commonly means that particular router is configured to not respond to the TTL-expired probes at all (many networks rate-limit or deliberately suppress this ICMP traffic for operational or security reasons), while it's still forwarding the actual traffic just fine, which is exactly what hop 5 succeeding demonstrates. This is a small but common point of confusion worth clearing up early: a silent hop in a traceroute is not, by itself, evidence of packet loss along the path.

## 7. Netfilter: where policy gets enforced

Somewhere between "the packet arrived" and "the packet was delivered to a socket" (or forwarded onward, or dropped), the kernel offers a set of well-defined interception points where other code — most commonly `iptables` or `nftables` rules, but also connection tracking, NAT, and various security modules — can inspect, modify, or discard the packet. This interception framework is called **Netfilter**, and it's important to separate the concept from the tools built on top of it: Netfilter is the kernel-level hook architecture; `iptables` and `nftables` are two different userspace tools (with two different kernel-side rule representations) that both express policy *through* those hooks.

There are five hook points in the IPv4/IPv6 Netfilter architecture, and their names describe their position in the packet's journey rather than anything about firewalling per se:

```
                    ┌─────────────┐
  incoming packet → │ PREROUTING  │
                    └──────┬──────┘
                           │
                    routing decision
                     /            \
        (destined for      (destined for
         this host)          elsewhere)
              │                    │
        ┌─────▼─────┐      ┌───────▼──────┐
        │   INPUT    │      │  FORWARD     │
        └─────┬─────┘      └───────┬──────┘
              │                    │
      delivered to a               │
      local socket                 │
              │                    │
        ┌─────▼─────┐              │
        │  (locally  │              │
        │  generated │              │
        │  response) │              │
        └─────┬─────┘              │
              │                    │
        ┌─────▼──────┐             │
        │  OUTPUT    │             │
        └─────┬──────┘             │
              │                    │
              └─────────┬──────────┘
                         │
                  ┌──────▼──────┐
                  │ POSTROUTING │
                  └──────┬──────┘
                          │
                  outgoing packet
```

`PREROUTING` fires on every packet arriving on any interface, before the routing decision that determines whether the packet is for this machine or needs forwarding. `INPUT` fires only on packets destined for a local socket on this machine. `FORWARD` fires only on packets this machine is routing through to somewhere else (relevant on a router, a NAT gateway, or a container host bridging traffic). `OUTPUT` fires on packets originated locally by a process on this machine. `POSTROUTING` fires on everything just before it actually leaves an interface. A single TCP connection to a service running on the local machine, from a remote client, touches `PREROUTING` and `INPUT` on the way in, and `OUTPUT` and `POSTROUTING` on the way out for the response — `FORWARD` never fires, because the packet's destination *is* this machine, not somewhere past it.

This hook diagram is exactly why a firewall rule placed in the wrong chain silently does nothing: a rule dropping traffic in the `FORWARD` chain has zero effect on traffic destined for a socket on the local machine, because that traffic never passes through `FORWARD` at all — it goes `PREROUTING` → `INPUT` and stops there. This single fact accounts for a large fraction of "my firewall rule doesn't work" confusion in the wild, and chapter 4 builds the full mental model needed to reason about it precisely, including the ordering of tables *within* a given hook (`raw`, `mangle`, `nat`, `filter` in `iptables` terms) and how `nftables` restructures the same underlying hooks into a more explicit priority-ordered model.

### 7.1 Connection tracking: the piece that makes stateful filtering possible

A rule like "allow established and related traffic back in" — nearly universal in any real firewall configuration — depends on a Netfilter subsystem separate from the filtering rules themselves: **conntrack**, the connection-tracking engine. Conntrack builds and maintains a table of every connection-like flow the machine has seen (a TCP connection identified by its four-tuple, or for UDP and ICMP, a time-limited pseudo-connection inferred from request/reply pairs), independent of whatever `iptables`/`nftables` rules exist. This table is directly inspectable:

```
$ conntrack -L
tcp   6 431999 ESTABLISHED src=192.168.1.42 dst=93.184.216.34 sport=51422 dport=443 \
    src=93.184.216.34 dst=192.168.1.42 sport=443 dport=51422 [ASSURED] mark=0 use=1
```

That single line encodes both directions of one TCP connection, its remaining timeout (`431999`, in an internal unit derived from jiffies), and the `[ASSURED]` flag indicating the kernel has seen enough of a real, bidirectional flow to no longer treat this entry as merely provisional. A rule matching `ctstate ESTABLISHED,RELATED` is checking this table, not re-deriving connection state from the packet in isolation — which is precisely why such a rule can correctly allow a reply packet back in even though no static rule explicitly opens the ephemeral port the reply is addressed to. NAT (both source and destination) is also implemented on top of this same tracking table, because rewriting an address consistently across a whole flow's packets requires exactly the kind of per-flow state conntrack already maintains — a fact that becomes directly relevant in chapter 4 when NAT and port-forwarding rules are covered as an application of, rather than something separate from, connection tracking.

## 8. The transport layer: TCP and UDP as state machines

Everything discussed so far — devices, addresses, routing, Netfilter hooks — operates on individual packets without necessarily caring what came before or after. The transport layer is where the kernel starts tracking *sequences* of packets as belonging to a single logical conversation, and this is where TCP earns its complexity.

TCP is, at its core, a finite state machine per connection, and the famous state names (`SYN_SENT`, `SYN_RECV`, `ESTABLISHED`, `FIN_WAIT_1`, `FIN_WAIT_2`, `TIME_WAIT`, `CLOSE_WAIT`, `LAST_ACK`, `CLOSED`) are not cosmetic labels — they're the literal values of the `sk_state` field inside the kernel's per-connection socket structure, and they're directly observable:

```
$ ss -tan
State       Recv-Q  Send-Q  Local Address:Port    Peer Address:Port
LISTEN      0       128     0.0.0.0:22            0.0.0.0:*
ESTABLISHED 0       0       192.168.1.42:22       192.168.1.10:51422
TIME_WAIT   0       0       192.168.1.42:443      203.0.113.7:38210
CLOSE_WAIT  0       0       192.168.1.42:8080     198.51.100.3:44012
```

Each of these lines is a connection sitting in a specific state of the TCP state machine at the instant `ss` was run, and each state implies something concrete about what has and hasn't happened yet on the wire. `TIME_WAIT`, for instance, is not an error or a stuck connection — it's the kernel deliberately holding onto a closed connection's identity for a bounded period (nominally twice the maximum segment lifetime) specifically to absorb any delayed, duplicate packets from the old connection that might otherwise be misinterpreted as belonging to a new connection reusing the same four-tuple. A server under high connection churn accumulating a large number of `TIME_WAIT` entries is not, by itself, evidence of a bug — it can be entirely expected behavior, and "fixing" it by disabling the protection carelessly (a piece of folk wisdom that circulates constantly) can reintroduce exactly the data-corruption scenario the state exists to prevent.

UDP is deliberately the opposite: it has no connection state machine at all in the same sense (a "UDP socket" that has called `connect()` is a userspace convenience for filtering which peer's datagrams it'll accept and simplifying the `send`/`recv` calls — the network itself still treats each UDP datagram as an entirely independent, unacknowledged unit). Chapter 5 covers both protocols' kernel-side implementation in depth, including exactly where and how buffering, retransmission timers, and congestion control fit into the picture — but the essential thing to internalize now is that TCP's complexity exists entirely in service of one goal: presenting an unreliable, unordered, packet-based network (IP) to the application as if it were a reliable, ordered, byte-stream (a plain file-like descriptor), and every one of those named states is doing part of that job.

### 8.1 Watching a handshake happen

Everything said about the TCP state machine so far can be observed directly with a packet capture, which is worth doing at least once with full attention rather than taking the state-machine description on faith:

```
$ tcpdump -i eth0 -n 'tcp port 443' -c 6
12:04:01.001122 IP 192.168.1.42.51422 > 93.184.216.34.443: Flags [S], seq 1024839201, win 64240
12:04:01.023841 IP 93.184.216.34.443 > 192.168.1.42.51422: Flags [S.], seq 559012, ack 1024839202, win 65160
12:04:01.023902 IP 192.168.1.42.51422 > 93.184.216.34.443: Flags [.], ack 559013, win 64240
12:04:01.024511 IP 192.168.1.42.51422 > 93.184.216.34.443: Flags [P.], seq 1:518, ack 559013
12:04:01.041233 IP 93.184.216.34.443 > 192.168.1.42.51422: Flags [P.], ack 518, win 65160
12:04:01.041877 IP 93.184.216.34.443 > 192.168.1.42.51422: Flags [.], seq 559013:561461, ack 518, win 65160
```

Lines one through three are exactly the three-way handshake traced conceptually in section 2.3 — `[S]` for the client's SYN, `[S.]` for the server's combined SYN-ACK, `[.]` for the client's final ACK — and the sequence numbers visibly increment in a way that matches TCP's byte-counting model (the server's SYN carries sequence number `559012`; the client's ACK acknowledging it is `559013`, one more, because a SYN itself consumes one sequence number even though it carries no payload). Line four (`[P.]`, PSH+ACK) is the client's TLS ClientHello being pushed to the application layer on the far end immediately rather than being held in a buffer. This kind of direct correspondence between the abstract state-machine description and the literal bytes on the wire is exactly the standard of evidence chapter 5 leans on throughout, and it's a habit worth building now: whenever a mental model produces a specific prediction, `tcpdump` is usually the fastest way to check it against reality.

## 9. Name resolution: the layer everyone forgets is a layer

DNS resolution is conspicuously absent from the classic four-layer picture, because it isn't a layer in the packet-processing sense at all — it's a *service* that applications consult, typically before ever opening a socket, to turn a name into the address that routing and the transport layer will actually use. It's easy to miss this distinction and file DNS mentally under "the network layer" simply because it produces IP addresses as output, but the actual DNS query itself, when one is needed, is carried as an ordinary UDP (or, for larger responses and increasingly by default, TCP) payload — meaning a DNS lookup is, from the stack's point of view, just another application using sockets exactly as described in section 4, with its own transport-layer segment traveling through the exact same network- and link-layer machinery as everything else. There is no special-cased "DNS layer" anywhere in the kernel; the entire mechanism described in this section lives in userspace, split across the C library's resolver code, an optional local caching daemon, and whatever upstream resolver that daemon is configured to query. But it deserves inclusion in this introductory tour because, in practice, "the network is broken" is diagnosed as a DNS problem more often than as a routing or firewall problem, and because the resolution path is genuinely more involved than "ask a DNS server."

A call to `getaddrinfo()` (the modern, protocol-agnostic replacement for the older `gethostbyname()`) doesn't go straight to a DNS query. It goes through the **Name Service Switch** (NSS), configured in `/etc/nsswitch.conf`, which can direct the lookup through several sources in a configured order — commonly the local `/etc/hosts` file first, then DNS, but potentially also mDNS, LDAP, or other sources depending on what's installed and configured. Only if and when the configured chain reaches a `dns` entry does an actual DNS query get constructed, and even then it may hit a local caching resolver (`systemd-resolved`, `dnsmasq`, or similar) before ever leaving the machine. Chapter 6 walks this entire path in detail, including why "it resolves with `dig` but not in the application" is a symptom with a small, specific set of causes almost always traceable to exactly this chain being configured or cached differently for the two lookup paths.

## 10. Namespaces: how one kernel pretends to be many

Everything described above — devices, addresses, routes, Netfilter rules, sockets — is, by default, global to the machine: one routing table, one set of interfaces, one firewall ruleset. **Network namespaces** are the kernel mechanism that partitions all of that global state into independent copies, such that a process inside one network namespace can have its own `eth0`, its own default route, its own `iptables` rules, entirely isolated from every other namespace on the same physical machine.

This is, without exaggeration, the single mechanism that makes Docker, Kubernetes, and essentially every container runtime's networking model possible. A container "having its own network" is not a fiction maintained by userspace tooling — it is a real, kernel-enforced network namespace, typically connected to the host's default namespace via a `veth` pair (a virtual, point-to-point pair of interfaces, one end left in the host namespace, often attached to a bridge, the other end moved into the container's namespace and typically renamed `eth0` from the container's point of view). Chapter 7 is dedicated entirely to this mechanism, because it's genuinely load-bearing infrastructure for anyone doing container or virtualization work, and "just restart the container" as a debugging strategy for networking issues tends to paper over misunderstandings that come back later at worse moments.

## 11. IPv6: the same layers, a different network-layer protocol

Everything in sections 6 through 9 was described in IPv4 terms for concreteness, but it's worth being explicit that IPv6 is not a separate stack bolted onto the side of the one described here — it's a different protocol occupying the same network layer, implemented in `net/ipv6/` alongside (not instead of) `net/ipv4/`, sharing the same `net_device` abstraction, the same Netfilter hook architecture (via a parallel `ip6tables`/the IPv6-aware parts of `nftables`), and the same socket API (`AF_INET6` instead of `AF_INET`, with the rest of the `socket()`/`connect()`/`read()`/`write()` pattern from section 4 identical). A dual-stack host — the normal case for most modern Linux systems — runs both protocol implementations simultaneously, with independent routing tables, independent addresses per interface, and, critically, independent Netfilter rule sets: an `iptables` rule blocking a port does nothing to IPv6 traffic on that same port unless the equivalent `ip6tables` (or unified `nftables`) rule also exists, a gap that has been the source of more than a few real security incidents where administrators secured the IPv4 side of a service and never noticed the IPv6 side was wide open.

The most consequential structural difference, from a "how do I reason about this system" standpoint, is that IPv6 addressing was designed around abundance rather than scarcity: a typical IPv6 allocation gives an end network a `/64` — enough addresses that automatic address assignment via Stateless Address Autoconfiguration (SLAAC) is the common case, rather than DHCP-style central assignment. A single interface routinely holds several IPv6 addresses simultaneously and legitimately: a link-local address (always present, scoped only to the local network segment, used for neighbor discovery — IPv6's replacement for ARP), one or more global addresses (routable on the internet), and sometimes a temporary "privacy extension" address that rotates periodically specifically to make long-term tracking of a single device across networks harder. Seeing `ip addr show eth0` list four or five IPv6 addresses on one interface is normal, not a misconfiguration — a fact that surprises people coming from an IPv4 mental model where one interface having one address is the unremarkable default.

## 12. A short list of common misconceptions worth heading off early

A few beliefs are common enough, and wrong enough, that it's worth naming and correcting them explicitly before they quietly shape how later chapters get read:

- **"A firewall rule that matches in `iptables -L` is definitely being applied."** Not necessarily — as section 7 showed, a rule's chain determines which packets it ever sees at all, independent of whether the rule itself is syntactically correct or listed. A perfectly correct rule in the wrong chain enforces nothing.
- **"`ping` working means the network is fine."** `ping` exercises exactly the link, network, and (trivially) the ICMP path — it says nothing about the transport layer, meaning a host can be fully pingable while every TCP port on it is firewalled or the service behind a given port is simply down.
- **"DNS is just a server somewhere that I query."** Section 9 already previewed why this understates the actual resolution path; chapter 6 makes the point in full.
- **"A dropped packet on my NIC is the network's fault."** Section 3.2 showed that drop counters are local, kernel/driver-side statistics — a rising local drop count implicates this machine's own receive path, not necessarily anything upstream.
- **"IPv6 doesn't matter if I haven't configured it."** As section 11 covers, a dual-stack Linux host typically has IPv6 addresses and connectivity by default via SLAAC, whether or not an administrator ever explicitly set it up — including, potentially, an entirely unfirewalled IPv6 path sitting next to a carefully firewalled IPv4 one.
- **"TCP's job is just to retransmit lost packets."** That's one part of the job; sections 8 and 8.1 only scratched the state-machine surface, and chapter 5 covers flow control and congestion control as equally central responsibilities, not afterthoughts.

## 13. Glossary of terms introduced in this chapter

A short reference, since several of these terms recur, unexplained, starting in the very next chapter:

- **`net_device` / netdev** — the kernel's internal representation of any network interface, physical or virtual (section 5).
- **FIB (Forwarding Information Base)** — the kernel's routing table data structure; "the routing table" in casual speech (section 6).
- **Netfilter** — the kernel hook architecture underlying `iptables`/`nftables` (section 7).
- **conntrack** — the connection-tracking subsystem that gives Netfilter and NAT their statefulness (section 7.1).
- **`sk_buff`** — the kernel's universal packet-buffer structure, previewed here and covered fully in chapter 2.
- **NSS (Name Service Switch)** — the configurable chain of lookup sources consulted before/alongside DNS (section 9).
- **network namespace** — the kernel mechanism partitioning network state into isolated copies, underlying containers (section 10).
- **`veth`** — a virtual, point-to-point pair of Ethernet-like interfaces, commonly used to connect a namespace to the host (section 10).
- **MTU (Maximum Transmission Unit)** — the largest payload a given device will transmit without fragmentation (section 5.2).
- **SLAAC (Stateless Address Autoconfiguration)** — the IPv6 mechanism by which a host can assign itself an address without a central DHCP-style server (section 11).

## 14. What's deliberately being deferred

To keep this chapter honest about its scope, it's worth listing, explicitly, what has been mentioned only in passing and will get real treatment later, so nothing here is mistaken for a complete treatment:

- The exact mechanics of packet reception at the driver level — interrupts, NAPI polling, and why high packet rates change the kernel's strategy for handling them — is chapter 2's entire subject.
- Policy routing (multiple tables, rule-based selection) beyond the single default table shown above is chapter 3.
- The full Netfilter table/chain model, connection tracking, and NAT are chapter 4.
- TCP's congestion control algorithms, buffer tuning, and the practical meaning of socket options like `SO_REUSEPORT` and `TCP_NODELAY` are chapter 5.
- The caching layers and failure modes of DNS resolution are chapter 6.
- The full namespace/veth/bridge picture, including how it composes with Netfilter for container networking, is chapter 7.
- Tunnels — how WireGuard and IPsec actually transform a packet — are chapter 8.
- Traffic shaping and queueing disciplines are chapter 9.
- Hardening sysctls and what each genuinely defends against are chapter 10.
- A systematic troubleshooting method that draws on everything above is chapter 11, and is, in a sense, the payoff for having read the other ten.

## 15. A note on eBPF and XDP: the stack is no longer purely fixed-function

Everything described so far treats the kernel's networking code as fixed logic — routing does routing, Netfilter does filtering, TCP does transport, and an administrator's only lever is configuration (routes, rules, sysctls). That picture was completely accurate for most of Linux's history, and it's still the right starting mental model, but it's no longer the whole story, and this chapter would be misleading if it didn't flag the exception.

**eBPF** (extended Berkeley Packet Filter) allows small, kernel-verified programs — not configuration, actual compiled code — to be attached at specific points in the networking stack and run in-kernel, without needing a kernel source change or a reboot. **XDP** (eXpress Data Path) is one especially aggressive attachment point: an eBPF program hooked in right at the driver, before the kernel has even allocated a full `sk_buff` for the incoming frame, letting a program decide to drop, redirect, or pass a packet at close to the earliest possible moment in its journey through the machine. This is how modern high-performance load balancers, DDoS mitigation systems, and some container networking implementations (Cilium being the best-known example) achieve packet-processing rates that would be difficult or impossible to reach by only adding more `iptables` rules — an XDP program dropping unwanted traffic can do so before most of the per-packet overhead described in chapters 2 through 4 has even been paid.

This chapter and the ten that follow it deliberately focus on the traditional, fixed-function stack, because that model is what almost all Netfilter rules, routing configuration, and socket-level tuning actually operate on, and it remains the correct foundation even for someone who will eventually work with eBPF-based tooling — a program attached via XDP still has to interact correctly with the routing, conntrack, and socket layers it's bypassing or accelerating, and reasoning about that interaction requires exactly the mental model this series builds. eBPF and XDP are mentioned here mainly so their absence from the rest of the series isn't mistaken for the topic being unimportant; they're simply a distinct, more specialized subject that presupposes everything covered in these eleven chapters rather than replacing it.

## 16. A closing note on method

One deliberate choice running through this series: wherever possible, claims are tied to something observable — a `/proc` file, a tool's output, a specific kernel source file — rather than left as assertions to take on faith. The Linux networking stack is unusually well-instrumented compared to many other parts of the kernel; `/proc/net/`, `ss`, `ip -s`, `nstat`, and `ethtool -S` between them expose an enormous amount of live internal state, and a recurring habit worth building is reaching for that live state to *check* a mental model rather than only reasoning about it in the abstract.

This has a practical consequence for how to read the chapters that follow. Each one will, at some point, describe a mechanism and then immediately show a command or a `/proc` entry that makes that mechanism visible on a running system. The intent is not decoration — it's that the command *is* the verification of the claim next to it. Running these commands on an actual machine while reading, rather than treating them as illustrative snippets, is the difference between acquiring a model that can be checked against reality and acquiring one more set of assertions to memorize. Several of the commands shown so far — `ip link`, `ip route`, `ss -tan`, `conntrack -L`, `tcpdump`, `traceroute` — will keep reappearing throughout the series, each time revealing a bit more of what they were already showing, because the underlying kernel state they read from is the same state every later chapter is trying to explain from a different angle.

It's also worth being honest that not every environment will show identical output to the examples above. Interface names vary by distribution and network hardware (`enp3s0`-style predictable naming versus the older `eth0` convention), some tools require root privileges or specific capabilities to run at all, and container or minimal environments may lack some of the diagnostic utilities shown until they're explicitly installed (`iproute2`, `conntrack-tools`, and `tcpdump` are the three package names to reach for on most distributions if any of these commands come back as "command not found"). None of that changes the underlying mechanism being described — only the exact names and packaging of the tools used to observe it — but it's worth reconciling before concluding a given example "doesn't apply here."

Chapter 2 begins putting this into practice immediately, starting from the moment a frame's electrical signal is recognized by a NIC and ending at the point a `sk_buff` is queued for a waiting process. That chapter is, deliberately, the most mechanically detailed of the entire series — everything from chapter 3 onward assumes the reader has a working model of `sk_buff` lifecycle, NAPI polling, and softirq processing, so it rewards being read carefully rather than skimmed.
