#!/usr/bin/env bash
# ShellCheck: clean with `shellcheck -S style -o all` except three OPTIONAL,
# purely stylistic checks, disabled file-wide for these reasons:
#   SC2250 require-variable-braces: "$var" vs "${var}" is cosmetic (all
#          expansions are quoted where it matters).
#   SC2312 check-extra-masked-returns: nearly every $(...) calls our own
#          formatting helpers (disp, human, fit) that cannot fail; output of
#          external commands is validated (regex / empty checks) where used.
#   SC2249 add-default-case: case statements deliberately ignore values that
#          need no action.
# shellcheck disable=SC2250,SC2312,SC2249
#
# linux-archive - terminal archive helper (create and extract archives in the
# current directory).  Pure bash + ANSI colours + tput; no dialog/fzf/whiptail.
#
# Targets: Debian, Ubuntu, Fedora, RHEL clones (Rocky/Alma), openSUSE, Arch,
# Alpine (see README for the tested releases).  Needs bash >= 4.4 and the GNU
# userland (coreutils, findutils, tar); install.sh installs all of it.
# Run `linux-archive --check` to see which helper tools are present.
#
# Facts this script relies on (observed in container tests; rerun the matrix
# described in README to verify the current revision):
#   * 7-Zip reads a password from STDIN when it needs one and has no tty
#     ("Enter password (will not be echoed):").  `7z a -p` (bare -p) means
#     "ask"; for l/t/x the bare -p means "empty password", so for reading we
#     omit -p and 7-Zip prompts only when really needed.  Switches used:
#     -mhe=on (7z header/file-name encryption), -mem=AES256 (zip AES-256),
#     -snl (store symlinks as links), -spd (no wildcard matching of names).
#     https://7-zip.org/  (7-Zip help: `7zz --help`)
#     p7zip 16.02 (EPEL 8/9) also asks "Verify password" when creating, so the
#     password is sent twice for `7z a`; newer 7-Zip ignores the second line.
#     7-Zip < 22 skips absolute/escaping symlinks on extraction (7-Zip >= 22
#     rewrites them); both cases are normalised so the user decides.
#   * Info-ZIP zip/unzip can only take a password on argv (-P) or from
#     /dev/tty, so passworded zip files are created AND extracted with 7-Zip.
#     man zip / man unzip
#   * Real RAR "unrar" (non-free) was observed to read the password from stdin
#     when it runs without a controlling terminal, hence every external tool
#     here runs under `setsid` (no /dev/tty, own process group so Ctrl+C can
#     kill the whole tree).  unrar-free cannot handle encrypted RAR at all.
#   * GNU tar/unzip/7-Zip/bsdtar all neutralise "../", absolute names and
#     writes through symlinks; linux-archive additionally scans listings
#     first and audits the extracted tree afterwards.
#
# ------------------------------------------------- environment hardening
# Done first, unconditionally (also for normal users): every external tool is
# found through a fixed PATH, and variables that silently change the
# behaviour of bash or of the archive tools are removed.  NOTE: bash itself
# reads BASH_ENV / SHELLOPTS / BASHOPTS before this line runs, so this
# protects the rest of the script and every child process, not bash's own
# start-up (`sudo` resets the environment for the root case; the copy that
# setup.sh installs starts with an absolute "#!/bin/bash" interpreter path).
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
IFS=$' \t\n'
# CDPATH changes `cd`, GLOBIGNORE changes globbing, BASH_ENV/ENV are sourced
# by every non-interactive child bash/sh (e.g. our `bash -c` pipelines).
unset -v BASH_ENV ENV CDPATH GLOBIGNORE POSIXLY_CORRECT 2>/dev/null
# SHELLOPTS/BASHOPTS are read-only inside bash; un-export them so child
# shells do not inherit options such as xtrace or noglob (bash(1) "SHELLOPTS").
export -n SHELLOPTS BASHOPTS 2>/dev/null
# Default-option variables of the archive tools (an attacker-controlled
# TAR_OPTIONS could e.g. add --absolute-names): tar(1) TAR_OPTIONS, unzip(1)
# UNZIP/UNZIPOPT, zip(1) ZIP/ZIPOPT, xz(1) XZ_DEFAULTS/XZ_OPT, gzip(1) GZIP,
# bzip2(1) BZIP2/BZIP, zstd(1) ZSTD_CLEVEL/ZSTD_NBTHREADS, lz4(1)
# LZ4_CLEVEL/LZ4_NBWORKERS, bsdtar(1) TAR_READER_OPTIONS/TAR_WRITER_OPTIONS/TAPE.
unset -v TAR_OPTIONS UNZIP UNZIPOPT ZIP ZIPOPT XZ_DEFAULTS XZ_OPT GZIP BZIP2 BZIP \
    ZSTD_CLEVEL ZSTD_NBTHREADS LZ4_CLEVEL LZ4_NBWORKERS TAR_READER_OPTIONS \
    TAR_WRITER_OPTIONS TAPE 2>/dev/null

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'linux-archive: bash >= 4.4 is required (this is bash %s).\n' "$BASH_VERSION" >&2
    exit 1
fi

readonly LA_VERSION="2.0.0"

# ---------------------------------------------------- safety limits
# Hard limits for extraction (abort, no "extract anyway"):
readonly LIMIT_MAX_BYTES=$(( 64 * 1024 * 1024 * 1024 ))  # declared unpacked size
readonly LIMIT_MAX_ENTRIES=1000000                       # number of members
readonly LIMIT_HARD_RATIO=1000                           # ratio refused when ...
readonly LIMIT_HARD_RATIO_MIN=$(( 1024 * 1024 * 1024 ))  # ... unpacked >= 1 GiB
# Soft limits (warning, the user may still extract):
readonly LIMIT_WARN_RATIO=100                            # ratio warned when ...
readonly LIMIT_WARN_RATIO_MIN=$(( 50 * 1024 * 1024 ))    # ... unpacked >= 50 MiB
readonly LIMIT_LIST_TIMEOUT=900                          # seconds for a listing run

# ------------------------------------------------------------------ globals
FORCE_PLAIN=0          # --plain: numbered menus instead of arrow-key menus
FORCE_NOCOLOR=0        # --no-color / NO_COLOR
UI_MODE=plain          # tui | plain (decided in ui_init)
UI_UTF8=0              # 1 when the terminal charset is UTF-8 (box drawing)
COLS=80
ROWS=24
RESIZED=0
SAVED_STTY=""
WORKDIR=""             # private scratch dir (job logs); removed on exit
PARTIAL_PATH=""        # temp dir holding a half-made archive / extraction
CUR_OP=""              # create | extract | ""  (used in the interrupt message)
EXIT_MSG=""
JOB_PID=""
JOB_RC=0
JOB_LOG=""
JOB_ABORT=""
JOB_SECRET=""          # password handed to the next job's STDIN (never exported)
export -n JOB_SECRET
JOB_STDOUT_FILE=""
JOB_WATCH_DIR=""
JOB_WATCH_LIMIT=0
JOB_SIZE_FILE=""
JOB_TIMEOUT=""         # seconds; empty = no limit
SZ=""                  # 7-Zip binary (7zz | 7z | 7za)
SZ_LINK=()             # extra 7z switches for symlinks (empty on very old 7-Zip)
SZ_RAR=0               # 1 when this 7-Zip build contains the RAR decoder
UNRAR=""               # real (non-free) unrar
UNRAR_FREE=""          # unrar-free fallback (Debian/Ubuntu)
UNAR=""                # unar (The Unarchiver) fallback: unencrypted RAR only
LSAR=""                # lsar, unar's lister
RAR_BACKEND=""         # unrar | 7z | unar | unrar-free | bsdtar | ""
LOCK_FD=""             # fd holding the per-directory output lock
SECRET_ACTIVE=0        # 1 while a password is held in memory
SECRET_XTRACE=0        # xtrace state to restore when the password is gone
# shellcheck disable=SC2034  # passed by name to the menu functions (nameref)
NOARR=()

# Never keep secrets or history around.  (A non-interactive script has no
# history anyway; this is belt and braces for `source`d or odd invocations.)
# No core dumps: a dump of this process could contain a password.
unset HISTFILE
set +o history 2>/dev/null || true
ulimit -c 0 2>/dev/null || true

# ------------------------------------------------------------ secrets
# While a password is held, xtrace MUST be off: with `bash -x` every [[ ]]
# test, assignment and the builtin `printf ... | tool` would print it.  The
# previous state is restored once the password has been wiped.
secret_on() {
    { local _s=$-; set +x; } 2>/dev/null
    if (( ! SECRET_ACTIVE )); then
        SECRET_ACTIVE=1
        if [[ $_s == *x* ]]; then SECRET_XTRACE=1; else SECRET_XTRACE=0; fi
    fi
}
secret_off() {
    (( SECRET_ACTIVE )) || return 0
    SECRET_ACTIVE=0
    if (( SECRET_XTRACE )); then SECRET_XTRACE=0; set -x; fi
    return 0
}

# --------------------------------------------------------------- locale
# zip stores UTF-8 names correctly only in a UTF-8 locale, and ${#var} /
# ${var:0:n} must count characters, not bytes.  C.UTF-8 is built into glibc on
# every tested glibc distro; musl (Alpine) has no `locale` command and is
# UTF-8 when LANG/LC_* say so.  Box drawing is only used when the *user's*
# locale is UTF-8.
setup_locale() {
    local cm lv
    cm=$(locale charmap 2>/dev/null || true)
    if [[ -z $cm ]] && ! have locale; then
        lv=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
        if [[ ${lv,,} == *utf-8* || ${lv,,} == *utf8* ]]; then cm=UTF-8; fi
    fi
    if [[ $cm == UTF-8 ]]; then
        UI_UTF8=1
    else
        UI_UTF8=0
        lv=$(locale -a 2>/dev/null)
        if [[ $'\n'${lv,,}$'\n' == *$'\n'c.utf8$'\n'* || $'\n'${lv,,}$'\n' == *$'\n'c.utf-8$'\n'* ]]; then
            export LC_ALL=C.UTF-8
        elif ! have locale; then
            export LC_ALL=C.UTF-8      # musl: always available
        fi
    fi
}

# ---------------------------------------------------------- tool discovery
have() { command -v "$1" >/dev/null 2>&1; }

find_7z() {
    local c out
    for c in 7zz 7z 7za; do
        if have "$c"; then
            SZ=$(command -v "$c")
            break
        fi
    done
    [[ -n $SZ ]] || return 1
    # -snl needs 7-Zip >= 21; very old p7zip (16.x) would reject it.
    SZ_LINK=(-snl)
    out=$("$SZ" i 2>&1 </dev/null)
    if [[ ${out:0:300} =~ ([0-9]+)\.[0-9]+ ]] && (( BASH_REMATCH[1] < 21 )); then
        SZ_LINK=()
    fi
    # `7z i` lists formats, then "Codecs:".  The RAR *format* is always listed;
    # only builds that ship the (non-free) unRAR code have a "Rar5" CODEC
    # (Arch: yes; Debian/Ubuntu: no - verified with `7z i`).
    local codecs=""
    [[ $out == *Codecs:* ]] && codecs=${out#*Codecs:}
    codecs=${codecs%%Hashers:*}
    if [[ $codecs == *" Rar5"* ]]; then SZ_RAR=1; fi
    return 0
}

# Debian's `unrar` name can be the non-free RAR tool or an alternative that
# points to unrar-free.  The real one prints "UNRAR x.xx freeware".
find_unrar() {
    local c out
    for c in unrar unrar-nonfree; do
        have "$c" || continue
        out=$("$c" 2>&1 </dev/null | head -n 3)
        if [[ $out == *UNRAR* ]]; then
            UNRAR=$(command -v "$c")
            break
        fi
    done
    if have unrar-free; then
        UNRAR_FREE=$(command -v unrar-free)
    fi
    if have unar && have lsar; then
        UNAR=$(command -v unar) LSAR=$(command -v lsar)
    fi
}

# Best available RAR extractor.  Only unrar and 7-Zip can take a password
# without argv (stdin).  unar accepts a password only as `-p <pw>` (argv) and
# bsdtar only via --passphrase (argv) or /dev/tty, so those two - and
# unrar-free, which cannot decrypt - are used for unencrypted RAR only.
pick_rar_backend() {
    if [[ -n $UNRAR ]]; then RAR_BACKEND=unrar
    elif [[ -n $SZ ]] && (( SZ_RAR )); then RAR_BACKEND=7z
    elif [[ -n $UNAR ]]; then RAR_BACKEND=unar
    elif [[ -n $UNRAR_FREE ]]; then RAR_BACKEND=unrar-free
    elif have bsdtar; then RAR_BACKEND=bsdtar
    else RAR_BACKEND=""; fi
}
rar_backend_decrypts() { [[ $RAR_BACKEND == unrar || $RAR_BACKEND == 7z ]]; }

# Read-only peek at /etc/os-release (never sourced): distro family for hints.
os_family() {
    local line id="" like=""
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line; do
            case $line in
                ID=*) id=${line#ID=} ;;
                ID_LIKE=*) like=${line#ID_LIKE=} ;;
            esac
        done </etc/os-release
    fi
    id=${id//\"/} like=${like//\"/}
    case " $id $like " in
        *" alpine "*) echo alpine ;;
        *" arch "*) echo arch ;;
        *" suse "*|*" opensuse "*|*opensuse*) echo suse ;;
        *" debian "*|*" ubuntu "*) echo debian ;;
        *" fedora "*|*" rhel "*|*" centos "*) echo fedora ;;
        *) echo unknown ;;
    esac
}

# The GNU userland is required: the safety scan relies on GNU tar's listing
# format, `realpath -m`, `find -printf` and `mv -T`.  BusyBox/uutils
# replacements are detected and reported instead of silently misbehaving.
# NOTE: no `cmd | grep -q` here - with pipefail, grep -q may exit before
# the writer is done, the writer dies of SIGPIPE and the pipeline "fails"
# (observed intermittently with `mv --help` on Arch).  Output is captured.
GNU_MISSING=()
check_gnu() {
    local out
    GNU_MISSING=()
    out=$(tar --version 2>/dev/null) || out=""
    [[ $out == *"GNU tar"* ]] || GNU_MISSING+=("GNU tar")
    find / -maxdepth 0 -printf '' >/dev/null 2>&1 || GNU_MISSING+=("GNU find (findutils)")
    realpath -m -- /nonexistent/a/../b >/dev/null 2>&1 || GNU_MISSING+=("realpath -m (GNU coreutils)")
    out=$(mv --help 2>&1) || out=""
    [[ $out == *--no-target-directory* ]] || GNU_MISSING+=("mv -T (GNU coreutils)")
    stat -c %s -- / >/dev/null 2>&1 || GNU_MISSING+=("stat -c (coreutils)")
    have setsid || GNU_MISSING+=("setsid (util-linux)")
    # BusyBox flock has no -w (timeout); util-linux flock prints its name.
    [[ $(flock --version 2>&1 </dev/null) == *util-linux* ]] || GNU_MISSING+=("flock (util-linux)")
    (( ${#GNU_MISSING[@]} == 0 ))
}

OS_FAMILY=""
pkg_for() {   # tool -> package name on this distro family (for hints only)
    [[ -n $OS_FAMILY ]] || OS_FAMILY=$(os_family)
    local f=$OS_FAMILY
    case $1 in
        7z|7zz|7za) if [[ $f == fedora ]]; then echo "7zip (Fedora) / p7zip (EPEL)"; else echo 7zip; fi ;;
        xz) if [[ $f == debian ]]; then echo xz-utils; else echo xz; fi ;;
        mksquashfs|unsquashfs) if [[ $f == suse ]]; then echo squashfs; else echo squashfs-tools; fi ;;
        rpm2cpio) case $f in debian|alpine) echo rpm2cpio ;; arch) echo rpm-tools ;; *) echo rpm ;; esac ;;
        ar) echo binutils ;;
        dpkg-deb) echo dpkg ;;
        bsdtar) case $f in debian|alpine) echo libarchive-tools ;; arch) echo libarchive ;; *) echo bsdtar ;; esac ;;
        tput) case $f in debian) echo ncurses-bin ;; suse) echo ncurses-utils ;; *) echo ncurses ;; esac ;;
        setsid|flock) echo util-linux ;;
        unrar) echo "unrar (non-free), or bsdtar for unencrypted RAR" ;;
        *) echo "$1" ;;
    esac
}

# need_tools tool...  -> 0 if all present, otherwise prints what is missing.
need_tools() {
    local t miss=()
    for t in "$@"; do
        case $t in
            7z) [[ -n $SZ ]] || miss+=("7z (package $(pkg_for 7z))") ;;
            unrar) pick_rar_backend; [[ -n $RAR_BACKEND ]] || miss+=("a RAR extractor (package $(pkg_for unrar))") ;;
            *) have "$t" || miss+=("$t (package $(pkg_for "$t"))") ;;
        esac
    done
    if (( ${#miss[@]} )); then
        msg_err "Missing tool(s): ${miss[*]}"
        msg_info "Install them with:  sudo ./install.sh"
        return 1
    fi
    return 0
}

print_check() {
    local t row ok=0 bad=0 g
    printf 'linux-archive %s - dependency check\n\n' "$LA_VERSION"
    for t in tar gzip bzip2 xz zstd lz4 zip unzip mksquashfs unsquashfs cabextract rpm2cpio cpio ar dpkg-deb bsdtar file setsid flock tput; do
        if have "$t"; then printf '  [ok]      %-12s %s\n' "$t" "$(command -v "$t")"; ok=$((ok+1))
        else printf '  [MISSING] %-12s package: %s\n' "$t" "$(pkg_for "$t")"; bad=$((bad+1)); fi
    done
    if [[ -n $SZ ]]; then
        row=$SZ
        (( SZ_RAR )) && row+=" (includes the RAR decoder)"
        printf '  [ok]      %-12s %s\n' "7-Zip" "$row"; ok=$((ok+1))
    else printf '  [MISSING] %-12s package: %s\n' "7-Zip" "$(pkg_for 7z)"; bad=$((bad+1)); fi
    pick_rar_backend
    case $RAR_BACKEND in
        unrar) row="$UNRAR (real RAR tool: RAR4/RAR5, encrypted RAR supported)" ;;
        7z) row="$SZ (7-Zip RAR decoder: RAR4/RAR5, encrypted RAR supported)" ;;
        unar) row="$UNAR (unar: unencrypted RAR only - it takes passwords only on argv)" ;;
        unrar-free) row="$UNRAR_FREE (unrar-free: no encrypted RAR, limited RAR5)" ;;
        bsdtar) row="$(command -v bsdtar) (libarchive: unencrypted RAR only)" ;;
        *) row="" ;;
    esac
    if [[ -n $row ]]; then printf '  [ok]      %-12s %s\n' "RAR" "$row"; ok=$((ok+1))
    else printf '  [MISSING] %-12s package: %s\n' "RAR" "$(pkg_for unrar)"; bad=$((bad+1)); fi
    if check_gnu; then
        printf '  [ok]      %-12s %s\n' "GNU tools" "GNU tar, findutils, coreutils, util-linux"; ok=$((ok+1))
    else
        for g in "${GNU_MISSING[@]}"; do printf '  [MISSING] %-12s %s\n' "GNU tools" "$g"; done; bad=$((bad+1))
    fi
    printf '\n%d present, %d missing.' "$ok" "$bad"
    (( bad )) && printf '  Run: sudo ./install.sh'
    printf '\n'
    return $(( bad > 0 ))
}

# --verify: compare the installed files with the manifest written by setup.sh.
readonly MANIFEST=/var/lib/linux-archive/manifest
print_verify() {
    local kind path a b c bad=0 n=0 sum seen_dir=0 seen_file=0 seen_larc=0
    if [[ ! -r $MANIFEST ]]; then
        printf 'linux-archive: no manifest at %s - not installed with setup.sh.\n' "$MANIFEST" >&2
        return 2
    fi
    while IFS=$'\t' read -r kind path a b c; do
        case $kind in
            file)
                n=$((n+1)); [[ $path == /opt/linux-archive/linux-archive.sh ]] && seen_file=1
                sum=$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1)
                if [[ ! $a =~ ^[0-9a-f]{64}$ ]]; then
                    printf '  [CHANGED]  %s (the manifest has no valid SHA-256)\n' "$path"; bad=1
                elif [[ -f $path && ! -L $path && $sum == "$a" && $(stat -c '%U:%G %a' -- "$path" 2>/dev/null) == "$b $c" ]]; then
                    printf '  [ok]       %s\n' "$path"
                else
                    printf '  [CHANGED]  %s\n' "$path"; bad=1
                fi ;;
            dir)
                n=$((n+1)); [[ $path == /opt/linux-archive ]] && seen_dir=1
                if [[ -d $path && ! -L $path && $(stat -c '%U:%G %a' -- "$path" 2>/dev/null) == "$a $b" ]]; then
                    printf '  [ok]       %s/\n' "$path"
                else
                    printf '  [CHANGED]  %s/\n' "$path"; bad=1
                fi ;;
            symlink)
                n=$((n+1))
                if [[ -L $path && $(readlink -- "$path") == "$a" ]]; then printf '  [ok]       %s -> %s\n' "$path" "$a"
                else printf '  [CHANGED]  %s\n' "$path"; bad=1; fi ;;
            larc)
                seen_larc=1
                if [[ $path != /usr/local/bin/larc || $a != /opt/linux-archive/linux-archive.sh ]]; then
                    printf '  [CHANGED]  invalid larc manifest record\n'; bad=1
                elif [[ $b == owned ]]; then
                    n=$((n+1))
                    if [[ -L $path && $(readlink -- "$path") == "$a" && $(command -v larc 2>/dev/null || true) == "$path" ]]; then
                        printf '  [ok]       %s -> %s (owned)\n' "$path" "$a"
                    else printf '  [CHANGED]  %s (owned alias missing, retargeted or shadowed)\n' "$path"; bad=1; fi
                elif [[ $b == collision ]]; then
                    printf '  [skipped]  larc (foreign command; not owned or checked)\n'
                else printf '  [CHANGED]  invalid larc manifest state\n'; bad=1; fi ;;
        esac
    done <"$MANIFEST"
    if (( n == 0 )); then printf 'linux-archive: the manifest is empty or unreadable.\n' >&2; return 2; fi
    # Fail closed: a manifest that omits a required record must not verify.
    (( seen_dir )) || { printf '  [CHANGED]  the manifest has no record for /opt/linux-archive\n'; bad=1; }
    (( seen_file )) || { printf '  [CHANGED]  the manifest has no record for /opt/linux-archive/linux-archive.sh\n'; bad=1; }
    (( seen_larc )) || { printf '  [CHANGED]  the manifest has no larc record (written by the current setup.sh)\n'; bad=1; }
    if (( bad )); then printf '\nVERIFY FAILED: the installation was modified (re-run: sudo ./setup.sh).\n'; return 1; fi
    printf '\nInstallation verified: files match the manifest.\n'
    return 0
}

# ----------------------------------------------------------- small helpers
# Wipe a secret variable (by name) before unsetting it.
wipe_var() {
    local -n _wv=$1
    _wv=${_wv:-}
    _wv=${_wv//?/0}
    _wv=""
    unset -n _wv
    unset -v "$1"
}

human() {   # bytes -> "12.3 MiB"
    local b=${1:-0} i=0 v unit
    local -a u=(B KiB MiB GiB TiB PiB)
    if (( b < 1024 )); then printf '%d B' "$b"; return; fi
    v=$(( b * 10 ))
    while (( v >= 10240 && i < 5 )); do v=$(( v / 1024 )); i=$(( i + 1 )); done
    unit=${u[$i]}
    printf '%d.%d %s' $(( v / 10 )) $(( v % 10 )) "$unit"
}

free_bytes() {   # free bytes on the filesystem holding $1
    # POSIX output format (df -P -k): 1024-byte blocks, available = field 4.
    local a line
    line=$(df -P -k -- "$1" 2>/dev/null | tail -n 1)
    read -r _ _ _ a _ <<<"$line"
    [[ $a =~ ^[0-9]+$ ]] || a=0
    printf '%s' $(( a * 1024 ))
}

file_size() {   # size of one file in bytes
    local s
    s=$(stat -c %s -- "$1" 2>/dev/null) || s=0
    printf '%s' "$s"
}

# Total bytes of regular files below the given paths (does not follow links).
tree_bytes() {
    local t=0 n
    while IFS= read -r n; do t=$(( t + n )); done < <(find "$@" -type f -printf '%s\n' 2>/dev/null)
    printf '%d' "$t"
}

# Printable, single-line version of an arbitrary file name (control chars and
# escape sequences must never reach the terminal).
# U+200E U+200F U+202A..U+202E U+2066..U+2069 as raw UTF-8 bytes (locale-independent).
readonly BIDI_SET=$'\xe2\x80\x8e\xe2\x80\x8f\xe2\x80\xaa\xe2\x80\xab\xe2\x80\xac\xe2\x80\xad\xe2\x80\xae\xe2\x81\xa6\xe2\x81\xa7\xe2\x81\xa8\xe2\x81\xa9'
disp() {
    local s=$1
    s=${s//[[:cntrl:]]/?}
    # Bidirectional overrides/isolates can make a name look like another one
    # ("Trojan Source", CVE-2021-42574); show them as '?' too.
    # (Only in a UTF-8 locale: there each byte sequence below is one character.)
    if (( UI_UTF8 )) || [[ ${LC_ALL:-} == *[Uu][Tt][Ff]* ]]; then
        s=${s//[$BIDI_SET]/?}
    fi
    printf '%s' "$s"
}

repeat() {   # repeat string count
    local out="" i
    for (( i = 0; i < $2; i++ )); do out+=$1; done
    printf '%s' "$out"
}

# A name that is safe to create in the current directory.
valid_name() {
    local n=$1
    [[ -n $n && $n != . && $n != .. && $n != */* ]] || return 1
    [[ $n != *[[:cntrl:]]* ]] || return 1
    (( ${#n} <= 200 )) || return 1
    return 0
}

path_exists() { [[ -e $1 || -L $1 ]]; }

# Serialise the final "check + rename" step of concurrent linux-archive runs
# in the current directory: flock(1) on a read-only descriptor of the
# directory itself (flock(2) works on directories; no lock file is created).
dir_lock() {
    exec {LOCK_FD}<"." || { LOCK_FD=""; return 1; }
    if ! flock -w 20 "$LOCK_FD"; then
        exec {LOCK_FD}<&-
        LOCK_FD=""
        return 1
    fi
    return 0
}
dir_unlock() {
    if [[ -n $LOCK_FD ]]; then exec {LOCK_FD}<&-; LOCK_FD=""; fi
    return 0
}

# First free "<stem>_N<ext>" in the current directory.
unique_name() {
    local stem=$1 ext=$2 n=2
    while path_exists "./${stem}_${n}${ext}"; do n=$(( n + 1 )); done
    printf '%s_%s%s' "$stem" "$n" "$ext"
}

# ------------------------------------------------------ cleanup & signals
kill_job() {
    [[ -n $JOB_PID ]] || return 0
    if kill -0 "$JOB_PID" 2>/dev/null; then
        kill -TERM -- "-$JOB_PID" 2>/dev/null || kill -TERM "$JOB_PID" 2>/dev/null
        local i
        for i in 1 2 3 4 5; do
            kill -0 "$JOB_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$JOB_PID" 2>/dev/null || true
        wait "$JOB_PID" 2>/dev/null
    fi
    JOB_PID=""
}

# shellcheck disable=SC2329  # reached only from the trap handlers (cleanup, on_signal)
restore_terminal() {
    if [[ $UI_MODE == tui ]]; then
        printf '%s%s' "${T_CNORM:-}" "${T_SGR0:-}"
    fi
    if [[ -n $SAVED_STTY ]]; then
        stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    fi
}

# shellcheck disable=SC2329  # installed with `trap cleanup EXIT`
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP WINCH
    kill_job
    { set +x; } 2>/dev/null      # never trace while wiping secrets on exit
    JOB_SECRET="" Z_PW="" A_PW="" SECRET_IN=""
    if [[ -n $PARTIAL_PATH ]] && is_scratch_name "$PARTIAL_PATH" && path_exists "$PARTIAL_PATH"; then
        rm -rf -- "$PARTIAL_PATH"
    fi
    if [[ -n $WORKDIR && -d $WORKDIR ]]; then rm -rf -- "$WORKDIR"; fi
    restore_terminal
    if [[ -n $EXIT_MSG ]]; then printf '\n%s\n' "$EXIT_MSG"; fi
    exit "$rc"
}

# shellcheck disable=SC2329  # installed with `trap ... INT/TERM/HUP`
on_signal() {   # on_signal <name> <exit-code>
    trap '' INT TERM HUP
    case $CUR_OP in
        create)  EXIT_MSG="Interrupted ($1) - the partial archive was deleted." ;;
        extract) EXIT_MSG="Interrupted ($1) - the partial extraction was deleted." ;;
        *)       EXIT_MSG="Interrupted ($1)." ;;
    esac
    exit "$2"
}

# ======================================================================= UI
SPACES=$(printf '%200s' '')
C_RST="" C_BOLD="" C_DIM="" C_REV="" C_ACC="" C_OK="" C_WARN="" C_ERR="" C_HEAD=""
T_HOME="" T_ED="" T_EL="" T_CIVIS="" T_CNORM="" T_SGR0=""
BOXW=80
BANNER_BUF=""
KEY=""
FIT=""
SCREEN_LINES=()     # content shown above every redraw of the next menus (menus repaint the screen)
PENDING_MSG=()      # messages to show right after the next screen_begin
MENU_INDEX=0
MENU_CHECKED=()
ASK_RESULT=""
SECRET_IN=""
G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|' G_PTR='>' G_OK='[ok]' G_ERR='[x]' G_WARN='[!]' G_INFO='[i]'
G_UP='Up' G_DOWN='Down'

ui_init() {
    UI_MODE=plain
    if (( ! FORCE_PLAIN )) && [[ -t 0 && -t 1 && -n ${TERM:-} && ${TERM:-} != dumb ]] && have tput; then
        T_HOME=$(tput home 2>/dev/null) T_ED=$(tput ed 2>/dev/null) T_EL=$(tput el 2>/dev/null)
        T_CIVIS=$(tput civis 2>/dev/null) T_CNORM=$(tput cnorm 2>/dev/null)
        if [[ -n $T_HOME && -n $T_ED && -n $T_EL && -n $T_CIVIS && -n $T_CNORM ]]; then
            UI_MODE=tui
        fi
    fi
    T_SGR0=$(tput sgr0 2>/dev/null || true)
    if [[ -t 0 ]]; then SAVED_STTY=$(stty -g 2>/dev/null || true); fi
    if (( ! FORCE_NOCOLOR )) && [[ -z ${NO_COLOR:-} && -t 1 ]] && have tput; then
        local n
        n=$(tput colors 2>/dev/null || echo 0)
        if [[ $n =~ ^[0-9]+$ ]] && (( n >= 8 )); then
            C_RST=$T_SGR0 C_BOLD=$(tput bold 2>/dev/null) C_DIM=$(tput dim 2>/dev/null)
            C_REV=$(tput rev 2>/dev/null)
            C_ACC=$(tput setaf 6) C_OK=$(tput setaf 2) C_WARN=$(tput setaf 3)
            C_ERR=$(tput setaf 1) C_HEAD=$(tput setaf 5)
        fi
    fi
    if (( UI_UTF8 )); then
        G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_H='─' G_V='│' G_PTR='❯'
        G_OK='✔' G_ERR='✖' G_WARN='⚠' G_INFO='ℹ' G_UP='↑' G_DOWN='↓'
    fi
    ui_layout
}

ui_layout() {
    # `stty size` asks the terminal on stdin (TIOCGWINSZ); `tput cols` inside
    # $(...) cannot reliably see the terminal (its stdout is a pipe), so it is
    # only the fallback.
    local sz
    sz=$(stty size 2>/dev/null) || sz=""
    if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[2] > 0 )); then
        ROWS=${BASH_REMATCH[1]} COLS=${BASH_REMATCH[2]}
    else
        COLS=$(tput cols 2>/dev/null || echo 80)
        ROWS=$(tput lines 2>/dev/null || echo 24)
    fi
    [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
    [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
    (( COLS < 44 )) && COLS=44
    (( ROWS < 14 )) && ROWS=14
    BOXW=$(( COLS - 1 ))
    (( BOXW > 100 )) && BOXW=100
    build_banner
}

# fit <text> <width>  ->  $FIT, exactly <width> characters (cut / padded).
fit() {
    local s=$1 w=$2 e='~' pad
    (( UI_UTF8 )) && e='…'
    if (( ${#s} > w )); then
        if (( w >= 2 )); then s="${s:0:w-1}$e"; else s=${s:0:w}; fi
    fi
    pad=$(( w - ${#s} ))
    (( pad > 0 )) && s+=${SPACES:0:pad}
    FIT=$s
}

build_banner() {
    local inner=$(( BOXW - 2 )) line1 line2 hl
    hl=$(repeat "$G_H" "$inner")
    fit " LINUX-ARCHIVE  -  terminal archive helper   v$LA_VERSION" "$inner"; line1=$FIT
    fit " folder: $(disp "$PWD")" "$inner"; line2=$FIT
    BANNER_BUF="${C_ACC}${G_TL}${hl}${G_TR}${C_RST}"$'\n'
    BANNER_BUF+="${C_ACC}${G_V}${C_RST}${C_BOLD}${C_HEAD}${line1}${C_RST}${C_ACC}${G_V}${C_RST}"$'\n'
    BANNER_BUF+="${C_ACC}${G_V}${C_RST}${C_DIM}${line2}${C_RST}${C_ACC}${G_V}${C_RST}"$'\n'
    BANNER_BUF+="${C_ACC}${G_BL}${hl}${G_BR}${C_RST}"$'\n'
}

# shellcheck disable=SC2329  # installed with `trap on_winch WINCH`
on_winch() { RESIZED=1; }

msg_ok()   { printf '%s%s%s %s\n' "$C_OK" "$G_OK" "$C_RST" "$*"; }
msg_err()  { printf '%s%s %s%s\n' "$C_ERR" "$G_ERR" "$*" "$C_RST"; }
msg_warn() { printf '%s%s %s%s\n' "$C_WARN" "$G_WARN" "$*" "$C_RST"; }
msg_info() { printf '%s%s%s %s\n' "$C_ACC" "$G_INFO" "$C_RST" "$*"; }

# Menus repaint the whole screen, so text that must stay visible next to a menu
# is collected in SCREEN_LINES (ui_note_*) and drawn by the menu itself.
ui_note()      { SCREEN_LINES+=("$1"); }
ui_note_info() { SCREEN_LINES+=("$(msg_info "$*")"); }
ui_note_warn() { SCREEN_LINES+=("$(msg_warn "$*")"); }
ui_note_err()  { SCREEN_LINES+=("$(msg_err "$*")"); }
ui_note_box()  { local l; while IFS= read -r l; do SCREEN_LINES+=("$l"); done < <(box_print "$@"); }
screen_flush() { local l; for l in "${SCREEN_LINES[@]}"; do printf '%s\n' "$l"; done; SCREEN_LINES=(); }
defer_warn()   { PENDING_MSG+=("$1"); }

screen_begin() {   # screen_begin <title>
    SCREEN_LINES=()
    if [[ $UI_MODE == tui ]]; then
        printf '%s%s%s' "$T_HOME" "$T_ED" "$T_CNORM"
        printf '%s' "$BANNER_BUF"
    else
        printf '\n%s== linux-archive %s  [%s] ==%s\n' "$C_ACC" "$LA_VERSION" "$(disp "$PWD")" "$C_RST"
    fi
    printf '\n%s%s%s\n\n' "$C_BOLD" "$1" "$C_RST"
    local m
    for m in "${PENDING_MSG[@]}"; do msg_warn "$m"; done
    PENDING_MSG=()
}

# Draw a titled box around the given lines.
box_print() {   # box_print <title> <line>...
    local title=$1 inner=$(( BOXW - 2 )) l hl
    shift
    fit " $title " "$(( ${#title} + 2 > inner - 2 ? inner - 2 : ${#title} + 2 ))"
    hl=$(repeat "$G_H" $(( inner - ${#FIT} - 1 )))
    printf '%s%s%s%s%s%s%s%s\n' "$C_ACC" "$G_TL" "$G_H" "$C_RST" "$C_BOLD$FIT$C_RST" "$C_ACC" "$hl" "$G_TR$C_RST"
    for l in "$@"; do
        fit " $(disp "$l")" "$inner"
        printf '%s%s%s%s%s%s%s\n' "$C_ACC" "$G_V" "$C_RST" "$FIT" "$C_ACC" "$G_V" "$C_RST"
    done
    hl=$(repeat "$G_H" "$inner")
    printf '%s%s%s%s%s\n' "$C_ACC" "$G_BL" "$hl" "$G_BR" "$C_RST"
}

# ------------------------------------------------------------------ input
# read_key -> $KEY in: UP DOWN LEFT RIGHT ENTER SPACE ESC BACK HOME END PGUP
# PGDN, a literal character, or "" after the poll timeout (used to notice
# SIGWINCH).  Returns 1 on end of input.
read_key() {
    KEY=""
    local k="" c rest="" rc last
    IFS= read -rsn1 -t 0.4 k
    rc=$?
    if (( rc > 128 )); then return 0; fi
    if (( rc != 0 )); then return 1; fi
    case $k in
        '')       KEY=ENTER ;;
        $'\r')    KEY=ENTER ;;
        ' ')      KEY=SPACE ;;
        $'\x7f'|$'\b') KEY=BACK ;;
        $'\e')
            while IFS= read -rsn1 -t 0.03 c; do
                rest+=$c
                if [[ $c == [A-Za-z~] ]] && (( ${#rest} >= 2 )); then break; fi
            done
            if [[ -z $rest ]]; then KEY=ESC; return 0; fi
            last=${rest: -1}
            case $last in
                A) KEY=UP ;;
                B) KEY=DOWN ;;
                C) KEY=RIGHT ;;
                D) KEY=LEFT ;;
                H) KEY=HOME ;;
                F) KEY=END ;;
                '~') case $rest in
                        '[5~') KEY=PGUP ;;
                        '[6~') KEY=PGDN ;;
                        '[1~'|'[7~') KEY=HOME ;;
                        '[4~'|'[8~') KEY=END ;;
                    esac ;;
            esac
            ;;
        *) KEY=$k ;;
    esac
    return 0
}

die_eof() { EXIT_MSG="Input closed - exiting."; exit 1; }

# ------------------------------------------------------------------ menus
# menu_single <title> <info> <labels-array> <details-array> [start-index]
#   -> $MENU_INDEX ; returns 1 for back/quit
# menu_multi  <title> <info> <labels-array> <details-array>
#   -> MENU_CHECKED[i]=0/1 ; returns 1 for back/quit
menu_single() { menu_run single "$@"; }
menu_multi()  { menu_run multi "$@"; }

menu_run() {
    if [[ $UI_MODE == tui ]]; then menu_tui "$@"; else menu_plain "$@"; fi
}

menu_plain() {
    local mode=$1 title=$2 info=$3
    local -n _L=$4
    local -n _D=$5
    local n=${#_L[@]} i line tok a b ok
    local -a toks
    MENU_CHECKED=()
    for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=0; done
    while :; do
        for line in "${SCREEN_LINES[@]}"; do printf '%s\n' "$line"; done
        printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RST"
        [[ -n $info ]] && printf '%s%s%s\n' "$C_DIM" "$info" "$C_RST"
        for (( i = 0; i < n; i++ )); do
            printf ' %3d) %s' $(( i + 1 )) "$(disp "${_L[i]}")"
            [[ -n ${_D[i]:-} ]] && printf '   %s%s%s' "$C_DIM" "$(disp "${_D[i]}")" "$C_RST"
            printf '\n'
        done
        if [[ $mode == single ]]; then
            printf 'Choose 1-%d  (q = back): ' "$n"
        else
            printf 'Choose numbers e.g. "1 3 5-7", a = all, q = back: '
        fi
        IFS= read -r line || die_eof
        line=${line//,/ }
        [[ $line == [qQ] ]] && return 1
        if [[ $mode == single ]]; then
            if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] && (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= n )); then
                MENU_INDEX=$(( BASH_REMATCH[1] - 1 )); return 0
            fi
        else
            for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=0; done
            ok=1
            if [[ $line == [aA] ]]; then
                for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=1; done
            else
                read -r -a toks <<<"$line"
                for tok in "${toks[@]}"; do
                    if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
                    elif [[ $tok =~ ^[0-9]+$ ]]; then a=$tok b=$tok
                    else ok=0; break; fi
                    if (( a < 1 || b > n || a > b )); then ok=0; break; fi
                    for (( i = a - 1; i < b; i++ )); do MENU_CHECKED[i]=1; done
                done
            fi
            if (( ok )) && [[ ${MENU_CHECKED[*]} == *1* ]]; then return 0; fi
        fi
        msg_warn "Invalid choice."
    done
}

menu_tui() {
    local mode=$1 title=$2 info=$3
    local -n L=$4
    local -n D=$5
    local n=${#L[@]} cur=${6:-0} top=0 vis i dv dw=0 lw inner step dirty=1 nn maxn ninfo=0
    MENU_CHECKED=()
    MENU_FLASH=""
    [[ -n $info ]] && ninfo=1
    for (( i = 0; i < n; i++ )); do
        MENU_CHECKED[i]=0
        dv=${D[i]:-}
        (( ${#dv} > dw )) && dw=${#dv}
    done
    (( cur >= n )) && cur=0
    printf '%s' "$T_CIVIS"
    RESIZED=1
    while :; do
        if (( RESIZED )); then
            # Clear the flag BEFORE measuring: a SIGWINCH that arrives while
            # ui_layout runs sets it again and triggers one more redraw.
            RESIZED=0; ui_layout; dirty=1
            printf '%s' "$T_HOME$T_ED"
        fi
        if (( dirty )); then
            inner=$(( BOXW - 2 ))
            (( dw > inner / 2 )) && dw=$(( inner / 2 ))
            # rows used besides notes and items: banner 4 + blank + title + [info] + 2 borders + flash + footer
            nn=${#SCREEN_LINES[@]}
            maxn=$(( ROWS - 11 - ninfo - (n < 3 ? n : 3) ))
            (( maxn < 0 )) && maxn=0
            (( nn > maxn )) && nn=$maxn
            vis=$(( ROWS - 11 - ninfo - nn ))
            (( vis < 3 )) && vis=3
            (( vis > n )) && vis=$n
            (( cur < top )) && top=$cur
            (( cur >= top + vis )) && top=$(( cur - vis + 1 ))
            menu_draw
            dirty=0
        fi
        read_key || die_eof
        [[ -z $KEY ]] && continue          # poll timeout: only checks RESIZED
        dirty=1
        MENU_FLASH=""
        step=0
        case $KEY in
            UP|k)     (( cur > 0 )) && cur=$(( cur - 1 )) || cur=$(( n - 1 )) ;;
            DOWN|j)   (( cur < n - 1 )) && cur=$(( cur + 1 )) || cur=0 ;;
            PGUP)     cur=$(( cur - vis )); (( cur < 0 )) && cur=0 ;;
            PGDN)     cur=$(( cur + vis )); (( cur >= n )) && cur=$(( n - 1 )) ;;
            HOME|g)   cur=0 ;;
            END|G)    cur=$(( n - 1 )) ;;
            SPACE)
                if [[ $mode == multi ]]; then MENU_CHECKED[cur]=$(( 1 - MENU_CHECKED[cur] ))
                else step=1; fi ;;
            a) if [[ $mode == multi ]]; then for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=1; done; fi ;;
            n) if [[ $mode == multi ]]; then for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=0; done; fi ;;
            i) if [[ $mode == multi ]]; then for (( i = 0; i < n; i++ )); do MENU_CHECKED[i]=$(( 1 - MENU_CHECKED[i] )); done; fi ;;
            ENTER) step=1 ;;
            RIGHT) [[ $mode == single ]] && step=1 ;;
            q|Q|ESC|LEFT|BACK) printf '%s' "$T_CNORM"; return 1 ;;
        esac
        if (( step )); then
            if [[ $mode == single ]]; then
                MENU_INDEX=$cur; printf '%s' "$T_CNORM"; return 0
            elif [[ ${MENU_CHECKED[*]} == *1* ]]; then
                printf '%s' "$T_CNORM"; return 0
            else
                MENU_FLASH="Nothing selected - press Space on an item first."
            fi
        fi
    done
}

MENU_FLASH=""

menu_draw() {   # uses the caller's (menu_tui) locals through dynamic scope
    local buf="" i row inner=$(( BOXW - 2 )) prefix lab detail style hl count
    local plen=3
    [[ $mode == multi ]] && plen=7
    lw=$(( inner - plen - dw - (dw > 0 ? 1 : 0) ))
    buf+=$T_HOME
    buf+=${BANNER_BUF//$'\n'/$T_EL$'\n'}
    buf+=$T_EL$'\n'
    buf+="${C_BOLD}${title}${C_RST}${T_EL}"$'\n'
    if (( ninfo )); then
        fit "$info" "$(( BOXW - 1 ))"
        buf+="${C_DIM}${FIT}${C_RST}${T_EL}"$'\n'
    fi
    for (( i = 0; i < nn; i++ )); do buf+="${SCREEN_LINES[i]}${T_EL}"$'\n'; done
    count=" $(( top + 1 ))-$(( top + vis )) of $n "
    (( n <= vis )) && count=""
    hl=$(repeat "$G_H" $(( inner - ${#count} )))
    buf+="${C_ACC}${G_TL}${count}${hl}${G_TR}${C_RST}${T_EL}"$'\n'
    for (( i = top; i < top + vis; i++ )); do
        if (( i == cur )); then prefix=" $G_PTR "; else prefix="   "; fi
        if [[ $mode == multi ]]; then
            if (( MENU_CHECKED[i] )); then prefix+="[x] "; else prefix+="[ ] "; fi
        fi
        lab=$(disp "${L[i]}")
        fit "$lab" "$lw"; row="$prefix$FIT"
        if (( dw > 0 )); then
            detail=$(disp "${D[i]:-}")
            fit "$detail" "$dw"; row+=" $FIT"
        fi
        fit "$row" "$inner"; row=$FIT
        style=""
        if (( i == cur )); then style=$C_REV$C_BOLD
        elif [[ $mode == multi ]] && (( MENU_CHECKED[i] )); then style=$C_OK; fi
        buf+="${C_ACC}${G_V}${C_RST}${style}${row}${C_RST}${C_ACC}${G_V}${C_RST}${T_EL}"$'\n'
    done
    hl=$(repeat "$G_H" "$inner")
    buf+="${C_ACC}${G_BL}${hl}${G_BR}${C_RST}${T_EL}"$'\n'
    buf+="${C_WARN}${MENU_FLASH}${C_RST}${T_EL}"$'\n'
    if [[ $mode == multi ]]; then
        fit "${G_UP}/${G_DOWN} move  Space toggle  a all  n none  i invert  Enter confirm  q/Esc back" "$(( BOXW - 1 ))"
    else
        fit "${G_UP}/${G_DOWN} move  Enter select  q/Esc back" "$(( BOXW - 1 ))"
    fi
    buf+="${C_DIM}${FIT}${C_RST}${T_EL}"$'\n'
    buf+=$T_ED
    printf '%s' "$buf"
}

# ---------------------------------------------------------------- prompts
confirm() {   # confirm <question> <y|n default>   -> 0 = yes
    local q=$1 def=${2:-n} ans hint='[y/N]'
    [[ $def == y ]] && hint='[Y/n]'
    printf '%s%s%s %s ' "$C_BOLD" "$q" "$C_RST" "$hint"
    if [[ $UI_MODE == tui ]]; then
        IFS= read -rsn1 ans || die_eof
        printf '%s\n' "$ans"
    else
        IFS= read -r ans || die_eof
    fi
    [[ -z $ans ]] && ans=$def
    [[ $ans == [yY]* ]]
}

ask_text() {   # ask_text <label> <default>  -> $ASK_RESULT
    local label=$1 def=${2:-}
    if [[ $UI_MODE == tui ]]; then
        printf '%s' "$T_CNORM"
        IFS= read -e -r -i "$def" -p "$label: " ASK_RESULT || die_eof
    else
        printf '%s [%s]: ' "$label" "$(disp "$def")"
        IFS= read -r ASK_RESULT || die_eof
        [[ -z $ASK_RESULT ]] && ASK_RESULT=$def
    fi
    return 0
}

# Hidden input.  Prompt goes to the terminal, never to a log.
ask_secret() {   # ask_secret <prompt>  -> $SECRET_IN
    printf '%s' "$1" >&2
    IFS= read -rs SECRET_IN || { printf '\n' >&2; return 1; }
    printf '\n' >&2
    return 0
}

# shellcheck disable=SC2120  # the message argument is optional
pause_key() {
    printf '%s%s%s' "$C_DIM" "${1:-Press any key to continue...}" "$C_RST"
    if [[ $UI_MODE == tui ]]; then IFS= read -rsn1 _ || true; else IFS= read -r _ || true; fi
    printf '\n'
}

# ============================================================== job runner
# run_job <label> <command...>
#   * runs the command in its own session (setsid): no /dev/tty, own process
#     group so kill_job can stop the whole tree on Ctrl+C;
#   * STDIN is /dev/null, or - when JOB_SECRET is set - a pipe carrying the
#     secret and nothing else.  The secret is therefore never in argv, never
#     in the environment (JOB_SECRET is not exported) and never on disk;
#   * STDOUT/STDERR go to $JOB_LOG (STDOUT to JOB_STDOUT_FILE if given);
#   * JOB_WATCH_DIR/JOB_WATCH_LIMIT abort the job when the directory grows
#     beyond the limit (zip-bomb / full-disk protection);
#   * JOB_SIZE_FILE is shown as a growing size next to the spinner.
# Result: JOB_RC (99 when aborted by the watchdog), JOB_ABORT ("" | limit).
run_job() {
    local label=$1 out start now elapsed=0 tick=0 frame=0 sz size_txt="" shown=0
    local -a frames
    shift
    if (( UI_UTF8 )); then frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'); else frames=('|' '/' '-' $'\\'); fi
    JOB_LOG="$WORKDIR/job.log"
    : >"$JOB_LOG"
    JOB_ABORT=""
    out=${JOB_STDOUT_FILE:-$JOB_LOG}
    # Optional wall-clock limit (coreutils timeout(1): -k sends KILL after TERM).
    if [[ -n $JOB_TIMEOUT ]] && have timeout; then
        set -- timeout -k 5 "$JOB_TIMEOUT" "$@"
    fi
    # The secret travels through a pipe from the builtin printf (no argv, no
    # environment, no here-string: bash < 5.1 backs here-strings/heredocs with
    # temp files).  Callers hold secret_on, so xtrace is off here.
    if [[ -n $JOB_SECRET ]]; then
        printf '%s\n' "$JOB_SECRET" | setsid "$@" >>"$out" 2>>"$JOB_LOG" &
    else
        setsid "$@" </dev/null >>"$out" 2>>"$JOB_LOG" &
    fi
    JOB_PID=$!
    JOB_SECRET=""
    start=$SECONDS
    [[ $UI_MODE == tui ]] && printf '%s' "$T_CIVIS"
    while kill -0 "$JOB_PID" 2>/dev/null; do
        now=$SECONDS
        elapsed=$(( now - start ))
        tick=$(( tick + 1 ))
        if [[ -n $JOB_WATCH_DIR ]] && (( tick % 3 == 0 )); then
            # Disk usage in KiB (portable `du -s -k`): what fills the disk.
            sz=$(du -s -k -- "$JOB_WATCH_DIR" 2>/dev/null | cut -f1)
            [[ $sz =~ ^[0-9]+$ ]] && sz=$(( sz * 1024 ))
            if [[ $sz =~ ^[0-9]+$ ]] && (( sz > JOB_WATCH_LIMIT )); then
                JOB_ABORT=limit
                kill_job
                break
            fi
        fi
        if [[ -n $JOB_SIZE_FILE ]] && (( tick % 4 == 0 )); then
            size_txt=$(human "$(file_size "$JOB_SIZE_FILE")")
        elif [[ -n $JOB_WATCH_DIR ]] && (( tick % 3 == 0 )); then
            size_txt=$(human "${sz:-0}")
        fi
        if [[ $UI_MODE == tui ]]; then
            if (( elapsed >= 1 || tick > 5 )); then
                frame=$(( (frame + 1) % ${#frames[@]} ))
                printf '\r%s%s%s %s  %s%ds  %s%s%s' "$C_ACC" "${frames[frame]}" "$C_RST" "$label" "$C_DIM" "$elapsed" "$size_txt" "$C_RST" "$T_EL"
                shown=1
            fi
        elif (( ! shown && elapsed >= 2 )); then
            printf '%s ...\n' "$label"
            shown=1
        fi
        sleep 0.1
    done
    if [[ -n $JOB_PID ]]; then
        wait "$JOB_PID" 2>/dev/null
        JOB_RC=$?
        JOB_PID=""
    fi
    if [[ -n $JOB_ABORT ]]; then JOB_RC=99; fi
    JOB_STDOUT_FILE="" JOB_WATCH_DIR="" JOB_WATCH_LIMIT=0 JOB_SIZE_FILE="" JOB_TIMEOUT=""
    if [[ $UI_MODE == tui ]]; then
        (( shown )) && printf '\r%s' "$T_EL"
        printf '%s' "$T_CNORM"
    fi
    return 0
}

job_log_has() { grep -qE -- "$1" "$JOB_LOG" 2>/dev/null; }

# Print the interesting part of the last job's log (sanitised).
job_log_show() {
    local n=${1:-6} line
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        printf '   %s%s%s\n' "$C_DIM" "$(disp "$line")" "$C_RST"
    done < <(grep -vE '^[[:space:]]*$|^7-Zip|^Scanning|^Enter password' "$JOB_LOG" 2>/dev/null | tail -n "$n")
}

# ==================================================================== ZIP
CWD_NAMES=()
# shellcheck disable=SC2034  # filled by list_cwd, handed to the menus by name
CWD_LABELS=() CWD_DETAILS=()
Z_ITEMS=()            # chosen entries, each as "./name" (safe for any name)
Z_SELMODE=single
Z_FMT="" Z_LVL="" Z_LVLNAME="" Z_PW="" Z_NAME="" Z_EXT="" Z_ARC="" Z_TMP="" Z_OVERWRITE=0
Z_CMD=() Z_STDOUT=""
CLI_OP="" CLI_FMT="" CLI_ITEMS=() CLI_DIRECT=0
INVOKED_AS=linux-archive
LV_LABELS=() LV_VALUES=() LV_DEF=0
FMT_IDS=() FMT_LABELS=() FMT_DETAILS=()

# The tool's own scratch/staging/trash folders (mktemp ./.linux-archive.XXXXXX).
# One rule shared by the pickers and the direct argv route: such a name is never
# a selectable item or archive.
is_scratch_name() { [[ ${1##*/} == .linux-archive.* ]]; }

# Fill CWD_* with the entries of the current directory: folders first, hidden
# entries included.  Names are only ever handled as array elements.
# shellcheck disable=SC2034  # CWD_LABELS/CWD_DETAILS are handed to the menus by name
list_cwd() {
    local n i t s off chunk=1000
    local -a all=() dirs=() files=() stats=() part=()
    shopt -s dotglob nullglob
    all=( * )
    shopt -u dotglob nullglob
    for n in "${all[@]}"; do
        is_scratch_name "$n" && continue
        if [[ -d $n && ! -L $n ]]; then dirs+=("$n"); else files+=("$n"); fi
    done
    CWD_NAMES=("${dirs[@]}" "${files[@]}")
    CWD_LABELS=() CWD_DETAILS=()
    for (( off = 0; off < ${#CWD_NAMES[@]}; off += chunk )); do
        mapfile -t part < <(stat -c '%A %s' -- "${CWD_NAMES[@]:off:chunk}" 2>/dev/null)
        stats+=("${part[@]}")
    done
    for (( i = 0; i < ${#CWD_NAMES[@]}; i++ )); do
        n=${CWD_NAMES[i]}
        t=${stats[i]:-}
        s=${t#* }
        case ${t:0:1} in
            d) CWD_LABELS[i]="$n/"; CWD_DETAILS[i]="<DIR>" ;;
            l) CWD_LABELS[i]="$n@"; CWD_DETAILS[i]="<LINK>" ;;
            *) CWD_LABELS[i]=$n; CWD_DETAILS[i]=$(human "${s:-0}") ;;
        esac
    done
}

# ---- format / level tables ------------------------------------------------
fmt_ext() {
    case $1 in
        zip) echo .zip ;; 7z) echo .7z ;; tar) echo .tar ;; tar.gz) echo .tar.gz ;;
        tar.bz2) echo .tar.bz2 ;; tar.xz) echo .tar.xz ;; tar.zst) echo .tar.zst ;;
        squashfs) echo .squashfs ;; gz) echo .gz ;; xz) echo .xz ;; zst) echo .zst ;;
    esac
}

fmt_tools() {
    case $1 in
        zip) echo zip ;; 7z) echo 7z ;; tar) echo tar ;;
        tar.gz) echo tar gzip ;; tar.bz2) echo tar bzip2 ;; tar.xz) echo tar xz ;;
        tar.zst) echo tar zstd ;; squashfs) echo mksquashfs unsquashfs ;;
        gz) echo gzip ;; xz) echo xz ;; zst) echo zstd ;;
    esac
}

# Compression program tar runs for -I (create) - constant strings, no user data.
# `tar -I PROG` runs PROG as the (de)compressor, adding -d when extracting
# (info tar "Using Compression Program").  xz --memlimit-compress=50% is a
# documented percentage limit (man xz); xz lowers threads/preset to fit it.
fmt_tarprog() {
    case $1 in
        tar.gz) echo "gzip -$2" ;;
        tar.bz2) echo "bzip2 -$2" ;;
        tar.xz) echo "xz -T0 -$2 --memlimit-compress=50%" ;;
        tar.zst) echo "zstd -q -T0 -$2" ;;
    esac
}

# fmt_levels <fmt>: fills LV_LABELS / LV_VALUES / LV_DEF; returns 1 when the
# format has no compression level (tar).  Flags verified with each tool's help:
#   zip -0..-9 | 7z -mx=0..9 | gzip/bzip2 -1..-9 | xz -0..-9 | zstd -1..-19
#   mksquashfs -comp gzip -Xcompression-level 1..9
fmt_levels() {
    LV_LABELS=() LV_VALUES=() LV_DEF=0
    case $1 in
        zip)  LV_LABELS=("Store - no compression (-0)" "Fastest (-1)" "Fast (-3)" "Normal (-6)" "Maximum (-9)")
              LV_VALUES=(0 1 3 6 9) LV_DEF=3 ;;
        7z)   LV_LABELS=("Store - no compression (-mx=0)" "Fastest (-mx=1)" "Fast (-mx=3)" "Normal (-mx=5)" "Maximum (-mx=7)" "Ultra (-mx=9)")
              LV_VALUES=(0 1 3 5 7 9) LV_DEF=3 ;;
        tar.gz|gz|tar.bz2)
              LV_LABELS=("Fastest (-1)" "Fast (-3)" "Normal (-6)" "Maximum (-9)")
              LV_VALUES=(1 3 6 9) LV_DEF=2 ;;
        tar.xz|xz)
              LV_LABELS=("Fastest (-0)" "Fast (-3)" "Normal (-6)" "Maximum (-9, needs much RAM)")
              LV_VALUES=(0 3 6 9) LV_DEF=2 ;;
        tar.zst|zst)
              LV_LABELS=("Fastest (-1)" "Normal (-3)" "Good (-9)" "High (-15)" "Maximum (-19, slow)")
              LV_VALUES=(1 3 9 15 19) LV_DEF=1 ;;
        squashfs)
              LV_LABELS=("Fastest (gzip level 1)" "Fast (gzip level 3)" "Normal (gzip level 6)" "Maximum (gzip level 9)")
              LV_VALUES=(1 3 6 9) LV_DEF=3 ;;
        *) return 1 ;;
    esac
    return 0
}

# ---- steps ---------------------------------------------------------------
z_pick_mode() {
    local -a l=("Single item   - one file or folder" "Multiple items - tick several with Space")
    screen_begin "ZIP  -  step 1: selection mode"
    menu_single "Selection mode" "How many items do you want to put in the archive?" l NOARR 0 || return 1
    if (( MENU_INDEX == 0 )); then Z_SELMODE=single; else Z_SELMODE=multi; fi
}

z_pick_items() {
    local i
    Z_ITEMS=()
    list_cwd
    if (( ${#CWD_NAMES[@]} == 0 )); then
        screen_begin "ZIP"
        msg_warn "This folder is empty - nothing to compress."
        pause_key
        return 1
    fi
    if [[ $Z_SELMODE == single ]]; then
        menu_single "Choose the item to compress" "Enter = select   (folders are included recursively)" CWD_LABELS CWD_DETAILS 0 || return 1
        Z_ITEMS=("./${CWD_NAMES[MENU_INDEX]}")
    else
        menu_multi "Choose the items to compress" "Space = toggle   a = all   Enter = confirm" CWD_LABELS CWD_DETAILS || return 1
        for (( i = 0; i < ${#CWD_NAMES[@]}; i++ )); do
            (( MENU_CHECKED[i] )) && Z_ITEMS+=("./${CWD_NAMES[i]}")
        done
    fi
    return 0
}

z_single_regular_file() {   # exactly one selected item and it is a regular file
    (( ${#Z_ITEMS[@]} == 1 )) && [[ -f ${Z_ITEMS[0]} && ! -L ${Z_ITEMS[0]} ]]
}
