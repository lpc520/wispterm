#!/usr/bin/env sh
# Test harness for wispterm-notify-setup. Pure POSIX sh. Exits non-zero on any failure.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOTIFY="$HERE/wispterm-notify.sh"
INSTALL="$HERE/install-wispterm-notify.sh"
FAILS=0
ESC="$(printf '\033')"
BEL="$(printf '\007')"

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS+1)); }
assert_contains() { # file needle desc
  if LC_ALL=C grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if LC_ALL=C grep -qF -- "$2" "$1"; then fail "$3 (unexpected: $2)"; else ok "$3"; fi
}

# ---- notify: Claude Code Notification on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"WispTerm","message":"hi"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;WispTerm;hi${BEL}" "CC Notification -> OSC777 title+body"
assert_contains "$t" "$BEL" "CC Notification -> emits BEL"

# ---- notify: Claude Code Stop on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Stop"}' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;Claude Code;完成，轮到你了${BEL}" "CC Stop -> OSC777 Claude Code title+body"

# ---- notify: Codex event as LAST argv ----
t="$(mktemp)"
WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY" '{"type":"agent-turn-complete","last-assistant-message":"done deal"}'
assert_contains "$t" "${ESC}]777;notify;Codex;done deal${BEL}" "Codex argv -> OSC777 Codex/body"

# ---- notify: sanitization (strip ';' delimiter from title and body) ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"a;b","message":"x;y"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;ab;xy${BEL}" "sanitize strips ';' from title and body"

# ---- notify: sanitization strips control bytes (ESC/BEL) decoded by jq ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"a","message":"b\u001bc\u0007d"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;a;bcd${BEL}" "sanitize strips ESC/BEL control bytes from body"

# ---- notify: empty payload -> no output, exit 0 ----
t="$(mktemp)"
printf '' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"; rc=$?
[ "$rc" -eq 0 ] && ok "empty payload exits 0" || fail "empty payload exit code ($rc)"
[ ! -s "$t" ] && ok "empty payload writes nothing" || fail "empty payload wrote output"

printf '\n%s test(s) failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
