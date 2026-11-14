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
