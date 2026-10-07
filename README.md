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
├── configs/
│   ├── conky/conky.conf        # Desktop system stats widget
│   ├── es-de/es_systems.xml    # ~/ES-DE/custom_systems/ — standalone emulator defaults
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
│   ├── 99-tweaks.conf          # /etc/sysctl.d/ — performance tweaks
│   ├── 99-disable-modules.conf # /etc/modprobe.d/ — blacklist unused protocols (attack surface)
│   ├── dnf.conf                # /etc/dnf/ — DNF settings
│   ├── zram-generator.conf     # /etc/systemd/ — ZRAM as large as RAM, up to 8GB, zstd
│   ├── tmp-mount-override.conf # /etc/systemd/system/tmp.mount.d/ — drop tmpfs usrquota
│   ├── scx_loader.toml         # /etc/scx_loader/ — scx_bpfland Gaming mode on desktops (lavd until #3791 ships)
│   ├── scx_loader-laptop.toml  # /etc/scx_loader/ — scx_bpfland Auto mode on laptops
│   ├── resolved-hardening.conf # /etc/systemd/resolved.conf.d/ — DNSSEC, DoT, LLMNR/mDNS off
│   ├── tuned-ppd.conf          # /etc/tuned/ppd.conf — PPD → tuned profile map
│   ├── macros.image-language-conf # /etc/rpm/ — limit langpacks to en_US
│   ├── ntsync.conf             # /etc/modules-load.d/ — load ntsync at boot
│   ├── 99-ntsync.rules         # /etc/udev/rules.d/ — ntsync user access
│   ├── 99-lamzu.rules          # /etc/udev/rules.d/ — LAMZU mouse configurator access (by USB ID)
│   ├── 99-dualsense.rules      # /etc/udev/rules.d/ — DualSense touchpad/motion noise fix
│   ├── 99-disable-wakeup.rules # /etc/udev/rules.d/ — LAMZU dongles must not wake the system
│   ├── libinput-overrides.quirks # /etc/libinput/ — no mouse debouncing for LAMZU mice
│   ├── hugepages.conf          # /etc/tmpfiles.d/ — transparent hugepages
│   ├── kwin-display-fix.sh     # /usr/lib/systemd/system-sleep/ — USB and amdgpu resume quirks
│   ├── usb-autosuspend.service # /etc/systemd/system/ — autosuspend xHCI-blocking USB devices (by USB ID)
│   ├── gamescope-caps.actions  # /etc/dnf/libdnf5-plugins/actions.d/ — re-grant CAP_SYS_NICE after gamescope updates
│   ├── plasmalogin.conf        # /etc/plasmalogin.conf — login screen wallpaper
│   └── plasmalogin-restart.conf # systemd drop-in — auto-restart plasmalogin on crash
├── scripts/
│   ├── lib/hw.sh               # Hardware detection shared by the setup scripts
│   ├── fedora-setup.sh         # Automated post-upgrade setup (run after the initial system upgrade + reboot)
│   ├── apply-system.sh         # Deploy system/ files to their system paths
│   ├── emulation-setup.sh      # ES-DE + standalone emulators (PS1/2/3, Wii)
│   ├── strata-setup.sh         # Local LLM (Strata) on the NVIDIA card — opt-in, ~65 GB
│   ├── setup-github.sh         # GitHub CLI login + git identity/defaults
│   ├── rice-start.sh           # Restart Conky
│   ├── sysinfo.sh              # System health overview in terminal
│   ├── hwstat.sh               # CPU/GPU readings for Conky and sysinfo (AMD, Intel, NVIDIA)
│   ├── deep-health.sh          # Full hardware audit — firmware, SMART, btrfs scrub, self-test
│   └── mok-reenroll.sh         # Re-enroll the akmods MOK after a BIOS flash
├── tests/
│   └── hw-detect.sh            # Detection and hwstat tests against fixture sysfs trees
├── setup.conf.example          # Per-machine overrides; copy to setup.conf
└── wallpaper/
    └── wallpaper.jpg           # Darth Vader — dark, teal glow, red lightsaber (5120x2880)
```

---

## Quick Setup (New Machine)

```bash
# 1. Update the system to a clean kernel/driver baseline first, then reboot
sudo dnf upgrade --refresh -y
sudo reboot

# 2. After the reboot, clone and run the setup
git clone https://github.com/26zl/fedora-kde-setup.git ~/fedora-setup
cd ~/fedora-setup
cp setup.conf.example setup.conf   # optional: only to override the detection
bash scripts/fedora-setup.sh
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

### 2. DNF Configuration

```bash
sudo cp system/dnf.conf /etc/dnf/dnf.conf
```

Key settings: `installonly_limit=2` (max 2 kernels), `max_parallel_downloads=10`, `fastestmirror=True`

### 3. RPM Fusion

```bash
sudo dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
sudo dnf group upgrade -y core
```

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
sudo cp system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
sudo cp system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
```

Skip `nvidia-wayland.conf` on a laptop with hybrid graphics. It forces GLX, GBM and VA-API onto NVIDIA, but the panel is driven by the integrated GPU. There the desktop stays on the iGPU and single programs run on NVIDIA with `switcherooctl launch <program>`. `apply-system.sh` makes that call itself.

**Enable power management services:**

```bash
sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate
```

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
sudo dnf install -y scx-scheds
sudo systemctl enable --now scx_loader.service
sudo cp system/scx_loader.toml /etc/scx_loader/config.toml
```

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

Default FedoraWorkstation zone has ports 1025-65535 open, plus the mdns, ssh and samba-client services. Harden to only what's needed:

```bash
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-port=1025-65535/udp
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-port=1025-65535/tcp
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=mdns
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=ssh
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=samba-client
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=kdeconnect
sudo firewall-cmd --permanent --zone=FedoraWorkstation --add-service=dhcpv6-client
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
sudo snapper -c root create --description "Initial clean setup" --cleanup-algorithm number
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
```

> Note: Fedora often pre-configures snapper. If `create-config` returns "subvolume already covered", skip it and go straight to creating a snapshot.

**BTRFS Assistant** (GUI) is available in the app menu — shows all snapshots and allows one-click restore.

To list snapshots:

```bash
sudo snapper -c root list
```

To restore, boot from a live USB, mount the BTRFS partition, and use `btrfs subvolume` to swap snapshots — or use BTRFS Assistant.

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
  app-vboxclient@autostart.service

# Akonadi (KDE PIM — only needed if using KMail/Kontact). It pulls in ~16 processes
# and its own MariaDB. Same reason: mask, not disable.
systemctl --user mask --now akonadi_control.service
```

Undo any of these with `systemctl --user unmask <unit>`.

`kalendarac` is the one that matters: with Akonadi masked it starts, fails to reach it, and dies with `malloc(): unaligned tcache chunk detected` — several hundred stack-trace lines in `journalctl -b -p err` every boot. `app-vboxclient` comes from `virtualbox-guest-additions`, which belongs inside a VM, not on the host.

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

`kernel-hardening-checker` is not packaged for Fedora. It is stdlib-only Python, so run it from a pinned tag:

```bash
git clone --depth 1 --branch v0.6.17.1 https://github.com/a13xp0p0v/kernel-hardening-checker /tmp/khc
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
cp configs/fish/config.fish ~/.config/fish/config.fish
cp configs/fish/functions/ya.fish ~/.config/fish/functions/ya.fish
```

### Shell Tools

```bash
sudo dnf install -y zoxide fzf ripgrep fd-find bat eza git-delta
```

lazygit is not in the Fedora repos and the `atim/lazygit` COPR stopped at 0.47, so `fedora-setup.sh` installs the pinned upstream release (v0.65.1, SHA-256 checked) to `/usr/local/bin`.

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

`configs/bashrc` holds the bashrc additions (aliases, zoxide, mise, starship). `fedora-setup.sh` handles the deploy: it prepends the ble.sh `--noattach` loader to line 1, then appends `configs/bashrc` itself followed by the `ble-attach` line — ble.sh requires `--noattach` first and `ble-attach` last.

[Bash-it](https://github.com/Bash-it/bash-it) is not used: ble.sh, Starship and `configs/bashrc` already cover it, and Kitty runs fish, not bash.

### mise (Runtime Version Manager)

```bash
sudo dnf copr enable -y jdxcode/mise
sudo dnf install -y mise
eval "$(mise activate bash)"
```

### Yazi (Terminal File Manager)

```bash
sudo dnf copr enable -y lihaohong/yazi
sudo dnf install -y yazi
```

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
cp configs/kde/DarthVader.colors ~/.local/share/color-schemes/
```

Apply: **System Settings → Colors → Darth Vader → Apply**

### Kvantum Theme (Application Style)

```bash
sudo dnf install -y kvantum
git clone --depth=1 https://github.com/vinceliuice/Layan-kde.git /tmp/layan-kde
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

The config builds its hardware rows when Conky starts. It shows one row per four CPU cores (up to 16), GPU lines for whatever `~/scripts/hwstat.sh` can read, and a line per disk mounted under `/mnt`. It adapts to the machine without edits.

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
sudo cp system/99-ntsync.rules /etc/udev/rules.d/99-ntsync.rules
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
| PS1 | DuckStation | Flatpak |
| PS2 | PCSX2 | Flatpak |
| PS3 | RPCS3 | Flatpak |
| SNES / N64 | RetroArch (snes9x / Mupen64Plus-Next cores) | Flatpak |
| Wii | Dolphin | Flatpak |
| Frontend | ES-DE (EmulationStation Desktop Edition) | Terra repo |

`fedora-setup.sh` adds Terra and limits it with `includepkgs` to `terra-release`, `terra-gpg-keys`, `starship` and `emulationstation-de`; unrestricted, its steam, scx-scheds and lact builds would shadow the RPM Fusion and COPR ones. `emulation-setup.sh` stops if Terra is missing.

### Default emulators (standalone, not libretro)

ES-DE defaults each system to a libretro core, but only the standalone emulators are installed — launching a game otherwise errors with `couldn't find emulator core file <x>_libretro.so`. `configs/es-de/es_systems.xml` (deployed to `~/ES-DE/custom_systems/`) overrides the default to the standalone emulator per system (psx → DuckStation, ps2 → PCSX2, ps3 → RPCS3, wii → Dolphin).

### BIOS / firmware / ROMs (user-provided)

Not shipped — provide your own:

- **ROMs** → `~/Emulation/roms/<system>/` (`psx`, `ps2`, `ps3`, `snes`, `n64`, `wii`). Set ES-DE's ROM directory here.
- **PS1/PS2 BIOS** → the emulator's `bios/` folder under `~/.var/app/<id>/`.
- **PS3 firmware** → RPCS3 → File → Install Firmware (`PS3UPDAT.PUP` from Sony).
- **SNES/N64 cores** → RetroArch → Online Updater → Update Installed Cores.

> ROMs on a separate disk: move `~/Emulation/roms` to the disk and symlink it back, then grant the emulator Flatpaks access to that path (`flatpak override --user --filesystem=<path> <id>`).

> DuckStation's Flathub build is end-of-life (still works). For the maintained version use the official AppImage in `~/Applications/` — ES-DE auto-detects it.

### Controller (DualSense)

- `system/99-dualsense.rules` stops the touchpad acting as a system mouse and the motion sensors registering as a second joystick (inverted axes / dead buttons).
- KWin's `gamecontroller` plugin emulates keyboard/mouse from a pad for desktop navigation, which hijacks emulators (D-pad→arrows, Cross→Enter, Circle→ESC). Disabled via `kwinrc` → `[Plugins] gamecontrollerEnabled=false` (needs re-login).
- Each emulator has its **own** mapping: PCSX2/DuckStation → Settings → Controllers → Automatic Mapping; Dolphin → Wii Remote 1 → Emulated Wii Remote → Configure.
- Camera feels inverted vs other games? That's the game's own *Invert Y-Axis* option, not the emulator.

---

## Local LLM (Strata)

[Strata](https://github.com/Niko1221/Strata) runs Qwen3.8-Flash-Next on the NVIDIA card plus system RAM and serves an OpenAI- and Anthropic-compatible API on `127.0.0.1:8080`. Opt-in — about 65 GB of model files and a one-time engine compile:

```bash
bash scripts/strata-setup.sh
```

Strata compiles its engine on Linux (its release assets are Windows-only), so the script adds NVIDIA's CUDA repo for `cuda-toolkit-13-4`. It clones Strata pinned to v0.1.40.1 into `~/Prosjekter/Strata` and puts the model files on `/mnt/data/Strata-data` — not under `/home`, which snapper snapshots. `STRATA_DIR` and `STRATA_DATA` override both paths.

- **Model by RAM**: under 40 GiB the Coder (IQ1_M, half the experts — strong at code, answers Norwegian prompts mostly in English); otherwise the full model at the size Strata recommends.
- **`--vram-reserve-mib 3072`**: the card also drives the desktop. With Strata's default 700 MiB reserve the lock screen could not allocate framebuffers on wake (`kscreenlocker_greet: eglSwapBuffers failed with 0x3003`, `nvidia-drm: Failed to allocate NVKMS memory for GEM object`) and froze. The bigger reserve costs about 20% decode speed (85 → 68 tokens/s on code).
- **Running it**: `~/Prosjekter/Strata/setup.sh` opens the chat on `http://127.0.0.1:8080`; closing its window stops the model. While it runs it holds ~20 GB of RAM and ~9 GB of VRAM — close it before gaming.

---

## Scripts

### `scripts/fedora-setup.sh`

Automated setup for a fresh Fedora 44 KDE install. Run after the initial system upgrade + reboot. It prints the detected hardware first, installs the matching GPU drivers, and deploys the `system/` files via `apply-system.sh`. Secure Boot MOK enrollment and BIOS settings stay manual (see the guide).

### `scripts/apply-system.sh`

Deploys every file in `system/` to its live path (see the repository structure above) and reloads what can be reloaded without a reboot. Hardware-specific files follow the detection: NVIDIA configs only with an NVIDIA driver, the desktop or laptop variants of tuned, scx and the kernel parameters. A config it deployed earlier that no longer fits the hardware, such as the NVIDIA files after a GPU swap, is removed as long as it is unedited. `fedora-setup.sh` calls it during setup; run it standalone to re-apply system configs after editing them.

### `scripts/lib/hw.sh` and `setup.conf`

`hw.sh` holds the detection: GPUs by PCI vendor and device ID (which also picks the NVIDIA driver branch), desktop or laptop from the SMBIOS chassis type or a system battery, Windows from the UEFI boot list. `setup.conf` (copied from `setup.conf.example`) overrides it per machine: `FORM_FACTOR`, `NVIDIA_DRIVER` and the opt-in `AUDIO_TRIM`. `tests/hw-detect.sh` runs the detection against fixture trees for each kind of machine.

### `scripts/emulation-setup.sh`

Retro emulation setup — installs ES-DE (Terra repo) and the standalone emulators (PS1/PS2/PS3, Wii), grants Flatpak ROM access, and deploys the standalone-emulator defaults. BIOS/firmware/ROMs are user-provided (see the printed manual steps).

### `scripts/strata-setup.sh`

Local LLM setup — CUDA toolkit from NVIDIA's repo, Strata pinned to a release, the model picked by RAM and a 3 GiB VRAM reserve for the desktop. See [Local LLM (Strata)](#local-llm-strata).

### `scripts/sysinfo.sh` — alias: `sysinfo`

Quick system health check in terminal. Shows CPU/GPU temps, load, RAM, disk (root plus anything mounted under `/mnt`), network, top processes, and warnings if anything exceeds 85%.

### `scripts/hwstat.sh`

One reading per call — `cpu-temp`, `gpu-name`, `gpu-temp`, `gpu-load`, `gpu-vram` — for Conky and `sysinfo.sh`. CPU temperature comes from `k10temp` (AMD) or `coretemp` (Intel). The GPU comes from `nvidia-smi` when the NVIDIA driver runs, otherwise from sysfs (AMD reports everything, Intel only a name). Fields it cannot read stay empty, and Conky leaves those lines out.

### `scripts/deep-health.sh`

Full hardware audit: BIOS version and POST time, Secure Boot and MOK state, machine check counters, per-DIMM memory speed, temperatures, NVMe SMART plus a short self-test, btrfs error counters and scrub, NTFS state, GPU, failed units. `sysinfo.sh` is the glance; this is the check after a BIOS flash or when boot feels wrong. Takes around six minutes — the scrub and the self-test dominate. Sections that do not apply (no NVMe, no btrfs root, no NVIDIA GPU) are skipped.

Firmware time far above normal (25 s or more on a desktop board) can mean the embedded controller is wedged. A reboot and Load Optimized Defaults do not clear it; only a full standby power drain does — PSU switch off, hold the case power button 30 seconds.

### `scripts/mok-reenroll.sh`

Re-enrolls the akmods signing key. A BIOS flash clears UEFI NVRAM and takes the MOK list with it, so locally signed modules such as NVIDIA's fail signature verification. With NVIDIA, nouveau claims the card and Plasma comes up to a black screen. The machine still boots to a TTY — run this from there, reboot, then pick Enroll MOK on the blue screen. Exits early if the key is still enrolled or Secure Boot is off.

### `scripts/rice-start.sh` — alias: `rice`

Restarts Conky.

**Install scripts:**

```bash
mkdir -p ~/scripts
cp scripts/rice-start.sh scripts/sysinfo.sh scripts/hwstat.sh scripts/deep-health.sh scripts/mok-reenroll.sh ~/scripts/
chmod +x ~/scripts/{rice-start,sysinfo,hwstat,deep-health,mok-reenroll}.sh
```

Conky and `sysinfo.sh` expect `hwstat.sh` next to them in `~/scripts/`.

Aliases (`rice`, `sysinfo`) are already in `configs/fish/config.fish` — deployed by `fedora-setup.sh`.

---

## Verification Checklist

Run after full setup to confirm everything is working:

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

## Sources & Credits

### Core Tools

| Tool | Source |
| --- | --- |
| Fedora KDE | [fedoraproject.org/spins/kde](https://fedoraproject.org/spins/kde) |
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
