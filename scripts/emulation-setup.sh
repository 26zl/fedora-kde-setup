#!/bin/bash
# Retro emulation: ES-DE frontend + standalone emulators (PS1/PS2/PS3, Wii)

# takes no options: --help (or any argument) prints this header instead of running
[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e
cd "$(dirname "$0")/.."

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

section "ES-DE frontend (Terra repo)"
# fedora-setup.sh adds Terra and limits it to the packages taken from it
rpm -q terra-release &>/dev/null || { warn "Terra repo missing — run scripts/fedora-setup.sh first"; exit 1; }
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
    org.duckstation.DuckStation \
    net.rpcs3.RPCS3 \
    org.DolphinEmu.dolphin-emu \
    org.libretro.RetroArch
ok "PCSX2 (PS2), DuckStation (PS1), RPCS3 (PS3), Dolphin (Wii), RetroArch (SNES/N64)"
warn "DuckStation's Flathub build is end-of-life. It still works; for the"
warn "maintained version use the official AppImage in ~/Applications/ instead."

section "Flatpak ROM access"
# ROMs on another disk: also grant that path (flatpak override --user --filesystem=<path> <app>)
for app in net.pcsx2.PCSX2 org.duckstation.DuckStation net.rpcs3.RPCS3 \
           org.libretro.RetroArch org.DolphinEmu.dolphin-emu; do
    flatpak override --user --filesystem="$HOME/Emulation" "$app"
done
ok "Emulators granted access to ~/Emulation"

section "ES-DE default emulators (standalone, not libretro)"
mkdir -p "$HOME/ES-DE/custom_systems"
cp configs/es-de/es_systems.xml "$HOME/ES-DE/custom_systems/es_systems.xml"
ok "custom_systems/es_systems.xml: psx/ps2/ps3/wii default to standalone"

section "Emulation setup complete"
warn "Manual steps (BIOS/firmware/ROMs are user-provided, not shipped):"
echo "  1. ROMs   → ~/Emulation/roms/<system>/  (psx, ps2, ps3, snes, n64, wii)"
echo "  2. PS1/PS2 BIOS → each emulator's bios folder under ~/.var/app/<id>/"
echo "  3. PS3 firmware → RPCS3 → File → Install Firmware (PS3UPDAT.PUP from Sony)"
echo "  4. SNES/N64 cores → RetroArch → Online Updater → Update Installed Cores"
echo "                      (snes9x, Mupen64Plus-Next)"
echo "  5. Controller → each emulator has its OWN mapping (PCSX2/DuckStation:"
echo "     Settings → Controllers → Automatic Mapping; Dolphin: Wii Remote 1"
echo "     → Emulated Wii Remote → Configure)"
echo ""
ok "Launch ES-DE and set the ROM directory to ~/Emulation/roms"
