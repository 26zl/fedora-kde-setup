#!/bin/bash
# Ollama setup: a download with the wrong hash is never installed, the drop-in carries the full
# sandbox, tuning only loads a scratch copy, an abort leaves the tuned model untouched, and Chatbox
# is installed as the user who called sudo without replacing what that user already has.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
fix="$tmp/root"
mkdir -p "$stub" "$tmp/copy/scripts" "$tmp/state"
export SAFE_LOG="$tmp/commands" FIX="$fix" STATE="$tmp/state" FIXTURE_ARCHIVE="$tmp/ollama.tar.zst"
export FIXTURE_CHATBOX="$tmp/chatbox.appimage"
fail() { echo "FAIL: $*" >&2; exit 1; }

script="$repo/scripts/ollama-setup.sh"
version=$(sed -n 's/^OLLAMA_VERSION=//p' "$script")
name=$(sed -n 's/^NAME=//p' "$script")
src=$(sed -n 's/^SRC=//p' "$script")
STUB_MODEL_SHA=$(sed -n 's/^MODEL_SHA256=//p' "$script")
chatbox_version=$(sed -n 's/^CHATBOX_VERSION=//p' "$script")
[ -n "$version" ] && [ -n "$name" ] && [ -n "$src" ] && [ -n "$STUB_MODEL_SHA" ] && [ -n "$chatbox_version" ] ||
    fail "cannot read the pins from $script"
[[ $(sed -n 's/^CHATBOX_SHA256=//p' "$script") =~ ^[0-9a-f]{64}$ ]] || fail "Chatbox has no SHA-256 pin"
export STUB_MODEL_SHA STUB_SRC=$src
tuning=$name-tuning
dropdir="$fix/etc/systemd/system/ollama.service.d"
printf 'fixture ollama archive\n' >"$FIXTURE_ARCHIVE"
printf '#!/bin/sh\necho executed >>"%s"\n' "$tmp/chatbox-executed" >"$FIXTURE_CHATBOX"

# The real script writes as root to /usr/local, /etc/systemd/system and /var/tmp; the copies write
# into the fixture tree instead and find the ollama stub on PATH.
patch_paths() {  # destination
    sed -e "s|^OLLAMA=/usr/local/bin/ollama\$|OLLAMA=ollama|" \
        -e "s|mktemp -d /var/tmp/|mktemp -d $fix/var/tmp/|" \
        -e "s|rm -rf /usr/local/lib/ollama|rm -rf $fix/usr/local/lib/ollama|" \
        -e "s|tar -xf - -C /usr/local\$|tar -xf - -C $fix/usr/local|" \
        -e "s|/etc/systemd/system|$fix/etc/systemd/system|g" "$script" >"$1"
    local want
    for want in 'OLLAMA=ollama' "mktemp -d $fix/var/tmp/" "rm -rf $fix/usr/local/lib/ollama" "-C $fix/usr/local" \
        "DROPDIR=$fix/etc/systemd/system/ollama.service.d"; do
        grep -qF -- "$want" "$1" || fail "a root path of ollama-setup.sh did not move into the fixture tree: $want"
    done
}
pinned="$tmp/copy/scripts/pinned.sh"
trusting="$tmp/copy/scripts/trusting.sh"
patch_paths "$pinned"
patch_paths "$trusting"
sed -i -e "s/^OLLAMA_SHA256=.*/OLLAMA_SHA256=$(sha256sum "$FIXTURE_ARCHIVE" | cut -d' ' -f1)/" \
    -e "s/^CHATBOX_SHA256=.*/CHATBOX_SHA256=$(sha256sum "$FIXTURE_CHATBOX" | cut -d' ' -f1)/" "$trusting"

# the model list lives in $STATE/models, a model's baked num_gpu in $STATE/baked.<name>
cat >"$stub/ollama" <<'STUB'
#!/bin/bash
printf 'ollama %s\n' "$*" >>"$SAFE_LOG"
models="$STATE/models"
touch "$models"
key() { printf '%s' "${1//\//_}"; }
case $1 in
    --version) echo "ollama version is ${STUB_VERSION:-0.0.0}" ;;
    list)
        echo 'NAME ID SIZE MODIFIED'
        while read -r m; do [[ $m == *:* ]] || m+=:latest; echo "$m 0123abcd 8.5GB now"; done <"$models" ;;
    pull | cp)
        target=${*: -1}
        grep -qxF "$target" "$models" || echo "$target" >>"$models" ;;
    show)
        if [ "$2" = "$STUB_SRC" ]; then
            echo "FROM /var/lib/ollama/models/blobs/sha256-$STUB_MODEL_SHA"
        elif [ -f "$STATE/baked.$(key "$2")" ]; then
            printf 'PARAMETER num_gpu %s\nPARAMETER num_ctx 8192\n' "$(cat "$STATE/baked.$(key "$2")")"
        fi ;;
    create)
        from=$(sed -n 's/^FROM //p' "$4")
        gpu=$(sed -n 's/^PARAMETER num_gpu //p' "$4")
        printf 'ollama-created %s from=%s num_gpu=%s\n' "$2" "$from" "$gpu" >>"$SAFE_LOG"
        grep -qxF "$2" "$models" || echo "$2" >>"$models"
        echo "$gpu" >"$STATE/baked.$(key "$2")" ;;
    rm)
        grep -vxF "$2" "$models" >"$models.new" || true
        mv "$models.new" "$models"
        command -p rm -f "$STATE/baked.$(key "$2")" ;;
    ps)
        if [ -f "$STATE/loaded" ]; then
            echo 'NAME ID SIZE PROCESSOR UNTIL'
            echo "$(cut -d' ' -f1 "$STATE/loaded"):latest 0123abcd 9GB 2%/98% 30s"
        fi ;;
    stop) command -p rm -f "$STATE/loaded" ;;
esac
exit 0
STUB
# API calls: generate loads a model, show reports its layers; ABORT_AT_LOAD=N sends the run a
# Ctrl+C (SIGINT to its process group) during the Nth load
cat >"$stub/curl" <<'STUB'
#!/bin/bash
out="" data="" url=""
while [ "$#" -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -d) data=$2; shift 2 ;;
        -m | --connect-timeout | --speed-limit | --speed-time | --retry) shift 2 ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
model=$(sed -n 's/.*"model":"\([^"]*\)".*/\1/p' <<<"$data")
case $url in
    */api/generate)
        gpu=$(sed -n 's/.*"num_gpu":\([0-9]*\).*/\1/p' <<<"$data")
        printf 'load %s num_gpu=%s\n' "$model" "$gpu" >>"$SAFE_LOG"
        count=$(($(cat "$STATE/loads" 2>/dev/null || echo 0) + 1))
        echo "$count" >"$STATE/loads"
        if [ "${ABORT_AT_LOAD:-0}" -eq "$count" ]; then
            read -r _ _ _ _ pgid _ </proc/$$/stat
            kill -INT -- "-$pgid"
        fi
        [ "${LOAD_FAIL:-no}" = no ] || exit 22
        echo "$model $gpu" >"$STATE/loaded" ;;
    */api/show)
        printf 'show %s\n' "$model" >>"$SAFE_LOG"
        echo '{"model_info":{"gemma3.block_count":48}}' ;;
    https://github.com/*)
        printf 'curl download %s\n' "$url" >>"$SAFE_LOG"
        cp "$FIXTURE_ARCHIVE" "$out" ;;
    https://download.chatboxai.app/*)
        printf 'curl download %s\n' "$url" >>"$SAFE_LOG"
        cp "$FIXTURE_CHATBOX" "$out" ;;
    *) printf 'curl %s\n' "$url" >>"$SAFE_LOG"; exit 22 ;;
esac
STUB
# free MiB for the loaded layer count from FREE_TABLE ("48:1500 45:2800 ..."), else FREE_LOADED
cat >"$stub/nvidia-smi" <<'STUB'
#!/bin/bash
[ -f "$STATE/loaded" ] || { echo 11000; exit 0; }
gpu=$(cut -d' ' -f2 "$STATE/loaded")
for pair in ${FREE_TABLE:-}; do
    [ "${pair%%:*}" != "$gpu" ] || { echo "${pair#*:}"; exit 0; }
done
echo "${FREE_LOADED:-1000}"
STUB
cat >"$stub/getent" <<'STUB'
#!/bin/bash
printf 'getent %s\n' "$*" >>"$SAFE_LOG"
case $1 in
    group) [ -f "$STATE/group" ] ;;
    passwd)
        # GUI_USER is the account that called sudo; every other lookup is the ollama service user
        if [ -n "${GUI_USER-}" ] && [ "$2" = "$GUI_USER" ]; then
            echo "$2:x:1000:1000::$FIX/home/$2:/bin/bash"
            exit 0
        fi
        [ -f "$STATE/home" ] || exit 2; echo "ollama:x:957:957::$(cat "$STATE/home"):/sbin/nologin" ;;
    *) exit 2 ;;
esac
STUB
cat >"$stub/useradd" <<'STUB'
#!/bin/bash
printf 'useradd %s\n' "$*" >>"$SAFE_LOG"
while [ "$#" -gt 0 ]; do case $1 in -d) echo "$2" >"$STATE/home"; shift 2 ;; *) shift ;; esac; done
STUB
cat >"$stub/groupadd" <<'STUB'
#!/bin/bash
printf 'groupadd %s\n' "$*" >>"$SAFE_LOG"
: >"$STATE/group"
STUB
cat >"$stub/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$SAFE_LOG"
[ "$1" != show ] || sed -n 's/^Environment="\(.*\)"$/Environment=\1/p' "$FIX/etc/systemd/system/ollama.service.d/vram-reserve.conf"
exit 0
STUB
cat >"$stub/zstd" <<'STUB'
#!/bin/bash
printf 'zstd %s\n' "$*" >>"$SAFE_LOG"
cat "${@: -1}"
STUB
cat >"$stub/tar" <<'STUB'
#!/bin/bash
printf 'tar %s\n' "$*" >>"$SAFE_LOG"
dir=${*: -1}
case $dir in "$FIX"/*) ;; *) echo "tar stub: refusing to extract outside the fixture: $dir" >&2; exit 1 ;; esac
cat >/dev/null
mkdir -p "$dir/lib/ollama" && : >"$dir/lib/ollama/extracted"
STUB
cat >"$stub/rm" <<'STUB'
#!/bin/bash
printf 'rm %s\n' "$*" >>"$SAFE_LOG"
for arg in "$@"; do
    case $arg in
        -*) ;;
        "$FIX"/*) command -p rm -rf -- "$arg" ;;
        *) echo "rm stub: refusing $arg" >&2; exit 1 ;;
    esac
done
STUB
cat >"$stub/flatpak" <<'STUB'
#!/bin/bash
printf 'flatpak %s\n' "$*" >>"$SAFE_LOG"
[ "$1" != info ] || [ "${ALPACA:-absent}" = installed ]
STUB
cat >"$stub/runuser" <<'STUB'
#!/bin/bash
[ "$1" = -u ] && [ "$3" = -- ] || { echo "runuser stub: unexpected arguments: $*" >&2; exit 1; }
printf 'runuser %s\n' "$2" >>"$SAFE_LOG"
shift 3
exec "$@"
STUB
cat >"$stub/journalctl" <<'STUB'
#!/bin/bash
echo 'level=INFO msg="inference compute" id=0 library=CUDA name=CUDA0'
STUB
cat >"$stub/id" <<'STUB'
#!/bin/bash
[ "$1" = -u ] && echo "${STUB_UID:-0}"
STUB
cat >"$stub/uname" <<'STUB'
#!/bin/bash
echo x86_64
STUB
cat >"$stub/dnf" <<'STUB'
#!/bin/bash
printf 'dnf %s\n' "$*" >>"$SAFE_LOG"
STUB
cat >"$stub/install" <<'STUB'
#!/bin/bash
printf 'install %s\n' "$*" >>"$SAFE_LOG"
STUB
printf '#!/bin/bash\nexit 1\n' >"$stub/pgrep"
printf '#!/bin/bash\nexit 0\n' >"$stub/sleep"
printf '#!/bin/bash\nexit 0\n' >"$stub/logger"
chmod +x "$stub"/*

fresh() {  # an empty fixture system and a stub state without models or users
    find "$fix" "$STATE" -mindepth 1 -delete 2>/dev/null || true
    mkdir -p "$fix/var/tmp" "$fix/usr/local" "$fix/etc/systemd/system"
}
existing_user() {  # home
    echo "$1" >"$STATE/home"
    : >"$STATE/group"
}
run() {  # expected-exit|fail copy; a new session, so a stubbed Ctrl+C reaches only this run
    local want=$1 rc
    : >"$SAFE_LOG"
    output=$(PATH="$stub:$PATH" NO_COLOR=1 SUDO_USER="${GUI_USER-}" setsid -w bash "$2" </dev/null 2>&1) && rc=0 || rc=$?
    if [ "$want" = fail ]; then
        [ "$rc" -ne 0 ] || fail "exit 0, want a failure ($output)"
    else
        [ "$rc" -eq "$want" ] || fail "exit $rc, want $want ($output)"
    fi
}
line_of() { grep -nE -m1 "$1" "$SAFE_LOG" | cut -d: -f1; }
# every ollama command that writes the name the GUI loads
name_writes() { grep -E "^ollama (cp [^ ]+ $name|pull $name|create $name|rm $name)( |$)" "$SAFE_LOG" || true; }

fresh
STUB_UID=1000 run 1 "$trusting"
[[ $output == *"run with sudo"* ]] || fail "no refusal for a non-root run"
[ ! -s "$SAFE_LOG" ] || fail "a non-root run went on to: $(head -n 1 "$SAFE_LOG")"

fresh
run 1 "$pinned"
grep -qx "curl download https://github.com/ollama/ollama/releases/download/$version/ollama-linux-amd64.tar.zst" "$SAFE_LOG" ||
    fail "the pinned release was not downloaded"
! grep -qE '^(zstd|tar|systemctl stop|rm .*/lib/ollama)' "$SAFE_LOG" || fail "a download with the wrong hash was installed"
[ ! -e "$fix/usr/local/lib/ollama/extracted" ] && [ ! -e "$dropdir" ] || fail "a download with the wrong hash changed the system"

fresh
FREE_TABLE="48:1500 45:2800 42:3200" run 0 "$trusting"
[[ $output != *refusing* ]] || fail "a stub was asked to touch a path outside the fixture: $output"
download=$(line_of '^curl download ') stop=$(line_of '^systemctl stop ollama') stale=$(line_of '^rm -rf .*/usr/local/lib/ollama$')
unpack=$(line_of '^zstd -dc ')
[ -n "$download" ] && [ -n "$stop" ] && [ -n "$stale" ] && [ -n "$unpack" ] &&
    [ "$download" -lt "$stop" ] && [ "$stop" -lt "$stale" ] && [ "$stale" -lt "$unpack" ] ||
    fail "the checked download was not installed in order: download, stop, stale libraries, unpack"
grep -qx "tar -xf - -C $fix/usr/local" "$SAFE_LOG" && [ -e "$fix/usr/local/lib/ollama/extracted" ] ||
    fail "a download with the right hash was not extracted into the prefix"
grep -q '^useradd .*-d /var/lib/ollama ' "$SAFE_LOG" || fail "the ollama user was not created with /var/lib/ollama"
for line in PrivateTmp=true PrivateUsers=true 'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX' UMask=0077 \
            'DeviceAllow=char-nvidia-uvm rwm'; do
    grep -qxF "$line" "$dropdir/hardening.conf" || fail "the hardening drop-in lacks $line"
done
grep -qx 'ReadWritePaths=/var/lib/ollama' "$dropdir/hardening.conf" || fail "the hardening drop-in lost its data directory"
[ "$(grep -c '^ReadWritePaths=' "$dropdir/hardening.conf")" -eq 1 ] || fail "a user homed in /var/lib/ollama got extra ReadWritePaths"
grep -qx "ollama cp $src $tuning" "$SAFE_LOG" || fail "the source model was not copied to $tuning"
created=$(line_of '^ollama-created ')
[ -n "$created" ] || fail "no model was baked"
grep -qx "ollama-created $name from=$tuning num_gpu=42" "$SAFE_LOG" || fail "$name was not baked from $tuning at the first fit"
head -n "$created" "$SAFE_LOG" | grep -q '^load ' || fail "nothing was loaded during tuning"
bad=$(head -n "$created" "$SAFE_LOG" | grep '^load ' | grep -v "^load $tuning " || true)
[ -z "$bad" ] || fail "tuning loaded something other than $tuning: $bad"
writes=$(name_writes)
[ "$(grep -c . <<<"$writes")" -eq 1 ] && [[ $writes == "ollama create $name -f "*/Modelfile ]] ||
    fail "$name was written by something other than the final create: $writes"
removed=$(line_of "^ollama rm $tuning\$")
[ -n "$removed" ] && [ "$removed" -gt "$created" ] || fail "$tuning was not removed after the bake"
[ "$(cat "$STATE/models")" = "$name" ] || fail "the model list after tuning is not just $name: $(tr '\n' ' ' <"$STATE/models")"

fresh
existing_user /usr/share/ollama
STUB_VERSION=${version#v} FREE_TABLE="48:3500" run 0 "$pinned"
grep -qx 'ReadWritePaths=/usr/share/ollama' "$dropdir/hardening.conf" || fail "the home of an upstream-created user stayed read-only"
! grep -q '^useradd' "$SAFE_LOG" || fail "an existing ollama user was created again"
! grep -qE '^(curl download|zstd|tar)' "$SAFE_LOG" || fail "the installed version was downloaded again"

fresh
existing_user /var/lib/ollama
STUB_VERSION=${version#v} LOAD_FAIL=yes run 1 "$pinned"
[[ $output == *"model tuning stopped"* ]] || fail "missing no-fit diagnostic"
grep -q "^load $tuning " "$SAFE_LOG" || fail "the no-fit run never tried a load"
! grep -q '^ollama-created ' "$SAFE_LOG" || fail "a model was baked without a fit"
grep -qx "ollama rm $tuning" "$SAFE_LOG" || fail "$tuning was left after a no-fit exit"
! grep -qxF "$tuning" "$STATE/models" || fail "$tuning is still listed after a no-fit exit"
! grep -qxF "$name" "$STATE/models" || fail "an uncapped model was left under $name"

# a tuned model from an earlier run must survive a re-run that finds no fit, and one that is aborted
for abort in 0 2; do
    fresh
    existing_user /var/lib/ollama
    printf '%s\n' "$name" >"$STATE/models"
    echo 30 >"$STATE/baked.$name"
    STUB_VERSION=${version#v} FREE_LOADED=1000 ABORT_AT_LOAD=$abort run fail "$pinned"
    if [ "$abort" -eq 0 ]; then
        [[ $output == *"previously tuned $name is kept unchanged"* ]] || fail "missing kept-model diagnostic"
    else
        [ "$(grep -c '^load ' "$SAFE_LOG")" -eq "$abort" ] || fail "the run went on after Ctrl+C during load $abort"
    fi
    [ -z "$(name_writes)" ] || fail "$name was written by a run without a fit (abort at load $abort): $(name_writes)"
    grep -qxF "$name" "$STATE/models" && [ "$(cat "$STATE/baked.$name")" = 30 ] ||
        fail "the tuned $name changed (abort at load $abort)"
    grep -qx "ollama rm $tuning" "$SAFE_LOG" || fail "$tuning was left behind (abort at load $abort)"
    ! grep -qxF "$tuning" "$STATE/models" || fail "$tuning is still listed (abort at load $abort)"
done

# Chatbox: installed as the user who called sudo, from a checked download, without running it.
export GUI_USER=tester
gui_home="$fix/home/$GUI_USER"
chatbox="$gui_home/Applications/Chatbox-x86_64.AppImage"
entry="$gui_home/.local/share/applications/xyz.chatboxapp.app.desktop"
config="$gui_home/.config/xyz.chatboxapp.app/config.json"
installed_run() {  # expected-exit copy: Ollama is current, so the run goes straight to tuning and the GUI
    existing_user /var/lib/ollama
    STUB_VERSION=${version#v} FREE_TABLE="48:3500" run "$1" "$2"
}
fresh
mkdir -p "$gui_home"
installed_run 0 "$trusting"
grep -qx "curl download https://download.chatboxai.app/releases/Chatbox-$chatbox_version-x86_64.AppImage" "$SAFE_LOG" ||
    fail "the pinned Chatbox build was not downloaded"
grep -qx "runuser $GUI_USER" "$SAFE_LOG" || fail "Chatbox was not installed as the user who called sudo"
cmp -s "$FIXTURE_CHATBOX" "$chatbox" && [ -x "$chatbox" ] || fail "Chatbox was not installed unchanged and executable"
grep -qxF "Exec=\"$chatbox\" %U" "$entry" || fail "the menu entry does not start the AppImage"
grep -q '"allowReportingAndTracking": false' "$config" || fail "a new Chatbox configuration leaves reporting on"
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$config" || fail "the Chatbox configuration is not valid JSON"
[ -z "$(find "$gui_home/Applications" -mindepth 1 -name '.chatbox.*')" ] || fail "the Chatbox download left its staging folder"
grep -qxF "  ✓ Chatbox: $chatbox" <<<"$output" || fail "the verification did not find Chatbox"
[[ $output != *"Alpaca from an earlier version"* ]] || fail "an Alpaca that is not installed was reported"

# the read-only test, run by that user without sudo, finds Chatbox or fails without it
verify_only() {  # expected-exit
    local rc
    : >"$SAFE_LOG"
    output=$(PATH="$stub:$PATH" NO_COLOR=1 STUB_UID=1000 USER="$GUI_USER" SUDO_USER="" FREE_TABLE="48:3500" \
        setsid -w bash "$trusting" test </dev/null 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq "$1" ] || fail "the read-only test exited $rc, want $1 ($output)"
}
verify_only 0
grep -qxF "  ✓ Chatbox: $chatbox" <<<"$output" || fail "the read-only test did not find Chatbox"
! grep -qE '^(runuser|curl download)' "$SAFE_LOG" || fail "the read-only test installed something"
mv "$chatbox" "$chatbox.away"
verify_only 1
[[ $output == *"Chatbox not installed"* ]] || fail "the read-only test passed without Chatbox"
mv "$chatbox.away" "$chatbox"

# a later run keeps the AppImage, the menu entry and the configuration it finds
printf 'a newer build\n' >"$chatbox"
printf 'an edited entry\n' >"$entry"
printf '{"settings":{"allowReportingAndTracking":true}}\n' >"$config"
installed_run 0 "$trusting"
! grep -q '^curl download https://download.chatboxai.app/' "$SAFE_LOG" || fail "an installed Chatbox was downloaded again"
[ "$(cat "$chatbox")" = 'a newer build' ] || fail "an installed Chatbox was replaced by the pinned build"
[ "$(cat "$entry")" = 'an edited entry' ] || fail "an existing menu entry was rewritten"
grep -q '"allowReportingAndTracking":true' "$config" || fail "an existing Chatbox configuration was changed"

# a download that misses the pin is not installed, and nothing is left for a later run to trust
fresh
mkdir -p "$gui_home"
installed_run fail "$pinned"
grep -q '^curl download https://download.chatboxai.app/' "$SAFE_LOG" || fail "the run with a wrong Chatbox hash never downloaded it"
[ ! -e "$chatbox" ] && [ ! -e "$entry" ] && [ ! -e "$config" ] || fail "a Chatbox download with the wrong hash was installed"
[ -z "$(find "$gui_home" -mindepth 1 -name '.chatbox.*')" ] || fail "a rejected Chatbox download left its staging folder"

# an Alpaca left by an earlier version of the script is named, not removed
fresh
mkdir -p "$gui_home"
ALPACA=installed installed_run 0 "$trusting"
[[ $output == *"Alpaca from an earlier version of this script is still installed"* ]] || fail "an Alpaca left by an earlier version went unmentioned"
! grep -qE '^flatpak (uninstall|install|override)' "$SAFE_LOG" || fail "the setup installed, changed or removed a Flatpak"

# as plain root there is no desktop user: nothing is installed, and the run still passes
unset GUI_USER
fresh
installed_run 0 "$pinned"
[[ $output == *"Chatbox not installed: run this script with sudo from your own account"* ]] || fail "no notice about the missing desktop user"
! grep -qE '^(runuser|curl download https://download.chatboxai.app/)' "$SAFE_LOG" || fail "Chatbox was installed without a desktop user"
[ ! -e "$tmp/chatbox-executed" ] || fail "the downloaded Chatbox AppImage was executed during setup"
echo "All Ollama setup tests passed."
