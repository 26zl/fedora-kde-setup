#!/bin/bash
# GitHub CLI + git authentication. Run as regular user (NO sudo):
#   bash scripts/setup-github.sh

[ $# -eq 0 ] || { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; case $1 in -h | --help) exit 0 ;; *) exit 2 ;; esac; }

set -e

# gh stores credentials per user and opens the user's browser — sudo breaks both
if [ "$EUID" -eq 0 ]; then
    echo "Run without sudo: bash scripts/setup-github.sh" >&2
    exit 1
fi

TEAL='\033[38;2;0;200;168m'
RESET='\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR-}" ]; then TEAL='' RESET=''; fi

ok()      { echo -e "  ${TEAL}✓${RESET} $1"; }
info()    { echo -e "  ${TEAL}→${RESET} $1"; }
section() { echo -e "\n${TEAL}━━━ $1 ━━━${RESET}"; }

section "GitHub CLI"
if ! command -v gh &>/dev/null; then
    sudo dnf install -y gh
fi
ok "gh $(gh --version | head -1 | awk '{print $3}') installed"

section "GitHub login"
if gh auth status &>/dev/null; then
    ok "Already logged in to GitHub"
    gh auth status
else
    info "Logging in to GitHub via your web browser..."
    gh auth login --hostname github.com --git-protocol https --web
fi

section "git <-> gh credentials"
gh auth setup-git
ok "git wired to gh credential helper"

section "git identity"
# Hidden account email falls back to GitHub's privacy-preserving noreply address.
login="$(gh api user --jq .login)"
id="$(gh api user --jq .id)"
email="$(gh api user --jq '.email // empty')"
[ -z "$email" ] && email="${id}+${login}@users.noreply.github.com"
git config --global user.name "$login"
git config --global user.email "$email"

git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global push.autoSetupRemote true

ok "user.name  = $(git config --global user.name)"
ok "user.email = $(git config --global user.email)"
