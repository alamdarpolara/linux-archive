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
