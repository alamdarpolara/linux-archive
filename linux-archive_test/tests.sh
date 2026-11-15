#!/usr/bin/env bash
#
# tests.sh - linux-archive test-suite (not a deliverable).  Runs as a NORMAL
# user; everything happens inside $T (default: ~/la_work, i.e. inside the test
# container - the repository itself can be mounted read-only).  Usage:
#     ONLY=matrix,cli ./tests.sh   (sections: static cli matrix single extract
#                                   negative overwrite security leak pty)
# shellcheck disable=SC2154  # PRETTY_NAME from os-release; LA_RC from sourced lib.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LA=${LA:-$HERE/../linux-archive.sh}
T=${T:-$HOME/la_work}
ONLY=${ONLY:-all}
export LC_ALL=C.UTF-8
unset NO_COLOR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

want() { [[ $ONLY == all || ,$ONLY, == *,"$1",* ]]; }

rm -rf -- "$T"
mkdir -p -- "$T"/{parent,ex,tmp,single,samples,neg}
export TMPDIR=$T/tmp          # linux-archive's private work dir lives here: easy leak checks
export LA_OUT=$T/last.out
LA=$(readlink -f -- "$LA")

echo "linux-archive test run: $(date -u +%FT%TZ)  $(. /etc/os-release; echo "$PRETTY_NAME")  bash $BASH_VERSION  user $(id -un)"
SZB=$(command -v 7zz || command -v 7z || command -v 7za)
echo "7-Zip: $SZB  $("$SZB" 2>&1 | grep -m1 -E '7-Zip|p7zip')"
SZ_HAS_RAR=0; "$SZB" i 2>/dev/null | sed -n '/^Codecs:/,/^Hashers:/p' | grep -q ' Rar5$' && SZ_HAS_RAR=1
echo "tools: $(tar --version | head -1) | $(bsdtar --version 2>&1 | head -1) | file $(file --version 2>&1 | head -1)"

# ------------------------------------------------------------------ static
if want static; then
    t_section "static checks / CLI"
    check "bash -n linux-archive.sh" "syntax error" bash -n "$LA"
    check "bash -n setup.sh / uninstall_setup.sh" "syntax error" bash -c "bash -n '$HERE/../setup.sh' && bash -n '$HERE/../uninstall_setup.sh'"
    check "sh -n install.sh (POSIX sh)" "syntax error" sh -n "$HERE/../install.sh"
    if command -v shellcheck >/dev/null; then
        sc=$(shellcheck -S style -o all "$LA" "$HERE/../setup.sh" "$HERE/../uninstall_setup.sh" 2>&1; shellcheck -s sh -S style -o all "$HERE/../install.sh" 2>&1)
        if [[ -z $sc ]]; then t_ok "shellcheck -S style -o all on all four scripts: no findings"; else t_bad "shellcheck" "$(head -n 5 <<<"$sc")"; fi
    else t_skip "shellcheck (in this container)" "not installed here - run centrally by run_all.sh"; fi
    # secrets: never in a here-string/heredoc (bash < 5.1 backs them with temp files)
    if ! grep -nE '<<<?.*(_PW|SECRET|PASS)' "$LA" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then t_ok "no password variable is ever fed through a here-string/heredoc"; else t_bad "here-string with secret" "$(grep -nE '<<<?.*(_PW|SECRET|PASS)' "$LA" | head -3)"; fi
    check "environment hardening present at the top (PATH, BASH_ENV, SHELLOPTS, TAR_OPTIONS)" "" bash -c "head -n 80 '$LA' | grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' && head -n 80 '$LA' | grep -q 'unset -v BASH_ENV ENV CDPATH' && head -n 80 '$LA' | grep -q 'export -n SHELLOPTS BASHOPTS' && head -n 80 '$LA' | grep -q 'TAR_OPTIONS'"
    check "--version" "" bash -c "'$LA' --version | grep -q '^linux-archive '"
    # Hermetic: --verify reads a fixed manifest path, so a host that really has
    # linux-archive installed would answer 0/1 instead of 2.  Use a copy of the
    # script whose manifest constant points at a path that does not exist; the
    # check fails if the constant was not found (the copy would be the real one).
    mkdir -p -- "$T/hermetic"
    HCOPY=$T/hermetic/linux-archive.sh
    sed 's|^readonly MANIFEST=.*|readonly MANIFEST=/nonexistent/linux-archive-test/manifest|' "$LA" >"$HCOPY"; chmod 755 "$HCOPY"
    check "--verify without an installation: clear message, exit 2" "" bash -c "grep -q '^readonly MANIFEST=/nonexistent/' '$HCOPY' && '$HCOPY' --verify >/dev/null 2>'$T/hermetic/verify.err'; [[ \$? == 2 ]] && grep -q 'not installed with setup.sh' '$T/hermetic/verify.err'"
    # Nothing may run after main returns: append a marker command to a copy and
    # check that the informational/usage paths keep their exit status and never
    # reach the marker (a tampered or concatenated script must not run extra code).
    XCOPY=$T/hermetic/appended.sh
    { cat -- "$HCOPY"; printf '%s\n' 'echo APPENDED_AFTER_MAIN'; } >"$XCOPY"; chmod 755 "$XCOPY"
    bad_paths=""
    for pair in "--version:0" "--help:0" "--verify:2" "--bogus:2" "zip --bogus:2" "nosuchsub:2"; do
        # shellcheck disable=SC2086  # the pair's first field is 1-2 words on purpose
        out=$("$XCOPY" ${pair%:*} 2>&1); rc=$?
        if (( rc != ${pair##*:} )) || grep -q APPENDED_AFTER_MAIN <<<"$out"; then bad_paths+=" [${pair%:*} rc=$rc]"; fi
    done
    if [[ -z $bad_paths ]]; then t_ok "nothing runs after main returns: exit status preserved on --version/--help/--verify/usage errors"; else t_bad "nothing runs after main returns: exit status preserved on --version/--help/--verify/usage errors" "$bad_paths"; fi
    check "--help" "" bash -c "'$LA' --help | grep -q 'Usage: linux-archive'"
    check "--check lists tools" "" bash -c "'$LA' --check | grep -q 'dependency check'"
    "$LA" --bogus >/dev/null 2>&1; rc=$?
    if (( rc == 2 )); then t_ok "unknown option -> exit 2"; else t_bad "unknown option" "rc=$rc"; fi
    check "header: #!/usr/bin/env bash + set -uo pipefail" "" bash -c "head -n1 '$LA' | grep -qx '#!/usr/bin/env bash' && grep -qx 'set -uo pipefail' '$LA'"
    check "no eval in linux-archive.sh" "found eval" bash -c "! grep -nE '(^|[^a-zA-Z_])eval[ (]' '$LA' | grep -v '^[0-9]*:#'"
    check "no 'ls' parsing in linux-archive.sh" "" bash -c "! grep -nE '\\bls\\b' '$LA' | grep -vE '^[0-9]*:[[:space:]]*#' | grep -qE '\\$\\(ls|\\| *ls|ls .*\\|'"
fi

# --------------------------------------------------------- direct CLI routes
if want cli; then
    # shellcheck source=test_subcommands.sh
    . "$HERE/test_subcommands.sh"
fi

# ------------------------------------------------------------ data + matrix
if want matrix || want leak || want overwrite; then
    make_data "$T/parent/data"
    echo "data set: $(find "$T/parent/data" | wc -l) entries, $(du -sh "$T/parent/data" | cut -f1)"
fi
DIDX=1

verify_level_flag() {   # verify_level_flag <fmt> <lvl#> <archive> [password]: did the level flag reach the tool?
    local fmt=$1 l=$2 arc=$3 pw=${4:--} b out
    if [[ $pw != - ]]; then
        out=$(printf '%s\n' "$pw" | (7zz l -slt "$arc" 2>/dev/null || 7z l -slt "$arc" 2>/dev/null))
        case $fmt:$l in
            zip:1) [[ $out == *'Path = data/bin/zeros.bin'*'Method = AES-256 Store'* ]] ;;
            zip:2|zip:5) [[ $out == *'Method = AES-256 Deflate'* ]] ;;
            7z:1) [[ $out == *'Method = Copy 7zAES'* ]] ;;
            *) return 0 ;;
        esac
        return
    fi
    case $fmt:$l in
        zip:1|zip:2|zip:5)
            out=$(unzip -v "$arc" 2>/dev/null | grep 'bin/zeros.bin')   # 1 MiB of zeros: the method shows the level
            case $l in 1) [[ $out == *Stored* ]] ;; 2) [[ $out == *Defl:F* ]] ;; 5) [[ $out == *Defl:X* ]] ;; esac ;;
        7z:1) out=$(7zz l -slt "$arc" 2>/dev/null || 7z l -slt "$arc" 2>/dev/null); [[ $out == *'Method = Copy'* ]] ;;
        gz:1) b=$(od -An -tu1 -j8 -N1 "$arc" | tr -d ' '); [[ $b == 4 ]] ;;
        gz:4) b=$(od -An -tu1 -j8 -N1 "$arc" | tr -d ' '); [[ $b == 2 ]] ;;
        *) return 0 ;;
    esac
}
t_summary
exit $(( FAIL > 0 ))
