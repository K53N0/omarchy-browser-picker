#!/bin/bash
# Checks `browser-picker --set-default` and the wrapper it writes, against a fake
# HOME and stub xdg-settings / xdg-mime / xdg-open / notify-send, so nothing on
# the machine running it changes and no picker or notification ever shows up.
#
#   bash test/test_set_default.sh

set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

passed=0
fail() { echo "FAIL: $1"; echo "      $2"; exit 1; }
ok() { passed=$((passed + 1)); }

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT

# Stubs log every call. xdg-settings keeps the default in a file; xdg-mime
# answers what a desktop-specific list would route https to.
mkdir -p "$fake/stubs" "$fake/state"
export LOG="$fake/log" STATE="$fake/state"
cat >"$fake/stubs/xdg-settings" <<'EOF'
#!/bin/bash
echo "xdg-settings $* desktop=${XDG_CURRENT_DESKTOP-unset} browser=${BROWSER-unset}" >>"$LOG"
case "$1 $2" in
  "get default-web-browser") cat "$STATE/default" 2>/dev/null ;;
  "set default-web-browser") printf '%s\n' "$3" >"$STATE/default" ;;
esac
EOF
cat >"$fake/stubs/xdg-mime" <<'EOF'
#!/bin/bash
echo "xdg-mime $*" >>"$LOG"
[[ "$1 $2" == "query default" ]] && cat "$STATE/effective" 2>/dev/null
exit 0
EOF
cat >"$fake/stubs/xdg-open" <<'EOF'
#!/bin/bash
echo "xdg-open $* guard=${BROWSER_PICKER_FALLBACK-}" >>"$LOG"
EOF
printf '#!/bin/bash\necho "notify $*" >>"$LOG"\n' >"$fake/stubs/notify-send"
printf '#!/bin/bash\nexit 0\n' >"$fake/stubs/update-desktop-database"
chmod +x "$fake/stubs/"*

# A throwaway copy of the plugin, so removing it later is a real removal. The
# folder name carries a quote and a space: the wrapper has to bake that path in
# as data.
plugin="$fake/plugins/it's here"
mkdir -p "$plugin"
cp -r "$ROOT/bin" "$ROOT/applications" "$plugin/"

run() { # env overrides as KEY=VALUE..., then the command
  env HOME="$fake/home" XDG_DATA_HOME="$fake/home/.local/share" XDG_CONFIG_HOME="$fake/home/.config" \
    PATH="$fake/stubs:$PATH" XDG_CURRENT_DESKTOP=Hyprland BROWSER=omarchy-launch-browser "$@"
}
support="$fake/home/.local/share/browser-picker"

# --- set-default on an Omarchy-shaped desktop ---------------------------------
echo chromium.desktop >"$STATE/default"
echo omarchy-browser.desktop >"$STATE/effective"
out=$(run "$plugin/bin/browser-picker" --set-default 2>&1) \
  || fail "--set-default failed behind Omarchy's router" "$out"
[[ $(<"$STATE/default") == browser-picker.desktop ]] \
  || fail "the default was not taken" "$(<"$STATE/default")"
ok

grep -q '^xdg-settings set default-web-browser browser-picker.desktop desktop= browser=unset$' "$LOG" \
  || fail "xdg-settings set ran with the desktop list or BROWSER in play" "$(<"$LOG")"
ok

[[ $(<"$support/fallback") == chromium.desktop ]] \
  || fail "the previous default was not recorded" "$(cat "$support/fallback" 2>&1)"
ok

grep -qxF "Exec=$support/launch %U" "$fake/home/.local/share/applications/browser-picker.desktop" \
  || fail "the .desktop does not point at the wrapper" "$(grep Exec= "$fake/home/.local/share/applications/browser-picker.desktop")"
ok

bash -n "$support/launch" || fail "the wrapper is not valid bash" "$(<"$support/launch")"
baked=$(bash -c 'eval "$(grep "^shim=" "$1")"; printf %s "$shim"' _ "$support/launch")
[[ $baked == "$plugin/bin/browser-picker" ]] \
  || fail "the plugin path did not survive into the wrapper" "$baked"
ok

# --- the router is never recorded as the fallback ----------------------------
rm -f "$support/fallback"
echo omarchy-browser.desktop >"$STATE/default"
run "$plugin/bin/browser-picker" --set-default >/dev/null 2>&1
[[ ! -e $support/fallback ]] \
  || fail "omarchy-browser.desktop was recorded as the fallback" "$(<"$support/fallback")"
ok

# --- a desktop list routing elsewhere is reported, not papered over -----------
echo firefox.desktop >"$STATE/effective"
out=$(run "$plugin/bin/browser-picker" --set-default 2>&1) \
  && fail "--set-default claimed success while firefox.desktop gets the links" "$out"
[[ $out == *firefox.desktop* ]] || fail "the error does not name the handler in the way" "$out"
ok
echo omarchy-browser.desktop >"$STATE/effective"

# --- after removal, with a fallback on record ---------------------------------
echo chromium.desktop >"$support/fallback"
rm -rf "$plugin"
: >"$LOG"
run "$support/launch" --new-window https://x.test >/dev/null 2>&1
grep -q '^xdg-settings set default-web-browser chromium.desktop desktop= browser=unset$' "$LOG" \
  || fail "the fallback browser was not restored" "$(<"$LOG")"
grep -qxF 'xdg-open https://x.test guard=1' "$LOG" \
  || fail "the link was not reopened, guarded, without its flags" "$(<"$LOG")"
ok

# --- after removal, with nothing on record ------------------------------------
rm -f "$support/fallback"
mkdir -p "$fake/home/.config"
printf '%s\n' '[Default Applications]' 'text/html=browser-picker.desktop' \
  'x-scheme-handler/https=browser-picker.desktop' 'x-scheme-handler/mailto=thunderbird.desktop' \
  >"$fake/home/.config/mimeapps.list"
: >"$LOG"
run "$support/launch" https://y.test >/dev/null 2>&1
grep -q 'browser-picker' "$fake/home/.config/mimeapps.list" \
  && fail "the wrapper left itself in mimeapps.list" "$(<"$fake/home/.config/mimeapps.list")"
grep -qxF 'x-scheme-handler/mailto=thunderbird.desktop' "$fake/home/.config/mimeapps.list" \
  || fail "the wrapper removed a line that was not its own" "$(<"$fake/home/.config/mimeapps.list")"
grep -qxF 'xdg-open https://y.test guard=1' "$LOG" || fail "the link was not reopened" "$(<"$LOG")"
ok

# --- a link that comes straight back stops instead of looping -----------------
: >"$LOG"
run BROWSER_PICKER_FALLBACK=1 "$support/launch" https://z.test >/dev/null 2>&1 \
  && fail "the second pass did not fail" "$(<"$LOG")"
grep -q '^xdg-open' "$LOG" && fail "the second pass reopened the link" "$(<"$LOG")"
grep -q '^notify ' "$LOG" || fail "the second pass said nothing" "$(<"$LOG")"
ok

echo "$passed passed"
