# Contributing

A personal Fedora KDE setup, kept public and actively maintained. Bug reports and pull
requests are welcome through GitHub issues and PRs; only `main` is supported (see
SECURITY.md).

## Before a pull request

```bash
shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh system/*.sh   # CI lints at severity warning
bash tests/hw-detect.sh                                            # detection fixtures, no root needed
bash tests/fresh-install.sh                                        # deploy steps in throwaway containers (podman or docker)
```

CI also resolves every package and Flatpak the scripts install (`tests/check-packages.sh`,
in a Fedora container), checks that every `system/` file is deployed by `apply-system.sh`,
and runs every script with `--help`.

## Conventions

- English in scripts, comments, config files and the README.
- One short imperative line per commit, no body, no `Co-Authored-By` or other attribution trailer.
- A new `system/` file needs a `sudo cp` line in `scripts/apply-system.sh` and a README entry;
  a new hardware branch needs a fixture in `tests/hw-detect.sh`; a new upstream download is
  pinned by version and SHA-256, or by commit.
- Scope: low-latency gaming, KDE and terminal rice, and the machine's security posture. Server
  administration and programming runtimes stay out; security tooling is documented in the
  README, not installed.

## Repository settings (as of 2026-10-22)

Recorded here because they live only in GitHub's settings: the `protect-main` ruleset blocks
deletion and force pushes and requires the five CI checks (shellcheck, validate, packages,
gitleaks, trivy) with no bypass; secret scanning, push protection, Dependabot security updates,
CodeQL for Actions and private vulnerability reporting are on; merge commits, squash and
rebase are all allowed, and branches are deleted on merge.
