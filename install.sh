#!/bin/sh
# install.sh - install everything linux-archive needs, on any supported Linux
# distribution, with the distribution's own package manager.
#
# POSIX sh on purpose (runs under dash, busybox ash, bash): minimal systems
# such as Alpine have no bash yet - this script installs it.
# ShellCheck: clean with `shellcheck -s sh -S style -o all` except the optional,
# purely stylistic checks SC2250 (require-variable-braces), SC2312
# (check-extra-masked-returns: $(...) output is validated where used) and
# SC2249 (add-default-case), disabled for the whole file.
# shellcheck disable=SC2250,SC2312,SC2249
#
# Supported (tested in containers, see README):
#   Debian 12/13, Ubuntu 22.04/24.04/26.04 (+ derivatives via ID_LIKE)  apt
#   Fedora                                                              dnf
#   Rocky / AlmaLinux 8 and 9 (+ other RHEL rebuilds via ID_LIKE)       dnf (+EPEL)
#   openSUSE Leap / Tumbleweed                                          zypper
#   Arch Linux (+ derivatives via ID_LIKE)                              pacman
#   Alpine Linux                                                        apk
# Immutable systems (NixOS, rpm-ostree, transactional openSUSE, Ubuntu Core)
# are detected and refused.  Unknown systems are refused (no blind installs).
#
# Repositories: only the distribution's official ones.  An EXTRA repository
# (EPEL on RHEL rebuilds, a non-free/multiverse/non-oss component, RPM
# Fusion) is enabled ONLY with --with-epel / --with-nonfree or an explicit
# "yes" typed by the user.  --yes NEVER enables one.
#
# Exit codes: 0 ok | 1 some required tool is still missing | 2 usage
#             3 not root and no sudo | 4 unsupported system | 5 immutable system
#             6 package manager busy (lock) or failing
set -u

# ------------------------------------------------- environment hardening
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset -v ENV BASH_ENV CDPATH 2>/dev/null || true
LC_ALL=C
export LC_ALL
umask 022

LA_VERSION=2.0.0
STATE_DIR=/var/lib/linux-archive
PKG_RECORD=$STATE_DIR/installed-packages
LOCK_TIMEOUT=300

# ------------------------------------------------------------------ output
C_RST="" C_B="" C_OK="" C_WARN="" C_ERR="" C_ACC=""
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    case $ncolors in ''|*[!0-9]*) ncolors=0 ;; *) ;; esac
    if [ "$ncolors" -ge 8 ]; then
        C_RST=$(tput sgr0) C_B=$(tput bold) C_OK=$(tput setaf 2) C_WARN=$(tput setaf 3) C_ERR=$(tput setaf 1) C_ACC=$(tput setaf 6)
    fi
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$C_ACC" "$C_RST" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }

usage() {
    cat <<'USAGE'
install.sh - install the dependencies of linux-archive (auto-detects the distribution)

  sudo ./install.sh [options]

  -y, --yes         never ask; safe defaults; official default repositories ONLY
                    (free RAR fallback, no EPEL, no non-free component)
  --with-nonfree    enable the non-free source of the real "unrar" for this
                    distribution (Debian non-free, Ubuntu multiverse, RPM Fusion
                    nonfree, openSUSE non-oss; Arch: package from [extra])
  --no-nonfree      never install non-free software, never ask about it
  --with-epel       RHEL rebuilds: enable EPEL (+ CRB/PowerTools), needed for
                    7-Zip, cabextract and dpkg there (implied by --with-nonfree)
  --dry-run         only show what would be done (no root needed)
  --with-setup      run ./setup.sh after a successful installation
  --no-update       do not refresh the package metadata first
  -h, --help        this text

Exit codes: 0 ok, 1 required tool missing, 2 usage, 3 not root/no sudo,
            4 unsupported system, 5 immutable system, 6 package manager busy/failing
USAGE
}

# --------------------------------------------------------------- arguments
ASSUME_YES=0 NONFREE=ask EPEL=ask DRY=0 WITH_SETUP=0 DO_UPDATE=1
for arg in "$@"; do
    case $arg in
        -y|--yes) ASSUME_YES=1 ;;
        --with-nonfree) NONFREE=yes ;;
        --no-nonfree) NONFREE=no ;;
        --with-epel) EPEL=yes ;;
        --dry-run|-n) DRY=1 ;;
        --with-setup) WITH_SETUP=1 ;;
        --no-update) DO_UPDATE=0 ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "linux-archive install.sh $LA_VERSION"; exit 0 ;;
        *) err "unknown option: $arg"; usage >&2; exit 2 ;;
    esac
done
[ "$NONFREE" = yes ] && [ "$EPEL" = ask ] && EPEL=yes
# --yes alone: never ask, never enable extra repositories.
if [ "$ASSUME_YES" -eq 1 ]; then
    [ "$NONFREE" = ask ] && NONFREE=no
    [ "$EPEL" = ask ] && EPEL=no
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || { err "cannot locate the script directory"; exit 1; }

# ------------------------------------------------------------------- root
if [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        info "Root is required - re-running with sudo..."
        exec sudo -- sh "$SCRIPT_DIR/install.sh" "$@"
    fi
    err "This script must be run as root (sudo ./install.sh); sudo is not installed."
    exit 3
fi

# run <command...>: execute, or only print it in --dry-run mode
