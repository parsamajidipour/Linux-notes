# 11. RAID

RAID (Redundant Array of Independent Disks) combines multiple physical drives into a single logical unit to gain redundancy, performance, or both. This chapter covers why RAID exists, the common RAID levels and their actual trade-offs, software RAID via `mdadm`, and the recovery basics every administrator should understand before they're needed under pressure.

---

## 11.1 Why RAID?

A single disk is a single point of failure — every physical device eventually fails (Chapter 2), and for any workload where availability or data durability matters, relying on exactly one drive is a risk decision, whether or not it's been made consciously. RAID addresses this by spreading data (and often redundant copies or parity information) across multiple drives, so that the failure of one drive doesn't mean the failure of the dataset.

**Two distinct, sometimes conflated, goals:**

- **Redundancy**: the array survives one (or more) drive failures without data loss, and ideally without interrupting service.
- **Performance**: spreading I/O across multiple drives can increase throughput and/or IOPS beyond what a single drive can provide.

Not every RAID level provides both — RAID 0 provides *only* performance (and actually makes reliability worse), which is a critical distinction covered in 11.2.

> **Warning:** RAID is not a backup. It protects against drive failure, not against accidental deletion, filesystem corruption, ransomware, or a fire/theft/disaster affecting the entire physical system. Every RAID deployment should still be paired with a genuine backup strategy (Chapter 15) covering scenarios RAID cannot address.

---

## 11.2 RAID Levels

### 11.2.1 RAID 0 — Striping

Data is split ("striped") across all drives in the array with no redundancy at all.

```
 Disk 1: [A1][A3][A5]
 Disk 2: [A2][A4][A6]
```

- **Capacity**: 100% of combined drive capacity (no overhead).
- **Performance**: best-case read/write throughput — I/O is spread across all drives simultaneously.
- **Redundancy**: **none**. The loss of *any single drive* in the array destroys the entire array's data, because every file's data is split across all members.
- **Reliability is actually worse than a single drive**, since the array's failure probability is the *combined* failure probability of all member drives, not any individual one.

> **Warning:** RAID 0 should only ever be used for genuinely disposable, easily-regenerated data (scratch/cache space, a build artifact cache that can be recreated) where maximum throughput matters more than durability. It is never an appropriate choice for anything containing data you cannot afford to lose.

### 11.2.2 RAID 1 — Mirroring

Every drive in the array holds an identical, complete copy of the data.

```
 Disk 1: [A][B][C]
 Disk 2: [A][B][C]   (exact mirror)
```

- **Capacity**: 50% of combined drive capacity (with 2 drives) — usable capacity equals one member drive's capacity regardless of how many mirrors you add.
- **Performance**: read performance can improve (reads can be served from either/any mirror); write performance is roughly equivalent to a single drive, since every write must be applied to all mirrors.
- **Redundancy**: survives the loss of all but one drive in the array (with only 2 drives, survives 1 failure).
- **Simplicity**: conceptually the simplest RAID level, with correspondingly simple and fast rebuilds.

### 11.2.3 RAID 5 — Striping with Distributed Parity

Data is striped across drives like RAID 0, but one drive-worth of space, spread across all drives (rotated per stripe, not fixed to one physical drive), stores **parity** — data that can reconstruct any single missing block via an XOR calculation across the other drives in that stripe.

```
 Disk 1: [A1][A3][ P3]
 Disk 2: [A2][ P2][A5]
 Disk 3: [P1][A4][A6]
              (parity rotates across drives)
```

- **Capacity**: (N-1)/N of combined capacity — e.g., 4 drives of 2TB each yields 6TB usable (one drive's worth lost to parity).
- **Performance**: good read throughput; write performance is reduced by the parity calculation and the "read-modify-write" penalty for partial-stripe writes.
- **Redundancy**: survives exactly **one** drive failure. A second failure before the array is rebuilt results in total data loss.
- **Rebuild risk**: rebuilding a RAID 5 array after a failed drive requires reading *every remaining drive in full* to recompute the missing data — a high-stress operation for the surviving drives, and increasingly risky on large modern drives (see 11.2.6).

### 11.2.4 RAID 6 — Striping with Double Distributed Parity

Identical concept to RAID 5, but with **two** independent parity blocks per stripe instead of one.

- **Capacity**: (N-2)/N of combined capacity.
- **Redundancy**: survives **two** simultaneous drive failures.
- **Performance**: write performance is further reduced versus RAID 5 due to the second parity calculation.
- **Why it exists**: directly addresses RAID 5's biggest modern weakness — the high-stress, hours-to-days-long rebuild window on large drives, during which a *second* failure is fully fatal under RAID 5 but survivable under RAID 6.

### 11.2.5 RAID 10 (1+0) — Mirrored Stripes

A stripe (RAID 0) built across multiple mirrored pairs (RAID 1) — combining both techniques.

```
 Mirror Pair 1: Disk 1 [A][C]  ←mirror→  Disk 2 [A][C]
 Mirror Pair 2: Disk 3 [B][D]  ←mirror→  Disk 4 [B][D]
              striped across both mirror pairs
```

- **Capacity**: 50% of combined capacity (same overhead as RAID 1, regardless of drive count).
- **Performance**: excellent — combines RAID 0's striped throughput with RAID 1's ability to serve reads from either mirror.
- **Redundancy**: survives multiple drive failures, *as long as no mirrored pair loses both of its members simultaneously* — meaningfully more resilient than RAID 5/6 in practice, and with a much faster, lower-stress rebuild (only the failed drive's mirror partner needs to be copied, not every drive in the array).
- **Cost**: requires at least 4 drives, and carries the same 50% capacity overhead as RAID 1 — the most expensive option per usable terabyte among the levels covered here.

### 11.2.6 Level Comparison

| Level | Min Drives | Usable Capacity | Fault Tolerance | Read Perf. | Write Perf. | Rebuild Stress |
|---|---|---|---|---|---|---|
| RAID 0 | 2 | 100% | None (worse than single disk) | Excellent | Excellent | N/A |
| RAID 1 | 2 | 50% (1 drive equiv.) | 1 of N-1 | Good | Moderate | Low |
| RAID 5 | 3 | (N-1)/N | 1 drive | Good | Reduced (parity calc) | High |
| RAID 6 | 4 | (N-2)/N | 2 drives | Good | Further reduced | High |
| RAID 10 | 4 | 50% | Multiple (pair-dependent) | Excellent | Excellent | Low |

> **Note:** RAID 5's viability on very large modern drives (multi-terabyte) is a genuinely contested topic in current storage practice. As drive capacities have grown far faster than drive throughput, RAID 5 rebuild times have stretched from hours to potentially days, during which the array runs with zero fault tolerance and every surviving drive is placed under sustained heavy read load — precisely the conditions correlated with additional failures (recall Chapter 2's note on correlated failures within a batch/lot of drives). Many practitioners today prefer RAID 6 or RAID 10 for new large-capacity deployments specifically because of this rebuild-window risk.

---

## 11.3 Software RAID with `mdadm`

Linux's native software RAID implementation is managed through `mdadm` ("multiple disk admin"), creating `/dev/mdX` devices (Chapter 3's `md` prefix).

### 11.3.1 Creating an Array

```bash
# Create a RAID 1 mirror from two partitions
$ sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb1 /dev/sdc1

# Create a RAID 5 array from three drives
$ sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sdb1 /dev/sdc1 /dev/sdd1

# Check array status and sync progress
$ cat /proc/mdstat
Personalities : [raid1]
md0 : active raid1 sdc1[1] sdb1[0]
      104792064 blocks super 1.2 [2/2] [UU]
      [=========>...........]  resync = 45.2% (47324864/104792064) finish=12.3min speed=45632K/sec

# Detailed array info
$ sudo mdadm --detail /dev/md0
```

### 11.3.2 Persisting Array Configuration

```bash
# Save the array's configuration so it reassembles correctly at boot
$ sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf

# Update the initramfs so early boot can find/assemble the array
$ sudo update-initramfs -u    # Debian/Ubuntu
$ sudo dracut -f               # RHEL/Fedora family
```

> **Warning:** Forgetting to persist the array configuration (and rebuild the initramfs, if the array is needed at boot — e.g., it hosts the root filesystem) is a common and entirely avoidable cause of "the RAID array didn't come back after reboot." The array itself is fine; the system simply never learned how to reassemble it automatically.

### 11.3.3 Building a Filesystem on Top

```bash
$ sudo mkfs.ext4 /dev/md0
$ sudo mount /dev/md0 /mnt/raid
```

From this point forward, the array behaves exactly like any other block device for partitioning, filesystem, and mounting purposes — everything from Chapters 4–7 applies unchanged on top of `/dev/md0`.

---

## 11.4 Recovery Basics

### 11.4.1 Handling a Failed Drive

```bash
# Identify a failed member (shown as (F) or removed from the active count)
$ cat /proc/mdstat
$ sudo mdadm --detail /dev/md0

# Explicitly mark a drive as failed if it hasn't been auto-detected
$ sudo mdadm --manage /dev/md0 --fail /dev/sdc1

# Remove the failed drive from the array
$ sudo mdadm --manage /dev/md0 --remove /dev/sdc1

# Physically replace the drive, then add its replacement
$ sudo mdadm --manage /dev/md0 --add /dev/sdd1

# Watch the rebuild progress
$ watch cat /proc/mdstat
```

### 11.4.2 Monitoring for Failures Proactively

```bash
# mdadm can run as a monitoring daemon, emailing on state changes
$ sudo mdadm --monitor --scan --daemonise

# Check the systemd service that typically handles this on modern distros
$ systemctl status mdmonitor
```

> **Tip:** Don't rely on manually running `cat /proc/mdstat` periodically as your only failure detection mechanism — configure `mdadm --monitor` (or your distribution's equivalent service) with a working email/alert destination, and actually test that the alert delivery works, ideally by simulating a failure in a non-production environment. A RAID array silently running in a degraded state, unnoticed, defeats the entire purpose of having redundancy in the first place.

### 11.4.3 A Note on Hardware RAID and Fake RAID

This chapter focuses on Linux software RAID (`mdadm`), which is mature, well-understood, and — for most modern workloads — performs comparably to dedicated hardware RAID controllers, without the vendor lock-in of proprietary hardware RAID metadata formats.

**"Fake RAID"** (motherboard/BIOS-level RAID, common on consumer hardware, e.g., Intel RST) is worth explicitly avoiding on Linux servers where possible — it's neither true hardware RAID (the actual RAID logic still runs in a driver, not dedicated silicon) nor Linux's native, well-supported `mdadm`, and tends to combine the downsides of both without the benefits of either.

---

## 11.5 Performance vs. Redundancy Trade-offs — Choosing a Level

| Priority | Recommended Level |
|---|---|
| Maximum performance, redundancy irrelevant (disposable/scratch data) | RAID 0 |
| Simple redundancy, smallest drive count, boot/root filesystems | RAID 1 |
| Balanced capacity efficiency and redundancy, moderate drive count, tolerable rebuild window | RAID 5 (smaller arrays, smaller drives) |
| Large-capacity arrays where rebuild-window risk matters | RAID 6 |
| Best combination of performance and redundancy, budget allows the capacity cost | RAID 10 |

> **Tip:** As a practical modern default: RAID 1 for small (2-drive) redundant boot/root needs, RAID 10 for performance-and-redundancy-critical data where the capacity cost is acceptable, and RAID 6 (over RAID 5) for large-capacity bulk-storage arrays where rebuild time is a real risk factor. Reserve RAID 5 for smaller, less critical arrays where its capacity efficiency outweighs the rebuild-window concern.

---

## 11.6 Common Mistakes

- **Treating RAID as a backup** (11.1) — it protects against drive failure only, not deletion, corruption, or disaster.
- **Choosing RAID 5 for a large-capacity array without accounting for rebuild-window risk** on modern large drives.
- **Forgetting to persist `mdadm` configuration and rebuild the initramfs**, leaving an array that works fine until the next reboot.
- **Not configuring or testing failure monitoring/alerting**, leaving a degraded array undetected for an extended period — during which a second failure can mean total data loss.
- **Mixing drives of significantly different performance characteristics** (e.g., a mismatched HDD in an otherwise-SSD array) — the array's effective performance is generally bounded by its slowest member.
- **Relying on motherboard "fake RAID"** on a Linux server instead of native `mdadm` or genuine hardware RAID.

---

## 11.7 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| Array shows degraded state | A member drive failed or was dropped | `cat /proc/mdstat`, `mdadm --detail /dev/mdX` |
| Array didn't reassemble after reboot | Missing/stale `mdadm.conf`, or initramfs not updated | Regenerate `mdadm.conf` via `--detail --scan`, rebuild initramfs |
| Rebuild is extremely slow | Competing I/O load, or intentional rebuild-speed throttling | Check `/proc/sys/dev/raid/speed_limit_min` and `speed_limit_max` |
| No failure alerts were sent despite a real failure | Monitoring daemon not running or misconfigured mail delivery | `systemctl status mdmonitor`; test alert delivery deliberately |
| Array reports more failures than expected drives lost | A cabling/controller issue affecting multiple drives simultaneously, not independent drive failures | Check controller/cabling before assuming coincidental multi-drive failure |

> **Security Note:** RAID redundancy has no bearing on data confidentiality — a mirrored or parity-protected array is exactly as readable by anyone with access to any single member drive (for RAID 1) or with enough drives to reconstruct the data (for RAID 5/6) as an unprotected single disk would be. RAID and encryption (Chapter 13) address entirely different concerns and are commonly layered together (encryption beneath or above the RAID layer, depending on the design) rather than treated as substitutes for one another.

---

*Previous: [10-LVM.md](./10-LVM.md) — Next: 12-Storage-Performance.md*
