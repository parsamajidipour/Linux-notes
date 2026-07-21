# 14. Troubleshooting Storage

Every prior chapter has included a troubleshooting section scoped to its own layer. This chapter provides the cross-cutting methodology — how to figure out *which layer* a problem actually lives in — plus deeper treatment of the issues that don't belong cleanly to any single chapter: disk-full scenarios, corruption recovery, and SMART-based proactive monitoring.

---

## 14.1 The Layered Diagnostic Method

Recall the storage stack from Chapter 1, Section 1.3. The single most valuable troubleshooting habit is to explicitly identify which layer a symptom points to, rather than guessing at a fix:

```
 Application          → Is the app itself misbehaving, or reporting a storage error?
 VFS / Filesystem      → Is the filesystem mounted, healthy, and has free space/inodes?
 Page Cache             → Is memory pressure or writeback behavior the actual issue?
 Device Mapper (LVM/    → Is an LV, LUKS volume, or RAID array in a healthy state?
   LUKS/RAID)
 Block Layer             → Are I/O errors, queue saturation, or scheduler issues present?
 Device Driver             → Does dmesg show driver-level errors?
 Physical Device             → Is the hardware itself failing (SMART, cabling, power)?
```

A practical way to apply this: start at the bottom (`dmesg`, `smartctl`) and top (application error message) simultaneously, and work toward the middle — hardware-level and application-level symptoms are both relatively quick to rule in or out, and doing so first narrows the remaining search space substantially before diving into filesystem or device-mapper internals.

> **Tip:** `dmesg -T | tail -50` (the `-T` flag gives human-readable timestamps) should be one of the very first commands run for almost any storage problem — kernel-level I/O errors, filesystem warnings, and device disconnects are logged here, often with the most specific and actionable detail available anywhere in the system.

---

## 14.2 Disk Full Scenarios

### 14.2.1 Genuine Space Exhaustion

```bash
df -h                              # confirm which filesystem, and by how much
du -h --max-depth=1 /path | sort -rh   # find the largest consumer, drill down iteratively
```

### 14.2.2 Inode Exhaustion (Chapter 5, Section 5.1.2)

```bash
df -i                              # IUse% at 100% with df -h showing free bytes = inode exhaustion
find /path -xdev | wc -l           # count entries on a specific filesystem to locate the culprit
```

### 14.2.3 Deleted-But-Open Files (Chapter 8, Section 8.7)

```bash
sudo lsof +L1 | grep deleted       # files with zero remaining links but still open
```

### 14.2.4 Reserved Root Space (ext4)

ext4's default 5% root-reserved blocks (Chapter 5, Section 5.2.1) can make `df` report a filesystem as "full" for non-root users while root can still write — a frequent source of confusion when an application running as a non-root user hits ENOSPC despite `df -h` showing what looks like available space, once the reserved margin is accounted for.

```bash
sudo tune2fs -l /dev/sdX | grep -i reserved
```

### 14.2.5 Thin Pool Exhaustion (Chapter 10, Section 10.6)

```bash
sudo lvs -a                        # check Data%/Meta% on the thin pool itself, not just individual LVs
```

> **Warning:** These five causes look identical from an application's point of view ("out of space" or "no space left on device" errors) but require entirely different remedies. Never jump straight to "delete some files" without first confirming *which* of these five is actually occurring — deleting files does nothing for inode exhaustion if the deleted files were large-but-few, and does nothing for thin pool exhaustion if other volumes sharing the pool are the actual consumers.

---

## 14.3 Filesystem Corruption

### 14.3.1 Recognizing Corruption

Common symptoms: mount failures with filesystem-specific error messages, files that suddenly appear as garbage/binary noise, directories that can't be listed, or kernel messages in `dmesg` referencing filesystem-internal structures (bad inode, bad extent, checksum mismatch).

```bash
dmesg -T | grep -iE 'ext4|xfs|btrfs|error|corrupt'
```

### 14.3.2 Repair by Filesystem Type

```bash
# ext4 — must be unmounted (or mounted read-only) first
$ sudo umount /dev/sdb1
$ sudo fsck.ext4 -f -y /dev/sdb1
# -f forces a check even if the filesystem appears clean; -y auto-answers yes to repairs

# XFS — uses a dedicated repair tool, not fsck
$ sudo umount /dev/sdb1
$ sudo xfs_repair /dev/sdb1
# If xfs_repair reports it needs to zero the log first:
$ sudo xfs_repair -L /dev/sdb1    # last resort — can lose recent unwritten transactions

# Btrfs — check first, then repair if needed
$ sudo umount /dev/sdb1
$ sudo btrfs check /dev/sdb1
$ sudo btrfs check --repair /dev/sdb1   # historically riskier; read current docs/warnings first
```

> **Warning:** Filesystem repair tools, by their nature, make destructive decisions about ambiguous or damaged structures — always work from a backup or, at minimum, a block-level image (`dd if=/dev/sdb1 of=/path/to/backup.img bs=4M status=progress`) when data value justifies the extra time, especially before running any repair flagged as "last resort" (like `xfs_repair -L` or `btrfs check --repair`). A repair tool's job is to reach a *consistent* state, not necessarily to preserve every byte of your original data if the two goals conflict.

### 14.3.3 Root Filesystem Corruption

If the corrupted filesystem is the one currently booted from, it generally cannot be unmounted (or safely repaired) while live. Boot from a live/rescue medium instead (Chapter 7, Section 7.6.3 covers the general rescue-boot pattern), then run the appropriate repair tool against the now-unmounted root partition from that external environment.

---

## 14.4 SMART Monitoring

### 14.4.1 Reading SMART Data

```bash
$ sudo smartctl -a /dev/sda
```

Key attributes worth watching (values and interpretation vary somewhat by manufacturer, but these are broadly consistent):

| Attribute | What It Indicates | Concerning Trend |
|---|---|---|
| Reallocated_Sector_Ct | Bad sectors the drive has remapped (HDD) | Any non-zero and climbing value |
| Current_Pending_Sector | Sectors suspected bad, awaiting remap confirmation | Non-zero and climbing |
| Reported_Uncorrectable_Errors | Errors the drive's ECC couldn't correct | Any non-zero value |
| Power_On_Hours | Cumulative operating time | Context for age-adjusted risk assessment, not inherently bad |
| Percentage_Used (NVMe) / Media_Wearout_Indicator (SSD) | Flash write endurance consumed (Chapter 2, Section 2.3.4) | Approaching 100% (or 0% remaining, depending on vendor convention) |
| Temperature_Celsius | Operating temperature | Sustained high values, especially for NVMe under load |

```bash
# Quick pass/fail overall health verdict
$ sudo smartctl -H /dev/sda

# Run a self-test (short = minutes, long/extended = hours, thorough but disruptive to performance meanwhile)
$ sudo smartctl -t short /dev/sda
$ sudo smartctl -t long /dev/sda

# Check self-test results afterward
$ sudo smartctl -l selftest /dev/sda
```

### 14.4.2 Proactive Monitoring, Not Just Reactive Checking

```bash
# smartd — the daemon form of SMART monitoring, running continuous background checks
$ sudo systemctl status smartd
$ cat /etc/smartd.conf
```

A representative `smartd.conf` entry enabling automatic monitoring and email alerts for a device:

```
/dev/sda -a -o on -S on -s (S/../.././02|L/../../6/03) -m admin@example.com
```

> **Tip:** Configure `smartd` on every server with local storage, with alert delivery actually tested end-to-end (not just configured and assumed working) — SMART data is one of the few genuinely predictive signals available for impending hardware failure, and it's routinely underused simply because nobody set up the alerting path, or set it up once and never verified it still worked after an infrastructure change.

---

## 14.5 Mount Failures — Consolidated Diagnostic Flow

Combining Chapters 6 and 7's individual troubleshooting tables into one flow:

1. **Does the device exist at all?** `lsblk`, `dmesg -T | tail`
2. **Does `blkid` recognize a filesystem on it?** `sudo blkid /dev/sdX1` — if empty/unrecognized, the filesystem itself may be missing or severely corrupted.
3. **Is the specified filesystem type correct?** Mismatched `-t` type (manual mount) or wrong type field (`fstab`) causes an immediate, specific mount failure.
4. **Does the mount point directory exist?** A missing target directory causes `mount` to fail outright.
5. **Are there conflicting options or an already-active mount at that path?** `findmnt <path>` to check current state before assuming failure.
6. **Check `journalctl -xe` or `dmesg -T`** for the specific underlying kernel/systemd error — this is almost always the fastest path to a specific, actionable cause rather than guessing.

```bash
$ sudo mount /dev/sdb1 /mnt/data
mount: /mnt/data: wrong fs type, bad option, bad superblock on /dev/sdb1, missing codepage or helper program, or other error.

$ sudo blkid /dev/sdb1     # confirm actual filesystem type first
$ dmesg -T | tail -20      # then check for the specific kernel-level reason
```

---

## 14.6 Common Storage Issues — Quick Reference

| Issue | First Command | Likely Chapter for Deep Dive |
|---|---|---|
| "No space left on device" | `df -h && df -i` | 5, 14.2 |
| Filesystem won't mount | `sudo blkid`, `dmesg -T` | 6, 14.5 |
| Filesystem reports corruption | `dmesg -T \| grep -i error` | 14.3 |
| Drive seems to be failing | `sudo smartctl -a /dev/sdX` | 2, 14.4 |
| RAID array degraded | `cat /proc/mdstat` | 11 |
| LVM won't activate | `sudo vgs`, `sudo lvs`, check `/etc/lvm/archive/` | 10 |
| Swap not activating | `sudo swapon -v` | 9 |
| LUKS volume won't unlock | `sudo cryptsetup luksDump` | 13 |
| Performance degraded unexpectedly | `iostat -x 1`, `fstrim -v` | 12 |
| USB drive disconnecting randomly | `dmesg -T`, check power delivery | 2.6 |

---

## 14.7 Recovery Examples — Worked Scenarios

### 14.7.1 "The root filesystem is reporting errors and won't mount cleanly on next boot"

```bash
# Boot from a live/rescue medium
lsblk                                      # identify the actual root partition
sudo fsck.ext4 -f -y /dev/sda2             # (or xfs_repair, depending on fs type)
# Reboot normally and confirm the fix held
```

### 14.7.2 "A RAID 5 array has one failed drive and I need to replace it"

```bash
cat /proc/mdstat                           # confirm which drive failed
sudo mdadm --manage /dev/md0 --fail /dev/sdc1 --remove /dev/sdc1
# physically replace the drive
sudo mdadm --manage /dev/md0 --add /dev/sdd1
watch cat /proc/mdstat                     # monitor rebuild progress
```

### 14.7.3 "An LVM logical volume was accidentally deleted, but a snapshot still exists"

```bash
sudo lvs -a                                 # confirm the snapshot's current state
sudo lvconvert --merge vg0/lv_data_snap     # merge the snapshot back to restore prior state
# (requires the origin to be inactive/unmounted for the merge to complete cleanly)
```

### 14.7.4 "A misconfigured `fstab` entry is blocking boot"

Covered in full in Chapter 7, Section 7.6 — the emergency-shell `mount -o remount,rw /`, edit, `mount -a` test, reboot pattern.

### 14.7.5 "An SSD suddenly can't be written to, but reads still work"

```bash
sudo smartctl -a /dev/sdX | grep -iE 'wearout|percentage_used'
# If wear is at/near 100%: the drive has hit its write-endurance limit — plan replacement,
# don't attempt further repair; back up any still-readable data immediately.
```

---

## 14.8 Common Mistakes

- **Attempting a fix before identifying the actual failing layer** (14.1) — leads to wasted effort (e.g., running `fsck` when the real problem is a failed drive that `smartctl` would have immediately revealed).
- **Running destructive repair tools without a backup or image first** (14.3.2), when data value justified the extra precaution.
- **Confusing the five distinct "disk full" causes** (14.2) and applying the wrong remedy.
- **Configuring SMART/RAID monitoring but never testing that alerts actually arrive** (14.4.2, 11.4.2) — silent monitoring failure is functionally equivalent to no monitoring at all.
- **Not checking `dmesg -T` early** in a troubleshooting session, missing the most specific and often immediately actionable error detail available.

---

## 14.9 Troubleshooting Meta-Checklist

When facing any storage issue, work through this list before reaching for a specific fix:

1. `dmesg -T | tail -50` — any recent kernel-level errors?
2. `lsblk -f` — does the device tree look as expected?
3. `df -h && df -i` — space or inode exhaustion?
4. `findmnt` — is the mount state what you think it is?
5. `sudo smartctl -H /dev/sdX` — is the underlying hardware healthy?
6. `cat /proc/mdstat` (if RAID is involved) — array healthy?
7. `sudo lvs -a` / `sudo vgs` (if LVM is involved) — volumes and pools healthy?
8. `journalctl -xe` — any relevant systemd-level failure detail?

> **Security Note:** When troubleshooting a system that may have been compromised (rather than simply malfunctioning), be cautious about running write-capable repair tools before preserving forensic evidence — `fsck`/`xfs_repair`/`btrfs check --repair` all modify on-disk state and can destroy evidence of tampering. If compromise is suspected rather than ordinary hardware/software failure, image the affected media first (`dd`) before any repair attempt, and involve appropriate incident-response processes.

---

*Previous: [13-Storage-Security.md](./13-Storage-Security.md) — Next: 15-Best-Practices.md*
