# 3. Block Devices

Chapter 2 covered the physical hardware. This chapter covers how the Linux kernel represents that hardware to the rest of the system — the naming conventions, the numbering scheme underneath those names, and the event-driven mechanism (`udev`) that turns a piece of hardware you just plugged in into a usable `/dev` entry within milliseconds.

---

## 3.1 What `/dev` Actually Is

`/dev` is not a regular directory full of regular files sitting on disk. It's populated by **devtmpfs**, a special in-kernel filesystem that exists only in RAM and is rebuilt fresh every boot, reflecting whatever hardware the kernel has currently detected. When you plug in a USB drive and a new entry like `/dev/sdb` appears, nothing was "written to disk" — the kernel created an in-memory device node and `udev` (Section 3.4) decorated it with permissions, ownership, and convenience symlinks.

```bash
$ mount | grep devtmpfs
devtmpfs on /dev type devtmpfs (rw,nosuid,size=8131824k,nr_inodes=...)
```

Each entry under `/dev` is either a **block device node** or a **character device node** (Chapter 1, Section 1.4), and each node is really just a pointer, made of two numbers, to a specific driver and device instance — covered in 3.3.

> **Note:** Because `/dev` is rebuilt at every boot from live kernel state, entries are not guaranteed to be assigned to the same name on every boot — this is precisely the problem that motivated the `/dev/disk/by-*` symlink scheme covered in 3.2, and the reason `/etc/fstab` should almost never reference raw device names directly (Chapter 7).

---

## 3.2 Device Naming Conventions

### 3.2.1 Traditional Naming

| Prefix | Device Type | Example |
|---|---|---|
| `sd` | SCSI/SATA/USB block devices (via the SCSI subsystem, which SATA and USB storage both go through) | `/dev/sda`, `/dev/sdb` |
| `nvme` | NVMe devices | `/dev/nvme0n1` |
| `vd` | Virtio block devices (common in KVM/QEMU virtual machines) | `/dev/vda` |
| `xvd` | Xen virtual block devices | `/dev/xvda` |
| `mmcblk` | MMC/SD card storage (common on embedded/ARM systems) | `/dev/mmcblk0` |
| `loop` | Loopback devices (a regular file exposed as a block device) | `/dev/loop0` |
| `md` | Software RAID arrays (via `mdadm`) | `/dev/md0` |
| `dm` | Device-mapper devices (LVM, LUKS, etc.) | `/dev/dm-0` |

For `sd`-prefixed devices, naming follows detection order: the first detected disk is `sda`, the second `sdb`, and so on, continuing `sdz`, `sdaa`, `sdab`, etc. if you somehow have more than 26 disks.

**Partition numbers** are appended after the device name: `/dev/sda1` is the first partition on `sda`. NVMe naming inserts a `p` before the partition number to disambiguate from the namespace number: `/dev/nvme0n1p1` is the first partition on namespace 1 of controller 0.

```
/dev/sda1
    │  └┴─ partition number
    │└─ disk letter (2nd disk = b, 3rd = c, ...)
    └── SCSI/SATA/USB block device

/dev/nvme0n1p1
     │   │  │└─ partition number
     │   │  └── "p" separator (avoids ambiguity with namespace number)
     │   └── namespace number
     └── controller number
```

> **Warning:** Traditional `sdX` naming is assigned by *detection order*, which depends on things like boot timing, USB enumeration order, and controller initialization order — none of which are guaranteed stable across reboots, especially with multiple disks or hot-pluggable storage. Never hard-code `/dev/sda1` in `/etc/fstab`, boot configuration, or scripts meant to survive a reboot. This is the single most common cause of "server won't boot after I added a disk." Use the stable identifiers in 3.2.2 instead.

### 3.2.2 Stable Identifiers: `/dev/disk/by-*`

To solve the instability problem above, `udev` maintains a set of symlink directories under `/dev/disk/`, each identifying devices by a property that doesn't depend on detection order:

```bash
$ ls -l /dev/disk/by-uuid/
lrwxrwxrwx 1 root root 10 Jul 20 09:00 3f2504e0-... -> ../../sda1

$ ls -l /dev/disk/by-label/
lrwxrwxrwx 1 root root 10 Jul 20 09:00 root-fs -> ../../sda1

$ ls -l /dev/disk/by-id/
lrwxrwxrwx 1 root root  9 Jul 20 09:00 ata-Samsung_SSD_980_PRO_2TB_S6... -> ../../sda

$ ls -l /dev/disk/by-path/
lrwxrwxrwx 1 root root  9 Jul 20 09:00 pci-0000:00:17.0-ata-1 -> ../../sda
```

| Scheme | Based On | Survives Reboot? | Survives Reformat? | Survives Hardware Move? |
|---|---|---|---|---|
| `by-uuid` | Filesystem UUID, generated at `mkfs` time | Yes | No (new UUID) | Yes |
| `by-label` | Filesystem label, user-assigned | Yes | No (unless relabeled) | Yes |
| `by-id` | Device serial number/model | Yes | Yes | Yes (unless the physical device itself changes) |
| `by-path` | Physical bus topology (PCI address, port) | Yes | Yes | **No** — tied to the physical slot/port |

> **Tip:** For `/etc/fstab` entries, `UUID=` is the conventional and most robust choice for most cases (Chapter 7 covers this exhaustively). `by-id` is particularly useful when you need to be certain you're referring to one *specific physical drive*, independent of filesystem state — for example, when assembling a RAID array or identifying a drive to physically remove.

---

## 3.3 Major and Minor Numbers

Every device node — block or character — is identified internally by a pair of numbers: the **major number** and the **minor number**.

- **Major number**: identifies which driver handles the device. All `sd`-prefixed SCSI disk devices historically share major number 8; all NVMe namespaces use major numbers in the 259+ range (or dynamically allocated); the `loop` driver has its own dedicated major number, and so on.
- **Minor number**: identifies the *specific instance* of a device that major number's driver is responsible for — which physical disk, and which partition on it.

```bash
$ ls -l /dev/sda /dev/sda1 /dev/sdb
brw-rw---- 1 root disk 8,  0 Jul 20 09:00 /dev/sda
brw-rw---- 1 root disk 8,  1 Jul 20 09:00 /dev/sda1
brw-rw---- 1 root disk 8, 16 Jul 20 09:00 /dev/sdb
```

Here, `8, 0` means major 8 (the `sd` driver), minor 0 (the first whole disk). `8, 1` is the first partition on that same disk (minor numbers for SCSI disks are traditionally allocated in blocks of 16 per physical disk — hence `sdb`, the second disk, starts at minor 16).

You can look up the kernel's registered major number assignments directly:

```bash
$ cat /proc/devices | head -15
Character devices:
  1 mem
  4 /dev/vc/0
  ...
Block devices:
  7 loop
  8 sd
259 blkext
```

**Why this matters practically:** this is largely invisible in day-to-day administration because `udev` and the naming scheme in 3.2 abstract it away — but it becomes directly relevant when troubleshooting at a low level (e.g., correlating a kernel error message that references a major:minor pair back to an actual device name), when working with device-mapper internals (`dm-0`, `dm-1`, ...), or when creating device nodes manually with `mknod` (rare, but occasionally necessary in minimal/container/chroot environments).

```bash
# Manually create a block device node (rarely needed directly — mostly for illustration)
$ sudo mknod /dev/mydevice b 8 0
```

---

## 3.4 udev: The User-Space Device Manager

### 3.4.1 What udev Does

`udev` is the user-space daemon (`systemd-udevd` on modern systemd-based distributions — udev's functionality was merged into systemd) responsible for:

1. Listening for kernel **uevents** — notifications the kernel emits whenever a device is added, removed, or changed.
2. Applying a rule-based system to decide what to *do* about that event: what permissions and ownership to assign, what symlinks to create, what additional actions to trigger (like automatically loading a kernel module, or running a custom script).
3. Actually creating (or removing) the corresponding entries in `/dev`.

```
   Kernel detects device
            │
            ▼
      uevent emitted (via netlink socket)
            │
            ▼
    systemd-udevd receives event
            │
            ▼
    Rules evaluated (/etc/udev/rules.d/, /usr/lib/udev/rules.d/)
            │
            ▼
    Device node created/updated + symlinks + permissions applied
```

### 3.4.2 udev Rules

Rules live in `.rules` files, processed in lexical order across `/usr/lib/udev/rules.d/` (package-provided defaults) and `/etc/udev/rules.d/` (local overrides — always prefer this directory for your own custom rules, since it takes precedence and survives package upgrades).

A simplified example rule that assigns a fixed, friendly symlink to a specific USB drive identified by its serial number:

```
# /etc/udev/rules.d/99-backup-drive.rules
SUBSYSTEM=="block", ATTRS{serial}=="WD-BACKUP-SERIAL-1234", SYMLINK+="backup_drive"
```

After this rule is in place, that specific physical drive will always be reachable at `/dev/backup_drive`, regardless of whether the kernel happens to enumerate it as `sdb` or `sdc` on a given boot.

```bash
# Reload rules after editing, without rebooting
$ sudo udevadm control --reload-rules
$ sudo udevadm trigger
```

### 3.4.3 Inspecting Device Attributes

`udevadm` is the primary tool for both writing rules and debugging device detection:

```bash
# Dump every udev/sysfs attribute known about a device — invaluable when writing rules
$ udevadm info --attribute-walk --name=/dev/sdb

# Query specific properties directly
$ udevadm info --query=property --name=/dev/sdb
ID_SERIAL=WD-BACKUP-SERIAL-1234
ID_FS_TYPE=ext4
ID_FS_UUID=3f2504e0-4f89-11d3-9a0c-0305e82c3301

# Watch device events live — extremely useful when a device isn't appearing as expected
$ sudo udevadm monitor --udev --subsystem-match=block
```

> **Tip:** `udevadm monitor` is one of the most underused diagnostic tools for storage problems. If a USB drive or a hot-plugged disk isn't showing up where you expect, run `udevadm monitor` in one terminal and physically re-attach the device — you'll see in real time exactly which events fire (or don't), which immediately tells you whether the problem is hardware/kernel detection (no event at all) or a udev rule/naming issue (event fires, but the expected symlink doesn't appear).

---

## 3.5 Device Discovery Process — Full Walkthrough

Bringing together Chapter 1's overview and this chapter's detail, here is the complete sequence from physical attachment to a usable device node, for a hot-plugged SATA/USB drive:

1. **Physical/electrical detection**: the bus controller (SATA host controller, USB host controller) detects a new device signal.
2. **Bus enumeration**: the appropriate kernel subsystem (`libata` for SATA, `usb-storage` or UAS for USB) identifies the device, negotiates link parameters, and reads basic identifying information from the device itself.
3. **SCSI layer registration**: both SATA and USB storage are presented to the kernel through the SCSI subsystem (a historical but still-current abstraction — this is why both show up as `sdX`). The SCSI layer probes the device (`INQUIRY` command) to learn vendor, model, and capacity.
4. **Block device object creation**: the kernel creates the internal block device structure and a corresponding entry appears under `/sys/block/`.
5. **uevent emission**: a `KERNEL[...] add` uevent is broadcast over a netlink socket.
6. **udev rule processing**: `systemd-udevd` receives the event, walks the applicable rules, and:
   - Creates `/dev/sdX`.
   - Reads the partition table (if any) and creates `/dev/sdX1`, `/dev/sdX2`, etc.
   - Runs filesystem-probing helpers (`blkid`-equivalent logic) to detect filesystem type, UUID, and label.
   - Creates the corresponding `/dev/disk/by-uuid/`, `/dev/disk/by-label/`, `/dev/disk/by-id/`, and `/dev/disk/by-path/` symlinks.
   - Applies permissions/group ownership (commonly group `disk`).
7. **Downstream reactions**: if `udisks2` is running (common on desktop systems) or if automount rules are configured, the newly available filesystem may be automatically mounted at this point. On servers, this step is typically absent — mounting is handled explicitly via `/etc/fstab` or manual `mount` commands (Chapters 6–7).

```bash
# Watch this entire sequence happen live
$ sudo udevadm monitor --udev --kernel --subsystem-match=block &
# ... now physically plug in a USB drive ...

KERNEL[1234.567] add /devices/.../sdb (block)
KERNEL[1234.568] add /devices/.../sdb/sdb1 (block)
UDEV [1234.610] add /devices/.../sdb (block)
UDEV [1234.615] add /devices/.../sdb/sdb1 (block)
```

Notice the two passes: `KERNEL` events fire first (raw kernel notification), then `UDEV` events fire slightly later, after `systemd-udevd` has finished processing rules for that device — this gap, though usually just milliseconds, is why scripts that react to device attachment should generally hook into `udev` rules rather than trying to race the raw kernel event.

---

## 3.6 Practical Examples

```bash
# List all block devices in a tree, showing type and mountpoint
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda           8:0    0   1.8T  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
├─sda2        8:2    0     1G  0 part /boot
└─sda3        8:3    0   1.8T  0 part
  └─vg0-root 253:0   0    50G  0 lvm  /

# Show major:minor numbers explicitly
$ lsblk -o NAME,MAJ:MIN,SIZE,TYPE

# Identify what filesystem (if any) is on a partition
$ sudo blkid /dev/sda3
/dev/sda3: UUID="a1b2c3d4-..." TYPE="LVM2_member"

# Find which physical device a mounted path lives on
$ findmnt /
TARGET SOURCE           FSTYPE OPTIONS
/      /dev/mapper/vg0-root ext4   rw,relatime
```

---

## 3.7 Common Mistakes

- **Hard-coding `/dev/sdX` names** in `fstab`, scripts, or documentation, then being surprised when disk order changes after a hardware change or kernel update.
- **Editing rules in `/usr/lib/udev/rules.d/` instead of `/etc/udev/rules.d/`** — package updates will silently overwrite changes in the former.
- **Forgetting to reload rules** (`udevadm control --reload-rules && udevadm trigger`) after editing a rule file and then concluding the rule "doesn't work."
- **Confusing `by-path` with `by-id`** — `by-path` changes if you move a drive to a different physical port/slot, which is rarely what you actually want for identifying a specific disk.
- **Assuming a missing `/dev/sdX` means hardware failure**, without first checking `dmesg` and `udevadm monitor` to see whether the kernel even detected the device at all — the fault could be anywhere from a bad cable to a udev rule conflict.

---

## 3.8 Troubleshooting

| Symptom | Diagnostic Command | What to Look For |
|---|---|---|
| New drive not appearing at all | `dmesg \| tail -40` | Any kernel-level detection or error messages |
| Drive detected by kernel but no `/dev` node | `udevadm monitor --udev` while re-plugging | Whether a `UDEV` event actually fires |
| Expected `/dev/disk/by-*` symlink missing | `udevadm info --query=property --name=/dev/sdX` | Whether `ID_FS_UUID`/`ID_SERIAL` etc. were populated |
| Custom udev rule not applying | `udevadm test /sys/class/block/sdX` (dry-run) | Which rules matched, in what order, and the final decided attributes |
| Device name changed after reboot, breaking a mount | Check whether `/etc/fstab` uses `/dev/sdX` instead of `UUID=`/`LABEL=` | Migrate to a stable identifier |

> **Security Note:** udev rules can execute arbitrary commands (`RUN+="..."`) in response to device events, including as root. Treat `/etc/udev/rules.d/` as a privileged configuration surface — a malicious or careless rule that triggers on `ACTION=="add"` for any block device can be a real local-privilege or persistence vector. Review third-party udev rules (bundled with some hardware vendor tools) with the same scrutiny you'd give a setuid binary or a systemd unit running as root.

---

*Previous: [02-Physical-Storage-Devices.md](./02-Physical-Storage-Devices.md) — Next: 04-Disk-Partitioning.md*
