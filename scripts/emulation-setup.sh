#!/bin/bash
# Retro emulation: ES-DE frontend + standalone emulators (PS1/PS2/PS3, Wii)

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e
[ "$EUID" -ne 0 ] || { echo "Run without sudo: bash scripts/emulation-setup.sh" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "This setup requires x86_64" >&2; exit 1; }
cd "$(dirname "$0")/.."

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

DUCKSTATION_VERSION=v0.1-11894
DUCKSTATION_REV=c66b2694da65cece8886ed3d4a069098831f8358
DUCKSTATION_SHA256=c2fd26257ac5cfefe4f77b61b04b8fe299f9c4e0cf6b851fc5259c815979466a
DUCKSTATION_LICENSE_SHA256=38762e3777f4ec00a6f769062a7c3f704fb78ce08303ecff88558da4c49cf9ea
rpm -q terra-release &>/dev/null || { warn "Terra repo missing — run scripts/fedora-setup.sh first"; exit 1; }

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

section "ES-DE frontend (Terra repo)"
# Terra builds ES-DE for a new Fedora release some time after the release ships
if dnf -q repoquery --available emulationstation-de 2>/dev/null | grep -q .; then
    sudo dnf install -y emulationstation-de
    ok "ES-DE installed"
else
    warn "Terra has no ES-DE build for Fedora $(rpm -E %fedora) yet: use the AppImage from es-de.org"
    warn "and re-run this script once Terra has it; the emulators below install either way"
fi

section "Emulators (Flatpak)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
    net.pcsx2.PCSX2 \
    net.rpcs3.RPCS3 \
    org.DolphinEmu.dolphin-emu \
    org.libretro.RetroArch
ok "PCSX2 (PS2), RPCS3 (PS3), Dolphin (Wii), RetroArch (SNES/N64)"

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
ok "custom_systems: psx/ps2/ps3/wii default to standalone; DuckStation resolves to the AppImage"

section "Emulation setup complete"
warn "Manual steps (BIOS/firmware/ROMs are user-provided, not shipped):"
echo "  1. ROMs   → ~/Emulation/roms/<system>/  (psx, ps2, ps3, snes, n64, wii)"
echo "  2. PS1 BIOS → ${XDG_DATA_HOME:-$HOME/.local/share}/duckstation/bios; PS2 BIOS → PCSX2's Flatpak data"
echo "  3. PS3 firmware → RPCS3 → File → Install Firmware (PS3UPDAT.PUP from Sony)"
echo "  4. SNES/N64 cores → RetroArch → Online Updater → Update Installed Cores"
echo "                      (snes9x, Mupen64Plus-Next)"
echo "  5. Controller → each emulator has its OWN mapping (PCSX2/DuckStation:"
echo "     Settings → Controllers → Automatic Mapping; Dolphin: Wii Remote 1"
echo "     → Emulated Wii Remote → Configure)"
echo ""
ok "Launch ES-DE and set the ROM directory to ~/Emulation/roms"
