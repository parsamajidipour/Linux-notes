# Boot Process and Targets

A complete, mechanism-level trace of what actually happens between the kernel handing off control and a fully booted, interactive system — the initramfs boundary, the full target chain from `sysinit.target` through `default.target`, exactly where the generator-driven mount-unit creation from `04-Unit-Files.md` Section 7.2 fits into that sequence, how emergency and rescue paths are reached when a step fails, the kernel command-line switches that alter boot behavior, and the mirror-image shutdown sequence that tears the same structure back down in reverse.

Every prior document in this series examined units and their relationships in isolation or in small worked groups. This document is where the *whole system's* boot sequence is assembled from those same pieces into one continuous, ordered narrative — the single largest, most consequential transaction systemd ever computes, and the one every other transaction discussed so far is, structurally, a smaller special case of.

---

## 1. The Full Boot Timeline: Kernel to PID 1

### 1.1 Before systemd exists at all

Before any systemd process runs, the kernel itself performs its own initialization — detecting hardware, mounting an initial root filesystem, and ultimately executing whatever binary is configured as `init` on that initial root. On the overwhelming majority of modern Linux systems, that initial root is **not** the final, real root filesystem at all — it's a small, temporary filesystem image called the **initramfs** (Section 2), and the binary executed there is very often a minimal systemd instance, not the full systemd that will eventually manage the running system.

Strictly before even the kernel's own initialization, a **bootloader** (GRUB being the dominant example on most distributions, though `systemd-boot` — a separate, much simpler UEFI-native bootloader that is itself part of the broader systemd project — is increasingly common) is what firmware hands control to first, and it's the bootloader, not the kernel or systemd, that actually reads its own configuration to determine which kernel image to load, which initramfs image to load alongside it, and what kernel command-line parameters (Section 10) to pass. This detail matters for troubleshooting specifically because it establishes a clean division of responsibility worth keeping straight: a wrong or outdated *kernel* being booted, or a kernel command-line parameter not taking effect, is a bootloader-configuration problem (regenerating a GRUB config, or editing a `systemd-boot` entry file) entirely outside anything covered in this document; everything from Section 1.2 onward assumes the bootloader has already correctly handed off to the intended kernel and initramfs, and begins its own account of the sequence only from that handoff point forward.

The kernel's own boot messages, visible via `journalctl -k` or the traditional `dmesg`, cover this pre-userspace phase — device detection, driver loading, initial memory setup — entirely before any systemd concept applies at all. `systemd-analyze time`'s `+Ns (kernel)` component (`02-Units-and-Dependencies.md` Section 10.1) is measuring precisely this phase, bounded by kernel timestamps rather than anything systemd itself tracks internally, since by definition nothing systemd-related is running yet during it.

### 1.2 The initramfs handoff

Once the kernel has mounted the initramfs and executed its `init` (again, typically a systemd instance, though historically often a simpler custom script), that environment's job is narrow and specific: assemble enough of a working system — loading whichever kernel modules the *real* root filesystem's storage controller needs, unlocking any encrypted volumes, activating LVM or software RAID if the real root lives on top of one — to be able to locate and mount the real, final root filesystem, and then hand off to it.

This handoff is called **`switch-root`**, and it is a genuinely different operation from an ordinary mount: it doesn't merely mount the real root somewhere and `chroot()` into it — a `chroot()` alone would leave the initramfs's own processes, mounts, and memory-resident filesystem lingering underneath, wasting memory and creating a confusing, layered mount namespace for the rest of the system's lifetime. `switch-root` instead moves the already-mounted real root to become the process tree's actual `/`, and recursively deletes everything that made up the initramfs's own temporary filesystem from memory, before finally executing the *real*, final systemd binary as the new PID 1 — a genuinely fresh process image, not a continuation of the initramfs's own systemd instance, even though both are, on most distributions, literally the same binary.

### 1.3 Why the distinction between "an initramfs systemd" and "the real systemd" matters

It's worth being precise about this because a confusing symptom category — "my unit runs fine normally but something is different very early in boot" — often traces directly back to confusing these two systemd instances. The initramfs's systemd instance loads an entirely different, much smaller set of units, from an entirely different unit search path (typically baked directly into the initramfs image itself, not `/etc/systemd/system/` on the real root, which isn't even mounted yet at that point) — a unit file living in `/etc/systemd/system/` on your real, final root filesystem is invisible to, and has no effect on, anything happening during the initramfs phase, because that unit file doesn't exist yet from the initramfs environment's point of view. Modifying initramfs-phase behavior (adding a kernel module load, changing how an encrypted root is unlocked) requires modifying the initramfs image itself — via `dracut` or `mkinitcpio`, depending on distribution — and regenerating it, an entirely separate workflow from anything covered in `04-Unit-Files.md`.

---

## 2. The initramfs Boundary in Detail

### 2.1 What the initramfs systemd instance actually does

A minimal but representative initramfs-phase target chain looks structurally similar to the real boot's own early targets (Section 3), scaled down to only what's needed to reach the real root:

```
initrd.target
├─ initrd-fs.target        (real root mounted read-only under /sysroot)
│  └─ sysroot.mount
├─ cryptsetup.target        (LUKS volumes unlocked, if applicable)
└─ lvm2-activation.target   (LVM volume groups activated, if applicable)
```

`sysroot.mount` — the unit responsible for mounting the eventual real root filesystem at the temporary path `/sysroot` within the initramfs's own namespace — is the pivotal unit in this chain; everything else in the initramfs phase exists to make this one mount possible (unlocking the encrypted device it lives on, activating the volume group containing it, loading the specific storage driver its underlying hardware requires). Once `initrd-fs.target` is reached, `systemd` in the initramfs invokes `systemd-fstab-generator`-adjacent logic one final time against `/sysroot`, executes any last-minute `initrd-cleanup.service`-style teardown, and then hands off, via `switch-root`, exactly as described in Section 1.2.

### 2.2 `dracut` and `mkinitcpio`

These are the two dominant tools (the former on Fedora/RHEL-family and Debian/Ubuntu, the latter on Arch-family distributions) responsible for **assembling** the initramfs image in the first place — bundling the kernel modules, the systemd binary itself, and a minimal set of supporting libraries and unit files into a compressed cpio archive the kernel can load directly into memory at boot. Regenerating the initramfs (`dracut -f`, or `mkinitcpio -P`) is required after certain classes of change — installing a new kernel, changing which modules are needed to reach the root filesystem (switching to a different storage controller, adding disk encryption) — precisely because the resulting image is a **built artifact**, not something read fresh from the real root's own filesystem at boot time; the real root, by definition, isn't mounted yet at the point the initramfs's own configuration would need to be consulted.

### 2.3 Diagnosing an initramfs-phase failure

Because the real root isn't mounted yet, an initramfs-phase failure has no access to the eventual, persistent journal on the real disk (`06-journald-and-Logging.md` covers journal persistence in depth) — diagnostic output during this phase is either shown directly on the console, or, if the initramfs itself is configured to retain a small in-memory journal, that fragment can sometimes be inspected *after* a successful boot via `journalctl --boot=-0 --catalog` filtering for the earliest timestamps, though availability varies by distribution's specific initramfs configuration. `rd.break` (Section 6) is the standard kernel command-line mechanism for dropping into an interactive shell **within** the initramfs itself, before `switch-root` occurs, specifically to debug a failure at this exact boundary — mounting the intended real root manually, checking whether the expected device nodes exist, and generally diagnosing why the automated `sysroot.mount` unit failed, entirely from within the constrained initramfs environment itself.

---

## 3. Early Boot Targets: `sysinit.target` and Its Prerequisites

Once `switch-root` has occurred and the real systemd is running as PID 1 on the real root filesystem, the target chain `01-Introduction.md` Section 8 named in overview is where the detailed sequencing actually happens.

### 3.1 The prerequisite chain feeding `sysinit.target`

```
sysinit.target
├─ local-fs.target
│  └─ (every non-network .mount unit, per 04-Unit-Files.md Section 7.2's
│      fstab-generator output, plus any hand-authored .mount units)
├─ swap.target
│  └─ (every .swap unit)
├─ cryptsetup.target
│  └─ (any LUKS volumes not already unlocked during the initramfs phase)
├─ systemd-udevd.service    (device management daemon starts)
├─ systemd-udev-trigger.service   (existing devices are (re-)announced)
├─ systemd-modules-load.service   (kernel modules listed in /etc/modules-load.d/)
├─ systemd-sysctl.service   (kernel parameters from /etc/sysctl.d/ applied)
└─ systemd-tmpfiles-setup.service (temporary/volatile files and directories
                                    created per /etc/tmpfiles.d/, referenced
                                    briefly in 01-Introduction.md Section 3's
                                    component table)
```

`sysinit.target` itself, per the `DefaultDependencies=` mechanism covered in `02-Units-and-Dependencies.md` Section 4, is what nearly every other unit on the system implicitly orders itself `After=`, without any unit author needing to write that ordering by hand — it represents the single synchronization point "the fundamental filesystem, device, and kernel-parameter groundwork is complete," and virtually nothing meaningful can happen before it, which is precisely why it's baked into the implicit-dependency default rather than left to be declared per-unit.

### 3.2 Why `local-fs.target` specifically gates so much

`local-fs.target`'s dependency closure is where every generator-produced `.mount` unit (`04-Unit-Files.md` Section 7.2) actually lives, and it's worth being explicit about the causal chain: `/etc/fstab` is read by `systemd-fstab-generator` **very early**, before `sysinit.target` is even reachable, specifically so that the resulting `.mount` units can be woven into this exact prerequisite position — a mount unit generated too late to participate in `local-fs.target`'s own dependency closure would be useless for gating anything that assumes local storage is available by the time `sysinit.target` is reached, which is the assumption nearly the entire rest of the boot sequence implicitly relies on. This is also, concretely, where the `nofail`-versus-not distinction from `04-Unit-Files.md` Section 7.2 has its real consequence: a non-`nofail` mount failing here fails `local-fs.target`'s own start job via ordinary `Requires=`-propagation (`02-Units-and-Dependencies.md` Section 13.1's failure-walkthrough pattern, playing out at the scale of the entire early-boot sequence rather than one application stack), which in turn fails `sysinit.target`, which — because virtually everything else implicitly depends on `sysinit.target` — is the single most common structural cause of a boot dropping into the emergency shell described in Section 9, rather than proceeding to a normal login prompt.

### 3.3 Generators, generally

`systemd-fstab-generator` is the running example throughout this series, but it's one member of a broader **generator** mechanism: any executable placed in specific well-known directories (`/usr/lib/systemd/system-generators/`, among others) and run automatically, very early, by PID 1 itself, before unit loading proper begins — each generator's job is to inspect the system (parse `/etc/fstab`, read kernel command-line parameters, or whatever else its specific purpose is) and emit ordinary unit files into a runtime-only directory systemd then loads alongside the statically-authored ones. `systemd-cryptsetup-generator` (translating `/etc/crypttab` entries into `.service`/dependency structures for unlocking encrypted volumes), `systemd-system-update-generator`, and `systemd-getty-generator` (Section 8) are further examples of the same underlying mechanism applied to different configuration sources — the pattern established concretely for mounts in `04-Unit-Files.md` Section 7.2 generalizes across a genuinely wide swath of early-boot configuration, not just filesystems.

### 3.4 The Three Early-Boot Configuration Services, in Detail

`systemd-modules-load.service`, `systemd-sysctl.service`, and `systemd-tmpfiles-setup.service` from Section 3.1's chain are worth a closer look individually, since each reads from its own `.d`-style directory convention — the same layered, drop-in-friendly pattern established for unit-file overrides in `04-Unit-Files.md` Section 3, applied here to system-wide configuration rather than a single unit.

```
# /etc/modules-load.d/webapp.conf
# One kernel module name per line, loaded by systemd-modules-load.service
br_netfilter
```

```
# /etc/sysctl.d/99-webapp.conf
# Kernel parameters applied by systemd-sysctl.service, equivalent to
# `sysctl -w` invocations run automatically during sysinit.target
net.core.somaxconn=4096
vm.swappiness=10
```

```
# /etc/tmpfiles.d/webapp.conf
# Directory/file creation and cleanup rules applied by
# systemd-tmpfiles-setup.service — the declarative, boot-time-integrated
# alternative to an ad hoc mkdir in a startup script
d /run/webapp 0750 webapp webapp -
```

That last example — a `d` line in a `tmpfiles.d` configuration file — is worth connecting directly back to `04-Unit-Files.md` Section 4.7's `RuntimeDirectory=` directive: `RuntimeDirectory=` is, under the hood, essentially a *unit-scoped* shorthand for exactly this same `tmpfiles.d`-style directory-creation mechanism, tied to a specific unit's own lifecycle rather than applied unconditionally at every boot regardless of whether any specific unit needs it. For a directory that should exist independent of any single service's own start/stop cycle — shared across multiple units, or needed even when no unit referencing it happens to be currently running — a standalone `tmpfiles.d` entry, processed once during `sysinit.target`'s own prerequisite chain, is the more appropriate of the two mechanisms; for a directory that conceptually belongs to one specific service and should track that service's own lifecycle, `RuntimeDirectory=` remains the better fit, exactly as `04-Unit-Files.md` recommended.

`systemd-tmpfiles` (the same underlying binary `systemd-tmpfiles-setup.service` invokes at boot) is also run periodically thereafter via `systemd-tmpfiles-clean.timer` — the subject of `07-Timers-and-Scheduled-Tasks.md` — handling ongoing cleanup of aged-out temporary files (`/tmp` entries older than a configured threshold, for instance) as a ongoing, scheduled operation distinct from the one-time, boot-only creation pass described here.

---

## 4. `basic.target`: The Midpoint

Between `sysinit.target` and the final, user-facing targets sits `basic.target`, gating on a further set of lower-level infrastructure targets rather than individual units directly:

```
basic.target
├─ sysinit.target       (per Section 3, already satisfied by this point)
├─ paths.target          (every enabled .path unit is now watching)
├─ sockets.target        (every enabled .socket unit is now listening,
│                         per 02-Units-and-Dependencies.md Section 11's
│                         socket-activation mechanism)
├─ timers.target         (every enabled .timer unit is now scheduled,
│                         subject of 07-Timers-and-Scheduled-Tasks.md)
└─ slices.target         (the top-level cgroup slice hierarchy, per
                           02-Units-and-Dependencies.md Section 12,
                           is established)
```

The practical significance of `basic.target` as a distinct synchronization point, separate from `sysinit.target`: by the time it's reached, every socket-activated service (`02-Units-and-Dependencies.md` Section 11) has its listening socket bound and ready to queue connections, every path unit is watching, and every timer is scheduled — meaning ordinary application services, ordered `After=basic.target` (which, per `02-Units-and-Dependencies.md` Section 4, is injected implicitly for normal service units via `DefaultDependencies=yes`), can safely assume these lower-level activation mechanisms are already fully operational the moment they themselves begin starting, without each individual service needing its own explicit ordering against `sockets.target`/`paths.target`/`timers.target` by hand.

---

## 5. `multi-user.target` versus `graphical.target`: The Final Stretch

With `basic.target` reached, the boot sequence forks into the genuinely user-facing, highly parallel final phase — the phase where the vast majority of application services (`sshd.service`, `nginx.service`, a database, and everything else covered by name throughout `02-`/`03-Units-and-Dependencies.md`) actually start, per whichever units are wired into `multi-user.target.wants/` via `enable`, exactly as `01-Introduction.md` Section 6 first described the symlink mechanism.

`graphical.target`, where applicable, is layered directly on top:

```ini
# graphical.target's own [Unit] section, conceptually
[Unit]
Requires=multi-user.target
Wants=display-manager.service
After=multi-user.target
Conflicts=rescue.target
```

This is a direct, concrete instance of the target-composability pattern `01-Introduction.md` Section 8 described abstractly — `graphical.target` doesn't duplicate `multi-user.target`'s own closure; it simply requires and orders after it, adding only the display-manager-specific layer on top, which is why a headless server profile (`multi-user.target` as `default.target`, Section 6) and a desktop profile (`graphical.target` as `default.target`) share the entire multi-user-level closure identically, differing only in this thin additional layer.

### 5.1 Why "multi-user" versus "graphical" rather than a single, unified target

Keeping these as two distinct, layered targets rather than one combined one directly enables two genuinely useful, independent operational capabilities: `systemctl isolate multi-user.target` on a currently-graphical system (`02-Units-and-Dependencies.md` Section 8) cleanly drops to a text-mode session without a full reboot, precisely because `graphical.target`'s `Conflicts=`/closure-boundary relationship to `multi-user.target` makes that transition a well-defined, correct operation rather than an ad hoc process-killing exercise; and `systemctl set-default multi-user.target` (Section 6) on a server that will never need a display manager avoids the entire display-manager dependency closure being pulled into the graph at boot at all, a meaningful startup-time and resource saving on machines that will never use it.

---

## 6. `default.target` and How It's Selected

`default.target` is not a distinct, independently-defined target in its own right — it is, structurally, a **symlink**, pointing at whichever real target (`multi-user.target`, `graphical.target`, or, less commonly, something else entirely) should actually be reached at the end of a normal boot.

```bash
systemctl get-default
# graphical.target

sudo systemctl set-default multi-user.target
```

`set-default` simply rewrites the symlink at `/etc/systemd/system/default.target` to point at the named target — an operation with **no immediate effect on the currently-running boot**, only on subsequent ones; changing what `default.target` points at doesn't retroactively affect what's already running, mirroring precisely the `enable`-versus-`start` distinction from `01-Introduction.md` Section 10 (a configuration-for-the-future action, not an immediate-effect one). `systemctl isolate <target>` remains the correct tool (`02-Units-and-Dependencies.md` Section 8) for immediately transitioning the *current*, already-running boot to a different target state.

### 6.1 Kernel command-line override

The kernel command-line parameter `systemd.unit=<target>` overrides `default.target` for a **single specific boot only**, without touching the persistent symlink at all — added, for instance, from the bootloader menu, to boot once into `rescue.target` for emergency maintenance without permanently changing the system's own configured default:

```
systemd.unit=rescue.target
```

This distinction — a persistent, `set-default`-configured choice versus a one-boot, kernel-command-line override — is worth keeping straight specifically because the two mechanisms look similar in effect (both determine "what does this boot end up at") but have entirely different persistence, and confusing them (editing a bootloader entry's `systemd.unit=` parameter under the mistaken belief this is a lasting change, when in fact it's a one-shot override that reverts on the very next unrelated boot cycle if the bootloader configuration itself isn't separately, deliberately made permanent) is a genuinely common source of "I set this and it didn't stick" confusion.

---

## 7. `getty@.service` and Console/Login Management

`04-Unit-Files.md` Section 2.4 used `getty@.service` as its running example for `DefaultInstance=`; it's worth returning to it here specifically because its enablement is itself generator-driven (Section 3.3), tying several threads from earlier documents together at the point in the boot sequence where it actually matters.

`systemd-getty-generator`, run at the same early stage as `systemd-fstab-generator`, inspects the available virtual consoles and kernel command-line parameters (`console=`) to determine which `getty@<tty>.service` instances should actually be pulled into `multi-user.target`'s closure for *this specific boot* — meaning the exact set of active login prompts can vary boot to boot based on hardware/console configuration detected at that specific early-boot moment, generated fresh each time rather than being a static, unconditionally-enabled set of units baked in permanently. `serial-getty@.service` is the parallel template for serial-console logins, pulled in by the same generator when a serial console is detected via the kernel command line's `console=ttyS0`-style parameter, following the identical template-instantiation mechanism `04-Unit-Files.md` covered in full generality.

### 7.1 Virtual Consoles and `Type=idle`, Revisited

`03-Service-Management.md` Section 2.4 introduced `Type=idle` largely as a curiosity, deferring detail until this document could supply the actual context it exists for. `getty@.service`'s own unit file sets `Type=idle` specifically because several `getty@<tty>` instances (one per active virtual console) are all starting concurrently, alongside whatever remaining `multi-user.target`-closure services haven't yet finished — without `Type=idle`'s deliberate deferral, each `getty` instance's own console-clearing and prompt-drawing could interleave, character by character, with unrelated services still printing their own boot-time status messages to the same physical console device, producing exactly the jumbled, unreadable output `Type=idle` exists to avoid. Because virtual consoles (`tty1` through `tty6`, conventionally) are switchable via the kernel's own `Alt`+`F<n>` mechanism independent of systemd entirely, each `getty@<tty>` instance is genuinely independent — a hung or crashed login shell on `tty2` has no bearing on `tty1`'s own availability, each tracked and supervised as its own separate unit exactly per the per-instance isolation guarantee `03-Service-Management.md` Section 9.1 established for templates generally.

### 7.2 First Boot Handling

A related, adjacent mechanism worth mentioning here: `ConditionFirstBoot=`, briefly named in `03-Service-Management.md` Section 11's `Condition*=` table, gates a unit to run **only on the very first boot** of a given installed system image — determined by the presence or absence of a specific marker file systemd itself manages, not by any date or counter. `systemd-firstboot` is the companion tool most commonly invoked via a `ConditionFirstBoot=yes`-gated unit, prompting for or applying initial system configuration (hostname, root password, locale, timezone) that only makes sense to set once, at first startup of a freshly-provisioned image, and should never re-trigger on any subsequent, ordinary boot of the same installation. This is a distinct concept from a mere "run once" oneshot pattern (`03-Service-Management.md` Section 2.3's `RemainAfterExit=` combined with a `ConditionPathExists=` guard checking for a marker file the unit itself creates) — `ConditionFirstBoot=` is specifically about the system's own provisioning lifecycle, tied to image deployment rather than to any individual unit's own bespoke state-tracking convention, and is the mechanism cloud-init-style and appliance-style first-boot customization workflows are frequently built on top of.

---

## 8. Emergency and Rescue Targets: When Boot Fails

`01-Introduction.md` Section 8 named `rescue.target` and `emergency.target` in its overview table without detailing precisely how or when systemd actually drops into either. This is that detail.

### 8.1 `rescue.target`: a deliberate, minimal boot target

`rescue.target` is a genuine, ordinary target in the same sense as `multi-user.target` — it can be deliberately selected (via `systemd.unit=rescue.target` on the kernel command line, per Section 6.1, or `systemctl isolate rescue.target` on an already-running system, per `02-Units-and-Dependencies.md` Section 8) and represents "single-user-equivalent, minimal services, a root shell on the console" — the direct structural descendant of SysVinit's runlevel 1, as `01-Introduction.md` Section 8's comparison table noted. Its own dependency closure deliberately excludes the large `multi-user.target` fan-out, giving an administrator a known-minimal, predictable environment for maintenance work that shouldn't be complicated by dozens of ordinary application services also being active and potentially interfering.

### 8.2 `emergency.target`: the automatic fallback

`emergency.target` is structurally similar but reached under different, generally *involuntary* circumstances: when `sysinit.target` itself — the fundamental groundwork covered in Section 3 — cannot be reached, because something in its own closure (most commonly, per Section 3.2, a non-`nofail` `local-fs.target` mount failure) has failed. Because so much of the rest of the boot sequence implicitly depends on `sysinit.target` (`02-Units-and-Dependencies.md` Section 4's `DefaultDependencies=yes` mechanism), a failure this early genuinely cannot proceed toward any of the normal targets at all — there is no meaningful "multi-user, minus the one broken piece" fallback available, because too much of the system's own basic assumptions (working local storage, correctly-applied kernel parameters) are what failed to materialize in the first place.

```
systemd[1]: Failed to mount /srv/webapp/data.
systemd[1]: Dependency failed for Local File Systems.
systemd[1]: local-fs.target: Job local-fs.target/start failed with result 'dependency'.
systemd[1]: Dependency failed for System Initialization.
systemd[1]: sysinit.target: Job sysinit.target/start failed with result 'dependency'.
systemd[1]: emergency.target: Starting...
```

This is precisely the `result 'dependency'` propagation pattern `02-Units-and-Dependencies.md` Section 13.1 walked through at application-stack scale, now occurring at the scale of the entire early-boot sequence — the same underlying mechanism, no special-cased "boot failure" logic distinct from ordinary transaction/requirement propagation, just applied to a chain critical enough that its failure has nowhere meaningful left to fall back to except the deliberately minimal `emergency.target`.

### 8.3 What's actually different about `emergency.target` versus `rescue.target`

`emergency.target` is even more minimal than `rescue.target` — critically, it does **not** wait for or require `local-fs.target` at all (since, per Section 8.2, that's very often precisely what failed and triggered the fallback in the first place), mounting only the absolute bare minimum (typically just `/`, read-only, and not necessarily even that if the failure was severe enough) rather than assuming any of the ordinary local-filesystem groundwork succeeded. This is a deliberate, load-bearing design choice: a fallback target that itself depended on the exact thing that just failed would be useless as a fallback at all, so `emergency.target`'s own dependency closure is kept deliberately, minimally independent of the specific early-boot machinery most likely to be the actual cause of needing it.

### 8.4 Diagnosing and recovering from an emergency-target boot

The console, at this point, typically presents a root shell with a message identifying roughly what failed, plus explicit instruction to run `journalctl -xb` for full detail — because the *reason* varies boot to boot (a failed mount, a failed `fsck`, a corrupted `/etc/fstab` entry), there's no single fixed recovery script; the actual investigative workflow is a direct, smaller-scale application of `02-Units-and-Dependencies.md` Section 13.1's failure-tracing method: search the boot log for the *first* `result 'exit-code'`/`'signal'`/`'timeout'` entry (as opposed to the cascading `result 'dependency'` entries that follow it), since that first genuine failure — not the several `dependency`-labeled units that failed only as a consequence of it — is the actual thing to fix, most commonly by correcting or temporarily commenting out a broken `/etc/fstab` line, then rebooting normally once the underlying issue is resolved.

---

## 9. Diagnosing the Full Boot with `systemd-analyze`

`02-Units-and-Dependencies.md` Section 10 introduced `systemd-analyze`'s toolkit for individual-unit critical-path analysis; applied at whole-boot scope, several of the same subcommands answer boot-sequence-specific questions this document's structure makes concrete.

```bash
systemd-analyze critical-chain
```

With no unit name argument at all (as opposed to the `critical-chain webapp.service` form used in `02-Units-and-Dependencies.md` Section 10.3), this reports the critical chain leading to `default.target` itself — the single longest dependency path determining total boot completion time across the *entire* sequence this document has walked through, from `sysinit.target`'s own prerequisites (Section 3) through whichever of `multi-user.target`/`graphical.target` (Section 5) `default.target` (Section 6) actually resolves to.

```bash
systemd-analyze plot > full-boot.svg
```

Rendered at whole-boot scope, this SVG makes the target-chain structure of this entire document visually concrete in a single image — the `sysinit.target` prerequisite cluster (Section 3), the `basic.target` midpoint (Section 4), and the final `multi-user.target`/`graphical.target` fan-out (Section 5) appear as visually distinct phases, with the genuine parallelism *within* each phase, and the hard serialization *between* phases (nothing in the `multi-user.target` fan-out can begin before `basic.target` closes, per Section 4's ordering guarantee), both directly visible rather than needing to be inferred from text output.

### 9.1 Boot Performance: From Diagnosis to Action

`02-Units-and-Dependencies.md` Section 10 focused on reading `critical-chain`/`blame` output; applied here at whole-boot scale, the same diagnostic output points toward a small number of genuinely common, structural fixes rather than requiring case-by-case investigation each time.

**A unit on the critical chain that doesn't need to be.** The single highest-value fix is usually finding a unit ordered `After=` something it doesn't actually functionally depend on — per `02-Units-and-Dependencies.md` Section 3.1's core lesson, an `After=` with no matching `Requires=`/`Wants=` is pure, removable ordering; if `critical-chain` reveals it's also on the *longest path*, removing an unnecessary `After=` line can shorten total boot time directly, by allowing that unit to run in the parallel portion of the graph instead of the serial one.

**Socket/bus activation for anything not immediately needed.** A service currently started unconditionally at `multi-user.target` time, but which in practice sits idle until first used, is a direct candidate for the socket-activation conversion described in `02-Units-and-Dependencies.md` Section 11 — moving its actual daemon startup off the boot-time critical path entirely, deferred until genuinely needed, at zero cost to the service's own eventual availability from the caller's perspective.

**`systemd-udev-settle.service` and similar "wait for everything" units.** As `02-Units-and-Dependencies.md` Section 10.2 noted in the abstract, a large `blame` entry isn't automatically a boot-time problem — but a unit whose entire purpose is "block until all device enumeration is finished," ordered `After=` by something that in practice only needs *one specific* device rather than the complete enumeration, is a common, fixable case of exactly this: replacing a blanket "settle" dependency with a specific `.device` unit dependency (`02-Units-and-Dependencies.md` Section 2.4's `BindsTo=dev-sdb1.device` pattern) narrows the wait to only what's actually needed, often substantially shortening the critical chain without any loss of correctness.

### 9.2 Hardware Watchdog Integration

Separate from the `WatchdogSec=`/`sd_notify` per-service mechanism covered in `03-Service-Management.md` Section 3.3, systemd can also drive a system-level **hardware watchdog device** (`/dev/watchdog`, a feature most server-class and embedded hardware exposes), providing a backstop against PID 1 itself — or the kernel as a whole — becoming unresponsive, a failure mode no *userspace* per-service watchdog could ever catch, since it presupposes systemd itself is still functioning correctly enough to notice and act on it.

```ini
# /etc/systemd/system.conf
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=10min
```

`RuntimeWatchdogSec=` configures systemd itself to ping the hardware watchdog device periodically, during ordinary operation — if PID 1 stops doing so (because it has hung, deadlocked, or the kernel itself has become unresponsive), the hardware watchdog device independently, at the firmware level, forces a hard reset after the configured interval elapses with no ping received, entirely outside of and unrecoverable-by any further software-level intervention, which is precisely the point: this is the backstop for the case where software-level recovery mechanisms have themselves stopped functioning. `RebootWatchdogSec=` configures a related but distinct guarantee — a maximum time budget for the reboot/shutdown process itself (Section 11) to actually complete, forcing a hard reset if an ordinary, software-driven shutdown sequence itself hangs partway through, rather than leaving a machine that requested a reboot stuck indefinitely in a half-shutdown state with no automatic recovery.

This is a `system.conf`-level (i.e., PID 1's own global configuration, distinct from any individual unit file) setting, not a per-unit directive, precisely because it protects the init system itself, not any specific service under its management — its presence or absence is a whole-machine operational policy decision, typically made deliberately for server/embedded hardware where unattended, automatic recovery from a total hang is a genuine operational requirement, rather than something toggled per-application the way `WatchdogSec=` is.

---

## 10. Kernel Command-Line Parameters Relevant to Boot

Several parameters, passed by the bootloader, alter systemd's own boot behavior before any unit is even loaded — worth a consolidated reference here, since examples throughout this document (`systemd.unit=`, `rd.break`) have referenced individual ones in passing.

| Parameter | Effect |
|---|---|
| `systemd.unit=<target>` | One-boot override of `default.target` (Section 6.1) |
| `rd.break` | Drop to an interactive shell within the initramfs, before `switch-root` (Section 2.3) |
| `systemd.log_level=debug` | Maximum verbosity logging from PID 1 itself, from the earliest possible point |
| `systemd.log_target=console` | Forces early log output to the console, useful when a failure occurs before the journal is fully available |
| `systemd.debug-shell=1` | Activates a debug shell (`debug-shell.service`) on a specific virtual console (typically tty9), available *alongside* an otherwise-normal boot, rather than replacing it — useful for observing a boot failure interactively without interrupting the sequence that's failing |
| `single` / `1` | Legacy SysVinit-style single-user request, translated by systemd into an effective `rescue.target` boot for compatibility with scripts and muscle memory predating systemd itself |
| `fsck.mode=force` / `fsck.mode=skip` | Overrides the automatic filesystem-check behavior that would otherwise run as part of the `local-fs.target` prerequisite chain (Section 3.2) |
| `systemd.mask=<unit>` | Masks a specific unit for this boot only, without a persistent `systemctl mask` |
| `systemd.wants=<unit>` | Adds a `Wants=` edge against `default.target` for this boot only, starting an additional unit without a persistent enable |

`systemd.log_level=debug` combined with `systemd.log_target=console` is the standard first move when diagnosing a boot failure severe enough that the system never reaches a state where `journalctl -xb` (Section 8.4) is even usable afterward — forcing maximal, immediately-visible detail onto the console itself, live, during the failing boot, rather than relying on log capture that assumes at least a partially-successful boot.

### 10.1 A Worked Debug-Boot Parameter Set

Combining several of the parameters from Section 10's table into one bootloader-menu edit is the standard escalation path for a boot failure severe enough that neither `emergency.target` (Section 8.2) nor ordinary console output has been informative enough to identify the actual cause:

```
systemd.log_level=debug systemd.log_target=console systemd.debug-shell=1 rd.break
```

Read left to right, this combination: forces maximal logging verbosity (`systemd.log_level=debug`) directly to the console rather than only the journal (`systemd.log_target=console`), opens an additional, always-available debug shell on a separate virtual console alongside the (possibly still-failing) main boot sequence (`systemd.debug-shell=1`) so an investigation can proceed interactively without waiting for the main sequence to either succeed or reach `emergency.target` on its own, and, if the failure is severe enough to be rooted in the initramfs phase itself rather than anything on the real root (Section 2.3), drops to an interactive shell before `switch-root` even occurs (`rd.break`) so the real root's own filesystem state can be inspected and manually mounted for direct investigation from within the constrained initramfs environment. Not every diagnostic session needs all four simultaneously — `rd.break` alone is the right, narrower tool for a suspected initramfs-phase problem specifically, and adding the logging-verbosity parameters on top of it is mainly useful when the *initramfs's own* log output, not merely the real root's, needs to be maximally verbose to identify the failure.

---

## 11. Shutdown and Reboot: The Mirror Process

Everything this document has covered runs, structurally, in reverse during shutdown — and it's worth tracing that reverse sequence explicitly, because several mechanisms established earlier in this series (`shutdown.target`'s implicit `Conflicts=`, `02-Units-and-Dependencies.md` Section 4) have their actual payoff specifically here.

### 11.1 The `Conflicts=shutdown.target` mechanism, revisited

Recall from `02-Units-and-Dependencies.md` Section 4 that every ordinary unit implicitly `Conflicts=`/`Before=shutdown.target` via `DefaultDependencies=yes` — this is precisely what makes `systemctl poweroff`/`reboot`/`halt` a well-ordered, graceful transaction rather than an abrupt kill-everything operation: starting `shutdown.target` (or, more precisely, one of `poweroff.target`/`reboot.target`/`halt.target`, each of which itself requires and orders after `shutdown.target`) triggers the conflict-resolution mechanism from `02-Units-and-Dependencies.md` Section 2.6 against every currently-active unit simultaneously, stopping each one via its own normal `ExecStop=`/`KillMode=`/`TimeoutStopSec=` machinery from `03-Service-Management.md`, in an order the dependency graph itself computes — units with nothing depending on them stop early and in parallel; units other things depend on stop only once their own dependents have already stopped, the exact mirror image of the parallel-start behavior this entire document has been describing for the boot direction.

### 11.2 The final unmounting phase

Once every ordinary service-level unit has stopped, a final, specialized sequence handles unmounting filesystems and deactivating swap — genuinely late in the shutdown sequence, and handled somewhat specially precisely because the normal unit-stop machinery assumes services can be stopped while filesystems remain mounted underneath them, an assumption that has to eventually be violated to actually complete a clean shutdown. `systemd-shutdown` (a separate, minimal binary from `systemd` itself, executed as the very last step) handles this final phase directly — outside the ordinary unit/cgroup supervision model entirely, since by this point there is no meaningful "system" left in the ordinary sense for that model to apply to, only the literal, final steps of unmounting, deactivating swap, and issuing the actual `reboot()`/`poweroff()` system call to the kernel.

### 11.3 `reboot.target`, `poweroff.target`, `kexec.target`, and `halt.target`

Four related, sibling targets exist for the different flavors of "shut the system down," differing only in the specific final kernel-level action `systemd-shutdown` invokes once the common `shutdown.target` closure above has completed: `poweroff.target` cuts power entirely, `reboot.target` restarts the machine through the normal firmware/bootloader path, `halt.target` stops the CPU without cutting power or rebooting (rare in practice on modern hardware), and `kexec.target` loads and jumps directly into a new kernel image without going through firmware/bootloader re-initialization at all — meaningfully faster than a full `reboot.target` cycle on hardware with slow firmware initialization, at the cost of skipping firmware-level hardware re-initialization the new kernel might, in some configurations, actually have wanted.

```bash
systemctl poweroff
systemctl reboot
systemctl kexec
```

Each of these commands is, structurally, nothing more than `systemctl isolate <corresponding-target>` (`02-Units-and-Dependencies.md` Section 8) plus the small amount of additional logic ensuring the transaction is treated as irreversible/non-cancelable once initiated — the actual graceful-shutdown mechanism underneath is identical to the ordinary isolate-transaction machinery already covered in full elsewhere in this series, not a separate, special-cased code path.

### 11.4 Inhibitor Locks: Delaying Shutdown Deliberately

Before the transaction described in Section 11.1 even begins, systemd (via `systemd-logind`, per `01-Introduction.md` Section 3's component table) checks for active **inhibitor locks** — a mechanism letting a process register "please delay (or block, or simply be informed of) a pending shutdown until I've finished something," without that process needing to be a systemd unit at all, or having any dependency-graph relationship to the shutdown transaction whatsoever.

```bash
systemd-inhibit --what=shutdown --why="Finishing database backup" \
  --mode=delay /usr/local/bin/backup.sh
```

`--mode=delay` (the default for most automatically-registered locks, such as ones desktop environments register during active file transfers) permits the shutdown request to be issued, but holds it off for a bounded grace period (`InhibitDelayMaxSec=` in `system.conf`, alongside the watchdog settings from Section 9.2) while the inhibiting operation finishes, after which the shutdown proceeds regardless — a soft delay, not an indefinite block. `--mode=block` is stronger, preventing the shutdown request from succeeding at all while the lock is held, requiring either the inhibiting process to release the lock or an administrator to override it explicitly.

```bash
systemctl list-jobs                 # not inhibitor-specific, but useful
                                      # alongside inhibitor checks when a
                                      # shutdown appears to be hanging
loginctl list-sessions               # sessions, which can themselves hold
                                      # implicit inhibitor-adjacent state
systemd-inhibit --list               # every currently active inhibitor lock,
                                      # what it's blocking/delaying, and why
```

This mechanism is worth knowing about specifically because it's a common, easy-to-overlook explanation for a `systemctl poweroff` that appears to hang rather than proceeding immediately — the delay is often entirely intentional and correctly bounded (per `InhibitDelayMaxSec=`), but an operator unaware the mechanism exists at all can mistake a brief, deliberate delay for the machine having genuinely hung, when `systemd-inhibit --list` would have shown precisely which process registered the lock and why, resolving the apparent mystery immediately.

### 11.5 Diagnosing a Slow Shutdown

The critical-chain/blame tooling from Section 9 has a direct analogue for the *stop* direction, worth knowing separately since shutdown timing problems have a genuinely different characteristic failure mode than boot timing problems do: rather than a long serial *ordering* chain (Section 9.1's typical boot-time culprit), a slow shutdown is overwhelmingly likely to be caused by one specific unit's `TimeoutStopSec=` (`03-Service-Management.md` Section 7.2) actually being exhausted — a service that isn't responding to `SIGTERM` promptly, forcing systemd to wait out the full configured timeout before escalating to `SIGKILL`, for every single such unit in the shutdown transaction.

```
systemd[1]: webapp.service: State 'stop-sigterm' timed out. Killing.
systemd[1]: webapp.service: Killing process 4821 (serve) with signal SIGKILL.
```

This exact log pattern — familiar from `03-Service-Management.md` Section 13's worked failure timeline, now occurring specifically during an ordinary, administrator-requested shutdown rather than as part of an automatic-restart cycle — is the standard signature to search `journalctl` for when a shutdown or reboot took noticeably longer than expected: each occurrence represents one unit's full `TimeoutStopSec=` being burned waiting for a graceful exit that never came, and unlike the boot-time critical-chain case, these delays are **not** parallelized away by systemd's own scheduling the way independent units' *start* times often are — a stop transaction still respects whatever ordering constraints exist between units (Section 11.1), but multiple *independent* units each individually timing out on their own `TimeoutStopSec=` genuinely does add to total shutdown wall-clock time in a way that's often more directly attributable to one or two specific, identifiable offending units than a typical slow-boot investigation tends to be.

---

## 12. A Fully Worked Boot Trace

Bringing every phase of this document together into one continuous, annotated `journalctl -b` excerpt, for a machine with an encrypted root, a separate data volume mounted via `/etc/fstab` without `nofail`, and `graphical.target` as its configured default:

```
[initramfs phase — Section 2]
systemd[1]: Reached target Initrd Root Device.
systemd[1]: Starting Cryptography Setup for luks-a1b2c3...
systemd[1]: Finished Cryptography Setup for luks-a1b2c3.
systemd[1]: Reached target Initrd Root File System.
systemd[1]: Starting Reload Configuration from the Real Root...
systemd[1]: Switching root.

[real root, sysinit.target prerequisites — Section 3]
systemd[1]: Starting File System Check on /dev/mapper/luks-a1b2c3...
systemd[1]: Mounting /...
systemd[1]: Mounting /srv/webapp/data...
systemd[1]: Starting udev Kernel Device Manager...
systemd[1]: Starting Load Kernel Modules...
systemd[1]: Starting Apply Kernel Variables...
systemd[1]: Reached target Local File Systems.
systemd[1]: Reached target System Initialization.

[basic.target — Section 4]
systemd[1]: Reached target Path Units.
systemd[1]: Listening on D-Bus System Message Bus Socket.
systemd[1]: Reached target Socket Units.
systemd[1]: Reached target Timer Units.
systemd[1]: Reached target Basic System.

[multi-user.target fan-out — Section 5]
systemd[1]: Starting Network Manager...
systemd[1]: Starting OpenSSH server daemon...
systemd[1]: Starting PostgreSQL database server...
systemd[1]: Finished Network Manager.
systemd[1]: Reached target Network.
systemd[1]: Reached target Network is Online.
systemd[1]: Finished OpenSSH server daemon.
systemd[1]: Finished PostgreSQL database server.
systemd[1]: Reached target Multi-User System.

[graphical.target — Section 5.1]
systemd[1]: Starting GNOME Display Manager...
systemd[1]: Finished GNOME Display Manager.
systemd[1]: Reached target Graphical Interface.
systemd[1]: Startup finished in 2.912s (kernel) + 1.804s (initrd) + 6.221s (userspace) = 10.937s.
```

Reading this trace against the document as a whole: the `Cryptography Setup` and `Initrd Root File System` lines are entirely Section 2's initramfs phase, invisible to and independent of anything in `/etc/systemd/system/` on the real root; `Switching root` is the exact `switch-root` operation from Section 1.2; the `File System Check`/mount lines immediately after are `local-fs.target`'s own closure (Section 3.2), with `/srv/webapp/data`'s mount specifically being the non-`nofail` entry that — had it failed instead of succeeding — would have produced the `emergency.target` cascade from Section 8.2 rather than the clean progression shown here; the `Basic System` line is Section 4's midpoint, gating the socket for `NetworkManager`'s D-Bus activation and every other `basic.target`-dependent mechanism; and the final `Multi-User System` followed by `Graphical Interface` lines trace exactly the layered `graphical.target`-requires-`multi-user.target` relationship from Section 5, with the final `Startup finished` line's three-part breakdown corresponding precisely to `systemd-analyze time`'s own reported structure from `02-Units-and-Dependencies.md` Section 10.1 — kernel phase (Section 1.1), initrd phase (Section 2), userspace phase (everything from `switch-root` onward, Sections 3 through 5 combined).

### 12.1 The Same Boot, With the Mount Failing Instead

To make Section 8.2's abstract description of the `emergency.target` cascade fully concrete, here is the identical machine's boot trace, with the sole change being that `/srv/webapp/data`'s underlying device is unavailable this time:

```
[real root, sysinit.target prerequisites]
systemd[1]: Starting File System Check on /dev/mapper/luks-a1b2c3...
systemd[1]: Mounting /...
systemd[1]: Mounting /srv/webapp/data...
systemd[1]: srv-webapp-data.mount: Mount process exited, code=exited status=32
systemd[1]: srv-webapp-data.mount: Failed with result 'exit-code'.
systemd[1]: Failed to mount /srv/webapp/data.
systemd[1]: Dependency failed for Local File Systems.
systemd[1]: local-fs.target: Job local-fs.target/start failed with result 'dependency'.
systemd[1]: Dependency failed for System Initialization.
systemd[1]: sysinit.target: Job sysinit.target/start failed with result 'dependency'.
systemd[1]: Reached target Emergency Mode.
systemd[1]: Starting Emergency Shell...
systemd[1]: Press Enter for maintenance
systemd[1]: (or press Control-D to continue): _
```

Applying the diagnostic method from Section 8.4 to this exact trace: scanning for the *first* `result 'exit-code'`/`'signal'`/`'timeout'` entry rather than the `result 'dependency'` entries that follow it lands precisely on the `srv-webapp-data.mount: Failed with result 'exit-code'` line — everything after it (`local-fs.target`'s own failure, then `sysinit.target`'s) is downstream propagation via the exact `Requires=`-failure mechanism `02-Units-and-Dependencies.md` Section 13.1 walked through at application scale, not three independent problems needing three independent investigations. An administrator dropped into this emergency shell has, at this point, a single, specific, correctly-identified thing to fix — mounting the device manually to confirm whether it's a transient unavailability or a genuine hardware/configuration problem, correcting or temporarily commenting the offending `/etc/fstab` line if appropriate, and then either continuing (`Control-D`, which attempts to proceed past the `emergency.target` fallback) or rebooting cleanly once the underlying cause is actually resolved, rather than guessing at three separate, differently-worded failure messages independently.

---

## 13. Common Anti-Patterns

**Assuming a unit file placed under `/etc/systemd/system/` affects initramfs-phase behavior.** As covered in Section 1.3, the initramfs loads units from an entirely separate, baked-in location — a real-root unit file is invisible during that phase regardless of how correctly it's written, and initramfs-phase changes require regenerating the initramfs image itself (Section 2.2), not editing anything under `/etc/systemd/system/`.

**Confusing `systemd.unit=` on the kernel command line with a persistent `set-default`.** As covered in Section 6.1, the former is a single-boot override with no lasting effect; assuming it "stuck" because the current boot behaved as expected is a common, easy mistake that resurfaces confusingly on the very next, unrelated boot cycle.

**Omitting `nofail` on a non-critical `/etc/fstab` entry.** As covered in Sections 3.2 and 8.2, this makes an otherwise-non-essential mount capable of taking down the entire boot via `local-fs.target`/`sysinit.target` propagation, landing the system in `emergency.target` for a filesystem that, in practice, the system could have booted perfectly well without.

**Treating `rescue.target` and `emergency.target` as interchangeable.** As covered in Section 8.3, `emergency.target` deliberately does not assume `local-fs.target` succeeded, while `rescue.target` does — attempting `systemctl isolate rescue.target` as a recovery step from within an already-reached `emergency.target` session, on a system where the underlying local-filesystem problem hasn't actually been fixed yet, will simply fail for the identical underlying reason that produced the `emergency.target` fallback in the first place.

**Debugging a boot failure by immediately reaching for `systemd.log_level=debug` before checking `journalctl -xb` on a boot that actually completed to a shell.** Section 10's maximal-verbosity kernel parameters are the right tool specifically when the boot fails *before* a diagnosable shell state is reached at all (Section 8.4) — for a boot that does reach `emergency.target` or an ordinary login prompt, the ordinary, already-captured journal is faster to search and easier to read than re-booting with maximal verbosity and capturing a much larger, noisier log for a failure that was already fully diagnosable from the standard output.

**Configuring `RuntimeWatchdogSec=` shorter than genuine, healthy boot or shutdown time.** As covered in Section 9.2, this is a backstop against PID 1 or the kernel becoming unresponsive, not a performance target to tune aggressively — a value set too tight, without first establishing what normal, successful timing actually looks like via the tooling in Section 9.1, produces spurious forced resets during entirely healthy operation, which is a materially worse operational outcome than the rare, genuine hang the watchdog exists to catch.

---

## 14. Exercises

**1.** A unit file is added under `/etc/systemd/system/` to load a kernel module the real root filesystem's storage controller needs. The next boot still fails to find the root filesystem. Why didn't the new unit help? *(Per Section 1.3, the initramfs — not the real root's systemd instance — is what needs to load that module, since the real root isn't mounted yet at the point the module is needed; the fix is adding the module to the initramfs's own configuration and regenerating it via `dracut`/`mkinitcpio`, per Section 2.2, not adding a unit file the real-root systemd instance will only ever see after the point the module was actually needed.)*

**2.** `/etc/fstab` has a non-`nofail` entry for a network-backed filesystem that happens to be temporarily unreachable at boot. What is the most likely observable outcome? *(Per Sections 3.2 and 8.2, the mount failure propagates `Requires=`-style through `local-fs.target` to `sysinit.target`, and because so much of the rest of boot implicitly depends on `sysinit.target`, the system lands in `emergency.target` rather than proceeding to a normal login — the fix is either adding `nofail`, or, more appropriately for a genuinely network-dependent filesystem, ordering it against `remote-fs.target` instead of `local-fs.target`, which is specifically designed to tolerate network-timing variability that `local-fs.target` assumes doesn't apply.)*

**3.** An administrator runs `systemctl set-default rescue.target`, intending a temporary maintenance window, then forgets to change it back. What happens on the next several ordinary reboots? *(Per Section 6, `set-default` is a persistent change — every subsequent boot, not merely the next one, will boot to `rescue.target` until the administrator explicitly runs `systemctl set-default` again pointing at the intended ordinary target; this is precisely why Section 6.1's one-boot `systemd.unit=` kernel-parameter override exists as the safer tool for a genuinely temporary, single-boot maintenance need.)*

**4.** Two otherwise-unrelated services, `A` and `B`, both `WantedBy=multi-user.target`, with no ordering directive between them at all. During shutdown, in what order do they stop, and why? *(Per Section 11.1, shutdown ordering mirrors boot ordering exactly — with no `Before=`/`After=` relationship between `A` and `B`, per `02-Units-and-Dependencies.md` Section 3.2's default-parallelism rule, they have no defined relative stop order either and are, in practice, very likely stopped concurrently, the same way they would have started concurrently at boot.)*

**5.** A `systemctl poweroff` appears to hang for exactly ninety seconds before the machine actually powers off, every single time, with no unit-level `TimeoutStopSec=` set anywhere near that value. What is a plausible, non-obvious explanation worth checking before assuming a hung process? *(Per Section 11.4, a registered inhibitor lock in `delay` mode — commonly held by a desktop-environment component finishing an in-progress operation — can account for exactly this kind of consistent, bounded delay; `systemd-inhibit --list` would reveal the specific lock and its stated reason, and `InhibitDelayMaxSec=` in `system.conf` would explain the specific ninety-second ceiling if that's the configured value.)*

**6.** A reboot takes noticeably longer than usual on one specific occasion, and `journalctl -b` from that boot shows one `State 'stop-sigterm' timed out. Killing.` line for a single service. Is this best diagnosed with `systemd-analyze critical-chain`, the tool used throughout Section 9 for slow *boots*? *(No — per Section 11.5, `critical-chain` is a boot-direction tool answering an ordering-chain question; a single slow shutdown dominated by one unit's exhausted `TimeoutStopSec=` is better diagnosed by directly searching for the `'stop-sigterm' timed out` log signature itself, which points immediately at the specific offending unit without needing graph-traversal tooling built for a different, ordering-dominated failure shape.)*

---

## 15. Pre-Deployment Checklist

Mirroring the checklists established across this series (`02-Units-and-Dependencies.md` Section 18a, `03-Service-Management.md` Section 21, `04-Unit-Files.md` Section 12), adapted to boot-sequence changes specifically — genuinely higher-stakes than an individual unit change, since a mistake here can affect whether the machine boots at all:

1. **Before adding any non-`nofail` `/etc/fstab` entry, deliberately ask whether this filesystem's absence should actually be able to prevent the entire system from booting.** Per Sections 3.2 and 8.2, this is the single most common self-inflicted cause of an unwanted `emergency.target` landing, and the answer is "yes, it should block boot" far less often in practice than a defensively-omitted `nofail` implies.
2. **After any initramfs-affecting change (new storage driver, new encryption configuration), confirm the initramfs was actually regenerated**, per Section 2.2 — a change to the real root's configuration alone, without a corresponding `dracut`/`mkinitcpio` regeneration, has no effect on initramfs-phase behavior at all, per Section 1.3's core distinction.
3. **Test a `set-default` change, or any other persistent boot-target change, with the one-boot `systemd.unit=` kernel-parameter override first**, per Section 6.1 — confirming the intended target actually boots cleanly before committing to the persistent, every-subsequent-boot version of the same change.
4. **If a hardware watchdog is configured (Section 9.2), confirm `RuntimeWatchdogSec=` and `RebootWatchdogSec=` are set to values that comfortably exceed the system's own observed normal boot and shutdown timing** (Section 12's worked trace being a template for what "normal" looks like) — a watchdog interval shorter than genuine, non-failure boot time produces spurious, unwanted forced resets during entirely healthy startups.
5. **After any change plausibly affecting boot time, run `systemd-analyze time` and `critical-chain` before and after, and compare**, per Section 9.1 — confirming an intended optimization actually shortened the critical path, rather than merely reducing one unit's own individual `blame` time while leaving total boot time unchanged because that unit was never on the critical path to begin with.

---

## 16. Quick-Reference Table

| Target / Mechanism | Section | Role |
|---|---|---|
| initramfs / `switch-root` | 1–2 | Bootstraps just enough to mount and hand off to the real root |
| `sysinit.target` | 3 | Fundamental filesystem, device, and kernel-parameter groundwork |
| `local-fs.target` | 3.2 | Gates on every generator-produced and hand-authored `.mount` unit |
| `basic.target` | 4 | Socket/path/timer/slice infrastructure fully operational |
| `multi-user.target` | 5 | Ordinary application services; the non-graphical final state |
| `graphical.target` | 5 | `multi-user.target` plus a display manager layered on top |
| `default.target` | 6 | Symlink selecting which target a normal boot actually reaches |
| `systemd.unit=` | 6.1 | One-boot kernel-command-line override of `default.target` |
| `rescue.target` | 8.1 | Deliberately selectable, minimal single-user-equivalent state |
| `emergency.target` | 8.2 | Involuntary fallback when `sysinit.target` itself cannot be reached |
| `shutdown.target` family | 11 | The mirror-image, ordered teardown of the entire boot sequence |

---

## 17. Glossary

**initramfs** — a small, temporary root filesystem image loaded directly by the kernel, used to bootstrap access to the real, final root filesystem.
**switch-root** — the operation replacing the initramfs's process tree and mounts with the real root's, distinct from a plain `chroot()`.
**Generator** — a program run very early by PID 1 to produce ordinary unit files dynamically from a non-native configuration source (`/etc/fstab` being the running example throughout this series).
**Synchronization point** — a target whose sole purpose is marking "everything in this closure is now ready," per `02-Units-and-Dependencies.md` Section 8's original definition, applied here at the scale of entire boot phases.
**Graceful shutdown** — the ordered, dependency-graph-driven stop sequence triggered by `shutdown.target`'s implicit conflict with every ordinary unit.
**Bootloader** — the firmware-launched program (GRUB, `systemd-boot`) responsible for selecting and loading the kernel and initramfs, strictly prior to and outside of anything systemd itself controls.
**Inhibitor lock** — a registration, held by any process via `systemd-logind`, that delays or blocks a pending shutdown until released or a maximum grace period elapses.
**Hardware watchdog** — a firmware-level device that forces a hard reset if not periodically pinged by software, serving as a backstop against PID 1 or the kernel itself becoming unresponsive.
**First boot** — the specific, marker-file-tracked initial startup of a freshly-provisioned system image, distinct from any individual unit's own "run once" convention.

---

## 18. What's Ahead

`06-journald-and-Logging.md` picks up directly from this document's own journal excerpts — journal internals, structured fields, persistence configuration (including precisely how much of the initramfs-phase log fragment mentioned in Section 2.3 survives into the post-boot, persistent journal), and forwarding to traditional syslog.

---

## References

- `systemd.special(7)` — the well-known target units this document traces in sequence
- `bootup(7)` — the canonical manual page documenting this exact boot sequence
- `dracut(8)`, `mkinitcpio(8)` — initramfs-assembly tooling referenced in Section 2.2
- `kernel-command-line(7)` — the full reference for parameters summarized in Section 10
- `systemd-analyze(1)` — `critical-chain`, `plot`, `time` applied at whole-boot scope
