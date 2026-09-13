#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

if [ ! -f .env ]; then
  cp .env.example .env
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

DB_NAME="${LANESHIFT_DB_NAME:-laneshift_bd}"

if [ -n "${PGPASSWORD:-}" ] && [ -z "${PGUSER:-}" ]; then
  export PGUSER=postgres
fi

for command_name in psql createdb python3 npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name"
    echo "Follow docs/INSTALLATION_AND_TESTING.md, then run this script again."
    exit 1
  fi
done

if ! psql -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
  echo "PostgreSQL is installed but is not running. Start Postgres.app and retry."
  exit 1
fi

if ! psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
  createdb "$DB_NAME"
  echo "Created database: $DB_NAME"
else
  echo "Using existing database: $DB_NAME"
fi

psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f database/setup.sql

python3 -m venv .venv
"$PROJECT_DIR/.venv/bin/python" -m pip install --upgrade pip
"$PROJECT_DIR/.venv/bin/pip" install -r backend/requirements.txt

cd frontend
npm install
npm run build

cd "$PROJECT_DIR"
"$PROJECT_DIR/.venv/bin/python" -m pytest

echo
echo "LaneShift BD setup is complete."
echo "Database verification, Python tests, and frontend build all passed."
echo "Run: ./scripts/start_all_mac.sh"
