#!/usr/bin/env bash
# Build the static site and serve it in the foreground on PORT (default 3000).
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
PORT="${PORT:-3000}"
OUT_DIR="$PROJECT_DIR/dist"
SOURCE_DIR="$PROJECT_DIR/public"

time_run() { /usr/bin/time -p "$@"; }

time_run mkdir -p "$OUT_DIR"
time_run cp -R "$SOURCE_DIR/." "$OUT_DIR/"

if [[ ! -f "$OUT_DIR/index.html" ]]; then
  echo "Build output is missing index.html: $OUT_DIR" >&2
  exit 1
fi

if [[ -n "${OPENCODE_WEB_DIR:-}" ]]; then
  time_run mkdir -p "$OPENCODE_WEB_DIR"
  time_run printf '{"project":"%s","directory":"%s"}\n' "$PROJECT_DIR" "$OUT_DIR" \
    > "$OPENCODE_WEB_DIR/deployment-output.json"
fi

echo "Serving $OUT_DIR on http://0.0.0.0:$PORT" >&2
exec /usr/bin/time -p python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$OUT_DIR"
