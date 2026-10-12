#!/bin/bash
# systemd sleep hook. Two device quirks, each a no-op when the device is absent:
#  - USB: an xHCI controller only reaches D3 when every device on it autosuspends.
#    The ITE RGB controller and Logitech receiver are forced to autosuspend over
#    sleep; the LAMZU dongle (373e:001e) can't (-110), so it is deauthorized
#    over sleep and re-authorized on resume.
#  - amdgpu can drop a DP/USB-C monitor while re-training the link on resume.
#    External outputs that were on before sleep are switched back on; outputs
#    that were off stay off, and laptop panels are left to KWin's lid handling.
AUTOSUSPEND_DEVS="048d:5711 046d:c548"
DEAUTH_DEVS="373e:001e"
# SELinux lets systemd_sleep_t create files only in systemd-sleep's own state directory, not in /run
OUTPUTS_STATE=/var/lib/systemd/sleep/kwin-display-fix.outputs

find_dev() {
    local vid="${1%%:*}" pid="${1##*:}"
    for dev in /sys/bus/usb/devices/*/; do
        [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
        [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ] && \
        echo "$dev" && return
    done
}

# run a command as the user of the active Wayland session
in_session() {
    local s uid sock
    for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
        [ "$(loginctl show-session "$s" -p Type --value)" = wayland ] || continue
        [ "$(loginctl show-session "$s" -p Active --value)" = yes ] || continue
        uid=$(loginctl show-session "$s" -p User --value)
        sock=$(find "/run/user/$uid" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' -quit)
        runuser -u "$(id -nu "$uid")" -- env XDG_RUNTIME_DIR="/run/user/$uid" WAYLAND_DISPLAY="$sock" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" timeout 10 "$@"
        return
    done
    return 1
}

if [ "$1" = "pre" ]; then
    for vid_pid in $AUTOSUSPEND_DEVS; do
        dev=$(find_dev "$vid_pid")
        [ -n "$dev" ] && echo 0 > "$dev/power/autosuspend_delay_ms" 2>/dev/null
        [ -n "$dev" ] && echo auto > "$dev/power/control" 2>/dev/null
    done
    for vid_pid in $DEAUTH_DEVS; do
        dev=$(find_dev "$vid_pid")
        [ -n "$dev" ] && echo 0 > "${dev}authorized" 2>/dev/null
    done
    : > "$OUTPUTS_STATE"
    if [ -d /sys/module/amdgpu ]; then
        in_session kscreen-doctor -j 2>/dev/null |
            jq -r '.outputs[] | select(.enabled) | .name' > "$OUTPUTS_STATE" 2>/dev/null
    fi
    sleep 0.5
fi

if [ "$1" = "post" ]; then
    for vid_pid in $AUTOSUSPEND_DEVS; do
        dev=$(find_dev "$vid_pid")
        [ -n "$dev" ] && echo on > "$dev/power/control" 2>/dev/null
    done
    for vid_pid in $DEAUTH_DEVS; do
        dev=$(find_dev "$vid_pid")
        if [ -n "$dev" ]; then
            # cycle 0→1 to power-reset dongle RF state and wake mouse from deep sleep
            echo 0 > "${dev}authorized" 2>/dev/null
            sleep 0.3
            echo 1 > "${dev}authorized" 2>/dev/null
        fi
    done

    if [ -d /sys/module/amdgpu ]; then
        sleep 4
        # the external outputs that were on before sleep; every connected one
        # when nothing was recorded (no session before sleep, or no state file)
        before=$(cat "$OUTPUTS_STATE" 2>/dev/null)
        mapfile -t enable < <(in_session kscreen-doctor -j 2>/dev/null |
            jq -r --arg before "$before" '
                ($before | split("\n") | map(select(length > 0))) as $was
                | .outputs[]
                | select(.connected)
                | select(($was | length) == 0 or (.name | IN($was[])))
                | select(.name | test("^(eDP|LVDS|DSI)") | not)
                | "output.\(.name).enable"')
        if [ ${#enable[@]} -gt 0 ]; then
            in_session kscreen-doctor "${enable[@]}" >/dev/null 2>&1 || true
        fi

        sleep 1
        in_session dbus-send --session --dest=org.kde.KWin \
            --type=method_call /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    fi
    rm -f "$OUTPUTS_STATE"
fi
