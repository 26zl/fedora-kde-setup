#!/bin/bash
# Check that the machine is in the state the setup leaves it in: after fedora-setup.sh,
# on the first boot after a Fedora release upgrade, or whenever something seems off.
# Changes nothing; exits 1 when a check fails. Notes (→) are worth a look, not failures.

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
# fixture root for the tests; empty on a real system
root=${HW_ROOT:-}
pass()    { echo -e "  ${TEAL}✓${RESET} $1"; }
fail()    { echo -e "  ${RED}✗${RESET} $1"; fails=$((fails + 1)); }
note()    { echo -e "  ${TEAL}→${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }
check() {  # description command...
    local what=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
zram_active()   { swapon --show=NAME --noheadings | grep -q zram; }
enforcing()     { [ "$(getenforce)" = Enforcing ]; }
gamescope_nice() { getcap "$(command -v gamescope)" | grep -q cap_sys_nice; }

FORM_FACTOR=$(hw_form_factor)
NVIDIA_BRANCH=$(hw_nvidia_driver)

section "System"
note "Fedora $(rpm -E %fedora), kernel $(uname -r); $(hw_summary)"
if failed=$(systemctl --failed --no-legend --plain 2>/dev/null); then
    failed=$(awk '{print $1}' <<< "$failed" | xargs)
    if [ -z "$failed" ]; then pass "no failed system units"; else fail "failed system units: $failed"; fi
else
    fail "cannot query system units"
fi
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
# a release upgrade that has to drop a broken *-release package takes its repository with it
stale=""
for pkg in rpmfusion-free-release rpmfusion-nonfree-release; do
    [ "$(rpm -q --qf '%{VERSION}' "$pkg" 2>/dev/null)" = "$(rpm -E %fedora)" ] || stale+=" $pkg"
done
if [ -z "$stale" ]; then
    pass "RPM Fusion release packages for Fedora $(rpm -E %fedora)"
else
    fail "RPM Fusion release packages missing or for another release:$stale (README step 3 reinstalls them)"
fi
check "zram swap active" zram_active
# bluetoothd uses the kernel crypto API (AF_ALG) that Fedora 45 starts restricting
if systemctl is-enabled -q bluetooth 2>/dev/null; then check "bluetooth running" systemctl is-active -q bluetooth; fi
# nofail keeps the boot clean when a mount stops working: a replaced disk, a driver the kernel dropped
unmounted=""
while read -r src dst _ opts _; do
    case $src in '' | \#*) continue ;; esac
    case $dst in none | swap) continue ;; esac
    case ",$opts," in *,noauto,* | *,x-systemd.automount,*) continue ;; esac
    findmnt --mountpoint "$dst" >/dev/null 2>&1 || unmounted+=" $dst"
done < "$root/etc/fstab"
if [ -z "$unmounted" ]; then pass "every fstab entry is mounted"; else fail "fstab entries not mounted:$unmounted"; fi
# the newest installed kernel is the one the next boot picks; check it before rebooting into it
next=$(find "$root/lib/modules" -mindepth 2 -maxdepth 2 -name vmlinuz -printf '%h\n' 2>/dev/null | sed 's#.*/##' | sort -V | tail -n 1)
[ "$next" != "$(uname -r)" ] || next=""
if [ -n "$next" ]; then
    missing=""
    while read -r src _ fstype _; do
        case $src in '' | \#*) continue ;; esac
        case $fstype in auto | swap | none | fuse* | ntfs-3g | nfs* | cifs | smb3 | tmpfs) continue ;; esac
        modprobe -n -q -S "$next" "fs-$fstype" 2>/dev/null || missing+=" $fstype"
    done < "$root/etc/fstab"
    if [ -z "$missing" ]; then
        pass "kernel $next has the filesystem drivers /etc/fstab uses"
    else
        fail "kernel $next lacks the filesystem drivers:$missing (boot $(uname -r) until /etc/fstab is changed)"
    fi
fi

section "Scheduler and tuning"
want=$(sed -n 's/^default_sched = "scx_\(.*\)"/\1/p' /etc/scx_loader/config.toml 2>/dev/null)
ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
if [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = enabled ] && [[ -n $want && $ops == "$want"* ]]; then
    pass "sched_ext: $ops"
else
    fail "sched_ext: no scx_${want:-?} attached (journalctl -u scx_loader; see the SCX section of the README)"
fi
if profile=$(tuned-adm active 2>/dev/null) && [ -n "$profile" ]; then
    profile=${profile#Current active profile: }
    if [ "$FORM_FACTOR" = laptop ] || [ "$profile" = latency-performance ]; then
        pass "tuned: $profile"
    else
        note "tuned: $profile (the desktop setting is latency-performance)"
    fi
else
    fail "tuned has no active profile"
fi

section "Graphics"
if [ -n "$NVIDIA_BRANCH" ]; then
    version_file=${NVIDIA_VERSION_FILE:-/proc/driver/nvidia/version}
    if [ -r "$version_file" ]; then
        loaded=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' "$version_file" | head -n 1)
        pass "NVIDIA driver ${loaded:-of unknown version} loaded"
        # modinfo names the module on disk, which an update replaces while the old one stays loaded
        if ! smi=$(timeout 10 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1) &&
            [[ $smi == *"version mismatch"* ]]; then
            note "the installed NVIDIA driver differs from the loaded $loaded: reboot to load it; until then newly started programs get no GPU compute"
        fi
    else
        fail "NVIDIA driver not loaded (MOK after a BIOS flash: scripts/mok-reenroll.sh)"
    fi
    check "NVIDIA keeps video memory over suspend" grep -Eq '^PreserveVideoMemoryAllocations: [12]$' /proc/driver/nvidia/params
    # module options apply when the driver loads, so a deployed change waits for the next boot
    store=$(sed -n 's/.*NVreg_TemporaryFilePath=\([^ ]*\).*/\1/p' "$root"/etc/modprobe.d/nvidia-*.conf 2>/dev/null | tail -n 1)
    params=${NVIDIA_PARAMS_FILE:-/proc/driver/nvidia/params}
    if [ -n "$store" ] && ! grep -qxF "TemporaryFilePath: \"$store\"" "$params" 2>/dev/null; then
        note "NVIDIA saves video memory to $store from the next boot"
    fi
    if [ -n "$next" ] && ! modinfo -k "$next" nvidia >/dev/null 2>&1; then
        note "no NVIDIA module for kernel $next yet: akmods builds it at boot (sudo akmods --kernels $next shows errors now)"
    fi
    check "NVIDIA suspend store has room for the video memory" bash system/nvidia-vram-check.sh
    check "NVIDIA pre-sleep capacity check enabled" systemctl is-enabled -q nvidia-vram-check.service
    for unit in nvidia-suspend nvidia-hibernate nvidia-suspend-then-hibernate nvidia-resume; do
        check "$unit enabled" systemctl is-enabled -q "$unit.service"
    done
fi
if command -v gamescope >/dev/null; then
    check "gamescope has CAP_SYS_NICE" gamescope_nice
fi
check "/dev/ntsync present" test -e /dev/ntsync

section "Security"
if zone=$(firewall-cmd --get-default-zone 2>/dev/null) &&
    services=$(firewall-cmd --zone="$zone" --list-services 2>/dev/null) &&
    ports=$(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); then
    if [ "$services" = dhcpv6-client ] && [ -z "$ports" ]; then
        pass "firewall ($zone): dhcpv6-client service; no explicit ports"
    else
        note "firewall ($zone): services=${services:-none}; ports=${ports:-none}"
    fi
else
    fail "cannot query firewalld"
fi
check "SELinux enforcing" enforcing
check "KDE display sleep service enabled" systemctl is-enabled -q kde-display-sleep.service

section "Deployed files"
# the same choices apply-system.sh makes: one scx variant, NVIDIA files only with the driver, no wallpaper with RICE=no
skip="scx_loader-laptop.toml"
[ "$FORM_FACTOR" = laptop ] && skip="scx_loader.toml"
[ -n "$NVIDIA_BRANCH" ] || skip+=" nvidia-performance.conf nvidia-wayland.conf nvidia-vram-check.sh nvidia-vram-check.service"
[ "$NVIDIA_BRANCH" = 580xx ] || skip+=" nvidia-580xx-storage.conf"
[ -n "$NVIDIA_BRANCH" ] && hw_is_hybrid_gpu && skip+=" nvidia-wayland.conf"
[ "${RICE:-yes}" = yes ] || skip+=" wallpaper.jpg"
drift=0
while read -r src dst; do
    [[ " $skip " == *" ${src##*/} "* ]] && continue
    if [ ! -e "$dst" ]; then fail "$src not deployed to $dst"; drift=1
    elif ! cmp -s "$src" "$dst"; then fail "$dst differs from $src"; drift=1; fi
done < <(awk '$1=="sudo" && $2=="cp" {print $3, $4}' scripts/apply-system.sh | sort -u)
installed_langs=$(sed -n 's/^%_install_langs[[:space:]]\+//p' /etc/rpm/macros.image-language-conf 2>/dev/null)
IFS=: read -ra expected_langs <<< "$(hw_install_langs)"
for lang in "${expected_langs[@]}"; do
    if [[ ":$installed_langs:" != *":$lang:"* ]]; then
        fail "/etc/rpm/macros.image-language-conf is missing locale $lang"
        drift=1
    fi
done
if [ "$drift" -eq 0 ]; then pass "every system/ file deployed and unchanged"; else note "bash scripts/apply-system.sh redeploys them"; fi
rpmnew=$(find /etc \( -name '*.rpmnew' -o -name '*.rpmsave' \) 2>/dev/null | tr '\n' ' ')
[ -z "$rpmnew" ] || note "package config updates waiting: $rpmnew (for files system/ replaces, re-run apply-system.sh instead)"

ollama_on=""
[ -n "$NVIDIA_BRANCH" ] && systemctl is-enabled -q ollama 2>/dev/null && ollama_on=1
if [ -d ~/ES-DE/custom_systems ] || compgen -G '/etc/yum.repos.d/cuda-fedora*.repo' >/dev/null ||
    [ -n "$ollama_on" ]; then
    section "Opt-in extras"
fi
if [ -n "$ollama_on" ] && ! systemctl is-active -q ollama 2>/dev/null; then
    fail "ollama is enabled but not running (systemctl status ollama)"
elif [ -n "$ollama_on" ]; then
    backend=$(journalctl -u ollama -b -o cat 2>/dev/null | grep -o 'msg="inference compute".*' | tail -n 1 |
        grep -o 'library=[A-Za-z0-9]*')
    if [ "$backend" = library=CUDA ]; then
        pass "ollama computes on CUDA"
    else
        lib=${backend#library=}
        pre=$(systemctl show ollama -p ExecStartPre --value 2>/dev/null | grep nvidia-modprobe |
            grep -o 'status=[0-9]*' | tail -n 1 || true)
        if [ -n "$pre" ] && [ "$pre" != status=0 ]; then
            fail "ollama computes on ${lib:-no GPU}, not CUDA: nvidia-modprobe exited ${pre#status=} before the start, so /dev/nvidia-uvm was missing (sudo bash scripts/ollama-setup.sh rewrites the hardening drop-in)"
        else
            fail "ollama computes on ${lib:-no GPU}, not CUDA (sudo bash scripts/ollama-setup.sh adds nvidia-uvm.conf)"
        fi
    fi
fi
if [ -d ~/ES-DE/custom_systems ]; then
    if [ -x ~/Applications/ES-DE_x64.AppImage ]; then
        pass "ES-DE AppImage installed"
    else
        fail "emulation is set up, but ~/Applications/ES-DE_x64.AppImage is missing (bash scripts/emulation-setup.sh)"
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
    # NVIDIA opens a release's repo with DCGM only; the toolkit follows later
    if [ "$id" != "cuda-fedora$rel-x86_64" ] && listing=$(curl -sf --max-time 20 \
        "https://developer.download.nvidia.com/compute/cuda/repos/fedora$rel/x86_64/"); then
        if grep -q 'cuda-toolkit-1' <<< "$listing"; then
            note "NVIDIA's fedora$rel CUDA repo has the toolkit: re-point $id (scripts/strata-setup.sh)"
        else
            note "NVIDIA's fedora$rel CUDA repo exists but has no cuda-toolkit yet; $id still works (no dist tag)"
        fi
    fi
done
# STRATA_REV=latest in setup.conf: Strata should run its newest release
strata_dir=${STRATA_DIR:-$HOME/Prosjekter/Strata}
if [ "${STRATA_REV-}" = latest ] && [ -d "$strata_dir/.git" ]; then
    installed=$(git -C "$strata_dir" describe --tags --abbrev=0 2>/dev/null) || installed=""
    newest=$(timeout 20 git -C "$strata_dir" ls-remote --tags --refs origin 2>/dev/null | sed -n 's#.*refs/tags/##p' |
        grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1) || newest=""
    if [ -z "$newest" ]; then
        note "cannot reach Strata's repository to look for a newer release"
    elif [ "$(printf '%s\n' "$newest" "${installed:-v0}" | sort -V | tail -n 1)" = "${installed:-v0}" ]; then
        pass "Strata runs its newest release, $installed"
    else
        note "Strata $newest is out (installed: ${installed:-unknown}): bash scripts/strata-setup.sh updates it"
    fi
fi

echo
if [ "$fails" -eq 0 ]; then
    pass "all checks passed"
else
    fail "$fails check(s) failed"
    exit 1
fi
