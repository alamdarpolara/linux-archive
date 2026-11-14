#!/usr/bin/env bash
# lib.sh - helpers shared by tests.sh / tests_root.sh (sourced, not run).
# shellcheck disable=SC2034,SC2154  # variables are set/used by the sourcing scripts

PASS=0 FAIL=0 SKIP=0
FAILED_NAMES=()

# t_ok <stable name> [detail]: the name never contains exit codes, counts or
# other run-dependent values; those go in the detail ("PASS  name  -- detail").
t_ok()   { PASS=$((PASS+1)); if [[ -n ${2:-} ]]; then printf 'PASS  %s  -- %s\n' "$1" "$2"; else printf 'PASS  %s\n' "$1"; fi; }
t_bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
t_skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s  -- %s\n' "$1" "${2:-}"; }
T_SEC_START=$SECONDS
t_section() { printf '\n==== %s ====   [t+%ss]\n' "$1" "$(( SECONDS - T_SEC_START ))"; }

# check <name> <detail-if-fails> <command...>
check() {
    local name=$1 detail=$2
    shift 2
    if "$@" >/dev/null 2>&1; then t_ok "$name"; else t_bad "$name" "$detail"; fi
}

t_summary() {
    printf '\n==== SUMMARY: %d passed, %d failed, %d skipped ====\n' "$PASS" "$FAIL" "$SKIP"
    if (( FAIL )); then printf 'Failed tests:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"; fi
}
