#!/bin/bash
# Rice starter — restarts the Conky user service

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e

systemctl --user restart conky.service
echo "Rice is live."
