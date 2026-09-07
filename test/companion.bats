#!/usr/bin/env bats
# Companion builds keep a private session directory separate from stock zmx.
# The legacy /tmp/fmx-<uid>/zmx address stays stable; ZMX_DIR selects a
# consumer's own directory. The version identifies the fork owner.
#
# Default-directory tests exercise the legacy path on this machine and leave
# its log in place. Every session created by the suite uses its private ZMX_DIR.

load test_helper

setup_file() {
  export COMPANION_PREFIX="$BATS_FILE_TMPDIR/companion"
  (cd "$REPO_DIR" && zig build -Dcompanion -Dversion=0.7.0+arthack.bats --prefix "$COMPANION_PREFIX")
}

@test "a companion build defaults to /tmp/fmx-<uid>/zmx and reports its build" {
  run env -u ZMX_DIR -u XDG_RUNTIME_DIR -u XDG_STATE_HOME "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"zmx		0.7.0+arthack.bats"* ]]
  [[ "$output" == *"socket_dir	/tmp/fmx-$(id -u)/zmx"* ]]
  [[ "$output" == *"log_dir		/tmp/fmx-$(id -u)/zmx/logs"* ]]
}

@test "a companion build creates its directory private" {
  local root="$BATS_TEST_TMPDIR/private"
  run env ZMX_DIR="$root/fmx-0/zmx" "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  [ "$(stat -f '%Lp' "$root/fmx-0" 2>/dev/null || stat -c '%a' "$root/fmx-0")" = "700" ]
  [ "$(stat -f '%Lp' "$root/fmx-0/zmx" 2>/dev/null || stat -c '%a' "$root/fmx-0/zmx")" = "700" ]
  [ "$(stat -f '%Lp' "$root/fmx-0/zmx/logs" 2>/dev/null || stat -c '%a' "$root/fmx-0/zmx/logs")" = "700" ]
}

@test "XDG_RUNTIME_DIR does not move a companion build's directory" {
  run env -u ZMX_DIR XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime" "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"socket_dir	/tmp/fmx-$(id -u)/zmx"* ]]
}

@test "ZMX_DIR still overrides a companion build's directory" {
  run "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"socket_dir	$ZMX_DIR"* ]]
  [[ "$output" == *"log_dir		$ZMX_DIR/logs"* ]]
}

@test "a companion build refuses a default directory that is not private" {
  # A directory at the default name that another user could have made, or
  # that others can traverse, would let them reach the sockets in it. The
  # by-hand path applies the same privacy checks as a consumer. The check covers both levels, so it
  # is exercised on a private copy of the layout through ZMX_DIR being unset
  # only when the real default is ours to chmod — which is not a test's to
  # do — and otherwise on the parent, by simulation below.
  local uid; uid="$(id -u)"
  if [[ -e "/tmp/fmx-$uid" && "$(stat -f '%u' "/tmp/fmx-$uid" 2>/dev/null || stat -c '%u' "/tmp/fmx-$uid")" != "$uid" ]]; then
    skip "/tmp/fmx-$uid belongs to someone else on this machine"
  fi
  local existed=0
  [[ -e "/tmp/fmx-$uid" ]] && existed=1
  run env -u ZMX_DIR "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  local mode_before; mode_before="$(stat -f '%Lp' "/tmp/fmx-$uid" 2>/dev/null || stat -c '%a' "/tmp/fmx-$uid")"
  chmod 750 "/tmp/fmx-$uid"
  run env -u ZMX_DIR "$COMPANION_PREFIX/bin/zmx" version
  chmod "$mode_before" "/tmp/fmx-$uid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/tmp/fmx-$uid is readable or writable by others (mode 750); refusing to use it (chmod 700 /tmp/fmx-$uid)"* ]]
  if (( ! existed )); then rm -rf "/tmp/fmx-$uid"; fi
}

@test "a build without -Dcompanion cannot carry an arthack fork version" {
  run zig build -Dversion=0.7.0+arthack.bats --prefix "$BATS_TEST_TMPDIR/refused"
  [ "$status" -ne 0 ]
  [[ "$output" == *"an arthack fork version (+arthack.) needs -Dcompanion"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/refused/bin/zmx" ]
}

@test "a stock build keeps the stock directory" {
  run env -u ZMX_DIR -u XDG_RUNTIME_DIR TMPDIR="$BATS_TEST_TMPDIR" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" "$ZMX" version
  [ "$status" -eq 0 ]
  [[ "$output" != *"/tmp/fmx-"* ]]
  [[ "$output" == *"socket_dir	$BATS_TEST_TMPDIR/zmx-$(id -u)"* ]]
}
