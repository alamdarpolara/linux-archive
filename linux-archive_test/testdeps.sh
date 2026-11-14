#!/bin/sh
# testdeps.sh - TEST-ONLY tools for the linux-archive test containers (not a
# deliverable).  Installs what the test-suite needs on top of install.sh:
# python3 (data generation, pty driver), expect (login-shell test), xorriso
# (ISO sample), rpmbuild (RPM sample), gcab (CAB sample), ps, sudo, useradd,
# cmp/diff - and creates the unprivileged user "tester" (uid 1000).
# Packages that a distribution does not have are reported and skipped; the
# suite then uses the committed fixture files or reports SKIP honestly.
# shellcheck disable=SC2154  # ID comes from sourced os-release
set -u
. /etc/os-release
fam=unknown
case " $ID ${ID_LIKE:-} " in
    *" alpine "*) fam=alpine ;; *" arch "*) fam=arch ;; *suse*) fam=suse ;;
    *" debian "*|*" ubuntu "*) fam=debian ;; *" fedora "*|*" rhel "*|*" centos "*) fam=rpm ;;
    *) ;;
esac
case $fam in
    debian) pk="python3 expect xorriso rpm gcab procps sudo diffutils inotify-tools passwd" ;;
    rpm)    pk="python3 expect xorriso rpm-build gcab procps-ng sudo diffutils inotify-tools shadow-utils util-linux which" ;;
    suse)   pk="python3 expect xorriso rpm-build gcab procps sudo diffutils inotify-tools shadow util-linux which" ;;
    arch)   pk="python expect libisoburn rpm-tools gcab procps-ng sudo diffutils inotify-tools shadow util-linux which" ;;
    alpine) pk="python3 expect xorriso rpm gcab procps sudo diffutils inotify-tools shadow util-linux-login" ;;
    *) echo "testdeps: unknown family"; exit 1 ;;
esac
inst() {
    case $fam in
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$1" >/dev/null 2>&1 ;;
        rpm) if command -v zypper >/dev/null 2>&1; then zypper -n -q install --no-recommends "$1" >/dev/null 2>&1
             else dnf -y -q --setopt=install_weak_deps=False install "$1" >/dev/null 2>&1; fi ;;
        suse) zypper -n -q install --no-recommends "$1" >/dev/null 2>&1 ;;
        arch) pacman -S --needed --noconfirm "$1" >/dev/null 2>&1 ;;
        alpine) apk add -q "$1" >/dev/null 2>&1 ;;
    esac
}
[ "$fam" = debian ] && apt-get update -qq >/dev/null 2>&1
for p in $pk; do
    if inst "$p"; then echo "testdeps: installed $p"; else echo "testdeps: NOT AVAILABLE: $p"; fi
done
if ! id tester >/dev/null 2>&1; then
    # uid 1000 is already taken by the "ubuntu" user in Ubuntu 24.04+ images
    uidopt="-u 1000"; getent passwd 1000 >/dev/null 2>&1 && uidopt=""
    if command -v useradd >/dev/null 2>&1; then useradd -m $uidopt -s /bin/bash tester
    else adduser -D $uidopt -s /bin/bash tester; fi
fi
# Alpine's adduser leaves the account locked ('!'), which blocks `su tester`.
if command -v passwd >/dev/null 2>&1; then passwd -d tester >/dev/null 2>&1 || true; fi
id tester
exit 0
