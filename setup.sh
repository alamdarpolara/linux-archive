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
