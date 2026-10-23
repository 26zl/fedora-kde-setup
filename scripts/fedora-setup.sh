#!/bin/bash
# Fedora 44 KDE post-install setup for x86_64; hardware overrides go in setup.conf.
# Run as a regular user; sudo is called where needed after one confirmation.
# --yes skips confirmation and is required without a terminal; --help shows usage.

YES=0
[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1-} in
    "") ;;
    --yes) YES=1 ;;
    -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

set -e
[ "$EUID" -ne 0 ] || {
    echo "run as a normal user, not root" >&2
    exit 1
}
[ -f /etc/fedora-release ] || { echo "this setup targets Fedora KDE; no /etc/fedora-release here" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "this setup requires x86_64" >&2; exit 1; }
[ "$(rpm -E %fedora)" = 44 ] || { echo "this setup targets Fedora 44 KDE" >&2; exit 1; }
command -v kwriteconfig6 >/dev/null || { echo "this setup requires KDE Plasma 6" >&2; exit 1; }
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh
# shellcheck source=scripts/lib/restore.sh
source scripts/lib/restore.sh
# shellcheck disable=SC1091
[ -f setup.conf ] && source ./setup.conf
hw_check_conf

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()   { echo -e "  ${TEAL}✓${RESET} $1"; }
info() { echo -e "  ${TEAL}→${RESET} $1"; }
warn() { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }
confirm() {
    [ "$YES" -eq 1 ] && return 0
    [ -t 0 ] || { echo "  not a terminal: pass --yes to run without the confirmation" >&2; exit 1; }
    local reply
    read -rp "  Continue? [y/N] " reply
    [[ $reply == [yY]* ]] || { echo "  stopped, nothing changed"; exit 1; }
}

# Preserve differing user files as numbered backups, including files in theme directories.
install_config() {  # src dest
    mkdir -p "$(dirname "$2")"
    if [ -d "$1" ]; then
        local entry
        mkdir -p "$2"
        for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            install_config "$entry" "$2/${entry##*/}"
        done
    elif [ ! -e "$2" ]; then
        cp "$1" "$2"
    elif ! cmp -s "$1" "$2"; then
        cp --backup=numbered "$1" "$2"
    fi
}

section "Hardware"
NVIDIA_BRANCH=$(hw_nvidia_driver)
ok "$(hw_summary)"

section "Plan"
echo "  This run will, with sudo where needed:"
echo "   - first save read-only Btrfs root/home snapshots and verified boot/EFI archives"
echo "     (requires the default same-filesystem Btrfs layout; close apps and other package managers first)"
echo "   - add RPM Fusion, three scoped COPRs and Terra, and install the gaming, terminal and Flatpak tools"
[ -n "$NVIDIA_BRANCH" ] && echo "   - install the NVIDIA driver ($NVIDIA_BRANCH branch)"
echo "   - set up snapper snapshots on a btrfs root, then deploy the system/ files through apply-system.sh"
echo "     (kernel arguments, sysctl, modprobe, udev, systemd units and drop-ins)"
echo "   - trim default firewall services and ports (ssh included), remove kde-connect, disable cups, abrt and gssproxy, enable auditd"
echo "   - set the RTC to UTC$(hw_has_windows && echo ' and make GRUB remember the last-booted OS')"
echo "   - write the KDE, kitty, fish, starship and conky configs (existing files kept as numbered backups) and edit ~/.bashrc"
confirm

section "Pre-setup restore point"
if create_setup_restore_point; then
    ok "Recovery files: $SETUP_RESTORE_DIR (reused by later runs; scripts/disk-cleanup.sh removes them; see RECOVERY.txt)"
else
    # the snapshot path needs the default btrfs layout; other layouts get a choice, not a silent skip
    warn "no pre-setup restore point on this layout; keep a verified offline backup before continuing"
    [ "$YES" -eq 0 ] || { warn "stopped: run without --yes to continue without a restore point"; exit 1; }
    read -rp "  Continue without a restore point? [y/N] " reply
    [[ $reply == [yY]* ]] || { echo "  stopped, nothing changed"; exit 1; }
fi

section "DNF configuration"
sudo cp system/dnf.conf /etc/dnf/dnf.conf
ok "DNF configured (max 2 kernels, parallel downloads)"

section "Firmware (fwupd)"
sudo dnf install -y fwupd
# A BIOS flash can clear the MOK list, so leave firmware updates until after enrollment.
sudo timeout 120 fwupdmgr refresh --force >/dev/null </dev/null || warn "fwupd metadata refresh failed (offline?)"
fw_updates=0 rc=0
fwupdmgr get-updates --no-unreported-check --no-metadata-check --no-remote-check </dev/null || rc=$?
# fwupdmgr exits 2 when there is nothing to do, 1 on a real failure
case $rc in
    0) fw_updates=1 ;;
    2) ok "no firmware updates" ;;
    *) warn "could not check for firmware updates (fwupdmgr exit $rc)" ;;
esac

section "Locale debloat"
install_langs=$(hw_install_langs)
langs=$(tr ':' '\n' <<<"$install_langs" | sed 's/_.*//' | sort -u)
if rpm -q glibc-all-langpacks &>/dev/null; then
    sudo dnf swap -y glibc-all-langpacks glibc-langpack-en
fi
for l in $langs; do
    sudo dnf install -y "glibc-langpack-$l"
done
# Keep the configured translations during later DNF operations.
printf '%%_install_langs %s\n' "$install_langs" | sudo tee /etc/rpm/macros.image-language-conf >/dev/null
ok "langpacks: $(echo "$langs" | xargs); install_langs: $install_langs"

section "RPM Fusion"
# Use RPM Fusion's own host because URL installs have no mirror fallback.
sudo dnf install -y \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
sudo dnf group upgrade -y core
ok "RPM Fusion free + nonfree installed"

section "Third-party repos"
# Restrict COPRs so later upgrades cannot replace unrelated Fedora packages.
sudo dnf copr enable -y bieszczaders/kernel-cachyos-addons
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons.includepkgs=scx-scheds,scx-tools'
sudo dnf copr enable -y lihaohong/yazi
# resvg: yazi's SVG previews; no other enabled repo ships it
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:lihaohong:yazi.includepkgs=yazi,resvg'
sudo dnf copr enable -y jdxcode/mise
sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:jdxcode:mise.includepkgs=mise'
# dnf does not expand $releasever inside --setopt values, so the shell fills in the release
sudo dnf install -y \
    --repofrompath "terra,https://repos.fyralabs.com/terra$(rpm -E %fedora)" \
    --setopt="terra.gpgkey=https://repos.fyralabs.com/terra$(rpm -E %fedora)/key.asc" \
    terra-release
# Terra also ships steam, scx-scheds, lact and more; take only starship and ES-DE from it
sudo dnf config-manager setopt 'terra.includepkgs=terra-release,terra-gpg-keys,starship,emulationstation-de*'
ok "COPR (scoped): scx-scheds, yazi, mise; Terra: starship, ES-DE"

section "GPU drivers"
case "$NVIDIA_BRANCH" in
    current)
        sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver
        ok "NVIDIA akmod drivers installed (current branch)"
        ;;
    580xx)
        sudo dnf install -y akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda libva-nvidia-driver
        ok "NVIDIA akmod drivers installed (580xx branch for Maxwell, Pascal and Volta)"
        ;;
esac
if [ -z "$NVIDIA_BRANCH" ] && [ "$(hw_nvidia_branch)" = none ]; then
    warn "NVIDIA GPU older than Maxwell: no packaged driver supports it, staying on nouveau"
fi
# RPM Fusion's VA-API builds include codecs omitted from Fedora's builds.
if hw_has_gpu 1002; then
    sudo dnf install -y mesa-va-drivers-freeworld
    ok "AMD: VA-API with H.264/H.265 (mesa-va-drivers-freeworld)"
fi
if hw_has_gpu 8086; then
    sudo dnf install -y intel-media-driver
    ok "Intel: VA-API with H.264/H.265 (intel-media-driver)"
fi

section "System tools"
sudo dnf install -y \
    steam \
    gamemode \
    mangohud \
    gamescope \
    libdnf5-plugin-actions \
    htop \
    btop \
    wl-clipboard \
    kvantum \
    conky \
    jq \
    pciutils \
    libva-utils \
    tuned \
    tuned-ppd \
    scx-scheds \
    zram-generator \
    lm_sensors
ok "System tools installed"

section "Terminal tools"
sudo dnf install -y \
    kitty \
    fish \
    zoxide \
    fzf \
    ripgrep \
    fd-find \
    bat \
    eza \
    fastfetch \
    git-delta \
    starship \
    yazi \
    mise

# fish runs inside kitty (not as login shell — keeps KDE session stable)
ok "fish installed (used as kitty shell, not login shell)"

dl=$(mktemp -d)
trap 'rm -rf "$dl"' EXIT
fetch() {  # url sha256 file
    curl -fsSL --connect-timeout 20 --retry 3 "$1" -o "$3"
    echo "$2  $3" | sha256sum -c --quiet -
}

if ! command -v lazygit &>/dev/null; then
    fetch https://github.com/jesseduffield/lazygit/releases/download/v0.66.2/lazygit_0.66.2_linux_x86_64.tar.gz \
        158efc9ddfa1241fab5fb3526bb442c8dc6c4b1904d73213b9e4e93e03c52034 "$dl/lazygit.tar.gz"
    tar -xzf "$dl/lazygit.tar.gz" -C "$dl" lazygit
    sudo install -m755 "$dl/lazygit" /usr/local/bin/lazygit
fi
ok "lazygit $(lazygit --version | grep -oP 'version=\K[^,]+')"

# ble.sh needs make and an origin remote for its relative submodule URL.
sudo dnf install -y git make
if [[ ! -f ~/.local/share/blesh/ble.sh ]]; then
    git init -q "$dl/ble.sh"
    git -C "$dl/ble.sh" remote add origin https://github.com/akinomyoga/ble.sh.git
    git -C "$dl/ble.sh" fetch -q --depth 1 origin d81fd54feb0d996fdff20dca27eaf0201f7015cc
    git -C "$dl/ble.sh" checkout -q FETCH_HEAD
    git -C "$dl/ble.sh" submodule update -q --init --recursive --depth 1
    make -C "$dl/ble.sh" install PREFIX=~/.local
    ok "ble.sh installed"
else
    ok "ble.sh already installed"
fi

mkdir -p ~/.local/share/fonts/JetBrainsMono
fetch https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz \
    04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf "$dl/JetBrainsMono.tar.xz"
tar -xf "$dl/JetBrainsMono.tar.xz" -C ~/.local/share/fonts/JetBrainsMono/
fc-cache -fv -q
ok "JetBrainsMono Nerd Font installed"

section "Flatpak (gaming)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# Remove Fedora's unused remote only when no installed apps depend on it.
if flatpak remotes --columns=name | grep -qx fedora && ! flatpak list --columns=origin | grep -qx fedora; then
    sudo flatpak remote-delete --system fedora
fi
flatpak install -y flathub \
    net.davidotek.pupgui2 \
    com.heroicgameslauncher.hgl \
    net.lutris.Lutris \
    com.usebottles.bottles \
    org.prismlauncher.PrismLauncher \
    io.github.benjamimgois.goverlay \
    com.github.wwmm.easyeffects
ok "ProtonUp-Qt, Heroic, Lutris, Bottles, Prism, GOverlay, EasyEffects installed"

section "tuned"
sudo systemctl enable --now tuned
# tuned-ppd applies system/tuned-ppd.conf: balanced by default, latency-performance behind the Performance mode
sudo systemctl enable --now tuned-ppd
ok "tuned + tuned-ppd enabled (profile is set by apply-system.sh)"

section "Snapper (BTRFS snapshots)"
# Create Snapper configs before apply-system.sh attempts its restore point.
if [ "$(findmnt -no FSTYPE /)" = btrfs ]; then
    sudo dnf install -y snapper btrfs-assistant
    # guards need sudo — a plain user can't see root's snapper configs
    if ! sudo snapper list-configs | grep -q "^root"; then
        sudo snapper -c root create-config / || warn "root config not created (subvolume already covered?)"
    fi
    if ! sudo snapper list-configs | grep -q "^home"; then
        sudo snapper -c home create-config /home || warn "home config not created (subvolume already covered?)"
    fi
    # Frequent /home snapshots can retain large deleted files, so only / gets a timeline.
    sudo snapper -c home set-config TIMELINE_CREATE=no || warn "home timeline not disabled"
    # Disabling timeline creation does not remove snapshots retained by the cleanup limits.
    sudo snapper -c root set-config TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 \
        TIMELINE_LIMIT_MONTHLY=1 TIMELINE_LIMIT_YEARLY=0 || warn "root timeline limits not set"
    sudo snapper -c home set-config TIMELINE_LIMIT_HOURLY=0 TIMELINE_LIMIT_DAILY=0 TIMELINE_LIMIT_WEEKLY=0 \
        TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 || warn "home timeline limits not set"
    # Number cleanup needs qgroups to measure the space retained by snapshots.
    sudo snapper -c root setup-quota || warn "root quota not set up"
    sudo snapper -c home setup-quota || warn "home quota not set up"
    if ! sudo snapper -c root list 2>/dev/null | grep -q "Initial clean setup"; then
        sudo snapper -c root create --description "Initial clean setup" --cleanup-algorithm number || warn "root snapshot failed"
    fi
    if ! sudo snapper -c home list 2>/dev/null | grep -q "Initial home snapshot"; then
        sudo snapper -c home create --description "Initial home snapshot" --cleanup-algorithm number || warn "home snapshot failed"
    fi
    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
    ok "Snapper: root + home snapshots, / timeline (5 hourly, 7 daily, 2 weekly, 1 monthly) + quota, /home timeline off"
else
    warn "root filesystem is not btrfs — Snapper skipped"
fi

section "System configs (scripts/apply-system.sh)"
bash scripts/apply-system.sh --yes
ok "System files deployed via apply-system.sh"

section "SCX scheduler (gaming)"
sudo systemctl enable --now scx_loader.service
# The scheduler attaches asynchronously and may fail on kernels with incompatible BTF.
for _ in $(seq 10); do
    [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" == "enabled" ]] && break
    sleep 1
done
if [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" == "enabled" ]]; then
    ok "sched_ext scheduler attached"
else
    warn "scx_loader enabled but no scheduler attached — see journalctl -u scx_loader"
fi

section "Gamescope capabilities"
sudo setcap cap_sys_nice+ep "$(command -v gamescope)"
ok "Gamescope granted CAP_SYS_NICE (--rt works)"

section "Firewall hardening"
# no --zone: the default zone is FedoraWorkstation on the KDE Edition, public on an Everything ISO install
sudo firewall-cmd --permanent --remove-service=mdns 2>/dev/null || true
sudo firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
sudo firewall-cmd --permanent --remove-service=samba-client 2>/dev/null || true
sudo firewall-cmd --permanent --remove-port=1025-65535/udp 2>/dev/null || true
sudo firewall-cmd --permanent --remove-port=1025-65535/tcp 2>/dev/null || true
sudo firewall-cmd --permanent --remove-service=kdeconnect 2>/dev/null || true
sudo firewall-cmd --permanent --add-service=dhcpv6-client
sudo firewall-cmd --reload
ok "Default firewall zone trimmed; review custom services and ports with firewall-cmd --list-all"

section "Clock and boot menu"
sudo timedatectl set-local-rtc 0
if hw_has_windows; then
    # GRUB re-picks the last-booted OS after a Windows hibernate wake; GRUB_SAVEDEFAULT requires GRUB_DEFAULT=saved
    grub_changed=0
    if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
        sudo cp -n /etc/default/grub /etc/default/grub.orig  # the untouched file, kept once
        if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
            sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        else
            echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
        fi
        grub_changed=1
    fi
    if ! grep -q '^GRUB_SAVEDEFAULT=true' /etc/default/grub; then
        sudo cp -n /etc/default/grub /etc/default/grub.orig
        echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub >/dev/null
        grub_changed=1
    fi
    if [[ $grub_changed -eq 1 ]]; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
    ok "RTC set to UTC (Windows must use UTC too); GRUB remembers last-booted OS"
else
    ok "RTC set to UTC; no Windows boot entry, GRUB default left alone"
fi

section "Disable ABRT crash reporters"
sudo systemctl disable --now abrtd abrt-oops abrt-xorg abrt-journal-core 2>/dev/null || true
ok "ABRT disabled (reduces background CPU/RAM usage)"

section "Disable unused listening services"
# auth-rpcgss-module.service can reactivate gssproxy unless it is masked.
sudo systemctl disable --now cups.service cups.socket cups.path 2>/dev/null || true
sudo systemctl mask --now gssproxy.service 2>/dev/null || true
sudo dnf mark user fuse-sshfs openssh-askpass 2>/dev/null || true
# Masking KDE Connect can block plasmashell on D-Bus activation.
sudo dnf remove -y kde-connect 2>/dev/null || true
ok "cups, gssproxy, KDE Connect removed"

section "auditd"
# the kernel cmdline sets audit=1 — without the daemon nothing collects the events
sudo systemctl enable --now auditd
ok "auditd collecting audit events"

section "KWin latency"
kwriteconfig6 --file kwinrc --group Compositing --key LatencyPolicy ExtremelyLow
kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled true
# KWin's gamepad->keyboard desktop navigation hijacks controllers in games/emulators
kwriteconfig6 --file kwinrc --group Plugins --key gamecontrollerEnabled false
ok "KWin: ExtremelyLow latency, blur enabled, gamepad-nav disabled"

section "KDE annoyances"
kwriteconfig6 --file kwinrc --group Plugins --key zoomEnabled false
kwriteconfig6 --file kwinrc --group Plugins --key shakecursorEnabled false
# Meta alone opens the launcher — games that use Meta as a modifier trigger it
kwriteconfig6 --file kwinrc --group ModifierOnlyShortcuts --key Meta ""
kwriteconfig6 --file klaunchrc --group BusyCursorSettings --key Bouncing false
kwriteconfig6 --file ksplashrc --group KSplash --key Engine none
kwriteconfig6 --file ksplashrc --group KSplash --key Theme None
kwriteconfig6 --file ksmserverrc --group General --key loginMode emptySession
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0.5
# Baloo indexes all of $HOME in the background; no file-content search used here
kwriteconfig6 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false
ok "KDE: zoom/shake/Meta-launcher/bounce/splash off, clean login, 0.5x animations, Baloo off"

section "Lock screen wallpaper"
kwriteconfig6 --file kscreenlockerrc \
  --group "Greeter" --group "Wallpaper" --group "org.kde.image" --group "General" \
  --key "Image" "file://${HOME}/Pictures/wallpaper.jpg"
ok "Lock screen wallpaper set"

section "Audio (WirePlumber)"
audio_conf=~/.config/wireplumber/wireplumber.conf.d/50-audio.conf
# opt-in, but an install that already has the file keeps getting updates
if [ "${AUDIO_TRIM:-no}" = yes ] || [ -f "$audio_conf" ]; then
    install_config configs/wireplumber/wireplumber.conf.d/50-audio.conf "$audio_conf"
    systemctl --user restart wireplumber
    ok "WirePlumber: onboard, iGPU HDMI and webcam audio disabled"
else
    ok "left at defaults (AUDIO_TRIM=yes in setup.conf hides onboard AMD audio, AMD iGPU HDMI and webcam mics)"
fi

section "Writing user configs"
mkdir -p ~/scripts ~/.config/systemd/user

install_config configs/kitty/kitty.conf ~/.config/kitty/kitty.conf
install_config configs/fastfetch/config.jsonc ~/.config/fastfetch/config.jsonc
install_config configs/starship/starship.toml ~/.config/starship.toml
install_config configs/conky/conky.conf ~/.config/conky/conky.conf
install_config configs/kde/DarthVader.colors ~/.local/share/color-schemes/DarthVader.colors
install_config configs/kde/kvantum/kvantum.kvconfig ~/.config/Kvantum/kvantum.kvconfig
install_config configs/kde/plasma-theme ~/.local/share/plasma/desktoptheme/darth-vader
install_config configs/fish/config.fish ~/.config/fish/config.fish
install_config configs/fish/functions/ya.fish ~/.config/fish/functions/ya.fish
install_config wallpaper/wallpaper.jpg ~/Pictures/wallpaper.jpg
ok "User configs written (existing files that differ kept as numbered backups)"

for script in rice-start sysinfo hwstat deep-health mok-reenroll disk-cleanup; do
    install_config "scripts/$script.sh" "$HOME/scripts/$script.sh"
done
chmod +x ~/scripts/{rice-start,sysinfo,hwstat,deep-health,mok-reenroll,disk-cleanup}.sh
ok "Scripts installed to ~/scripts/"

# ble.sh requires --noattach before other shell setup and ble-attach after it.
# sed cannot prepend to a missing or empty file, so make sure it has a first line
[ -s ~/.bashrc ] || echo '# ~/.bashrc' >>~/.bashrc
if ! grep -q 'blesh/ble.sh' ~/.bashrc; then
    [ -e ~/.bashrc.orig ] || cp ~/.bashrc ~/.bashrc.orig
    sed -i '1s|^|# >>> fedora-kde-setup: ble.sh must load before anything else >>>\n[[ $- == *i* ]] \&\& source ~/.local/share/blesh/ble.sh --noattach\n# <<< fedora-kde-setup <<<\n\n|' ~/.bashrc
    ok "$HOME/.bashrc: ble.sh --noattach added at top"
fi
if ! grep -q 'zoxide init' ~/.bashrc; then
    [ -e ~/.bashrc.orig ] || cp ~/.bashrc ~/.bashrc.orig
    # the ble-attach line must land in .bashrc unexpanded
    # shellcheck disable=SC2016
    { echo ""; echo "# >>> fedora-kde-setup: configs/bashrc >>>"; cat configs/bashrc; echo ""; echo '[[ ${BLE_VERSION-} ]] && ble-attach'; echo "# <<< fedora-kde-setup <<<"; } >> ~/.bashrc
    ok "$HOME/.bashrc: configs/bashrc appended, ble-attach added last"
fi

install_config configs/systemd/conky.service ~/.config/systemd/user/conky.service
systemctl --user daemon-reload
systemctl --user enable --now conky.service
ok "Conky systemd user service installed and enabled"

section "Setup complete"
step=0
next() { step=$((step + 1)); echo "  $step. $1"; }
if [ -n "$NVIDIA_BRANCH" ]; then
    warn "Before rebooting (NVIDIA):"
    next "Wait ~5 min for the NVIDIA kernel module to build, then:"
    echo "       sudo akmods --force && sudo dracut --force"
    if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
        next "Queue the MOK key: sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
        echo "     → reboot and pick 'Enroll MOK' at the blue MOK Manager screen"
    fi
    echo ""
fi
warn "After reboot:"
if [ "$fw_updates" = 1 ]; then
    next "Firmware updates are available: sudo fwupdmgr update"
    echo "     → after a UEFI/BIOS update with Secure Boot on: sudo ~/scripts/mok-reenroll.sh"
fi
next "KDE Settings → Colors → DarthVader → Apply"
next "KDE Settings → Application Style → kvantum → Apply"
next "KDE Settings → Fonts → Fixed width → JetBrainsMono Nerd Font"
next "KDE Settings → Wallpaper → ~/Pictures/wallpaper.jpg"
echo ""
info "Conky runs as a systemd user service (systemctl --user status conky)"
info "For retro emulation (ES-DE + PS1/PS2/PS3/Wii): bash scripts/emulation-setup.sh"
info "For a local LLM (Strata, ~85 GB download): bash scripts/strata-setup.sh"
info "For a local LLM via Ollama + Alpaca GUI (~9 GB download): sudo bash scripts/ollama-setup.sh"
info "After the reboot, check the result: bash scripts/verify-setup.sh"
ok "Reboot recommended."
