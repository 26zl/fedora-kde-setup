#!/bin/bash
# Check that the machine is in the state the setup leaves it in: after fedora-setup.sh,
# on the first boot after a Fedora release upgrade, or whenever something seems off.
# Changes nothing; exits 1 when a check fails. Notes (→) are worth a look, not failures.

# takes no options: --help (or any argument) prints this header instead of running
[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

cd "$(dirname "$0")/.." || exit 2
# shellcheck source=scripts/lib/hw.sh
source scripts/lib/hw.sh
# shellcheck disable=SC1091
[ -f setup.conf ] && source ./setup.conf
hw_check_conf || exit 2

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

fails=0
pass()    { echo -e "  ${TEAL}✓${RESET} $1"; }
fail()    { echo -e "  ${RED}✗${RESET} $1"; fails=$((fails + 1)); }
note()    { echo -e "  ${TEAL}→${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }
# pass or fail on a command's exit status
check() {  # description command...
    local what=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
zram_active()   { swapon --show=NAME --noheadings | grep -q zram; }
enforcing()     { [ "$(getenforce)" = Enforcing ]; }
gamescope_nice() { getcap "$(command -v gamescope)" | grep -q cap_sys_nice; }
sleep_dir_ok()  { stat -c %C /var/lib/systemd/sleep | grep -q systemd_sleep_var_lib_t; }

FORM_FACTOR=$(hw_form_factor)
NVIDIA_BRANCH=$(hw_nvidia_driver)

section "System"
note "Fedora $(rpm -E %fedora), kernel $(uname -r); $(hw_summary)"
failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)
if [ -z "$failed" ]; then pass "no failed system units"; else fail "failed system units: $failed"; fi
failed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)
[ -z "$failed" ] || note "failed user units: $failed"
missing=""
args=$(grep -oP '^KERNEL_ARGS="\K[^"]+' scripts/apply-system.sh)
# shellcheck disable=SC2016  # the pattern matches a literal $KERNEL_ARGS
[ "$FORM_FACTOR" = desktop ] &&
    args+=" $(grep -oP 'desktop \] && KERNEL_ARGS="\$KERNEL_ARGS \K[^"]+' scripts/apply-system.sh)"
for a in $args; do grep -qw -- "$a" /proc/cmdline || missing+=" $a"; done
if [ -z "$missing" ]; then pass "kernel arguments: $args"; else fail "kernel arguments missing:$missing"; fi
check "auditd running" systemctl is-active -q auditd
check "zram swap active" zram_active

section "Scheduler and tuning"
want=$(sed -n 's/^default_sched = "scx_\(.*\)"/\1/p' /etc/scx_loader/config.toml 2>/dev/null)
ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
if [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = enabled ] && [[ -n $want && $ops == "$want"* ]]; then
    pass "sched_ext: $ops"
else
    fail "sched_ext: no scx_${want:-?} attached (journalctl -u scx_loader; see the SCX section of the README)"
fi
profile=$(tuned-adm active 2>/dev/null | sed 's/^Current active profile: //')
if [ "$FORM_FACTOR" = laptop ] || [ "$profile" = latency-performance ]; then
    pass "tuned: $profile"
else
    note "tuned: $profile (the desktop setting is latency-performance)"
fi

section "Graphics"
if [ -n "$NVIDIA_BRANCH" ]; then
    if [ -r /proc/driver/nvidia/version ]; then
        pass "NVIDIA driver $(modinfo -F version nvidia 2>/dev/null) loaded"
    else
        fail "NVIDIA driver not loaded (MOK after a BIOS flash: scripts/mok-reenroll.sh)"
    fi
    check "NVIDIA keeps video memory over suspend" grep -q 'PreserveVideoMemoryAllocations: 1' /proc/driver/nvidia/params
fi
if command -v gamescope >/dev/null; then
    check "gamescope has CAP_SYS_NICE" gamescope_nice
fi
check "/dev/ntsync present" test -e /dev/ntsync

section "Security"
zone=$(firewall-cmd --get-default-zone 2>/dev/null)
services=$(firewall-cmd --zone="$zone" --list-services 2>/dev/null)
if [ "$services" = dhcpv6-client ]; then pass "firewall ($zone): dhcpv6-client only"; else note "firewall ($zone): ${services:-unreadable}"; fi
check "SELinux enforcing" enforcing
if [ -e /usr/lib/systemd/system-sleep/kwin-display-fix.sh ]; then
    check "sleep hook state directory labelled for systemd-sleep" sleep_dir_ok
fi

section "Deployed files"
# the same choices apply-system.sh makes: one scx variant, NVIDIA files only with the driver
skip="scx_loader-laptop.toml"
[ "$FORM_FACTOR" = laptop ] && skip="scx_loader.toml"
[ -n "$NVIDIA_BRANCH" ] || skip+=" nvidia-performance.conf nvidia-wayland.conf"
[ -n "$NVIDIA_BRANCH" ] && hw_is_hybrid_gpu && skip+=" nvidia-wayland.conf"
drift=0
while read -r src dst; do
    [[ " $skip " == *" ${src##*/} "* ]] && continue
    if [ ! -e "$dst" ]; then fail "$src not deployed to $dst"; drift=1
    elif ! cmp -s "$src" "$dst"; then fail "$dst differs from $src"; drift=1; fi
done < <(awk '$1=="sudo" && $2=="cp" {print $3, $4}' scripts/apply-system.sh | sort -u)
[ "$(cat /etc/rpm/macros.image-language-conf 2>/dev/null)" = "%_install_langs $(hw_install_langs)" ] ||
    { fail "/etc/rpm/macros.image-language-conf does not match the locales in use"; drift=1; }
if [ "$drift" -eq 0 ]; then pass "every system/ file deployed and unchanged"; else note "bash scripts/apply-system.sh redeploys them"; fi
rpmnew=$(find /etc \( -name '*.rpmnew' -o -name '*.rpmsave' \) 2>/dev/null | tr '\n' ' ')
[ -z "$rpmnew" ] || note "package config updates waiting: $rpmnew (for files system/ replaces, re-run apply-system.sh instead)"

if [ -f ~/ES-DE/custom_systems/es_systems.xml ] || compgen -G '/etc/yum.repos.d/cuda-fedora*.repo' >/dev/null; then
    section "Opt-in extras"
fi
if [ -f ~/ES-DE/custom_systems/es_systems.xml ]; then
    if rpm -q emulationstation-de >/dev/null 2>&1; then
        pass "ES-DE installed"
    elif dnf -q repoquery --available emulationstation-de 2>/dev/null | grep -q .; then
        note "ES-DE missing but Terra has it: bash scripts/emulation-setup.sh"
    else
        note "ES-DE missing; Terra has no build for Fedora $(rpm -E %fedora) yet (AppImage from es-de.org meanwhile)"
    fi
fi
for repofile in /etc/yum.repos.d/cuda-fedora*.repo; do
    [ -f "$repofile" ] || continue
    id=$(sed -n 's/^\[\(.*\)\]$/\1/p' "$repofile" | head -n 1)
    if awk -v s="[$id]" '/^\[/ {in_s = ($0 == s)} in_s && /^exclude=.*nvidia-driver/ {found = 1} END {exit !found}' \
        /etc/dnf/repos.override.d/99-config_manager.repo 2>/dev/null; then
        pass "CUDA repo excludes NVIDIA's driver packages"
    else
        fail "CUDA repo $id lacks the driver exclude (bash scripts/strata-setup.sh sets it)"
    fi
    rel=$(rpm -E %fedora)
    if [ "$id" != "cuda-fedora$rel-x86_64" ] && curl -sf -o /dev/null --max-time 20 \
        "https://developer.download.nvidia.com/compute/cuda/repos/fedora$rel/x86_64/cuda-fedora$rel.repo"; then
        note "NVIDIA now has a fedora$rel CUDA repo; $id still works (no dist tag)"
    fi
done

echo
if [ "$fails" -eq 0 ]; then
    pass "all checks passed"
else
    fail "$fails check(s) failed"
    exit 1
fi
