# Agent instructions

Guidance for AI coding agents working in this repository. Humans should read the README;
the check commands and conventions live in CONTRIBUTING.md and apply here too.

## What this is

Post-install setup for Fedora KDE Plasma 6 on Wayland: config files and Bash scripts, no
build system and no runtime. `scripts/` holds the scripts (`scripts/lib/hw.sh` is the shared
hardware detection), `system/` the files deployed to system paths, `configs/` the files
deployed to user paths, `tests/` the CI checks. `fedora-setup.sh` runs once on a fresh
install; `apply-system.sh` re-deploys `system/` files.

## Before finishing

Run the checks in CONTRIBUTING.md. The live-system check (`bash scripts/verify-setup.sh`) is
read-only; the deployed copies of `system/` files can be compared with:

```bash
awk '$1=="sudo" && $2=="cp" {print $3, $4}' scripts/apply-system.sh |
  while read -r s d; do cmp -s "$s" "$d" || echo "DIFF: $s"; done
```

## Boundaries

- The scripts change the live system as root and ask once before doing so; `fedora-setup.sh`
  and `apply-system.sh` refuse to run without a terminal unless given `--yes`. Do not run
  them against a real machine from an agent session without being asked.
- Do not add download-and-pipe-to-shell steps, weaken the crypto policy, or install server or
  developer runtimes; the setup stays gaming- and desktop-focused (security tooling is
  documented in the README, not installed).
- Pin any upstream binary by version and SHA-256, or by commit.
- Do not commit or push unless asked.
