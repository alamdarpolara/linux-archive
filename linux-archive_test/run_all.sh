#!/usr/bin/env bash
# run_all.sh - the whole proof (not a deliverable): for every distribution in
# distros.sh build the test image through the REAL install.sh, run the
# install.sh scenarios in fresh containers, the root suite (setup.sh,
# uninstall_setup.sh, disk-full, root extraction) and the main suite (as an
# unprivileged user), and write logs/<distro>.log plus logs/SUMMARY.txt.
#   ./run_all.sh                 all distributions
#   ONLY=debian13,arch ./run_all.sh
#   JOBS=2 ./run_all.sh          distributions in parallel (default 1)
#   SKIP_BUILD=1 / SKIP_INSTALL=1 / SKIP_ROOT=1 / SKIP_MAIN=1
# Needs docker or podman on the host; it never installs either.
# shellcheck disable=SC2154  # DISTROS comes from the sourced distros.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
P=$(dirname -- "$HERE")
LOGS=$HERE/logs
mkdir -p "$LOGS"
# shellcheck source=distros.sh
. "$HERE/distros.sh"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then CT=docker
elif command -v podman >/dev/null 2>&1; then CT=podman
else
    echo "Neither docker nor podman is usable on this host.  Install one, e.g. on Debian/Ubuntu:"
    echo "  sudo apt-get install docker.io      (or: sudo apt-get install podman)"
    exit 1
fi

summary_of() { grep -E '^==== SUMMARY' "$1" 2>/dev/null | tail -n 1 | sed 's/^==== SUMMARY: //; s/ ====$//'; }

run_one() {
    local name=$1 img=$2 args=$3 plat=${4:-} t0=$SECONDS s bad=0
    local log=$LOGS/$name.log
    local -a pf=()
    [[ -n $plat ]] && pf=(--platform "$plat")
    : >"$log"
    rm -f -- "$LOGS/.$name.status"
    {
        echo "######## $name  ($img)   $(date -u +%FT%TZ)"
        if [[ -z ${SKIP_BUILD:-} ]]; then
            echo "--- build test image (install.sh $args)"
            if $CT build -q "${pf[@]}" -f "$HERE/Dockerfile" --build-arg BASE="$img" --build-arg INSTALL_ARGS="$args" -t "la-test:$name" "$P" >/dev/null 2>"$LOGS/.$name.build.err"; then
                echo "image la-test:$name built"
            else
                echo "IMAGE BUILD FAILED:"; cat "$LOGS/.$name.build.err"; return 1
            fi
            rm -f "$LOGS/.$name.build.err"
        fi
        echo; echo "--- install.sh in the test image (build log tail)"
        $CT run --rm "la-test:$name" sh -c 'tail -n 30 /var/log/la-install.log' || bad=1
        if [[ -z ${SKIP_INSTALL:-} ]]; then
            for s in base nonfree; do
                echo; echo "--- install.sh scenario: $s (fresh $img container)"
                $CT run --rm "${pf[@]}" -v "$P":/proj:ro "$img" sh /proj/linux-archive_test/test_install.sh "$s" 2>&1 || bad=1
            done
            echo; echo "--- install.sh scenario: interactive (test image la-test:$name)"
            $CT run --rm -v "$P":/proj:ro "la-test:$name" sh /proj/linux-archive_test/test_install.sh interactive 2>&1 || bad=1
        fi
        if [[ -z ${SKIP_ROOT:-} ]]; then
            echo; echo "--- root suite (setup.sh, uninstall_setup.sh, disk-full, root extraction)"
            $CT run --rm --cap-add SYS_ADMIN -v "$P":/proj:ro "la-test:$name" bash /proj/linux-archive_test/tests_root.sh 2>&1 || bad=1
        fi
        if [[ -z ${SKIP_MAIN:-} ]]; then
            echo; echo "--- main suite (as user 'tester')"
            $CT run --rm --user tester -e HOME=/home/tester -w /home/tester -v "$P":/proj:ro "la-test:$name" bash /proj/linux-archive_test/tests.sh 2>&1 || bad=1
        fi
        echo; echo "######## $name finished in $(( SECONDS - t0 )) s"
    } >>"$log" 2>&1
    grep -qE '^FAIL[[:space:]]|^IMAGE BUILD FAILED:|^Traceback' "$log" && bad=1
    s=$(grep -E '^==== SUMMARY' "$log" | sed 's/^==== SUMMARY: //; s/ ====$//' | tr '\n' ';')
    printf '%s\n' "$bad" >"$LOGS/.$name.status"
    printf '%-12s %s%s\n' "$name" "$s" "$([[ $bad == 1 ]] && printf ' [FAILED]')"
    return "$bad"
}

shellcheck_bad=0
{
    echo "shellcheck $($CT run --rm koalaman/shellcheck:stable --version | sed -n 2p)  $(date -u +%FT%TZ)"
    $CT run --rm -v "$P":/mnt:ro -w /mnt koalaman/shellcheck:stable -S style -o all linux-archive.sh setup.sh uninstall_setup.sh \
        && $CT run --rm -v "$P":/mnt:ro -w /mnt koalaman/shellcheck:stable -s sh -S style -o all install.sh \
        && $CT run --rm -v "$P":/mnt:ro -w /mnt koalaman/shellcheck:stable -S warning -o all linux-archive_test/{lib,run_all,distros,tests,tests_root,test_subcommands}.sh \
        && $CT run --rm -v "$P":/mnt:ro -w /mnt koalaman/shellcheck:stable -s sh -S warning -o all linux-archive_test/{testdeps,test_install}.sh \
        && echo "shellcheck: production scripts clean at -S style -o all; all test shell scripts clean at -S warning -o all"
} >"$LOGS/shellcheck.log" 2>&1 || shellcheck_bad=1
cat "$LOGS/shellcheck.log"

pids=()
for e in "${DISTROS[@]}"; do
    IFS='|' read -r name img args plat <<<"$e"
    [[ -n ${ONLY:-} && ,$ONLY, != *,$name,* ]] && continue
    run_one "$name" "$img" "$args" "$plat" &
    pids+=($!)
    while (( $(jobs -rp | wc -l) >= ${JOBS:-1} )); do wait -n; done
done
wait
failed=$shellcheck_bad
{
    echo "linux-archive test matrix  $(date -u +%FT%TZ)"
    for e in "${DISTROS[@]}"; do
        IFS='|' read -r name _ <<<"$e"
        [[ -n ${ONLY:-} && ,$ONLY, != *,$name,* ]] && continue
        status=1
        [[ -f $LOGS/.$name.status ]] && read -r status <"$LOGS/.$name.status"
        (( status == 0 )) || failed=1
        printf '%-12s ' "$name"
        grep -E '^==== SUMMARY' "$LOGS/$name.log" 2>/dev/null | sed 's/^==== SUMMARY: //; s/ ====$//' | tr '\n' ';'
        [[ $status == 0 ]] && echo ' [PASSED]' || echo ' [FAILED]'
    done
    [[ $shellcheck_bad == 0 ]] && echo 'shellcheck: passed' || echo 'shellcheck: FAILED'
} >"$LOGS/SUMMARY.txt"
cat "$LOGS/SUMMARY.txt"
exit "$failed"
