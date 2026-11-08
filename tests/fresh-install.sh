#!/bin/bash
# Test system deployment, README copy steps and setup confirmation in throwaway Fedora containers.
# Commands that need a booted system are stubbed; filesystem changes are real.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
image=registry.fedoraproject.org/fedora:45

if [ "${1-}" != --inside ]; then
    engine=$(command -v podman || command -v docker) || { echo "needs podman or docker" >&2; exit 2; }
    failed=0
    for target in desktop desktop-580xx laptop readme setup-gate; do
        echo "==> $target"
        # a local setup.conf would override the hardware under test
        # shellcheck disable=SC2016  # $0 is expanded by the container's shell
        tar --exclude=.git --exclude=setup.conf -cf - . |
            "$engine" run --rm -i "$image" bash -c \
                'mkdir /repo && tar -xf - -C /repo && exec bash /repo/tests/fresh-install.sh --inside "$0"' "$target" ||
            failed=1
    done
    exit "$failed"
fi

[ -e /run/.containerenv ] || [ -e /.dockerenv ] || { echo "--inside writes to /etc: container only" >&2; exit 2; }
# the packages that own the remaining target directories on every Fedora KDE install
dnf -y -q install systemd-udev kmod tuned diffutils
stub=$(mktemp -d)
printf '#!/bin/sh\nexec "$@"\n' >"$stub/sudo"
printf '#!/bin/sh\nexit 1\n' >"$stub/snapper"
for c in grubby kreadconfig6 kwriteconfig6 modprobe restorecon setquota sysctl systemctl systemd-tmpfiles tuned-adm udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$stub/$c"
done
chmod +x "$stub"/*
# an empty HW_ROOT has no GPU, battery or Windows, so FORM_FACTOR and NVIDIA_DRIVER decide
HW_ROOT=$(mktemp -d)
export PATH="$stub:$PATH" NO_COLOR=1 HW_ROOT

case $2 in
    desktop)
        # real KConfig tools: the login screen key must not replace a wallpaper chosen in System Settings
        dnf -y -q install kf6-kconfig
        rm "$stub/kreadconfig6" "$stub/kwriteconfig6"
        apply() { RICE=$1 FORM_FACTOR=desktop NVIDIA_DRIVER=current bash scripts/apply-system.sh --yes; }
        greeter=(--file /etc/plasmalogin.conf --group Greeter --group Wallpaper --group org.kde.image --group General --key Image)
        expect_wp() { [ "$(kreadconfig6 "${greeter[@]}")" = "$1" ] || { echo "FAILED: $2" >&2; exit 1; }; }
        apply yes
        expect_wp file:///usr/share/wallpapers/custom/wallpaper.jpg "the login screen wallpaper was not set"
        [ ! -e /etc/modprobe.d/nvidia-580xx-storage.conf ] || { echo "FAILED: the current driver got the 580xx store" >&2; exit 1; }
        apply no >/dev/null
        expect_wp "" "RICE=no left the login screen wallpaper in place"
        [ ! -e /usr/share/wallpapers/custom/wallpaper.jpg ] || { echo "FAILED: RICE=no kept the wallpaper copy" >&2; exit 1; }
        kwriteconfig6 "${greeter[@]}" file:///var/lib/plasmalogin/wallpapers/own.jpg
        apply yes >/dev/null
        apply no >/dev/null
        expect_wp file:///var/lib/plasmalogin/wallpapers/own.jpg "a wallpaper chosen in System Settings was replaced"
        echo "apply-system.sh: login screen wallpaper set, removed with RICE=no, and a chosen one kept"
        ;;
    desktop-580xx)
        FORM_FACTOR=desktop NVIDIA_DRIVER=580xx bash scripts/apply-system.sh --yes
        grep -q 'NVreg_TemporaryFilePath=/var/tmp' /etc/modprobe.d/nvidia-580xx-storage.conf ||
            { echo "FAILED: 580xx keeps its suspend store on the /tmp tmpfs" >&2; exit 1; }
        ;;
    laptop) FORM_FACTOR=laptop NVIDIA_DRIVER=none bash scripts/apply-system.sh --yes ;;
    readme)
        failed=0 prev=""
        while IFS=$'\t' read -r block cmd; do
            if [ "$block" != "$prev" ]; then
                # what the first Plasma login leaves; anything deeper is the step's own job
                HOME=$(mktemp -d)
                mkdir -p "$HOME/.config" "$HOME/.local/share"
                prev=$block
            fi
            eval "$cmd" || { echo "FAILED (README bash block $block): $cmd" >&2; failed=1; }
        done < <(awk '/^```bash/ { b++; f = 1; next } /^```/ { f = 0 }
            f { l = l $0; if (sub(/\\$/, "", l)) next; sub(/[ \t]+#.*$/, "", l)
                if (l ~ /^(sudo )?(cp|mkdir -p) / && l ~ /[ \t][~\/][^ \t]*$/) print b "\t" l; l = "" }' README.md)
        exit "$failed"
        ;;
    setup-gate)
        # Noninteractive setup must stop at confirmation before the first sudo call.
        out=$(bash scripts/fedora-setup.sh </dev/null 2>&1) && rc=0 || rc=$?
        if [ "$rc" -eq 0 ] || [[ $out != *"run as a normal user"* ]]; then
            echo "FAILED: fedora-setup.sh did not refuse root (exit $rc)" >&2; exit 1
        fi
        useradd -m tester && chmod 755 "$stub" "$HW_ROOT"
        out=$(runuser -u tester -- env PATH="$PATH" HW_ROOT="$HW_ROOT" NO_COLOR=1 HOME=/home/tester \
            bash scripts/fedora-setup.sh </dev/null 2>&1) && rc=0 || rc=$?
        if [ "$rc" -ne 1 ] || [[ $out != *"━━━ Plan ━━━"* ]] || [[ $out != *"not a terminal"* ]]; then
            echo "FAILED: expected the plan and a refusal with exit 1, got exit $rc:" >&2; echo "$out" >&2; exit 1
        fi
        echo "fedora-setup.sh: refuses root, prints the plan and stops without --yes"
        printf '#!/bin/sh\necho "unexpected sudo call" >&2\nexit 99\n' >"$stub/sudo"
        for unsupported in architecture release; do
            case $unsupported in
                architecture) stub_command='uname'; value=aarch64; message="requires x86_64" ;;
                release) stub_command='rpm'; value=44; message="targets Fedora 45" ;;
            esac
            printf '#!/bin/sh\necho %s\n' "$value" >"$stub/$stub_command"
            chmod +x "$stub/$stub_command"
            out=$(runuser -u tester -- env PATH="$PATH" HW_ROOT="$HW_ROOT" NO_COLOR=1 HOME=/home/tester \
                bash scripts/fedora-setup.sh --yes </dev/null 2>&1) && rc=0 || rc=$?
            rm "$stub/$stub_command"
            if [ "$rc" -ne 1 ] || [[ $out != *"$message"* ]] || [[ $out == *"unexpected sudo call"* ]]; then
                echo "FAILED: unsupported $unsupported reached setup (exit $rc): $out" >&2; exit 1
            fi
        done
        echo "fedora-setup.sh: rejects unsupported architectures and releases before sudo"
        rm "$stub/kwriteconfig6"
        out=$(runuser -u tester -- env PATH="$PATH" HW_ROOT="$HW_ROOT" NO_COLOR=1 HOME=/home/tester \
            bash scripts/fedora-setup.sh --yes </dev/null 2>&1) && rc=0 || rc=$?
        if [ "$rc" -ne 1 ] || [[ $out != *"KDE Plasma 6"* ]] || [[ $out == *"unexpected sudo call"* ]]; then
            echo "FAILED: missing KDE tools reached setup (exit $rc): $out" >&2; exit 1
        fi
        echo "fedora-setup.sh: rejects missing KDE tools before sudo"
        ;;
    *) echo "unknown target: $2" >&2; exit 2 ;;
esac
