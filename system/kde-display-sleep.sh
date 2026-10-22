#!/bin/bash
# Capture before sleep.target; restore after systemd-sleep has thawed user sessions.
set -euo pipefail

case ${1-} in
    pre|post) ;;
    -h|--help) sed -n '2s/^# //p' "$0"; exit 0 ;;
    *) echo "Usage: $0 pre|post" >&2; exit 2 ;;
esac

umask 077
state_file="${RUNTIME_DIRECTORY:-/run/kde-display-sleep}/outputs.json"

find_session() {
    local candidate _
    while read -r candidate _; do
        [ "$(loginctl show-session "$candidate" -p Type --value)" = wayland ] || continue
        [ "$(loginctl show-session "$candidate" -p Class --value)" = user ] || continue
        [ "$(loginctl show-session "$candidate" -p Active --value)" = yes ] || continue
        session_uid=$(loginctl show-session "$candidate" -p User --value)
        [[ $session_uid =~ ^[0-9]+$ ]] || continue
        session_user=$(id -nu "$session_uid") || continue
        session_runtime="${HW_ROOT:-}/run/user/$session_uid"
        wayland_socket=$(find "$session_runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' -quit)
        [ -n "$wayland_socket" ] || continue
        session_id=$candidate
        return 0
    done < <(loginctl list-sessions --no-legend --no-pager)
    return 1
}

in_session() {
    timeout 5 runuser -u "$session_user" -- env XDG_RUNTIME_DIR="$session_runtime" \
        WAYLAND_DISPLAY="$wayland_socket" DBUS_SESSION_BUS_ADDRESS="unix:path=$session_runtime/bus" "$@"
}

read_outputs() {
    in_session kscreen-doctor -j | jq -ce '
        .outputs | select(type == "array")
        | select(all(.[]; (.name | type == "string") and (.enabled | type == "boolean")
            and (.connected | type == "boolean")))'
}

if [ "$1" = pre ]; then
    rm -f "$state_file"
    [ -d "${HW_ROOT:-}/sys/module/amdgpu" ] || exit 0
    find_session || exit 0
    outputs=$(read_outputs)
    jq -n --arg session "$session_id" --arg uid "$session_uid" --argjson outputs "$outputs" '
        {session: $session, uid: $uid, outputs: [$outputs[]
            | select(.enabled and .connected)
            | select(.name | test("^(eDP|LVDS|DSI)"; "i") | not) | .name]}' >"$state_file"
    exit 0
fi

[ -f "$state_file" ] || exit 0
trap 'rm -f "$state_file"' EXIT
[ -d "${HW_ROOT:-}/sys/module/amdgpu" ] || exit 0
saved=$(jq -ce 'select((.session | type == "string") and (.uid | type == "string")
    and (.outputs | type == "array") and all(.outputs[]; type == "string"))' "$state_file")
[ "$(jq '.outputs | length' <<< "$saved")" -gt 0 ] || exit 0
find_session || exit 0
[ "$session_id" = "$(jq -r '.session' <<< "$saved")" ] || exit 0
[ "$session_uid" = "$(jq -r '.uid' <<< "$saved")" ] || exit 0

# Allow amdgpu's external links to settle before comparing the resumed configuration.
sleep 4
outputs=$(read_outputs)
enable=$(jq -r --argjson saved "$saved" '.[]
    | select(.connected and (.enabled | not))
    | select(.name | test("^(eDP|LVDS|DSI)"; "i") | not)
    | select(.name | IN($saved.outputs[])) | "output.\(.name).enable"' <<< "$outputs")
if [ -n "$enable" ]; then
    mapfile -t enable_args <<< "$enable"
    in_session kscreen-doctor "${enable_args[@]}"
fi
