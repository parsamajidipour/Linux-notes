# 12. Storage Performance

Every prior chapter has referenced performance concepts in passing — this chapter makes them precise. Understanding IOPS, throughput, latency, and queue depth as distinct, related-but-different measurements is the foundation for correctly benchmarking, tuning, and troubleshooting storage performance.

---

## 12.1 The Four Core Metrics

### 12.1.1 IOPS (I/O Operations Per Second)

The count of individual read or write operations a device/system completes per second, regardless of how much data each operation moves. IOPS matters most for **random-access, small-transfer workloads** — database lookups, metadata-heavy filesystem operations, many small files.

### 12.1.2 Throughput (Bandwidth)

The volume of data moved per unit time, typically expressed in MB/s or GB/s. Throughput matters most for **large, sequential transfers** — bulk file copies, streaming media, backups, large sequential database scans.

**Relationship between IOPS and throughput:**

```
Throughput = IOPS × Average I/O size
```

This relationship explains a common source of confusion: a device can post *impressive* throughput numbers on large sequential transfers while performing *poorly* on IOPS-bound random workloads, or vice versa. Always ask which of the two actually matters for the workload in question before evaluating a benchmark number in isolation.

### 12.1.3 Latency

The time elapsed between issuing an I/O request and receiving its completion. Unlike IOPS and throughput (which describe aggregate capacity), latency describes the experience of a *single* operation — and it's what applications and users actually feel. High IOPS/throughput numbers achieved via extreme parallelism can coexist with poor per-operation latency; the two are related but not interchangeable.

### 12.1.4 Queue Depth

The number of I/O requests allowed to be outstanding (issued but not yet completed) simultaneously. Higher queue depths let a device (particularly NVMe, per Chapter 2's discussion of its massive queue support) work on many requests in parallel, generally increasing achievable IOPS and throughput — but often at the cost of increased latency for any *individual* request, since it may sit in queue behind others.

```
   Low Queue Depth (QD=1)          High Queue Depth (QD=32)
   ┌───┐                            ┌───┬───┬───┬───┬───┐
   │ 1 │ → complete → next            │ 1 │ 2 │ 3 │...│32 │ → all in flight
   └───┘                            └───┴───┴───┴───┴───┘
   Lower per-op latency              Higher aggregate throughput/IOPS,
   Lower aggregate throughput         higher per-op latency under load
```

> **Note:** Benchmark numbers advertised by manufacturers are frequently measured at high queue depths specifically because that's where the largest numbers appear — a drive's "headline" random IOPS figure at QD=32 or QD=64 can look dramatically better than its QD=1 performance, which is what a single-threaded application actually experiences. Always check what queue depth a benchmark number was measured at before comparing devices or trusting a spec sheet figure as representative of your actual workload.

---

## 12.2 `iostat` — Real-Time and Historical I/O Statistics

`iostat` (part of the `sysstat` package) is the primary tool for observing these metrics live on a running system.

```bash
# Basic extended stats, updated every 2 seconds
$ iostat -x 2

Device            r/s     w/s   rMB/s   wMB/s  r_await  w_await  aqu-sz  %util
nvme0n1          45.00  120.00    5.20   48.30     0.12     0.45    0.08  12.30
sda               2.00    8.00    0.10    1.20     4.50    12.30    0.15   8.20
```

Key columns:

| Column | Meaning |
|---|---|
| `r/s` / `w/s` | Read/write operations per second (IOPS, split by direction) |
| `rMB/s` / `wMB/s` | Throughput, read/write |
| `r_await` / `w_await` | Average latency (ms) for reads/writes, including queue wait time |
| `aqu-sz` | Average queue depth actually observed |
| `%util` | Percentage of time the device had at least one I/O request outstanding — **not** a direct measure of saturation for devices capable of parallel I/O (see warning below) |

```bash
# Per-CPU stats alongside device stats — useful for spotting CPU-bound vs I/O-bound bottlenecks
$ iostat -xz 1

# Only show active devices (skip idle ones with zero activity)
$ iostat -xz 1 -p ALL
```

> **Warning:** `%util` is frequently misread as "the device is X% saturated." For a traditional single-queue HDD, that interpretation is roughly correct. For a modern NVMe device capable of servicing thousands of requests in parallel, `%util` at 100% only means the device was busy with *at least one* request the entire time — it says nothing about how much *more* capacity remained available. For NVMe/high-queue-depth devices, `aqu-sz` and `r_await`/`w_await` are far more meaningful saturation indicators than `%util` alone.

---

## 12.3 Benchmarking with `fio`

`iostat` observes existing workloads; `fio` (Flexible I/O tester) generates controlled, configurable synthetic workloads for deliberate benchmarking — the standard tool for actually answering "what can this storage do" rather than "what is it currently doing."

```bash
# Random 4K read IOPS test, simulating database-like access
$ sudo fio --name=randread --filename=/data/testfile --size=1G \
    --rw=randread --bs=4k --iodepth=32 --numjobs=4 --runtime=30 \
    --time_based --group_reporting

# Sequential throughput test
$ sudo fio --name=seqwrite --filename=/data/testfile --size=1G \
    --rw=write --bs=1M --iodepth=1 --numjobs=1 --runtime=30 \
    --time_based --group_reporting

# Mixed random read/write, simulating a realistic OLTP-style workload
$ sudo fio --name=mixed --filename=/data/testfile --size=1G \
    --rw=randrw --rwmixread=70 --bs=4k --iodepth=16 --numjobs=4 \
    --runtime=60 --time_based --group_reporting
```

Key `fio` parameters to understand:

| Parameter | Meaning |
|---|---|
| `--rw=` | Access pattern: `read`, `write`, `randread`, `randwrite`, `randrw` |
| `--bs=` | Block size per I/O operation — small (4k) for IOPS-focused tests, large (1M) for throughput tests |
| `--iodepth=` | Queue depth to simulate |
| `--numjobs=` | Number of parallel worker threads/processes |
| `--size=` | Total data size per job |
| `--direct=1` | Bypass the page cache, testing the actual device rather than cached memory — usually essential for a meaningful device-level benchmark |

> **Tip:** Always set `--direct=1` when benchmarking actual device performance — without it, `fio` (like any application) may be measuring page cache speed (essentially RAM speed) for at least part of the test rather than genuine device I/O, producing misleadingly excellent numbers that don't reflect real device capability, especially for a test file smaller than available RAM.

> **Warning:** Benchmark against a workload pattern that actually resembles your real application — a sequential large-block throughput test tells you very little about how a device will perform under a random small-block database workload, and vice versa (12.1.2). Design the `fio` job to mirror the access pattern you actually care about, not a generically "impressive" configuration.

---

## 12.4 I/O Schedulers

The kernel's block layer (Chapter 1) applies an I/O scheduler to decide the order and grouping of queued requests before submission to the device. The right scheduler choice depends on the underlying device type.

```bash
# View available and currently active scheduler for a device
$ cat /sys/block/sda/queue/scheduler
[mq-deadline] kyber bfq none

# Change scheduler temporarily
$ echo bfq | sudo tee /sys/block/sda/queue/scheduler
```

| Scheduler | Best Suited For | Behavior |
|---|---|---|
| `none` (no-op) | NVMe SSDs | Minimal overhead — the device's own internal parallelism handles ordering better than the kernel guessing |
| `mq-deadline` | General-purpose, SATA SSDs, HDDs | Ensures bounded maximum latency per request while still allowing reasonable merging/reordering |
| `bfq` (Budget Fair Queueing) | Desktop/interactive workloads, HDDs with mixed workloads | Prioritizes fairness and interactive responsiveness over raw throughput — can add overhead unsuitable for high-IOPS NVMe |
| `kyber` | Fast SSDs/NVMe with latency-sensitive mixed workloads | Lightweight latency-target-based scheduling, a middle ground between `none` and `bfq` |

> **Note:** For NVMe devices specifically, `none` is frequently the correct choice, precisely because the device's own massive internal queue depth and controller intelligence (Chapter 2, Section 2.4) generally outperforms additional kernel-side reordering — the scheduler's traditional job of compensating for a slow, single-queue device doesn't apply the same way to hardware designed for deep native parallelism.

---

## 12.5 Performance Tuning Checklist

- **Verify TRIM/discard is active** on SSDs (Chapter 2, Section 2.3.2) — a frequently overlooked cause of gradual SSD slowdown.
- **Check partition alignment** (Chapter 4, Section 4.6) — misalignment silently doubles physical I/O for straddling writes.
- **Match the I/O scheduler to the device type** (12.4) — `none` for NVMe, `mq-deadline`/`bfq` for HDDs and general SATA SSDs.
- **Consider `noatime`/`relatime` mount options** (Chapter 6, Section 6.6) to eliminate unnecessary metadata write overhead from every read operation, particularly beneficial on read-heavy, high-IOPS workloads.
- **Separate high-I/O workloads across independent devices** where possible (e.g., a database's data files and its write-ahead log on physically separate devices) to avoid contention between sequential-log-write patterns and random-data-access patterns competing for the same queue.
- **Right-size `vm.swappiness`** (Chapter 9, Section 9.5) so the kernel isn't reclaiming memory in a way that fights against a storage-sensitive workload's actual needs.
- **Benchmark with a representative workload pattern** (12.3) before and after any tuning change — intuition about what "should" help is frequently wrong, and only measurement settles it.
- **Watch queue depth and latency, not just raw IOPS/throughput headline numbers**, when evaluating whether a device or configuration actually fits the target workload (12.1.4).

---

## 12.6 Common Mistakes

- **Comparing sequential throughput benchmarks when the real workload is random I/O**, or vice versa — the two measurements answer fundamentally different questions (12.1.2).
- **Benchmarking without `--direct=1`**, unintentionally measuring page cache/RAM speed rather than actual device performance.
- **Reading `%util` as a direct saturation percentage on NVMe devices**, missing genuine remaining capacity (12.2).
- **Leaving the default I/O scheduler unexamined on NVMe storage**, when `none` frequently performs better by avoiding redundant kernel-side reordering.
- **Tuning based on assumption rather than measurement** — changing scheduler, mount options, or `swappiness` without a before/after benchmark to confirm the change actually helped the specific workload in question.
- **Testing on a mostly-idle system and extrapolating to production load**, missing contention effects that only appear under realistic concurrent, multi-tenant I/O.

---

## 12.7 Troubleshooting Performance Issues

| Symptom | Likely Area to Investigate | Diagnostic Step |
|---|---|---|
| High application latency, moderate IOPS | Queue depth saturation, wrong scheduler | `iostat -x 1` — check `r_await`/`w_await` and `aqu-sz` |
| Good sequential benchmark, poor real-world database performance | Workload mismatch — device tested with the wrong access pattern | Re-benchmark with `fio --rw=randrw --bs=4k` to match actual pattern |
| SSD performance degrading over weeks/months | TRIM not running, garbage collection saturation | `fstrim -v /`, check `discard` mount option or `fstrim.timer` status |
| High `%util` reported but application isn't obviously I/O-bound | Misleading `%util` interpretation on a parallel-capable NVMe device | Cross-check with `aqu-sz` and actual latency, not `%util` alone |
| Storage performance fine in isolation, poor under real production load | Contention between multiple concurrent workloads sharing the device | `iostat -x 1` during actual production load; consider workload separation across devices |

> **Security Note:** Storage performance monitoring tools like `iostat` and `fio` can reveal information about workload patterns (timing and volume of I/O activity can, in some scenarios, leak information about what an application is doing) — exercise the same access-control discipline around performance monitoring output and historical logs as you would around any other operational telemetry, particularly on shared or multi-tenant systems.

---

*Previous: [11-RAID.md](./11-RAID.md) — Next: 13-Storage-Security.md*
