#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_NAME="${LANESHIFT_DB_NAME:-laneshift_bd}"

if [ -n "${PGPASSWORD:-}" ] && [ -z "${PGUSER:-}" ]; then
  export PGUSER=postgres
fi

if [ ! -x .venv/bin/python ]; then
  echo "Python environment is missing. Run ./scripts/setup_mac.sh first."
  exit 1
fi

if [ ! -d frontend/node_modules ]; then
  echo "Frontend packages are missing. Run ./scripts/setup_mac.sh first."
  exit 1
fi

echo "1/3 PostgreSQL verification"
psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f database/05_verification.sql

echo "2/3 Python simulation and API tests"
.venv/bin/python -m pytest

echo "3/3 React production build"
cd frontend
npm run build

echo
echo "All LaneShift BD checks passed."
