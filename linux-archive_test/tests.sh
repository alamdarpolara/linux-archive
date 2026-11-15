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
