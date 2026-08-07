#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ ! -x .venv/bin/uvicorn ]; then
  echo "Setup is incomplete. Run ./scripts/setup_mac.sh first."
  exit 1
fi

cleanup() {
  if [ -n "${API_PID:-}" ]; then
    kill "$API_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

.venv/bin/uvicorn backend.app.main:app --host 127.0.0.1 --port 8000 &
API_PID=$!

echo "API:       http://127.0.0.1:8000"
echo "API docs:  http://127.0.0.1:8000/docs"
echo "Dashboard: http://127.0.0.1:5173"

cd frontend
npm run dev

