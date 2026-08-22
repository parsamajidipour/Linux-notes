# Linux Networking Deep Dive

An eleven-chapter, mechanism-level reference on the Linux networking stack — built from the physical arrival of a frame on a NIC, through every layer the kernel touches on the way to a socket, and back out again through routing, filtering, encryption, and traffic shaping. Each chapter tries to answer the same underlying question at a different point in that journey: **what is actually happening to this packet, and why does the kernel do it this way rather than some other way?**

This isn't a configuration cookbook. Every distribution already documents its own syntax for `ip`, `nftables`, or `wg` well enough. What's harder to find in one place is the mechanism underneath that syntax — why a firewall rule in the wrong chain silently does nothing, why a routing table isn't evaluated the way a firewall ruleset is, why a VPN tunnel's MTU has to be lower than the physical link's, why TCP's behavior on a given connection reflects that connection's own measured history rather than being a fixed function of configuration. Understanding the mechanism is what turns a wall of symptoms into something derivable.

## How the series is built

Each chapter builds directly on the ones before it, and each one closes by naming, explicitly, what it deliberately left open for a later chapter to pick up — so the series reads as one continuous argument rather than eleven disconnected essays. Code examples, `/proc` files, and command output are used throughout specifically so that claims can be checked against a running system rather than taken on faith; reaching for the same handful of tools (`ip`, `ss`, `tcpdump`, `conntrack`, `tc`) repeatedly across chapters is deliberate, since the state they expose is the same state every chapter is trying to explain from a different angle.

## Chapters

1. **[Introduction and the Networking Stack](01-Introduction-and-the-Networking-Stack.md)**
   Orients the whole series: the four-layer model Linux actually implements (as opposed to the seven-layer diagram everyone memorizes and no one uses), where networking code lives inside the kernel source tree, the socket API as the boundary between application and kernel, and a preview of every mechanism the following ten chapters build out in full — interfaces, routing, Netfilter, the transport layer, DNS, namespaces, tunnels, traffic control, hardening, and troubleshooting.

2. **[The Kernel Network Stack and Data Path](02-The-Kernel-Network-Stack-and-Data-Path.md)**
   The literal journey of a frame from wire to userspace: DMA rings, NAPI's interrupt-mitigation strategy and why a naive one-interrupt-per-packet design collapses under load, softirq processing and per-CPU `%soft` time, and the `sk_buff` structure that carries a packet through every layer without ever needing to be copied. Closes with a five-step sequence for diagnosing unexplained packet loss at this level.

3. **[Interfaces, Addressing, and Routing Tables](03-Interfaces-Addressing-and-Routing-Tables.md)**
   How an address actually attaches to an interface (and why several can, simultaneously, on purpose), the routing table as an LC-trie performing longest-prefix match rather than a list evaluated in order, the neighbor subsystem's own state machine for resolving a next hop's link-layer address, and policy routing — up to 255 independent routing tables, selected by rule, composing into what amounts to several routers layered on one machine.

4. **[Netfilter and Packet Filtering](04-Netfilter-and-Packet-Filtering.md)**
   The five hooks a packet can touch, precisely ordered relative to the routing decision chapter 3 built — the single fact that explains why a `PREROUTING` DNAT rule can change which routing outcome even applies. Covers the `raw`/`mangle`/`nat`/`filter` table split, connection tracking as a state machine genuinely distinct from TCP's own, and a mechanism-level comparison of `iptables` and `nftables` rather than treating one as a syntax facelift of the other.

5. **[Sockets and the Transport Layer](05-Sockets-and-the-Transport-Layer.md)**
   What TCP and UDP actually do, as kernel-resident state machines, to turn IP's best-effort delivery into a reliable byte stream or a simple datagram service. Send/receive buffers and the receive window, adaptive retransmission timing, the genuine difference between flow control and congestion control, slow start and congestion avoidance, CUBIC versus BBR, and the mechanism behind socket options like `TCP_NODELAY` and `SO_REUSEPORT` that are usually reached for by habit rather than understanding.

6. **[DNS Resolution Internals](06-DNS-Resolution-Internals.md)**
   Why "it resolves with `dig` but not in the application" has a precise, mechanical explanation: the Name Service Switch consulted before DNS is even considered, `/etc/hosts` silently overriding it entirely, a local caching daemon sitting in front of the actual upstream recursive resolver, and the multi-hop root-to-authoritative query chain that TTLs govern the caching of at every layer.

7. **[Network Namespaces and Virtual Interfaces](07-Network-Namespaces-and-Virtual-Interfaces.md)**
   What actually makes container networking work: namespaces as independent copies of state (not code), `veth` pairs as a virtual patch cable between them, bridges as software Ethernet switches connecting many namespaces together, and why none of this required inventing a single new packet-processing mechanism beyond what chapters 1 through 4 had already built.

8. **[VPNs and Tunneling](08-VPNs-and-Tunneling.md)**
   Encapsulation as the one idea underlying every tunnel, WireGuard's minimal handshake and transparent roaming versus IPsec's more elaborate, certificate-capable AH/ESP/IKE framework, and — finally explained rather than just named — the exact mechanism behind the "small packets work, large packets hang" MTU symptom chapter 1 flagged in passing.

9. **[Traffic Control and QoS](09-Traffic-Control-and-QoS.md)**
   The queueing discipline as a checkpoint deliberately about choosing what to sacrifice under scarcity: `tbf`'s token-bucket rate limiting, `fq_codel`'s combination of per-flow fairness and bufferbloat mitigation, DSCP marking and the split between setting a priority and actually enforcing it, and HTB's hierarchical bandwidth sharing worked through with concrete numbers.

10. **[Network Security Hardening](10-Network-Security-Hardening.md)**
    A tradeoff-first tour of the sysctl-level defenses sitting under everything else: SYN cookies surviving a flood without storing state, reverse-path filtering and the strict-versus-loose tension with legitimately asymmetric routing, and why nearly every setting here trades some real capability or diagnostic visibility for a security benefit — rarely a universally correct choice independent of a machine's actual role.

11. **[Diagnostics, Debugging, and Troubleshooting](11-Diagnostics-Debugging-and-Troubleshooting.md)**
    Not a new mechanism but the connective method tying the previous ten together: a layered-elimination principle for moving from an unclassified symptom to whichever chapter's specific toolkit the symptom actually calls for, worked through end to end in a single realistic investigation spanning six of the preceding chapters.

## Repository Structure

```
Networking/
    README.md
    01-Introduction-and-the-Networking-Stack.md
    02-The-Kernel-Network-Stack-and-Data-Path.md
    03-Interfaces-Addressing-and-Routing-Tables.md
    04-Netfilter-and-Packet-Filtering.md
    05-Sockets-and-the-Transport-Layer.md
    06-DNS-Resolution-Internals.md
    07-Network-Namespaces-and-Virtual-Interfaces.md
    08-VPNs-and-Tunneling.md
    09-Traffic-Control-and-QoS.md
    10-Network-Security-Hardening.md
    11-Diagnostics-Debugging-and-Troubleshooting.md
```

---

**Status: complete.** All eleven chapters and this README are finished.
