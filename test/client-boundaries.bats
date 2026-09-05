#!/usr/bin/env bats
load test_helper

@test "malformed control frames drop their peer and leave the Session alive" {
  run python3 "$BATS_TEST_DIRNAME/client-boundaries.py" "$ZMX" malformed
  [ "$status" -eq 0 ]
}

@test "Write preserves a literal destination containing an apostrophe" {
  run python3 "$BATS_TEST_DIRNAME/client-boundaries.py" "$ZMX" quoted
  [ "$status" -eq 0 ]
}
