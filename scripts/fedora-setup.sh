#!/bin/bash
# Fedora 44 KDE post-install setup. Detects the hardware (scripts/lib/hw.sh) and
# adapts to it: GPU drivers for NVIDIA, AMD or Intel, desktop or laptop tuning,
# dual-boot handling. Overrides go in setup.conf (see setup.conf.example).
# Run as regular user — sudo is called where needed

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

ok()   { echo -e "  ${TEAL}✓${RESET} $1"; }
info() { echo -e "  ${TEAL}→${RESET} $1"; }
warn() { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

section "Hardware"
NVIDIA_BRANCH=$(hw_nvidia_driver)
ok "$(hw_summary)"

section "DNF configuration"
sudo cp system/dnf.conf /etc/dnf/dnf.conf
ok "DNF configured (max 2 kernels, parallel downloads)"

section "Locale debloat"
# keep a langpack for every locale in use (a regional LC_* locale too), not only English
langs=$(locale | sed -n 's/^[A-Z_]*="\{0,1\}\([a-z]\{2,3\}\)_.*/\1/p' | sort -u)
if rpm -q glibc-all-langpacks &>/dev/null; then
    sudo dnf swap -y glibc-all-langpacks glibc-langpack-en
fi
for l in $langs; do
    sudo dnf install -y "glibc-langpack-$l"
done
sudo cp system/macros.image-language-conf /etc/rpm/macros.image-language-conf
ok "langpacks: $(echo "$langs" | xargs); new packages install English translations only"

section "RPM Fusion"
sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
sudo dnf group upgrade -y core
ok "RPM Fusion free + nonfree installed"

section "Third-party repos"
sudo dnf copr enable -y bieszczaders/kernel-cachyos-addons  # scx-scheds
sudo dnf copr enable -y lihaohong/yazi
sudo dnf copr enable -y jdxcode/mise
# dnf does not expand $releasever inside --setopt values, so the shell fills in the release
sudo dnf install -y \
    --repofrompath "terra,https://repos.fyralabs.com/terra$(rpm -E %fedora)" \
    --setopt="terra.gpgkey=https://repos.fyralabs.com/terra$(rpm -E %fedora)/key.asc" \
    terra-release
# Terra also ships steam, scx-scheds, lact and more; take only starship and ES-DE from it
sudo dnf config-manager setopt 'terra.includepkgs=terra-release,terra-gpg-keys,starship,emulationstation-de*'
ok "COPR: scx-scheds, yazi, mise; Terra: starship, ES-DE"

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
# Fedora's Mesa and Intel VA-API drivers leave out the patented codecs; libva
# loads RPM Fusion's builds (dri-freeworld, dri-nonfree) ahead of Fedora's
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

# Pinned upstream releases, checked against these hashes before anything is installed
dl=$(mktemp -d)
fetch() {  # url sha256 file
    curl -fsSL "$1" -o "$3"
    echo "$2  $3" | sha256sum -c --quiet -
}

if ! command -v lazygit &>/dev/null; then
    fetch https://github.com/jesseduffield/lazygit/releases/download/v0.65.1/lazygit_0.65.1_linux_x86_64.tar.gz \
        02beacbcda0fa342e50ae3480ba8147307353af3fb28e1d5f790e02329c201a6 "$dl/lazygit.tar.gz"
    tar -xzf "$dl/lazygit.tar.gz" -C "$dl" lazygit
    sudo install -m755 "$dl/lazygit" /usr/local/bin/lazygit
fi
ok "lazygit $(lazygit --version | grep -oP 'version=\K[^,]+')"

# ble.sh — bash syntax highlighting; .gitmodules uses a relative URL, so origin must exist
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

# JetBrainsMono Nerd Font
mkdir -p ~/.local/share/fonts/JetBrainsMono
fetch https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz \
    04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf "$dl/JetBrainsMono.tar.xz"
tar -xf "$dl/JetBrainsMono.tar.xz" -C ~/.local/share/fonts/JetBrainsMono/
fc-cache -fv -q
ok "JetBrainsMono Nerd Font installed"
rm -rf "$dl"

section "Flatpak (gaming)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# the spin ships Fedora's own OCI remote too; everything here comes from Flathub, and the
# extra remote only slows every Discover refresh
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

section "System configs (scripts/apply-system.sh)"
bash scripts/apply-system.sh
ok "System files deployed via apply-system.sh"

section "SCX scheduler (gaming)"
sudo systemctl enable --now scx_loader.service
# sched_ext schedulers fail to load on kernels whose BTF came from pahole <= 1.30
# (Fedora 7.1.x-7.2.6, fixed in 7.2.7); check CONFIG_PAHOLE_VERSION in /boot/config-*.
if [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" == "enabled" ]]; then
    ok "sched_ext scheduler attached"
else
    warn "scx_loader enabled but no scheduler attached — see journalctl -u scx_loader"
fi

section "Gamescope capabilities"
sudo setcap cap_sys_nice+ep "$(command -v gamescope)"
ok "Gamescope granted CAP_SYS_NICE (--rt works)"

section "Firewall hardening"
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=mdns 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=ssh 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=samba-client 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-port=1025-65535/udp 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-port=1025-65535/tcp 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --remove-service=kdeconnect 2>/dev/null || true
sudo firewall-cmd --permanent --zone=FedoraWorkstation --add-service=dhcpv6-client
sudo firewall-cmd --reload
ok "Firewall hardened (dhcpv6-client only; ssh, samba-client, mdns, kdeconnect removed)"

section "Clock and boot menu"
sudo timedatectl set-local-rtc 0
if hw_has_windows; then
    # GRUB re-picks the last-booted OS after a Windows hibernate wake; GRUB_SAVEDEFAULT requires GRUB_DEFAULT=saved
    grub_changed=0
    if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
        if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
            sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        else
            echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
        fi
        grub_changed=1
    fi
    if ! grep -q '^GRUB_SAVEDEFAULT=true' /etc/default/grub; then
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
# gssproxy is masked because auth-rpcgss-module.service pulls a disabled unit back in;
# kde-connect is removed because masking it makes plasmashell block on D-Bus activation.
sudo systemctl disable --now cups.service cups.socket cups.path 2>/dev/null || true
sudo systemctl mask --now gssproxy.service 2>/dev/null || true
sudo dnf mark user fuse-sshfs openssh-askpass 2>/dev/null || true
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
# zoom (Meta+=) and shake-to-find cursor both fire by accident
kwriteconfig6 --file kwinrc --group Plugins --key zoomEnabled false
kwriteconfig6 --file kwinrc --group Plugins --key shakecursorEnabled false
# Meta alone opens the launcher — games that use Meta as a modifier trigger it
kwriteconfig6 --file kwinrc --group ModifierOnlyShortcuts --key Meta ""
kwriteconfig6 --file klaunchrc --group BusyCursorSettings --key Bouncing false
kwriteconfig6 --file ksplashrc --group KSplash --key Engine none
kwriteconfig6 --file ksplashrc --group KSplash --key Theme None
# start each login clean instead of reopening the last session
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

section "Snapper (BTRFS snapshots)"
if [ "$(findmnt -no FSTYPE /)" = btrfs ]; then
    sudo dnf install -y snapper btrfs-assistant
    # guards need sudo — a plain user can't see root's snapper configs
    if ! sudo snapper list-configs | grep -q "^root"; then
        sudo snapper -c root create-config / || warn "root config not created (subvolume already covered?)"
    fi
    if ! sudo snapper list-configs | grep -q "^home"; then
        sudo snapper -c home create-config /home || warn "home config not created (subvolume already covered?)"
    fi
    if ! sudo snapper -c root list 2>/dev/null | grep -q "Initial clean setup"; then
        sudo snapper -c root create --description "Initial clean setup" --cleanup-algorithm number || warn "root snapshot failed"
    fi
    if ! sudo snapper -c home list 2>/dev/null | grep -q "Initial home snapshot"; then
        sudo snapper -c home create --description "Initial home snapshot" --cleanup-algorithm number || warn "home snapshot failed"
    fi
    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
    ok "Snapper: root + home snapshots, timeline enabled"
else
    warn "root filesystem is not btrfs — Snapper skipped"
fi

section "Audio (WirePlumber)"
audio_conf=~/.config/wireplumber/wireplumber.conf.d/50-audio.conf
# opt-in, but an install that already has the file keeps getting updates
if [ "${AUDIO_TRIM:-no}" = yes ] || [ -f "$audio_conf" ]; then
    mkdir -p "$(dirname "$audio_conf")"
    cp configs/wireplumber/wireplumber.conf.d/50-audio.conf "$audio_conf"
    systemctl --user restart wireplumber
    ok "WirePlumber: onboard, iGPU HDMI and webcam audio disabled"
else
    ok "left at defaults (AUDIO_TRIM=yes in setup.conf hides onboard AMD audio, AMD iGPU HDMI and webcam mics)"
fi

section "Writing user configs"
mkdir -p ~/.config/kitty ~/.config/conky \
         ~/.config/Kvantum ~/.local/share/color-schemes \
         ~/scripts ~/Pictures ~/.config/fish/functions \
         ~/.local/share/plasma/desktoptheme \
         ~/.config/systemd/user ~/.config/fastfetch

cp configs/kitty/kitty.conf ~/.config/kitty/kitty.conf
cp configs/fastfetch/config.jsonc ~/.config/fastfetch/config.jsonc
cp configs/starship/starship.toml ~/.config/starship.toml
cp configs/conky/conky.conf ~/.config/conky/conky.conf
cp configs/kde/DarthVader.colors ~/.local/share/color-schemes/DarthVader.colors
cp configs/kde/kvantum/kvantum.kvconfig ~/.config/Kvantum/kvantum.kvconfig
cp -rT configs/kde/plasma-theme ~/.local/share/plasma/desktoptheme/darth-vader
cp configs/fish/config.fish ~/.config/fish/config.fish
cp configs/fish/functions/ya.fish ~/.config/fish/functions/ya.fish
cp wallpaper/wallpaper.jpg ~/Pictures/wallpaper.jpg
ok "User configs written"

cp scripts/rice-start.sh scripts/sysinfo.sh scripts/hwstat.sh scripts/deep-health.sh scripts/mok-reenroll.sh ~/scripts/
chmod +x ~/scripts/{rice-start,sysinfo,hwstat,deep-health,mok-reenroll}.sh
ok "Scripts installed to ~/scripts/"

# ble.sh requires --noattach first and ble-attach last; configs/bashrc goes in between
if ! grep -q 'blesh/ble.sh' ~/.bashrc; then
    sed -i '1s|^|[[ $- == *i* ]] \&\& source ~/.local/share/blesh/ble.sh --noattach\n\n|' ~/.bashrc
    ok "$HOME/.bashrc: ble.sh --noattach added at top"
fi
if ! grep -q 'zoxide init' ~/.bashrc; then
    # the ble-attach line must land in .bashrc unexpanded
    # shellcheck disable=SC2016
    { echo ""; cat configs/bashrc; echo ""; echo '[[ ${BLE_VERSION-} ]] && ble-attach'; } >> ~/.bashrc
    ok "$HOME/.bashrc: configs/bashrc appended, ble-attach added last"
fi

cp configs/systemd/conky.service ~/.config/systemd/user/conky.service
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
next "KDE Settings → Colors → DarthVader → Apply"
next "KDE Settings → Application Style → kvantum → Apply"
next "KDE Settings → Fonts → Fixed width → JetBrainsMono Nerd Font"
next "KDE Settings → Wallpaper → ~/Pictures/wallpaper.jpg"
echo ""
info "Conky runs as a systemd user service (systemctl --user status conky)"
info "For retro emulation (ES-DE + PS1/PS2/PS3/Wii): bash scripts/emulation-setup.sh"
ok "Reboot recommended."
