#!/bin/bash
# Trim snapper timelines and remove unused runtimes, package caches and container images.
# Keeps number snapshots; / keeps 5 hourly, 7 daily, 2 weekly and 1 monthly timeline snapshots.
# /home keeps no timeline snapshots; containers and volumes are preserved.
# Also lists the pre-setup restore points and removes them after an interactive confirmation.
# Usage: sudo bash scripts/disk-cleanup.sh [--yes] (--yes confirms the snapshot trim only).

YES=0
[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1-} in
    "") ;;
    --yes) YES=1 ;;
    -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

set -eu
[ "$(id -u)" -eq 0 ] || { echo "run: sudo bash $0"; exit 1; }

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

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
    if [ "$YES" -eq 1 ]; then ans=y; else read -r -p "  Apply and delete? [y/N] " ans || ans=""; fi
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
if [ -d /.fedora-kde-setup-backups ]; then
    for run in /.fedora-kde-setup-backups/run-*; do
        [ -d "$run" ] || continue
        # -x keeps du out of the root and home snapshots, which are subvolumes of their own
        echo "  $run: $(du -shx "$run" 2>/dev/null | cut -f1) of archives$([ -e "$run/READY" ] || echo ', incomplete')"
    done
    if [ "$YES" -eq 1 ]; then
        warn "restore points are only deleted after an interactive confirmation"
        ans=n
    else
        read -r -p "  Delete these restore points, snapshots included? [y/N] " ans || ans=""
    fi
    case $ans in
    y | Y)
        for run in /.fedora-kde-setup-backups/run-*; do
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
if command -v flatpak >/dev/null; then
    if flatpak uninstall --unused -y --system --noninteractive >/dev/null 2>&1; then
        ok "flatpak: unused runtimes removed"
    else
        warn "flatpak: unused runtimes not removed"
    fi
fi
if [ -d /var/cache/PackageKit ]; then
    systemctl stop packagekit 2>/dev/null || true
    rm -rf /var/cache/PackageKit/*
    ok "PackageKit package cache cleared"
fi
dnf clean packages -q >/dev/null 2>&1 && ok "dnf package cache cleared"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
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
if [ -n "${SUDO_USER:-}" ] && command -v podman >/dev/null; then
    uid=$(id -u "$SUDO_USER")
    if sudo -u "$SUDO_USER" -H env XDG_RUNTIME_DIR="/run/user/$uid" podman image prune -af >/dev/null 2>&1; then
        ok "podman: unused images of $SUDO_USER removed"
    else
        warn "podman: prune failed for $SUDO_USER"
    fi
fi

section "Result"
# Deleted snapshots release space only after btrfs drops the subvolume.
[ "$(findmnt -no FSTYPE /)" = btrfs ] && { btrfs subvolume sync / >/dev/null 2>&1 || true; }
after=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
ok "free on /: ${before}G -> ${after}G"
[ -d /root/.cache ] && echo "  left alone: /root/.cache $(du -sh /root/.cache 2>/dev/null | cut -f1) (caches of commands run with sudo)"
command -v docker >/dev/null && docker volume ls -q 2>/dev/null | sed 's/^/  docker volume kept: /'
exit 0
