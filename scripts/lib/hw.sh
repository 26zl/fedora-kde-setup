# shellcheck shell=bash
# Hardware detection shared by fedora-setup.sh and apply-system.sh. Source it.
# Everything is read below $HW_ROOT (empty on a real system), so
# tests/hw-detect.sh can run it against a fixture tree.

# One line per display controller: "<vendor> <device> <pci slot>", lowercase hex.
# 10de is NVIDIA, 1002 AMD, 8086 Intel.
hw_gpus() {
    local dev class vendor device
    for dev in "$HW_ROOT"/sys/bus/pci/devices/*; do
        read -r class 2>/dev/null <"$dev/class" || continue
        [[ $class == 0x03* ]] || continue
        read -r vendor <"$dev/vendor"
        read -r device <"$dev/device"
        echo "${vendor#0x} ${device#0x} ${dev##*/}"
    done
}

hw_has_gpu() {  # vendor
    local vendor _
    while read -r vendor _; do
        [ "$vendor" = "$1" ] && return 0
    done < <(hw_gpus)
    return 1
}

hw_gpu_count() {
    local n=0 _
    while read -r _; do n=$((n + 1)); done < <(hw_gpus)
    echo "$n"
}

# RPM Fusion driver branch for the newest NVIDIA GPU: "current" from Turing
# (device 0x1e00) on, "580xx" for Maxwell, Pascal and Volta (0x1340-0x1dff),
# which the driver dropped after 580, and "none" for Kepler and older, which
# stay on nouveau. Prints nothing when there is no NVIDIA GPU.
hw_nvidia_branch() {
    local vendor device _ newest=-1
    while read -r vendor device _; do
        [ "$vendor" = 10de ] || continue
        if (( 16#$device > newest )); then newest=$((16#$device)); fi
    done < <(hw_gpus)
    if (( newest >= 0x1e00 )); then echo current
    elif (( newest >= 0x1340 )); then echo 580xx
    elif (( newest >= 0 )); then echo none
    fi
}

# SMBIOS chassis types 8-11, 14 and 30-32 are portable. When the firmware
# reports nothing useful, a system battery decides; mice and controllers report
# their batteries with scope "Device" and do not count.
hw_is_laptop() {
    local chassis="" supply type scope
    read -r chassis 2>/dev/null <"$HW_ROOT/sys/class/dmi/id/chassis_type" || true
    case "$chassis" in
        8|9|10|11|14|30|31|32) return 0 ;;
        3|4|5|6|7|13|15|16|17|23|24|35|36) return 1 ;;
    esac
    for supply in "$HW_ROOT"/sys/class/power_supply/*; do
        read -r type 2>/dev/null <"$supply/type" || continue
        [ "$type" = Battery ] || continue
        scope=""
        read -r scope 2>/dev/null <"$supply/scope"
        [ "$scope" = Device ] || return 0
    done
    return 1
}

# Refuse a setup.conf value outside the documented set instead of quietly
# falling back to detection, which would hide a typo until the wrong files land.
hw_check_conf() {
    case "${FORM_FACTOR:-auto}" in auto|desktop|laptop) ;;
        *) echo "setup.conf: FORM_FACTOR must be auto, desktop or laptop (got '$FORM_FACTOR')" >&2; return 1 ;;
    esac
    case "${NVIDIA_DRIVER:-auto}" in auto|current|580xx|none) ;;
        *) echo "setup.conf: NVIDIA_DRIVER must be auto, current, 580xx or none (got '$NVIDIA_DRIVER')" >&2; return 1 ;;
    esac
    case "${AUDIO_TRIM:-no}" in yes|no) ;;
        *) echo "setup.conf: AUDIO_TRIM must be yes or no (got '$AUDIO_TRIM')" >&2; return 1 ;;
    esac
}

# desktop or laptop; FORM_FACTOR in setup.conf overrides the detection.
hw_form_factor() {
    case "${FORM_FACTOR:-auto}" in
        desktop|laptop) echo "$FORM_FACTOR" ;;
        *) if hw_is_laptop; then echo laptop; else echo desktop; fi ;;
    esac
}

# NVIDIA driver branch to install ("current" or "580xx"), or nothing.
# NVIDIA_DRIVER in setup.conf overrides the detection.
hw_nvidia_driver() {
    local branch
    case "${NVIDIA_DRIVER:-auto}" in
        current|580xx) echo "$NVIDIA_DRIVER"; return ;;
        none) return ;;
    esac
    branch=$(hw_nvidia_branch)
    case "$branch" in
        current|580xx) echo "$branch" ;;
    esac
}

# Laptop whose display runs on an integrated GPU next to an NVIDIA one.
hw_is_hybrid_laptop() {
    [ "$(hw_form_factor)" = laptop ] && hw_has_gpu 10de && [ "$(hw_gpu_count)" -gt 1 ]
}

# Windows shares this machine: its boot manager is in the UEFI boot list, or on
# the ESP Fedora mounts at /boot/efi (a second disk's ESP is not seen). Under a
# fixture root the firmware is not consulted, only the tree.
hw_has_windows() {
    if [ -z "$HW_ROOT" ]; then
        efibootmgr 2>/dev/null | grep -q 'Windows Boot Manager' && return 0
    fi
    find "$HW_ROOT/boot/efi/EFI" -maxdepth 3 -iname bootmgfw.efi 2>/dev/null | grep -q .
}

hw_cpu_vendor() {
    local vendor
    vendor=$(awk -F': ' '/^vendor_id/ { print $2; exit }' "$HW_ROOT/proc/cpuinfo" 2>/dev/null)
    case "$vendor" in
        AuthenticAMD) echo amd ;;
        GenuineIntel) echo intel ;;
        *) echo "${vendor:-unknown}" ;;
    esac
}

# One-line description of what the scripts will adapt to.
hw_summary() {
    local vendor names="" nvidia
    while read -r vendor _; do
        case "$vendor" in
            10de) names+=" NVIDIA" ;;
            1002) names+=" AMD" ;;
            8086) names+=" Intel" ;;
            *) names+=" $vendor" ;;
        esac
    done < <(hw_gpus)
    nvidia=$(hw_nvidia_driver)
    echo "$(hw_form_factor), $(hw_cpu_vendor) CPU, GPU:${names:- none}${nvidia:+ (NVIDIA driver: $nvidia)}$(hw_has_windows && echo ', Windows dual-boot')"
}
