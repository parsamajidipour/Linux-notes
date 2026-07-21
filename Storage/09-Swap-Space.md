# 9. Swap Space

Swap extends the system's usable memory by using block storage as an overflow area for pages the kernel decides aren't currently needed in RAM. This chapter covers how swap actually works, the two ways to provision it, and how to tune its behavior for different workloads.

---

## 9.1 What Swap Actually Does

When physical RAM is under pressure, the kernel's memory management subsystem can move less-recently-used memory pages out to swap space on disk, freeing that RAM for pages that are actively needed. If a swapped-out page is accessed again later, the kernel reads it back into RAM (a **page fault**, specifically a "major fault" since it requires disk I/O) — transparently to the application, which has no idea its memory was ever anywhere but RAM.

```
   RAM                                    Swap (disk)
 ┌──────────────┐                       ┌──────────────┐
 │ Active Page A │                       │              │
 │ Active Page B │  ◀── page reclaim ──  │ Idle Page X   │
 │ Active Page C │      (write out)       │ Idle Page Y   │
 └──────────────┘                       └──────────────┘
        ▲                                       │
        └──────────── page fault ───────────────┘
              (read back in on access)
```

**Why this matters:** swap is not simply "extra RAM" — it's dramatically slower (even on NVMe, orders of magnitude slower than actual RAM access), so its purpose is specifically to absorb *infrequently accessed* memory, acting as a pressure release valve rather than a genuine RAM substitute. A system that's actively, continuously swapping ("thrashing") under a working set that simply doesn't fit will perform far worse than the same system with more RAM — swap buys graceful degradation and headroom, not equivalent capacity.

> **Warning:** Never treat swap capacity as a substitute for adequate RAM in a performance-sensitive workload (databases, in-memory caches, latency-sensitive services). Heavy sustained swapping under such workloads is a symptom to fix at the RAM/capacity-planning level, not a steady-state condition to tune around indefinitely.

---

## 9.2 Swap Partition vs. Swap File

Linux supports two equally functional mechanisms for providing swap space, differing mainly in flexibility and setup method.

### 9.2.1 Swap Partition

A dedicated partition, formatted specifically for swap use.

```bash
# Create a swap partition (after partitioning it with fdisk/parted, type 'Linux swap')
$ sudo mkswap /dev/sdb2
$ sudo swapon /dev/sdb2
```

**Advantages:** slightly simpler for the kernel (no filesystem layer in between), traditionally considered marginally more efficient, and immune to filesystem-level fragmentation concerns.

**Disadvantages:** fixed size, requiring a repartitioning operation (Chapter 4) to resize — inconvenient on a live system, especially if there's no free unpartitioned space adjacent to it.

### 9.2.2 Swap File

A regular file on an existing filesystem, used as swap.

```bash
# Allocate a swap file (fallocate is fast; falls back to dd if unsupported by the fs)
$ sudo fallocate -l 4G /swapfile
# Some filesystems (notably Btrfs with certain configurations) don't support fallocate
# for swap files cleanly — dd is the safe universal fallback:
$ sudo dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress

# Correct, restrictive permissions — swap files must not be world-readable
$ sudo chmod 600 /swapfile

# Format as swap and activate
$ sudo mkswap /swapfile
$ sudo swapon /swapfile
```

**Advantages:** trivially resizable (just create a new, larger file and swap it in), doesn't require dedicated partition space decided at install time, and can be added or removed from an already-running system with zero downtime.

**Disadvantages:** historically had performance caveats on certain filesystem/kernel combinations (largely resolved on modern kernels with ext4/XFS for regular swap files, though Btrfs has specific additional requirements — a swap file on Btrfs must live on a dedicated, non-copy-on-write, non-snapshotted subvolume, since CoW and swap are fundamentally incompatible).

> **Tip:** For most modern systems — including cloud instances and VMs, where repartitioning is especially inconvenient — a swap file is the more practical default choice today. Reserve swap partitions for cases with a specific reason (very old kernel/filesystem combinations, or a strong preference to keep swap I/O isolated from filesystem overhead entirely).

### 9.2.3 Comparison

| | Swap Partition | Swap File |
|---|---|---|
| Resizing | Requires repartitioning | Trivial — create new file, swap it in |
| Setup complexity | Slightly more (partitioning step) | Simpler (just a file) |
| Filesystem overhead | None | Minimal on modern kernels/ext4/XFS |
| Btrfs compatibility | N/A (own partition) | Requires dedicated no-CoW subvolume |
| Cloud/VM friendliness | Awkward (fixed disk layout) | Excellent |

---

## 9.3 `swapon` and `swapoff`

```bash
# Activate all swap devices/files listed in /etc/fstab
$ sudo swapon -a

# View currently active swap
$ swapon --show
NAME       TYPE      SIZE  USED PRIO
/swapfile  file        4G    0B   -2
/dev/sdb2  partition   8G    0B   -1

# Deactivate a specific swap device/file
# (migrates any currently-swapped pages back into RAM first — requires sufficient free RAM)
$ sudo swapoff /swapfile

# Remove a swap file entirely after deactivating it
$ sudo swapoff /swapfile
$ sudo rm /swapfile
```

> **Warning:** `swapoff` needs enough free RAM to hold everything currently swapped out, since it has to migrate those pages back before releasing the swap space. On a system under real memory pressure, `swapoff` can itself trigger further swapping-in pressure or even stall noticeably — plan for a moment of elevated load when disabling swap on a busy production system.

### 9.3.1 Persistent Swap via `/etc/fstab`

```
UUID=xxxxxxxx-xxxx-...   none   swap   sw   0   0
/swapfile                none   swap   sw   0   0
```

As covered in Chapter 7, swap entries use `none` as the mount point (they're not mounted into the directory tree at all) and `swap` as both the filesystem type and part of the options field.

---

## 9.4 Swap Priority

Multiple swap devices/files can be active simultaneously, with an optional priority controlling which one the kernel prefers to use first.

```bash
# Assign explicit priority (higher number = preferred first)
$ sudo swapon -p 10 /dev/sdb2
$ sudo swapon -p 5 /swapfile
```

**Why this matters practically:** if you have both a fast NVMe-backed swap file and a slower spinning-disk swap partition, assigning the NVMe-backed one a higher priority ensures the kernel exhausts the faster option before falling back to the slower one — genuinely useful in mixed-storage systems, though increasingly rare as an actual deployment pattern given flash storage's ubiquity today.

---

## 9.5 `vm.swappiness`

`vm.swappiness` is a kernel tunable (0–200 on modern kernels, historically documented as 0–100) controlling how aggressively the kernel prefers to reclaim memory by swapping versus by dropping page cache (clean, reclaimable cache pages backing files — cheaper to reclaim since they can simply be re-read from disk rather than needing an actual swap write).

```bash
# View current value
$ cat /proc/sys/vm/swappiness
60

# Set temporarily (until reboot)
$ sudo sysctl vm.swappiness=10

# Set persistently
$ echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
$ sudo sysctl --system
```

| Value | Behavior |
|---|---|
| 0 | Kernel avoids swapping as long as possible, strongly preferring to reclaim page cache instead (not a hard guarantee of zero swap under extreme pressure) |
| 60 (typical default) | Balanced default suitable for general-purpose desktop/server use |
| 100 | Kernel treats swapping and page cache reclaim as roughly equally preferable |
| Higher (100–200, on kernels that support the extended range) | More aggressively prefers swapping over reclaiming file-backed cache |

> **Tip:** Database servers and other workloads that maintain large amounts of important data in application-managed memory (not page cache) commonly lower `vm.swappiness` (often to 1–10) to strongly discourage the kernel from swapping out that memory in favor of dropping page cache instead, since page cache can be cheaply repopulated from disk while swapping active database memory out (and later back in) directly hurts latency.

---

## 9.6 Performance Considerations

- **Swap on NVMe/SSD** is dramatically more tolerable than swap on spinning disk — the latency penalty of a major page fault against an HDD (Chapter 2) can be genuinely severe (tens of milliseconds per fault, versus microseconds for NVMe), directly translating into visible application stalls under any real swapping load.
- **Swap write endurance on SSDs** is a legitimate, if often overstated, concern — modern SSD endurance ratings (Chapter 2, Section 2.3.4) are generally high enough that reasonable swap usage on a well-provisioned system is not a practical wear concern, but a system that's constantly, heavily swapping due to genuine RAM undersizing will accelerate wear on flash-backed swap meaningfully faster than one with adequate RAM and only occasional light swap use.
- **`zswap`/`zram`** are worth knowing about even outside a deep dive: `zram` creates a compressed, RAM-backed swap device (trading CPU cycles for effectively larger usable memory, entirely avoiding disk I/O); `zswap` acts as a compressed write-back cache in front of real disk-backed swap. Both are common on memory-constrained systems (small cloud instances, embedded devices, some desktop distributions by default) and are worth investigating specifically when disk-backed swap I/O itself is the bottleneck rather than the fact of swapping at all.

```bash
# Check whether zram is available/active
$ lsmod | grep zram
$ swapon --show    # zram devices appear here too, once activated
```

---

## 9.7 How Much Swap Do You Need?

There's no single universally correct formula — it depends heavily on workload — but reasonable modern starting heuristics:

| Scenario | General Guidance |
|---|---|
| Server with ample RAM (32GB+), latency-sensitive workload | Small swap (a few GB) as a safety net, low `swappiness` |
| Desktop/workstation with moderate RAM | Swap roughly equal to RAM, or enough to support hibernation if desired (swap must be ≥ RAM size for hibernation to work reliably) |
| Cloud instance / VM with limited RAM | Swap file sized to provide meaningful headroom against burst memory pressure, without masking a genuine need to upsize the instance |
| Systems using hibernation | Swap must be at least as large as installed RAM (the entire RAM contents need somewhere to go) |

> **Note:** The old rule-of-thumb "swap = 2x RAM" predates modern systems with tens or hundreds of gigabytes of RAM, and no longer generally applies — sizing swap as a fixed multiple of very large RAM amounts wastes disk space for no real benefit. Size swap based on actual workload memory-pressure headroom needs (and hibernation requirements, if applicable), not a blanket ratio.

---

## 9.8 Common Mistakes

- **Sizing swap as a blind multiple of RAM** on modern high-RAM systems, wasting disk space without a real corresponding benefit.
- **Forgetting `chmod 600` on a swap file**, leaving it world-readable — a real information-disclosure risk, since swap can contain sensitive data that was resident in process memory (see Security Note below).
- **Creating a swap file on Btrfs without the required dedicated, no-CoW subvolume setup**, leading to activation failures or, worse, filesystem corruption risk.
- **Treating heavy, sustained swapping as something to tune away with `swappiness` alone**, rather than recognizing it as a signal of genuine RAM undersizing for the workload.
- **Running `swapoff` on a system under real memory pressure without expecting a temporary performance hit**, since the kernel must migrate swapped pages back into already-scarce RAM.

---

## 9.9 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| System sluggish, high disk activity, low apparent CPU use | Heavy swapping (thrashing) | `vmstat 1` — watch the `si`/`so` (swap in/out) columns; `free -h` for overall pressure |
| Swap file/partition fails to activate | Wrong permissions, missing `mkswap`, or (Btrfs) missing no-CoW subvolume setup | `sudo swapon -v /swapfile` for verbose error output |
| Swap not active after reboot despite `swapon` working manually | Missing or incorrect `/etc/fstab` entry | Verify the `fstab` swap line, then `sudo swapon -a` |
| Hibernation fails or produces corrupted resume | Swap smaller than RAM, or wrong resume device configured | Confirm swap size ≥ RAM; check bootloader `resume=` parameter matches actual swap device/UUID |
| Suspiciously high SSD wear alongside heavy swap use | Genuine RAM undersizing driving continuous swap I/O | Address root cause (more RAM, lower memory footprint) rather than only monitoring wear |

> **Security Note:** Swap space can contain sensitive data that was resident in a process's memory at the time it was swapped out — encryption keys, passwords momentarily held in memory, or other secrets an application never intended to touch disk at all. On systems handling sensitive data, consider encrypted swap (swap on a `dm-crypt`/LUKS volume — Chapter 13 covers this in depth) and always ensure swap files carry restrictive `600` permissions as shown in 9.2.2. Simply deleting a swap file does not securely erase its prior contents any more than deleting any other file does (Chapter 13, Section 13.3 covers secure deletion).

---

*Previous: [08-Storage-Management-Tools.md](./08-Storage-Management-Tools.md) — Next: 10-LVM.md*
