# 1. Introduction to Linux Storage

A mechanism-level look at what storage actually is, how Linux organizes it into a layered stack, and the vocabulary this entire series depends on. This is not a "getting started" tutorial — it's the conceptual foundation the next fourteen chapters build on.

---

## 1.1 What Is Storage?

At the most basic level, storage is any medium capable of retaining data after the process that wrote it has stopped running, and — critically for a multi-user operating system — after the machine itself has been powered off. This second property is what separates storage from memory (RAM). RAM is fast and directly addressable by the CPU, but it is volatile: the moment power is cut, its contents are gone. Storage devices (HDDs, SSDs, NVMe drives, tape, optical media) trade raw access speed for persistence.

This trade-off is the reason every operating system, Linux included, is built around a **storage hierarchy**:

```
        ┌─────────────────────┐
        │   CPU Registers      │  fastest, smallest, most expensive per byte
        ├─────────────────────┤
        │   CPU Cache (L1-L3)  │
        ├─────────────────────┤
        │   RAM (Main Memory)  │  volatile
        ├─────────────────────┤
        │   NVMe / SSD          │
        ├─────────────────────┤
        │   HDD                 │
        ├─────────────────────┤
        │   Network / Tape /    │  slowest, largest, cheapest per byte
        │   Cold Storage         │  persistent
        └─────────────────────┘
```

**Why it works this way:** every layer down this pyramid is progressively cheaper per gigabyte and progressively slower to access. System design — and by extension, most of the tuning decisions covered later in this series — is about deciding which data belongs at which layer, and how the operating system moves data between layers efficiently and safely.

For a Linux administrator, "storage" in practice means answering a series of concrete questions:

- Where does a byte of data physically live?
- How does the kernel find it again?
- What guarantees exist that it survives a crash, a reboot, or a disk failure?
- How fast can it be read or written, and under what conditions does that speed degrade?
- Who is allowed to read or write it, and how is that enforced?

Every chapter in this series is really just an elaboration of one of these five questions.

> **Tip:** When troubleshooting any storage issue, it helps to explicitly ask yourself which of these five questions you're actually trying to answer. "The application is slow" is not a storage question by itself — "what is my I/O latency under this workload" is.

---

## 1.2 Linux Storage Architecture

Linux storage is not a single subsystem — it's a stack of cooperating layers, each with a narrow, well-defined responsibility. Understanding this stack is the single highest-leverage piece of knowledge in this entire series, because nearly every other topic (partitioning, filesystems, LVM, RAID, performance tuning) is really just "which layer of this stack am I working in, and what does that layer promise me?"

```
 ┌────────────────────────────────────────────┐
 │              Applications                    │
 └────────────────────────────────────────────┘
                      │  read() / write() / open()
 ┌────────────────────────────────────────────┐
 │         Virtual Filesystem (VFS)              │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Filesystem (ext4, XFS, Btrfs, ...)          │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Page Cache / Buffer Cache                    │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Device Mapper (LVM, LUKS, RAID via dm)      │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Block Layer (I/O scheduler, request queue)  │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Device Driver (NVMe, SCSI/SATA, USB)         │
 └────────────────────────────────────────────┘
                      │
 ┌────────────────────────────────────────────┐
 │   Physical Storage Device                      │
 └────────────────────────────────────────────┘
```

Each layer only needs to know about the layer immediately below and above it. An application calling `write()` has no idea whether the underlying device is an NVMe SSD, a software RAID array, or an encrypted LVM volume on a spinning disk over iSCSI — and that's by design. This abstraction is what lets you, as an administrator, insert layers like LVM or `dm-crypt` transparently, without any application changes.

**Why it's layered this way:** separating these concerns means each layer can evolve independently. XFS and ext4 don't need to know anything about NVMe command queuing; the block layer doesn't need to know anything about file permissions. This is the same design philosophy behind networking's OSI model, applied to storage.

---

## 1.3 Storage Stack Overview — Walking Through a Single Write

It's worth tracing exactly what happens when an application executes `write()` on a regular file, because this single walk-through ties the entire stack together.

1. **Application** calls `write(fd, buf, count)`. This is a system call, so it traps into the kernel.
2. **VFS (Virtual Filesystem)** receives the call. VFS is a kernel abstraction layer that presents a single uniform interface (`open`, `read`, `write`, `close`, ...) regardless of which actual filesystem is backing the file. It resolves the file descriptor to an inode and hands off to the filesystem-specific implementation.
3. **Filesystem** (say, ext4) translates the write into changes to its own on-disk structures: it may need to allocate new blocks, update the inode's block pointers, update metadata like modification time, and — if journaling is enabled — write a journal entry describing the transaction before applying it.
4. **Page cache**: in the common case, the write does not go to disk immediately. It's copied into a page cache entry in RAM and the page is marked "dirty." The `write()` call returns to the application at this point — this is why a `write()` completing does *not* guarantee the data is durably on disk.
5. **Device mapper** (if present): if the filesystem sits on an LVM logical volume, a `dm-crypt` encrypted volume, or a software RAID array assembled via `dm-raid`/`mdadm`, the write is intercepted here and remapped — a logical block address on the logical volume is translated to one or more physical block addresses on the underlying physical volume(s).
6. **Block layer**: the write becomes a block I/O request (`struct bio` in kernel terms), which is merged with adjacent requests where possible, queued, and scheduled according to the active I/O scheduler policy (e.g., `none`, `mq-deadline`, `bfq` — covered in Chapter 12).
7. **Device driver**: the NVMe, SCSI, or SATA driver translates the block request into the actual command protocol the device understands (an NVMe command, a SCSI CDB, an ATA command) and submits it to the device's hardware queue.
8. **Physical device**: the drive's own controller (increasingly complex firmware, especially on SSDs) executes the write to physical media — spinning platters and a head assembly for HDDs, NAND flash cells for SSDs/NVMe.
9. **Completion**: the device signals completion via an interrupt (or polling, in high-performance NVMe configurations); this propagates back up the stack.
10. Later, either the kernel's flusher threads (`kworker` writeback threads) or an explicit `fsync()`/`sync` call push dirty pages from the page cache to the actual device, at which point the data is durable.

```
write() ──▶ VFS ──▶ Filesystem ──▶ Page Cache (dirty)
                                        │
                              (later, async or fsync)
                                        ▼
                                 Device Mapper
                                        │
                                        ▼
                                  Block Layer
                                        │
                                        ▼
                                Device Driver
                                        │
                                        ▼
                              Physical Device
```

> **Warning:** Step 4 is the single most misunderstood part of the Linux storage stack. A successful `write()` return code means the kernel has accepted the data into its cache — nothing more. If the machine loses power before writeback occurs, that data can be lost. Applications that need a durability guarantee must call `fsync()` (or open the file with `O_DIRECT`/`O_SYNC`), and this is precisely why databases are so aggressive about calling `fsync()` at transaction commit boundaries.

---

## 1.4 Block Devices vs. Character Devices

Linux exposes hardware to user space largely through device files under `/dev`, and these fall into two fundamental categories that behave completely differently.

**Block devices** are devices that support random access to fixed-size blocks of data (traditionally 512 bytes, though modern devices commonly use 4096-byte physical sectors). Because access is block-oriented and random, the kernel can cache, reorder, and merge I/O requests against them. Disks, SSDs, USB drives, and loopback devices are all block devices — you'll see them as `/dev/sda`, `/dev/nvme0n1`, `/dev/vda`, etc.

**Character devices** transfer data as a stream of bytes, sequentially, with no fixed block size and typically no seeking or caching. Terminals, serial ports, `/dev/null`, `/dev/zero`, and `/dev/random` are character devices.

| Property | Block Device | Character Device |
|---|---|---|
| Access pattern | Random access, block-addressed | Sequential stream |
| Buffering | Cached in page cache | Usually unbuffered |
| Example | `/dev/sda`, `/dev/nvme0n1` | `/dev/tty`, `/dev/null` |
| Typical use | Filesystems, partitions | Terminals, streaming I/O |
| Seek support | Yes (`lseek()` meaningful) | Usually no |

You can distinguish them instantly in an `ls -l /dev` listing: block devices show a `b` as the first character of the permission string, character devices show a `c`.

```bash
$ ls -l /dev/sda /dev/null
brw-rw---- 1 root disk    8,   0 Jul 20 10:00 /dev/sda
crw-rw-rw- 1 root root    1,   3 Jul 20 10:00 /dev/null
```

Notice also the two numbers before the date (`8, 0` and `1, 3`) — these are the **major and minor device numbers**, which are covered in depth in Chapter 3. Briefly: the major number tells the kernel which driver handles the device, and the minor number identifies the specific device instance to that driver.

**Why this distinction matters practically:** filesystems can only be built on block devices, because a filesystem's on-disk structures (superblocks, inodes, allocation bitmaps) depend fundamentally on the ability to seek to and randomly update fixed-size blocks. You cannot `mkfs` a character device. Conversely, some administrative and security tools deliberately use character devices — for example, reading from `/dev/urandom` (a character device) to seed cryptographic key generation.

---

## 1.5 How Linux Interacts With Storage — The Unified Device Model

Modern Linux organizes all hardware, storage included, through **sysfs** (`/sys`) and the unified **device model**, with `udev` as the user-space component that reacts to hardware events and creates the actual `/dev` nodes (covered fully in Chapter 3).

At a high level, when a storage device is attached:

1. The relevant bus driver (PCIe for NVMe, SCSI subsystem for SATA/SAS, USB subsystem for USB storage) detects the device.
2. The kernel creates an internal representation of the device and populates a corresponding hierarchy under `/sys/block/`.
3. A `uevent` is emitted to notify user space.
4. `udev` receives the `uevent`, applies its rules (`/etc/udev/rules.d/`, `/usr/lib/udev/rules.d/`), and creates device nodes in `/dev` along with any configured symlinks (e.g., `/dev/disk/by-uuid/...`).
5. The device is now usable — it can be partitioned, formatted, or, if it already contains a recognized filesystem and appropriate `fstab`/automount configuration exists, automatically mounted.

```
Physical device attached
        │
        ▼
 Bus driver detects (PCIe / SCSI / USB)
        │
        ▼
 Kernel creates device object (/sys/block/...)
        │
        ▼
 uevent emitted
        │
        ▼
 udev applies rules ──▶ /dev/sdX created + symlinks
        │
        ▼
 Device usable (partition / format / mount)
```

This event-driven model is why plugging in a USB drive on a modern Linux desktop "just works," and it's also the mechanism underlying predictable device naming, hot-plug support, and tools like `udevadm monitor` that let you watch these events in real time as they happen — genuinely useful when debugging why a disk isn't showing up as expected.

---

## 1.6 Why This Matters: The Mental Model Going Forward

Every subsequent chapter in this series maps onto a specific layer of the stack described in 1.3:

- **Chapter 2 (Physical Storage Devices)** — the bottom of the stack: the hardware itself.
- **Chapter 3 (Block Devices)** — how the kernel names and represents that hardware.
- **Chapter 4 (Disk Partitioning)** — subdividing a block device before anything is built on top of it.
- **Chapter 5 (Filesystems)** — the layer that gives raw blocks meaning as files and directories.
- **Chapters 6–7 (Mounting)** — how filesystems get attached into the single Linux directory tree.
- **Chapter 8 (Tools)** — the everyday commands for inspecting every layer above.
- **Chapter 9 (Swap)** — a special-purpose use of block storage as memory backing.
- **Chapter 10 (LVM)** and **Chapter 11 (RAID)** — layers inserted between the physical device and the filesystem (the "device mapper" step in the diagram).
- **Chapter 12 (Performance)** — measuring and tuning behavior at every layer.
- **Chapter 13 (Security)** — access control and encryption applied across the stack.
- **Chapter 14 (Troubleshooting)** — diagnosing failures by identifying *which layer* is misbehaving.
- **Chapter 15 (Best Practices)** — operational discipline tying it all together.

> **Note:** Keep the layered diagram from 1.3 in mind throughout this entire series. Nearly every troubleshooting question in Chapter 14 reduces to "at which layer of this stack does the problem actually live?" — and misdiagnosing the layer is the single most common mistake even experienced administrators make under pressure.

---

*Next: [02-Physical-Storage-Devices.md](./02-Physical-Storage-Devices.md)*
