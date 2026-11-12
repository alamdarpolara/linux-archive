#!/usr/bin/env bash
# ShellCheck: clean with `shellcheck -S style -o all` except the optional,
# purely stylistic checks SC2250 (require-variable-braces), SC2312
# (check-extra-masked-returns: $(...) here only wraps commands whose output
# is validated) and SC2249 (add-default-case), disabled for the whole file.
# shellcheck disable=SC2250,SC2312,SC2249
#
# uninstall_setup.sh - remove everything setup.sh installed (root only).
#
#   sudo ./uninstall_setup.sh                 remove (asks for confirmation)
#   sudo ./uninstall_setup.sh --yes           remove without asking
#   sudo ./uninstall_setup.sh --dry-run       only show what would be removed
#   sudo ./uninstall_setup.sh --remove-deps   also remove the packages that
#                                             install.sh newly installed
#
# Safety rules
#   * Only what setup.sh recorded in /var/lib/linux-archive/manifest (or, for a
#     setup without manifest, the exact fixed paths it uses) is touched.
#   * There is no `rm -rf` anywhere: /opt/linux-archive is removed only when it
#     is a real, root-owned directory whose contents match the manifest
#     exactly (same file list, same SHA-256).  Otherwise nothing in it is
#     deleted, the differences are printed and the exit code is 1.
#   * The alias block is cut out of the bash configuration file atomically
#     (temp file + rename on the same filesystem); everything else in the file
#     stays byte-identical, and owner, mode and SELinux label are kept.  A
#     timestamped backup is written first and deleted once the result has
#     been verified (kept with --keep-backup, or automatically on failure).
#   * --remove-deps removes only packages listed in
#     /var/lib/linux-archive/installed-packages (written by install.sh), never
#     packages that were present before, never core packages, and never when
#     the package manager would also remove other packages.
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
readonly PKG_RECORD=$STATE_DIR/installed-packages
readonly BEGIN_MARK='# BEGIN linux-archive (managed by setup.sh - do not edit)'
readonly END_MARK='# END linux-archive'
readonly RC_CANDIDATES=(/etc/bash.bashrc /etc/bashrc /etc/bash/bashrc /etc/bash.bashrc.local)
# Never removed by --remove-deps, even if install.sh had installed them:
readonly PROTECTED_PKGS=" bash coreutils coreutils-single findutils grep tar gzip sed util-linux util-linux-core util-linux-misc ncurses ncurses-bin ncurses-utils file dpkg rpm binutils busybox "

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
plan() { printf '%s[dry-run]%s would %s\n' "$C_ACC" "$C_RST" "$*"; }

usage() {
    cat <<'USAGE'
uninstall_setup.sh - remove everything setup.sh installed (must be run as root)

  sudo ./uninstall_setup.sh [options]

  --dry-run        show what would be removed, change nothing
  --yes, -y        do not ask for confirmation
  --remove-deps    also remove the packages that install.sh newly installed
                   (only those; never packages that were already present)
  --keep-backup    keep the timestamped backup of the bash configuration file
  -h, --help       this text

Exit codes: 0 ok (or nothing to remove), 1 error / refused, 2 usage,
            3 not root, 5 immutable system, 6 busy (another setup/uninstall runs)
USAGE
}
