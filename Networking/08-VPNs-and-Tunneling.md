# Chapter 8: VPNs and Tunneling

## 1. What this chapter is actually for

Chapter 7 closed by previewing this one: a tunnel interface is, mechanically, yet another kind of virtual `net_device`, sitting alongside the `veth` and bridge interfaces chapter 7 introduced. What makes a tunnel distinct — and worth its own chapter rather than a subsection of chapter 7 — is that it connects endpoints that aren't sharing a kernel at all, potentially separated by the entire, untrusted public internet, and it has to solve two problems chapter 7's purely local `veth`/bridge model never had to face: making an arbitrary packet survive a trip across a network that has no idea a private conversation is happening inside it, and, for the VPN case specifically, keeping that packet's contents confidential and authentic from anyone observing the path in between.

This chapter treats WireGuard and IPsec as data-path mechanisms — what each actually does to a packet, structurally — rather than as configuration recipes, in keeping with this series' overall approach. Chapter 1's MTU discussion (section 5.2) already flagged the single most common tunnel-related symptom ("small stuff works, big stuff hangs") without fully explaining the mechanism behind it; this chapter supplies that explanation, along with the broader model needed to reason about any tunnel's behavior from first principles rather than from a checklist of common fixes.

It's worth naming, up front, why this chapter treats WireGuard and IPsec side by side rather than picking one as the primary subject and mentioning the other only briefly: the two protocols represent genuinely different points on a design spectrum — minimal and fixed versus elaborate and configurable — and understanding *why* each made the choices it did is more instructive than learning either one in isolation. A reader who understands only WireGuard's minimal handshake might reasonably wonder why IPsec needs anything as involved as IKE's two-phase negotiation; a reader who understands only IPsec's flexibility might wonder what WireGuard is sacrificing by not offering the same algorithm agility. Holding both models in view simultaneously, as this chapter does, makes each one's design choices legible as trade-offs rather than as arbitrary complexity or arbitrary simplicity.

## 2. Encapsulation: the concept underlying every tunnel

Every tunnel, regardless of protocol, does fundamentally the same thing: it takes an entire packet — headers and all — and wraps it as the *payload* of a new, outer packet, addressed to traverse the actual, physical network between the two tunnel endpoints. This is worth stating in the most general terms first, because it's easy to get lost in any one protocol's specific header formats without noticing that they're all instances of the same underlying idea.

### 2.1 A generic encapsulated packet, structurally

```
Before encapsulation:
+------------------+------------------+
| Original IP hdr  |   Original payload |
| (src: 10.8.0.2)   |                    |
| (dst: 10.8.0.5)   |                    |
+------------------+------------------+

After encapsulation:
+------------------+------------------+------------------+------------------+
| Outer IP hdr     | Outer transport  | Tunnel-specific   |   Original packet |
| (src: 203.0.113.1)| hdr (e.g. UDP)   | header (varies)   |  (entirely intact,|
| (dst: 198.51.100.1)|                  |                   |  possibly encrypted)|
+------------------+------------------+------------------+------------------+
```

The original packet — with its own, entirely separate source and destination addresses, from the tunnel's own private address space (`10.8.0.2`/`10.8.0.5` in this example, exactly the kind of addresses chapter 3's routing model would direct toward a tunnel interface) — is carried, unmodified in its logical content, as payload inside an outer packet whose addresses (`203.0.113.1`/`198.51.100.1`) are the tunnel endpoints' real, publicly-routable addresses. Every router on the actual physical path between those two endpoints sees only the outer packet — it has no visibility into, and no ability to route based on, the inner packet's own addressing at all, which is precisely what makes the inner addressing "private" in the sense chapter 3's discussion of private address ranges implied without fully explaining the mechanism that enforces it.

### 2.2 Why this requires a `net_device`, not just a userspace process

It's worth being explicit about why a tunnel is implemented as a `net_device` (chapter 1, section 5) at all, rather than simply being a userspace process that reads and rewrites packets some other way. Representing a tunnel as a genuine `net_device` means everything chapters 1 through 4 already built — routing (a route can point `dev wg0`, exactly as chapter 1's original routing table example showed), Netfilter (traffic on a tunnel interface passes through the same hooks as any other), and the entire `sk_buff` data path (chapter 2) — applies to tunnel traffic automatically, without any of those subsystems needing tunnel-specific logic. When an application sends a packet destined for an address reachable only via the tunnel, the ordinary FIB lookup (chapter 3) selects the tunnel interface as the outbound device, exactly as it would select any physical NIC — the tunnel's own transmit function (`ndo_start_xmit`, chapter 2's terminology) is then responsible for actually performing the encapsulation described in section 2.1, wrapping the packet, and handing the *resulting*, outer packet back into the ordinary IP transmit path, to be routed again — this time based on the outer addresses — toward the actual physical interface that will carry it onto the wire.

This "packet gets routed twice" structure — once by the application's own connection needing the tunnel, and again by the tunnel's own encapsulated output needing to reach the real remote endpoint — is worth internalizing precisely, because it's the mechanical reason tunnel interfaces interact with routing in ways that can initially seem confusing: a route pointing traffic *into* a tunnel, and a completely separate route (an ordinary route to the tunnel peer's real, public address) governing how the tunnel's own *encapsulated* output actually leaves the machine, are two entirely distinct routing decisions, made by the same FIB (chapter 3) but at two different points in a single logical packet's journey.

## 3. WireGuard: a minimal, modern design

WireGuard is a comparatively recent VPN protocol, deliberately designed around a small, fixed set of cryptographic primitives and a minimal protocol state machine, in contrast to IPsec's considerably larger, more configurable design (section 4). It's worth understanding both, because the design philosophy difference between them explains a great deal about why each behaves the way it does operationally.

### 3.1 The WireGuard interface as seen from routing and addressing

A WireGuard interface (`wg0`, in examples throughout this series) is configured with a private key, a list of peers (each identified by a public key, not by any name or certificate — a deliberate simplification relative to IPsec's certificate/PKI-capable model), and, for each peer, an allowed-IPs list and typically an endpoint address:

```
[Interface]
PrivateKey = <this machine's private key>
Address = 10.8.0.2/24

[Peer]
PublicKey = <peer's public key>
AllowedIPs = 10.8.0.0/24
Endpoint = 203.0.113.1:51820
```

`AllowedIPs` does double duty in a way that's worth being explicit about, because it governs both routing and, separately, a security check: it tells the kernel which inner (tunnel-address-space) destinations should be routed toward this specific peer (functioning as an implicit route, in a multi-peer configuration where different peers are reachable via different, disjoint address ranges), *and* it tells WireGuard which source addresses are acceptable on decrypted, incoming traffic claiming to be from this peer — a packet arriving through the tunnel with a source address outside the configured `AllowedIPs` for the peer it decrypted successfully under is dropped, even though the cryptographic authentication itself succeeded, as a defense against a legitimately-authenticated peer spoofing traffic that should have come from a different peer or address range entirely.

### 3.2 The handshake: a fixed, minimal state machine

WireGuard's handshake (based on the Noise protocol framework) is deliberately simple relative to protocols like IPsec's IKE (section 4.2): a brief, one-round-trip exchange establishing a shared session key between the two peers, after which all data traffic is protected using that session key, with keys rotated automatically on a fixed schedule (roughly every two minutes, by default) rather than remaining fixed indefinitely — a design choice specifically limiting how much traffic, and for how long, any single compromised key could expose, without requiring any administrator-visible re-negotiation process to achieve this rotation, since it happens automatically and transparently as part of the protocol's ordinary operation.

It's worth being precise about a consequence of this design that surprises people coming from more traditional VPN protocols: WireGuard has no persistent "connection" in the TCP sense at all — it's fundamentally connectionless at the protocol level (built on UDP, chapter 5's section 5, for exactly the reasons that section described UDP suiting applications that don't need TCP's particular reliability guarantees), and a WireGuard interface will silently attempt a fresh handshake whenever it has data to send and no valid, current session key exists, rather than maintaining any explicit "connected"/"disconnected" state an administrator might expect to observe directly. This is precisely why a WireGuard interface can appear, from `ip link show`, to be up and configured correctly, seemingly indefinitely, even when the actual remote peer has been unreachable for hours — there's no persistent-connection state to reflect that unreachability back to the interface's own reported status; the failure only becomes visible when the next real data packet needs to be sent and the resulting fresh handshake attempt fails.

### 3.3 Diagnosing a WireGuard tunnel: what's actually observable

Given the above, it's worth knowing what genuinely useful, observable state does exist for a WireGuard interface, since the interface's own up/down status alone is close to useless for diagnosis:

```
$ wg show wg0
interface: wg0
  public key: <this machine's public key>
  private key: (hidden)
  listening port: 51820

peer: <peer's public key>
  endpoint: 203.0.113.1:51820
  allowed ips: 10.8.0.0/24
  latest handshake: 2 minutes, 14 seconds ago
  transfer: 128.40 KiB received, 94.12 KiB sent
```

The `latest handshake` field is, in practice, the single most useful piece of diagnostic information available for a WireGuard tunnel — a recent, successful handshake is strong, direct evidence the tunnel is genuinely working end to end (since a handshake requires the peer to correctly decrypt and respond to a cryptographic exchange, not merely respond to some simpler reachability check), while a handshake that's aged well beyond the roughly-two-minute rotation interval, with no fresher one replacing it, indicates the tunnel has stopped functioning, even if the interface itself still reports as administratively up. Combined with `transfer` (cumulative bytes moved, directly comparable across repeated checks to confirm data is actually flowing, not merely that a handshake once succeeded in the past), this gives a genuinely reliable picture of tunnel health, considerably more reliable than inferring health from interface state alone, exactly analogous to chapter 3's warning (section 4.2's closing note) that a `FAILED` neighbor-cache entry on a point-to-point interface reflects something different from an ordinary ARP problem — here, an "up" WireGuard interface with a stale handshake reflects something different from the interface simply being misconfigured.

### 3.4 Roaming: why WireGuard tolerates endpoint changes gracefully

One further behavior worth understanding, because it's a genuine design advantage stemming directly from section 3.2's connectionless model: a WireGuard peer's configured `Endpoint` address is not treated as fixed and authoritative in the way a TCP connection's four-tuple is (chapter 1, section 8) — if a valid, authenticated packet arrives from a *different* source address than the currently-recorded endpoint for that peer, WireGuard updates its records to that new address and continues the conversation without interruption, provided the packet decrypts successfully under that peer's known key. This is precisely what lets a WireGuard tunnel survive a client roaming between networks (a laptop moving from Wi-Fi to a cellular connection, changing its own public-facing address entirely) without the tunnel needing to be manually reconnected or even necessarily going down at all from the application's perspective — the next data packet or keepalive triggers a fresh handshake if the session key has expired, or simply continues using the existing session key with WireGuard silently updating its notion of "where this peer currently is" based on the cryptographically-authenticated source of the most recent valid packet. This stands in useful contrast to more traditional VPN designs, including many IPsec deployments, where a Security Association can be considerably more tightly bound to a specific expected peer address, making this kind of transparent roaming a less automatic property of the protocol itself, though achievable in some IPsec configurations with additional mechanisms specifically layered on top for this purpose.

## 4. IPsec: a more elaborate, more configurable design



IPsec predates WireGuard by decades and reflects a considerably different design philosophy: rather than one small, fixed protocol, it's a framework encompassing multiple distinct protocols (AH and ESP, section 4.1), a separate key-negotiation protocol (IKE, section 4.2), and a highly configurable policy system (the Security Policy Database and Security Association Database, section 4.3) — genuinely more capable of expressing complex, multi-party, certificate-based deployments than WireGuard's minimal peer-list model, at the cost of considerably more configuration surface and, historically, a reputation for being harder to get right.

### 4.1 AH and ESP: two different things IPsec can do to a packet

IPsec defines two distinct protocols for actually protecting packet data, and it's worth distinguishing them clearly, since they serve different purposes and are sometimes conflated. **AH (Authentication Header)** provides authentication and integrity — cryptographic proof the packet genuinely came from the claimed sender and wasn't modified in transit — but does *not* encrypt the payload at all; the original packet's contents remain visible to anyone observing the path, merely with cryptographic assurance they weren't tampered with. **ESP (Encapsulating Security Payload)** provides both authentication/integrity *and* encryption, actually hiding the original packet's contents from on-path observers, and is, in practice, the considerably more commonly deployed of the two — most real-world IPsec VPN deployments use ESP specifically because confidentiality, not merely authenticity, is the usual goal, with AH reserved for narrower cases where encryption isn't needed or is deliberately excluded (some regulatory or network-monitoring contexts specifically want packet contents inspectable in transit while still wanting tamper-evidence, which is exactly AH's niche).

### 4.2 IKE: negotiating the actual cryptographic parameters

Where WireGuard's handshake (section 3.2) is fixed and minimal, IPsec's key-negotiation protocol, **IKE (Internet Key Exchange)**, is considerably more elaborate specifically because IPsec supports negotiating *which* cryptographic algorithms to use at all (a deliberate flexibility WireGuard's design philosophy explicitly rejects, on the reasoning that algorithm agility introduces more attack surface — a downgrade to a weaker negotiated algorithm being a classically exploited category of vulnerability — than it provides genuine benefit). IKE operates in two phases: Phase 1 establishes a secure channel between the two peers themselves (analogous in spirit, though not in mechanism, to WireGuard's single handshake), and Phase 2, running inside that already-secured Phase 1 channel, negotiates the specific parameters (algorithms, key lifetimes) for the actual data-protecting Security Associations that ESP or AH will use. This two-phase structure, plus the underlying algorithm-negotiation flexibility, is precisely why IPsec configuration involves considerably more explicit parameters than WireGuard's comparatively terse configuration file — an administrator is, in effect, specifying choices WireGuard's design deliberately made in advance and doesn't expose as configuration at all.

### 4.3 Security Associations: IPsec's per-direction, per-algorithm state

A subtlety worth flagging because it trips people up when first inspecting IPsec state directly: a single logical IPsec "tunnel" between two peers is actually represented, in the kernel's IPsec subsystem (`net/xfrm/`, chapter 1's brief mention of this directory now getting its payoff), as at least two separate **Security Associations (SAs)** — one governing traffic in each direction — each with its own negotiated keys, its own sequence-number state (used for replay protection, detecting and rejecting a captured-and-resent packet), and its own lifetime, after which IKE must renegotiate fresh keys for that direction. This is directly visible:

```
$ ip xfrm state
src 203.0.113.1 dst 198.51.100.1
    proto esp spi 0xc1a2b3d4 reqid 1 mode tunnel
    auth-trunc hmac(sha256) ...
    enc cbc(aes) ...
src 198.51.100.1 dst 203.0.113.1
    proto esp spi 0xd4c3b2a1 reqid 1 mode tunnel
    auth-trunc hmac(sha256) ...
    enc cbc(aes) ...
```

Two entries, one per direction, each with its own Security Parameter Index (`spi`) — a value carried in every ESP packet's header specifically to let the receiving end identify which of its (potentially many, in a multi-peer deployment) Security Associations should be used to process that specific packet. This is a genuinely different bookkeeping model from WireGuard's single, symmetric session key per peer (section 3.2) — a design difference worth understanding precisely because diagnosing an asymmetric IPsec failure (traffic flows in one direction but not the other) is directly explained by this per-direction SA structure: it's entirely possible, and a real, observable failure mode, for one direction's SA to be correctly established while the other's negotiation failed or expired without being renewed, something WireGuard's simpler, inherently bidirectional session-key model doesn't have a direct analog for.

## 5. The MTU problem, revisited with the actual mechanism now visible

Chapter 1's section 5.2 described the "small stuff works, big stuff hangs" symptom without fully explaining it. With encapsulation's structure now visible (section 2.1), the mechanism is straightforward to state precisely: every tunnel adds header overhead — the outer IP header, any outer transport header (UDP, for WireGuard), and the tunnel-specific header and authentication/encryption overhead (an ESP or WireGuard header, plus whatever padding or authentication tag the specific cryptographic mode requires) — on top of whatever the inner packet already was. If the inner packet was already close to the *physical* path's MTU, adding this overhead pushes the resulting outer packet over that physical MTU, requiring fragmentation (chapter 5, section 5.3's discussion of UDP fragmentation costs applies directly here, since WireGuard's outer transport is UDP) or, if fragmentation is blocked somewhere along the path (a common, deliberate security posture on many networks, precisely because fragmented traffic is harder to inspect statefully, as chapter 4's connection-tracking discussion implied), outright silent loss of the oversized packets specifically, while smaller packets that don't cross this threshold continue working normally.

### 5.1 Why the fix is lowering the tunnel's own MTU, not the physical link's

The correct fix, given this mechanism, follows directly: the tunnel interface's own configured MTU (`ip link set wg0 mtu 1420`, a value chapter 1's section 5.2 mentioned without deriving) needs to be set low enough that even after the tunnel's own encapsulation overhead is added, the resulting outer packet still fits comfortably within the *physical* path's actual MTU — not the tunnel's MTU, the physical link's. This is precisely why WireGuard's commonly-recommended default MTU (1420, versus ordinary Ethernet's 1500) reflects roughly 80 bytes of overhead budget for the WireGuard header, UDP header, and outer IP header combined — set conservatively enough to leave room even when the physical path itself has slightly reduced MTU somewhere along its length (a common real-world case, since many ISP or corporate network paths carry additional encapsulation of their own, such as PPPoE, reducing the *effective* usable MTU below Ethernet's nominal 1500 well before a VPN tunnel's own overhead is even considered). Setting the tunnel's MTU too high relative to the true physical path doesn't produce an error anywhere — it produces exactly the silent, size-dependent failure pattern this section has now fully explained, discoverable only by noticing the specific "small packets fine, large packets fail" signature and reasoning through this exact chain from application data size down to physical-path MTU.

### 5.2 A worked diagnostic sequence for the MTU symptom

Given the mechanism section 5 just established, it's worth turning it into a concrete checklist, in keeping with this series' habit of closing out mechanism explanations with an actionable sequence. Faced with a tunnel where small connections (DNS, SSH sessions) work but larger transfers hang or stall:

1. Confirm the symptom matches this specific pattern by testing with a deliberately large, uninterrupted ping (`ping -M do -s 1400 <peer-tunnel-address>`, the `-M do` flag disabling fragmentation so a failure is unambiguous rather than silently fragmented and masked) against a range of sizes, looking for the specific size threshold where failure begins — this threshold, once found, directly indicates the effective MTU the path can actually sustain.
2. Compare that discovered threshold against the tunnel interface's currently configured MTU (`ip link show wg0`) — if the configured MTU is higher than what step 1 discovered, that gap is the direct cause.
3. Lower the tunnel's MTU to a value comfortably below the discovered threshold (leaving some margin for section 5.1's overhead budget, since the discovered threshold in step 1 already reflects the *outer*, encapsulated packet's actual limit, meaning the tunnel's own MTU — governing the *inner* packet size before encapsulation — needs to be lower than that threshold by roughly the tunnel's own header overhead, not equal to it).
4. If no single MTU value resolves the problem across all destinations reachable through the tunnel — a symptom suggesting the *physical* path's effective MTU varies depending on destination, not merely being uniformly lower than Ethernet's nominal 1500 — investigate Path MTU Discovery specifically, since a network that's dropping the ICMP "fragmentation needed" messages this mechanism relies on (a common, if debatably advisable, firewall configuration) can prevent endpoints from ever correctly discovering a path's true, possibly destination-dependent, MTU limit on their own.

This sequence deliberately isolates the *symptom's threshold* (step 1) before touching any configuration, precisely because guessing at an MTU value and testing empirically without first establishing the actual failure threshold risks either leaving unnecessary overhead margin (a smaller-than-necessary MTU, costing some throughput efficiency) or under-correcting entirely (a value still too high, leaving the original symptom only partially resolved in a way that might not be immediately obvious).

## 6. Split tunneling and full tunneling: a routing decision, not a VPN-protocol one



A final concept worth covering explicitly, because it's often described as if it were a VPN-protocol-specific feature rather than what it actually is: whether *all* of a client's traffic gets routed through a VPN tunnel ("full tunneling") or only traffic destined for specific, tunnel-reachable subnets ("split tunneling") is, mechanically, nothing more than an application of chapter 3's ordinary routing model — specifically, what the tunnel interface's associated routes actually cover. A configuration where the tunnel interface is assigned only a route for `10.8.0.0/24` (matching section 3.1's `AllowedIPs` example) is split tunneling — traffic to that specific subnet uses the tunnel, everything else uses the client's ordinary default route, entirely unaffected. A configuration where the tunnel interface is instead assigned the *default* route itself (`0.0.0.0/0`, chapter 3's longest-prefix-match logic then directing essentially all traffic toward the tunnel, since nothing more specific exists to compete with it) is full tunneling — every packet, regardless of destination, gets encapsulated and sent through the tunnel, including traffic that has nothing to do with whatever the tunnel's actual purpose is.

This is worth understanding precisely because it means "should this be split or full tunneling" is genuinely a routing-table decision, not a distinct feature toggle some protocols support and others don't — both WireGuard's `AllowedIPs` (section 3.1) and an IPsec Security Policy Database entry ultimately resolve to ordinary kernel routes (or, for WireGuard specifically, routes the `AllowedIPs` configuration causes to be installed automatically), and reasoning about which traffic will and won't traverse a given tunnel is, in every case, exactly the longest-prefix-match reasoning chapter 3 already built, applied to whatever specific routes a given tunnel's configuration happens to install.

## 7. What's deliberately being deferred

- The cryptographic primitives themselves (which specific ciphers, key-exchange algorithms, and their relative security properties) are outside this series' networking-mechanism focus — this chapter treats encryption and authentication as black-box operations a tunnel performs, not as a subject in cryptography.
- IKEv1 versus IKEv2's specific protocol differences, and the considerable configuration surface real-world IPsec deployments involve (certificate management, NAT-traversal encapsulation for IPsec specifically, which has its own considerations distinct from WireGuard's inherently NAT-friendly UDP-based design) are not covered in the depth a dedicated IPsec-focused treatment would require.
- GRE and other non-VPN tunneling protocols (used for plain encapsulation without any cryptographic protection at all, common in certain routing and multicast-distribution scenarios) follow the same section 2 encapsulation model but aren't covered individually here, since they add nothing conceptually beyond what sections 2 through 5 already establish, absent the cryptographic and key-management concerns specific to sections 3 and 4.
- Traffic control interaction with tunnel interfaces (rate-limiting or prioritizing traffic specifically at the tunnel boundary, as opposed to the physical interface underneath it) is chapter 9's subject, applying the qdisc model from chapter 2, section 5.2, to tunnel interfaces exactly as it would to any other `net_device`.

## 8. Glossary of terms introduced in this chapter

- **encapsulation** — wrapping an entire original packet, headers included, as the payload of a new outer packet addressed for the actual physical path between tunnel endpoints (section 2.1).
- **`AllowedIPs`** (WireGuard) — a per-peer configuration value serving both as an implicit route and as a source-address filter on decrypted incoming traffic (section 3.1).
- **roaming** (WireGuard) — the protocol's ability to update a peer's recorded endpoint address transparently upon receiving a validly-authenticated packet from a new source, without requiring the tunnel to be reconnected (section 3.4).
- **AH / ESP** (IPsec) — Authentication Header (integrity/authentication only) and Encapsulating Security Payload (integrity, authentication, and encryption), the two protocols IPsec can use to protect a packet (section 4.1).
- **IKE (Internet Key Exchange)** — IPsec's key-negotiation protocol, operating in two phases and supporting negotiable cryptographic algorithms, in contrast to WireGuard's fixed, minimal handshake (section 4.2).
- **Security Association (SA)** — a per-direction IPsec state record (keys, sequence numbers, lifetime), meaning a single logical IPsec tunnel is actually at least two independent SAs (section 4.3).
- **SPI (Security Parameter Index)** — a value carried in each ESP/AH packet identifying which Security Association the receiver should use to process it (section 4.3).
- **Path MTU Discovery** — the mechanism by which endpoints learn a path's true, possibly destination-dependent, MTU limit, dependent on ICMP "fragmentation needed" messages not being blocked along the path (section 5.2).
- **split tunneling / full tunneling** — whether only specific, tunnel-reachable subnets or all traffic gets routed through a tunnel, determined entirely by ordinary routing configuration rather than any tunnel-protocol-specific mechanism (section 6).

## 9. A closing note connecting this back to the rest of the series

Every mechanism this chapter has described was, in a real sense, already available in this series by the end of chapter 4: a tunnel interface is a `net_device` (chapter 1); encapsulated traffic is ordinary `sk_buff` data flowing through the transmit path (chapter 2), just constructed by a tunnel-specific transmit function rather than a physical driver; which traffic goes into a tunnel, and how a tunnel's own encapsulated output finds its way to the real remote endpoint, are both ordinary FIB lookups (chapter 3), just applied twice in sequence to a single logical packet's journey; and a tunnel interface's traffic traverses the same Netfilter hooks (chapter 4) as anything else, meaning a firewall rule can filter tunnel traffic exactly as it would filter any other interface's traffic, with no special tunnel-specific exception required. What's genuinely new in this chapter is narrow and specific: the cryptographic handshake and key-management machinery (sections 3 and 4) that WireGuard and IPsec each layer on top of this otherwise-ordinary `net_device`/routing/Netfilter foundation, and the MTU arithmetic (section 5) that encapsulation's added overhead makes newly relevant in a way it wasn't for chapter 7's uncompressed `veth`/bridge model.

Chapter 9 turns to traffic control — the queueing-discipline mechanism chapter 2 introduced only briefly (section 5.2) as a checkpoint sitting between a routing decision and a driver's transmit function — and covers, in full, how that checkpoint can be used to shape, prioritize, and rate-limit traffic on any interface this series has discussed, physical or virtual, tunnel or otherwise.
