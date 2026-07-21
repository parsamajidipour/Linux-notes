# 15. Best Practices

The previous fourteen chapters covered each layer of the Linux storage stack in depth. This final chapter steps back to operational discipline — the practices that tie every layer together into a system you can actually run in production with confidence.

---

## 15.1 Capacity Planning

### 15.1.1 Plan From Actual Measurement, Not Intuition

Chapter 12 established that benchmarking beats guessing. The same principle applies to capacity planning: track actual growth trends (`df -h` history, ideally via a real monitoring system per 15.2) rather than provisioning based on a one-time estimate and hoping it holds.

```bash
# A simple growth-tracking habit — log usage over time
$ echo "$(date -Iseconds) $(df -h /data --output=used,avail | tail -1)" >> /var/log/disk-growth.log
```

### 15.1.2 Separate Growth-Prone Areas

Per Chapter 4's rationale for partitioning, isolating fast-growing data (`/var/log`, container image layers, database growth, upload directories) onto its own volume or LVM logical volume (Chapter 10) means unexpected growth threatens a contained area rather than the entire root filesystem — and, critically, LVM's online extension (Chapter 10, Section 10.3) means you can respond to that growth without downtime, *if* there's a volume group with headroom to extend into.

### 15.1.3 Leave Deliberate Headroom

- **In the volume group**: don't allocate 100% of a VG's capacity to logical volumes immediately — retaining free extents makes emergency extension (Chapter 10, Section 10.3) possible without adding new physical storage under time pressure.
- **In thin pools** (Chapter 10, Section 10.6): monitor actual physical utilization, not just nominal/virtual allocation, and alert well before the pool is genuinely full — thin pool exhaustion is a shared failure affecting every volume drawing from it.
- **On the filesystem itself**: most filesystems perform measurably worse as they approach full capacity (fragmentation, allocator search overhead) — treat "80% full" as a genuine action threshold on production systems, not just a cosmetic monitoring number.

> **Tip:** A practical capacity-planning rule of thumb: provision for projected usage 6–12 months out, keep at least 20% headroom on any volume that can't be trivially extended, and treat any volume approaching that threshold as an active planning item rather than a future problem.

---

## 15.2 Monitoring

### 15.2.1 What to Monitor — Consolidated From Every Chapter

| Signal | Chapter | Why It Matters |
|---|---|---|
| Filesystem space and inode usage | 5, 14.2 | Prevents disk-full outages; inode exhaustion is easy to miss without explicit monitoring |
| SMART health data | 2, 14.4 | Predictive — often catches failing hardware before total failure |
| RAID array state | 11 | A degraded array with no monitoring is redundancy in name only |
| LVM thin pool utilization | 10, 14.2.5 | Shared failure domain across multiple volumes |
| I/O latency and queue depth | 12 | Catches performance degradation before it becomes a user-visible incident |
| LUKS/encrypted volume unlock status | 13 | Confirms automated unlock at boot is actually succeeding, not silently failing to a degraded state |
| Swap activity | 9 | Sustained swapping indicates genuine memory pressure worth addressing at the root cause |

### 15.2.2 Alerting Discipline

Nearly every chapter's troubleshooting section noted the same failure pattern: monitoring configured once, never actually tested end-to-end, silently stops working (a changed mail relay, a renamed alert channel, a decommissioned notification endpoint) and nobody notices until the underlying problem it was supposed to catch actually occurs.

> **Warning:** An untested alert path is not meaningfully different from no monitoring at all — it creates false confidence, which is arguably worse than no monitoring, since it actively discourages the manual checking that would otherwise have caught the problem. Periodically (not just once, at initial setup) verify that alerts for SMART failures, RAID degradation, and capacity thresholds actually reach a human.

---

## 15.3 Backup Strategy

### 15.3.1 RAID Is Not a Backup (Restated Deliberately)

Chapter 11 made this point once; it's important enough to restate here as a standalone principle. RAID protects against drive failure. It does nothing against accidental deletion, ransomware, filesystem corruption that replicates across mirrors, application bugs that overwrite good data with bad, or a disaster affecting the whole physical system. A genuine backup strategy is a *separate* requirement, regardless of how robust the RAID/redundancy layer is.

### 15.3.2 The 3-2-1 Principle

A widely-used, simple heuristic worth adopting as a baseline:

- **3** copies of important data (the original plus two backups).
- **2** different storage media/types (not two backups on identical drives sharing the same failure modes).
- **1** copy stored off-site (protecting against physical disaster — fire, theft, site-wide failure — affecting the primary location).

### 15.3.3 Snapshots Are a Component, Not a Complete Backup Strategy

Btrfs snapshots (Chapter 5, Section 5.4.1) and LVM snapshots (Chapter 10, Section 10.5) are extremely valuable for fast rollback of recent changes — but they typically live on the *same* physical storage as the data they're protecting. A drive failure, and in many cases the RAID array's own catastrophic failure, takes the snapshots down with the live data. Snapshots are an excellent complement to genuine off-system backups, not a replacement for them.

### 15.3.4 Test Restores, Not Just Backups

A backup that has never been restored is an unverified assumption, not a working safety net. Periodically actually restore from backup (to a test environment, not production) to confirm the backup is complete, uncorrupted, and that the restore procedure itself works and is documented well enough to execute correctly under the stress of a real incident.

> **Security Note:** Encrypted volumes (Chapter 13) complicate backup strategy in one specific way worth planning for deliberately: backups of encrypted data are only useful if the encryption keys are also backed up (securely, and separately from the data itself) — losing the LUKS key material means the backup, however complete, is permanently unreadable. Include key/keyfile backup explicitly in any backup strategy involving encrypted volumes.

---

## 15.4 Performance Optimization — Consolidated Checklist

Restating Chapter 12's checklist as part of the final operational summary:

- Choose the right physical device type for the actual access pattern (Chapter 2).
- Align partitions correctly — modern tooling defaults handle this; don't override without reason (Chapter 4).
- Choose the filesystem suited to the workload — general-purpose (ext4), high-throughput/parallel (XFS), or snapshot/integrity-focused (Btrfs) (Chapter 5).
- Apply appropriate mount options (`noatime`, `discard` where relevant) (Chapter 6).
- Match the I/O scheduler to the device type — `none` for NVMe, `mq-deadline`/`bfq` for HDD/SATA SSD (Chapter 12).
- Separate independent high-I/O workloads across different physical devices where contention would otherwise be an issue (Chapter 12).
- Benchmark before and after any tuning change, with a workload pattern that actually resembles production (Chapter 12).

---

## 15.5 Production Recommendations

### 15.5.1 A Reasonable Default Stack for a General-Purpose Server

- **Partitioning**: GPT (Chapter 4), minimal static partitions (ESP, `/boot`, and a large LVM physical volume).
- **Filesystem**: ext4 for general use, XFS if the workload is large-file/high-throughput oriented (Chapter 5).
- **Volume management**: LVM for flexibility (Chapter 10), with deliberate headroom retained in the volume group.
- **Redundancy**: RAID 1 or RAID 10 for boot/critical data, RAID 6 for large bulk-storage arrays where rebuild-window risk matters (Chapter 11).
- **Encryption**: LUKS on any volume containing sensitive data, configured from initial provisioning rather than retrofitted later (Chapter 13).
- **Monitoring**: SMART (`smartd`), RAID state, capacity/inode thresholds, and I/O latency, all with tested alerting (15.2).
- **Backup**: 3-2-1 principle, with periodically tested restores, independent of whatever RAID/snapshot capability exists locally (15.3).

### 15.5.2 Documentation as an Operational Practice

Every non-obvious storage decision — why a particular filesystem was chosen, why a mount carries a specific option, why a RAID level was selected over an alternative — is worth a brief comment or entry in system documentation. The reasoning that's obvious at setup time is rarely obvious eighteen months later during an incident at an inconvenient hour, and the fastest possible troubleshooting is troubleshooting where the "why" is already documented rather than needing to be reverse-engineered under pressure.

---

## 15.6 Common Mistakes to Avoid — Full-Series Summary

Drawing together the recurring themes from every chapter's own mistakes section:

- **Hard-coding unstable identifiers** — `/dev/sdX` in `fstab` or scripts instead of `UUID=` (Chapters 3, 7).
- **Treating RAID as a backup** (Chapters 11, 15.3).
- **Ignoring inode exhaustion** as a distinct failure mode from byte-space exhaustion (Chapters 5, 14).
- **Skipping TRIM/discard configuration on SSDs**, leading to unexplained performance degradation over time (Chapter 2, 12).
- **Choosing RAID 5 for large modern arrays** without accounting for rebuild-window risk (Chapter 11).
- **Shrinking an LVM logical volume before shrinking its filesystem** — the reverse of the safe order (Chapter 10).
- **Deferring encryption to "later"** rather than provisioning it from the start, especially given the SSD-specific difficulty of reliable after-the-fact secure deletion (Chapter 13).
- **Configuring monitoring/alerting once and never testing it again** (Chapters 11, 14, 15.2).
- **Benchmarking or troubleshooting with a workload pattern that doesn't match the real one** — sequential vs. random, the single most common source of misleading storage performance conclusions (Chapter 12).
- **Not testing backup restores**, discovering gaps only during an actual incident (15.3.4).

---

## 15.7 Closing Framework: The Five Questions, Revisited

Chapter 1 opened with five questions every storage decision ultimately answers. Having covered the full stack, they're worth revisiting as a final lens for any future storage decision:

1. **Where does a byte of data physically live?** — Chapters 2–4 (physical devices, block devices, partitioning).
2. **How does the kernel find it again?** — Chapters 3, 5 (device naming, filesystem structures).
3. **What guarantees exist that it survives a crash, reboot, or disk failure?** — Chapters 5, 9–11 (journaling, swap, LVM, RAID).
4. **How fast can it be read or written, and under what conditions does that degrade?** — Chapter 12 (performance).
5. **Who is allowed to read or write it, and how is that enforced?** — Chapter 13 (security).

Every storage problem you'll encounter as a Linux administrator, DevOps engineer, or security engineer maps onto one or more of these five questions. When a new, unfamiliar situation arises that isn't explicitly covered in this series, returning to this framework — and to the layered stack diagram from Chapter 1 — is the most reliable way to reason through it correctly.

---

*Previous: [14-Troubleshooting.md](./14-Troubleshooting.md)*

*This concludes the Storage series. Return to [README.md](./README.md) for the full index.*
