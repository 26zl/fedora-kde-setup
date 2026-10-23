#!/bin/bash
# Local LLM via pinned Ollama and Gemma builds, with Alpaca as the GUI (~9 GB).
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
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

# Update both values from the release's sha256sum.txt (./ollama-linux-amd64.tar.zst).
OLLAMA_VERSION=v0.40.10
OLLAMA_SHA256=1e8ad2d2a394efdd235bee74deec237badd95142ffba77588140ab2a9ecec227
SRC=hf.co/llmfan46/gemma-4-12B-it-uncensored-heretic-GGUF:Q4_K_M
# The model digest guards against changes to the mutable Hugging Face tag.
MODEL_SHA256=0930ee39b491bfef38c2d8d843576672648b2b0460ff8bd2870a35d4f50e6735
NAME=gemma4-12b-heretic
CTX=8192
TARGET=3000          # bake the largest num_gpu that still leaves this many MiB free
PASS=2500            # a loaded model must leave at least this many MiB free to be safe
OVERHEAD=$((3 * 1024 * 1024 * 1024))
API=http://127.0.0.1:11434
export OLLAMA_HOST=127.0.0.1:11434
OLLAMA=/usr/local/bin/ollama
DROPDIR=/etc/systemd/system/ollama.service.d

free_mib() {
    local free
    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) || return 1
    free=${free%%$'\n'*}
    [[ $free =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Report free VRAM only after confirming the model is resident.
load_free() {
    curl -fsS -m 300 "$API/api/generate" -d \
        "{\"model\":\"$NAME\",\"stream\":false,\"think\":false,\"keep_alive\":\"30s\",\"prompt\":\"hi\",\"options\":{\"num_ctx\":$CTX,\"num_gpu\":$1,\"num_predict\":1}}" >/dev/null 2>&1 || return 1
    "$OLLAMA" ps 2>/dev/null | grep -q "$NAME" || return 1
    free_mib
}

verify() {
    local failed=0 free split baked
    echo "  ollama: $("$OLLAMA" --version 2>&1 | awk '{print $NF}')"
    "$OLLAMA" list 2>/dev/null | grep -q "$NAME" || { warn "$NAME is not installed (run with sudo first)"; return 1; }
    if systemctl show ollama -p Environment 2>/dev/null | grep -q "OLLAMA_GPU_OVERHEAD=$OVERHEAD"; then
        ok "reserve floor: OLLAMA_GPU_OVERHEAD set"
    else
        warn "reserve floor: not set (run with sudo)"
        failed=1
    fi
    baked=$(get_baked_gpu) || baked=""
    [[ $baked =~ ^[0-9]+$ ]] || { warn "model has no valid num_gpu cap"; return 1; }
    "$OLLAMA" show "$NAME" --modelfile 2>/dev/null | grep -iE 'num_gpu|num_ctx' | sed 's/^/  baked: /' || true
    free=$(load_free "$baked") || free=""
    split=$("$OLLAMA" ps 2>/dev/null | awk -v n="$NAME" '$0 ~ n {for(i=1;i<=NF;i++) if($i ~ /%\//) print $i}') || split=""
    "$OLLAMA" stop "$NAME" >/dev/null 2>&1 || { warn "could not unload $NAME"; failed=1; }
    echo "  processor split (CPU/GPU): ${split:-n/a}"
    if [ "${free:-0}" -ge "$PASS" ]; then ok "VRAM free with model loaded: ${free} MiB"
    else warn "VRAM free with model loaded: ${free:-unknown} MiB (want >= $PASS)"; failed=1; fi
    if flatpak info --system com.jeffser.Alpaca >/dev/null 2>&1; then
        ok "Alpaca: $(flatpak info --system com.jeffser.Alpaca | awk '/Version:/{print $2}')"
    else
        warn "Alpaca not installed"
        failed=1
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
    curl -fL --retry 3 -o "$tmp/ollama.tar.zst" \
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

# PrivateDevices would hide the accelerators, so allow them explicitly instead.
PrivateDevices=false
DevicePolicy=closed
DeviceAllow=char-nvidiactl rw
DeviceAllow=char-nvidia-caps rw
DeviceAllow=char-nvidia-frontend rw
DeviceAllow=char-nvidia-uvm rw
DeviceAllow=char-drm rw
DeviceAllow=char-fb rw
HARDEN
# sorts after hardening.conf, whose empty Environment= would otherwise clear this floor
printf '[Service]\nEnvironment="OLLAMA_GPU_OVERHEAD=%s"\n' "$OVERHEAD" > "$DROPDIR/vram-reserve.conf"
systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama
for _ in $(seq 30); do "$OLLAMA" list >/dev/null 2>&1 && break; sleep 1; done
"$OLLAMA" list >/dev/null 2>&1 || { warn "ollama.service did not become ready"; exit 1; }
ok "ollama.service running, hardening + VRAM reserve applied"

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
# a re-run keeps the previously tuned model until the new one is baked
previous=""
if "$OLLAMA" list 2>/dev/null | grep -q "^$NAME:"; then
    "$OLLAMA" cp "$NAME" "$NAME-previous" >/dev/null && previous="$NAME-previous"
fi
"$OLLAMA" cp "$SRC" "$NAME"

# The baked GPU layer limit reserves desktop VRAM beyond OLLAMA_GPU_OVERHEAD alone.
echo "  tuning num_gpu for >= ${TARGET} MiB free at ${CTX} context"
blocks=$(curl -s -m 30 "$API/api/show" -d "{\"model\":\"$NAME\"}" |
    jq -r '.model_info|to_entries[]|select(.key|endswith(".block_count")).value' | head -1)
{ [ -n "$blocks" ] && [ "$blocks" -gt 0 ]; } 2>/dev/null || blocks=48
best="" bestfree_ng="" bestfree_val=0
for ng in "$blocks" $((blocks - 3)) $((blocks - 6)) $((blocks - 9)) $((blocks - 12)) $((blocks - 15)); do
    [ "$ng" -ge 1 ] || continue
    free=$(load_free "$ng") || free=""
    "$OLLAMA" stop "$NAME" >/dev/null 2>&1 || true
    echo "  num_gpu=$ng -> ${free} MiB free"
    if [ "${free:-0}" -ge "$TARGET" ]; then best=$ng; break; fi
    if [ "${free:-0}" -gt "$bestfree_val" ]; then bestfree_ng=$ng; bestfree_val=$free; fi
done
if [ -z "$best" ] && [ "$bestfree_val" -ge "$PASS" ]; then
    best=$bestfree_ng
    warn "no layer count reaches ${TARGET} MiB free; using num_gpu=$best with ${bestfree_val} MiB"
fi
[ -n "$best" ] || {
    if [ -n "$previous" ]; then
        "$OLLAMA" cp "$previous" "$NAME" >/dev/null && "$OLLAMA" rm "$previous" >/dev/null 2>&1
        warn "no layer count leaves ${PASS} MiB free; the previously tuned $NAME is kept unchanged"
    else
        "$OLLAMA" rm "$NAME" >/dev/null 2>&1 || true
        warn "no layer count leaves ${PASS} MiB free; model tuning stopped"
    fi
    exit 1
}
echo "  baking num_gpu=$best, num_ctx=$CTX"
printf 'FROM %s\nPARAMETER num_gpu %s\nPARAMETER num_ctx %s\n' "$NAME" "$best" "$CTX" > "$tmp/Modelfile"
"$OLLAMA" create "$NAME" -f "$tmp/Modelfile"
[ -z "$previous" ] || "$OLLAMA" rm "$previous" >/dev/null 2>&1 || true
# only the tuned name stays listed, so a GUI cannot pick the source entry and load it uncapped
"$OLLAMA" rm "$SRC" >/dev/null 2>&1 || true
ok "$NAME tuned"

section "Alpaca (chat GUI)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --system flathub com.jeffser.Alpaca
# its bundled Ollama plugin is not wanted: the hardened system service answers on 127.0.0.1:11434
flatpak uninstall -y --system com.jeffser.Alpaca.Plugins.Ollama 2>/dev/null || true
# WebKit's DMA-BUF renderer aborts Alpaca's in-app browser on this NVIDIA/Wayland box
flatpak override --system --env=WEBKIT_DISABLE_DMABUF_RENDERER=1 com.jeffser.Alpaca
ok "Alpaca installed — add an Ollama instance at http://127.0.0.1:11434, Override Parameters off"

section "Verify"
verify
