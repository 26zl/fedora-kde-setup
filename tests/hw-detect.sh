#!/bin/bash
# Runs scripts/lib/hw.sh and scripts/hwstat.sh against fixture sysfs trees and
# stub commands, one fixture per kind of machine the setup has to handle.
# HW_ROOT, FORM_FACTOR and NVIDIA_DRIVER are read by the sourced functions.
# shellcheck disable=SC2034
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

check() {  # description expected actual
    if [ "$2" != "$3" ]; then
        echo "FAIL: $1: expected '$2', got '$3'" >&2
        failures=$((failures + 1))
    fi
}

yes_no() { if "$@"; then echo yes; else echo no; fi; }

pci() {  # root slot vendor device [class]
    local dev="$1/sys/bus/pci/devices/$2"
    mkdir -p "$dev"
    echo "${5:-0x030000}" >"$dev/class"
    echo "0x$3" >"$dev/vendor"
    echo "0x$4" >"$dev/device"
}

chassis() {  # root type
    mkdir -p "$1/sys/class/dmi/id"
    echo "$2" >"$1/sys/class/dmi/id/chassis_type"
}

battery() {  # root name [scope]
    mkdir -p "$1/sys/class/power_supply/$2"
    echo Battery >"$1/sys/class/power_supply/$2/type"
    if [ -n "${3:-}" ]; then echo "$3" >"$1/sys/class/power_supply/$2/scope"; fi
}

cpu() {  # root vendor_id
    mkdir -p "$1/proc"
    printf 'processor\t: 0\nvendor_id\t: %s\n' "$2" >"$1/proc/cpuinfo"
}

stub() {  # name body
    printf '#!/bin/bash\n%s\n' "$2" >"$tmp/bin/$1"
    chmod +x "$tmp/bin/$1"
}

mkdir -p "$tmp/bin"
PATH="$tmp/bin:$PATH"
stub efibootmgr 'exit 0'

# shellcheck source=scripts/lib/hw.sh
source "$repo/scripts/lib/hw.sh"

# A desktop: AMD CPU with its integrated GPU plus a discrete RTX card. The
# NVIDIA HDMI audio function (class 0403) must not count as a GPU.
desk="$tmp/desktop"
cpu "$desk" AuthenticAMD
chassis "$desk" 3
pci "$desk" 0000:01:00.0 10de 2882
pci "$desk" 0000:01:00.1 10de 22be 0x040300
pci "$desk" 0000:7c:00.0 1002 164e
HW_ROOT="$desk"
check "desktop: GPU count" 2 "$(hw_gpu_count)"
check "desktop: form factor" desktop "$(hw_form_factor)"
check "desktop: NVIDIA branch" current "$(hw_nvidia_branch)"
check "desktop: NVIDIA driver" current "$(hw_nvidia_driver)"
check "desktop: has AMD GPU" yes "$(yes_no hw_has_gpu 1002)"
check "desktop: has Intel GPU" no "$(yes_no hw_has_gpu 8086)"
check "desktop: hybrid laptop" no "$(yes_no hw_is_hybrid_laptop)"
check "desktop: CPU vendor" amd "$(hw_cpu_vendor)"
check "desktop: no Windows" no "$(yes_no hw_has_windows)"
# the firmware boot list is only read on a real system (empty HW_ROOT)
stub efibootmgr "echo 'Boot0000* Windows Boot Manager	HD(1,GPT,...)'"
check "desktop: boot list ignored under a fixture root" no "$(yes_no hw_has_windows)"
check "desktop: Windows in the boot list" yes "$(HW_ROOT="" yes_no hw_has_windows)"
stub efibootmgr 'exit 0'
mkdir -p "$desk/boot/efi/EFI/Microsoft/Boot"
touch "$desk/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"
check "desktop: Windows on the ESP only" yes "$(yes_no hw_has_windows)"
check "desktop: summary" \
    "desktop, amd CPU, GPU: NVIDIA AMD (NVIDIA driver: current), Windows dual-boot" "$(hw_summary)"

FORM_FACTOR=laptop
check "override: FORM_FACTOR" laptop "$(hw_form_factor)"
check "override: hybrid follows FORM_FACTOR" yes "$(yes_no hw_is_hybrid_laptop)"
FORM_FACTOR=auto
NVIDIA_DRIVER=none
check "override: NVIDIA_DRIVER=none" "" "$(hw_nvidia_driver)"
NVIDIA_DRIVER=580xx
check "override: NVIDIA_DRIVER=580xx" 580xx "$(hw_nvidia_driver)"
unset NVIDIA_DRIVER FORM_FACTOR

# setup.conf validation: a typo must fail, not fall back to detection
check "conf: defaults valid" yes "$(yes_no hw_check_conf)"
check "conf: FORM_FACTOR=Laptop rejected" no "$(FORM_FACTOR=Laptop yes_no hw_check_conf 2>/dev/null)"
check "conf: NVIDIA_DRIVER=latest rejected" no "$(NVIDIA_DRIVER=latest yes_no hw_check_conf 2>/dev/null)"
check "conf: AUDIO_TRIM=true rejected" no "$(AUDIO_TRIM=true yes_no hw_check_conf 2>/dev/null)"
check "conf: all overrides valid" yes "$(FORM_FACTOR=laptop NVIDIA_DRIVER=none AUDIO_TRIM=yes yes_no hw_check_conf)"

# Driver branch boundaries: Maxwell starts at 0x1340, Turing at 0x1e00.
for case in 133f:none 1340:580xx 1b80:580xx 1db1:580xx 1e04:current 2204:current; do
    root="$tmp/nvidia-${case%%:*}"
    pci "$root" 0000:01:00.0 10de "${case%%:*}"
    HW_ROOT="$root"
    check "NVIDIA device ${case%%:*}: branch" "${case##*:}" "$(hw_nvidia_branch)"
done
HW_ROOT="$tmp/nvidia-133f"
check "Kepler: no driver installed" "" "$(hw_nvidia_driver)"

# Intel + NVIDIA notebook; the dGPU is a 3D controller (class 0302).
hybrid="$tmp/hybrid"
cpu "$hybrid" GenuineIntel
chassis "$hybrid" 10
pci "$hybrid" 0000:00:02.0 8086 46a6
pci "$hybrid" 0000:01:00.0 10de 25a2 0x030200
HW_ROOT="$hybrid"
check "hybrid: form factor" laptop "$(hw_form_factor)"
check "hybrid: hybrid laptop" yes "$(yes_no hw_is_hybrid_laptop)"
check "hybrid: CPU vendor" intel "$(hw_cpu_vendor)"

# Firmware without a useful chassis type: a system battery means laptop, a
# mouse battery (scope Device) does not.
root="$tmp/unknown-battery"
chassis "$root" 2
battery "$root" BAT0
HW_ROOT="$root"
check "unknown chassis + system battery" laptop "$(hw_form_factor)"
root="$tmp/unknown-mouse"
chassis "$root" 1
battery "$root" hidpp_battery_0 Device
HW_ROOT="$root"
check "unknown chassis + mouse battery" desktop "$(hw_form_factor)"

root="$tmp/no-gpu"
mkdir -p "$root/sys/bus/pci/devices"
HW_ROOT="$root"
check "no GPU: branch" "" "$(hw_nvidia_branch)"
check "no GPU: summary" "desktop, unknown CPU, GPU: none" "$(hw_summary)"

# hwstat.sh: CPU temperature from k10temp or coretemp, skipping other sensors.
root="$tmp/hwmon-amd"
mkdir -p "$root/sys/class/hwmon/hwmon0" "$root/sys/class/hwmon/hwmon1"
echo nvme >"$root/sys/class/hwmon/hwmon0/name"
echo 30000 >"$root/sys/class/hwmon/hwmon0/temp1_input"
echo k10temp >"$root/sys/class/hwmon/hwmon1/name"
echo 45125 >"$root/sys/class/hwmon/hwmon1/temp1_input"
check "hwstat: k10temp" "45.1°C" "$(HW_ROOT="$root" bash "$repo/scripts/hwstat.sh" cpu-temp)"
root="$tmp/hwmon-intel"
mkdir -p "$root/sys/class/hwmon/hwmon2"
echo coretemp >"$root/sys/class/hwmon/hwmon2/name"
echo 52000 >"$root/sys/class/hwmon/hwmon2/temp1_input"
check "hwstat: coretemp" "52.0°C" "$(HW_ROOT="$root" bash "$repo/scripts/hwstat.sh" cpu-temp)"
check "hwstat: no sensor" "" "$(HW_ROOT="$tmp/no-gpu" bash "$repo/scripts/hwstat.sh" cpu-temp)"

# hwstat.sh: NVIDIA through nvidia-smi. Stub bodies are scripts of their own,
# so their $1 is meant literally.
# shellcheck disable=SC2016
stub nvidia-smi 'case "$1" in
  --query-gpu=name) echo "NVIDIA GeForce RTX 4060" ;;
  --query-gpu=temperature.gpu) echo 48 ;;
  --query-gpu=utilization.gpu) echo 7 ;;
  --query-gpu=memory.used,memory.total) echo "1234, 8188" ;;
esac'
check "hwstat: NVIDIA name" "RTX 4060" "$(bash "$repo/scripts/hwstat.sh" gpu-name)"
check "hwstat: NVIDIA temp" "48°C" "$(bash "$repo/scripts/hwstat.sh" gpu-temp)"
check "hwstat: NVIDIA load" "7%" "$(bash "$repo/scripts/hwstat.sh" gpu-load)"
check "hwstat: NVIDIA vram" "1234 MiB / 8188 MiB" "$(bash "$repo/scripts/hwstat.sh" gpu-vram)"

# hwstat.sh: nvidia-smi present but no driver loaded -> sysfs. The discrete AMD
# card (most VRAM) wins over the iGPU; connector entries are skipped.
stub nvidia-smi 'echo "NVIDIA-SMI has failed"; exit 9'
stub lspci 'case "$*" in
  *0000:03:00.0*) printf "Slot:\t03:00.0\nDevice:\tNavi 32 [Radeon RX 7800 XT]\n" ;;
  *0000:00:02.0*) printf "Slot:\t00:02.0\nDevice:\tAlder Lake-P GT2 [Iris Xe Graphics]\n" ;;
esac'
amd="$tmp/drm-amd"
for slot in 0000:03:00.0 0000:7c:00.0; do
    mkdir -p "$amd/sys/devices/pci0000:00/$slot"
    echo 0x1002 >"$amd/sys/devices/pci0000:00/$slot/vendor"
done
echo 536870912 >"$amd/sys/devices/pci0000:00/0000:7c:00.0/mem_info_vram_total"
dgpu="$amd/sys/devices/pci0000:00/0000:03:00.0"
echo 17163091968 >"$dgpu/mem_info_vram_total"
echo 1073741824 >"$dgpu/mem_info_vram_used"
echo 12 >"$dgpu/gpu_busy_percent"
mkdir -p "$dgpu/hwmon/hwmon3"
echo 55000 >"$dgpu/hwmon/hwmon3/temp1_input"
mkdir -p "$amd/sys/class/drm/card0" "$amd/sys/class/drm/card1" "$amd/sys/class/drm/card1-DP-1"
ln -s "$amd/sys/devices/pci0000:00/0000:7c:00.0" "$amd/sys/class/drm/card0/device"
ln -s "$dgpu" "$amd/sys/class/drm/card1/device"
check "hwstat: AMD name" "Radeon RX 7800 XT" "$(HW_ROOT="$amd" bash "$repo/scripts/hwstat.sh" gpu-name)"
check "hwstat: AMD temp" "55°C" "$(HW_ROOT="$amd" bash "$repo/scripts/hwstat.sh" gpu-temp)"
check "hwstat: AMD load" "12%" "$(HW_ROOT="$amd" bash "$repo/scripts/hwstat.sh" gpu-load)"
check "hwstat: AMD vram" "1024 MiB / 16368 MiB" "$(HW_ROOT="$amd" bash "$repo/scripts/hwstat.sh" gpu-vram)"

# hwstat.sh: Intel iGPU only has a name to show.
intel="$tmp/drm-intel"
mkdir -p "$intel/sys/devices/pci0000:00/0000:00:02.0" "$intel/sys/class/drm/card0"
echo 0x8086 >"$intel/sys/devices/pci0000:00/0000:00:02.0/vendor"
ln -s "$intel/sys/devices/pci0000:00/0000:00:02.0" "$intel/sys/class/drm/card0/device"
check "hwstat: Intel name" "Iris Xe Graphics" "$(HW_ROOT="$intel" bash "$repo/scripts/hwstat.sh" gpu-name)"
check "hwstat: Intel temp" "" "$(HW_ROOT="$intel" bash "$repo/scripts/hwstat.sh" gpu-temp)"
check "hwstat: Intel vram" "" "$(HW_ROOT="$intel" bash "$repo/scripts/hwstat.sh" gpu-vram)"

if ((failures > 0)); then
    exit 1
fi
echo "All hardware detection tests passed."
