#!/bin/bash
# Local LLM: Strata runs Qwen3.8-Flash-Next on the NVIDIA card plus system RAM.
# Opt-in — about 65 GB of model files and a one-time engine compile.

set -e
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

STRATA_REV=82f46a8c8f475f001ad76d92f58f4a4f8ffb0253  # v0.1.40.1
STRATA_DIR=${STRATA_DIR:-$HOME/Prosjekter/Strata}
# not under /home: snapper would keep the model files in every snapshot
STRATA_DATA=${STRATA_DATA:-/mnt/data/Strata-data}

hw_has_gpu 10de || { warn "Strata's CUDA engine needs an NVIDIA GPU"; exit 1; }
mkdir -p "$STRATA_DATA" 2>/dev/null ||
    { warn "Cannot create $STRATA_DATA — mount the data disk or set STRATA_DATA"; exit 1; }

section "CUDA toolkit"
# Strata compiles its engine on Linux (its release assets are Windows-only). NVIDIA's repo
# lags Fedora releases and its packages carry no dist tag, so fedora44 keeps working after an upgrade
[ -f /etc/yum.repos.d/cuda-fedora44.repo ] ||
    sudo dnf config-manager addrepo \
        --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo
sudo dnf install -y cuda-toolkit-13-4 gcc-c++ git
ok "CUDA 13.4 toolkit (NVIDIA repo), gcc-c++, git"

section "Strata checkout"
if [ ! -d "$STRATA_DIR/.git" ]; then
    git clone -q --filter=blob:none https://github.com/Niko1221/Strata.git "$STRATA_DIR"
    # pinned on main, not detached: the checkout's own update.sh runs git pull --ff-only
    git -C "$STRATA_DIR" reset -q --hard "$STRATA_REV"
fi
ok "$STRATA_DIR at $(git -C "$STRATA_DIR" describe --tags --always)"

section "Model and engine"
# the full model needs ~48 GB of RAM; the Coder keeps half the experts and fits 32 GB
family=qwen
[ "$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)" -lt 40 ] && family=coder
# the card also drives the desktop: with Strata's default 700 MiB reserve the lock
# screen could not allocate framebuffers on wake and froze
"$STRATA_DIR/setup.sh" --yes --family "$family" --no-start --data-dir "$STRATA_DATA" --vram-reserve-mib 3072
if [ "$family" = coder ]; then
    # Strata's own tip for 32 GB: 2 GiB more for the desktop at the same decode speed
    python3 -I - "$STRATA_DIR/strata-coder-iq1_m.json" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.setdefault("env", {})["STRATA_RESIDENT_HEADROOM_GIB"] = "6"
json.dump(cfg, open(sys.argv[1], "w"), indent=1)
EOF
fi
ok "Strata installed ($family), model files in $STRATA_DATA"

section "Strata setup complete"
ok "Start: $STRATA_DIR/setup.sh — chat on http://127.0.0.1:8080, closing its window stops it"
warn "Running, it holds ~20 GB of RAM and ~9 GB of VRAM: close it before gaming or leaving the PC"
