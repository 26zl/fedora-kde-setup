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

# interactive runs also leave these lines in the journal: journalctl -t fedora-kde-setup
journal() { [ ! -t 1 ] || logger -t fedora-kde-setup -- "${0##*/}: $*" 2>/dev/null || true; }
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; journal "ok: $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; journal "warning: $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; journal "$1"; }

PINNED_REV=146df3c468739147f520ac3816de806f71232571  # v0.2.12
STRATA_URL=${STRATA_URL:-https://github.com/Niko1221/Strata.git}
# setup.conf may set both paths and STRATA_REV; the environment wins over it
# shellcheck disable=SC1091
conf() { if [ -f setup.conf ]; then (unset "$1"; . ./setup.conf >/dev/null; printf '%s' "${!1-}"); fi; }
STRATA_DIR=${STRATA_DIR:-$(conf STRATA_DIR)}
STRATA_DIR=${STRATA_DIR:-$HOME/Prosjekter/Strata}
STRATA_DATA=${STRATA_DATA:-$(conf STRATA_DATA)}
# not under /home: snapper would keep the model files in every snapshot
STRATA_DATA=${STRATA_DATA:-/mnt/data/Strata-data}
# latest follows Strata's newest release instead of the commit this repo was tested with
STRATA_REV=${STRATA_REV:-$(conf STRATA_REV)}
STRATA_REV=${STRATA_REV:-$PINNED_REV}

target_rev() {  # the commit to run: the newest vX.Y.Z release for latest, else STRATA_REV
    local tag
    if [ "$STRATA_REV" = latest ]; then
        tag=$(git -C "$STRATA_DIR" tag -l 'v*' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1) || return 1
        git -C "$STRATA_DIR" rev-parse --verify -q "$tag^{commit}"
    else
        git -C "$STRATA_DIR" rev-parse --verify -q "$STRATA_REV^{commit}"
    fi
}

hw_has_gpu 10de || { warn "Strata's CUDA engine needs an NVIDIA GPU"; exit 1; }
if [ -d "$STRATA_DIR/.git" ]; then
    git -C "$STRATA_DIR" diff --quiet HEAD -- ||
        { warn "$STRATA_DIR has tracked changes; review them before running its setup code"; exit 1; }
    git -C "$STRATA_DIR" fetch -q --tags origin || { warn "cannot fetch Strata's updates into $STRATA_DIR"; exit 1; }
    target=$(target_rev) || { warn "Strata has no revision $STRATA_REV"; exit 1; }
    # only a fast-forward, so a checkout with commits of its own is left for review
    if ! git -C "$STRATA_DIR" merge-base --is-ancestor HEAD "$target"; then
        if [ "$STRATA_REV" = latest ] && git -C "$STRATA_DIR" merge-base --is-ancestor "$target" HEAD; then
            target=$(git -C "$STRATA_DIR" rev-parse HEAD)
        else
            warn "$STRATA_DIR cannot fast-forward to ${target:0:7}; review the checkout before retrying"
            exit 1
        fi
    fi
fi
mkdir -p "$STRATA_DATA" 2>/dev/null ||
    { warn "Cannot create $STRATA_DATA — mount the data disk or set STRATA_DATA"; exit 1; }
ok "checkout $STRATA_DIR, model files $STRATA_DATA"

section "CUDA toolkit"
# with the toolkit and the scoped repo in place there is nothing for sudo, so an update needs no password
if rpm -q cuda-toolkit-13-4 gcc-c++ git >/dev/null 2>&1 && [ -f /etc/yum.repos.d/cuda-fedora44.repo ] &&
    awk '/^\[/ {s = ($0 == "[cuda-fedora44-x86_64]")} s && /^exclude=.*nvidia-driver/ {f = 1} END {exit !f}' \
        /etc/dnf/repos.override.d/99-config_manager.repo 2>/dev/null; then
    ok "CUDA 13.4 toolkit (NVIDIA repo), gcc-c++, git already installed"
else
    # NVIDIA's repo lags Fedora releases; its packages carry no dist tag, so fedora44 works on newer releases.
    [ -f /etc/yum.repos.d/cuda-fedora44.repo ] ||
        sudo dnf config-manager addrepo \
            --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo
    # NVIDIA's own driver packages in this repo replace RPM Fusion's driver or collide with its
    # files; this is the exclude list from rpmfusion.org/Howto/CUDA
    sudo dnf config-manager setopt 'cuda-fedora44-x86_64.exclude=nvidia-driver*,cuda-drivers*,nvidia-modprobe,nvidia-persistenced,nvidia-settings,nvidia-libXNVCtrl*,nvidia-xconfig,nvidia-open,nvidia-imex,nvidia-kmod-common,libnvidia-fbc,kmod-nvidia-*-dkms,nvidia-fs*,nvidia-gds*,xorg-x11-nvidia*'
    sudo dnf install -y cuda-toolkit-13-4 gcc-c++ git
    ok "CUDA 13.4 toolkit (NVIDIA repo), gcc-c++, git"
fi

section "Strata checkout"
if [ ! -d "$STRATA_DIR/.git" ]; then
    git clone -q --filter=blob:none "$STRATA_URL" "$STRATA_DIR"
    target=$(target_rev) || { warn "Strata has no revision $STRATA_REV"; exit 1; }
    # Only a newly created checkout may be reset without discarding user changes.
    git -C "$STRATA_DIR" reset -q --hard "$target"
elif [ "$(git -C "$STRATA_DIR" rev-parse HEAD)" != "$target" ]; then
    git -C "$STRATA_DIR" merge -q --ff-only "$target"
    # an engine built from the old source turns the build into a no-op, and setup then stops
    rm -rf "$STRATA_DIR/build"
fi
ok "$STRATA_DIR at $(git -C "$STRATA_DIR" describe --tags --always)"

section "Model and engine"
# the full model needs ~48 GB of RAM; the Coder keeps half the experts and fits 32 GB
family=qwen
[ "$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)" -lt 40 ] && family=coder
# Reserve VRAM for the desktop; experimental speed projection applies the refusal-direction vector.
# --build compiles the pinned commit: a ready-made engine is checked only against a hash from its own release.
# Pictures stay off for the text-only Coder.
context=()
# beside the 3 GiB reserve, Strata's 128K default leaves a 12 GB card no room for the expert cache;
# 64K still holds a coding agent's 36K prompt
vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1) || vram=""
[[ $vram =~ ^[[:space:]]*([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -le 12288 ] && context=(--context 65536)
"$STRATA_DIR/setup.sh" --yes --family "$family" --no-start --data-dir "$STRATA_DATA" "${context[@]}" \
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
    # the cutoff fixes the dependency set to what PyPI held then, as the version fixes the server
    args = ["--exclude-newer", "2026-11-08T00:00:00Z", "duckduckgo-mcp-server@0.7.0"]
    cfg["mcp_servers"] = {"search": {"command": "uvx", "args": args}}
json.dump(cfg, open(path, "w"), indent=1)
EOF
fi
ok "Strata installed ($family), model files in $STRATA_DATA"

section "Strata setup complete"
ok "Start: $STRATA_DIR/run-<model>.sh — chat on http://127.0.0.1:8080; Ctrl+C in that terminal stops it, closing the tab does not"
if [ "$family" = coder ]; then
    warn "Loaded, it holds ~20 GB of RAM and ~9 GB of VRAM until 10 minutes after the last request: stop it before gaming"
else
    warn "Loaded, it holds ~48 GB of RAM and ~9 GB of VRAM until you stop it: stop it before gaming"
fi
