#!/bin/bash
# Retro emulation: ES-DE frontend + standalone emulators (PS1/PS2/PS3, GameCube/Wii)

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e
[ "$EUID" -ne 0 ] || { echo "Run without sudo: bash scripts/emulation-setup.sh" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "This setup requires x86_64" >&2; exit 1; }
cd "$(dirname "$0")/.."

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

# interactive runs also leave these lines in the journal: journalctl -t fedora-kde-setup
journal() { [ ! -t 1 ] || logger -t fedora-kde-setup -- "${0##*/}: $*" 2>/dev/null || true; }
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; journal "ok: $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; journal "warning: $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; journal "$1"; }

DUCKSTATION_VERSION=v0.1-12442
DUCKSTATION_REV=dd4a0eb779296a525f8b10b6d9a45911ad6d088f
DUCKSTATION_SHA256=4d5c3dcfd9937dc9e77b8fcd5f879b8ec0c69551d5ed13462592073608542fca
DUCKSTATION_LICENSE_SHA256=38762e3777f4ec00a6f769062a7c3f704fb78ce08303ecff88558da4c49cf9ea
# the release's package file on GitLab; its SHA-256 is the one GitLab's API lists for it
ES_DE_VERSION=3.5.0
ES_DE_URL=https://gitlab.com/es-de/emulationstation-de/-/package_files/357718352/download
ES_DE_SHA256=abc2999a12385f85775bd3f986fa891c76b69df3791f7c12e4c783cf3c3630f5

section "DuckStation (official AppImage)"
applications="$HOME/Applications"
mkdir -p "$applications"
download=$(mktemp -d "$applications/.duckstation.XXXXXX")
trap 'rm -rf "$download"' EXIT
curl -fsSL --connect-timeout 20 --max-time 300 --retry 3 \
    "https://github.com/stenzek/duckstation/releases/download/$DUCKSTATION_VERSION/DuckStation-x64.AppImage" \
    -o "$download/DuckStation-x64.AppImage"
printf '%s  %s\n' "$DUCKSTATION_SHA256" "$download/DuckStation-x64.AppImage" | sha256sum -c --quiet -
curl -fsSL --connect-timeout 20 --max-time 60 --retry 3 \
    "https://raw.githubusercontent.com/stenzek/duckstation/$DUCKSTATION_REV/LICENSE" \
    -o "$download/DuckStation-LICENSE.txt"
printf '%s  %s\n' "$DUCKSTATION_LICENSE_SHA256" "$download/DuckStation-LICENSE.txt" | sha256sum -c --quiet -
cat >"$download/DuckStation-SOURCE.txt" <<EOF
DuckStation by Connor McLaughlin and contributors
Version: $DUCKSTATION_VERSION
Source: https://github.com/stenzek/duckstation/tree/$DUCKSTATION_REV
Official download: https://www.duckstation.org/
License: Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International
License text: DuckStation-LICENSE.txt
The upstream AppImage is unmodified and retains its bundled third-party notices.
EOF
chmod 755 "$download/DuckStation-x64.AppImage"
chmod 644 "$download/DuckStation-LICENSE.txt" "$download/DuckStation-SOURCE.txt"
# Stage beside the destination so a failed download cannot replace the installed binary.
mv -fT "$download/DuckStation-LICENSE.txt" "$applications/DuckStation-LICENSE.txt"
mv -fT "$download/DuckStation-SOURCE.txt" "$applications/DuckStation-SOURCE.txt"
mv -fT "$download/DuckStation-x64.AppImage" "$applications/DuckStation-x64.AppImage"
ok "DuckStation $DUCKSTATION_VERSION: $applications/DuckStation-x64.AppImage"
if flatpak info org.duckstation.DuckStation >/dev/null 2>&1; then
    warn "The old DuckStation Flatpak is still installed; ES-DE now uses the official AppImage."
    warn "Its data is unchanged. Close both versions and copy ~/.var/app/org.duckstation.DuckStation/config/duckstation"
    warn "to ${XDG_DATA_HOME:-$HOME/.local/share}/duckstation only if the destination is absent; re-add game directories."
    warn "After checking saves: flatpak uninstall org.duckstation.DuckStation"
    warn "Keep its data when uninstalling; do not pass --delete-data."
fi

section "ES-DE (official AppImage)"
# es-de.org ships Linux builds only as AppImages; Terra's RPM lagged each new Fedora release
es_download=$(mktemp -d "$applications/.es-de.XXXXXX")
trap 'rm -rf "$download" "$es_download"' EXIT
curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 "$ES_DE_URL" \
    -o "$es_download/ES-DE_x64.AppImage"
printf '%s  %s\n' "$ES_DE_SHA256" "$es_download/ES-DE_x64.AppImage" | sha256sum -c --quiet -
chmod 755 "$es_download/ES-DE_x64.AppImage"
mv -fT "$es_download/ES-DE_x64.AppImage" "$applications/ES-DE_x64.AppImage"
menu="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$menu"
cat >"$es_download/es-de.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ES-DE
GenericName=Emulator frontend
Comment=Browse and play the games in ~/Emulation/roms
Exec="$applications/ES-DE_x64.AppImage"
Icon=applications-games
Terminal=false
Categories=Game;Emulator;
EOF
mv -fT "$es_download/es-de.desktop" "$menu/es-de.desktop"
ok "ES-DE $ES_DE_VERSION: $applications/ES-DE_x64.AppImage, in the menu under Games"

section "Emulators (Flatpak)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
    net.pcsx2.PCSX2 \
    net.rpcs3.RPCS3 \
    org.DolphinEmu.dolphin-emu \
    org.libretro.RetroArch
ok "PCSX2 (PS2), RPCS3 (PS3), Dolphin (GameCube/Wii), RetroArch (SNES/N64)"

section "Flatpak ROM access"
# ROMs on another disk: also grant that path (flatpak override --user --filesystem=<path> <app>)
for app in net.pcsx2.PCSX2 net.rpcs3.RPCS3 \
           org.libretro.RetroArch org.DolphinEmu.dolphin-emu; do
    flatpak override --user --filesystem="$HOME/Emulation" "$app"
done
ok "Emulators granted access to ~/Emulation"

section "ES-DE default emulators (standalone, not libretro)"
mkdir -p "$HOME/ES-DE/custom_systems"
# es_find_rules.xml resolves %EMULATOR_DUCKSTATION% to the pinned AppImage alone, ahead of a leftover Flatpak
for f in es_systems.xml es_find_rules.xml; do
    if ! cmp -s "configs/es-de/$f" "$HOME/ES-DE/custom_systems/$f"; then
        cp --backup=numbered "configs/es-de/$f" "$HOME/ES-DE/custom_systems/$f"
    fi
done
ok "custom_systems: psx/ps2/ps3/gc/wii default to standalone; DuckStation resolves to the AppImage"

section "Emulation setup complete"
warn "Manual steps (BIOS/firmware/ROMs are user-provided, not shipped):"
echo "  1. ROMs   → ~/Emulation/roms/<system>/  (psx, ps2, ps3, snes, n64, gc, wii)"
echo "  2. PS1 BIOS → ${XDG_DATA_HOME:-$HOME/.local/share}/duckstation/bios; PS2 BIOS → PCSX2's Flatpak data"
echo "  3. PS3 firmware → RPCS3 → File → Install Firmware (PS3UPDAT.PUP from Sony)"
echo "  4. SNES/N64 cores → RetroArch → Online Updater → Update Installed Cores"
echo "                      (snes9x, Mupen64Plus-Next)"
echo "  5. Controller → each emulator has its OWN mapping (PCSX2/DuckStation:"
echo "     Settings → Controllers → Automatic Mapping; Dolphin: Wii Remote 1"
echo "     → Emulated Wii Remote → Configure)"
echo ""
ok "Launch ES-DE and set the ROM directory to ~/Emulation/roms"
