#!/usr/bin/env bash
set -euo pipefail

MOUNTPOINT="/mnt/tmpfs-lab"
SIZE="128M"

sudo mkdir -p "$MOUNTPOINT"
sudo mount -t tmpfs -o "size=$SIZE,mode=1777" tmpfs "$MOUNTPOINT"

echo "[+] Mounted tmpfs:"
findmnt "$MOUNTPOINT"

echo "[+] Before write:"
df -h "$MOUNTPOINT"
grep -E 'Shmem|MemAvailable|SwapFree' /proc/meminfo || true

echo "[+] Writing 64 MiB..."
dd if=/dev/zero of="$MOUNTPOINT/blob" bs=1M count=64 status=progress

echo "[+] After write:"
df -h "$MOUNTPOINT"
grep -E 'Shmem|MemAvailable|SwapFree' /proc/meminfo || true

echo "[+] Cleanup"
sudo rm -f "$MOUNTPOINT/blob"
sudo umount "$MOUNTPOINT"
sudo rmdir "$MOUNTPOINT"
