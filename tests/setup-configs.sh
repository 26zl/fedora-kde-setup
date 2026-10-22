#!/bin/bash
# Exercise config deployment and backup retention using temporary user files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck disable=SC1090
source <(sed -n '/^install_config() {/,/^}/p' scripts/fedora-setup.sh)

printf 'upstream\n' >"$scratch/source"
dest="$scratch/config/app.conf"
install_config "$scratch/source" "$dest"
cmp "$scratch/source" "$dest"

printf 'custom one\n' >"$dest"
install_config "$scratch/source" "$dest"
cmp "$scratch/source" "$dest"
grep -qx 'custom one' "$dest.~1~"

install_config "$scratch/source" "$dest"
[ ! -e "$dest.~2~" ]
printf 'custom two\n' >"$dest"
install_config "$scratch/source" "$dest"
grep -qx 'custom one' "$dest.~1~"
grep -qx 'custom two' "$dest.~2~"

mkdir -p "$scratch/theme-source" "$scratch/theme-target"
mkdir -p "$scratch/theme-source/nested"
printf 'hidden setting\n' >"$scratch/theme-source/nested/.settings"
printf 'theme default\n' >"$scratch/theme-source/settings"
printf 'custom theme\n' >"$scratch/theme-target/settings"
printf 'local extension\n' >"$scratch/theme-target/extra"
install_config "$scratch/theme-source" "$scratch/theme-target"
cmp "$scratch/theme-source/settings" "$scratch/theme-target/settings"
grep -qx 'custom theme' "$scratch/theme-target/settings.~1~"
grep -qx 'local extension' "$scratch/theme-target/extra"
cmp "$scratch/theme-source/nested/.settings" "$scratch/theme-target/nested/.settings"
install_config "$scratch/theme-source" "$scratch/theme-target"
[ ! -e "$scratch/theme-target/settings.~2~" ]

echo 'config deployment: existing files and theme extensions preserved; unchanged reruns create no backups'
