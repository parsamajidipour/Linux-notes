# Linux Networking Deep Dive

An eleven-chapter, mechanism-level reference on the Linux networking stack — built from first principles at the kernel data-path level up through the tools and habits that make troubleshooting a live system tractable.

This isn't a "how to configure your network" guide. Configuration is the easy part; every distribution documents its own syntax for `ip`, `nmcli`, or `netplan` well enough. What's harder to find in one place is *why* the configuration works the way it does — what happens to a packet the instant it lands on a NIC, why a socket option changes behavior at a layer you didn't expect, why `iptables` and `nftables` disagree about ordering, why a DNS query sometimes takes five different paths to resolve the same name. This series tries to close that gap.

## Why this section exists

Most people who work with Linux servers have a working relationship with the network stack that looks like this: routes get set, firewalls get rules added, DNS gets configured, and everything works until the day it doesn't. When it stops working, the debugging usually degrades into cargo-culted commands copied from a forum post from eight years ago. The goal here is the opposite: build a mental model precise enough that when something breaks, the fix is derived, not guessed.

Every chapter tries to answer the same underlying question at a different layer: **what is actually happening to this packet, and why does the kernel do it this way rather than some other way?**

## Chapters

1. **Introduction and the Networking Stack** — orienting the whole series: where networking sits inside the kernel, the layering model Linux actually implements (as opposed to the OSI diagram everyone memorizes and nobody uses), and the questions the rest of the series will answer.
2. **The Kernel Network Stack and Data Path** — the literal journey of a packet from wire to userspace: NIC, driver, `sk_buff`, NAPI polling, softirqs, and where control returns to a process.
3. **Interfaces, Addressing, and Routing Tables** — how the kernel represents a "network interface," how addresses attach to it, and how the routing subsystem decides where a packet goes next.
4. **Netfilter and Packet Filtering (iptables/nftables)** — the hook architecture underneath both tools, why tables and chains are ordered the way they are, and a mechanism-level comparison of the two frameworks.
5. **Sockets and the Transport Layer** — how TCP and UDP are actually implemented as kernel objects, the socket API as a state machine, and the buffer and congestion-control knobs that matter in practice.
6. **DNS Resolution Internals** — the full resolution path from a `getaddrinfo()` call through NSS, resolver configuration, and caching layers, with a framework for diagnosing "it resolves on one machine but not another."
7. **Network Namespaces and Virtual Interfaces** — the primitives that make containers and VMs possible: `netns`, `veth` pairs, bridges, and how isolation is actually enforced at the kernel level.
8. **VPNs and Tunneling** — WireGuard and IPsec examined as data-path mechanisms rather than as configuration recipes: what a tunnel actually does to a packet.
9. **Traffic Control and QoS** — the `tc` subsystem, queueing disciplines, and how the kernel decides which packet leaves the NIC next when there's contention.
10. **Network Security Hardening** — the sysctl knobs that matter, what each one is actually defending against, and the tradeoffs of enabling it.
11. **Diagnostics, Debugging, and Troubleshooting** — a systematic method for isolating network problems, built on the mental model from the previous ten chapters rather than a memorized command list.

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

**Work in progress.**
