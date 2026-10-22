#!/bin/bash
# Re-enroll the akmods signing key after a BIOS flash cleared the MOK list, which
# leaves akmods-built modules such as NVIDIA's unloadable under Secure Boot; run it from the TTY.

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e

TEAL='\033[38;2;0;200;168m'
RED='\033[38;2;170;28;28m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RED='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
warn()    { echo -e "  ${RED}!${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

section "State"
if ! SB=$(mokutil --sb-state 2>/dev/null); then
    warn "cannot determine Secure Boot state"
    exit 1
fi
case "$SB" in
    *"SecureBoot enabled"*) ;;
    *"SecureBoot disabled"*) ok "Secure Boot is off — nothing to enroll"; exit 0 ;;
    *) warn "unknown Secure Boot state"; exit 1 ;;
esac
ok "Secure Boot enabled"

NVIDIA=0
lspci -n 2>/dev/null | grep -Eq ' 03[0-9a-f]{2}: 10de:' && NVIDIA=1
if [ "$NVIDIA" -eq 1 ]; then
    if lsmod | grep -q '^nvidia'; then
        ok "nvidia module already loaded"
    else
        warn "nvidia module not loaded"
    fi
fi
lspci -k | grep -A3 -Ei 'VGA|3D controller|Display controller' | grep 'Kernel driver' | sed 's/^\s*/  /' || true

KEY=""
for candidate in /etc/pki/akmods/certs/public_key.der /etc/pki/akmods/certs/*.der; do
    [ -f "$candidate" ] && { KEY="$candidate"; break; }
done
[ -n "$KEY" ] || { warn "no signing key under /etc/pki/akmods/certs"; exit 1; }
echo "  key: $KEY"

if mokutil --test-key "$KEY" 2>/dev/null | grep -q "already enrolled"; then
    ok "key is already enrolled — nothing to do"
    if [ "$NVIDIA" -eq 1 ] && ! lsmod | grep -q '^nvidia'; then
        warn "but nvidia is not loaded, so the problem is elsewhere: check 'dmesg | grep -i nvidia'"
    fi
    exit 0
fi
warn "key is NOT enrolled — this is why the modules will not load"

section "Enrollment"
[ -t 0 ] || { warn "needs an interactive terminal for the password prompt"; exit 1; }
cat <<'INFO'
  You will now set a ONE-TIME password, entered twice. It is used once at the
  next boot and then discarded. Use digits only, e.g. 12345678 — the MOK screen
  is US layout, so letters on other keyboard layouts land in the wrong place.

  After this finishes, reboot. A blue "Shim UEFI key management" screen appears
  and waits about 10 seconds:

      Enroll MOK  ->  Continue  ->  Yes  ->  password  ->  Reboot

  Miss the window and nothing breaks — just run this script again.
INFO
read -rp "  Enter to continue, Ctrl+C to abort: " _

mokutil --import "$KEY"

if mokutil --list-new 2>/dev/null | grep -q .; then
    ok "enrollment queued — reboot and follow the blue screen"
else
    warn "nothing queued, the import may have failed"
    exit 1
fi
