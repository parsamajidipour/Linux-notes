# 5. Filesystems

A partition or block device is just a flat range of addressable blocks — it has no concept of "files," "directories," or "permissions" on its own. A filesystem is the layer of on-disk data structures and kernel logic that imposes that meaning. This chapter covers what a filesystem actually does mechanically, the major filesystems you'll encounter on Linux, and how to choose between them.

---

## 5.1 What Is a Filesystem?

At minimum, every filesystem needs to solve four problems:

1. **Naming**: mapping human-readable paths (`/home/user/file.txt`) to underlying storage locations.
2. **Allocation**: tracking which blocks are free and which are in use, and deciding which blocks to hand out for a new file.
3. **Metadata**: storing attributes about each file — size, timestamps, permissions, ownership, and (crucially) *where its data actually lives* on the block device.
4. **Consistency**: ensuring the on-disk structures remain internally coherent even across crashes, power loss, or concurrent access — this is the entire reason journaling (5.3) exists.

### 5.1.1 Core Building Blocks

Nearly every Linux-native filesystem (ext4, XFS, Btrfs) is built from variations on the same conceptual pieces:

- **Superblock**: a small structure, usually near the start of the filesystem (often mirrored elsewhere too), holding filesystem-wide metadata — total size, block size, free block count, filesystem state (clean/dirty), and pointers to the other core structures.
- **Inode**: a fixed-size record holding all metadata about a single file *except its name* — permissions, ownership, timestamps, size, and pointers to the actual data blocks. A file's name lives in its parent directory's entry, not in the inode itself — which is precisely why hard links work (multiple directory entries can point at the same inode).
- **Data blocks**: the actual file content.
- **Directory entries**: mappings from a filename to an inode number, stored as special-purpose data within a directory "file."
- **Allocation bitmap / B-tree / extent map**: the bookkeeping structure(s) tracking which blocks are free and which files own which blocks.

```
        Directory Entry              Inode                    Data Blocks
        ┌─────────────┐         ┌───────────────┐         ┌───────────┐
        │ "file.txt"   │──────▶ │ inode #12345    │──────▶ │  Block A   │
        │ → inode 12345│         │ perms: 644      │──────▶ │  Block B   │
        └─────────────┘         │ owner: uid 1000 │──────▶ │  Block C   │
                                  │ size: 8192 bytes│         └───────────┘
                                  │ mtime: ...       │
                                  └───────────────┘
```

> **Note:** This is why `ls -l` can show a file's permissions and size without reading its data content at all — that information lives in the inode, which the directory lookup reaches directly. It's also why renaming a file within the same filesystem is instantaneous regardless of file size: only the directory entry changes; the inode and data blocks never move.

### 5.1.2 Inodes and `df -i`

Every filesystem that uses the traditional inode model has a **finite, fixed number of inodes**, decided at filesystem creation time — independent of how much raw block space is free. It is entirely possible to have plenty of free disk space (per `df -h`) while being completely unable to create a new file, because every inode has been consumed — a classic and often confusing failure mode, most common on filesystems storing enormous numbers of very small files (mail spools, certain cache directories).

```bash
$ df -i /
Filesystem     Inodes  IUsed    IFree IUse% Mounted on
/dev/sda1     6553600 6553600       0  100% /
# Notice IFree is 0 even though `df -h` might show plenty of free bytes
```

> **Warning:** "No space left on device" does not always mean the disk is actually full in terms of bytes. Always check `df -i` alongside `df -h` when diagnosing this error — inode exhaustion is a distinct and surprisingly common cause.

---

## 5.2 ext4

### 5.2.1 Overview

ext4 is the direct evolutionary descendant of ext2/ext3, and remains the default filesystem on many mainstream Linux distributions. It's a mature, well-understood, general-purpose journaling filesystem.

Key characteristics:

- **Extent-based allocation**: rather than tracking every individual block (as older ext2/ext3 did), ext4 uses *extents* — a single record describing a contiguous run of blocks ("blocks 1000–1500 belong to this file"), dramatically reducing metadata overhead for large files and improving performance on large sequential writes.
- **Journaling**: metadata (and optionally data) changes are written to a journal before being applied to the main filesystem structures, so a crash mid-write can be recovered by replaying or discarding the incomplete journal entry, rather than requiring a full filesystem scan.
- **Backward/forward compatibility**: ext4 can mount ext2/ext3 filesystems, and many ext4 features can be selectively enabled/disabled, making it a flexible, low-risk default choice.
- **Delayed allocation**: block allocation decisions are deferred until data is actually flushed to disk, allowing the filesystem to make smarter, more contiguous allocation choices, at the cost of a (small) larger data-loss window if the system crashes before flush.

```bash
# Create an ext4 filesystem
$ sudo mkfs.ext4 /dev/sdb1

# Check and repair an ext4 filesystem (must be unmounted, or mounted read-only)
$ sudo fsck.ext4 -f /dev/sdb1

# Tune ext4 parameters (e.g., reserved block percentage)
$ sudo tune2fs -l /dev/sdb1   # list current parameters
$ sudo tune2fs -m 1 /dev/sdb1 # reduce root-reserved space from default 5% to 1%
```

> **Tip:** ext4 reserves 5% of space by default for the root user, originally intended to prevent fragmentation-related performance collapse and to give root headroom to clean up a full disk. On large modern data volumes (multi-TB), 5% can represent a meaningful amount of "wasted" space — reducing it with `tune2fs -m` is common practice for large non-root data volumes, but generally left alone on the root filesystem itself.

### 5.2.2 When to Use ext4

ext4 remains an excellent default for: general-purpose servers, most desktop/workstation installs, and boot/root filesystems where maturity and broad tooling support matter more than cutting-edge features. It has an enormous installed base and correspondingly well-understood failure modes and recovery tooling.

---

## 5.3 XFS

### 5.3.1 Overview

XFS is a high-performance journaling filesystem originally developed by SGI, and is the default root filesystem on Red Hat Enterprise Linux and its derivatives. It was designed from the outset for large files, large filesystems, and high parallel I/O throughput.

Key characteristics:

- **Allocation groups**: XFS internally divides a filesystem into multiple independent allocation groups, each with its own metadata structures, allowing genuinely parallel I/O across CPU cores without a single shared metadata bottleneck — a major reason XFS tends to outperform ext4 on multi-threaded, high-throughput workloads.
- **Excellent large-file and large-filesystem handling**: XFS scales gracefully to very large files and multi-petabyte filesystems.
- **Online operations**: XFS filesystems can be grown while mounted and in active use (`xfs_growfs`) — a significant operational convenience. Notably, **XFS filesystems cannot be shrunk**, only grown; this is a real design trade-off to be aware of when provisioning.
- **Metadata-only journaling by default**: like ext4's default mode, XFS journals metadata, not necessarily file data itself, though this is configurable in ext4's case.

```bash
# Create an XFS filesystem
$ sudo mkfs.xfs /dev/sdb1

# Check filesystem (XFS uses a different repair tool than fsck)
$ sudo xfs_repair /dev/sdb1

# Grow an XFS filesystem online (after growing the underlying partition/LV)
$ sudo xfs_growfs /mount/point
```

> **Warning:** Unlike ext4 and Btrfs, XFS has no supported way to shrink a filesystem in place. If there's a realistic chance a volume will need to shrink later, either provision conservatively, use LVM with room to grow instead of shrink, or choose a filesystem that supports shrinking.

### 5.3.2 When to Use XFS

XFS is a strong choice for: large data volumes, high-throughput parallel workloads (media processing, big-data/analytics storage, large database data directories), and any environment already standardized on RHEL/CentOS/Rocky/Alma, where it's the well-tested default.

---

## 5.4 Btrfs

### 5.4.1 Overview

Btrfs ("B-tree filesystem") is a modern copy-on-write (CoW) filesystem that integrates functionality traditionally handled by separate layers (LVM-style volume management, RAID) directly into the filesystem itself.

Key characteristics:

- **Copy-on-write**: Btrfs never overwrites data in place — a modification always writes to a new location, and metadata pointers are updated atomically to reference the new data. This is the foundation of several of its headline features.
- **Snapshots**: because of CoW, Btrfs can create instantaneous, space-efficient snapshots — a point-in-time, read-only (or writable) view of the filesystem that only consumes additional space as the live filesystem and the snapshot diverge.
- **Built-in checksumming**: Btrfs checksums both data and metadata, allowing it to detect silent data corruption ("bit rot") that a traditional filesystem would simply miss.
- **Built-in multi-device support**: Btrfs can natively span multiple block devices and provides RAID-like redundancy (RAID0/1/10, with RAID5/6 support historically considered less mature/production-ready — worth checking current kernel documentation before relying on it) without needing `mdadm` or LVM underneath.
- **Subvolumes**: independently mountable, independently snapshottable namespaces within a single Btrfs filesystem — useful for separating, e.g., `/` and `/home` logically while sharing the same underlying pool of space.

```bash
# Create a Btrfs filesystem
$ sudo mkfs.btrfs /dev/sdb1

# Create a subvolume
$ sudo btrfs subvolume create /mnt/mysubvol

# Create a snapshot of the root subvolume
$ sudo btrfs subvolume snapshot / /.snapshots/pre-upgrade-2026-07-20

# Check filesystem usage (Btrfs reports space differently than df, due to CoW and multi-device pooling)
$ sudo btrfs filesystem usage /mnt/data

# Scrub — verify checksums across the entire filesystem and repair from redundancy if available
$ sudo btrfs scrub start /mnt/data
```

> **Tip:** Btrfs snapshots are the mechanism behind tools like Snapper and the "roll back after a bad update" capability on distributions like openSUSE. A pre-upgrade snapshot taken in under a second, at minimal space cost, is one of the most practically useful features available on any Linux filesystem today — strongly consider it for root filesystems on systems where quick rollback matters.

### 5.4.2 When to Use Btrfs

Btrfs is a strong choice when snapshotting, built-in data integrity checking, or native multi-device pooling are directly valuable to your use case — desktop/workstation root filesystems with rollback support, NAS-style multi-disk pools, or any environment where silent data corruption detection is a real concern. It carries somewhat more operational complexity than ext4/XFS, and (as noted above) certain RAID levels have historically had stability caveats worth checking against current documentation before production use.

---

## 5.5 FAT32, exFAT, and NTFS (Cross-Platform Filesystems)

These are not Linux-native filesystems, but you'll encounter them constantly — USB drives, EFI System Partitions, and any media meant to be read by Windows or macOS as well as Linux.

### 5.5.1 FAT32

- Extremely widely compatible — readable by virtually every OS and device (cameras, embedded systems, game consoles, router firmware).
- **4 GiB maximum individual file size** and a **practical volume size ceiling of ~2 TiB** — a real limitation for modern large media files.
- No permissions, no journaling, no support for Linux-native ownership/permission metadata.
- Required by the UEFI specification for the **EFI System Partition (ESP)** — this is the one place FAT32 remains essentially mandatory on modern Linux systems, regardless of what filesystem the rest of the system uses.

### 5.5.2 exFAT

- Designed as FAT32's successor for removable media — no 4 GiB file size limit, better suited to large modern files (video, disk images).
- Still lacks POSIX permissions and journaling.
- Now has mature open-source Linux support (`exfatprogs`/`exfat-utils`, kernel driver merged upstream) — no longer requires proprietary or FUSE-based drivers as it once did.
- Good default choice for a USB drive that needs to move large files between Linux, Windows, and macOS.

### 5.5.3 NTFS

- Windows' native filesystem; Linux support is provided via the `ntfs3` in-kernel driver (modern kernels) or the older FUSE-based `ntfs-3g`.
- Supports large files, journaling, and a permissions model — but that permissions model is Windows ACL-based, not POSIX-native, so interoperability with Linux permissions is imperfect.
- Useful for dual-boot systems where a shared data partition needs full read/write access from both Windows and Linux.

```bash
# Format a USB drive as exFAT — good general-purpose cross-platform choice today
$ sudo mkfs.exfat /dev/sdb1

# Mount an NTFS partition (modern kernels with ntfs3 support this natively)
$ sudo mount -t ntfs3 /dev/sdb1 /mnt/windows
```

> **Note:** None of FAT32, exFAT, or NTFS are appropriate choices for a Linux root filesystem, `/home`, or any Linux-native data directory that depends on POSIX permissions, symlinks, device nodes, or journaling behavior matched to Linux workloads. Reserve them for interoperability scenarios: removable media, the ESP, and dual-boot data-sharing partitions.

---

## 5.6 Choosing the Right Filesystem

| Requirement | Recommended Filesystem |
|---|---|
| General-purpose root/server filesystem, maximum maturity | ext4 |
| Large files, high-throughput parallel I/O, big data volumes | XFS |
| Snapshots, built-in checksumming, multi-device pooling | Btrfs |
| Maximum cross-platform removable media compatibility (older devices) | FAT32 |
| Cross-platform removable media, large file support | exFAT |
| Dual-boot shared data partition with Windows | NTFS |
| EFI System Partition | FAT32 (required by UEFI spec) |

### 5.6.1 Filesystem Comparison Table

| Feature | ext4 | XFS | Btrfs | FAT32 | exFAT | NTFS |
|---|---|---|---|---|---|---|
| Journaling | Yes | Yes | CoW (no traditional journal needed) | No | No | Yes |
| Max file size | 16 TiB | 8 EiB | 16 EiB | 4 GiB | 16 EiB (spec) | 16 TiB (practical) |
| Max volume size | 1 EiB | 8 EiB | 16 EiB | ~2 TiB (practical) | 128 PiB (spec) | 256 TiB |
| Online resize (grow) | Yes | Yes | Yes | No | No | Limited |
| Online resize (shrink) | Offline only | **No** | Yes | No | No | Limited (Windows tools) |
| Snapshots | No (native) | No (native) | **Yes** | No | No | Yes (VSS, Windows-side) |
| Checksumming (data) | No | No | **Yes** | No | No | No |
| Native multi-device/RAID | No | No | **Yes** | No | No | No |
| POSIX permissions | Yes | Yes | Yes | No | No | Partial (ACL-based) |
| Linux support maturity | Very high | Very high | High, actively evolving | Universal | High | High (via ntfs3) |
| Best fit | General purpose | Large/parallel I/O | Snapshots/integrity | Legacy removable media | Modern removable media | Windows interop |

---

## 5.7 Common Mistakes

- **Choosing XFS for a volume that will need to shrink later**, then discovering there's no supported shrink path and having to recreate the filesystem entirely.
- **Formatting a Linux-only data volume as NTFS or exFAT "just to be safe,"** losing POSIX permissions, symlink support, and journaling behavior tuned for Linux workloads, for no actual cross-platform benefit.
- **Ignoring inode exhaustion** (`df -i`) when diagnosing "disk full" errors on filesystems with huge numbers of small files.
- **Assuming Btrfs RAID5/6 has the same maturity/safety guarantees as traditional RAID5/6** — always check current documentation and known caveats before relying on it for production redundancy.
- **Not testing snapshot/rollback procedures (Btrfs) before relying on them in an incident** — a snapshot you've never actually restored from is an untested backup.

---

## 5.8 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| "No space left on device" with `df -h` showing free space | Inode exhaustion | `df -i` |
| ext4 filesystem won't mount, reports errors | Filesystem inconsistency, likely from an unclean shutdown | `sudo fsck.ext4 -f /dev/sdX` (unmounted) |
| XFS filesystem reports corruption | Metadata inconsistency | `sudo xfs_repair /dev/sdX` (unmounted) |
| Btrfs reports checksum errors | Silent data corruption detected | `sudo btrfs scrub start` then `btrfs scrub status`; check for redundancy to auto-repair from |
| Can't shrink an XFS filesystem | Not supported by design | Back up data, recreate filesystem at desired size, restore |
| Filesystem mounted from Windows shows permission oddities on Linux | NTFS ACL model vs POSIX mismatch | Consider explicit `uid=`/`gid=`/`umask=` mount options |

> **Security Note:** FAT32, exFAT, and NTFS (via `ntfs-3g`/`ntfs3`) do not enforce Linux-native ownership and permission semantics the way ext4/XFS/Btrfs do — files on a mounted FAT32/exFAT volume typically appear owned by whichever `uid`/`gid` was specified (or defaulted) at mount time, regardless of any per-file metadata, because none exists. Never rely on filesystem-level permissions for access control on non-POSIX filesystems; enforce access control at the mount point (who can mount it, mount options like `uid=`, `gid=`, `umask=`) or at the application layer instead.

---

*Previous: [04-Disk-Partitioning.md](./04-Disk-Partitioning.md) — Next: 06-Mounting-Filesystems.md*
