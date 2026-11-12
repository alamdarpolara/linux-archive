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

# ------------------------------------------------- environment hardening
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
IFS=$' \t\n'
unset -v BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null
export -n SHELLOPTS BASHOPTS 2>/dev/null
umask 022
export LC_ALL=C

readonly INSTALL_DIR=/opt/linux-archive
readonly INSTALL_BIN=$INSTALL_DIR/linux-archive.sh
readonly LINK=/usr/local/bin/linux-archive
readonly LARC_LINK=/usr/local/bin/larc
readonly STATE_DIR=/var/lib/linux-archive
readonly MANIFEST=$STATE_DIR/manifest
readonly BEGIN_MARK='# BEGIN linux-archive (managed by setup.sh - do not edit)'
readonly END_MARK='# END linux-archive'

# ------------------------------------------------------------------ output
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    C_RST=$(tput sgr0) C_OK=$(tput setaf 2) C_WARN=$(tput setaf 3) C_ERR=$(tput setaf 1) C_ACC=$(tput setaf 6)
else
    C_RST="" C_OK="" C_WARN="" C_ERR="" C_ACC=""
fi
info() { printf '%s[i]%s %s\n' "$C_ACC" "$C_RST" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'USAGE'
setup.sh - install linux-archive system-wide (must be run as root)

  sudo ./setup.sh              install or update (safe to run repeatedly)
  sudo ./setup.sh --yes        never ask
  sudo ./setup.sh --verify     compare the installed files with the manifest
  sudo ./setup.sh --uninstall  remove everything (delegates to uninstall_setup.sh;
                               its options, e.g. --dry-run, are passed through)
  ./setup.sh --help            this text

Exit codes: 0 ok, 1 error, 2 usage, 3 not root, 5 immutable system, 6 busy (locked)
USAGE
}

# --------------------------------------------------------------- arguments
MODE=install ASSUME_YES=0
PASS_ARGS=()
for arg in "$@"; do
    if [[ $MODE == uninstall ]]; then PASS_ARGS+=("$arg"); continue; fi
    case $arg in
        --uninstall|-u) MODE=uninstall ;;
        --verify) MODE=verify ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown option: $arg"; usage; exit 2 ;;
    esac
done
