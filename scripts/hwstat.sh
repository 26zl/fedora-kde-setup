#!/bin/bash
# One hardware reading per call, for Conky and sysinfo.sh:
#   hwstat.sh cpu-temp | gpu-name | gpu-temp | gpu-load | gpu-vram
# Handles AMD and Intel CPUs and NVIDIA, AMD and Intel GPUs. Prints nothing
# when a value cannot be read, so callers can leave the field out.

HW_ROOT="${HW_ROOT:-}"

cpu_temp() {
    local want hw name
    # k10temp temp1 is Tctl on AMD, coretemp temp1 the package sensor on Intel
    for want in k10temp zenpower coretemp; do
        for hw in "$HW_ROOT"/sys/class/hwmon/hwmon*; do
            read -r name 2>/dev/null <"$hw/name" || continue
            [ "$name" = "$want" ] || continue
            [ -r "$hw/temp1_input" ] || continue
            awk '{ printf "%.1f°C\n", $1 / 1000 }' "$hw/temp1_input"
            return
        done
    done
}

# First line of an nvidia-smi query; fails when the driver is not running.
nvidia_query() {
    local out
    out=$(nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null) || return 1
    echo "${out%%$'\n'*}"
}

nvidia_gpu() {
    local out
    case "$1" in
        name) out=$(nvidia_query name) && out=${out#NVIDIA } && out=${out#GeForce } ;;
        temp) out=$(nvidia_query temperature.gpu) && out="$out°C" ;;
        load) out=$(nvidia_query utilization.gpu) && out="$out%" ;;
        vram) out=$(nvidia_query memory.used,memory.total) && out="${out%%,*} MiB / ${out##*, } MiB" ;;
    esac || return 1
    echo "$out"
}

# The DRM card with the most VRAM (a discrete AMD card beats its iGPU), else
# the first card.
drm_device() {
    local card best="" best_vram=-2 vram
    for card in "$HW_ROOT"/sys/class/drm/card[0-9]*; do
        [[ ${card##*/} == *-* ]] && continue    # connectors such as card1-DP-1
        [ -e "$card/device/vendor" ] || continue
        vram=-1
        read -r vram 2>/dev/null <"$card/device/mem_info_vram_total"
        if [ "$vram" -gt "$best_vram" ]; then
            best="$card/device"
            best_vram=$vram
        fi
    done
    [ -n "$best" ] && echo "$best"
}

drm_gpu() {
    local dev value used total hw slot
    dev=$(drm_device) || return 0
    case "$1" in
        name)
            slot=$(sed -n 's/^PCI_SLOT_NAME=//p' "$dev/uevent" | head -n 1)
            [ -n "$slot" ] || slot=$(basename "$(readlink -f "$dev")")
            # "Navi 32 [Radeon RX 7800 XT]" -> "Radeon RX 7800 XT"
            lspci -vmm -s "$slot" 2>/dev/null |
                sed -n 's/^Device:[[:space:]]*//p' | sed 's/.*\[\(.*\)\].*/\1/' | head -n 1
            ;;
        temp)
            for hw in "$dev"/hwmon/hwmon*; do
                [ -r "$hw/temp1_input" ] || continue
                awk '{ printf "%.0f°C\n", $1 / 1000 }' "$hw/temp1_input"
                return
            done
            ;;
        load)
            read -r value 2>/dev/null <"$dev/gpu_busy_percent" && echo "$value%"
            ;;
        vram)
            read -r used 2>/dev/null <"$dev/mem_info_vram_used" || return 0
            read -r total 2>/dev/null <"$dev/mem_info_vram_total" || return 0
            echo "$((used / 1048576)) MiB / $((total / 1048576)) MiB"
            ;;
    esac
}

gpu() {
    command -v nvidia-smi >/dev/null && nvidia_gpu "$1" && return
    drm_gpu "$1"
}

case "$1" in
    cpu-temp) cpu_temp ;;
    gpu-name|gpu-temp|gpu-load|gpu-vram) gpu "${1#gpu-}" ;;
    *) echo "usage: ${0##*/} cpu-temp|gpu-name|gpu-temp|gpu-load|gpu-vram" >&2; exit 2 ;;
esac
