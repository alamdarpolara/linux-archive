#!/usr/bin/env bash
# ShellCheck: clean with `shellcheck -S style -o all` except the optional,
# purely stylistic checks SC2250 (require-variable-braces), SC2312
# (check-extra-masked-returns: $(...) here only wraps commands whose output
# is validated) and SC2249 (add-default-case), disabled for the whole file.
# shellcheck disable=SC2250,SC2312,SC2249
#
# setup.sh - install linux-archive system-wide (root only).
#
#   sudo ./setup.sh               install or update (idempotent)
#   sudo ./setup.sh --yes         same, never ask
#   sudo ./setup.sh --verify      check the installation against its manifest
#   sudo ./setup.sh --uninstall   remove it again (runs ./uninstall_setup.sh)
#
# What it does
#   1. copies linux-archive.sh to /opt/linux-archive/linux-archive.sh
#      (root:root 0755, directory root:root 0755: only root can modify it,
#      every user can run it).  The installed copy gets an absolute
#      "#!/bin/bash" interpreter line, so the system-wide command never looks
#      bash up through the caller's PATH;
#   2. creates /usr/local/bin/linux-archive -> /opt/linux-archive/linux-archive.sh.
#      Also offers /usr/local/bin/larc when no other larc command or path exists.
#      This symlink is the PRIMARY entry point: bash does not expand aliases in
#      non-interactive shells (bash -c, ssh host cmd, scripts, cron) and
#      `sudo` ignores aliases, so only a command on PATH works everywhere;
#   3. adds a marked BEGIN/END alias block to the system-wide interactive bash
#      configuration of this distribution (secondary; re-runs never duplicate it):
#        Debian/Ubuntu/Arch: /etc/bash.bashrc     Fedora/RHEL clones: /etc/bashrc
#        openSUSE: /etc/bash.bashrc.local (bash.bashrc is replaced by updates)
#        Alpine: /etc/bash/bashrc
#   4. writes a manifest (/var/lib/linux-archive/manifest) of everything it
#      created, with SHA-256 sums.  uninstall_setup.sh removes only what the
#      manifest lists, and `--verify` detects tampering.
#
# The tool always works on the current directory of the terminal it is run in.
set -uo pipefail
