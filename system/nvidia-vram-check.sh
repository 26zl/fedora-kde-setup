#!/bin/bash
# Check NVIDIA's active suspend backing store without changing the system.
# Exits nonzero if the store cannot hold all GPU memory plus a five percent margin; a
# RAM-backed store (the default /tmp) is bounded by MemAvailable as well as its own size.

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }
set -euo pipefail

fail() { echo "NVIDIA suspend: $*" >&2; exit 1; }
params=${NVIDIA_PARAMS_FILE:-/proc/driver/nvidia/params}
meminfo=${MEMINFO_FILE:-/proc/meminfo}
[ -e "$params" ] || exit 0
[ -r "$params" ] || fail 'cannot read active driver parameters'
grep -Eq '^PreserveVideoMemoryAllocations: [12]$' "$params" ||
    fail 'video memory preservation is disabled; apply the NVIDIA config and reboot'
backing=$(sed -n 's/^TemporaryFilePath:[[:space:]]*"\(.*\)"$/\1/p' "$params")
backing=${backing:-/tmp}
[[ $backing == /* && -d $backing ]] || fail "backing directory $backing is unavailable"
fstype=$(findmnt -n -o FSTYPE -T "$backing") && [ -n "$fstype" ] || fail 'cannot identify the backing filesystem'
mount_options=$(findmnt -n -o OPTIONS -T "$backing") || fail 'cannot read backing-store mount options'
case ",$mount_options," in *,ro,*) fail 'backing filesystem is read-only' ;; esac

memory=$(timeout 10 nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) ||
    fail 'cannot read GPU memory capacity'
total_mib=0
while IFS= read -r value; do
    [[ $value =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] || fail 'invalid GPU memory capacity'
    total_mib=$((total_mib + 10#${BASH_REMATCH[1]}))
done <<< "$memory"
[ "$total_mib" -gt 0 ] || fail 'GPU memory capacity is empty'
required=$(((total_mib * 1048576 * 105 + 99) / 100))
available=$(df -B1 --output=avail -- "$backing" | awk 'NR == 2 {print $1}') ||
    fail 'cannot read backing-store free space'
[[ $available =~ ^[0-9]+$ ]] || fail 'invalid backing-store free space'
case "$fstype" in
    tmpfs | ramfs)
        # the store lives in RAM, so what the kernel can still hand out caps it, not the tmpfs size
        mem_available=$(awk '/^MemAvailable:/ {print $2 * 1024}' "$meminfo") || fail 'cannot read MemAvailable'
        [[ $mem_available =~ ^[0-9]+$ ]] || fail 'cannot read MemAvailable'
        [ "$available" -le "$mem_available" ] || available=$mem_available
        ;;
esac
[ "$available" -ge "$required" ] ||
    fail "$backing needs at least $(((required + 1048575) / 1048576)) MiB free for ${total_mib} MiB of GPU memory; close a loaded model or game first"
echo "NVIDIA suspend: $backing has room for ${total_mib} MiB of GPU memory plus 5%"
