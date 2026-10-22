#!/bin/bash
# Hardware audit with btrfs scrub and supported short SMART tests on every NVMe/SATA disk.
# Changes nothing except what the scrub repairs from btrfs' duplicate metadata.

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e
export LC_ALL=C

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

FAILED_CHECKS=0
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; FAILED_CHECKS=1; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

ata_test_status() {
    sed -n '/Self-test execution status:/s/.*([[:space:]]*\([0-9][0-9]*\)).*/\1/p' <<<"$1"
}

check_smart_disk() {  # device transport
    local disk=$1 transport=$2 health attributes caps status state result finished=0 unhealthy=0 code i
    echo "  $disk ($transport):"
    if health=$(smartctl -H "$disk" 2>/dev/null); then
        printf '%s\n' "$health" | grep -i 'overall-health' | sed 's/^/    /' || true
    else
        warn "$disk: SMART health query failed or reported an unhealthy device"
        unhealthy=1
        printf '%s\n' "$health" | grep -i 'overall-health' | sed 's/^/    /' || true
    fi
    if attributes=$(smartctl -A "$disk" 2>/dev/null); then
        printf '%s\n' "$attributes" | grep -iE 'Critical Warning|Available Spare:|Percentage Used|Media and Data Integrity|Error Information Log|^Temperature:|Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error' | sed 's/^/    /' || true
    else
        warn "$disk: cannot read SMART attributes"
    fi
    [ "$unhealthy" -eq 0 ] || { warn "$disk: short self-test skipped after failed health query"; return; }
    caps=$(smartctl -c "$disk" 2>/dev/null) || { warn "$disk: cannot read self-test capabilities"; return; }
    if [ "$transport" = nvme ]; then
        if [[ $caps != *Self_Test* ]]; then
            echo "  $disk: short self-tests not supported; skipped"
            return
        fi
        state=$(smartctl -l selftest "$disk" 2>/dev/null) || { warn "$disk: cannot read self-test state; no test started"; return; }
        status=$(grep -i 'Self-test status:' <<<"$state" || true)
        case "$status" in
            *"No self-test in progress"*) ;;
            *"self-test in progress"*) warn "$disk: another self-test is running; left unchanged"; return ;;
            *) warn "$disk: unknown self-test state; no test started"; return ;;
        esac
    else
        if grep -q '^[[:space:]]*No Self-test supported\.' <<<"$caps"; then
            echo "  $disk: short self-tests not supported; skipped"
            return
        fi
        grep -q '^[[:space:]]*Self-test supported\.' <<<"$caps" || { warn "$disk: unknown self-test capabilities; no test started"; return; }
        code=$(ata_test_status "$caps")
        [[ $code =~ ^[0-9]+$ ]] || { warn "$disk: unknown self-test state; no test started"; return; }
        if (( (code & 240) == 240 )); then
            warn "$disk: another self-test is running; left unchanged"
            return
        fi
    fi
    echo "  $disk: running short self-test..."
    smartctl -t short "$disk" >/dev/null 2>&1 || { warn "$disk: could not start self-test; no new result to report"; return; }
    for ((i=0; i<90; i++)); do
        sleep 5
        if [ "$transport" = nvme ]; then
            state=$(smartctl -l selftest "$disk" 2>/dev/null) || { warn "$disk: cannot read running self-test state"; return; }
            status=$(grep -i 'Self-test status:' <<<"$state" || true)
            case "$status" in
                *"No self-test in progress"*) finished=1; break ;;
                *"self-test in progress"*) ;;
                *) warn "$disk: unknown self-test state after start"; return ;;
            esac
        else
            state=$(smartctl -c "$disk" 2>/dev/null) || { warn "$disk: cannot read running self-test state"; return; }
            code=$(ata_test_status "$state")
            [[ $code =~ ^[0-9]+$ ]] || { warn "$disk: unknown self-test state after start"; return; }
            if (( (code & 240) != 240 )); then finished=1; break; fi
        fi
        printf '.'
    done
    echo
    if [ "$finished" -ne 1 ]; then
        warn "$disk: self-test did not finish within 450 seconds; check smartctl -l selftest $disk"
        return
    fi
    state=$(smartctl -l selftest "$disk" 2>/dev/null) || { warn "$disk: cannot read completed self-test log"; return; }
    if [ "$transport" = nvme ]; then
        result=$(grep -E '^[[:space:]]*0[[:space:]]+' <<<"$state" || true)
    else
        result=$(grep -E '^[[:space:]]*#?[[:space:]]*1[[:space:]]+' <<<"$state" || true)
    fi
    case "$result" in
        *"Completed without error"*) ok "$disk: self-test passed" ;;
        "") warn "$disk: no self-test result recorded" ;;
        *) warn "$disk: self-test: $result" ;;
    esac
}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

DISKS=$(lsblk -dnpo PATH,TYPE,TRAN)
mapfile -t SMART_DISKS < <(awk '$2=="disk" && $3 ~ /^(nvme|sata|ata)$/ {print $1, $3}' <<<"$DISKS")
ROOTFS=$(findmnt -no SOURCE / || true)
BOOTFS=$(findmnt -no SOURCE /boot || true)
mapfile -t NTFS < <(lsblk -rno PATH,FSTYPE | awk '$2=="ntfs"{print $1}')

section "Firmware"
echo "  board       $(dmidecode -s baseboard-product-name)"
echo "  BIOS        $(dmidecode -s bios-version)  ($(dmidecode -s bios-release-date))"
systemd-analyze time 2>/dev/null | head -1 | sed 's/^/  /' || true
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
if KERNEL_LOG=$(dmesg 2>/dev/null); then
    MCE=$(printf '%s' "$KERNEL_LOG" | grep -ciE 'machine check|mce: \[Hardware Error\]' || true)
    if [ "$MCE" -eq 0 ]; then ok "0 machine check events"; else warn "$MCE machine check events — investigate"; fi
else
    warn "cannot read kernel log for machine check events"
fi
if VULN_STATE=$(grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null); then
    VULN=$(printf '%s\n' "$VULN_STATE" | wc -l)
    UNMIT=$(printf '%s\n' "$VULN_STATE" | grep -c "Vulnerable" || true)
    if [ "$UNMIT" -eq 0 ]; then ok "$VULN vulnerabilities, all mitigated"; else warn "$UNMIT unmitigated"; fi
else
    warn "cannot read CPU vulnerability status"
fi

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
if [ "${#SMART_DISKS[@]}" -gt 0 ] && command -v smartctl >/dev/null; then
    for entry in "${SMART_DISKS[@]}"; do
        read -r disk transport <<<"$entry"
        check_smart_disk "$disk" "$transport"
    done
else
    warn "no supported NVMe/SATA disks or smartctl missing — SMART checks skipped"
fi

section "Filesystems"
if [ -n "$ROOTFS" ] && [ "$(findmnt -no FSTYPE /)" = "btrfs" ]; then
    if STATS=$(btrfs device stats / 2>/dev/null) && [ -n "$STATS" ]; then
        ERRS=$(printf '%s\n' "$STATS" | grep -vc ' 0$' || true)
        if [ "$ERRS" -eq 0 ]; then
            ok "btrfs error counters all zero"
        else
            warn "btrfs reports errors:"
            printf '%s\n' "$STATS" | grep -v ' 0$' | sed 's/^/    /' || true
        fi
    else
        warn "cannot read btrfs error counters"
    fi
    echo "  scrubbing (reads and checksums every block)..."
    if SCRUB=$(btrfs scrub start -B / 2>&1); then
        printf '%s\n' "$SCRUB" | grep -E 'Duration|Error summary' | sed 's/^/  /' || true
    else
        warn "btrfs scrub failed or reported uncorrectable errors"
        printf '%s\n' "$SCRUB" | sed 's/^/    /'
    fi
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
if UNITS=$(systemctl --failed --no-legend --no-pager); then
    FAILED=$(printf '%s\n' "$UNITS" | grep -c . || true)
    if [ "$FAILED" -eq 0 ]; then
        ok "0 failed units"
    else
        warn "$FAILED failed units:"
        printf '%s\n' "$UNITS" | sed 's/^/    /'
    fi
else
    warn "cannot read failed systemd units"
fi
if JOURNAL=$(journalctl -b -p err --no-pager 2>/dev/null); then
    ERRLINES=$(printf '%s' "$JOURNAL" | grep -vc '^--' || true)
    echo "  $ERRLINES error lines this boot"
    if [ "$ERRLINES" -gt 0 ]; then
        printf '%s\n' "$JOURNAL" | tail -8 | sed 's/^/    /'
    fi
else
    warn "cannot read journal errors for this boot"
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
exit "$FAILED_CHECKS"
