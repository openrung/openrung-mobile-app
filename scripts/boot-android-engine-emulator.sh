#!/usr/bin/env bash
set -euo pipefail

log=/tmp/openrung-emulator.log
emulator_pid=
diagnostics() {
  local status=$?
  if (( status != 0 )); then
    echo "Emulator failed to boot (exit $status)" >&2
    cat "$log" >&2 || true
    timeout 5 adb devices -l || true
    if [[ -n "$emulator_pid" ]]; then kill "$emulator_pid" 2>/dev/null || true; fi
  fi
}
trap diagnostics EXIT

"$ANDROID_HOME/emulator/emulator" -avd openrung-contract -port 5554 \
  -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect \
  > "$log" 2>&1 &
emulator_pid=$!
timeout 15 adb start-server
# Bound BOTH discovery and boot completion. A missing library, failed KVM setup,
# or a dead emulator should print its stderr immediately, not consume the job.
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    wait "$emulator_pid" || exit $?
    exit 1
  fi
  booted=$(timeout 5 adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [[ "$booted" == 1 ]]; then
    echo "Contract emulator ready"
    exit 0
  fi
  sleep 2
done
exit 124
