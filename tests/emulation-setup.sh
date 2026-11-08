#!/bin/bash
# Exercise verified downloads, emulator selection and the RPCS3 and DuckStation Flatpak migrations without running
# downloaded code.
set -euo pipefail
[ "$EUID" -ne 0 ] || { echo "Run these fixtures without root." >&2; exit 2; }
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
other_fs=
# u+w first: the failed-move case makes a directory read-only
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp" ${other_fs:+"$other_fs"}' EXIT
stub="$tmp/bin"
mkdir -p "$stub" "$tmp/repo/scripts" "$tmp/repo/configs/es-de"
cp "$repo/scripts/emulation-setup.sh" "$tmp/repo/scripts/"
cp "$repo/configs/es-de/es_systems.xml" "$repo/configs/es-de/es_find_rules.xml" "$tmp/repo/configs/es-de/"
export EMULATION_FIXTURES="$tmp" EMULATION_LOG="$tmp/commands" EMULATION_EXECUTED="$tmp/executed"
: >"$EMULATION_LOG"
: >"$tmp/all-commands"
cat >"$tmp/app.fixture" <<'APP'
#!/bin/sh
echo unexpected >>"$EMULATION_EXECUTED"
exit 99
APP
for name in esde rpcs3 shadps4-app xenia; do
    cp "$tmp/app.fixture" "$tmp/$name.fixture"
    printf '# %s stand-in\n' "$name" >>"$tmp/$name.fixture"
done
printf 'Synthetic upstream license fixture.\n' >"$tmp/license.fixture"
printf 'Corrupt download.\n' >"$tmp/corrupt.fixture"
printf 'Synthetic PS3 save.\n' >"$tmp/save.fixture"
printf 'Synthetic memory card.\n' >"$tmp/card.fixture"
duckstation_fixture="$tmp/duckstation.fixture"
mkdir -p "$duckstation_fixture/bios" "$duckstation_fixture/memcards" "$duckstation_fixture/cache"
printf 'Synthetic BIOS.\n' >"$duckstation_fixture/bios/fixture.bin"
cp "$tmp/card.fixture" "$duckstation_fixture/memcards/fixture.mcd"
printf '[Main]\nSettingsVersion = 3\n' >"$duckstation_fixture/settings.ini"
printf 'Synthetic game list cache.\n' >"$duckstation_fixture/cache/gamelist.cache"

# The real pins: a full SHA-256 per download, and URLs that name one fixed build.
python3 - "$repo/scripts/emulation-setup.sh" <<'PY'
import re
import sys

values = dict(re.findall(r"^([A-Z0-9_]+)=(\S+)$", open(sys.argv[1]).read(), flags=re.M))
for name in ("DUCKSTATION", "DUCKSTATION_LICENSE", "ES_DE", "RPCS3", "SHADPS4", "XENIA_EDGE"):
    assert re.fullmatch(r"[0-9a-f]{64}", values[f"{name}_SHA256"]), f"{name} has no SHA-256 pin"
urls = {name: url for name, url in values.items() if name.endswith("_URL")}
assert re.search(r"/package_files/\d+/download$", urls["ES_DE_URL"]), "ES-DE is not one package file"
assert "/releases/download/build-" in urls["RPCS3_URL"], "RPCS3 is not one build"
assert f"/rpcs3-v{values['RPCS3_VERSION']}-" in urls["RPCS3_URL"], "RPCS3 URL and version differ"
version = values["SHADPS4_VERSION"]
assert urls["SHADPS4_URL"].endswith(f"/v.{version}/shadps4-linux-sdl-{version}.zip"), "shadPS4 URL and version differ"
assert f"/download/{values['XENIA_EDGE_VERSION']}/" in urls["XENIA_EDGE_URL"], "Xenia Edge URL and version differ"
for url in urls.values():
    assert not re.search(r"latest|continuous|nightly", url, re.I), f"moving download: {url}"
PY

# Keep real checksum validation when substituting synthetic downloads in the copied script.
python3 - "$tmp" <<'PY'
import hashlib
from pathlib import Path
import re
import sys
import zipfile

root = Path(sys.argv[1])
with zipfile.ZipFile(root / "shadps4.fixture", "w") as archive:
    archive.write(root / "shadps4-app.fixture", "Shadps4-sdl.AppImage")
path = root / "repo/scripts/emulation-setup.sh"
script = path.read_text()
for key, name in [("DUCKSTATION_SHA256", "app.fixture"), ("DUCKSTATION_LICENSE_SHA256", "license.fixture"),
                  ("ES_DE_SHA256", "esde.fixture"), ("RPCS3_SHA256", "rpcs3.fixture"),
                  ("SHADPS4_SHA256", "shadps4.fixture"), ("XENIA_EDGE_SHA256", "xenia.fixture")]:
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    script, count = re.subn(rf"^{key}=[0-9a-f]{{64}}$", f"{key}={digest}", script, flags=re.M)
    assert count == 1, f"missing {key} pin"
path.write_text(script)
PY
cat >"$stub/uname" <<'STUB'
#!/bin/sh
echo "${EMULATION_ARCH:-x86_64}"
STUB
cat >"$stub/dnf" <<'STUB'
#!/bin/sh
printf 'dnf %s\n' "$*" >>"$EMULATION_LOG"
STUB
cat >"$stub/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$EMULATION_LOG"
STUB
cat >"$stub/flatpak" <<'STUB'
#!/bin/bash
printf 'flatpak %s\n' "$*" >>"$EMULATION_LOG"
case $1 in
    info)
        # EMULATION_FLATPAKS lists the installed apps as id=origin
        for installed in ${EMULATION_FLATPAKS-}; do
            [ "${installed%%=*}" = "${!#}" ] || continue
            [ "$2" != --show-origin ] || echo "${installed#*=}"
            exit 0
        done
        exit 1 ;;
    ps) printf '%s\n' ${EMULATION_RUNNING-} ;;
    uninstall)
        [ ! -e "$HOME/.var/app/net.rpcs3.RPCS3/config/rpcs3" ] || echo 'uninstall with data in place' >>"$EMULATION_LOG" ;;
esac
STUB
cat >"$stub/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$EMULATION_LOG"
[ "${EMULATION_DOWNLOAD:-good}" != bad-download ] || exit 22
destination= url=
while [ "$#" -gt 0 ]; do
    case $1 in
        -o) destination=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
case $url in
    */DuckStation-x64.AppImage) source_file=app.fixture; corrupt=bad-app ;;
    */LICENSE) source_file=license.fixture; corrupt=bad-license ;;
    */package_files/*/download) source_file=esde.fixture; corrupt=bad-esde ;;
    */rpcs3-v*_linux64.AppImage) source_file=rpcs3.fixture; corrupt=bad-rpcs3 ;;
    */shadps4-linux-sdl-*.zip) source_file=shadps4.fixture; corrupt=bad-shadps4 ;;
    */xenia_edge_linux.AppImage) source_file=xenia.fixture; corrupt=bad-xenia ;;
    *) exit 3 ;;
esac
[ "${EMULATION_DOWNLOAD:-good}" != "$corrupt" ] || source_file=corrupt.fixture
cp "$EMULATION_FIXTURES/$source_file" "$destination"
STUB
chmod +x "$stub"/*

fail() { echo "FAIL: $*" >&2; exit 1; }
new_home() {  # NAME: an empty home whose path has spaces
    cat "$EMULATION_LOG" >>"$tmp/all-commands"
    : >"$EMULATION_LOG"
    test_home="$tmp/home $1"
    config_home="$test_home/.config"
    applications="$test_home/Applications"
    mkdir -p "$test_home"
}
run_setup() {  # an empty config_home runs it with XDG_CONFIG_HOME unset
    env -u XDG_CONFIG_HOME HOME="$test_home" ${config_home:+XDG_CONFIG_HOME="$config_home"} \
        XDG_DATA_HOME="$test_home/.local/share" PATH="$stub:$PATH" NO_COLOR=1 bash "$tmp/repo/scripts/emulation-setup.sh"
}
setup_ok() {
    run_setup >"$tmp/output" 2>&1 || { cat "$tmp/output" >&2; fail "setup failed in ${test_home##*/}"; }
}
rpcs3_flatpak_data() {
    flatpak_rpcs3="$test_home/.var/app/net.rpcs3.RPCS3/config/rpcs3"
    save="dev_hdd0/home/00000001/savedata/FIXTURE00/SYS-DATA"
    mkdir -p "$flatpak_rpcs3/${save%/*}"
    cp "$tmp/save.fixture" "$flatpak_rpcs3/$save"
}
kept_flatpak() {  # WHEN: the RPCS3 Flatpak and its data must both be untouched
    ! grep -q '^flatpak uninstall' "$EMULATION_LOG" || fail "the RPCS3 Flatpak was removed $1"
    cmp -s "$tmp/save.fixture" "$flatpak_rpcs3/$save" || fail "the RPCS3 Flatpak's data changed $1"
}
duckstation_flatpak_data() {
    flatpak_duckstation="$test_home/.var/app/org.duckstation.DuckStation/config/duckstation"
    mkdir -p "${flatpak_duckstation%/*}"
    cp -a "$duckstation_fixture" "$flatpak_duckstation"
}
kept_duckstation_data() {  # WHEN: the DuckStation Flatpak's data must be untouched
    diff -r "$duckstation_fixture" "$flatpak_duckstation" >/dev/null || fail "the DuckStation Flatpak's data changed $1"
}
copied_duckstation_data() {  # DESTINATION
    diff -r "$duckstation_fixture" "$1" >/dev/null || fail "the DuckStation Flatpak's data was not copied to $1"
    [ -z "$(find "${1%/*}" -maxdepth 1 -name '.duckstation.*')" ] || fail "the DuckStation copy left its temporary folder"
}
flatpak_apps="net.pcsx2.PCSX2 org.libretro.RetroArch com.github.Rosalie241.RMG org.azahar_emu.Azahar org.ppsspp.PPSSPP
              net.kuribo64.melonDS org.flycast.Flycast info.cemu.Cemu org.DolphinEmu.dolphin-emu"

# A download that fails or misses its pin stops the run before anything is installed.
new_home corrupt
mkdir -p "$applications"
printf 'Existing DuckStation.\n' >"$applications/DuckStation-x64.AppImage"
printf 'Existing ES-DE.\n' >"$applications/ES-DE_x64.AppImage"
cp -a "$applications" "$tmp/existing-applications"
for mode in bad-download bad-app bad-license bad-esde bad-rpcs3 bad-shadps4 bad-xenia; do
    : >"$EMULATION_LOG"
    if EMULATION_DOWNLOAD=$mode run_setup >"$tmp/output" 2>&1; then
        fail "$mode passed checksum validation"
    fi
    diff -r "$tmp/existing-applications" "$applications" >/dev/null || fail "$mode changed ~/Applications"
    ! grep -qv '^curl ' "$EMULATION_LOG" || fail "$mode went on past the downloads"
    [ ! -e "$test_home/.local/share/applications" ] || fail "$mode added menu entries"
done

# First install.
new_home fresh
setup_ok
for pair in DuckStation-x64.AppImage:app ES-DE_x64.AppImage:esde rpcs3_linux64.AppImage:rpcs3 \
            Shadps4-sdl.AppImage:shadps4-app xenia_edge_linux.AppImage:xenia; do
    cmp -s "$tmp/${pair#*:}.fixture" "$applications/${pair%%:*}" || fail "${pair%%:*} was not installed unchanged"
    [ -x "$applications/${pair%%:*}" ] || fail "${pair%%:*} is not executable"
done
installed=$(find "$applications" -mindepth 1 -printf '%P\n' | LC_ALL=C sort | paste -sd ' ')
[ "$installed" = "DuckStation-LICENSE.txt DuckStation-SOURCE.txt DuckStation-x64.AppImage ES-DE_x64.AppImage Shadps4-sdl.AppImage rpcs3_linux64.AppImage xenia_edge_linux.AppImage" ] ||
    fail "unexpected files in ~/Applications: $installed"
cmp -s "$tmp/license.fixture" "$applications/DuckStation-LICENSE.txt" || fail "license notice was not preserved"
grep -q 'Attribution-NonCommercial-NoDerivatives 4.0' "$applications/DuckStation-SOURCE.txt" || fail "missing separate upstream license notice"
for entry in es-de:ES-DE_x64.AppImage rpcs3:rpcs3_linux64.AppImage; do
    desktop="$test_home/.local/share/applications/${entry%%:*}.desktop"
    grep -qxF "Exec=\"$applications/${entry#*:}\"" "$desktop" || fail "the ${entry%%:*} menu entry does not start its AppImage"
    grep -qx 'Categories=Game;Emulator;' "$desktop" || fail "the ${entry%%:*} menu entry is not under Games"
done
grep -q 'curl .*/package_files/[0-9]*/download' "$EMULATION_LOG" || fail "ES-DE was not fetched from its pinned package file"
! grep -qE '^(sudo|dnf) ' "$EMULATION_LOG" || fail "emulation setup ran dnf or sudo"
flathub=$(sed -n 's/^flatpak install -y flathub //p' "$EMULATION_LOG" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ')
[ "$flathub" = "com.github.Rosalie241.RMG info.cemu.Cemu net.kuribo64.melonDS net.pcsx2.PCSX2 org.azahar_emu.Azahar org.flycast.Flycast org.libretro.RetroArch org.ppsspp.PPSSPP" ] ||
    fail "Flathub installs differ from one emulator per system: $flathub"
grep -qxF 'flatpak remote-add --if-not-exists dolphin https://flatpak.dolphin-emu.org/releases.flatpakrepo' "$EMULATION_LOG" ||
    fail "Dolphin's own Flatpak repository was not added"
grep -qxF 'flatpak install -y --reinstall dolphin org.DolphinEmu.dolphin-emu' "$EMULATION_LOG" ||
    fail "Dolphin did not come from its own repository"
! grep -q '^flatpak uninstall' "$EMULATION_LOG" || fail "a first install removed a Flatpak"
[ ! -e "$config_home/duckstation" ] || fail "a DuckStation folder appeared without Flatpak data to copy"
for app in $flatpak_apps; do
    grep -qxF "flatpak override --user --filesystem=$test_home/Emulation $app" "$EMULATION_LOG" || fail "$app cannot read ~/Emulation"
done
[ "$(grep -c '^flatpak override' "$EMULATION_LOG")" = 9 ] || fail "a Flatpak got access although the setup does not install it"
python3 - "$test_home/ES-DE/custom_systems/es_systems.xml" "$test_home/ES-DE/custom_systems/es_find_rules.xml" "$applications" <<'PY'
from fnmatch import fnmatchcase
import os
import sys
import xml.etree.ElementTree as ET

expected = {
    "psx": ("DuckStation (Standalone)", "%EMULATOR_DUCKSTATION% -batch %ROM%"),
    "ps2": ("PCSX2 (Standalone)", "%EMULATOR_PCSX2% -batch %ROM%"),
    "ps3": ("RPCS3 Directory (Standalone)", "%EMULATOR_RPCS3% --no-gui %ROM%"),
    "psp": ("PPSSPP (Standalone)", "%EMULATOR_PPSSPP% %ROM%"),
    "n64": ("Rosalie's Mupen GUI (Standalone)", "%EMULATOR_ROSALIES-MUPEN-GUI% --nogui -q %ROM%"),
    "nds": ("melonDS (Standalone)", "%EMULATOR_MELONDS% -f %ROM%"),
    "n3ds": ("Azahar (Standalone)", "%EMULATOR_AZAHAR% %ROM%"),
    "gc": ("Dolphin (Standalone)", "%INJECT%=%BASENAME%.esprefix %EMULATOR_DOLPHIN% -b -e %ROM%"),
    "wii": ("Dolphin (Standalone)", "%INJECT%=%BASENAME%.esprefix %EMULATOR_DOLPHIN% -b -e %ROM%"),
    "dreamcast": ("Flycast (Standalone)", "%EMULATOR_FLYCAST% %ROM%"),
    "xbox360": ("Xenia Edge (Standalone)", "%EMULATOR_XENIA-EDGE% %INJECT%=%BASENAME%.commands %ROM%"),
}
systems = {system.findtext("name"): system for system in ET.parse(sys.argv[1]).getroot()}
assert set(systems) == set(expected), sorted(set(systems) ^ set(expected))
for name, default in expected.items():
    command = systems[name].find("command")
    assert (command.get("label"), command.text) == default, name
rules = ET.parse(sys.argv[2]).getroot()
duckstation = next(emulator for emulator in rules if emulator.get("name") == "DUCKSTATION")
entries = [entry.text for rule in duckstation if rule.get("type") == "staticpath" for entry in rule]
assert entries == ["~/Applications/DuckStation-x64.AppImage"]
# ES-DE 3.5.0's bundled find rules for the AppImages that have no rule of their own here
installed = os.listdir(sys.argv[3])
for pattern in ("rpcs3*.AppImage", "Shadps4-sdl*.AppImage", "xenia_edge*.AppImage"):
    assert len([name for name in installed if fnmatchcase(name, pattern)]) == 1, pattern
PY

# Coming from the PCSX2/RPCS3/Dolphin/RetroArch Flatpaks and the EOL DuckStation Flatpak.
new_home upgrade
rpcs3_flatpak_data
duckstation_flatpak_data
cores="$test_home/.var/app/org.libretro.RetroArch/config/retroarch/cores"
mkdir -p "$cores" "$test_home/ES-DE/custom_systems"
printf 'Synthetic core.\n' >"$cores/mupen64plus_next_libretro.so"
printf 'Synthetic core.\n' >"$cores/snes9x_libretro.so"
printf '<custom-system-fixture/>\n' >"$test_home/ES-DE/custom_systems/es_systems.xml"
EMULATION_FLATPAKS="net.rpcs3.RPCS3=flathub org.DolphinEmu.dolphin-emu=flathub org.duckstation.DuckStation=flathub" \
    setup_ok
cmp -s "$tmp/save.fixture" "$config_home/rpcs3/$save" || fail "the RPCS3 Flatpak's data did not move to ~/.config/rpcs3"
[ ! -e "$flatpak_rpcs3" ] || fail "RPCS3 data stayed in the Flatpak's folder"
grep -qxF 'flatpak uninstall -y net.rpcs3.RPCS3' "$EMULATION_LOG" || fail "the RPCS3 Flatpak stayed after its data moved"
! grep -q 'uninstall with data in place' "$EMULATION_LOG" || fail "the RPCS3 Flatpak was removed before its data moved"
grep -qxF 'flatpak install -y --reinstall dolphin org.DolphinEmu.dolphin-emu' "$EMULATION_LOG" ||
    fail "Flathub's Dolphin was not switched to Dolphin's repository"
[ ! -e "$cores/mupen64plus_next_libretro.so" ] || fail "RetroArch kept an N64 core next to RMG"
[ -e "$cores/snes9x_libretro.so" ] || fail "the SNES core was removed"
grep -q 'The old DuckStation Flatpak is still installed' "$tmp/output" || fail "missing old Flatpak migration guidance"
kept_duckstation_data "while it was installed"
copied_duckstation_data "$config_home/duckstation"
[ ! -e "$test_home/.local/share/duckstation" ] || fail "DuckStation data went to ~/.local/share although XDG_CONFIG_HOME is set"
[ -f "$test_home/ES-DE/custom_systems/es_systems.xml.~1~" ] || fail "existing ES-DE custom systems were not backed up"
! grep -qE '^flatpak (install|override|uninstall).*org\.duckstation\.DuckStation' "$EMULATION_LOG" ||
    fail "old DuckStation Flatpak was installed, modified or removed"
: >"$EMULATION_LOG"
EMULATION_FLATPAKS=org.DolphinEmu.dolphin-emu=dolphin setup_ok
! grep -q '^flatpak install .*org\.DolphinEmu\.dolphin-emu' "$EMULATION_LOG" || fail "Dolphin from its own repository was installed again"
[ ! -e "$test_home/ES-DE/custom_systems/es_systems.xml.~2~" ] || fail "unchanged setup created another backup"
! grep -q '^  ! .*DuckStation' "$tmp/output" || fail "a repeated run warned about the DuckStation data it had copied"

# The RPCS3 Flatpak stays, with its data, whenever its data cannot be moved whole.
for destination in non-empty empty; do
    new_home "both $destination"
    rpcs3_flatpak_data
    mkdir -p "$config_home/rpcs3"
    [ "$destination" = empty ] || printf 'Synthetic newer config.\n' >"$config_home/rpcs3/config.yml"
    EMULATION_FLATPAKS=net.rpcs3.RPCS3=flathub setup_ok
    kept_flatpak "while ~/.config/rpcs3 existed ($destination)"
    contents=$(find "$config_home/rpcs3" -mindepth 1 -printf '%P\n')
    [ "$contents" = "$([ "$destination" = empty ] || echo config.yml)" ] || fail "data was moved into an existing ~/.config/rpcs3"
    grep -q 'RPCS3 data is in both' "$tmp/output" || fail "no warning about two RPCS3 data folders"
done
new_home read-only
rpcs3_flatpak_data
mkdir -p "$config_home"
chmod 555 "$config_home"
EMULATION_FLATPAKS=net.rpcs3.RPCS3=flathub setup_ok
chmod 755 "$config_home"
kept_flatpak "after its data could not move"
grep -q 'Could not rename' "$tmp/output" || fail "no warning after a failed move"
new_home other-filesystem
rpcs3_flatpak_data
if other_fs=$(mktemp -d /dev/shm/emulation-setup.XXXXXX 2>/dev/null) &&
    [ "$(stat -c %d "$other_fs")" != "$(stat -c %d "$test_home")" ]; then
    config_home="$other_fs/config"
    EMULATION_FLATPAKS=net.rpcs3.RPCS3=flathub setup_ok
    kept_flatpak "after a move that needed a copy to another filesystem"
    [ ! -e "$config_home/rpcs3" ] || fail "RPCS3 data was copied to another filesystem"
else
    echo "Skipped the cross-filesystem move: /dev/shm is not a separate filesystem here."
fi
new_home running
rpcs3_flatpak_data
EMULATION_FLATPAKS=net.rpcs3.RPCS3=flathub EMULATION_RUNNING=net.rpcs3.RPCS3 setup_ok
kept_flatpak "while it was running"
[ ! -e "$config_home/rpcs3" ] || fail "RPCS3 data moved while the Flatpak was running"
grep -q 'The RPCS3 Flatpak is running' "$tmp/output" || fail "no warning about the running RPCS3 Flatpak"
new_home no-data
EMULATION_FLATPAKS=net.rpcs3.RPCS3=flathub setup_ok
grep -qxF 'flatpak uninstall -y net.rpcs3.RPCS3' "$EMULATION_LOG" || fail "an RPCS3 Flatpak without data stayed installed"
[ ! -e "$config_home/rpcs3" ] || fail "an RPCS3 folder appeared without data to move"

# The DuckStation Flatpak's data is copied, also after an uninstall, and only into an absent folder; the original stays.
new_home duckstation-uninstalled
duckstation_flatpak_data
config_home=
setup_ok
copied_duckstation_data "$test_home/.local/share/duckstation"
kept_duckstation_data "after the copy"
[ ! -e "$test_home/.config/duckstation" ] || fail "DuckStation data went to ~/.config without XDG_CONFIG_HOME"
! grep -q 'The old DuckStation Flatpak is still installed' "$tmp/output" || fail "an uninstalled Flatpak was reported installed"
new_home duckstation-both
duckstation_flatpak_data
mkdir -p "$config_home/duckstation"
printf 'Synthetic newer settings.\n' >"$config_home/duckstation/settings.ini"
EMULATION_FLATPAKS=org.duckstation.DuckStation=flathub setup_ok
kept_duckstation_data "while the AppImage's folder existed"
[ "$(find "$config_home/duckstation" -mindepth 1 -printf '%P\n')" = settings.ini ] ||
    fail "data was copied into an existing DuckStation folder"
grep -q 'and 2 of its' "$tmp/output" || fail "no warning naming the two DuckStation files the AppImage lacks"
new_home duckstation-running
duckstation_flatpak_data
EMULATION_FLATPAKS=org.duckstation.DuckStation=flathub EMULATION_RUNNING=org.duckstation.DuckStation setup_ok
kept_duckstation_data "while it was running"
[ ! -e "$config_home/duckstation" ] || fail "DuckStation data was copied while the Flatpak was running"
grep -q 'The DuckStation Flatpak is running' "$tmp/output" || fail "no warning about the running DuckStation Flatpak"
new_home duckstation-unreadable
duckstation_flatpak_data
chmod 000 "$flatpak_duckstation/memcards/fixture.mcd"
setup_ok
chmod 644 "$flatpak_duckstation/memcards/fixture.mcd"
kept_duckstation_data "after a failed copy"
[ ! -e "$config_home/duckstation" ] || fail "a failed DuckStation copy left a partial folder"
[ -z "$(find "$config_home" -maxdepth 1 -name '.duckstation.*')" ] || fail "a failed DuckStation copy left its temporary folder"
grep -q 'Could not copy' "$tmp/output" || fail "no warning after a failed DuckStation copy"

# ROMs on another disk behind a ~/Emulation/roms link.
new_home linked-roms
mkdir -p "$tmp/other disk/roms" "$test_home/Emulation"
ln -s "$tmp/other disk/roms" "$test_home/Emulation/roms"
target=$(readlink -f "$tmp/other disk/roms")
setup_ok
for app in $flatpak_apps; do
    grep -qxF "flatpak override --user --filesystem=$test_home/Emulation --filesystem=$target $app" "$EMULATION_LOG" ||
        fail "$app cannot read the ROMs behind the ~/Emulation/roms link"
done

new_home aarch64
if EMULATION_ARCH=aarch64 run_setup >"$tmp/output" 2>&1; then
    fail "unsupported architecture was accepted"
fi
[ ! -s "$EMULATION_LOG" ] || fail "unsupported architecture reached downloads or package commands"

cat "$EMULATION_LOG" >>"$tmp/all-commands"
[ ! -e "$EMULATION_EXECUTED" ] || fail "a downloaded AppImage was executed during setup"
! grep -q -- '--delete-data' "$tmp/all-commands" || fail "a Flatpak's data was deleted"
! grep -q 'uninstall with data in place' "$tmp/all-commands" || fail "the RPCS3 Flatpak was removed before its data moved"
echo "All emulation setup tests passed."
