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
# The tool's own scratch/staging/trash folders (mktemp ./.linux-archive.XXXXXX).
# One rule shared by the pickers and the direct argv route: such a name is never
# a selectable item or archive.
is_scratch_name() { [[ ${1##*/} == .linux-archive.* ]]; }
