# Changelog

The repository follows the current Fedora release instead of version numbers, newest first. Each entry names the
pull request with the details.

## Unreleased: Fedora 45

- Strata v0.2.12. `STRATA_REV=latest` in `setup.conf` follows its newest release; a re-run fast-forwards the
  checkout and rebuilds the engine without sudo, and `verify-setup.sh` says when a newer release is out.
- Move to Fedora 45, exclude broken upgrade builds and check that every fstab entry is mounted (#39).
- Add an opt-in Windows 11 VM on KVM/libvirt; the root-equivalent `libvirt` group is opt-in (#40).
- NVIDIA suspend: the capacity check counts free RAM for the current driver's in-memory store, and 580xx saves
  video memory to `/var/tmp` instead of a `/tmp` of half the RAM.
- `verify-setup.sh` checks a newly installed kernel's filesystem drivers and NVIDIA module before it boots.
- `disk-cleanup.sh` asks before removing container images and gains `--dry-run`.
- `dnf.conf` keeps Fedora's `skip_if_unavailable=False`; `fedora-upgrade.sh` relaxes it for the release download,
  checks before it updates, reads dnf in English and stops when snapper cannot take the restore point.
- `ollama-setup.sh` tunes on a scratch copy, so an abort keeps the capped model, adds the rest of the nixpkgs
  sandbox and keeps an upstream-created `ollama` user's home writable.
- `apply-system.sh` restarts scx_loader and systemd-resolved whenever they have not read their current config.
- The scripts that change the system log their progress to the journal (`journalctl -t fedora-kde-setup`).
- Pins: lazygit 0.66.3, ble.sh `1529427`, DuckStation v0.1-12442, Ollama v0.40.15; Strata's web search pins
  its PyPI dependencies by upload date.
- CI: ShellCheck pinned, Trivy's severity filter applied to SARIF, a weekly full-history gitleaks scan, a wider
  private-IP check, and stub tests for `fedora-setup.sh` and `ollama-setup.sh`.

## Fedora 44

### 2026-11

- Switch scx back to scx_lavd (#36).
- Make the desktop look optional and stop overwriting `/etc/plasmalogin.conf` (#35).

### 2026-10

- Move `pull-requests: write` from the workflow to the gitleaks job (#34).
- Fix the audit and review findings: confirmations, recovery, sleep, pins, docs and Strata 0.2.3.1 (#31).
- Add an opt-in Ollama and Alpaca local-LLM setup (#30).
- List every file in the README tree and document `setup-github.sh` (#29).
- Trim snapper's timeline, add a disk cleanup script and install it to `~/scripts` (#27, #28).
- Unload Strata when idle, give its chat web search and turn on its refusal-direction vector (#25, #26).
- List firmware updates in the setup and add a firmware step to the guide (#24).
- Create missing target directories, harden the default firewall zone and test the deploy steps on a fresh
  Fedora (#22).
- Note what Fedora 45 changes for the setup and check Bluetooth after it (#18).
- Add a Fedora release upgrade script and a live setup check (#17).
- Exclude CUDA's driver packages, fix the sleep hook state path and harden the scripts (#16).
- Scope third-party repos, keep resvg in the yazi COPR scope and fix multi-machine defaults (#14, #15).
- Show packages that lag on the next release as warnings (#12).
- Add an opt-in Strata local LLM setup (#11).

### 2026-09

- Check package availability on the next Fedora release too (#9).
- Drop the unused Fedora Flatpak remote during setup (#8).
- Trim the Plasma theme to its two non-Breeze files and shrink the wallpaper (#7).
- Validate `setup.conf`, keep fixtures off the firmware and set `balanced` on laptops (#6).
- Detect the hardware and adapt the setup to it (#5).
- Add weekly Dependabot updates for GitHub Actions (#1); Dependabot keeps them current since (#2–#4, #10, #19,
  #21, #33).
