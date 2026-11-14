#!/bin/sh
# test_install.sh <scenario> - runs INSIDE a clean, freshly started container of
# the distribution under test (as root, repo mounted read-only at /proj).
# Not a deliverable.  POSIX sh: it must run on a minimal image without bash.
#   base      unknown/immutable refusal, --help/--version/--bogus, --dry-run as
#             non-root, first run --yes (free, no extra repositories), second run
#             (idempotent), non-root without sudo, non-root with sudo
#   nonfree   --yes --with-nonfree (real unrar where the distribution allows it)
#   interactive  the RAR question through a pseudo-terminal (util-linux script)
# shellcheck disable=SC2154  # ID/PRETTY_NAME come from sourced os-release
set -u
INSTALL=/proj/install.sh
scenario=${1:-base}
PASS=0 FAIL=0 SKIP=0 FAILED=""
t_ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
t_bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED|$1"; printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
t_skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s  -- %s\n' "$1" "${2:-}"; }
t_section() { printf '\n==== %s ====\n' "$1"; }
. /etc/os-release
FAM=unknown
case " $ID ${ID_LIKE:-} " in
    *" alpine "*) FAM=alpine ;; *" arch "*) FAM=arch ;; *suse*) FAM=suse ;;
    *" debian "*|*" ubuntu "*) FAM=debian ;; *" fedora "*) if [ "$ID" = fedora ]; then FAM=fedora; else FAM=el; fi ;;
    *" rhel "*|*" centos "*) FAM=el ;;
esac
SH=$(readlink -f /bin/sh)
echo "install.sh scenario '$scenario' on $PRETTY_NAME (family $FAM, /bin/sh -> $SH)  $(date -u +%FT%TZ)"

all_cmds() {
    bad=""
    for c in bash zip unzip tar gzip bzip2 xz zstd lz4 mksquashfs unsquashfs cabextract rpm2cpio cpio ar dpkg-deb bsdtar file setsid flock tput realpath timeout sha256sum; do
        command -v "$c" >/dev/null 2>&1 || bad="$bad $c"
    done
    command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 || bad="$bad 7z"
    tar --version | head -n 1 | grep -q 'GNU tar' || bad="$bad gnutar"
    flock --version 2>&1 | grep -q util-linux || bad="$bad util-linux-flock"
    [ -z "$bad" ] || { echo "missing:$bad"; return 1; }
}
real_unrar() { unrar 2>&1 </dev/null | head -n 3 | grep -q UNRAR; }
pm_has() {
    case $FAM in
        debian) [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ] ;;
        arch) pacman -Qq "$1" >/dev/null 2>&1 ;;
        alpine) apk info -e "$1" >/dev/null 2>&1 ;;
        *) rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}
repo_snapshot() {   # fingerprint of the repository configuration
    case $FAM in
        debian) cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null | sha256sum ;;
        fedora|el) dnf -q repolist --enabled 2>/dev/null | sort | sha256sum ;;
        suse) cat /etc/zypp/repos.d/*.repo 2>/dev/null | sha256sum ;;   # `zypper lr` columns change after a refresh
        arch) sha256sum < /etc/pacman.conf ;;
        alpine) sha256sum < /etc/apk/repositories ;;
    esac
}
mkuser() {   # mkuser NAME
    if command -v useradd >/dev/null 2>&1; then useradd -m "$1" >/dev/null 2>&1
    else adduser -D "$1" >/dev/null 2>&1; fi
    passwd -d "$1" >/dev/null 2>&1 || true
}
as_user() {   # as_user USER COMMAND: run a shell command as USER (su, or sudo on Fedora's base image)
    if command -v su >/dev/null 2>&1; then su "$1" -c "$2"
    elif command -v sudo >/dev/null 2>&1; then sudo -u "$1" sh -c "$2"
    else echo "no su/sudo available"; return 127; fi
}
pm_install_test() {   # install a test helper package with the native manager
    case $FAM in
        debian) apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        fedora|el) dnf -y -q install "$@" >/dev/null 2>&1 ;;
        suse) zypper -n -q install "$@" >/dev/null 2>&1 ;;
        arch) pacman -S --needed --noconfirm "$@" >/dev/null 2>&1 ;;
        alpine) apk add -q "$@" >/dev/null 2>&1 ;;
    esac
}
# The install arguments that must give a COMPLETE installation here.
FULL_ARGS="--yes"
[ "$FAM" = el ] && FULL_ARGS="--yes --with-epel"
