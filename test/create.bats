#!/usr/bin/env bats
# `zmx create`: create-only, returns on an acknowledged exec, structured.

load test_helper
bats_require_minimum_version 1.5.0

# Helper: the daemon lingers briefly after its child ends (SIGHUP, 500ms,
# SIGKILL, then the socket is removed), so "gone" has to be polled.
wait_for_gone() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if [[ ! -e "$ZMX_DIR/$name" ]]; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name' to go away" >&2
  return 1
}

# Helper: wait until no process's command line matches the pattern. The
# daemon's argv is the create command line, so this covers the daemon, the
# pty child, and anything it spawned.
wait_for_no_process() {
  local pattern="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if ! pgrep -f "$pattern" >/dev/null; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for processes matching '$pattern' to exit:" >&2
  pgrep -fl "$pattern" >&2
  return 1
}

@test "create: returns once the command is running" {
  run "$ZMX" create --json c-ok /bin/sh -c 'echo ready; sleep 30'
  [ "$status" -eq 0 ]
  [[ "$output" == '{"ok":true,"name":"c-ok","socketPath":"'"$ZMX_DIR"'/c-ok","pid":'*',"createdAt":'* ]]

  # The pid is the child's, and it is alive.
  local pid
  pid=$(printf '%s' "$output" | sed -E 's/.*"pid":([0-9]+).*/\1/')
  kill -0 "$pid"

  run "$ZMX" list --short
  [[ "$output" == "c-ok" ]]
}

@test "create: prose form says created, like attach" {
  run "$ZMX" create c-prose /bin/sh -c 'sleep 30'
  [ "$status" -eq 0 ]
  [[ "$output" == 'session "c-prose" created' ]]
}

@test "create: a taken name is AlreadyExists, and the command is not run" {
  "$ZMX" create c-dup /bin/sh -c 'sleep 30' >/dev/null
  run "$ZMX" create --json c-dup /bin/sh -c 'touch "$ZMX_DIR/never"; sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"c-dup","socketPath":"'"$ZMX_DIR"'/c-dup","error":"AlreadyExists",'* ]]
  sleep 0.3
  [ ! -e "$ZMX_DIR/never" ]
}

@test "create: a command that cannot start is ExecFailed with no orphan" {
  run "$ZMX" create --json c-noexec /nonexistent/program --flag
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"c-noexec","error":"ExecFailed","message":"session \"c-noexec\": command failed to start: FileNotFound","detail":"FileNotFound"}' ]]

  wait_for_gone c-noexec
  run "$ZMX" list --short
  [[ "$output" == "" ]]
  # Neither the daemon nor a child survives a command that never started.
  wait_for_no_process 'nonexistent/program'
}

@test "create: prose exec failure goes to stderr with exit 1" {
  run --separate-stderr "$ZMX" create c-noexec2 /nonexistent/program
  [ "$status" -eq 1 ]
  [ "$output" == "" ]
  [[ "$stderr" == 'error: session "c-noexec2": command failed to start: FileNotFound' ]]
}

@test "create: the session is born with its labels" {
  run "$ZMX" create --json --labels "owner=fmx instance=abc" c-labels /bin/sh -c 'sleep 30'
  [ "$status" -eq 0 ]
  run "$ZMX" get c-labels
  [[ "$output" == "instance=abc owner=fmx" ]]
}

@test "create: a bad label is refused before anything exists" {
  run "$ZMX" create --json --labels "name=x" c-badlabel /bin/sh -c 'sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"c-badlabel","error":"InvalidLabel",'* ]]
  [ ! -e "$ZMX_DIR/c-badlabel" ]
}

@test "create: requires a command" {
  run "$ZMX" create --json c-nocmd
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"c-nocmd","error":"CommandRequired",'* ]]
  [ ! -e "$ZMX_DIR/c-nocmd" ]
}

@test "create: argv goes straight to exec, -- separates it" {
  run "$ZMX" create --json c-argv -- /bin/sh -c 'printf "%s|" "$@"; sleep 30' x --json 'a b' "--"
  [ "$status" -eq 0 ]
  sleep 0.5
  run "$ZMX" history c-argv
  [[ "$output" == *'--json|a b|--|'* ]]
}

@test "create: a stale socket is replaced" {
  "$ZMX" create c-stale /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session c-stale
  # Kill the daemon outright so the socket file stays behind, refused.
  local pid
  pid=$(pgrep -f "zmx create c-stale" | head -1)
  kill -9 "$pid"
  sleep 0.3
  [ -e "$ZMX_DIR/c-stale" ]

  run "$ZMX" create --json c-stale /bin/sh -c 'sleep 30'
  [ "$status" -eq 0 ]
  [[ "$output" == '{"ok":true,'* ]]
}

@test "create --help shows help without creating a session" {
  run "$ZMX" create --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  run "$ZMX" list --short
  [[ "$output" == "" ]]
}

@test "create --scrollback-lines: the restore keeps that many lines" {
  # Lines short enough never to wrap: the limit counts screen rows, so a
  # wrapped line would make retention depend on the terminal's width.
  local gen='seq -f "%05g ......................." 1 3000; sleep 60'
  "$ZMX" create --scrollback-lines 2500 c-sb /bin/sh -c "$gen" >/dev/null
  ZMX_SCROLLBACK_LINES=100 "$ZMX" create c-sb-env /bin/sh -c "$gen" >/dev/null
  local i=0
  while (( i < 100 )); do
    "$ZMX" history c-sb | grep -q '^03000 ' && "$ZMX" history c-sb-env | grep -q '^03000 ' && break
    sleep 0.1; (( i++ )) || true
  done
  sleep 0.3

  # ghostty frees whole pages, so a limit is an upper bound, and its floor
  # is one page -- which is larger on a wide terminal. Hence generous
  # bounds: what must hold is that each limit is respected and they differ.
  local big small
  big=$("$ZMX" history c-sb | grep -c '^0[0-9]\{4\} ')
  small=$("$ZMX" history c-sb-env | grep -c '^0[0-9]\{4\} ')
  (( big >= 1500 && big <= 2600 )) || { echo "c-sb kept $big lines for a 2500 limit" >&2; false; }
  (( small >= 24 && small <= 1000 )) || { echo "c-sb-env kept $small lines for a 100 limit" >&2; false; }
  (( big > small * 2 )) || { echo "limits did not separate: $big vs $small" >&2; false; }
}

@test "history: a scrollback larger than one frame arrives whole, in several frames" {
  # 76 columns of payload: short enough not to wrap at 80, and 16000 rows
  # stay under the limit at any width, so the whole run is retained.
  local gen='seq -f "%06g ---------------------------------------------------------------" 1 16000; echo FIN; sleep 60'
  "$ZMX" create --scrollback-lines 20000 c-hist /bin/sh -c "$gen" >/dev/null
  local i=0
  while (( i < 400 )); do
    "$ZMX" history c-hist | grep -q '^FIN' && break
    sleep 0.1; (( i++ )) || true
  done

  local bytes
  bytes=$("$ZMX" history c-hist | wc -c | tr -d ' ')
  (( bytes > 1100000 )) || { echo "history is only $bytes bytes" >&2; false; }
  run bash -c "\"$ZMX\" history c-hist | grep -c '^0[0-9]\{5\} '"
  [ "$output" -eq 16000 ]
  run bash -c "\"$ZMX\" history c-hist | head -1 | cut -c1-6"
  [ "$output" == "000001" ]
  # Scoped capture uses its own request/reply tag but the same completion
  # contract. Large captures must reach the CLI whole; screen-only must not
  # accidentally fall back to the complete history.
  run bash -o pipefail -c '
    "$1" history --scrollback 20000 c-hist | grep -c "^0[0-9]\{5\} "
  ' _ "$ZMX"
  [ "$status" -eq 0 ]
  [ "$output" -eq 16000 ]
  run "$ZMX" history --screen c-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIN"* ]]
  [[ "$output" != *"000001 "* ]]
  # And it really crossed the socket in more than one frame -- a daemon
  # that sent one oversized frame would satisfy everything above.
  run grep -c "chunks=[2-9]" "$ZMX_DIR/logs/c-hist.log"
  [ "$output" -ge 1 ]
}

@test "history: a transfer that ends early fails instead of printing a fragment" {
  local gen='seq -f "%06g ---------------------------------------------------------------" 1 16000; echo FIN; sleep 60'
  "$ZMX" create --scrollback-lines 20000 c-cut /bin/sh -c "$gen" >/dev/null
  local i=0
  while (( i < 400 )); do
    "$ZMX" history c-cut | grep -q '^FIN' && break
    sleep 0.1; (( i++ )) || true
  done

  # Kill the daemon while it is answering: whatever reached stdout is a
  # fragment, and the exit status has to say so.
  local child daemon
  child=$("$ZMX" inspect --json c-cut | sed -E 's/.*"pid":([0-9]+).*/\1/')
  daemon=$(ps -o ppid= -p "$child" | tr -d ' ')
  # The killer runs in the background so the client stays in the foreground
  # and `run` can see its status.
  ( sleep 0.02; kill -9 "$daemon" ) &
  run --separate-stderr "$ZMX" history c-cut
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"is incomplete"* ]]
}

@test "create: a timeout larger than poll's int does not panic the creator" {
  run "$ZMX" create --json --timeout-ms 4294967295 c-bigt -- sleep 30
  [ "$status" -eq 0 ]
  [[ "$output" == '{"ok":true,"name":"c-bigt",'* ]]
}

@test "create: the loser of a creation race is told AlreadyExists" {
  local out
  out=$(for i in 1 2 3 4 5 6; do "$ZMX" create --json c-race /bin/sh -c 'sleep 30' & done; wait)
  [ "$(grep -c '"ok":true' <<<"$out")" -eq 1 ]
  [ "$(grep -c '"error":"AlreadyExists"' <<<"$out")" -eq 5 ]
  # No other error, and no Zig trace on stderr.
  [ "$(grep -c '"error":"Internal"' <<<"$out")" -eq 0 ]
}

@test "create: labels that would be silently dropped are refused" {
  # LabelIterator stops at a token with no '=' and drops the rest.
  run "$ZMX" create --json --labels 'a=b c' c-lbl /bin/sh -c 'sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"InvalidLabel"'*': c"}' ]]
  run "$ZMX" create --json --labels 'junk' c-lbl2 /bin/sh -c 'sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"InvalidLabel"'* ]]
  run "$ZMX" list --short
  [ "$output" == "" ]
}

@test "create --json: a usage error answers in JSON, not prose" {
  run "$ZMX" create --json --timeout-ms soon c-usage -- sleep 1
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,'*'"error":"UsageError","message":"--timeout-ms requires a number of milliseconds"}' ]]
  run "$ZMX" create --json --bogus c-usage -- sleep 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"UsageError"'* ]]
  # Without --json the same errors are prose on stderr.
  run --separate-stderr "$ZMX" create --timeout-ms soon c-usage -- sleep 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "error: --timeout-ms requires a number of milliseconds" ]]
}

@test "create: every report names the session the same way, prefix and all" {
  ZMX_SESSION_PREFIX=pre- run "$ZMX" create --json c-pre
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"pre-c-pre","error":"CommandRequired"'* ]]
}
