# 4. Disk Partitioning

Before a block device can host a filesystem, it's typically subdivided into partitions — logical regions of the disk that behave, from the filesystem and mount layer's perspective, as independent block devices in their own right. This chapter covers the two partition table formats you'll encounter (MBR and GPT), the tools used to create and manage partitions, and the alignment considerations that matter for performance.

---

## 4.1 Why Partition at All?

A single physical disk is frequently split into multiple partitions for reasons that have nothing to do with the hardware and everything to do with administrative and operational separation:

- **Separating the OS from data**: a corrupted or full `/home` partition shouldn't be able to take down `/` or prevent the system from booting.
- **Applying different mount options per region**: e.g., `noexec,nosuid` on `/tmp`, but not on `/`.
- **Supporting multiple filesystems or operating systems on one disk**: a dual-boot system, or a boot partition (often FAT32/EFI System Partition) alongside a Linux-native root filesystem.
- **Isolating growth**: giving `/var/log` its own partition so runaway logging can't fill the entire disk and starve the OS.
- **Enabling independent backup/snapshot boundaries**: some backup and snapshot tools operate at the partition or volume level.

> **Note:** Modern practice increasingly pushes this flexibility down into LVM (Chapter 10) rather than static partitions — a small number of physical partitions (often just an EFI System Partition, a `/boot` partition, and a large LVM physical volume) with LVM handling the finer subdivision. Partitioning fundamentals remain essential either way, since LVM physical volumes still sit on top of partitions (or whole disks).

---

## 4.2 MBR (Master Boot Record)

### 4.2.1 Structure and Limitations

MBR is the original PC partitioning scheme, dating to the early 1980s. It stores partition information in the first 512-byte sector of the disk:

```
 Sector 0 (512 bytes)
 ┌──────────────────────────────────────────┐
 │  Boot code (446 bytes)                     │
 ├──────────────────────────────────────────┤
 │  Partition entry 1 (16 bytes)              │
 ├──────────────────────────────────────────┤
 │  Partition entry 2 (16 bytes)              │
 ├──────────────────────────────────────────┤
 │  Partition entry 3 (16 bytes)              │
 ├──────────────────────────────────────────┤
 │  Partition entry 4 (16 bytes)              │
 ├──────────────────────────────────────────┤
 │  Boot signature (2 bytes: 0x55AA)          │
 └──────────────────────────────────────────┘
```

Because only 64 bytes are reserved for partition entries at 16 bytes each, MBR is hard-limited to **4 primary partitions**. To work around this, MBR introduced **extended** and **logical** partitions (4.2.2).

MBR also uses 32-bit values (LBA addressing) to describe partition start/size, which caps the maximum addressable disk size at 2 TiB — any disk or portion of a disk beyond that is simply unreachable under MBR, regardless of the disk's actual capacity.

| MBR Limitation | Value |
|---|---|
| Max primary partitions | 4 |
| Max addressable disk size | 2 TiB |
| Partition table redundancy | None (single copy, single point of failure) |
| Partition type identification | 1-byte type code (often ambiguous/reused across vendors) |

### 4.2.2 Primary, Extended, and Logical Partitions

To exceed the 4-partition limit, one of the four primary partition slots can instead be designated an **extended partition** — a container that itself holds **logical partitions**, linked together internally.

```
 MBR Partition Table (4 slots)
 ┌────────────┬────────────┬────────────┬──────────────────┐
 │ Primary 1   │ Primary 2   │ Primary 3   │ Extended          │
 │ (sda1)      │ (sda2)      │ (sda3)      │ (sda4)            │
 └────────────┴────────────┴────────────┴──────┬────────────┘
                                                    │
                              ┌─────────────────────┼─────────────────────┐
                              ▼                     ▼                     ▼
                        Logical (sda5)        Logical (sda6)        Logical (sda7)
```

Rules worth internalizing:

- You can have **at most one** extended partition among the four primary slots.
- Logical partitions inside the extended partition are numbered starting at 5, regardless of how many primary partitions exist (this is why you'll sometimes see `sda1`, `sda2`, then jump straight to `sda5`).
- You cannot boot directly from a logical partition on most legacy BIOS systems — boot loaders generally require a primary (or the extended container itself, indirectly) — though GRUB2's flexibility has made this less of a hard rule in practice than it once was.

> **Warning:** MBR's extended/logical partition scheme is a historical workaround for a hard architectural limit, not a feature to reach for by choice on new systems. If you're setting up a new disk today and the hardware/firmware supports it (nearly all hardware from the last 15+ years does), use GPT instead (4.3) and avoid this complexity entirely.

---

## 4.3 GPT (GUID Partition Table)

### 4.3.1 Why GPT Replaced MBR

GPT is part of the UEFI specification and was designed specifically to remove MBR's limitations:

| Property | MBR | GPT |
|---|---|---|
| Max partitions | 4 (or more via extended/logical) | 128 by default (configurable) |
| Max disk/partition size | 2 TiB | ~9.4 ZB (effectively unlimited for current hardware) |
| Partition table redundancy | None | Primary copy at start of disk + backup copy at end of disk |
| Integrity checking | None | CRC32 checksums on the header and partition table |
| Partition identification | Ambiguous 1-byte type codes | 128-bit GUIDs (globally unique, type and per-partition) |
| Boot firmware | BIOS (legacy) | UEFI (GPT can also be used with BIOS via a hybrid/BIOS-boot-partition setup, but is designed for UEFI) |

### 4.3.2 GPT Structure

```
 ┌───────────────────────────────────────────────────┐
 │  LBA 0: Protective MBR (compatibility placeholder)  │
 ├───────────────────────────────────────────────────┤
 │  LBA 1: Primary GPT Header (checksums, table loc.)  │
 ├───────────────────────────────────────────────────┤
 │  LBA 2-33: Primary Partition Table (128 entries)     │
 ├───────────────────────────────────────────────────┤
 │                                                       │
 │              Partitions (actual data)                │
 │                                                       │
 ├───────────────────────────────────────────────────┤
 │  Backup Partition Table (mirror of primary)          │
 ├───────────────────────────────────────────────────┤
 │  Backup GPT Header (at the very end of the disk)     │
 └───────────────────────────────────────────────────┘
```

The **protective MBR** at LBA 0 exists purely so that older tools that only understand MBR see a single partition spanning the "whole disk" rather than misinterpreting an empty-looking MBR sector as an uninitialized disk and potentially overwriting it.

**Why the backup header/table at the end of the disk matters practically:** if the primary GPT header or table becomes corrupted (a common symptom after certain kinds of partial writes or corruption events), GPT-aware tools like `gdisk` can detect the mismatch and offer to repair the primary copy from the backup — a recovery capability MBR simply has no equivalent for.

```bash
# gdisk will proactively warn about and offer to fix a primary/backup mismatch
$ sudo gdisk -l /dev/sda
Caution: invalid main GPT header, but valid backup; regenerating main header
from backup!
```

> **Security Note:** GPT's per-partition GUID and CRC32 integrity checks make partition-table-level tampering or accidental corruption more detectable than under MBR — but note that CRC32 protects against *accidental* corruption, not deliberate malicious modification; it is not a cryptographic integrity guarantee.

---

## 4.4 Partitioning Tools

### 4.4.1 `fdisk`

`fdisk` is the traditional, near-universal partitioning tool. Modern versions (`util-linux` package) support both MBR and GPT transparently.

```bash
$ sudo fdisk /dev/sdb

Welcome to fdisk (util-linux 2.39).

Command (m for help): p
Disk /dev/sdb: 100 GiB, 107374182400 bytes, 209715200 sectors
Disklabel type: gpt

Command (m for help): n
Partition number (1-128, default 1):
First sector (2048-209715166, default 2048):
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-209715166, default 209715166): +50G

Created a new partition 1 of type 'Linux filesystem' and of size 50 GiB.

Command (m for help): w
The partition table has been altered.
```

Key `fdisk` interactive commands:

| Command | Action |
|---|---|
| `p` | Print the current partition table |
| `n` | Create a new partition |
| `d` | Delete a partition |
| `t` | Change a partition's type code/GUID |
| `g` | Create a new empty GPT partition table |
| `o` | Create a new empty MBR (DOS) partition table |
| `w` | Write changes to disk and exit |
| `q` | Quit without saving changes |

> **Warning:** `w` writes immediately and irreversibly (as far as the partition table is concerned — the underlying data on any deleted partitions is usually still physically present until overwritten, but the table pointing to it is gone). Always double-check with `p` before `w`, and always confirm you're operating on the intended device (`/dev/sdb`, not `/dev/sda`) — this is one of the highest-consequence typos in all of Linux administration.

### 4.4.2 `gdisk`

`gdisk` is `fdisk`'s GPT-specific counterpart, with an almost identical command interface but GPT-aware features — GUID management, protective MBR handling, and the corrupted-header recovery mentioned in 4.3.2.

```bash
$ sudo gdisk /dev/sdb
GPT fdisk (gdisk) version 1.0.9

Command (? for help): p
Command (? for help): n
Command (? for help): w
```

Use `gdisk` when you specifically need GPT-aware diagnostics or repair; for routine partition creation on a disk you know is already GPT, modern `fdisk` handles it equally well.

### 4.4.3 `parted`

`parted` differs from `fdisk`/`gdisk` in a meaningful way: changes are applied **immediately**, command by command, rather than staged and only committed on `w`. It also supports both scripted (non-interactive) and interactive use, which makes it popular for automation.

```bash
# Interactive
$ sudo parted /dev/sdb
(parted) mklabel gpt
(parted) mkpart primary ext4 0% 50%
(parted) print
(parted) quit

# Scripted / non-interactive — ideal for automation and provisioning scripts
$ sudo parted -s /dev/sdb mklabel gpt
$ sudo parted -s /dev/sdb mkpart primary ext4 0% 50%
$ sudo parted -s /dev/sdb mkpart primary ext4 50% 100%
```

> **Tip:** `parted`'s percentage-based sizing (`0% 50%`) is a convenient way to avoid manual sector-math, but be aware it can produce partitions that aren't perfectly aligned to the underlying device's physical block/erase-block boundaries unless you let `parted` apply its own alignment optimization (on by default in modern versions — see 4.6). For precise, alignment-guaranteed sizing, specify exact units (`MiB`, `GiB`) instead of percentages.

### 4.4.4 Tool Comparison

| Tool | Table Support | Commit Model | Best For |
|---|---|---|---|
| `fdisk` | MBR + GPT | Staged (write with `w`) | General interactive use, most common default |
| `gdisk` | GPT (specifically) | Staged (write with `w`) | GPT-specific tasks, corrupted GPT recovery |
| `parted` | MBR + GPT | Immediate, per-command | Scripting/automation, non-interactive provisioning |

---

## 4.5 Viewing and Verifying Partitions

```bash
# Kernel's current view of block devices and partitions
$ lsblk /dev/sdb

# Detailed partition table dump, either tool works on either table type
$ sudo fdisk -l /dev/sdb
$ sudo gdisk -l /dev/sdb

# Machine-readable partition/filesystem info — useful in scripts
$ sudo blkid /dev/sdb1

# Force the kernel to re-read the partition table without a reboot
# (needed after partitioning a disk that's already in use, e.g. the boot disk)
$ sudo partprobe /dev/sdb
# or, if partprobe isn't available/effective:
$ sudo blockdev --rereadpt /dev/sdb
```

> **Note:** After creating or modifying partitions with `fdisk`/`gdisk`/`parted`, the kernel doesn't always automatically notice the change, particularly for a disk with partitions currently mounted or in use elsewhere in the system. `partprobe` (or a reboot, as a fallback) ensures `/dev/sdX*` entries match the actual on-disk table.

---

## 4.6 Partition Alignment

### 4.6.1 Why Alignment Matters

Modern storage devices operate in fixed-size physical blocks — commonly 4096-byte "4K" sectors on modern HDDs (often presented to the OS as legacy 512-byte logical sectors for compatibility — "512e") and much larger erase blocks on SSDs (Chapter 2, Section 2.3.1, often hundreds of KB). If a partition's starting offset doesn't align with these underlying physical boundaries, a single logical write from the filesystem can straddle two physical blocks, forcing the device to perform two physical operations (and, on some HDDs, an expensive read-modify-write cycle) for what should have been one.

```
 Misaligned partition start:
 Physical block boundaries:  |----4K----|----4K----|----4K----|
 Partition data:                  |----4K write----|
                                   ▲ straddles two physical blocks — 2x physical I/O

 Aligned partition start:
 Physical block boundaries:  |----4K----|----4K----|----4K----|
 Partition data:              |----4K write----|
                               ▲ single physical block — 1x physical I/O
```

On SSDs, misalignment relative to the much larger erase block size can additionally trigger unnecessary read-modify-erase-write cycles during garbage collection, accelerating wear (Chapter 2, Section 2.3.4) in addition to hurting performance.

### 4.6.2 The Modern Default: 1 MiB Alignment

The historical convention of starting the first partition at sector 63 (a legacy CHS-geometry artifact from the MBR/BIOS era) is a textbook example of the misalignment problem above, and is why old Linux installations occasionally show noticeably worse disk performance than expected even on decent hardware.

All modern partitioning tools (`fdisk`, `gdisk`, `parted`) default to starting the first partition at the **1 MiB boundary** (sector 2048, at 512 bytes/sector), which is a multiple of essentially every physical block size in common use (4K sectors, and even most SSD erase block sizes), and is the safe, correct default for virtually all modern hardware.

```bash
# Confirm current alignment on an existing partition
$ cat /sys/block/sda/sda1/alignment_offset
0
# 0 = correctly aligned

# Check the device's reported physical/logical sector sizes
$ sudo blockdev --getpbsz --getss /dev/sda
4096
512
```

> **Tip:** Unless you have a specific reason to do otherwise (matching an unusual RAID stripe size, for instance — Chapter 11), simply accept the default alignment offered by `fdisk`, `gdisk`, or `parted` on any modern system. Manually specifying sector numbers to "optimize" alignment is almost always unnecessary with current tooling and default behavior, and is a common source of self-inflicted misalignment when done incorrectly.

---

## 4.7 Best Practices

- **Prefer GPT for any new disk**, unless you have a specific legacy BIOS/compatibility requirement that mandates MBR. The 2 TiB ceiling and 4-partition limit of MBR are pure liabilities on modern hardware.
- **Always double- and triple-check the target device name** (`/dev/sdX`) before any write operation. Consider using `lsblk` immediately beforehand in the same terminal session to visually confirm which device is which.
- **Use `parted -s` or equivalent scripted tools for repeatable provisioning** (infrastructure automation, kickstart/preseed installs) rather than manual interactive sessions, to eliminate human error at scale.
- **Leave partition table creation to modern tooling's default alignment** — don't hand-roll sector offsets without a concrete reason.
- **Label partitions or set clear GUIDs/types** where the tooling supports it, to make later identification (Chapter 3, Section 3.2.2) easier and less error-prone than relying on partition order alone.
- **Back up the partition table before major changes** on a disk containing important data — `sgdisk --backup=table.bak /dev/sdX` (for GPT) can save a great deal of pain if something goes wrong mid-operation.

```bash
# Backup and restore a GPT partition table (invaluable before risky operations)
$ sudo sgdisk --backup=gpt-backup.bin /dev/sdb
$ sudo sgdisk --load-backup=gpt-backup.bin /dev/sdb
```

---

## 4.8 Common Mistakes

- **Operating on the wrong device** — a moment's inattention with `fdisk`/`parted` pointed at `/dev/sda` instead of `/dev/sdb` can destroy a system's boot disk. This is, without exaggeration, one of the most common causes of catastrophic, self-inflicted data loss in Linux administration.
- **Forgetting `partprobe`/a reboot** after repartitioning a disk that's already mounted or in active use, leading to the kernel and the actual on-disk table disagreeing.
- **Mixing MBR assumptions into a GPT world** — e.g., expecting a hard 4-partition limit or worrying about the 2 TiB ceiling on a disk that's actually using GPT.
- **Manually forcing non-default sector alignment** without understanding the underlying physical block size, inadvertently creating the exact misalignment problem the modern defaults are designed to avoid.
- **Deleting and recreating a partition to "resize" it**, discarding the filesystem's own resize tooling (Chapter 5) — this destroys data unless done with extreme care and exact size/offset matching; growing or shrinking a filesystem in place with the correct dedicated tools is almost always the safer path.

---

## 4.9 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| Kernel doesn't see new partition after creation | Stale in-kernel partition table cache | `sudo partprobe /dev/sdX` or reboot |
| `gdisk` reports "invalid main GPT header, but valid backup" | Primary GPT header/table corruption | Let `gdisk` regenerate from backup, then verify with `sgdisk -p` |
| Unexpectedly poor disk performance after partitioning | Partition alignment offset | `cat /sys/block/sdX/sdX1/alignment_offset` (should read `0`) |
| "Partition table is corrupt/invalid" on tool startup | Missing/damaged MBR or GPT structures | Confirm which table type is expected; consider `sgdisk` verify/repair options |
| Disk shows as MBR when GPT was expected (or vice versa) | Wrong tool used to inspect, or table was actually overwritten | Cross-check with `blkid`, `lsblk -o NAME,PTTYPE`, and `gdisk -l` |

> **Security Note:** A disk's partition table is metadata, not the filesystem's own access controls — anyone with root access (or physical access and a live boot medium) can freely delete, resize, or recreate partitions, bypassing whatever permissions exist on the filesystems within. Physical and root-level access control (Chapter 13) is the actual security boundary here, not anything at the partitioning layer itself.

---

*Previous: [03-Block-Devices.md](./03-Block-Devices.md) — Next: 05-Filesystems.md*
