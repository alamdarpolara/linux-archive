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
run() {
    if [ "$DRY" -eq 1 ]; then printf '%s[dry-run]%s %s\n' "$C_ACC" "$C_RST" "$*"; return 0; fi
    "$@"
}

# ------------------------------------------------------- system detection
osr() {   # osr KEY: value from /etc/os-release (parsed, never sourced)
    [ -r /etc/os-release ] || return 0
    sed -n "s/^$1=//p" /etc/os-release | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}
OS_ID=$(osr ID) OS_LIKE=$(osr ID_LIKE) OS_VER=$(osr VERSION_ID) OS_NAME=$(osr PRETTY_NAME)
OS_CODENAME=$(osr VERSION_CODENAME)
[ -z "$OS_CODENAME" ] && OS_CODENAME=$(osr UBUNTU_CODENAME)
OS_NAME=${OS_NAME:-unknown system}

root_is_readonly() {
    [ -r /proc/mounts ] || return 1
    awk '$2 == "/" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "ro") f = 1 } END { exit f ? 0 : 1 }' /proc/mounts
}

# Immutable / declarative systems: NixOS (ID=nixos), rpm-ostree / bootc images
# (/run/ostree-booted, see rpm-ostree docs), transactional openSUSE/SUSE
# (ID opensuse-microos/aeon/kalpa, sl-micro, or transactional-update + read-only /),
# Ubuntu Core (ID=ubuntu-core), or simply a read-only /usr.
immutable_reason() {
    case " $OS_ID $OS_LIKE " in *" nixos "*) echo "NixOS - add the tools to configuration.nix instead"; return 0 ;; *) ;; esac
    if [ -e /run/ostree-booted ]; then echo "an rpm-ostree/OSTree image-based system - use rpm-ostree or a toolbox container"; return 0; fi
    case $OS_ID in
        opensuse-microos|opensuse-aeon|opensuse-kalpa|sl-micro|suse-microos)
            echo "a transactional openSUSE/SUSE system - use transactional-update"; return 0 ;;
        ubuntu-core) echo "Ubuntu Core - snap based, read-only"; return 0 ;;
        *) ;;
    esac
    if command -v transactional-update >/dev/null 2>&1 && root_is_readonly; then
        echo "a transactional system with a read-only root - use transactional-update"; return 0
    fi
    if [ -d /usr ] && [ "$(id -u)" -eq 0 ] && [ ! -w /usr ]; then echo "a system whose /usr is read-only"; return 0; fi
    return 1
}
if reason=$(immutable_reason); then
    err "Refusing to install: $OS_NAME is $reason."
    err "Nothing was changed."
    exit 5
fi

FAMILY=unknown PM=""
case " $OS_ID $OS_LIKE " in
    *" alpine "*) FAMILY=alpine PM=apk ;;
    *" arch "*) FAMILY=arch PM=pacman ;;
    *suse*) FAMILY=suse PM=zypper ;;
    *" debian "*|*" ubuntu "*) FAMILY=debian PM=apt ;;
    *" fedora "*) if [ "$OS_ID" = fedora ]; then FAMILY=fedora; else FAMILY=el; fi; PM=dnf ;;
    *" rhel "*|*" centos "*) FAMILY=el PM=dnf ;;
    *) ;;
esac
case $OS_ID in rhel|rocky|almalinux|centos|ol|eurolinux|circle|navy) FAMILY=el PM=dnf ;; *) ;; esac
IS_UBUNTU=0
case " $OS_ID $OS_LIKE " in *" ubuntu "*) IS_UBUNTU=1 ;; *) ;; esac
EL_MAJOR=${OS_VER%%.*}

pm_binary_ok() {
    case $PM in
        apt) command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1 ;;
        dnf) command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1 ;;
        zypper) command -v zypper >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1 ;;
        pacman) command -v pacman >/dev/null 2>&1 ;;
        apk) command -v apk >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

REQUIRED_HELP="bash (>= 4.4), GNU tar, GNU coreutils, GNU findutils, util-linux (setsid, flock), ncurses (tput), file, 7-Zip, zip, unzip, gzip, bzip2, xz, zstd, lz4, squashfs-tools, cabextract, rpm2cpio, cpio, binutils (ar), dpkg (dpkg-deb), bsdtar (libarchive)"
if [ "$FAMILY" = unknown ] || ! pm_binary_ok; then
    err "Unsupported system: $OS_NAME (ID=$OS_ID, ID_LIKE=$OS_LIKE)."
    err "Nothing was installed.  Install these tools with your package manager:"
    err "  $REQUIRED_HELP"
    exit 4
fi
IN_CONTAINER=no
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then IN_CONTAINER=yes; fi
info "Detected: $OS_NAME  (family: $FAMILY, package manager: $PM, arch: $(uname -m), container: $IN_CONTAINER)"

# ------------------------------------------------------------ tool checks
