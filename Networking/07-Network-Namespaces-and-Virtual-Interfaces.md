# Chapter 7: Network Namespaces and Virtual Interfaces

## 1. What this chapter is actually for

Every chapter so far has quietly assumed a single, global set of network state: one list of interfaces, one routing table (or, with policy routing, a small handful selected by rule), one Netfilter ruleset, one DNS configuration. That assumption has been flagged as a simplification repeatedly — chapters 1, 3, and 6 each mentioned network namespaces in passing as the mechanism that partitions this global state into independent copies — and this chapter is where that mechanism finally gets its own full treatment.

This matters for a reason that's easy to underappreciate until it's been felt directly: container networking, which underlies Docker, Kubernetes, and essentially every modern container runtime, is not a separate, container-specific networking model bolted onto Linux. It is the exact same mechanisms this entire series has already covered — `net_device`s, routing tables, Netfilter hooks, DNS resolution — simply instantiated multiple times, in isolated, independent copies, composed together with a small number of additional primitives (namespaces themselves, `veth` pairs, and bridges) that this chapter introduces. Someone who has followed chapters 1 through 6 already understands the overwhelming majority of what makes container networking work; this chapter's job is to supply the remaining, comparatively small piece — how one kernel maintains several independent instances of everything already covered, and how those instances get connected back together when needed.

It's worth naming, upfront, a specific misconception this chapter aims to correct: it's tempting to think of a container's networking as somehow "fake" or "simulated" relative to a physical machine's — a lightweight imitation of real networking rather than the genuine article. Nothing about that framing survives this chapter's material. A container's `veth` interface is a real `net_device`, participating fully in the same `sk_buff` lifecycle, the same routing lookups, the same Netfilter hook traversal as any physical interface — the only thing "virtual" about it is what sits at the very bottom of the stack, where a physical NIC would otherwise be. Everything above that point is the identical machinery, doing identical work, on identically real (if namespace-scoped) kernel state.

## 2. Network namespaces: what actually gets duplicated

A network namespace is a kernel-enforced partition of essentially all the global networking state discussed in this series: `net_device`s (with the narrow exception of certain devices that can be explicitly moved between namespaces, covered in section 4), routing tables and rules, Netfilter tables and conntrack state, and even certain `/proc/net/` and `/sys/class/net/` entries, which reflect only the calling process's own namespace rather than some machine-wide view. A process inside a network namespace that runs `ip link show` sees only the interfaces that namespace has — not the host's physical NIC, not other containers' virtual interfaces, nothing outside its own partition — and this isn't an access-control restriction layered on top of a shared view; it's a genuinely separate, independent instance of the underlying kernel data structures chapters 1 through 4 described.

### 2.1 Creating and entering a namespace directly

It's worth seeing this mechanism used directly, without a container runtime's abstraction on top of it, because the underlying primitive is simpler than the layers built on it might suggest:

```
$ ip netns add myns
$ ip netns exec myns ip link show
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN
```

`ip netns add` creates a new, empty network namespace — note that even `lo`, the loopback interface every namespace gets automatically, starts in a `DOWN` state, unlike the host's own `lo`, which is essentially always administratively up by convention; a genuinely fresh namespace has no working network connectivity at all, not even to itself, until explicitly configured. `ip netns exec myns <command>` runs a command inside that namespace's network context — the command's *process* namespace, filesystem view, and everything else remain entirely normal; only the network-related kernel state it sees is swapped to the new namespace's independent copy. This partial nature is worth being explicit about: network namespaces are one specific namespace type among several Linux provides (others cover process IDs, mount points, users, and more), and a container runtime typically combines several of these namespace types together to produce the fuller isolation a container needs, of which network namespaces are only one piece.

### 2.2 What doesn't get duplicated: kernel code, only kernel *state*

A crucial, easily-missed point: creating a network namespace duplicates *state* — the specific data structures (net_device lists, routing tables, and so on) chapters 1 through 4 described — not *code*. There is exactly one copy of the kernel's TCP implementation, one copy of the Netfilter hook-processing logic, one copy of the routing lookup algorithm, running on the machine regardless of how many namespaces exist; each namespace simply gives that single shared code its own independent set of data to operate on. This is why network namespaces are comparatively cheap to create and destroy — dozens or hundreds of them on one machine, as is routine on a container-heavy host, impose memory and bookkeeping overhead proportional to the *state* each namespace holds (however many interfaces, routes, and connections it actually has), not to any duplicated *code*, which remains entirely shared and unaffected by how many namespaces exist.

### 2.3 Persistent namespaces and `/var/run/netns`

Section 2.1's `ip netns add` command does more than call the underlying kernel primitive — it also creates a bind-mounted reference under `/var/run/netns/`, which is what lets a namespace persist and remain addressable by name (`myns`) even after every process that was running inside it has exited. This is worth understanding because the underlying kernel mechanism (`clone()` with the `CLONE_NEWNET` flag, or the related `unshare()` syscall) doesn't inherently name or persist a namespace at all — a namespace created directly via one of these syscalls exists only as long as some process (or, more precisely, some open file descriptor referencing it) keeps it alive, and vanishes the moment nothing references it anymore, exactly like any other kernel resource without an explicit persistence mechanism. `ip netns`'s bind-mount trick is a userspace convenience specifically working around this — it keeps a reference to the namespace alive via the mounted file itself, letting `ip netns exec myns ...` find and enter that specific, still-alive namespace by name at any later point, rather than requiring some process to have stayed running inside it the whole time. Container runtimes generally don't use `/var/run/netns` directly — a running container's own main process (or a lightweight placeholder process kept alive specifically for this purpose) serves the equivalent "keep the namespace alive" role for as long as the container itself is considered to exist.

## 3. `veth` pairs: connecting an isolated namespace back to the world



A namespace with only a `DOWN` loopback interface, as created in section 2.1, has no way to communicate with anything outside itself — which is, in isolation, not very useful. The **`veth` pair** is the primitive that solves this: a virtual, point-to-point pair of Ethernet-like interfaces, created together, where anything transmitted on one end appears, essentially instantaneously and entirely in-kernel, as received on the other end — a virtual patch cable, with each end capable of living in a different network namespace.

### 3.1 Creating and wiring a `veth` pair

```
$ ip link add veth-host type veth peer name veth-ns
$ ip link set veth-ns netns myns
```

This creates two linked interfaces, `veth-host` and `veth-ns`, and then moves `veth-ns` into the `myns` namespace created earlier — `veth-host` remains in the original (typically the host's default) namespace. From this point, each end behaves, from its own namespace's perspective, like an ordinary `net_device` (chapter 1, section 5) — it can be assigned an address, brought up, and have routes attached to it, exactly as any physical interface would, with every mechanism from chapters 2 through 4 applying to traffic on it identically. The only thing distinguishing a `veth` interface from a physical NIC, mechanically, is what happens when a frame is transmitted on it: rather than a driver handing the frame to real hardware (chapter 2, section 5.1's `ndo_start_xmit`), a `veth` device's transmit function simply delivers the frame directly into the paired interface's receive path, in the other namespace, without any physical medium involved at all.

### 3.2 A minimal worked example: connecting a namespace to the host

Completing the setup from sections 2.1 and 3.1 into something that actually works end to end:

```
$ ip addr add 10.200.0.1/24 dev veth-host
$ ip link set veth-host up

$ ip netns exec myns ip addr add 10.200.0.2/24 dev veth-ns
$ ip netns exec myns ip link set veth-ns up
$ ip netns exec myns ip link set lo up

$ ping -c 1 10.200.0.2
$ ip netns exec myns ping -c 1 10.200.0.1
```

Both pings succeed, and it's worth being precise about what's actually happening mechanically when they do — this is a genuine, if minimal, exercise of essentially the entire stack chapters 1 through 4 described, just entirely within one physical machine's kernel: the ICMP echo request from the host's namespace is constructed, routed (chapter 3) via the directly-connected route the kernel auto-derived from `veth-host`'s address, handed to `veth-host`'s transmit function, delivered directly into `veth-ns`'s receive path (crossing the namespace boundary at this exact point), processed by IP within `myns`'s independent routing and Netfilter state (chapters 3 and 4, now operating on `myns`'s own copy of that state), recognized as destined for `myns`'s own address, and answered — with the reply retracing the same path in reverse. No physical wire, no NIC hardware, and no driver in the chapter 2 sense were involved anywhere in this exchange, yet every layer of processing this series has described up through chapter 4 genuinely occurred.

### 3.3 What `veth` traffic reveals about chapter 2's data path in a virtual context

It's worth being precise about how much of chapter 2's data-path detail genuinely applies to a `veth` interface, since it's a virtual device rather than a physical one. A `veth` interface participates fully in `sk_buff` handling (chapter 2, section 4) — a frame transmitted on one end is still represented as an ordinary `sk_buff`, still passes through GRO/GSO consideration, and still triggers NAPI-style processing on the receiving end (a `veth` device implements its own NAPI poll function, even though there's no physical hardware or DMA ring underneath it — the "packet arrived" signal comes from the paired interface's transmit call directly, rather than a hardware interrupt, but the same softirq-based processing model from chapter 2, section 3, still applies). What's genuinely absent is anything at or below the DMA/ring-buffer layer (chapter 2, sections 2.1–2.2) — there's no physical medium, no interrupt coalescing to tune, and no NIC hardware offload capabilities (checksum offload, TSO) to speak of, though `veth` devices do commonly report *software* checksum offload support, since the "hardware" doing the transmission is, in this case, just another piece of kernel code running on the same CPU, for which computing a checksum is essentially free relative to a real NIC's marginal cost of the same operation. This means chapter 2's diagnostic sequence (its section 9) applies to `veth` traffic with the physical-layer-specific steps (checking `ethtool -S` for hardware error counters, for instance) simply not being relevant — there's no hardware to report errors from — while the softirq/NAPI-budget-exhaustion checks remain exactly as applicable to a busy `veth` interface moving high volumes of inter-container traffic as they would be to a physical NIC under similar load.

## 4. Bridges: connecting more than two namespaces together



A single `veth` pair connects exactly two endpoints — adequate for one namespace talking to the host, but insufficient the moment more than one namespace needs to communicate with each other and with the host, which is the ordinary case for any real container host running more than a single container. The **bridge** — a software Ethernet switch, briefly introduced in chapter 1's `net_device` example — is the mechanism that generalizes this to many participants.

### 4.1 What a bridge actually does

A Linux bridge, created as its own `net_device` (`ip link add br0 type bridge`), maintains a MAC-address-to-port forwarding table, exactly as a physical Ethernet switch does: a frame arriving on one port (an interface attached to the bridge) gets forwarded out whichever other port the bridge believes holds the destination MAC address, learned by observing source addresses on frames as they arrive, or flooded to all ports if the destination isn't yet known. This operates entirely at the link layer (chapter 1's four-layer model) — a bridge has no awareness of IP addresses, routing, or anything above Ethernet framing; it is, deliberately, a much simpler device than a router, precisely because switching (forwarding based on link-layer addresses within one logical network segment) is a genuinely simpler problem than routing (forwarding based on network-layer addresses, potentially across many distinct segments).

### 4.2 The standard container-networking topology

Combining sections 2 through 4's primitives produces the topology essentially every container runtime's default "bridge networking" mode implements:

```
    Host namespace                    Container namespace A
   ┌──────────────┐                  ┌──────────────────┐
   │              │                  │                    │
   │   br0        │◄──veth-hostA────►│   veth-nsA (eth0)  │
   │  10.200.0.1  │                  │   10.200.0.2       │
   │              │                  │                    │
   │              │                  └──────────────────┘
   │              │                  ┌──────────────────┐
   │              │                  │Container namespace B│
   │              │◄──veth-hostB────►│   veth-nsB (eth0)  │
   │              │                  │   10.200.0.3       │
   └──────────────┘                  └──────────────────┘
```

Each container gets its own `veth` pair, with the host-side end attached as a port on the bridge, rather than directly addressed itself — the bridge, not any individual `veth-host*` interface, holds the `10.200.0.1` address that serves as this virtual network's gateway. Traffic between two containers on the same bridge (container A to container B) is switched directly by the bridge at the link layer, without ever needing to leave the host or be routed at the IP layer at all — a genuinely fast, low-overhead path, exactly analogous to two devices plugged into the same physical Ethernet switch communicating without needing any router involved. Traffic from a container destined *outside* this virtual network (to the broader internet, say) does need IP-layer routing and typically NAT (chapter 4's `MASQUERADE`, applied to traffic leaving the bridge's subnet via the host's own external interface) — this is precisely the mechanism behind the "container has its own private IP, but can still reach the internet" behavior that's the default in essentially every container runtime, built entirely from mechanisms this series has already covered individually, composed together.

### 4.3 Why `br_netfilter` (chapter 4, section 8) matters here specifically

Chapter 4's section 8 flagged, in the abstract, that bridged traffic bypasses ordinary Netfilter hooks unless `br_netfilter` is loaded and its associated sysctls enabled. This chapter's topology is precisely the concrete case that abstract point was anticipating: without `br_netfilter`, traffic between two containers attached to the same bridge (section 4.2's container A and B) would never traverse `FORWARD`-chain Netfilter rules at all, regardless of how those rules were written, because that traffic is being switched at layer 2 between bridge ports, never touching the IP-layer `FORWARD` hook a firewall rule would ordinarily rely on. Every mainstream container runtime that offers network-level isolation between containers on the same bridge depends on `br_netfilter` being enabled specifically to make this traffic visible to Netfilter at all — a genuinely load-bearing dependency, and one worth checking directly (`sysctl net.bridge.bridge-nf-call-iptables`) on any container host where inter-container firewall rules seem to be silently ignored.

### 4.4 Bridges versus routing between namespaces: a genuine design choice

It's worth being explicit that connecting multiple namespaces via a shared bridge (section 4.2) isn't the only possible topology — an alternative design would give each namespace's `veth` pair its own distinct subnet, with the host routing (chapter 3) between them at the IP layer rather than switching them at the link layer via a shared bridge. Both approaches genuinely work, and understanding why the bridge model is the overwhelmingly common default is worth a moment's thought: switching is a cheaper, simpler operation than routing (no routing-table lookup, no TTL decrement, no per-hop processing at all — chapter 4's hook diagram doesn't even apply to purely link-layer-switched traffic, as chapter 4's section 8 covered), and a shared subnet lets every container reach every other container without any explicit routing configuration needing to be added each time a new container joins — simply attaching a new `veth` pair's host-side end to the existing bridge is sufficient, with no routing table on the host needing any update at all for containers to reach each other.

The routed alternative isn't merely hypothetical, though — it's precisely the model some more elaborate container networking setups (certain Kubernetes CNI plugins, in particular) use instead, specifically because it composes more cleanly across multiple physical hosts: a bridge is fundamentally a single-host, single-broadcast-domain construct, while a routed model, giving each host's containers their own distinct subnet, extends naturally to a multi-host cluster via ordinary routing (each host simply needs a route for every other host's container subnet, pointing at that host), without requiring any single, shared broadcast domain spanning multiple physical machines at all — a genuine architectural tradeoff between the bridge model's simplicity within one host and the routed model's cleaner extension across many.

### 4.5 The bridge's own address and its role as more than just a gateway

Section 4.2's topology gave the bridge itself an address (`10.200.0.1`), functioning as the default gateway for every attached namespace. It's worth being precise about what this address actually represents mechanically: a Linux bridge, despite being conceptually a link-layer device, can genuinely hold an IP address directly, because the bridge `net_device` itself, like any other `net_device` (chapter 1, section 5), supports having addresses attached to it (chapter 3, section 2). Traffic destined for the bridge's own address is delivered locally, exactly like traffic to any other of the host's own addresses (chapter 3, section 6.1's loopback discussion applies by the same underlying mechanism, just via the bridge device rather than `lo`) — and it's this same address that a container's default route (section 5.1) points at as its gateway, meaning a container reaching "outside" its own subnet sends that traffic to the bridge's address first, where the host's own routing table (now genuinely consulted, since this traffic isn't destined for another port on the same bridge) takes over and forwards it onward, subject to the IP-forwarding requirement covered in section 6.

## 5. Namespace-scoped state: what chapters 3, 4, and 6 look like from inside one



Each preceding chapter's model applies fully and unmodified inside any one namespace — this section is less about new mechanism and more about making explicit what "fully and unmodified" actually means in the container context, since it's easy to assume something must be different without pinning down exactly what.

### 5.1 Routing inside a namespace

`myns` from section 2, once `veth-ns` is configured (section 3.2), has its own routing table, entirely independent of the host's — `ip netns exec myns ip route show` displays only routes relevant to that namespace, typically just a directly-connected route for `veth-ns`'s own subnet and, in a fuller container setup, a default route pointing at the bridge's address as gateway. This is precisely chapter 3's FIB model, instantiated once per namespace, with no new routing concept required — the "closing note" at the end of chapter 3 flagged this composition in advance, and this chapter has now supplied the concrete mechanism (namespaces plus `veth` pairs plus bridges) that makes it real rather than merely theoretical.

### 5.2 Netfilter and conntrack inside a namespace

Similarly, `myns` maintains its own, entirely independent Netfilter tables and conntrack state (chapter 4) — a connection tracked as `ESTABLISHED` inside a container's namespace has no bearing on, and is invisible to, conntrack state in the host's namespace or any other container's namespace, even for what might appear to be "the same" logical connection from an external client's point of view (the client's connection genuinely terminates, gets NAT'd, and is re-established as a *different* tracked flow, from the host's own conntrack perspective, in the common case where the host is doing NAT for containers behind it). This is worth knowing specifically because it explains why `iptables`/`nftables` rules configured inside a container have zero effect on the host's own filtering, and vice versa — an administrator wanting to filter traffic to a specific container from the host side needs a `FORWARD`-chain rule in the *host's* namespace (matched against the container's bridge-assigned address), not a rule configured from within the container itself, which only ever sees its own, entirely separate copy of this machinery.

### 5.3 DNS inside a namespace

Chapter 6's entire resolution chain — NSS, `/etc/resolv.conf`, a local caching layer, and the recursive-resolution process itself — is, from a namespace's point of view, just ordinary configuration living in that namespace's own filesystem view (container runtimes typically mount a container-specific `/etc/resolv.conf`, often populated with the runtime's own embedded DNS server address for resolving other containers by name, rather than the host's own resolver configuration). This is precisely why a container can have completely different DNS behavior than its host — a different set of nameservers, a different `search` domain, even resolving names (other containers, by their assigned names) that mean nothing at all outside that specific container's namespace and DNS configuration — with every mechanism chapter 6 described applying identically, just against namespace-specific configuration and, in the case of an embedded runtime DNS server, an entirely custom (if often quite simple) implementation of the resolver side of that chapter's model.

## 6. IP forwarding and NAT: the host's role as a router for its own containers

Section 4.2's topology described the host forwarding container-originated traffic out to the broader network. This depends on a specific piece of kernel configuration this series hasn't yet needed to mention explicitly: **IP forwarding** must be enabled (`net.ipv4.ip_forward = 1`, and its IPv6 equivalent) on the host, because without it, the kernel's routing logic (chapter 3) will not forward packets between interfaces at all — only process packets destined for its own addresses, dropping anything that would otherwise need forwarding to some other interface.

This is worth flagging explicitly because it's a genuinely common setup omission: a host with everything else configured correctly — bridge, `veth` pairs, NAT rules — but with IP forwarding left disabled, will still successfully let a container reach the host itself (traffic destined for the bridge's own address doesn't need forwarding, per the `INPUT`-chain distinction chapter 1 first introduced), while any traffic the container sends *toward the broader internet* is silently dropped at the routing stage, before ever reaching the NAT rule that would otherwise have handled it — a specific, checkable configuration gap (`sysctl net.ipv4.ip_forward`) worth ruling out early in any "containers can reach the host but not the internet" investigation, precisely because its symptom is easily mistaken for a NAT or firewall misconfiguration when the actual gap sits one layer earlier, at the routing decision chapter 3 described, never even reaching the NAT rule that a firewall-focused investigation might otherwise focus on first.

### 6.1 Diagnosing the "container reaches host, not internet" symptom directly

Section 6's closing paragraph flagged a specific, common symptom and its likely cause. It's worth turning that into a concrete diagnostic sequence, in the same spirit as previous chapters' closing checklists, since it's a genuinely frequent real-world container-networking complaint:

1. Confirm connectivity to the bridge/gateway address itself from inside the container (`ping 10.200.0.1` in section 4.2's topology) — success here confirms the `veth`/bridge wiring from sections 3 and 4 is intact, narrowing the problem to something beyond this chapter's link-layer mechanisms.
2. Check `sysctl net.ipv4.ip_forward` on the host — a value of `0` here is, by itself, sufficient to fully explain "reaches the gateway, nothing beyond it," independent of anything else being configured correctly.
3. If forwarding is enabled, confirm a NAT (`MASQUERADE`, chapter 4 section 4.2) rule actually exists for traffic leaving the container subnet via the host's external interface — a missing NAT rule produces a related but distinct symptom: the container's traffic reaches the host, gets routed and forwarded correctly, but arrives at the actual external destination still bearing the container's private, non-globally-routable source address, which the destination (or, more likely, some router along the path) has no way to send a reply back to.
4. If both forwarding and NAT are configured correctly, confirm `br_netfilter` (section 4.3) isn't inadvertently blocking this specific traffic — a firewall rule intended for one purpose, but written broadly enough to also catch outbound container traffic passing through the same `FORWARD` chain, is a real, if less common, fourth possibility once the first three, more likely causes have been ruled out.

This sequence deliberately mirrors the general diagnostic discipline this series has built from chapter 2 onward: check the most fundamental, "did this even reach the next layer at all" question first (step 1), then work outward through progressively more specific configuration (steps 2 through 4), rather than jumping directly to the most complex possible explanation before ruling out the simpler ones a single `sysctl` check or rule inspection can eliminate in seconds.

## 7. What's deliberately being deferred



- Overlay networking — mechanisms like VXLAN that let containers on *different physical hosts* appear to share one flat virtual network, extending this chapter's single-host bridge model across a real network — is a genuinely distinct, considerably more involved subject, not covered in this series.
- Container-runtime-specific networking modes beyond the default bridge model described here (host networking, where a container shares the host's namespace directly rather than getting its own; more elaborate CNI-plugin-based topologies in Kubernetes environments) build on this chapter's primitives but involve orchestration logic outside this chapter's kernel-mechanism-focused scope.
- IPVLAN and MACVLAN, alternative virtual-interface mechanisms distinct from the `veth`-plus-bridge model this chapter focused on, offering different isolation and performance tradeoffs, are mentioned here only to flag that `veth`/bridge is not the *only* way to give a namespace network connectivity, without elaborating on the alternatives further.
- Traffic control and qdiscs (chapter 9) apply to `veth` and bridge interfaces exactly as they do to physical ones, and can be used to rate-limit or prioritize traffic to and from specific containers — a natural extension of this chapter's topology that chapter 9 will cover from the traffic-control side.

## 8. Glossary of terms introduced in this chapter

- **network namespace** — a kernel-enforced, independent copy of essentially all networking state: interfaces, routing tables, Netfilter/conntrack state, and namespace-scoped configuration files (section 2).
- **`CLONE_NEWNET` / `unshare()`** — the underlying kernel primitives that create a network namespace; `ip netns` is a userspace convenience layered on top, adding persistence and naming (section 2.3).
- **`veth` pair** — two linked virtual Ethernet-like interfaces, forming a point-to-point link, with each end capable of residing in a different namespace (section 3).
- **bridge** — a software Ethernet switch, forwarding frames between attached ports based on a learned MAC-address table, operating entirely at the link layer (section 4.1).
- **`br_netfilter`** — the kernel module/sysctl combination required for bridged traffic to traverse ordinary Netfilter hooks, without which inter-container firewall rules on the same bridge have no effect (section 4.3).
- **IP forwarding** (`net.ipv4.ip_forward`) — the kernel setting required for the routing subsystem to forward packets between interfaces at all, as opposed to only processing traffic destined for its own addresses (section 6).

## 9. A closing note connecting this back to the rest of the series

This chapter has, in a real sense, been the payoff for reading the previous six carefully: nothing here required a new packet-processing mechanism distinct from `net_device`s (chapter 1), the receive/transmit data path (chapter 2), routing (chapter 3), Netfilter (chapter 4), the transport layer (chapter 5), or DNS (chapter 6) — every one of those mechanisms simply gets instantiated once per namespace, and connected across namespace boundaries using two comparatively small additional primitives, `veth` pairs and bridges. Container networking's apparent complexity, encountered from the outside as a black box of Docker or Kubernetes networking modes, resolves, from the inside, into a composition of mechanisms this series had already fully explained by chapter 6 — the container-specific novelty is genuinely just sections 2 through 4 of this chapter, layered on top of everything else.

It's worth stating plainly what this means for approaching an unfamiliar container networking problem in practice: rather than treating "container networking" as its own separate domain of knowledge requiring its own separate diagnostic toolkit, the more productive framing — and the one this whole chapter has tried to instill — is to ask, at each step of a container-networking investigation, *which namespace* a given piece of state belongs to, and then apply exactly the same chapter-1-through-6 diagnostic instincts within that namespace as would apply on a bare, non-containerized host. "Is the container's default route correct" is chapter 3's question, asked with `ip netns exec` in front of the command. "Is a Netfilter rule matching the traffic" is chapter 4's question, asked against the right table's or bridge's actual traversal path. "Is DNS resolving what's expected" is chapter 6's question, asked against the container's own, possibly entirely distinct, resolver configuration. None of these questions change in kind once a namespace is involved — only the specific namespace whose state needs to be inspected changes, and section 5's brief tour of each prior chapter's model "from inside one" was meant to make that translation automatic rather than something to be relearned separately for the container context each time it comes up.

Chapter 8 turns to a mechanism that, unlike this chapter's bridge-and-`veth` model, doesn't require both endpoints to be on the same physical machine at all: VPN tunnels, examined at the same data-path level chapter 2 applied to ordinary interfaces, tracing exactly what happens to a packet as it's encrypted, encapsulated, and sent across a network that has no idea a private, isolated conversation is happening inside it. It's worth noting, as a preview of that chapter's own connection back to this one, that a tunnel interface is, in the taxonomy this chapter has built, yet another kind of virtual `net_device` — sitting alongside `veth` and bridge interfaces as further evidence of chapter 1's original point that the kernel's `net_device` abstraction was deliberately built to accommodate exactly this kind of proliferation of virtual link types without requiring any of the higher layers this series has covered to know or care which specific kind of virtual (or physical) device they happen to be operating on top of.
