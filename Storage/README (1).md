# Storage

A comprehensive, practice-oriented reference on Linux storage — from the physical device up through partitioning, filesystems, volume management, RAID, performance, security, and troubleshooting.

Written for Linux administrators, DevOps engineers, and security engineers, and structured to double as LPIC/RHCSA-style exam preparation.

This series does not stop at *how* to run a command. Each chapter explains the underlying mechanism first, so that the commands make sense as consequences of that mechanism rather than as memorized incantations.

---

## Structure

Each numbered chapter below is a standalone Markdown file in this directory. Chapters build on each other roughly in order, but each is written to also stand alone as a reference you can jump into directly.

| # | Chapter | File | Status |
|---|---|---|---|
| 1 | Introduction to Linux Storage | `01-Introduction.md` | ✅ Complete |
| 2 | Physical Storage Devices | `02-Physical-Storage-Devices.md` | ⏳ Pending |
| 3 | Block Devices | `03-Block-Devices.md` | ⏳ Pending |
| 4 | Disk Partitioning | `04-Disk-Partitioning.md` | ⏳ Pending |
| 5 | Filesystems | `05-Filesystems.md` | ⏳ Pending |
| 6 | Mounting Filesystems | `06-Mounting-Filesystems.md` | ⏳ Pending |
| 7 | Persistent Mounts | `07-Persistent-Mounts.md` | ⏳ Pending |
| 8 | Storage Management Tools | `08-Storage-Management-Tools.md` | ⏳ Pending |
| 9 | Swap Space | `09-Swap-Space.md` | ⏳ Pending |
| 10 | Logical Volume Manager (LVM) | `10-LVM.md` | ⏳ Pending |
| 11 | RAID | `11-RAID.md` | ⏳ Pending |
| 12 | Storage Performance | `12-Storage-Performance.md` | ⏳ Pending |
| 13 | Storage Security | `13-Storage-Security.md` | ⏳ Pending |
| 14 | Troubleshooting Storage | `14-Troubleshooting.md` | ⏳ Pending |
| 15 | Best Practices | `15-Best-Practices.md` | ⏳ Pending |

---

## Who This Is For

- Linux administrators who need a real mental model of the storage stack, not just a list of commands.
- DevOps engineers responsible for provisioning, resizing, and monitoring storage in production.
- Security engineers who need to reason about encryption, permissions, and secure deletion at the storage layer.
- Anyone preparing for LPIC, RHCSA/RHCE, or similar Linux certification tracks.

## How to Read This

Chapters are meant to be read in order the first time through — each one assumes the concepts from the previous chapters. After that, use it as a reference: jump directly to the chapter you need.

Throughout the series you'll see four recurring callout types:

> **Note** — supplementary context worth knowing.
> **Tip** — a practical shortcut or habit worth adopting.
> **Warning** — a mistake that can cause data loss, downtime, or a broken boot.
> **Security Note** — a consideration specifically relevant to hardening or auditing a system.

---

*Part of the [Linux Notes](https://github.com/parsamajidipour/Linux-notes) repository.*
