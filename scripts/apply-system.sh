#!/bin/bash
# Deploy all system/ files to their live system paths. Hardware-specific files
# follow scripts/lib/hw.sh and the overrides in setup.conf (see setup.conf.example).
# Prints what it will change and asks once; --yes skips that (required when stdin
# is not a terminal; fedora-setup.sh and the CI container pass it)

YES=0
[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1-} in
    "") ;;
    --yes) YES=1 ;;
    -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

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
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }
confirm() {
    [ "$YES" -eq 1 ] && return 0
    [ -t 0 ] || { echo "  not a terminal: pass --yes to run without the confirmation" >&2; exit 1; }
    local reply
    read -rp "  Continue? [y/N] " reply
    [[ $reply == [yY]* ]] || { echo "  stopped, nothing changed"; exit 1; }
}

# Retire obsolete deployments only when they still match the repository copy.
retire() {  # repo-file live-path
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        sudo rm -f "$2"
        ok "removed obsolete $2"
    fi
}

FORM_FACTOR=$(hw_form_factor)
NVIDIA_BRANCH=$(hw_nvidia_driver)
KERNEL_ARGS="nowatchdog audit=1 audit_backlog_limit=8192 skew_tick=1 preempt=full"
# desktops trade a little idle power for cache locality; laptops keep power-efficient workqueues
[ "$FORM_FACTOR" = desktop ] && KERNEL_ARGS="$KERNEL_ARGS workqueue.power_efficient=false"
section "Hardware"
ok "$(hw_summary)"

section "Plan"
echo "  This run will, with sudo:"
echo "   - take a snapper snapshot of / first (the restore point)"
echo "   - copy every system/ file to its system path and reload sysctl, udev, tmpfiles and systemd"
echo "   - set the kernel arguments on every installed kernel: $KERNEL_ARGS"
echo "   - restart journald, and scx_loader and systemd-resolved only when their config changed"
confirm

section "Restore point"
# /etc is in the root snapshot, /boot (kernel arguments) is not
if snap=$(sudo snapper -c root create --description "before apply-system.sh" --cleanup-algorithm number --print-number 2>/dev/null); then
    ok "snapper root snapshot $snap (sudo snapper -c root status $snap..0 lists what this run changed)"
else
    warn "no snapper root config yet: no restore point"
fi

section "NVIDIA"
if [ -n "$NVIDIA_BRANCH" ]; then
    sudo cp system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
    sudo mkdir -p /usr/local/bin
    sudo cp system/nvidia-vram-check.sh /usr/local/bin/nvidia-vram-check.sh
    sudo chmod 755 /usr/local/bin/nvidia-vram-check.sh
    sudo cp system/nvidia-vram-check.service /etc/systemd/system/nvidia-vram-check.service
    sudo restorecon /usr/local/bin/nvidia-vram-check.sh /etc/systemd/system/nvidia-vram-check.service
    sudo systemctl daemon-reload
    sudo systemctl enable nvidia-vram-check.service
    sudo systemctl enable nvidia-suspend nvidia-hibernate nvidia-suspend-then-hibernate nvidia-resume
    ok "nvidia-performance.conf, pre-sleep capacity check and suspend/resume services enabled"
    if hw_is_hybrid_gpu; then
        # Forcing NVIDIA rendering keeps a hybrid system's dGPU awake and can break the session.
        retire system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
        ok "hybrid graphics: desktop stays on the integrated GPU (offload apps with switcherooctl launch)"
    else
        sudo mkdir -p /etc/environment.d
        sudo cp system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
        ok "nvidia-wayland.conf"
    fi
else
    if cmp -s system/nvidia-vram-check.service /etc/systemd/system/nvidia-vram-check.service; then
        sudo systemctl disable nvidia-vram-check.service
        retire system/nvidia-vram-check.service /etc/systemd/system/nvidia-vram-check.service
        sudo systemctl daemon-reload
    fi
    if [ ! -e /etc/systemd/system/nvidia-vram-check.service ]; then
        retire system/nvidia-vram-check.sh /usr/local/bin/nvidia-vram-check.sh
    fi
    retire system/nvidia-performance.conf /etc/modprobe.d/nvidia-performance.conf
    retire system/nvidia-wayland.conf /etc/environment.d/nvidia-wayland.conf
    ok "no NVIDIA driver in use — skipped"
fi

section "sysctl / DNF / ZRAM"
sudo cp system/99-tweaks.conf /etc/sysctl.d/99-tweaks.conf
sudo sysctl --system -q
sudo cp system/99-disable-modules.conf /etc/modprobe.d/99-disable-modules.conf
sudo cp system/dnf.conf /etc/dnf/dnf.conf
# Restrict languages without stripping translations required by the system or session.
printf '%%_install_langs %s\n' "$(hw_install_langs)" | sudo tee /etc/rpm/macros.image-language-conf >/dev/null
sudo cp system/zram-generator.conf /etc/systemd/zram-generator.conf
sudo cp system/hugepages.conf /etc/tmpfiles.d/hugepages.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/hugepages.conf
ok "99-tweaks.conf, 99-disable-modules.conf, dnf.conf, zram-generator.conf, hugepages.conf"

section "Kernel parameters"
sudo grubby --update-kernel=ALL --remove-args="nowatchdog audit=0 audit=1 audit_backlog_limit skew_tick=1 workqueue.power_efficient=false preempt=full" 2>/dev/null || true
sudo grubby --update-kernel=ALL --args="$KERNEL_ARGS"
ok "Kernel parameters set for a $FORM_FACTOR (takes effect on next boot)"

section "SCX scheduler"
sudo mkdir -p /etc/scx_loader
scx_before=$(cat /etc/scx_loader/config.toml 2>/dev/null || true)
if [ "$FORM_FACTOR" = laptop ]; then
    sudo cp system/scx_loader-laptop.toml /etc/scx_loader/config.toml
    ok "scx_loader-laptop.toml (scx_bpfland, Auto mode)"
else
    sudo cp system/scx_loader.toml /etc/scx_loader/config.toml
    ok "scx_loader.toml (scx_bpfland, Gaming mode)"
fi
# scx_loader reads its config only when it starts
if [ "$scx_before" != "$(cat /etc/scx_loader/config.toml)" ] && systemctl is-active -q scx_loader; then
    sudo systemctl restart scx_loader
    ok "scx_loader restarted on the new config"
fi

section "tuned"
sudo cp system/tuned-ppd.conf /etc/tuned/ppd.conf
if [ "$FORM_FACTOR" = laptop ]; then
    # Balanced lets tuned-ppd select its battery profile on laptops.
    sudo tuned-adm profile balanced
    ok "tuned: balanced; PPD performance mapped to latency-performance"
else
    sudo tuned-adm profile latency-performance
    ok "tuned: latency-performance; PPD performance mapped to latency-performance"
fi

section "udev rules (device quirks, inert without the device)"
retire system/70-lamzu.rules /etc/udev/rules.d/99-lamzu.rules
sudo cp system/70-lamzu.rules /etc/udev/rules.d/70-lamzu.rules
sudo cp system/99-disable-wakeup.rules /etc/udev/rules.d/99-disable-wakeup.rules
sudo cp system/99-dualsense.rules /etc/udev/rules.d/99-dualsense.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
ok "70-lamzu.rules, 99-disable-wakeup.rules, 99-dualsense.rules"

section "Suspend / resume"
sudo cp system/kwin-display-fix.sh /usr/lib/systemd/system-sleep/kwin-display-fix.sh
sudo chmod +x /usr/lib/systemd/system-sleep/kwin-display-fix.sh
sudo mkdir -p /usr/local/bin
sudo cp system/kde-display-sleep.sh /usr/local/bin/kde-display-sleep.sh
sudo chmod 755 /usr/local/bin/kde-display-sleep.sh
sudo cp system/kde-display-sleep.service /etc/systemd/system/kde-display-sleep.service
sudo restorecon /usr/local/bin/kde-display-sleep.sh /etc/systemd/system/kde-display-sleep.service
sudo cp system/usb-autosuspend.service /etc/systemd/system/usb-autosuspend.service
sudo systemctl daemon-reload
sudo systemctl enable kde-display-sleep.service
sudo systemctl enable --now usb-autosuspend.service
ok "USB sleep hook, KDE display sleep service and USB autosuspend service"

section "DNS hardening"
sudo mkdir -p /etc/systemd/resolved.conf.d
# a restart drops the per-link DNS a VPN or Tailscale set, so only restart on change
if ! cmp -s system/resolved-hardening.conf /etc/systemd/resolved.conf.d/hardening.conf; then
    sudo cp system/resolved-hardening.conf /etc/systemd/resolved.conf.d/hardening.conf
    sudo systemctl restart systemd-resolved
fi
ok "resolved-hardening.conf (Quad9 fallback, opportunistic DNSSEC/DoT)"

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
ok "journal capped at 1G"

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
retire system/70-ntsync.rules /etc/udev/rules.d/99-ntsync.rules
sudo cp system/70-ntsync.rules /etc/udev/rules.d/70-ntsync.rules
sudo udevadm control --reload-rules
sudo modprobe ntsync 2>/dev/null || true
sudo udevadm trigger --subsystem-match=misc --sysname-match=ntsync
ok "70-ntsync.rules, ntsync.conf"

section "Disk quota fix (tmpfs)"
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo cp system/tmp-mount-override.conf /etc/systemd/system/tmp.mount.d/override.conf
sudo mkdir -p /etc/systemd/system/user-runtime-dir@.service.d
sudo cp system/user-runtime-dir-noquota.conf /etc/systemd/system/user-runtime-dir@.service.d/noquota.conf
sudo systemctl daemon-reload
# drop-in clears /dev/shm limit at each login; clear the current session now too
sudo setquota -u "${SUDO_UID:-$(id -u)}" 0 0 0 0 /dev/shm 2>/dev/null || true
ok "usrquota dropped on /tmp (reboot); /dev/shm per-user limit cleared at each login"

section "gamescope capabilities"
sudo mkdir -p /etc/dnf/libdnf5-plugins/actions.d
sudo cp system/gamescope-caps.actions /etc/dnf/libdnf5-plugins/actions.d/gamescope-caps.actions
ok "CAP_SYS_NICE re-applied after every gamescope update (needs libdnf5-plugin-actions)"

section "Done"
ok "All system files deployed. Reboot recommended if modprobe/zram configs changed."
