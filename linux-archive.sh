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
