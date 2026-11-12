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
[ "${GPU_READ_FAIL:-no}" != mismatch ] || { echo 'Failed to initialize NVML: Driver/library version mismatch'; exit 18; }
printf '%s\n' "${GPU_MEMORY:-8192}"
STUB
cat >"$scratch/bin/df" <<'STUB'
#!/bin/bash
printf 'Avail\n%s\n' "${BACKING_FREE:-18038862644}"
STUB
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH" MEMINFO_FILE="$scratch/meminfo" NVIDIA_VERSION_FILE="$scratch/version"
# a directory that does not exist yet: nothing can be remembered until it does
export NVIDIA_VRAM_STATE="$scratch/state/total-mib"
write_version() {  # module release
    printf 'NVRM version: NVIDIA UNIX %s for x86_64  %s  Release Build  (fixture)\n' "$1" "$2" >"$NVIDIA_VERSION_FILE"
}
write_version 'x86_64 Kernel Module' 580.105.08

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

# with no path, the open module keeps the store in RAM from 615.71.09 on: MemAvailable counts, /tmp does not
write_version 'Open Kernel Module' 615.78.08
BACKING_FREE=1 bash "$repo/system/nvidia-vram-check.sh" | grep -q 'RAM has room' ||
    { echo 'FAIL: the in-RAM store was measured on /tmp' >&2; exit 1; }
write_meminfo 4000000
reject 'RAM needs at least'
write_meminfo
for driver in 'Open Kernel Module|610.57.04' 'x86_64 Kernel Module|615.78.08'; do
    write_version "${driver%|*}" "${driver#*|}"
    BACKING_FREE=1 reject '/tmp needs at least'
done
rm -f "$NVIDIA_VERSION_FILE"
BACKING_FREE=1 reject '/tmp needs at least'

# Between a driver update and the reboot nvidia-smi cannot reach the loaded module: the total it gave before stands in.
write_params
[ ! -e "$scratch/state" ] || { echo 'FAIL: the check created its own state directory' >&2; exit 1; }
GPU_READ_FAIL=mismatch reject 'cannot read GPU memory capacity'
mkdir "$scratch/state"
GPU_MEMORY=$'8192\n4096' bash "$repo/system/nvidia-vram-check.sh" >/dev/null
[ "$(cat "$NVIDIA_VRAM_STATE")" = 12288 ] || { echo 'FAIL: the GPU memory total was not remembered' >&2; exit 1; }
output=$(GPU_READ_FAIL=mismatch bash "$repo/system/nvidia-vram-check.sh" 2>&1) ||
    { echo "FAIL: a driver update refused the suspend: $output" >&2; exit 1; }
[[ $output == *'using the 12288 MiB reported before'* && $output == *'has room for 12288 MiB'* ]] ||
    { echo "FAIL: the remembered total was not used: $output" >&2; exit 1; }
[ "$(cat "$NVIDIA_VRAM_STATE")" = 12288 ] || { echo 'FAIL: a failed read changed the remembered total' >&2; exit 1; }
GPU_READ_FAIL=mismatch BACKING_FREE=1 reject 'needs at least 12903 MiB'
GPU_READ_FAIL=yes reject 'cannot read GPU memory capacity'
for junk in '' 0 012 '12288 MiB' -5; do
    printf '%s\n' "$junk" >"$NVIDIA_VRAM_STATE"
    GPU_READ_FAIL=mismatch reject 'cannot read GPU memory capacity'
done
grep -q 'NVreg_TemporaryFilePath=/var/tmp' "$repo/system/nvidia-580xx-storage.conf" ||
    { echo 'FAIL: 580xx keeps its store on the /tmp tmpfs' >&2; exit 1; }
! grep -q 'TemporaryFilePath' "$repo/system/nvidia-performance.conf" ||
    { echo 'FAIL: the current branch no longer keeps its store in RAM' >&2; exit 1; }
echo 'All NVIDIA backing-store tests passed.'
