#!/bin/bash
# Exercise helper failure paths with package, service and hardware commands stubbed.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub"
export SAFE_LOG="$tmp/commands"
: >"$SAFE_LOG"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$stub/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$SAFE_LOG"
case "$*" in
    *restart*) exit 1 ;;
    *show*) [ "${RESERVE:-yes}" = yes ] && echo 'Environment=OLLAMA_GPU_OVERHEAD=3221225472'; exit 0 ;;
    *) exit 1 ;;
esac
STUB
cat >"$stub/id" <<'STUB'
#!/bin/bash
if [ "$#" -gt 1 ]; then echo 4242; else echo 0; fi
STUB
cat >"$stub/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$SAFE_LOG"
STUB
cat >"$stub/rm" <<'STUB'
#!/bin/bash
printf 'rm %s\n' "$*" >>"$SAFE_LOG"
STUB
cat >"$stub/docker" <<'STUB'
#!/bin/bash
printf 'docker %s\n' "$*" >>"$SAFE_LOG"
case "$1" in info|volume) exit 0 ;; *) exit 1 ;; esac
STUB
cat >"$stub/flatpak" <<'STUB'
#!/bin/bash
case "$1" in info) echo 'Version: 1.0'; exit 0 ;; *) exit 1 ;; esac
STUB
cat >"$stub/df" <<'STUB'
#!/bin/bash
case "$*" in *-BM*) printf 'Avail\n2048M\n' ;; *) printf 'Avail\n20G\n' ;; esac
STUB
cat >"$stub/findmnt" <<'STUB'
#!/bin/bash
case "$*" in *FSTYPE*) echo btrfs ;; *SOURCE*) echo /dev/fake ;; esac
STUB
for command in snapper mokutil; do
    printf '#!/bin/bash\nexit 1\n' >"$stub/$command"
done
printf '#!/bin/bash\nexit 0\n' >"$stub/dnf"
printf '#!/bin/bash\nexit 0\n' >"$stub/podman"
cat >"$stub/nvidia-smi" <<'STUB'
#!/bin/bash
echo "${VRAM:-3000}"
STUB
printf '#!/bin/bash\nexit 0\n' >"$stub/curl"
cat >"$stub/btrfs" <<'STUB'
#!/bin/bash
[ "$1" != scrub ]
STUB
chmod +x "$stub"/*

if output=$(PATH="$stub:$PATH" bash "$repo/scripts/rice-start.sh" 2>&1); then
    fail "rice-start accepted a failed service restart"
fi
[[ $output != *"Rice is live"* ]] || fail "rice-start printed success after a failure"

output=$(PATH="$stub:$PATH" SUDO_USER=fixture bash "$repo/scripts/disk-cleanup.sh" --yes)
grep -q 'podman image prune -af$' "$SAFE_LOG" || fail "cleanup did not prune only Podman images"
! grep -q 'podman system prune' "$SAFE_LOG" || fail "cleanup can delete stopped Podman containers"
[[ $output == *"docker: image cleanup failed"* ]] || fail "Docker image failure was hidden"
[[ $output == *"docker: build cache cleanup failed"* ]] || fail "Docker build failure was hidden"

if output=$(PATH="$stub:$PATH" bash "$repo/scripts/mok-reenroll.sh" 2>&1); then
    fail "mok-reenroll accepted an unreadable Secure Boot state"
fi
[[ $output == *"cannot determine Secure Boot state"* ]] || fail "missing Secure Boot failure diagnostic"

cat >"$stub/ollama" <<'STUB'
#!/bin/bash
case "$1" in
    --version) echo 'ollama version is 0.40.8' ;;
    list|ps) echo 'gemma4-12b-heretic 100%/GPU' ;;
    show) [ "${CAP:-yes}" = yes ] && echo 'PARAMETER num_gpu 30'; exit 0 ;;
    stop) exit 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$stub/ollama"
cat >"$tmp/verify.sh" <<'TEST'
#!/bin/bash
set -euo pipefail
# Source only function definitions and constants, before the install/test dispatch.
# shellcheck disable=SC1090
source <(sed '/^if \[ "${1:-}" = test \]; then/,$d' "$HELPER_REPO/scripts/ollama-setup.sh")
OLLAMA="$HELPER_STUB/ollama"
verify
TEST
export HELPER_REPO="$repo" HELPER_STUB="$stub"
PATH="$stub:$PATH" bash "$tmp/verify.sh" >"$tmp/verify.out" || fail "healthy Ollama verification failed"
if PATH="$stub:$PATH" VRAM=1000 bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted insufficient free VRAM"
fi
if PATH="$stub:$PATH" RESERVE=no bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted a missing service VRAM reserve"
fi
if PATH="$stub:$PATH" CAP=no bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted a model without its GPU layer limit"
fi

if [ "$EUID" -ne 0 ]; then
    mkdir -p "$tmp/checkout/.git" "$tmp/hw/sys/bus/pci/devices/0000:01:00.0"
    printf '0x030000\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/class"
    printf '0x10de\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/vendor"
    printf '0x2f04\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/device"
    cat >"$stub/git" <<'STUB'
#!/bin/bash
case "$*" in
    *rev-parse*) echo "${GIT_PIN:-unreviewed-revision}" ;;
    *diff*) exit 1 ;;
    *) exit 1 ;;
esac
STUB
    cat >"$stub/uname" <<'STUB'
#!/bin/bash
case "$1" in -r) echo fixture-kernel ;; *) echo x86_64 ;; esac
STUB
    chmod +x "$stub/git" "$stub/uname"
    : >"$SAFE_LOG"
    if output=$(PATH="$stub:$PATH" HW_ROOT="$tmp/hw" STRATA_DIR="$tmp/checkout" STRATA_DATA="$tmp/model-data" \
        bash "$repo/scripts/strata-setup.sh" 2>&1); then
        fail "Strata accepted an unpinned existing checkout"
    fi
    [[ $output == *"is not at pinned revision"* ]] || fail "missing Strata revision failure diagnostic"
    pin=$(awk -F'[= ]' '/^STRATA_REV=/{print $2}' "$repo/scripts/strata-setup.sh")
    if output=$(PATH="$stub:$PATH" HW_ROOT="$tmp/hw" STRATA_DIR="$tmp/checkout" STRATA_DATA="$tmp/model-data" \
        GIT_PIN="$pin" bash "$repo/scripts/strata-setup.sh" 2>&1); then
        fail "Strata accepted modified tracked setup code"
    fi
    [[ $output == *"has tracked changes"* ]] || fail "missing Strata tracked-change diagnostic"
    [ ! -e "$tmp/model-data" ] || fail "Strata created model storage before validating the checkout"
    ! grep -q '^sudo ' "$SAFE_LOG" || fail "Strata changed system packages before validating the checkout"

    cat >"$stub/rpm" <<'STUB'
#!/bin/bash
case "$1" in -E) echo 44 ;; *) echo fixture-kernel ;; esac
STUB
    printf '#!/bin/bash\necho 200\n' >"$stub/curl"
    chmod +x "$stub/rpm" "$stub/curl"
    if output=$(PATH="$stub:$PATH" HW_ROOT="$tmp/hw" bash "$repo/scripts/fedora-upgrade.sh" --yes 2>&1); then
        fail "fedora-upgrade accepted an unreadable Secure Boot state"
    fi
    [[ $output == *"cannot determine Secure Boot state; verify it before upgrading"* ]] || fail "missing upgrade Secure Boot failure diagnostic"
    ! grep -q 'system-upgrade' "$SAFE_LOG" || fail "upgrade download began without Secure Boot validation"
fi

cat >"$stub/lsblk" <<'STUB'
#!/bin/bash
case "$*" in
    *TRAN*)
        if [ "${SMART_MULTIPLE:-no}" = yes ]; then
            printf '/dev/nvmeA disk nvme\n/dev/nvmeB disk nvme\n/dev/sataA disk sata\n/dev/sataB disk sata\n/dev/vda disk virtio\n/dev/sataA1 part sata\n'
        else
            echo '/dev/fake disk nvme'
        fi ;;
esac
STUB
cat >"$stub/smartctl" <<'STUB'
#!/bin/bash
printf 'smartctl %s\n' "$*" >>"$SAFE_LOG"
disk=${*: -1}
state="$SMART_STATE_DIR/${disk##*/}.started"
busy=no
[ "$disk" != "${SMART_BUSY_DEVICE:-}" ] || busy=yes
if [ -f "$state" ] && [ "${SMART_FINISH:-no}" != yes ]; then busy=yes; fi
case "$1" in
    -t) [ "${NVME_START:-no}" = yes ] || exit 1; touch "$state" ;;
    -c)
        [ "$disk" != "${SMART_CAP_FAIL_DEVICE:-}" ] || exit 1
        case "$disk" in
            *sata*)
                if [ "$disk" = "${SMART_UNSUPPORTED_DEVICE:-}" ]; then
                    echo 'No Self-test supported.'
                else
                    echo 'Self-test supported.'
                    if [ "$busy" = yes ]; then echo 'Self-test execution status: ( 249) Self-test routine in progress...'
                    else echo 'Self-test execution status: ( 0) Previous self-test completed without error'; fi
                fi ;;
            *) echo 'Optional Admin Commands (0x0017): Security Format Frmw_DL Self_Test' ;;
        esac ;;
    -l)
        if [[ $disk == *sata* ]]; then index='# 1'; else
            index=0
            if [ "$busy" = yes ]; then echo 'Self-test status: Short self-test in progress'
            else echo 'Self-test status: No self-test in progress'; fi
        fi
        if [ "$disk" = "${SMART_RESULT_FAIL_DEVICE:-}" ]; then echo "$index Short Completed: read failure"
        else echo "$index Short Completed without error"; fi ;;
    -H)
        [ "${AUDIT_READ_FAIL:-no}" != yes ] || exit 1
        if [ "$disk" = "${SMART_FAIL_DEVICE:-}" ]; then
            echo 'SMART overall-health self-assessment test result: FAILED'; exit 8
        fi
        echo 'SMART overall-health self-assessment test result: PASSED' ;;
    -A) [ "${AUDIT_READ_FAIL:-no}" != yes ]; exit ;;
    *) exit 0 ;;
esac
STUB
for command in dmidecode sensors efibootmgr lspci ntfsfix tune2fs getenforce systemd-analyze sleep; do
    printf '#!/bin/bash\nexit 0\n' >"$stub/$command"
done
for command in dmesg journalctl; do
    cat >"$stub/$command" <<'STUB'
#!/bin/bash
[ "${AUDIT_READ_FAIL:-no}" != yes ]
STUB
done
chmod +x "$stub"/*
export SMART_STATE_DIR="$tmp/smart-state"
mkdir "$SMART_STATE_DIR"
if output=$(PATH="$stub:$PATH" bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "deep-health accepted failed checks"
fi
[[ $output == *"could not start self-test; no new result to report"* ]] || fail "missing NVMe failure diagnostic"
[[ $output != *"self-test passed"* ]] || fail "a stale NVMe result was reported as a new pass"
[ "$(grep -c 'smartctl -l selftest' "$SAFE_LOG")" -eq 1 ] || fail "failed NVMe startup still polled old results"
[[ $output == *"cannot read btrfs error counters"* ]] || fail "unreadable btrfs counters were treated as healthy"
[[ $output == *"btrfs scrub failed or reported uncorrectable errors"* ]] || fail "failed btrfs scrub was hidden"
[[ $output == *"cannot read failed systemd units"* ]] || fail "unreadable systemd state was treated as healthy"

if output=$(PATH="$stub:$PATH" AUDIT_READ_FAIL=yes bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "deep-health accepted unreadable diagnostics"
fi
[[ $output == *"cannot read kernel log"* ]] || fail "unreadable kernel log was treated as healthy"
[[ $output == *"cannot read journal errors"* ]] || fail "unreadable journal was treated as healthy"
[[ $output == *"SMART health query failed"* ]] || fail "failed SMART health query was hidden"
[[ $output == *"cannot read SMART attributes"* ]] || fail "failed SMART attribute query was hidden"

if output=$(PATH="$stub:$PATH" NVME_START=yes bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "deep-health accepted an unfinished self-test"
fi
[[ $output == *"self-test did not finish within 450 seconds"* ]] || fail "self-test timeout was hidden"
[[ $output != *"self-test passed"* ]] || fail "timed-out self-test reported a stale result"

mkdir "$tmp/smart-multi"
: >"$SAFE_LOG"
if output=$(PATH="$stub:$PATH" SMART_STATE_DIR="$tmp/smart-multi" SMART_MULTIPLE=yes NVME_START=yes SMART_FINISH=yes \
    SMART_FAIL_DEVICE=/dev/nvmeB SMART_RESULT_FAIL_DEVICE=/dev/sataA SMART_UNSUPPORTED_DEVICE=/dev/sataB \
    bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "multi-disk audit accepted device errors"
fi
for disk in /dev/nvmeA /dev/nvmeB /dev/sataA /dev/sataB; do
    grep -q "smartctl -H $disk$" "$SAFE_LOG" || fail "SMART health omitted $disk"
    grep -q "smartctl -A $disk$" "$SAFE_LOG" || fail "SMART attributes omitted $disk"
done
[[ $output == *"/dev/nvmeA: self-test passed"* ]] || fail "a healthy NVMe disk was not tested"
[[ $output == *"/dev/nvmeB: SMART health query failed"* ]] || fail "second NVMe failure was hidden"
[[ $output == *"/dev/sataA: self-test:"* ]] || fail "SATA self-test failure was hidden"
[[ $output == *"/dev/sataB: short self-tests not supported; skipped"* ]] || fail "unsupported SATA self-test was not reported"
! grep -q 'smartctl -t short /dev/sataB' "$SAFE_LOG" || fail "unsupported SATA self-test was started"
! grep -q 'smartctl -t short /dev/nvmeB' "$SAFE_LOG" || fail "a self-test was started after failed SMART health"
! grep -q 'smartctl .* /dev/vda\|smartctl .* /dev/sataA1' "$SAFE_LOG" || fail "unsupported devices or partitions were tested"

mkdir "$tmp/smart-busy"
: >"$SAFE_LOG"
if output=$(PATH="$stub:$PATH" SMART_STATE_DIR="$tmp/smart-busy" SMART_MULTIPLE=yes NVME_START=yes SMART_FINISH=yes \
    SMART_BUSY_DEVICE=/dev/nvmeB SMART_CAP_FAIL_DEVICE=/dev/sataB bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "multi-disk audit accepted skipped diagnostics"
fi
[[ $output == *"/dev/nvmeB: another self-test is running; left unchanged"* ]] || fail "running NVMe test was not preserved"
[[ $output == *"/dev/sataA: self-test passed"* ]] || fail "supported SATA short test did not complete"
[[ $output == *"/dev/sataB: cannot read self-test capabilities"* ]] || fail "unreadable SATA capabilities were hidden"
! grep -q 'smartctl -t short /dev/nvmeB\|smartctl -t short /dev/sataB' "$SAFE_LOG" || fail "a busy or unreadable disk test was started"

mkdir "$tmp/smart-sata-busy"
: >"$SAFE_LOG"
if output=$(PATH="$stub:$PATH" SMART_STATE_DIR="$tmp/smart-sata-busy" SMART_MULTIPLE=yes NVME_START=yes SMART_FINISH=yes \
    SMART_BUSY_DEVICE=/dev/sataA bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "multi-disk audit accepted a skipped SATA diagnostic"
fi
[[ $output == *"/dev/sataA: another self-test is running; left unchanged"* ]] || fail "running SATA test was not preserved"
! grep -q 'smartctl -t short /dev/sataA' "$SAFE_LOG" || fail "a running SATA self-test was replaced"

echo "All helper script failure-path tests passed."
