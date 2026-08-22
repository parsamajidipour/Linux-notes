# Chapter 3: Interfaces, Addressing, and Routing Tables

## 1. What this chapter is actually for

Chapter 2 ended at a specific, deliberately unfinished point: a `sk_buff` has arrived, IP has parsed its header inside `ip_rcv()`, and the kernel needs to decide what happens to it next — deliver it locally, forward it elsewhere, or drop it. That decision, and everything that feeds into making it, is this chapter's subject.

It's easy to treat "routing" as a solved, boring problem — add a default gateway, maybe a couple of static routes, and move on. That's a reasonable simplification for a single-homed workstation, and it's precisely where the simplification stops working: a machine with more than one interface, a container host bridging traffic between namespaces, a server with policy requirements about which traffic goes out which link, or anything doing real forwarding needs a model of routing considerably more detailed than "there's one table, and it has a default route." This chapter builds that fuller model, starting from how addresses attach to interfaces in the first place, through the routing table's actual data structure and lookup algorithm, to the policy-routing mechanism that lets a single machine behave, in effect, as if it had several independent routers layered on top of each other.

It's worth being explicit up front about a distinction that recurs throughout this chapter and matters for how the material should be read: everything here concerns how a machine decides where to send a packet *given a set of routes and rules that already exist*. This chapter is not about how those routes get there in the first place beyond the simplest cases (an administrator running `ip route add`, or the kernel auto-deriving a route from an interface's own address configuration). Dynamic routing protocols — mechanisms by which multiple routers exchange information and collectively populate each other's tables — are a distinct, considerably larger subject, deliberately out of scope here (see section 7), and nothing in this chapter should be read as a partial treatment of them; it's a complete treatment of a genuinely separate question, namely what a single machine does with whatever routing information it already has.

## 2. Addresses as a property of the interface, not the machine

Chapter 1 mentioned in passing that an IP address is not intrinsically "the identity of a machine" — it's a property attached to a specific `net_device`. This chapter needs that idea in a more precise, structural form, because the entire addressing model rests on it.

### 2.1 `struct in_ifaddr` and the interface address list

Every IPv4 address assigned to an interface is represented internally as a `struct in_ifaddr`, and every `net_device` maintains a list of these — meaning, structurally, an interface can have zero addresses (a device that's registered and up but unconfigured), exactly one (the overwhelmingly common case), or several simultaneously. Each `in_ifaddr` carries, at minimum: the address itself, a prefix length (equivalently, a netmask), a broadcast address (derived from the prefix, for the traditional case, though this can also be set explicitly), and scope information.

This is directly visible and directly manipulable:

```
$ ip addr add 10.0.0.5/24 dev eth0
$ ip addr add 10.0.0.6/24 dev eth0
$ ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP
    link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.5/24 scope global eth0
       valid_lft forever preferred_lft forever
    inet 10.0.0.6/24 scope global secondary eth0
       valid_lft forever preferred_lft forever
```

Both addresses are now live on `eth0` — the kernel will respond to ARP requests for either, accept traffic destined for either, and (subject to routing decisions covered later in this chapter) can originate traffic from either. Removing one (`ip addr del 10.0.0.5/24 dev eth0`) doesn't affect the other, and neither addition nor removal requires bringing the interface down first — the address list is genuinely dynamic, independent of the interface's own up/down administrative state (section 2.3 returns to this distinction). The second address is marked `secondary`, a label with real historical baggage (older kernels, and some networking tools, treat the first address on an interface slightly differently for certain legacy behaviors around which address gets used as a default source), but for ordinary purposes today, multiple addresses on one interface behave symmetrically. This capability is the direct mechanism behind a machine legitimately answering for several IPs on one physical NIC — a load balancer terminating traffic for multiple virtual IPs on one interface, or a server participating in an IP failover scheme (`keepalived`/VRRP moving a "virtual" address between machines by adding and removing exactly this kind of secondary address) both rely on precisely this structural fact.

### 2.2 Scope: not every address means the same thing

An address's **scope** describes how far it's meaningful to advertise or use — a concept that matters more for IPv6 (where scope is baked into the address ranges themselves, as chapter 1 mentioned regarding link-local addresses) but exists for IPv4 too, if less prominently. `ip addr show lo` on essentially any Linux machine will show:```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
    inet 127.0.0.1/8 scope host lo
```

`scope host` means this address is meaningful only to this machine itself — it will never be routed anywhere else, and no other machine on any network could meaningfully send traffic to it. Compare this to `scope global` on `eth0` in the example above, meaning the address is meant to be reachable from anywhere routing permits. IPv6 formalizes this same idea into the address ranges themselves: `fe80::/10` addresses are inherently link-local scope (meaningful only on the immediate network segment, never routed beyond it, and — a detail that trips people up the first time they encounter it — requiring a scope identifier alongside the address in tools and APIs, like `fe80::1%eth0`, precisely because the same link-local address can validly exist simultaneously on every interface a machine has, without ambiguity only because each is implicitly scoped to its own interface).

It's worth being precise about what enforces scope, since "scope" can otherwise sound like a purely advisory label rather than something the kernel actually acts on. Scope genuinely constrains routing behavior: a `scope link` route (an address's directly-connected network, reachable without a next hop) is only considered valid for traffic actually originating from or destined to that same link, and the kernel will not, for instance, treat a `scope host` address as a legitimate source address for outbound traffic leaving via a physical interface — attempting to bind a socket to `127.0.0.1` and then send traffic out through `eth0` fails precisely because the scope mismatch is enforced, not merely documented. This is a small but genuine safety mechanism: it prevents a category of address-spoofing-adjacent mistakes (a process accidentally sourcing external traffic from a loopback or otherwise clearly-local address) from silently succeeding.

### 2.3 What "up" actually gates

An interface being administratively down (`ip link set eth0 down`) doesn't remove its addresses from the `in_ifaddr` list — they remain configured, simply inactive. This is worth being precise about because the practical symptom is easy to misdiagnose: a downed interface's addresses will still appear in `ip addr show`, which can make it look, at a glance, like addressing is fine and something else must be broken, when the actual problem is that the interface simply isn't passing traffic at all. The `UP` flag (or its absence) shown in `ip link show` output is the fact to check first, before addressing, in exactly this kind of situation — a habit that generalizes the diagnostic discipline chapter 2 built around checking observable kernel state directly rather than assuming from partial evidence.

### 2.4 IPv6 addressing in more depth: multiple addresses as the normal case

Chapter 1's section 11 already flagged that a dual-stack interface typically carries several IPv6 addresses simultaneously and legitimately. It's worth returning to this now with the `in_ifaddr`-equivalent structure (`inet6_ifaddr` for IPv6) in view, because the reasons for this multiplicity are more specific than "IPv6 just has more addresses."

A freshly-configured interface on a network offering SLAAC typically ends up with, at minimum: a link-local address (always present and always derived, conventionally, from the interface's MAC address via a defined algorithm, or from a random identifier for privacy reasons on modern kernels), one or more global addresses derived similarly from a network-advertised prefix, and — if privacy extensions are enabled, which they are by default on most modern distributions — one or more **temporary addresses**, generated with a randomized interface identifier and rotated on a schedule, specifically so a device's traffic can't be trivially correlated across time or across different networks purely by observing a stable address. `ip addr show` reflects all of this directly:

```
$ ip -6 addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    inet6 2001:db8:1:2:a1b2:c3d4:e5f6:7890/64 scope global temporary dynamic
       valid_lft 86392sec preferred_lft 3592sec
    inet6 2001:db8:1:2:1234:56ff:fe78:9abc/64 scope global dynamic mngtmpaddr
       valid_lft 2591992sec preferred_lft 604792sec
    inet6 fe80::1234:56ff:fe78:9abc/64 scope link
       valid_lft forever preferred_lft forever
```

The `preferred_lft` on the `temporary` address is deliberately much shorter than on the stable global address — this is the rotation mechanism directly visible: once `preferred_lft` expires, the kernel stops using this specific temporary address for *new* outbound connections (existing connections already using it continue uninitiated, tracked separately via `valid_lft`, until that longer lifetime also expires), and generates a fresh temporary address to take over as the preferred one for new connections going forward. A machine's outbound connections, observed over time, can therefore legitimately originate from several different source addresses in succession, none of which is somehow more "real" than the others — all of them are, simultaneously, valid addresses for that one interface, differing only in scope, purpose, and how long they're expected to remain in active use.

### 2.5 Duplicate Address Detection: a step IPv4 never really had

Before a newly-generated IPv6 address (whether link-local or via SLAAC) is actually put into active use, the kernel performs **Duplicate Address Detection (DAD)** — sending a Neighbor Solicitation for the address-to-be onto the local segment and waiting briefly to see if any other device claims it, before considering the address genuinely assigned. This is directly visible as a transient `tentative` flag on a freshly-added address:

```
$ ip addr add 2001:db8:1:2::5/64 dev eth0
$ ip addr show eth0 | grep inet6
    inet6 2001:db8:1:2::5/64 scope global tentative dadfailed
```

A `dadfailed` result specifically means another device on the segment already answered for this exact address — a genuine conflict, and the address will not actually be used by the kernel in this state, unlike a simple misconfiguration in IPv4 (where two devices sharing an address typically just cause silent, hard-to-diagnose confusion, with both devices happily believing they own it and neighboring devices' ARP caches flapping between the two unpredictably). DAD's existence is a deliberate design choice in IPv6 to catch exactly this class of conflict explicitly and early, rather than leaving it to be diagnosed after the fact from its symptoms — a genuinely useful improvement over IPv4's silence on the same failure mode, and worth knowing about specifically because a `tentative`/`dadfailed` address sitting unused on an interface is sometimes mistaken for a simple configuration typo rather than recognized as the kernel actively and correctly refusing to use a genuinely conflicting address rather than silently accepting a broken configuration.

## 3. The Forwarding Information Base: what a "routing table" actually is



With addressing established, the next question chapter 2 left open resurfaces directly: given a packet (locally originated or being forwarded), which interface and next hop should it use? This is the Forwarding Information Base's job, and it's worth understanding both the data structure and the lookup algorithm, not just the `ip route` command that manipulates it.

### 3.1 From hash tables to a trie: why the data structure changed

Older Linux kernels (pre-2.6.something, now ancient history but occasionally still referenced in older documentation) implemented the FIB as a hash table. This worked, but had an awkward interaction with longest-prefix matching: a hash table is excellent at exact-match lookups, but routing fundamentally needs *longest-prefix* matching — given a destination address, find the *most specific* matching route among potentially many routes that all technically match (a `/32` host route, a `/24` matching its containing subnet, and a `/0` default route can all simultaneously "match" the same destination address, and the routing lookup needs to pick the most specific one, not just any one). A pure hash table has no natural notion of "prefix" at all — it can tell you instantly whether an *exact* key exists, but has no efficient way to ask "what's the longest prefix of this address that exists as a key," which is precisely the question every routing lookup needs answered. The historical workaround involved maintaining separate hash tables per possible prefix length and checking them from most to least specific, which works but scales awkwardly and wastes memory on mostly-empty tables for prefix lengths with few or no routes.

Modern Linux (since kernel 2.6.13, so this has been the case for essentially the entire life of any system anyone reading this is likely to be managing) uses a **LC-trie** (Level-Compressed trie) — a data structure specifically designed for efficient longest-prefix-match lookups over IP address space, structured so that a lookup walks down the trie following the bits of the destination address, naturally encountering more specific matches at deeper levels, and can determine the best match in time roughly proportional to the address length rather than the number of routes in the table. Conceptually, a plain (uncompressed) binary trie over IP addresses would have one node per bit-prefix actually present among the routes, and a lookup simply follows the destination address bit by bit, remembering the most specific route seen at any point along that walk, and returning whichever one was deepest (most specific) by the time the walk either runs out of bits or falls off the trie (no route matches any further). The "level-compression" part of LC-trie is a further optimization on top of this: long runs of nodes each having only a single child (common in sparse regions of address space) get compressed into a single, wider node, meaning the actual number of levels the lookup has to traverse in practice is considerably smaller than the naive bit-by-bit picture would suggest — this matters practically on any machine with a genuinely large routing table (a BGP-speaking router carrying the full internet routing table has hundreds of thousands of entries) — a linear scan through that many routes for every packet would be untenable, and the trie structure (with level-compression specifically helping keep its depth manageable even at that scale) is precisely what makes lookup performance stay reasonable regardless of table size.

### 3.2 Longest-prefix match, worked through concretely

Take the table from chapter 1's introduction and add a bit more detail:

```
$ ip route show
default via 192.168.1.1 dev eth0
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.42
10.8.0.0/24 dev wg0 proto kernel scope link src 10.8.0.2
10.8.0.5/32 via 10.8.0.1 dev wg0
```

A packet destined for `10.8.0.5` matches all four routes in some sense (every address matches `default`; `10.8.0.5` also happens to fall within `10.8.0.0/24`; and it exactly matches `10.8.0.5/32`). Longest-prefix match means the `/32` entry wins — it's the most specific possible match, a prefix length of 32 bits (the entirety of an IPv4 address), meaning this exact single address gets its own, more specific routing treatment than the rest of `10.8.0.0/24` (perhaps because that one specific host needs to be reached via a different next hop than the rest of the VPN subnet — an entirely realistic scenario for, say, a host that's multi-homed within the VPN itself). A packet for `10.8.0.7`, lacking any host-specific route, would fall through to the `/24` entry instead, and a packet for anything outside `192.168.1.0/24` and `10.8.0.0/24` entirely falls through both of those to the `/0` default route.

This mechanism — always preferring the longest matching prefix, regardless of the order routes happen to be listed in — is worth internalizing precisely, because it explains why route *order* in `ip route show` output is cosmetic (routes are typically shown sorted by prefix length or by table's own internal ordering for readability) rather than being consulted in sequence the way, say, Netfilter or firewall rules are (chapter 4 will make that contrast explicit, because conflating "rules evaluated in the order they're listed" — true for Netfilter chains — with "routes evaluated in the order they're listed" — not true for the FIB — is a genuinely common source of confusion for people coming from firewall configuration to routing configuration or vice versa).

### 3.3 Route attributes beyond destination and next hop

The example table above already showed several attributes worth naming explicitly, since `ip route show` output packs a lot into a terse format:

- **`dev`** — the outbound interface for this route.
- **`via`** — the next-hop address, when the destination isn't directly reachable on the local network segment (contrast the `192.168.1.0/24` route, which has no `via` — its destinations are directly on `eth0`'s own network segment, reachable via ARP/neighbor discovery rather than forwarding through another router).
- **`proto`** — where this route came from: `kernel` for routes the kernel itself derived automatically from interface configuration (the `192.168.1.0/24` and `10.8.0.0/24` entries exist purely because those addresses were assigned to those interfaces — the kernel infers the corresponding directly-connected route automatically), `static` for routes an administrator added by hand, or a routing-protocol-specific value (`bird`, `zebra`/`ospf`/`bgp`, and similar) for routes installed by a dynamic routing daemon.
- **`scope`** — a route-level scope concept distinct from, but related to, address scope from section 2.2: `link` scope means the destination is on the directly-attached network segment (no next-hop router needed); `global` scope (often simply omitted, as the default) means the destination may be anywhere reachable via a next hop; `host` scope covers routes to the machine's own addresses (an automatically-created route to `127.0.0.1` and to each of the machine's own configured addresses, handled internally so that a process connecting to the machine's own address works correctly without that traffic needing to actually round-trip through a physical interface).
- **`src`** — the source address the kernel will prefer when *originating* traffic matched by this route, if the application didn't explicitly bind to a specific source address itself — directly relevant when a machine has multiple addresses (section 2.1) and needs a sensible default for which one to use when initiating outbound connections that don't care which of its addresses gets used.
- **`metric`** — a numeric preference value used to break ties when multiple routes exist for the *same* destination prefix at the *same* specificity — unlike longest-prefix matching (which resolves ties between different-specificity routes), metric resolves the remaining ambiguity when two routes genuinely have identical prefixes (common with multiple default routes, one per network connection on a multi-homed machine, where metric determines which one is preferred absent any other distinguishing policy).

### 3.4 `ip route get`: asking the kernel to perform the lookup for you

Rather than mentally simulating longest-prefix match against a printed table, it's often faster and more reliable to simply ask the kernel to perform the lookup and report the result — exactly what `ip route get` does:

```
$ ip route get 10.8.0.5
10.8.0.5 via 10.8.0.1 dev wg0 src 10.8.0.2
    cache
```

This single command exercises the exact same FIB lookup path a real packet destined for that address would trigger, and reports back which route actually won, which next hop and interface would be used, and which source address the kernel would select by default (tying directly back to the `src` attribute from section 3.3). The `cache` line reflects a genuinely useful implementation detail: while the routing *table* itself is the trie described in section 3.1, the kernel also maintains a small cache of recent lookup results for frequently-used destinations, avoiding a full trie traversal on every single packet for high-volume flows — this is an optimization layered on top of the trie, not a replacement for it, and it's transparent to everything described in this chapter; `ip route get` simply surfaces its existence.

This command is worth reaching for constantly during any real routing diagnosis, specifically because it removes the need to manually reason through longest-prefix match against a potentially large table by hand — a process that's mechanically simple in principle but genuinely error-prone to do correctly under time pressure, especially once policy routing (section 5) is involved and the *table* consulted might not even be `main`. `ip route get` optionally accepts a `from` argument specifically to test policy-routing scenarios (`ip route get 8.8.8.8 from 203.0.113.5` reports which table and route a packet with that specific source address would actually use), directly validating a policy-routing configuration like the one built in section 5.2 without needing to generate real traffic to observe the effect.

### 3.5 ECMP: multiple equally-good routes

Section 3.3 introduced `metric` as the tie-breaker between routes of identical prefix length competing for the same destination. There's a related but distinct case worth naming: **Equal-Cost Multi-Path (ECMP)** routing, where multiple next hops for the same destination are configured with genuinely equal preference, and the kernel load-balances traffic across all of them rather than picking one and ignoring the rest:

```
$ ip route add 10.0.0.0/8 \
    nexthop via 192.168.1.1 dev eth0 weight 1 \
    nexthop via 192.168.1.2 dev eth0 weight 1
```

The kernel selects among these next hops per-flow (using a hash of the packet's addresses and ports, similar in spirit to the RSS hashing from chapter 2, section 2.4, and for the same underlying reason — keeping one flow's packets consistently on one path avoids the reordering problems chapter 2's section 6.1 covered in the context of multi-core processing, which apply equally to multi-path routing). This is genuinely common in data-center and router configurations where multiple physical links of equal capacity connect to the same next-hop peer, and it's worth distinguishing clearly from the metric-based tie-breaking in section 3.3: metric picks a single winning route and the others sit unused as backups; ECMP actively splits traffic across multiple routes simultaneously, all considered equally valid.

## 4. Neighbor discovery: resolving the next hop's link-layer address



A routing lookup answers "which interface, and which next-hop IP address." It deliberately doesn't answer a related, necessary question: given that next-hop IP address, what link-layer (Ethernet MAC) address does a frame actually need to be addressed to, in order to physically reach it? That's a separate subsystem — the **neighbor** subsystem (`net/core/neighbour.c`), and its protocol-specific implementations are ARP for IPv4 and Neighbor Discovery Protocol (NDP) for IPv6.

### 4.1 ARP as a cache, and what happens on a cache miss

The neighbor subsystem maintains a cache — traditionally called the ARP cache for IPv4, though the underlying kernel structure is protocol-agnostic — mapping IP addresses to link-layer addresses, directly inspectable:

```
$ ip neigh show
192.168.1.1 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
192.168.1.10 dev eth0 lladdr 11:22:33:44:55:66 STALE
10.8.0.1 dev wg0  FAILED
```

Each entry, like a TCP connection (chapter 1, section 8), sits in a specific state of its own small state machine — formally called Neighbor Unreachability Detection (NUD) — and it's worth naming the full set of states, not just the three shown above, because the transitions between them explain some otherwise-surprising cache behavior:

- **`INCOMPLETE`** — an ARP request has been sent, no reply received yet.
- **`REACHABLE`** — a mapping has been confirmed recently (either by an ARP reply, or, for TCP traffic specifically, by positive upper-layer confirmation — the kernel takes a successful, acknowledged TCP exchange as implicit evidence the neighbor is genuinely reachable, avoiding redundant ARP traffic for connections already proving the path works).
- **`STALE`** — the confirmation has aged out (past a configurable timeout), but the entry is still used speculatively; a fresh confirmation attempt happens the next time it's actually used, not proactively.
- **`DELAY`** — a brief transitional state entered from `STALE` upon use, giving upper-layer confirmation (again, an ACK'd TCP segment counts) a short window to arrive before falling back to actively probing.
- **`PROBE`** — the kernel is actively sending unicast ARP requests directly to the last-known link-layer address, attempting reconfirmation.
- **`FAILED`** — reconfirmation attempts exhausted without a reply.

The `STALE`/`DELAY` distinction is a genuinely elegant piece of design worth appreciating on its own terms: rather than treating every aged-out neighbor entry as requiring an immediate, disruptive fresh ARP broadcast the moment it's used again, the kernel gives ordinary upper-layer traffic (an ACK coming back on a TCP connection that happens to be using this neighbor) a chance to implicitly reconfirm the mapping for free, only falling back to explicit ARP probing if that implicit confirmation doesn't materialize quickly. This is precisely why sustained, active TCP connections rarely trigger visible ARP traffic even over long lifetimes despite cache entries formally aging out on a schedule — the traffic itself is doing the reconfirmation work invisibly.

On a genuine cache miss for a device that *does* use ARP — a route resolves to a next-hop IP address on a directly-connected Ethernet segment, but no cached link-layer address exists yet (entering `INCOMPLETE`) — the kernel queues the outbound packet and broadcasts an ARP request ("who has 192.168.1.1? tell 192.168.1.42") onto that segment. Every device on the segment receives this broadcast; only the device actually holding that IP address is expected to respond, with its own MAC address, at which point the kernel populates the neighbor cache, transitions the entry to `REACHABLE`, and releases the originally-queued packet (and any others that arrived in the meantime for the same destination) for actual transmission.

This queuing behavior is worth knowing about because it explains a specific, small, easily-misread latency artifact: the very first packet sent to a previously-unseen address on a local segment genuinely does incur extra latency — the round trip for the ARP resolution itself — before the actual packet is transmitted, a delay that vanishes on every subsequent packet to the same destination once the cache entry exists. A `ping` to a fresh destination sometimes shows a visibly higher first-reply time than subsequent replies for exactly this reason, and it's a normal, expected artifact of the resolution process rather than evidence of an intermittent network problem.

### 4.2 Gratuitous ARP and its uses

One further mechanism worth naming because it recurs in high-availability setups: a **gratuitous ARP** is an ARP announcement sent without having been requested by anyone — a device broadcasting "this IP address now belongs to this MAC address" unprompted, specifically to update every other device's neighbor cache on the segment proactively. This is precisely the mechanism `keepalived`/VRRP and similar failover tools use when a virtual IP address moves from one physical machine to another: the newly-active machine sends a gratuitous ARP for the virtual address, and every other device on the segment updates its neighbor cache immediately, rather than waiting for their existing (now-stale, pointing at the old machine) cache entries to expire naturally — directly relevant to how fast a failover actually becomes visible to the rest of the network, and a good concrete illustration of how the addressing (section 2) and neighbor-resolution (this section) mechanisms compose to support a real operational pattern.

It's also worth reconciling this with the `wg0` entry shown in `FAILED` state in section 4.1's example. WireGuard interfaces (and many other virtual, point-to-point-style interfaces) don't use ARP in any meaningful sense at all — there's no broadcast-capable shared medium to ARP onto in the first place, since a point-to-point tunnel has exactly one possible peer, not a segment of many devices to discover among. A `FAILED` neighbor entry on such an interface therefore doesn't indicate an ARP-resolution problem specifically; it more likely reflects the underlying tunnel not passing traffic at all, or the peer configuration expecting a next-hop address that was never actually reachable through the tunnel — a distinction worth keeping straight, since chapter 8's tunnel-specific diagnostics build on knowing not to chase an ARP explanation on an interface type where ARP was never the mechanism in play to begin with.

## 5. Policy routing: beyond a single table

Sections 3 and 4 described routing as if there's exactly one FIB table and one universal lookup process. That's the default configuration and the right mental starting point, but it understates what the kernel actually supports, previewed briefly in chapter 1: Linux maintains up to 255 separate routing tables, and a separate mechanism — **routing rules**, inspected via `ip rule show` — decides, for any given packet, *which table* to actually consult.

### 5.1 The default rule set

Every Linux system, even one that's never touched policy routing explicitly, already has a small set of rules in place:

```
$ ip rule show
0:      from all lookup local
32766:  from all lookup main
32767:  from all lookup default
```

The number on the left is priority — rules are evaluated in ascending priority order, and the first one whose `from`/`to`/other match conditions apply determines which table gets consulted (the familiar single table from sections 2–4 is, in fact, just the `main` table, one of these three defaults). The `local` table (priority 0, always consulted first) holds the automatically-generated routes for the machine's own addresses and loopback traffic — the mechanism underlying the `scope host` routes mentioned in section 3.3 — while `default` (priority 32767, consulted last, and empty by default on most systems) exists mostly as a hook point for exceptional configurations rather than routine use.

### 5.2 A worked policy-routing scenario: routing by source address

The classic use case for going beyond this default setup is a machine with two distinct outbound network connections (say, two internet uplinks from different providers) where traffic *arriving* from one needs its *replies* to leave via the same connection it arrived on, regardless of what the single, unified `main` table's default route might otherwise prefer. Without this, an asymmetric routing situation arises: a connection's inbound packets take one path, but the machine's replies take a different path back out — and many upstream networks, for security reasons, drop traffic that appears on an unexpected path relative to where they'd expect the corresponding return traffic, breaking the connection entirely from the client's point of view even though, from this machine's own local perspective, nothing looked obviously wrong.

The fix uses exactly the two mechanisms this section has introduced: separate routing tables, one per uplink, each containing that uplink's own default route, plus rules that select the correct table based on *source* address rather than destination:

```
$ ip route add default via 203.0.113.1 dev eth0 table 100
$ ip route add default via 198.51.100.1 dev eth1 table 200
$ ip rule add from 203.0.113.5 table 100
$ ip rule add from 198.51.100.9 table 200
```

Now, a packet being originated with source address `203.0.113.5` (the address assigned to `eth0`) consults table 100 for its routing decision, ending up correctly out `eth0` via that uplink's own gateway, regardless of what the `main` table's own default route says — and symmetrically for `198.51.100.9` and `eth1`. This is a genuinely common real-world configuration, and understanding it as "the same longest-prefix-match FIB lookup from section 3, just against a different table, selected by a separate rule-matching step first" is considerably more useful than memorizing it as an isolated recipe, because the same composition — rules choosing a table, that table then undergoing an ordinary FIB lookup — generalizes to other selection criteria (`ip rule add fwmark ... table ...`, selecting a table based on a Netfilter-applied packet mark, is a common pairing that chapter 4 will make more sense of once connection tracking and marking are covered directly).

### 5.3 `fwmark`-based table selection and its relationship to Netfilter

Section 5.2 built a policy-routing scenario keyed on source address, matched directly by an `ip rule`. A second, extremely common selection criterion deserves a mention here even though its full context (Netfilter marking) belongs to chapter 4: a rule can match on `fwmark`, a numeric value that Netfilter rules can attach to a packet as it passes through earlier stages of processing (the `MARK` target, in `iptables` terms, or the equivalent `meta mark set` in `nftables`). This decouples the *criterion* used to select a routing table from anything intrinsic to the packet's own addressing — a Netfilter rule can mark a packet based on nearly any condition it can match (originating process's user ID via `owner` matching, a specific destination port, deep packet inspection results, whatever the firewall configuration is capable of expressing), and policy routing then simply consults that mark:

```
$ ip rule add fwmark 0x1 table 100
```

The practical significance is that policy routing's selection criteria aren't limited to what's visible in a packet's own IP header (source/destination address, which is all sections 5.1–5.2 used) — anything Netfilter can classify, policy routing can subsequently act on, because the two subsystems compose through this one shared field on the `sk_buff`. This is precisely the seam chapter 4 will pick up in detail, and it's worth flagging now specifically so this chapter's routing model isn't mistaken for a complete picture of what determines a packet's path — the full picture only comes into view once Netfilter's marking capability is added to what's been built here.

### 5.4 A note on route caching and lookup cost under policy routing

It's worth addressing a natural question once multiple tables and rules enter the picture: does evaluating a sequence of rules before even reaching the FIB lookup from section 3 impose meaningful per-packet overhead, especially on a busy machine? In practice, the rule list is typically short (a handful of entries even in fairly elaborate policy-routing setups, rather than hundreds), and rule evaluation itself is a simple, fast sequential match against a small number of conditions — nothing approaching the complexity of the trie traversal it eventually leads into. The `cache` mechanism mentioned in section 3.4 also applies here: once a particular packet flow's `(rule, table, route)` outcome has been determined, subsequent packets belonging to the same flow can often reuse that cached outcome rather than re-walking the rule list and the trie from scratch on every single packet. The overhead genuinely worth worrying about in a policy-routing design is not raw lookup cost but *rule ordering* correctness — since rules, unlike routes within one table, genuinely are evaluated in strict priority order (section 5.1), a broad, early rule can inadvertently shadow a more specific one added afterward at a lower priority number... precisely the same category of ordering mistake chapter 4 will describe for Netfilter chains, and worth watching for here for the identical underlying reason: an evaluation-order-based mechanism silently doing the wrong thing because a more general rule matched first, before a more specific one further down ever got a chance to.

## 6. Interfaces revisited: what routing needs from them that chapter 2 didn't cover



Chapter 2 covered `net_device` primarily from the data-path perspective — how frames physically move in and out through it. Routing has its own, narrower set of requirements from an interface, worth stating explicitly because they clarify a few otherwise-odd behaviors.

### 6.1 The loopback interface as a genuinely routed device

It's easy to think of `lo` as a special case exempt from ordinary routing logic, given how it's typically introduced ("just the loopback"). It isn't exempt at all — traffic to `127.0.0.1` (or, for that matter, to any of the machine's *own* addresses on any interface) is handled by the same FIB lookup mechanism from section 3, just resolved via the automatically-generated `local` table routes mentioned in section 5.1, which direct such traffic to the `lo` device regardless of which physical interface the destination address is actually configured on. This is why a process on a machine can `connect()` to that machine's own public-facing address and have the connection work entirely locally, without any packet actually needing to reach a physical NIC at all — the routing lookup, consulting the `local` table before ever reaching `main`, redirects the traffic to loopback transparently, and everything from section 3 onward applies to this traffic exactly as it would to any other, just with a different table's entries taking effect first.

This has a genuinely practical consequence worth spelling out: a service that binds to a specific address (rather than the wildcard `0.0.0.0` or `::`) and is then accessed from the same machine using that specific address, rather than `127.0.0.1`, still has its traffic routed through loopback by the mechanism just described, even though the address being used looks, superficially, like a "real," externally-reachable one. This is precisely why a firewall rule intended to restrict access to a service from *other* machines sometimes surprises an administrator by not affecting access from the local machine itself using that same external address — the traffic never actually leaves via the physical interface those rules might be scoped to, and depending on exactly where in the Netfilter hook sequence (chapter 1, section 7) the relevant rule sits, it may or may not even be traversed at all for traffic that the `local` table has already silently rerouted through `lo`.

### 6.2 Interface index versus interface name: why routes sometimes survive a rename

`ip link show` displays a numeric ifindex alongside each device's name (chapter 1, section 5), and it's worth knowing that the kernel's actual routing and neighbor-cache internals reference interfaces by this numeric ifindex, not by name — the name is a userspace-facing convenience, resolved to and from the ifindex by the tools presenting it. This has a small but occasionally confusing practical consequence: renaming an interface (`ip link set eth0 name wan0`) doesn't invalidate routes or neighbor entries pointing at it, because internally, nothing about the ifindex changed — only the display name did. Conversely, an ifindex is *not* guaranteed to be stable across a reboot or a device being unplugged and replugged (a new device registration, even for what looks like "the same" physical NIC from a human's perspective, can be assigned a different ifindex), which is precisely why persistent interface *naming* rules (systemd's predictable network interface naming, or older `udev` rules) exist — they exist to keep the human-facing *name* stable across these events, compensating for the fact that the underlying ifindex the kernel actually depends on is not guaranteed to be.

A related, occasionally-encountered symptom worth being able to recognize follows directly from this: a route or neighbor entry that appears to reference a device that no longer seems to exist under that name (`ip route show` reporting a route against an interface name that `ip link show` no longer lists) usually indicates exactly this kind of ifindex churn — the route is stale, still pointing at an ifindex whose associated device was torn down and possibly replaced by a new one under a different (or even the same) name but a different underlying index — rather than indicating file corruption or a tooling bug. Cleaning this up is simply a matter of removing the stale route once the discrepancy is recognized, and the underlying lesson generalizes usefully: whenever routing configuration seems to reference something that "shouldn't" exist anymore, ifindex churn from a device having been torn down and recreated is a reasonable first hypothesis to check, ahead of more exotic explanations.

### 6.3 What multiple addresses and namespaces mean for routing, previewed

Sections 2 and 3 of this chapter treated a single machine as having one, unified set of interfaces and one set of routing tables (or, with policy routing, several tables selected by rule). Chapter 1's section 10 already flagged that network namespaces partition essentially all of this global state — meaning a container, running in its own namespace, has its own entirely independent `net_device` list, its own independent FIB tables, and its own independent routing rules, with no visibility into the host's or any other namespace's configuration at all. Everything this chapter has described — addresses attaching to interfaces, longest-prefix match, policy routing via rules — applies fully and identically *within* any one namespace; namespaces don't change the routing model itself, they simply give each one its own private, non-interacting instance of the entire apparatus this chapter has built. A `veth` pair, with one end in the host namespace and one end moved into a container's namespace, is itself just an ordinary interface from each namespace's own point of view — addressed, routed, and neighbor-resolved exactly as described here, with the only novelty being that the "wire" connecting the two ends is a purely virtual, in-kernel construct rather than anything physical. Chapter 7 covers this composition in full; the point worth taking from this chapter alone is that nothing about namespaces required any new routing concept — the existing model simply gets instantiated once per namespace.

## 7. What's deliberately being deferred

- The full Netfilter hook mechanism and how it interacts with the routing decisions described in sections 3 and 5 — including how a packet can be marked by Netfilter and that mark subsequently consulted by a routing rule, hinted at in section 5.2 — is chapter 4's job.
- IPv6-specific routing details (route lifetime handling tied to SLAAC, the differences in how Neighbor Discovery replaces ARP mechanically rather than just conceptually) are left largely implicit here, following chapter 1's treatment of IPv6 as running the same architecture with a different network-layer protocol; nothing in this chapter's routing model is IPv4-specific in its logic, only in some of its concrete examples.
- Dynamic routing protocols (OSPF, BGP) that install routes with `proto` values other than `kernel`/`static` are out of scope entirely — this series covers what the kernel does with a routing table, not the protocols by which a table gets populated dynamically across multiple routers.
- Traffic control and qdiscs, mentioned in chapter 2 as sitting between IP's routing decision and the driver, are chapter 9's full subject, and this chapter deliberately treated "the interface was chosen" as the end of the routing story, leaving what happens to a packet queued on that interface for chapter 9 to cover.

## 8. Glossary of terms introduced in this chapter

A short reference, in the same spirit as the previous two chapters', since routing-rule and neighbor-state terminology in particular recurs from here through chapter 9.

- **`in_ifaddr` / `inet6_ifaddr`** — the kernel structures representing one IPv4 or IPv6 address attached to an interface; an interface can hold several of either (section 2.1, 2.4).
- **scope (address)** — how broadly an address is meant to be reachable or advertised: `host`, `link`, or `global` (section 2.2).
- **temporary address** — an IPv6 privacy-extension address with a randomized identifier, rotated periodically to resist long-term tracking (section 2.4).
- **DAD (Duplicate Address Detection)** — the IPv6 mechanism confirming a newly-generated address isn't already claimed by another device before it's put into active use (section 2.5).
- **FIB (Forwarding Information Base)** — the kernel's routing table data structure, implemented as an LC-trie for efficient longest-prefix-match lookup (section 3.1).
- **longest-prefix match** — the rule that, among all routes matching a destination, the most specific (longest prefix) one is used (section 3.2).
- **metric** — a tie-breaking preference value between routes of identical specificity (section 3.3).
- **ECMP (Equal-Cost Multi-Path)** — multiple next hops configured with genuinely equal preference, with traffic load-balanced across all of them per-flow (section 3.5).
- **neighbor subsystem / ARP / NDP** — the mechanism resolving a next-hop IP address to a link-layer address, with ARP as the IPv4 protocol and NDP as the IPv6 equivalent (section 4).
- **NUD (Neighbor Unreachability Detection)** — the state machine (`INCOMPLETE`, `REACHABLE`, `STALE`, `DELAY`, `PROBE`, `FAILED`) governing a neighbor cache entry's confidence in its own validity (section 4.1).
- **gratuitous ARP** — an unrequested ARP announcement used to proactively update other devices' neighbor caches, notably during IP failover (section 4.2).
- **routing rule / policy routing** — the mechanism selecting which of up to 255 routing tables applies to a given packet, evaluated before the FIB lookup itself (section 5).
- **`fwmark`** — a numeric packet mark, typically set by a Netfilter rule, usable as a policy-routing rule's match criterion (section 5.3).
- **ifindex** — the kernel's stable numeric identifier for a `net_device`, distinct from its (renameable) display name (section 6.2).

## 9. A closing note connecting this back to chapters 1 and 2

Chapter 1 introduced routing as a single-table lookup answering "which interface, and via which next hop." This chapter has, hopefully, filled that in considerably: addresses are properties attached to interfaces, sometimes several per interface, and for IPv6 specifically, several simultaneously by design rather than by exception; the routing table is really a longest-prefix-match trie, not a linear list evaluated in listed order; a resolved next-hop IP still needs a separate neighbor-resolution step, governed by its own small state machine, before a frame can actually be addressed; and the entire single-table picture is itself just the default, simplest case of a considerably more general policy-routing mechanism capable of running what amount to several independent routing configurations on the same machine simultaneously, selected per-packet by rules evaluated before the FIB lookup ever happens, on criteria that can extend beyond addressing alone once Netfilter marking is involved.

It's worth drawing together, as chapter 2 did, the diagnostic sequence this chapter's material supports, since in practice it gets applied together rather than as isolated facts about individual mechanisms. Faced with traffic reaching the wrong interface, or not reaching a destination that should be reachable, a reasonable sequence is:

1. Confirm the relevant interface is actually administratively up and holds the expected address (`ip link show`, `ip addr show` — section 2.3's warning about addresses persisting on a downed interface applies directly here).
2. Ask the kernel directly what it would do with a packet to the destination in question, rather than reasoning about the table by eye (`ip route get`, section 3.4) — including testing with an explicit `from` source address if policy routing might be involved.
3. If the result looks wrong, check the rule list (`ip rule show`) before the routing table itself — a misrouted packet is at least as often a rule-ordering problem (section 5.4) as it is a missing or incorrect route in the table that rule ultimately selects.
4. Check the neighbor cache for the resolved next hop (`ip neigh show`) if the route itself looks correct but traffic still isn't arriving — a `FAILED` or persistently `INCOMPLETE` entry on an Ethernet-type interface points at a link-layer resolution problem distinct from anything routing-table-related, while the same state on a point-to-point interface (section 4.2's closing note) points elsewhere entirely, toward the tunnel or virtual link itself rather than ARP.
5. If everything above looks correct in isolation, consider whether Netfilter (chapter 4) is altering the packet's destination, marking, or fate somewhere between the interface and the routing decision — the seam section 5.3 flagged, and the natural next place to look once this chapter's own mechanisms have all been ruled out.

Chapter 2 left off at `ip_rcv()` having just parsed a packet's IP header, with the question of "where does this packet go next" deliberately unanswered. This chapter has now answered it in full for the ordinary case, and provided a diagnostic sequence for the cases where the answer isn't what was expected — but deliberately left open exactly the point chapter 4 needs: everything described here assumes no Netfilter rule has intervened to alter the packet's marking, destination, or fate along the way. Chapter 4 picks up at precisely that gap, tracing how `iptables`/`nftables` rules attach to the same hook points introduced in chapter 1, and how they can influence — through marking, NAT, or outright interception — the very routing and forwarding decisions this chapter has just spent its length explaining.
