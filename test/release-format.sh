#!/usr/bin/env bash
# release:prepare formats CHANGELOG.md with dprint and the repo's own config
# when there is one, and with hk only when there is not.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff
fake cog
fake dprint

echo "repo with .config/dprint.json: dprint formats the changelog alone"
new_remote with-dprint
d="${TMP}/with-dprint"; new_jj_repo "$d" example.com/withdprint
echo '{}' > "$d/.config/dprint.json"
(cd "$d" && jj commit -m "build: add dprint config" > /dev/null 2>&1)
: > "${CALLS}"
run_task "$d" prepare COG="${FAKES}/cog"
check_eq "prepare succeeds" 0 "${STATUS}"
check_eq "dprint ran on CHANGELOG.md" "dprint fmt -c .config/dprint.json CHANGELOG.md" "$(grep '^dprint ' "${CALLS}")"
check_eq "hk did not run" "" "$(grep '^hk ' "${CALLS}")"

echo "repo without it: hk formats the changelog"
new_remote without-dprint
d="${TMP}/without-dprint"; new_jj_repo "$d" example.com/withoutdprint
: > "${CALLS}"
run_task "$d" prepare COG="${FAKES}/cog"
check_eq "prepare succeeds" 0 "${STATUS}"
check_eq "hk ran on CHANGELOG.md" "hk fix CHANGELOG.md" "$(grep '^hk ' "${CALLS}")"
check_eq "dprint did not run" "" "$(grep '^dprint ' "${CALLS}")"

finish
