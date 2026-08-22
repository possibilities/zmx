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
