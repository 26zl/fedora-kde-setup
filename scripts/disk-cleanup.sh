#!/bin/bash
# Trim snapper timelines and remove unused runtimes, package caches and container images.
# Keeps number snapshots; / keeps 5 hourly, 7 daily, 2 weekly and 1 monthly timeline snapshots.
# /home keeps no timeline snapshots; containers and volumes are preserved.
# Pre-setup restore points and container images go only after an interactive confirmation.
# Usage: sudo bash scripts/disk-cleanup.sh [--yes | --dry-run]
# --yes confirms the snapshot trim only; --dry-run lists what would go and changes nothing.

YES=0 DRY=0
[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1-} in
    "") ;;
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

set -eu
[ "$(id -u)" -eq 0 ] || { echo "run: sudo bash $0"; exit 1; }
# fixture root for the tests; empty on a real system
ROOT=${DISK_CLEANUP_ROOT:-}

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

# interactive runs also leave these lines in the journal: journalctl -t fedora-kde-setup
journal() { [ ! -t 1 ] || logger -t fedora-kde-setup -- "${0##*/}: $*" 2>/dev/null || true; }
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; journal "ok: $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; journal "warning: $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; journal "$1"; }
# sets ans: a dry run declines everything, and --yes answers only the prompts it may confirm
answer() {  # prompt yes-may-confirm
    if [ "$DRY" -eq 1 ]; then
        ans=n
    elif [ "$YES" -eq 1 ]; then
        if [ "$2" = yes ]; then ans=y; else ans=n; fi
    else
        read -r -p "  $1 [y/N] " ans || ans=""
    fi
}

[ "$DRY" -eq 0 ] || echo "  dry run: lists what would go, changes nothing"
before=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')

section "Snapshots"
if command -v snapper >/dev/null && snapper list-configs 2>/dev/null | grep -q '^root'; then
    for c in root home; do
        snapper list-configs | grep -q "^$c" || continue
        echo "  $c:"
        snapper -c "$c" list --columns number,date,used-space,cleanup,description | sed 's/^/    /'
    done
    echo "  / keeps its number snapshots and the newest 5 hourly, 7 daily, 2 weekly and 1 monthly timeline ones;"
    echo "  /home keeps no timeline snapshots. Other snapshot cleanup types are preserved."
    answer "Apply and delete?" yes
    case $ans in
    y | Y)
        if snapper -c root set-config TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 \
            TIMELINE_LIMIT_MONTHLY=1 TIMELINE_LIMIT_YEARLY=0 && snapper -c root cleanup timeline; then
            ok "/ timeline trimmed"
        else
            warn "/ timeline not trimmed"
        fi
        if snapper list-configs | grep -q '^home'; then
            if snapper -c home set-config TIMELINE_LIMIT_HOURLY=0 TIMELINE_LIMIT_DAILY=0 TIMELINE_LIMIT_WEEKLY=0 \
                TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 && snapper -c home cleanup timeline; then
                ok "/home timeline snapshots removed"
            else
                warn "/home timeline snapshots not removed"
            fi
        fi
        ;;
    *) warn "snapshots left as they are" ;;
    esac
else
    warn "no snapper config for / — snapshots skipped"
fi

section "Pre-setup restore points"
if [ -d "$ROOT/.fedora-kde-setup-backups" ]; then
    for run in "$ROOT"/.fedora-kde-setup-backups/run-*; do
        [ -d "$run" ] || continue
        # -x keeps du out of the root and home snapshots, which are subvolumes of their own
        echo "  $run: $(du -shx "$run" 2>/dev/null | cut -f1) of archives$([ -e "$run/READY" ] || echo ', incomplete')"
    done
    [ "$YES" -eq 0 ] || warn "restore points are only deleted after an interactive confirmation"
    answer "Delete these restore points, snapshots included?" no
    case $ans in
    y | Y)
        for run in "$ROOT"/.fedora-kde-setup-backups/run-*; do
            [ -d "$run" ] || continue
            for snap in "$run/root" "$run/home"; do
                [ -d "$snap" ] && btrfs subvolume delete "$snap" >/dev/null
            done
            rm -rf "$run"
        done
        ok "pre-setup restore points removed"
        ;;
    *) warn "restore points left as they are" ;;
    esac
else
    echo "  none"
fi

section "Caches"
if [ "$DRY" -eq 1 ]; then
    for dir in "$ROOT/var/cache/PackageKit" "$ROOT/var/cache/libdnf5"; do
        if [ -d "$dir" ]; then echo "  would clear $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"; fi
    done
    if command -v flatpak >/dev/null; then echo "  would remove unused flatpak runtimes"; fi
else
    if command -v flatpak >/dev/null; then
        if flatpak uninstall --unused -y --system --noninteractive >/dev/null 2>&1; then
            ok "flatpak: unused runtimes removed"
        else
            warn "flatpak: unused runtimes not removed"
        fi
    fi
    if [ -d "$ROOT/var/cache/PackageKit" ]; then
        systemctl stop packagekit 2>/dev/null || true
        rm -rf "$ROOT"/var/cache/PackageKit/*
        ok "PackageKit package cache cleared"
    fi
    dnf clean packages -q >/dev/null 2>&1 && ok "dnf package cache cleared"
fi

section "Container images"
docker_on=0 podman_on=0
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    docker_on=1
    docker system df 2>/dev/null | awk 'NR == 1 || /^(Images|Build Cache)/' | sed 's/^/  docker  /' || true
fi
if [ -n "${SUDO_USER:-}" ] && command -v podman >/dev/null; then
    uid=$(id -u "$SUDO_USER")
    podman_user() { sudo -u "$SUDO_USER" -H env XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"; }
    if usage=$(podman_user system df 2>/dev/null); then
        podman_on=1
        awk 'NR == 1 || /^Images/' <<<"$usage" | sed 's/^/  podman  /'
    fi
fi
if [ "$docker_on" -eq 0 ] && [ "$podman_on" -eq 0 ]; then
    echo "  none"
else
    [ "$YES" -eq 0 ] || warn "container images are only removed after an interactive confirmation"
    answer "Remove every image no container uses, locally built ones included, and the build cache?" no
    case $ans in
    y | Y)
        if [ "$docker_on" -eq 1 ]; then
            if images=$(docker image prune -af 2>&1); then
                images=${images##*$'\n'}
                ok "docker: unused images (${images#Total reclaimed space: }) removed, containers and volumes kept"
            else
                warn "docker: image cleanup failed"
            fi
            if build=$(docker builder prune -af 2>&1); then
                build=${build##*$'\n'}
                ok "docker: build cache (${build#Total: }) removed"
            else
                warn "docker: build cache cleanup failed"
            fi
        fi
        if [ "$podman_on" -eq 1 ]; then
            if podman_user image prune -af >/dev/null 2>&1; then
                ok "podman: unused images of $SUDO_USER removed"
            else
                warn "podman: prune failed for $SUDO_USER"
            fi
        fi
        ;;
    *) warn "container images left as they are" ;;
    esac
fi

section "Result"
if [ "$DRY" -eq 1 ]; then
    ok "dry run: nothing changed"
else
    # Deleted snapshots release space only after btrfs drops the subvolume.
    [ "$(findmnt -no FSTYPE /)" = btrfs ] && { btrfs subvolume sync / >/dev/null 2>&1 || true; }
    after=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
    ok "free on /: ${before}G -> ${after}G"
fi
[ -d "$ROOT/root/.cache" ] && echo "  left alone: /root/.cache $(du -sh "$ROOT/root/.cache" 2>/dev/null | cut -f1) (caches of commands run with sudo)"
command -v docker >/dev/null && docker volume ls -q 2>/dev/null | sed 's/^/  docker volume kept: /'
exit 0
