#!/bin/bash
# In a fresh Fedora container: add the repos the setup scripts add, then check that
# every package named on a "dnf install -y" line resolves. Run by CI for the current
# release and the next one, so a rename upstream or a repo that lags a release shows
# up before an install does.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# the next-release job passes "warning": a repo that lags the release is expected there
level=${1:-error}
rel=$(rpm -E %fedora)
echo "==> Fedora $rel: adding repos"
dnf -y -q install dnf5-plugins
dnf -y -q install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$rel.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$rel.noarch.rpm"
grep -hoP 'copr enable -y \K\S+' scripts/*.sh | while read -r c; do dnf -y -q copr enable "$c"; done
grep -hoP -- '--from-repofile=\K\S+' scripts/*.sh |
    while read -r r; do dnf -y -q config-manager addrepo --from-repofile="$r"; done
dnf -y -q install --repofrompath "terra,https://repos.fyralabs.com/terra$rel" \
    --setopt="terra.gpgkey=https://repos.fyralabs.com/terra$rel/key.asc" terra-release
# fetches every repo's metadata and signing keys once, so the queries below stay fast
dnf -y -q makecache

echo "==> Fedora $rel: resolving packages"
missing=0
for p in $(sed ':a;/\\$/{N;s/\\\n//;ba}' scripts/*.sh | grep -oP 'dnf install -y \K.*' |
           tr ' ' '\n' | grep -E '^[a-z0-9][a-z0-9._+-]*$' | sort -u); do
    # -y: makecache does not always import Terra's key; unanswered, the prompt drops the repo
    dnf -y -q repoquery --available "$p" | grep -q . || { echo "::$level::not available on Fedora $rel: $p"; missing=1; }
done
[ "$level" = warning ] && exit 0
exit $missing
