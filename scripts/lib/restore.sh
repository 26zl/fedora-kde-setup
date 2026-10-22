# shellcheck shell=bash
# Native snapshots protect the first package transaction without requiring Snapper.

restore_error() { printf 'Restore point: %s\n' "$*" >&2; return 1; }

restore_check_nested() {  # source filesystem-root home-mode
    local listing line relative prefix=${2#/}
    listing=$(sudo btrfs subvolume list -o "$1") || { restore_error "cannot inspect nested subvolumes at $1"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ $line == *" path "* ]] || { restore_error "unrecognized subvolume listing"; return 1; }
        relative=${line#* path }
        [ -z "$prefix" ] || relative=${relative#"$prefix"/}
        case "$relative" in
            .snapshots|.snapshots/*|.fedora-kde-setup-backups|.fedora-kde-setup-backups/*) continue ;;
        esac
        if [ "$3" = home ]; then
            restore_error "nested home subvolume $relative needs separate recovery protection"; return 1
        fi
        case "$relative" in
            var/lib/machines|var/lib/machines/*|var/lib/portables|var/lib/portables/*) continue ;;
            etc|etc/*|usr|usr/*|var|var/*|root|root/*|opt|opt/*|home|home/*)
                restore_error "nested system subvolume $relative is outside the supported root/home layout"; return 1 ;;
        esac
    done <<<"$listing"
}

restore_archive_boot() {  # source destination
    sudo tar --one-file-system --acls --xattrs --selinux --numeric-owner --sparse \
        -C "$1" -cpf "$2.partial" . || { restore_error "archive failed: $1 (incomplete backup retained)"; return 1; }
    sudo tar -tf "$2.partial" >/dev/null || { restore_error "archive verification failed: $1"; return 1; }
    sudo chmod 600 "$2.partial" || return 1
    sudo mv -- "$2.partial" "$2" || return 1
}

create_setup_restore_point() {  # optional filesystem fixture root
    local base=${1:-/} root home_type root_uuid home_uuid root_id home_id
    local root_fsroot home_fsroot path candidate mounts layout available required size esp=0 rtc command ready
    base=${base%/}
    root="$base/"
    for command in sudo btrfs findmnt tar sha256sum du df mktemp install timedatectl; do
        command -v "$command" >/dev/null || { restore_error "required tool missing: $command; no setup changes made"; return 1; }
    done
    [ "$(findmnt -n -o FSTYPE -T "$root")" = btrfs ] || {
        restore_error "a Btrfs root is required for pre-setup recovery; use a verified offline backup for another layout"; return 1;
    }
    sudo btrfs subvolume show "$root" >/dev/null || { restore_error "root is not a snapshot-capable subvolume"; return 1; }
    root_uuid=$(findmnt -n -o UUID -T "$root") || return 1
    root_fsroot=$(findmnt -n -o FSROOT -T "$root") || return 1
    root_id=$(sudo btrfs inspect-internal rootid "$root") || return 1
    [[ $root_id =~ ^[0-9]+$ ]] && [ -n "$root_uuid" ] || { restore_error "cannot identify root filesystem"; return 1; }
    restore_check_nested "$root" "$root_fsroot" root || return 1

    # Separate OS mounts are not captured by a root subvolume snapshot.
    mounts=$(findmnt --real -rn -o TARGET) || return 1
    while IFS= read -r path; do
        case "$path" in
            "$base"/etc|"$base"/etc/*|"$base"/usr|"$base"/usr/*|"$base"/var|"$base"/var/*|"$base"/root|"$base"/root/*|"$base"/opt|"$base"/opt/*)
                restore_error "separate system mount $path needs its own offline recovery backup"; return 1 ;;
            "$base"/home/*)
                restore_error "nested home mount $path needs its own offline recovery backup"; return 1 ;;
            "$base"/boot/efi) ;;
            "$base"/boot/*)
                restore_error "nested boot mount $path is outside the supported boot/EFI layout"; return 1 ;;
        esac
    done <<<"$mounts"
    home_type=$(findmnt -n -o FSTYPE -T "$base/home") || return 1
    home_uuid=$(findmnt -n -o UUID -T "$base/home") || return 1
    [ "$home_type" = btrfs ] && [ "$home_uuid" = "$root_uuid" ] || {
        restore_error "/home must be on the root Btrfs filesystem for this recovery path"; return 1;
    }
    home_id=$(sudo btrfs inspect-internal rootid "$base/home") || return 1
    [[ $home_id =~ ^[0-9]+$ ]] || { restore_error "cannot identify home subvolume"; return 1; }
    home_fsroot=$(findmnt -n -o FSROOT -T "$base/home") || return 1
    if [ "$home_id" != "$root_id" ]; then
        sudo btrfs subvolume show "$base/home" >/dev/null || { restore_error "/home must be a subvolume root"; return 1; }
        restore_check_nested "$base/home" "$home_fsroot" home || return 1
    fi

    [ -d "$base/boot" ] || { restore_error "/boot is missing"; return 1; }
    findmnt -rn -M "$base/boot/efi" >/dev/null && esp=1
    if [ -d "$base/sys/firmware/efi" ] && [ "$esp" -ne 1 ]; then
        restore_error "mount the EFI system partition at /boot/efi before setup"; return 1
    fi
    size=$(sudo du -sbx "$base/boot") || return 1
    read -r required _ <<<"$size"
    [[ $required =~ ^[0-9]+$ ]] || { restore_error "cannot measure boot archive space"; return 1; }
    if [ "$esp" -eq 1 ]; then
        size=$(sudo du -sbx "$base/boot/efi") || return 1
        read -r candidate _ <<<"$size"
        [[ $candidate =~ ^[0-9]+$ ]] || return 1
        required=$((required + candidate))
    fi
    available=$(df -PB1 "$root" | awk 'NR==2 {print $4}') || return 1
    [[ $available =~ ^[0-9]+$ ]] || { restore_error "cannot read free space"; return 1; }
    [ "$available" -ge "$((required + 536870912))" ] || { restore_error "not enough free space for boot archives and snapshot metadata"; return 1; }
    rtc=$(timedatectl show --property=LocalRTC --value) || { restore_error "cannot record RTC state"; return 1; }
    case "$rtc" in yes|no) ;; *) restore_error "unrecognized RTC state"; return 1 ;; esac
    layout=$(findmnt --real -rn -o TARGET,SOURCE,FSTYPE,UUID,FSROOT) || return 1

    # a completed restore point from an earlier run is reused; snapper covers the later runs
    if ready=$(sudo bash -c 'ls -d "$1"/run-*/READY 2>/dev/null | head -n 1' bash "$base/.fedora-kde-setup-backups") &&
        [ -n "$ready" ]; then
        SETUP_RESTORE_DIR=${ready%/READY}
        printf 'Restore point: reusing %s\n' "$SETUP_RESTORE_DIR" >&2
        return 0
    fi
    sudo install -d -m700 -- "$base/.fedora-kde-setup-backups" || return 1
    SETUP_RESTORE_DIR=$(sudo mktemp -d "$base/.fedora-kde-setup-backups/run-XXXXXXXX") || return 1
    sudo chmod 700 "$SETUP_RESTORE_DIR" || return 1
    printf 'Root UUID: %s\nRoot subvolume: %s\nHome subvolume: %s\nLocalRTC: %s\n' \
        "$root_uuid" "$root_fsroot" "$home_fsroot" "$rtc" | sudo tee "$SETUP_RESTORE_DIR/layout.txt" >/dev/null || return 1
    printf '%s\n' "$layout" | sudo tee "$SETUP_RESTORE_DIR/mounts.txt" >/dev/null || return 1
    sudo btrfs subvolume snapshot -r "$root" "$SETUP_RESTORE_DIR/root" >&2 || { restore_error "root snapshot failed; setup stopped"; return 1; }
    [ "$(sudo btrfs property get -ts "$SETUP_RESTORE_DIR/root" ro)" = ro=true ] || { restore_error "root snapshot is not read-only"; return 1; }
    if [ "$home_id" != "$root_id" ]; then
        sudo btrfs subvolume snapshot -r "$base/home" "$SETUP_RESTORE_DIR/home" >&2 || { restore_error "home snapshot failed; setup stopped"; return 1; }
        [ "$(sudo btrfs property get -ts "$SETUP_RESTORE_DIR/home" ro)" = ro=true ] || { restore_error "home snapshot is not read-only"; return 1; }
    fi
    restore_archive_boot "$base/boot" "$SETUP_RESTORE_DIR/boot.tar" || return 1
    if [ "$esp" -eq 1 ]; then
        restore_archive_boot "$base/boot/efi" "$SETUP_RESTORE_DIR/esp.tar" || return 1
    fi
    sudo bash -c 'cd "$1" && sha256sum boot.tar layout.txt mounts.txt >SHA256SUMS &&
        if [ -f esp.tar ]; then sha256sum esp.tar >>SHA256SUMS; fi && sha256sum -c SHA256SUMS' \
        bash "$SETUP_RESTORE_DIR" >&2 || { restore_error "backup checksum verification failed"; return 1; }
    sudo tee "$SETUP_RESTORE_DIR/RECOVERY.txt" >/dev/null <<'RECOVERY' || return 1
This directory is retained until you remove it; Snapper does not manage it.
Before recovery, save newer files elsewhere and boot a Fedora live USB.
Mount the Btrfs filesystem by the UUID in layout.txt with subvolid=5.
Locate this directory under the recorded root subvolume and verify SHA256SUMS.
Create writable snapshots of root and, if present, home under unused sibling names.
Keep the current subvolumes under other names, then move the writable replacements
to the original subvolume paths recorded in layout.txt; preserve required nested
mount points and check /etc/fstab and boot subvol=/subvolid= arguments before boot.
Mount the original /boot and EFI system partition separately and restore boot.tar
and esp.tar into their respective mount points, preserving owners and attributes.
Do not extract boot.tar over a mounted ESP: it is archived separately.
Restore the recorded RTC policy with timedatectl set-local-rtc after booting.
Root/home snapshots are sequential filesystem restore points, not a disk backup
or an atomic application transaction. Close applications and package managers first.
Other mounted disks, old nested snapshots, firmware and EFI NVRAM are not backed up.
Do not use snapper rollback on these unmanaged snapshots.
RECOVERY
    printf 'Backup creation and archive checks completed.\n' | sudo tee "$SETUP_RESTORE_DIR/READY" >/dev/null || return 1
}
