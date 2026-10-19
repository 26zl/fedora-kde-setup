#!/bin/bash
# Runs the deploy steps on a fresh Fedora, each in its own throwaway container:
# scripts/apply-system.sh for a desktop with NVIDIA and for a laptop without, and every
# cp/mkdir line in the README's code blocks, each block in a new home. A step that only
# works where its target directory already exists fails here instead of on a first
# install. Commands that need a booted system are stubbed; cp, mkdir and rm are real.
# Needs podman or docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
image=registry.fedoraproject.org/fedora:44

if [ "${1-}" != --inside ]; then
    engine=$(command -v podman || command -v docker) || { echo "needs podman or docker" >&2; exit 2; }
    failed=0
    for target in desktop laptop readme; do
        echo "==> $target"
        # a local setup.conf would override the hardware under test
        # shellcheck disable=SC2016  # $0 is expanded by the container's shell
        tar --exclude=.git --exclude=setup.conf -cf - . |
            "$engine" run --rm -i "$image" bash -c \
                'mkdir /repo && tar -xf - -C /repo && exec bash /repo/tests/fresh-install.sh --inside "$0"' "$target" ||
            failed=1
    done
    exit "$failed"
fi

[ -e /run/.containerenv ] || [ -e /.dockerenv ] || { echo "--inside writes to /etc: container only" >&2; exit 2; }
# the packages that own the remaining target directories on every Fedora KDE install
dnf -y -q install systemd-udev kmod tuned diffutils
stub=$(mktemp -d)
printf '#!/bin/sh\nexec "$@"\n' >"$stub/sudo"
printf '#!/bin/sh\nexit 1\n' >"$stub/snapper"
for c in grubby modprobe restorecon setquota sysctl systemctl systemd-tmpfiles tuned-adm udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$stub/$c"
done
chmod +x "$stub"/*
# an empty HW_ROOT has no GPU, battery or Windows, so FORM_FACTOR and NVIDIA_DRIVER decide
HW_ROOT=$(mktemp -d)
export PATH="$stub:$PATH" NO_COLOR=1 HW_ROOT

case $2 in
    desktop) FORM_FACTOR=desktop NVIDIA_DRIVER=current bash scripts/apply-system.sh ;;
    laptop) FORM_FACTOR=laptop NVIDIA_DRIVER=none bash scripts/apply-system.sh ;;
    readme)
        failed=0 prev=""
        while IFS=$'\t' read -r block cmd; do
            if [ "$block" != "$prev" ]; then
                # what the first Plasma login leaves; anything deeper is the step's own job
                HOME=$(mktemp -d)
                mkdir -p "$HOME/.config" "$HOME/.local/share"
                prev=$block
            fi
            eval "$cmd" || { echo "FAILED (README bash block $block): $cmd" >&2; failed=1; }
        done < <(awk '/^```bash/ { b++; f = 1; next } /^```/ { f = 0 }
            f { l = l $0; if (sub(/\\$/, "", l)) next; sub(/[ \t]+#.*$/, "", l)
                if (l ~ /^(sudo )?(cp|mkdir -p) / && l ~ /[ \t][~\/][^ \t]*$/) print b "\t" l; l = "" }' README.md)
        exit "$failed"
        ;;
    *) echo "unknown target: $2" >&2; exit 2 ;;
esac
