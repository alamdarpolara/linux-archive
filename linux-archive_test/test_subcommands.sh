#!/usr/bin/env bash
# Sourced by tests.sh: CLI paths, flow routing, and input safety.
# shellcheck disable=SC2034,SC2154,SC2250,SC2312,SC2249
# T and LA are set by tests.sh; the others are optional stylistic checks.

t_section "subcommands and direct arguments"
D=$T/cli
mkdir -p "$D"
printf 'a small payload\n' > "$D/sample.txt"
printf 'second payload\n' > "$D/second.txt"
CLI_LOG=$D/last.out
cli_run() { # cwd, input string, command args...
    local wd=$1 input=$2
    shift 2
    ( cd -- "$wd" && printf '%s' "$input" | "$LA" --plain --no-color "$@" >"$CLI_LOG" 2>&1 )
    CLI_RC=$?
}
cli_created() {
    local label=$1 target=$2
    if (( CLI_RC == 0 )) && [[ -s $target ]] && grep -q 'Archive created and verified' "$CLI_LOG" &&
        ! grep -Eq 'Main menu|Selection mode|Choose the item to compress|Choose the items to compress' "$CLI_LOG" &&
        { [[ $label == zip\ with\ file* ]] || ! grep -q 'Archive format' "$CLI_LOG"; }; then
        t_ok "$label: archive created, known prompts skipped"
    else
        t_bad "$label" "rc=$CLI_RC $(tail -n 5 "$CLI_LOG" | tr '\n' '|')"
    fi
}

# The full entry point is unchanged, and entering a flow directly does not
# accidentally fall through to the main menu when input closes.
cli_run "$D" ''
if grep -q 'Main menu' "$CLI_LOG" && grep -q 'What do you want to do?' "$CLI_LOG"; then t_ok 'no args still opens the full menu'; else t_bad 'no args menu' "rc=$CLI_RC"; fi
for sub in zip 7z tar tar.gz tgz tar.bz2 tar.xz tar.zst squashfs gz xz zst; do
    cli_run "$D" '' "$sub"
    if [[ $sub == gz || $sub == xz || $sub == zst ]]; then
        if grep -q 'Choose the item to compress' "$CLI_LOG" && ! grep -Eq 'Main menu|Selection mode|Archive format' "$CLI_LOG"; then t_ok "$sub without files asks only for its required one file"; else t_bad "$sub without files" "rc=$CLI_RC"; fi
    elif grep -q 'Selection mode' "$CLI_LOG" && ! grep -Eq 'Main menu|Archive format' "$CLI_LOG"; then
        t_ok "$sub without files asks selection mode, skips main/format menus"
    else t_bad "$sub without files" "rc=$CLI_RC $(tail -n 4 "$CLI_LOG" | tr '\n' '|')"; fi
done
for sub in zip 7z tar tar.gz tgz tar.bz2 tar.xz tar.zst squashfs gz xz zst; do
    mkdir -p "$D/picker/$sub"
    cp "$D/sample.txt" "$D/picker/$sub/sample.txt"
    input=$'1\n1\n'                       # selection mode, then picker
    [[ $sub == gz || $sub == xz || $sub == zst ]] && input=$'1\n' # picker only
    [[ $sub == zip ]] && input+=$'1\n' # the zip flow still asks for format
    [[ $sub != tar ]] && input+=$'1\n' # all but tar ask for level
    [[ $sub == zip || $sub == 7z ]] && input+=$'1\n' # no password
    input+=$'\n'                         # accept proposed output name
    cli_run "$D/picker/$sub" "$input" "$sub"
    ext=$sub; [[ $sub == tgz ]] && ext=tar.gz
    if (( CLI_RC == 0 )) && [[ -s $D/picker/$sub/sample.txt.$ext ]] && grep -q 'Archive created and verified' "$CLI_LOG"; then
        t_ok "$sub without files selects and creates through the picker"
    else t_bad "$sub without files picker flow" "rc=$CLI_RC $(tail -n 5 "$CLI_LOG" | tr '\n' '|')"; fi
done
# A selected file means no selection question or picker. A format selected in
# argv must never ask for it again, but unknown level/password/name still ask.
for fmt in 7z tar tar.gz tgz tar.bz2 tar.xz tar.zst squashfs gz xz zst; do
    mkdir -p "$D/formats/$fmt"
    cp "$D/sample.txt" "$D/formats/$fmt/sample.txt"
    if [[ $fmt == tar ]]; then input=$'\n'
    elif [[ $fmt == 7z ]]; then input=$'1\n1\n\n'
    else input=$'1\n\n'; fi
    cli_run "$D/formats/$fmt" "$input" "$fmt" sample.txt
    target=$D/formats/$fmt/sample.txt.$fmt
    [[ $fmt == tgz ]] && target=$D/formats/$fmt/sample.txt.tar.gz
    cli_created "$fmt with file" "$target"
    if [[ $fmt == 7z ]]; then
        if grep -q 'Password protection' "$CLI_LOG" && grep -q 'Compression level' "$CLI_LOG"; then t_ok '7z asks level and password'; else t_bad '7z unknown prompts' ''; fi
    elif [[ $fmt != tar ]]; then
        if grep -q 'Compression level' "$CLI_LOG"; then t_ok "$fmt asks level"; else t_bad "$fmt level prompt" ''; fi
    fi
done
cli_run "$D" $'1\n1\n1\n\n' zip sample.txt
cli_created 'zip with file and chosen ZIP format' "$D/sample.txt.zip"
if grep -q 'Archive format' "$CLI_LOG" && grep -q 'Password protection' "$CLI_LOG"; then t_ok 'zip asks format, level and password'; else t_bad 'zip unknown prompts' ''; fi
cli_run "$D" '' unzip
if grep -q 'Choose the archive to extract' "$CLI_LOG" && ! grep -q 'Main menu' "$CLI_LOG"; then t_ok 'unzip without file opens only archive picker'; else t_bad 'unzip no-file picker' "rc=$CLI_RC"; fi
mkdir -p "$D/picker_unzip"; cp "$D/sample.txt.zip" "$D/picker_unzip/"
cli_run "$D/picker_unzip" $'1\n1\n\n' unzip
if (( CLI_RC == 0 )) && [[ -f $D/picker_unzip/sample.txt/sample.txt ]]; then t_ok 'unzip without files picks and extracts an archive'; else t_bad 'unzip picker flow' "rc=$CLI_RC"; fi
cli_run "$D" $'1\nsample_unpacked\n' unzip sample.txt.zip
if (( CLI_RC == 0 )) && cmp -s "$D/sample.txt" "$D/sample_unpacked/sample.txt" && ! grep -Eq 'Main menu|Choose the archive to extract' "$CLI_LOG"; then t_ok 'unzip with file skips picker and extracts content'; else t_bad 'unzip direct extract' "rc=$CLI_RC $(tail -n 5 "$CLI_LOG" | tr '\n' '|')"; fi
# A second archive is processed through the same scan, review and output rules.
mkdir -p "$D/multi_unzip"
cp "$D/formats/tar.gz/sample.txt.tar.gz" "$D/multi_unzip/a.tar.gz"
cp "$D/formats/7z/sample.txt.7z" "$D/multi_unzip/b.7z"
cli_run "$D/multi_unzip" $'1\n\n1\n\n' unzip a.tar.gz b.7z
if (( CLI_RC == 0 )) && [[ -f $D/multi_unzip/a/sample.txt && -f $D/multi_unzip/b/sample.txt ]] && [[ $(grep -c 'Extraction finished and verified' "$CLI_LOG") == 2 ]]; then t_ok 'unzip two file arguments processes both'; else t_bad 'unzip multiple files' "rc=$CLI_RC $(tail -n 5 "$CLI_LOG" | tr '\n' '|')"; fi

# Exercise direct selection of directories and multiple files, as well as --.
mkdir -p "$D/folder"; printf 'inside\n' > "$D/folder/inside.txt"
cli_run "$D" $'1\n\n' tar.gz folder second.txt
if (( CLI_RC == 0 )) && tar -tzf "$D/cli.tar.gz" | grep -q 'folder/inside.txt'; then t_ok 'multiple CLI items include directory recursively'; else t_bad 'multiple CLI items' "rc=$CLI_RC"; fi
printf 'dash\n' > "$D/-leading file.txt"
cli_run "$D" $'\n' tar -- '-leading file.txt'
if (( CLI_RC == 0 )) && [[ -s $D/-leading\ file.txt.tar ]] && tar -tf "$D/-leading file.txt.tar" | grep -q -- '-leading file.txt'; then t_ok '-- preserves a leading-dash filename'; else t_bad 'leading dash argument' "rc=$CLI_RC"; fi
for name in 'a b.txt' "quote'single.txt" 'dq"uote.txt' 'ünïcödé 日本語.txt' $'new\nline.txt' $'evil‮gpj.txt' $'\e[31mred\e[0m.txt'; do
    printf 'hostile filename payload\n' >"$D/$name"
    cli_run "$D" $'\n' tar -- "$name"
    if (( CLI_RC == 0 )) && [[ -s $D/${name//$'\n'/_}.tar ]]; then
        t_ok "direct hostile-name archive: $(printf '%q' "$name")"
    elif (( CLI_RC == 0 )) && grep -q 'Archive created and verified' "$CLI_LOG"; then
        t_ok "direct hostile-name archive: $(printf '%q' "$name")"
    else t_bad "direct hostile-name archive: $(printf '%q' "$name")" "rc=$CLI_RC"; fi
    if [[ $(cat "$CLI_LOG") == *$'\e'* || $(cat "$CLI_LOG") == *$'‮'* ]]; then t_bad 'CLI terminal sanitisation' "$(printf '%q' "$name")"; fi
done
for invalid in /etc/passwd ../sample.txt folder/../sample.txt missing.txt; do
    cli_run "$D" '' tar "$invalid"
    if (( CLI_RC == 2 )) && grep -q 'Usage:' "$CLI_LOG" && ! grep -q 'Main menu' "$CLI_LOG"; then t_ok "invalid path $(printf '%q' "$invalid") is refused (2, usage, no menu)"; else t_bad "invalid path $(printf '%q' "$invalid")" "rc=$CLI_RC"; fi
done
cli_run "$D" '' gz folder
if (( CLI_RC == 2 )); then t_ok 'single-file format refuses a directory'; else t_bad 'single-file directory' "rc=$CLI_RC"; fi
ln -s sample.txt "$D/source-link"
cli_run "$D" '' xz source-link
if (( CLI_RC == 2 )); then t_ok 'single-file format refuses a symlink'; else t_bad 'single-file symlink' "rc=$CLI_RC"; fi
cli_run "$D" '' zst sample.txt second.txt
if (( CLI_RC == 2 )); then t_ok 'single-file format refuses two inputs'; else t_bad 'single-file multiple' "rc=$CLI_RC"; fi
for bad in mystery '--password=secret' '--format=zip'; do
    # These must report a usage error before even probing the terminal.
    cli_run "$D" '' "$bad"
    if (( CLI_RC == 2 )) && grep -q 'Usage:' "$CLI_LOG" && ! grep -q 'Main menu' "$CLI_LOG"; then t_ok "invalid CLI $bad returns 2 without menu"; else t_bad "invalid CLI $bad" "rc=$CLI_RC"; fi
done
cli_run "$D" '' unzip --format=zip
if (( CLI_RC == 2 )) && grep -q 'Usage:' "$CLI_LOG"; then t_ok 'unzip rejects format option'; else t_bad 'unzip format option' "rc=$CLI_RC"; fi
# Input validation must not regress when invoking archive tools from argv.
mkdir -p "$D/envcheck"
printf 'environment payload\n' > "$D/envcheck/clean.txt"
printf 'printf "sourced by: %%s\\n" "$0" >> "%s"\n' "$D/envcheck/marker" > "$D/envcheck/bashenv"
( cd "$D/envcheck" && printf '1\n\n' | env BASH_ENV="$D/envcheck/bashenv" TAR_OPTIONS=--to-stdout GZIP=-1 XZ_OPT=-0 \
    SHELLOPTS=braceexpand:hashall:interactive-comments:monitor "$LA" --plain tar.gz clean.txt >"$D/envcheck/create.out" 2>&1 )
( cd "$D/envcheck" && printf '1\nclean_extracted\n' | env BASH_ENV="$D/envcheck/bashenv" TAR_OPTIONS=--to-stdout \
    "$LA" --plain unzip clean.txt.tar.gz >"$D/envcheck/extract.out" 2>&1 )
if [[ -s $D/envcheck/clean.txt.tar.gz && -f $D/envcheck/clean_extracted/clean.txt ]] &&
    ! grep -q 'linux-archive-pipe' "$D/envcheck/marker" 2>/dev/null; then
    t_ok 'direct route neutralises BASH_ENV, SHELLOPTS and archive tool options in children'
else t_bad 'hostile environment with direct arguments' "$(tail -n 4 "$D/envcheck/extract.out" | tr '\n' '|')"; fi
# The content detector rejects a misleading extension, just as the picker does.
printf 'not an archive\n' > "$D/not-real.zip"
cli_run "$D" '' unzip not-real.zip
if (( CLI_RC == 2 )) && ! grep -q 'Choose the archive' "$CLI_LOG"; then t_ok 'direct unzip rejects fake archive by content'; else t_bad 'fake archive direct unzip' "rc=$CLI_RC"; fi
# Neither default nor final output may write through a pre-created symlink.
printf 'victim\n' > "$D/victim"
ln -s victim "$D/second.txt.tar"
cli_run "$D" $'\n\n' tar second.txt
if (( CLI_RC == 0 )) && [[ $(<"$D/victim") == victim && -L $D/second.txt.tar && -s $D/second.txt_2.tar ]] && grep -q 'symbolic link - refused' "$CLI_LOG"; then t_ok 'direct output symlink refused; renamed under original flock/mv policy'; else t_bad 'direct output symlink refusal' "rc=$CLI_RC"; fi
mkdir -p "$D/destcheck/victimdir"
cp "$D/sample.txt.zip" "$D/destcheck/"
ln -s victimdir "$D/destcheck/sample.txt"
cli_run "$D/destcheck" $'1\n\n\n' unzip sample.txt.zip
if (( CLI_RC == 0 )) && [[ -L $D/destcheck/sample.txt && -z $(ls -A "$D/destcheck/victimdir") && -f $D/destcheck/sample.txt_2/sample.txt ]] && grep -q 'symbolic link - refused' "$CLI_LOG"; then t_ok 'direct unzip destination symlink refused, victim untouched'; else t_bad 'direct unzip destination symlink' "rc=$CLI_RC"; fi
# Compare both entry points against the same source, without relying on setup.
ln -s "$LA" "$D/larc"
ln -s "$LA" "$D/linux-archive"
version=$("$LA" --version)
if [[ $("$D/larc" --version) == "larc ${version#* }" && $("$D/linux-archive" --version) == "$version" ]] && "$D/larc" --help | grep -q '^Usage: larc '; then t_ok 'larc resolves same script and uses its invocation name'; else t_bad 'larc invocation' ''; fi
mkdir -p "$D/long" "$D/short"
cp -p "$D/sample.txt" "$D/long/sample.txt"      # same mtime: tar stores it to the second
cp -p "$D/sample.txt" "$D/short/sample.txt"
( cd "$D/long" && printf '\n' | "$D/linux-archive" --plain tar sample.txt >"$D/long.out" 2>&1 )
( cd "$D/short" && printf '\n' | "$D/larc" --plain tar sample.txt >"$D/short.out" 2>&1 )
if cmp -s "$D/long/sample.txt.tar" "$D/short/sample.txt.tar" && grep -q 'Archive created and verified' "$D/long.out" && grep -q 'Archive created and verified' "$D/short.out"; then t_ok 'larc and linux-archive direct flows produce identical archives'; else t_bad 'larc vs linux-archive result' ''; fi

# ---- gap a: one shared rule for the tool's own scratch names (.linux-archive.*)
# The pickers hide them; the direct argv route must refuse them with the same
# rule (a leftover scratch folder or a hostile file with that name must not be
# archived or extracted by naming it on the command line).
mkdir -p "$D/scratch"
cp "$D/sample.txt" "$D/scratch/sample.txt"
printf 'leftover\n' > "$D/scratch/.linux-archive.AbC123"
cp "$D/sample.txt.zip" "$D/scratch/.linux-archive.AbC123.zip"
for name in .linux-archive.AbC123 ./.linux-archive.AbC123; do
    cli_run "$D/scratch" '' tar -- "$name"
    if (( CLI_RC == 2 )) && grep -qi 'internal scratch name' "$CLI_LOG" && ! grep -q 'Archive created' "$CLI_LOG" && [[ -z $(find "$D/scratch" -maxdepth 1 -name '*.tar' -print -quit) ]]; then
        t_ok "direct zip refuses the scratch name $(printf '%q' "$name") (exit 2, nothing created)"
    else t_bad "direct zip refuses the scratch name $(printf '%q' "$name") (exit 2, nothing created)" "rc=$CLI_RC $(tail -n 3 "$CLI_LOG" | tr '\n' '|')"; fi
done
cli_run "$D/scratch" '' unzip .linux-archive.AbC123.zip
if (( CLI_RC == 2 )) && grep -qi 'internal scratch name' "$CLI_LOG" && [[ -z $(find "$D/scratch" -maxdepth 1 -type d -name '.linux-archive.AbC123' -print -quit) ]]; then
    t_ok 'direct unzip refuses a scratch name (exit 2, same message as zip)'
else t_bad 'direct unzip refuses a scratch name (exit 2, same message as zip)' "rc=$CLI_RC $(tail -n 3 "$CLI_LOG" | tr '\n' '|')"; fi
cli_run "$D/scratch" $'1\n' tar
if ! grep -q '\.linux-archive\.' "$CLI_LOG" && grep -q 'sample.txt' "$CLI_LOG"; then t_ok 'the picker still hides scratch names'; else t_bad 'the picker still hides scratch names' "$(tail -n 4 "$CLI_LOG" | tr '\n' '|')"; fi

# ---- gap d: larc and linux-archive give identical results, not only for tar
# Same source copied with its mtime, one run per entry point; results are
# compared byte for byte (archives) or tree for tree (extraction).
parity_run() {   # parity_run <dir> <binary> <input> args...
    local dir=$1 bin=$2 input=$3
    shift 3
    ( cd -- "$dir" && printf '%s' "$input" | "$bin" --plain --no-color "$@" >"$dir/run.out" 2>&1 )
    PARITY_RC=$?
}
# Only the working folder name and the elapsed-time line may differ.
parity_norm() { sed -E 's#par_(long|short)#par_X#g; s#(Time:[[:space:]]+)[0-9]+ s#\1N s#'; }
parity_check() {   # parity_check <name> <input> <result> <bytes|zip> <archive args...>
    local name=$1 input=$2 res=$3 mode=$4 w rl rs same=0
    shift 4
    for w in long short; do
        rm -rf -- "$D/par_$w"; mkdir -p "$D/par_$w"
        cp -p "$D/sample.txt" "$D/par_$w/sample.txt"
        cp -p "$D/sample.txt.zip" "$D/par_$w/x.zip"
    done
    parity_run "$D/par_long" "$D/linux-archive" "$input" "$@"; rl=$PARITY_RC
    parity_run "$D/par_short" "$D/larc" "$input" "$@"; rs=$PARITY_RC
    if [[ $mode == zip ]]; then
        # Info-ZIP stores the file's access time in the UT extra field, so two
        # runs differ by a byte even for identical input: compare everything
        # else exactly (other files, listing, integrity, member content).
        if diff -r --exclude=run.out --exclude="$res" "$D/par_long" "$D/par_short" >/dev/null 2>&1 &&
            diff <(zipinfo -l "$D/par_long/$res" | sed 1d) <(zipinfo -l "$D/par_short/$res" | sed 1d) >/dev/null 2>&1 &&
            unzip -tq "$D/par_long/$res" >/dev/null 2>&1 && unzip -tq "$D/par_short/$res" >/dev/null 2>&1 &&
            [[ $(unzip -p "$D/par_long/$res" | sha256sum) == "$(unzip -p "$D/par_short/$res" | sha256sum)" ]]; then same=1; fi
    elif diff -r --exclude=run.out "$D/par_long" "$D/par_short" >/dev/null 2>&1; then same=1; fi
    if (( rl == 0 && rs == 0 && same )) && [[ -e $D/par_long/$res ]] &&
        diff -q <(parity_norm <"$D/par_long/run.out") <(parity_norm <"$D/par_short/run.out") >/dev/null; then
        t_ok "$name"
    else t_bad "$name" "rc=$rl/$rs result=$res $(diff -r --exclude=run.out "$D/par_long" "$D/par_short" 2>&1 | head -n 3 | tr '\n' '|') output: $(diff <(parity_norm <"$D/par_long/run.out") <(parity_norm <"$D/par_short/run.out") 2>&1 | head -n 4 | tr '\n' '|')"; fi
}
parity_check 'larc and linux-archive: zip sample.txt gives identical archive and output' $'1\n1\n1\n\n' sample.txt.zip zip zip sample.txt
parity_check 'larc and linux-archive: 7z sample.txt gives identical archive and output' $'1\n1\n\n' sample.txt.7z bytes 7z sample.txt
parity_check 'larc and linux-archive: unzip x.zip gives identical tree and output' $'1\n\n' x/sample.txt bytes unzip x.zip
