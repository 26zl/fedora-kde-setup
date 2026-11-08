#!/bin/bash
# Windows VM setup: bad input stops before sudo, no ISO means no VM, an ISO builds the full definition.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub" "$tmp/hw/dev" "$tmp/nokvm"
: >"$tmp/hw/dev/kvm"
: >"$tmp/Win11_Test.iso"
export SAFE_LOG="$tmp/commands"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$stub/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$SAFE_LOG"
case "$*" in
    *" dominfo "*) [ "${VM_EXISTS:-no}" = yes ] ;;
    *" net-info "*) echo 'Active:         yes' ;;
    *" pool-info "*) echo 'State:          running' ;;
    *) exit 0 ;;
esac
STUB
cat >"$stub/setsid" <<'STUB'
#!/bin/bash
printf 'setsid %s\n' "$*" >>"$SAFE_LOG"
STUB
chmod +x "$stub"/*

run() {  # expected-exit args...
    local want=$1 rc
    shift
    : >"$SAFE_LOG"
    output=$(PATH="$stub:$PATH" HW_ROOT="${KVM_ROOT:-$tmp/hw}" NO_COLOR=1 \
        bash "$repo/scripts/windows-vm-setup.sh" "$@" </dev/null 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq "$want" ] || fail "exit $rc, want $want for: $* ($output)"
}
no_sudo() { ! grep -q '^sudo ' "$SAFE_LOG" || fail "$1 reached sudo"; }

KVM_ROOT="$tmp/nokvm" run 1 --yes
[[ $output == *"no /dev/kvm"* ]] || fail "missing KVM diagnostic"
no_sudo "a host without KVM"

run 1 --yes "$tmp/missing.iso"
[[ $output == *"cannot read"* ]] || fail "missing ISO diagnostic"
no_sudo "a missing ISO"

VM_RAM_MIB=2048 run 1 --yes
no_sudo "too little RAM"
VM_NAME='bad name' run 1 --yes
no_sudo "an invalid VM name"

run 1
[[ $output == *"not a terminal"* ]] || fail "no refusal without a terminal"
no_sudo "a run without --yes or a terminal"

run 0 --yes
grep -q '^sudo dnf install -y qemu-kvm ' "$SAFE_LOG" || fail "packages not installed"
! grep -q '^sudo virt-install ' "$SAFE_LOG" || fail "a VM was created without an ISO"

VM_EXISTS=yes run 1 --yes "$tmp/Win11_Test.iso"
[[ $output == *"exists already"* ]] || fail "existing VM diagnostic"
! grep -q '^sudo virt-install ' "$SAFE_LOG" || fail "an existing VM was redefined"

run 0 --yes "$tmp/Win11_Test.iso"
install=$(grep '^sudo virt-install ' "$SAFE_LOG") || fail "virt-install not called"
for want in '--osinfo win11' 'firmware.feature0.name=secure-boot' 'firmware.feature1.name=enrolled-keys' \
    'backend.type=emulator,backend.version=2.0' 'bus=virtio' "--cdrom /var/lib/libvirt/images/Win11_Test.iso" \
    'virtio-win-' 'model=virtio'; do
    [[ $install == *"$want"* ]] || fail "VM definition lacks $want"
done
grep -q '^sudo install -m 0644 .*Win11_Test.iso /var/lib/libvirt/images/Win11_Test.iso$' "$SAFE_LOG" ||
    fail "the ISO was not copied next to the disk"
grep -q '^setsid -f virt-manager ' "$SAFE_LOG" || fail "the console was not opened"
echo "All Windows VM setup tests passed."
