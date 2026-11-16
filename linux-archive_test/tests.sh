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

if want matrix; then
    t_section "create + extract matrix (formats x levels x password), verified with sha256 + modes + symlinks"
    PW='P@ss wörd "q" $x \back 日本!'
    PW_ASCII='P@ss word "q" $x \back !'
    for fmt in zip 7z tar tar.gz tar.bz2 tar.xz tar.zst squashfs; do
        n=$(fmt_nlevels "$fmt"); ext=$(fmt_ext "$fmt")
        levels=(-); if (( n > 0 )); then mapfile -t levels < <(seq 1 "$n"); fi
        pws=(-)
        [[ $fmt == 7z ]] && pws=(- "$PW")
        [[ $fmt == zip ]] && pws=(- "$PW_ASCII")
        for lvl in "${levels[@]}"; do
            for pw in "${pws[@]}"; do
                tag=""; [[ $pw != - ]] && tag="_pw"
                name="out_${fmt}_L${lvl}${tag}${ext}"
                id="matrix $fmt level#$lvl$([[ $pw != - ]] && echo ' +password')"
                zip_run "$T/parent" single "$DIDX" "$fmt" "$lvl" "$pw" "$name"
                if [[ ! -s $T/parent/$name ]] || ! grep -q 'Archive created and verified' "$LA_OUT"; then
                    t_bad "$id: create" "rc=$LA_RC $(tail -n 5 "$LA_OUT" | tr '\n' '|')"; continue
                fi
                if ! no_leftovers "$T/parent"; then t_bad "$id: create" "temp leftovers"; continue; fi
                if ! verify_level_flag "$fmt" "$lvl" "$T/parent/$name" "$pw"; then t_bad "$id: level flag effect" "unexpected archive properties"; fi
                d="$T/ex/$name"; mkdir -p "$d"; ln "$T/parent/$name" "$d/$name"
                enc=none
                if [[ $pw != - ]]; then if [[ $fmt == 7z ]]; then enc=header; else enc=data; fi; fi
                unzip_run "$d" "$enc" "$pw" 2
                out="$d/${name%"$ext"}"
                if [[ -d $out/data ]] && same_tree "$out/data" "$T/parent/data"; then t_ok "$id: create+extract identical"
                else t_bad "$id: extract/compare" "rc=$LA_RC $(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
            done
        done
    done
fi

if want single; then
    t_section "single-file formats gz / xz / zst (levels)"
    head -c 300000 /dev/urandom | base64 > "$T/single/report.txt"
    for fmt in gz xz zst; do
        n=$(fmt_nlevels "$fmt"); ext=$(fmt_ext "$fmt")
        for lvl in $(seq 1 "$n"); do
            name="report.txt_L${lvl}${ext}"
            id="single $fmt level#$lvl"
            zip_run "$T/single" single "$(index_of "$T/single" report.txt)" "$fmt" "$lvl" - "$name"
            if [[ ! -s $T/single/$name ]] || ! grep -q 'Archive created and verified' "$LA_OUT"; then
                t_bad "$id: create" "rc=$LA_RC $(tail -n 5 "$LA_OUT" | tr '\n' '|')"; continue
            fi
            verify_level_flag "$fmt" "$lvl" "$T/single/$name" || t_bad "$id: level flag effect" ""
            d="$T/ex/single_$name"; mkdir -p "$d"; ln "$T/single/$name" "$d/$name"
            unzip_run "$d" none -
            out="$d/${name%"$ext"}/report.txt_L${lvl}"
            if cmp -s "$T/single/report.txt" "$out"; then t_ok "$id: create+extract identical"
            else t_bad "$id: extract/compare" "rc=$LA_RC $(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
        done
    done
    # gz/xz/zst are offered only for exactly one regular file
    la_run "$T/parent" 1 1 "$DIDX" 3   # Zip, single item, the data folder, then back out
    if ! grep -q 'gzip  (single file)' "$LA_OUT"; then t_ok "single-file formats NOT offered for a folder"; else t_bad "single-file formats hidden for folders" ""; fi
    la_run "$T/single" 1 1 "$(index_of "$T/single" report.txt)" 3
    if grep -q 'gzip  (single file)' "$LA_OUT"; then t_ok "single-file formats offered for one regular file"; else t_bad "single-file formats offered for a file" ""; fi
fi

# -------------------------------------------------------- multi-select zip
if want matrix; then
    t_section "multi-select + tricky names"
    mkdir -p "$T/multi"; rm -rf "$T/multi"/*
    cd "$T/multi" || exit 1
    printf 'a\n' > a.txt; printf 'b\n' > "-b dash.txt"; printf 'c\n' > $'c\nnl.txt'; mkdir "d ir"; printf 'd\n' > "d ir/x"
    ln -s a.txt lnk
    cd "$T" || exit 1
    # entries: dirs first: "d ir"=1 ; files: -b dash.txt=2 a.txt=3 c\nnl=4 lnk=5 (glob order, C.UTF-8)
    zip_run "$T/multi" multi "1 2 3 4 5" tar.gz 3 - multi_all.tar.gz
    if [[ -s $T/multi/multi_all.tar.gz ]] && [[ $(tar -tzf "$T/multi/multi_all.tar.gz" | wc -l) -ge 6 ]]; then t_ok "multi-select: 5 items archived"; else t_bad "multi-select tar.gz" "$(tail -n 4 "$LA_OUT" | tr '\n' '|')"; fi
    zip_run "$T/multi" multi "2 4" zip 4 - multi_two.zip
    if [[ -s $T/multi/multi_two.zip ]] && [[ $(unzip -Z1 "$T/multi/multi_two.zip" | wc -l) -eq 2 ]]; then t_ok "multi-select: only the ticked items (2) are in the zip"; else t_bad "multi-select subset" "$(unzip -Z1 "$T/multi/multi_two.zip" 2>&1 | head -3 | tr '\n' '|')"; fi
fi

# ------------------------------------------------ unusual folder / archive names
if want matrix; then
    t_section "unusual working-folder and archive names"
    WD="$T/we ird 'q' \"dq\" ünï 日本 -d"
    mkdir -p "$WD"; printf 'content\n' > "$WD/f.txt"
    zip_run "$WD" single 1 tar.gz 3 - "my arc 'x'.tar.gz"
    if [[ -s "$WD/my arc 'x'.tar.gz" ]] && no_leftovers "$WD"; then t_ok "create in a folder whose name has spaces, quotes, unicode and a leading dash-word"; else t_bad "weird cwd create" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    mkdir -p "$T/we ird ex"; cp "$WD/my arc 'x'.tar.gz" "$T/we ird ex/"
    unzip_run "$T/we ird ex" none -
    if [[ $(cat "$T/we ird ex/my arc 'x'/f.txt" 2>/dev/null) == content ]]; then t_ok "extract an archive with spaces/quotes in its name -> folder 'my arc 'x''"; else t_bad "weird archive name" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
fi

# ------------------------------------------------------ extract-only formats
mk_samples() {
    local s=$T/samples ss=$T/ssrc
    # Fix the umask so generated samples compare consistently across hosts
    # (the invoking user's umask is often 0002).
    rm -rf "$ss"
    (
        umask 022
        mkdir -p "$ss/src/sub" "$ss/src/emptyd"
        printf 'alpha\n' > "$ss/src/a.txt"; printf 'beta\n' > "$ss/src/sub/b.txt"; chmod 600 "$ss/src/sub/b.txt"
        ln -s a.txt "$ss/src/lnk"
    )
    cd "$ss" || return 1
    tar -cf "$s/s.tar" src
    gzip -c "$s/s.tar" > "$s/s.tar.gz"; cp "$s/s.tar.gz" "$s/s.tgz"
    bzip2 -c "$s/s.tar" > "$s/s.tar.bz2"
    xz -c "$s/s.tar" > "$s/s.tar.xz"
    zstd -q -c "$s/s.tar" > "$s/s.tar.zst"
    lz4 -q -c "$s/s.tar" > "$s/s.tar.lz4"
    xz --format=lzma -c "$s/s.tar" > "$s/s.tar.lzma"
    for c in gz:gzip bz2:bzip2 xz:xz zst:zstd lz4:lz4 lzma:xz; do
        ext=${c%%:*}
        case $ext in
            gz) gzip -c src/a.txt > "$s/single.txt.gz" ;;
            bz2) bzip2 -c src/a.txt > "$s/single.txt.bz2" ;;
            xz) xz -c src/a.txt > "$s/single.txt.xz" ;;
            zst) zstd -q -c src/a.txt > "$s/single.txt.zst" ;;
            lz4) lz4 -q -c src/a.txt > "$s/single.txt.lz4" ;;
            lzma) xz --format=lzma -c src/a.txt > "$s/single.txt.lzma" ;;
        esac
    done
    zip -q -r -y "$s/s.zip" src; cp "$s/s.zip" "$s/s.jar"; cp "$s/s.zip" "$s/s.war"; cp "$s/s.zip" "$s/s.apk"
    (7zz a -snl -bd "$s/s.7z" src || 7z a -snl -bd "$s/s.7z" src) >/dev/null 2>&1
    command -v xorriso >/dev/null && xorriso -as mkisofs -quiet -R -J -o "$s/s.iso" . >/dev/null 2>&1
    mksquashfs src "$s/s.squashfs" -keep-as-directory -no-progress -noappend >/dev/null 2>&1
    find src | cpio -o -H newc --quiet > "$s/s.cpio" 2>/dev/null
    ar rcs "$s/s.a" src/a.txt src/sub/b.txt
    command -v gcab >/dev/null && gcab -c "$s/s.cab" src/a.txt src/sub/b.txt >/dev/null 2>&1
    mkdir -p "$T/debroot/DEBIAN" "$T/debroot/usr/share/la"
    printf 'Package: la-test\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@example.org>\nDescription: t\n' > "$T/debroot/DEBIAN/control"
    printf 'hi\n' > "$T/debroot/usr/share/la/f"
    dpkg-deb --build "$T/debroot" "$s/s.deb" >/dev/null 2>&1
    if command -v rpmbuild >/dev/null; then
        mkdir -p "$T/rb"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}
        cat > "$T/rb/SPECS/t.spec" <<'SPEC'
Name: latest
Version: 1.0
Release: 1
Summary: t
License: MIT
BuildArch: noarch
%description
t
%install
mkdir -p %{buildroot}/usr/share/latest
echo hello > %{buildroot}/usr/share/latest/f.txt
ln -s f.txt %{buildroot}/usr/share/latest/lnk
%files
/usr/share/latest
SPEC
        rpmbuild --define "_topdir $T/rb" -bb "$T/rb/SPECS/t.spec" >/dev/null 2>&1
        cp "$T"/rb/RPMS/noarch/*.rpm "$s/s.rpm" 2>/dev/null
    fi
    cd "$T" || return 1
}

extract_sample() {   # extract_sample <file> -> $XD (dir with result)
    local f=$1 b
    b=${f##*/}
    XD=$T/ex/sample_$b
    rm -rf "$XD"; mkdir -p "$XD"; ln "$f" "$XD/$b" 2>/dev/null || cp "$f" "$XD/$b"
    unzip_run "$XD" none -
}

if want extract; then
    t_section "extract-only formats (real archives built with the real tools)"
    mk_samples
    for f in s.tar s.tar.gz s.tgz s.tar.bz2 s.tar.xz s.tar.zst s.tar.lz4 s.tar.lzma s.zip s.jar s.war s.apk s.7z s.iso s.squashfs s.cpio; do
        id="extract $f"
        if [[ ! -s $T/samples/$f ]]; then t_skip "$id" "sample could not be built here"; continue; fi
        extract_sample "$T/samples/$f"
        base=$(cd "$XD" && ls -d -- */ 2>/dev/null | head -n 1); base=${base%/}
        if [[ -n $base && -d $XD/$base/src ]] && same_tree "$XD/$base/src" "$T/ssrc/src"; then t_ok "$id (names, modes, symlink, contents)"
        else t_bad "$id" "rc=$LA_RC $(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    done
    for f in single.txt.gz single.txt.bz2 single.txt.xz single.txt.zst single.txt.lz4 single.txt.lzma; do
        id="extract $f"
        extract_sample "$T/samples/$f"
        out="$XD/single.txt/single.txt"
        if cmp -s "$out" "$T/ssrc/src/a.txt"; then t_ok "$id"; else t_bad "$id" "rc=$LA_RC $(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    done
    # ar / cab / deb / rpm: different layouts
    extract_sample "$T/samples/s.a"
    if cmp -s "$XD/s/a.txt" "$T/ssrc/src/a.txt" && cmp -s "$XD/s/b.txt" "$T/ssrc/src/sub/b.txt"; then t_ok "extract s.a (ar)"; else t_bad "extract s.a (ar)" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    if [[ -s $T/samples/s.cab ]]; then
        extract_sample "$T/samples/s.cab"
        if cmp -s "$XD/s/src/a.txt" "$T/ssrc/src/a.txt" && cmp -s "$XD/s/src/sub/b.txt" "$T/ssrc/src/sub/b.txt"; then t_ok "extract s.cab"; else t_bad "extract s.cab" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    else t_skip "extract s.cab" "skipped: sample could not be built here (gcab unavailable or failed)"; fi
    extract_sample "$T/samples/s.deb"
    if [[ $(cat "$XD/s/usr/share/la/f" 2>/dev/null) == hi && -f $XD/s/DEBIAN/control ]]; then t_ok "extract s.deb (data + control)"; else t_bad "extract s.deb" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    if [[ -s $T/samples/s.rpm ]]; then
        extract_sample "$T/samples/s.rpm"
        if [[ $(cat "$XD/s/usr/share/latest/f.txt" 2>/dev/null) == hello && $(readlink "$XD/s/usr/share/latest/lnk") == f.txt ]]; then t_ok "extract s.rpm (file + symlink)"; else t_bad "extract s.rpm" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    else t_skip "extract s.rpm" "skipped: sample could not be built here (rpmbuild unavailable or failed)"; fi

    # odd archive names: leading dash, newline
    D=$T/ex/odd1; rm -rf "$D"; mkdir -p "$D"; cp "$T/samples/s.zip" "$D/-lead dash.zip"
    unzip_run "$D" none -
    if [[ -f "$D/-lead dash/src/a.txt" ]]; then t_ok "archive named '-lead dash.zip' (leading dash + space) extracts to './-lead dash/'"; else t_bad "leading-dash archive" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    D=$T/ex/odd2; rm -rf "$D"; mkdir -p "$D"; cp "$T/samples/s.zip" "$D/$(printf 'new\nline.zip')"
    unzip_run "$D" none -
    if [[ -f "$D/new_line/src/a.txt" ]]; then t_ok "archive with a NEWLINE in its name: extracted (folder name sanitised to new_line)"; else t_bad "newline archive name" "$(ls -A "$D" | tr '\n' '|') $(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    # a third-party ZipCrypto zip: weak-encryption warning, password still works
    D=$T/ex/zipcrypto; rm -rf "$D"; mkdir -p "$D/src"; echo secret > "$D/src/s.txt"
    ( cd "$D" && printf '%s\n' 'zc-pass' 'zc-pass' | { 7zz a -tzip -mem=ZipCrypto -p -bd zc.zip src >/dev/null 2>&1 || 7z a -tzip -mem=ZipCrypto -p -bd zc.zip src >/dev/null 2>&1; } )
    mkdir -p "$D/x"; mv "$D/zc.zip" "$D/x/"
    unzip_run "$D/x" data zc-pass
    if grep -q 'ZipCrypto' "$LA_OUT" && [[ $(cat "$D/x/zc/src/s.txt" 2>/dev/null) == secret ]]; then t_ok "ZipCrypto zip: weak-encryption warning shown, correct password extracts"; else t_bad "ZipCrypto warning" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi

    # Optional RAR fixtures are excluded from the public tree. Supply them
    # locally only after verifying their redistribution rights.
    # Which backend linux-archive picks here: real unrar > 7-Zip with RAR codec > unar > unrar-free > bsdtar.
    RS=$HERE/samples/rar_dl
    RAR_DECRYPTS=0
    if [[ $(unrar 2>&1 </dev/null) == *UNRAR* ]] || (( SZ_HAS_RAR )); then RAR_DECRYPTS=1; fi
    echo "RAR backend able to decrypt (real unrar or 7-Zip RAR codec): $RAR_DECRYPTS"
    for f in test_read_format_rar5_compressed.rar test_read_format_rar5_stored.rar; do
        if [[ ! -s $RS/$f ]]; then t_skip "extract $f" "skipped: fixture not present"; continue; fi
        extract_sample "$RS/$f"
        if [[ -n $(find "$XD" -type f ! -name '*.rar' -print -quit) ]]; then t_ok "extract $f (RAR5, plain)"
        elif (( ! RAR_DECRYPTS )) && grep -qiE 'failed|nothing was extracted|cannot read' "$LA_OUT" && no_leftovers "$XD" && [[ $(bsdtar --version 2>&1) == *"libarchive 3."[0-3]"."* ]]; then
            t_ok "extract $f: libarchive < 3.4 has no RAR5 reader - clean failure, no leftovers (documented limitation)"
        else t_bad "extract $f" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    done
    for f in test_read_format_rar4_encrypted_filenames.rar test_read_format_rar5_encrypted_filenames.rar; do
        if [[ ! -s $RS/$f ]]; then
            t_skip "extract $f (header-encrypted RAR)" "skipped: fixture not present"
            if (( RAR_DECRYPTS )); then t_skip "wrong password $f" "skipped: fixture not present"; fi
            continue
        fi
        XD=$T/ex/rar_$f; rm -rf "$XD"; mkdir -p "$XD"; cp "$RS/$f" "$XD/"
        if (( RAR_DECRYPTS )); then
            unzip_run "$XD" header password
            n=$(find "$XD" -type f ! -name '*.rar' | wc -l)
            if (( n == 4 )) && grep -q 'password-protected' "$LA_OUT"; then t_ok "extract $f (header-encrypted RAR, password via stdin)"; else t_bad "extract $f" "files=$n $(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
            XD=$T/ex/rarwrong_$f; rm -rf "$XD"; mkdir -p "$XD"; cp "$RS/$f" "$XD/"
            la_run "$XD" 2 1 bad1 bad2 bad3 3
            if grep -q 'Too many wrong passwords' "$LA_OUT" && [[ -z $(find "$XD" -type f ! -name '*.rar' -print -quit) ]] && no_leftovers "$XD"; then t_ok "wrong password x3 on $f -> refused, nothing left"; else t_bad "wrong password $f" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
        else
            la_run "$XD" 2 1 3
            if [[ -z $(find "$XD" -type f ! -name '*.rar' -print -quit) ]] && no_leftovers "$XD" && grep -qE 'cannot|not use it|not supported|refused|Cannot read' "$LA_OUT"; then t_ok "header-encrypted RAR without a decrypting RAR tool: refused honestly, nothing left"; else t_bad "encrypted RAR refusal" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
        fi
    done
    if [[ -s $RS/test_read_format_rar5_encrypted.rar ]]; then
        XD=$T/ex/rar_enc_data; rm -rf "$XD"; mkdir -p "$XD"; cp "$RS/test_read_format_rar5_encrypted.rar" "$XD/"
        if (( RAR_DECRYPTS )); then
            unzip_run "$XD" data password
            if grep -q 'password' "$LA_OUT"; then t_ok "RAR with encrypted file contents: password prompt appears"; else t_bad "RAR data-encrypted prompt" ""; fi
        else
            la_run "$XD" 2 1 1 "" "" 3
            if [[ ! -e $XD/test_read_format_rar5_encrypted/b.txt ]] && no_leftovers "$XD" && grep -qiE 'encrypted|cannot|failed' "$LA_OUT"; then t_ok "RAR with encrypted contents without a decrypting tool: refused/failed cleanly"; else t_bad "data-encrypted RAR refusal" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
        fi
    else
        t_skip "RAR with encrypted file contents" "skipped: fixture not present"
    fi
fi

# ---------------------------------------------------------- negative tests
if want negative; then
    t_section "negative cases"
    N=$T/neg
    mk_neg() { rm -rf "${N:?}/$1"; mkdir -p "$N/$1"; }
    # --- wrong password (7z header-enc + zip AES) and retry that succeeds
    mkdir -p "$T/pwsrc"; printf 'secret data\n' > "$T/pwsrc/s.txt"
    ( cd "$T" && printf '%s\n' 1 1 "$(index_of "$T" pwsrc)" 2 6 2 "good pw" "good pw" "" "" 3 | "$LA" --plain --no-color >"$LA_OUT" 2>&1 )
    mk_neg wp7z; cp "$T/pwsrc.7z" "$N/wp7z/" 2>/dev/null
    la_run "$N/wp7z" 2 1 bad1 bad2 bad3 3
    if grep -q 'Wrong password' "$LA_OUT" && grep -q 'Too many wrong passwords' "$LA_OUT" && [[ ! -d $N/wp7z/pwsrc ]] && no_leftovers "$N/wp7z"; then t_ok "7z (header-encrypted): 3 wrong passwords -> refused, nothing created"; else t_bad "wrong password 7z" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    mk_neg wp7zretry; cp "$T/pwsrc.7z" "$N/wp7zretry/"
    la_run "$N/wp7zretry" 2 1 bad1 "good pw" 1 "" "" 3
    if [[ $(cat "$N/wp7zretry/pwsrc/pwsrc/s.txt" 2>/dev/null) == 'secret data' ]]; then t_ok "7z: wrong password, then the right one -> extracted"; else t_bad "7z retry" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    ( cd "$T" && printf '%s\n' 1 1 "$(index_of "$T" pwsrc)" 1 1 2 "zip pw" "zip pw" "pwsrc_aes.zip" "" 3 | "$LA" --plain --no-color >"$LA_OUT" 2>&1 )
    ( cd "$T" && printf '%s\n' 1 1 "$(index_of "$T" pwsrc)" 1 1 1 "pwsrc_plain.zip" "" 3 | "$LA" --plain --no-color >"$LA_OUT" 2>&1 )
    mk_neg wpzip; cp "$T/pwsrc_aes.zip" "$N/wpzip/"
    la_run "$N/wpzip" 2 1 1 "" bad1 bad2 bad3 "" 3
    if grep -q 'Too many wrong passwords' "$LA_OUT" && [[ ! -d $N/wpzip/pwsrc_aes ]] && no_leftovers "$N/wpzip"; then t_ok "zip AES-256 (data-encrypted): 3 wrong passwords -> refused, nothing created"; else t_bad "wrong password zip" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    # password asked ONLY when needed: plain zip must not prompt
    mk_neg nopw; cp "$T/pwsrc_plain.zip" "$N/nopw/"
    la_run "$N/nopw" 2 1 1 "" "" 3
    if ! grep -qi 'password' "$LA_OUT" && [[ $(cat "$N/nopw/pwsrc_plain/pwsrc/s.txt" 2>/dev/null) == 'secret data' ]]; then t_ok "unencrypted zip: no password prompt, extracted directly"; else t_bad "no prompt for plain zip" "$(grep -i password "$LA_OUT" | head -2)"; fi
    # --- corrupted / truncated
    for kind in zip 7z tar.gz tar.xz tar.zst gz; do
        mk_neg "c_$kind"; src=$T/samples/s.$kind
        [[ $kind == gz ]] && src=$T/samples/single.txt.gz
        [[ $kind == tar.xz || $kind == tar.zst || $kind == tar.gz || $kind == zip || $kind == 7z ]] || true
        [[ -s $src ]] || { t_skip "corrupt $kind" "no sample"; continue; }
        size=$(stat -c %s "$src")
        # corrupt: overwrite bytes in the middle
        cp "$src" "$N/c_$kind/bad.$kind"
        python3 - "$N/c_$kind/bad.$kind" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
m = len(b) // 2
for i in range(m, min(m + 24, len(b))):
    b[i] ^= 0xFF
open(p, 'wb').write(b)
PY
        la_run "$N/c_$kind" 2 1 1 "" "" 3
        if [[ ! -d $N/c_$kind/bad ]] && no_leftovers "$N/c_$kind" && grep -qiE 'fail|cannot read|damaged|error' "$LA_OUT"; then t_ok "corrupted $kind -> clear error, nothing extracted, no leftovers"; else t_bad "corrupted $kind" "rc=$LA_RC dir=$(ls -A "$N/c_$kind" | tr '\n' ' ') $(tail -n 4 "$LA_OUT" | tr '\n' '|')"; fi
        mk_neg "t_$kind"; head -c $(( size * 6 / 10 )) "$src" > "$N/t_$kind/trunc.$kind"
        la_run "$N/t_$kind" 2 1 1 "" "" 3
        if [[ ! -d $N/t_$kind/trunc ]] && no_leftovers "$N/t_$kind" && grep -qiE 'fail|cannot read|damaged|truncated|error' "$LA_OUT"; then t_ok "truncated $kind -> clear error, nothing extracted, no leftovers"; else t_bad "truncated $kind" "rc=$LA_RC dir=$(ls -A "$N/t_$kind" | tr '\n' ' ') $(tail -n 4 "$LA_OUT" | tr '\n' '|')"; fi
    done
    # --- zero-byte, fake and renamed
    mk_neg fake; : > "$N/fake/zero.zip"; echo "just text" > "$N/fake/fake.zip"; echo "text" > "$N/fake/fake.tar.gz"
    head -c 200 /dev/urandom > "$N/fake/fake.7z"; mkdir "$N/fake/folder.zip"; echo x > "$N/fake/plain.txt"
    la_run "$N/fake" 2 3
    if grep -q 'No supported archive' "$LA_OUT" && grep -q 'hidden' "$LA_OUT" || grep -q '4 file(s)' "$LA_OUT"; then t_ok "zero-byte/fake archives are hidden (no supported archive found)"; else t_bad "fake archives hidden" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    cp "$T/samples/s.zip" "$N/fake/data.bin"; cp "$T/samples/s.tar.gz" "$N/fake/notes.txt"
    la_run "$N/fake" 2 q 3
    listing=$(sed -n '/Choose the archive/,/Choose 1-/p' "$LA_OUT")
    if grep -q 'data.bin' <<<"$listing" && grep -q 'notes.txt' <<<"$listing" && ! grep -q 'plain.txt' <<<"$listing" && ! grep -q 'fake\.' <<<"$listing" && ! grep -q 'zero.zip' <<<"$listing" && ! grep -q 'folder.zip' <<<"$listing"; then
        t_ok "unzip list: shows renamed real archives, hides text/fake/zero-byte/folders"
    else t_bad "unzip list filter" "$(echo "$listing" | tr '\n' '|')"; fi
    mk_neg renamed; cp "$T/samples/s.zip" "$N/renamed/data.bin"
    la_run "$N/renamed" 2 1 1 "" "" 3
    if [[ -f $N/renamed/data.bin_extracted/src/a.txt ]]; then t_ok "zip renamed to .bin: detected by content, extracted to data.bin_extracted/"; else t_bad "renamed zip" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
    # --- path traversal / absolute / symlink attacks
    python3 - "$N" <<'PY'
import sys, zipfile, tarfile, io, os
n = sys.argv[1]
def tar(name, ents):
    t = tarfile.open(name, 'w')
    for kind, nm, data in ents:
        ti = tarfile.TarInfo(nm)
        if kind == 'f': ti.size = len(data); t.addfile(ti, io.BytesIO(data))
        elif kind == 'l': ti.type = tarfile.SYMTYPE; ti.linkname = data; t.addfile(ti)
        elif kind == 'h': ti.type = tarfile.LNKTYPE; ti.linkname = data; t.addfile(ti)
    t.close()
for d in ('trav_zip', 'trav_tar', 'abs_zip', 'abs_tar', 'sym_tar', 'sym_zip', 'hard_tar', 'safe_links'):
    os.makedirs(os.path.join(n, d), exist_ok=True)
z = zipfile.ZipFile(n + '/trav_zip/trav.zip', 'w'); z.writestr('../../la_evil_zip.txt', 'EVIL'); z.writestr('ok.txt', 'fine'); z.close()
tar(n + '/trav_tar/trav.tar', [('f', '../../la_evil_tar.txt', b'EVIL'), ('f', 'ok.txt', b'fine')])
z = zipfile.ZipFile(n + '/abs_zip/abs.zip', 'w'); z.writestr('/tmp/la_abs_zip.txt', 'EVIL'); z.writestr('ok.txt', 'fine'); z.close()
tar(n + '/abs_tar/abs.tar', [('f', '/tmp/la_abs_tar.txt', b'EVIL'), ('f', 'ok.txt', b'fine')])
tar(n + '/sym_tar/sym.tar', [('l', 'lnk', '/tmp'), ('f', 'lnk/la_pwned_tar.txt', b'EVIL'), ('f', 'ok.txt', b'fine')])
z = zipfile.ZipFile(n + '/sym_zip/sym.zip', 'w'); zi = zipfile.ZipInfo('lnk'); zi.create_system = 3; zi.external_attr = 0o120777 << 16
z.writestr(zi, '/tmp'); z.writestr('lnk/la_pwned_zip.txt', 'EVIL'); z.writestr('ok.txt', 'fine'); z.close()
tar(n + '/hard_tar/hard.tar', [('h', 'hl', '/etc/passwd'), ('f', 'ok.txt', b'fine')])
tar(n + '/safe_links/links.tar', [('f', 'ok.txt', b'fine'), ('l', 'abs_link', '/etc/hostname'), ('l', 'up_link', '../../etc/passwd'), ('l', 'in_link', 'ok.txt')])
PY
    for c in trav_zip:trav.zip trav_tar:trav.tar abs_zip:abs.zip abs_tar:abs.tar sym_tar:sym.tar sym_zip:sym.zip; do
        d=${c%%:*}; f=${c#*:}
        la_run "$N/$d" 2 1 3
        if grep -q 'Extraction refused for safety' "$LA_OUT" && [[ -z $(find "$N/$d" -mindepth 1 ! -name "$f" -print -quit) ]]; then t_ok "$d: dangerous archive refused, nothing extracted"; else t_bad "$d refused" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    done
    # GNU cpio writes a member name containing LF literally in -tv output.
    # The second line must not be mistaken for an independent safe entry.
    mk_neg cpio_break
    python3 - "$N/cpio_break/break.cpio" <<'PY'
import sys

def record(name, data):
    name = name.encode('utf-8') + b'\0'
    fields = (1, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0)
    header = b'070701' + b''.join(('%08X' % value).encode('ascii') for value in fields)
    head = header + name
    return head + b'\0' * (-len(head) % 4) + data + b'\0' * (-len(data) % 4)

with open(sys.argv[1], 'wb') as archive:
    archive.write(record('ordinary\n/../../tmp/la_cpio_break_proof', b'NOPE'))
    archive.write(record('TRAILER!!!', b''))
PY
    la_run "$N/cpio_break" 2 1 3
    if grep -q 'Extraction refused for safety' "$LA_OUT" && grep -q 'line break' "$LA_OUT" &&
        [[ ! -e /tmp/la_cpio_break_proof && ! -d $N/cpio_break/break ]] && no_leftovers "$N/cpio_break"; then
        t_ok 'cpio member with a line break is refused before extraction'
    else t_bad 'cpio line-break safety' "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    # hard link whose target is /etc/passwd: tar itself strips the '/', linux-archive warns; nothing may be linked
    la_run "$N/hard_tar" 2 1 3
    if grep -q 'Extraction refused for safety' "$LA_OUT" && grep -q 'hard link whose target' "$LA_OUT" && [[ -z $(find "$N/hard_tar" -samefile /etc/passwd 2>/dev/null) && ! -d $N/hard_tar/hard ]] && no_leftovers "$N/hard_tar"; then t_ok "hard link to /etc/passwd: refused (link target outside the archive), nothing extracted"; else t_bad "hard link attack" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    if [[ ! -e /tmp/la_evil_zip.txt && ! -e /tmp/la_evil_tar.txt && ! -e /tmp/la_abs_zip.txt && ! -e /tmp/la_abs_tar.txt && ! -e /tmp/la_pwned_tar.txt && ! -e /tmp/la_pwned_zip.txt && ! -e "$N/la_evil_zip.txt" && ! -e "$T/la_evil_zip.txt" && ! -e "$T/la_evil_tar.txt" ]]; then t_ok "no file escaped the extraction folder (checked /tmp and parents)"; else t_bad "escape check" "a file was written outside"; fi
    # dangerous symlinks: warn + Remove (default)
    la_run "$N/safe_links" 2 1 1 "" 1 "" 3
    if [[ -f $N/safe_links/links/ok.txt && ! -e $N/safe_links/links/abs_link && ! -L $N/safe_links/links/abs_link && ! -L $N/safe_links/links/up_link && -L $N/safe_links/links/in_link ]] && grep -q 'point outside' "$LA_OUT"; then t_ok "dangerous symlinks (absolute, ../ escape) detected and removed; harmless relative link kept"; else t_bad "dangerous symlink handling" "$(ls -la "$N/safe_links/links" 2>&1 | tr '\n' '|') $(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    mk_neg keep_links; cp "$N/safe_links/links.tar" "$N/keep_links/"
    la_run "$N/keep_links" 2 1 1 "" 2 "" 3
    if [[ $(readlink "$N/keep_links/links/abs_link" 2>/dev/null) == /etc/hostname ]]; then t_ok "dangerous symlinks: 'Keep them' keeps the exact original target"; else t_bad "keep symlinks" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    mk_neg abort_links; cp "$N/safe_links/links.tar" "$N/abort_links/"
    la_run "$N/abort_links" 2 1 1 "" 3 "" 3
    if [[ ! -d $N/abort_links/links ]] && no_leftovers "$N/abort_links"; then t_ok "dangerous symlinks: 'Abort' deletes everything extracted"; else t_bad "abort on symlinks" "$(ls -A "$N/abort_links" | tr '\n' ' ')"; fi
    # --- zip bomb (small highly compressed file)
    mk_neg bomb; head -c 314572800 /dev/zero | ( cd "$N/bomb" && zip -q -9 bomb.zip - )
    echo "zip bomb: $(stat -c %s "$N/bomb/bomb.zip") bytes -> 300 MiB"
    la_run "$N/bomb" 2 1 2 3
    if grep -q 'ZIP BOMB' "$LA_OUT" && [[ ! -d $N/bomb/bomb ]] && no_leftovers "$N/bomb"; then t_ok "zip bomb (ratio ~1000:1): warned, default/Cancel extracts nothing"; else t_bad "zip bomb warning" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    la_run "$N/bomb" 2 1 1 "" "" 3
    sz=$(stat -c %s "$N/bomb/bomb/-" 2>/dev/null || echo 0)
    if (( sz == 314572800 )); then t_ok "zip bomb: 'Extract anyway' honoured when the user insists (size verified)"; else t_bad "zip bomb forced extract" "size=$sz"; fi
    # --- 7-Zip cannot do non-ASCII ZIP passwords: refused up front with an explanation
    mk_neg zipuni; echo data > "$N/zipuni/f.txt"
    la_run "$N/zipuni" 1 1 1 1 4 2 "pässwörd" "pässwörd" q q q q q 3
    if grep -q 'only plain ASCII' "$LA_OUT" && [[ ! -e $N/zipuni/f.txt.zip ]] && no_leftovers "$N/zipuni"; then t_ok "zip + non-ASCII password: refused up front with an explanation (7z format accepts it)"; else t_bad "zip unicode password" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
fi

# ---------------------------------------------- overwrite / rename / skip
if want overwrite; then
    t_section "existing output: Overwrite / Rename / Skip (create and extract)"
    P=$T/parent
    zip_run "$P" single "$DIDX" tar - - exist.tar            # first creation
    mkdir -p "$T/ow"; cp -r "$P/data/docs" "$T/ow/";
    # Overwrite
    zip_run "$P" single "$DIDX" tar.gz 3 - exist.tar.gz; zip_run "$P" single "$DIDX" tar.gz 3 - exist.tar.gz overwrite
    if grep -q 'already exists' "$LA_OUT" && grep -q 'Archive created and verified' "$LA_OUT" && [[ -s $P/exist.tar.gz ]] && [[ ! -e $P/exist_2.tar.gz ]]; then t_ok "create: Overwrite replaces the file"; else t_bad "create overwrite" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    # Rename
    zip_run "$P" single "$DIDX" tar.gz 3 - exist.tar.gz rename
    if [[ -s $P/exist_2.tar.gz && -s $P/exist.tar.gz ]]; then t_ok "create: Rename writes exist_2.tar.gz and keeps the original"; else t_bad "create rename" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    # Skip
    h1=$(sha256sum "$P/exist.tar.gz" | cut -d' ' -f1); before=$(ls "$P" | wc -l)
    zip_run "$P" single "$DIDX" tar.gz 3 - exist.tar.gz skip
    h2=$(sha256sum "$P/exist.tar.gz" | cut -d' ' -f1); after=$(ls "$P" | wc -l)
    if [[ $h1 == "$h2" && $before == "$after" ]] && no_leftovers "$P"; then t_ok "create: Skip leaves everything untouched"; else t_bad "create skip" "before=$before after=$after"; fi
    # output name equal to a selected item -> refused
    zip_run "$P" single "$(index_of "$P" exist.tar)" tar - exist.tar q q q
    # (answers after the refusal are extra; the point is that the item was never overwritten)
    if [[ $(stat -c %s "$P/exist.tar") -gt 1000 ]]; then t_ok "create: archive can never replace its own source item"; else t_bad "self-overwrite guard" ""; fi
    # extraction: destination exists
    D=$T/ex/ow_extract; rm -rf "$D"; mkdir -p "$D/zz_old"; cp "$T/samples/s.zip" "$D/zz.zip"; mkdir -p "$D/zz"; echo OLD > "$D/zz/old.txt"
    # menu entries sorted: folders first; archive is the only archive -> index 1
    la_run "$D" 2 1 1 "" 1 y "" 3        # review=Extract, dest default 'zz' exists -> Overwrite -> confirm y
    if [[ -f $D/zz/src/a.txt && ! -e $D/zz/old.txt ]]; then t_ok "extract: Overwrite replaces the existing folder (after confirmation)"; else t_bad "extract overwrite" "$(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    D=$T/ex/ow_extract2; rm -rf "$D"; mkdir -p "$D/zz"; cp "$T/samples/s.zip" "$D/zz.zip"; echo OLD > "$D/zz/old.txt"
    la_run "$D" 2 1 1 "" 1 y "" 3; rm -rf "$D/zz"; mkdir -p "$D/zz"; echo OLD > "$D/zz/old.txt"
    la_run "$D" 2 1 1 "" 2 "" "" 3
    if [[ -f $D/zz_2/src/a.txt && -f $D/zz/old.txt ]]; then t_ok "extract: Rename extracts to zz_2 and keeps the old folder"; else t_bad "extract rename" "$(ls -A "$D" | tr '\n' ' ') $(tail -n 8 "$LA_OUT" | tr '\n' '|')"; fi
    D=$T/ex/ow_extract3; rm -rf "$D"; mkdir -p "$D/zz"; cp "$T/samples/s.zip" "$D/zz.zip"; echo OLD > "$D/zz/old.txt"
    la_run "$D" 2 1 1 "" 3 3
    if [[ ! -d $D/zz/src && -f $D/zz/old.txt ]] && no_leftovers "$D"; then t_ok "extract: Skip leaves the existing folder untouched, nothing extracted"; else t_bad "extract skip" "$(ls -A "$D" | tr '\n' ' ')"; fi
    D=$T/ex/ow_extract4; rm -rf "$D"; mkdir -p "$D/zz"; cp "$T/samples/s.zip" "$D/zz.zip"; echo OLD > "$D/zz/old.txt"
    la_run "$D" 2 1 1 "" 1 n "" 3 3
    if [[ -f $D/zz/old.txt && ! -d $D/zz/src ]]; then t_ok "extract: declining the delete-confirmation keeps the old folder"; else t_bad "extract overwrite decline" "$(ls -A "$D" | tr '\n' ' ')"; fi
fi

# ------------------------------------------------------------- security
if want security; then
    t_section "security: hostile names and environment, symlinked outputs, concurrency, bombs, permissions"
    S=$T/sec; rm -rf "$S"; mkdir -p "$S"
    [[ -s $T/samples/s.zip ]] || mk_samples
    # --- 1. escape sequences / bidi overrides / newlines in names never reach the terminal raw
    mkdir -p "$S/ansi/w" "$S/ansi/x"
    printf 'x\n' > "$S/ansi/w/"$'\e[31mred\e[0m.txt'
    printf 'y\n' > "$S/ansi/w/"$'evil‮gpj.exe'
    printf 'z\n' > "$S/ansi/w/"$'two\nlines\a.txt'
    ( cd "$S/ansi/w" && tar -cf "$S/ansi/x/names.tar" . )
    la_run "$S/ansi/w" 1 2 a q q q 3                       # zip, multi-select list with all names, then back out
    out1=$(cat "$LA_OUT")
    la_run "$S/ansi/x" 2 1 2 q 3                           # unzip: review screen lists the member names
    out2=$(cat "$LA_OUT")
    if [[ $out1$out2 != *$'\e'* && $out1$out2 != *$'‮'* && $out1$out2 != *$'\a'* ]] && grep -q '?\[31mred' <<<"$out1" && grep -q 'red' <<<"$out2"; then
        t_ok "names with ESC sequences, U+202E and control characters are shown sanitised ('?'), never raw (menus and archive preview)"
    else t_bad "terminal-escape sanitising" "$(printf '%s' "$out1$out2" | grep -a -m3 -E 'red|gpj' | od -c | head -n 4 | tr '\n' ' ')"; fi
    # --- 2. hostile environment: BASH_ENV/ENV/CDPATH/IFS/TAR_OPTIONS and a PATH with fake tools first
    E=$S/env; mkdir -p "$E/fakebin" "$E/w" "$E/x"
    for b in 7z 7zz 7za tar gzip zip unzip xz zstd bsdtar file find mv; do
        printf '#!/bin/sh\necho "FAKE %s was executed" >> "%s/marker"\nexit 1\n' "$b" "$E" > "$E/fakebin/$b"; chmod 755 "$E/fakebin/$b"
    done
    printf 'echo "BASH_ENV/ENV sourced by: $0" >> "%s/marker"\n' "$E" > "$E/evil.sh"
    printf 'payload\n' > "$E/w/f.txt"
    ( cd "$E/w" && printf '%s\n' 1 1 1 4 3 "" "" 3 | env BASH_ENV="$E/evil.sh" ENV="$E/evil.sh" CDPATH="$E" IFS=x \
        TAR_OPTIONS=--to-stdout GZIP=-1 XZ_OPT=-0 PATH="$E/fakebin:$PATH" "$LA" --plain --no-color >"$E/out1" 2>&1 )
    cp "$E/w/f.txt.tar.gz" "$E/x/" 2>/dev/null
    ( cd "$E/x" && printf '%s\n' 2 1 1 "" "" 3 | env BASH_ENV="$E/evil.sh" ENV="$E/evil.sh" CDPATH="$E" IFS=x \
        TAR_OPTIONS=--to-stdout PATH="$E/fakebin:$PATH" "$LA" --plain --no-color >"$E/out2" 2>&1 )
    if [[ -s $E/w/f.txt.tar.gz ]] && grep -q 'Archive created and verified' "$E/out1" && [[ $(cat "$E/x/f.txt/f.txt" 2>/dev/null) == payload ]] && ! grep -q 'FAKE' "$E/marker" 2>/dev/null; then
        t_ok "PATH with fake 7z/tar/gzip/... first: none of them ran (fixed PATH); TAR_OPTIONS=--to-stdout ignored (files really extracted)"
    else t_bad "hostile PATH/TAR_OPTIONS" "$(cat "$E/marker" 2>/dev/null | head -3 | tr '\n' '|') $(tail -n 4 "$E/out2" | tr '\n' '|')"; fi
    if ! grep -q 'linux-archive-pipe' "$E/marker" 2>/dev/null; then t_ok "BASH_ENV/ENV are NOT inherited by child shells (the tar.gz listing ran 'bash -c' without sourcing it)"
    else t_bad "BASH_ENV in children" "$(cat "$E/marker")"; fi
    if grep -q 'sourced by: .*linux-archive.sh' "$E/marker" 2>/dev/null; then
        echo "    note: bash itself sources BASH_ENV before line 1 of the repo copy (documented limitation; the installed copy is the same bash behaviour, sudo resets the environment)"
    fi
    # --- 3. a pre-created symlink at the output path is refused (create and extract)
    Y=$S/sym; mkdir -p "$Y/w" "$Y/x" "$Y/outside/vdir"
    echo VICTIM > "$Y/outside/victim.txt"; echo data > "$Y/w/f.txt"
    ln -s "$Y/outside/victim.txt" "$Y/w/f.txt.tar.gz"
    la_run "$Y/w" 1 1 1 4 3 "" "" "" 3
    if grep -q 'symbolic link - refused' "$LA_OUT" && [[ $(cat "$Y/outside/victim.txt") == VICTIM && -L $Y/w/f.txt.tar.gz && -s $Y/w/f.txt_2.tar.gz ]]; then
        t_ok "create: output name that is a symlink to an outside file is refused; victim untouched; renamed to f.txt_2.tar.gz"
    else t_bad "symlinked output (create)" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    cp "$T/samples/s.zip" "$Y/x/s.zip"; ln -s "$Y/outside/vdir" "$Y/x/s"
    la_run "$Y/x" 2 1 1 "" "" "" 3
    if grep -q 'symbolic link - refused' "$LA_OUT" && [[ -z $(ls -A "$Y/outside/vdir") && -f $Y/x/s_2/src/a.txt ]]; then
        t_ok "extract: destination that is a symlink to an outside folder is refused; nothing written there; extracted to s_2/"
    else t_bad "symlinked destination (extract)" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    # --- 4. two concurrent runs creating the same output name
    C=$S/conc; mkdir -p "$C"; head -c 30000000 /dev/urandom > "$C/big.bin"
    ( cd "$C" && printf '%s\n' 1 1 1 4 1 same.tar.gz "" 3 | "$LA" --plain --no-color >"$C/o1" 2>&1 ) &
    p1=$!
    ( cd "$C" && printf '%s\n' 1 1 1 4 1 same.tar.gz "" 3 | "$LA" --plain --no-color >"$C/o2" 2>&1 ) &
    p2=$!
    wait "$p1" "$p2"
    nok=$(cat "$C/o1" "$C/o2" | grep -c 'Archive created and verified')
    nref=$(cat "$C/o1" "$C/o2" | grep -cE 'created meanwhile|already exists')
    if (( nok >= 1 )) && (( nok + nref == 2 )) && tar -tzf "$C/same.tar.gz" 2>/dev/null | grep -qxE '(\./)?big\.bin' && gzip -t "$C/same.tar.gz" && no_leftovers "$C"; then
        t_ok "two concurrent runs writing same.tar.gz: one wins, the other refuses to overwrite; the archive is intact; no temp leftovers"
    else t_bad "concurrent creates" "ok=$nok refused=$nref $(tail -n 3 "$C/o1" | tr '\n' '|') $(tail -n 3 "$C/o2" | tr '\n' '|')"; fi
    # --- 5. hard zip-bomb limit: ratio >= 1000:1 with >= 1 GiB unpacked is refused outright
    B=$S/hardbomb; mkdir -p "$B"
    head -c 1181116006 /dev/zero | ( cd "$B" && zip -q -9 hb.zip - )
    echo "    hard bomb: $(stat -c %s "$B/hb.zip") bytes -> 1.1 GiB"
    la_run "$B" 2 1 3
    if grep -q 'ZIP BOMB - refused' "$LA_OUT" && grep -q 'Extraction refused for safety' "$LA_OUT" && [[ ! -d $B/hb ]] && no_leftovers "$B"; then t_ok "zip bomb above the hard limit (1.1 GiB, ratio ~1000:1): refused outright, no 'extract anyway'"
    else t_bad "hard zip bomb" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    rm -f "$B/hb.zip"
    # --- 6. file-count bomb: more than 1,000,000 members
    FC=$S/countbomb; mkdir -p "$FC"
    python3 - "$FC/many.tar.gz" <<'PY2'
import sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz', compresslevel=1) as t:
    for i in range(1000001):
        ti = tarfile.TarInfo('f%07d' % i); ti.size = 0; t.addfile(ti)
PY2
    la_run "$FC" 2 1 3
    if grep -q 'file-count bomb' "$LA_OUT" && grep -q 'Extraction refused for safety' "$LA_OUT" && no_leftovers "$FC" && [[ ! -d $FC/many ]]; then t_ok "file-count bomb (1,000,001 members): refused before extraction"
    else t_bad "file-count bomb" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    rm -f "$FC/many.tar.gz"
    # --- 7. hard link whose target climbs out ('../'): refused from the listing
    H=$S/hl; mkdir -p "$H"
    python3 - "$H/hl.tar" <<'PY2'
import sys, tarfile, io
t = tarfile.open(sys.argv[1], 'w')
ti = tarfile.TarInfo('ok.txt'); ti.size = 3; t.addfile(ti, io.BytesIO(b'ok\n'))
ti = tarfile.TarInfo('hl'); ti.type = tarfile.LNKTYPE; ti.linkname = '../../outside.txt'; t.addfile(ti)
t.close()
PY2
    la_run "$H" 2 1 3
    if grep -q 'Extraction refused for safety' "$LA_OUT" && grep -q 'hard link whose target' "$LA_OUT" && [[ ! -d $H/hl ]]; then t_ok "hard link with a '../' target: refused (escape attempt), nothing extracted"
    else t_bad "hard link escape" "$(tail -n 6 "$LA_OUT" | tr '\n' '|')"; fi
    # --- 8. setuid / world-writable modes from an archive are not kept
    P=$S/perm; mkdir -p "$P"
    python3 - "$P/perm.zip" <<'PY2'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
for name, mode in (('suid.sh', 0o104777), ('ww.txt', 0o100666), ('sticky', 0o41777)):
    zi = zipfile.ZipInfo(name + ('/' if mode & 0o40000 else '')); zi.create_system = 3; zi.external_attr = mode << 16
    z.writestr(zi, '' if mode & 0o40000 else 'data\n')
z.close()
PY2
    la_run "$P" 2 1 1 "" "" 3
    m1=$(stat -c %a "$P/perm/suid.sh" 2>/dev/null); m2=$(stat -c %a "$P/perm/ww.txt" 2>/dev/null); m3=$(stat -c %a "$P/perm/sticky" 2>/dev/null)
    if [[ -n $m1 && -n $m2 && -n $m3 ]] && ! find "$P/perm" -perm /7000 | grep -q . && ! find "$P/perm" ! -type l -perm -0002 | grep -q .; then
        t_ok "setuid, sticky and world-writable modes from a zip are stripped (modes now: $m1 $m2 $m3)"
    else t_bad "mode sanitising" "modes: $m1 $m2 $m3 $(tail -n 4 "$LA_OUT" | tr '\n' '|')"; fi
fi

# --------------------------------------------------------- password leakage
if want leak; then
    t_section "password leakage proof (ps, /proc/*/cmdline, /proc/*/environ, history, logs, /tmp)"
    SECRET='LaLeakCanary_91c7e2!pw'
    mkdir -p "$T/bigparent/bigdir"
    if [[ ! -s $T/bigparent/bigdir/big.bin ]]; then
        { yes 'linux-archive test line with some compressible text 0123456789' | head -c 20000000; head -c 30000000 /dev/urandom; } > "$T/bigparent/bigdir/big.bin"
    fi
    echo "big file: $(du -h "$T/bigparent/bigdir/big.bin" | cut -f1)"
    STOP=$T/leak.stop; HITS=$T/leak.hits; SEEN=$T/leak.seen
    poller() {
        local psout
        : >"$HITS"; : >"$SEEN"
        while [[ ! -e $STOP ]]; do
            psout=$(ps -eo args= 2>/dev/null)
            grep -aF -f <(printf '%s\n' "$SECRET") <<<"$psout" >>"$HITS"
            grep -qE '(^|/)7z[za]? (a|x|t|l) ' <<<"$psout" && echo 1 >"$SEEN"
            cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -aF -f <(printf '%s\n' "$SECRET") >>"$HITS"
            cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep -aF -f <(printf '%s\n' "$SECRET") >>"$HITS"
            sleep 0.03
        done
    }
    rm -f "$STOP"; poller & PPID_POLL=$!
    if command -v inotifywait >/dev/null; then
        inotifywait -m -r -q -e create -e moved_to --format '%e %w%f' "$TMPDIR" /tmp /var/tmp /dev/shm >"$T/inotify.log" 2>/dev/null &
        PID_INO=$!
    fi
    sleep 0.3
    run_leak() {   # run_leak <desc> <fmt> <level#> <outname> ; creates then extracts with SECRET
        local desc=$1 fmt=$2 lvl=$3 name=$4 ext enc
        ext=$(fmt_ext "$fmt")
        zip_run "$T/bigparent" single 1 "$fmt" "$lvl" "$SECRET" "$name"
        if [[ -s $T/bigparent/$name ]] && grep -q 'Archive created and verified' "$LA_OUT"; then t_ok "leak-run: create $desc"; else t_bad "leak-run: create $desc" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; return; fi
        if grep -qaF -f <(printf '%s\n' "$SECRET") "$LA_OUT"; then t_bad "password absent from linux-archive's own output ($desc create)" "found"; else t_ok "password absent from linux-archive's own output ($desc create)"; fi
        enc=data; [[ $fmt == 7z ]] && enc=header
        local d=$T/ex/leak_$name; rm -rf "$d"; mkdir -p "$d"; ln "$T/bigparent/$name" "$d/$name"
        unzip_run "$d" "$enc" "$SECRET" 2
        if cmp -s "$d/${name%"$ext"}/bigdir/big.bin" "$T/bigparent/bigdir/big.bin" 2>/dev/null; then t_ok "leak-run: extract $desc (50 MB, content identical)"; else t_bad "leak-run: extract $desc" "$(tail -n 5 "$LA_OUT" | tr '\n' '|')"; fi
        if grep -qaF -f <(printf '%s\n' "$SECRET") "$LA_OUT"; then t_bad "password absent from linux-archive's own output ($desc extract)" "found"; else t_ok "password absent from linux-archive's own output ($desc extract)"; fi
    }
    run_leak "7z -mx=9 header-encrypted" 7z 6 leak7.7z
    run_leak "zip AES-256" zip 4 leakz.zip
    # The new argv selection route uses the same hidden prompt and pipe, not a
    # password argument. Keep the process poller running throughout this run.
    ( cd "$T/bigparent" && printf '%s\n' 1 2 "$SECRET" "$SECRET" direct.7z | "$LA" --plain --no-color 7z bigdir >"$T/direct_secret.out" 2>&1 )
    if [[ -s $T/bigparent/direct.7z ]] && ! grep -qaF -f <(printf '%s\n' "$SECRET") "$T/direct_secret.out"; then t_ok 'direct 7z argv route creates encrypted archive without printing password'; else t_bad 'direct 7z password route' "$(tail -n 5 "$T/direct_secret.out" | tr '\n' '|')"; fi
    mkdir -p "$T/direct_unpack"; cp "$T/bigparent/direct.7z" "$T/direct_unpack/"
    ( cd "$T/direct_unpack" && printf '%s\n' "$SECRET" 1 '' | "$LA" --plain --no-color unzip direct.7z >"$T/direct_extract.out" 2>&1 )
    if cmp -s "$T/direct_unpack/direct/bigdir/big.bin" "$T/bigparent/bigdir/big.bin" && ! grep -qaF -f <(printf '%s\n' "$SECRET") "$T/direct_extract.out"; then t_ok 'direct unzip argv route decrypts without printing password'; else t_bad 'direct unzip password route' "$(tail -n 5 "$T/direct_extract.out" | tr '\n' '|')"; fi
    # bash -x: the password must not appear in the xtrace output either
    # (secret sections force xtrace off), neither on stderr nor via BASH_XTRACEFD.
    mkdir -p "$T/xtr"; printf 'traced\n' > "$T/xtr/t.txt"
    ( cd "$T/xtr" && printf '%s\n' 1 1 1 2 3 2 "$SECRET" "$SECRET" "" "" 3 | bash -x "$LA" --plain --no-color >"$T/xtrace.out" 2>&1 )
    mkdir -p "$T/xtr2"; cp "$T/xtr/t.txt.7z" "$T/xtr2/" 2>/dev/null
    ( cd "$T/xtr2" && printf '%s\n' 2 1 "$SECRET" 1 "" "" 3 | BASH_XTRACEFD=7 bash -x "$LA" --plain --no-color >"$T/xtrace2.out" 2>&1 7>"$T/xtrace2.fd" )
    mkdir -p "$T/xtr_direct"; printf 'traced direct\n' > "$T/xtr_direct/t.txt"
    ( cd "$T/xtr_direct" && printf '%s\n' 1 2 "$SECRET" "$SECRET" '' | bash -x "$LA" --plain 7z t.txt >"$T/xtrace_direct.out" 2>&1 )
    if [[ -s $T/xtr_direct/t.txt.7z ]] && ! grep -qaF -f <(printf '%s\n' "$SECRET") "$T/xtrace_direct.out"; then t_ok 'direct 7z route: password absent from bash -x'; else t_bad 'direct password in xtrace' ''; fi
    tlines=$(cat "$T/xtrace.out" "$T/xtrace2.fd" | grep -c '^+')
    if [[ -s $T/xtr/t.txt.7z && $(cat "$T/xtr2/t.txt/t.txt" 2>/dev/null) == traced ]] && (( tlines > 1000 )); then
        t_ok "bash -x runs: encrypted 7z created and extracted while tracing ($tlines trace lines captured)"
    else t_bad "bash -x runs" "lines=$tlines $(tail -n 4 "$T/xtrace2.out" | tr '\n' '|')"; fi
    # negative control: an ordinary traced bash DOES print such a value, so the grep below is meaningful
    # (the value goes in through stdin: the argv poller is running right now)
    ctl=$(printf '%s\n' "$SECRET" | bash -x -c 'read -r pw; [[ -n $pw ]]' 2>&1)
    if grep -qaF -f <(printf '%s\n' "$SECRET") <<<"$ctl"; then t_ok "control: plain 'bash -x' would print the password (the xtrace check is effective)"; else t_bad "xtrace control" ""; fi
    if ! grep -qaF -f <(printf '%s\n' "$SECRET") "$T/xtrace.out" "$T/xtrace2.out" "$T/xtrace2.fd"; then
        t_ok "password NOT in the xtrace output (stderr trace and BASH_XTRACEFD file)"
    else t_bad "xtrace leak" "$(grep -aF -m2 -f <(printf '%s\n' "$SECRET") "$T/xtrace.out" "$T/xtrace2.fd" | cut -c1-120)"; fi
    if grep -q '^+* *secret_on' "$T/xtrace.out" && grep -q 'set +x' "$T/xtrace2.fd"; then t_ok "trace shows secret_on switching xtrace off before the password is handled"; else t_bad "secret_on in trace" ""; fi
    rm -f "$T/xtrace.out" "$T/xtrace2.out" "$T/xtrace2.fd" "$T/xtrace_direct.out"
    touch "$STOP"; wait "$PPID_POLL" 2>/dev/null
    [[ -n ${PID_INO:-} ]] && kill "$PID_INO" 2>/dev/null
    if [[ -s $SEEN ]]; then t_ok "poller really observed the 7z processes while they ran (the check is effective)"; else t_bad "poller effectiveness" "never saw a 7z process"; fi
    if [[ ! -s $HITS ]]; then t_ok "password NOT in 'ps' args, /proc/*/cmdline or /proc/*/environ during create/extract (zip AES + 7z)"; else t_bad "argv/environ leak" "$(head -c 300 "$HITS")"; fi
    hits=$(grep -rlaF -f <(printf '%s\n' "$SECRET") /tmp "$T" "$HOME" /var/tmp /dev/shm 2>/dev/null | grep -v -e "$HITS" -e '/leak\.')
    if [[ -z $hits ]]; then t_ok "password NOT found in files under /tmp, /var/tmp, /dev/shm, \$HOME (incl. shell history) or the test folder"; else t_bad "password on disk" "$hits"; fi
    if [[ -s $T/inotify.log ]]; then
        tmpc=$(grep -c CREATE "$T/inotify.log")
        t_ok "inotifywait watched $TMPDIR, /tmp, /var/tmp, /dev/shm during the runs: $tmpc file creations, none contains the password (scan above)"
    fi
    if ! cat ~/.bash_history ~/.zsh_history 2>/dev/null | grep -qaF -f <(printf '%s\n' "$SECRET"); then t_ok "no shell history file contains the password"; else t_bad "history leak" ""; fi
    check "linux-archive temp dir removed after run" "leftover linux-archive.* in TMPDIR" bash -c "[[ -z \$(find '$T/tmp' -maxdepth 1 -name 'linux-archive.*' -print -quit) ]]"
    # static: JOB_SECRET never exported, password never on a command line
    if grep -q '^export -n JOB_SECRET' "$LA" && ! grep -qE 'export +JOB_SECRET|declare -x' "$LA"; then t_ok "JOB_SECRET is declared 'export -n' and never exported"; else t_bad "JOB_SECRET export" ""; fi
    if ! grep -nE -e ' -P ?"?[$]' -e '-p"?[$][A-Za-z_{]' -e '--password' "$LA" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then t_ok "code never builds a command line containing a password (-P \$pw / -p\$pw / --password)"; else t_bad "password on argv in code" ""; fi
fi

# -------------------------------------------------------------------- pty
if want pty; then
    t_section "interactive UI through a real pty (arrow keys, space, back/quit, resize, Ctrl+C)"
    PTY_OUT=$(python3 "$HERE/pty_test.py" "$LA" "$T/pty" 2>&1)
    echo "$PTY_OUT"
    while IFS= read -r line; do
        case $line in
            PASS*) PASS=$((PASS+1)) ;;
            FAIL*) FAIL=$((FAIL+1)); FAILED_NAMES+=("${line#FAIL  }") ;;
            SKIP*) SKIP=$((SKIP+1)) ;;
        esac
    done <<<"$PTY_OUT"
    if grep -q '^PTY_DONE' <<<"$PTY_OUT"; then t_ok "pty driver ran to the end"; else t_bad "pty driver crashed or stopped early" "$(tail -n 3 <<<"$PTY_OUT" | tr '\n' '|')"; fi
fi

t_summary
exit $(( FAIL > 0 ))
