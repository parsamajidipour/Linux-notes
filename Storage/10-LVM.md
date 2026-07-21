# 10. Logical Volume Manager (LVM)

Static partitions (Chapter 4) are fixed at creation time and tied to a specific physical disk's layout. LVM inserts a flexible abstraction layer between physical storage and filesystems, allowing volumes to be resized, spanned across multiple disks, and snapshotted — all without the rigid constraints of traditional partitioning.

---

## 10.1 The Three-Layer LVM Model

LVM is built from three concepts, each wrapping the layer below it:

```
 ┌─────────────────────────────────────────────────────┐
 │  Logical Volumes (LVs)                                 │
 │  lv_root   lv_home   lv_data   lv_swap                 │
 └─────────────────────────────────────────────────────┘
                          ▲
                          │  carved from
 ┌─────────────────────────────────────────────────────┐
 │  Volume Group (VG)                                      │
 │  vg0 — a pool of storage combining multiple PVs          │
 └─────────────────────────────────────────────────────┘
                          ▲
                          │  composed of
 ┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
 │ Physical Volume 1   │ │ Physical Volume 2   │ │ Physical Volume 3   │
 │ (/dev/sda3)          │ │ (/dev/sdb1)          │ │ (/dev/sdc1)          │
 └───────────────────┘ └───────────────────┘ └───────────────────┘
```

- **Physical Volume (PV)**: a partition or whole disk initialized for LVM use. This is the raw storage LVM is allowed to manage.
- **Volume Group (VG)**: a pool created by combining one or more PVs into a single unit of allocatable storage. A VG can span multiple physical disks transparently.
- **Logical Volume (LV)**: a chunk of storage carved out of a VG's pool, which is what actually gets formatted with a filesystem and mounted — functionally, an LV behaves like a partition, but without a static partition's rigid boundaries.

**Why this layered model is powerful:** because the VG is just a pool, growing storage is often as simple as adding a new PV to the VG and then extending an LV into the newly available space — no repartitioning, no data migration, frequently no downtime at all. This flexibility is the entire reason LVM exists.

---

## 10.2 Creating an LVM Setup

### 10.2.1 Step 1 — Create Physical Volumes

```bash
# Prepare partitions (or whole disks) for LVM use
$ sudo pvcreate /dev/sdb1 /dev/sdc1

# View physical volumes
$ sudo pvs
PV         VG   Fmt  Attr PSize   PFree
/dev/sdb1       lvm2 ---  100.00g 100.00g
/dev/sdc1       lvm2 ---  100.00g 100.00g

$ sudo pvdisplay /dev/sdb1
```

### 10.2.2 Step 2 — Create a Volume Group

```bash
$ sudo vgcreate vg0 /dev/sdb1 /dev/sdc1

$ sudo vgs
VG   #PV #LV #SN Attr   VSize   VFree
vg0    2   0   0 wz--n- 200.00g 200.00g

$ sudo vgdisplay vg0
```

### 10.2.3 Step 3 — Create Logical Volumes

```bash
# Create a 50GB logical volume
$ sudo lvcreate -L 50G -n lv_data vg0

# Create a logical volume using a percentage of remaining free space
$ sudo lvcreate -l 100%FREE -n lv_archive vg0

$ sudo lvs
LV         VG   Attr       LSize
lv_data    vg0  -wi-a----- 50.00g
lv_archive vg0  -wi-a----- 150.00g

$ sudo lvdisplay /dev/vg0/lv_data
```

### 10.2.4 Step 4 — Format and Mount

```bash
$ sudo mkfs.ext4 /dev/vg0/lv_data
$ sudo mount /dev/vg0/lv_data /mnt/data

# LVs also appear under /dev/mapper/
$ ls -l /dev/mapper/vg0-lv_data
```

> **Note:** Logical volumes are exposed as device-mapper devices — `/dev/vg0/lv_data` and `/dev/mapper/vg0-lv_data` refer to the exact same underlying device via different naming conventions; both work identically in `fstab` and elsewhere. Chapter 3's device model discussion applies here too — the actual major:minor pair belongs to the `dm` (device mapper) driver.

---

## 10.3 Extending Volumes

One of LVM's core value propositions: growing storage on a live system, often without downtime.

### 10.3.1 Extending a Volume Group (Adding More Physical Storage)

```bash
# Prepare a new disk/partition
$ sudo pvcreate /dev/sdd1

# Add it to the existing volume group's pool
$ sudo vgextend vg0 /dev/sdd1

$ sudo vgs vg0
VG   #PV #LV #SN Attr   VSize   VFree
vg0    3   2   0 wz--n- 300.00g 100.00g
```

### 10.3.2 Extending a Logical Volume

```bash
# Grow lv_data by 20GB
$ sudo lvextend -L +20G /dev/vg0/lv_data

# Or grow it to consume all remaining free space in the VG
$ sudo lvextend -l +100%FREE /dev/vg0/lv_data
```

### 10.3.3 Growing the Filesystem to Match

Extending the logical volume alone does **not** grow the filesystem sitting on it — that's a separate step, using the filesystem's own resize tooling (Chapter 5):

```bash
# ext4 — can be done online (while mounted)
$ sudo resize2fs /dev/vg0/lv_data

# XFS — can only grow, and must be mounted (grown via the mount point, not the device)
$ sudo xfs_growfs /mnt/data

# Btrfs — can be done online, targets the mount point
$ sudo btrfs filesystem resize +20G /mnt/data
```

A convenient shortcut combines the LV extend and ext4 resize into one command:

```bash
$ sudo lvextend -L +20G -r /dev/vg0/lv_data   # -r automatically calls resize2fs/xfs_growfs after
```

> **Tip:** The `-r` flag on `lvextend` (and `lvreduce`) automatically invokes the appropriate filesystem resize tool for you, correctly ordered — genuinely useful and worth using by default rather than remembering the two-step process manually every time.

---

## 10.4 Reducing (Shrinking) Volumes

Shrinking is meaningfully riskier than growing, and the safe order of operations is the **exact reverse** of extending: shrink the filesystem *first*, then shrink the logical volume — never the other way around.

```bash
# ext4 — must be unmounted first for a safe shrink
$ sudo umount /mnt/data
$ sudo e2fsck -f /dev/vg0/lv_data       # mandatory consistency check before resizing
$ sudo resize2fs /dev/vg0/lv_data 30G   # shrink filesystem to 30GB FIRST
$ sudo lvreduce -L 30G /dev/vg0/lv_data # THEN shrink the LV to match

$ sudo mount /dev/vg0/lv_data /mnt/data
```

> **Warning:** Shrinking the logical volume *before* shrinking the filesystem will truncate the underlying block device out from under the filesystem's existing data structures, causing data loss and likely filesystem corruption. Always shrink the filesystem first, verify it succeeded, and only then shrink the LV — and always maintain a current backup before any shrink operation regardless of how carefully the steps are followed. Also remember: **XFS cannot be shrunk at all** (Chapter 5, Section 5.3.1) — an XFS-backed LV can only ever grow.

---

## 10.5 Snapshots

LVM snapshots capture a point-in-time, consistent view of a logical volume, implemented via copy-on-write: at snapshot creation, no data is actually copied; instead, the snapshot tracks changes made to the original LV *after* the snapshot point, storing only the original versions of blocks that get overwritten.

```bash
# Create a 5GB snapshot of lv_data (space here is for tracking changes, not a full copy)
$ sudo lvcreate -L 5G -s -n lv_data_snap /dev/vg0/lv_data

$ sudo lvs
LV            VG   Attr       LSize  Origin   Data%
lv_data       vg0  owi-aos--- 50.00g
lv_data_snap  vg0  swi-a-s--- 5.00g  lv_data  2.34

# Mount the snapshot read-only to inspect/recover a prior state
$ sudo mount -o ro /dev/vg0/lv_data_snap /mnt/snapshot

# Remove a snapshot once no longer needed
$ sudo lvremove /dev/vg0/lv_data_snap
```

**Why the snapshot's own size matters:** the snapshot's allocated space is a buffer for tracking *changed* blocks, not a full copy of the origin volume. If the origin volume changes more than the snapshot's allocated capacity before the snapshot is removed, the snapshot becomes **invalid** and unusable — sized snapshots need headroom proportional to expected write volume during the snapshot's lifetime, not the origin volume's total size.

> **Warning:** An LVM snapshot that runs out of allocated space becomes permanently invalid and must be discarded — it cannot be "topped up" after the fact in the traditional (non-thin) snapshot model. For any snapshot expected to live for more than a brief maintenance window, either size it generously or use **thin provisioning** (10.6), where this specific failure mode is handled far more gracefully.

**Common practical use:** taking a consistent snapshot immediately before a risky operation (a package upgrade, a schema migration, a config change), with the plan to quickly roll back by restoring from the snapshot if something goes wrong — conceptually similar to Btrfs snapshots (Chapter 5, Section 5.4.1), but implemented at the LVM/block level rather than inside the filesystem itself, which means it works with any filesystem type, not just Btrfs.

---

## 10.6 Thin Provisioning (Brief Overview)

Beyond the "thick" (fully pre-allocated) LVs covered above, LVM also supports **thin provisioning**: logical volumes that report a nominal size larger than what's actually physically allocated, drawing from a shared thin pool as data is actually written.

```bash
# Create a thin pool
$ sudo lvcreate -L 100G -T vg0/thinpool

# Create a thin logical volume — can report a virtual size larger than the pool itself
$ sudo lvcreate -V 200G -T vg0/thinpool -n lv_thin

$ sudo lvs -a vg0
```

**Why this matters:** thin provisioning enables over-commitment — allocating more virtual storage than is physically present, betting that not every volume will actually use its full nominal allocation simultaneously (a common and reasonable bet in virtualization/container hosting scenarios). It also makes thin snapshots dramatically cheaper and avoids the fixed-size invalidation risk described in 10.5.

> **Warning:** Thin provisioning's over-commitment model shifts the "running out of space" failure mode from an individual volume to the shared pool — if the underlying thin pool itself fills up, **every** thin volume drawing from it can be affected simultaneously, including ones that individually appear to have plenty of nominal free space. Monitoring the pool's actual physical utilization (not just individual volumes' reported sizes) is essential and non-optional when using thin provisioning in production.

---

## 10.7 Advantages and Disadvantages

| Advantages | Disadvantages |
|---|---|
| Online resizing (grow, and shrink for most filesystems) without repartitioning | Added complexity — another abstraction layer to understand and troubleshoot |
| Can span multiple physical disks transparently | Slight performance overhead versus raw partitions (usually negligible on modern hardware) |
| Native snapshot support, independent of filesystem type | Snapshot invalidation risk if under-sized (thick snapshots) |
| Thin provisioning enables flexible over-commitment | Thin pool exhaustion is a shared, cross-volume failure risk |
| Well-integrated with most Linux distributions' installers and tooling | Recovery from LVM metadata corruption is more involved than recovering a simple partition table |

---

## 10.8 Common Mistakes

- **Extending the LV but forgetting to grow the filesystem**, then being confused why `df` still shows the old size despite `lvs` reporting the LV as larger.
- **Shrinking the LV before shrinking the filesystem** (10.4) — a serious, data-loss-risking ordering mistake.
- **Under-sizing a traditional (thick) snapshot** for its intended lifetime, causing silent invalidation before it's actually needed for rollback.
- **Not monitoring thin pool utilization directly**, only checking individual thin LVs, and being caught off guard by pool exhaustion affecting multiple volumes at once.
- **Forgetting that XFS-backed LVs can never shrink**, and discovering this only after already needing to reduce space.

---

## 10.9 Troubleshooting

| Symptom | Likely Cause | Diagnostic Step |
|---|---|---|
| `lvextend` succeeds but `df` shows old size | Filesystem wasn't resized after the LV | Run `resize2fs`/`xfs_growfs`/`btrfs filesystem resize` (or redo with `lvextend -r`) |
| Snapshot shows as invalid | Snapshot exceeded its allocated change-tracking space | Remove and recreate with larger allocation, or migrate to thin provisioning |
| VG shows free space but `lvcreate` fails | Space fragmented across PVs in a way the request can't satisfy, or extent size mismatch | Check `vgs`/`pvs` output for free extents per PV; consider `--alloc anywhere` |
| Thin pool nearing capacity warnings | Over-commitment approaching real physical limits | `lvs -a` to check pool `Data%`/`Meta%`; extend the pool or the underlying VG |
| LVM metadata appears corrupted, VG won't activate | Damaged LVM metadata (rare, but serious) | `vgcfgrestore` from LVM's automatic metadata backups in `/etc/lvm/backup/` and `/etc/lvm/archive/` |

```bash
# LVM automatically archives metadata changes — a real safety net worth knowing about
$ ls /etc/lvm/archive/
$ sudo vgcfgrestore --list vg0
$ sudo vgcfgrestore vg0    # restore from the most recent archived metadata
```

> **Security Note:** LVM snapshots and thin volumes can retain data from the origin volume even after the "live" data has been deleted or overwritten at the filesystem level — a snapshot is, by design, a preserved point-in-time view. When secure deletion matters (Chapter 13), remember that snapshots referencing a volume must also be accounted for and removed; deleting a file on the live volume does nothing to purge that same data still held by an existing snapshot.

---

*Previous: [09-Swap-Space.md](./09-Swap-Space.md) — Next: 11-RAID.md*
