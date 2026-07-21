# 2. Physical Storage Devices

Everything above this layer — filesystems, LVM, RAID, mount points — is built on top of a physical device that has to actually store bits somewhere. This chapter looks at the dominant device types you'll encounter as a Linux administrator: how each one physically works, why that mechanism produces the performance and failure characteristics it does, and how to reason about choosing between them.

---

## 2.1 Why the Physical Layer Still Matters

It's tempting to treat the physical device as a black box — "it's just a block device, the kernel handles the rest." For day-to-day file operations that's true. But the moment you're doing capacity planning, diagnosing a performance problem, or deciding on a RAID level, the physical characteristics of the device you're sitting on stop being an abstraction and start being the actual constraint.

A single fact illustrates this well: a 7200 RPM HDD can sustain roughly 100–200 random IOPS. A commodity NVMe SSD can sustain hundreds of thousands. That's not a 2x or 10x difference — it can be a 1000x difference for random-access workloads like databases. No amount of filesystem tuning, kernel scheduling, or caching cleverness closes a gap that large. You have to understand the physical device to know when you're fighting a losing battle against its fundamental limits.

> **Note:** Sequential throughput (MB/s) and random IOPS are different measurements and devices can be strong in one and weak in the other. A spinning disk can post very respectable sequential throughput numbers (150–250 MB/s) while being catastrophically bad at random small-file access. Always ask "sequential or random?" before comparing two numbers.

---

## 2.2 Hard Disk Drives (HDD)

### 2.2.1 How an HDD Physically Works

An HDD stores data magnetically on one or more spinning platters coated with a ferromagnetic material. A read/write head, mounted on an actuator arm, moves radially across the platter surface (much like a record player's needle, but never touching the surface — it flies on a microscopic cushion of air) to reach the correct track, while the platter's rotation brings the correct sector under the head.

```
        ┌─────────────────────────────┐
        │         Platter (top view)    │
        │     ┌───────────────────┐     │
        │    ╱   ╱─ ─ ─ ─ ─ ─╲   ╲    │
        │   │   │   tracks      │   │   │
        │   │   │  (concentric) │   │   │
        │    ╲   ╲_ _ _ _ _ _╱   ╱    │
        │     └───────────────────┘     │
        │              ▲                │
        │              │ actuator arm    │
        │           (head)               │
        └─────────────────────────────┘
```

Every read or write requires two mechanical delays before any data transfer even begins:

- **Seek time**: the time for the actuator arm to physically move the head to the correct track. Typically 4–15 milliseconds.
- **Rotational latency**: the time waiting for the platter to spin the correct sector under the head. On average, this is half a full rotation. At 7200 RPM, a full rotation is ~8.3ms, so average rotational latency is ~4.2ms.

Only after both of these mechanical delays does actual data transfer occur, and data transfer itself is comparatively fast.

**Why this matters:** this is the entire reason HDDs are catastrophic for random I/O and fine for sequential I/O. A sequential read/write keeps the head roughly in place and lets data stream past continuously — no repeated seeks. A random-access workload (a database doing lookups scattered across the disk, or many small files) pays the full seek + rotational latency cost on *every single operation*.

```bash
# Rough mental math for random IOPS on a 7200 RPM HDD:
# seek (~9ms avg) + rotational latency (~4.2ms) ≈ 13ms per random I/O
# 1000ms / 13ms ≈ 77 IOPS
```

This is why the commonly quoted figure for consumer 7200 RPM HDDs is around 75–100 random IOPS — it falls directly out of the mechanical physics.

### 2.2.2 Key HDD Specifications

| Spec | Typical Value | What It Means |
|---|---|---|
| Rotational speed | 5400 / 7200 / 10000 / 15000 RPM | Higher RPM → lower rotational latency, more heat/noise/power |
| Seek time | 4–15 ms | Time to move head to correct track |
| Areal density | Varies by generation | Data per unit of platter surface — drives capacity growth |
| Cache/buffer | 32MB–256MB DRAM | Absorbs bursts, does not change fundamental seek physics |
| Interface | SATA, SAS | Determines max theoretical throughput and command queuing depth |
| MTBF | ~1–2.5 million hours | Manufacturer's statistical reliability estimate, not a guarantee for any single unit |

> **Tip:** For enterprise/server-class HDDs, always check whether the drive is rated for continuous 24/7 operation. Consumer-grade drives are frequently rated for a much lower duty cycle and will fail faster under datacenter-style constant load.

### 2.2.3 When HDDs Still Make Sense

Despite being outperformed by flash storage in nearly every performance dimension, HDDs remain the correct choice for:

- **Cold storage / archival data**: data accessed rarely, where cost-per-terabyte matters far more than latency.
- **Large sequential workloads**: backup targets, media archives, log aggregation storage.
- **Very large capacity requirements at lowest cost**: HDDs still lead SSDs significantly in raw cost-per-terabyte at the high-capacity end (18TB+ drives).
- **Write endurance-agnostic bulk storage**: HDDs don't wear out from writes the way flash does (see 2.3.4), which matters for write-heavy archival or logging tiers.

> **Warning:** Never put a latency-sensitive workload (an OLTP database, a hot key-value store, container image layers under heavy build churn) on spinning disk and expect flash-like performance from caching alone. The page cache can absorb *read* latency for hot data, but any write-heavy or cache-miss-heavy workload will expose the underlying mechanical latency immediately.

---

## 2.3 Solid-State Drives (SSD)

### 2.3.1 How an SSD Physically Works

SSDs have no moving parts. Data is stored in **NAND flash memory cells**, organized into pages (typically 4–16KB) grouped into blocks (typically hundreds of pages, often 256KB–4MB). This organizational structure creates behavior that is fundamentally different from an HDD, in ways that matter a great deal to an administrator:

- **Reads and writes happen at the page level** — you can write to an empty page directly.
- **You cannot overwrite a page in place.** A page must be *erased* before it can be written again, and erasure only happens at the *block* level (hundreds of pages at once), not the page level.
- Because of this asymmetry, an SSD controller can never simply "overwrite" existing data the way an HDD can. Instead, it writes new data to a fresh, already-erased page elsewhere, marks the old page as stale, and relies on a background process to reclaim stale pages later.

```
 Block (must be erased as a whole unit)
 ┌────┬────┬────┬────┬────┬────┬────┬────┐
 │Page│Page│Page│Page│Page│Page│Page│Page│
 │ 0  │ 1  │ 2  │ 3  │ 4  │ 5  │ 6  │ 7  │
 └────┴────┴────┴────┴────┴────┴────┴────┘
   ▲ can write directly if empty
   ▲ cannot overwrite in place — must erase whole block first
```

### 2.3.2 The Flash Translation Layer (FTL) and Garbage Collection

An SSD controller runs firmware called the **Flash Translation Layer (FTL)**, which does the heavy lifting of making a fundamentally awkward storage medium (page-writable, block-erasable, wear-limited) look to the OS like a simple, linearly addressable block device.

The FTL is responsible for:

- **Logical-to-physical address mapping**: the OS's logical block address is not the physical NAND location — the FTL maintains this mapping and can move data around transparently.
- **Wear leveling**: distributing writes evenly across all physical blocks so no single block wears out far ahead of the others (see 2.3.4).
- **Garbage collection**: proactively finding blocks with a lot of stale pages, copying the still-valid pages elsewhere, and erasing the block so it's ready for new writes. This runs as a background process and is largely invisible — except when it isn't (see the warning below).
- **TRIM support**: when a file is deleted at the filesystem level, the OS can issue a `TRIM` command telling the SSD "these logical blocks no longer hold valid data." Without TRIM, the SSD's garbage collector doesn't know a page is free until something overwrites it, and it will unnecessarily preserve stale data during garbage collection, hurting both performance and endurance.

```bash
# Check whether a block device supports TRIM/discard
$ lsblk --discard /dev/sda
NAME DISC-ALN DISC-GRAN DISC-MAX DISC-ZERO
sda         0       512B       2G         0

# Manually trigger TRIM on all mounted filesystems that support it
$ sudo fstrim -av
/                  : 12.4 GiB (13328844800 bytes) trimmed
/boot              : 421.3 MiB (441860096 bytes) trimmed
```

> **Warning:** An SSD that's been running for a long time without TRIM support (e.g., an older filesystem/mount configuration, or a virtualized environment where discard passthrough isn't configured) can experience significant write performance degradation as garbage collection is forced to work harder with less information about what's actually free. This is one of the most common — and most fixable — causes of "my SSD got slow over time."

> **Tip:** Most modern Linux distributions either mount filesystems with the `discard` option (continuous, inline TRIM — has a small performance cost per delete) or, more commonly recommended, run `fstrim` periodically via a systemd timer (`fstrim.timer`, enabled by default on most distros). Check with `systemctl status fstrim.timer`.

### 2.3.3 SSD Interfaces: SATA vs NVMe

SSDs come in two broad interface families that matter enormously for performance, covered in more depth in 2.4 and 2.5, but summarized here:

| | SATA SSD | NVMe SSD |
|---|---|---|
| Protocol | AHCI (designed for spinning disks) | NVMe (designed for flash from the ground up) |
| Bus | SATA (max ~600 MB/s) | PCIe (multiple GB/s, generation-dependent) |
| Queue depth | 1 queue, 32 commands | Up to 65,535 queues, 65,536 commands each |
| Typical form factor | 2.5" drive | M.2, U.2, PCIe add-in card |

The queue depth difference is not a minor detail — it's the single biggest reason NVMe dramatically outperforms SATA SSDs under concurrent, parallel workloads (heavily multi-threaded databases, virtualization hosts), even when using similar underlying NAND.

### 2.3.4 Write Endurance and Wear

Flash cells degrade with each program/erase (P/E) cycle — the insulating layer that traps electrons to represent a bit gradually wears down. This gives flash-based storage a *finite write endurance*, unlike HDDs, which are not meaningfully worn out by writes (though they do have mechanical wear from spinning and seeking).

Manufacturers express this endurance as:

- **TBW (Terabytes Written)**: total data the drive is rated to absorb over its life.
- **DWPD (Drive Writes Per Day)**: how many times you could rewrite the drive's full capacity, every day, for the warranty period, without exceeding the rated endurance.

```bash
# Check SSD wear level and health via SMART
$ sudo smartctl -a /dev/nvme0n1 | grep -iE 'percentage_used|wear|media_wearout'
Percentage Used:                   7%
```

> **Security Note:** Because the FTL remaps logical addresses to physical NAND locations transparently, a "deleted" or "overwritten" file's old data may still physically exist on the flash media in a page marked stale but not yet erased. This has real implications for secure deletion — covered in depth in Chapter 13.

### 2.3.5 Cell Types: SLC, MLC, TLC, QLC

NAND flash cells can store different numbers of bits per cell, trading cost and density against performance and endurance:

| Type | Bits/Cell | Relative Endurance | Relative Cost/GB | Common Use |
|---|---|---|---|---|
| SLC | 1 | Highest | Highest | Enterprise, caching tiers |
| MLC | 2 | High | High | Prosumer/enterprise |
| TLC | 3 | Medium | Medium | Mainstream consumer/enterprise |
| QLC | 4 | Lowest | Lowest | High-capacity consumer, cold-ish data |

**Why it matters for administrators:** if you're provisioning storage for a write-heavy workload (e.g., a database's write-ahead log, a CI system building thousands of ephemeral containers per day), checking the DWPD/TBW rating — and by extension the underlying cell type — is not optional. A QLC consumer drive under sustained heavy-write enterprise load can wear out far faster than its capacity and price might suggest.

---

## 2.4 NVMe (Non-Volatile Memory Express)

NVMe is not, strictly speaking, a competing storage medium to SSD — it's a *protocol*, designed specifically for flash storage attached over PCIe, as opposed to reusing SATA/AHCI, which was designed decades earlier around the assumptions of spinning disks (single command queue, high per-command overhead, an interface bus that tops out around 600 MB/s).

### 2.4.1 Why NVMe Is Fundamentally Faster, Not Just "Newer"

- **Massively parallel queuing**: NVMe supports up to 65,535 I/O queues, each with up to 65,536 outstanding commands. AHCI/SATA supports exactly 1 queue with 32 commands. On a multi-core system running many concurrent I/O-heavy processes, this lets NVMe drives service requests from multiple CPU cores in parallel with essentially no lock contention at the queue level.
- **Lower per-command overhead**: NVMe was designed to require fewer CPU cycles per I/O operation than the legacy AHCI command set, which reduces CPU-side bottlenecking at high IOPS.
- **Direct PCIe attachment**: bypasses the SATA controller and its bus bandwidth ceiling entirely. A PCIe 4.0 x4 NVMe drive has a theoretical bus bandwidth around 8 GB/s, versus SATA's hard ceiling around 600 MB/s.

```bash
# Identify NVMe devices and basic info
$ lsblk -d -o NAME,SIZE,MODEL,TRAN
NAME    SIZE MODEL                    TRAN
nvme0n1 1.8T Samsung SSD 980 PRO 2TB   nvme
sda     3.6T ST4000NM000A              sata

# Detailed NVMe controller/namespace info
$ sudo nvme id-ctrl /dev/nvme0 | head -20
$ sudo nvme smart-log /dev/nvme0
```

### 2.4.2 NVMe Namespaces

NVMe introduces the concept of a **namespace** — a quantity of non-volatile storage that can be formatted into logical blocks, roughly analogous to a partition but implemented at the controller/protocol level rather than by an on-disk partition table. A single physical NVMe SSD can expose multiple namespaces, each appearing to the OS as an independent block device (`/dev/nvme0n1`, `/dev/nvme0n2`, ...). This is primarily used in enterprise contexts for workload isolation on shared NVMe hardware.

> **Note:** For the overwhelming majority of single-server/workstation use, you'll deal with exactly one namespace per drive (`nvme0n1`), and it will look and behave, from a partitioning and filesystem standpoint, essentially the same as a SATA disk — just faster.

---

## 2.5 SATA and SAS

### 2.5.1 SATA (Serial ATA)

SATA is the dominant consumer/prosumer interface for both HDDs and SATA-class SSDs. Key characteristics:

- Single-device point-to-point connection (no shared bus like old parallel ATA).
- Max theoretical throughput around 600 MB/s (SATA III / 6 Gbps).
- Uses the AHCI protocol, with the queue-depth limitations described above.
- Hot-plug capable in most modern implementations.

### 2.5.2 SAS (Serial Attached SCSI)

SAS is the enterprise/datacenter counterpart to SATA, and while it looks similar physically (SAS backplanes often accept both SAS and SATA drives), it differs in important ways:

| | SATA | SAS |
|---|---|---|
| Typical throughput | Up to 600 MB/s | Up to 2400 MB/s (12 Gbps SAS-3) |
| Command queue depth | 32 (NCQ) | 256 (native SCSI queuing) |
| Dual-porting (redundant paths) | No | Yes — critical for HA storage arrays |
| Full-duplex | No | Yes |
| Typical use | Consumer, prosumer, single-server | Enterprise arrays, SANs, high-availability clusters |

**Why dual-porting matters:** SAS drives can be connected to two separate controllers/paths simultaneously, so if one HBA (Host Bus Adapter) or cable path fails, storage remains reachable via the second path. This is a foundational building block of enterprise storage high availability — SATA has no equivalent.

> **Tip:** If you see a drive bay backplane in a server accepting both SAS and SATA drives, you can generally mix them — SAS backplanes are designed to be backward-compatible with SATA drives — but you cannot plug a SAS drive into a pure SATA-only port; the connectors are physically/electrically incompatible for the SAS-specific pins.

---

## 2.6 USB Storage

USB storage devices (flash drives, external HDDs/SSDs) attach via the USB mass storage protocol (or, increasingly, UASP — USB Attached SCSI Protocol, which behaves much more like native SCSI/SAS command queuing and is noticeably faster for random I/O than legacy USB mass storage).

### 2.6.1 Key Considerations

- **Performance variance is enormous.** A cheap USB flash drive might sustain single-digit MB/s on random writes; a good external NVMe enclosure over USB 3.2/USB4 can approach native NVMe speeds.
- **Power delivery matters.** Bus-powered external drives (especially 2.5" HDDs and some SSD enclosures) can behave erratically — unexpected disconnects, I/O errors — if the USB port can't supply sufficient stable current, especially through unpowered hubs.
- **Filesystem compatibility.** USB storage frequently arrives pre-formatted as exFAT or NTFS for cross-platform (Windows/macOS/Linux) compatibility, rather than a native Linux filesystem. Reformatting to ext4/XFS is common when a drive is dedicated to Linux-only use (see Chapter 5).
- **Not designed for sustained server workloads.** USB storage — even fast USB storage — is fundamentally a removable-media interface, without the reliability guarantees, hot-plug event robustness, or sustained-duty-cycle design of SATA/SAS/NVMe. Treat it as appropriate for backups, transfers, and installation media — not as a primary server storage tier.

```bash
# Identify a newly attached USB storage device
$ lsblk
$ dmesg | tail -20
[12345.678901] usb 2-1: new SuperSpeed USB device
[12345.789012] sd 5:0:0:0: [sdb] Attached SCSI removable disk

# Check whether the device negotiated UASP (much faster) vs legacy mass storage
$ lsusb -t
```

> **Warning:** Always unmount (`umount`) — and ideally use `udisksctl power-off` or equivalent — before physically disconnecting a USB storage device. Because writes are frequently cached (Chapter 1, Section 1.3), a "successful" file copy that finished in the file manager does not guarantee the data has actually been flushed to the physical device. Yanking the cable before writeback completes is one of the most common causes of USB drive corruption and data loss.

---

## 2.7 Performance Comparison

The table below is intended as a *directional* comparison — actual numbers vary significantly by specific model, generation, and workload, but the relative ordering and magnitude of the gaps is consistent and worth internalizing.

| Metric | HDD (7200 RPM) | SATA SSD | NVMe SSD (PCIe 4.0) |
|---|---|---|---|
| Sequential Read | ~150–250 MB/s | ~500–550 MB/s | ~5,000–7,500 MB/s |
| Sequential Write | ~150–250 MB/s | ~450–520 MB/s | ~4,000–7,000 MB/s |
| Random Read IOPS (4K) | ~75–180 | ~80,000–100,000 | ~500,000–1,000,000+ |
| Random Write IOPS (4K) | ~75–180 | ~70,000–90,000 | ~400,000–900,000+ |
| Typical Latency | 5–15 ms | ~0.1 ms | ~0.02–0.05 ms |
| Cost per TB | Lowest | Medium | Highest |
| Endurance concern | Mechanical wear | Write cycles (TBW/DWPD) | Write cycles (TBW/DWPD) |

```
Relative random 4K IOPS (illustrative, not to scale):

HDD        |█
SATA SSD   |███████████████████████████████████
NVMe SSD   |████████████████████████████████████████████████████████████████████████████
```

> **Note:** The gap between HDD random IOPS and SSD random IOPS (roughly 500–1000x) is far larger than the gap between SATA SSD and NVMe SSD random IOPS (roughly 5–10x). If you're migrating a random-I/O-heavy workload off spinning disk, *any* flash storage is likely to deliver the overwhelming majority of the achievable improvement — NVMe vs SATA SSD is a real but secondary optimization by comparison.

---

## 2.8 Advantages and Disadvantages Summary

| Device Type | Advantages | Disadvantages |
|---|---|---|
| **HDD** | Lowest cost/TB; no write-wear; mature, well-understood failure modes; excellent for sequential/archival | Very poor random I/O; mechanical failure modes (bearings, heads); higher power/noise/heat per TB at small scale; fragile to physical shock |
| **SATA SSD** | Large performance jump over HDD; drop-in SATA compatibility; moderate cost/TB | Bottlenecked by SATA/AHCI ceiling; still far behind NVMe under concurrent load; finite write endurance |
| **NVMe SSD** | Best-in-class throughput, IOPS, and latency; massive queue depth for concurrent workloads | Highest cost/TB; finite write endurance; can generate significant heat under sustained load (thermal throttling); fewer physical slots on some systems (M.2 slot count) |
| **USB Storage** | Portable; universally compatible; cheap for basic use | Highly variable performance/quality; not designed for sustained server duty cycles; power-delivery quirks; easy to unsafely disconnect |

---

## 2.9 Choosing a Device Type: A Practical Framework

When provisioning storage for a specific role, work through these questions in order:

1. **Is the access pattern predominantly sequential or random?**
   Sequential-heavy (backups, media, log archives, large batch reads) → HDD is often still cost-effective. Random-heavy (databases, VM images, container layers) → flash is close to mandatory for acceptable latency.

2. **What's the durability/endurance profile of the workload?**
   Write-heavy, high-churn (CI build caches, write-ahead logs, high-frequency logging) → check TBW/DWPD carefully; consider higher-endurance cell types (MLC over QLC) or enterprise-rated drives.

3. **Is this single-user/single-threaded or highly concurrent?**
   Many parallel I/O streams (multi-tenant database hosts, virtualization hosts, busy build servers) → NVMe's deep queuing advantage becomes decisive, not just a nice-to-have.

4. **What's the availability requirement?**
   Enterprise HA storage arrays where a single path failure must not cause an outage → SAS's dual-porting becomes relevant; commodity SATA/NVMe generally lacks this.

5. **What's the actual budget per terabyte, and how much of the dataset is genuinely "hot"?**
   Very often the right answer isn't "all NVMe" or "all HDD" but a *tiered* approach — small, fast NVMe/SSD for hot data and metadata, larger HDD pools for bulk/cold data, tied together with LVM, caching layers, or application-level tiering. This tiering pattern reappears throughout Chapters 10–12.

> **Tip:** Don't guess at IOPS/throughput requirements — measure the actual workload where possible (Chapter 12 covers `iostat`, `fio`, and related benchmarking tools in depth) before committing to a storage tier. Over-provisioning expensive NVMe for a workload that's actually sequential-bulk-archive in nature is a common, avoidable cost mistake; under-provisioning flash for a genuinely random-I/O-heavy database is a common, avoidable performance mistake.

---

## 2.10 Common Mistakes

- **Assuming all SSDs perform the same.** Interface (SATA vs NVMe), cell type (SLC/MLC/TLC/QLC), and controller quality all produce large real-world differences even within "SSD" as a category.
- **Ignoring TRIM/discard configuration**, leading to unexplained SSD slowdown over time (2.3.2).
- **Running enterprise write-heavy workloads on consumer-grade QLC drives** without checking DWPD, then being surprised by early wear-related failures.
- **Treating USB external storage as a reliable primary server volume** rather than what it's designed for: portable/backup use.
- **Comparing sequential throughput numbers when the real workload is random-access**, leading to storage that "benchmarks great" but performs poorly in production.
- **Forgetting that HDD mechanical failure modes are physically different from flash wear-out** — this affects monitoring strategy (Chapter 14) and RAID rebuild risk calculus (Chapter 11): HDDs in the same RAID array from the same batch tend to fail in correlated bursts due to shared mechanical wear and manufacturing lot effects, which is a real factor in RAID design.

---

## 2.11 Troubleshooting Physical-Layer Issues

| Symptom | Likely Physical-Layer Cause | First Diagnostic Step |
|---|---|---|
| Sudden, severe I/O slowdown on an SSD | TRIM not running / garbage collection saturation | `sudo fstrim -v /` and check `discard` mount option |
| Intermittent USB drive disconnects | Insufficient bus power, bad cable, unpowered hub | Try direct port, powered hub, `dmesg -w` while reproducing |
| Clicking/grinding noise from a drive | HDD mechanical failure (head/bearing) | Back up immediately; check `smartctl -a` for reallocated sectors |
| SSD reporting high "percentage used" in SMART | Approaching rated write endurance | Plan replacement; review whether workload should move to higher-endurance media |
| Device visible in `dmesg` but not in `lsblk` | Partition table missing/corrupt, or device init failure | `sudo fdisk -l /dev/sdX`, check `dmesg` for driver errors |

> **Security Note:** SMART data (`smartctl -a`), including reallocated sector counts, power-on hours, and (for SSDs) wear percentage, should be part of routine monitoring — not just a reactive troubleshooting tool. Silent physical degradation is one of the more common precursors to unplanned data loss, and it's detectable well before catastrophic failure if you're actually watching it. Chapter 14 covers proactive SMART monitoring in detail.

---

*Previous: [01-Introduction.md](./01-Introduction.md) — Next: 03-Block-Devices.md*
