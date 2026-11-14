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
