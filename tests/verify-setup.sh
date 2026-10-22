#!/bin/bash
# Critical system probes must report unavailable services as failures.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts/lib" "$tmp/bin" "$tmp/hardware"
cp "$repo/scripts/verify-setup.sh" "$repo/scripts/apply-system.sh" "$tmp/repo/scripts/"
cp "$repo/scripts/lib/hw.sh" "$tmp/repo/scripts/lib/"

cat >"$tmp/bin/systemctl" <<'STUB'
#!/bin/bash
if [ "$1" = --failed ]; then
    [ "$VERIFY_PROBES" = available ] || exit 1
    echo 'example.service loaded failed failed Example service'
fi
exit 0
STUB
cat >"$tmp/bin/tuned-adm" <<'STUB'
#!/bin/bash
[ "$VERIFY_PROBES" = available ] || exit 1
echo 'Current active profile: balanced'
STUB
cat >"$tmp/bin/firewall-cmd" <<'STUB'
#!/bin/bash
[ "$VERIFY_PROBES" = available ] || exit 1
case $* in
    --get-default-zone) echo public ;;
    *--list-services) echo dhcpv6-client ;;
    *--list-ports) echo "${VERIFY_PORTS-}" ;;
esac
STUB
for command in dnf curl; do
    printf '#!/bin/bash\nexit 1\n' >"$tmp/bin/$command"
done
chmod +x "$tmp/bin/"*

run_probe() {
    output=$(PATH="$tmp/bin:$PATH" HW_ROOT="$tmp/hardware" FORM_FACTOR=laptop NVIDIA_DRIVER=none \
        NO_COLOR=1 VERIFY_PROBES="$1" bash "$tmp/repo/scripts/verify-setup.sh" 2>/dev/null) && status=0 || status=$?
    [ "$status" -eq 1 ] || { echo 'FAIL: verifier did not report fixture failures' >&2; exit 1; }
}

expect() {
    [[ $output == *"$1"* ]] || { echo "FAIL: verifier omitted '$1'" >&2; exit 1; }
}

run_probe unavailable
expect '✗ cannot query system units'
expect '✗ tuned has no active profile'
expect '✗ cannot query firewalld'
[[ $output != *'✓ no failed system units'* && $output != *'✓ tuned:'* ]] ||
    { echo 'FAIL: unavailable probes reported success' >&2; exit 1; }

run_probe available
expect '✗ failed system units: example.service'
expect '✓ tuned: balanced'
expect '✓ firewall (public): dhcpv6-client service; no explicit ports'
export VERIFY_PORTS=8080/tcp
run_probe available
expect '→ firewall (public): services=dhcpv6-client; ports=8080/tcp'
[[ $output != *'✓ firewall'* ]] || { echo 'FAIL: explicit firewall ports were ignored' >&2; exit 1; }
echo 'All setup verification tests passed.'
