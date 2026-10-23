#!/bin/bash
# Exercise storage and GPU failures without invoking the installed driver.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/backing"
export NVIDIA_PARAMS_FILE="$scratch/params"
cat >"$scratch/bin/findmnt" <<'STUB'
#!/bin/bash
case $* in
    *FSTYPE*) echo "${BACKING_FS:-btrfs}" ;;
    *OPTIONS*) echo "${BACKING_OPTIONS:-rw,relatime}" ;;
esac
STUB
cat >"$scratch/bin/nvidia-smi" <<'STUB'
#!/bin/bash
[ "${GPU_READ_FAIL:-no}" != yes ] || exit 1
printf '%s\n' "${GPU_MEMORY:-8192}"
STUB
cat >"$scratch/bin/df" <<'STUB'
#!/bin/bash
printf 'Avail\n%s\n' "${BACKING_FREE:-18038862644}"
STUB
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH" MEMINFO_FILE="$scratch/meminfo"

write_meminfo() {  # MemAvailable in kB
    printf 'MemTotal:       32000000 kB\nMemAvailable:   %s kB\n' "${1:-20000000}" >"$MEMINFO_FILE"
}
write_meminfo
write_params() {
    printf 'PreserveVideoMemoryAllocations: %s\nTemporaryFilePath: "%s"\n' "${1:-1}" "$scratch/backing" >"$NVIDIA_PARAMS_FILE"
}
reject() {
    if output=$(bash "$repo/system/nvidia-vram-check.sh" 2>&1); then
        echo "FAIL: unsafe backing store was accepted: $*" >&2; exit 1
    fi
    [[ $output == *"$1"* ]] || { echo "FAIL: missing diagnostic: $1" >&2; exit 1; }
}

bash "$repo/system/nvidia-vram-check.sh"
write_params
bash "$repo/system/nvidia-vram-check.sh" >/dev/null
GPU_MEMORY=$'8192\n8192' bash "$repo/system/nvidia-vram-check.sh" >/dev/null
GPU_MEMORY=$'8192\n8192' BACKING_FREE=18038862643 reject 'needs at least'
BACKING_FS=tmpfs bash "$repo/system/nvidia-vram-check.sh" >/dev/null
write_meminfo 4000000
BACKING_FS=tmpfs reject 'needs at least'
BACKING_FS=ramfs reject 'needs at least'
write_meminfo
MEMINFO_FILE="$scratch/missing-meminfo" BACKING_FS=tmpfs reject 'cannot read MemAvailable'
BACKING_OPTIONS=ro,relatime reject 'filesystem is read-only'
BACKING_FREE=1 reject 'needs at least'
BACKING_FREE=unknown reject 'invalid backing-store free space'
GPU_READ_FAIL=yes reject 'cannot read GPU memory capacity'
GPU_MEMORY='N/A' reject 'invalid GPU memory capacity'
GPU_MEMORY=0 reject 'capacity is empty'
write_params 0
reject 'preservation is disabled'
write_params 2
bash "$repo/system/nvidia-vram-check.sh" >/dev/null
printf 'PreserveVideoMemoryAllocations: 1\nTemporaryFilePath: ""\n' >"$NVIDIA_PARAMS_FILE"
write_meminfo 4000000
BACKING_FS=tmpfs reject 'needs at least'
write_meminfo
BACKING_FS=tmpfs bash "$repo/system/nvidia-vram-check.sh" >/dev/null
echo 'All NVIDIA backing-store tests passed.'
