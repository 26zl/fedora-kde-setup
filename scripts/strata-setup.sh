#!/bin/bash
# Local LLM: Strata runs Qwen3.8-Flash-Next on the NVIDIA card plus system RAM.
# Opt-in — about 85 GB of model files and a one-time engine compile.

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e
[ "$EUID" -ne 0 ] || { echo "Run without sudo: bash scripts/strata-setup.sh" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "Strata's CUDA packages require x86_64" >&2; exit 1; }
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

STRATA_REV=7ddc17a38fe7f31637e895ecfba58c2cd43d65ec  # v0.2.3.1
STRATA_DIR=${STRATA_DIR:-$HOME/Prosjekter/Strata}
# not under /home: snapper would keep the model files in every snapshot
STRATA_DATA=${STRATA_DATA:-/mnt/data/Strata-data}

hw_has_gpu 10de || { warn "Strata's CUDA engine needs an NVIDIA GPU"; exit 1; }
if [ -d "$STRATA_DIR/.git" ]; then
    [ "$(git -C "$STRATA_DIR" rev-parse HEAD)" = "$STRATA_REV" ] ||
        { warn "$STRATA_DIR is not at pinned revision $STRATA_REV; review the checkout before retrying"; exit 1; }
    git -C "$STRATA_DIR" diff --quiet HEAD -- ||
        { warn "$STRATA_DIR has tracked changes; review them before running pinned setup code"; exit 1; }
fi
mkdir -p "$STRATA_DATA" 2>/dev/null ||
    { warn "Cannot create $STRATA_DATA — mount the data disk or set STRATA_DATA"; exit 1; }

section "CUDA toolkit"
# The engine is compiled from the pinned commit (--build below): 0.2's ready-made engines are checked
# only against a hash from the same GitHub release. NVIDIA's repo lags Fedora releases and its
# packages carry no dist tag, so fedora44 keeps working after an upgrade
[ -f /etc/yum.repos.d/cuda-fedora44.repo ] ||
    sudo dnf config-manager addrepo \
        --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo
# NVIDIA's own driver packages in this repo replace RPM Fusion's driver or collide with its
# files; this is the exclude list from rpmfusion.org/Howto/CUDA
sudo dnf config-manager setopt 'cuda-fedora44-x86_64.exclude=nvidia-driver*,cuda-drivers*,nvidia-modprobe,nvidia-persistenced,nvidia-settings,nvidia-libXNVCtrl*,nvidia-xconfig,nvidia-open,nvidia-imex,nvidia-kmod-common,libnvidia-fbc,kmod-nvidia-*-dkms,nvidia-fs*,nvidia-gds*,xorg-x11-nvidia*'
sudo dnf install -y cuda-toolkit-13-4 gcc-c++ git
ok "CUDA 13.4 toolkit (NVIDIA repo), gcc-c++, git"

section "Strata checkout"
if [ ! -d "$STRATA_DIR/.git" ]; then
    git clone -q --filter=blob:none https://github.com/Niko1221/Strata.git "$STRATA_DIR"
    # Only a newly created checkout may be reset without discarding user changes.
    git -C "$STRATA_DIR" reset -q --hard "$STRATA_REV"
fi
ok "$STRATA_DIR at $(git -C "$STRATA_DIR" describe --tags --always)"

section "Model and engine"
# the full model needs ~48 GB of RAM; the Coder keeps half the experts and fits 32 GB
family=qwen
[ "$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)" -lt 40 ] && family=coder
# Reserve VRAM for the desktop; experimental speed projection applies the refusal-direction vector.
# --build compiles the pinned source instead of fetching a ready-made engine; pictures stay off (text-only Coder).
"$STRATA_DIR/setup.sh" --yes --family "$family" --no-start --data-dir "$STRATA_DATA" \
    --vram-reserve-mib 3072 --experimental-speed-projection on --vision no --images no --build
if [ "$family" = coder ]; then
    # Keep desktop RAM available and unload the engine after ten idle minutes.
    command -v uvx >/dev/null || warn "uvx not found: the chat gets no web search (install uv)"
    python3 -I - "$STRATA_DIR/strata-coder-iq1_m.json" "$(command -v uvx || true)" <<'EOF'
import json, sys
path, uvx = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg.setdefault("env", {})["STRATA_RESIDENT_HEADROOM_GIB"] = "6"
cfg["idle_unload_s"] = 600
cfg["fit_max_tokens"] = True
if uvx:
    cfg["mcp_servers"] = {"search": {"command": "uvx", "args": ["duckduckgo-mcp-server@0.7.0"]}}
json.dump(cfg, open(path, "w"), indent=1)
EOF
fi
ok "Strata installed ($family), model files in $STRATA_DATA"

section "Strata setup complete"
ok "Start: $STRATA_DIR/run-<model>.sh — chat on http://127.0.0.1:8080; Ctrl+C in that terminal stops it, closing the tab does not"
warn "Loaded, it holds ~20 GB of RAM and ~9 GB of VRAM until 10 minutes after the last request: stop it before gaming"
