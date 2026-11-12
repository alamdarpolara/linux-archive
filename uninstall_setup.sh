#!/usr/bin/env bash
# ShellCheck: clean with `shellcheck -S style -o all` except the optional,
# purely stylistic checks SC2250 (require-variable-braces), SC2312
# (check-extra-masked-returns: $(...) here only wraps commands whose output
# is validated) and SC2249 (add-default-case), disabled for the whole file.
# shellcheck disable=SC2250,SC2312,SC2249
#
# uninstall_setup.sh - remove everything setup.sh installed (root only).
#
#   sudo ./uninstall_setup.sh                 remove (asks for confirmation)
#   sudo ./uninstall_setup.sh --yes           remove without asking
#   sudo ./uninstall_setup.sh --dry-run       only show what would be removed
#   sudo ./uninstall_setup.sh --remove-deps   also remove the packages that
#                                             install.sh newly installed
#
# Safety rules
#   * Only what setup.sh recorded in /var/lib/linux-archive/manifest (or, for a
#     setup without manifest, the exact fixed paths it uses) is touched.
#   * There is no `rm -rf` anywhere: /opt/linux-archive is removed only when it
#     is a real, root-owned directory whose contents match the manifest
#     exactly (same file list, same SHA-256).  Otherwise nothing in it is
#     deleted, the differences are printed and the exit code is 1.
#   * The alias block is cut out of the bash configuration file atomically
#     (temp file + rename on the same filesystem); everything else in the file
#     stays byte-identical, and owner, mode and SELinux label are kept.  A
#     timestamped backup is written first and deleted once the result has
#     been verified (kept with --keep-backup, or automatically on failure).
#   * --remove-deps removes only packages listed in
#     /var/lib/linux-archive/installed-packages (written by install.sh), never
#     packages that were present before, never core packages, and never when
#     the package manager would also remove other packages.
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
readonly PKG_RECORD=$STATE_DIR/installed-packages
readonly BEGIN_MARK='# BEGIN linux-archive (managed by setup.sh - do not edit)'
readonly END_MARK='# END linux-archive'
readonly RC_CANDIDATES=(/etc/bash.bashrc /etc/bashrc /etc/bash/bashrc /etc/bash.bashrc.local)
# Never removed by --remove-deps, even if install.sh had installed them:
readonly PROTECTED_PKGS=" bash coreutils coreutils-single findutils grep tar gzip sed util-linux util-linux-core util-linux-misc ncurses ncurses-bin ncurses-utils file dpkg rpm binutils busybox "

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
plan() { printf '%s[dry-run]%s would %s\n' "$C_ACC" "$C_RST" "$*"; }

usage() {
    cat <<'USAGE'
uninstall_setup.sh - remove everything setup.sh installed (must be run as root)

  sudo ./uninstall_setup.sh [options]

  --dry-run        show what would be removed, change nothing
  --yes, -y        do not ask for confirmation
  --remove-deps    also remove the packages that install.sh newly installed
                   (only those; never packages that were already present)
  --keep-backup    keep the timestamped backup of the bash configuration file
  -h, --help       this text

Exit codes: 0 ok (or nothing to remove), 1 error / refused, 2 usage,
            3 not root, 5 immutable system, 6 busy (another setup/uninstall runs)
USAGE
}

DRY=0 ASSUME_YES=0 REMOVE_DEPS=0 KEEP_BACKUP=0
for arg in "$@"; do
    case $arg in
        --dry-run|-n) DRY=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --remove-deps) REMOVE_DEPS=1 ;;
        --keep-backup) KEEP_BACKUP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown option: $arg"; usage; exit 2 ;;
    esac
done

# ------------------------------------------------------------------- root
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
        info "Root is required - re-running with sudo..."
        exec sudo -- bash "$(readlink -f -- "${BASH_SOURCE[0]}")" "$@"
    fi
    err "uninstall_setup.sh must be run as root:  sudo ./uninstall_setup.sh"
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
root_is_readonly() {
    local mnt opts
    [[ -r /proc/mounts ]] || return 1
    while read -r _ mnt _ opts _; do
        if [[ $mnt == / ]]; then [[ ,$opts, == *,ro,* ]] && return 0; fi
    done </proc/mounts
    return 1
}
immutable_reason() {   # same rules as setup.sh (see the comment there)
    local id like
    id=$(osr ID) like=$(osr ID_LIKE)
    if [[ $id == nixos || " $like " == *" nixos "* ]]; then echo "NixOS"; return 0; fi
    if [[ -e /run/ostree-booted ]]; then echo "an rpm-ostree/OSTree image-based system"; return 0; fi
    case $id in
        opensuse-microos|opensuse-aeon|opensuse-kalpa|sl-micro|suse-microos) echo "a transactional openSUSE/SUSE system"; return 0 ;;
        ubuntu-core) echo "Ubuntu Core"; return 0 ;;
    esac
    if command -v transactional-update >/dev/null 2>&1 && root_is_readonly; then echo "a transactional system with a read-only root"; return 0; fi
    if [[ -d /usr && ! -w /usr ]]; then echo "a system whose /usr is read-only"; return 0; fi
    return 1
}
if reason=$(immutable_reason); then
    err "Refusing to run: this is $reason (setup.sh never installs there, so there is nothing to remove)."
    exit 5
fi

# ---------------------------------------------------------------- locking
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
    command -v flock >/dev/null 2>&1 || die "flock (util-linux) is missing."
    [[ -L $LOCK_FILE ]] && die "$LOCK_FILE is a symlink - refusing to use it."
    exec 9>>"$LOCK_FILE" || die "cannot open $LOCK_FILE"
    if ! flock -n 9; then
        err "Another setup.sh / uninstall_setup.sh is running (lock: $LOCK_FILE)."
        exit 6
    fi
}

# --------------------------------------------------------------- helpers
sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

strip_block() {   # strip_block <file> <begin> <end>
    local line skip=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$2" ]]; then skip=1; continue; fi
        if (( skip )); then [[ $line == "$3" ]] && skip=0; continue; fi
        printf '%s\n' "$line"
    done <"$1"
}

block_state() {   # none | ok | broken
    local b e
    [[ -f $1 ]] || { echo none; return; }
    b=$(grep -cFx -- "$2" "$1")
    e=$(grep -cFx -- "$3" "$1")
    if (( b == 0 && e == 0 )); then echo none
    elif (( b == 1 && e == 1 )); then echo ok
    else echo broken; fi
}

replace_file() {   # replace_file <new-file> <target>: atomic, keeps owner/mode/label
    chmod --reference="$2" -- "$1" || return 1
    chown --reference="$2" -- "$1" || return 1
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled && command -v chcon >/dev/null 2>&1; then
        chcon --reference="$2" -- "$1" 2>/dev/null || true
    fi
    mv -f -- "$1" "$2"
}

# ------------------------------------------------------- read the manifest
M_DIR="" M_FILE="" M_SUM="" M_LINK="" M_LINK_TGT="" M_LOCK=""
M_LARC="" M_LARC_TGT="" M_LARC_STATE="" M_LARC_SEEN=0
M_RC=() M_RC_CREATED=() M_RC_NL=()
HAVE_MANIFEST=0
if [[ -f $MANIFEST && ! -L $MANIFEST ]]; then
    [[ $(stat -c '%u' -- "$MANIFEST") == 0 ]] || die "$MANIFEST is not owned by root - refusing to trust it."
    HAVE_MANIFEST=1
    while IFS=$'\t' read -r kind p a b c; do
        case $kind in
            dir) M_DIR=$p ;;
            file) M_FILE=$p M_SUM=$a ;;
            symlink) M_LINK=$p M_LINK_TGT=$a ;;
            larc)
                (( M_LARC_SEEN == 0 )) || die "manifest has duplicate larc records - refusing."
                M_LARC_SEEN=1 M_LARC=$p M_LARC_TGT=$a M_LARC_STATE=$b ;;
            bashrc) M_RC+=("$p") M_RC_CREATED+=("${a:-0}") M_RC_NL+=("${b:-0}") ;;
            lock) M_LOCK=$p ;;
        esac
        : "$c"
    done <"$MANIFEST"
    # The manifest may only name the fixed paths setup.sh uses.
    [[ -z $M_DIR || $M_DIR == "$INSTALL_DIR" ]] || die "manifest names an unexpected directory ($M_DIR) - refusing."
    [[ -z $M_FILE || $M_FILE == "$INSTALL_BIN" ]] || die "manifest names an unexpected file ($M_FILE) - refusing."
    [[ -z $M_LINK || $M_LINK == "$LINK" ]] || die "manifest names an unexpected symlink ($M_LINK) - refusing."
    [[ -z $M_LINK_TGT || $M_LINK_TGT == "$INSTALL_BIN" ]] || die "manifest names an unexpected symlink target - refusing."
    if (( M_LARC_SEEN )); then
        [[ $M_LARC == "$LARC_LINK" && $M_LARC_TGT == "$INSTALL_BIN" ]] ||
            die "manifest names an unexpected larc path or target - refusing."
        [[ $M_LARC_STATE == owned || $M_LARC_STATE == collision ]] ||
            die "manifest has an invalid larc ownership decision - refusing."
    fi
    for p in "${M_RC[@]}"; do
        case " ${RC_CANDIDATES[*]} " in *" $p "*) ;; *) die "manifest names an unexpected bash file ($p) - refusing." ;; esac
    done
    case $M_LOCK in ""|/run/linux-archive-setup.lock|/var/lib/linux-archive-setup.lock) ;; *) die "manifest names an unexpected lock file - refusing." ;; esac
fi

# --------------------------------------------------------- what is there?
ACTIONS=()          # human-readable plan
FAILED=0
FOUND=0
RC_TARGETS=()       # bash files that contain our block
for p in "${RC_CANDIDATES[@]}"; do
    [[ -f $p ]] || continue
    st=$(block_state "$p" "$BEGIN_MARK" "$END_MARK")
    case $st in
        ok) RC_TARGETS+=("$p"); ACTIONS+=("remove the linux-archive alias block from $p"); FOUND=1 ;;
        broken) err "$p has unbalanced linux-archive markers - it will NOT be touched; remove the block by hand."; FAILED=1; FOUND=1 ;;
    esac
done
LINK_REMOVE=0
if [[ -L $LINK ]]; then
    FOUND=1
    if [[ $(readlink -- "$LINK") != "$INSTALL_BIN" ]]; then warn "$LINK points somewhere else ($(readlink -- "$LINK")) - it will be left alone."
    elif (( HAVE_MANIFEST )) && [[ $M_LINK == "$LINK" ]]; then LINK_REMOVE=1; ACTIONS+=("remove the symlink $LINK")
    else warn "$LINK is not recorded in the manifest - it will be left alone."; fi
elif [[ -e $LINK ]]; then
    warn "$LINK is not a symlink created by setup.sh - it will be left alone."
fi

# Never infer larc ownership from its name or even a matching target: it must
# have an owned record in the manifest AND still point to our installed file.
LARC_REMOVE=0
if [[ $M_LARC_STATE == owned ]]; then
    if [[ -L $LARC_LINK && $(readlink -- "$LARC_LINK") == "$INSTALL_BIN" ]]; then
        LARC_REMOVE=1
        ACTIONS+=("remove the manifest-owned symlink $LARC_LINK")
    elif [[ -e $LARC_LINK || -L $LARC_LINK ]]; then
        warn "$LARC_LINK no longer points to $INSTALL_BIN - foreign replacement left alone."
    fi
fi

# /opt/linux-archive must match the manifest exactly.
DIR_OK=0
DIR_PROBLEMS=()
if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
    FOUND=1
    if [[ -L $INSTALL_DIR ]]; then DIR_PROBLEMS+=("$INSTALL_DIR is a symbolic link")
    elif [[ ! -d $INSTALL_DIR ]]; then DIR_PROBLEMS+=("$INSTALL_DIR is not a directory")
    else
        [[ $(stat -c '%u' -- "$INSTALL_DIR") == 0 ]] || DIR_PROBLEMS+=("$INSTALL_DIR is not owned by root")
        while IFS= read -r -d '' e; do
            if [[ $e != "$INSTALL_BIN" ]]; then DIR_PROBLEMS+=("unexpected entry: $(printf '%q' "$e")"); fi
        done < <(find "$INSTALL_DIR" -mindepth 1 -print0 2>/dev/null)
        if [[ -e $INSTALL_BIN || -L $INSTALL_BIN ]]; then
            if [[ -L $INSTALL_BIN || ! -f $INSTALL_BIN ]]; then DIR_PROBLEMS+=("$INSTALL_BIN is not a regular file")
            elif (( HAVE_MANIFEST )); then
                # Never delete the script on a manifest without a usable digest.
                if [[ ! $M_SUM =~ ^[0-9a-f]{64}$ ]]; then
                    DIR_PROBLEMS+=("the manifest has no valid SHA-256 for $INSTALL_BIN - refusing to delete it")
                elif [[ $(sha256_of "$INSTALL_BIN") != "$M_SUM" ]]; then
                    DIR_PROBLEMS+=("$INSTALL_BIN was modified (SHA-256 differs from the manifest)")
                fi
            else
                grep -q '^readonly LA_VERSION=' "$INSTALL_BIN" || DIR_PROBLEMS+=("$INSTALL_BIN is not the linux-archive script (no manifest to compare with)")
            fi
        fi
    fi
    if (( ${#DIR_PROBLEMS[@]} == 0 )); then
        DIR_OK=1
        [[ -e $INSTALL_BIN ]] && ACTIONS+=("delete $INSTALL_BIN")
        ACTIONS+=("remove the directory $INSTALL_DIR")
    else
        err "$INSTALL_DIR does not match the manifest - NOTHING in it will be deleted:"
        for e in "${DIR_PROBLEMS[@]}"; do err "   - $e"; done
        FAILED=1
    fi
fi

# Packages recorded by install.sh
DEPS=()
if (( REMOVE_DEPS )); then
    if [[ -f $PKG_RECORD && ! -L $PKG_RECORD && $(stat -c '%u' -- "$PKG_RECORD") == 0 ]]; then
        while IFS= read -r p; do
            [[ $p =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || continue
            if [[ $PROTECTED_PKGS == *" $p "* ]]; then info "Keeping core package '$p' (protected)."; continue; fi
            DEPS+=("$p")
        done <"$PKG_RECORD"
        (( ${#DEPS[@]} )) && ACTIONS+=("remove packages installed by install.sh: ${DEPS[*]}")
    else
        info "No package record from install.sh ($PKG_RECORD) - no packages to remove."
    fi
fi
# The state directory counts as "installed by setup.sh" only through its manifest;
# install.sh's package record alone is kept for a later --remove-deps.
if (( HAVE_MANIFEST )); then FOUND=1; fi

if (( ! FOUND )) && (( ${#DEPS[@]} == 0 )); then
    info "Nothing to remove - linux-archive is not installed by setup.sh."
    [[ -f $PKG_RECORD ]] && info "(install.sh's record of installed packages is kept: $PKG_RECORD - see --remove-deps)"
    exit 0
fi

# --------------------------------------------------------------- confirm
printf '\nPlanned actions:\n'
for a in "${ACTIONS[@]}"; do printf '  - %s\n' "$a"; done
(( HAVE_MANIFEST )) && printf '  - remove the manifest %s\n' "$MANIFEST"
printf '\n'
if (( DRY )); then
    for a in "${ACTIONS[@]}"; do plan "$a"; done
    info "Dry run: nothing was changed."
    exit "$FAILED"
fi
if (( ! ASSUME_YES )); then
    if [[ ! -t 0 ]]; then die "Not a terminal - re-run with --yes to confirm."; fi
    read -r -p "Proceed? [y/N] " ans || exit 1
    [[ $ans == [yY]* ]] || { info "Cancelled - nothing was changed."; exit 1; }
fi

take_lock

# ----------------------------------------------------------- 1. alias block
for rc in "${RC_TARGETS[@]}"; do
    created=0 nl=0
    for i in "${!M_RC[@]}"; do
        [[ ${M_RC[i]} == "$rc" ]] && { created=${M_RC_CREATED[i]}; nl=${M_RC_NL[i]}; }
    done
    if [[ -L $rc ]]; then warn "$rc is a symlink - not editing it."; FAILED=1; continue; fi
    backup="$rc.linux-archive-uninstall.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p -- "$rc" "$backup" || { err "cannot back up $rc - not touching it."; FAILED=1; continue; }
    tmp=$(mktemp "$rc.la-XXXXXX") || { err "cannot create a temp file next to $rc"; FAILED=1; continue; }
    strip_block "$rc" "$BEGIN_MARK" "$END_MARK" >"$tmp"
    # setup.sh added a newline before the block when the file did not end
    # with one: take it away again so the file is byte-identical to before.
    if [[ $nl == 1 && -s $tmp ]]; then
        truncate -s -1 -- "$tmp"
    fi
    if [[ $created == 1 && ! -s $tmp ]]; then
        rm -f -- "$tmp" "$rc" && ok "Removed $rc (setup.sh had created it; it is empty now)."
    elif replace_file "$tmp" "$rc"; then
        ok "Alias block removed from $rc."
    else
        rm -f -- "$tmp"; err "could not update $rc (backup kept: $backup)"; FAILED=1; continue
    fi
    # Verify: no markers left, and the result equals the backup minus the block.
    if [[ -e $rc ]] && grep -qF -- "$BEGIN_MARK" "$rc"; then
        err "$rc still contains the block - backup kept: $backup"; FAILED=1
    elif (( KEEP_BACKUP )); then
        info "Backup kept: $backup"
    else
        rm -f -- "$backup"
    fi
done

# --------------------------------------------------------------- 2. symlink
if (( LINK_REMOVE )) && [[ -L $LINK && $(readlink -- "$LINK") == "$INSTALL_BIN" ]]; then
    rm -f -- "$LINK" && ok "Removed symlink $LINK."
fi

# -------------------------------------------------------- 3. larc symlink
if (( LARC_REMOVE )); then
    if [[ -L $LARC_LINK && $(readlink -- "$LARC_LINK") == "$INSTALL_BIN" ]]; then
        if rm -f -- "$LARC_LINK"; then ok "Removed manifest-owned symlink $LARC_LINK."
        else err "Could not remove $LARC_LINK."; FAILED=1; fi
    else
        warn "$LARC_LINK changed before removal - left alone."
    fi
fi

# ------------------------------------------------------------ 4. directory
if (( DIR_OK )); then
    if [[ -f $INSTALL_BIN && ! -L $INSTALL_BIN ]]; then rm -f -- "$INSTALL_BIN" && ok "Removed $INSTALL_BIN."; fi
    if rmdir -- "$INSTALL_DIR" 2>/dev/null; then ok "Removed $INSTALL_DIR."
    else err "$INSTALL_DIR is not empty after removing the script - left in place."; FAILED=1; fi
fi

# ------------------------------------------------------------- 5. packages
pm_remove() {   # remove DEPS with the native package manager, refusing collateral removals
    local -a ok_pkgs=() p
    if command -v apt-get >/dev/null 2>&1; then
        for p in "${DEPS[@]}"; do [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]] && ok_pkgs+=("$p"); done
        (( ${#ok_pkgs[@]} )) || return 0
        # Simulate first: abort if apt would remove anything else.
        local extra
        extra=$(apt-get -s remove "${ok_pkgs[@]}" 2>/dev/null | sed -n 's/^Remv \([^ ]*\).*/\1/p' | while read -r r; do
            r=${r%%:*}; case " ${ok_pkgs[*]} " in *" $r "*) ;; *) printf '%s ' "$r" ;; esac; done)
        if [[ -n $extra ]]; then err "apt would also remove: $extra- packages kept."; return 1; fi
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "${ok_pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then
        for p in "${DEPS[@]}"; do rpm -q "$p" >/dev/null 2>&1 && ok_pkgs+=("$p"); done
        (( ${#ok_pkgs[@]} )) || return 0
        # rpm -e --test fails when another package still needs one of them.
        if ! rpm -e --test "${ok_pkgs[@]}" >/dev/null 2>&1; then err "other packages depend on: ${ok_pkgs[*]} - packages kept."; return 1; fi
        rpm -e "${ok_pkgs[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        for p in "${DEPS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 && ok_pkgs+=("$p"); done
        (( ${#ok_pkgs[@]} )) || return 0
        # Plain -R (no -c/-s) refuses when other packages depend on them.
        pacman -R --noconfirm "${ok_pkgs[@]}"
    elif command -v apk >/dev/null 2>&1; then
        for p in "${DEPS[@]}"; do apk info -e "$p" >/dev/null 2>&1 && ok_pkgs+=("$p"); done
        (( ${#ok_pkgs[@]} )) || return 0
        # apk del only drops them from /etc/apk/world; packages still needed stay.
        apk del "${ok_pkgs[@]}"
    else
        err "no supported package manager found"; return 1
    fi
}
if (( ${#DEPS[@]} )); then
    if pm_remove; then ok "Removed the packages that install.sh had installed."
    else err "Package removal was refused or failed - see above."; FAILED=1; fi
fi

# ----------------------------------------------------- 6. state directory
