# Fedora 44 KDE — Full Setup Guide

[![ShellCheck](https://github.com/26zl/fedora-kde-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/26zl/fedora-kde-setup/actions/workflows/shellcheck.yml)
[![Secret Scan](https://github.com/26zl/fedora-kde-setup/actions/workflows/secret-scan.yml/badge.svg)](https://github.com/26zl/fedora-kde-setup/actions/workflows/secret-scan.yml)
[![Trivy](https://github.com/26zl/fedora-kde-setup/actions/workflows/trivy.yml/badge.svg)](https://github.com/26zl/fedora-kde-setup/actions/workflows/trivy.yml)
[![Validate](https://github.com/26zl/fedora-kde-setup/actions/workflows/validate.yml/badge.svg)](https://github.com/26zl/fedora-kde-setup/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-teal.svg)](LICENSE)
[![Fedora](https://img.shields.io/badge/Fedora-44-blue?logo=fedora&logoColor=white)](https://fedoraproject.org/)
[![KDE Plasma](https://img.shields.io/badge/KDE-Plasma%206-1d99f3?logo=kde&logoColor=white)](https://kde.org/)
[![Wayland](https://img.shields.io/badge/Wayland-native-orange?logo=wayland&logoColor=white)](https://wayland.freedesktop.org/)

Post-installation guide, config files, and scripts for Fedora 44 KDE Plasma 6 on Wayland. Focused on low-latency gaming and a clean rice.

The automated fresh-install setup supports Fedora 44 on x86_64 and refuses other releases
and architectures before making changes. Its pre-install recovery requires a Btrfs root
and `/home` on the same Btrfs filesystem, with no separate system-data mounts or nested
home subvolumes outside the supported layout. On other layouts it asks whether to continue
without that restore point; with `--yes` it stops. Other hardware paths have fixture coverage;
the complete setup still needs validation on each target machine.

## Hardware Support

The scripts detect the hardware and adapt to it, so the same repo sets up a gaming desktop or a laptop, with an NVIDIA, AMD or Intel GPU:

| Detected | What the setup does |
| --- | --- |
| NVIDIA GPU, Turing (RTX 20 / GTX 16) or newer | `akmod-nvidia` from RPM Fusion, NVIDIA Wayland and suspend configs; under Secure Boot it prints the MOK enrollment steps |
| NVIDIA GPU, Maxwell, Pascal or Volta (GTX 900 / 10) | The `580xx` driver branch, the last one that supports them. Older cards stay on nouveau |
| AMD GPU | `mesa-va-drivers-freeworld` for H.264/H.265 hardware video |
| Intel GPU | `intel-media-driver` for H.264/H.265 hardware video |
| Desktop | tuned `latency-performance`, scx Gaming mode, `workqueue.power_efficient=false` |
| Laptop | tuned keeps its battery-aware `balanced` profile, scx runs in Auto mode. With hybrid graphics the desktop stays on the integrated GPU |
| Windows in the UEFI boot list | GRUB remembers the last-booted OS |
| btrfs root | Snapper snapshots |
| AMD or Intel CPU | CPU temperature from `k10temp` or `coretemp` in Conky and `sysinfo` |

Detection lives in `scripts/lib/hw.sh`, and `fedora-setup.sh` prints what it found before it changes anything. To override it, copy `setup.conf.example` to `setup.conf` (git-ignored) and set `FORM_FACTOR`, `NVIDIA_DRIVER` or `AUDIO_TRIM`; a value outside the documented set stops the scripts before they change anything. Everything targets x86_64. Peripheral quirks (LAMZU mice, DualSense controllers, a few USB receivers) match on USB IDs and do nothing unless the device is plugged in.

Developed and verified on an AMD desktop with a discrete NVIDIA card next to the CPU's integrated GPU, dual-booting Windows. The other hardware paths are covered by `tests/hw-detect.sh` and the CI package check.

---

## Repository Structure

```text
├── .github/                    # CI workflows (shellcheck, validate, gitleaks, trivy), Dependabot, PR template
├── configs/
│   ├── conky/conky.conf        # Desktop system stats widget
│   ├── fastfetch/config.jsonc  # fastfetch module layout
│   ├── es-de/es_systems.xml    # ~/ES-DE/custom_systems/ — standalone emulator defaults
│   ├── es-de/es_find_rules.xml # ~/ES-DE/custom_systems/ — DuckStation resolves to the pinned AppImage
│   ├── fish/
│   │   ├── config.fish         # Fish shell config (aliases, zoxide, starship)
│   │   └── functions/ya.fish   # Yazi cd-on-exit wrapper
│   ├── kde/
│   │   ├── DarthVader.colors   # KDE color scheme (teal + red on black)
│   │   ├── kvantum/
│   │   │   └── kvantum.kvconfig # Kvantum theme config (LayanDark)
│   │   └── plasma-theme/       # Plasma desktop theme: Breeze with contrast/transparency tweaks (metadata.json + plasmarc)
│   ├── kitty/kitty.conf        # Terminal config — fish shell, Darth Vader palette
│   ├── starship/starship.toml  # Shell prompt
│   ├── wireplumber/
│   │   └── wireplumber.conf.d/
│   │       └── 50-audio.conf   # Opt-in (AUDIO_TRIM): hide onboard AMD, iGPU HDMI and webcam audio
│   ├── systemd/
│   │   └── conky.service       # ~/.config/systemd/user/ — Conky autostart service
│   └── bashrc                  # ~/.bashrc additions (ble.sh, zoxide, aliases)
├── system/
│   ├── nvidia-wayland.conf     # /etc/environment.d/ — NVIDIA Wayland env vars (NVIDIA only, not on hybrid laptops)
│   ├── nvidia-performance.conf # /etc/modprobe.d/ — NVIDIA kernel options (NVIDIA only)
│   ├── nvidia-vram-check.sh    # /usr/local/bin/ — read-only NVIDIA suspend storage check
│   ├── nvidia-vram-check.service # /etc/systemd/system/ — require sufficient storage before sleep
│   ├── 99-tweaks.conf          # /etc/sysctl.d/ — performance tweaks
│   ├── 99-disable-modules.conf # /etc/modprobe.d/ — blacklist unused protocols (attack surface)
│   ├── dnf.conf                # /etc/dnf/ — DNF settings
│   ├── journald-limits.conf    # /etc/systemd/journald.conf.d/ — journal capped at 1G
│   ├── user-runtime-dir-noquota.conf # user-runtime-dir@.service drop-in — drop the /dev/shm quota at login
│   ├── firefox-policies.json   # /etc/firefox/policies/ — telemetry, Studies, Pocket and sponsored content off
│   ├── zram-generator.conf     # /etc/systemd/ — ZRAM as large as RAM, up to 8GB, zstd
│   ├── tmp-mount-override.conf # /etc/systemd/system/tmp.mount.d/ — drop tmpfs usrquota
│   ├── scx_loader.toml         # /etc/scx_loader/ — scx_bpfland Gaming mode on desktops (lavd until #3791 ships)
│   ├── scx_loader-laptop.toml  # /etc/scx_loader/ — scx_bpfland Auto mode on laptops
│   ├── resolved-hardening.conf # /etc/systemd/resolved.conf.d/ — DNSSEC, DoT, LLMNR/mDNS off
│   ├── tuned-ppd.conf          # /etc/tuned/ppd.conf — PPD → tuned profile map
│   ├── ntsync.conf             # /etc/modules-load.d/ — load ntsync at boot
│   ├── 70-ntsync.rules         # /etc/udev/rules.d/ — ntsync user access
│   ├── 70-lamzu.rules          # /etc/udev/rules.d/ — LAMZU mouse configurator access (by USB ID)
│   ├── 99-dualsense.rules      # /etc/udev/rules.d/ — DualSense touchpad/motion noise fix
│   ├── 99-disable-wakeup.rules # /etc/udev/rules.d/ — LAMZU dongles must not wake the system
│   ├── libinput-overrides.quirks # /etc/libinput/ — no mouse debouncing for LAMZU mice
│   ├── hugepages.conf          # /etc/tmpfiles.d/ — transparent hugepages
│   ├── kwin-display-fix.sh     # /usr/lib/systemd/system-sleep/ — USB suspend/resume quirks
│   ├── kde-display-sleep.sh    # /usr/local/bin/ — preserve enabled external display state
│   ├── kde-display-sleep.service # /etc/systemd/system/ — KDE IPC before freeze and after thaw
│   ├── usb-autosuspend.service # /etc/systemd/system/ — autosuspend xHCI-blocking USB devices (by USB ID)
│   ├── gamescope-caps.actions  # /etc/dnf/libdnf5-plugins/actions.d/ — re-grant CAP_SYS_NICE after gamescope updates
│   ├── plasmalogin.conf        # /etc/plasmalogin.conf — login screen wallpaper
│   └── plasmalogin-restart.conf # systemd drop-in — auto-restart plasmalogin on crash
├── scripts/
│   ├── lib/hw.sh               # Hardware detection shared by the setup scripts
│   ├── lib/restore.sh          # Pre-install root/home snapshots and verified boot/EFI archives
│   ├── fedora-setup.sh         # Automated post-upgrade setup (run after the initial system upgrade + reboot)
│   ├── apply-system.sh         # Deploy system/ files to their system paths
│   ├── emulation-setup.sh      # ES-DE + standalone emulators (PS1/2/3, Wii)
│   ├── strata-setup.sh         # Local LLM (Strata) on the NVIDIA card — opt-in, 85 GB+
│   ├── ollama-setup.sh         # Local LLM (Ollama) + Alpaca chat GUI — opt-in, ~9 GB
│   ├── setup-github.sh         # GitHub CLI login + git identity/defaults
│   ├── rice-start.sh           # Restart Conky
│   ├── sysinfo.sh              # System health overview in terminal
│   ├── hwstat.sh               # CPU/GPU readings for Conky and sysinfo (AMD, Intel, NVIDIA)
│   ├── deep-health.sh          # Full hardware audit — firmware, SMART, btrfs scrub, self-test
│   ├── disk-cleanup.sh         # Trim snapper's timeline and clear package and container caches
│   ├── mok-reenroll.sh         # Re-enroll the akmods MOK after a BIOS flash
│   ├── fedora-upgrade.sh       # Upgrade to the next Fedora release (checks, snapshot, download)
│   └── verify-setup.sh         # Check the live system against the setup (after setup or an upgrade)
├── tests/
│   ├── hw-detect.sh            # Detection and hwstat tests against fixture sysfs trees
│   ├── verify-setup.sh         # Read-only verification failure paths with command stubs
│   ├── helper-scripts.sh       # Maintenance command failures and upgrade safeguards
│   ├── setup-configs.sh        # Numbered user config backups and repeat installs
│   ├── sleep-hooks.sh          # Display lifecycle, USB quirks and systemd unit ordering
│   ├── nvidia-vram.sh          # GPU capacity, disk storage and failure paths
│   ├── emulation-setup.sh      # Pinned AppImage downloads and ES-DE selection
│   ├── setup-restore.sh        # Recovery gates and boot/EFI archive round trips
│   ├── fresh-install.sh        # CI: apply-system.sh and the README's copy steps on a fresh Fedora
│   └── check-packages.sh       # CI: literal package names resolve in the scoped repos
├── setup.conf.example          # Per-machine overrides; copy to setup.conf
├── CONTRIBUTING.md             # Checks to run, conventions, repository settings
├── AGENTS.md                   # Boundaries for AI coding agents
├── SECURITY.md                 # How to report a vulnerability
└── wallpaper/
    └── wallpaper.jpg           # Darth Vader — dark, teal glow, red lightsaber (5120x2880)
```

---

## Quick Setup (New Machine)

```bash
# 1. Update the system to a clean kernel/driver baseline first, then reboot
sudo dnf upgrade --refresh -y
sudo reboot

# 2. After the reboot, clone and run the setup (the KDE image does not ship git)
sudo dnf install -y git
git clone https://github.com/26zl/fedora-kde-setup.git ~/fedora-setup
cd ~/fedora-setup
cp setup.conf.example setup.conf   # optional: only to override the detection
bash scripts/fedora-setup.sh       # prints what it will change and asks once; --yes skips that
```

> The setup script automates most of the guide below. A few steps stay manual: the initial system upgrade + reboot (Step 1), the optional service trimming, applying the Layan Kvantum theme, and Secure Boot MOK enrollment + BIOS settings (NVIDIA only).

---

## Step-by-Step Guide

### 1. System Update

```bash
sudo dnf upgrade --refresh -y
sudo dnf autoremove && sudo dnf clean all
sudo reboot
```

Firmware (UEFI/BIOS, SSD, peripherals) through fwupd and the LVFS:

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

Do this before the NVIDIA driver, or with Secure Boot on run `sudo bash scripts/mok-reenroll.sh` after any UEFI/BIOS update: a BIOS flash can clear the enrolled MOK key, and the signed NVIDIA modules then stop loading. `fedora-setup.sh` only lists the available updates and leaves applying them to you.

### 2. DNF Configuration

```bash
sudo cp system/dnf.conf /etc/dnf/dnf.conf
```

Key settings: `installonly_limit=2` (max 2 kernels), `max_parallel_downloads=10`, `fastestmirror=True`

### 3. RPM Fusion

```bash
sudo dnf install -y \
  "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
sudo dnf group upgrade -y core
```

The two release packages come over HTTPS from RPM Fusion's own server and carry its signing keys; every package after that is GPG-verified. Terra's key is fetched the same way (`--setopt=terra.gpgkey=`), so trust in both repos rests on TLS to their hosts.

### 4. GPU Drivers

`fedora-setup.sh` installs what the detected GPUs need. Several can apply at once, e.g. an AMD iGPU next to an NVIDIA card.

**AMD** — Fedora's Mesa leaves out H.264/H.265. RPM Fusion's build adds them, and libva loads it ahead of Fedora's:

```bash
sudo dnf install -y mesa-va-drivers-freeworld
```

**Intel** — same for Intel's media driver:

```bash
sudo dnf install -y intel-media-driver
```

**NVIDIA** — the current branch covers Turing (RTX 20 / GTX 16) and newer. Maxwell, Pascal and Volta (GTX 900 / 10) need the `580xx` branch, the last one that supports them; for those cards, use `akmod-nvidia-580xx` and `xorg-x11-drv-nvidia-580xx-cuda` instead. Kepler and older cards stay on nouveau.

```bash
sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver
```

Wait ~5 minutes for akmods to build the kernel module, then:

```bash
sudo akmods --force
sudo dracut --force
```

**Apply NVIDIA configs:**

```bash
sudo mkdir -p /etc/environment.d
sudo cp system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
sudo cp system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
```

Skip `nvidia-wayland.conf` on a laptop with hybrid graphics. It forces GLX, GBM and VA-API onto NVIDIA, but the panel is driven by the integrated GPU. There the desktop stays on the iGPU and single programs run on NVIDIA with `switcherooctl launch <program>`. `apply-system.sh` makes that call itself.

**Enable power management services:**

```bash
sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate
sudo systemctl enable nvidia-suspend-then-hibernate
sudo mkdir -p /usr/local/bin
sudo cp system/nvidia-vram-check.sh /usr/local/bin/nvidia-vram-check.sh
sudo chmod 755 /usr/local/bin/nvidia-vram-check.sh
sudo cp system/nvidia-vram-check.service /etc/systemd/system/nvidia-vram-check.service
sudo restorecon /usr/local/bin/nvidia-vram-check.sh /etc/systemd/system/nvidia-vram-check.service
sudo systemctl daemon-reload
sudo systemctl enable nvidia-vram-check.service
```

On suspend the driver saves the video memory to `/tmp`, the tmpfs default. The read-only
capacity check runs before sleep and the NVIDIA sleep services: it needs room for the sum
of all GPU memory plus 5%, following
[NVIDIA's sizing guidance](https://download.nvidia.com/XFree86/Linux-x86_64/580.105.08/README/powermanagement.html),
and on a RAM-backed store it counts `MemAvailable`, so a suspend with a loaded model
filling the RAM is refused with a message instead of failing halfway. Inspect refusals
with `journalctl -u nvidia-vram-check.service`.

`kde-display-sleep.service` captures enabled, connected external displays before
`sleep.target` and restores only that recorded set after user sessions thaw. It only acts
with the amdgpu module loaded, whose DisplayPort link re-training on resume is what
disconnects a monitor; on other hardware it exits at once. It never
enables laptop panels or displays that were disabled before sleep, and ignores captures
from another session. The USB-only hook runs inside the frozen interval. Both are
deployed by `apply-system.sh`; the display service is enabled without starting it during
installation. This ordering follows the [systemd sleep integration example](https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html#sleep.target).

**Enroll Secure Boot MOK key** (only with Secure Boot on; `mokutil --sb-state` tells):

```bash
sudo mokutil --import /etc/pki/akmods/certs/public_key.der
sudo reboot
# Select "Enroll MOK" at the blue MOK Manager screen on reboot
```

**Verify after reboot:**

```bash
mokutil --sb-state           # Should show: SecureBoot enabled
lsmod | grep nvidia          # Should list nvidia, nvidia_drm, nvidia_modeset, nvidia_uvm
nvidia-smi                   # Should show your GPU
```

### 5. CPU Performance (tuned)

```bash
sudo dnf install -y tuned
sudo systemctl enable --now tuned
sudo cp system/tuned-ppd.conf /etc/tuned/ppd.conf
sudo tuned-adm profile latency-performance   # desktops only
```

The `tuned-ppd.conf` maps KDE's "Performance" power mode to `latency-performance` instead of the default `throughput-performance`, so the profile persists correctly at boot. Laptops get `balanced` instead (`apply-system.sh` sets it, which also undoes `latency-performance` left by an earlier desktop run), and tuned-ppd switches that to `balanced-battery` when unplugged. Performance is still one click away in the battery applet. This relies on `tuned-ppd`, which the KDE spin ships and `fedora-setup.sh` installs; without it tuned keeps whatever profile was last set.

> **Note:** Recent AMD CPUs run `amd-pstate-epp` and Intel CPUs `intel_pstate`, both in active mode by default. In that mode only the `performance` and `powersave` governors exist, not `schedutil` or others.

### 6. SCX Scheduler (Gaming)

```bash
sudo dnf copr enable -y bieszczaders/kernel-cachyos-addons  # scx-scheds is not in the Fedora repos
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons.includepkgs=scx-scheds,scx-tools'
sudo dnf install -y scx-scheds
sudo mkdir -p /etc/scx_loader
sudo cp system/scx_loader.toml /etc/scx_loader/config.toml
sudo systemctl enable --now scx_loader.service
```

`includepkgs` limits the COPR to the two packages used here; unrestricted, a later `dnf upgrade` can pull its builds of other packages, and `scx-scheds` would pull the `scx-tools-git` snapshot instead of the `scx-tools` release. `fedora-setup.sh` scopes every COPR it adds the same way.

On a laptop, deploy `system/scx_loader-laptop.toml` instead: Auto mode, because Gaming mode keeps tasks on the fastest cores at the cost of battery.

`scx_bpfland` runs in Gaming mode for now. `scx_lavd` gives better frame pacing, but 1.1.3 starves tasks for 30–43 s until the kernel watchdog ejects it ([sched-ext/scx#3791](https://github.com/sched-ext/scx/issues/3791)). The fix is commit [`6d31ddd`](https://github.com/sched-ext/scx/commit/6d31ddd8973333e95ae7e3584e84029533064d69), which only touches lavd; switch `default_sched` back to `scx_lavd` once the COPR ships a build that contains it.

> **Loads from kernel 7.2.7-200 on; broken on Fedora 7.1.x–7.2.6.** Those builds fail with
> `the running kernel's BTF has malformed scx kfunc prototype(s)` — `KF_IMPLICIT_ARGS`
> kfuncs only get a loadable BTF prototype from a new enough pahole at kernel build time,
> and they used pahole 1.30 or older; 7.2.7-200 was built with 1.32.
> `grep CONFIG_PAHOLE_VERSION /boot/config-*` shows which pahole built each installed kernel.
> Same failure: [CachyOS COPR #113](https://github.com/CachyOS/copr-linux-cachyos/issues/113).
> Verify with `cat /sys/kernel/sched_ext/state` — `disabled` means EEVDF is running instead.
> The kernel's watchdog ejects a scheduler on a `runnable task stall` and `scx_loader` restarts it
> (`journalctl -k | grep 'runnable task stall'`).

### 7. ZRAM

```bash
sudo dnf install -y zram-generator
sudo cp system/zram-generator.conf /etc/systemd/zram-generator.conf
sudo reboot
```

Verify: `lsblk | grep zram` — should show a swap device as large as the RAM, up to 8GB (Fedora's own size rule; this file adds zstd compression).

### 8. sysctl Tweaks

```bash
sudo cp system/99-tweaks.conf /etc/sysctl.d/99-tweaks.conf
sudo sysctl --system
```

| Key | Value | Purpose |
| --- | --- | --- |
| `vm.swappiness` | `180` | Favour ZRAM over disk swap |
| `vm.max_map_count` | `2147483642` | Required for some games (Steam/Proton) |
| `net.core.rmem_max` | `16777216` | Better network throughput |
| `net.core.wmem_max` | `16777216` | Better network throughput |
| `vm.compaction_proactiveness` | `0` | Disable proactive memory compaction — reduces jitter |
| `vm.page_lock_unfairness` | `1` | Lower page lock contention |

Transparent hugepages are configured via `system/hugepages.conf` (deployed to `/etc/tmpfiles.d/`):

```bash
sudo cp system/hugepages.conf /etc/tmpfiles.d/hugepages.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/hugepages.conf
```

| Setting | Value | Purpose |
| --- | --- | --- |
| `transparent_hugepage/enabled` | `madvise` | 2MB pages only for processes that opt in via `madvise()` — fewer TLB misses without blanket overhead |
| `transparent_hugepage/shmem_enabled` | `advise` | Hugepages for shared memory (wine/Proton) |
| `transparent_hugepage/khugepaged/defrag` | `0` | Disable background defrag — reduces jitter |

### 9. Kernel Parameters

```bash
sudo grubby --update-kernel=ALL --args="nowatchdog audit=1 audit_backlog_limit=8192 skew_tick=1 workqueue.power_efficient=false preempt=full"
```

`apply-system.sh` leaves `workqueue.power_efficient=false` out on laptops, where the power-efficient workqueues save battery.

| Parameter | Purpose |
| --- | --- |
| `nowatchdog` | Disable watchdog timers — reduces interrupts |
| `audit=1` | Enable the audit framework — `auditd.service` has `ConditionKernelCommandLine=!audit=0` and will not start without it |
| `audit_backlog_limit=8192` | The kernel default is 64, which overflows during boot once `audit=1` is set (`kauditd hold queue overflow` in dmesg) and silently drops audit events |
| `skew_tick=1` | Skew timer ticks across cores — reduces lock contention |
| `workqueue.power_efficient=false` | Disable power-efficient workqueues — prevents cross-core cache misses |
| `preempt=full` | Full kernel preemption. Fedora builds `PREEMPT_DYNAMIC` and boots `lazy` by default; `full` trades a little throughput for lower worst-case latency. Check the active model with `journalctl -k -b \| grep 'Dynamic Preempt'` |

Takes effect on next boot. Verify with `cat /proc/cmdline`.

### 10. CPU Temperature Sensor

```bash
sudo dnf install -y lm_sensors
sensors | grep -E 'Tctl|Package id'  # Verify: Tctl on AMD, Package id 0 on Intel
```

`k10temp` (AMD) and `coretemp` (Intel) load on their own through the CPU's modalias; no `modules-load.d` entry is needed. `scripts/hwstat.sh cpu-temp` reads whichever one is present.

### 11. Firewall Hardening

The KDE Edition's default zone, FedoraWorkstation, has ports 1025-65535 open, plus the mdns, ssh and samba-client services. An install from the Everything ISO defaults to `public` instead; without `--zone`, `firewall-cmd` changes whichever zone is the default. Harden to only what's needed:

```bash
sudo firewall-cmd --permanent --remove-port=1025-65535/udp
sudo firewall-cmd --permanent --remove-port=1025-65535/tcp
sudo firewall-cmd --permanent --remove-service=mdns
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --permanent --remove-service=samba-client
sudo firewall-cmd --permanent --remove-service=kdeconnect
sudo firewall-cmd --permanent --add-service=dhcpv6-client
sudo firewall-cmd --reload
firewall-cmd --list-services  # Verify: dhcpv6-client
```

`kdeconnect` is removed from the zone — add it back if you pair a phone (see Disable Unnecessary Services).

### 12. Dual-Boot (Clock + Sleep/Hibernate)

Only relevant when Windows shares the machine. `fedora-setup.sh` checks the UEFI boot list for a Windows Boot Manager entry and otherwise only sets the clock to UTC.

**Clock** — Windows and Linux must read the hardware clock the same way, or the time is off by your UTC offset after switching OS. Use UTC on both sides:

- **Linux** → UTC: `fedora-setup.sh` runs `sudo timedatectl set-local-rtc 0`. Verify with `timedatectl` — it must show `RTC in local TZ: no`. If it shows `yes`, the two clocks fight; re-run `sudo timedatectl set-local-rtc 0`. *(This is the usual reason the time is still wrong even after the Windows reg edit.)*
- **Windows** → UTC, PowerShell as Administrator:
  ```powershell
  reg add "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /d 1 /t REG_DWORD /f
  ```
  Then Settings → Time & language → **Set time automatically** on.

**Sleep / hibernate** — after a long sleep, Windows (Modern Standby) auto-hibernates and powers off. The next wake is a full boot, so GRUB appears (Fedora is first in the UEFI boot order) and after its timeout boots Fedora — stranding the hibernated Windows session.

- **Windows** — disable hibernate (a desktop never needs it; sleep keeps RAM powered; on a laptop, weigh this against battery drain while asleep), PowerShell as Administrator:
  ```powershell
  powercfg /h off
  ```
  This also disables Fast Startup, which must be off when sharing an NTFS disk with Linux.
- **Linux** — `fedora-setup.sh` sets `GRUB_SAVEDEFAULT=true` (with `GRUB_DEFAULT=saved`) and regenerates `grub.cfg`, so GRUB remembers the last-booted OS. If GRUB does appear it re-selects Windows and chainloads the Windows Boot Manager, which resumes the hibernated session.

### 13. Backup — Snapper (BTRFS Snapshots)

Fedora installs on BTRFS by default. Snapper integrates natively with Fedora's subvolume layout. `fedora-setup.sh` skips this step when the root filesystem is something else.

```bash
sudo dnf install -y snapper btrfs-assistant
sudo snapper -c root create-config /
sudo snapper -c home create-config /home
sudo snapper -c home set-config TIMELINE_CREATE=no
sudo snapper -c root set-config TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 TIMELINE_LIMIT_MONTHLY=1 TIMELINE_LIMIT_YEARLY=0
sudo snapper -c home set-config TIMELINE_LIMIT_HOURLY=0 TIMELINE_LIMIT_DAILY=0 TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0
sudo snapper -c root setup-quota
sudo snapper -c home setup-quota
sudo snapper -c root create --description "Initial clean setup" --cleanup-algorithm number
sudo snapper -c home create --description "Initial home snapshot" --cleanup-algorithm number
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
```

> Note: Fedora often pre-configures snapper. If `create-config` returns "subvolume already covered", skip it and go straight to creating a snapshot.

`/home` changes constantly, so its hourly timeline snapshots are what fill the disk; it keeps only manual and number-cleanup snapshots, and `/` carries the timeline. The number cleanup needs a btrfs qgroup to weigh how much space snapshots pin, which `setup-quota` creates. Snapper's defaults keep 10 hourly, 10 daily, 10 monthly and 10 yearly timeline snapshots, and `TIMELINE_CREATE=no` does not delete the ones already made, so leftover home snapshots can pin hundreds of GB of deleted data. `/` therefore keeps 5 hourly, 7 daily, 2 weekly and 1 monthly, `/home` keeps none, and `scripts/disk-cleanup.sh` applies the limits and removes the rest.

**BTRFS Assistant** (GUI) is available in the app menu — shows all snapshots and allows one-click restore.

To list snapshots:

```bash
sudo snapper -c root list
```

To restore, boot from a live USB, mount the BTRFS partition, and use `btrfs subvolume` to swap snapshots — or use BTRFS Assistant.

Snapshots sit on the same disk as the data, so they are not a backup. [kopia](https://github.com/kopia/kopia) does encrypted, incremental backups to another disk or a remote and is not part of this setup.

### 14. Disable Unnecessary Services

```bash
# System services. Keep ModemManager on a laptop with a mobile broadband (WWAN)
# modem, and pcscd if you use a smart card or a YubiKey's PIV/OpenPGP applet.
sudo systemctl disable --now ModemManager avahi-daemon.socket avahi-daemon pcscd.socket pcscd

# Unused services holding sockets. gssproxy must be masked, not disabled —
# auth-rpcgss-module.service pulls it back in through WantedBy.
sudo systemctl disable --now cups.service cups.socket cups.path   # no printer
sudo systemctl mask --now gssproxy.service                        # no NFS mounts

# KDE Connect binds 0.0.0.0:1716 plus random UDP ports. Remove the package rather
# than masking it — Plasma re-activates the daemon over D-Bus, and a stub D-Bus
# service makes plasmashell block for 25s per attempt and the panel disappear.
# Keep the two dependencies that are useful on their own.
sudo dnf mark user fuse-sshfs openssh-askpass
sudo dnf remove -y kde-connect

# Baloo file indexer (major CPU offender)
balooctl6 disable
kwriteconfig6 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false

# KDE user services. These are generated from XDG autostart files and have no
# [Install] section, so `disable` silently does nothing — they must be masked.
# Verify with `systemctl --user is-enabled <unit>`: "generated" means still active.
systemctl --user mask --now \
  app-org.kde.discover.notifier@autostart.service \
  app-org.kde.kalendarac@autostart.service \
  app-sealertauto@autostart.service \
  app-org.freedesktop.problems.applet@autostart.service \
  'app-imsettings\x2dstart@autostart.service' \
  app-vboxclient@autostart.service

# Akonadi (KDE PIM — only needed if using KMail/Kontact). It pulls in ~16 processes
# and its own MariaDB. Same reason: mask, not disable.
systemctl --user mask --now akonadi_control.service

# DrKonqi's crash pickup: KDE's own unit stops it after 30 minutes (RuntimeMaxSec), which
# systemd records as a failed unit at every login. Crashes while logged in still get their
# dialog through drkonqi-coredump-launcher.socket; only crashes from before login go unseen.
systemctl --user mask --now drkonqi-coredump-pickup.service
```

Undo any of these with `systemctl --user unmask <unit>`.

`kalendarac` is the one that matters: with Akonadi masked it starts, fails to reach it, and dies with `malloc(): unaligned tcache chunk detected` — several hundred stack-trace lines in `journalctl -b -p err` every boot. `app-vboxclient` comes from `virtualbox-guest-additions`, which belongs inside a VM, not on the host. `imsettings-start` fails every login with `Current desktop isn't supported by IMSettings`; systemd escapes the hyphen in its unit name as `\x2d`.

### 15. libinput Debouncing

libinput adds eager debouncing to all mice by default. LAMZU mice such as the Maya X 8K use Hall Effect switches — debouncing is unnecessary and can block fast clicks. The quirk matches LAMZU's USB vendor IDs, so every other mouse keeps the default debouncing; add a section with your mouse's vendor ID (`lsusb`) to extend it.

```bash
sudo mkdir -p /etc/libinput
sudo cp system/libinput-overrides.quirks /etc/libinput/local-overrides.quirks
```

### 16. Audio Trim (optional)

`configs/wireplumber/wireplumber.conf.d/50-audio.conf` hides the onboard AMD audio controller, AMD iGPU HDMI audio and every webcam microphone from PipeWire. That is right when all sound goes through another device, such as a USB headset or the GPU's HDMI/DP output, and wrong otherwise — on many laptops the same AMD controller drives the speakers. It is therefore opt-in: set `AUDIO_TRIM=yes` in `setup.conf`, or copy it by hand:

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
cp configs/wireplumber/wireplumber.conf.d/50-audio.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

---

### 17. tmpfs Quota Fix (/tmp + /dev/shm)

systemd 256+ mounts `/tmp` and `/dev/shm` with an automatic per-user quota (~12 GB on 30 GB RAM). Heavy temp use (Chrome, large extractions) hits it and fails with **"Disk quota exceeded"** long before the tmpfs is full. Pointless on a single-user box.

```bash
# /tmp — drop-in removes usrquota (keeps nosuid/nodev/size)
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo cp system/tmp-mount-override.conf /etc/systemd/system/tmp.mount.d/override.conf

# /dev/shm — mounted before any unit exists, and remount cannot drop tmpfs quota.
# The limit is (re)applied by systemd-user-runtime-dir at every login, so clear it
# right after, from the unit that sets it.
sudo mkdir -p /etc/systemd/system/user-runtime-dir@.service.d
sudo cp system/user-runtime-dir-noquota.conf \
        /etc/systemd/system/user-runtime-dir@.service.d/noquota.conf
sudo systemctl daemon-reload
```

`/tmp` takes effect on reboot; `/dev/shm` from the next login. An `/etc/fstab` entry for
`/dev/shm` does **not** work — verified live, the quota survives it.

---

## Security Tooling

Not installed by `fedora-setup.sh` — these live on the system rather than in the repo,
documented here so the machine's security posture is reproducible.

### Auditing and integrity

```bash
sudo dnf install -y lynis aide rkhunter
```

| Tool | Use |
|---|---|
| `lynis` | Whole-system audit: `sudo lynis audit system` |
| `aide` | File integrity: `sudo aide --init` for a baseline, `sudo aide --check` after |
| `rkhunter` | Rootkit scan: `sudo rkhunter --check` |
| `auditd` | Collects the kernel audit events (`audit=1`, see Kernel Parameters): `sudo ausearch -m avc -ts today`, `sudo aureport --summary` |

AIDE flags every package update as a change; refresh the baseline with `sudo aide --update`.

Lynis suggestions that must not be applied here: `rp_filter=1` (breaks Tailscale and VPN routing), `kernel.modules_disabled=1` (blocks NVIDIA and USB), lower `vm.swappiness` (180 is set for ZRAM), disabling USB storage.

`kernel-hardening-checker` is not packaged for Fedora. It is stdlib-only Python, so run it from a pinned commit (v0.6.17.1):

```bash
git init -q /tmp/khc && git -C /tmp/khc fetch -q --depth 1 https://github.com/a13xp0p0v/kernel-hardening-checker afc376f2a935994793343cfeb05953583cc30191 && git -C /tmp/khc checkout -q FETCH_HEAD
sudo sysctl -a > /tmp/sysctl.txt
python3 /tmp/khc/bin/kernel-hardening-checker -c /boot/config-$(uname -r) -l /proc/cmdline -s /tmp/sysctl.txt -m show_fail
```

Most failures are expected. The kconfig checks describe Fedora's kernel build — fixing them means a self-built kernel, which breaks Secure Boot. The per-vulnerability mitigation checks only accept `mitigations=auto,nosmt`; the default `auto` is mitigated, which `deep-health.sh` confirms from sysfs. The zero-cost findings are in `99-tweaks.conf` (`kernel.unprivileged_bpf_disabled=1`, `kernel.oops_limit=100`, `vm.mmap_rnd_bits=32`). Findings that must not be applied here: `nosmt` (halves the threads), `ia32_emulation=0` (Steam and 32-bit games), `user.max_user_namespaces=0` (Flatpak, Steam pressure-vessel, browser sandboxes), `lockdown=confidentiality` and `kernel.kptr_restrict=2` (perf and bpftrace), `kernel.yama.ptrace_scope=3` (gdb, strace), `vm.mmap_rnd_compat_bits=16` (32-bit games lose contiguous address space), `kernel.warn_limit` (a driver's WARN splats would panic the box), and on AMD `pti=on` and `intel_iommu=on`, which only apply to Intel CPUs.

[dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening) and [dev-sec/linux-baseline](https://github.com/dev-sec/linux-baseline) are not used. They are server baselines: the defaults (`rp_filter=1`, `net.ipv4.ip_forward=0`, `kernel.kptr_restrict=2`, `kernel.sysrq=0`, a templated `auditd.conf`) break Mullvad, Tailscale, Docker and bpftrace here, and linux-baseline needs an InSpec runtime to check what lynis already covers.

### Malware scanning

```bash
sudo dnf install -y clamav clamd clamav-freshclam
sudo systemctl enable --now clamav-freshclam-once.timer
```

The timer is not enabled by the package, so without it the signature database silently goes stale — it ships once at install time and never updates. It runs daily with `Persistent=true`, so a missed run is caught up at next boot.

On-access scanning (`clamd@scan`, `clamav-clamonacc`) stays off — it costs throughput on every file read. Scan on demand with `clamscan -r <path>`, and pass `--tempdir` when scanning large archives so decompression does not fill `/tmp`.

### Sandboxing and mandatory access control

SELinux runs `enforcing` with the targeted policy — verify with `sestatus`, and use
`setroubleshoot` to explain denials. Flatpak sandboxes applications through `bubblewrap`.
Firejail is deliberately not used: it is SUID, has had its own privilege-escalation CVEs,
and Flatpak already covers the GUI applications here.

### Disk and system crypto

`cryptsetup` (LUKS), `gnupg2`, `openssl`.

### Firewall and VPN

`firewalld` (see Firewall Hardening above), `mullvad-vpn`, `tailscale`, `wireguard-tools`,
`openvpn`. DNS never gets a forced global resolver — see `system/resolved-hardening.conf`.

### Browser

`system/firefox-policies.json`, deployed to `/etc/firefox/policies/policies.json`, turns off telemetry, Studies, Pocket and sponsored content and turns on tracking protection for every profile. Per-profile hardening beyond that, such as fingerprinting resistance and cache behaviour, is what a [Betterfox](https://github.com/yokoffing/Betterfox) or [arkenfox](https://github.com/arkenfox/user.js) `user.js` does; neither is deployed here.

### Firmware and Secure Boot

`mokutil` manages enrolled keys (see NVIDIA Drivers + Secure Boot), `fwupd` applies
firmware updates (`fwupdmgr refresh && fwupdmgr update`), `efibootmgr` lists boot entries.

---

## Terminal Setup

### Kitty Terminal

```bash
sudo dnf install -y kitty
mkdir -p ~/.config/kitty
cp configs/kitty/kitty.conf ~/.config/kitty/kitty.conf
```

**Key bindings:**

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Tab` | Next tab |
| `Ctrl+Shift+Enter` | New window (split) |

### JetBrainsMono Nerd Font

```bash
mkdir -p ~/.local/share/fonts/JetBrainsMono
curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz" \
  -o /tmp/JetBrainsMono.tar.xz
echo "04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf  /tmp/JetBrainsMono.tar.xz" | sha256sum -c
tar -xf /tmp/JetBrainsMono.tar.xz -C ~/.local/share/fonts/JetBrainsMono/
fc-cache -fv
```

In KDE: **System Settings → Fonts → Fixed width** → `JetBrainsMono Nerd Font`

### Starship Prompt

Packaged in the Terra repo, which `fedora-setup.sh` adds and restricts with `includepkgs` (see Emulation):

```bash
sudo dnf install -y --repofrompath "terra,https://repos.fyralabs.com/terra$(rpm -E %fedora)" \
  --setopt="terra.gpgkey=https://repos.fyralabs.com/terra$(rpm -E %fedora)/key.asc" terra-release
sudo dnf config-manager setopt 'terra.includepkgs=terra-release,terra-gpg-keys,starship,emulationstation-de*'
sudo dnf install -y starship
cp configs/starship/starship.toml ~/.config/starship.toml
```

### Fish Shell (inside Kitty)

Fish is configured as the shell for Kitty only (`shell /usr/bin/fish` in `kitty.conf`), keeping bash as the login shell for KDE/PAM compatibility.

```bash
sudo dnf install -y fish
mkdir -p ~/.config/fish/functions
cp configs/fish/config.fish ~/.config/fish/config.fish
cp configs/fish/functions/ya.fish ~/.config/fish/functions/ya.fish
```

### Shell Tools

```bash
sudo dnf install -y zoxide fzf ripgrep fd-find bat eza git-delta
```

lazygit is not in the Fedora repos and the `atim/lazygit` COPR stopped at 0.47, so `fedora-setup.sh` installs the pinned upstream release (v0.66.2, SHA-256 checked) to `/usr/local/bin`.

### ble.sh (bash syntax highlighting)

Adds fish-style syntax coloring and completion in bash. Load order matters — it must be sourced before other config.

Pinned to a master commit; `origin` must exist because `.gitmodules` uses a relative URL:

```bash
git init -q /tmp/ble.sh && cd /tmp/ble.sh
git remote add origin https://github.com/akinomyoga/ble.sh.git
git fetch -q --depth 1 origin d81fd54feb0d996fdff20dca27eaf0201f7015cc && git checkout -q FETCH_HEAD
git submodule update -q --init --recursive --depth 1
make install PREFIX=~/.local
```

`configs/bashrc` holds the bashrc additions (aliases, zoxide, mise, starship). `fedora-setup.sh` handles the deploy: it prepends the ble.sh `--noattach` loader to line 1, then appends `configs/bashrc` itself followed by the `ble-attach` line — ble.sh requires `--noattach` first and `ble-attach` last. Both additions sit between `# >>> fedora-kde-setup` and `# <<< fedora-kde-setup` markers, and the untouched file is kept once as `~/.bashrc.orig`.

[Bash-it](https://github.com/Bash-it/bash-it) is not used: ble.sh, Starship and `configs/bashrc` already cover it, and Kitty runs fish, not bash.

### mise (Runtime Version Manager)

```bash
sudo dnf copr enable -y jdxcode/mise
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:jdxcode:mise.includepkgs=mise'
sudo dnf install -y mise
eval "$(mise activate bash)"
```

### Yazi (Terminal File Manager)

```bash
sudo dnf copr enable -y lihaohong/yazi
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:lihaohong:yazi.includepkgs=yazi,resvg'
sudo dnf install -y yazi
```

`resvg` renders yazi's SVG previews and comes from the same COPR.

---

## Desktop Rice (Darth Vader Theme)

![Wallpaper](wallpaper/wallpaper.jpg)

**Color palette extracted from wallpaper:**

| Color | Hex | Usage |
| --- | --- | --- |
| Background | `#090909` | Terminal, Conky bg |
| Teal (primary) | `#00c8a8` | Accents, clock, labels |
| Teal (bright) | `#1de9b6` | Directory, highlights |
| Red | `#cc2222` | Errors, speeds, danger |
| Gray | `#b0bec5` | Foreground text |

### Wallpaper

```bash
mkdir -p ~/Pictures
cp wallpaper/wallpaper.jpg ~/Pictures/wallpaper.jpg
```

Set in KDE: right-click desktop → Configure Desktop → Wallpaper

### KDE Color Scheme

```bash
mkdir -p ~/.local/share/color-schemes
cp configs/kde/DarthVader.colors ~/.local/share/color-schemes/
```

Apply: **System Settings → Colors → Darth Vader → Apply**

### Kvantum Theme (Application Style)

```bash
sudo dnf install -y kvantum
git init -q /tmp/layan-kde && git -C /tmp/layan-kde fetch -q --depth 1 https://github.com/vinceliuice/Layan-kde.git a0b6a4956022276aee33309b2e07d1d0ef3db30c && git -C /tmp/layan-kde checkout -q FETCH_HEAD
```

In **Kvantum Manager:**

1. Install/Update Theme → Select `/tmp/layan-kde/Kvantum/Layan` → Install
2. Change/Delete Theme → Select `LayanDark` → Use this theme

Apply: **System Settings → Application Style → kvantum → Apply**

```bash
mkdir -p ~/.config/Kvantum
cp configs/kde/kvantum/kvantum.kvconfig ~/.config/Kvantum/kvantum.kvconfig
```

Enable blur: **System Settings → Desktop Effects → Blur** (or via terminal):

```bash
kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled true
dbus-send --session --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure
```

### KDE Panel

Right-click panel → Enter Edit Mode:

- **Position:** Bottom
- **Alignment:** Center
- **Width:** Fit content
- **Floating:** Panel and applets (gives rounded corners)
- **Opacity:** Translucent

### Conky (System Stats Widget)

```bash
sudo dnf install -y conky
mkdir -p ~/.config/conky ~/.config/systemd/user
cp configs/conky/conky.conf ~/.config/conky/conky.conf
cp configs/systemd/conky.service ~/.config/systemd/user/conky.service
systemctl --user daemon-reload
systemctl --user enable --now conky.service
```

The config builds its hardware rows when Conky starts. It shows one row per four CPU cores (up to 16), GPU lines for whatever `~/scripts/hwstat.sh` can read, and a line per disk mounted under `/mnt`. It sits on the second screen when KWin reports more than one enabled output, otherwise on the only one, and adapts to the machine without edits.

---

## Gaming Setup

### Steam

Installed natively from RPM Fusion (`sudo dnf install steam`), not Flatpak. The Flatpak sandbox ships its own NVIDIA driver layer, which broke Vulkan device init (`RenderDeviceMgr001`) and forced shader reprocessing on a multi-GPU machine. Native uses the host driver directly. Launch options: `gamemoderun mangohud %command%` — host gamemode and MangoHud work without sandbox extensions. On a multi-GPU system, if a game picks the wrong GPU, pin NVIDIA with `__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only` (NVIDIA's offload layer, container-safe). Avoid `VK_LOADER_DRIVERS_SELECT` — it breaks Steam's pressure-vessel container.

### Flatpak

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak remote-delete --system fedora   # the spin's own OCI remote; unused, slows Discover refreshes
flatpak install -y flathub \
  net.davidotek.pupgui2 \
  com.heroicgameslauncher.hgl \
  net.lutris.Lutris \
  com.usebottles.bottles \
  org.prismlauncher.PrismLauncher \
  io.github.benjamimgois.goverlay \
  com.github.wwmm.easyeffects
```

### NTSync (Wine/Proton CPU sync)

NTSync is a Linux kernel feature that replaces Wine's user-space synchronization with native kernel primitives — lower CPU overhead and better frame times.

Requires Linux ≥ 6.14 and **GE-Proton ≥ 10-10** (install via ProtonUp-Qt). Standard Steam Proton does not support NTSync yet. Proton uses it automatically once `/dev/ntsync` is available.

```bash
sudo cp system/ntsync.conf /etc/modules-load.d/ntsync.conf
sudo cp system/70-ntsync.rules /etc/udev/rules.d/70-ntsync.rules
sudo udevadm control --reload-rules
sudo modprobe ntsync
```

Verify: `ls /dev/ntsync` — should exist after modprobe.

### Gamescope

```bash
sudo dnf install -y gamescope
sudo setcap cap_sys_nice+ep "$(which gamescope)"
```

`CAP_SYS_NICE` lets Gamescope use `--rt` (real-time scheduling) without root. rpm drops file capabilities whenever it replaces the binary, so `system/gamescope-caps.actions` (a `libdnf5-plugin-actions` hook) re-applies it after every gamescope install or update. Steam launch option example, with your display's mode filled in: `gamescope -W <width> -H <height> -r <refresh> --hdr-enabled -- %command%`. From a shell, `gcs2 <command>` (in `configs/bashrc` and `config.fish`) runs a program in gamescope at the primary monitor's current mode, read from `kscreen-doctor`.

### GameMode + MangoHud

```bash
sudo dnf install -y gamemode mangohud
```

Steam launch options: `gamemoderun mangohud %command%`

This is the universal baseline — use it on every game, native or Proton. The flags in the table below stack in front of it only for Proton games that need them.

### ProtonUp-Qt (Proton versions)

Installed via Flatpak (`net.davidotek.pupgui2`). Use to install GE-Proton for better game compatibility.

### KDE Direct Scanout

KDE Plasma can bypass the compositor entirely for fullscreen games, reducing latency. Requires:

- No color profile applied to the display
- HDR off
- Night Light off
- No custom KWin effects (default set only)

Compositor bypass happens automatically when conditions are met. Inspect it in the KWin debug console: `qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.showDebugConsole`.

### Steam Launch Options

Per-game launch options in Steam (right-click game → Properties → Launch Options):

| Use case | Launch option |
| --- | --- |
| Native Wayland (GE-Proton) | `PROTON_ENABLE_WAYLAND=1 %command%` |
| DLSS / RTX / Reflex (NVIDIA) | `PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 %command%` |
| Ray tracing (VKD3D) | `VKD3D_CONFIG=dxr %command%` |
| NVIDIA GPU not detected in game | add `PROTON_HIDE_NVIDIA_GPU=0` |
| All combined (NVIDIA) | `PROTON_ENABLE_WAYLAND=1 PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 PROTON_HIDE_NVIDIA_GPU=0 VKD3D_CONFIG=dxr %command%` |

Append `gamemoderun mangohud` after the env vars to keep GameMode and the overlay, e.g. `PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 gamemoderun mangohud %command%`.

On Proton 9+/GE-Proton 10.x, NVAPI is on by default, so `PROTON_ENABLE_NVAPI` is mostly a no-op. To force DLSS 4 DLLs on RTX 50-series, use GE-Proton with `PROTON_DLSS_UPGRADE=1 %command%`.

### Display & competitive

Verify the compositor actually runs at the panel's refresh rate with `qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.supportInformation | grep 'Refresh Rate'` — `MaxFPS` in `kwinrc` is an X11 leftover and does not limit Wayland.

- **VRR**: System Settings → Display & Monitor → Adaptive Sync → `Automatic`. On NVIDIA, driver 555.58+ gives Wayland explicit sync (no flicker). Good for desktop and single-player; leave it off for competitive CS2 (adds ~1-3 ms once FPS is well above refresh).
- **HDR**: use KWin's native HDR per-display. Avoid gamescope HDR on Plasma 6.5 with NVIDIA — known washed/grey regression. Keep HDR off for CS2 (it's SDR).
- **CS2 NVIDIA Reflex** (NVIDIA only): leave **Disabled** in Video settings — on Linux/NVIDIA it often hurts frametime consistency. Cap frames with `+fps_max 400` instead.

`PROTON_ENABLE_WAYLAND=1` requires GE-Proton — standard Steam Proton ignores it.

---

## Emulation

Retro frontend (ES-DE) + standalone emulators. Install with:

```bash
bash scripts/emulation-setup.sh
```

| System | Emulator | Source |
|---|---|---|
| PS1 | DuckStation | Official AppImage, pinned version and SHA-256 |
| PS2 | PCSX2 | Flatpak |
| PS3 | RPCS3 | Flatpak |
| SNES / N64 | RetroArch (snes9x / Mupen64Plus-Next cores) | Flatpak |
| Wii | Dolphin | Flatpak |
| Frontend | ES-DE (EmulationStation Desktop Edition) | Terra repo |

`fedora-setup.sh` adds Terra and limits it with `includepkgs` to `terra-release`, `terra-gpg-keys`, `starship` and `emulationstation-de`; unrestricted, its steam, scx-scheds and lact builds would shadow the RPM Fusion and COPR ones. `emulation-setup.sh` stops if Terra is missing. Terra builds ES-DE for a new Fedora release some time after it ships; until then the script skips ES-DE with a warning and installs the emulators, and the AppImage from [es-de.org](https://es-de.org/) works in the meantime.

### Default emulators (standalone, not libretro)

ES-DE defaults each system to a libretro core, but only the standalone emulators are installed — launching a game otherwise errors with `couldn't find emulator core file <x>_libretro.so`. `configs/es-de/es_systems.xml` (deployed to `~/ES-DE/custom_systems/`) overrides the default to the standalone emulator per system (psx → DuckStation, ps2 → PCSX2, ps3 → RPCS3, wii → Dolphin). A custom `es_find_rules.xml` resolves `%EMULATOR_DUCKSTATION%` to `~/Applications/DuckStation-x64.AppImage` alone, so an old Flatpak on the PATH cannot take precedence. Existing custom XML is kept as a numbered backup.

### BIOS / firmware / ROMs (user-provided)

Not shipped — provide your own:

- **ROMs** → `~/Emulation/roms/<system>/` (`psx`, `ps2`, `ps3`, `snes`, `n64`, `wii`). Set ES-DE's ROM directory here.
- **PS1 BIOS** → `${XDG_DATA_HOME:-$HOME/.local/share}/duckstation/bios`.
- **PS2 BIOS** → PCSX2's `bios/` folder under `~/.var/app/net.pcsx2.PCSX2/`.
- **PS3 firmware** → RPCS3 → File → Install Firmware (`PS3UPDAT.PUP` from Sony).
- **SNES/N64 cores** → RetroArch → Online Updater → Update Installed Cores.

> ROMs on a separate disk: move `~/Emulation/roms` to the disk and symlink it back, then grant the emulator Flatpaks access to that path (`flatpak override --user --filesystem=<path> <id>`).

DuckStation uses the unmodified official `v0.1-11894` AppImage. Both the executable and
the license are checked against pinned SHA-256 values before replacement. Its separate
[CC BY-NC-ND 4.0 license](https://github.com/stenzek/duckstation/blob/c66b2694da65cece8886ed3d4a069098831f8358/LICENSE)
includes noncommercial and no-derivatives conditions; this repository's MIT license
does not relicense DuckStation. License and source notices are installed alongside it.

An existing EOL DuckStation Flatpak and its data are retained. Close both versions and
copy its `~/.var/app/org.duckstation.DuckStation/config/duckstation` directory to the
native data location only if that destination is absent, then re-add game directories.
Check saves before uninstalling the old Flatpak, and keep its data by omitting
`--delete-data`. The installer prints these steps and always selects the new AppImage.

### Controller (DualSense)

- `system/99-dualsense.rules` stops the touchpad acting as a system mouse and the motion sensors registering as a second joystick (inverted axes / dead buttons).
- KWin's `gamecontroller` plugin emulates keyboard/mouse from a pad for desktop navigation, which hijacks emulators (D-pad→arrows, Cross→Enter, Circle→ESC). Disabled via `kwinrc` → `[Plugins] gamecontrollerEnabled=false` (needs re-login).
- Each emulator has its **own** mapping: PCSX2/DuckStation → Settings → Controllers → Automatic Mapping; Dolphin → Wii Remote 1 → Emulated Wii Remote → Configure.
- Camera feels inverted vs other games? That's the game's own *Invert Y-Axis* option, not the emulator.

---

## Local LLM (Strata)

[Strata](https://github.com/Niko1221/Strata) runs Qwen3.8-Flash-Next on the NVIDIA card plus system RAM and serves an OpenAI- and Anthropic-compatible API on `127.0.0.1:8080`. Opt-in — about 85 GB of model files for the Coder (more for the full model) and a one-time engine compile:

```bash
bash scripts/strata-setup.sh
```

Strata 0.2 is a desktop app, a Terminal and an engine, with Linux AppImages and ready-made engines; the ready-made engine is checked only against a hash fetched from the same GitHub release, so the script keeps compiling the engine from the pinned commit (`--build`) and adds NVIDIA's CUDA repo for `cuda-toolkit-13-4`, with NVIDIA's own driver packages excluded as [RPM Fusion recommends](https://rpmfusion.org/Howto/CUDA): they replace RPM Fusion's driver or collide with its files, and the next driver update then fails. It clones Strata pinned to v0.2.3.1 into `~/Prosjekter/Strata` and puts the model files on `/mnt/data/Strata-data` — not under `/home`, which snapper snapshots. `STRATA_DIR` and `STRATA_DATA` override both paths. An existing checkout must match the pinned commit and have no tracked edits; move an older one with `git fetch`, `git merge --ff-only <commit>` and `rm -rf build` in it first; a build folder left from the old source makes the compile a no-op and setup stops.

- **Model by RAM**: under 40 GiB the Coder (IQ1_M, half the experts — strong at code, answers Norwegian prompts mostly in English); otherwise the full model at the size Strata recommends.
- **Text only**: `--vision no --images no` keep 0.2's picture reader and image model off, so the Coder stays a text model with nothing new in VRAM; `./setup.sh --setup` in the checkout turns them on.
- **`--vram-reserve-mib 3072`**: the card also drives the desktop. With Strata's default 700 MiB reserve the lock screen could not allocate framebuffers on wake (`kscreenlocker_greet: eglSwapBuffers failed with 0x3003`, `nvidia-drm: Failed to allocate NVKMS memory for GEM object`) and froze. The bigger reserve costs about 20% decode speed (85 → 68 tokens/s on code).
- **`--experimental-speed-projection on`**: despite the name, Strata's refusal-direction vector, projected out of layers 4–44 at run time, so the model answers instead of refusing. On the Coder it refuses 4 of 146 AdvBench and JailbreakBench prompts, against 143 without it; Strata measures a mean KL of 0.063 to the stock model and 0.2–0.4% less speed. A request with `"experimental_speed_projection": false` gets the stock model.
- **Idle unload**: `"idle_unload_s": 600` in `strata-coder-iq1_m.json` ends the engine after 10 minutes without requests, so its RAM and VRAM go back; the next request loads it again in seconds while the files are still in the page cache.
- **Web search**: `"mcp_servers"` gives the chat page a DuckDuckGo search and page-fetch tool from `uvx duckduckgo-mcp-server@0.7.0` (no account), written when `uvx` is installed. The model decides when to call it, so what it reads from the web is untrusted input; API clients do not get the tool unless they send `"strata_mcp": true`.
- **Agents**: `"fit_max_tokens": true` shortens a request's `max_tokens` to the room left instead of refusing it (400). The Coder's 32K context is the real limit: Claude Code's system prompt alone is 26–31K, so it connects (`ANTHROPIC_BASE_URL=http://127.0.0.1:8080`, any `ANTHROPIC_AUTH_TOKEN`, a known `ANTHROPIC_MODEL` name) but has room for one-liners only, and Codex 0.163 sends ~36K before the first word and is refused. Both need a larger context chosen in Strata's setup, which takes VRAM from the 3 GiB reserve — not done here.
- **Running it**: `~/Prosjekter/Strata/run-coder-iq1_m.sh` opens the chat on `http://127.0.0.1:8080`. Closing the browser tab does not stop the server — Ctrl+C in its terminal does. Loaded, the model holds ~20 GB of RAM and ~9 GB of VRAM until 10 minutes after the last request — stop it before gaming.

---

## Local LLM (Ollama)

[Ollama](https://ollama.com) serves `gemma-4-12B-it-uncensored-heretic` (an uncensored community build of Gemma, from Hugging Face) on `127.0.0.1:11434`, with [Alpaca](https://flathub.org/apps/com.jeffser.Alpaca) as the chat GUI. Opt-in — about 9 GB:

```bash
sudo bash scripts/ollama-setup.sh
```

- **Upstream build**: Fedora's `ollama` links ROCm and pulls ~4 GiB of AMD libraries that are useless next to an NVIDIA card, so the script installs the CUDA build from Ollama's GitHub release, pinned by version and SHA-256. Re-run it after a version bump.
- **Hardened unit**: a drop-in applies the directives the nixpkgs module uses (`systemd-analyze security` 9.2 → 2.2) — it resets the `$PATH` the installer bakes into the unit and allows only the accelerator devices.
- **VRAM cap**: the card also drives the desktop, and a full load leaves under 1 GB free, which freezes the lock screen on wake (the same failure as Strata's, above). `OLLAMA_GPU_OVERHEAD` sets a 3 GiB floor, but only a baked `num_gpu` holds the headroom, so the script sweeps GPU layer counts and bakes the largest that still leaves about 3 GB free at `num_ctx 8192`. Every Ollama version fits the layers differently, which is why a re-run re-tunes.
- **Running it**: `ollama run gemma4-12b-heretic`, or pick the model in Alpaca. In Alpaca, add an Ollama instance at `http://127.0.0.1:11434` and leave **Override Parameters** off — on, it sends its own `num_ctx` and overrides the baked cap that holds the VRAM margin.

---

## Scripts

`--help` on the setup and maintenance scripts prints their header and exits without changing anything, and output is plain text when piped or with `NO_COLOR` set. `fedora-setup.sh` and `apply-system.sh` print what they will change and ask once, `fedora-upgrade.sh` asks before passing `--allowerasing` and `disk-cleanup.sh` before trimming snapshots; `--yes` answers those with yes, and without a terminal the first two refuse to run while the last two take the no. `ollama-setup.sh test` verifies an install, and `hwstat.sh` takes the reading to print. Any other argument prints the header and exits 2.

### `scripts/fedora-setup.sh`

Automated setup for a fresh Fedora 44 KDE install. Run after the initial system upgrade + reboot. It prints the detected hardware first, creates a verified recovery point before its first package or configuration change, installs the matching GPU drivers, and deploys the `system/` files via `apply-system.sh`. Close applications and other package managers first. Secure Boot MOK enrollment and BIOS settings stay manual (see the guide).

### `scripts/apply-system.sh`

Takes a snapper snapshot of `/` (see [Undoing Changes](#undoing-changes)), then deploys every file in `system/` to its live path (see the repository structure above) and reloads what can be reloaded without a reboot, including a `scx_loader` restart when its config changed. Hardware-specific files follow the detection: NVIDIA configs only with an NVIDIA driver, the desktop or laptop variants of tuned, scx and the kernel parameters. A config it deployed earlier that no longer fits the hardware, such as the NVIDIA files after a GPU swap, is removed as long as it is unedited. `fedora-setup.sh` calls it during setup; run it standalone to re-apply system configs after editing them.

### `scripts/lib/hw.sh` and `setup.conf`

`hw.sh` holds the detection: GPUs by PCI vendor and device ID (which also picks the NVIDIA driver branch), desktop or laptop from the SMBIOS chassis type or a system battery, Windows from the UEFI boot list. `setup.conf` (copied from `setup.conf.example`) overrides it per machine: `FORM_FACTOR`, `NVIDIA_DRIVER` and the opt-in `AUDIO_TRIM`. `tests/hw-detect.sh` runs the detection against fixture trees for each kind of machine.

### `scripts/setup-github.sh`

GitHub CLI login and a git identity derived from it: installs `gh`, logs in through the browser, wires git to gh's credential helper, then sets `user.name` and `user.email` from the GitHub account (the noreply address when the account email is hidden), `init.defaultBranch main`, `pull.rebase false` and `push.autoSetupRemote`. Run without sudo; gh keeps its credentials per user.

### `scripts/emulation-setup.sh`

Retro emulation setup — installs ES-DE (Terra repo) and the standalone emulators (PS1/PS2/PS3, Wii), grants Flatpak ROM access, and deploys the standalone-emulator defaults. BIOS/firmware/ROMs are user-provided (see the printed manual steps).

### `scripts/strata-setup.sh`

Local LLM setup — CUDA toolkit from NVIDIA's repo, Strata pinned to a release, the model picked by RAM, a 3 GiB VRAM reserve for the desktop, Strata's refusal vector, idle unload and DuckDuckGo web search. See [Local LLM (Strata)](#local-llm-strata).

### `scripts/ollama-setup.sh`

Local LLM via Ollama — the upstream CUDA build with a hardened unit, the uncensored Gemma model tuned to leave the desktop about 3 GB of VRAM, and Alpaca as the GUI. Opt-in; re-run to update Ollama and re-tune. See [Local LLM (Ollama)](#local-llm-ollama).

### `scripts/sysinfo.sh` — alias: `sysinfo`

Quick system health check in terminal. Shows CPU/GPU temps, load, RAM, disk (root plus anything mounted under `/mnt`), network, top processes, and warnings if anything exceeds 85%.

### `scripts/hwstat.sh`

One reading per call — `cpu-temp`, `gpu-name`, `gpu-temp`, `gpu-load`, `gpu-vram` — for Conky and `sysinfo.sh`. CPU temperature comes from `k10temp` (AMD) or `coretemp` (Intel). The GPU comes from `nvidia-smi` when the NVIDIA driver runs, otherwise from sysfs (AMD reports everything, Intel only a name). Fields it cannot read stay empty, and Conky leaves those lines out.

### `scripts/deep-health.sh`

Hardware audit: BIOS version and POST time, Secure Boot and MOK state, machine check counters, per-DIMM memory speed, temperatures, every physical NVMe/SATA disk's SMART data and supported short self-test, btrfs error counters and scrub, NTFS state, GPU, failed units. It preserves running self-tests, skips unsupported tests, and continues to later disks after a device failure. USB bridges and virtual disks are outside SMART discovery. Install the documented health-tool prerequisites before running it; missing `smartctl` is reported as a failure. `sysinfo.sh` is the glance; this is the check after a BIOS flash or when boot feels wrong. A single-disk audit takes around six minutes; each short test waits at most 450 seconds and btrfs scrub time depends on data size. Failed or unreadable health checks exit nonzero.

Firmware time far above normal (25 s or more on a desktop board) can mean the embedded controller is wedged. A reboot and Load Optimized Defaults do not clear it; only a full standby power drain does — PSU switch off, hold the case power button 30 seconds.

### `scripts/disk-cleanup.sh`

Space back from what grows unnoticed: snapper's snapshot timeline (listed first, trimmed only after a y/N), unused flatpak runtimes, PackageKit's and dnf's package caches, docker's unused images and build cache (volumes stay) and the calling user's unused podman images. Installed to `~/scripts/` by the setup; run with sudo. It waits for btrfs to release the deleted snapshots, which takes minutes after a big trim.

### `scripts/mok-reenroll.sh`

Re-enrolls the akmods signing key. A BIOS flash clears UEFI NVRAM and takes the MOK list with it, so locally signed modules such as NVIDIA's fail signature verification. With NVIDIA, nouveau claims the card and Plasma comes up to a black screen. The machine still boots to a TTY — run this from there, reboot, then pick Enroll MOK on the blue screen. Exits early if the key is still enrolled or Secure Boot is off.

### `scripts/fedora-upgrade.sh`

Upgrades to the next Fedora release; see [Upgrading Fedora](#upgrading-fedora). It downloads and leaves the reboot to `sudo dnf system-upgrade reboot`.

### `scripts/verify-setup.sh`

Checks the live system against what the setup configures: failed units, kernel arguments, auditd, zram, the sched_ext scheduler, tuned, the NVIDIA driver and suspend backing capacity, sleep services, gamescope's capability, NTSync, the firewall, SELinux, every deployed `system/` file, pending `.rpmnew` files and, when installed, ES-DE and the CUDA repo exclude. Run it after `fedora-setup.sh` and on the first boot of a new Fedora release. It changes nothing and exits 1 when a check fails.

### `scripts/rice-start.sh` — alias: `rice`

Restarts Conky.

**Install scripts:**

```bash
mkdir -p ~/scripts
cp scripts/rice-start.sh scripts/sysinfo.sh scripts/hwstat.sh scripts/deep-health.sh scripts/mok-reenroll.sh scripts/disk-cleanup.sh ~/scripts/
chmod +x ~/scripts/{rice-start,sysinfo,hwstat,deep-health,mok-reenroll,disk-cleanup}.sh
```

Conky and `sysinfo.sh` expect `hwstat.sh` next to them in `~/scripts/`.

Aliases (`rice`, `sysinfo`) are already in `configs/fish/config.fish` — deployed by `fedora-setup.sh`.

---

## Verification Checklist

`bash scripts/verify-setup.sh` runs these checks and more for the detected hardware, compares every deployed `system/` file with the repo, and exits non-zero when one fails. By hand, after a full setup:

```bash
# Kernel + Secure Boot
uname -r
mokutil --sb-state

# GPU — NVIDIA
nvidia-smi
lsmod | grep nvidia
# GPU — any vendor: the VA-API driver in use
vainfo 2>/dev/null | grep -i 'driver version'

# CPU (desktop; a laptop shows powersave and balanced / balanced-battery)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # performance
tuned-adm active                                             # latency-performance

# SCX scheduler (scx_loader reports active even when nothing is attached)
cat /sys/kernel/sched_ext/state      # enabled
cat /sys/kernel/sched_ext/root/ops   # bpfland_...

# ZRAM
lsblk | grep zram
cat /proc/sys/vm/swappiness  # 180

# Firewall
firewall-cmd --list-services  # dhcpv6-client

# Temperature
~/scripts/hwstat.sh cpu-temp

# Rice
pgrep conky && echo "Conky running"
```

---

## Undoing Changes

- **Pre-install recovery**: before package or configuration changes, `fedora-setup.sh` creates private read-only root and separate home snapshots plus verified `/boot` and EFI archives under `/.fedora-kde-setup-backups/run-*`. A `READY` marker identifies a completed backup; `RECOVERY.txt`, `layout.txt` and `mounts.txt` record recovery instructions, original layout and RTC policy. Recover from a Fedora live USB after saving newer work elsewhere. A later run reuses a completed restore point instead of adding one; Snapper does not manage them, and `scripts/disk-cleanup.sh` lists them and removes them on request. They protect the supported root/home/boot layout; external disks, firmware and EFI NVRAM are outside their scope. Filesystem snapshots on the same disk are not protection against disk loss or an atomic application transaction.
- **Later system deployments**: `apply-system.sh` separately takes a Snapper root snapshot and prints its number. `sudo snapper -c root status <n>..0` lists what changed since, and `sudo snapper -c root undochange <n>..0 <path>` reverts a file. Its root snapshot excludes `/boot`; use the original pre-install archives when reverting that install, or remove later kernel arguments with `sudo grubby --update-kernel=ALL --remove-args="<args>"`.
- **System files**: every target listed under Repository Structure is a file the setup adds, so deleting it undoes it, except `/etc/dnf/dnf.conf`, `/etc/tuned/ppd.conf` and `/etc/plasmalogin.conf`, which replace package defaults. Delete those and run `sudo dnf reinstall <package>` (`rpm -qf <file>` names it); a reinstall alone keeps the edited file because it is `%config(noreplace)`.
- **Services, firewall, KDE settings**: the commands in the guide above are the record; `systemctl unmask`, `firewall-cmd --permanent --add-service=<name>` and `kwriteconfig6` with the old value reverse them.
- **User configs**: `fedora-setup.sh` keeps replaced config files, including files within theme directories, the Conky unit, optional audio rules and helper scripts, as `<file>.~N~` next to each file. It preserves unrelated files inside copied theme directories. KDE settings written through `kwriteconfig6` need their own reversal.
- **GRUB default**: `/etc/default/grub.orig` is the file before the setup edited it; copy it back and run `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`.
- **Terminal extras**: `fedora-setup.sh` installs lazygit to `/usr/local/bin`, ble.sh to `~/.local/share/blesh`, the JetBrains Mono Nerd Font to `~/.local/share/fonts/JetBrainsMono`, and the helper scripts to `~/scripts`; remove those, then delete the two blocks between the `# >>> fedora-kde-setup` and `# <<< fedora-kde-setup` markers from `~/.bashrc`, or restore `~/.bashrc.orig`.
- **Ollama** (`scripts/ollama-setup.sh`): `sudo systemctl disable --now ollama`, then remove `/etc/systemd/system/ollama.service` and its `.d` drop-ins, `/usr/local/bin/ollama`, `/usr/local/lib/ollama`, `/var/lib/ollama`, the `ollama` user and group, and the GUI with `flatpak uninstall com.jeffser.Alpaca`.
- **Strata** (`scripts/strata-setup.sh`): remove the checkout (`~/Prosjekter/Strata`), the model files (`/mnt/data/Strata-data`), the CUDA repo `/etc/yum.repos.d/cuda-fedora44.repo`, and `sudo dnf remove cuda-toolkit-13-4`.
- **Emulation** (`scripts/emulation-setup.sh`): `flatpak uninstall` the Flatpak emulators, `sudo dnf remove emulationstation-de`, and remove `~/Applications/DuckStation-x64.AppImage` plus its license/source sidecars. Restore the numbered backups of `~/ES-DE/custom_systems/es_systems.xml` and `es_find_rules.xml` if present. ROMs, BIOS files and saves are left alone.

---

## Upgrading Fedora

```bash
bash scripts/fedora-upgrade.sh     # to the next release, e.g. 44 -> 45; downloads, does not reboot
sudo dnf system-upgrade reboot     # runs the upgrade offline and boots into the new release
bash scripts/verify-setup.sh       # on the first boot of the new release
```

`fedora-upgrade.sh` stops until the new release is out (its directory on dl.fedoraproject.org goes live on release day), brings the current release up to date and asks for a reboot if that installed a newer kernel. It refuses to start with less than 10 GB free on `/` or 200 MB on `/boot`, or on an NVIDIA machine whose driver is not loaded or whose akmods key is not enrolled under Secure Boot. Then it takes a snapper snapshot of `/` and downloads the upgrade.

`skip_if_unavailable=True` in `dnf.conf` keeps a third-party repo that has no build for the new release from stopping the download. A package built against libraries the new release replaced does stop it: the script names it and asks before passing `--allowerasing`, which removes it; reinstall it once its repo catches up. For Fedora 45 that is `emulationstation-de` from Terra, linked against FFmpeg 8 while Fedora 45 moves to FFmpeg 9. akmods rebuilds the NVIDIA module for the new kernel, at the latest on the first boot before the login screen. Fedora 45's mandatory RPM signatures do not stop it, because akmods installs its local build through `dnf --nogpgcheck`.

`/etc/dnf/dnf.conf`, `/etc/tuned/ppd.conf` and `/etc/plasmalogin.conf` are the package-owned files this setup replaces. When `verify-setup.sh` reports `.rpmnew` versions of them or other drift, review the package defaults for required upstream changes before re-running `scripts/apply-system.sh`. Reapplying overwrites those paths with this repository's versions.

What Fedora 45 changes for this setup (from its [ChangeSet](https://fedoraproject.org/wiki/Releases/45/ChangeSet)):

- **kmscon replaces the kernel text console.** It takes the keyboard layout from `localectl` and falls back to fbcon when it cannot start, so `mok-reenroll.sh` still runs from a TTY. `setfont` and `loadkeys` no longer apply there.
- **ptrace**: debuggers (`gdb`, `strace`, `ltrace`, `elfutils`, `systemtap`) now pull in `yama-ptrace-enable`, which sets `kernel.yama.ptrace_scope=0`. `99-tweaks.conf` keeps it at 1.
- **RPM signatures are mandatory**: `rpm -i` refuses an unsigned package or one whose key is not imported. Install local RPMs with `dnf install ./file.rpm`, which is also how akmods installs its NVIDIA build.
- **Repo files move to `/usr/share/dnf5/repos.d`.** The `includepkgs` and `exclude` limits the scripts set live in `/etc/dnf/repos.override.d` and keep applying. An edited packaged repo file comes back as `.rpmsave`.
- **Lua 5.5**: Conky is rebuilt against it, and `configs/conky/conky.conf` parses and runs unchanged.
- **Kernel crypto userspace API (AF_ALG) gets restricted.** bluetoothd uses it, so pair a Bluetooth device once after the upgrade; `verify-setup.sh` checks that the service still runs.

---

## Sources & Credits

### Core Tools

| Tool | Source |
| --- | --- |
| Fedora KDE | [fedoraproject.org/kde](https://fedoraproject.org/kde/) |
| RPM Fusion | [rpmfusion.org](https://rpmfusion.org/) |
| NVIDIA drivers | [rpmfusion.org/Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA) |
| SCX Schedulers | [github.com/sched-ext/scx](https://github.com/sched-ext/scx) |
| Flatpak / Flathub | [flathub.org](https://flathub.org/) |

### Terminal

| Tool | Source |
| --- | --- |
| Kitty | [sw.kovidgoyal.net/kitty](https://sw.kovidgoyal.net/kitty/) |
| Fish | [fishshell.com](https://fishshell.com/) |
| ble.sh | [github.com/akinomyoga/ble.sh](https://github.com/akinomyoga/ble.sh) |
| Starship | [starship.rs](https://starship.rs/) |
| Zoxide | [github.com/ajeetdsouza/zoxide](https://github.com/ajeetdsouza/zoxide) |
| Lazygit | [github.com/jesseduffield/lazygit](https://github.com/jesseduffield/lazygit) |
| Yazi | [github.com/sxyazi/yazi](https://github.com/sxyazi/yazi) |
| mise | [mise.jdx.dev](https://mise.jdx.dev/) |
| fzf | [github.com/junegunn/fzf](https://github.com/junegunn/fzf) |
| ripgrep | [github.com/BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) |
| bat | [github.com/sharkdp/bat](https://github.com/sharkdp/bat) |
| eza | [github.com/eza-community/eza](https://github.com/eza-community/eza) |
| JetBrainsMono NF | [github.com/ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts) |

### Rice / Desktop

| Tool | Source |
| --- | --- |
| Conky | [github.com/brndnmtthws/conky](https://github.com/brndnmtthws/conky) |
| Kvantum | [github.com/tsujan/Kvantum](https://github.com/tsujan/Kvantum) |
| Layan KDE | [github.com/vinceliuice/Layan-kde](https://github.com/vinceliuice/Layan-kde) |
| Panel Colorizer | [github.com/luisbocanegra/plasma-panel-colorizer](https://github.com/luisbocanegra/plasma-panel-colorizer) |
| Wallpaper | Made for this repo, no third-party source; covered by the MIT license like the rest of it |

### Gaming

| Tool | Source |
| --- | --- |
| Steam | [store.steampowered.com](https://store.steampowered.com/) |
| ProtonUp-Qt | [github.com/DavidoTek/ProtonUp-Qt](https://github.com/DavidoTek/ProtonUp-Qt) |
| Heroic Games Launcher | [heroicgameslauncher.com](https://heroicgameslauncher.com/) |
| Lutris | [lutris.net](https://lutris.net/) |
| Bottles | [usebottles.com](https://usebottles.com/) |
| Prism Launcher | [prismlauncher.org](https://prismlauncher.org/) |
| GOverlay | [github.com/benjamimgois/goverlay](https://github.com/benjamimgois/goverlay) |
| EasyEffects | [github.com/wwmm/easyeffects](https://github.com/wwmm/easyeffects) |
| MangoHud | [github.com/flightlessmango/MangoHud](https://github.com/flightlessmango/MangoHud) |
| GameMode | [github.com/FeralInteractive/gamemode](https://github.com/FeralInteractive/gamemode) |
| Gamescope | [github.com/ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope) |

### Gaming Guides

| Guide | Source |
| --- | --- |
| Linux Gaming Optimization | [github.com/theyareonit/linux-gaming-optimization](https://github.com/theyareonit/linux-gaming-optimization) |
| Linux Gaming Guide (AdelKS) | [github.com/AdelKS/LinuxGamingGuide](https://github.com/AdelKS/LinuxGamingGuide) |
| Linux Gaming Wiki | [linux-gaming.kwindu.eu](https://linux-gaming.kwindu.eu/) |

### Security

| Tool | Source |
| --- | --- |
| kernel-hardening-checker | [github.com/a13xp0p0v/kernel-hardening-checker](https://github.com/a13xp0p0v/kernel-hardening-checker) |

### References

- [Fedora Documentation](https://docs.fedoraproject.org/)
- [WirePlumber ALSA configuration](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html) — `monitor.alsa.rules` and `device.disabled`, used by `50-audio.conf`
- [Arch Wiki](https://wiki.archlinux.org/) — good reference even on Fedora
- [r/Fedora](https://www.reddit.com/r/Fedora/)
- [r/unixporn](https://www.reddit.com/r/unixporn/)
- [r/linux_gaming](https://www.reddit.com/r/linux_gaming/)
