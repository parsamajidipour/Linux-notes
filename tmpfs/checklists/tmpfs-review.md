# tmpfs review checklist

Use this before adding a tmpfs mount to a server, container, or CI environment.

## Data safety

- [ ] Data stored here is disposable.
- [ ] Data does not need to survive reboot.
- [ ] Applications can recreate required directories/files after boot.

## Sizing

- [ ] `size=` is explicitly set.
- [ ] Inode usage was considered for workloads with many small files.
- [ ] Memory limit/container limit was considered.
- [ ] Swap behavior was considered.

## Security

- [ ] `nosuid` is used where appropriate.
- [ ] `nodev` is used where appropriate.
- [ ] `noexec` is used where appropriate.
- [ ] Permissions and sticky bit are correct for shared temporary directories.
- [ ] Sensitive data risk was reviewed if swap is enabled.

## Operations

- [ ] Monitoring includes tmpfs byte usage.
- [ ] Monitoring includes inode usage.
- [ ] Failure mode is understood when the mount fills.
- [ ] The mount is tested before production use.
- [ ] fstab entries are tested with `mount -a` before reboot.
