#!/bin/bash
# Deploy all system/ files to their live system paths. Hardware-specific files
# follow scripts/lib/hw.sh and the overrides in setup.conf (see setup.conf.example).

set -e
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh
# shellcheck disable=SC1091
[ -f setup.conf ] && source ./setup.conf
hw_check_conf

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

# Remove a file an earlier run deployed once it no longer fits the hardware, but
# only while it still matches the repo copy — an edited file is the owner's.
retire() {  # repo-file live-path
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        sudo rm -f "$2"
        ok "removed $2 (does not apply to this hardware)"
    fi
}

FORM_FACTOR=$(hw_form_factor)
NVIDIA_BRANCH=$(hw_nvidia_driver)
section "Hardware"
ok "$(hw_summary)"

section "NVIDIA"
if [ -n "$NVIDIA_BRANCH" ]; then
    sudo cp system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
    sudo systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume
    ok "nvidia-performance.conf, suspend/resume services enabled"
    if hw_is_hybrid_laptop; then
        # the panel hangs off the integrated GPU; forcing GLX, GBM and VA-API onto
        # NVIDIA would keep the dGPU awake and can break the session
        retire system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
        ok "hybrid graphics: desktop stays on the integrated GPU (offload apps with switcherooctl launch)"
    else
        sudo cp system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
        ok "nvidia-wayland.conf"
    fi
else
    retire system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
    retire system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
    ok "no NVIDIA driver in use — skipped"
fi

section "sysctl / DNF / ZRAM"
sudo cp system/99-tweaks.conf /etc/sysctl.d/99-tweaks.conf
sudo sysctl --system -q
sudo cp system/99-disable-modules.conf /etc/modprobe.d/99-disable-modules.conf
sudo cp system/dnf.conf /etc/dnf/dnf.conf
sudo cp system/macros.image-language-conf /etc/rpm/macros.image-language-conf
sudo cp system/zram-generator.conf /etc/systemd/zram-generator.conf
sudo cp system/hugepages.conf /etc/tmpfiles.d/hugepages.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/hugepages.conf
ok "99-tweaks.conf, 99-disable-modules.conf, dnf.conf, zram-generator.conf, hugepages.conf"

section "Kernel parameters"
KERNEL_ARGS="nowatchdog audit=1 audit_backlog_limit=8192 skew_tick=1 preempt=full"
# desktops trade a little idle power for cache locality; laptops keep power-efficient workqueues
[ "$FORM_FACTOR" = desktop ] && KERNEL_ARGS="$KERNEL_ARGS workqueue.power_efficient=false"
sudo grubby --update-kernel=ALL --remove-args="nowatchdog audit=0 audit=1 audit_backlog_limit skew_tick=1 workqueue.power_efficient=false preempt=full" 2>/dev/null || true
sudo grubby --update-kernel=ALL --args="$KERNEL_ARGS"
ok "Kernel parameters set for a $FORM_FACTOR (takes effect on next boot)"

section "SCX scheduler"
sudo mkdir -p /etc/scx_loader
if [ "$FORM_FACTOR" = laptop ]; then
    sudo cp system/scx_loader-laptop.toml /etc/scx_loader/config.toml
    ok "scx_loader-laptop.toml (scx_bpfland, Auto mode)"
else
    sudo cp system/scx_loader.toml /etc/scx_loader/config.toml
    ok "scx_loader.toml (scx_bpfland, Gaming mode)"
fi

section "tuned"
sudo cp system/tuned-ppd.conf /etc/tuned/ppd.conf
if [ "$FORM_FACTOR" = laptop ]; then
    # tuned-ppd's battery-aware default; also undoes latency-performance left by an
    # earlier desktop run. Performance in the battery applet still maps to latency-performance
    sudo tuned-adm profile balanced
    ok "tuned: balanced; PPD performance mapped to latency-performance"
else
    sudo tuned-adm profile latency-performance
    ok "tuned: latency-performance; PPD performance mapped to latency-performance"
fi

section "udev rules (device quirks, inert without the device)"
sudo cp system/99-lamzu.rules /etc/udev/rules.d/99-lamzu.rules
sudo cp system/99-disable-wakeup.rules /etc/udev/rules.d/99-disable-wakeup.rules
sudo cp system/99-dualsense.rules /etc/udev/rules.d/99-dualsense.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
ok "99-lamzu.rules, 99-disable-wakeup.rules, 99-dualsense.rules"

section "Suspend / resume"
sudo cp system/kwin-display-fix.sh /usr/lib/systemd/system-sleep/kwin-display-fix.sh
sudo chmod +x /usr/lib/systemd/system-sleep/kwin-display-fix.sh
sudo cp system/usb-autosuspend.service /etc/systemd/system/usb-autosuspend.service
sudo systemctl daemon-reload
sudo systemctl enable --now usb-autosuspend.service
ok "kwin-display-fix.sh, usb-autosuspend.service"

section "DNS hardening"
sudo mkdir -p /etc/systemd/resolved.conf.d
# a restart drops the per-link DNS a VPN or Tailscale set, so only restart on change
if ! cmp -s system/resolved-hardening.conf /etc/systemd/resolved.conf.d/hardening.conf; then
    sudo cp system/resolved-hardening.conf /etc/systemd/resolved.conf.d/hardening.conf
    sudo systemctl restart systemd-resolved
fi
ok "resolved-hardening.conf (Quad9, DNSSEC, DoT)"

section "plasmalogin restart fix"
sudo mkdir -p /etc/systemd/system/plasmalogin.service.d
sudo cp system/plasmalogin-restart.conf /etc/systemd/system/plasmalogin.service.d/restart.conf
sudo systemctl daemon-reload
ok "plasmalogin-restart.conf"

section "plasmalogin wallpaper"
sudo mkdir -p /usr/share/wallpapers/custom
sudo cp wallpaper/wallpaper.jpg /usr/share/wallpapers/custom/wallpaper.jpg
sudo cp system/plasmalogin.conf /etc/plasmalogin.conf
ok "Login screen wallpaper set"

section "journald limits"
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp system/journald-limits.conf /etc/systemd/journald.conf.d/limits.conf
sudo systemctl restart systemd-journald
ok "journal capped at 1G (systemd default here was 4G)"

section "Firefox policies"
sudo mkdir -p /etc/firefox/policies
sudo cp system/firefox-policies.json /etc/firefox/policies/policies.json
ok "Firefox: telemetry, Studies, Pocket and sponsored content off; tracking protection on"

section "libinput debounce"
sudo mkdir -p /etc/libinput
sudo cp system/libinput-overrides.quirks /etc/libinput/local-overrides.quirks
ok "libinput-overrides.quirks (debouncing off for LAMZU mice only)"

section "NTSync"
sudo cp system/ntsync.conf /etc/modules-load.d/ntsync.conf
sudo cp system/99-ntsync.rules /etc/udev/rules.d/99-ntsync.rules
sudo udevadm control --reload-rules
sudo modprobe ntsync 2>/dev/null || true
ok "99-ntsync.rules, ntsync.conf"

section "Disk quota fix (tmpfs)"
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo cp system/tmp-mount-override.conf /etc/systemd/system/tmp.mount.d/override.conf
sudo mkdir -p /etc/systemd/system/user-runtime-dir@.service.d
sudo cp system/user-runtime-dir-noquota.conf /etc/systemd/system/user-runtime-dir@.service.d/noquota.conf
sudo systemctl daemon-reload
# drop-in clears /dev/shm limit at each login; clear the current session now too
sudo setquota -u "$(id -u)" 0 0 0 0 /dev/shm 2>/dev/null || true
ok "usrquota dropped on /tmp (reboot); /dev/shm per-user limit cleared at each login"

section "gamescope capabilities"
sudo mkdir -p /etc/dnf/libdnf5-plugins/actions.d
sudo cp system/gamescope-caps.actions /etc/dnf/libdnf5-plugins/actions.d/gamescope-caps.actions
ok "CAP_SYS_NICE re-applied after every gamescope update (needs libdnf5-plugin-actions)"

section "Done"
ok "All system files deployed. Reboot recommended if modprobe/zram configs changed."
