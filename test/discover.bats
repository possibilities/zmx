#!/usr/bin/env bats
# `list --json`, `inspect`, `--where`: report sessions, change nothing.

load test_helper
bats_require_minimum_version 1.5.0

# A session whose daemon is gone but whose socket file remains: what a
# supervisor finds after a crash, and what the plain list sweeps up.
make_refused() {
  local name="$1"
  "$ZMX" create "$name" /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session "$name"
  local pid
  pid=$(pgrep -f "zmx create $name " | head -1)
  kill -9 "$pid"
  sleep 0.3
  [ -S "$ZMX_DIR/$name" ]
}

@test "list --json: every session as an array, live and refused alike" {
  "$ZMX" create --labels "owner=t profile=p1" d-live /bin/sh -c 'sleep 30' >/dev/null
  make_refused d-dead

  run "$ZMX" list --json
  [ "$status" -eq 0 ]
  [[ "$output" == '[{"name":"d-dead","socketPath":"'"$ZMX_DIR"'/d-dead","state":"refused","detail":"ConnectionRefused"},{"name":"d-live","socketPath":"'"$ZMX_DIR"'/d-live","state":"live","pid":'*',"clients":0,"createdAt":'*',"cmd":"/bin/sh -c '"'"'sleep 30'"'"'","cwd":"file://'*'","labels":{"owner":"t","profile":"p1"},"lifecycle":"running","protocol":{"minVersion":1,"maxVersion":1,"capabilities":0}}]' ]]

  # Reporting the refused socket did not delete it.
  [ -S "$ZMX_DIR/d-dead" ]
}

@test "list --json: empty directory is an empty array, exit 0" {
  run "$ZMX" list --json
  [ "$status" -eq 0 ]
  [ "$output" == "[]" ]
}

@test "list --where: keeps matching sessions, drops the rest and the unreadable" {
  "$ZMX" create --labels "owner=t profile=p1" d-p1 /bin/sh -c 'sleep 30' >/dev/null
  "$ZMX" create --labels "owner=t profile=p2" d-p2 /bin/sh -c 'sleep 30' >/dev/null
  "$ZMX" create d-unlabelled /bin/sh -c 'sleep 30' >/dev/null
  make_refused d-dead

  run "$ZMX" list --where owner=t --where profile=p2
  [ "$status" -eq 0 ]
  [[ "$output" == *"name=d-p2"* ]]
  [[ "$output" != *"d-p1"* ]]
  [[ "$output" != *"d-unlabelled"* ]]
  [[ "$output" != *"d-dead"* ]]

  run "$ZMX" list --json --where=owner=t
  [[ "$output" == *'"name":"d-p1"'* ]]
  [[ "$output" == *'"name":"d-p2"'* ]]
  [[ "$output" != *'d-dead'* ]]

  # --where is a report, not a sweep.
  [ -S "$ZMX_DIR/d-dead" ]
}

@test "list --where: requires key=value" {
  run "$ZMX" list --where
  [ "$status" -eq 1 ]
  run "$ZMX" list --where nope
  [ "$status" -eq 1 ]
}

@test "inspect: live, refused, and absent, as JSON and prose" {
  "$ZMX" create --labels "owner=t" d-one /bin/sh -c 'sleep 30' >/dev/null
  make_refused d-gone

  run "$ZMX" inspect --json d-one
  [ "$status" -eq 0 ]
  [[ "$output" == '{"name":"d-one","socketPath":"'"$ZMX_DIR"'/d-one","state":"live","pid":'*',"labels":{"owner":"t"},"lifecycle":"running","protocol":{"minVersion":1,"maxVersion":1,"capabilities":0}}' ]]

  run "$ZMX" inspect --json d-gone
  [ "$status" -eq 0 ]
  [ "$output" == '{"name":"d-gone","socketPath":"'"$ZMX_DIR"'/d-gone","state":"refused","detail":"ConnectionRefused"}' ]
  [ -S "$ZMX_DIR/d-gone" ]

  run "$ZMX" inspect --json d-never
  [ "$status" -eq 0 ]
  [ "$output" == '{"name":"d-never","state":"absent"}' ]

  run "$ZMX" inspect d-one
  [ "$status" -eq 0 ]
  [[ "$output" == "name=d-one"$'\n'"state=live"$'\n'"pid="* ]]
  [[ "$output" == *"label.owner=t"$'\n'"protocol=1..1" ]]

  run "$ZMX" inspect d-never
  [ "$output" == "name=d-never"$'\n'"state=absent" ]
}

@test "inspect --where: a session outside the filter reads as absent" {
  "$ZMX" create --labels "owner=other" d-theirs /bin/sh -c 'sleep 30' >/dev/null
  run "$ZMX" inspect --json --where owner=mine d-theirs
  [ "$output" == '{"name":"d-theirs","state":"absent"}' ]
}

@test "inspect: requires a name" {
  run "$ZMX" inspect
  [ "$status" -ne 0 ]
}

@test "plain list still sweeps a refused socket" {
  make_refused d-sweep
  run "$ZMX" list
  [[ "$output" == *"name=d-sweep"*"status=cleaning up"* ]]
  [ ! -e "$ZMX_DIR/d-sweep" ]
}

# ============================================================================
# Exit records
# ============================================================================

@test "exit record: a created session that ends leaves one; attach does not" {
  "$ZMX" create --labels "owner=t" d-ends /bin/sh -c 'exit 7' >/dev/null
  "$ZMX" attach d-plain /bin/sh -c 'exit 3' </dev/null >/dev/null 2>&1 || true
  # The daemon writes the record during its teardown, after the socket goes.
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-ends.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  [ -e "$ZMX_DIR/exited/d-ends.json" ]
  sleep 0.5
  [ ! -e "$ZMX_DIR/exited/d-plain.json" ]

  run "$ZMX" inspect --json d-ends
  [[ "$output" == '{"name":"d-ends","socketPath":"'"$ZMX_DIR"'/d-ends","state":"exited","pid":'*',"createdAt":'*',"labels":{"owner":"t"},"lifecycle":"exited","exit":{"code":7,"signal":0,"reason":"natural","endedAt":'*'}}' ]]

  run "$ZMX" inspect d-ends
  [[ "$output" == *"state=exited"*"exit_code=7"*"reason=natural"*"label.owner=t" ]]
}

@test "exit record: a kill is recorded as requested, with the signal" {
  "$ZMX" create d-killed /bin/sh -c 'sleep 30' >/dev/null
  "$ZMX" kill d-killed >/dev/null
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-killed.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  run "$ZMX" inspect --json d-killed
  [[ "$output" == *'"exit":{"code":0,"signal":1,"reason":"requested","endedAt":'* ]]
}

@test "exit record: a command that never started is recorded as exec_failure" {
  run "$ZMX" create --json d-noexec /nonexistent/program
  [ "$status" -eq 1 ]
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-noexec.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  run "$ZMX" inspect --json d-noexec
  [[ "$output" == *'"reason":"exec_failure"'* ]]
}

@test "exit record: list --json includes exited sessions, --where filters them" {
  "$ZMX" create --labels "owner=t" d-gone /bin/sh -c 'exit 0' >/dev/null
  "$ZMX" create --labels "owner=t" d-here /bin/sh -c 'sleep 30' >/dev/null
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-gone.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done

  run "$ZMX" list --json
  [[ "$output" == '[{"name":"d-here",'*'"state":"live"'*'},{"name":"d-gone",'*'"state":"exited"'*'}]' ]]
  run "$ZMX" list --json --where owner=t
  [[ "$output" == *'"name":"d-gone"'* ]]
  run "$ZMX" list --json --where owner=u
  [ "$output" == "[]" ]
}

@test "exit record: forget removes it, idempotently; create replaces it" {
  "$ZMX" create d-again /bin/sh -c 'exit 1' >/dev/null
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-again.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done

  run "$ZMX" forget d-again
  [ "$status" -eq 0 ]
  [ "$output" == 'forgot session "d-again"' ]
  [ ! -e "$ZMX_DIR/exited/d-again.json" ]
  run "$ZMX" forget d-again
  [ "$status" -eq 0 ]
  [ "$output" == 'no exit record for session "d-again"' ]
  run "$ZMX" inspect --json d-again
  [ "$output" == '{"name":"d-again","state":"absent"}' ]

  "$ZMX" create d-again /bin/sh -c 'exit 2' >/dev/null
  i=0
  while [[ ! -e "$ZMX_DIR/exited/d-again.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  run "$ZMX" create --json d-again /bin/sh -c 'sleep 30'
  [ "$status" -eq 0 ]
  [ ! -e "$ZMX_DIR/exited/d-again.json" ]
}

@test "exit record: one that cannot be read is reported, not treated as absent" {
  mkdir -p "$ZMX_DIR/exited"
  printf '{"name":' > "$ZMX_DIR/exited/d-bad.json"
  run "$ZMX" inspect --json d-bad
  [ "$output" == '{"name":"d-bad","socketPath":"'"$ZMX_DIR"'/d-bad","state":"exited","detail":"MalformedExitRecord"}' ]
  run "$ZMX" list --json
  [[ "$output" == *'"detail":"MalformedExitRecord"'* ]]
}

@test "a session cannot be named after zmx's own directories" {
  run "$ZMX" create --json exited /bin/sh -c 'sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == '{"ok":false,"name":"exited","error":"InvalidName",'*'"detail":"SessionNameReserved"}' ]]
  [ ! -e "$ZMX_DIR/exited" ] || [ -d "$ZMX_DIR/exited" ]
  run "$ZMX" create --json logs /bin/sh -c 'sleep 30'
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"InvalidName"'* ]]
}

@test "a name is never absent between its socket and its record" {
  "$ZMX" create d-gap /bin/sh -c 'exit 5' >/dev/null
  # Poll hard across the teardown: refused, then exited, never absent.
  local seen=""
  for i in $(seq 1 40); do
    local state
    state=$("$ZMX" inspect --json d-gap | sed -E 's/.*"state":"([a-z]+)".*/\1/')
    [ "$state" == "absent" ] && { echo "saw absent during teardown after: $seen" >&2; false; }
    seen="$seen $state"
    [ "$state" == "exited" ] && break
    sleep 0.05
  done
  [[ "$seen" == *exited* ]]
}

@test "a record from an earlier session never sits next to a live one" {
  "$ZMX" create --labels gen=1 d-reuse /bin/sh -c 'sleep 30' >/dev/null
  "$ZMX" kill d-reuse >/dev/null
  # Immediately, inside the old daemon's teardown grace.
  "$ZMX" create --labels gen=2 d-reuse /bin/sh -c 'sleep 30' >/dev/null
  sleep 1.2
  run "$ZMX" inspect --json d-reuse
  [[ "$output" == *'"state":"live"'*'"gen":"2"'* ]]
  [ ! -e "$ZMX_DIR/exited/d-reuse.json" ]
}

@test "a non-create session start clears an earlier record of that name" {
  "$ZMX" create d-mixed /bin/sh -c 'exit 7' >/dev/null
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-mixed.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  "$ZMX" run d-mixed -d true >/dev/null
  wait_for_session d-mixed
  [ ! -e "$ZMX_DIR/exited/d-mixed.json" ]
  run "$ZMX" inspect --json d-mixed
  [[ "$output" == *'"state":"live"'* ]]
}

@test "the daemon's own end is recorded as requested, not as the child's doing" {
  "$ZMX" create d-term /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session d-term
  # The daemon is the child's parent; pgrep on an argv bats may have
  # rewritten is not something to depend on.
  local child daemon
  child=$("$ZMX" inspect --json d-term | sed -E 's/.*"pid":([0-9]+).*/\1/')
  daemon=$(ps -o ppid= -p "$child" | tr -d ' ')
  kill -TERM "$daemon"
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-term.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  run "$ZMX" inspect --json d-term
  [[ "$output" == *'"reason":"requested"'* ]]
}

@test "a cmd that is not valid UTF-8 stays a JSON string" {
  "$ZMX" create d-utf8 /bin/sh -c "$(printf 'sleep 30 #\xff\xfe')" >/dev/null
  run "$ZMX" inspect --json d-utf8
  [[ "$output" == *'"cmd":"'*'"'* ]]
  [[ "$output" != *'"cmd":['* ]]
}

@test "--where filters exited sessions in the text list too" {
  "$ZMX" create --labels owner=t d-w1 /bin/sh -c 'exit 0' >/dev/null
  "$ZMX" create --labels owner=u d-w2 /bin/sh -c 'exit 0' >/dev/null
  local i=0
  while [[ ! -e "$ZMX_DIR/exited/d-w2.json" && $i -lt 50 ]]; do sleep 0.1; (( i++ )) || true; done
  run "$ZMX" list --where owner=t
  [[ "$output" == *"name=d-w1"*"state=exited"*"owner=t"* ]]
  [[ "$output" != *"d-w2"* ]]
}
