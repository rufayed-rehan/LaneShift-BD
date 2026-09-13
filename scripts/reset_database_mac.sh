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
psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f database/reset.sql
