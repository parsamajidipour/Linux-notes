# 13. Storage Security

Earlier chapters referenced security considerations throughout — this chapter consolidates them and goes deeper on the topics that deserve dedicated treatment: file permissions as they interact with the storage stack, encryption at rest via LUKS, secure deletion, and mount-level hardening.

---

## 13.1 File Permissions Recap (Storage-Relevant Aspects)

Full permission semantics belong to a dedicated permissions reference, but a few storage-specific interactions are worth calling out here:

- **Permissions live in the inode** (Chapter 5, Section 5.1.1), not in the directory entry or the filesystem's block allocation — this is why permission changes are instantaneous regardless of file size, and why hard links to the same inode always share identical permissions.
- **Non-POSIX filesystems** (FAT32, exFAT, NTFS via `ntfs-3g`/`ntfs3` — Chapter 5, Section 5.5) have no native concept of Unix ownership/permissions at all. Whatever appears in `ls -l` on a mounted FAT32/exFAT volume is synthesized at mount time from the `uid=`, `gid=`, and `umask=` mount options — it is not a property of the individual files.
- **Special bits relevant to storage**: SUID/SGID (execute-as-owner/group) and the sticky bit (restrict deletion in shared directories like `/tmp` to the file's own owner) interact directly with mount options like `nosuid` (Chapter 6, Section 6.6), which override the on-disk bit entirely for that mount, regardless of what the filesystem itself records.

```bash
# Confirm whether nosuid is actually stripping SUID behavior on a given mount
$ findmnt -o TARGET,OPTIONS /mnt/external
```

---

## 13.2 Encryption at Rest: LUKS

**LUKS** (Linux Unified Key Setup) is the standard Linux disk encryption framework, implemented via the kernel's `dm-crypt` device-mapper target (the same device-mapper mechanism underlying LVM — Chapter 10 — and software RAID's `dm-raid` mode).

### 13.2.1 How LUKS Fits Into the Stack

LUKS sits as its own device-mapper layer, typically *beneath* LVM or a filesystem, and *above* the raw partition/block device:

```
 ┌─────────────────────────────┐
 │   Filesystem (ext4/XFS/...)   │
 ├─────────────────────────────┤
 │   LVM (optional)               │
 ├─────────────────────────────┤
 │   LUKS / dm-crypt              │  ◀── encryption happens here
 ├─────────────────────────────┤
 │   Partition / Block Device     │
 └─────────────────────────────┘
```

Everything above the LUKS layer — the filesystem, and LVM if present — operates completely unaware that encryption is happening; they simply see a normal block device (`/dev/mapper/luks-<uuid>`) that happens to transparently encrypt/decrypt on every read/write.

### 13.2.2 Setting Up LUKS Encryption

```bash
# Initialize LUKS on a partition (THIS DESTROYS ANY EXISTING DATA on the partition)
$ sudo cryptsetup luksFormat /dev/sdb1

# Open the encrypted volume, creating a mapped device node
$ sudo cryptsetup luksOpen /dev/sdb1 secure_data
# Prompts for the passphrase; on success, creates /dev/mapper/secure_data

# Format and use the now-decrypted mapped device normally
$ sudo mkfs.ext4 /dev/mapper/secure_data
$ sudo mount /dev/mapper/secure_data /mnt/secure

# When done, unmount and close the mapping
$ sudo umount /mnt/secure
$ sudo cryptsetup luksClose secure_data
```

### 13.2.3 Key Management

LUKS supports multiple key slots (typically 8), allowing several independent passphrases (or keyfiles) to unlock the same encrypted volume — useful for having a personal passphrase alongside a securely-stored recovery keyfile, without sharing a single credential.

```bash
# Add an additional key (e.g., a keyfile for automated/unattended unlocking)
$ sudo cryptsetup luksAddKey /dev/sdb1 /path/to/keyfile

# List current key slots
$ sudo cryptsetup luksDump /dev/sdb1

# Remove a specific key slot
$ sudo cryptsetup luksRemoveKey /dev/sdb1
```

> **Security Note:** Anyone possessing *any one* valid key slot's passphrase or keyfile can decrypt the entire volume — LUKS key slots are alternative ways to unlock the same underlying master key, not independent per-user encryption. Losing control of any single key slot's credential should be treated as a full compromise of that volume; the appropriate response is re-encryption with a new master key, not merely removing the compromised key slot (since the data was already exposed under the old key during the exposure window).

### 13.2.4 Persistent Unlocking at Boot

```
# /etc/crypttab
secure_data  UUID=xxxxxxxx-xxxx-...  none  luks
```

Referencing this mapped name (`secure_data`) in `/etc/fstab` (Chapter 7) as `/dev/mapper/secure_data` allows the system to prompt for the passphrase during boot, or, if a keyfile path is given in the `crypttab` third field instead of `none`, unlock automatically without interaction — a common pattern for encrypted data volumes on servers that need to come up unattended, though it does mean the keyfile itself becomes a critical piece of protected material (commonly stored on a separate, more tightly access-controlled boot volume, or supplied via a hardware security module/TPM-backed mechanism on more sophisticated setups).

> **Warning:** An unattended-unlock keyfile stored unprotected on the same, otherwise-unencrypted boot disk provides real protection only against a *stolen drive scenario* (the encrypted data drive alone, without the boot disk, is unreadable) — it provides essentially no protection against an attacker who has access to the complete running or imaged system, since the key material is sitting right there. Understand precisely which threat model a given automated-unlock configuration actually defends against before relying on it.

---

## 13.3 Secure Deletion

### 13.3.1 Why "Delete" Doesn't Mean "Gone"

Deleting a file, on essentially every mainstream filesystem, removes the directory entry and marks the inode/blocks as free — it does **not** overwrite the actual data. Until something else happens to allocate and write to those same blocks, the original data typically remains physically present and recoverable with appropriate tools.

This is compounded further on flash storage (Chapter 2, Section 2.3.2): the Flash Translation Layer's remapping means even a deliberate overwrite at the filesystem level may not overwrite the *same physical NAND cells* the original data occupied — the FTL may simply write the new data to a different, already-erased physical location and mark the old physical location stale, leaving the original data physically intact until garbage collection eventually erases that block.

### 13.3.2 Secure Deletion Approaches

| Method | Applicability | Effectiveness |
|---|---|---|
| `shred` (overwrite passes) | HDDs, traditional magnetic media | Reasonably effective on HDDs; **not reliable on SSDs** due to FTL remapping (13.3.1) |
| Filesystem-level secure delete (rare, mostly historical) | Some older filesystems had `-o discard`/secure-delete options | Largely deprecated/unreliable on modern filesystems and flash storage |
| Full-disk encryption from the start (13.2) | Any media | **Most reliable modern approach** — see 13.3.3 |
| ATA Secure Erase / NVMe Format with crypto erase | SSDs/NVMe specifically | Effective when supported — instructs the drive's own firmware to erase or cryptographically invalidate all data |
| Physical destruction | Any media, end-of-life disposal | Only fully certain method for media being retired entirely |

```bash
# shred — reasonably meaningful on HDDs, NOT reliable on SSDs
$ sudo shred -vfz -n 3 /dev/sdb1

# ATA Secure Erase for an SSD (use with genuine caution — irreversibly wipes the entire drive)
$ sudo hdparm --user-master u --security-set-pass p /dev/sdb
$ sudo hdparm --user-master u --security-erase p /dev/sdb

# NVMe format with a crypto-erase/user-data-erase secure erase setting
$ sudo nvme format /dev/nvme0n1 --ses=1
```

> **Warning:** `shred` was designed around the physical characteristics of magnetic media and provides materially weaker (and often no meaningful) guarantees on SSDs, due to wear leveling and the FTL's write remapping described in 13.3.1. For SSDs specifically, prefer the drive's own dedicated secure-erase command (ATA Secure Erase / NVMe Format), or better still, ensure the data was encrypted from the moment it was written (13.3.3), so "secure deletion" of individual files is never actually load-bearing.

### 13.3.3 The Practical Modern Answer: Encrypt From the Start

The most reliable and lowest-effort approach to secure deletion, especially on SSD/flash media, is to make the *entire volume* LUKS-encrypted from the moment data is first written (13.2). Under this model, "securely deleting" any specific piece of data — or the entire volume — reduces to destroying (or simply forgetting) the LUKS master key, rendering every block on the device, past or present, cryptographically unrecoverable regardless of what remains physically present on the media, FTL remapping included.

> **Tip:** For any volume where secure deletion is a realistic requirement (decommissioning drives, handling regulated/sensitive data, mobile/removable media that could be lost or stolen), the highest-leverage decision is made at *provisioning* time — encrypt from the start — rather than at deletion time, when the physical realities of flash storage make after-the-fact guarantees much harder to provide with confidence.

---

## 13.4 Read-Only Mounts

Mounting a filesystem `ro` (Chapter 6, Section 6.6) is a simple, effective hardening measure for any data that shouldn't change during normal operation:

```bash
# Mount a distribution's package repository mirror, install media, or reference dataset read-only
$ sudo mount -o ro /dev/sdb1 /mnt/reference-data

# Remount an already-mounted filesystem read-only without unmounting
$ sudo mount -o remount,ro /mnt/data
```

**Practical use cases:** boot media and rescue partitions, reference/golden datasets that should never be modified in place, forensic analysis of a filesystem (mounting evidence read-only to avoid any risk of altering timestamps or content), and immutable-infrastructure patterns where a base image should never drift from its known-good state.

> **Security Note:** A read-only *mount option* is a convenience/safety measure enforced by the kernel's mount layer, not a cryptographically or physically enforced guarantee — a process with sufficient privilege can remount the filesystem read-write (`mount -o remount,rw`). For genuine tamper-evidence (e.g., forensic contexts), pair a read-only mount with the underlying block device's own hardware write-protect mechanism where available (some USB devices and SD cards support a physical write-protect switch or lock), rather than relying on the mount option alone as the sole control.

---

## 13.5 Secure Mount Options — Consolidated

Bringing together the hardening-relevant options introduced in Chapter 6, Section 6.6:

```bash
# A hardened /tmp mount — a widely-recommended baseline
tmpfs  /tmp  tmpfs  defaults,noexec,nosuid,nodev,size=2G  0  0

# A hardened removable-media mount point
/dev/sdb1  /mnt/usb  vfat  defaults,noexec,nosuid,nodev,uid=1000,gid=1000  0  0
```

| Option | Protects Against |
|---|---|
| `noexec` | Execution of binaries/scripts placed on that filesystem |
| `nosuid` | SUID/SGID privilege escalation via binaries on that filesystem |
| `nodev` | Device files on that filesystem being used to access hardware directly |
| `ro` | Any modification at all (Section 13.4) |

> **Note:** `noexec` is not an absolute barrier — it's well known that some interpreters can be invoked *against* a script on a `noexec` filesystem (e.g., `bash /mnt/usb/script.sh` runs `bash` itself, which is executable elsewhere, merely reading the script as data) even though the script file itself cannot be executed directly. Treat these options as meaningful defense-in-depth layers, not a complete, unbypassable sandbox on their own — they're most effective combined with other controls (application allowlisting, mandatory access control frameworks like SELinux/AppArmor) rather than relied upon in isolation.

---

## 13.6 Security Best Practices Summary

- **Encrypt sensitive data volumes from the start** (13.2, 13.3.3) — the single highest-leverage decision for both confidentiality and eventual secure deletion.
- **Understand LUKS key slot semantics** (13.2.3) — any valid key unlocks everything; treat key compromise as full volume compromise.
- **Never trust `shred` alone on SSD/flash media** (13.3.2) — prefer drive-native secure erase commands or, better, encryption-from-the-start.
- **Apply `noexec,nosuid,nodev` to `/tmp`, `/var/tmp`, and removable media mounts** as routine baseline hardening (13.5).
- **Use read-only mounts for reference data and forensic contexts** (13.4), understanding their limits as a software-only control.
- **Remember RAID and encryption solve different problems** (Chapter 11, Section 11.7's security note) — layer them deliberately rather than assuming one substitutes for the other.
- **Account for snapshots and mirrors when reasoning about data destruction** (Chapter 10, Section 10.9's security note) — deleting live data doesn't purge copies retained elsewhere in the stack.

---

## 13.7 Common Mistakes

- **Assuming file deletion is equivalent to secure erasure**, especially on SSDs, where the FTL's behavior makes this assumption particularly unreliable (13.3.1).
- **Storing an unattended-unlock LUKS keyfile on the same unencrypted boot disk** without understanding the narrow threat model that configuration actually protects against (13.2.4).
- **Relying on `noexec` as a complete execution-prevention control** without accounting for interpreter-invocation bypasses (13.5).
- **Treating a read-only mount as tamper-proof** rather than as a convenience control that a privileged process can reverse (13.4).
- **Forgetting that RAID mirrors/parity give zero confidentiality benefit** and encrypting only "the important drive" in a RAID array while leaving others plaintext, when in fact every member drive of a RAID 1 mirror contains a complete readable copy.

---

## 13.8 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| LUKS volume won't unlock with a known-good passphrase | Wrong key slot targeted, or `crypttab` misconfiguration | `cryptsetup luksDump /dev/sdX` to inspect key slots |
| Automated LUKS unlock at boot fails | Missing/incorrect keyfile path or permissions in `/etc/crypttab` | Check `journalctl -b` for the specific `cryptsetup` unit failure |
| `noexec` doesn't seem to prevent a script from running | Script invoked via an interpreter rather than executed directly (13.5) | Confirm via `findmnt` that `noexec` is actually applied, then address at the application/MAC-policy layer |
| Deleted sensitive file believed still recoverable | Standard filesystem delete semantics (13.3.1), especially on SSD | Treat as expected behavior; plan for encryption-from-the-start on future sensitive volumes |
| Read-only mount unexpectedly became writable | A process remounted it, or it was never actually enforced as expected | `findmnt -o OPTIONS` to confirm current state; audit what remounted it |

---

*Previous: [12-Storage-Performance.md](./12-Storage-Performance.md) — Next: 14-Troubleshooting.md*
