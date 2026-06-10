#!/usr/bin/env bash
# e2e-smoke.sh -- Drive every MCP tool through bin/emacs-devtools-mcp
# against a live host Emacs daemon.  Used by `make test-mcp'.
#
# Runs in three phases:
#
#   1. Bring up an `emacs --bg-daemon' host with the package loaded and
#      the server listening at $XDG_RUNTIME_DIR/edmcp/e2e.sock.
#   2. Open a persistent connection through bin/emacs-devtools-mcp
#      (the actual relay) and run `initialize'.
#   3. Drive `tools/list' and one `tools/call' per registered tool,
#      asserting the reply shape (success vs. expected isError envelope).
#
# Cleanup runs on EXIT.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

NAME=e2e
SERVER=edmcp-e2e-host
RT="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR unset}"
DIR="$RT/edmcp"
SOCK="$DIR/$NAME.sock"
TOKEN_FILE="$DIR/$NAME.token"

mkdir -p "$DIR"
chmod 700 "$DIR"

# Tear down any prior session.
emacsclient -s "$SERVER" --eval '(kill-emacs)' >/dev/null 2>&1 || true
rm -f "$SOCK" "$TOKEN_FILE"

# Bring up the host daemon with the package loaded and the server bound
# to $NAME so bin/emacs-devtools-mcp can find the socket and token.
emacs --bg-daemon="$SERVER" -Q \
  --eval "(add-to-list 'load-path \"$ROOT/lisp\")" \
  --eval "(require 'emacs-devtools-mcp)" \
  --eval "(require 'emacs-devtools-mcp-server)" \
  --eval "(setq emacs-devtools-mcp-server-name \"$NAME\")" \
  --eval "(emacs-devtools-mcp-server-start)" >/dev/null

cleanup() {
  emacsclient -s "$SERVER" --eval '(kill-emacs)' >/dev/null 2>&1 || true
  rm -f "$SOCK" "$TOKEN_FILE"
}
trap cleanup EXIT

# Wait for the socket and token file to appear.
for _ in $(seq 1 40); do
  [ -S "$SOCK" ] && [ -r "$TOKEN_FILE" ] && break
  sleep 0.2
done
[ -S "$SOCK" ]      || { echo "FAIL: no socket at $SOCK" >&2; exit 1; }
[ -r "$TOKEN_FILE" ] || { echo "FAIL: no token file at $TOKEN_FILE" >&2; exit 1; }

# Allowlist a temp init dir for the init-tool calls and stage a small
# init.el with a known-bad form for bisect.  Also stage a tiny .el file
# that defines `edmcp-e2e-fixture' with a real source location so the
# edebug_* tools can locate it (edebug needs a definition site, which
# eval'd defuns don't have).
INIT_DIR="$(mktemp -d)"
INIT="$INIT_DIR/init.el"
cat >"$INIT" <<'EOF'
;;; -*- lexical-binding: t; -*-
(setq edmcp-e2e-a 1)
(setq edmcp-e2e-b 2)
(defvar edmcp-e2e-marker t)
(setq edmcp-e2e-c 3)
EOF

FIXTURE="$INIT_DIR/edmcp-e2e-fixture.el"
cat >"$FIXTURE" <<'EOF'
;;; -*- lexical-binding: t; -*-
(defun edmcp-e2e-fixture (x) (* x 2))
(provide 'edmcp-e2e-fixture)
EOF

emacsclient -s "$SERVER" --eval \
  "(setq emacs-devtools-mcp-init-allowlist (cons \"$INIT_DIR\" emacs-devtools-mcp-init-allowlist))" \
  >/dev/null

# Open a persistent MCP connection through the actual relay, with a
# coproc so we can gate per-request: write one frame to the relay,
# read one JSON line back, validate, repeat.  Per-request gating
# guarantees we never trip the server's single-in-flight `:slow' guard
# even for back-to-back slow tools.
coproc MCP { EDMCP_NAME="$NAME" "$ROOT/bin/emacs-devtools-mcp"; }
exec 3>&"${MCP[1]}" 4<&"${MCP[0]}"

# Send one frame, return the matching response by id.
ID=0
PASS=0
FAIL=0
FAILED_NAMES=()

call() {
  local name="$1"; local args_json="$2"; local expect="${3:-success}"
  ID=$((ID + 1))
  jq -nc --argjson id "$ID" --arg n "$name" --argjson a "$args_json" \
    '{jsonrpc:"2.0", id:$id, method:"tools/call",
      params:{name:$n, arguments:$a}}' >&3

  local line=""
  if ! IFS= read -r -t 60 -u 4 line; then
    printf 'FAIL %-22s tool=%s reason=read-timeout\n' "$name" "$name"
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); return
  fi

  local err is_err
  err="$(jq -r '.error // empty' <<<"$line")"
  is_err="$(jq -r '.result.isError | tostring' <<<"$line")"

  case "$expect" in
    success)
      if [ -z "$err" ] && [ "$is_err" != "true" ]; then
        printf 'PASS %-22s\n' "$name"; PASS=$((PASS + 1))
      else
        printf 'FAIL %-22s err=%s isErr=%s body=%s\n' \
          "$name" "$err" "$is_err" "$line"
        FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
      fi ;;
    is-error)
      if [ "$is_err" = "true" ]; then
        printf 'PASS %-22s (expected isError)\n' "$name"; PASS=$((PASS + 1))
      else
        printf 'FAIL %-22s expected isError, got %s\n' "$name" "$line"
        FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
      fi ;;
    *)
      printf 'FAIL %-22s unknown expectation %s\n' "$name" "$expect"
      FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name") ;;
  esac
}

# Phase 2: initialize through the relay.  The relay injects the
# per-launch token from $TOKEN_FILE into params._meta.token of this
# request.
jq -nc '{jsonrpc:"2.0", id:0, method:"initialize",
         params:{protocolVersion:"2024-11-05", capabilities:{}}}' >&3
IFS= read -r -t 30 -u 4 init_line
init_proto="$(jq -r '.result.protocolVersion // empty' <<<"$init_line")"
if [ -z "$init_proto" ]; then
  echo "FAIL initialize: $init_line" >&2; exit 1
fi
echo "PASS initialize           protocolVersion=$init_proto"
PASS=$((PASS + 1))

# A spec-conforming client sends notifications/initialized right after
# the handshake.  The server must ignore it without a reply and keep
# serving -- if this regressed into closing or replying, the very next
# read (tools/list below) would fail or desynchronize.
jq -nc '{jsonrpc:"2.0", method:"notifications/initialized"}' >&3
echo "SENT notifications/initialized (no reply expected)"

# tools/list smoke -- count must equal the registry size, derived
# from the deftool call sites in lisp/ so adding or removing a tool
# cannot silently drift past a hard-coded threshold.
# `|| true' so a zero-match grep (exit 1) under `set -o pipefail' yields
# expected_tools=0 and fails loudly at the `-ne' check below, rather than
# killing the script with no diagnostic.
expected_tools="$(grep -h '^(emacs-devtools-mcp-deftool ' "$ROOT"/lisp/*.el | wc -l || true)"
jq -nc '{jsonrpc:"2.0", id:99, method:"tools/list"}' >&3
IFS= read -r -t 30 -u 4 list_line
tool_count="$(jq '.result.tools | length' <<<"$list_line")"
if [ "$tool_count" -ne "$expected_tools" ]; then
  echo "FAIL tools/list returned $tool_count tools; lisp/ defines $expected_tools" >&2
  exit 1
fi
echo "PASS tools/list           count=$tool_count"
PASS=$((PASS + 1))

# Phase 3: one tools/call per registered tool.  Order matters where
# state is built up (eval_elisp creates the edebug/trace fixture; spawn
# precedes list/kill).  Comments call out which envelope shape we're
# asserting -- success or isError.

# --- server / smoke ---
call ping                  '{"message":"hi"}'

# --- eval / debug ---
# Load a fixture file so edebug has a real source location for the
# function it's about to instrument.  An eval'd `defun' has no source
# location and edebug refuses to instrument it.
call eval_elisp            "$(jq -nc --arg f "$FIXTURE" '{form:("(load \"" + $f + "\" nil t)")}')"
call eval_elisp            '{"form":"(edmcp-e2e-fixture 21)"}'
# Canned-answer path: a prompting form must resolve from `answers`
# rather than blocking until the slow-tool timeout.
call eval_elisp            '{"form":"(if (y-or-n-p \"e2e? \") :yes :no)","answers":[true]}'
call edebug_instrument     '{"function":"edmcp-e2e-fixture"}'
call edebug_uninstrument   '{"function":"edmcp-e2e-fixture"}'
call capture_backtrace     '{"form":"(error \"e2e probe\")"}'
call trace_function        '{"function":"edmcp-e2e-fixture"}'
call eval_elisp            '{"form":"(edmcp-e2e-fixture 7)"}'
call trace_log             '{}'
call untrace_function      '{"function":"edmcp-e2e-fixture"}'

# --- buffer / state ---
# Explicit host target on one call so the canonical `{"host": true}`
# shape is exercised over the wire, not just the omitted default.
call list_buffers          '{"target":{"host":true}}'
call buffer_state          '{"buffer":"*scratch*"}'
call buffer_substring      '{"buffer":"*scratch*","start":1,"end":1}'
call list_messages         '{}'
call list_warnings         '{}'
# Selector "t" runs all loaded ERT tests.  In a fresh -Q daemon none
# are loaded, so this returns total=0 instantly.
call ert_run               '{"selector":"t"}'
call describe_hooks        '{"hook":"after-change-functions"}'

# --- keys ---
call where_is              '{"command":"find-file"}'
call lookup_key            '{"keys":"C-x C-f"}'
call describe_keymap       '{"keymap":"global-map"}'
call simulate_keys         '{"keys":"a b c","buffer":"*scratch*"}'
call key_translation_trace '{"keys":"C-x C-f"}'

# --- gui ---
# In a headless --bg-daemon there is no X display, so screenshot_frame
# should return an isError envelope explaining that.  The other GUI
# tools work without a display because they introspect frame/face data
# via the lisp object model.
call screenshot_frame      '{}'                                                    is-error
call get_frame_tree        '{}'
call face_at               '{"buffer":"*scratch*","line":1,"column":0}'
call describe_face         '{"name":"default"}'
call list_faces            '{}'
call color_contrast        '{"foreground":"#ffffff","background":"#000000"}'

# --- init / startup ---
call init_lint             "$(jq -nc --arg f "$INIT" '{file:$f}')"
call startup_profile       "$(jq -nc --arg f "$INIT" '{file:$f}')"
call bisect_init           "$(jq -nc --arg f "$INIT" '{file:$f, predicate:"(boundp '\''edmcp-e2e-marker)"}')"

# --- spawn ---
# spawn -> capture handle from result -> list_handles -> kill the handle
ID=$((ID + 1))
jq -nc --argjson id "$ID" \
  '{jsonrpc:"2.0", id:$id, method:"tools/call",
    params:{name:"spawn_emacs", arguments:{}}}' >&3
IFS= read -r -t 30 -u 4 spawn_line
spawn_text="$(jq -r '.result.content[0].text' <<<"$spawn_line")"
spawn_handle="$(jq -r '.handle' <<<"$spawn_text")"
if [ -z "$spawn_handle" ] || [ "$spawn_handle" = "null" ]; then
  printf 'FAIL %-22s body=%s\n' spawn_emacs "$spawn_line"
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("spawn_emacs")
else
  printf 'PASS %-22s handle=%s\n' spawn_emacs "$spawn_handle"
  PASS=$((PASS + 1))
fi

call list_handles          '{}'
# attach_emacs to a known-bad name should produce isError, not crash.
call attach_emacs          '{"server_name":"edmcp-e2e-no-such-daemon"}' is-error

if [ -n "${spawn_handle:-}" ] && [ "$spawn_handle" != "null" ]; then
  call kill_spawn          "$(jq -nc --arg h "$spawn_handle" '{handle:$h}')"
else
  call kill_spawn          '{"handle":"unknown-handle"}'
fi

# --- spawn with display_mode: xvfb-run + screenshot_frame round-trip ---
# Guarded: only run when (a) xvfb-run is in PATH and (b) the `emacs'
# binary was built with X support, since the spawn uses the same
# binary as the host and a no-X build (e.g. `purcell/nix-emacs-ci',
# which configures `--with-x=no') cannot create a graphical frame
# even under xvfb-run -- `make-frame-on-display' errors and the
# backend probe later reports `unavailable'.
#
# Sequence: spawn -> eval_elisp creates a real graphical frame inside the
# spawn on the xvfb-run-provided DISPLAY (and resets the cached backend
# probe so the next call re-evaluates) -> screenshot_frame against the
# spawn -> kill_spawn.  Without the frame-creation step, the daemon
# would report `display-graphic-p' = nil and the backend probe would
# return `unavailable'.
emacs_has_x=no
if emacs --batch -Q --eval \
     "(kill-emacs (if (fboundp 'x-create-frame) 0 1))" >/dev/null 2>&1; then
  emacs_has_x=yes
fi
if [ "$emacs_has_x" != yes ]; then
  echo "SKIP spawn_emacs/xvfb-run    (emacs built without X support)"
elif command -v xvfb-run >/dev/null 2>&1; then
  ID=$((ID + 1))
  jq -nc --argjson id "$ID" \
    '{jsonrpc:"2.0", id:$id, method:"tools/call",
      params:{name:"spawn_emacs",
              arguments:{display_mode:"xvfb-run"}}}' >&3
  IFS= read -r -t 30 -u 4 xvfb_spawn_line
  xvfb_spawn_text="$(jq -r '.result.content[0].text' <<<"$xvfb_spawn_line")"
  xvfb_handle="$(jq -r '.handle' <<<"$xvfb_spawn_text")"
  if [ -z "$xvfb_handle" ] || [ "$xvfb_handle" = "null" ]; then
    printf 'FAIL %-22s body=%s\n' spawn_emacs/xvfb-run "$xvfb_spawn_line"
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("spawn_emacs/xvfb-run")
  else
    printf 'PASS %-22s handle=%s\n' spawn_emacs/xvfb-run "$xvfb_handle"
    PASS=$((PASS + 1))
    # Create a graphical frame inside the spawn so `screenshot_frame'
    # has something to export, and reset the cached backend probe so
    # the next call re-evaluates `display-graphic-p'.
    frame_form='(progn
                  (setq emacs-devtools-mcp-tools-gui--host-backend nil)
                  (setq emacs-devtools-mcp-screenshot-max-pixels (cons 4096 4096))
                  (select-frame
                    (make-frame-on-display (getenv "DISPLAY")
                                           (quote ((name . "edmcp-e2e-xvfb")
                                                   (width . 40)
                                                   (height . 12)))))
                  t)'
    call eval_elisp          "$(jq -nc --arg h "$xvfb_handle" --arg f "$frame_form" \
      '{form:$f, target:{spawn:$h}}')"
    call screenshot_frame    "$(jq -nc --arg h "$xvfb_handle" \
      '{target:{spawn:$h}}')"
    call kill_spawn          "$(jq -nc --arg h "$xvfb_handle" '{handle:$h}')"
  fi
else
  echo "SKIP spawn_emacs/xvfb-run    (xvfb-run not in PATH)"
fi

# --- Negative case: protocol-level error path through the relay ---
ID=$((ID + 1))
jq -nc --argjson id "$ID" \
  '{jsonrpc:"2.0", id:$id, method:"tools/call",
    params:{name:"no_such_tool", arguments:{}}}' >&3
IFS= read -r -t 10 -u 4 unk_line
unk_code="$(jq -r '.error.code // empty' <<<"$unk_line")"
if [ "$unk_code" = "-32601" ]; then
  printf 'PASS %-22s code=-32601\n' '(unknown tool)'
  PASS=$((PASS + 1))
else
  printf 'FAIL %-22s body=%s\n' '(unknown tool)' "$unk_line"
  FAIL=$((FAIL + 1))
fi

# Unknown *method* (not just unknown tool) must also be -32601.
ID=$((ID + 1))
jq -nc --argjson id "$ID" \
  '{jsonrpc:"2.0", id:$id, method:"resources/list", params:{}}' >&3
IFS= read -r -t 10 -u 4 meth_line
meth_code="$(jq -r '.error.code // empty' <<<"$meth_line")"
if [ "$meth_code" = "-32601" ]; then
  printf 'PASS %-22s code=-32601\n' '(unknown method)'
  PASS=$((PASS + 1))
else
  printf 'FAIL %-22s body=%s\n' '(unknown method)' "$meth_line"
  FAIL=$((FAIL + 1))
fi

# Schema-invalid args path -- ping accepts an optional message *string*.
ID=$((ID + 1))
jq -nc --argjson id "$ID" \
  '{jsonrpc:"2.0", id:$id, method:"tools/call",
    params:{name:"ping", arguments:{message:42}}}' >&3
IFS= read -r -t 10 -u 4 bad_line
bad_code="$(jq -r '.error.code // empty' <<<"$bad_line")"
if [ "$bad_code" = "-32602" ]; then
  printf 'PASS %-22s code=-32602\n' '(schema-invalid)'
  PASS=$((PASS + 1))
else
  printf 'FAIL %-22s body=%s\n' '(schema-invalid)' "$bad_line"
  FAIL=$((FAIL + 1))
fi

echo
echo "summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
