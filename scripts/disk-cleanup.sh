#!/bin/bash
# Disk cleanup — trims snapper's snapshot timeline, then drops the caches that grow unnoticed: unused
# flatpak runtimes, PackageKit's and dnf's package caches, docker's unused images and build cache
# (volumes stay) and the calling user's unused podman images. Lists the snapshots and asks before
# deleting any; the rest is cache. Waits for btrfs to release the deleted snapshots, minutes after a
# big trim. On 2026-10-21 snapshots pinned 280 GB of deleted data on a 412 GB root (live data 104 GB).
# Keeps on /: every number-cleanup snapshot plus 5 hourly, 7 daily, 2 weekly and 1 monthly timeline
# ones; /home keeps no timeline snapshots (its timeline is off, fedora-setup.sh sets that).
# Usage:  sudo bash scripts/disk-cleanup.sh

# takes no options: --help (or any argument) prints this header instead of running
[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

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
    echo "  /home keeps no timeline snapshots. Everything else is deleted."
    read -r -p "  Apply and delete? [y/N] " ans
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
    images=$(docker image prune -af 2>/dev/null | tail -1)
    build=$(docker builder prune -af 2>/dev/null | tail -1)
    ok "docker: unused images (${images#Total reclaimed space: }) and build cache (${build#Total: }) removed, volumes kept"
fi
if [ -n "${SUDO_USER:-}" ] && command -v podman >/dev/null; then
    uid=$(id -u "$SUDO_USER")
    if sudo -u "$SUDO_USER" -H env XDG_RUNTIME_DIR="/run/user/$uid" podman system prune -af >/dev/null 2>&1; then
        ok "podman: unused images of $SUDO_USER removed"
    else
        warn "podman: prune failed for $SUDO_USER"
    fi
fi

section "Result"
# a deleted snapshot gives its space back only once btrfs has dropped the subvolume
[ "$(findmnt -no FSTYPE /)" = btrfs ] && { btrfs subvolume sync / >/dev/null 2>&1 || true; }
after=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
ok "free on /: ${before}G -> ${after}G"
[ -d /root/.cache ] && echo "  left alone: /root/.cache $(du -sh /root/.cache 2>/dev/null | cut -f1) (caches of commands run with sudo)"
command -v docker >/dev/null && docker volume ls -q 2>/dev/null | sed 's/^/  docker volume kept: /'
exit 0
