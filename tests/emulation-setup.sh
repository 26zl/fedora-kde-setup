#!/bin/bash
# Exercise verified AppImage installation and migration without running downloaded code.
set -euo pipefail
[ "$EUID" -ne 0 ] || { echo "Run these fixtures without root." >&2; exit 2; }
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
test_home="$tmp/home with spaces"
mkdir -p "$stub" "$tmp/repo/scripts" "$tmp/repo/configs/es-de" "$test_home/Applications"
cp "$repo/scripts/emulation-setup.sh" "$tmp/repo/scripts/"
cp "$repo/configs/es-de/es_systems.xml" "$repo/configs/es-de/es_find_rules.xml" "$tmp/repo/configs/es-de/"
export EMULATION_FIXTURES="$tmp" EMULATION_LOG="$tmp/commands" EMULATION_EXECUTED="$tmp/executed"
: >"$EMULATION_LOG"
cat >"$tmp/app.fixture" <<'APP'
#!/bin/sh
echo unexpected >>"$EMULATION_EXECUTED"
exit 99
APP
printf 'Synthetic upstream license fixture.\n' >"$tmp/license.fixture"
printf 'Corrupt download.\n' >"$tmp/corrupt.fixture"
# Keep real checksum validation when substituting synthetic downloads in the copied script.
python3 - "$tmp" <<'PY'
import hashlib
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
path = root / "repo/scripts/emulation-setup.sh"
script = path.read_text()
for key, name in [("DUCKSTATION_SHA256", "app.fixture"), ("DUCKSTATION_LICENSE_SHA256", "license.fixture")]:
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    script, count = re.subn(rf"^{key}=[0-9a-f]{{64}}$", f"{key}={digest}", script, flags=re.M)
    assert count == 1, f"missing {key} pin"
path.write_text(script)
PY
cat >"$stub/uname" <<'STUB'
#!/bin/sh
echo "${EMULATION_ARCH:-x86_64}"
STUB
cat >"$stub/rpm" <<'STUB'
#!/bin/sh
[ "${EMULATION_TERRA:-yes}" = yes ] || exit 1
case "$*" in *%fedora*) echo 44 ;; esac
STUB
cat >"$stub/dnf" <<'STUB'
#!/bin/sh
echo emulationstation-de
STUB
cat >"$stub/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$EMULATION_LOG"
STUB
cat >"$stub/flatpak" <<'STUB'
#!/bin/sh
printf 'flatpak %s\n' "$*" >>"$EMULATION_LOG"
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
    *) exit 3 ;;
esac
[ "${EMULATION_DOWNLOAD:-good}" != "$corrupt" ] || source_file=corrupt.fixture
cp "$EMULATION_FIXTURES/$source_file" "$destination"
STUB
chmod +x "$stub"/*

fail() { echo "FAIL: $*" >&2; exit 1; }
run_setup() { env HOME="$test_home" PATH="$stub:$PATH" NO_COLOR=1 bash "$tmp/repo/scripts/emulation-setup.sh"; }
app="$test_home/Applications/DuckStation-x64.AppImage"
printf 'Existing AppImage.\n' >"$app"
cp "$app" "$tmp/existing-app"
if EMULATION_TERRA=no run_setup >"$tmp/output" 2>&1; then
    fail "missing Terra prerequisite was accepted"
fi
[ ! -s "$EMULATION_LOG" ] || fail "missing Terra reached downloads or package changes"
cmp -s "$tmp/existing-app" "$app" || fail "missing Terra replaced the existing AppImage"
for mode in bad-download bad-app bad-license; do
    : >"$EMULATION_LOG"
    if EMULATION_DOWNLOAD=$mode run_setup >"$tmp/output" 2>&1; then
        fail "$mode passed checksum validation"
    fi
    cmp -s "$tmp/existing-app" "$app" || fail "$mode replaced the existing AppImage"
    ! grep -qE '^(sudo|flatpak install)' "$EMULATION_LOG" || fail "$mode changed other packages"
    [ ! -e "$test_home/Applications/DuckStation-LICENSE.txt" ] || fail "$mode installed unverified notices"
    [ -z "$(find "$test_home/Applications" -name '.duckstation.*' -print -quit)" ] || fail "$mode leaked temporary files"
done

mkdir -p "$test_home/.var/app/org.duckstation.DuckStation/config/duckstation/memcards" "$test_home/ES-DE/custom_systems"
printf 'Synthetic memory card.\n' >"$tmp/card.fixture"
cp "$tmp/card.fixture" "$test_home/.var/app/org.duckstation.DuckStation/config/duckstation/memcards/fixture.mcd"
printf '<custom-system-fixture/>\n' >"$test_home/ES-DE/custom_systems/es_systems.xml"
: >"$EMULATION_LOG"
run_setup >"$tmp/output"
cmp -s "$tmp/app.fixture" "$app" || fail "verified AppImage was not installed unchanged"
[ -x "$app" ] || fail "installed AppImage is not executable"
cmp -s "$tmp/license.fixture" "$test_home/Applications/DuckStation-LICENSE.txt" || fail "license notice was not preserved"
grep -q 'Attribution-NonCommercial-NoDerivatives 4.0' "$test_home/Applications/DuckStation-SOURCE.txt" || fail "missing separate upstream license notice"
grep -q 'The old DuckStation Flatpak is still installed' "$tmp/output" || fail "missing old Flatpak migration guidance"
cmp -s "$tmp/card.fixture" "$test_home/.var/app/org.duckstation.DuckStation/config/duckstation/memcards/fixture.mcd" || fail "old Flatpak data was changed"
[ -f "$test_home/ES-DE/custom_systems/es_systems.xml.~1~" ] || fail "existing ES-DE custom systems were not backed up"
! grep -E '^flatpak (install|override|uninstall).*org\.duckstation\.DuckStation' "$EMULATION_LOG" || fail "old Flatpak was installed, modified or removed"
! grep -q '/releases/download/latest/' "$EMULATION_LOG" || fail "AppImage download was not version-pinned"
run_setup >"$tmp/output"
[ ! -e "$EMULATION_EXECUTED" ] || fail "downloaded AppImage was executed during setup"
[ ! -e "$test_home/ES-DE/custom_systems/es_systems.xml.~2~" ] || fail "unchanged setup created another backup"

python3 - "$test_home/ES-DE/custom_systems/es_systems.xml" "$test_home/ES-DE/custom_systems/es_find_rules.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

systems = ET.parse(sys.argv[1]).getroot()
psx = next(system for system in systems if system.findtext("name") == "psx")
command = psx.find("command")
assert command.text == "%EMULATOR_DUCKSTATION% -batch %ROM%"
assert command.get("label") == "DuckStation (Standalone)"
rules = ET.parse(sys.argv[2]).getroot()
duckstation = next(emulator for emulator in rules if emulator.get("name") == "DUCKSTATION")
entries = [entry.text for rule in duckstation if rule.get("type") == "staticpath" for entry in rule]
assert entries == ["~/Applications/DuckStation-x64.AppImage"]
PY

: >"$EMULATION_LOG"
if EMULATION_ARCH=aarch64 run_setup >"$tmp/output" 2>&1; then
    fail "unsupported architecture was accepted"
fi
[ ! -s "$EMULATION_LOG" ] || fail "unsupported architecture reached downloads or package commands"
echo "All emulation setup tests passed."
