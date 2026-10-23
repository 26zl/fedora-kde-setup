#!/bin/bash
# Upgrade to the next Fedora release (44 -> 45 when run on 44). Updates the current
# release, checks the machine, takes a snapper snapshot of / and downloads the
# upgrade; it does not reboot. Start the upgrade with `sudo dnf system-upgrade reboot`
# and run scripts/verify-setup.sh on the first boot of the new release.
# Run as regular user — sudo is called where needed; --yes answers the --allowerasing
# question with yes

YES=0
[ $# -le 1 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2; }
case ${1-} in
    "") ;;
    --yes) YES=1 ;;
    -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac

set -e
[ "$EUID" -ne 0 ] || {
    echo "run as a normal user, not root" >&2
    exit 1
}
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh
# shellcheck disable=SC1091
[ -f setup.conf ] && source ./setup.conf
hw_check_conf

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

current=$(rpm -E %fedora)
target=$((current + 1))

section "Fedora $current -> $target"
# Require the final release directory to avoid a pre-release upgrade.
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://dl.fedoraproject.org/pub/fedora/linux/releases/$target/") || true
case "$status" in
    200) ok "Fedora $target is released" ;;
    404) warn "Fedora $target is not released yet"; exit 1 ;;
    *)   warn "cannot reach dl.fedoraproject.org (HTTP ${status:-none})"; exit 1 ;;
esac

section "Fedora $current up to date"
sudo dnf upgrade --refresh -y
newest=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)
if [ "$newest" != "$(uname -r)" ]; then
    warn "kernel $newest is installed but $(uname -r) is running: reboot and run this again"
    exit 1
fi
ok "running the newest kernel ($newest)"

section "Preflight"
root_free=$(df --output=avail -BG / | tail -n 1 | tr -dc 0-9)
boot_free=$(df --output=avail -BM /boot | tail -n 1 | tr -dc 0-9)
# a KDE desktop upgrade downloads about 5 GiB and installs it next to the old packages
[ "$root_free" -ge 10 ] || { warn "only ${root_free}G free on /, free at least 10G first"; exit 1; }
[ "$boot_free" -ge 200 ] || { warn "only ${boot_free}M free on /boot, free at least 200M first"; exit 1; }
ok "free space: / ${root_free}G, /boot ${boot_free}M"
if [ -n "$(hw_nvidia_driver)" ]; then
    if ! SB=$(LC_ALL=C mokutil --sb-state 2>/dev/null); then
        warn "cannot determine Secure Boot state; verify it before upgrading"
        exit 1
    fi
    case "$SB" in
        *"SecureBoot enabled"*|*"SecureBoot disabled"*) ;;
        *) warn "unknown Secure Boot state; verify it before upgrading"; exit 1 ;;
    esac
    [ -r /proc/driver/nvidia/version ] || { warn "the NVIDIA driver is not loaded now; fix that before upgrading"; exit 1; }
    # akmods builds the module for the new kernel; under Secure Boot it only loads
    # when the akmods key is enrolled
    if [[ $SB == *"SecureBoot enabled"* ]]; then
        LC_ALL=C sudo mokutil --test-key /etc/pki/akmods/certs/public_key.der 2>/dev/null | grep -q 'already enrolled' ||
            { warn "akmods key not enrolled: run scripts/mok-reenroll.sh first"; exit 1; }
    fi
    ok "NVIDIA driver loaded$([[ $SB == *"SecureBoot enabled"* ]] && echo ', akmods key enrolled')"
fi
if units=$(systemctl --failed --no-legend --plain); then
    failed=$(printf '%s\n' "$units" | awk '{print $1}' | xargs)
    if [ -n "$failed" ]; then
        warn "already failed before the upgrade (compare afterwards): $failed"
    else
        ok "no failed units"
    fi
else
    warn "cannot read failed systemd units; compare their state manually after upgrading"
fi

section "Restore point"
if snap=$(sudo snapper -c root create --description "before Fedora $target" --userdata important=yes \
    --cleanup-algorithm number --print-number 2>/dev/null); then
    ok "snapper root snapshot $snap; /boot is not in it, the Fedora $current kernel stays as a boot entry"
else
    warn "no snapper root config: no restore point"
fi

section "Download"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
# Offer --allowerasing only after dependency resolution fails; dnf previews removals.
echo "  resolving the Fedora $target transaction (fetches its metadata first)..."
# shellcheck disable=SC2024  # the log is this user's own temp file
sudo dnf system-upgrade download --releasever="$target" --assumeno >"$log" 2>&1 || true
erasing=()
if grep -q 'Failed to resolve the transaction' "$log"; then
    grep -oE 'installed package [^ ]+' "$log" | sort -u | sed 's/^installed package /  blocked by: /'
    warn "these have no build for Fedora $target yet; --allowerasing removes them,"
    warn "and they can be reinstalled once their repository catches up"
    if [ "$YES" -eq 1 ]; then reply=y; else read -rp "  Continue with --allowerasing? [y/N] " reply || reply=""; fi
    [[ $reply == [yY]* ]] || { warn "stopped before downloading Fedora $target; Fedora $current stays as it is"; exit 1; }
    erasing=(--allowerasing)
fi
sudo dnf system-upgrade download --releasever="$target" "${erasing[@]}"

section "Next"
ok "Fedora $target is downloaded"
echo "  1. sudo dnf system-upgrade reboot   runs the upgrade offline; with NVIDIA the first"
echo "                                      boot rebuilds the module before the login screen"
echo "  2. bash scripts/verify-setup.sh     on the first boot of Fedora $target"
echo "  3. bash scripts/apply-system.sh     if verify-setup.sh reports drift or .rpmnew files"
