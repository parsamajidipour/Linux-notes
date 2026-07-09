# Notes to self

- tmpfs size is a limit, not preallocated memory.
- tmpfs is backed by virtual memory, not strictly RAM only.
- tmpfs may use swap.
- `/dev/shm` being too small can break browsers, test runners, and some database workloads.
- `No space left on device` can mean bytes are full or inodes are exhausted.
- Deleted but open files can still consume tmpfs space.
- `nosuid,nodev,noexec` should be considered for shared temporary mounts.
- Do not put persistent logs or uploads on tmpfs unless losing them is acceptable.
