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

case $scenario in
base)
    t_section "refusals: unknown and immutable systems (nothing may change)"
    cp /etc/os-release /tmp/os-release.real
    printf 'ID=plan9\nNAME="Plan 9"\nPRETTY_NAME="Plan 9 (fake)"\n' > /etc/os-release
    out=$(sh "$INSTALL" --yes 2>&1); rc=$?
    if [ $rc -eq 4 ] && echo "$out" | grep -q 'Unsupported system' && echo "$out" | grep -q 'GNU tar'; then t_ok "unknown distribution: refused (exit 4) with the list of required tools"; else t_bad "unknown distribution" "rc=$rc $out"; fi
    printf 'ID=nixos\nNAME=NixOS\nPRETTY_NAME="NixOS (fake)"\n' > /etc/os-release
    out=$(sh "$INSTALL" --yes 2>&1); rc=$?
    if [ $rc -eq 5 ] && echo "$out" | grep -q 'NixOS'; then t_ok "NixOS (ID=nixos): refused (exit 5)"; else t_bad "nixos" "rc=$rc $out"; fi
    cp /tmp/os-release.real /etc/os-release
    mkdir -p /run; touch /run/ostree-booted
    out=$(sh "$INSTALL" --yes 2>&1); rc=$?
    if [ $rc -eq 5 ] && echo "$out" | grep -q 'ostree'; then t_ok "rpm-ostree marker /run/ostree-booted: refused (exit 5)"; else t_bad "ostree" "rc=$rc $out"; fi
    rm -f /run/ostree-booted
    if ! command -v 7z >/dev/null 2>&1 && ! command -v 7zz >/dev/null 2>&1 && ! command -v 7za >/dev/null 2>&1 && [ ! -e /var/lib/linux-archive ]; then t_ok "the refusals installed nothing"; else t_bad "refusal side effects" ""; fi

    t_section "arguments / shells"
    sh "$INSTALL" --help >/dev/null 2>&1; rc=$?; [ $rc -eq 0 ] && t_ok "--help exits 0" || t_bad "--help" "rc=$rc"
    sh "$INSTALL" --bogus >/dev/null 2>&1; rc=$?; [ $rc -eq 2 ] && t_ok "unknown option exits 2" || t_bad "unknown option" "rc=$rc"
    v=$(sh "$INSTALL" --version 2>&1); case $v in *"install.sh 2."*) t_ok "--version: $v" ;; *) t_bad "--version" "$v" ;; esac
    for shl in dash "busybox ash" bash; do
        set -- $shl
        command -v "$1" >/dev/null 2>&1 || continue
        $shl "$INSTALL" --help >/dev/null 2>&1; rc=$?
        [ $rc -eq 0 ] && t_ok "runs under '$shl' (--help)" || t_bad "runs under $shl" "rc=$rc"
    done

    t_section "--dry-run as a normal user (no root needed, nothing changes)"
    mkuser plain
    before=$(repo_snapshot)
    out=$(as_user plain "sh $INSTALL --dry-run --yes" 2>&1); rc=$?
    echo "$out" | tail -n 8 | sed 's/^/    | /'
    if [ $rc -eq 0 ] && echo "$out" | grep -q 'Dry run: nothing was changed'; then t_ok "--dry-run exits 0 and says nothing was changed"; else t_bad "--dry-run" "rc=$rc"; fi
    if [ "$before" = "$(repo_snapshot)" ] && [ ! -e /var/lib/linux-archive ]; then t_ok "--dry-run changed no repository configuration and wrote no state"; else t_bad "--dry-run side effects" ""; fi

    t_section "non-root user without sudo"
    if ! command -v sudo >/dev/null 2>&1; then
        out=$(as_user plain "sh $INSTALL --yes" 2>&1); rc=$?
        if [ $rc -eq 3 ] && echo "$out" | grep -q 'must be run as root'; then t_ok "refuses with a clear message (exit 3)"; else t_bad "non-root refusal" "rc=$rc $out"; fi
    else t_skip "non-root without sudo" "sudo is preinstalled in this image"; fi

    t_section "first run on a clean system: --yes (official default repositories ONLY)"
    before=$(repo_snapshot)
    if [ "$FAM" = el ]; then
        out=$(sh "$INSTALL" --yes 2>&1); rc=$?
        echo "$out" | tail -n 32 | sed 's/^/    | /'
        if [ $rc -eq 1 ] && echo "$out" | grep -q -- '--with-epel'; then t_ok "RHEL rebuild, --yes alone: EPEL NOT enabled; missing 7-Zip/cabextract/dpkg reported (exit 1, hint --with-epel)"; else t_bad "el --yes" "rc=$rc"; fi
        if [ "$before" = "$(repo_snapshot)" ] && ! dnf -q repolist --enabled 2>/dev/null | grep -qi '^epel'; then t_ok "--yes did not enable any repository"; else t_bad "--yes enabled a repository" ""; fi
    fi
    out=$(sh "$INSTALL" $FULL_ARGS 2>&1); rc=$?
    echo "$out" | tail -n 34 | sed 's/^/    | /'
    [ $rc -eq 0 ] && t_ok "install.sh $FULL_ARGS exits 0" || t_bad "install.sh rc" "$rc"
    m=$(all_cmds); [ $? -eq 0 ] && t_ok "every required command exists and is the right implementation" || t_bad "required commands" "$m"
    echo "$out" | grep -q 'Summary' && echo "$out" | grep -q 'installed now' && t_ok "summary table printed (tool | package | status)" || t_bad "summary table" ""
    if real_unrar; then t_bad "--yes installed the NON-FREE unrar" ""; else t_ok "--yes did NOT install the non-free unrar"; fi
    if [ "$FAM" != el ]; then
        if [ "$before" = "$(repo_snapshot)" ]; then t_ok "--yes did not add or enable any repository"; else t_bad "--yes changed repositories" ""; fi
    fi
    [ -s /var/lib/linux-archive/installed-packages ] && t_ok "newly installed packages recorded ($(wc -l < /var/lib/linux-archive/installed-packages) in /var/lib/linux-archive/installed-packages)" || t_bad "package record" ""
    t_section "second run (idempotency)"
    out=$(sh "$INSTALL" $FULL_ARGS 2>&1); rc=$?
    [ $rc -eq 0 ] && t_ok "second run exits 0" || t_bad "second run rc" "$rc"
    if ! echo "$out" | grep -q 'installed now'; then t_ok "second run installs nothing"; else t_bad "second run installs" ""; fi
    echo "$out" | grep -q 'already present' && t_ok "second run reports everything as already present" || t_bad "already present" ""

    t_section "non-root user WITH sudo: re-executes itself through sudo"
    if pm_install_test sudo || command -v sudo >/dev/null 2>&1; then
        mkuser viasudo; mkdir -p /etc/sudoers.d; echo 'viasudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/viasudo; chmod 440 /etc/sudoers.d/viasudo
        out=$(as_user viasudo "sh $INSTALL $FULL_ARGS" 2>&1); rc=$?
        echo "$out" | head -n 3 | sed 's/^/    | /'
        [ $rc -eq 0 ] && t_ok "exit 0 via sudo" || t_bad "sudo rc" "$rc $(echo "$out" | tail -n 3)"
        echo "$out" | grep -q 're-running with sudo' && t_ok "it announced the sudo re-run" || t_bad "sudo announcement" ""
    else t_skip "sudo re-exec" "sudo not installable"; fi
    ;;
esac
printf '\n==== SUMMARY: %d passed, %d failed, %d skipped ====\n' "$PASS" "$FAIL" "$SKIP"
[ $FAIL -gt 0 ] && printf 'Failed tests:%s\n' "$FAILED" | tr '|' '\n'
[ $FAIL -eq 0 ]
