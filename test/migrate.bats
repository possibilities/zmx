#!/usr/bin/env bats
# `zmx migrate`: handing a live session to another build without restarting
# the child.

load test_helper
bats_require_minimum_version 1.5.0

# The pid the daemon reports is the child's, which is exactly the number a
# migration must not change.
child_pid() {
  "$ZMX" list --json | sed -E 's/.*"name":"'"$1"'"[^}]*"pid":([0-9]+).*/\1/'
}

# The daemon that took a session over, if there is one. Matched on the
# handoff socket path it was executed with, which keeps it inside this test's
# own directory: other zmx sessions may be running on this machine.
importer_pid() {
  pgrep -f "__migrate-import $ZMX_DIR/" | head -1
}

# A daemon outlives its socket file by the moment it takes to finish tearing
# down, so "gone" is polled here too.
wait_for_no_importer() {
  local timeout="${1:-5}" i=0
  while (( i < timeout * 10 )); do
    [[ -z "$(importer_pid)" ]] && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for the importing daemon to exit:" >&2
  pgrep -fl "__migrate-import $ZMX_DIR/" >&2
  return 1
}

wait_for_gone() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    [[ ! -e "$ZMX_DIR/$name" ]] && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name' to go away" >&2
  return 1
}

@test "migrate: the child keeps running under a new daemon" {
  "$ZMX" create m-live /bin/sh -c 'echo MARKER-ONE; sleep 30' >/dev/null
  wait_for_output m-live MARKER-ONE

  local before after
  before=$(child_pid m-live)
  [ -n "$before" ]
  # The daemon holding the session right now is not an importer.
  [ -z "$(importer_pid)" ]

  run "$ZMX" migrate m-live
  [ "$status" -eq 0 ]
  [[ "$output" == "migrated session m-live to "*"/zmx" ]]

  after=$(child_pid m-live)
  [ "$before" = "$after" ]
  kill -0 "$after"

  # A different process is the session now.
  [ -n "$(importer_pid)" ]

  run "$ZMX" list --short
  [[ "$output" == "m-live" ]]
}

@test "migrate: the terminal the daemon was showing survives" {
  "$ZMX" create m-screen /bin/sh -c 'echo BEFORE-HANDOFF; sleep 30' >/dev/null
  wait_for_output m-screen BEFORE-HANDOFF

  "$ZMX" migrate m-screen
  run "$ZMX" history m-screen
  [[ "$output" == *"BEFORE-HANDOFF"* ]]

  # And the new daemon is still reading the pty: what the child writes after
  # the swap reaches the same terminal.
  "$ZMX" send m-screen 'echo AFTER-HANDOFF
'
  wait_for_output m-screen AFTER-HANDOFF
}

@test "migrate: output crossing the swap is neither lost nor repeated" {
  # The seam is where a handoff can quietly cost a screenful: the shadow
  # terminal is the session's memory, and a migration that ate part of it
  # would erode the session a little at a time.
  "$ZMX" create --scrollback-lines 6000 m-stream /bin/sh -c \
    'i=1; while [ $i -le 1200 ]; do echo "L$i"; i=$((i+1)); done; echo ALLDONE; sleep 30' >/dev/null
  # Deliberately mid-stream: the child is still writing when the swap runs.
  sleep 0.1
  "$ZMX" migrate m-stream
  wait_for_output m-stream ALLDONE 10

  run bash -c "'$ZMX' history m-stream | grep -c '^L[0-9]*$'"
  [ "$output" = "1200" ]

  # Every line exactly once, in order, across the point where the daemon
  # changed underneath the child.
  run bash -c "'$ZMX' history m-stream | grep '^L[0-9]*$' | sed 's/^L//' | sort -n | uniq -d"
  [ -z "$output" ]
  run bash -c "'$ZMX' history m-stream | grep '^L[0-9]*$' | sed 's/^L//' | head -1"
  [ "$output" = "1" ]
  run bash -c "'$ZMX' history m-stream | grep '^L[0-9]*$' | sed 's/^L//' | tail -1"
  [ "$output" = "1200" ]
}

@test "migrate: labels, command, and creation time cross unchanged" {
  "$ZMX" create --labels "role=agent tier=one" m-meta /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session m-meta
  local created_before
  created_before=$("$ZMX" inspect m-meta --json | sed -E 's/.*"createdAt":([0-9]+).*/\1/')

  "$ZMX" migrate m-meta

  run "$ZMX" get m-meta
  [[ "$output" == *"role=agent"* ]]
  [[ "$output" == *"tier=one"* ]]

  run "$ZMX" inspect m-meta --json
  [[ "$output" == *'"createdAt":'"$created_before"* ]]
  [[ "$output" == *'"cmd":"/bin/sh -c '"'"'sleep 30'"'"'"'* ]]
}

@test "migrate: a session can be handed on more than once" {
  "$ZMX" create m-twice /bin/sh -c 'echo CHAINED; sleep 30' >/dev/null
  wait_for_output m-twice CHAINED
  local before
  before=$(child_pid m-twice)

  "$ZMX" migrate m-twice
  "$ZMX" migrate m-twice

  [ "$(child_pid m-twice)" = "$before" ]
  run "$ZMX" history m-twice
  [[ "$output" == *"CHAINED"* ]]
}

@test "migrate: the final-client policy comes back disarmed, not armed at nobody" {
  "$ZMX" create --exit-on-last-client m-policy /bin/sh -c 'echo ARMED; sleep 30' >/dev/null
  wait_for_output m-policy ARMED

  # Arm it the only way it arms: a real terminal attaches.
  script -q /dev/null "$ZMX" attach m-policy >/dev/null 2>&1 &
  local client=$!
  sleep 1
  "$ZMX" migrate m-policy
  # The swap took the client away; it did not leave.
  kill "$client" 2>/dev/null || true
  sleep 1

  # The session survives, which is the whole point of migrating it, and it is
  # now in the state a created session is in before its first attach.
  run "$ZMX" list --short
  [[ "$output" == "m-policy" ]]

  # And the policy still means what it says: the next terminal to attach and
  # leave ends the session.
  script -q /dev/null "$ZMX" attach m-policy >/dev/null 2>&1 &
  local second=$!
  sleep 1
  kill "$second" 2>/dev/null || true
  wait_for_gone m-policy 10
}

@test "migrate: after a handoff the exit is reported without a status" {
  "$ZMX" create m-exit /bin/sh -c 'sleep 1; exit 7' >/dev/null
  wait_for_session m-exit
  "$ZMX" migrate m-exit
  wait_for_gone m-exit

  # The daemon that watched it end had not forked it, so it could not learn
  # the 7. Saying so beats reporting a zero nobody observed.
  run "$ZMX" inspect m-exit --json
  [[ "$output" == *'"state":"exited"'* ]]
  [[ "$output" == *'"code":null'* ]]
  [[ "$output" == *'"signal":null'* ]]
  [[ "$output" == *'"reason":"natural"'* ]]
}

@test "migrate: a session nobody handed on still reports its exact status" {
  "$ZMX" create m-exact /bin/sh -c 'sleep 1; exit 7' >/dev/null
  wait_for_session m-exact
  wait_for_gone m-exact

  run "$ZMX" inspect m-exact --json
  [[ "$output" == *'"code":7'* ]]
  [[ "$output" == *'"signal":0'* ]]
}

@test "migrate: a target that cannot be run leaves the session alone" {
  "$ZMX" create m-badexe /bin/sh -c 'echo STILL-HERE; sleep 30' >/dev/null
  wait_for_output m-badexe STILL-HERE
  local before
  before=$(child_pid m-badexe)

  run "$ZMX" migrate m-badexe --to /nonexistent/zmx
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot resolve"* ]]

  # A path that exists but is not a zmx is refused by the daemon rather than
  # by the client, which is the case that has to roll back.
  run "$ZMX" migrate m-badexe --to /etc/hosts
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused to migrate"* ]]

  [ "$(child_pid m-badexe)" = "$before" ]
  run "$ZMX" history m-badexe
  [[ "$output" == *"STILL-HERE"* ]]
}

@test "migrate: a rolled-back handoff leaves no importer behind" {
  "$ZMX" create m-noleak /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session m-noleak
  run "$ZMX" migrate m-noleak --to /etc/hosts
  [ "$status" -eq 1 ]

  # Nothing is left holding the handoff socket, and no half-started daemon.
  wait_for_no_importer
  run bash -c "ls '$ZMX_DIR/logs' | grep -c '\.sock$' || true"
  [[ "$output" == "0" ]]
}

@test "migrate: a stalled importer times out, is reaped, and leaves live IO" {
  "$ZMX" create --scrollback-lines 5000 m-stalled /bin/sh -c \
    'i=1; while [ $i -le 4000 ]; do printf "line %04d: abcdefghijklmnopqrstuvwxyz0123456789\n" "$i"; i=$((i+1)); done; echo READY; while read -r line; do echo "got:$line"; done' >/dev/null
  wait_for_output m-stalled READY
  cat > "$BATS_TEST_TMPDIR/stalled-importer" <<'PY'
#!/usr/bin/env python3
import os, socket, sys, time
with open(os.environ['ZMX_DIR'] + '/logs/stalled.pid', 'w') as f:
    f.write(str(os.getpid()))
peer = socket.socket(socket.AF_UNIX)
peer.connect(sys.argv[2])
peer.sendall(sys.argv[3].encode())
time.sleep(30)
PY
  chmod +x "$BATS_TEST_TMPDIR/stalled-importer"
  local before importer
  before=$(child_pid m-stalled)
  run timeout 15 "$ZMX" migrate m-stalled --to "$BATS_TEST_TMPDIR/stalled-importer"
  importer=$(cat "$ZMX_DIR/logs/stalled.pid")
  [ "$status" -eq 1 ]
  [[ "$output" == *Timeout* ]]
  ! kill -0 "$importer" 2>/dev/null
  [ "$(child_pid m-stalled)" = "$before" ]
  "$ZMX" send m-stalled 'ALIVE
'
  wait_for_output m-stalled got:ALIVE
  wait_for_no_importer
}

@test "migrate: an unknown session is an error, not a new one" {
  run "$ZMX" migrate m-absent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or unresponsive"* ]]
  run "$ZMX" list --short
  [[ "$output" != *"m-absent"* ]]
}

@test "migrate: the migrated session still answers kill" {
  "$ZMX" create m-kill /bin/sh -c 'sleep 30' >/dev/null
  wait_for_session m-kill
  "$ZMX" migrate m-kill

  run "$ZMX" kill m-kill
  [ "$status" -eq 0 ]
  wait_for_gone m-kill
  wait_for_no_importer
}

@test "migrate: incomplete escape and UTF-8 output refuse until completed" {
  local suffix prefix ending expected
  for suffix in escape utf8; do
    if [[ "$suffix" == escape ]]; then
      prefix='\033[3'; ending='1mRED\033[0m\n'; expected=RED
    else
      prefix='\342\202'; ending='\254\n'; expected='€'
    fi
    "$ZMX" create "m-$suffix" /bin/sh -c \
      'printf "BEFORE\r\n$1"; while [ ! -f "$3" ]; do sleep 0.05; done; printf "$2"; sleep 30' \
      sh "$prefix" "$ending" "$BATS_TEST_TMPDIR/go-$suffix" >/dev/null
    wait_for_output "m-$suffix" BEFORE
    run "$ZMX" migrate "m-$suffix"
    [ "$status" -eq 1 ]
    [[ "$output" == *"terminal output sequence is incomplete"* ]]
    touch "$BATS_TEST_TMPDIR/go-$suffix"
    wait_for_output "m-$suffix" "$expected"
    "$ZMX" migrate "m-$suffix"
    run "$ZMX" history "m-$suffix"
    [[ "$output" == *"$expected"* ]]
  done
}

@test "migrate: pending wrap survives before the child's next character" {
  "$ZMX" create m-wrap /bin/sh -c \
    'printf "%080d" 0; while [ ! -f "$1" ]; do sleep 0.05; done; printf "NEXT\n"; sleep 30' \
    sh "$BATS_TEST_TMPDIR/go-wrap" >/dev/null
  wait_for_output m-wrap 00000000
  "$ZMX" migrate m-wrap
  touch "$BATS_TEST_TMPDIR/go-wrap"
  wait_for_output m-wrap NEXT
  run "$ZMX" history m-wrap
  # A CUP without pending-wrap preservation overwrites the final zero.
  [[ "$output" == *"$(printf '%080d' 0)"* ]]
}

@test "migrate: leaving alternate screen restores the primary saved wrap" {
  "$ZMX" create m-saved-wrap /bin/sh -c \
    'printf "%080d" 0; printf "\033[?1049hALTERNATE"; while [ ! -f "$1" ]; do sleep 0.05; done; printf "\033[?1049lNEXT\n"; sleep 30' \
    sh "$BATS_TEST_TMPDIR/go-saved-wrap" >/dev/null
  wait_for_output m-saved-wrap ALTERNATE
  "$ZMX" migrate m-saved-wrap
  touch "$BATS_TEST_TMPDIR/go-saved-wrap"
  wait_for_output m-saved-wrap NEXT
  run "$ZMX" history m-saved-wrap
  [[ "$output" == *"$(printf '%080d' 0)"* ]]
}

@test "migrate: a target using another directory refuses without touching either session" {
  "$ZMX" create m-dir /bin/sh -c 'echo SOURCE; sleep 30' >/dev/null
  wait_for_output m-dir SOURCE
  local other="$BATS_TEST_TMPDIR/other"
  ZMX_DIR="$other" "$ZMX" create m-dir /bin/sh -c 'echo TARGET; sleep 30' >/dev/null
  cat > "$BATS_TEST_TMPDIR/other-zmx" <<EOF
#!/bin/sh
export ZMX_DIR='$other'
exec '$ZMX' "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/other-zmx"
  run "$ZMX" migrate m-dir --to "$BATS_TEST_TMPDIR/other-zmx"
  [ "$status" -eq 1 ]
  run "$ZMX" history m-dir
  [[ "$output" == *SOURCE* ]]
  run env ZMX_DIR="$other" "$ZMX" history m-dir
  [[ "$output" == *TARGET* ]]
  ZMX_DIR="$other" "$ZMX" kill --force m-dir
  wait_for_no_importer
}
