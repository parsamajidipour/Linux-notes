# 7. Persistent Mounts

Chapter 6 covered mounting a filesystem manually, for the current session only. This chapter covers making that mount survive a reboot — the `/etc/fstab` file, the stable identifiers it should reference, and — because this is one of the highest-stakes configuration files on any Linux system — how to recover when it's misconfigured and the system won't boot cleanly.

---

## 7.1 What `/etc/fstab` Does

`/etc/fstab` ("filesystem table") is read early in the boot process by `systemd` (which generates corresponding `.mount` units from it) to determine which filesystems to mount, where, and with what options, before the system reaches a normal login state. It's also consulted by the plain `mount -a` command, which mounts everything listed that isn't already mounted.

```bash
$ cat /etc/fstab
# <file system>                            <mount point>  <type>  <options>          <dump>  <pass>
UUID=3f2504e0-4f89-11d3-9a0c-0305e82c3301   /              ext4    defaults           0       1
UUID=7c9e6679-7425-40de-944b-e07fc1f90ae7   /boot          ext4    defaults           0       2
UUID=A1B2-C3D4                              /boot/efi      vfat    umask=0077         0       1
/dev/mapper/vg0-swap                        none           swap    sw                 0       0
UUID=8f14e45f-ceea-467e-b7b9-e46b95e7f5c0   /home          ext4    defaults,noatime   0       2
```

### 7.1.1 Field-by-Field Breakdown

| Field | Meaning |
|---|---|
| 1. Device/identifier | What to mount — `UUID=`, `LABEL=`, `/dev/...`, or a network path |
| 2. Mount point | Where to mount it (`none` for swap) |
| 3. Filesystem type | `ext4`, `xfs`, `btrfs`, `vfat`, `swap`, or `auto` to let the kernel detect |
| 4. Options | Comma-separated mount options (Chapter 6, Section 6.6) |
| 5. Dump | Legacy `dump` backup utility flag — `1` to include, `0` to skip. Almost universally `0` on modern systems; `dump` itself is rarely used anymore |
| 6. Pass | `fsck` order at boot — `0` = never check, `1` = check first (root only), `2` = check after root, in parallel where possible |

> **Note:** The "dump" field is a historical relic from the `dump`/`restore` backup utility era. Leaving it at `0` is standard practice today; almost no modern system actually uses the `dump` tool.

---

## 7.2 UUID vs. LABEL

As established in Chapter 3, Section 3.2.2, referencing `/dev/sdX` directly in `fstab` is fragile because device names aren't guaranteed stable across boots. `fstab` should reference a **stable identifier** instead — in practice, almost always `UUID=`, sometimes `LABEL=`.

```bash
# Find a filesystem's UUID and label
$ sudo blkid /dev/sda1
/dev/sda1: UUID="3f2504e0-4f89-11d3-9a0c-0305e82c3301" TYPE="ext4" LABEL="rootfs"

# Set (or change) a filesystem label after creation
$ sudo e2label /dev/sda1 rootfs        # ext2/3/4
$ sudo xfs_admin -L rootfs /dev/sdb1   # XFS (must be unmounted)
$ sudo btrfs filesystem label /dev/sdc1 datapool   # Btrfs
```

**When to prefer `UUID=`:** the default, safe choice for nearly all cases — guaranteed unique, generated automatically at `mkfs` time, and immune to human naming mistakes.

**When `LABEL=` can be preferable:** when human readability in configuration files matters (a fleet of similarly-provisioned machines where you want `fstab` to visibly say `LABEL=data` rather than an opaque UUID string), or in imaging/cloning workflows where you deliberately want every cloned system to share a predictable label — though be aware that **cloning a filesystem also clones its UUID**, which can create UUID collisions across multiple disks attached to the same system if not regenerated (see 7.5).

> **Warning:** Never mix `LABEL=` across multiple disks with the same label attached to one system — the resulting ambiguity about which device `fstab` actually means is a real, if less common than UUID collisions, source of boot-time confusion.

---

## 7.3 Boot-Time Mounting Order and Dependencies

`systemd` translates `/etc/fstab` entries into native `.mount` unit files at boot (and you can inspect these directly):

```bash
$ systemctl list-units --type=mount
$ systemctl status home.mount
$ systemd-fstab-generator   # (rarely run manually — mostly for understanding what happens)
```

Mounts under `/`, `/boot`, `/boot/efi`, and swap are considered essential to reaching a normal boot target, and a failure to mount one of these (especially root) can drop the system into an emergency shell rather than completing boot. Non-critical mounts (an optional data drive at `/mnt/archive`, for instance) can be configured with the `nofail` option (7.4) specifically so their absence or failure doesn't block the entire boot process.

---

## 7.4 Common Mount Options Specific to `fstab` Reliability

| Option | Effect |
|---|---|
| `nofail` | Boot continues normally even if this filesystem fails to mount (critical for removable/optional/network drives) |
| `noauto` | Don't automatically mount at boot; only mount when explicitly requested (`mount /mountpoint`) — useful for occasional-use drives |
| `_netdev` | Marks a network filesystem (NFS, CIFS, iSCSI) so systemd waits for network availability before attempting the mount |
| `x-systemd.device-timeout=` | How long to wait for the underlying device to appear before giving up (useful for slow-to-initialize USB/network storage) |
| `x-systemd.mount-timeout=` | How long to wait for the mount operation itself to complete before giving up |

```bash
# A safe fstab entry for an occasionally-attached external drive
UUID=abc123...  /mnt/backup  ext4  defaults,nofail,noauto,x-systemd.device-timeout=10  0  2

# A network filesystem entry
192.168.1.10:/export/data  /mnt/nfs  nfs  defaults,_netdev,nofail  0  0
```

> **Tip:** `nofail` should be considered mandatory for any non-essential mount — an external drive, a secondary data disk, a network share. Without it, a single unavailable or slow-to-initialize device can turn into a full boot failure for the entire machine, which is a disproportionate consequence for what's usually a minor, recoverable hardware/network hiccup.

---

## 7.5 Common Configuration Mistakes

- **Referencing `/dev/sdX` instead of `UUID=`/`LABEL=`**, leading to a mount pointing at the wrong (or a nonexistent) device after a hardware change or reordering.
- **Omitting `nofail` on non-critical mounts**, turning a missing external drive or an unreachable network share into a full boot failure.
- **Typos in the mount point path** — if the directory referenced in field 2 doesn't exist, the mount will simply fail; `systemd` does not create missing mount point directories automatically in most configurations.
- **Wrong filesystem type field** — specifying `ext4` for a partition that's actually XFS (or vice versa) will cause a mount failure at boot.
- **Duplicate UUIDs after disk cloning** — imaging a disk with `dd` or similar block-level cloning duplicates the filesystem's UUID exactly. If both the original and the clone are ever attached to the same system simultaneously, `blkid`/`fstab` resolution becomes ambiguous or unpredictable.

```bash
# Regenerate a new UUID after cloning an ext4 filesystem, to avoid collisions
$ sudo tune2fs -U random /dev/sdc1

# XFS equivalent
$ sudo xfs_admin -U generate /dev/sdc1
```

- **Editing `fstab` and rebooting immediately without testing** — the single riskiest habit related to this file. See 7.7 for the safer pattern.

---

## 7.6 Recovery From a Broken `fstab`

### 7.6.1 Symptoms

A malformed `/etc/fstab` entry — especially one affecting `/`, `/boot`, or `/boot/efi` — commonly manifests as:

- The system drops into an **emergency shell** (`systemd`'s rescue/emergency target) during boot, often with a message like `Failed to mount /mnt/data` or a prompt to "give root password for maintenance."
- Boot hangs for an extended period (waiting on `x-systemd.device-timeout`) before eventually either succeeding degraded or dropping to emergency mode.

### 7.6.2 Recovery Steps

1. **In the emergency shell**, the root filesystem is typically mounted read-only. Remount it read-write first:
   ```bash
   mount -o remount,rw /
   ```
2. **Edit the offending entry** in `/etc/fstab` using any available editor (`vi`/`nano`, whichever is present in the minimal environment):
   ```bash
   vi /etc/fstab
   ```
3. **Comment out or fix the problematic line.** If unsure which line is at fault, comparing against `blkid` output for what devices/UUIDs actually currently exist is the fastest diagnostic:
   ```bash
   blkid
   ```
4. **Test the corrected file without rebooting**, using `mount -a`, which will surface any remaining syntax or resolution errors immediately:
   ```bash
   mount -a
   ```
5. Once `mount -a` completes without error, reboot normally to confirm the fix holds outside the emergency environment.

### 7.6.3 Recovery From a Live/Rescue Boot Medium (Worse-Case Scenario)

If the system won't reach even the emergency shell (e.g., `/boot` itself is misconfigured), boot from a live USB/rescue image instead:

```bash
# Identify and mount the actual root filesystem from the rescue environment
lsblk
mount /dev/sda2 /mnt

# If /boot is a separate partition, mount it too, nested correctly
mount /dev/sda1 /mnt/boot

# Edit fstab from outside the broken system
vi /mnt/etc/fstab

# Optionally, chroot in to run further checks/repairs with the target system's own tools
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
chroot /mnt /bin/bash
```

> **Warning:** Always fix and verify `/etc/fstab` changes with `mount -a` (or equivalent testing) *before* rebooting whenever possible. A broken `fstab` affecting the root filesystem is one of the more common causes of "the server won't come back up" incidents after routine maintenance — and one of the most avoidable, given how cheap it is to test first.

---

## 7.7 Best Practices

- **Always test with `mount -a` after editing `fstab`**, before rebooting, to catch syntax errors and resolution failures in a recoverable state.
- **Use `UUID=` by default**; reserve `LABEL=` for cases with a specific readability or fleet-provisioning rationale, and ensure labels are actually unique across all attached disks.
- **Apply `nofail` to every non-essential mount** — anything that isn't `/`, `/boot`, `/boot/efi`, or swap should almost always have it.
- **Keep a backup of a known-good `/etc/fstab`** before making changes (`cp /etc/fstab /etc/fstab.bak`) — a trivial habit that turns a bad edit into a one-line recovery instead of a rescue-boot exercise.
- **Regenerate UUIDs after block-level disk cloning** to avoid ambiguous device resolution if both source and clone are ever present simultaneously.
- **Document non-obvious mount option choices inline** (a comment line above the entry) — future-you (or a colleague) troubleshooting a boot issue at 3 AM will appreciate knowing *why* a given filesystem is mounted `noexec,nosuid`.

---

## 7.8 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| Boot drops to emergency shell | A non-`nofail` mount in `fstab` failed | Check `journalctl -xb` for the specific failing unit; `blkid` to verify the referenced UUID/device still exists |
| `mount -a` reports "special device ... does not exist" | UUID/LABEL/device referenced in `fstab` no longer matches any actual device | `blkid` to find the current correct identifier; update `fstab` accordingly |
| Mount point exists in `fstab` but nothing is mounted there after boot | Entry has `noauto` set (intentionally, or by mistake) | Check the options field; remove `noauto` if it should mount automatically |
| System hangs for a long time at boot before continuing | `x-systemd.device-timeout` waiting on a slow or absent device | Confirm the device's actual presence; add/adjust `nofail` and timeout options for non-critical mounts |
| Two disks appear to "fight" over the same mount point after cloning | Duplicate UUIDs from block-level cloning | Regenerate UUID on the clone with `tune2fs -U random` / `xfs_admin -U generate` |

---

*Previous: [06-Mounting-Filesystems.md](./06-Mounting-Filesystems.md) — Next: 08-Storage-Management-Tools.md*
