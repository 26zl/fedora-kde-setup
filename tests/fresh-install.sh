#!/bin/bash
# Test system deployment, README copy steps and setup confirmation in throwaway Fedora containers.
# Commands that need a booted system are stubbed; filesystem changes are real.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
image=registry.fedoraproject.org/fedora:44

if [ "${1-}" != --inside ]; then
    engine=$(command -v podman || command -v docker) || { echo "needs podman or docker" >&2; exit 2; }
    failed=0
    for target in desktop laptop readme setup-gate; do
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
for c in grubby kwriteconfig6 modprobe restorecon setquota sysctl systemctl systemd-tmpfiles tuned-adm udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$stub/$c"
done
chmod +x "$stub"/*
# an empty HW_ROOT has no GPU, battery or Windows, so FORM_FACTOR and NVIDIA_DRIVER decide
HW_ROOT=$(mktemp -d)
export PATH="$stub:$PATH" NO_COLOR=1 HW_ROOT

case $2 in
    desktop) FORM_FACTOR=desktop NVIDIA_DRIVER=current bash scripts/apply-system.sh --yes ;;
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
        if bash scripts/fedora-setup.sh </dev/null >/dev/null 2>&1; then
            echo "FAILED: fedora-setup.sh ran as root" >&2; exit 1
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
                release) stub_command='rpm'; value=43; message="targets Fedora 44" ;;
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
