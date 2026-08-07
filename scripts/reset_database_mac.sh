#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_NAME="${LANESHIFT_DB_NAME:-laneshift_bd}"
cd "$PROJECT_DIR"
psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f database/reset.sql

