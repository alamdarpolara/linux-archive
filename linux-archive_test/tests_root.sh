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

t_section "setup.sh - install"
out=$(bash "$SETUP" --yes 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
if (( rc == 0 )); then t_ok "setup.sh install exits 0"; else t_bad "setup.sh install" "rc=$rc"; fi
if command -v script >/dev/null && command -v timeout >/dev/null; then
    out=$(timeout -k 3 35 script -q -e -c "bash '$SETUP'" /dev/null 2>&1); rc=$?
    if (( rc == 0 )) && grep -q 'Manifest written' <<<"$out" && bash "$SETUP" --verify >/dev/null 2>&1; then
        t_ok 'setup.sh on a real pseudo-terminal completes without hanging; manifest verifies'
    else t_bad 'setup.sh pseudo-terminal run' "rc=$rc $(tail -n 5 <<<"$out" | tr '\n' '|')"; fi
else t_skip 'setup.sh pseudo-terminal run' 'script/timeout missing'; fi
check "script installed as /opt/linux-archive/linux-archive.sh" "" test -f /opt/linux-archive/linux-archive.sh
check "installed copy == source except the interpreter line" "" bash -c "cmp -s <(tail -n +2 '$LA') <(tail -n +2 /opt/linux-archive/linux-archive.sh)"
ishb=$(head -n 1 /opt/linux-archive/linux-archive.sh)
if [[ $ishb == '#!/bin/bash' || $ishb == '#!/usr/bin/bash' ]]; then t_ok "installed copy uses an absolute interpreter, not '/usr/bin/env bash'" "$ishb"; else t_bad "installed copy uses an absolute interpreter, not '/usr/bin/env bash'" "$ishb"; fi
chk() { [[ $(stat -c '%U:%G %a' "$1") == "$2" ]]; }
check "/opt/linux-archive is root:root 755" "$(stat -c '%U:%G %a' /opt/linux-archive)" chk /opt/linux-archive "root:root 755"
check "/opt/linux-archive/linux-archive.sh is root:root 755" "$(stat -c '%U:%G %a' /opt/linux-archive/linux-archive.sh)" chk /opt/linux-archive/linux-archive.sh "root:root 755"
check "no group/other write permission on the dir or the script" "" bash -c '[[ -z $(find /opt/linux-archive -perm /022) ]]'
check "symlink /usr/local/bin/linux-archive -> /opt/linux-archive/linux-archive.sh" "" bash -c '[[ $(readlink /usr/local/bin/linux-archive) == /opt/linux-archive/linux-archive.sh ]]'
check "symlink /usr/local/bin/larc -> /opt/linux-archive/linux-archive.sh" "" bash -c '[[ $(readlink /usr/local/bin/larc) == /opt/linux-archive/linux-archive.sh ]]'
check "manifest records owned larc" "" grep -q $'^larc\t/usr/local/bin/larc\t/opt/linux-archive/linux-archive.sh\towned' /var/lib/linux-archive/manifest
check "$RC has exactly one BEGIN and one END marker" "" bash -c "[[ \$(grep -c '^# BEGIN linux-archive' $RC) == 1 && \$(grep -c '^# END linux-archive' $RC) == 1 ]]"
check "alias line present in $RC" "" grep -qx "alias linux-archive='/opt/linux-archive/linux-archive.sh'" "$RC"
if (( RC_EXISTED )); then
    check "$RC keeps its owner and mode ($ORIG_MODE)" "$(stat -c '%a %U:%G' "$RC")" bash -c "[[ \$(stat -c '%a %U:%G' $RC) == '$ORIG_MODE' ]]"
fi
check "manifest written (root:root 644) with dir/file/symlink/bashrc entries" "" bash -c "[[ \$(stat -c '%U:%G %a' /var/lib/linux-archive/manifest) == 'root:root 644' ]] && grep -q \$'^file\t/opt/linux-archive/linux-archive.sh\t' /var/lib/linux-archive/manifest && grep -q \$'^symlink\t' /var/lib/linux-archive/manifest && grep -q \$'^bashrc\t$RC' /var/lib/linux-archive/manifest"
check "setup.sh --verify: OK right after install" "" bash "$SETUP" --verify
check "linux-archive --verify (as a normal user): OK" "" su tester -c "/usr/local/bin/linux-archive --verify"
check "larc --verify (as a normal user): OK" "" su tester -c "/usr/local/bin/larc --verify"
out=$(su tester -c '/usr/local/bin/larc --help'); rc=$?
if (( rc == 0 )) && grep -q '^Usage: larc ' <<<"$out"; then t_ok "larc help uses invoked name"; else t_bad "larc help" "rc=$rc $out"; fi
rm -f /usr/local/bin/larc
out=$(bash "$SETUP" --verify 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'larc' <<<"$out"; then t_ok "setup --verify detects missing larc"; else t_bad "larc missing verification" "rc=$rc $out"; fi
out=$(su tester -c '/usr/local/bin/linux-archive --verify' 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'larc' <<<"$out"; then t_ok "linux-archive --verify detects missing larc"; else t_bad "larc missing tool verification" "rc=$rc $out"; fi
bash "$SETUP" >/dev/null 2>&1
check "setup re-creates missing larc" "" test -L /usr/local/bin/larc
ln -sfn /tmp/foreign-alias /usr/local/bin/larc
out=$(bash "$SETUP" --verify 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'larc' <<<"$out"; then t_ok "setup --verify detects retargeted larc"; else t_bad "larc retarget verification" "rc=$rc $out"; fi
out=$(bash "$UNINST" --dry-run 2>&1)
if [[ -L /usr/local/bin/larc ]] && grep -q 'larc' <<<"$out"; then t_ok "uninstall does not silently claim a retargeted larc"; else t_bad "larc foreign symlink safety" "$out"; fi
rm -f /usr/local/bin/larc
bash "$SETUP" >/dev/null 2>&1

t_section "only root can modify; everybody can run"
as_tester 'echo x >> /opt/linux-archive/linux-archive.sh' 2>/dev/null; rc=$?
if (( rc != 0 )); then t_ok "normal user cannot append to the installed script"; else t_bad "tamper" "write succeeded"; fi
as_tester 'touch /opt/linux-archive/evil' 2>/dev/null; rc=$?
if (( rc != 0 )); then t_ok "normal user cannot create files in /opt/linux-archive"; else t_bad "tamper dir" "write succeeded"; fi
as_tester 'rm -f /opt/linux-archive/linux-archive.sh' 2>/dev/null; rc=$?
if (( rc != 0 )) && [[ -f /opt/linux-archive/linux-archive.sh ]]; then t_ok "normal user cannot delete the script"; else t_bad "tamper delete" ""; fi
as_tester "ln -sfn /tmp/x /usr/local/bin/linux-archive" 2>/dev/null; rc=$?
if (( rc != 0 )); then t_ok "normal user cannot replace the /usr/local/bin symlink"; else t_bad "symlink tamper" ""; fi
check "normal user can execute it" "" bash -c "su tester -c '/usr/local/bin/linux-archive --version' | grep -q '^linux-archive '"
# setpriv (util-linux) switches uid/gid directly - Arch's "nobody" account is
# expired, so `su nobody` is refused there by PAM regardless of linux-archive.
# (BusyBox setpriv on Alpine has no --reuid: fall back to su there.)
if id nobody >/dev/null 2>&1; then
    if setpriv --help 2>&1 | grep -q -- '--reuid'; then
        check "other users (nobody) can execute it too" "" bash -c "cd / && setpriv --reuid=\$(id -u nobody) --regid=\$(id -g nobody) --clear-groups /opt/linux-archive/linux-archive.sh --version | grep -q '^linux-archive '"
    else
        check "other users (nobody) can execute it too" "" bash -c "cd / && su -s /bin/sh nobody -c '/opt/linux-archive/linux-archive.sh --version' | grep -q '^linux-archive '"
    fi
fi

t_section "setup.sh - idempotent re-run, tamper detection"
h1=$(sha256sum < "$RC"); m1=$(grep -v '^#' /var/lib/linux-archive/manifest)
out=$(bash "$SETUP" 2>&1); rc=$?
h2=$(sha256sum < "$RC"); m2=$(grep -v '^#' /var/lib/linux-archive/manifest)
if (( rc == 0 )) && [[ $h1 == "$h2" && $m1 == "$m2" ]]; then t_ok "second run: exit 0, $RC byte-identical (no duplicate block), same manifest"; else t_bad "idempotent re-run" "rc=$rc"; fi
bash "$SETUP" >/dev/null 2>&1; bash "$SETUP" >/dev/null 2>&1
check "after 4 runs there is still exactly one block" "" bash -c "[[ \$(grep -c '^# BEGIN linux-archive' $RC) == 1 ]]"
echo '# my own later line' >> "$RC"
bash "$SETUP" >/dev/null 2>&1
check "unrelated content added after the block survives a re-run" "" grep -qx '# my own later line' "$RC"
sed -i '/^# my own later line$/d' "$RC"
echo "echo tampered" >> /opt/linux-archive/linux-archive.sh
out=$(bash "$SETUP" --verify 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'MODIFIED' <<<"$out"; then t_ok "setup.sh --verify detects a tampered script (non-zero exit)" "rc=$rc"; else t_bad "setup.sh --verify detects a tampered script (non-zero exit)" "rc=$rc $out"; fi
out=$(su tester -c '/usr/local/bin/linux-archive --verify' 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'CHANGED' <<<"$out"; then t_ok "linux-archive --verify detects it too (exit 1)" "rc=$rc"; else t_bad "linux-archive --verify detects it too (exit 1)" "rc=$rc $out"; fi
bash "$SETUP" >/dev/null 2>&1
check "re-run restores the modified script; --verify OK again" "" bash "$SETUP" --verify

t_section "locking: no concurrent setup/uninstall"
LOCKF=/run/linux-archive-setup.lock; [[ -d /run ]] || LOCKF=/var/lib/linux-archive-setup.lock
# The holder takes the lock, then signals readiness through a file and keeps
# the lock until the test releases it (no sleep-based timing; the loops below
# only wait for those signals, with generous safety limits).
rm -f -- "$W/lock.ready" "$W/lock.release"
( flock -x 8; : >"$W/lock.ready"
  for (( j = 0; j < 1200; j++ )); do [[ -e $W/lock.release ]] && break; sleep 0.1; done ) 8>>"$LOCKF" &
lpid=$!
for (( j = 0; j < 300; j++ )); do [[ -e $W/lock.ready ]] && break; sleep 0.1; done
if [[ -e $W/lock.ready ]]; then
    out=$(bash "$SETUP" 2>&1); rc1=$?
    out2=$(bash "$UNINST" --yes 2>&1); rc2=$?
else out="" out2="" rc1=-1 rc2=-1; fi
: >"$W/lock.release"
wait "$lpid"
if (( rc1 == 6 && rc2 == 6 )) && grep -q 'Another setup.sh' <<<"$out" && [[ -f /opt/linux-archive/linux-archive.sh ]]; then t_ok "while another run holds the lock: setup.sh and uninstall_setup.sh refuse at once (exit 6), nothing changed" "rc=$rc1/$rc2"; else t_bad "while another run holds the lock: setup.sh and uninstall_setup.sh refuse at once (exit 6), nothing changed" "lock holder ready: $([[ -e $W/lock.ready ]] && echo yes || echo NO); rc=$rc1/$rc2 $out $out2"; fi
( bash "$SETUP" >$W/s1 2>&1; echo $? >$W/s1.rc ) & ( bash "$SETUP" >$W/s2 2>&1; echo $? >$W/s2.rc ) & wait
r1=$(cat $W/s1.rc) r2=$(cat $W/s2.rc)
if { (( r1 == 0 && r2 == 6 )) || (( r1 == 6 && r2 == 0 )) || (( r1 == 0 && r2 == 0 )); } && [[ $(grep -c '^# BEGIN linux-archive' "$RC") == 1 ]] && bash "$SETUP" --verify >/dev/null 2>&1; then
    t_ok "two setup.sh started together: no corruption (one block, verify OK)" "exit codes $r1/$r2"
else t_bad "two setup.sh started together: no corruption (one block, verify OK)" "exit codes $r1/$r2"; fi

t_section "the command works: fresh interactive login shell, non-interactive shells, sudo"
cat > $W/login.exp <<EOF
set timeout 20
spawn su - tester
expect -re {[\$#] $}
send "type linux-archive\r"
expect "aliased to"
send "mkdir -p /tmp/rt/wd && cd /tmp/rt/wd && echo hi > f.txt\r"
expect -re {[\$#] $}
send "linux-archive --version\r"
expect "$VER"
send "linux-archive\r"
expect "Main menu"
expect "folder: /tmp/rt/wd"
send "q"
expect "Bye!"
expect -re {[\$#] $}
send "exit\r"
expect eof
EOF
if command -v expect >/dev/null; then
    out=$(expect $W/login.exp 2>&1); rc=$?
    if (( rc == 0 )) && grep -q 'aliased to' <<<"$out" && grep -q 'folder: /tmp/rt/wd' <<<"$out"; then t_ok "fresh interactive LOGIN shell: 'linux-archive' is an alias, starts, and shows the CURRENT folder"
    else
        # Some distributions' skeleton .bashrc does not read the system file in a login shell:
        if grep -q 'folder: /tmp/rt/wd' <<<"$out"; then t_ok "fresh interactive LOGIN shell: the command starts in the CURRENT folder (via /usr/local/bin; the alias is not loaded in login shells here)"
        else t_bad "login shell" "$(echo "$out" | tail -n 8 | tr '\n' '|')"; fi
    fi
else t_skip "login shell via expect" "expect not available"; fi
out=$(su tester -c 'linux-archive --version' 2>&1); [[ $out == "$VER" ]] && t_ok "non-interactive 'su user -c linux-archive' works (symlink in /usr/local/bin)" || t_bad "non-interactive via symlink" "$out"
out=$(su tester -c "sh -c 'cd /tmp && linux-archive --version'" 2>&1); [[ $out == "$VER" ]] && t_ok "'sh -c linux-archive' works" || t_bad "sh -c" "$out"
out=$(su tester -c "bash -c 'cd /tmp && linux-archive --version'" 2>&1); [[ $out == "$VER" ]] && t_ok "'bash -c linux-archive' in another directory works" || t_bad "bash -c" "$out"
if command -v sudo >/dev/null; then
    out=$(su tester -c 'sudo linux-archive --version' 2>&1)
    if [[ $out == "$VER" ]]; then t_ok "'sudo linux-archive' works (sudo ignores aliases; /usr/local/bin is in secure_path here)"
    else
        out2=$(su tester -c 'sudo /usr/local/bin/linux-archive --version' 2>&1)
        if [[ $out2 == "$VER" ]]; then t_ok "'sudo linux-archive' is not found (secure_path lacks /usr/local/bin on this distro) - 'sudo /usr/local/bin/linux-archive' works (documented)"
        else t_bad "sudo" "$out | $out2"; fi
    fi
fi
rm -f /usr/local/bin/linux-archive
out=$(su tester -c "bash -c 'linux-archive --version'" 2>&1); rc=$?
if (( rc != 0 )); then t_ok "WITHOUT the symlink a non-interactive shell cannot find linux-archive (so the symlink is required)"; else t_bad "symlink necessity" "rc=$rc $out"; fi
out=$(su tester -c "bash -i -c 'linux-archive --version'" 2>&1)
if [[ $out == *"$VER"* ]]; then t_ok "WITHOUT the symlink an interactive bash still works through the alias in $RC"
else t_skip "alias-only interactive shell" "a new user's interactive bash does not read $RC by default here (the symlink is the primary entry point)"; fi
bash "$SETUP" >/dev/null 2>&1
check "setup.sh re-creates the symlink" "" bash -c '[[ $(readlink /usr/local/bin/linux-archive) == /opt/linux-archive/linux-archive.sh ]]'
t_summary
exit $(( FAIL > 0 ))
