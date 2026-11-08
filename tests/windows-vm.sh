#!/bin/bash
# Windows VM setup: bad input stops before sudo, no ISO means no VM, the virtio-win download is checked,
# the libvirt group stays opt-in, and an ISO builds the full definition.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub" "$tmp/hw/dev" "$tmp/nokvm" "$tmp/copy/scripts"
: >"$tmp/hw/dev/kvm"
: >"$tmp/Win11_Test.iso"
printf 'virtio-win fixture\n' >"$tmp/virtio.fixture"
export SAFE_LOG="$tmp/commands" VIRTIO_FIXTURE="$tmp/virtio.fixture"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$stub/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$SAFE_LOG"
case "$*" in
    *" dominfo "*) [ "${VM_EXISTS:-no}" = yes ] ;;
    *" net-info "*) echo 'Active:         yes' ;;
    *" pool-info "*) echo 'State:          running' ;;
    'sha256sum -c --status -') [ "${VIRTIO_PRESENT:-yes}" = yes ] ;;
    *) exit 0 ;;
esac
STUB
cat >"$stub/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$SAFE_LOG"
while [ "$#" -gt 0 ]; do
    case $1 in -o) cp "$VIRTIO_FIXTURE" "$2"; shift 2 ;; *) shift ;; esac
done
STUB
cat >"$stub/setsid" <<'STUB'
#!/bin/bash
printf 'setsid %s\n' "$*" >>"$SAFE_LOG"
STUB
cat >"$stub/xdg-user-dir" <<'STUB'
#!/bin/bash
echo "${TEST_XDG_DOWNLOAD:-$HOME}"
STUB
cat >"$stub/id" <<'STUB'
#!/bin/bash
case "$1" in -nG) echo "${TEST_GROUPS:-users wheel}" ;; *) exec /usr/bin/id "$@" ;; esac
STUB
chmod +x "$stub"/*
pinned="$repo/scripts/windows-vm-setup.sh"
# a copy that trusts the fixture, so the download path runs through the real sha256sum
trusting="$tmp/copy/scripts/windows-vm-setup.sh"
sed "s/^VIRTIO_SHA256=.*/VIRTIO_SHA256=$(sha256sum "$tmp/virtio.fixture" | cut -d' ' -f1)/" "$pinned" >"$trusting"

run() {  # expected-exit script args...
    local want=$1 script=$2 rc
    shift 2
    : >"$SAFE_LOG"
    output=$(PATH="$stub:$PATH" HW_ROOT="${KVM_ROOT:-$tmp/hw}" NO_COLOR=1 \
        bash "$script" "$@" </dev/null 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq "$want" ] || fail "exit $rc, want $want for: $* ($output)"
}
no_sudo() { ! grep -q '^sudo ' "$SAFE_LOG" || fail "$1 reached sudo"; }

KVM_ROOT="$tmp/nokvm" run 1 "$pinned" --yes
[[ $output == *"no /dev/kvm"* ]] || fail "missing KVM diagnostic"
no_sudo "a host without KVM"

run 1 "$pinned" --yes "$tmp/missing.iso"
[[ $output == *"cannot read"* ]] || fail "missing ISO diagnostic"
no_sudo "a missing ISO"

VM_RAM_MIB=2048 run 1 "$pinned" --yes
no_sudo "too little RAM"
VM_NAME='bad name' run 1 "$pinned" --yes
no_sudo "an invalid VM name"
VM_LIBVIRT_GROUP=maybe run 1 "$pinned" --yes
no_sudo "an invalid VM_LIBVIRT_GROUP"

run 1 "$pinned"
[[ $output == *"not a terminal"* ]] || fail "no refusal without a terminal"
no_sudo "a run without --yes or a terminal"

run 0 "$pinned" --yes
grep -q '^sudo dnf install -y qemu-kvm ' "$SAFE_LOG" || fail "packages not installed"
! grep -q '^sudo virt-install ' "$SAFE_LOG" || fail "a VM was created without an ISO"
! grep -q '^sudo usermod ' "$SAFE_LOG" || fail "the root-equivalent libvirt group was granted without VM_LIBVIRT_GROUP=yes"
! grep -q '^curl ' "$SAFE_LOG" || fail "virtio-win was downloaded although it was present"

TEST_GROUPS=users VM_LIBVIRT_GROUP=yes run 0 "$pinned" --yes
grep -q '^sudo usermod -aG libvirt ' "$SAFE_LOG" || fail "VM_LIBVIRT_GROUP=yes did not add the group"

VIRTIO_PRESENT=no run 0 "$trusting" --yes
grep -q -- '^curl .*--speed-time ' "$SAFE_LOG" || fail "the download has no stall limit"
grep -q '^sudo install -m 0644 .*/virtio-win.iso /var/lib/libvirt/images/virtio-win-' "$SAFE_LOG" ||
    fail "a checked virtio-win download was not installed"
VIRTIO_PRESENT=no run 1 "$pinned" --yes
! grep -q '^sudo install .*virtio-win' "$SAFE_LOG" || fail "a virtio-win download with the wrong hash was installed"

VM_EXISTS=yes run 1 "$pinned" --yes "$tmp/Win11_Test.iso"
[[ $output == *"exists already"* ]] || fail "existing VM diagnostic"
! grep -q '^sudo virt-install ' "$SAFE_LOG" || fail "an existing VM was redefined"

run 0 "$pinned" --yes "$tmp/Win11_Test.iso"
install=$(grep '^sudo virt-install ' "$SAFE_LOG") || fail "virt-install not called"
for want in '--osinfo win11' 'firmware.feature0.name=secure-boot' 'firmware.feature1.name=enrolled-keys' \
    'backend.type=emulator,backend.version=2.0' 'bus=virtio' "--cdrom /var/lib/libvirt/images/Win11_Test.iso" \
    'virtio-win-' 'model=virtio' 'model.type=qxl,model.vgamem=65536' 'name=org.qemu.guest_agent.0'; do
    [[ $install == *"$want"* ]] || fail "VM definition lacks $want"
done
grep -q '^sudo install -m 0644 /dev/stdin /var/lib/libvirt/images/Win11_Test.iso$' "$SAFE_LOG" ||
    fail "the ISO was not copied next to the disk through the user's own read"
grep -q '^setsid -f virt-manager ' "$SAFE_LOG" || fail "the console was not opened"

# --find-iso: the newest finished Windows 11 ISO in the download folder or VM_ISO_DIR, never the real ~/Downloads
home="$tmp/home"
mkdir -p "$home/Downloads" "$tmp/xdg" "$tmp/isos" "$tmp/no-isos"
find_iso() { HOME="$home" VM_ISO_DIR="${ISO_DIR:-$tmp/no-isos}" run "$@"; }
cdrom() { grep '^sudo virt-install ' "$SAFE_LOG" | grep -o -- '--cdrom [^ ]*'; }
find_iso 1 "$pinned" --yes --find-iso
[[ $output == *"no Windows 11 ISO in $home/Downloads"* && $output == *"software-download/windows11"* ]] ||
    fail "--find-iso without an ISO gave no diagnostic: $output"
no_sudo "--find-iso without an ISO"
truncate -s 5G "$home/Downloads/Win11_25H2_English_x64.iso"
: >"$home/Downloads/Win11_25H2_English_x64.iso.part"
find_iso 1 "$pinned" --yes --find-iso
[[ $output == *"not finished downloading"* ]] || fail "an ISO with a .part beside it was taken"
no_sudo "an unfinished download"
rm "$home/Downloads/Win11_25H2_English_x64.iso.part"
touch -d '2 hours ago' "$home/Downloads/Win11_25H2_English_x64.iso"
printf 'placeholder\n' >"$home/Downloads/Windows11_Client_x64_en-us_26300_9457.iso"
find_iso 1 "$pinned" --yes --find-iso
[[ $output == *"not finished downloading"* ]] || fail "a file too small for a Windows ISO was taken"
no_sudo "a too-small ISO"
truncate -s 5G "$home/Downloads/Windows11_Client_x64_en-us_26300_9457.iso"
find_iso 0 "$pinned" --yes --find-iso
[ "$(cdrom)" = "--cdrom /var/lib/libvirt/images/Windows11_Client_x64_en-us_26300_9457.iso" ] ||
    fail "the newest ISO was not the one installed from: $(cdrom)"
[[ $output == *"Windows ISO: $home/Downloads/Windows11_Client_x64_en-us_26300_9457.iso"* ]] || fail "the found ISO was not named"
rm "$home/Downloads/"*.iso
truncate -s 5G "$tmp/isos/Win11_24H2_English_x64.iso"
ISO_DIR="$tmp/isos" find_iso 0 "$pinned" --yes --find-iso
[ "$(cdrom)" = "--cdrom /var/lib/libvirt/images/Win11_24H2_English_x64.iso" ] || fail "an ISO in VM_ISO_DIR was not found"
truncate -s 5G "$tmp/xdg/Win11_25H2_Norwegian_x64.iso"
TEST_XDG_DOWNLOAD="$tmp/xdg" find_iso 0 "$pinned" --yes --find-iso
[ "$(cdrom)" = "--cdrom /var/lib/libvirt/images/Win11_25H2_Norwegian_x64.iso" ] || fail "an ISO in the XDG download folder was not found"
find_iso 2 "$pinned" --yes --find-iso "$tmp/Win11_Test.iso"
no_sudo "a path together with --find-iso"
echo "All Windows VM setup tests passed."
