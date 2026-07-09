# tmpfs

> Notes on how `tmpfs` works, where Linux uses it, and what can go wrong when temporary filesystems are treated like normal disk storage.

---

## Why I started reading about tmpfs

I kept seeing `tmpfs` in places like `/run`, `/dev/shm`, and sometimes `/tmp`.

At first glance, it looks like a normal filesystem that happens to be fast. After reading more carefully, I realized that `tmpfs` sits at an interesting point between filesystems, virtual memory, swap, shared memory, containers, and system boot behavior.

This note is my attempt to understand it properly instead of reducing it to the usual sentence: "tmpfs is a filesystem in RAM."

That sentence is useful, but incomplete.

---

## Short definition

`tmpfs` is a temporary in-memory filesystem backed by the Linux virtual memory subsystem.

Files stored in `tmpfs` do not live on a persistent block device like an ext4 or XFS filesystem. Their contents are stored in memory pages managed by the kernel. These pages usually reside in RAM, but they may also be moved to swap when swap is enabled and the kernel decides that doing so is necessary.

When a `tmpfs` mount is unmounted, or when the system reboots, its contents are lost.

---

## The most important idea

`tmpfs` is not simply "a RAM disk."

A traditional RAM disk reserves a fixed chunk of memory and exposes it as a block device. `tmpfs` behaves differently:

- it grows and shrinks dynamically;
- it uses memory only for actual data and metadata stored inside it;
- it is integrated with the kernel page cache and virtual memory system;
- it can be limited by mount options such as `size`, `nr_inodes`, `mode`, `uid`, and `gid`;
- it can use swap unless swap usage is disabled or unavailable;
- it disappears when unmounted or after reboot.

This makes `tmpfs` flexible, but it also means it must be treated as part of system memory pressure, not as free storage.

---

## Where tmpfs is commonly used

Common Linux systems often use `tmpfs` for volatile runtime data:

| Path | Typical purpose |
|---|---|
| `/run` | Runtime state for services since boot |
| `/dev/shm` | POSIX shared memory area |
| `/tmp` | Temporary files on some distributions/configurations |
| `/run/user/<uid>` | Per-user runtime files, sockets, and session state |
| container mounts | Temporary writable areas inside containers |
| build/test environments | Fast scratch space for short-lived data |

The exact mount points vary by distribution and system configuration.

Check your own system:

```bash
findmnt -t tmpfs
```

or:

```bash
mount | grep tmpfs
```

---

## tmpfs vs disk filesystems

A disk filesystem such as ext4, XFS, or Btrfs stores persistent data on a block device. It survives reboot unless explicitly deleted or corrupted.

`tmpfs` is different:

| Property | tmpfs | ext4 / XFS / Btrfs |
|---|---|---|
| Backing storage | Virtual memory | Block device |
| Persistence | Lost on unmount/reboot | Persistent |
| Speed | Usually very fast | Depends on disk/storage |
| Memory pressure impact | Direct | Mostly indirect through page cache |
| Can use swap | Yes, if enabled | Not in the same way |
| Common use | Runtime/temp/shared memory | Durable files |

The practical rule is simple: use `tmpfs` only for data that can be regenerated or safely discarded.

---

## tmpfs vs ramfs

`ramfs` and `tmpfs` are often confused.

`ramfs` is an older simple in-memory filesystem. It grows as files are added, but it does not enforce a maximum size limit in the same practical way. That makes it dangerous: a user or process can write until memory is exhausted.

`tmpfs` adds size limits and swap integration, which makes it suitable for real systems.

| Feature | tmpfs | ramfs |
|---|---|---|
| Size limit | Yes | No practical enforced limit |
| Can use swap | Yes | No |
| Safer for general use | Yes | Usually no |
| Commonly used by distributions | Yes | Rarely |

In almost all normal cases, use `tmpfs`, not `ramfs`.

---

## Memory model

The core thing to understand is that `tmpfs` stores file contents as memory pages.

When a process writes to a file on `tmpfs`, the kernel allocates memory pages to hold that data. Those pages are accounted as shared memory (`Shmem`) in many memory reporting tools because `tmpfs` is implemented through the same shmem infrastructure used by shared memory mechanisms.

You can observe this through:

```bash
grep -E 'Shmem|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
```

Example fields:

```text
MemAvailable:   ...
Shmem:          ...
SwapTotal:      ...
SwapFree:       ...
```

`Shmem` includes memory used by tmpfs and shared memory mappings. It is not always only your manually mounted tmpfs directories.

---

## tmpfs and swap

A common misunderstanding is that `tmpfs` is always RAM-only.

More accurately:

- tmpfs contents are stored in virtual memory;
- active pages are usually in RAM;
- inactive pages may be swapped out if swap is enabled;
- if swap is disabled, tmpfs pressure competes only for RAM;
- if tmpfs fills memory and the system cannot reclaim enough pages, the system may hit OOM conditions.

This matters on production systems.

A large `tmpfs` mount does not immediately consume its full declared size. For example:

```bash
sudo mount -t tmpfs -o size=10G tmpfs /mnt/ramdisk
```

This does not instantly use 10 GiB of RAM. It only sets an upper limit. Memory is consumed as files are written.

But if a process actually writes 10 GiB of data there, the system must store those pages in RAM and/or swap.

---

## Size limits

A `tmpfs` mount can be limited with the `size` option:

```bash
sudo mount -t tmpfs -o size=512M tmpfs /mnt/ramdisk
```

The `size` value is a maximum limit, not preallocated memory.

You can inspect the size with:

```bash
df -h /mnt/ramdisk
```

You can remount with a different size without destroying existing contents:

```bash
sudo mount -o remount,size=1G /mnt/ramdisk
```

This is useful when a workload needs more temporary space, but it should be done carefully on shared systems.

---

## Inode limits

A filesystem can run out of inodes before it runs out of bytes.

This can happen when a workload creates many tiny files.

Check inode usage:

```bash
df -i /mnt/ramdisk
```

Set an inode limit:

```bash
sudo mount -t tmpfs -o size=512M,nr_inodes=100k tmpfs /mnt/ramdisk
```

If a tmpfs mount has plenty of free space but applications fail with errors like `No space left on device`, check both byte usage and inode usage:

```bash
df -h /mnt/ramdisk
df -i /mnt/ramdisk
```

---

## Mount options

Useful tmpfs mount options include:

| Option | Meaning |
|---|---|
| `size=512M` | Maximum filesystem size |
| `nr_inodes=100k` | Maximum number of inodes |
| `mode=1777` | Directory permissions |
| `uid=1000` | Owner user ID |
| `gid=1000` | Owner group ID |
| `noexec` | Prevent execution of binaries from the mount |
| `nosuid` | Ignore set-user-ID and set-group-ID bits |
| `nodev` | Do not interpret device files |

Example:

```bash
sudo mount -t tmpfs \
  -o size=512M,mode=1777,nosuid,nodev,noexec \
  tmpfs /mnt/scratch
```

Security-related options such as `nosuid`, `nodev`, and `noexec` are especially useful for temporary directories exposed to multiple users or untrusted workloads.

---

## Permissions and sticky bit

Temporary directories such as `/tmp` usually use mode `1777`:

```text
drwxrwxrwt
```

The final `t` is the sticky bit. It allows multiple users to create files in the directory, but prevents users from deleting files owned by other users.

For a shared temporary mount, this is usually important:

```bash
sudo mount -t tmpfs -o size=1G,mode=1777 tmpfs /mnt/shared-tmp
```

Without correct permissions, applications may fail in confusing ways.

---

## Persistent configuration with fstab

To mount tmpfs at boot, add an entry to `/etc/fstab`:

```fstab
tmpfs /mnt/scratch tmpfs defaults,size=1G,mode=1777,nosuid,nodev,noexec 0 0
```

Then apply it:

```bash
sudo mkdir -p /mnt/scratch
sudo mount -a
findmnt /mnt/scratch
```

Be careful with `/etc/fstab`. A bad entry can cause boot or mount problems. For remote servers, test carefully before rebooting.

---

## `/run` and runtime state

`/run` is commonly mounted as tmpfs.

It stores runtime state created after boot:

- PID files;
- sockets;
- lock files;
- service state;
- temporary daemon data.

Because `/run` is volatile, services must recreate their required directories and files at boot.

This is why systemd services often use options such as:

```ini
RuntimeDirectory=myapp
RuntimeDirectoryMode=0755
```

This tells systemd to create `/run/myapp` when the service starts.

---

## `/dev/shm` and shared memory

`/dev/shm` is usually a tmpfs mount used for POSIX shared memory.

Check it:

```bash
findmnt /dev/shm
```

Applications may use `/dev/shm` for fast IPC or shared memory objects. Databases, browsers, language runtimes, and containerized applications can be sensitive to the size of `/dev/shm`.

In Docker, the default `/dev/shm` size is often small for some workloads. This can break applications such as browsers or test runners.

Example Docker option:

```bash
docker run --shm-size=1g image-name
```

---

## `/tmp` on tmpfs

Some systems mount `/tmp` as tmpfs. Others keep `/tmp` on disk and clean it with systemd-tmpfiles or distribution-specific policies.

If `/tmp` is tmpfs:

- temporary file operations may be faster;
- files disappear after reboot;
- large temporary files consume memory/swap;
- builds that use `/tmp` heavily can cause memory pressure;
- applications expecting huge temporary disk space may fail.

Check:

```bash
findmnt /tmp
```

If `/tmp` is not tmpfs, the command may show a normal disk-backed filesystem.

---

## systemd-tmpfiles is related but different

`tmpfs` is a filesystem.

`systemd-tmpfiles` is a userspace mechanism for creating, cleaning, and managing temporary files and directories according to configuration rules.

They often interact because temporary directories and runtime directories may live on tmpfs, but they are not the same thing.

Examples:

```bash
systemd-tmpfiles --cat-config
systemd-tmpfiles --clean
systemd-tmpfiles --create
```

Typical config locations:

```text
/usr/lib/tmpfiles.d/
/etc/tmpfiles.d/
/run/tmpfiles.d/
```

Use `/etc/tmpfiles.d/` for local administrator overrides.

---

## Containers and tmpfs

Containers use tmpfs in several ways:

- `/dev/shm` inside containers;
- temporary mounts for secrets;
- writable runtime directories;
- isolated scratch space;
- Kubernetes `emptyDir` volumes with memory backing.

Docker example:

```bash
docker run --tmpfs /run:rw,noexec,nosuid,size=64m image-name
```

Docker Compose example:

```yaml
services:
  app:
    image: example/app
    tmpfs:
      - /run:size=64m,mode=755
      - /tmp:size=512m,mode=1777
```

A tmpfs mount in a container is still backed by the host kernel memory. It is isolated by mount namespaces, but it is not magic memory outside the host.

---

## Kubernetes memory-backed emptyDir

Kubernetes can mount an `emptyDir` volume backed by memory:

```yaml
volumes:
  - name: scratch
    emptyDir:
      medium: Memory
      sizeLimit: 512Mi
```

This behaves like tmpfs from the container's perspective.

Important point: memory used by this volume counts against the pod/container memory usage on many setups. If the application writes too much, it may trigger eviction or OOM behavior.

---

## Performance characteristics

`tmpfs` is fast because it avoids normal disk I/O.

However, performance is not infinite. It still involves:

- system calls;
- VFS operations;
- page allocation;
- memory accounting;
- possible swap activity;
- metadata operations;
- CPU cache and memory bandwidth limitations.

For many small temporary files, `tmpfs` can be much faster than disk. For very large files, memory pressure and swap can erase the advantage or make the system unstable.

The right question is not "Is tmpfs fast?" but:

> Is this data temporary, bounded, and safe to store in memory-backed storage?

---

## Security considerations

`tmpfs` can improve security because data disappears after reboot or unmount, but it should not be treated as secure deletion.

Important details:

- tmpfs data may be swapped to disk if swap is enabled;
- swap may persist depending on configuration;
- crash dumps, hibernation, or memory capture may expose data;
- processes with enough privilege can still read files while mounted;
- permissions still matter;
- `noexec`, `nosuid`, and `nodev` should be considered for untrusted temporary paths.

For sensitive secrets, tmpfs is useful, but it is only one layer. Consider swap encryption, secret lifetime, permissions, process isolation, and logging behavior.

---

## Operational risks

The most common tmpfs mistakes are:

1. treating tmpfs as free disk space;
2. allowing unbounded writes;
3. mounting `/tmp` as tmpfs without considering build workloads;
4. forgetting inode exhaustion;
5. forgetting that tmpfs may use swap;
6. using tmpfs for data that must survive reboot;
7. giving containers too small `/dev/shm`;
8. giving containers too large tmpfs mounts without memory limits;
9. not using `nosuid,nodev,noexec` for shared temporary areas;
10. ignoring tmpfs usage during memory troubleshooting.

---

## Troubleshooting tmpfs

### See all tmpfs mounts

```bash
findmnt -t tmpfs
```

### Check usage

```bash
df -h -t tmpfs
```

### Check inode usage

```bash
df -i -t tmpfs
```

### Check memory accounting

```bash
grep -E 'MemAvailable|Shmem|SwapTotal|SwapFree' /proc/meminfo
```

### Find large files under a tmpfs mount

```bash
sudo du -ah /run 2>/dev/null | sort -h | tail -n 20
```

### Find deleted-but-open files

```bash
sudo lsof +L1
```

Deleted-but-open files can still consume space until the process closes the file descriptor.

### Check mount options

```bash
findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,OPTIONS /run
```

---

## Practical experiment

Create a test mount:

```bash
sudo mkdir -p /mnt/tmpfs-lab
sudo mount -t tmpfs -o size=128M,mode=1777 tmpfs /mnt/tmpfs-lab
```

Check it:

```bash
df -h /mnt/tmpfs-lab
findmnt /mnt/tmpfs-lab
```

Write a file:

```bash
dd if=/dev/zero of=/mnt/tmpfs-lab/blob bs=1M count=64 status=progress
```

Observe:

```bash
df -h /mnt/tmpfs-lab
grep -E 'Shmem|MemAvailable|SwapFree' /proc/meminfo
```

Try to exceed the limit:

```bash
dd if=/dev/zero of=/mnt/tmpfs-lab/blob2 bs=1M count=128 status=progress
```

You should eventually see a `No space left on device` error.

Clean up:

```bash
sudo rm -f /mnt/tmpfs-lab/blob /mnt/tmpfs-lab/blob2
sudo umount /mnt/tmpfs-lab
sudo rmdir /mnt/tmpfs-lab
```

---

## When tmpfs is a good idea

Use tmpfs when the data is:

- temporary;
- bounded in size;
- safe to lose;
- performance-sensitive;
- recreated automatically;
- not required after reboot.

Good examples:

- runtime directories;
- short-lived build artifacts;
- test scratch space;
- IPC/shared memory;
- temporary secrets with proper swap/security considerations;
- container scratch directories;
- CI temporary workspace for small workloads.

---

## When tmpfs is a bad idea

Avoid tmpfs when:

- data must persist;
- workloads can generate unbounded output;
- memory is already tight;
- the system has no swap and no safety limits;
- huge builds write to `/tmp`;
- logs are stored there accidentally;
- users can write freely without quotas or limits.

---

## My mental model

I think of tmpfs as:

> A filesystem interface over virtual memory, useful for temporary data, but dangerous when mistaken for storage.

That mental model keeps the important parts visible:

- it looks like a filesystem;
- it behaves like temporary storage;
- it consumes memory;
- it may involve swap;
- it disappears;
- it needs limits.

---

## Commands worth remembering

```bash
findmnt -t tmpfs
```

```bash
df -h -t tmpfs
```

```bash
df -i -t tmpfs
```

```bash
grep -E 'Shmem|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
```

```bash
sudo mount -t tmpfs -o size=512M,mode=1777,nosuid,nodev,noexec tmpfs /mnt/scratch
```

```bash
sudo mount -o remount,size=1G /mnt/scratch
```

---

## References

- Linux kernel documentation: `Documentation/filesystems/tmpfs.rst`
- `man 5 tmpfs`
- `man 8 mount`
- `man 5 fstab`
- `man 5 proc_meminfo`
- `man 5 tmpfiles.d`
- `man 8 systemd-tmpfiles`
