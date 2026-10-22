#!/bin/bash
# System status — quick health overview

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

HWSTAT="$(dirname "$(readlink -f "$0")")/hwstat.sh"

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
GRAY='\033[38;2;144;168;160m'
WHITE='\033[38;2;200;216;208m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' GRAY='' WHITE='' RESET=''; fi

line() { echo -e "${TEAL}────────────────────────────────────${RESET}"; }

echo ""
line
echo -e "  ${TEAL}SYSTEM STATUS${RESET}  $(date '+%A, %d %B %Y  %H:%M')"
line

KERNEL=$(uname -r)
UPTIME=$(uptime -p | sed 's/up //')
echo -e "  ${GRAY}kernel ${RESET}${WHITE}${KERNEL}${RESET}"
echo -e "  ${GRAY}uptime ${RESET}${WHITE}${UPTIME}${RESET}"

line

# CPU counters are cumulative since boot, so load uses the delta between samples.
read -r _ u1 n1 s1 i1 w1 irq1 soft1 steal1 _ < /proc/stat
sleep 0.5
read -r _ u2 n2 s2 i2 w2 irq2 soft2 steal2 _ < /proc/stat
CPU_LOAD=$(awk -v busy=$(( (u2 + n2 + s2 + irq2 + soft2 + steal2) - (u1 + n1 + s1 + irq1 + soft1 + steal1) )) \
               -v total=$(( (u2 + n2 + s2 + i2 + w2 + irq2 + soft2 + steal2) - (u1 + n1 + s1 + i1 + w1 + irq1 + soft1 + steal1) )) \
               'BEGIN {printf "%.1f", total ? busy * 100 / total : 0}')
CPU_FREQ=$(grep 'cpu MHz' /proc/cpuinfo | awk '{sum+=$4; count++} END {printf "%.2f", sum/count/1000}')
CPU_TEMP=$("$HWSTAT" cpu-temp)
CPU_NAME=$(grep -m1 'model name' /proc/cpuinfo |
    sed -E 's/.*: //; s/\((R|TM)\)//g; s/ CPU @.*$//; s/^.*(AMD|Intel) //; s/ [0-9]+-Core Processor *$//; s/ (w\/|with) Radeon.*$//')
echo -e "  ${TEAL}CPU  ${GRAY}${CPU_NAME}${RESET}"
echo -e "  ${GRAY}load   ${WHITE}${CPU_LOAD}%  ${GRAY}freq  ${WHITE}${CPU_FREQ}GHz  ${GRAY}temp  ${WHITE}${CPU_TEMP:-N/A}${RESET}"

line

GPU_NAME=$("$HWSTAT" gpu-name)
GPU_TEMP=$("$HWSTAT" gpu-temp)
GPU_LOAD=$("$HWSTAT" gpu-load)
GPU_VRAM=$("$HWSTAT" gpu-vram)
if [ -n "$GPU_NAME" ]; then
    echo -e "  ${TEAL}GPU  ${GRAY}${GPU_NAME}${RESET}"
    GPU_LINE=""
    [ -n "$GPU_TEMP" ] && GPU_LINE+="${GRAY}temp   ${WHITE}${GPU_TEMP}  "
    [ -n "$GPU_LOAD" ] && GPU_LINE+="${GRAY}load  ${WHITE}${GPU_LOAD}  "
    [ -n "$GPU_VRAM" ] && GPU_LINE+="${GRAY}vram  ${WHITE}${GPU_VRAM}"
    [ -n "$GPU_LINE" ] && echo -e "  ${GPU_LINE}${RESET}"
    line
fi

MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_PCT=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}')
SWAP_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')
SWAP_LABEL=swap
swapon --show=NAME --noheadings 2>/dev/null | grep -q zram && SWAP_LABEL=zram
echo -e "  ${TEAL}MEMORY${RESET}"
echo -e "  ${GRAY}ram    ${WHITE}${MEM_USED} / ${MEM_TOTAL} ${GRAY}(${MEM_PCT}%)${RESET}"
printf "  ${GRAY}%-6s ${WHITE}%s / %s${RESET}\n" "$SWAP_LABEL" "$SWAP_USED" "$SWAP_TOTAL"

line

# Disk — root, plus every disk mounted directly under /mnt (e.g. /mnt/data)
ROOT_USED=$(df -h / | awk 'NR==2 {print $3}')
ROOT_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
ROOT_PCT=$(df / | awk 'NR==2 {print $5}')
echo -e "  ${TEAL}DISK${RESET}"
echo -e "  ${GRAY}root   ${WHITE}${ROOT_USED} / ${ROOT_TOTAL} ${GRAY}(${ROOT_PCT})${RESET}"
while read -r MNT; do
    read -r MNT_USED MNT_TOTAL < <(df -h --output=used,size "$MNT" 2>/dev/null | awk 'NR==2 {print $1, $2}')
    [ -n "$MNT_USED" ] && printf "  ${GRAY}%-6s ${WHITE}%s / %s${RESET}\n" "${MNT#/mnt/}" "$MNT_USED" "$MNT_TOTAL"
done < <(findmnt -rn -o TARGET 2>/dev/null | grep -E '^/mnt/[^/]+$')

line

IFACE=$(ip route show default | grep -oP 'dev \K\S+' | head -1)
IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "  ${TEAL}NETWORK${RESET}"
echo -e "  ${GRAY}ip     ${WHITE}${IP:-No address}${RESET}"

line

echo -e "  ${TEAL}TOP PROCESSES${RESET}"
ps -eo comm,pcpu --sort=-pcpu | head -4 | tail -3 | \
    awk -v teal="$TEAL" -v gray="$GRAY" -v white="$WHITE" -v reset="$RESET" \
    '{printf "  %s%-20s%s %s%s%%%s\n", gray, $1, reset, white, $2, reset}'

line
echo ""

WARN=0
[ "$MEM_PCT" -gt 85 ] && echo -e "  ${RED}WARNING: RAM usage above 85%${RESET}" && WARN=1
GPU_TEMP_C=${GPU_TEMP%%[!0-9]*}
[ "${GPU_TEMP_C:-0}" -gt 85 ] && echo -e "  ${RED}WARNING: GPU temp above 85°C${RESET}" && WARN=1
[ "${ROOT_PCT/\%/}" -gt 85 ] && echo -e "  ${RED}WARNING: Root disk above 85% full${RESET}" && WARN=1
[ "$WARN" -eq 0 ] && echo -e "  ${TEAL}All systems healthy.${RESET}"
echo ""
