#!/bin/bash
# Full hardware audit (~6 min: btrfs scrub + NVMe self-test); sysinfo.sh is the quick glance.
# Changes nothing except what the scrub repairs from btrfs' duplicate metadata.

# takes no options: --help (or any argument) prints this header instead of running
[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# Device discovery — never hardcode, the disk layout can change
NVME=$(lsblk -dno PATH,TRAN | awk '$2=="nvme"{print $1; exit}')
ROOTFS=$(findmnt -no SOURCE / || true)
BOOTFS=$(findmnt -no SOURCE /boot || true)
mapfile -t NTFS < <(lsblk -rno PATH,FSTYPE | awk '$2=="ntfs"{print $1}')

section "Firmware"
echo "  board       $(dmidecode -s baseboard-product-name)"
echo "  BIOS        $(dmidecode -s bios-version)  ($(dmidecode -s bios-release-date))"
systemd-analyze time 2>/dev/null | head -1 | sed 's/^/  /' || true
# firmware time far above normal can mean a wedged embedded controller; only a full power drain clears it
SB=$(mokutil --sb-state 2>/dev/null | head -1 || true)
echo "  ${SB:-Secure Boot state unknown}"
# only exists once akmods has built a module (NVIDIA and the like)
for key in /etc/pki/akmods/certs/public_key.der /etc/pki/akmods/certs/*.der; do
    [ -f "$key" ] || continue
    if mokutil --test-key "$key" 2>/dev/null | grep -q "already enrolled"; then
        ok "akmods signing key enrolled"
    else
        warn "akmods key NOT enrolled — run mok-reenroll.sh, or akmods-built modules (NVIDIA) will not load"
    fi
    break
done
efibootmgr 2>/dev/null | grep -E '^Boot0' | sed 's/\t.*//;s/^/  /' || true

section "CPU"
grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ */  /'
echo "  threads     $(nproc)"
echo "  microcode  $(grep -m1 microcode /proc/cpuinfo | cut -d: -f2-)"
MCE=$(dmesg | grep -ciE 'machine check|mce: \[Hardware Error\]' || true)
if [ "$MCE" -eq 0 ]; then ok "0 machine check events"; else warn "$MCE machine check events — investigate"; fi
VULN=$(grep -rl . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null | wc -l || true)
UNMIT=$(grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null | grep -c "Vulnerable" || true)
if [ "$UNMIT" -eq 0 ]; then ok "$VULN vulnerabilities, all mitigated"; else warn "$UNMIT unmitigated"; fi

section "Memory"
# Pair each populated slot with its own speed — a flat grep interleaves the fields
dmidecode -t memory | awk '
    /^Memory Device/       { size=""; speed=""; conf=""; part="" }
    /^\tSize:/             { size=$2" "$3 }
    /^\tSpeed:/            { speed=$2 }
    /^\tConfigured Memory/ { conf=$4 }
    /^\tPart Number:/      { part=$3 }
    /^$/ && size != "" && size !~ /No/ { printf "  %-8s %-6s rated %s MT/s, running %s MT/s\n", size, part, speed, conf }
'
# Without ECC memory there are no EDAC counters, so an empty mc directory is normal, not a fault
EDAC=0
for mc in /sys/devices/system/edac/mc/mc*; do
    [ -d "$mc" ] || continue
    EDAC=1
    echo "  $(basename "$mc")  CE=$(cat "$mc/ce_count") UE=$(cat "$mc/ue_count")"
done
[ "$EDAC" -eq 1 ] || echo "  no EDAC counters (expected without ECC memory)"
free -h | sed 's/^/  /'

section "Temperatures"
if command -v sensors >/dev/null; then
    # Tctl/Tccd: AMD (k10temp), Package id: Intel (coretemp), Composite: NVMe, edge: AMD GPU
    sensors 2>/dev/null | grep -E 'Tctl|Tccd|Package id|Composite|^edge|^temp[0-9]' | sed 's/^/  /' || true
else
    warn "lm_sensors not installed"
fi

section "Storage"
if [ -n "$NVME" ]; then
    smartctl -H "$NVME" 2>/dev/null | grep -i 'overall-health' | sed 's/^/  /' || true
    smartctl -A "$NVME" 2>/dev/null | grep -iE 'Critical Warning|Available Spare:|Percentage Used|Media and Data Integrity|Error Information Log|^Temperature:' | sed 's/^/  /' || true

    echo "  running NVMe short self-test..."
    smartctl -t short "$NVME" >/dev/null 2>&1 || warn "could not start self-test"
    # "No self-test in progress" contains "in progress" — match the finished state, not the running one
    for _ in $(seq 1 90); do
        sleep 5
        STATUS=$(smartctl -l selftest "$NVME" 2>/dev/null | grep -i 'Self-test status' || true)
        case "$STATUS" in
            *"No self-test in progress"*) break ;;
            *) printf '.' ;;
        esac
    done
    echo
    RESULT=$(smartctl -l selftest "$NVME" 2>/dev/null | grep -E '^\s*0\s+' || true)
    case "$RESULT" in
        *"without error"*) ok "self-test passed" ;;
        "")                warn "no self-test result recorded" ;;
        *)                 warn "self-test: $RESULT" ;;
    esac
else
    echo "  no NVMe device — SMART self-test skipped (it covers NVMe only)"
fi

section "Filesystems"
if [ -n "$ROOTFS" ] && [ "$(findmnt -no FSTYPE /)" = "btrfs" ]; then
    ERRS=$(btrfs device stats / 2>/dev/null | grep -vc ' 0$' || true)
    if [ "$ERRS" -eq 0 ]; then
        ok "btrfs error counters all zero"
    else
        warn "btrfs reports errors:"
        btrfs device stats / | grep -v ' 0$' | sed 's/^/    /' || true
    fi
    echo "  scrubbing (reads and checksums every block)..."
    btrfs scrub start -B / 2>/dev/null | grep -E 'Duration|Error summary' | sed 's/^/  /' || true
fi
if [ -n "$BOOTFS" ]; then
    STATE=$(tune2fs -l "$BOOTFS" 2>/dev/null | awk -F: '/Filesystem state/{gsub(/ /,"",$2); print $2}' || true)
    if [ "$STATE" = "clean" ]; then ok "/boot clean"; else warn "/boot state: ${STATE:-unknown}"; fi
fi
for part in "${NTFS[@]}"; do
    if ntfsfix -n "$part" >/dev/null 2>&1; then ok "$part clean"; else warn "$part needs chkdsk from Windows"; fi
done

section "GPU"
lspci 2>/dev/null | grep -Ei 'VGA compatible|3D controller|Display controller' | cut -d' ' -f2- | sed 's/^/  /' || true
if lspci -n 2>/dev/null | grep -Eq ' 03[0-9a-f]{2}: 10de:'; then
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version,temperature.gpu,power.draw,memory.used,memory.total \
            --format=csv,noheader 2>/dev/null | sed 's/^/  /' || true
        ok "nvidia driver bound"
    else
        warn "nvidia-smi not responding — check the driver and the MOK enrollment above"
    fi
fi
lspci -k | grep -A3 -Ei 'VGA|3D controller|Display controller' | grep 'Kernel driver' | sed 's/^\s*/  /' || true

section "Fedora"
FAILED=$(systemctl --failed --no-legend --no-pager | grep -c . || true)
if [ "$FAILED" -eq 0 ]; then
    ok "0 failed units"
else
    warn "$FAILED failed units:"
    systemctl --failed --no-legend --no-pager | sed 's/^/    /' || true
fi
ERRLINES=$(journalctl -b -p err --no-pager 2>/dev/null | grep -vc '^--' || true)
echo "  $ERRLINES error lines this boot"
if [ "$ERRLINES" -gt 0 ]; then
    journalctl -b -p err --no-pager 2>/dev/null | tail -8 | sed 's/^/    /' || true
fi
echo "  SELinux: $(getenforce 2>/dev/null || echo unknown)"
TAINT=$(cat /proc/sys/kernel/tainted)
# 4096 is the out-of-tree bit, set by modules such as NVIDIA's — anything else is worth a look
if [ "$TAINT" -eq 0 ] || [ "$TAINT" -eq 4096 ]; then
    ok "kernel taint $TAINT"
else
    warn "kernel taint $TAINT"
fi

echo
