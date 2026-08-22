# Chapter 6: DNS Resolution Internals

## 1. What this chapter is actually for

Every chapter so far has assumed a destination IP address already exists by the time routing, Netfilter, or TCP gets involved. In practice, the overwhelming majority of connections start from a name, not an address, and the process that turns one into the other is more involved — and more often the actual cause of "the network is broken" reports — than its everyday description ("DNS resolves names to IPs") suggests. This chapter traces that process in full: from an application's `getaddrinfo()` call, through the Name Service Switch, through whatever local caching resolver is involved, out to an actual DNS query on the wire, and back.

Chapter 1 already flagged the central fact this chapter expands on: DNS resolution is not a single, atomic step, and "it resolves with `dig` but not in the application" is a symptom with a small, specific set of causes, almost all traceable to different parts of this chapter's resolution path being configured, or cached, differently for the two lookup routes. Understanding the full path precisely is what turns that symptom from a mystery into a short, mechanical checklist.

It's worth being explicit about a framing choice this chapter makes, because it shapes what does and doesn't get covered: everything here concerns DNS as a *client* — how a machine resolves names, and where that process can diverge from expectations. Running authoritative DNS infrastructure (designing zone files, managing delegation, operating nameservers that answer for a domain) is a related but genuinely separate skill, closer to systems administration for a specific service than to the kernel- and protocol-level mechanism this series has focused on elsewhere. This chapter's treatment of authoritative servers (section 4) is limited to what a resolving client needs to understand about them — that they exist, and how a recursive resolver finds and queries them — not how to operate one.

## 2. The Name Service Switch: DNS is one source among several

An application almost never calls "the DNS resolver" directly. It calls `getaddrinfo()` (the modern, protocol-agnostic name resolution function; the older `gethostbyname()` still exists for legacy code but resolves through the same underlying machinery) — a C library function that consults the **Name Service Switch (NSS)**, configured in `/etc/nsswitch.conf`, to decide which source or sources of naming information to consult, and in what order.

```
$ cat /etc/nsswitch.conf
...
hosts:      files dns
...
```

This single line is doing more work than it might appear to. It says: for hostname lookups, consult `files` first (meaning `/etc/hosts`), and only if that source doesn't have an answer, fall through to `dns`. Each of these — `files`, `dns`, and others that can appear here (`mdns` for multicast DNS/Bonjour-style local discovery, `myhostname` for resolving the machine's own configured hostname, `ldap` in some enterprise environments) — is implemented as a separate NSS module, and `getaddrinfo()` walks through them in the configured order, returning the first authoritative answer it gets.

### 2.1 Why `/etc/hosts` matters more than it looks like it should

This ordering explains a specific, common troubleshooting trap: an entry in `/etc/hosts` for a given hostname will always win over whatever DNS would otherwise return, silently, for every single lookup of that name on this machine, regardless of what any DNS record says. A stale `/etc/hosts` entry — left over from a manual edit made months earlier for a since-resolved testing purpose — can cause a name to resolve to an outdated address indefinitely, in a way that's completely invisible to `dig` or `nslookup` run against DNS directly, since those tools bypass NSS and query DNS servers directly rather than going through `getaddrinfo()`'s NSS-mediated path. This is precisely the mechanical explanation behind chapter 1's flagged symptom: `dig somehost.example.com` can report one address while an application resolving the same name reports a different one, and the discrepancy has nothing to do with DNS caching or propagation delay at all — it's simply `/etc/hosts` intercepting the lookup before DNS is ever consulted.

### 2.2 `getent hosts`: testing resolution the way an application actually sees it

Because of this gap between `dig` (DNS-only) and an application's actual resolution path (NSS-mediated), it's worth knowing about a tool that exercises the *real* path directly: `getent hosts <name>` calls the exact same NSS-mediated resolution machinery any ordinary application linked against the standard C library would use, respecting `/etc/nsswitch.conf`'s configured order, `/etc/hosts`, and whatever caching layer sits in front of DNS (section 4). Reaching for `getent hosts` rather than `dig` when the actual question is "what would my application see" — rather than "what does DNS itself currently say" — is precisely the habit that avoids the false lead described in section 2.1, and it's worth adopting as the default first diagnostic step for any resolution discrepancy, ahead of anything DNS-server-specific.

### 2.3 Other NSS sources worth knowing exist

Section 2's example configuration listed only `files` and `dns`, the two overwhelmingly most common sources for hostname resolution, but it's worth knowing NSS is a genuinely general mechanism, not one specific to DNS. `myhostname`, when present, resolves the machine's own configured hostname (and a handful of well-known special names like `localhost`) without consulting any external source at all — this is why a machine can typically resolve its own hostname to its own address even with no network connectivity whatsoever, and why that specific lookup's behavior can seem to follow different rules than an ordinary external hostname lookup, because it genuinely is handled by different logic entirely, resolved locally before `dns` or even `files` would ordinarily be consulted. `mdns`/`mdns4`/`mdns6` variants handle multicast DNS, the zero-configuration, broadcast-based mechanism `.local`-suffixed names typically use (Apple's Bonjour and the broader Avahi implementation both build on this), which works entirely differently from the recursive, hierarchical DNS this chapter otherwise describes — it has no central authority at all, with each device on a local network segment simply announcing its own name directly. A machine's NSS configuration determining which of these gets consulted, and in what order, for any given lookup is precisely why two machines on the same network, with differently-ordered `nsswitch.conf` files, can resolve the identical name differently, or resolve one name successfully while the other machine fails on the exact same name, purely as a function of NSS configuration rather than anything about the name or the network itself.

## 3. From NSS to an actual DNS query: the resolver library



Once NSS's `dns` module is reached, actual DNS protocol work begins, handled by the resolver library (`glibc`'s implementation, or a functionally similar one on other C libraries) consulting `/etc/resolv.conf`:

```
$ cat /etc/resolv.conf
nameserver 127.0.0.53
options edns0 trust-ad
search example.com corp.internal
```

Each line here does distinct work worth understanding individually.

### 3.1 `nameserver`: which DNS server(s) to actually query

The `nameserver` line(s) — there can be several, tried in order if earlier ones don't respond — give the resolver library the address of an actual DNS server to send queries to. On many modern desktop Linux distributions, this is not the actual upstream DNS server at all; `127.0.0.53` is a strong signal that `systemd-resolved` (section 5) is running locally, intercepting this address and acting as a caching, forwarding intermediary between the resolver library and whatever real upstream DNS servers are actually configured (visible via `resolvectl status` rather than this file directly, on such a system). This is worth flagging immediately because it's a common point of confusion: editing `/etc/resolv.conf` directly on a `systemd-resolved`-managed system frequently doesn't have the effect an administrator expects, precisely because the file gets regenerated by `systemd-resolved` itself, pointing back at its own local listening address, undoing a manual edit on the next regeneration.

### 3.2 `search`: how a bare hostname becomes a fully-qualified one

The `search` line lists domain suffixes the resolver will try appending to a bare (non-fully-qualified) hostname before giving up. Given the configuration above, a lookup for the bare name `db1` would actually generate queries for `db1.example.com`, then `db1.corp.internal`, in that order, only falling through to treating `db1` as if it were already fully-qualified (or failing outright) if neither suffixed attempt succeeds. This is exactly the mechanism that lets internal tooling refer to `db1` rather than `db1.corp.internal` everywhere, and it's also a common source of a specific, confusing failure mode: a name that resolves correctly by coincidence — because it matches a suffix search entry unintentionally — behaving differently once that search configuration changes (a machine moved to a different network, with a different `search` list, no longer successfully resolving a bare name that happened to work before purely by accident of suffix matching, not because the name was ever actually fully qualified in the way the application's configuration assumed).

### 3.3 `options`: behavioral flags on the resolution process itself

The `options` line configures resolver-internal behavior distinct from where or how queries get sent. `edns0` enables Extension Mechanisms for DNS, needed for several modern DNS features (including, notably, DNSSEC validation signaling and responses larger than what the original DNS specification's message size allowed for) — a resolver without `edns0` enabled can fail in subtle ways against modern DNS infrastructure that assumes its availability. `trust-ad` relates to DNSSEC (chapter 10 touches on DNS security more broadly): it tells the resolver library to trust an upstream recursive resolver's own "Authenticated Data" flag rather than performing DNSSEC validation itself — a reasonable choice when the upstream resolver (an ISP's or `systemd-resolved`'s own upstream) is itself trusted to have already done that validation correctly, but a meaningfully different security posture than validating locally, worth knowing about specifically because it means DNSSEC's guarantees, when configured this way, rest on trusting an intermediary rather than being independently verified end to end by this specific machine.

## 4. The DNS query itself: structure and the recursive resolution process

Once the resolver library has a fully-qualified name and a server to query, an actual DNS query gets constructed and sent — ordinarily as a single UDP datagram (chapter 5, section 5, covered UDP's characteristics directly; DNS is one of its most common real-world uses), though modern DNS increasingly falls back to or even prefers TCP for larger responses or specific security-oriented deployments (DNS-over-TLS and DNS-over-HTTPS, both covered briefly in section 7, run over TCP-based transports by necessity).

### 4.1 Recursive versus authoritative: who actually answers

It's worth being precise about a distinction that's easy to blur: the server this machine's resolver actually talks to (`127.0.0.53`, or whatever a corporate or ISP-provided nameserver address resolves to) is almost never the **authoritative** server for the domain being looked up — it's a **recursive resolver**, whose job is to, on behalf of the querying client, perform however many additional queries are needed against the actual authoritative infrastructure for that name, and return a final answer, rather than requiring the client itself to walk the DNS hierarchy manually.

A recursive resolver handling a fresh (uncached) query for `www.example.com` performs, roughly:

1. A query to one of the 13 root DNS server clusters (well-known, hardcoded addresses every recursive resolver ships with), asking, in effect, "who is authoritative for `.com`?"
2. A query to the `.com` top-level-domain (TLD) server returned by that first answer, asking "who is authoritative for `example.com`?"
3. A query to `example.com`'s own authoritative nameserver (returned by the TLD server), asking, finally, "what is the address for `www.example.com`?"

Each of these is a distinct network round trip the *recursive resolver* performs, entirely transparent to the original client, which sent exactly one query and receives exactly one answer, with all of this multi-step work happening behind that single exchange. This is worth knowing precisely because it explains where a fresh, uncached DNS lookup's latency actually comes from — potentially three or more sequential round trips, each to a different server, chained together — versus a cached lookup, which the recursive resolver can answer immediately from its own cache without any of these round trips at all, explaining the often dramatic difference in latency between a "cold" and "warm" DNS lookup for the same name.

### 4.2 TTL: how long a cached answer stays valid

Every DNS record carries a **Time To Live (TTL)** value, set by the authoritative nameserver, specifying how long any resolver caching this record — the recursive resolver, and potentially a local caching layer on top of it (section 5) — is permitted to serve it from cache before it must be re-queried from the authoritative source. This is directly why changing a DNS record doesn't take effect everywhere instantaneously: every resolver that had cached the old value, at any point in this multi-hop chain, continues serving it until that specific cached copy's TTL expires, and different resolvers may have cached the record at different times, meaning the "propagation" of a DNS change is really just many independent caches expiring at different, staggered moments rather than any single coordinated update event. A commonly-used operational technique — lowering a record's TTL well in advance of a planned change, then raising it again afterward — exists specifically to shrink this staggered-expiry window ahead of a change that needs to take effect predictably and quickly, at the cost of increased query volume against the authoritative servers during the low-TTL period, since a shorter TTL means every cache expires and re-queries more frequently.

### 4.3 Why the recursive resolver, not the client, does the walking

It's worth being explicit about why DNS is architected this way — with a client delegating the entire multi-step lookup to a recursive resolver, rather than performing the root→TLD→authoritative walk itself. A few considerations converge on this design: first, caching efficiency — a recursive resolver serving many clients (an ISP's resolver, serving thousands of subscribers) can cache the intermediate results (which server is authoritative for `.com`, for instance) once and reuse them across every client's queries, rather than each individual client needing to independently discover and cache the same intermediate information; second, simplicity for the client — a client only ever needs to know the address of *one* resolver, rather than needing built-in knowledge of the root server addresses and the logic to walk the hierarchy correctly (though every recursive resolver does need exactly this knowledge, which is why root server addresses are widely published and effectively fixed, changing only very rarely and with extensive advance notice); and third, this design places the majority of the query volume against root and TLD servers onto a comparatively small number of well-provisioned recursive resolvers, rather than every single client machine on the internet independently querying the root servers directly for every fresh lookup — a load-distribution property that's been essential to the DNS root infrastructure remaining operationally manageable at internet scale.

## 5. Local caching layers: what sits between the resolver library and the network



Section 3.1 already flagged that `127.0.0.53` in `/etc/resolv.conf` typically signals a local caching daemon rather than a genuine upstream server. It's worth understanding what such a daemon actually does, because it's a second, distinct caching layer sitting *in front of* whatever caching the upstream recursive resolver (section 4) itself performs.

### 5.1 `systemd-resolved`

On modern systemd-based distributions, `systemd-resolved` is typically this local layer: it listens on `127.0.0.53` (and, for compatibility, `127.0.0.1` in some configurations), maintains its own cache of recently-resolved records (respecting each record's own TTL from section 4.2), and forwards actual queries to whichever upstream DNS servers are configured — often ones automatically learned from DHCP or a VPN connection, in addition to or instead of any manually-configured servers. Its status, including which upstream servers are actually in use (which may not match what a stale reading of `/etc/resolv.conf` alone would suggest, per the caveat in section 3.1) is inspectable directly:

```
$ resolvectl status
Global
       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (eth0)
    Current Scopes: DNS
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 192.168.1.1
       DNS Servers: 192.168.1.1
```

This output is worth reading carefully in any resolution troubleshooting scenario, precisely because it shows the *actual* upstream server in use — here, `192.168.1.1`, likely a local router doing its own DNS forwarding — a fact that `cat /etc/resolv.conf` alone (showing only `127.0.0.53`, the local stub listener) would never reveal on its own.

### 5.2 `dnsmasq` and other alternatives

Not every system runs `systemd-resolved`; `dnsmasq` (common on many router/gateway devices, and occasionally on desktop Linux configurations predating or deliberately avoiding `systemd-resolved`) fills a broadly similar role — local caching, plus, on router-class devices, DHCP service for a local network, with each DHCP lease often getting an automatically-generated local DNS entry, letting devices on a home or small office network resolve each other's hostnames without needing an authoritative DNS zone to be manually maintained anywhere. The specific caching behavior and available diagnostic commands differ from `systemd-resolved`'s, but the underlying purpose — reducing repeated round trips to an upstream recursive resolver by serving a local cache — is the same, and the same general diagnostic principle applies regardless of which specific daemon is in play: check what the local caching layer itself is actually forwarding to and caching from, rather than assuming `/etc/resolv.conf`'s literal contents represent the actual upstream in use.

### 5.3 A worked example: diagnosing a stale cache with two layers in play

Given the two caching layers this section has now described — the recursive upstream resolver's own cache (section 4.2) and a local caching daemon's cache (this section) — a genuinely stale DNS answer can originate from either layer, and distinguishing them matters for knowing what to actually flush or wait out. `resolvectl flush-caches` (for `systemd-resolved`) or the equivalent for whichever local daemon is in use clears only the *local* cache; if the answer served afterward is still stale, the staleness lives in the upstream recursive resolver's own cache instead, which isn't something this machine has any direct control over — the only remedy at that point is waiting out the record's TTL (section 4.2) at that upstream layer, or, if the upstream is itself under administrative control (a self-hosted recursive resolver, rather than an ISP's), flushing its cache specifically. Confusing these two layers — flushing the local cache and concluding the problem is unresolved because the underlying upstream cache is what was actually stale — is a common, avoidable troubleshooting dead end once the two-layer structure is understood clearly.

### 5.4 Negative caching at the local layer, and why it can outlast a fix

Section 6.3 will describe DNS's own negative-answer (`NXDOMAIN`) caching in the context of authoritative and recursive-resolver behavior; it's worth noting here, ahead of that, that local caching daemons typically implement their own negative caching as well, independent of and sometimes with different timing characteristics than whatever negative-caching TTL the authoritative zone specifies. This means a `flush-caches` at the local layer (section 5.3) is genuinely the right first move for a suspected negative-caching problem, precisely because it clears this local negative-cache entry immediately, without needing to wait out whatever TTL the authoritative side originally specified — a small but practically useful distinction between the two negative-caching layers, since only one of the two (the local one) is typically directly clearable on demand from the affected machine itself.

## 6. What a DNS answer actually contains, beyond a bare address



Section 4 described DNS answers loosely as "an address." It's worth being more precise, because DNS records come in several distinct types, and conflating them is a source of confusion in more elaborate lookups.

### 6.1 A vs AAAA: IPv4 and IPv6 as separate record types

An `A` record maps a name to an IPv4 address; an `AAAA` record maps the same (or a different) name to an IPv6 address — entirely separate record types, queried separately (though `getaddrinfo()`, section 2, typically queries for both automatically on a dual-stack system, per chapter 1's section 11 treatment of dual-stack hosts, and returns whichever addresses exist, letting the application or a lower-level connection mechanism choose between them). A domain can have only an `A` record, only an `AAAA` record, or both — and a name resolving successfully for IPv4 but failing for IPv6 (or vice versa) is a legitimate, common state reflecting a domain operator's own dual-stack deployment choices, not necessarily a client-side resolution problem.

### 6.2 CNAME: an alias, not an answer

A `CNAME` record doesn't provide an address at all — it says "this name is an alias for that other name; look *that* one up instead." A lookup for `www.example.com` might return a `CNAME` pointing to `example.com.cdn-provider.net`, which the resolver then transparently re-queries (potentially following several chained `CNAME`s, in principle, though excessively long chains are considered poor practice and most authoritative infrastructure avoids them) until it reaches a name with an actual `A`/`AAAA` record. This is precisely the mechanism behind most CDN and cloud-load-balancer integrations: a domain operator points their own name at the CDN provider's name via `CNAME`, and the CDN provider's own DNS infrastructure (potentially returning different `A` records to different resolvers, based on their apparent geographic location, for latency-optimized routing) has full control over the actual addresses returned, without the domain operator needing to update anything themselves as the CDN's own infrastructure changes.

### 6.3 The negative-answer case, and why it's cached too

A query for a name that genuinely doesn't exist (no record of any relevant type) still produces a specific, well-formed DNS response — `NXDOMAIN` ("no such domain") — rather than the query simply failing or timing out, and this negative answer is itself cached, with its own TTL (governed by a specific field in the domain's own DNS configuration, the SOA record's negative-caching TTL). This is worth knowing because it explains a particular, easily-misread symptom: a name that was genuinely nonexistent moments ago, freshly created, can continue to fail to resolve for a period after its DNS record has actually been correctly published, purely because the negative `NXDOMAIN` answer for the old, nonexistent state was itself cached, at whichever layer(s) it was cached, and hasn't yet expired — a directly analogous situation to section 4.2's positive-record TTL expiry, just for the absence of a record rather than its presence.

### 6.4 SRV, TXT, and MX: names that resolve to more than an address

Beyond `A`/`AAAA`/`CNAME`, a handful of other record types recur often enough in practice to be worth naming, precisely because their existence explains why "DNS" is a considerably richer directory service than "hostname to address" alone would suggest. An `MX` record specifies which mail server(s) handle email for a domain, with an associated priority value determining which server a sending mail system should try first; a `TXT` record holds arbitrary text, used for a wide variety of purposes including domain-ownership verification (many services require adding a specific `TXT` record as proof of control over a domain before activating some feature) and email-authentication mechanisms like SPF, which lists which servers are authorized to send email on the domain's behalf; and an `SRV` record generalizes this further, specifying not just a target host but a specific port and priority/weight for a named service (`_sip._tcp.example.com`, for instance, letting a domain advertise where its SIP service can be reached, without that information needing to be hardcoded into every client separately). None of these record types get resolved by an ordinary `getaddrinfo()` call — an application needing one of them uses a more specific DNS query function or library — but recognizing their existence matters for understanding that DNS's role in a real infrastructure extends considerably beyond the address-resolution path this chapter has focused on, into service discovery and domain-verification territory that follows the same underlying query/cache/TTL mechanics described throughout this chapter.

## 7. DNS-over-TLS and DNS-over-HTTPS: encrypting the query itself



Everything described in sections 3 through 5 has implicitly assumed DNS queries travel as plain, unencrypted UDP or TCP — which was the universal case for decades, and remains extremely common, but is no longer the *only* case. **DNS-over-TLS (DoT)** and **DNS-over-HTTPS (DoH)** both wrap the same underlying DNS query/response structure inside an encrypted transport — TLS directly for DoT (typically on port 853, distinct from ordinary DNS's port 53), or an HTTPS request for DoH (indistinguishable, at the network level, from ordinary web traffic, since it shares HTTPS's port 443 and general transport characteristics) — specifically to prevent an on-path observer (an ISP, a public Wi-Fi network operator, anyone positioned to see ordinary plaintext DNS traffic) from seeing which names a client is resolving, a privacy property plain DNS never provided.

This has a genuinely practical consequence worth flagging for anyone doing network-level diagnosis: a client using DoH in particular can be effectively invisible to conventional DNS-traffic monitoring on a network (since its DNS queries are indistinguishable from ordinary HTTPS traffic to the resolver's own domain, at the packet-inspection level chapter 4's tools operate at), which is precisely the privacy property it's designed to provide, but which also means a firewall rule or monitoring setup built around "DNS traffic is what's on port 53" (an assumption baked into a great deal of older network-monitoring and filtering infrastructure) simply doesn't see DoH traffic as DNS at all. Some browsers and operating systems now default to DoH for at least some resolution paths, meaning this isn't a purely theoretical edge case but an increasingly common real deployment reality worth accounting for when reasoning about what a network-level DNS-monitoring or filtering setup can and can't actually observe.

### 7.1 Why this matters even on networks that don't seem to care about DNS privacy

It's worth being clear that DoT/DoH adoption isn't purely a niche privacy-enthusiast concern — a growing number of mainstream browsers and operating systems have shifted toward defaulting to DoH for at least some resolution paths, meaning an administrator managing a network's DNS behavior (for content filtering, security monitoring, or simple visibility into what's being resolved) may find that a meaningful fraction of traffic on their network no longer uses conventional, observable DNS at all, regardless of whether anyone on that network deliberately configured it that way. Where this matters operationally, the available responses are limited and worth naming plainly: block DoH's typical destinations outright (a blunt approach, with collateral effects on any other traffic sharing those same endpoints), explicitly configure managed devices to disable DoH and use a specific conventional resolver instead (requiring endpoint-level configuration control that not every network administrator has), or accept the reduced visibility as a tradeoff of not controlling the endpoints in question. None of these is DNS-mechanism-specific in the way the rest of this chapter has been — they're policy responses to a protocol-level shift — but understanding *why* the visibility gap exists (encrypted transport indistinguishable from ordinary HTTPS, as section 7 described) is what makes evaluating those responses possible in the first place, rather than mistakenly assuming a missing DNS log simply reflects unusually low query volume.

## 8. What's deliberately being deferred



- Namespace-scoped DNS configuration — how `/etc/resolv.conf` and NSS behavior differ inside a network namespace or container, where a completely independent resolver configuration is entirely possible — builds on this chapter's model but is chapter 7's subject.
- DNSSEC's actual cryptographic validation mechanics (as opposed to the `trust-ad` delegation behavior mentioned in section 3.3) are outside this chapter's scope; this chapter covers resolution mechanics, not the security properties layered on top of them.
- mDNS/`.local` resolution (used by service-discovery protocols like Bonjour/Avahi) follows an entirely different, non-hierarchical, multicast-based mechanism distinct from everything in sections 3 through 6, and isn't covered further here beyond its brief mention as one possible NSS source in section 2.
- Split-horizon DNS (an authoritative nameserver returning different answers depending on the querying client's network location, common in corporate environments distinguishing internal from external queriers) is a deployment pattern this chapter's resolution model fully supports without modification, but isn't elaborated on further here as a distinct topic.

## 9. Glossary of terms introduced in this chapter

- **NSS (Name Service Switch)** — the configurable chain of lookup sources (`files`, `dns`, and others) `getaddrinfo()` consults, in the order given by `/etc/nsswitch.conf` (section 2).
- **`myhostname` / `mdns`** — additional NSS sources handling a machine's own hostname locally, and multicast, broadcast-based `.local` name resolution respectively, both operating by entirely different mechanisms than hierarchical DNS (section 2.3).
- **`search` (resolv.conf)** — the list of domain suffixes tried, in order, when resolving a bare (non-fully-qualified) hostname (section 3.2).
- **recursive resolver** — a DNS server that performs however many additional queries are needed against authoritative infrastructure on a client's behalf, returning a single final answer (section 4.1).
- **authoritative nameserver** — the server holding the actual, canonical DNS records for a given domain, as opposed to a recursive resolver merely relaying queries toward it (section 4.1).
- **TTL (Time To Live, DNS sense)** — how long a cached DNS answer remains valid before it must be re-queried from the authoritative source (section 4.2).
- **`systemd-resolved` / `dnsmasq`** — common local caching-resolver daemons sitting between the resolver library and the actual upstream recursive resolver (section 5).
- **CNAME** — a DNS record type aliasing one name to another, rather than providing an address directly (section 6.2).
- **NXDOMAIN** — the well-formed DNS response indicating a queried name genuinely doesn't exist, itself subject to caching (section 6.3).
- **MX / TXT / SRV** — record types serving mail routing, arbitrary text/verification data, and generalized service discovery respectively, beyond simple address resolution (section 6.4).
- **DoT / DoH (DNS-over-TLS / DNS-over-HTTPS)** — mechanisms encrypting the DNS query/response exchange itself, for privacy from on-path observers (section 7).

## 10. A closing note connecting this back to chapters 1 through 5

Chapter 1 characterized DNS resolution as more involved than "ask a server, get an address," without detailing why. This chapter has, hopefully, made that concrete: an application's lookup passes through NSS before DNS is even considered; `/etc/hosts` can silently override DNS entirely; a local caching daemon typically sits between the resolver library and the actual upstream recursive resolver, itself performing a potentially multi-hop chain of queries against root, TLD, and authoritative servers; and every layer in this chain — local cache, upstream recursive resolver's cache, even the negative `NXDOMAIN` case — caches its answers according to a TTL that determines how quickly a change actually becomes visible, and to whom. The "it resolves with `dig` but not in the application" symptom chapter 1 flagged has, by this chapter's end, a precise mechanical explanation: `dig` bypasses NSS and queries DNS directly, while an application's actual resolution path runs through every layer this chapter has described, any one of which — a stale `/etc/hosts` entry, a local cache that hasn't yet expired an old answer, a `search` suffix producing an unintended match — can cause the two paths to diverge.

It's worth drawing together, as previous chapters have, the diagnostic sequence this chapter's material supports, since a resolution problem in practice benefits from checking these layers in a specific, efficient order rather than jumping to the most exotic explanation first:

1. Use `getent hosts <name>` (section 2.2), not `dig`, to see what the application's actual resolution path would produce — this immediately reveals whether `/etc/hosts` (section 2.1) or an NSS source other than DNS is intercepting the lookup before it ever reaches a DNS server.
2. If `getent` and `dig` genuinely disagree with no `/etc/hosts` entry or other NSS override in play, check the local caching layer directly (`resolvectl status` for `systemd-resolved`, or the equivalent for whatever daemon is in use, per section 5) — a stale local cache entry is a common, easily-checked cause, and flushing it (`resolvectl flush-caches` or equivalent) is a low-risk, quick test.
3. If flushing the local cache doesn't resolve the discrepancy, the staleness likely lives in the upstream recursive resolver's own cache (section 5.3) — outside this machine's direct control, and resolvable only by waiting out the relevant TTL or, if the upstream resolver is itself under administrative control, flushing it there specifically.
4. If the failure is a hard failure (`NXDOMAIN` or a timeout) rather than a stale-but-present answer, check whether the name genuinely exists yet from the authoritative side, keeping section 6.3's negative-caching behavior in mind — a freshly-created record can still resolve as `NXDOMAIN` for a period purely because the negative answer for its prior nonexistent state was itself cached and hasn't yet expired.

None of these four steps requires anything beyond what this chapter has covered, and working through them in this order — from the application's actual resolution path, through the local cache, to the upstream resolver, and finally to the authoritative side — resolves the large majority of "DNS is being weird" reports before they require treating DNS as a black box to be poked at with `dig` alone and no further structure.

Chapter 7 turns to network namespaces in full — the mechanism, previewed in chapters 1 and 3, that lets a container or virtual machine have an entirely independent copy of everything this series has covered so far, including, as this chapter's own deferred section noted, its own independent DNS configuration, resolvable only by understanding that the entire apparatus this chapter just traced can exist multiple times, in parallel, isolated instances, on what is physically a single machine.
