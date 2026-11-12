#!/bin/bash
# Local LLM via pinned Ollama and Gemma builds, with Chatbox as the GUI (~9 GB).
# Installs a hardened system service and tunes the model to reserve desktop VRAM.
#
# Usage:
#   sudo bash scripts/ollama-setup.sh        # install or update, then verify
#        bash scripts/ollama-setup.sh test   # verify what is installed (no sudo)

[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1:-} in
"") ;;
test) ;;
-h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
*) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

cd "$(dirname "$0")/.." || exit 1

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi
# interactive runs also leave these lines in the journal: journalctl -t fedora-kde-setup
journal() { [ ! -t 1 ] || logger -t fedora-kde-setup -- "${0##*/}: $*" 2>/dev/null || true; }
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; journal "ok: $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; journal "warning: $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; journal "$1"; }

# Update both values from the release's sha256sum.txt (./ollama-linux-amd64.tar.zst).
OLLAMA_VERSION=v0.40.15
OLLAMA_SHA256=628c018404a4206493efd38e46251c154ede5141b8b8dc85c659b3b027c47379
SRC=hf.co/llmfan46/gemma-4-12B-it-uncensored-heretic-GGUF:Q4_K_M
# The model digest guards against changes to the mutable Hugging Face tag.
MODEL_SHA256=0930ee39b491bfef38c2d8d843576672648b2b0460ff8bd2870a35d4f50e6735
# Chatbox lists the AppImage's SHA-512 in https://download.chatboxai.app/releases/latest-linux.yml;
# this is the SHA-256 of the file that matched it. Update both values together.
CHATBOX_VERSION=1.24.4
CHATBOX_SHA256=34641898feadf7edc517312412b98dd5ee7276a7d0408be2e64bb5ff00d3e43d
CHATBOX_APP=Applications/Chatbox-x86_64.AppImage
NAME=gemma4-12b-heretic
CTX=16384            # 8192 overflows once a tool returns a pasted file; Ollama then drops the oldest message
TARGET=3000          # bake the largest num_gpu that still leaves this many MiB free
PASS=2500            # a loaded model must leave at least this many MiB free to be safe
OVERHEAD=$((3 * 1024 * 1024 * 1024))
API=http://127.0.0.1:11434
export OLLAMA_HOST=127.0.0.1:11434
OLLAMA=/usr/local/bin/ollama
DROPDIR=/etc/systemd/system/ollama.service.d

# the home of the desktop user: whoever called sudo, or the one running the read-only test
desktop_home() {
    local user=${SUDO_USER:-}
    [ -n "$user" ] || [ "$(id -u)" -eq 0 ] || user=${USER:-}
    [ -n "$user" ] && [ "$user" != root ] || return 1
    getent passwd "$user" | cut -d: -f6
}

free_mib() {
    local free
    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) || return 1
    free=${free%%$'\n'*}
    [[ $free =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Report free VRAM only after confirming the model is resident.
load_free() {  # num_gpu model
    curl -fsS -m 300 "$API/api/generate" -d \
        "{\"model\":\"$2\",\"stream\":false,\"think\":false,\"keep_alive\":\"30s\",\"prompt\":\"hi\",\"options\":{\"num_ctx\":$CTX,\"num_gpu\":$1,\"num_predict\":1}}" >/dev/null 2>&1 || return 1
    "$OLLAMA" ps 2>/dev/null | grep -q "$2" || return 1
    free_mib
}

verify() {
    local failed=0 free split baked backend home
    echo "  ollama: $("$OLLAMA" --version 2>&1 | awk '{print $NF}')"
    "$OLLAMA" list 2>/dev/null | grep -q "$NAME" || { warn "$NAME is not installed (run with sudo first)"; return 1; }
    if systemctl show ollama -p Environment 2>/dev/null | grep -q "OLLAMA_GPU_OVERHEAD=$OVERHEAD"; then
        ok "reserve floor: OLLAMA_GPU_OVERHEAD set"
    else
        warn "reserve floor: not set (run with sudo)"
        failed=1
    fi
    if systemctl show ollama -p Environment 2>/dev/null | grep -qE 'OLLAMA_MAX_LOADED_MODELS=1( |$)'; then
        ok "one model at a time: OLLAMA_MAX_LOADED_MODELS set"
    else
        warn "one model at a time: not set (run with sudo)"
        failed=1
    fi
    backend=$(journalctl -u ollama -b -o cat 2>/dev/null | grep -o 'msg="inference compute".*' | tail -n 1 |
        grep -o 'library=[A-Za-z0-9]*') || backend=""
    if [ "$backend" = library=CUDA ]; then
        ok "compute: CUDA"
    else
        warn "compute: ${backend:-no GPU found} (want library=CUDA; see nvidia-uvm.conf)"
        failed=1
    fi
    baked=$(get_baked_gpu) || baked=""
    [[ $baked =~ ^[0-9]+$ ]] || { warn "model has no valid num_gpu cap"; return 1; }
    "$OLLAMA" show "$NAME" --modelfile 2>/dev/null | grep -iE 'num_gpu|num_ctx' | sed 's/^/  baked: /' || true
    free=$(load_free "$baked" "$NAME") || free=""
    split=$("$OLLAMA" ps 2>/dev/null | awk -v n="$NAME" '$0 ~ n {for(i=1;i<=NF;i++) if($i ~ /%\//) print $i}') || split=""
    "$OLLAMA" stop "$NAME" >/dev/null 2>&1 || { warn "could not unload $NAME"; failed=1; }
    echo "  processor split (CPU/GPU): ${split:-n/a}"
    if [ "${free:-0}" -ge "$PASS" ]; then ok "VRAM free with model loaded: ${free} MiB"
    else warn "VRAM free with model loaded: ${free:-unknown} MiB (want >= $PASS)"; failed=1; fi
    # a run as plain root has no desktop user, so there is nothing to look for
    if home=$(desktop_home) && [ -n "$home" ]; then
        if [ -x "$home/$CHATBOX_APP" ]; then
            ok "Chatbox: $home/$CHATBOX_APP"
        else
            warn "Chatbox not installed (run with sudo from your own account)"
            failed=1
        fi
    fi
    return "$failed"
}

get_baked_gpu() { "$OLLAMA" show "$NAME" --modelfile 2>/dev/null | awk '/num_gpu/{print $NF}' | head -1; }

if [ "${1:-}" = test ]; then
    command -v nvidia-smi >/dev/null || { warn "no nvidia-smi — NVIDIA driver required"; exit 1; }
    verify
    exit $?
fi

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (or 'bash $0 test' to only verify): sudo bash $0"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { warn "the pinned Ollama build requires x86_64"; exit 1; }
command -v nvidia-smi >/dev/null || { warn "no nvidia-smi — this setup targets an NVIDIA card"; exit 1; }
tmp=$(mktemp -d /var/tmp/ollama-setup.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

section "Dependencies"
dnf install -y jq zstd
ok "jq, zstd"

section "Ollama $OLLAMA_VERSION (upstream)"
if "$OLLAMA" --version 2>/dev/null | grep -q "version is ${OLLAMA_VERSION#v}$"; then
    ok "already installed"
else
    curl -fL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 -o "$tmp/ollama.tar.zst" \
        "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/ollama-linux-amd64.tar.zst"
    echo "$OLLAMA_SHA256  $tmp/ollama.tar.zst" | sha256sum -c -
    systemctl stop ollama 2>/dev/null || true
    rm -rf /usr/local/lib/ollama          # stale runner libraries, as upstream's install.sh does
    zstd -dc "$tmp/ollama.tar.zst" | tar -xf - -C /usr/local
    ok "installed to /usr/local"
fi

# the data dir must sit under the hardening drop-in's ReadWritePaths (ProtectSystem=strict)
getent group ollama >/dev/null || groupadd -r ollama
getent passwd ollama >/dev/null || useradd -r -g ollama -d /var/lib/ollama -s /sbin/nologin ollama
install -d -o ollama -g ollama /var/lib/ollama
# upstream's install.sh creates the user with its key and models in /usr/share/ollama
ollama_home=$(getent passwd ollama | cut -d: -f6)

section "Hardened + VRAM-capped systemd unit"
# Preserve a hand-tuned base unit while managing the setup's drop-ins.
if [ ! -f /etc/systemd/system/ollama.service ]; then
    cat > /etc/systemd/system/ollama.service <<'UNIT'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT
fi
mkdir -p "$DROPDIR"
# Reset inherited unit environment before applying the service's controlled PATH.
cat > "$DROPDIR/hardening.conf" <<'HARDEN'
[Service]
Environment=
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

CapabilityBoundingSet=
LockPersonality=true
MemoryDenyWriteExecute=true
NoNewPrivileges=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ReadWritePaths=/var/lib/ollama
RemoveIPC=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
SystemCallFilter=@system-service @resources
SystemCallFilter=~@privileged
PrivateTmp=true
PrivateUsers=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077

# PrivateDevices would hide the accelerators, so allow them explicitly instead.
PrivateDevices=false
DevicePolicy=closed
DeviceAllow=char-nvidiactl rw
DeviceAllow=char-nvidia-caps rw
DeviceAllow=char-nvidia-frontend rw
# m: nvidia-uvm.conf's pre-command creates /dev/nvidia-uvm from inside this cgroup, where the device filter applies
DeviceAllow=char-nvidia-uvm rwm
DeviceAllow=char-drm rw
DeviceAllow=char-fb rw
HARDEN
case $ollama_home in /var/lib/ollama | / | "") ;; *) printf 'ReadWritePaths=%s\n' "$ollama_home" >>"$DROPDIR/hardening.conf" ;; esac
# sorts after hardening.conf, whose empty Environment= would otherwise clear this floor
printf '[Service]\nEnvironment="OLLAMA_GPU_OVERHEAD=%s"\n' "$OVERHEAD" > "$DROPDIR/vram-reserve.conf"
# with num_gpu baked, a second model is started beside the loaded one, fails with cudaMalloc and is retried
printf '[Service]\nEnvironment="OLLAMA_MAX_LOADED_MODELS=1"\n' > "$DROPDIR/single-model.conf"
# Without this CUDA falls back to Vulkan: DeviceAllow= resolves char-nvidia-uvm when the unit starts,
# and NoNewPrivileges stops libcuda's setuid nvidia-modprobe from loading it and creating /dev/nvidia-uvm.
# The + prefix lifts the per-process sandbox, not the cgroup's device filter, hence the m above.
cat > "$DROPDIR/nvidia-uvm.conf" <<'UVM'
[Unit]
Wants=modprobe@nvidia_uvm.service
After=modprobe@nvidia_uvm.service

[Service]
ExecStartPre=-+/usr/bin/nvidia-modprobe -c0 -u
UVM
systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama
for _ in $(seq 30); do "$OLLAMA" list >/dev/null 2>&1 && break; sleep 1; done
"$OLLAMA" list >/dev/null 2>&1 || { warn "ollama.service did not become ready"; exit 1; }
ok "ollama.service running, hardening, VRAM reserve, one-model limit and nvidia-uvm applied"

section "Model: $NAME"
if pgrep -f '^ollama pull' >/dev/null; then
    warn "waiting up to an hour for a running ollama pull to finish"
    for _ in $(seq 240); do pgrep -f '^ollama pull' >/dev/null || break; sleep 15; done
    pgrep -f '^ollama pull' >/dev/null && { warn "a pull is still running; try again later"; exit 1; }
fi
"$OLLAMA" pull "$SRC"
modelfile=$("$OLLAMA" show "$SRC" --modelfile 2>/dev/null || true)
[[ $modelfile == *"sha256-$MODEL_SHA256"* ]] ||
    { warn "$SRC is not the pinned build; update MODEL_SHA256 if the change is intended"; exit 1; }
# tuning loads an uncapped scratch copy, so an abort never leaves $NAME without its cap
tuning=$NAME-tuning
trap 'rm -rf "$tmp"; "$OLLAMA" rm "$tuning" >/dev/null 2>&1 || true' EXIT
"$OLLAMA" cp "$SRC" "$tuning"

# The baked GPU layer limit reserves desktop VRAM beyond OLLAMA_GPU_OVERHEAD alone.
echo "  tuning num_gpu for >= ${TARGET} MiB free at ${CTX} context"
blocks=$(curl -s -m 30 "$API/api/show" -d "{\"model\":\"$tuning\"}" |
    jq -r '.model_info|to_entries[]|select(.key|endswith(".block_count")).value' | head -1) || blocks=""
{ [ -n "$blocks" ] && [ "$blocks" -gt 0 ]; } 2>/dev/null || blocks=48
best="" bestfree_ng="" bestfree_val=0
for ng in "$blocks" $((blocks - 3)) $((blocks - 6)) $((blocks - 9)) $((blocks - 12)) $((blocks - 15)); do
    [ "$ng" -ge 1 ] || continue
    free=$(load_free "$ng" "$tuning") || free=""
    "$OLLAMA" stop "$tuning" >/dev/null 2>&1 || true
    echo "  num_gpu=$ng -> ${free} MiB free"
    if [ "${free:-0}" -ge "$TARGET" ]; then best=$ng; break; fi
    if [ "${free:-0}" -gt "$bestfree_val" ]; then bestfree_ng=$ng; bestfree_val=$free; fi
done
if [ -z "$best" ] && [ "$bestfree_val" -ge "$PASS" ]; then
    best=$bestfree_ng
    warn "no layer count reaches ${TARGET} MiB free; using num_gpu=$best with ${bestfree_val} MiB"
fi
[ -n "$best" ] || {
    if "$OLLAMA" list 2>/dev/null | grep -q "^$NAME:"; then
        warn "no layer count leaves ${PASS} MiB free; the previously tuned $NAME is kept unchanged"
    else
        warn "no layer count leaves ${PASS} MiB free; model tuning stopped"
    fi
    exit 1
}
echo "  baking num_gpu=$best, num_ctx=$CTX"
printf 'FROM %s\nPARAMETER num_gpu %s\nPARAMETER num_ctx %s\n' "$tuning" "$best" "$CTX" > "$tmp/Modelfile"
"$OLLAMA" create "$NAME" -f "$tmp/Modelfile"
"$OLLAMA" rm "$tuning" >/dev/null 2>&1 || true
# only the tuned name stays listed, so a GUI cannot pick the source entry and load it uncapped
"$OLLAMA" rm "$SRC" >/dev/null 2>&1 || true
ok "$NAME tuned"

section "Chatbox (chat GUI)"
# Run as the user who called sudo, not as root: the AppImage replaces itself when it updates, and none of this
# needs privileges. A copy that is already there stays: a newer build's settings may not load in the pinned one.
chatbox_setup=$(cat <<'CHATBOX'
set -euo pipefail
app="$HOME/$3"
if [ ! -e "$app" ]; then
    mkdir -p "${app%/*}"
    staging=$(mktemp -d "${app%/*}/.chatbox.XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    curl -fL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 -o "$staging/Chatbox.AppImage" \
        "https://download.chatboxai.app/releases/Chatbox-$1-x86_64.AppImage"
    printf '%s  %s\n' "$2" "$staging/Chatbox.AppImage" | sha256sum -c --quiet -
    chmod 755 "$staging/Chatbox.AppImage"
    mv -fT "$staging/Chatbox.AppImage" "$app"
fi
entry="$HOME/.local/share/applications/xyz.chatboxapp.app.desktop"
if [ ! -e "$entry" ]; then
    mkdir -p "${entry%/*}"
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Chatbox' 'GenericName=AI chat client' \
        'Comment=Chat with the local Ollama models' "Exec=\"$app\" %U" 'Icon=dialog-messages' 'Terminal=false' \
        'Categories=Utility;' 'StartupWMClass=Chatbox' >"$entry"
fi
# Chatbox reports usage and crashes unless its configuration says otherwise; an existing one is the user's own
config="$HOME/.config/xyz.chatboxapp.app/config.json"
if [ ! -e "$config" ]; then
    mkdir -p "${config%/*}"
    printf '{\n\t"settings": {\n\t\t"allowReportingAndTracking": false\n\t}\n}\n' >"$config"
fi
CHATBOX
)
if home=$(desktop_home) && [ -d "$home" ]; then
    runuser -u "$SUDO_USER" -- env HOME="$home" \
        bash -c "$chatbox_setup" chatbox "$CHATBOX_VERSION" "$CHATBOX_SHA256" "$CHATBOX_APP"
    ok "Chatbox: $home/$CHATBOX_APP, in the menu — Settings → Model Provider → Ollama, then Fetch"
else
    warn "Chatbox not installed: run this script with sudo from your own account"
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info --system com.jeffser.Alpaca >/dev/null 2>&1; then
    warn "Alpaca from an earlier version of this script is still installed and no longer used here:"
    warn "flatpak uninstall com.jeffser.Alpaca removes it (--delete-data also drops its chats)"
fi

section "Verify"
verify
