#!/usr/bin/env bash
# ShellCheck: clean with `shellcheck -S style -o all` except the optional,
# purely stylistic checks SC2250 (require-variable-braces), SC2312
# (check-extra-masked-returns: $(...) here only wraps commands whose output
# is validated) and SC2249 (add-default-case), disabled for the whole file.
# shellcheck disable=SC2250,SC2312,SC2249
#
# setup.sh - install linux-archive system-wide (root only).
#
#   sudo ./setup.sh               install or update (idempotent)
#   sudo ./setup.sh --yes         same, never ask
#   sudo ./setup.sh --verify      check the installation against its manifest
#   sudo ./setup.sh --uninstall   remove it again (runs ./uninstall_setup.sh)
#
# What it does
#   1. copies linux-archive.sh to /opt/linux-archive/linux-archive.sh
#      (root:root 0755, directory root:root 0755: only root can modify it,
#      every user can run it).  The installed copy gets an absolute
#      "#!/bin/bash" interpreter line, so the system-wide command never looks
#      bash up through the caller's PATH;
#   2. creates /usr/local/bin/linux-archive -> /opt/linux-archive/linux-archive.sh.
#      Also offers /usr/local/bin/larc when no other larc command or path exists.
#      This symlink is the PRIMARY entry point: bash does not expand aliases in
#      non-interactive shells (bash -c, ssh host cmd, scripts, cron) and
#      `sudo` ignores aliases, so only a command on PATH works everywhere;
#   3. adds a marked BEGIN/END alias block to the system-wide interactive bash
#      configuration of this distribution (secondary; re-runs never duplicate it):
#        Debian/Ubuntu/Arch: /etc/bash.bashrc     Fedora/RHEL clones: /etc/bashrc
#        openSUSE: /etc/bash.bashrc.local (bash.bashrc is replaced by updates)
#        Alpine: /etc/bash/bashrc
#   4. writes a manifest (/var/lib/linux-archive/manifest) of everything it
#      created, with SHA-256 sums.  uninstall_setup.sh removes only what the
#      manifest lists, and `--verify` detects tampering.
#
# The tool always works on the current directory of the terminal it is run in.
set -uo pipefail

# ------------------------------------------------- environment hardening
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
IFS=$' \t\n'
unset -v BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null
export -n SHELLOPTS BASHOPTS 2>/dev/null
umask 022
export LC_ALL=C

readonly INSTALL_DIR=/opt/linux-archive
readonly INSTALL_BIN=$INSTALL_DIR/linux-archive.sh
readonly LINK=/usr/local/bin/linux-archive
readonly LARC_LINK=/usr/local/bin/larc
readonly STATE_DIR=/var/lib/linux-archive
readonly MANIFEST=$STATE_DIR/manifest
readonly BEGIN_MARK='# BEGIN linux-archive (managed by setup.sh - do not edit)'
readonly END_MARK='# END linux-archive'

# ------------------------------------------------------------------ output
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    C_RST=$(tput sgr0) C_OK=$(tput setaf 2) C_WARN=$(tput setaf 3) C_ERR=$(tput setaf 1) C_ACC=$(tput setaf 6)
else
    C_RST="" C_OK="" C_WARN="" C_ERR="" C_ACC=""
fi
info() { printf '%s[i]%s %s\n' "$C_ACC" "$C_RST" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'USAGE'
setup.sh - install linux-archive system-wide (must be run as root)

  sudo ./setup.sh              install or update (safe to run repeatedly)
  sudo ./setup.sh --yes        never ask
  sudo ./setup.sh --verify     compare the installed files with the manifest
  sudo ./setup.sh --uninstall  remove everything (delegates to uninstall_setup.sh;
                               its options, e.g. --dry-run, are passed through)
  ./setup.sh --help            this text

Exit codes: 0 ok, 1 error, 2 usage, 3 not root, 5 immutable system, 6 busy (locked)
USAGE
}

# --------------------------------------------------------------- arguments
MODE=install ASSUME_YES=0
PASS_ARGS=()
for arg in "$@"; do
    if [[ $MODE == uninstall ]]; then PASS_ARGS+=("$arg"); continue; fi
    case $arg in
        --uninstall|-u) MODE=uninstall ;;
        --verify) MODE=verify ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown option: $arg"; usage; exit 2 ;;
    esac
done

SRC_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P) || die "cannot locate the source directory"

if [[ $MODE == uninstall ]]; then
    [[ -f $SRC_DIR/uninstall_setup.sh ]] || die "uninstall_setup.sh not found next to setup.sh ($SRC_DIR)."
    (( ASSUME_YES )) && PASS_ARGS+=(--yes)
    exec bash -- "$SRC_DIR/uninstall_setup.sh" "${PASS_ARGS[@]}"
fi

if [[ $EUID -ne 0 ]]; then
    err "setup.sh must be run as root (it writes to /opt, /usr/local/bin, /var/lib and /etc)."
    err "Run:  sudo ./setup.sh"
    exit 3
fi

# ------------------------------------------------------- system detection
osr() {   # osr KEY -> value from /etc/os-release (parsed, never sourced)
    local line v=""
    [[ -r /etc/os-release ]] || return 0
    while IFS= read -r line; do
        if [[ $line == "$1="* ]]; then v=${line#*=}; v=${v#[\"\']}; v=${v%[\"\']}; fi
    done </etc/os-release
    printf '%s' "$v"
}

root_is_readonly() {   # / mounted read-only according to /proc/mounts?
    local mnt opts
    [[ -r /proc/mounts ]] || return 1
    while read -r _ mnt _ opts _; do
        if [[ $mnt == / ]]; then [[ ,$opts, == *,ro,* ]] && return 0; fi
    done </proc/mounts
    return 1
}

# Immutable / declarative systems manage /usr and /opt themselves; writing
# there is either impossible or lost on the next update.  Detection:
#   NixOS: ID=nixos (os-release(5)); rpm-ostree/bootc (Silverblue, Kinoite,
#   CoreOS...): /run/ostree-booted (rpm-ostree docs, dnf PR #2053);
#   transactional openSUSE (MicroOS, Aeon, Kalpa, SLE Micro): ID
#   opensuse-microos/sl-micro, or transactional-update + read-only /;
#   Ubuntu Core: ID=ubuntu-core.
immutable_reason() {
    local id like
    id=$(osr ID) like=$(osr ID_LIKE)
    if [[ $id == nixos || " $like " == *" nixos "* ]]; then echo "NixOS (declarative: add the tools to configuration.nix)"; return 0; fi
    if [[ -e /run/ostree-booted ]]; then echo "an rpm-ostree/OSTree image-based system (use rpm-ostree / toolbox)"; return 0; fi
    case $id in
        opensuse-microos|opensuse-aeon|opensuse-kalpa|sl-micro|suse-microos)
            echo "a transactional openSUSE/SUSE system (use transactional-update)"; return 0 ;;
        ubuntu-core) echo "Ubuntu Core (snap-based, read-only)"; return 0 ;;
    esac
    if command -v transactional-update >/dev/null 2>&1 && root_is_readonly; then
        echo "a transactional system with a read-only root (use transactional-update)"; return 0
    fi
    if [[ -d /usr && ! -w /usr ]]; then echo "a system whose /usr is read-only"; return 0; fi
    return 1
}

if reason=$(immutable_reason); then
    err "Refusing to install: this is $reason."
    err "Nothing was changed.  linux-archive.sh itself still runs directly (./linux-archive.sh)."
    exit 5
fi

FAMILY=""
detect_family() {
    local id like
    id=$(osr ID) like=$(osr ID_LIKE)
    case " $id $like " in
        *" alpine "*) FAMILY=alpine ;;
        *" arch "*) FAMILY=arch ;;
        *suse*) FAMILY=suse ;;
        *" debian "*|*" ubuntu "*) FAMILY=debian ;;
        *" fedora "*|*" rhel "*|*" centos "*) FAMILY=fedora ;;
        *) FAMILY=unknown ;;
    esac
}
detect_family

# The system-wide interactive bash file for this family (verified per distro
# in the test containers: it is what a new user's interactive bash reads).
pick_bashrc() {
    case $FAMILY in
        suse) echo /etc/bash.bashrc.local ;;
        fedora) echo /etc/bashrc ;;
        alpine) echo /etc/bash/bashrc ;;
        *)
            if [[ -f /etc/bash.bashrc ]]; then echo /etc/bash.bashrc
            elif [[ -f /etc/bashrc ]]; then echo /etc/bashrc
            elif [[ -f /etc/bash/bashrc ]]; then echo /etc/bash/bashrc
            else echo /etc/bash.bashrc; fi ;;
    esac
}

# ---------------------------------------------------------------- locking
# One setup/uninstall at a time.  The lock file lives in /run (root-only,
# never world-writable, so it cannot be pre-created as a symlink by a user);
# flock(1) -n fails at once instead of waiting.
LOCK_FILE=""
take_lock() {
    local d
    for d in /run /var/lib; do
        if [[ -d $d && ! -L $d && $(stat -c '%u' -- "$d") == 0 && $(stat -c '%A' -- "$d") != ????????w? ]]; then
            LOCK_FILE=$d/linux-archive-setup.lock
            break
        fi
    done
    [[ -n $LOCK_FILE ]] || die "no safe directory for the lock file (/run or /var/lib)."
    command -v flock >/dev/null 2>&1 || die "flock (util-linux) is missing - run ./install.sh first."
    [[ -L $LOCK_FILE ]] && die "$LOCK_FILE is a symlink - refusing to use it."
    exec 9>>"$LOCK_FILE" || die "cannot open $LOCK_FILE"
    if ! flock -n 9; then
        err "Another setup.sh / uninstall_setup.sh is running (lock: $LOCK_FILE)."
        exit 6
    fi
}

# --------------------------------------------------------------- helpers
sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# Print a file without one marked block (exact line matches, no regexes).
strip_block() {   # strip_block <file> <begin> <end>
    local line skip=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$2" ]]; then skip=1; continue; fi
        if (( skip )); then [[ $line == "$3" ]] && skip=0; continue; fi
        printf '%s\n' "$line"
    done <"$1"
}

block_state() {   # block_state <file> <begin> <end> -> none | ok | broken
    local b e
    [[ -f $1 ]] || { echo none; return; }
    b=$(grep -cFx -- "$2" "$1")
    e=$(grep -cFx -- "$3" "$1")
    if (( b == 0 && e == 0 )); then echo none
    elif (( b == 1 && e == 1 )); then echo ok
    else echo broken; fi
}

# Replace <target> atomically with <new>, keeping owner, mode and SELinux label.
replace_file() {   # replace_file <new-file> <target>
    chmod --reference="$2" -- "$1" || return 1
    chown --reference="$2" -- "$1" || return 1
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled && command -v chcon >/dev/null 2>&1; then
        chcon --reference="$2" -- "$1" 2>/dev/null || true
    fi
    mv -f -- "$1" "$2"
}

# Every directory from / down to <path> must be root-owned and not writable
# by group/others - otherwise a local user could swap files under us.
check_parents() {   # check_parents <path>
    local p=$1 st perm
    while [[ -n $p && $p != / ]]; do
        p=$(dirname -- "$p")
        [[ -e $p ]] || continue
        st=$(stat -L -c '%u %A' -- "$p")
        perm=${st#* }
        if [[ ${st%% *} != 0 ]]; then die "$p is not owned by root - refusing to install below it."; fi
        if [[ $perm == ????????w? ]]; then die "$p is writable by everybody - refusing to install below it."; fi
        if [[ $perm == ?????w???? ]]; then die "$p is group-writable ($(stat -L -c '%G' -- "$p")) - refusing to install below it."; fi
    done
}

# ------------------------------------------------------------ alias block
add_alias_block() {   # add_alias_block <bashrc>
    local rc=$1 state tmp
    if [[ -L $rc ]]; then
        warn "$rc is a symlink - not editing it (the $LINK command still works everywhere)."
        RC_FILE=""
        return 0
    fi
    state=$(block_state "$rc" "$BEGIN_MARK" "$END_MARK")
    [[ $state == broken ]] && die "$rc has a damaged linux-archive block (unbalanced markers) - fix it by hand, then re-run."
    if [[ ! -f $rc ]]; then
        mkdir -p -- "$(dirname -- "$rc")"
        : >"$rc" && chmod 644 -- "$rc" && chown root:root -- "$rc"
        RC_CREATED=1
        info "Created $rc (sourced by the system-wide bash configuration)."
    fi
    tmp=$(mktemp "$rc.la-XXXXXX") || die "cannot create a temp file next to $rc"
    if [[ $state == ok ]]; then strip_block "$rc" "$BEGIN_MARK" "$END_MARK" >"$tmp"; else cat -- "$rc" >"$tmp"; fi
    if [[ -s $tmp && $(tail -c 1 -- "$tmp" | wc -l) -eq 0 ]]; then
        printf '\n' >>"$tmp"
        RC_ADDED_NL=1
    fi
    {
        printf '%s\n' "$BEGIN_MARK"
        printf "alias linux-archive='%s'\n" "$INSTALL_BIN"
        printf '%s\n' "$END_MARK"
    } >>"$tmp"
    if [[ $state == ok ]] && cmp -s -- "$tmp" "$rc"; then
        rm -f -- "$tmp"
        ok "Alias block in $rc is already up to date (no duplicate added)."
        return 0
    fi
    replace_file "$tmp" "$rc" || { rm -f -- "$tmp"; die "could not update $rc"; }
    if [[ $state == ok ]]; then ok "Alias block in $rc refreshed (no duplicate added)."
    else ok "Alias block added to $rc."; fi
}

# Does a NEW user's interactive bash really see the alias?  Simulated with a
# throw-away HOME populated from /etc/skel (no real user's files are read).
#
# The check must NOT inherit the caller's controlling terminal: `bash -i` turns
# on job control and falls back to /dev/tty when stdin is not a tty, and
# `timeout` runs its command in a background process group, so on a real
# terminal bash is stopped by SIGTTIN/SIGTTOU.  Interactive bash also ignores
# SIGTERM, so a plain `timeout` never ended it and setup.sh hung forever (and
# the stuck child kept the setup lock).  Hence: setsid (new session, no
# controlling tty - the same situation as cron/containers), `timeout -k`
# (SIGKILL as a last resort) and the lock fd 9 closed for the child.
verify_alias() {
    local home out
    local -a sess=()
    home=$(mktemp -d) || return 1
    if [[ -f /etc/skel/.bashrc ]]; then cp -- /etc/skel/.bashrc "$home/.bashrc"; fi
    if command -v setsid >/dev/null 2>&1; then
        # util-linux setsid needs -w to wait for the child; busybox setsid has no -w.
        if setsid --help 2>&1 | grep -q -- '--wait'; then sess=(setsid -w); else sess=(setsid); fi
    fi
    out=$(cd / && env -i HOME="$home" TERM=dumb PATH="$PATH" \
        "${sess[@]+"${sess[@]}"}" timeout -k 2 20 bash -i -c 'alias linux-archive' </dev/null 2>/dev/null 9>&-)
    rm -rf -- "$home"
    [[ $out == *"$INSTALL_BIN"* ]]
}
