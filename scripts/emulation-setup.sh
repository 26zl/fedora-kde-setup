#!/bin/bash
# Retro emulation: ES-DE and one emulator per system, each one ES-DE's default for its system.
# PS1 DuckStation, PS2 PCSX2, PS3 RPCS3, PS4 shadPS4, PSP PPSSPP, SNES RetroArch, N64 RMG, DS melonDS,
# 3DS Azahar, GameCube and Wii Dolphin, Wii U Cemu, Dreamcast Flycast, Xbox 360 Xenia Edge.

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
# every RPCS3 build is its own release; its notes list the SHA-256
RPCS3_VERSION=0.0.43-20572
RPCS3_URL=https://github.com/RPCS3/rpcs3-binaries-linux/releases/download/build-e61d5eaf0f7135e578a5280b2bb2bd5c8a1c439f/rpcs3-v0.0.43-20572-e61d5eaf_linux64.AppImage
RPCS3_SHA256=c34a9e553846842c2be073bfa4980c2fec587362ad022c100b8391ca66847fc8
SHADPS4_VERSION=0.21.0
SHADPS4_URL=https://github.com/shadps4-emu/shadPS4/releases/download/v.0.21.0/shadps4-linux-sdl-0.21.0.zip
SHADPS4_SHA256=7c41c58254461d742b5edf564e23795697b63e9e46de11d0e1ed67bd2cbaae68
# Xenia Edge has no stable channel: every commit is a release, tagged with its short hash
XENIA_EDGE_VERSION=3c0f1d3
XENIA_EDGE_URL=https://github.com/has207/xenia-edge/releases/download/3c0f1d3/xenia_edge_linux.AppImage
XENIA_EDGE_SHA256=351bf908849a6052251b48a7c104b2fd11d662e082f31161221d0f204dd0ed15

applications="$HOME/Applications"
menu="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$applications"
# Stage beside the destination so a failed download cannot replace an installed binary.
staging=$(mktemp -d "$applications/.emulation-setup.XXXXXX")
trap 'rm -rf "$staging"' EXIT

fetch() {  # URL NAME SHA256
    curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 "$1" -o "$staging/$2"
    printf '%s  %s\n' "$3" "$staging/$2" | sha256sum -c --quiet -
}
install_appimage() {  # NAME
    chmod 755 "$staging/$1"
    mv -fT "$staging/$1" "$applications/$1"
}
menu_entry() {  # ID NAME GENERIC-NAME COMMENT APPIMAGE
    mkdir -p "$menu"
    cat >"$staging/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
GenericName=$3
Comment=$4
Exec="$applications/$5"
Icon=applications-games
Terminal=false
Categories=Game;Emulator;
EOF
    mv -fT "$staging/$1.desktop" "$menu/$1.desktop"
}

section "Downloads (pinned, checked before anything is installed)"
fetch "https://github.com/stenzek/duckstation/releases/download/$DUCKSTATION_VERSION/DuckStation-x64.AppImage" \
    DuckStation-x64.AppImage "$DUCKSTATION_SHA256"
fetch "https://raw.githubusercontent.com/stenzek/duckstation/$DUCKSTATION_REV/LICENSE" \
    DuckStation-LICENSE.txt "$DUCKSTATION_LICENSE_SHA256"
fetch "$ES_DE_URL" ES-DE_x64.AppImage "$ES_DE_SHA256"
fetch "$RPCS3_URL" rpcs3_linux64.AppImage "$RPCS3_SHA256"
fetch "$SHADPS4_URL" shadps4.zip "$SHADPS4_SHA256"
fetch "$XENIA_EDGE_URL" xenia_edge_linux.AppImage "$XENIA_EDGE_SHA256"
# only this member is read; no path from the archive is ever written
python3 -I - "$staging/shadps4.zip" "$staging/Shadps4-sdl.AppImage" <<'EOF'
import shutil
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive, archive.open("Shadps4-sdl.AppImage") as member, \
        open(sys.argv[2], "xb") as appimage:
    shutil.copyfileobj(member, appimage)
EOF
ok "Every download matches its pinned SHA-256"

section "DuckStation (official AppImage)"
cat >"$staging/DuckStation-SOURCE.txt" <<EOF
DuckStation by Connor McLaughlin and contributors
Version: $DUCKSTATION_VERSION
Source: https://github.com/stenzek/duckstation/tree/$DUCKSTATION_REV
Official download: https://www.duckstation.org/
License: Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International
License text: DuckStation-LICENSE.txt
The upstream AppImage is unmodified and retains its bundled third-party notices.
EOF
chmod 644 "$staging/DuckStation-LICENSE.txt" "$staging/DuckStation-SOURCE.txt"
mv -fT "$staging/DuckStation-LICENSE.txt" "$applications/DuckStation-LICENSE.txt"
mv -fT "$staging/DuckStation-SOURCE.txt" "$applications/DuckStation-SOURCE.txt"
install_appimage DuckStation-x64.AppImage
ok "DuckStation $DUCKSTATION_VERSION: $applications/DuckStation-x64.AppImage"
# DuckStation's own rule: $XDG_CONFIG_HOME/duckstation when that is an absolute path, else ~/.local/share/duckstation
case ${XDG_CONFIG_HOME-} in
    /*) duckstation_data="$XDG_CONFIG_HOME/duckstation" ;;
    *) duckstation_data="$HOME/.local/share/duckstation" ;;
esac
flatpak_duckstation="$HOME/.var/app/org.duckstation.DuckStation/config/duckstation"
if [ ! -d "$flatpak_duckstation" ]; then
    :
elif flatpak ps --columns=application 2>/dev/null | grep -qx org.duckstation.DuckStation; then
    warn "The DuckStation Flatpak is running. Close it and run this script again to copy its data to the AppImage."
elif [ -e "$duckstation_data" ] || [ -L "$duckstation_data" ]; then
    missing=0
    while IFS= read -r -d '' file; do
        [ -e "$duckstation_data/$file" ] || missing=$((missing + 1))
    done < <(cd "$flatpak_duckstation" && find . -type f ! -path './cache/*' -printf '%P\0')
    if [ "$missing" -gt 0 ]; then
        warn "$duckstation_data already existed, so the DuckStation Flatpak's data was not copied and $missing of its"
        warn "files (BIOS, memory cards, save states) are missing there. Close DuckStation and copy them from $flatpak_duckstation."
    fi
else
    # copied beside the destination and renamed into place, so an interrupted copy never looks complete
    copy=
    if mkdir -p "${duckstation_data%/*}" && copy=$(mktemp -d "${duckstation_data%/*}/.duckstation.XXXXXX") &&
        cp -a "$flatpak_duckstation/." "$copy/duckstation" && mv -T "$copy/duckstation" "$duckstation_data"; then
        rmdir "$copy"
        ok "Copied the DuckStation Flatpak's BIOS, saves and settings to $duckstation_data; the originals stay in ~/.var/app"
    else
        [ -z "$copy" ] || rm -rf "$copy"
        warn "Could not copy $flatpak_duckstation to $duckstation_data, so nothing was created there."
        warn "Copy that folder there yourself while DuckStation is closed."
    fi
fi
if flatpak info org.duckstation.DuckStation >/dev/null 2>&1; then
    warn "The old DuckStation Flatpak is still installed; ES-DE starts the AppImage. Once that shows your BIOS and saves:"
    warn "flatpak uninstall org.duckstation.DuckStation (without --delete-data)"
fi

section "ES-DE (official AppImage)"
# es-de.org ships Linux builds only as AppImages; Terra's RPM lagged each new Fedora release
install_appimage ES-DE_x64.AppImage
menu_entry es-de ES-DE "Emulator frontend" "Browse and play the games in ~/Emulation/roms" ES-DE_x64.AppImage
ok "ES-DE $ES_DE_VERSION: $applications/ES-DE_x64.AppImage, in the menu under Games"

section "RPCS3 (official AppImage)"
install_appimage rpcs3_linux64.AppImage
menu_entry rpcs3 RPCS3 "PlayStation 3 emulator" "Install the PS3 firmware and games" rpcs3_linux64.AppImage
ok "RPCS3 $RPCS3_VERSION: $applications/rpcs3_linux64.AppImage, in the menu under Games"
rpcs3_data="${XDG_CONFIG_HOME:-$HOME/.config}/rpcs3"
flatpak_data="$HOME/.var/app/net.rpcs3.RPCS3/config/rpcs3"
if flatpak info net.rpcs3.RPCS3 >/dev/null 2>&1; then
    if flatpak ps --columns=application 2>/dev/null | grep -qx net.rpcs3.RPCS3; then
        warn "The RPCS3 Flatpak is running. Close it and run this script again to move its data and remove it."
    elif [ ! -e "$flatpak_data" ]; then
        flatpak uninstall -y net.rpcs3.RPCS3
        ok "Removed the RPCS3 Flatpak, which held no data"
    elif [ -e "$rpcs3_data" ] || [ -L "$rpcs3_data" ]; then
        warn "RPCS3 data is in both $flatpak_data and $rpcs3_data, so the Flatpak stays installed."
        warn "Keep the copy you want in $rpcs3_data, then: flatpak uninstall net.rpcs3.RPCS3 (without --delete-data)"
    # a rename or nothing: a copy to another filesystem could stop halfway and split the data
    elif mkdir -p "${rpcs3_data%/*}" && mv -T --no-copy "$flatpak_data" "$rpcs3_data"; then
        flatpak uninstall -y net.rpcs3.RPCS3
        ok "Moved the RPCS3 Flatpak's data to $rpcs3_data and removed the Flatpak; its cache stays in ~/.var/app"
    else
        warn "Could not rename $flatpak_data to $rpcs3_data, so the Flatpak stays installed."
        warn "Move that folder there yourself, then: flatpak uninstall net.rpcs3.RPCS3 (without --delete-data)"
    fi
fi

section "shadPS4 and Xenia Edge (official AppImages)"
install_appimage Shadps4-sdl.AppImage
ok "shadPS4 $SHADPS4_VERSION (PS4): $applications/Shadps4-sdl.AppImage"
install_appimage xenia_edge_linux.AppImage
ok "Xenia Edge $XENIA_EDGE_VERSION (Xbox 360): $applications/xenia_edge_linux.AppImage"

section "Emulators (Flatpak)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
    net.pcsx2.PCSX2 \
    org.libretro.RetroArch \
    com.github.Rosalie241.RMG \
    org.azahar_emu.Azahar \
    org.ppsspp.PPSSPP \
    net.kuribo64.melonDS \
    org.flycast.Flycast \
    info.cemu.Cemu
ok "Flathub: PCSX2, RetroArch (SNES), RMG (N64), Azahar (3DS), PPSSPP, melonDS (DS), Flycast (Dreamcast), Cemu (Wii U)"
# the Dolphin team's own repository uses Flathub's app ID, so switching keeps ~/.var/app/org.DolphinEmu.dolphin-emu
flatpak remote-add --if-not-exists dolphin https://flatpak.dolphin-emu.org/releases.flatpakrepo
if [ "$(flatpak info --show-origin org.DolphinEmu.dolphin-emu 2>/dev/null)" != dolphin ]; then
    flatpak install -y --reinstall dolphin org.DolphinEmu.dolphin-emu
fi
ok "Dolphin (GameCube, Wii) from flatpak.dolphin-emu.org"
# earlier manual steps had this core installed for N64, which RMG runs now
core="$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores/mupen64plus_next_libretro.so"
if [ -f "$core" ]; then
    rm -f "$core"
    ok "Removed RetroArch's Mupen64Plus-Next core: N64 runs in RMG"
fi

section "Flatpak ROM access"
grants=(--filesystem="$HOME/Emulation")
readable="$HOME/Emulation"
emulation=$(readlink -m "$HOME/Emulation")
roms=$(readlink -m "$HOME/Emulation/roms")
# a ROM folder linked to another disk is reachable in the sandbox only through its target
if [[ $roms != "$emulation"/* ]]; then
    grants+=(--filesystem="$roms")
    readable+=" and $roms, the ROM folder it links to"
fi
for app in net.pcsx2.PCSX2 org.libretro.RetroArch com.github.Rosalie241.RMG org.azahar_emu.Azahar \
           org.ppsspp.PPSSPP net.kuribo64.melonDS org.flycast.Flycast info.cemu.Cemu org.DolphinEmu.dolphin-emu; do
    flatpak override --user "${grants[@]}" "$app"
done
ok "Emulator Flatpaks can read $readable"

section "ES-DE default emulators"
mkdir -p "$HOME/ES-DE/custom_systems"
# es_find_rules.xml resolves %EMULATOR_DUCKSTATION% to the pinned AppImage alone, ahead of a leftover Flatpak
for f in es_systems.xml es_find_rules.xml; do
    if ! cmp -s "configs/es-de/$f" "$HOME/ES-DE/custom_systems/$f"; then
        cp --backup=numbered "configs/es-de/$f" "$HOME/ES-DE/custom_systems/$f"
    fi
done
ok "custom_systems: each system starts the emulator installed above; DuckStation resolves to the AppImage"

section "Emulation setup complete"
warn "Manual steps (BIOS, firmware, keys and games are your own dumps, never shipped):"
echo "  1. Games  → ~/Emulation/roms/<system>/  (psx ps2 ps3 ps4 psp snes n64 nds n3ds gc wii wiiu dreamcast xbox360)"
echo "  2. PS1 BIOS → $duckstation_data/bios; PS2 BIOS → PCSX2's Flatpak data"
echo "  3. PS3 firmware → RPCS3 (in the menu) → File → Install Firmware (PS3UPDAT.PUP from Sony)"
echo "  4. PS4 → per game a .desktop file in roms/ps4 whose Exec line runs"
echo "     $applications/Shadps4-sdl.AppImage \"<game folder>/eboot.bin\""
echo "  5. SNES core → RetroArch → Online Updater → Core Downloader → Nintendo - SNES / SFC (Snes9x - Current)"
echo "  6. Controller → each emulator has its OWN mapping (PCSX2/DuckStation:"
echo "     Settings → Controllers → Automatic Mapping; Dolphin: Wii Remote 1"
echo "     → Emulated Wii Remote → Configure)"
echo ""
ok "Launch ES-DE and set the ROM directory to ~/Emulation/roms"
