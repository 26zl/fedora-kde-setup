# Security Policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository (Security tab, "Report a vulnerability"). Please do not open a public issue for security problems. Include the script and line, the Fedora release and what the script changed on the system.

## Scope

The scripts run commands as root through `sudo` and change the system: package repositories, kernel arguments, sysctl, udev rules, systemd units, the firewall and a systemd sleep hook. A flaw in what they install, how they download it or how they configure the machine is in scope. Vulnerabilities in the packages themselves belong to their upstreams: Fedora, RPM Fusion, the COPR owners, Terra, NVIDIA, Flathub and the Dolphin team's Flatpak repository, the projects whose pinned GitHub or GitLab releases or commits the scripts download (lazygit, ble.sh, Nerd Fonts, DuckStation, ES-DE, RPCS3, shadPS4, Xenia Edge, Ollama, Strata), the Hugging Face model `ollama-setup.sh` pulls, and the PyPI packages `uvx` resolves for Strata's web search (`duckduckgo-mcp-server`, pinned by version and by an upload-date cutoff).

Only `main` is supported.
