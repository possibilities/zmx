#!/usr/bin/env bats
# The Companion build (-Dcompanion) keeps fmx's sessions in fmx's directory by
# default — /tmp/fmx-<uid>/zmx, logs under it — so `fmx-zmx list` by hand
# needs no ZMX_DIR and a bare run never touches the directory a stock zmx on
# the same machine uses. ZMX_DIR still overrides it, which is how fmx's own
# tests keep a private directory; -Dversion is what the Companion reports.

load test_helper

setup_file() {
  export COMPANION_PREFIX="$BATS_FILE_TMPDIR/companion"
  (cd "$REPO_DIR" && zig build -Dcompanion -Dversion=0.7.0+fmx.bats --prefix "$COMPANION_PREFIX")
}

@test "a companion build defaults to /tmp/fmx-<uid>/zmx and reports its build" {
  run env -u ZMX_DIR -u XDG_RUNTIME_DIR -u XDG_STATE_HOME "$COMPANION_PREFIX/bin/zmx" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"zmx		0.7.0+fmx.bats"* ]]
  [[ "$output" == *"socket_dir	/tmp/fmx-$(id -u)/zmx"* ]]
  [[ "$output" == *"log_dir		/tmp/fmx-$(id -u)/zmx/logs"* ]]
}

@test "a companion build creates its directory private, the way fmx will accept it" {
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

@test "a stock build keeps the stock directory" {
  run env -u ZMX_DIR -u XDG_RUNTIME_DIR "$ZMX" version
  [ "$status" -eq 0 ]
  [[ "$output" != *"/tmp/fmx-"* ]]
}
