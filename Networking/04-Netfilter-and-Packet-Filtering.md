# Chapter 4: Netfilter and Packet Filtering (iptables/nftables)

## 1. What this chapter is actually for

Chapter 3 ended with a deliberate gap: everything it described — addressing, the FIB lookup, neighbor resolution, policy routing — assumed no other piece of the kernel had already changed a packet's destination, marking, or fate along the way. That assumption was never fully true, and this chapter is where the reason becomes explicit: **Netfilter**, the hook architecture chapter 1 introduced only in outline, sits at several precise points along the exact journey chapters 2 and 3 traced, and it can inspect, mark, rewrite, or discard a packet at any of them — sometimes *before* the routing decision chapter 3 spent its length explaining, sometimes after, and the difference matters enormously for reasoning about what a given rule actually does.

Most people's working knowledge of `iptables` or `nftables` is a catalog of commands that produce observed effects — add a rule, traffic gets blocked or allowed. This chapter aims at the layer beneath that catalog: the hook architecture both tools are built on, why chains and tables are ordered the way they are, what connection tracking actually does underneath a stateful rule, and a genuine, mechanism-level comparison between `iptables` and `nftables` rather than treating the newer tool as simply "the same thing with different syntax."

## 2. The five hooks, revisited with routing now in view

Chapter 1 introduced the five Netfilter hook points — `PREROUTING`, `INPUT`, `FORWARD`, `OUTPUT`, `POSTROUTING` — and the diagram showing a packet touching some subset of them depending on whether it's locally destined, being forwarded, or locally originated. With chapter 3's routing model now available, it's worth being precise about exactly *where* each hook sits relative to the routing decision, because that ordering is what determines what each hook can and can't see or influence.

```
   incoming frame
         │
   ┌─────▼─────┐
   │ PREROUTING │  ← before any routing decision at all
   └─────┬─────┘
         │
   routing decision (chapter 3's FIB lookup)
      /        \
  (local)    (forward)
     │            │
┌────▼────┐  ┌────▼────┐
│  INPUT   │  │ FORWARD │
└────┬────┘  └────┬────┘
     │             │
 (delivered         │
  to socket)        │
     │             │
locally-generated   │
   response         │
     │             │
┌────▼────┐        │
│ OUTPUT  │        │
└────┬────┘        │
     │             │
     └──────┬──────┘
    second routing decision
    (for OUTPUT traffic, and
     re-evaluated after any
     PREROUTING-stage rewrite)
            │
     ┌──────▼──────┐
     │ POSTROUTING │  ← after all routing decisions, just before the device
     └──────┬──────┘
            │
     outgoing frame
```

`PREROUTING` firing *before* the routing decision is the single most consequential ordering fact in this whole diagram, and it's worth dwelling on why: it means a `PREROUTING` rule can rewrite a packet's destination address (destination NAT, section 4) *before* the kernel has decided whether the packet is locally destined or needs forwarding — meaning the rewrite itself can change which of those two outcomes actually happens. A packet arriving addressed to this machine's own public IP on port 8080, DNAT'd in `PREROUTING` to an internal address like `10.0.0.5:80`, gets routed — by the *routing decision that happens after* the rewrite — as if it had always been destined for `10.0.0.5`, which might mean it now needs forwarding (if `10.0.0.5` isn't local to this machine) even though the packet, as it physically arrived, looked like ordinary traffic destined for a local service. This is precisely the mechanism behind port-forwarding and reverse-proxy-at-the-packet-level setups, and understanding it requires holding both chapter 3's routing model and this hook ordering in mind simultaneously — neither alone explains the behavior.

`OUTPUT` sitting *before* its own routing decision (rather than after, the way `PREROUTING`'s relationship to routing works) reflects a genuinely different circumstance: a locally-generated packet doesn't have a routing decision to make *until* `OUTPUT` has had a chance to look at it, because IP doesn't yet know the packet exists until the local process or protocol stack hands it over. This is why `OUTPUT`-stage NAT (rewriting a locally-originated packet's destination) also triggers a fresh routing lookup afterward, for the same reason `PREROUTING`'s DNAT does — the rewritten destination might legitimately need a different outbound interface than the original one would have.

## 3. Tables: grouping rules by the kind of thing they do

The five hooks describe *where* in a packet's journey rules run; **tables** describe *what kind* of rule is running at each hook, and multiple tables can attach to the same hook, evaluated in a fixed, well-defined order relative to each other. `iptables` names four tables explicitly (a fifth, `security`, exists for SELinux-related labeling and is rarely used directly); it's worth knowing what each is actually for, not just its name.- **`raw`** — runs earliest, before connection tracking (section 5) has even looked at the packet. Its main purpose is marking specific traffic as exempt from connection tracking entirely (`NOTRACK`), useful for high-volume traffic where tracking overhead isn't wanted, or where tracking would actively misbehave (certain multi-path or asymmetric-routing scenarios).
- **`mangle`** — for altering packet headers or metadata that isn't the destination/source address itself — TTL, DSCP/ToS marking for QoS purposes (chapter 9 picks this up), or setting the `fwmark` policy routing can consult (chapter 3, section 5.3).
- **`nat`** — for address translation specifically: DNAT (rewriting destination, done in `PREROUTING` or `OUTPUT`) and SNAT/masquerading (rewriting source, done in `POSTROUTING`). A subtlety worth flagging immediately and returned to in section 5: NAT rules, unlike ordinary filtering rules, are only ever consulted for the *first* packet of a connection — connection tracking then applies the same rewrite automatically to every subsequent packet in that flow, without re-running the NAT rule each time.
- **`filter`** — the default table, and the one most `iptables -A INPUT -j DROP`-style rules land in if no table is specified; ordinary accept/drop/reject decisions live here.

The ordering across tables, for a hook where more than one applies, is fixed by the kernel and not configurable: at `PREROUTING`, for instance, `raw` runs before `mangle`, which runs before `nat`, in that order — meaning a `raw` rule genuinely can affect whether connection tracking (and therefore later NAT and stateful filtering) ever sees a given packet at all, a capability that wouldn't make sense if the ordering were reversed. Getting a rule's *table* right, not just its chain, is therefore just as load-bearing for correct behavior as chapter 1's original point about getting the *chain* right — a syntactically valid rule in the wrong table, much like one in the wrong chain, can silently fail to have the intended effect because it never runs relative to the other processing it was implicitly assumed to interact with.

## 4. NAT in more detail: what actually gets rewritten, and when

Chapter 1 mentioned NAT only in passing, as an application of connection tracking; it's worth returning to it now with tables and hooks both in view, because "NAT" covers two genuinely distinct operations that are easy to conflate.

### 4.1 Destination NAT (DNAT): rewriting where a packet is going

DNAT changes a packet's destination address (and often port) before the routing decision consults it — this is exactly the port-forwarding scenario from section 2. A typical rule:

```
$ iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.0.0.5:80
```

This runs in `PREROUTING`, the earliest hook, precisely because the rewrite needs to happen before routing decides where the packet goes — a DNAT rule placed in a later hook wouldn't achieve the same effect, since routing would already have made its decision based on the original, un-rewritten destination.

### 4.2 Source NAT (SNAT) and masquerading: rewriting where a packet came from

SNAT changes a packet's source address, and runs in `POSTROUTING` — the last possible point, specifically because the rewrite needs to happen only *after* routing and filtering decisions (which should see the packet's real, original source) have already been made, and just before the packet actually leaves via its chosen interface:

```
$ iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

`MASQUERADE` is a specific, commonly-used variant of SNAT that automatically uses whatever address is currently assigned to the outbound interface, rather than a fixed address specified in the rule — this matters for interfaces whose address might change (a DHCP-assigned uplink, for instance), where a fixed-address `SNAT` rule would need manual updating every time the address changed, while `MASQUERADE` adapts automatically. This is the exact mechanism behind a home router or a NAT gateway allowing many internally-addressed devices to share one externally-visible IP address: each outbound connection gets its source address (and, to keep multiple internal hosts' connections distinguishable to the outside world, typically its source *port* as well) rewritten to the shared external address as it passes through `POSTROUTING`.

### 4.3 Why NAT rules only run once per connection

Section 3 flagged that NAT rules are only consulted for a connection's first packet. This is a direct consequence of how NAT is implemented on top of connection tracking (section 5): the moment a NAT rule fires for a packet, the specific rewrite it performed is recorded in that packet's conntrack entry, and every subsequent packet belonging to the same tracked connection — in both directions — has the recorded rewrite applied automatically by the conntrack/NAT engine, without the original rule being re-evaluated. This is both a performance optimization (avoiding redundant rule evaluation for high-packet-count connections) and, more importantly, a correctness requirement: without it, nothing would guarantee that every packet of one logical connection gets the *same* rewrite applied consistently, which would break the connection from either endpoint's perspective. This is precisely why a NAT rule change doesn't affect already-established connections — their rewrite behavior is already fixed in their conntrack entry, immune to a rule being modified or removed afterward, until that connection's tracking entry itself expires or is manually flushed.

## 5. Connection tracking in full: the state machine underneath statefulness

Chapter 1 introduced conntrack briefly as the mechanism making "allow established, related" rules and NAT possible. This chapter's job is to go one level deeper: what does a conntrack entry actually track, and how does its own state machine relate to (but differ from) the TCP state machine from chapter 1, section 8?

### 5.1 Conntrack states are not the same as TCP states

This is a genuinely common point of confusion worth heading off directly: `ESTABLISHED`, as a *conntrack* state, does not mean the same thing as TCP's own `ESTABLISHED` state (chapter 1, section 8). Conntrack's states describe the connection from the *tracking subsystem's* point of view, which is more coarse-grained and protocol-generic (since conntrack also tracks UDP and ICMP "connections," which have no TCP-style handshake at all):

- **`NEW`** — the first packet of a flow conntrack hasn't seen before; no reply has been observed yet.
- **`ESTABLISHED`** — conntrack has seen traffic in both directions for this flow; note that for TCP, this can be true before the TCP handshake has actually completed (a SYN and a corresponding SYN-ACK is enough for conntrack to consider the flow bidirectional, even though the TCP connection itself is still, per chapter 1's terminology, in `SYN_RECV`/`SYN_SENT`).
- **`RELATED`** — a new flow that conntrack can associate with an existing one via protocol-specific helper logic — the canonical example being an FTP data connection, which conntrack's FTP helper recognizes as related to an existing FTP control connection by inspecting that control connection's application-layer content (the `PORT`/`PASV` command negotiating the data connection's parameters), letting a firewall rule allow the data connection without needing a separate, generic rule opening a wide range of ephemeral ports.
- **`INVALID`** — a packet that doesn't fit any recognized state for its protocol (a TCP packet with an invalid flag combination for the connection's current tracked state, for instance) — a state worth actively filtering on in practice, since `INVALID` packets are frequently the product of packet crafting, malformed retransmissions past a connection's actual lifetime, or genuine attack traffic, and dropping them outright is a low-risk, broadly beneficial rule.

The practical upshot of the mismatch between conntrack's `ESTABLISHED` and TCP's own `ESTABLISHED`: a firewall rule matching `ctstate ESTABLISHED` is coarser and generally more permissive than it might sound if read as "only fully-established TCP connections" — it will match traffic for a TCP connection that conntrack considers bidirectional even while the TCP handshake itself is still completing, which is almost always the intended, correct behavior (the return SYN-ACK of an outbound-initiated connection needs to be let back in specifically during this window), but it's worth understanding precisely rather than assuming the two state machines are one and the same.

### 5.2 The conntrack table as the shared substrate under both filtering and NAT

Chapter 1's section 7.1 already showed `conntrack -L` output and the basic four-tuple-plus-reply-tuple structure of an entry. It's worth adding, now that both NAT and stateful filtering are in view, that a single conntrack entry genuinely serves *both* purposes simultaneously: the same entry that lets a `ctstate ESTABLISHED,RELATED` filtering rule permit return traffic is also exactly where a NAT rewrite gets recorded (section 4.3) for that same connection. This shared substrate is why NAT and stateful filtering compose so naturally in practice — a NAT'd connection's return traffic is recognized as `ESTABLISHED` by the same mechanism, and has its reverse rewrite applied by the same mechanism, entirely because both operations are reading from and writing to the identical underlying tracking entry rather than two separate, potentially-inconsistent bookkeeping systems.

### 5.3 Timeouts: why a table doesn't grow forever

Every conntrack entry carries a protocol- and state-specific timeout, visible as the numeric field in `conntrack -L` output (chapter 1's example showed `431999`, an internal timer value). These timeouts vary substantially by protocol and state — a `TIME_WAIT`-adjacent TCP conntrack state times out relatively quickly, while an actively `ESTABLISHED` long-lived connection's entry is kept alive as long as traffic continues to flow, refreshed on each packet seen. UDP, lacking any explicit connection-teardown signal, relies entirely on a timeout to eventually expire a tracked "connection" (typically a considerably shorter default timeout than TCP's `ESTABLISHED` timeout, reflecting UDP's connectionless nature) — this is directly why a long-idle UDP-based session (some VPN protocols, certain real-time media protocols) can silently stop working after a period of inactivity even though nothing about the underlying network changed: the conntrack entry aged out, and by the time traffic resumes, it's treated as an entirely new, untracked flow, potentially failing a stateful firewall rule that was relying on the (now-expired) `ESTABLISHED` classification.

The practical implication worth internalizing: a rule set that seems to work initially but starts silently dropping return traffic on long-idle connections is a reasonably common symptom of a conntrack timeout mismatch relative to an application protocol's actual idle behavior, and it's diagnosable directly by checking `conntrack -L` for the flow in question (or its absence, once expired) rather than assuming the fault lies elsewhere in routing or the application itself.

## 6. `nftables`: the same hooks, a different rule representation

`iptables` was, for a long time, the default and only mainstream Netfilter front-end; `nftables` is its designated modern replacement, and it's worth understanding precisely what changed and what stayed the same, because the two are frequently discussed as if `nftables` were simply a syntax facelift rather than a genuinely different internal model.

### 6.1 What's actually the same

`nftables` attaches to the exact same five Netfilter hooks described in section 2, and it shares the same conntrack subsystem underneath (section 5) — a `RELATED,ESTABLISHED` match means the same thing to either tool, because both are consulting the identical kernel-side tracking table. Nothing about the fundamental architecture chapters 1 and this chapter have described changes depending on which front-end tool is in use; what changes is how rules are expressed and evaluated within that architecture.

### 6.2 What's actually different

`iptables` ships with a fixed, hardcoded set of tables and chains — the four (or five) tables from section 3, each with a fixed set of built-in chains tied to specific hooks, and a fixed evaluation order across tables at each hook. `nftables` inverts this: tables and chains are user-defined constructs (an administrator explicitly creates a table, then explicitly creates a chain within it and specifies which hook and what priority it attaches to), and **priority** is an explicit numeric value the administrator assigns, rather than an implicit ordering baked into the tool.

```
# nftables: an explicit table, an explicit chain, an explicit hook and priority
$ nft add table inet filter
$ nft add chain inet filter input { type filter hook input priority 0 \; }
$ nft add rule inet filter input tcp dport 22 accept
```

The `priority 0` here is directly comparable to where `iptables`' `filter` table implicitly sits relative to `mangle` and `nat` at the same hook — but in `nftables`, that relative position is a number the administrator can see and set explicitly, rather than a fact about `iptables`' internal table-ordering that has to be memorized or looked up separately. This is a genuine architectural improvement from a reasoning-about-correctness standpoint: the entire question section 3 spent effort explaining — "which table runs before which, at a given hook" — becomes directly readable from the configuration itself in `nftables`, rather than requiring outside knowledge of `iptables`' fixed, undocumented-in-the-rules-themselves ordering.

A second genuine difference, beyond just table/chain flexibility: `nftables` rules can match on a considerably richer set of expressions natively, and the tool's internal representation (a bytecode-like instruction set executed by an in-kernel virtual machine, versus `iptables`' more literal, per-rule linear match-and-jump structure) is designed to allow more efficient set-based matching — checking a packet against a large set of addresses or ports can be done as a genuine set-membership lookup, rather than a linear scan through many individual rules each checking one value, which was `iptables`' typical approach for accomplishing the same effective policy (many `-A` rules, each testing one address, evaluated in sequence until one matches or the chain's rules are exhausted).

### 6.3 A concrete illustration of the ordering-visibility difference

Chapter 3, section 5.4 flagged rule-ordering mistakes (in the policy-routing context) as a common source of "correct-looking rules doing the wrong thing," and the exact same category of mistake applies to Netfilter chains — a broad rule earlier in a chain's evaluation order can match and terminate processing (`ACCEPT`, `DROP`, or an implicit fall-through depending on the rule's target) before a more specific rule further down the same chain ever gets evaluated. `iptables`' linear, `-A`-appends-to-the-end model makes this a matter of rule *position within one chain*; `nftables`' explicit priority model extends the same concern to *chains themselves*, when multiple chains attach to the same hook — a chain with a lower (numerically smaller, evaluated earlier) priority value can have a rule that disposes of a packet (accepting or dropping it outright) before a chain with a higher priority value at the same hook is ever consulted. Both tools have real ordering to reason about; `nftables` simply makes that ordering an explicit, inspectable number rather than leaving part of it (the inter-table ordering `iptables` handles implicitly) as background knowledge the administrator has to bring from documentation rather than from the ruleset itself.

## 7. A worked example: tracing one connection through the full hook/table/conntrack picture

It's worth pulling sections 2 through 5 together with a single concrete scenario, because the individual pieces are more useful once their interaction is seen end to end. Consider a home router doing NAT for an internal network, with an internal client initiating an outbound HTTPS connection.

1. The client's SYN packet, source `192.168.1.50:51000`, destination `93.184.216.34:443`, arrives on the router's internal interface. It hits `PREROUTING` first (section 2) — no DNAT rule matches (this traffic isn't destined for a port the router forwards inbound), so the packet passes through unmodified at this hook.
2. Connection tracking, consulted as part of this same early processing, has never seen this flow before — a new conntrack entry is created, in the `NEW` state (section 5.1).
3. Routing (chapter 3) determines this packet needs forwarding, out the router's external interface — the `FORWARD` chain, not `INPUT`, is where filtering rules for this packet apply (chapter 1's original point about chain selection, now with the full mechanism behind it visible).
4. A `FORWARD`-chain filtering rule, in the `filter` table, permits the traffic (an ordinary "allow forwarded traffic from the internal network" policy).
5. The packet reaches `POSTROUTING`, where a `MASQUERADE` rule (section 4.2) rewrites its source address from `192.168.1.50:51000` to the router's own external address and a chosen external port — say, `203.0.113.9:40000` — and this rewrite is recorded in the connection's conntrack entry.
6. The rewritten packet leaves via the external interface, reaching the remote server, which sees a connection apparently originating from `203.0.113.9:40000`.
7. The server's SYN-ACK arrives addressed to `203.0.113.9:40000` — conntrack recognizes this as the reply to the tracked flow from step 2 (now transitioning conntrack's state to `ESTABLISHED`, per section 5.1, well before the TCP handshake itself has actually finished), and — critically — the `PREROUTING` stage on this returning packet consults the *same* conntrack entry to reverse the NAT rewrite automatically, rewriting the destination back to `192.168.1.50:51000` before any routing or filtering decision is made on it.
8. Routing now sees a packet destined for `192.168.1.50` — an internal address — and forwards it inward; a `FORWARD`-chain rule matching `ctstate ESTABLISHED` (section 5.1) permits it, without needing any explicit rule that would otherwise have to open port `51000` on the internal client for inbound traffic.

Every mechanism from this chapter appears somewhere in this single trace: hook ordering determining when the NAT rewrite happens relative to routing (steps 1, 3, 5, 7), the `filter`/`nat` table distinction (steps 4–5), the specific behavior of `MASQUERADE` versus a fixed-address SNAT (step 5), conntrack's `NEW`→`ESTABLISHED` transition happening ahead of the TCP handshake's own completion (steps 2, 7), and stateful filtering relying on that same tracked state rather than a separately-configured inbound rule (step 8).

## 8. A note on bridged traffic and `br_netfilter`

Section 2's hook diagram implicitly assumes a machine that's routing between distinct IP subnets — the ordinary case this chapter has focused on. It's worth flagging a related, genuinely common scenario that behaves differently by default: traffic passing through a Linux **bridge** (chapter 1's `net_device` example included one; chapter 7 covers bridges properly in the context of container networking). A bridge operates at the link layer — it's a software Ethernet switch, forwarding frames based on MAC address tables, with no IP-layer routing decision involved at all for traffic it's simply switching between its ports.

By default, this means bridged traffic never touches the Netfilter hooks this chapter has described — a `FORWARD`-chain rule intended to filter traffic between two bridged interfaces silently does nothing, for exactly the same category of reason chapter 1 warned about with chain selection generally: the traffic in question never reaches that chain to begin with, because it's being switched at layer 2, not routed at layer 3. The `br_netfilter` kernel module changes this default: when loaded (and with the corresponding `sysctl` values — `net.bridge.bridge-nf-call-iptables` and its IPv6/ARP counterparts — enabled), bridged IP traffic is deliberately routed through the same `PREROUTING`/`FORWARD`/`POSTROUTING` hooks this chapter has described, even though it's logically being switched rather than routed. This is precisely the mechanism that lets container runtimes (Docker being the most visible example) apply `iptables`/`nftables`-based firewall rules and NAT to traffic between containers on the same bridge — without `br_netfilter` enabled, none of those rules would ever see that traffic at all, a genuinely common source of "my firewall rules don't seem to apply to container traffic" confusion when this module or its associated sysctls aren't configured as a container runtime expects.

## 9. What's deliberately being deferred

- TCP's own internal behavior — the exact handshake and state transitions referenced in step 7 above — was covered in chapter 1's introduction and gets its full, dedicated treatment in chapter 5, including buffering, retransmission, and congestion control.
- `fwmark`-based policy routing, introduced from the routing side in chapter 3 section 5.3, was only touched on here from the Netfilter side (the `mangle` table's marking capability in section 3) — the composition of the two subsystems is complete once both chapters' halves are combined, but neither chapter alone repeats the other's full treatment.
- eBPF/XDP-based filtering, previewed in chapter 1 as a mechanism that can intercept and drop traffic even earlier than any Netfilter hook (operating before a full `sk_buff` even exists, per chapter 2), remains outside this series' scope — Netfilter and XDP can coexist on the same machine, with XDP typically handling extremely high-volume, simple accept/drop decisions and Netfilter handling the richer, stateful policy this chapter has described.
- Connection-tracking helpers for protocols beyond the FTP example in section 5.1 (SIP, various VPN protocols with embedded control-channel address negotiation) follow the same `RELATED` mechanism but have their own protocol-specific parsing logic not covered here in detail.

## 10. Glossary of terms introduced in this chapter

- **hook** — one of the five fixed points (`PREROUTING`, `INPUT`, `FORWARD`, `OUTPUT`, `POSTROUTING`) in a packet's journey where Netfilter processing can occur (section 2).
- **table** (`iptables` sense) — a fixed grouping of rules by purpose (`raw`, `mangle`, `nat`, `filter`), each with its own fixed evaluation order relative to the others at a shared hook (section 3).
- **DNAT / SNAT / MASQUERADE** — destination and source address translation, and the dynamic, interface-address-following variant of SNAT (section 4).
- **conntrack** — the connection-tracking engine underlying both stateful filtering and NAT, with its own state machine distinct from TCP's own (section 5).
- **`NEW` / `ESTABLISHED` / `RELATED` / `INVALID`** — the conntrack-level connection states, not to be confused with TCP's own connection states (section 5.1).
- **conntrack helper** — protocol-specific logic (e.g., for FTP) that lets conntrack recognize a new flow as `RELATED` to an existing one by inspecting application-layer content (section 5.1).
- **priority** (`nftables` sense) — the explicit numeric value determining evaluation order among multiple chains attached to the same hook (section 6.2).
- **`br_netfilter`** — the kernel module (and associated sysctls) that routes bridged (layer-2-switched) IP traffic through the ordinary Netfilter hooks, which it otherwise bypasses entirely (section 8).

## 11. Diagnosing rule behavior directly, rather than by inspection alone

Sections 2 through 7 built a model precise enough to predict, in principle, what a given ruleset does to a given packet. In practice, it's often faster — and a good way to confirm the model is actually correct — to observe the ruleset's real behavior directly rather than only reasoning about it from `iptables -L` or `nft list ruleset` output.

### 11.1 Rule-hit counters

Both tools maintain per-rule packet and byte counters, visible with `iptables -L -v` or `nft list ruleset -a` (with the `-a` including per-rule handles usable to reference a specific rule precisely). A rule with a zero hit count after traffic that should have matched it has passed through is a direct, unambiguous signal that something about the rule's match conditions, its chain, or its table/priority isn't what was intended — considerably more reliable than re-reading the rule's syntax and assuming it's correct.

### 11.2 `LOG` and `nft ... log`

Both tools support logging matched packets to the kernel log (`iptables -j LOG`, or `nft ... log prefix "some-tag "` as part of an `nftables` rule), without necessarily affecting the packet's fate — a `LOG` rule can sit immediately before a `DROP` or `ACCEPT` rule matching the same conditions, letting an administrator see exactly which packets are hitting a given point in the ruleset, with full header detail, via `dmesg` or the system journal. This is particularly useful for confirming *which* rule in a chain is actually the one making a given decision, when several rules' match conditions could plausibly overlap.

### 11.3 `nft monitor` and rule tracing

`nftables` additionally supports a `trace` statement, which, combined with `nft monitor trace`, shows a packet's actual, real-time path through every rule and chain it's evaluated against — a considerably more direct tool for confirming the hook-ordering and chain-ordering model built in sections 2, 3, and 6 than manually re-deriving it from the ruleset's static text. Enabling tracing on a narrowly-scoped rule (matched only for a specific test connection, to avoid flooding the trace output with unrelated traffic) and then generating that test traffic is often the fastest way to settle an ambiguous "why is this packet being treated this way" question conclusively, rather than continuing to reason abstractly about hook and table ordering.

## 12. A closing note connecting this back to chapters 1 through 3

Chapter 1 introduced Netfilter as five hook points a firewall rule attaches to; chapter 3 explained routing as if Netfilter weren't there at all. This chapter has, hopefully, shown how the two actually compose: `PREROUTING`-stage DNAT can change which routing outcome even applies to a packet; `OUTPUT`-stage processing precedes a locally-originated packet's own routing lookup; and the conntrack table sitting underneath both stateful filtering and NAT is the shared mechanism that lets return traffic be recognized and correctly un-rewritten without a separate, explicit rule for every reply. The worked trace in section 7 is meant to stand in for the kind of reasoning this whole series has been building toward from chapter 1 onward: not memorizing what a specific rule does in isolation, but tracing a single real packet through the full stack of mechanisms and predicting its fate at each step, and section 10's diagnostic tools exist for exactly the moments when that prediction and the ruleset's actual behavior diverge. Chapter 5 turns to the layer this chapter's example repeatedly gestured at but didn't itself explain — what TCP's own state machine and buffering actually look like from the inside, picking up precisely where the SYN and SYN-ACK in section 7's trace left off.

