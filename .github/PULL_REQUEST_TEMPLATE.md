<!-- One short imperative title. The body is optional; this list is the review checklist. -->

- [ ] `shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh system/*.sh` is clean
- [ ] `bash tests/hw-detect.sh` passes
- [ ] `bash tests/verify-setup.sh` passes
- [ ] `bash tests/helper-scripts.sh` passes
- [ ] `bash tests/fedora-setup.sh` and `bash tests/ollama-setup.sh` pass
- [ ] `bash tests/setup-configs.sh` passes
- [ ] `bash tests/sleep-hooks.sh` and `bash tests/nvidia-vram.sh` pass
- [ ] `bash tests/emulation-setup.sh`, `bash tests/setup-restore.sh` and `bash tests/windows-vm.sh` pass
- [ ] `bash tests/fresh-install.sh` passes when changing deployment or README copy steps
- [ ] README updated for any new file, option or system change
- [ ] a new `system/` file is deployed by `apply-system.sh`; a new download is pinned and checksummed
