# 8. Storage Management Tools

Previous chapters introduced these tools individually, as needed. This chapter consolidates them into a single reference — what each one is actually for, how they differ from tools that look similar, and practical combined workflows for everyday administration.

---

## 8.1 `lsblk` — List Block Devices

`lsblk` reads from the kernel's live device tree (via `sysfs`), not from `/etc/fstab` or any configuration file, making it the most reliable "what does the system actually see right now" tool for block devices.

```bash
# Default tree view
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda           8:0    0   1.8T  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
├─sda2        8:2    0     1G  0 part /boot
└─sda3        8:3    0   1.8T  0 part
  └─vg0-root 253:0   0    50G  0 lvm  /

# Show filesystem type and UUID
$ lsblk -f

# Show specific columns only
$ lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID

# Include discard/TRIM support info (Chapter 2)
$ lsblk --discard

# Machine-readable output for scripting
$ lsblk -J        # JSON
$ lsblk -P        # key=value pairs, one device per line
```

> **Tip:** `lsblk -f` is usually the fastest single command to run at the start of any storage troubleshooting session — it shows device hierarchy, filesystem type, UUID, and current mount point all at once, immediately orienting you before you reach for more specialized tools.

---

## 8.2 `blkid` — Identify Block Device Attributes

While `lsblk` shows the device hierarchy, `blkid` specializes in filesystem-level metadata — UUID, LABEL, and TYPE — read directly from each device's filesystem superblock.

```bash
# Show all devices with recognized filesystem metadata
$ sudo blkid

# Query a specific device
$ sudo blkid /dev/sda1
/dev/sda1: UUID="3f2504e0-..." TYPE="ext4" PARTUUID="a1b2c3d4-01"

# Extract just one value — useful in scripts
$ sudo blkid -s UUID -o value /dev/sda1
3f2504e0-4f89-11d3-9a0c-0305e82c3301
```

> **Note:** `blkid` maintains an internal cache (`/run/blkid/blkid.tab` on modern systems) for performance. If you've just formatted or relabeled a device and `blkid` still shows stale information, running it as root (which forces a re-scan for uncached/changed devices) or explicitly targeting the device usually resolves it.

---

## 8.3 `df` — Report Filesystem Disk Space Usage

`df` reports space usage per *mounted filesystem*, not per file or directory.

```bash
# Human-readable sizes
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda3        50G   12G   36G  25% /
/dev/sda1       512M  6.1M  506M   2% /boot/efi

# Inode usage (Chapter 5, Section 5.1.2) — a distinct and often-forgotten resource
$ df -i

# Show filesystem type per mount
$ df -hT

# Limit to a specific filesystem type
$ df -h -t ext4
```

> **Warning:** `df` reports space as seen by the filesystem layer, which can be misleading in a few specific situations: a file that's been deleted but is still held open by a running process still counts against used space until the process closes it or exits (see 8.7); on Btrfs, reported "available" space can be non-intuitive due to copy-on-write and multi-device pooling (Chapter 5, Section 5.4); and on thinly-provisioned LVM (Chapter 10), `df` shows the logical volume's nominal size, not necessarily how much physical space is actually still free in the underlying pool.

---

## 8.4 `du` — Estimate File and Directory Space Usage

Where `df` reports per-filesystem totals, `du` walks a directory tree and reports actual space consumed by files and directories within it — the tool you reach for when you know a filesystem is full and need to find *what's* filling it.

```bash
# Human-readable, summarized total for a directory
$ du -sh /var/log

# Show sizes of each immediate subdirectory, sorted largest-first
$ du -h --max-depth=1 /var | sort -rh

# Find the largest directories anywhere under a path
$ du -ah /home | sort -rh | head -20

# Exclude a specific path (useful when a subdirectory is a separate mount you don't want counted twice)
$ du -sh --exclude=/home/user/mnt /home/user
```

> **Tip:** A `du -sh` total and the corresponding `df -h` "used" figure for the same filesystem can legitimately disagree — sparse files, deleted-but-open files (8.7), and hard links (counted multiple times by naive `du` traversal in some edge cases, though modern `du` deduplicates hard links by default) are the usual explanations. When the numbers diverge significantly and unexpectedly, that gap itself is a useful diagnostic clue rather than a tool malfunction.

---

## 8.5 `findmnt` — Query the Mount Tree

Covered in Chapter 6, but worth summarizing here alongside its siblings:

```bash
# Full mount tree
$ findmnt

# Query a specific mount point or device
$ findmnt /home
$ findmnt /dev/sda1

# Verify specific options actually applied
$ findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /

# Validate /etc/fstab against actual system state without mounting anything
$ findmnt --verify
```

`findmnt --verify` in particular is an underused gem: it checks every `fstab` entry for basic sanity (does the referenced device/UUID exist, is the mount point present, are options recognized) without actually attempting to mount anything — a safer first check than `mount -a` when you're not sure an edit is fully correct yet.

---

## 8.6 `mount` — Recap Reference

Covered in depth in Chapter 6. As a quick reference alongside these other tools:

```bash
$ mount                          # list all current mounts
$ sudo mount /dev/sdb1 /mnt/data # mount explicitly
$ sudo mount -a                  # mount everything in fstab not already mounted
```

---

## 8.7 `lsof` and `fuser` — What's Actually Using a Filesystem

These aren't storage-specific tools, but they're essential companions when `df` and reality disagree, or when `umount` reports "busy" (Chapter 6, Section 6.3.1).

```bash
# List open files on a specific filesystem
$ sudo lsof +D /var/log

# Find deleted-but-still-open files — a classic "df says full, du says fine" cause
$ sudo lsof +L1 | grep deleted

# Show which processes are using a mount point
$ sudo fuser -vm /mnt/data
```

> **Warning:** A very common real-world scenario: an application (a log daemon, a database) has a large file open, the file gets deleted (by a log rotation script, a careless `rm`, or manual cleanup), but the underlying disk space is **not** actually freed because the process still holds an open file descriptor to it. `df` will show the space as used; `du` on the visible directory tree will show it as free (because the file no longer has a name/directory entry to walk to). The fix is either to have the holding process close/reopen the file (a log rotation signal, e.g. `SIGHUP`, or a service restart) — not simply recreating a file of the same name.

---

## 8.8 `udevadm` — Device Event and Attribute Inspection

Covered in depth in Chapter 3, Section 3.4.3. Included here for completeness as part of the toolkit:

```bash
$ udevadm info --query=property --name=/dev/sda1
$ udevadm monitor --udev --subsystem-match=block
$ sudo udevadm trigger    # re-trigger rule processing for existing devices
```

---

## 8.9 `smartctl` — Physical Device Health

Introduced in Chapter 2; belongs in the everyday toolkit for proactive monitoring, not just reactive troubleshooting:

```bash
$ sudo smartctl -a /dev/sda            # full SMART report
$ sudo smartctl -H /dev/sda            # quick overall health verdict
$ sudo smartctl -t short /dev/sda      # run a short self-test
```

---

## 8.10 Putting It Together: Common Combined Workflows

### 8.10.1 "The disk is full — what's actually using the space?"

```bash
df -h                          # confirm which filesystem is actually full
df -i                          # rule out inode exhaustion too
du -h --max-depth=1 / | sort -rh   # find the largest top-level consumer
# repeat du -h --max-depth=1 on the largest directory found, drilling down
lsof +L1 | grep deleted        # check for deleted-but-open files as a separate cause
```

### 8.10.2 "A new drive was attached — what is it and is it usable?"

```bash
lsblk -f                       # see it appear, check for existing filesystem/UUID
sudo blkid /dev/sdb            # confirm filesystem type if lsblk was ambiguous
sudo smartctl -H /dev/sdb      # quick health check before trusting it with data
sudo fdisk -l /dev/sdb         # inspect partition table if any
```

### 8.10.3 "I can't unmount a drive"

```bash
findmnt /mnt/data              # confirm it's actually mounted where you think
sudo lsof +D /mnt/data         # find open files
sudo fuser -vm /mnt/data       # find processes with a working directory or handle there
# close/stop the offending process(es), then:
sudo umount /mnt/data
```

### 8.10.4 "Verify a fresh `fstab` edit before rebooting"

```bash
findmnt --verify               # sanity-check syntax and identifier resolution
sudo mount -a                  # actually attempt to mount everything
findmnt                        # confirm final state matches expectations
```

---

## 8.11 Tool Summary Table

| Tool | Primary Purpose | Operates On |
|---|---|---|
| `lsblk` | Device hierarchy, live kernel view | Block devices |
| `blkid` | Filesystem UUID/LABEL/TYPE | Filesystem superblocks |
| `df` | Space usage per mounted filesystem | Mounted filesystems |
| `du` | Space usage per file/directory | Directory trees |
| `findmnt` | Mount tree query and `fstab` validation | Mount table |
| `mount`/`umount` | Attach/detach filesystems | Mount table |
| `lsof`/`fuser` | What's using a file or mount point | Open file descriptors |
| `udevadm` | Device events and attributes | udev/sysfs |
| `smartctl` | Physical device health | Device firmware (SMART) |

---

## 8.12 Common Mistakes

- **Reaching for `du` to answer a "which filesystem is full" question** — that's `df`'s job; `du` answers "what within this tree is using space," a different question.
- **Trusting `du` totals across a directory tree that spans multiple mount points** without `--one-file-system` (`-x`), which can double-count or produce confusing totals by walking into a separately-mounted filesystem nested underneath.
- **Not checking `df -i` when `df -h` shows free space but files still can't be created** (Chapter 5, Section 5.1.2).
- **Forgetting `lsof +L1`/deleted-file checks** when disk usage numbers don't add up, and instead assuming `du`/`df` themselves are buggy.
- **Ignoring `smartctl` until a drive has already failed**, rather than treating it as routine monitoring (Chapter 14 covers proactive monitoring cadence).

```bash
# Restrict du to a single filesystem, avoiding double-counting nested mounts
$ du -sh -x /
```

---

## 8.13 Troubleshooting Quick Reference

| Question | Command |
|---|---|
| What block devices exist right now? | `lsblk -f` |
| What's this device's UUID/label/type? | `blkid /dev/sdX` |
| Which filesystem is full? | `df -h` |
| Is it actually inodes, not space? | `df -i` |
| What's taking up space in this directory? | `du -h --max-depth=1 \| sort -rh` |
| What's actually mounted where? | `findmnt` |
| Is this fstab edit safe before reboot? | `findmnt --verify` then `mount -a` |
| What's holding this mount point busy? | `lsof +D <path>`, `fuser -vm <path>` |
| Is this drive physically healthy? | `smartctl -H /dev/sdX` |
| Did udev actually see this device? | `udevadm monitor --udev` |

---

*Previous: [07-Persistent-Mounts.md](./07-Persistent-Mounts.md) — Next: 09-Swap-Space.md*
