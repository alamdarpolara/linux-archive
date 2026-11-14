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

# ------------------------------------------------------------ test data
# make_data <dir>: the standard data set (see the list in the report).
make_data() {
    local d=$1 i j
    rm -rf -- "$d"
    mkdir -p -- "$d"/{docs,web,img,bin,emptydir,nested/a/b/c/d,nested/empty_leaf,many}
    cd -- "$d" || return 1
    printf 'Hello, linux-archive!\nSecond line.\n' > docs/hello.txt
    printf '# Readme\n\nSome *markdown* text.\n' > docs/readme.md
    printf 'Zażółć gęślą jaźń – ünïcödé text 日本語 пример\n' > docs/unicode.txt
    printf '<?php\necho "hi";\n' > web/index.php
    printf '<!DOCTYPE html><html><body><p>hi</p></body></html>\n' > web/page.html
    printf 'body{color:#333}\n' > web/style.css
    printf 'console.log("x");\n' > web/script.js
    # minimal valid PDF
    printf '%%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 72 72]>>endobj\ntrailer<</Root 1 0 R/Size 4>>\n%%%%EOF\n' > docs/tiny.pdf
    python3 - <<'PY'
import struct, zlib, base64
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00')) + chunk(b'IEND', b'')
open('img/pixel.png', 'wb').write(png)
jpg = base64.b64decode('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=')
open('img/pixel.jpg', 'wb').write(jpg)
PY
    head -c 1048576 /dev/urandom > bin/rand.bin
    head -c 1048576 /dev/zero > bin/zeros.bin
    printf '#!/bin/sh\necho run\n' > bin/exe.sh; chmod 755 bin/exe.sh
    printf 'top secret\n' > bin/secret.txt; chmod 600 bin/secret.txt
    : > empty.txt
    printf 'deep\n' > nested/a/b/c/d/deep.txt
    printf 'with space\n' > "with space.txt"
    printf 'unicode name\n' > "ünïcödé 日本語.txt"
    printf 'leading dash\n' > "-dash.txt"
    mkdir -- "-dashdir"; printf 'inside dashdir\n' > "-dashdir/inner.txt"
    printf 'single quote\n' > "quote'single.txt"
    printf 'double quote\n' > 'dq"uote.txt'
    printf 'brackets\n' > 'br[ack]et.txt'
    printf 'star question\n' > 'st*r?.txt'
    printf 'at sign\n' > '@at.txt'
    printf 'newline in name\n' > $'new\nline.txt'
    printf 'backslash\n' > 'back\slash.txt'
    printf 'tab in name\n' > $'tab\there.txt'
    ln -s docs/hello.txt ln_rel
    ln -s nested ln_dir
    ln -s nowhere ln_dangling
    ln -s /etc/hostname ln_abs
    printf 'hard\n' > hard1.txt; ln hard1.txt hard2.txt
    for i in 0 1 2 3 4 5 6 7 8 9; do
        mkdir -p -- "many/d$i"
        for j in $(seq 0 59); do printf 'file %s/%s\n' "$i" "$j" > "many/d$i/f$j.txt"; done
    done
    cd - >/dev/null || return 1
}

# Stable description of a tree: names, types, modes, link targets  (NUL safe).
tree_meta() {
    ( cd -- "$1" && find . -mindepth 1 -printf '%p\t%y\t%m\t%l\0' | LC_ALL=C sort -z | sha256sum | cut -d' ' -f1 )
}
tree_meta_text() {
    ( cd -- "$1" && find . -mindepth 1 -printf '%p\t%y\t%m\t%l\0' | LC_ALL=C sort -z | tr '\0' '\n' )
}
tree_sums() {
    ( cd -- "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1 )
}
