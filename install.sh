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

MISSING_TOOLS=""
for t in $REQUIRED_TOOLS; do
    if tool_ok "$t"; then add_status "$t" "-" "already present"
    else MISSING_TOOLS="$MISSING_TOOLS $t"; fi
done

if [ -n "$MISSING_TOOLS" ]; then
    pm_refresh
    for t in $MISSING_TOOLS; do
        chosen=""
        for cand in $(pkgs_for "$t"); do
            allok=1
            for p in $(printf '%s' "$cand" | tr '+' ' '); do
                pkg_installed "$p" && continue
                pkg_available "$p" || allok=0
            done
            if [ "$allok" -eq 1 ]; then chosen=$cand; break; fi
        done
        if [ -z "$chosen" ] && [ "$DRY" -eq 1 ]; then
            # --dry-run never refreshes the metadata, so "not found" may only mean "not refreshed".
            add_status "$t" "$(pkgs_for "$t" | cut -d' ' -f1)" "would be installed (if available)"
            continue
        fi
        if [ -z "$chosen" ]; then
            hint=""
            [ "$FAMILY" = el ] && [ "$EPEL_STATE" != "enabled (with CRB/PowerTools)" ] && [ "$EPEL_STATE" != "already enabled" ] && hint=" (needs EPEL: --with-epel)"
            add_status "$t" "$(pkgs_for "$t" | cut -d' ' -f1)" "UNAVAILABLE$hint"
            continue
        fi
        for p in $(printf '%s' "$chosen" | tr '+' ' '); do
            case " $TO_INSTALL " in *" $p "*) ;; *) TO_INSTALL="$TO_INSTALL $p" ;; esac
        done
        add_status "$t" "$chosen" "pending"
    done
fi

# Packages not installed yet (before the run) -> recorded after success.
BEFORE_MISSING=""
for p in $TO_INSTALL; do pkg_installed "$p" || BEFORE_MISSING="$BEFORE_MISSING $p"; done

PM_FAILED=0
if [ -n "$TO_INSTALL" ]; then
    info "Installing:$TO_INSTALL"
    # shellcheck disable=SC2086  # word splitting of the package list is intended
    if ! pm_install $TO_INSTALL; then
        warn "Bulk installation failed; retrying package by package..."
        for p in $TO_INSTALL; do pm_install "$p" >>"$LOG" 2>&1 || { warn "could not install $p"; PM_FAILED=1; }; done
    fi
fi
for p in $BEFORE_MISSING; do
    if [ "$DRY" -eq 1 ] || pkg_installed "$p"; then record_new "$p"; fi
done

# ------------------------------------------------------------------- RAR
# The real RAR extractor (unrar by RARLAB) has a NON-FREE licence.  Free
# alternatives: 7-Zip builds that include the RAR decoder (Arch), and unar
# (The Unarchiver; extracts RAR4/RAR5 but takes passwords only on argv, so
# linux-archive uses it for unencrypted RAR archives only).
RAR_RESULT=""
real_unrar() {
    for ru_c in unrar unrar-nonfree; do
        have "$ru_c" || continue
        "$ru_c" 2>&1 </dev/null | head -n 3 | grep -q 'UNRAR' && return 0
    done
    return 1
}
sevenzip_has_rar() {
    for sr_b in 7zz 7z 7za; do
        have "$sr_b" || continue
        "$sr_b" i 2>/dev/null | sed -n '/^Codecs:/,/^Hashers:/p' | grep -q ' Rar5$' && return 0
    done
    return 1
}

# Debian/Ubuntu: write a deb822 source for COMPONENT that copies URIs, Suites
# and Signed-By of the system's own entries for this release (apt refuses two
# entries for the same archive with different Signed-By values).
APT_ADDED=""
apt_add_component() {   # apt_add_component COMPONENT FILE
    aac_comp=$1 aac_file=$2
    if [ -z "$OS_CODENAME" ]; then warn "unknown release codename - cannot add the '$aac_comp' component."; return 1; fi
    aac_tmp=$(mktemp "${TMPDIR:-/tmp}/linux-archive-src.XXXXXX") || return 1
    {
        printf '# Added by linux-archive install.sh (component "%s" for the real unrar).\n' "$aac_comp"
        printf '# Remove this file and run "apt-get update" to undo.\n'
        for f in /etc/apt/sources.list.d/*.sources; do
            [ -r "$f" ] || continue
            awk -v code="$OS_CODENAME" -v comp="$aac_comp" '
                function flush() {
                    if (types ~ /(^| )deb( |$)/ && enabled != "no" && uris != "" && suites != "") {
                        n = split(suites, s, " "); keep = ""
                        for (i = 1; i <= n; i++) if (s[i] == code || index(s[i], code "-") == 1) keep = keep (keep == "" ? "" : " ") s[i]
                        if (keep != "") { printf "\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\n", uris, keep, comp
                                          if (sb != "") printf "Signed-By: %s\n", sb }
                    }
                    types = uris = suites = sb = enabled = ""; cur = ""
                }
                /^[ \t]*$/ { flush(); next }
                /^#/ { next }
                /^[ \t]/ { if (cur == "sb") sb = sb "\n" $0; next }
                { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[ \t]*/, "", v); cur = ""
                  if (k == "Types") types = v; else if (k == "URIs") uris = v; else if (k == "Suites") suites = v
                  else if (k == "Enabled") enabled = v; else if (k == "Signed-By") { sb = v; cur = "sb" } }
                END { flush() }' "$f"
        done
        if [ -r /etc/apt/sources.list ]; then
            awk -v code="$OS_CODENAME" -v comp="$aac_comp" '
                $1 == "deb" {
                    i = 2; sb = ""
                    if ($2 ~ /^\[/) { while (i <= NF) { o = $i; if (o ~ /^\[?signed-by=/) { sb = o; sub(/^\[?signed-by=/, "", sb); sub(/\]$/, "", sb) }
                                                         i++; if (o ~ /\]$/) break } }
                    uri = $i; suite = $(i + 1)
                    if (suite == code || index(suite, code "-") == 1) {
                        printf "\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\n", uri, suite, comp
                        if (sb != "") printf "Signed-By: %s\n", sb
                    }
                }' /etc/apt/sources.list
        fi
    } >"$aac_tmp"
    if ! grep -q '^URIs:' "$aac_tmp"; then
        rm -f -- "$aac_tmp"; warn "no apt entries for '$OS_CODENAME' found to extend."; return 1
    fi
    info "Adding $aac_file (component '$aac_comp' of the system's own mirrors)."
    if [ "$DRY" -eq 1 ]; then sed 's/^/    | /' "$aac_tmp"; rm -f -- "$aac_tmp"; return 0; fi
    if ! { chmod 0644 "$aac_tmp" && mv -f -- "$aac_tmp" "$aac_file"; }; then rm -f -- "$aac_tmp"; return 1; fi
    APT_ADDED=$aac_file
    if ! apt-get -o DPkg::Lock::Timeout="$LOCK_TIMEOUT" update -qq; then
        warn "apt rejected the added source - removing $aac_file again."
        rm -f -- "$aac_file"; APT_ADDED=""
        apt-get update -qq || true
        return 1
    fi
    return 0
}

# Fedora/RHEL: RPM Fusion (rpmfusion.org/Configuration).  Instead of the
# documented "--nogpgcheck", the release packages are verified with the RPM
# Fusion keys shipped in the distribution's own signed package
# distribution-gpg-keys (Fedora repo / EPEL).
rpmfusion_enable() {
    if rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then return 0; fi
    if [ "$FAMILY" = fedora ]; then rf_kind=fedora rf_ver=$(rpm -E %fedora); else rf_kind=el rf_ver=$(rpm -E %rhel); fi
    case $rf_ver in ''|*[!0-9]*) warn "cannot determine the release number for RPM Fusion."; return 1 ;; *) ;; esac
    pkg_installed distribution-gpg-keys || { pm_install distribution-gpg-keys || return 1; record_new distribution-gpg-keys; }
    for t in free nonfree; do
        rf_key=/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-$t-$rf_kind-$rf_ver
        if [ "$DRY" -eq 0 ] && [ ! -r "$rf_key" ]; then warn "missing $rf_key - refusing to add RPM Fusion without a verified key."; return 1; fi
        run rpmkeys --import "$rf_key" || return 1
    done
    run dnf -y --setopt=localpkg_gpgcheck=1 install \
        "https://mirrors.rpmfusion.org/free/$rf_kind/rpmfusion-free-release-$rf_ver.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/$rf_kind/rpmfusion-nonfree-release-$rf_ver.noarch.rpm" || return 1
    record_new rpmfusion-free-release; record_new rpmfusion-nonfree-release
    return 0
}

# openSUSE: the official non-oss repository (download.opensuse.org).  It is
# signed with the same openSUSE key as the main repository, so no new key is
# imported (zypper refuses an unknown key in non-interactive mode).
SN_ADDED="" SN_ENABLED=""
suse_enable_nonoss() {
    sn_alias=$(zypper -n -q lr -u 2>/dev/null | awk -F'|' 'tolower($0) ~ /non-oss/ && tolower($0) !~ /debug|source/ { gsub(/ /, "", $2); print $2; exit }')
    if [ -n "$sn_alias" ]; then
        run zypper -n modifyrepo --enable "$sn_alias" >/dev/null || return 1
        SN_ENABLED=$sn_alias
        run zypper -n -q refresh "$sn_alias"
        return $?
    fi
    case $OS_ID in
        opensuse-tumbleweed|opensuse-slowroll) sn_url=https://download.opensuse.org/tumbleweed/repo/non-oss/ ;;
        opensuse-leap) sn_url=https://download.opensuse.org/distribution/leap/$OS_VER/repo/non-oss/ ;;
        *) warn "unknown openSUSE flavour '$OS_ID' - cannot add the non-oss repository."; return 1 ;;
    esac
    run zypper -n addrepo --refresh "$sn_url" linux-archive-non-oss || return 1
    SN_ADDED=linux-archive-non-oss
    run zypper -n -q refresh linux-archive-non-oss
}

# Undo a just-added RPM Fusion when its repositories do not work: a broken
# repository makes every later dnf command fail (skip_if_unavailable=False).
rpmfusion_rollback() {
    case " $NEW_PKGS " in *" rpmfusion-nonfree-release "*) ;; *) return 0 ;; esac
    warn "RPM Fusion did not work here (mirror/metadata error) - removing it again so dnf keeps working."
    run rpm -e rpmfusion-nonfree-release rpmfusion-free-release >/dev/null 2>&1 || warn "could not remove the RPM Fusion release packages"
    rr_keep=""
    for rr_p in $NEW_PKGS; do
        case $rr_p in rpmfusion-nonfree-release|rpmfusion-free-release) ;; *) rr_keep="$rr_keep $rr_p" ;; esac
    done
    NEW_PKGS=$rr_keep
}

nonfree_install_unrar() {
    BEFORE_UNRAR=yes
    pkg_installed unrar || BEFORE_UNRAR=no
    case $FAMILY in
        debian)
            pm_refresh
            if ! pkg_available unrar; then
                if [ "$IS_UBUNTU" -eq 1 ]; then apt_add_component multiverse /etc/apt/sources.list.d/linux-archive-multiverse.sources || return 1
                else apt_add_component non-free /etc/apt/sources.list.d/linux-archive-nonfree.sources || return 1; fi
            fi ;;
        fedora|el) [ "$FAMILY" = el ] && { EPEL=yes; ensure_epel || return 1; }
                   rpmfusion_enable || { rpmfusion_rollback; return 1; }
                   if ! pkg_installed unrar || ! real_unrar; then
                       if ! pm_install unrar; then rpmfusion_rollback; return 1; fi
                   fi
                   if ! real_unrar; then
                       # e.g. RPM Fusion EL10 builds need an x86-64-v3 CPU (AlmaLinux v2 hosts).
                       warn "the installed 'unrar' does not run here: $(first_line unrar | cut -c1-100)"
                       case " $BEFORE_UNRAR " in *" no "*) run rpm -e unrar >/dev/null 2>&1 ;; *) ;; esac
                       rpmfusion_rollback
                       return 1
                   fi
                   record_new unrar
                   return 0 ;;
        suse) if ! pkg_available unrar; then
                  if ! suse_enable_nonoss; then
                      [ -n "$SN_ADDED" ] && run zypper -n removerepo "$SN_ADDED" >/dev/null 2>&1
                      [ -n "$SN_ENABLED" ] && run zypper -n modifyrepo --disable "$SN_ENABLED" >/dev/null 2>&1
                      warn "the openSUSE non-oss repository could not be used - reverted."
                      return 1
                  fi
              fi ;;
        arch) pm_refresh ;;
        alpine) warn "Alpine Linux does not package the non-free unrar."; return 1 ;;
        *) return 1 ;;
    esac
    pkg_installed unrar && return 0
    pm_install unrar || return 1
    record_new unrar
    return 0
}

# Free fallback: no extra package.  bsdtar (libarchive, installed above)
# reads unencrypted RAR4 archives, and RAR5 since libarchive 3.4.  An
# already installed unar / unrar-free is used by linux-archive as well.
free_rar_fallback() {
    if have unar && have lsar; then RAR_RESULT="unar (free; unencrypted RAR only)"; return 0; fi
    if have unrar-free; then RAR_RESULT="unrar-free (free; no encrypted RAR)"; return 0; fi
    if have bsdtar; then
        fr_v=$(first_line bsdtar --version | sed -n 's/.*libarchive \([0-9][0-9.]*\).*/\1/p')
        case $fr_v in
            3.[0-3].*|[0-2].*)
                # libarchive < 3.4 has no RAR5 reader (EL8): add the free unar if packaged.
                pm_refresh
                if pkg_available unar && pm_install unar; then
                    record_new unar
                    RAR_RESULT="unar installed (free; unencrypted RAR4/RAR5 - libarchive $fr_v has no RAR5)"
                else
                    RAR_RESULT="bsdtar (libarchive $fr_v): unencrypted RAR4 only - no RAR5, no encrypted RAR"
                fi ;;
            *) RAR_RESULT="bsdtar (libarchive ${fr_v:-?}): unencrypted RAR4/RAR5 - no encrypted RAR" ;;
        esac
        return 0
    fi
    RAR_RESULT="no RAR extractor available on this system"
    return 1
}

handle_rar() {
    if real_unrar; then RAR_RESULT="unrar (real RAR tool) already installed"; return 0; fi
    if sevenzip_has_rar; then RAR_RESULT="7-Zip includes the RAR decoder (RAR4/RAR5, encrypted RAR) - nothing else needed"; return 0; fi
    if [ "$NONFREE" = ask ]; then
        if [ -t 0 ]; then
            say ""
            say "${C_B}RAR support${C_RST}"
            say "  The real RAR extractor 'unrar' (RARLAB) is NON-FREE software."
            case $FAMILY in
                debian) if [ "$IS_UBUNTU" -eq 1 ]; then say "  It comes from Ubuntu's 'multiverse' component (added if not enabled yet)."
                        else say "  It comes from Debian's 'non-free' component (added if not enabled yet)."; fi ;;
                fedora|el) say "  It comes from the RPM Fusion 'nonfree' repository (it will be added)." ;;
                suse) say "  It comes from openSUSE's 'non-oss' repository (enabled if needed)." ;;
                arch) say "  It is in Arch's official [extra] repository." ;;
                alpine) say "  Alpine does not package it." ;;
                *) ;;
            esac
            say "  Without it, the free libarchive (bsdtar) extracts RAR archives, but NOT encrypted ones."
            printf 'Install the non-free unrar? [y/N] '
            read -r hr_ans || hr_ans=""
            case $hr_ans in [yY]*) NONFREE=yes ;; *) NONFREE=no ;; esac
        else
            NONFREE=no
        fi
    fi
    if [ "$NONFREE" = yes ]; then
        if nonfree_install_unrar; then RAR_RESULT="unrar (non-free) installed"; return 0; fi
        warn "The non-free unrar could not be installed - using the free fallback."
    else
        info "Non-free software is not installed (use --with-nonfree for the real unrar)."
    fi
    free_rar_fallback || true
}
handle_rar

# ---------------------------------------------------------- record + verify
if [ -n "$NEW_PKGS" ] && [ "$DRY" -eq 0 ]; then
    mkdir -p -- "$STATE_DIR" && chmod 0755 -- "$STATE_DIR"
    if [ -L "$PKG_RECORD" ] || [ -L "$STATE_DIR" ]; then
        warn "$PKG_RECORD is a symlink - not recording installed packages."
    else
        for p in $NEW_PKGS; do printf '%s\n' "$p"; done | cat -- - "$PKG_RECORD" 2>/dev/null | sort -u >"$PKG_RECORD.tmp" \
            && chmod 0644 "$PKG_RECORD.tmp" && mv -f -- "$PKG_RECORD.tmp" "$PKG_RECORD"
    fi
fi

say ""
say "${C_B}Summary${C_RST}  ($OS_NAME, $PM)"
printf '  %-14s %-26s %s\n' "TOOL" "PACKAGE" "STATUS"
FAILED=0
printf '%s' "$STATUS_LINES" | while IFS='|' read -r t p s; do
    [ -n "$t" ] || continue
    if [ "$s" = pending ]; then
        if [ "$DRY" -eq 1 ]; then s="would be installed"
        elif tool_ok "$t" && tool_runs "$t"; then s="installed now"
        else s="FAILED"; fi
    elif [ "$s" = "already present" ] && [ "$DRY" -eq 0 ] && ! tool_runs "$t"; then
        s="present but does NOT run"
    fi
    case $s in
        FAILED*|UNAVAILABLE*|*NOT*) col=$C_ERR ;;
        "installed now"|"would be installed") col=$C_OK ;;
        *) col=$C_ACC ;;
    esac
    printf '  %-14s %-26s %s%s%s\n' "$t" "$p" "$col" "$s" "$C_RST"
done
printf '  %-14s %-26s %s\n' "RAR" "-" "$RAR_RESULT"
[ "$FAMILY" = el ] && printf '  %-14s %-26s %s\n' "EPEL" "-" "$EPEL_STATE"
[ -n "$APT_ADDED" ] && info "Added apt source: $APT_ADDED (delete it + apt-get update to undo)."
say ""

if [ "$DRY" -eq 1 ]; then
    info "Dry run: nothing was changed."
    exit 0
fi
for t in $REQUIRED_TOOLS; do
    if ! tool_ok "$t" || ! tool_runs "$t"; then FAILED=1; err "required tool not usable: $t"; fi
done
[ "$PM_FAILED" -eq 1 ] && FAILED=1
if [ "$FAILED" -eq 1 ]; then
    err "Some required tools are missing - see the summary above."
    [ "$FAMILY" = el ] && [ "$EPEL" != yes ] && info "On $OS_NAME most of them come from EPEL:  sudo ./install.sh --with-epel"
    exit 1
fi
ok "All required tools are installed and working."
[ -n "$NEW_PKGS" ] && info "Recorded the packages installed by this run in $PKG_RECORD."
if [ "$WITH_SETUP" -eq 1 ]; then
    if [ -f "$SCRIPT_DIR/setup.sh" ]; then
        info "Running setup.sh ..."
        if [ "$ASSUME_YES" -eq 1 ]; then bash "$SCRIPT_DIR/setup.sh" --yes; else bash "$SCRIPT_DIR/setup.sh"; fi
        exit $?
    fi
    err "setup.sh not found next to install.sh"; exit 1
fi
say "Next step:  sudo ./setup.sh   (installs the 'linux-archive' command)"
exit 0
