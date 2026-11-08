#!/bin/bash
# Critical system probes must report unavailable services as failures.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts/lib" "$tmp/bin" "$tmp/hardware"
cp "$repo/scripts/verify-setup.sh" "$repo/scripts/apply-system.sh" "$tmp/repo/scripts/"
cp "$repo/scripts/lib/hw.sh" "$tmp/repo/scripts/lib/"

cat >"$tmp/bin/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
    --failed*)
        [ "$VERIFY_PROBES" = available ] || exit 1
        echo 'example.service loaded failed failed Example service' ;;
    "is-active -q ollama") [ "${OLLAMA_ACTIVE:-yes}" = yes ] || exit 3 ;;
esac
exit 0
STUB
cat >"$tmp/bin/modprobe" <<'STUB'
#!/bin/bash
module=${*: -1}
[[ " ${MISSING_FS-} " != *" ${module#fs-} "* ]]
STUB
cat >"$tmp/bin/modinfo" <<'STUB'
#!/bin/bash
[ "${NVIDIA_MODULE:-present}" = present ]
STUB
printf '#!/bin/bash\necho '"'"'msg="inference compute" id=0 library=CUDA'"'"'\n' >"$tmp/bin/journalctl"
mkdir -p "$tmp/hardware/etc/modprobe.d" "$tmp/hardware/lib/modules/9.9.9-test"
: >"$tmp/hardware/lib/modules/9.9.9-test/vmlinuz"
printf '/dev/fixture-root / btrfs defaults 0 0\n/dev/fixture-data /mnt/fixture ntfs3 noauto,discard 0 0\n' >"$tmp/hardware/etc/fstab"
printf 'options nvidia NVreg_TemporaryFilePath=/var/tmp\n' >"$tmp/hardware/etc/modprobe.d/nvidia-580xx-storage.conf"
printf 'PreserveVideoMemoryAllocations: 1\nTemporaryFilePath: ""\n' >"$tmp/nvidia-params"
cat >"$tmp/bin/tuned-adm" <<'STUB'
#!/bin/bash
[ "$VERIFY_PROBES" = available ] || exit 1
echo 'Current active profile: balanced'
STUB
cat >"$tmp/bin/firewall-cmd" <<'STUB'
#!/bin/bash
[ "$VERIFY_PROBES" = available ] || exit 1
case $* in
    --get-default-zone) echo public ;;
    *--list-services) echo dhcpv6-client ;;
    *--list-ports) echo "${VERIFY_PORTS-}" ;;
esac
STUB
printf '#!/bin/bash\nexit 1\n' >"$tmp/bin/curl"
cat >"$tmp/bin/dnf" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${VERIFY_DNF_LOG:-/dev/null}"
exit 1
STUB
chmod +x "$tmp/bin/"*

run_probe() {
    output=$(PATH="$tmp/bin:$PATH" HW_ROOT="$tmp/hardware" FORM_FACTOR=laptop NVIDIA_DRIVER=none \
        NO_COLOR=1 VERIFY_PROBES="$1" bash "$tmp/repo/scripts/verify-setup.sh" 2>/dev/null) && status=0 || status=$?
    [ "$status" -eq 1 ] || { echo 'FAIL: verifier did not report fixture failures' >&2; exit 1; }
}

expect() {
    [[ $output == *"$1"* ]] || { echo "FAIL: verifier omitted '$1'" >&2; exit 1; }
}

run_probe unavailable
expect '✗ cannot query system units'
expect '✗ tuned has no active profile'
expect '✗ cannot query firewalld'
[[ $output != *'✓ no failed system units'* && $output != *'✓ tuned:'* ]] ||
    { echo 'FAIL: unavailable probes reported success' >&2; exit 1; }

run_probe available
expect '✗ failed system units: example.service'
expect '✓ tuned: balanced'
expect '✓ firewall (public): dhcpv6-client service; no explicit ports'
export VERIFY_PORTS=8080/tcp
run_probe available
expect '→ firewall (public): services=dhcpv6-client; ports=8080/tcp'
[[ $output != *'✓ firewall'* ]] || { echo 'FAIL: explicit firewall ports were ignored' >&2; exit 1; }
# emulation set up: the ES-DE AppImage must be there; any user-run dnf query must not wait on a key import prompt
mkdir -p "$tmp/home/ES-DE/custom_systems" "$tmp/home/Applications"
: >"$tmp/dnf.log"
run_home() {
    output=$(HOME="$tmp/home" VERIFY_DNF_LOG="$tmp/dnf.log" PATH="$tmp/bin:$PATH" HW_ROOT="$tmp/hardware" FORM_FACTOR=laptop \
        NVIDIA_DRIVER=none NO_COLOR=1 VERIFY_PROBES=available bash "$tmp/repo/scripts/verify-setup.sh" 2>/dev/null) || true
}
run_home
expect '✗ emulation is set up, but ~/Applications/ES-DE_x64.AppImage is missing'
printf '#!/bin/sh\nexit 0\n' >"$tmp/home/Applications/ES-DE_x64.AppImage"
chmod +x "$tmp/home/Applications/ES-DE_x64.AppImage"
run_home
expect '✓ ES-DE AppImage installed'
! grep -v -- '--assumeno' "$tmp/dnf.log" | grep -q . || { echo 'FAIL: a dnf query can wait on a prompt' >&2; exit 1; }

# the next kernel must have every filesystem driver /etc/fstab names, noauto entries included
run_probe available
expect '✓ kernel 9.9.9-test has the filesystem drivers /etc/fstab uses'
MISSING_FS=ntfs3 run_probe available
expect '✗ kernel 9.9.9-test lacks the filesystem drivers: ntfs3'
run_nvidia() {
    output=$(PATH="$tmp/bin:$PATH" HW_ROOT="$tmp/hardware" FORM_FACTOR=desktop NVIDIA_DRIVER=current NO_COLOR=1 \
        NVIDIA_PARAMS_FILE="$tmp/nvidia-params" VERIFY_PROBES=available bash "$tmp/repo/scripts/verify-setup.sh" 2>/dev/null) || true
}
run_nvidia
expect '→ NVIDIA saves video memory to /var/tmp from the next boot'
[[ $output != *"no NVIDIA module for kernel"* && $output != *"ollama is enabled but not running"* ]] ||
    { echo 'FAIL: a built NVIDIA module or a running ollama was reported' >&2; exit 1; }
NVIDIA_MODULE=missing OLLAMA_ACTIVE=no run_nvidia
expect '→ no NVIDIA module for kernel 9.9.9-test yet'
expect '✗ ollama is enabled but not running'
echo 'All setup verification tests passed.'
