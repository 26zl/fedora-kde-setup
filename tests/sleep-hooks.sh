#!/bin/bash
# Exercise display restoration and USB sleep quirks against isolated fixtures.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/root/sys/module/amdgpu" "$tmp/root/run/user/1000" "$tmp/root/run/user/1001"
python3 - "$tmp/root/run/user/1000/wayland-0" "$tmp/root/run/user/1001/wayland-0" <<'PY'
import socket
import sys
for path in sys.argv[1:]:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.bind(path)
PY

cat >"$tmp/bin/loginctl" <<'STUB'
#!/bin/bash
[ "$SLEEP_STAGE" != frozen ] || exit 99
case $1 in
    list-sessions) [ "$SESSION_MODE" != none ] && echo "$SESSION_ID 1000 fixture-user seat0" ;;
    show-session)
        case $4 in
            Type) if [ "$SESSION_MODE" = x11 ]; then echo x11; else echo wayland; fi ;;
            Class) if [ "$SESSION_MODE" = greeter ]; then echo greeter; else echo user; fi ;;
            Active) if [ "$SESSION_MODE" = inactive ]; then echo no; else echo yes; fi ;;
            User) echo "$SESSION_UID" ;;
        esac
        ;;
esac
STUB
cat >"$tmp/bin/id" <<'STUB'
#!/bin/bash
echo fixture-user
STUB
cat >"$tmp/bin/runuser" <<'STUB'
#!/bin/bash
[ "$SLEEP_STAGE" != frozen ] || exit 99
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
STUB
cat >"$tmp/bin/kscreen-doctor" <<'STUB'
#!/bin/bash
if [ "$1" = -j ]; then
    echo "$SLEEP_STAGE" >>"$QUERY_LOG"
    [ "$QUERY_FAIL" = no ] || exit 1
    cat "$DISPLAY_CONFIG"
else
    printf '%s\n' "$*" >>"$CALL_LOG"
    [ "$RESTORE_FAIL" = no ] || exit 1
fi
STUB
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HW_ROOT="$tmp/root" RUNTIME_DIRECTORY="$tmp/state"
export CALL_LOG="$tmp/calls" QUERY_LOG="$tmp/queries"

cat >"$tmp/before.json" <<'JSON'
{"outputs":[
  {"name":"DP-1","enabled":true,"connected":true},
  {"name":"DP-2","enabled":false,"connected":true},
  {"name":"eDP-1","enabled":true,"connected":true},
  {"name":"DP-3","enabled":true,"connected":true},
  {"name":"DP-4","enabled":true,"connected":true},
  {"name":"HDMI-A-1","enabled":true,"connected":true}
]}
JSON
cat >"$tmp/after.json" <<'JSON'
{"outputs":[
  {"name":"DP-1","enabled":false,"connected":true},
  {"name":"DP-2","enabled":false,"connected":true},
  {"name":"eDP-1","enabled":false,"connected":true},
  {"name":"DP-3","enabled":false,"connected":false},
  {"name":"DP-4","enabled":true,"connected":true},
  {"name":"HDMI-A-1","enabled":false,"connected":true}
]}
JSON
printf '{"outputs":[]}\n' >"$tmp/empty.json"
printf 'invalid JSON\n' >"$tmp/invalid.json"

fail() { echo "FAIL: $1" >&2; exit 1; }
reset() {
    export SESSION_MODE=user SESSION_ID=c1 SESSION_UID=1000 QUERY_FAIL=no RESTORE_FAIL=no
    : >"$CALL_LOG"
    : >"$QUERY_LOG"
}
capture() {
    DISPLAY_CONFIG="${1:-$tmp/before.json}" SLEEP_STAGE=pre bash "$repo/system/kde-display-sleep.sh" pre
}
resume() {
    DISPLAY_CONFIG="$tmp/after.json" SLEEP_STAGE=post bash "$repo/system/kde-display-sleep.sh" post
}
unchanged() { [ ! -s "$CALL_LOG" ] || fail "$1 changed display state"; }
consumed() { [ ! -e "$tmp/state/outputs.json" ] || fail 'sleep state was not consumed'; }

reset
capture
[ "$(stat -c %a "$tmp/state/outputs.json")" = 600 ] || fail 'display state is not private'
resume
[ "$(cat "$CALL_LOG")" = 'output.DP-1.enable output.HDMI-A-1.enable' ] || fail 'incorrect outputs restored'
[ "$(wc -l <"$CALL_LOG")" -eq 1 ] || fail 'outputs were not restored atomically'
consumed

reset
resume
unchanged 'missing capture'
[ ! -s "$QUERY_LOG" ] || fail 'missing capture queried KDE'

reset
capture "$tmp/empty.json"
: >"$QUERY_LOG"
resume
unchanged 'empty capture'
[ ! -s "$QUERY_LOG" ] || fail 'empty capture queried KDE'
consumed

for mode in none greeter inactive x11; do
    reset
    capture
    export SESSION_MODE=$mode
    capture
    consumed
    resume
    unchanged "$mode session"
done

reset
capture
export QUERY_FAIL=yes
if capture; then fail 'failed capture was accepted'; fi
consumed
resume
unchanged 'failed capture'

reset
capture
if capture "$tmp/invalid.json" 2>/dev/null; then fail 'invalid JSON was accepted'; fi
consumed
resume
unchanged 'invalid capture'

reset
capture
export SESSION_ID=c2
resume
unchanged 'changed active session'
consumed

reset
capture
export SESSION_UID=1001
resume
unchanged 'changed session user'
consumed

reset
cp "$tmp/invalid.json" "$tmp/state/outputs.json"
if resume 2>/dev/null; then fail 'invalid saved state was accepted'; fi
unchanged 'invalid saved state'
consumed

reset
capture
export QUERY_FAIL=yes
if resume; then fail 'failed resume query was accepted'; fi
unchanged 'failed resume query'
consumed

reset
capture
export RESTORE_FAIL=yes
if resume; then fail 'failed output restoration was accepted'; fi
consumed

reset
mv "$tmp/root/sys/module/amdgpu" "$tmp/root/sys/module/amdgpu.off"
capture
resume
unchanged 'non-amdgpu hardware'
[ ! -s "$QUERY_LOG" ] || fail 'non-amdgpu hardware queried KDE'
mv "$tmp/root/sys/module/amdgpu.off" "$tmp/root/sys/module/amdgpu"

reset
mv "$tmp/root/run/user/1000/wayland-0" "$tmp/wayland-0"
capture
resume
unchanged 'missing Wayland socket'
mv "$tmp/wayland-0" "$tmp/root/run/user/1000/wayland-0"

mkdir -p "$tmp/root/sys/bus/usb/devices/1-1/power" "$tmp/root/sys/bus/usb/devices/1-2"
printf '048d\n' >"$tmp/root/sys/bus/usb/devices/1-1/idVendor"
printf '5711\n' >"$tmp/root/sys/bus/usb/devices/1-1/idProduct"
printf '373e\n' >"$tmp/root/sys/bus/usb/devices/1-2/idVendor"
printf '001e\n' >"$tmp/root/sys/bus/usb/devices/1-2/idProduct"
SLEEP_STAGE=frozen bash "$repo/system/kwin-display-fix.sh" pre
[ "$(cat "$tmp/root/sys/bus/usb/devices/1-1/power/control")" = auto ] || fail 'USB autosuspend not enabled'
[ "$(cat "$tmp/root/sys/bus/usb/devices/1-2/authorized")" = 0 ] || fail 'USB dongle not deauthorized'
SLEEP_STAGE=frozen bash "$repo/system/kwin-display-fix.sh" post
[ "$(cat "$tmp/root/sys/bus/usb/devices/1-1/power/control")" = on ] || fail 'USB power not restored'
[ "$(cat "$tmp/root/sys/bus/usb/devices/1-2/authorized")" = 1 ] || fail 'USB dongle not reauthorized'

python3 - "$repo" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
repo = Path(sys.argv[1])
unit = ConfigParser()
unit.read(repo / 'system/kde-display-sleep.service')
assert unit['Unit']['Before'] == 'sleep.target'
assert unit['Unit']['DefaultDependencies'] == 'no'
assert unit['Unit']['StopWhenUnneeded'] == 'yes'
assert unit['Service']['Type'] == 'oneshot'
assert unit['Service']['RemainAfterExit'] == 'yes'
assert unit['Service']['RuntimeDirectoryMode'] == '0700'
assert unit['Service']['ExecStart'].endswith(' pre')
assert unit['Service']['ExecStop'].endswith(' post')
assert unit['Install']['WantedBy'] == 'sleep.target'
guard = ConfigParser()
guard.read(repo / 'system/nvidia-vram-check.service')
required_by = {'sleep.target', 'nvidia-suspend.service', 'nvidia-hibernate.service',
    'nvidia-suspend-then-hibernate.service'}
assert set(guard['Install']['RequiredBy'].split()) == required_by
assert required_by.issubset(guard['Unit']['Before'].split())
hook = (repo / 'system/kwin-display-fix.sh').read_text()
assert all(command not in hook for command in ('kscreen-doctor', 'loginctl', 'runuser', 'dbus-send'))
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    units = root / 'etc/systemd/system'
    units.mkdir(parents=True)
    for service in ('kde-display-sleep', 'nvidia-vram-check'):
        shutil.copy(repo / f'system/{service}.service', units)
        executable = root / f'usr/local/bin/{service}.sh'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
    for target in ('sleep.target', 'sysinit.target', 'basic.target', 'shutdown.target'):
        (units / target).write_text('[Unit]\nDescription=Fixture target\nDefaultDependencies=no\n')
    for name in required_by:
        if name.endswith('.service'):
            (units / name).write_text('[Unit]\nDescription=Fixture NVIDIA service\nDefaultDependencies=no\n'
                '[Service]\nType=oneshot\nExecStart=/usr/local/bin/nvidia-vram-check.sh\n')
        required = units / f'{name}.requires'
        required.mkdir()
        (required / 'nvidia-vram-check.service').symlink_to('../nvidia-vram-check.service')
    subprocess.run(['systemd-analyze', 'verify', '--man=no', f'--root={root}',
        'kde-display-sleep.service', 'nvidia-vram-check.service', 'sleep.target'], check=True)
PY
echo 'All sleep hook tests passed.'
