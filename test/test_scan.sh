#!/bin/bash
# Checks browser-picker-scan against a fake HOME, so the assertions do not
# depend on which browsers the machine running them happens to have.
#
#   bash test/test_scan.sh

set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/../bin/browser-picker-scan"

passed=0
fail() { echo "FAIL: $1"; echo "      $2"; exit 1; }
ok() { passed=$((passed + 1)); }

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT

# A Local State with two identically-named profiles and one with no name at all,
# which is what Opera writes.
mkdir -p "$fake/.config/chromium"
cat >"$fake/.config/chromium/Local State" <<'JSON'
{"profile":{"info_cache":{
  "Default":   {"name":"acme-client"},
  "Profile 7": {"name":"acme-client"},
  "Profile 9": {"name":""},
  "Profile 3": {"name":"He said \"hi\""}
}}}
JSON

# A stub `chromium` on PATH so the scanner believes it is installed. The PATH is
# replaced rather than prepended: keeping the real one would let every browser
# actually installed on this machine into the results, and the assertions below
# are about what the scanner does with the fixture, not with the host.
mkdir -p "$fake/bin"
printf '#!/bin/sh\nexit 0\n' >"$fake/bin/chromium"
chmod +x "$fake/bin/chromium"
ln -s "$(command -v jq)" "$fake/bin/jq"

out=$(HOME="$fake" PATH="$fake/bin" "$SCAN") \
  || fail "scan exited non-zero" "$out"

jq -e . >/dev/null 2>&1 <<<"$out" || fail "output is not valid JSON" "$out"
ok

# Duplicate display names must still be distinguishable.
labels=$(jq -r '.entries[].label' <<<"$out")
dupes=$(sort <<<"$labels" | uniq -d)
[[ -z $dupes ]] || fail "duplicate labels survived" "$dupes"
ok

count=$(grep -c 'acme-client' <<<"$labels")
[[ $count -eq 2 ]] || fail "expected both acme-client profiles" "found $count"
ok

# An empty profile name falls back to the directory, never a dangling dash.
grep -q 'Profile 9' <<<"$labels" \
  || fail "empty profile name did not fall back to its directory" "$labels"
grep -qE '— *$' <<<"$labels" && fail "a label ends in a dangling dash" "$labels"
ok

# Ids are keyed on the directory, so renaming a profile never breaks a rule.
jq -e '[.entries[] | select(.manage | not) | .id] | index("chromium:Profile 7")' \
  >/dev/null <<<"$out" || fail "id is not <bin>:<profile-dir>" "$out"
ok

# A quote in a profile name must not produce a payload the QML side cannot read.
jq -e '[.entries[].label] | map(select(test("He said"))) | length == 1' \
  >/dev/null <<<"$out" || fail "a quoted profile name was mangled" "$out"
ok

# Every browser gets exactly one manage row.
manage=$(jq '[.entries[] | select(.manage)] | length' <<<"$out")
[[ $manage -eq 1 ]] || fail "expected one manage row" "got $manage"
ok

# Nothing that is not installed may appear.
jq -e '[.entries[] | select(.bin != "chromium")] | length == 0' \
  >/dev/null <<<"$out" || fail "an uninstalled browser was listed" "$out"
ok

echo "$passed passed"
