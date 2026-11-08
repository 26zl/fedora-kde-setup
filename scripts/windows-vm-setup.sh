#!/bin/bash
# Windows 11 VM on KVM/libvirt: UEFI Secure Boot, TPM 2.0, virtio disk and network. Opt-in.
# Without an ISO it sets up libvirt, the VM storage and the virtio drivers; with a Windows 11
# ISO it also creates the VM and opens its console. Windows Setup itself stays interactive.
# Run as a regular user; sudo is called where needed after one confirmation.
#   bash scripts/windows-vm-setup.sh [--yes] [Win11.iso | --find-iso]
# --find-iso takes the newest finished Windows 11 ISO in the download folder or VM_ISO_DIR.
# VM_NAME (win11), VM_RAM_MIB, VM_CPUS and VM_DISK_GIB (128) override the defaults;
# VM_LIBVIRT_GROUP=yes adds you to the libvirt group, which manages VMs as root without a password.

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
YES=0 ISO="" FIND_ISO=0
for arg in "$@"; do
    case $arg in
        --yes) YES=1 ;;
        --find-iso) FIND_ISO=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage; exit 2 ;;
        *) [ -z "$ISO" ] || { usage; exit 2; }; ISO=$arg ;;
    esac
done
[ "$FIND_ISO" -eq 0 ] || [ -z "$ISO" ] || { usage; exit 2; }

set -e
[ "$EUID" -ne 0 ] || { echo "run as a normal user, not root" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "this setup requires x86_64" >&2; exit 1; }
cd "$(dirname "$0")/.."

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

# interactive runs also leave these lines in the journal: journalctl -t fedora-kde-setup
journal() { [ ! -t 1 ] || logger -t fedora-kde-setup -- "${0##*/}: $*" 2>/dev/null || true; }
ok()      { echo -e "  ${TEAL}✓${RESET} $1"; journal "ok: $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; journal "warning: $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; journal "$1"; }

# fedorapeople publishes no checksum for the ISO; the hash pins the file as first downloaded
VIRTIO_VERSION=0.1.302
VIRTIO_SHA256=303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
VIRTIO_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VIRTIO_VERSION-1/virtio-win-$VIRTIO_VERSION.iso
IMAGES=/var/lib/libvirt/images
CONNECT=qemu:///system
user=${USER:-$(id -un)}
mem_mib=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
threads=$(nproc)
VM_NAME=${VM_NAME:-win11}
# MemTotal sits below the installed size, so a 24 GB machine reports less than 24 GiB
VM_RAM_MIB=${VM_RAM_MIB:-$((mem_mib >= 22528 ? 8192 : 4096))}
VM_CPUS=${VM_CPUS:-$((threads / 2 > 8 ? 8 : (threads / 2 < 2 ? 2 : threads / 2)))}
VM_DISK_GIB=${VM_DISK_GIB:-128}
# setup.conf may set VM_ISO_DIR; the environment wins over it
# shellcheck disable=SC1091
conf() { if [ -f setup.conf ]; then (unset "$1"; . ./setup.conf >/dev/null; printf '%s' "${!1-}"); fi; }
VM_ISO_DIR=${VM_ISO_DIR:-$(conf VM_ISO_DIR)}

[ -e "${HW_ROOT-}/dev/kvm" ] || { warn "no /dev/kvm: turn on SVM (AMD) or VT-x (Intel) in the firmware setup"; exit 1; }
[[ $VM_NAME =~ ^[A-Za-z0-9._-]+$ ]] || { warn "VM_NAME may hold only letters, digits, dot, dash and underscore"; exit 1; }
case ${VM_LIBVIRT_GROUP:-no} in yes | no) ;; *) warn "VM_LIBVIRT_GROUP must be yes or no"; exit 1 ;; esac
for var in VM_RAM_MIB VM_CPUS VM_DISK_GIB; do
    [[ ${!var} =~ ^[1-9][0-9]*$ ]] || { warn "$var must be a whole number"; exit 1; }
done
if [ "$VM_RAM_MIB" -lt 4096 ] || [ "$VM_CPUS" -lt 2 ] || [ "$VM_DISK_GIB" -lt 64 ]; then
    warn "Windows 11 needs at least 4096 MiB of RAM, 2 CPUs and a 64 GiB disk"
    exit 1
fi
if [ "$FIND_ISO" -eq 1 ]; then
    dirs=()
    download=$(xdg-user-dir DOWNLOAD 2>/dev/null) || download=""
    for dir in "$download" "$HOME/Downloads" "$VM_ISO_DIR"; do
        [ -n "$dir" ] && [ "$dir" != "$HOME" ] && [ -d "$dir" ] && [[ " ${dirs[*]} " != *" $dir "* ]] && dirs+=("$dir")
    done
    [ "${#dirs[@]}" -eq 0 ] || ISO=$(find "${dirs[@]}" -maxdepth 1 -type f -iname 'win*11*.iso' -printf '%T@ %p\n' 2>/dev/null |
        sort -n | tail -n 1 | cut -d' ' -f2-)
    if [ -z "$ISO" ]; then
        warn "no Windows 11 ISO in ${dirs[*]:-$HOME/Downloads}; get it from https://www.microsoft.com/software-download/windows11"
        exit 1
    fi
    # a browser keeps an empty file under the final name until its .part or .crdownload file is complete
    if [ -e "$ISO.part" ] || [ -e "$ISO.crdownload" ] || [ "$(stat -c %s "$ISO")" -lt 4000000000 ]; then
        warn "$ISO is not finished downloading; run this again when it is"
        exit 1
    fi
    ok "Windows ISO: $ISO"
fi
if [ -n "$ISO" ]; then
    [ -f "$ISO" ] && [ -r "$ISO" ] || { warn "cannot read $ISO"; exit 1; }
    ISO=$(realpath "$ISO")
fi

section "Plan"
echo "  packages  qemu-kvm, libvirt, virt-install, virt-manager, swtpm, edk2-ovmf"
if [ "${VM_LIBVIRT_GROUP:-no}" = yes ]; then
    echo "  libvirt   daemon sockets and the NAT network on, $user in the libvirt group (root-equivalent)"
else
    echo "  libvirt   daemon sockets and the NAT network on; virt-manager asks for your password"
fi
echo "  storage   $IMAGES as its own btrfs subvolume when empty, outside root snapshots"
echo "  drivers   virtio-win $VIRTIO_VERSION ISO in $IMAGES, SHA-256 checked"
if [ -n "$ISO" ]; then
    echo "  VM        $VM_NAME: $VM_RAM_MIB MiB, $VM_CPUS vCPUs, $VM_DISK_GIB GiB disk, installing from ${ISO##*/}"
else
    echo "  VM        none yet; run again with the Windows 11 ISO"
fi
if [ "$YES" -ne 1 ]; then
    [ -t 0 ] || { warn "not a terminal: pass --yes to run without the question"; exit 1; }
    read -rp "  Continue? [y/N] " reply || reply=""
    [[ $reply == [yY]* ]] || { warn "stopped; nothing changed"; exit 1; }
fi

section "Packages"
sudo dnf install -y qemu-kvm libvirt-daemon-kvm libvirt-daemon-config-network virt-install virt-manager swtpm swtpm-tools edk2-ovmf
ok "KVM, libvirt, virt-install, virt-manager, swtpm, OVMF"

section "libvirt"
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
sudo virsh -c "$CONNECT" net-autostart default >/dev/null
sudo virsh -c "$CONNECT" net-info default | grep -q '^Active:.*yes' || sudo virsh -c "$CONNECT" net-start default >/dev/null
ok "virtqemud, virtnetworkd and virtstoraged sockets; NAT network \"default\" active"
if id -nG "$user" | grep -qw libvirt; then
    ok "$user is in the libvirt group"
elif [ "${VM_LIBVIRT_GROUP:-no}" = yes ]; then
    # polkit lets the libvirt group manage qemu:///system without a password, which amounts to root
    sudo usermod -aG libvirt "$user"
    warn "$user added to the libvirt group: no more password prompts, and root-equivalent; log out and in"
else
    ok "virt-manager asks for your password (VM_LIBVIRT_GROUP=yes skips that and grants root-equivalent access)"
fi

section "Storage"
if [ "$(stat -f -c %T "$IMAGES" 2>/dev/null)" != btrfs ]; then
    ok "$IMAGES is not on btrfs; left as it is"
elif [ "$(stat -c %i "$IMAGES")" = 256 ]; then
    ok "$IMAGES is already its own subvolume"
elif sudo find "$IMAGES" -mindepth 1 -maxdepth 1 | grep -q .; then
    warn "$IMAGES already holds files; left as it is, so root snapshots keep VM disks"
else
    # Snapper snapshots / and stops at nested subvolumes; NOCOW keeps a qcow2 from fragmenting.
    sudo rmdir "$IMAGES"
    sudo btrfs subvolume create "$IMAGES" >/dev/null
    sudo chmod 0711 "$IMAGES"
    sudo chattr +C "$IMAGES"
    sudo restorecon "$IMAGES"
    ok "$IMAGES is a btrfs subvolume without copy-on-write"
fi
sudo virsh -c "$CONNECT" pool-info default >/dev/null 2>&1 || {
    sudo virsh -c "$CONNECT" pool-define-as default dir --target "$IMAGES" >/dev/null
    sudo virsh -c "$CONNECT" pool-autostart default >/dev/null
}
sudo virsh -c "$CONNECT" pool-info default | grep -q '^State:.*running' || sudo virsh -c "$CONNECT" pool-start default >/dev/null
sudo virsh -c "$CONNECT" pool-refresh default >/dev/null
ok "storage pool \"default\" at $IMAGES"

section "virtio-win drivers"
virtio_iso=$IMAGES/virtio-win-$VIRTIO_VERSION.iso
if echo "$VIRTIO_SHA256  $virtio_iso" | sudo sha256sum -c --status - 2>/dev/null; then
    ok "virtio-win $VIRTIO_VERSION already in $IMAGES"
else
    tmp=$(mktemp -d /var/tmp/windows-vm.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    curl -fL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 -o "$tmp/virtio-win.iso" "$VIRTIO_URL"
    echo "$VIRTIO_SHA256  $tmp/virtio-win.iso" | sha256sum -c --quiet -
    sudo install -m 0644 "$tmp/virtio-win.iso" "$virtio_iso"
    ok "virtio-win $VIRTIO_VERSION downloaded and checked"
fi

if [ -z "$ISO" ]; then
    section "Next"
    echo "  Download Windows 11 (Disk Image ISO) from microsoft.com/software-download/windows11, then:"
    echo "  bash scripts/windows-vm-setup.sh <path to the ISO>   (or --find-iso once it is in ~/Downloads)"
    exit 0
fi

section "VM $VM_NAME"
if sudo virsh -c "$CONNECT" dominfo "$VM_NAME" >/dev/null 2>&1; then
    warn "$VM_NAME exists already; open it in virt-manager, or remove it first (README: Undoing Changes)"
    exit 1
fi
# qemu cannot search /home and libvirt cannot label files on NTFS, so the ISO goes next to the disk;
# the user opens it, so a path swapped after the checks cannot make root copy another file
install_iso=$IMAGES/${ISO##*/}
# shellcheck disable=SC2024  # the redirect runs as the user on purpose
[ "$ISO" = "$install_iso" ] || sudo install -m 0644 /dev/stdin "$install_iso" <"$ISO"
sudo virt-install --connect "$CONNECT" --name "$VM_NAME" --osinfo win11 \
    --memory "$VM_RAM_MIB" --vcpus "$VM_CPUS" --cpu host-passthrough \
    --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk "path=$IMAGES/$VM_NAME.qcow2,size=$VM_DISK_GIB,format=qcow2,bus=virtio,cache=none,discard=unmap" \
    --cdrom "$install_iso" \
    --disk "$virtio_iso,device=cdrom,bus=sata" \
    --network network=default,model=virtio \
    --graphics spice --noautoconsole
ok "$VM_NAME created; it boots the Windows installer now"
setsid -f virt-manager --connect "$CONNECT" --show-domain-console "$VM_NAME" >/dev/null 2>&1 || true

section "Windows Setup (in the virt-manager window)"
echo "  1. Press a key at \"Press any key to boot from CD or DVD\"; missed it: Send Key > Ctrl+Alt+Del"
echo "  2. At \"Where do you want to install Windows?\" choose Load driver and browse the virtio-win CD:"
printf '     %s\n' 'viostor\w11\amd64 for the disk, then NetKVM\w11\amd64 for the network'
echo "  3. After the first login run virtio-win-guest-tools.exe from the same CD (display, clipboard)"
