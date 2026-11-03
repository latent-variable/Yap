#!/usr/bin/env bash
# Guard against accidentally turning the hotkey implementation into a keylogger.
set -euo pipefail
cd "$(dirname "$0")/.."

global="$(grep -RIn 'addGlobalMonitorForEvents' app/Sources || true)"
if [ -n "$global" ]; then
  # The one permitted global monitor is modifier-state-only in HotKey.swift.
  if printf '%s\n' "$global" | grep -vE 'app/Sources/Yap/HotKey\.swift:.*addGlobalMonitorForEvents\(matching: \.flagsChanged\)' ; then
    echo "input-monitor policy violation: global monitor may observe more than modifier state" >&2
    exit 1
  fi
  [ "$(printf '%s\n' "$global" | wc -l | tr -d ' ')" = "1" ] || {
    echo "input-monitor policy violation: expected exactly one global modifier monitor" >&2
    exit 1
  }
fi

# Key-down capture is allowed only in the Settings shortcut recorder, where it
# is scoped to the active recording and removed immediately afterward.
local_keydown="$(grep -RIn 'addLocalMonitorForEvents' app/Sources | grep -E 'keyDown|\.keyDown' || true)"
if [ -n "$local_keydown" ]; then
  if printf '%s\n' "$local_keydown" | grep -v 'app/Sources/Yap/Views/SettingsView.swift:'; then
    echo "input-monitor policy violation: local key-down monitor outside Settings recorder" >&2
    exit 1
  fi
fi

# These APIs capture global keyboard input rather than the specific hotkey chord.
if grep -RInE 'CGEventTapCreate|IOHIDManagerCreate|IOHIDDeviceOpen|pynput|keyboard\.hook' \
  app/Sources backend; then
  echo "input-monitor policy violation: low-level keyboard capture API found" >&2
  exit 1
fi

echo "input-monitor policy: no global key-down/character capture"
