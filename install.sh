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
have() { command -v "$1" >/dev/null 2>&1; }

# first_line CMD...: first output line of a command (stderr included)
first_line() { "$@" 2>&1 </dev/null | head -n 1; }

# tool_ok TOOL: is the tool usable as linux-archive needs it?  BusyBox
# applets (Alpine) lack options linux-archive uses (cpio -D, flock -w,
# unzip -tq, xz compression ...), so the real implementations are required.
tool_ok() {
    case $1 in
        7z) have 7zz || have 7z || have 7za ;;
        gnutar) have tar && case $(first_line tar --version) in *"GNU tar"*) true ;; *) false ;; esac ;;
        grep) have grep && case $(first_line grep --version) in *GNU*) true ;; *) false ;; esac ;;
        # BusyBox answers "gzip: unrecognized option" - GNU gzip prints "gzip 1.x".
        gzip) have gzip && gzip --version >/dev/null 2>&1 && case $(first_line gzip --version) in "gzip "[0-9]*) true ;; *) false ;; esac ;;
        cpio) have cpio && case $(first_line cpio --version) in *"GNU cpio"*) true ;; *) false ;; esac ;;
        bzip2) have bzip2 && case $(first_line bzip2 --help) in *"block-sorting"*) true ;; *) false ;; esac ;;
        unzip) have unzip && case $(first_line unzip -v) in UnZip*) true ;; *) false ;; esac ;;
        xz) have xz && case $(first_line xz --version) in *"XZ Utils"*) true ;; *) false ;; esac ;;
        gnucoreutils) have realpath && realpath -m -- /x/../y >/dev/null 2>&1 \
                      && mv --help 2>&1 | grep -q -- '--no-target-directory' \
                      && have timeout && have sha256sum && stat -c %s -- / >/dev/null 2>&1 ;;
        gnufind) have find && find / -maxdepth 0 -printf '' >/dev/null 2>&1 ;;
        setsid) have setsid ;;
        flock) have flock && case $(first_line flock --version) in *util-linux*) true ;; *) false ;; esac ;;
        mksquashfs) have mksquashfs && have unsquashfs ;;
        *) have "$1" ;;
    esac
}

# Harmless invocation proving the tool really runs (after installation).
tool_runs() {
    case $1 in
        7z) for b in 7zz 7z 7za; do if have "$b"; then "$b" i >/dev/null 2>&1 && return 0; fi; done; return 1 ;;
        bash) bash -c 'exit $(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ? 0 : 1 ))' ;;
        zip) zip -v >/dev/null 2>&1 ;;
        unzip) unzip -v >/dev/null 2>&1 ;;
        gnutar) tar --version >/dev/null 2>&1 ;;
        gzip|xz|zstd|cpio|file|bsdtar|dpkg-deb|ar|grep|flock) "$1" --version >/dev/null 2>&1 ;;
        bzip2) bzip2 --help >/dev/null 2>&1 ;;
        lz4) lz4 -V >/dev/null 2>&1 ;;
        mksquashfs) mksquashfs -version >/dev/null 2>&1 ;;
        cabextract) cabextract --version >/dev/null 2>&1 ;;
        rpm2cpio) [ -x "$(command -v rpm2cpio)" ] ;;
        setsid) setsid true >/dev/null 2>&1 ;;
        tput) tput -V >/dev/null 2>&1 ;;
        gnucoreutils|gnufind) tool_ok "$1" ;;
        *) tool_ok "$1" ;;
    esac
}

REQUIRED_TOOLS="bash gnutar gnucoreutils gnufind grep setsid flock tput file 7z zip unzip gzip bzip2 xz zstd lz4 mksquashfs cabextract rpm2cpio cpio ar dpkg-deb bsdtar"

# pkgs_for TOOL: candidate packages, best first ("a+b" = install both).
# Package names were verified with each distribution's package manager.
pkgs_for() {
    case $FAMILY:$1 in
        *:bash) echo bash ;;
        *:gnutar) echo tar ;;
        alpine:gnucoreutils|*:gnucoreutils) echo coreutils ;;
        *:gnufind) echo findutils ;;
        *:grep) echo grep ;;
        alpine:flock) echo flock ;;
        alpine:setsid) echo util-linux-misc ;;
        *:setsid|*:flock) echo util-linux ;;
        debian:tput) echo ncurses-bin ;;
        suse:tput) echo ncurses-utils ;;
        *:tput) echo ncurses ;;
        *:file) echo file ;;
        debian:7z) echo 7zip p7zip-full ;;
        el:7z) echo 7zip p7zip+p7zip-plugins ;;
        fedora:7z) echo 7zip p7zip+p7zip-plugins ;;
        suse:7z) echo 7zip p7zip-full ;;
        *:7z) echo 7zip ;;
        *:zip) echo zip ;;
        *:unzip) echo unzip ;;
        *:gzip) echo gzip ;;
        *:bzip2) echo bzip2 ;;
        debian:xz) echo xz-utils ;;
        *:xz) echo xz ;;
        *:zstd) echo zstd ;;
        *:lz4) echo lz4 ;;
        suse:mksquashfs) echo squashfs ;;
        *:mksquashfs) echo squashfs-tools ;;
        *:cabextract) echo cabextract ;;
        debian:rpm2cpio) echo rpm2cpio rpm ;;
        alpine:rpm2cpio) echo rpm2cpio ;;
        arch:rpm2cpio) echo rpm-tools ;;
        *:rpm2cpio) echo rpm ;;
        *:cpio) echo cpio ;;
        *:ar) echo binutils ;;
        *:dpkg-deb) echo dpkg ;;
        debian:bsdtar|alpine:bsdtar) echo libarchive-tools ;;
        arch:bsdtar) echo libarchive ;;
        *:bsdtar) echo bsdtar ;;
        *) echo "" ;;
    esac
}

# ----------------------------------------------------- package manager glue
LOG=$(mktemp "${TMPDIR:-/tmp}/linux-archive-install.XXXXXX") || { err "cannot create a temp file"; exit 1; }
trap 'rm -f -- "$LOG"' EXIT
trap 'rm -f -- "$LOG"; exit 130' INT
trap 'rm -f -- "$LOG"; exit 143' TERM

pkg_installed() {
    case $PM in
        apt) [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ] ;;
        dnf|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

pkg_available() {
    case $PM in
        apt) pa_c=$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: //p' | head -n 1)
             [ -n "$pa_c" ] && [ "$pa_c" != "(none)" ] ;;
        dnf) [ -n "$(dnf -q repoquery --qf '%{name}\n' "$1" 2>/dev/null | head -n 1)" ] ;;
        zypper) zypper -n -q search -x -t package -- "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        apk) [ -n "$(apk search -e "$1" 2>/dev/null | head -n 1)" ] ;;
        *) return 1 ;;
    esac
}

# Wait (up to LOCK_TIMEOUT s) while another package manager run holds its lock.
# apt and apk wait by themselves (apt -o DPkg::Lock::Timeout=N, apk --wait N;
# their locks are fcntl locks that flock(1) cannot see); pacman, zypper and
# dnf are checked through their lock / pid files.
wait_for_pm_lock() {
    [ "$DRY" -eq 1 ] && return 0
    [ "$(id -u)" -eq 0 ] || return 0
    wl_t=0
    while :; do
        wl_busy=""
        case $PM in
            pacman) [ -e /var/lib/pacman/db.lck ] && wl_busy=/var/lib/pacman/db.lck ;;
            zypper) [ -s /run/zypp.pid ] && kill -0 "$(cat /run/zypp.pid 2>/dev/null)" 2>/dev/null && wl_busy=/run/zypp.pid ;;
            dnf) for f in /var/cache/dnf/*.pid /var/lib/dnf/rpmdb_lock.pid /run/dnf/*.pid; do
                     [ -s "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null && wl_busy=$f
                 done ;;
            *) ;;
        esac
        [ -z "$wl_busy" ] && return 0
        if [ "$wl_t" -ge "$LOCK_TIMEOUT" ]; then
            err "The package manager is still busy after ${LOCK_TIMEOUT}s (lock: $wl_busy)."
            return 1
        fi
        [ "$wl_t" -eq 0 ] && info "Waiting for another package manager run to finish ($wl_busy)..."
        sleep 5
        wl_t=$((wl_t + 5))
    done
}

UPDATED=0
pm_refresh() {
    [ "$UPDATED" -eq 1 ] && return 0
    UPDATED=1
    [ "$DO_UPDATE" -eq 1 ] || return 0
    wait_for_pm_lock || exit 6
    info "Refreshing the package metadata..."
    case $PM in
        apt) run apt-get -o DPkg::Lock::Timeout="$LOCK_TIMEOUT" update -qq || warn "apt-get update failed - continuing with the existing package lists." ;;
        dnf) run dnf -q -y makecache >/dev/null || warn "dnf makecache failed - continuing." ;;
        zypper) ZYPP_LOCK_TIMEOUT=$LOCK_TIMEOUT run zypper -n -q refresh || warn "zypper refresh failed - continuing." ;;
        pacman) if [ ! -s /var/lib/pacman/sync/core.db ]; then
                    # Fresh system without sync databases: Arch supports only full
                    # upgrades (-Syu), never partial ones (-Sy pkg) - wiki "Partial upgrades".
                    run pacman -Syu --noconfirm || warn "pacman -Syu failed."
                fi ;;
        apk) run apk --wait "$LOCK_TIMEOUT" update -q || warn "apk update failed - continuing." ;;
        *) ;;
    esac
}

# pm_install PKG...: install, retrying once after waiting for a lock.
pm_install() {
    wait_for_pm_lock || exit 6
    case $PM in
        apt) DEBIAN_FRONTEND=noninteractive run apt-get -o DPkg::Lock::Timeout="$LOCK_TIMEOUT" install -y --no-install-recommends "$@" ;;
        dnf) run dnf -y --setopt=install_weak_deps=False install "$@" ;;
        zypper) ZYPP_LOCK_TIMEOUT=$LOCK_TIMEOUT run zypper -n install --no-recommends "$@" ;;
        pacman) run pacman -S --needed --noconfirm "$@" ;;
        apk) run apk --wait "$LOCK_TIMEOUT" add "$@" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------- EPEL (RHEL family)
EPEL_STATE="not needed"
epel_enabled() { dnf -q repolist --enabled 2>/dev/null | grep -qi '^epel[[:space:]]'; }
ensure_epel() {
    [ "$FAMILY" = el ] || return 0
    if epel_enabled; then EPEL_STATE="already enabled"; return 0; fi
    if [ "$EPEL" = ask ]; then
        if [ -t 0 ]; then
            say ""
            say "${C_B}EPEL${C_RST}: 7-Zip, cabextract and dpkg are not in the base repositories of"
            say "  $OS_NAME.  They come from EPEL (Extra Packages for Enterprise Linux, free"
            say "  software by the Fedora Project, GPG-signed).  Enabling EPEL also enables the"
            say "  distribution's CRB/PowerTools repository, as the EPEL documentation requires."
            printf 'Enable EPEL now? [y/N] '
            read -r ee_ans || ee_ans=""
            case $ee_ans in [yY]*) EPEL=yes ;; *) EPEL=no ;; esac
        else
            EPEL=no
        fi
    fi
    if [ "$EPEL" != yes ]; then
        EPEL_STATE="not enabled (re-run with --with-epel for 7-Zip, cabextract, dpkg)"
        return 0
    fi
    pm_refresh
    # epel-release comes from the distribution's own signed "extras" repository.
    if ! pkg_installed epel-release; then
        pm_install epel-release dnf-plugins-core || { EPEL_STATE="FAILED to install epel-release"; return 1; }
        record_new epel-release
    fi
    case $EL_MAJOR in
        8) run dnf config-manager --set-enabled powertools >/dev/null 2>&1 || run dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 || warn "could not enable PowerTools" ;;
        *) run dnf config-manager --set-enabled crb >/dev/null 2>&1 || warn "could not enable CRB" ;;
    esac
    run dnf -q -y makecache >/dev/null 2>&1 || true
    EPEL_STATE="enabled (with CRB/PowerTools)"
}

# ------------------------------------------------------ install required set
NEW_PKGS=""          # packages this run installed (recorded for uninstall)
record_new() { case " $NEW_PKGS " in *" $1 "*) ;; *) NEW_PKGS="$NEW_PKGS $1" ;; esac; }

TO_INSTALL="" STATUS_LINES=""
add_status() {   # add_status TOOL PACKAGE STATUS
    STATUS_LINES="$STATUS_LINES$(printf '%s|%s|%s' "$1" "$2" "$3")
"
}

ensure_epel || true
