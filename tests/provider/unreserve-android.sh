#!/usr/bin/env bash
# Until labelle-cli#405 PR 3 ("delete android from the CLI") lands, the CLI
# still reserves the `android` namespace and parses `labelle android ...` as
# its legacy built-in subcommand, so a provider declaring `namespace =
# "android"` fails discovery with ReservedNamespace and never dispatches.
#
# This makes exactly those two edits to a labelle-cli checkout pinned by CI,
# so the e2e can drive this provider through the CLI's real discovery, build
# (`zig build --system`) and context path. Delete this script (and its CI
# step) once the pinned CLI has PR 3.
set -euo pipefail
cli="${1:?usage: unreserve-android.sh <labelle-cli checkout>}"
dispatch="$cli/src/cli/provider_dispatch.zig"
main="$cli/src/cli.zig"

grep -q '"ios",   "android", "wasm",' "$dispatch"
grep -q 'std.mem.eql(u8, first, "android")' "$main"

python3 - "$dispatch" "$main" <<'PY'
import sys
dispatch, main = sys.argv[1], sys.argv[2]
def edit(path, old, new):
    text = open(path, encoding="utf-8").read()
    assert text.count(old) == 1, (path, old)
    open(path, "w", encoding="utf-8").write(text.replace(old, new))
edit(dispatch, '"ios",   "android", "wasm",', '"ios",   "wasm",')
edit(main, 'std.mem.eql(u8, first, "android")', 'std.mem.eql(u8, first, "android-legacy-builtin")')
PY

! grep -q '"android", "wasm"' "$dispatch"
! grep -q 'std.mem.eql(u8, first, "android")' "$main"
echo "unreserve-android: patched $cli"
