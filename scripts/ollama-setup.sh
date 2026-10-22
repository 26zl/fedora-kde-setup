#!/bin/bash
# Local LLM via Ollama — opt-in, about 9 GB. Reproduces the setup this repo runs on the RTX 5070:
#   - Ollama from its upstream GitHub release (Fedora's package links ROCm, useless next to NVIDIA),
#     pinned by version and SHA-256, installed to /usr/local with a hardened systemd unit
#   - gemma-4-12B-it-uncensored-heretic (an uncensored community build of Gemma on Hugging Face),
#     with a baked GPU-layer cap and context so a plain run leaves the desktop ~3 GB of VRAM
#   - Alpaca (Flatpak) as the chat GUI for Ollama, and for Strata's API if that is set up too
# Re-run after a version bump: a new Ollama fits the layers differently, so it re-tunes the model.
#
# Usage:
#   sudo bash scripts/ollama-setup.sh        # install or update, then verify
#        bash scripts/ollama-setup.sh test   # verify what is installed (no sudo)

case ${1:-} in
"") ;;
test) ;;
-h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
*) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

cd "$(dirname "$0")/.."

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

# bump both together from the release's sha256sum.txt (./ollama-linux-amd64.tar.zst)
OLLAMA_VERSION=v0.40.8
OLLAMA_SHA256=0bb17cc19e9c1339ddbe0cba55148bf068f8f19dec8ec5fd531461aaa207282a
SRC=hf.co/llmfan46/gemma-4-12B-it-uncensored-heretic-GGUF:Q4_K_M
# the GGUF layer behind that tag; a Hugging Face tag can move, so the pull is checked against it
MODEL_SHA256=0930ee39b491bfef38c2d8d843576672648b2b0460ff8bd2870a35d4f50e6735
NAME=gemma4-12b-heretic
CTX=8192
TARGET=3000          # bake the largest num_gpu that still leaves this many MiB free
PASS=2500            # a loaded model must leave at least this many MiB free to be safe
OVERHEAD=$((3 * 1024 * 1024 * 1024))
API=http://127.0.0.1:11434
OLLAMA=/usr/local/bin/ollama
DROPDIR=/etc/systemd/system/ollama.service.d

free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1; }

# load NAME at the given num_gpu and fixed context, then report the free VRAM — but only
# once the model is actually resident, so a failed load is not read as lots of free VRAM
load_free() {
    curl -fsS -m 300 "$API/api/generate" -d \
        "{\"model\":\"$NAME\",\"stream\":false,\"think\":false,\"keep_alive\":\"30s\",\"prompt\":\"hi\",\"options\":{\"num_ctx\":$CTX,\"num_gpu\":$1,\"num_predict\":1}}" >/dev/null 2>&1 || return 1
    "$OLLAMA" ps 2>/dev/null | grep -q "$NAME" || return 1
    free_mib
}

verify() {
    set +e
    echo "--- verification ---"
    echo "  ollama: $("$OLLAMA" --version 2>&1 | awk '{print $NF}')"
    "$OLLAMA" list 2>/dev/null | grep -q "$NAME" || { warn "$NAME is not installed (run with sudo first)"; return 1; }
    if systemctl show ollama -p Environment 2>/dev/null | grep -q "OLLAMA_GPU_OVERHEAD=$OVERHEAD"; then
        ok "reserve floor: OLLAMA_GPU_OVERHEAD set"
    else
        warn "reserve floor: not set (run with sudo)"
    fi
    "$OLLAMA" show "$NAME" --modelfile 2>/dev/null | grep -iE 'num_gpu|num_ctx' | sed 's/^/  baked: /'
    local free split
    free=$(load_free "$(get_baked_gpu)")
    split=$("$OLLAMA" ps | awk -v n="$NAME" '$0 ~ n {for(i=1;i<=NF;i++) if($i ~ /%\//) print $i}')
    "$OLLAMA" stop "$NAME" >/dev/null 2>&1
    echo "  processor split (CPU/GPU): ${split:-n/a}"
    if [ "${free:-0}" -ge "$PASS" ]; then ok "VRAM free with model loaded: ${free} MiB"
    else warn "VRAM free with model loaded: ${free} MiB (want >= $PASS)"; fi
    if flatpak info --system com.jeffser.Alpaca >/dev/null 2>&1; then
        ok "Alpaca: $(flatpak info --system com.jeffser.Alpaca | awk '/Version:/{print $2}')"
    else
        warn "Alpaca not installed"
    fi
}

get_baked_gpu() { "$OLLAMA" show "$NAME" --modelfile 2>/dev/null | awk '/num_gpu/{print $NF}' | head -1; }

if [ "${1:-}" = test ]; then
    command -v nvidia-smi >/dev/null || { warn "no nvidia-smi — NVIDIA driver required"; exit 1; }
    verify
    exit $?
fi

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (or 'bash $0 test' to only verify): sudo bash $0"; exit 1; }
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
# written only if absent, so a hand-tuned unit survives; the drop-ins below are always ours
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
# hardening from the directives the nixpkgs ollama module uses (9.2 UNSAFE -> 2.2 OK). The empty
# Environment= resets the installing user's $PATH that upstream's installer bakes into the unit.
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
systemctl enable --now ollama
for _ in $(seq 30); do "$OLLAMA" list >/dev/null 2>&1 && break; sleep 1; done
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
"$OLLAMA" cp "$SRC" "$NAME"

# OLLAMA_GPU_OVERHEAD alone does not hold the headroom; a baked num_gpu does. A full load leaves
# <1 GB free and freezes kscreenlocker on wake (see the Strata VRAM note in the README).
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
[ -n "$best" ] || best=${bestfree_ng:-$((blocks - 15))}
echo "  baking num_gpu=$best, num_ctx=$CTX"
printf 'FROM %s\nPARAMETER num_gpu %s\nPARAMETER num_ctx %s\n' "$NAME" "$best" "$CTX" > "$tmp/Modelfile"
"$OLLAMA" create "$NAME" -f "$tmp/Modelfile"
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
