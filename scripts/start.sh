#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"
if [[ "${1:-}" == "--mock" ]]; then
    shift
    exec python3 "$ROOT/scripts/demo.py" "$@"
fi
exec "$ROOT/dist/Hush.app/Contents/MacOS/Hush" "$@"
