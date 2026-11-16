#!/usr/bin/env bash
#
# tests_root.sh - tests that need real root (not a deliverable): setup.sh,
# uninstall_setup.sh, locking, tamper detection, disk-full, collision safety,
# simulation (tmpfs), extraction as root (device nodes, setuid), missing tools.
# Run INSIDE a throw-away container (it edits /etc, /opt, /usr/local, /var/lib):
#   docker run --rm --cap-add SYS_ADMIN -v <repo>:/proj:ro la-test:<distro> bash /proj/linux-archive_test/tests_root.sh
# shellcheck disable=SC2154  # ID/PRETTY_NAME are sourced from os-release, FAIL from lib.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
P=$(dirname -- "$HERE")
LA=$P/linux-archive.sh
SETUP=$P/setup.sh
UNINST=$P/uninstall_setup.sh
export LC_ALL=C.UTF-8
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $EUID -eq 0 ]] || { echo "must run as root inside a container"; exit 2; }
id tester >/dev/null 2>&1 || { echo "user 'tester' missing (testdeps.sh)"; exit 2; }
mkdir -p /etc/sudoers.d; echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester; chmod 440 /etc/sudoers.d/tester
W=/tmp/rt; rm -rf $W; mkdir -p $W; chown tester $W
. /etc/os-release
echo "setup/root test run: $(date -u +%FT%TZ)  $PRETTY_NAME  bash $BASH_VERSION"

# The system-wide bash file setup.sh is expected to use on this distribution.
case " $ID ${ID_LIKE:-} " in
    *suse*) RC=/etc/bash.bashrc.local ;;
    *" fedora "*|*" rhel "*|*" centos "*) RC=/etc/bashrc ;;
    *" alpine "*) RC=/etc/bash/bashrc ;;
    *) RC=/etc/bash.bashrc ;;
esac
echo "expected system bash file: $RC"
RC_EXISTED=0; [[ -e $RC ]] && RC_EXISTED=1
[[ -e $RC ]] && cp -p "$RC" $W/rc.original
ORIG_HASH=$( [[ -e $RC ]] && sha256sum < "$RC" )
ORIG_MODE=$( [[ -e $RC ]] && stat -c '%a %U:%G' "$RC" )
as_tester() { su tester -c "$1"; }
VER=$(bash "$LA" --version)

# --------------------------------------------------------------- guards
t_section "setup.sh / uninstall_setup.sh - guards"
out=$(as_tester "bash $SETUP" 2>&1); rc=$?
if (( rc == 3 )) && grep -q 'must be run as root' <<<"$out"; then t_ok "setup.sh refuses to run without root (exit 3, clear message)"; else t_bad "setup.sh root guard" "rc=$rc $out"; fi
if [[ ! -e /opt/linux-archive && ! -e /usr/local/bin/linux-archive && ! -e /var/lib/linux-archive/manifest ]]; then t_ok "refusal changed nothing on the system"; else t_bad "refusal side effects" ""; fi
out=$(as_tester "bash $UNINST --yes </dev/null" 2>&1); rc=$?
if (( rc == 3 )); then t_ok "uninstall_setup.sh refuses without root and without a terminal for sudo (exit 3)"; else t_bad "uninstall root guard" "rc=$rc $out"; fi
bash "$SETUP" --bogus >/dev/null 2>&1; rc=$?
if (( rc == 2 )); then t_ok "setup.sh: unknown option -> exit 2"; else t_bad "setup unknown option" "rc=$rc"; fi
bash "$UNINST" --bogus >/dev/null 2>&1; rc=$?
if (( rc == 2 )); then t_ok "uninstall_setup.sh: unknown option -> exit 2"; else t_bad "uninstall unknown option" "rc=$rc"; fi
check "setup.sh --help works for everybody" "" bash -c "su tester -c 'bash $SETUP --help' | grep -q uninstall"
out=$(bash "$UNINST" --yes 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'Nothing to remove' <<<"$out"; then t_ok "uninstall on a clean system: exit 0, 'Nothing to remove'"; else t_bad "uninstall clean" "rc=$rc $out"; fi

# ------------------------------------------------- immutable-system refusal
t_section "immutable / declarative systems are refused (fake markers)"
cp -p /etc/os-release $W/os-release.real
printf 'ID=nixos\nNAME=NixOS\nPRETTY_NAME="NixOS (fake)"\n' > /etc/os-release
for s in "$SETUP" "$UNINST --yes"; do
    out=$(bash $s 2>&1); rc=$?
    if (( rc == 5 )) && grep -q 'NixOS' <<<"$out" && [[ ! -e /opt/linux-archive ]]; then t_ok "$(basename "${s%% *}") on NixOS (ID=nixos): refused, exit 5, nothing changed"; else t_bad "nixos refusal $(basename "${s%% *}")" "rc=$rc $out"; fi
done
cp -p $W/os-release.real /etc/os-release
mkdir -p /run; touch /run/ostree-booted
for s in "$SETUP" "$UNINST --yes"; do
    out=$(bash $s 2>&1); rc=$?
    if (( rc == 5 )) && grep -q 'ostree' <<<"$out" && [[ ! -e /opt/linux-archive ]]; then t_ok "$(basename "${s%% *}") with /run/ostree-booted: refused, exit 5"; else t_bad "ostree refusal $(basename "${s%% *}")" "rc=$rc $out"; fi
done
rm -f /run/ostree-booted

t_section "larc collision: foreign command must survive setup and uninstall"
printf '#!/bin/sh\nprintf "foreign alias\\n"\n' > /usr/local/bin/larc; chmod 755 /usr/local/bin/larc
foreign_sum=$(sha256sum < /usr/local/bin/larc)
out=$(bash "$SETUP" --yes 2>&1); rc=$?
if (( rc == 0 )) && [[ $(sha256sum < /usr/local/bin/larc) == "$foreign_sum" ]] && grep -q 'larc' <<<"$out" && grep -q $'^larc\t/usr/local/bin/larc\t.*\tcollision' /var/lib/linux-archive/manifest; then t_ok "setup warns and records collision without touching foreign larc"; else t_bad "larc collision install" "rc=$rc $out"; fi
out=$(bash "$SETUP" --verify 2>&1); rc=$?
if (( rc == 0 )) && grep -qi 'skipped' <<<"$out"; then t_ok "setup --verify reports foreign larc as skipped"; else t_bad "larc collision verify" "rc=$rc $out"; fi
out=$(bash "$UNINST" --yes 2>&1); rc=$?
if (( rc == 0 )) && [[ $(sha256sum < /usr/local/bin/larc) == "$foreign_sum" ]]; then t_ok "uninstall leaves foreign larc byte-identical"; else t_bad "larc collision uninstall" "rc=$rc $out"; fi
rm -f /usr/local/bin/larc

t_section "larc shadowed by an earlier PATH entry: reinstall records a collision, verify agrees"
MF=/var/lib/linux-archive/manifest
bash "$SETUP" --yes >/dev/null 2>&1
mkdir -p /usr/local/sbin
printf '#!/bin/sh\nprintf "shadowing larc\\n"\n' > /usr/local/sbin/larc; chmod 755 /usr/local/sbin/larc
shadow_sum=$(sha256sum < /usr/local/sbin/larc)
out=$(bash "$SETUP" --yes 2>&1); rc=$?
if (( rc == 0 )) && [[ $(sha256sum < /usr/local/sbin/larc) == "$shadow_sum" ]] && grep -q $'^larc\t/usr/local/bin/larc\t/opt/linux-archive/linux-archive.sh\tcollision\t/usr/local/sbin/larc' "$MF" && ! grep -q $'^larc\t.*\towned' "$MF"; then
    t_ok "shadowed owned larc: reinstall records a collision and leaves the shadowing command untouched" "rc=$rc"
else t_bad "shadowed owned larc: reinstall records a collision and leaves the shadowing command untouched" "rc=$rc $(grep '^larc' "$MF") $out"; fi
out=$(bash "$SETUP" --verify 2>&1); rc=$?
if (( rc == 0 )); then t_ok "shadowed owned larc: setup.sh --verify passes (collision skipped)" "rc=$rc"; else t_bad "shadowed owned larc: setup.sh --verify passes (collision skipped)" "rc=$rc $out"; fi
out=$(su tester -c '/usr/local/bin/linux-archive --verify' 2>&1); rc=$?
if (( rc == 0 )); then t_ok "shadowed owned larc: linux-archive --verify agrees with setup.sh --verify" "rc=$rc"; else t_bad "shadowed owned larc: linux-archive --verify agrees with setup.sh --verify" "rc=$rc $out"; fi
out=$(bash "$UNINST" --yes 2>&1); rc=$?
if (( rc == 0 )) && [[ $(sha256sum < /usr/local/sbin/larc) == "$shadow_sum" ]] && [[ ! -e /usr/local/bin/larc && ! -L /usr/local/bin/larc ]]; then
    t_ok "shadowed owned larc: uninstall leaves the shadowing command alone and no dead larc link behind" "rc=$rc"
else t_bad "shadowed owned larc: uninstall leaves the shadowing command alone and no dead larc link behind" "rc=$rc $out"; fi
rm -f /usr/local/sbin/larc

t_section "manifest completeness fails closed (verify) and blank digest / unrecorded link are never deleted (uninstall)"
bash "$SETUP" --yes >/dev/null 2>&1
cp -p "$MF" "$W/manifest.good"
restore_manifest() { cp -p "$W/manifest.good" "$MF"; }
for kind in file dir larc; do
    restore_manifest
    sed -i "/^$kind\t/d" "$MF"
    out=$(bash "$SETUP" --verify 2>&1); rc1=$?
    out2=$(su tester -c '/usr/local/bin/linux-archive --verify' 2>&1); rc2=$?
    if (( rc1 == 1 && rc2 == 1 )); then t_ok "manifest without its '$kind' record: both verify paths fail" "rc=$rc1/$rc2"
    else t_bad "manifest without its '$kind' record: both verify paths fail" "rc=$rc1/$rc2 $out | $out2"; fi
done
restore_manifest
sed -i -E 's#^(file\t[^\t]+)\t.*#\1#' "$MF"
out=$(bash "$SETUP" --verify 2>&1); rc1=$?
out2=$(su tester -c '/usr/local/bin/linux-archive --verify' 2>&1); rc2=$?
if (( rc1 == 1 && rc2 == 1 )); then t_ok "manifest file record without a digest: both verify paths fail" "rc=$rc1/$rc2"
else t_bad "manifest file record without a digest: both verify paths fail" "rc=$rc1/$rc2 $out | $out2"; fi
out=$(bash "$UNINST" --yes 2>&1); rc=$?
if (( rc != 0 )) && [[ -f /opt/linux-archive/linux-archive.sh ]]; then t_ok "uninstall refuses to delete the script when the manifest digest is blank" "rc=$rc"
else t_bad "uninstall refuses to delete the script when the manifest digest is blank" "rc=$rc script_exists=$([[ -f /opt/linux-archive/linux-archive.sh ]] && echo yes || echo NO) $out"; fi
bash "$SETUP" --yes >/dev/null 2>&1
cp -p "$MF" "$W/manifest.good"
sed -i '/^symlink\t/d' "$MF"
out=$(bash "$UNINST" --yes 2>&1); rc=$?
if [[ $(readlink /usr/local/bin/linux-archive 2>/dev/null) == /opt/linux-archive/linux-archive.sh ]]; then t_ok "uninstall removes the long-name link only when the manifest records it" "rc=$rc"
else t_bad "uninstall removes the long-name link only when the manifest records it" "rc=$rc link=$(readlink /usr/local/bin/linux-archive 2>&1) $out"; fi
# Clean up whatever is left (the unrecorded link, the restored installation).
rm -f /usr/local/bin/linux-archive
restore_manifest
bash "$SETUP" --yes >/dev/null 2>&1
bash "$UNINST" --yes >/dev/null 2>&1
rm -f /usr/local/bin/larc /usr/local/bin/linux-archive
t_summary
exit $(( FAIL > 0 ))
