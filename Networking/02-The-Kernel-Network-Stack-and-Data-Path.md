# Chapter 2: The Kernel Network Stack and Data Path

## 1. What this chapter is actually for

Chapter 1 named the pieces — `net_device`, sockets, routing, Netfilter, TCP — and sketched, in a paragraph or two each, what role they play. This chapter takes the single most mechanically dense part of that picture, the journey of one packet from "electrical signal on a wire" to "bytes a userspace process can `read()`," and walks it at the level of the actual kernel machinery: interrupts, ring buffers, `sk_buff` allocation, NAPI polling, softirqs, and the protocol dispatch that finally hands a packet to IP.

This matters for a reason that isn't obvious until it's been felt directly: almost every serious "why is my network slow / dropping packets / behaving strangely under load" investigation eventually bottoms out somewhere in this chapter's territory, because this is where the kernel makes its decisions about *how much work to do, and when* — decisions that are largely invisible from `ip route` or `iptables -L`, and that don't show up as application-level errors so much as unexplained latency, jitter, or loss. A `sk_buff` allocation failing under memory pressure, a NAPI budget being exhausted before a receive queue is drained, an IRQ pinned to an already-busy CPU core — none of these produce a clean error message anywhere an application can see. They produce symptoms that look, from far enough away, exactly like "the network is being weird," and the only way to actually diagnose them is to understand the mechanism well enough to know where to look.

There's a second, quieter reason this chapter matters, which is worth stating directly rather than leaving implicit: a large fraction of the performance-tuning advice that circulates informally about Linux networking — "just increase this buffer size," "just pin IRQs to specific cores," "just disable this offload feature" — is advice that only makes sense in light of the mechanisms this chapter describes. Applying it without understanding *why* it works (or when it doesn't) tends to produce cargo-culted configuration that helps in one environment and actively hurts in another, because the right setting for any of these knobs depends on the balance between CPU capacity, packet rate, packet size distribution, and the specific workload's latency-versus-throughput priorities — none of which a generic tuning guide can know about a specific machine in advance. The goal of this chapter isn't to hand over a list of settings to change; it's to make it possible to look at a specific machine's behavior and derive which settings, if any, are worth touching.


## 2. The physical starting point: a frame arrives

Start at the earliest possible moment: a frame's electrical (or optical) signal arrives at a Network Interface Card. The NIC's job, in hardware, is to recognize the start and end of the frame, validate its checksum (the Frame Check Sequence, a CRC computed over the frame), and — critically for everything that follows — get the frame's bytes into a place the operating system can access, without requiring the CPU to babysit every single bit as it arrives. That mechanism is Direct Memory Access (DMA), and understanding it is the first prerequisite for understanding the rest of the receive path.

### 2.1 DMA rings: how the NIC and the kernel share memory without constant CPU involvement

When a NIC driver initializes, it allocates a block of memory — the **receive ring** (often called the RX ring, or RX descriptor ring) — consisting of a fixed number of descriptor slots, each one a small structure containing a pointer to a buffer in RAM and some status flags. The driver programs the NIC hardware with the physical address of this ring. From that point on, the NIC can write incoming frame data directly into the buffers those descriptors point to, using DMA, entirely independent of what the CPU is doing at that instant — no CPU cycles are spent copying bytes off the wire into memory; the hardware does it directly.

It's worth being clear about the division of labor this implies, because it's a recurring pattern throughout the rest of this chapter: the NIC hardware's job is narrowly scoped to physical signal handling and moving bytes into memory the driver already prepared; essentially every decision about *what to do* with those bytes — when to notify software, how to batch that notification, which CPU should handle it — is software policy, sitting in the driver and the generic networking code above it. This separation is precisely why the same physical NIC hardware can behave very differently depending on driver version and kernel configuration — the hardware provides raw capability (DMA, multiple queues, checksum computation, segmentation), and the policy layers described in the rest of this chapter decide how and when to use it.

```
RX Ring (simplified):

  descriptor[0] -> buffer @ 0x7f001000  [status: DD=0]  (empty, ready for hardware)
  descriptor[1] -> buffer @ 0x7f001800  [status: DD=1]  (hardware has written a frame here)
  descriptor[2] -> buffer @ 0x7f002000  [status: DD=0]  (empty, ready for hardware)
  ...
  descriptor[N] -> buffer @ 0x7f00N800  [status: DD=0]
```

The `DD` (Descriptor Done) bit — the exact name varies by NIC hardware family, but the concept is close to universal — is how the driver later discovers which descriptors have new data without needing the NIC to interrupt it for every single detail; the driver can, in principle, just scan the ring and check this bit. In practice, something still has to *tell* the driver that new frames have arrived at all, which is where interrupts come in.

### 2.2 The naive approach: an interrupt per frame, and why it doesn't scale

The conceptually simplest design has the NIC raise a hardware interrupt every time it finishes DMA'ing a frame into the ring. The CPU, upon receiving the interrupt, suspends whatever it was doing, jumps to the driver's interrupt handler, which acknowledges the interrupt, reads the new frame's descriptor, hands the frame off for further processing, and returns.

This works correctly, and for low packet rates — a home network, a lightly loaded server — it's essentially fine. It breaks down catastrophically at high packet rates, for a reason worth internalizing precisely: **hardware interrupts are expensive relative to the amount of work they trigger.** An interrupt forces a context switch-like transition (saving CPU state, jumping to a fixed handler address, eventually restoring state), and on a NIC receiving, say, a million small packets per second — entirely realistic for a busy server or anything doing routing/forwarding — a naive one-interrupt-per-frame design would mean a million interrupts per second, each one preempting whatever useful work the CPU was doing, for the benefit of processing a single, often tiny, frame. This condition has a name in the networking literature: **receive livelock** — the system spends so much of its CPU time servicing interrupts that essentially no CPU time is left to actually do useful work with the data those interrupts delivered, and throughput can paradoxically *collapse* as offered load increases, rather than gracefully degrading.

### 2.3 NAPI: interrupt mitigation via polling

Linux's answer to this, in place since the early 2000s and used by essentially every modern network driver, is **NAPI** ("New API," a name that has stuck around long after "new" stopped being accurate). The core idea is a hybrid: use an interrupt to *learn that there's work to do*, but then switch to polling — actively checking the ring for more data — for as long as data keeps arriving, rather than taking a fresh interrupt for every single frame.

Concretely, the sequence looks like this:

1. A frame (or several) arrives via DMA; the NIC raises an interrupt.
2. The driver's interrupt handler runs, but does almost nothing: it **disables further interrupts from this device** and schedules a NAPI poll (via `napi_schedule()`), then returns immediately. This handler is intentionally trivial — its entire job is to hand off to the polling mechanism as fast as possible.
3. At a moment chosen by the kernel's softirq scheduler (discussed in section 3), the driver's registered **poll function** runs. This function repeatedly checks the RX ring for completed descriptors, and for each one, pulls the frame out, wraps it in a `sk_buff` (section 4), and passes it further up the stack — up to a **budget**, a maximum number of frames (or a time limit) it's allowed to process in one polling pass, so that this loop can't monopolize the CPU indefinitely even under sustained high load.
4. If the ring is drained (no more frames waiting) before the budget is exhausted, the poll function re-enables the device's interrupt and exits polling mode — the system reverts to interrupt-driven behavior, appropriate for low, bursty traffic.
5. If the budget runs out before the ring is drained, the poll function reschedules itself to run again shortly, *without* re-enabling the hardware interrupt yet — the system stays in polling mode, appropriate for sustained high traffic, where taking on the overhead of individual interrupts would be counterproductive.

This design — interrupts for the low-traffic case, polling for the high-traffic case, with an automatic transition between the two based on observed load — is precisely what avoids the receive-livelock collapse described above: as offered load increases, the *fraction* of CPU time spent on interrupt overhead per frame processed goes *down*, not up, because polling amortizes the cost of "checking for new data" across however many frames happen to be waiting in a given pass.

### 2.4 Observing NAPI and interrupt behavior directly

This isn't abstract kernel internals trivia — it's directly observable, and worth checking on a real system:

```
$ cat /proc/interrupts | grep eth0
 124:  8231211   8341022   8129887   8098123   PCI-MSI 1048577-edge   eth0-rx-0
 125:  7982341   8012233   8241109   8177654   PCI-MSI 1048578-edge   eth0-rx-1
```

Each row is one interrupt line, and the four numeric columns are the count of interrupts serviced on CPU 0 through CPU 3 respectively (a machine with more cores would show more columns). A modern multi-queue NIC typically exposes several RX queues (`eth0-rx-0`, `eth0-rx-1`, ...), each with its own interrupt line, specifically so that received traffic can be spread across multiple CPU cores in parallel rather than funneling all of it through one core's NAPI poll loop — this spreading mechanism, called Receive Side Scaling (RSS), decides which queue a given incoming frame lands in based on a hash of its headers (source/destination address and port, typically), ensuring all frames belonging to one flow consistently land on the same queue and therefore the same CPU, which matters for the ordering guarantees discussed later in this chapter.

The interrupt *count* climbing steadily under load is expected; what's worth watching for is a count that climbs at a rate roughly proportional to raw packet rate rather than being damped by NAPI's polling behavior — a sign, on investigation, that something is preventing the NAPI poll loop from doing its job (a misbehaving driver, or the budget/weight tuning being poorly matched to the actual traffic pattern).

Interrupt *coalescing* settings, tunable via `ethtool -c eth0`, sit alongside NAPI as a second, complementary lever on the same underlying tradeoff: they let the NIC hardware itself delay raising an interrupt until either a certain number of frames have arrived or a certain time has passed, batching multiple frames into a single interrupt even before NAPI polling gets involved. The two mechanisms (hardware coalescing and NAPI's software-level batching) work at different points in the pipeline but toward the same goal — reduce the number of expensive interrupt-driven transitions per unit of useful work.

### 2.5 A worked numeric example: why the naive design actually collapses

It's worth making the receive-livelock argument from section 2.2 concrete with rough numbers, because "interrupts are expensive" is easy to accept abstractly and easy to underestimate in practice. A hardware interrupt, on typical modern server hardware, costs somewhere in the range of a few hundred nanoseconds to low microseconds of pure overhead — saving register state, executing the handler's prologue, eventually restoring state — before any actual useful work happens. That sounds negligible until it's multiplied by rate: at one million packets per second (a rate a single fast NIC can sustain with small packets, and one that isn't exotic for a busy load balancer or router), one interrupt per packet at even a conservative one microsecond of pure overhead consumes the *entire* CPU core's time budget on overhead alone, leaving zero time for the actual packet processing the interrupt was raised to enable. This is the precise mechanism behind receive livelock: as offered packet rate increases past some threshold, the fraction of CPU time spent on per-packet interrupt overhead approaches 100%, and throughput — the rate of packets actually processed and delivered — can fall even as the rate of packets arriving keeps climbing, because the system is spending all its time context-switching into and out of interrupt handlers rather than draining the ring those handlers were meant to service. NAPI's batching directly attacks this multiplication: processing, say, sixty-four frames per interrupt instead of one cuts the per-packet overhead contribution by roughly the same factor, transforming a linear, unbounded overhead-per-packet-rate relationship into something that stays bounded even as load grows, right up to the point where the CPU's raw processing capacity — not interrupt overhead — becomes the limiting factor.

## 3. Softirqs: where the actual packet processing happens

The NAPI poll function described above doesn't run in the original hardware interrupt context — running substantial packet-processing logic (which can take a genuinely variable amount of time) directly inside a hardware interrupt handler would itself reintroduce a version of the same latency problem NAPI is trying to solve, because hardware interrupts are typically handled with other interrupts on the same line masked, and a slow interrupt handler blocks the CPU from servicing anything else time-sensitive.

Instead, Linux runs the NAPI poll function inside a **softirq** — a "software interrupt," a kernel mechanism for deferring work out of hardware interrupt context into a context that still runs with high priority (higher than any userspace process, and higher than normal kernel threads) but that can be preempted by actual hardware interrupts if a genuinely urgent one arrives. The specific softirq responsible for network receive processing is `NET_RX_SOFTIRQ`; there's a corresponding `NET_TX_SOFTIRQ` for parts of the transmit path.

### 3.1 Where softirqs actually run, and why this matters for CPU accounting

Softirqs run either immediately after a hardware interrupt handler returns (if the softirq was raised during that handler, as `napi_schedule()` does), or inside a dedicated per-CPU kernel thread called `ksoftirqd` when there's more softirq work pending than can reasonably be drained inline — a safety valve that prevents softirq processing from starving normal process scheduling entirely under extreme, sustained load.

This has a direct, practical consequence for reading CPU utilization correctly on a busy network-facing machine: time spent processing packets in softirq context shows up in `top` or `mpstat` output under a specific category, `%si` (softirq), distinct from `%us` (userspace) and `%sy` (regular kernel/syscall time):

```
$ mpstat -P ALL 1 1
Linux 6.8.0 ...
12:15:01     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %idle
12:15:02     all    12.40    0.00    3.10    0.05    0.02   18.90    0.00   65.53
12:15:02       0     8.10    0.00    2.90    0.00    0.00   41.20    0.00   47.80
12:15:02       1    14.30    0.00    3.40    0.10    0.05    2.10    0.00   80.05
```

CPU 0 in this output is spending 41% of its time in softirq context, versus 2% on CPU 1 — a strong, direct signal that RSS (section 2.4) has concentrated the bulk of incoming network processing onto one core, and that this specific core is the one to investigate first if network throughput seems capped below what the hardware should support, because it may simply be running out of CPU time to keep draining its NAPI poll loop, independent of anything happening elsewhere in the system. This is a genuinely common real-world diagnostic pattern — "high `%soft` concentrated on one or two cores while others sit idle" — and it's one that's essentially invisible unless the reader already knows to look at per-CPU softirq time specifically, rather than only at aggregate CPU usage.

### 3.2 `softnet_stat`: the kernel's own scoreboard for this exact process

Because this section of the stack is a well-known source of subtle problems, the kernel exposes purpose-built statistics for it:

```
$ cat /proc/net/softnet_stat
0002dbf1 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
0001a9c4 00000012 00000000 00000000 00000000 00000000 00000000 00000000 00000000
```

Each line corresponds to one CPU. The columns, in order, are (among others depending on kernel version): the total number of packets processed, the number of times this CPU's NAPI budget was exhausted before the queue was drained (`dropped`... more precisely this second field historically tracked packets dropped because the per-CPU backlog queue was full, and a separate mechanism tracks budget exhaustion, but both point at the same underlying phenomenon — this CPU couldn't keep up), and further fields covering things like time squeezed due to budget limits. A non-zero, growing value in the "budget exhausted" column on a specific CPU is close to a direct confirmation of the exact scenario described in section 3.1: that CPU's NAPI poll loop is being cut off before it finishes draining the ring, meaning frames are queuing up (and, if this persists long enough that the ring itself fills, eventually being dropped at the hardware/driver level before software even gets a chance to inspect them individually).

### 3.3 IRQ affinity: choosing which core handles which queue

Section 3.1 showed how uneven `%soft` distribution across cores can point at a specific bottleneck. It's worth closing the loop on this by naming the actual lever that controls it: **IRQ affinity** — which CPU core (or set of cores) a given interrupt line is allowed to be serviced on, configurable through `/proc/irq/<n>/smp_affinity` (a hexadecimal CPU bitmask) or more conveniently via tools like `irqbalance`, a daemon that automatically redistributes interrupt affinity based on observed load, or a driver-provided helper script (many multi-queue NIC drivers ship a `set_irq_affinity` script for exactly this purpose).

The default behavior on most distributions is to let `irqbalance` handle this automatically, and for most workloads that's the right choice — it reacts to changing load patterns without manual intervention. On latency-sensitive, high-throughput systems, though, manual pinning is common: explicitly assigning each RX queue's interrupt to a specific core, disabling `irqbalance` for that interface, and often further pinning the application process consuming that traffic to the *same* core (or an adjacent one sharing an L2/L3 cache) via `taskset` or a container's CPU affinity settings — directly exploiting the cache-locality reasoning behind RFS (section 6), but applied manually and deterministically rather than left to the kernel's automatic flow tracking. This kind of manual tuning trades operational simplicity for predictability, and it's most justified precisely on the machines where the `%soft` imbalance described in section 3.1 has already been observed and diagnosed as a genuine bottleneck — not applied speculatively to a machine that hasn't shown that symptom, since pinning interrupts away from where load actually needs them can just as easily make things worse.

## 4. `sk_buff`: the structure that carries a packet through the kernel



Once a frame has been pulled off the ring inside a NAPI poll pass, it needs a kernel-internal representation that can be passed between all the different pieces of code described in chapter 1 — the link layer, IP, Netfilter, TCP or UDP, and eventually the socket layer — without each of those layers needing to know the internal format the previous layer used. That representation is the **socket buffer**, `struct sk_buff`, defined in `net/core/skbuff.c` and its associated header, and it is, without much exaggeration, the single most important data structure in the entire Linux networking stack.

### 4.1 Why a dedicated structure, rather than a plain buffer of bytes

A naive design might represent a packet as just a pointer to a contiguous block of bytes and a length. This fails almost immediately in practice, for a reason that becomes obvious once the packet's actual journey is considered: as a packet moves down through the layers (say, on transmit — application data being wrapped by TCP, then IP, then Ethernet), headers get **prepended** at each layer, and as it moves up through the layers on receive, headers get **stripped**. A plain byte-buffer-and-length representation would require either copying the buffer at every layer boundary (expensive, and exactly the kind of per-packet overhead the DMA and NAPI machinery worked hard to avoid elsewhere) or complex, fragile pointer arithmetic scattered across every protocol handler.

There's a second requirement a real design has to satisfy that a naive one easily misses: the same packet, or fragments of it, sometimes need to be referenced from multiple places simultaneously without duplication — a packet queued for local delivery to a socket while also, in a bridging or forwarding scenario, needing to be duplicated toward another interface; or a large piece of data spanning multiple non-contiguous memory pages (common with certain zero-copy send paths) that still needs to be treated as one logical packet by everything above the memory-management layer. `sk_buff` supports reference counting and, in its more advanced forms, fragment lists (`skb_shared_info`, holding pointers to additional pages of data beyond the buffer's own linear region) specifically to handle these cases without falling back to a copy — details this introductory treatment won't dwell on further, but worth knowing exist, since they're part of why the structure has the reputation of being one of the more intricate pieces of the networking kernel to work with directly.

`sk_buff` solves this with a design built around **headroom**: when a `sk_buff` is allocated, it reserves extra space *before* the actual packet data, so that a lower layer (say, Ethernet, wrapping an IP packet for transmission) can write its header directly into that reserved space by simply moving a pointer backward, rather than allocating a new, larger buffer and copying everything into it. The structure tracks several key pointers into its underlying data buffer:

```
+----------+----------------+------------------------+----------+
|  head    |    headroom    |     actual packet data   |  tailroom |
+----------+----------------+------------------------+----------+
           ^                ^                        ^          ^
         head              data                     tail       end
```

- **`head`** and **`end`** mark the boundaries of the entire allocated buffer.
- **`data`** points to the start of the currently-valid packet content — this is what moves as headers are added or removed.
- **`tail`** points to the end of the currently-valid content, used similarly when appending data.

Four core operations manipulate these pointers, and their names are worth knowing because kernel networking code (and driver code) uses them constantly:

- **`skb_reserve()`** — used right after allocation, to carve out headroom for headers that will be added later, before any data is written.
- **`skb_push()`** — moves `data` backward and returns the new `data` pointer, used when *prepending* a header (an IP layer adding its header in front of a TCP segment, for instance).
- **`skb_pull()`** — moves `data` forward, used when *stripping* a header that's already been processed (IP processing consuming the IP header, exposing the TCP segment underneath for the transport layer to look at next).
- **`skb_put()`** — moves `tail` forward, used when *appending* data at the end of the buffer.

The elegance here — and it's worth pausing on why this matters rather than treating it as a mere implementation footnote — is that adding or removing a header at any layer becomes an O(1) pointer adjustment rather than a copy, for the overwhelming majority of cases where enough headroom was reserved up front. A `sk_buff` allocated for transmission, in particular, is typically allocated with headroom sized to accommodate the worst case of every header that might need to be added — link layer, IP, TCP/UDP — precisely so that the entire downward journey through the stack touches the buffer's pointers, not its bytes.

### 4.2 A worked example: header stripping on receive

Concretely, tracing a received TCP/IP-over-Ethernet packet through this structure:

1. The NIC driver's NAPI poll function allocates a `sk_buff` and copies (or, on more sophisticated NICs, DMAs directly into) the raw Ethernet frame bytes into it. At this point, `data` points at the start of the Ethernet header.
2. The link-layer receive code (`net/ethernet/eth.c` roughly) inspects the Ethernet header — reading the EtherType field to learn this frame carries an IPv4 payload — and calls `skb_pull()` to advance `data` past the 14-byte Ethernet header. `data` now points at the start of the IP header.
3. IPv4 receive processing (`ip_rcv()` in `net/ipv4/ip_input.c`) validates the IP header (checksum, TTL, and so on), determines the packet is destined for this host (rather than needing forwarding — this is where the routing lookup from chapter 1's section 6 actually gets invoked), and calls `skb_pull()` again to advance `data` past the IP header (typically 20 bytes, more if IP options are present). `data` now points at the start of the TCP segment.
4. TCP receive processing looks up the socket this segment belongs to (by matching the four-tuple against its hash table of active connections), validates the TCP header and sequence numbers, calls `skb_pull()` once more to advance past the TCP header, and what remains — pointed to by `data`, with a length given by `tail - data` — is the actual application payload, which gets queued onto the destination socket's receive buffer for a `read()` call to eventually retrieve.

At no point in this entire sequence was the packet's payload bytes copied to accommodate header removal — only the `data` pointer moved, three times, once per layer. This is the concrete mechanism behind a claim from chapter 1: that `sk_buff` is genuinely protocol-agnostic infrastructure, with Ethernet, IP, and TCP code each doing their own layer's work on the *same* underlying buffer, coordinating purely through these pointer conventions.

### 4.3 GRO: merging packets before the stack even sees them as separate

One further optimization, sitting right at the NAPI/`sk_buff` boundary, is worth knowing about because it can be genuinely confusing when first encountered in a packet capture: **Generic Receive Offload (GRO)**. Modern NICs (and the kernel's software GRO layer, for hardware that doesn't do this itself) can recognize that several consecutive incoming frames are actually parts of the same large TCP stream — segments that arrived close together in time, from the same connection — and merge them into a single, larger `sk_buff` before handing it up to IP and TCP processing at all, rather than making the upper layers process each smaller segment independently.

This is a pure performance optimization: processing one `sk_buff` carrying 64KB of reassembled data costs meaningfully less in per-packet overhead (checksum validation, routing lookup, socket lookup — all of section 4.2's work) than processing, say, forty-five separate ~1460-byte `sk_buff`s covering the same data. The reason it's worth flagging explicitly here is a practical one: someone running `tcpdump` and expecting to see individual ~1500-byte frames on the wire, but instead seeing occasional, much larger "frames" reported for a local capture, isn't looking at malformed traffic or a capture bug — they're most likely looking at the effect of GRO (or, on the transmit side, the mirror-image optimization, Generic Segmentation Offload, discussed in section 5) reassembling or pre-segmenting traffic below the point where `tcpdump`'s capture point sits, versus what actually appeared on the physical wire.

### 4.4 What happens when `sk_buff` allocation fails

Section 4.1 through 4.3 described the happy path. It's worth being explicit about the unhappy one, because it's a real, recurring cause of packet loss that's easy to misattribute. `sk_buff` allocation, like any other kernel memory allocation, can fail — most commonly under severe memory pressure, though certain allocation contexts (specifically, allocations happening inside interrupt or softirq context, which cannot sleep waiting for memory to be freed) are more failure-prone than ordinary process-context allocations, because they're restricted to atomic allocation flags that return immediately with failure rather than waiting.

When the NAPI poll function's attempt to allocate a fresh `sk_buff` for an incoming frame fails, the frame is simply dropped — there is no buffer to receive it into, and no meaningful way to apply backpressure to a NIC that has already DMA'd the frame into a ring descriptor moments earlier. This shows up in exactly the kind of statistics introduced earlier in this chapter: the `drop` column in `/proc/net/dev` (section 3.2 of chapter 1) and specific counters in `ethtool -S`, often labeled something like `rx_no_buffer_count` or similar depending on the driver. A machine under genuine memory pressure — perhaps running many memory-hungry containers with insufficient headroom, or suffering a memory leak in an unrelated process — can develop network packet loss that has nothing to do with the network itself, the NIC, the cable, or anything upstream, and everything to do with the kernel being unable to allocate the buffers needed to receive traffic that has already physically arrived.

A related, container-specific variant of this same failure mode is worth naming explicitly, since it's increasingly common on modern infrastructure: a cgroup with a memory limit configured can hit that limit's allocation failures for kernel-side networking buffers belonging to processes inside it, well before the *host's* overall memory is under any pressure at all. From inside the container, this looks exactly like unexplained packet loss or connection stalls; from the host's perspective, `free` shows plenty of memory available, because the constraint is scoped to the cgroup, not the machine. Diagnosing this specific variant requires checking the cgroup's own memory statistics (`memory.stat`, or the equivalent `cgroup.stat`/pressure-stall-information files under `/sys/fs/cgroup/`) rather than host-wide memory reporting — another instance of the general principle that the *symptom* (network packets disappearing) and the *cause* (a memory allocation constraint, at whatever scope it happens to be enforced) can be arbitrarily far apart in the system, and checking the wrong scope entirely misses the real explanation.

This is a good example of why chapter 1's closing advice — check observable state rather than assume — matters in practice: "the network is dropping packets" and "this machine (or this cgroup) is out of memory" can be, mechanically, the exact same underlying event, distinguishable only by checking memory statistics at the right scope alongside the network-specific counters.

### 4.5 GSO: postponing segmentation as long as possible on transmit

Section 4.3 described GRO — merging small incoming packets into a larger `sk_buff` before upper-layer processing. The transmit-side mirror of this idea is **Generic Segmentation Offload (GSO)**, and it's worth understanding as a distinct optimization even though it addresses the same underlying cost (per-packet processing overhead) from the opposite direction.

When TCP has a large amount of data to send — more than fits in a single maximum-segment-size-limited packet — the naive approach would have TCP itself construct many separate, wire-sized `sk_buff`s, each going through routing lookup, Netfilter hook traversal, and driver hand-off independently. GSO lets TCP instead construct *one* oversized `sk_buff` — larger than what could ever actually be transmitted on the wire — and defer the actual splitting into wire-sized segments to as late as possible in the transmit path: ideally, to the NIC hardware itself, if it supports **TSO (TCP Segmentation Offload)**, meaning the hardware receives one large buffer and a description of how to slice it into properly-headered segments, and does that slicing in hardware as it transmits, at no CPU cost at all. Where hardware TSO isn't available, the kernel's software GSO layer performs the same splitting just before handing frames to the driver — later than the naive design, but still only once, right before transmission, rather than duplicating routing and Netfilter processing per-segment throughout the whole downward journey through the stack.

The practical upshot mirrors GRO's: a `tcpdump` capture taken at certain points can show `sk_buff`s (and therefore apparent "frames," if the capture point sits above where segmentation happens) considerably larger than any real Ethernet frame's maximum size would allow, and this is expected behavior reflecting GSO/TSO, not a sign of a broken capture or an oversized-packet bug.

## 5. The transmit path: much of the same machinery, run in reverse



Transmission is not simply "the receive path backward," but it shares enough structure that it's efficient to describe it in terms of what's different rather than starting from scratch.

### 5.1 From `write()` to the transmit ring

When a process calls `write()` (or `send()`) on a TCP socket, the kernel copies the given bytes into the socket's send buffer and, assuming the TCP state machine and congestion/flow control (chapter 5's subject) permit it, constructs one or more `sk_buff`s carrying TCP segments, which then travel *down* through the same layer stack described in section 4.2, but in reverse: TCP's `skb_push()` prepends the TCP header, IP's `skb_push()` prepends the IP header (after a routing lookup determines the outbound interface and next hop, per chapter 1 section 6), and the link layer's equivalent prepends the Ethernet header. The resulting `sk_buff`, now containing a complete frame, is handed to the outbound `net_device`'s registered transmit function — the `ndo_start_xmit` entry point mentioned in chapter 1, section 5.1 — which is where driver-specific code takes over, placing the frame into the NIC's **transmit ring** (the DMA-based counterpart to the receive ring from section 2.1) for the hardware to actually send.

It's worth being precise about one detail that's easy to gloss over: the copy from userspace into kernel socket buffers that `write()` performs is a genuine, unavoidable memory copy (barring more exotic zero-copy mechanisms like `MSG_ZEROCOPY` or `sendfile()`, which exist specifically to avoid it in narrower circumstances) — this is different in kind from the header push/pull operations described in section 4.1, which manipulate pointers into an already-allocated buffer rather than copying payload bytes. The one unavoidable copy happens at the userspace/kernel boundary; everything from that point onward, as the buffer travels down through TCP, IP, and the link layer, avoids further copying precisely because of the `sk_buff` design covered earlier in this chapter. This is worth knowing because "how many times does this data get copied" is a legitimate, answerable question for any given code path, and the answer for the ordinary transmit path is, ideally, exactly once.

### 5.2 Queueing disciplines: a checkpoint before the driver

Between the IP layer handing a fully-formed packet toward the device and that packet actually reaching the driver's transmit function, there's an additional checkpoint worth knowing exists even though it's the full subject of chapter 9: the **queueing discipline**, or `qdisc`, attached to the outbound `net_device`. Every interface has one, even if an administrator has never configured anything explicitly — the default is `pfifo_fast`, a simple, mostly-FIFO discipline with light priority handling. This is the mechanism `tc` configures, and it's the reason that, for instance, artificially limiting an interface's outbound bandwidth (`tc qdisc add ... tbf ...`) or reordering which traffic gets sent first under contention is possible at all — the qdisc sits exactly at this point in the transmit path, between "IP has decided this packet is ready to go" and "the driver is asked to actually transmit it," queueing and reordering packets as configured before they ever reach the hardware.

The existence of this checkpoint also explains a specific, sometimes puzzling observation: a machine can show essentially idle CPU and an idle-looking NIC, and yet outbound traffic is still being deliberately delayed or capped — because the qdisc is holding packets back by design, not because anything is overloaded. `tc -s qdisc show dev eth0` surfaces this directly, reporting sent/dropped packet counts and, for shaping disciplines specifically, the current queue depth — a genuinely different signal from the driver- and NIC-level statistics discussed elsewhere in this chapter, because it reflects administrative policy rather than hardware or software capacity limits.

### 5.3 Transmit completion and freeing the `sk_buff`

Unlike receive, where a `sk_buff` is allocated fresh for each incoming frame and eventually consumed by a socket (or dropped), a transmitted `sk_buff` needs to be freed once the hardware confirms it has actually finished sending the frame — the NIC can't be allowed to keep using memory the kernel might reuse for something else while a DMA transfer from that memory is still in progress. This confirmation arrives via a transmit-completion interrupt (itself subject to the same NAPI-style batching principles as receive, on modern drivers, precisely to avoid the same interrupt-storm problem described in section 2.2 applying equally to the transmit side), at which point the driver walks the transmit ring, identifies which descriptors' DMA transfers have completed, and releases the corresponding `sk_buff`s back to the kernel's memory allocator.

A transmit ring that fills up — because the hardware or link is slower than the rate at which the kernel is handing it packets — causes the driver to signal back-pressure to the rest of the stack (`netif_stop_queue()`), which propagates as the qdisc from section 5.2 holding packets rather than handing them to a driver that has no room for them, which in turn, for TCP traffic specifically, eventually feeds back into TCP's own flow-control and congestion-control decisions (chapter 5) — a chain of backpressure running from the physical hardware ring all the way up to the transport-layer state machine, entirely through mechanisms that don't require any single component to know about the others directly.

## 6. Multi-core scaling: RSS, RPS, and RFS

Section 2.4 introduced Receive Side Scaling (RSS) — hardware-based spreading of incoming traffic across multiple RX queues (and therefore multiple CPU cores) based on a hash of packet headers. It's worth rounding this out with two related, software-level mechanisms that address gaps RSS alone doesn't cover, because all three are frequently discussed together and are easy to conflate.

- **RSS (Receive Side Scaling)** — implemented in NIC hardware. Requires a multi-queue-capable NIC. Distributes *interrupts* (and therefore initial NAPI processing) across cores based on a hash, typically of the source/destination IP and port.
- **RPS (Receive Packet Steering)** — a software equivalent to RSS, useful specifically for NICs that lack multi-queue hardware support (older or simpler hardware, or certain virtualized NIC models), where the kernel itself computes a similar hash after a packet has already been received on a single queue/core, and redirects it to a different core's backlog queue for the remainder of processing.
- **RFS (Receive Flow Steering)** — a refinement on top of RPS: rather than steering purely by a stateless hash, RFS tracks which CPU core a given flow's *application* is actually running on (by watching where the relevant socket's `recvmsg()`/`read()` calls occur) and steers that flow's packets toward that same core specifically, on the reasoning that processing a packet on the same core that will eventually consume it in userspace improves CPU cache locality and reduces cross-core synchronization overhead — a real effect, especially under high packet rates, though one that trades off against the more even load distribution a pure hash-based scheme provides.

All three exist to solve the same underlying problem introduced in section 3.1: a single CPU core's NAPI poll loop and softirq processing has a finite capacity, and on modern multi-core hardware, that capacity is far below what the aggregate system could sustain if load were spread across all available cores. Whether that spreading happens in hardware (RSS) or software (RPS/RFS) is a detail; the goal in every case is keeping any one core's `%soft` time (section 3.1) from becoming the system's bottleneck while other cores sit idle.

### 6.1 Why flow-to-core consistency matters: ordering guarantees

It's worth being explicit about *why* RSS, RPS, and RFS all take care to keep a given flow's packets on a single, consistent core rather than simply load-balancing each packet independently to whichever core happens to be least busy at that instant. TCP's correctness model depends on packets within one connection being processed by the receiving side in a sequence-consistent way — out-of-order delivery is something TCP is *designed* to tolerate at the network level (packets can genuinely arrive out of order after traversing multiple internet routers with different queuing), but it comes at a real cost: out-of-order segments have to be held in a reorder buffer until the missing earlier segment arrives, and excessive reordering can trigger TCP's loss-detection heuristics into assuming a packet was lost when it was merely delayed, causing unnecessary retransmission.

If a single flow's packets were distributed across multiple CPU cores at random, each core's independent NAPI poll loop and softirq processing could easily finish processing a segment from a later point in the stream before another core finishes an earlier one — introducing exactly this kind of artificial reordering purely as an artifact of parallel processing, on a network path that might otherwise have delivered every packet in perfect order. Keeping one flow pinned to one core (the entire point of the hashing in RSS, and the explicit goal of RFS) sidesteps this entirely: a single core processes a flow's packets in the order its own NAPI loop drains them from the ring, which — for a single interface receiving from a single physical link — matches the order they actually arrived on the wire. This is a good example of a piece of "obvious" multi-core scaling advice (spread work evenly across cores) being deliberately *not* followed in its most naive form, because the naive form would silently reintroduce a correctness-adjacent performance problem elsewhere in the stack.

### 6.2 Checksum offload: another cost pushed onto hardware

One more optimization worth mentioning in the same spirit as GRO/GSO, because it follows an identical pattern of "push a per-packet cost to hardware or defer it as late as possible," is checksum handling. TCP, UDP, and IP all carry checksums for error detection, and computing them requires reading every byte of a packet's payload — a real, non-trivial cost at high data rates, potentially large enough to bind on data cache bandwidth rather than raw computation on some workloads.

Modern NICs can compute (on transmit) and verify (on receive) these checksums directly in hardware, and Linux's driver model exposes this as an `sk_buff` flag: rather than the kernel computing a TCP checksum in software before handing a packet to the driver, it can mark the `sk_buff` as needing hardware checksum offload, leaving a placeholder value, and let the NIC fill in (or validate) the real checksum as the frame passes through hardware on its way out (or in). This can be inspected via `ethtool -k eth0`, which lists offload features and whether each is currently enabled (`tx-checksumming`, `rx-checksumming`, alongside entries for `tcp-segmentation-offload` and `generic-receive-offload`, tying this directly back to sections 4.3 and 4.5). Disabling these offloads — sometimes done deliberately during low-level debugging, because a software-computed checksum is easier to reason about and verify by hand than trusting hardware — measurably increases CPU cost per packet, which is itself a useful, concrete illustration of how much of this entire chapter's material exists specifically to keep that cost as low as possible.

## 7. What's deliberately being deferred



- The full routing lookup process — how the FIB trie is actually organized and searched — is chapter 3, though this chapter has already shown *where* in the packet's journey that lookup happens (inside `ip_rcv()`/`ip_forward()` processing, described in section 4.2).
- The complete Netfilter hook mechanism, and exactly where within the sequence described in section 4.2 each of the five hooks from chapter 1 actually fires, is chapter 4's job to make precise.
- TCP's own internal state handling — once a `sk_buff` reaches the transport layer via the process in section 4.2 — including buffering, retransmission, and congestion control, is chapter 5.
- Traffic control and queueing disciplines, introduced only briefly in section 5.2, get full treatment in chapter 9, including how multiple qdiscs can be composed into a hierarchy.
- eBPF/XDP, previewed in chapter 1, attaches even earlier than the NAPI poll function described in section 2.3 — directly in the driver, before a full `sk_buff` is even allocated — precisely so that a decision to drop unwanted traffic can avoid paying for section 4's `sk_buff` allocation and section 4.2's layer-by-layer processing entirely. That mechanism's internals remain outside this series' scope, as noted in chapter 1.

## 8. Glossary of terms introduced in this chapter

A short reference, in the same spirit as chapter 1's, since several of these terms — particularly `sk_buff`, NAPI, and softirq — recur constantly starting in chapter 3.

- **DMA (Direct Memory Access)** — hardware writing directly to/from system memory without CPU involvement in the byte-by-byte transfer (section 2.1).
- **RX/TX ring** — the descriptor-based buffer structures a NIC and driver share via DMA for receiving and transmitting frames (sections 2.1, 5.1).
- **NAPI** — the interrupt-mitigation mechanism that switches between interrupt-driven and polling-based packet reception depending on load (section 2.3).
- **softirq** — a deferred, high-priority-but-preemptible execution context used for the bulk of packet-processing work outside of hardware interrupt handlers (section 3).
- **`ksoftirqd`** — the per-CPU kernel thread that handles softirq work when it can't be drained inline (section 3.1).
- **IRQ affinity** — the configuration determining which CPU core(s) a given interrupt line is serviced on (section 3.3).
- **`sk_buff`** — the kernel's core packet-buffer structure, with `head`/`data`/`tail`/`end` pointers enabling O(1) header push/pull operations (section 4).
- **GRO / GSO / TSO** — Generic Receive/Segmentation Offload and TCP Segmentation Offload: mechanisms that merge multiple small packets into one large `sk_buff` on receive (GRO), or defer splitting one large `sk_buff` into wire-sized segments until as late as possible on transmit, ideally in hardware (GSO/TSO) — both reducing per-packet processing overhead (sections 4.3, 4.5).
- **qdisc (queueing discipline)** — the configurable queueing/scheduling layer a packet passes through immediately before reaching a driver's transmit function (section 5.2).
- **RSS / RPS / RFS** — hardware and software mechanisms for spreading packet processing across multiple CPU cores while preserving per-flow ordering (section 6).

## 9. A closing note connecting this back to chapter 1

Chapter 1 described `net_device`, sockets, routing, and Netfilter as if they were simply available, waiting to do their jobs when a packet arrives. This chapter has, hopefully, replaced that slightly abstract picture with a more concrete one: a NIC receives a frame via DMA into a ring buffer; an interrupt (mitigated by NAPI) triggers a poll function running in softirq context; that poll function allocates a `sk_buff` and hands it through Ethernet, IP, and transport-layer processing, each layer adjusting the buffer's `data` pointer rather than copying bytes; and the whole apparatus is replicated, via RSS/RPS/RFS, across as many CPU cores as the hardware and configuration allow.

It's worth drawing together, in one place, the diagnostic habit this chapter has been building piece by piece, because in practice it gets applied as a single sequence rather than as isolated facts about individual subsystems. Faced with a machine exhibiting unexplained network slowness, loss, or jitter under load, the sequence this chapter equips is roughly:

1. Check `/proc/net/dev` (chapter 1, section 3.2) for rising drop or error counters on the relevant interface — this immediately distinguishes "packets are being lost at or below the driver level" from "packets are arriving fine but something further up is the problem."
2. If drops are present, check `/proc/net/softnet_stat` (section 3.2 of this chapter) for budget-exhaustion counters, and `mpstat -P ALL` (section 3.1) for `%soft` concentrated on specific cores — this distinguishes "this CPU can't keep up with its NAPI workload" from other causes of drops.
3. Check `/proc/interrupts` (section 2.4) and current IRQ affinity settings (section 3.3) to see whether interrupt load is already spread sensibly across cores, or concentrated somewhere it shouldn't be.
4. Check general memory pressure (`free`, `/proc/meminfo`, or relevant cgroup statistics) to rule out the `sk_buff` allocation failure scenario from section 4.4, which produces symptoms indistinguishable from a "real" network problem without this specific check.
5. Check `ethtool -k` (section 6.2) and `ethtool -S` for the interface, to confirm offloads are configured as expected and to look for hardware-reported error counters that might explain loss happening even earlier than any of the above — in the NIC itself, before DMA ever hands a frame to the kernel.

None of these five steps requires anything beyond what this chapter has already covered, and in practice, working through them in this order — from "did the frame even get delivered by the driver" through to "is there a hardware-level explanation" — resolves a large fraction of network performance mysteries before they ever require the deeper protocol-level knowledge of chapters 3 through 9. Every subsequent chapter's subject — routing, Netfilter, TCP, DNS, namespaces, tunnels, traffic control, hardening, and troubleshooting — is, in a real sense, additional detail layered onto some specific point within the journey this chapter just traced end to end, and chapter 11's full troubleshooting methodology assumes this five-step sequence as its starting point rather than repeating it from scratch.

Chapter 3 picks up precisely at the point where `ip_rcv()` was mentioned in passing in section 4.2, and asks the question this chapter deliberately left open: given a packet whose IP header has just been parsed, how, exactly, does the kernel decide where it goes next?
