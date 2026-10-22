#!/bin/bash
# Verify recovery gates and real boot archive round trips with synthetic filesystems.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
stub="$scratch/bin"
fixture="$scratch/root"
mkdir -p "$stub" "$fixture"/{boot/efi/EFI/test,home/tester/.config,etc,usr,var,proc}
printf 'kernel before setup\n' >"$fixture/boot/vmlinuz-test"
printf 'EFI before setup\n' >"$fixture/boot/efi/EFI/test/loader.efi"
printf 'KDE before setup\n' >"$fixture/home/tester/.config/kwinrc"
printf 'Fedora release 44\n' >"$fixture/etc/fedora-release"
printf 'vendor_id: GenuineIntel\n' >"$fixture/proc/cpuinfo"
export RESTORE_FIXTURE="$fixture" RESTORE_LOG="$scratch/commands"
export REAL_TAR
REAL_TAR=$(command -v tar)
: >"$RESTORE_LOG"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$stub/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$RESTORE_LOG"
case "$1" in
    btrfs|tar|chmod|mv|install|mktemp|tee|du|bash) exec "$@" ;;
    cp|dnf) echo SETUP_MUTATION >>"$RESTORE_LOG"; exit 77 ;;
    *) echo "unexpected privileged test command: $1" >&2; exit 99 ;;
esac
STUB
cat >"$stub/btrfs" <<'STUB'
#!/bin/bash
case "$1 $2" in
    'subvolume show') exit 0 ;;
    'subvolume list')
        [ "${RESTORE_NESTED:-no}" != yes ] || echo 'ID 300 gen 1 top level 256 path root/var/lib/flatpak'
        exit 0 ;;
    'inspect-internal rootid')
        case "$3" in */home) echo 257 ;; *) echo 256 ;; esac ;;
    'subvolume snapshot')
        [ "${RESTORE_SNAPSHOT_FAIL:-no}" != yes ] || exit 1
        case "$4" in
            */home) cp -a "$4" "$5" ;;
            *) mkdir -p "$5"; printf 'root before setup\n' >"$5/root-state" ;;
        esac ;;
    'property get') echo ro=true ;;
    *) echo 'unexpected Btrfs test command' >&2; exit 99 ;;
esac
STUB
cat >"$stub/findmnt" <<'STUB'
#!/bin/bash
case "$*" in
    *' -M '*) [ "${RESTORE_ESP:-yes}" = yes ]; exit ;;
    *TARGET,SOURCE,FSTYPE,UUID,FSROOT*) printf '%s fixture btrfs fixture-filesystem /root\n' "$RESTORE_FIXTURE/" ;;
    *FSTYPE*) echo "${RESTORE_FSTYPE:-btrfs}" ;;
    *UUID*) echo fixture-filesystem ;;
    *FSROOT*) case "${*: -1}" in */home) echo /home ;; *) echo /root ;; esac ;;
    *TARGET*) printf '%s\n' "$RESTORE_FIXTURE/" "$RESTORE_FIXTURE/home" "$RESTORE_FIXTURE/boot"
        [ "${RESTORE_SEPARATE_VAR:-no}" != yes ] || echo "$RESTORE_FIXTURE/var" ;;
    *) exit 99 ;;
esac
STUB
cat >"$stub/df" <<'STUB'
#!/bin/bash
printf 'Filesystem 1-blocks Used Available Capacity Mounted\nfixture 99999999999 0 %s 0%% /\n' "${RESTORE_FREE:-99999999999}"
STUB
cat >"$stub/timedatectl" <<'STUB'
#!/bin/bash
echo no
STUB
cat >"$stub/tar" <<'STUB'
#!/bin/bash
case "$*" in
    *-cpf*) [ "${RESTORE_TAR_FAIL:-no}" != yes ] || exit 1 ;;
esac
exec "$REAL_TAR" "$@"
STUB
printf '#!/bin/bash\necho 44\n' >"$stub/rpm"
printf '#!/bin/bash\necho x86_64\n' >"$stub/uname"
printf '#!/bin/bash\nexit 0\n' >"$stub/kwriteconfig6"
chmod +x "$stub"/*

cat >"$scratch/run-backup.sh" <<'TEST'
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1090
source "$RESTORE_LIBRARY"
create_setup_restore_point "$RESTORE_FIXTURE"
printf '%s\n' "$SETUP_RESTORE_DIR"
TEST
export RESTORE_LIBRARY="$repo/scripts/lib/restore.sh"
backup=$(PATH="$stub:$PATH" bash "$scratch/run-backup.sh" 2>"$scratch/output") || fail "default Btrfs backup failed"
[ -f "$backup/READY" ] || fail "completed backup lacks READY marker"
[ "$(stat -c %a "$backup")" = 700 ] || fail "backup run directory is not private"
[ "$(stat -c %a "$fixture/.fedora-kde-setup-backups")" = 700 ] || fail "backup parent is not private"
mkdir "$scratch/recovered-boot" "$scratch/recovered-esp"
tar -xpf "$backup/boot.tar" -C "$scratch/recovered-boot"
tar -xpf "$backup/esp.tar" -C "$scratch/recovered-esp"
cmp "$fixture/boot/vmlinuz-test" "$scratch/recovered-boot/vmlinuz-test"
cmp "$fixture/boot/efi/EFI/test/loader.efi" "$scratch/recovered-esp/EFI/test/loader.efi"
cmp "$fixture/home/tester/.config/kwinrc" "$backup/home/tester/.config/kwinrc"
(cd "$backup" && sha256sum -c SHA256SUMS >/dev/null) || fail "recorded archive checksums failed"
reused=$(PATH="$stub:$PATH" bash "$scratch/run-backup.sh" 2>"$scratch/output") || fail "reusing a completed backup failed"
[ "$reused" = "$backup" ] || fail "a second run did not reuse the completed backup"
[ "$(find "$fixture/.fedora-kde-setup-backups" -maxdepth 1 -name 'run-*' | wc -l)" -eq 1 ] || fail "a second run created another backup"

for scenario in filesystem space archive snapshot nested mount missing; do
    test_path="$stub:$PATH"
    case "$scenario" in
        filesystem) flag=RESTORE_FSTYPE=ext4 ;;
        space) flag=RESTORE_FREE=1 ;;
        archive) flag=RESTORE_TAR_FAIL=yes ;;
        snapshot) flag=RESTORE_SNAPSHOT_FAIL=yes ;;
        nested) flag=RESTORE_NESTED=yes ;;
        mount) flag=RESTORE_SEPARATE_VAR=yes ;;
        missing) flag=RESTORE_FSTYPE=btrfs; mv "$stub/btrfs" "$stub/btrfs.off"; test_path="$stub" ;;
    esac
    : >"$RESTORE_LOG"
    # a completed earlier run would be reused, so each scenario starts without one
    rm -rf "$fixture/.fedora-kde-setup-backups"
    if env PATH="$test_path" "$flag" "$BASH" "$scratch/run-backup.sh" >"$scratch/failed-path" 2>"$scratch/output"; then
        fail "$scenario did not stop backup preparation"
    fi
    [ "$scenario" != missing ] || grep -q 'required tool missing: btrfs' "$scratch/output" || fail "missing tool gate was not exercised"
    [ "$scenario" != missing ] || mv "$stub/btrfs.off" "$stub/btrfs"
    ! grep -q SETUP_MUTATION "$RESTORE_LOG" || fail "$scenario reached a system mutation"
    [ "$(find "$fixture/.fedora-kde-setup-backups" -name READY 2>/dev/null | wc -l)" -eq 0 ] || fail "incomplete backup was announced as ready"
done

if [ "$EUID" -ne 0 ]; then
    rm -rf "$fixture/.fedora-kde-setup-backups"
    mini="$scratch/repo"
    mkdir -p "$mini/scripts/lib"
    sed "s@/etc/fedora-release@$fixture/etc/fedora-release@g" "$repo/scripts/fedora-setup.sh" >"$mini/scripts/fedora-setup.sh"
    cp "$repo/scripts/lib/hw.sh" "$mini/scripts/lib/hw.sh"
    cat >"$mini/scripts/lib/restore.sh" <<'TEST'
# shellcheck shell=bash
create_setup_restore_point() {
    # shellcheck disable=SC1090
    source "$RESTORE_LIBRARY"
    create_setup_restore_point "$RESTORE_FIXTURE"
}
TEST
    : >"$RESTORE_LOG"
    if PATH="$stub:$PATH" HW_ROOT="$fixture" RESTORE_TAR_FAIL=yes bash "$mini/scripts/fedora-setup.sh" --yes \
        >"$scratch/output" 2>&1; then
        fail "main installer accepted a failed pre-install backup"
    fi
    ! grep -q SETUP_MUTATION "$RESTORE_LOG" || fail "main installer changed config/packages before backup completion"
    grep -q 'archive failed:' "$scratch/output" || fail "main installer did not reach its backup gate"

    : >"$RESTORE_LOG"
    PATH="$stub:$PATH" HW_ROOT="$fixture" bash "$mini/scripts/fedora-setup.sh" --yes >"$scratch/output" 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 77 ] || fail "main installer did not reach the guarded first system change after backup (exit $rc)"
    grep -q 'Recovery files:' "$scratch/output" || fail "main installer did not announce a completed backup"
fi

echo 'Setup recovery gates and synthetic root/home/boot/EFI recovery checks passed.'
