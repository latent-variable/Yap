#!/usr/bin/env bash
# Fail closed if a code change could introduce global key capture.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
files = list(Path("app/Sources").rglob("*.swift"))
contents = {str(path): path.read_text() for path in files}
recorder_file = "app/Sources/Yap/Views/SettingsView.swift"
hotkey_file = "app/Sources/Yap/HotKey.swift"
recorder = contents[recorder_file]
start = recorder.index("private struct HotKeyRecorder: View {")
end = recorder.index("// MARK: - History", start)
body = recorder[start:end]

global_calls = []
local_key_calls = []
for file, source in contents.items():
    for m in re.finditer(r'addGlobalMonitorForEvents\s*\(\s*matching:\s*([^)]*)\)', source):
        global_calls.append((file, m.group(1).strip()))
    for m in re.finditer(r'addLocalMonitorForEvents\s*\(\s*matching:\s*([^)]*)\)', source):
        if ".keyDown" in m.group(1):
            local_key_calls.append((file, m.group(0)))

assert global_calls == [(hotkey_file, ".flagsChanged")], (
    "global keyboard event monitor expanded", global_calls
)
expected = "addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])"
assert len(local_key_calls) == 1, ("unexpected local key-down monitors", local_key_calls)
assert local_key_calls[0][0] == recorder_file, local_key_calls
assert recorder.count(expected) == 1 and body.count(expected) == 1, (
    "local key-down monitor must only exist inside HotKeyRecorder"
)
assert "recording ? startMonitor() : stopMonitor()" in body, (
    "recorder must only activate monitor while recording"
)
assert ".onDisappear { stopMonitor() }" in body, (
    "recorder monitor must be removed when Settings closes"
)
assert "recording = false\n        stopMonitor()" in body, (
    "recorder monitor must be removed after committing a chord"
)

for file, source in contents.items():
    for api in ("CGEventTapCreate", "IOHIDManagerCreate", "IOHIDDeviceOpen"):
        assert api not in source, ("forbidden global keyboard capture API", file, api)

print("input-monitor policy: only a modifier global monitor and scoped shortcut recorder")
PY
