#!/bin/bash
# The fzf fallback has to apply handlers itself, because that path never
# reaches QML. With no handler configured it must leave a Zoom URL alone —
# translating it anyway is how the native client loses the meeting.
#
#   bash test/test_fallback_handlers.sh

set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

passed=0
fail() { echo "FAIL: $1"; echo "      $2"; exit 1; }
ok() { passed=$((passed + 1)); }

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
export LOG="$fake/log"

mkdir -p "$fake/stubs" "$fake/home/.config/omarchy"
cat >"$fake/stubs/omarchy-shell" <<'EOF'
#!/bin/bash
exit 1
EOF
cat >"$fake/stubs/foot" <<'EOF'
#!/bin/bash
while [[ ${1:-} == --* ]]; do shift; done
"$@"
EOF
cat >"$fake/stubs/fzf" <<'EOF'
#!/bin/bash
cp "$BP_IN" "$LOG.choices"
head -n1
EOF
cat >"$fake/stubs/uwsm-app" <<'EOF'
#!/bin/bash
echo "uwsm $*" >>"$LOG"
EOF
printf '#!/bin/bash\nexit 0\n' >"$fake/stubs/notify-send"
chmod +x "$fake/stubs/"*

plugin="$fake/plugin"
mkdir -p "$plugin/bin"
cp "$ROOT/bin/browser-picker" "$plugin/bin/"
cat >"$plugin/bin/browser-picker-scan" <<'EOF'
#!/bin/bash
cat <<'JSON'
{"entries":[
  {"id":"chromium:Profile 1","label":"Chromium — Work","bin":"/usr/bin/chromium","family":"chromium","profile":"Profile 1","manage":false},
  {"id":"firefox:dev","label":"Firefox — dev","bin":"/usr/bin/firefox","family":"firefox","profile":"dev","manage":false}
]}
JSON
EOF
chmod +x "$plugin/bin/browser-picker" "$plugin/bin/browser-picker-scan"

run() {
  env HOME="$fake/home" PATH="$fake/stubs:$PATH" "$@"
}

# --- no handler: the Zoom URL is handed on unchanged -------------------------
: >"$LOG"
run "$plugin/bin/browser-picker" 'zoommtg://zoom.us/join?confno=123&pwd=ab' >/dev/null
grep -q 'zoommtg://zoom.us/join?confno=123&pwd=ab' "$LOG" \
  || fail "the fallback rewrote a Zoom URL with no handler" "$(<"$LOG")"
grep -q -- '--app=' "$LOG" \
  && fail "the fallback launched --app with no handler" "$(<"$LOG")"
grep -q 'Firefox' "$LOG.choices" \
  || fail "the fallback hid Firefox when no handler claimed the link" "$(<"$LOG.choices")"
ok

# --- an explicit empty list is the same switch -------------------------------
printf '%s\n' '{ "handlers": [], "settings": { "newWindow": true } }' \
  >"$fake/home/.config/omarchy/browser-picker.json"
: >"$LOG"
run "$plugin/bin/browser-picker" --new-window 'zoommtg://zoom.us/join?confno=5' >/dev/null
grep -q 'zoommtg://zoom.us/join?confno=5' "$LOG" \
  || fail "an empty handlers list still translated the URL" "$(<"$LOG")"
grep -q -- '--new-window' "$LOG" \
  || fail "newWindow was dropped for an ordinary launch" "$(<"$LOG")"
grep -q -- '--app=' "$LOG" && fail "an empty handlers list launched --app" "$(<"$LOG")"
ok

# --- a configured handler translates, filters, and uses --app ----------------
cat >"$fake/home/.config/omarchy/browser-picker.json" <<'EOF'
{
  "settings": { "newWindow": true },
  "handlers": [
    {
      "id": "zoom",
      "schemes": ["zoommtg", "zoomus"],
      "label": "Zoom",
      "launch": "app",
      "translate": "zoom",
      "entryIds": ["chromium:Profile 1"]
    }
  ]
}
EOF
: >"$LOG"
run "$plugin/bin/browser-picker" --new-window \
  'https://us02web.zoom.us/j/82255158777?pwd=abc' >/dev/null
grep -q -- '--app=https://app.zoom.us/wc/join/82255158777?pwd=abc' "$LOG" \
  || fail "the handler did not launch the web client" "$(<"$LOG")"
grep -q -- '--new-window' "$LOG" \
  && fail "an --app launch also passed --new-window" "$(<"$LOG")"
grep -q firefox "$LOG" && fail "an --app handler offered Firefox" "$(<"$LOG")"
grep -qxF 'Zoom — Work' "$LOG.choices" \
  || fail "the handler did not relabel the profile" "$(<"$LOG.choices")"
ok

echo "$passed passed"
