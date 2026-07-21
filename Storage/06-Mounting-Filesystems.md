# 6. Mounting Filesystems

A formatted partition sitting idle isn't accessible to applications until it's **mounted** — attached at a specific point in the single, unified Linux directory tree. This chapter covers the mechanics of mounting and unmounting, mount points, bind mounts, and the mount options that shape how a filesystem behaves once attached. Persistent (boot-time) mounting via `/etc/fstab` is covered separately in Chapter 7.

---

## 6.1 The Unified Directory Tree Concept

Unlike Windows, where each storage volume gets its own drive letter (`C:`, `D:`, `E:`), Linux presents **one single directory tree** rooted at `/`, regardless of how many physical devices, partitions, or filesystems are actually involved. Additional filesystems don't get a new top-level identity — they get **grafted into** the existing tree at a chosen directory, called the **mount point**.

```
                         /
                         │
        ┌────────┬───────┼───────┬─────────┐
        │        │        │        │         │
      /boot     /home    /var    /tmp      /mnt/backup
        │        │        │        │         │
   (own fs)  (own fs)  (own fs)  (tmpfs)  (own fs, external drive)
```

**Why this matters:** from an application's or user's point of view, `/home/user/document.txt` looks like an ordinary path — nothing about it reveals that `/home` might be on an entirely separate physical disk, a separate filesystem type, or even a network share (NFS, CIFS). This transparency is powerful, but it also means the exact same path can point at wildly different underlying storage depending on what's currently mounted where — a source of real confusion during troubleshooting if you forget to check `findmnt`/`mount` output.

---

## 6.2 The `mount` Command

### 6.2.1 Basic Usage

```bash
# Basic mount — filesystem type is usually auto-detected
$ sudo mount /dev/sdb1 /mnt/data

# Explicitly specify filesystem type (useful when auto-detection is ambiguous, or required)
$ sudo mount -t ext4 /dev/sdb1 /mnt/data

# Mount with specific options
$ sudo mount -t ext4 -o ro,noatime /dev/sdb1 /mnt/data

# Mount by UUID instead of device name (Chapter 3, Section 3.2.2)
$ sudo mount UUID=3f2504e0-4f89-11d3-9a0c-0305e82c3301 /mnt/data
```

### 6.2.2 What `mount` Actually Does

At the kernel level, mounting attaches a filesystem's root directory to an existing directory (the mount point) in the current namespace. Everything below that point in the tree is now served by the newly mounted filesystem; whatever was previously visible at that path (if the mount point directory wasn't empty) becomes temporarily hidden — not deleted, just inaccessible until the filesystem is unmounted again.

> **Warning:** Mounting over a non-empty directory doesn't warn you by default, and the original contents are not deleted — they're simply obscured for as long as the mount is active. This has caused real confusion (and occasionally real data-loss scares) when someone mounts a new filesystem onto an existing directory with files in it, "loses" those files, panics, and only later realizes they're still there, just hidden beneath the new mount.

### 6.2.3 Viewing Current Mounts

```bash
# Simple listing
$ mount | column -t

# Cleaner, more script-friendly view
$ findmnt

# Filter to a specific mount point or device
$ findmnt /home
$ findmnt /dev/sdb1

# Kernel's live view (the authoritative source — /proc/mounts)
$ cat /proc/mounts
```

> **Tip:** `findmnt` is generally preferable to raw `mount` output for troubleshooting — it presents a cleaner tree view, supports filtering, and can show you mount option inheritance for nested/bind mounts far more clearly than parsing `mount`'s output by hand.

---

## 6.3 `umount`

```bash
# Unmount by mount point
$ sudo umount /mnt/data

# Unmount by device
$ sudo umount /dev/sdb1

# Lazy unmount — detaches immediately, cleans up once no longer busy
$ sudo umount -l /mnt/data

# Force unmount (primarily relevant for unresponsive network filesystems)
$ sudo umount -f /mnt/nfs-share
```

### 6.3.1 "Device Is Busy"

The most common `umount` failure is `target is busy`, meaning some process still has an open file handle, a working directory, or a memory-mapped file on that filesystem.

```bash
# Identify what's using the mount point
$ sudo lsof +D /mnt/data
$ sudo fuser -vm /mnt/data

# Kill the offending processes (careful — understand what you're killing first)
$ sudo fuser -k /mnt/data
```

> **Warning:** `umount -l` (lazy unmount) detaches the filesystem from the directory tree immediately, but the actual underlying device isn't released until all references clear — this can create a confusing state where the mount point appears unmounted but the device is still technically busy underneath. Prefer identifying and closing the actual open handles (`lsof`, `fuser`) over reaching for `-l`/`-f` by default, especially on filesystems containing important data mid-write.

---

## 6.4 Bind Mounts

A **bind mount** attaches an existing directory (or file) to a second location in the tree — not a new filesystem, but a second view into part of an already-mounted one.

```bash
# Make /var/www/uploads also accessible at /srv/shared/uploads
$ sudo mount --bind /var/www/uploads /srv/shared/uploads

# Read-only bind mount — a common pattern for safely exposing data into a container/chroot
$ sudo mount --bind /var/www/uploads /srv/shared/uploads
$ sudo mount -o remount,bind,ro /srv/shared/uploads
```

**Why bind mounts are useful:**

- **Container/chroot environments**: exposing a specific host directory inside a restricted filesystem view without exposing the entire host filesystem.
- **Reorganizing paths without moving data**: making the same data accessible under two different paths, useful during migrations or when legacy paths still need to work.
- **Backup tooling**: some backup workflows bind-mount a directory into a snapshot-friendly location.

```
    /var/www/uploads  ──────bind mount──────▶  /srv/shared/uploads
         (original)                                  (same inode/data,
                                                        second path)
```

> **Note:** A bind mount is *not* a symlink. It operates at the kernel's VFS layer, and behaves identically to the original for all purposes (permissions checks still apply to the actual underlying files, not the bind mount path itself) — this makes it far more robust than a symlink for use inside restricted environments like chroots and containers, where symlink targets outside the restricted root often can't be resolved at all.

---

## 6.5 Temporary Mounts

Not every mount corresponds to a persistent block device. Several special-purpose filesystem types are commonly mounted temporarily, in RAM or as views into kernel state:

```bash
# tmpfs — a RAM-backed filesystem; contents vanish on unmount/reboot
$ sudo mount -t tmpfs -o size=512M tmpfs /mnt/scratch

# Mounting an ISO image as a loopback device
$ sudo mount -o loop image.iso /mnt/iso

# Mounting a disk image file (e.g., for inspecting a VM disk)
$ sudo mount -o loop,offset=1048576 disk.img /mnt/vm-partition
```

`/tmp` on many modern distributions is itself a `tmpfs` mount by default — fast, but its contents don't survive a reboot and its capacity is bounded by available RAM (plus swap, if the system falls back to it), which is worth knowing before writing anything large or important to `/tmp`.

> **Tip:** Mounting an image file with an `offset=` option (as shown above) is genuinely useful when you need to inspect a specific partition inside a raw disk image without first extracting it — you just need to calculate the byte offset of that partition's start sector (sector number × sector size).

---

## 6.6 Common Mount Options

| Option | Effect |
|---|---|
| `ro` | Mount read-only |
| `rw` | Mount read-write (default) |
| `noexec` | Prevent execution of binaries from this filesystem |
| `nosuid` | Ignore SUID/SGID bits on this filesystem |
| `nodev` | Ignore device files on this filesystem |
| `noatime` | Don't update file access-time on every read (notable performance win on busy filesystems) |
| `relatime` | Update access-time only when it's older than the modify/change time (modern default — good balance) |
| `sync` | All writes are applied synchronously (safer, much slower) |
| `async` | Writes are buffered/cached normally (default) |
| `defaults` | Shorthand for `rw,suid,dev,exec,auto,nouser,async` — the typical baseline |
| `remount` | Change options on an already-mounted filesystem without unmounting |
| `uid=`, `gid=` | Force ownership on filesystems without native POSIX permissions (FAT32/exFAT/NTFS) |
| `discard` | Issue inline TRIM on delete (Chapter 2, Section 2.3.2) |

```bash
# Combine multiple hardening-relevant options — a common pattern for /tmp
$ sudo mount -t tmpfs -o size=1G,noexec,nosuid,nodev tmpfs /tmp

# Change mount options in place without unmounting
$ sudo mount -o remount,ro /mnt/data
```

> **Security Note:** `noexec,nosuid,nodev` on filesystems that shouldn't need to execute binaries or honor device/SUID semantics — `/tmp`, `/var/tmp`, removable media mount points, and any world-writable data partition — is a foundational, low-cost hardening measure. It doesn't eliminate every risk (there are known bypass techniques for `noexec` in certain configurations, such as invoking an interpreter directly on a script file rather than executing the file itself), but it meaningfully raises the bar and is standard practice on hardened systems. Chapter 13 covers this in more depth.

---

## 6.7 Mount Namespaces (Brief Context)

Modern Linux supports **mount namespaces**, allowing different processes to see entirely different mount trees — the foundational kernel mechanism behind containers (Docker, Podman, LXC) and `chroot`-style isolation. A process inside a container can have `/` bind-mounted to a completely different directory than the host's actual `/`, be unable to see host mounts at all, and mount/unmount things within its own namespace without affecting the host.

```bash
# View the mount namespace a process belongs to
$ ls -l /proc/<pid>/ns/mnt

# Run a command in a new, isolated mount namespace (requires appropriate privileges)
$ sudo unshare --mount bash
```

> **Note:** A full treatment of mount namespaces and container storage is outside the scope of this chapter, but it's worth knowing this mechanism exists — it's why `mount` output *inside* a container often looks completely different from `mount` output on the host, and why debugging container storage issues sometimes requires explicitly checking from both perspectives.

---

## 6.8 Practical Examples

```bash
# Mount a new drive, verify, and check mount options actually applied
$ sudo mount -t ext4 -o noatime /dev/sdb1 /mnt/data
$ findmnt /mnt/data
TARGET     SOURCE      FSTYPE OPTIONS
/mnt/data  /dev/sdb1   ext4   rw,noatime,...

# Safely eject a USB drive
$ sync                      # flush any pending writes first
$ sudo umount /mnt/usb
$ sudo udisksctl power-off -b /dev/sdb   # spin down / power off, if supported

# Test a mount option change without permanently altering fstab yet
$ sudo mount -o remount,ro /

# Bind-mount a directory read-only into a chroot for a build environment
$ sudo mount --bind /usr/src /chroot/build/usr/src
$ sudo mount -o remount,bind,ro /chroot/build/usr/src
```

---

## 6.9 Common Mistakes

- **Mounting over a non-empty directory** and momentarily panicking that data was "deleted" (6.2.2) — it's hidden, not gone, and reappears once unmounted.
- **Forgetting that `--bind` mounts don't automatically propagate mount option changes** — remounting bind mount options requires the explicit `remount,bind` combination shown in 6.4, not just `-o` on the original bind command.
- **Using `umount -f`/`-l` reflexively** instead of first identifying (via `lsof`/`fuser`) what's actually holding the mount busy — this can mask an application bug (a process that should have closed a file handle but didn't) rather than fixing it.
- **Writing large or important data to `/tmp`** without realizing it's commonly `tmpfs`-backed and RAM-bound, then losing it on reboot or running the system out of memory.
- **Not testing mount option changes with `remount` before committing them to `/etc/fstab`**, risking a boot-time failure discovered only after a reboot (Chapter 7 covers safer testing patterns for `fstab` specifically).

---

## 6.10 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| `mount: wrong fs type, bad option, bad superblock` | Wrong `-t` type specified, or filesystem actually corrupt | `sudo blkid /dev/sdX1` to confirm actual fs type; run appropriate fsck |
| `umount: target is busy` | Open file handles, active working directory, or mmap on the filesystem | `lsof +D <mountpoint>`, `fuser -vm <mountpoint>` |
| Mounted directory appears empty when it shouldn't | Mounted over an already-populated directory, or mount actually failed silently | `findmnt <mountpoint>` to confirm what's actually mounted there |
| Mount options don't seem to be applied | Remount needed, or option unsupported by that filesystem type | `findmnt -o OPTIONS <mountpoint>` to see the kernel's actual applied options |
| Files created in a bind-mounted directory don't show read-only as expected | Bind + option change requires the two-step `mount --bind` then `remount,bind` sequence | Re-apply with the explicit two-command pattern shown in 6.4 |

---

*Previous: [05-Filesystems.md](./05-Filesystems.md) — Next: 07-Persistent-Mounts.md*
