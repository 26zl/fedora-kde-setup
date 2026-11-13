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
    *show*)
        env=""
        [ "${LIMIT:-yes}" = no ] || env+=" OLLAMA_MAX_LOADED_MODELS=1"
        [ "${RESERVE:-yes}" = no ] || env+=" OLLAMA_GPU_OVERHEAD=3221225472"
        echo "Environment=${env# }"
        exit 0 ;;
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

cleanup_root="$tmp/cleanup-root"
mkdir -p "$cleanup_root/.fedora-kde-setup-backups/run-a" "$cleanup_root/var/cache/PackageKit"
: >"$cleanup_root/.fedora-kde-setup-backups/run-a/READY"
cleanup() { PATH="$stub:$PATH" SUDO_USER=fixture DISK_CLEANUP_ROOT="$cleanup_root" bash "$repo/scripts/disk-cleanup.sh" "$@"; }
: >"$SAFE_LOG"
output=$(cleanup --yes </dev/null)
! grep -qE 'image prune|builder prune' "$SAFE_LOG" || fail "--yes removed container images without a confirmation"
! grep -q "^rm -rf $cleanup_root/.fedora-kde-setup-backups" "$SAFE_LOG" || fail "--yes deleted a restore point"
[[ $output == *"container images are only removed after an interactive confirmation"* ]] || fail "--yes kept images silently"
# prompts: restore points, then container images
: >"$SAFE_LOG"
output=$(printf 'n\ny\n' | cleanup)
grep -q 'podman image prune -af$' "$SAFE_LOG" || fail "cleanup did not prune only Podman images"
! grep -q 'podman system prune' "$SAFE_LOG" || fail "cleanup can delete stopped Podman containers"
[[ $output == *"docker: image cleanup failed"* ]] || fail "Docker image failure was hidden"
[[ $output == *"docker: build cache cleanup failed"* ]] || fail "Docker build failure was hidden"
! grep -q "^rm -rf $cleanup_root/.fedora-kde-setup-backups" "$SAFE_LOG" || fail "a declined restore point was deleted"
: >"$SAFE_LOG"
printf 'y\nn\n' | cleanup >/dev/null
grep -q "^rm -rf $cleanup_root/.fedora-kde-setup-backups/run-a$" "$SAFE_LOG" || fail "a confirmed restore point was kept"
! grep -qE 'image prune|builder prune' "$SAFE_LOG" || fail "declined container images were removed"
: >"$SAFE_LOG"
output=$(printf 'y\ny\ny\n' | cleanup --dry-run)
! grep -qE 'prune|^rm |^systemctl stop' "$SAFE_LOG" || fail "a dry run changed something: $(cat "$SAFE_LOG")"
[[ $output == *"would clear $cleanup_root/var/cache/PackageKit"* && $output == *"dry run: nothing changed"* ]] ||
    fail "a dry run did not list what would go"

if output=$(PATH="$stub:$PATH" bash "$repo/scripts/mok-reenroll.sh" 2>&1); then
    fail "mok-reenroll accepted an unreadable Secure Boot state"
fi
[[ $output == *"cannot determine Secure Boot state"* ]] || fail "missing Secure Boot failure diagnostic"
mkdir -p "$tmp/mokbin" "$tmp/certs"
cat >"$tmp/mokbin/mokutil" <<'STUB'
#!/bin/bash
printf 'mokutil %s\n' "$*" >>"$SAFE_LOG"
case "$1" in
    --sb-state) echo "${MOK_SB:-SecureBoot enabled}" ;;
    --test-key) if [ "${MOK_ENROLLED:-no}" = yes ]; then echo "$2 is already enrolled"; else echo "$2 is not enrolled"; fi ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' >"$tmp/mokbin/lspci"
printf '#!/bin/bash\nexit 0\n' >"$tmp/mokbin/lsmod"
chmod +x "$tmp/mokbin"/*
mok() { PATH="$tmp/mokbin:$stub:$PATH" MOK_CERT_DIR="$tmp/certs" bash "$repo/scripts/mok-reenroll.sh" </dev/null 2>&1; }
: >"$SAFE_LOG"
output=$(MOK_SB='SecureBoot disabled' mok) || fail "mok-reenroll failed with Secure Boot off"
[[ $output == *"nothing to enroll"* ]] || fail "Secure Boot off was not reported"
if output=$(MOK_SB='SecureBoot unknown' mok); then fail "mok-reenroll accepted an unknown Secure Boot state"; fi
if output=$(mok); then fail "mok-reenroll went on without a signing key"; fi
[[ $output == *"no signing key under $tmp/certs"* ]] || fail "a missing signing key was not reported"
: >"$tmp/certs/public_key.der"
output=$(MOK_ENROLLED=yes mok) || fail "an enrolled key was treated as a failure"
[[ $output == *"already enrolled"* ]] || fail "an enrolled key was not recognised"
if output=$(mok); then fail "mok-reenroll imported a key without a terminal"; fi
[[ $output == *"needs an interactive terminal"* ]] || fail "no terminal refusal before the import"
! grep -q 'mokutil --import' "$SAFE_LOG" || fail "a key was imported without a confirmation"

cat >"$stub/ollama" <<'STUB'
#!/bin/bash
case "$1" in
    --version) echo 'ollama version is 0.40.10' ;;
    list|ps) echo 'gemma4-12b-heretic 100%/GPU' ;;
    show) [ "${CAP:-yes}" = yes ] && echo 'PARAMETER num_gpu 30'; exit 0 ;;
    stop) exit 0 ;;
    *) exit 1 ;;
esac
STUB
cat >"$stub/journalctl" <<'STUB'
#!/bin/bash
case "$*" in *"-u ollama"*) echo "level=INFO msg=\"inference compute\" id=0 library=${BACKEND:-CUDA} name=GPU0" ;; esac
STUB
chmod +x "$stub/ollama" "$stub/journalctl"
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
if PATH="$stub:$PATH" LIMIT=no bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted a service without its one-model limit"
fi
if PATH="$stub:$PATH" CAP=no bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted a model without its GPU layer limit"
fi
if PATH="$stub:$PATH" BACKEND=Vulkan bash "$tmp/verify.sh" >"$tmp/verify.out"; then
    fail "Ollama accepted the Vulkan fallback"
fi

if [ "$EUID" -ne 0 ]; then
    mkdir -p "$tmp/hw/sys/bus/pci/devices/0000:01:00.0"
    printf '0x030000\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/class"
    printf '0x10de\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/vendor"
    printf '0x2f04\n' >"$tmp/hw/sys/bus/pci/devices/0000:01:00.0/device"
    cat >"$stub/uname" <<'STUB'
#!/bin/bash
case "$1" in -r) echo fixture-kernel ;; *) echo x86_64 ;; esac
STUB
    chmod +x "$stub/uname"
    # a stand-in for Strata's repository: releases v0.1.0 and v0.2.0, then an untagged commit
    sgit() { git -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
    origin="$tmp/strata-origin"
    git init -q -b main "$origin"
    cat >"$origin/setup.sh" <<'STUB'
#!/bin/bash
printf 'strata-setup %s\n' "$*" >>"$SAFE_LOG"
printf '{}\n' >"$(dirname "$0")/strata-coder-iq1_m.json"
STUB
    chmod +x "$origin/setup.sh"
    sgit -C "$origin" add setup.sh
    sgit -C "$origin" commit -q -m one && sgit -C "$origin" tag v0.1.0
    sgit -C "$origin" commit -q --allow-empty -m two && sgit -C "$origin" tag v0.2.0
    sgit -C "$origin" commit -q --allow-empty -m three
    v1=$(git -C "$origin" rev-parse v0.1.0) v2=$(git -C "$origin" rev-parse v0.2.0) v3=$(git -C "$origin" rev-parse main)
    # rm is the logging stub inside the script, so removals are read from SAFE_LOG
    checkout() {  # commit: a clone of the stand-in at that commit
        rm -rf "$tmp/strata" "$tmp/model-data"
        git clone -q "$origin" "$tmp/strata" && git -C "$tmp/strata" reset -q --hard "$1"
        : >"$SAFE_LOG"
    }
    run_strata() {  # STRATA_REV expected-exit
        output=$(PATH="$stub:$PATH" HW_ROOT="$tmp/hw" STRATA_DIR="$tmp/strata" STRATA_DATA="$tmp/model-data" \
            STRATA_REV="$1" bash "$repo/scripts/strata-setup.sh" 2>&1) && rc=0 || rc=$?
        [ "$rc" -eq "$2" ] || fail "strata-setup.sh with STRATA_REV=$1 exited $rc, want $2: $output"
    }
    at() { [ "$(git -C "$tmp/strata" rev-parse HEAD)" = "$1" ] || fail "$2"; }
    untouched() {  # what a refused run must leave alone
        [ ! -e "$tmp/model-data" ] || fail "Strata created model storage before validating the checkout"
        ! grep -q '^sudo ' "$SAFE_LOG" || fail "Strata changed system packages before validating the checkout"
        ! grep -q "^rm -rf $tmp/strata/build" "$SAFE_LOG" || fail "a refused Strata run removed the built engine"
    }

    checkout "$v1"
    printf '# edited\n' >>"$tmp/strata/setup.sh"
    run_strata latest 1
    [[ $output == *"has tracked changes"* ]] || fail "missing Strata tracked-change diagnostic"
    untouched
    checkout "$v1"
    sgit -C "$tmp/strata" commit -q --allow-empty -m local
    run_strata latest 1
    [[ $output == *"cannot fast-forward"* ]] || fail "a Strata checkout with its own commit was moved"
    untouched
    checkout "$v3"
    run_strata "$v2" 1
    [[ $output == *"cannot fast-forward"* ]] || fail "a pinned run accepted a checkout past the pin"
    untouched
    run_strata 0000000 1
    [[ $output == *"has no revision 0000000"* ]] || fail "an unknown Strata revision was accepted"

    checkout "$v1"
    run_strata latest 0
    at "$v2" "latest did not move Strata to its newest release, v0.2.0"
    grep -qx "rm -rf $tmp/strata/build" "$SAFE_LOG" || fail "the engine of the old source was kept for the build"
    grep -q '^strata-setup --yes .*--build' "$SAFE_LOG" || fail "Strata's setup did not rebuild the engine"
    grep -q '^strata-setup .*--context 65536' "$SAFE_LOG" || fail "a 12 GB card kept Strata's 128K context"
    : >"$SAFE_LOG"
    VRAM=24576 run_strata latest 0
    ! grep -q -- '--context' "$SAFE_LOG" || fail "a 24 GB card lost Strata's default context"
    checkout "$v1"
    run_strata "$v2" 0
    at "$v2" "a pinned run did not fast-forward to its pin"
    checkout "$v3"
    run_strata latest 0
    at "$v3" "latest moved a checkout already past the newest release"
    ! grep -q "^rm -rf $tmp/strata/build" "$SAFE_LOG" || fail "an unchanged Strata checkout lost its engine"

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
    ! grep -q '^sudo dnf upgrade' "$SAFE_LOG" || fail "the current release was updated before the preflight checks passed"
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
        # bit 6: the error log holds entries, while the disk itself passes
        if [ "$disk" = "${SMART_HISTORY_DEVICE:-}" ]; then
            echo 'SMART overall-health self-assessment test result: PASSED'; exit 64
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
    SMART_FAIL_DEVICE=/dev/nvmeB SMART_RESULT_FAIL_DEVICE=/dev/sataA SMART_UNSUPPORTED_DEVICE=/dev/sataB SMART_HISTORY_DEVICE=/dev/nvmeA \
    bash "$repo/scripts/deep-health.sh" 2>&1); then
    fail "multi-disk audit accepted device errors"
fi
for disk in /dev/nvmeA /dev/nvmeB /dev/sataA /dev/sataB; do
    grep -q "smartctl -H $disk$" "$SAFE_LOG" || fail "SMART health omitted $disk"
    grep -q "smartctl -A $disk$" "$SAFE_LOG" || fail "SMART attributes omitted $disk"
done
[[ $output == *"/dev/nvmeA: self-test passed"* ]] || fail "a healthy NVMe disk was not tested"
[[ $output == *"/dev/nvmeB: SMART reports a failing disk"* ]] || fail "second NVMe failure was hidden"
[[ $output == *"/dev/nvmeA: SMART lists past threshold crossings or logged errors"* ]] || fail "SMART error log entries were hidden"
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

# dnf's report for N+1 builds with an unmet requirement and for a package without an N+1 build
if [ "$EUID" -ne 0 ]; then
    upg="$tmp/upgrade"
    mkdir -p "$upg/bin" "$upg/repo/scripts/lib" "$upg/hw"
    cp "$repo/scripts/fedora-upgrade.sh" "$upg/repo/scripts/"
    cp "$repo/scripts/lib/hw.sh" "$upg/repo/scripts/lib/"
    cat >"$upg/problems.log" <<'LOG'
Failed to resolve the transaction:
Packages for argument 'admin-tools' installed, but not available.
Problem 1: conflicting requests
  - rpmfusion-nonfree-release-44-3.noarch does not belong to a distupgrade repository
  - nothing provides /usr/share/dnf5/libdnf.conf.d/ needed by rpmfusion-nonfree-release-45-1.noarch from rpmfusion-nonfree
Problem 2: conflicting requests
  - rpmfusion-free-release-44-3.noarch does not belong to a distupgrade repository
  - nothing provides /usr/share/dnf5/libdnf.conf.d/ needed by rpmfusion-free-release-45-1.noarch from rpmfusion-free
Problem 3: problem with installed package emulationstation-de-3.5.0-1.fc44.x86_64
  - installed package emulationstation-de-3.5.0-1.fc44.x86_64 requires libavutil.so.60()(64bit), but none of the providers can be installed
You can try to add to command line:
  --setopt=optional_metadata_types=filelists to load additional filelists metadata
LOG
    cat >"$upg/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$SAFE_LOG"
case "$*" in
    "snapper list-configs") [ "${SNAPPER_CONFIG:-no}" = no ] || printf 'Config | Subvolume\n-------+----------\nroot   | /\n' ;;
    snapper*) exit 1 ;;
    *"system-upgrade download"*--assumeno*)
        printf 'resolve LC_ALL=%s\n' "${LC_ALL-}" >>"$SAFE_LOG"
        [[ "$*" == *--allowerasing* ]] || cat "$UPGRADE_PROBLEMS" ;;
    *repoquery*emulationstation-de*) ;;
esac
exit 0
STUB
    cat >"$upg/bin/rpm" <<'STUB'
#!/bin/bash
case "$1" in -E) echo 44 ;; *) echo fixture-kernel ;; esac
STUB
    printf '#!/bin/bash\necho 200\n' >"$upg/bin/curl"
    printf '#!/bin/bash\necho fixture-kernel\n' >"$upg/bin/uname"
    chmod +x "$upg/bin"/*
    : >"$SAFE_LOG"
    output=$(PATH="$upg/bin:$stub:$PATH" TMPDIR="$upg" HW_ROOT="$upg/hw" UPGRADE_PROBLEMS="$upg/problems.log" NO_COLOR=1 \
        bash "$upg/repo/scripts/fedora-upgrade.sh" --yes 2>&1) || fail "upgrade stopped on the 44 -> 45 problems: $output"
    download=$(grep '^sudo dnf system-upgrade download ' "$SAFE_LOG" | grep -v -- --assumeno) || fail "no final download"
    [[ $download == *"--setopt=optional_metadata_types=comps,filelists,updateinfo"* ]] || fail "download without filelists"
    [[ $download == *"--exclude=rpmfusion-free-release --exclude=rpmfusion-nonfree-release --allowerasing"* ]] ||
        fail "broken release builds were not excluded: $download"
    [[ $output == *"rpmfusion-free-release carries its repository's .repo files"* ]] ||
        fail "no warning that RPM Fusion goes away"
    [[ $output == *"https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-45.noarch.rpm"* ]] &&
        [[ $output == *"https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-45.noarch.rpm"* ]] ||
        fail "no RPM Fusion reinstall command"
    [[ $output == *"sudo dnf install emulationstation-de"* ]] || fail "no reinstall hint for a package without a build"
    if ! grep -q '^resolve LC_ALL=C$' "$SAFE_LOG" || grep '^resolve ' "$SAFE_LOG" | grep -qvx 'resolve LC_ALL=C'; then
        fail "dnf's report was parsed in a translated locale"
    fi
    [[ $download == *"--setopt=skip_if_unavailable=True"* ]] || fail "a repo without a build for the new release can stop the download"
    : >"$SAFE_LOG"
    output=$(PATH="$upg/bin:$stub:$PATH" TMPDIR="$upg" HW_ROOT="$upg/hw" UPGRADE_PROBLEMS=/dev/null NO_COLOR=1 \
        bash "$upg/repo/scripts/fedora-upgrade.sh" --yes 2>&1) || fail "a clean upgrade failed: $output"
    download=$(grep '^sudo dnf system-upgrade download ' "$SAFE_LOG" | grep -v -- --assumeno) || fail "no clean download"
    [[ $download != *filelists* && $download != *--exclude* && $download != *--allowerasing* ]] ||
        fail "a clean upgrade got workaround options: $download"
    [[ $output != *"reinstall what the upgrade removed"* ]] || fail "a clean upgrade listed removals"
    : >"$SAFE_LOG"
    if output=$(PATH="$upg/bin:$stub:$PATH" TMPDIR="$upg" HW_ROOT="$upg/hw" UPGRADE_PROBLEMS=/dev/null NO_COLOR=1 \
        SNAPPER_CONFIG=yes bash "$upg/repo/scripts/fedora-upgrade.sh" --yes 2>&1); then
        fail "the upgrade went on although snapper could not take the restore point"
    fi
    [[ $output == *"snapper has a root config but took no snapshot"* ]] || fail "no diagnostic for the failed snapshot"
    ! grep -q 'system-upgrade download' "$SAFE_LOG" || fail "the download began without a restore point"
fi

echo "All helper script failure-path tests passed."
