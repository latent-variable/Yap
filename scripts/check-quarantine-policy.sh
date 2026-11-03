#!/usr/bin/env bash
# A downloaded app's quarantine metadata is a Gatekeeper security boundary.
# Runtime and packaging code must never recursively remove it or clear it from
# an app bundle. Users must not be asked to run xattr -cr as an install workaround.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -RInE 'xattr[[:space:]].*(-cr|-dr|-d)[[:space:]].*(com\.apple\.quarantine|\.app)' \
  app/Sources scripts --exclude=check-quarantine-policy.sh; then
  echo "quarantine policy violation: do not strip Gatekeeper quarantine" >&2
  exit 1
fi

echo "quarantine policy: app and packaging code preserve Gatekeeper metadata"
