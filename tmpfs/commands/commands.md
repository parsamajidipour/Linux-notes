# tmpfs command notes

## List tmpfs mounts

```bash
findmnt -t tmpfs
```

## Show disk-style usage for tmpfs mounts

```bash
df -h -t tmpfs
```

## Show inode usage

```bash
df -i -t tmpfs
```

## Inspect a specific mount

```bash
findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,OPTIONS /dev/shm
```

## Create a temporary tmpfs mount

```bash
sudo mkdir -p /mnt/scratch
sudo mount -t tmpfs -o size=512M,mode=1777,nosuid,nodev,noexec tmpfs /mnt/scratch
```

## Resize an existing tmpfs mount

```bash
sudo mount -o remount,size=1G /mnt/scratch
```

## Unmount

```bash
sudo umount /mnt/scratch
```

## Observe memory fields related to tmpfs/shmem

```bash
grep -E 'MemAvailable|Shmem|SwapTotal|SwapFree' /proc/meminfo
```

## Find large files in a tmpfs mount

```bash
sudo du -ah /run 2>/dev/null | sort -h | tail -n 20
```

## Find deleted files still held open by processes

```bash
sudo lsof +L1
```
