#!/bin/bash
# fedora-setup.sh end to end with every system change stubbed: the refusals stop before sudo, Terra is
# added only once, the GRUB defaults are saved before apply-system.sh, ~/.bashrc gets ble.sh once, and
# with Windows the boot menu waits at least 10 s without grub2-mkconfig rewriting the kernel options.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin" copy="$tmp/repo" fx="$tmp/fixture"
mkdir -p "$stub" "$copy" "$fx/etc/default" "$fx/proc" "$fx/sys/class/dmi/id" "$fx/sys/bus/pci/devices/0000:0c:00.0"
export SAFE_LOG="$tmp/commands"
fail() { echo "FAIL: $*" >&2; exit 1; }

# an AMD desktop without Windows, on Fedora 45
printf '0x030000\n' >"$fx/sys/bus/pci/devices/0000:0c:00.0/class"
printf '0x1002\n' >"$fx/sys/bus/pci/devices/0000:0c:00.0/vendor"
printf '0x164e\n' >"$fx/sys/bus/pci/devices/0000:0c:00.0/device"
echo 3 >"$fx/sys/class/dmi/id/chassis_type"
printf 'vendor_id\t: AuthenticAMD\n' >"$fx/proc/cpuinfo"
echo 'LANG="en_US.UTF-8"' >"$fx/etc/locale.conf"
echo 'Fedora release 45 (Forty Five)' >"$fx/etc/fedora-release"
echo 'GRUB_TIMEOUT=5' >"$fx/etc/default/grub"

# a copy with the restore point and the system deploy stubbed, and its host paths in the fixture
tar -C "$repo" --exclude=.git --exclude=setup.conf -cf - . | tar -C "$copy" -xf -
cat >"$copy/scripts/lib/restore.sh" <<'STUB'
# shellcheck shell=bash
create_setup_restore_point() { SETUP_RESTORE_DIR=/.fedora-kde-setup-backups/run-test; }
STUB
cat >"$copy/scripts/apply-system.sh" <<'STUB'
#!/bin/bash
printf 'apply-system %s\n' "$*" >>"$SAFE_LOG"
STUB
sed -i -e "s#/etc/fedora-release#$fx/etc/fedora-release#g" -e "s#/etc/default/grub#$fx/etc/default/grub#g" \
    "$copy/scripts/fedora-setup.sh"

cat >"$stub/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$SAFE_LOG"
[ "$1" != tee ] || sed 's/^/tee< /' >>"$SAFE_LOG"
STUB
cat >"$stub/rpm" <<'STUB'
#!/bin/bash
case "$*" in
    '-E %fedora') echo "${TEST_RELEASE:-45}" ;;
    '-q terra-release') [ "${TERRA_INSTALLED:-no}" = yes ] ;;
    *) exit 1 ;;
esac
STUB
cat >"$stub/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$SAFE_LOG"
while [ "$#" -gt 0 ]; do
    case $1 in -o) : >"$2"; shift 2 ;; *) shift ;; esac
done
STUB
cat >"$stub/uname" <<'STUB'
#!/bin/bash
echo x86_64
STUB
cat >"$stub/locale" <<'STUB'
#!/bin/bash
echo 'LANG=en_US.UTF-8'
STUB
cat >"$stub/findmnt" <<'STUB'
#!/bin/bash
case "$*" in *FSTYPE*) echo btrfs ;; esac
STUB
cat >"$stub/fwupdmgr" <<'STUB'
#!/bin/bash
exit 2
STUB
cat >"$stub/lazygit" <<'STUB'
#!/bin/bash
echo 'commit=fixture, build date=fixture, build source=fixture, version=0.0.0, os=linux, arch=amd64'
STUB
# everything else that could touch the machine, the session or the network only logs
for command in dnf flatpak systemctl git make fc-cache tar sha256sum kwriteconfig6 kreadconfig6 mokutil \
    efibootmgr firewall-cmd timedatectl logger sleep; do
    cat >"$stub/$command" <<STUB
#!/bin/bash
printf '$command %s\n' "\$*" >>"\$SAFE_LOG"
STUB
done
chmod +x "$stub"/*

run() {  # expected-exit home args...
    local want=$1 home=$2 rc
    shift 2
    mkdir -p "$home"
    : >"$SAFE_LOG"
    output=$(cd "$tmp" && PATH="$stub:$PATH" HOME="$home" HW_ROOT="$fx" NO_COLOR=1 \
        bash "$copy/scripts/fedora-setup.sh" "$@" </dev/null 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq "$want" ] || fail "exit $rc, want $want for: $* ($(tail -n 5 <<<"$output"))"
}
no_sudo() { ! grep -q '^sudo ' "$SAFE_LOG" || fail "$1 reached sudo"; }
blocks() { grep -c '^# >>> fedora-kde-setup: configs/bashrc >>>$' "$1/.bashrc" || true; }
attach_line="[[ \${BLE_VERSION-} ]] && ble-attach"

TEST_RELEASE=44 run 1 "$tmp/home-refused" --yes
[[ $output == *"targets Fedora 45"* ]] || fail "another Fedora release was not refused"
no_sudo "another Fedora release"
run 1 "$tmp/home-refused"
[[ $output == *"not a terminal"* ]] || fail "a run without a terminal or --yes did not stop"
no_sudo "a run without a terminal or --yes"
# root inside a user namespace; GitHub's Ubuntu runners forbid those, and tests/fresh-install.sh covers it as real root
if unshare -r true 2>/dev/null; then
    : >"$SAFE_LOG"
    if output=$(cd "$tmp" && PATH="$stub:$PATH" HW_ROOT="$fx" unshare -r bash "$copy/scripts/fedora-setup.sh" --yes </dev/null 2>&1); then
        fail "root was not refused"
    fi
    [[ $output == *"run as a normal user"* ]] || fail "missing root refusal diagnostic"
    no_sudo "a run as root"
fi

home="$tmp/home"
run 0 "$home" --yes
[ "$(grep -c -- '--repofrompath terra,' "$SAFE_LOG" || true)" -eq 1 ] || fail "Terra was not added exactly once"
grep -qxF 'sudo dnf install -y --repofrompath terra,https://repos.fyralabs.com/terra45 --setopt=terra.gpgkey=https://repos.fyralabs.com/terra45/key.asc terra-release' \
    "$SAFE_LOG" || fail "Terra was added for the wrong release"
grub=$(grep -nxF "sudo cp -n $fx/etc/default/grub $fx/etc/default/grub.orig" "$SAFE_LOG" | cut -d: -f1)
apply=$(grep -nx 'apply-system --yes' "$SAFE_LOG" | cut -d: -f1)
{ [ -n "$grub" ] && [ -n "$apply" ] && [ "$grub" -lt "$apply" ]; } ||
    fail "the GRUB defaults were not saved before apply-system.sh rewrote GRUB_CMDLINE_LINUX"
! grep -qE 'GRUB_|grub2-mkconfig' "$SAFE_LOG" || fail "a machine without Windows got its boot menu changed"
[ "$(blocks "$home")" -eq 1 ] || fail "configs/bashrc was not appended once"
[ "$(grep -cxF "$attach_line" "$home/.bashrc" || true)" -eq 1 ] || fail "ble-attach was not added once"
[ "$(tail -n 2 "$home/.bashrc" | head -n 1)" = "$attach_line" ] || fail "ble-attach is not the last line of the block"
head -n 2 "$home/.bashrc" | grep -qF 'source ~/.local/share/blesh/ble.sh --noattach' || fail "ble.sh is not loaded first"

# a second run, now with terra-release installed: dnf refuses --repofrompath for a configured repo id
TERRA_INSTALLED=yes run 0 "$home" --yes
! grep -q -- '--repofrompath terra,' "$SAFE_LOG" || fail "Terra's install ran again although terra-release is installed"
[ "$(blocks "$home")" -eq 1 ] || fail "a second run appended configs/bashrc again"
[ "$(grep -cxF "$attach_line" "$home/.bashrc" || true)" -eq 1 ] || fail "a second run added ble-attach again"

# a .bashrc that already initialises zoxide still needs the block and ble-attach
zoxide_home="$tmp/home-zoxide"
mkdir -p "$zoxide_home"
cat >"$zoxide_home/.bashrc" <<'RC'
# ~/.bashrc
eval "$(zoxide init bash)"
RC
run 0 "$zoxide_home" --yes
[ "$(blocks "$zoxide_home")" -eq 1 ] || fail "a .bashrc with zoxide but no ble-attach did not get configs/bashrc"
[ "$(grep -cxF "$attach_line" "$zoxide_home/.bashrc" || true)" -eq 1 ] || fail "a .bashrc with zoxide did not get ble-attach"

# Windows on the ESP: sudo only logs, so each run sees /etc/default/grub as written here
mkdir -p "$fx/boot/efi/EFI/Microsoft/Boot"
: >"$fx/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"
grub_run() {  # lines of /etc/default/grub
    printf '%s\n' "$@" >"$fx/etc/default/grub"
    run 0 "$tmp/home-windows" --yes
}
mkconfig="sudo grub2-mkconfig --no-grubenv-update -o /boot/grub2/grub.cfg"
grub_run GRUB_TIMEOUT=5
grep -qxF "sudo sed -i s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/ $fx/etc/default/grub" "$SAFE_LOG" ||
    fail "Fedora's 5 s countdown was not raised to 10"
for line in GRUB_DEFAULT=saved GRUB_SAVEDEFAULT=true; do
    grep -qxF "tee< $line" "$SAFE_LOG" || fail "$line was not added"
done
[ "$(grep -cxF "$mkconfig" "$SAFE_LOG")" -eq 1 ] || fail "grub.cfg was not regenerated once with --no-grubenv-update"
! grep -q 'grub2-mkconfig -o' "$SAFE_LOG" || fail "grub2-mkconfig ran without --no-grubenv-update and rewrote the kernel options"
[[ $output == *"GRUB waits at least 10 s and remembers the last-booted OS"* ]] || fail "the boot menu step did not report the countdown"
grub_run GRUB_DEFAULT=saved GRUB_SAVEDEFAULT=true
grep -qxF 'tee< GRUB_TIMEOUT=10' "$SAFE_LOG" && [ "$(grep -cxF "$mkconfig" "$SAFE_LOG")" -eq 1 ] ||
    fail "a missing GRUB_TIMEOUT was not added"
for keep in 10 15 -1; do
    grub_run "GRUB_TIMEOUT=$keep" GRUB_DEFAULT=saved GRUB_SAVEDEFAULT=true
    ! grep -qE 'GRUB_|grub2-mkconfig' "$SAFE_LOG" || fail "GRUB_TIMEOUT=$keep was changed or grub.cfg regenerated for nothing"
done
echo "All Fedora setup tests passed."
