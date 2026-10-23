#!/bin/bash
# xHCI needs every attached device suspended; the LAMZU dongle requires deauthorization.
AUTOSUSPEND_DEVS="048d:5711 046d:c548"
DEAUTH_DEVS="373e:001e"

find_dev() {
    local vid="${1%%:*}" pid="${1##*:}"
    for dev in "${HW_ROOT:-}"/sys/bus/usb/devices/*/; do
        [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
        [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ] && \
        echo "$dev" && return
    done
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
fi
