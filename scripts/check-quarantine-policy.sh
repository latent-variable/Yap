#!/usr/bin/env bash
# Quarantine metadata is a Gatekeeper trust boundary. Enforce a fail-closed
# policy that does not depend on literal .app paths or variable names.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
paths = [*Path("app/Sources").rglob("*.swift"), *Path("scripts").rglob("*.sh")]
for path in paths:
    if path.name == "check-quarantine-policy.sh":
        continue
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "//")):
            continue
        # Even 'xattr -cr "$bundle"' is unsafe: reject executable invocation
        # entirely from app code and packaging scripts. Reading attributes for
        # auditing can happen in a separate test workflow.
        if re.search(r'(?<![\w/])(?:/usr/bin/)?xattr\b', line):
            raise SystemExit(f"{path}:{number}: executable xattr use is forbidden")
        # Also prevent direct calls into Darwin's attribute-removal APIs.
        if re.search(r'\b(?:remove|set|fremove|fset|lremove|lset)xattr\s*\(', line):
            raise SystemExit(f"{path}:{number}: extended-attribute mutation is forbidden")
print("quarantine policy: no runtime/packaging attribute-removal code")
PY
