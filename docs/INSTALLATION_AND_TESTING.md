# LaneShift BD — Installation and Testing

## 1. Required applications

- Visual Studio Code
- PostgreSQL 15 or newer
- Python 3.11 or newer
- Node.js 18 or newer
- A modern browser

Postgres.app is the simplest PostgreSQL option on macOS. pgAdmin and Postman are optional because the project includes SQL scripts and Swagger API documentation.

## 2. Open the project

In VS Code, select **File → Open Folder** and choose `LaneShift-BD`.

This prepared copy can be started immediately from **Terminal → New Terminal**:

```bash
./scripts/start_all_mac.sh
```

Only for a fresh installation on another computer, confirm the Terminal is in the project root, then run:

```bash
chmod +x scripts/*.sh
./scripts/setup_mac.sh
```

The setup script:

1. Checks PostgreSQL, Python, and Node.js.
2. Creates or reuses the `laneshift_bd` database.
3. Builds all tables, constraints, functions, triggers, procedures, views, and seed data.
4. Installs FastAPI, Psycopg, SimPy, Pytest, and the frontend packages.
5. Runs the SQL verification, Python tests, and React production build.

Successful setup ends with:

```text
Database verification, Python tests, and frontend build all passed.
```

`setup_mac.sh` recreates LaneShift BD's own project tables. To add the simulation extension to an existing version-1 database without removing its records, use:

```bash
psql -v ON_ERROR_STOP=1 -d laneshift_bd -f database/06_upgrade_v1_to_v2.sql
```

## 3. PostgreSQL connection settings

The default `.env.example` works with password-free Postgres.app installations:

```env
DATABASE_URL=postgresql:///laneshift_bd
API_HOST=127.0.0.1
API_PORT=8000
```

For a password-based `postgres` account, create or edit `.env`:

```env
DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost:5432/laneshift_bd
PGHOST=localhost
PGUSER=postgres
PGPASSWORD=YOUR_PASSWORD
API_HOST=127.0.0.1
API_PORT=8000
```

Do not commit `.env`; it is already excluded by `.gitignore`.

## 4. Start the project

```bash
./scripts/start_all_mac.sh
```

Keep that Terminal open, then visit:

- Dashboard: <http://127.0.0.1:5173>
- Swagger API: <http://127.0.0.1:8000/docs>
- Health check: <http://127.0.0.1:8000/health>

Press **Control+C** to stop the project.

To run the backend and frontend separately:

```bash
./scripts/run_backend_mac.sh
```

```bash
./scripts/run_frontend_mac.sh
```

## 5. Recommended first demonstration

1. Open **Simulation lab**.
2. Keep **Morning inbound surge** selected.
3. Keep `AIR-01`, the six-lane Airport-to-Khilkhet segment.
4. Keep random seed `4410`.
5. Click **Run automated experiment**.
6. Explain that SimPy replayed the same random vehicle stream against all five safe lane allocations.
7. Point out that PostgreSQL selected `4 inbound / 2 outbound` instead of the fixed `3/3` split.
8. Compare waiting time, queue length, speed, and completed vehicles.
9. Show the queue chart and all candidate rows.
10. Show the audit trail, **Run history**, and **DBMS evidence**.

The exact values are generated, not hardcoded. With seed `4410`, the result is reproducible.

## 6. Run all automated tests

```bash
./scripts/test_all_mac.sh
```

### PostgreSQL checks

`database/05_verification.sql` checks:

- Base, scheduled, simulated, and decided lane totals
- Five active scenario definitions
- Complete daily-plan coverage
- Trigger-created schedules
- Rejection of an invalid simulation baseline
- Rejection of an invalid queued-to-completed transition
- Rejection of an invalid candidate lane total

The intentional invalid rows are caught and removed inside the verification routine.

### Python checks

The Pytest suite checks:

- A fixed random seed reproduces the same demand
- All `N-1` safe allocations are evaluated
- Balanced traffic prefers the baseline
- Morning pressure benefits from additional inbound lanes
- An incident increases queueing and waiting
- `0/N`, `N/0`, and wrong-total arrangements are rejected
- FastAPI request validation and scenario routing

### Frontend check

The Vite production build verifies that the React application compiles successfully.

## 7. Useful DBMS queries for the teacher

Open PostgreSQL:

```bash
psql -d laneshift_bd
```

Inspect the scenarios:

```sql
SELECT scenario_code, name, inbound_rate_vph, outbound_rate_vph,
       incident_direction, weather_speed_factor
FROM traffic_scenarios
ORDER BY scenario_id;
```

Inspect recent experiments:

```sql
SELECT run_id, scenario_name, segment_code,
       baseline_inbound_lanes || '/' || baseline_outbound_lanes AS baseline,
       selected_inbound_lanes || '/' || selected_outbound_lanes AS selected,
       predicted_improvement_percent
FROM simulation_run_dashboard
ORDER BY run_id DESC;
```

Inspect every candidate from the latest run:

```sql
SELECT inbound_lanes, outbound_lanes, is_baseline, is_selected,
       average_wait_seconds, max_queue_vehicles,
       completed_vehicles, objective_score, improvement_percent
FROM simulation_candidate_comparison
WHERE run_id = (SELECT MAX(run_id) FROM simulation_runs)
ORDER BY inbound_lanes;
```

Inspect the database-owned decision trail:

```sql
SELECT event_type, message, details, created_at
FROM automation_events
WHERE run_id = (SELECT MAX(run_id) FROM simulation_runs)
ORDER BY event_id;
```

Type `\q` to exit PostgreSQL.

## 8. Swagger API demonstration

Open <http://127.0.0.1:8000/docs> and try:

- `GET /api/simulation/scenarios`
- `POST /api/simulation/runs`
- `GET /api/simulation/runs`
- `GET /api/simulation/runs/{run_id}`
- `GET /api/database/evidence`

Example request body:

```json
{
  "scenario_code": "morning_peak",
  "segment_id": 1,
  "seed": 4410
}
```

## 9. Reset the demonstration data

This recreates LaneShift BD's project tables and sample data. It does not delete the database itself.

```bash
./scripts/reset_database_mac.sh
```

Run it before class if you want an empty simulation history.

## 10. Troubleshooting

### `psql: command not found`

Add the PostgreSQL binary directory to `PATH`. For Postgres.app:

```bash
export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
```

### PostgreSQL asks for a password repeatedly

Add `PGHOST`, `PGUSER`, and `PGPASSWORD` to `.env` as shown in section 3.

### Database connection failed

Confirm PostgreSQL is running and verify that `DATABASE_URL` in `.env` has the correct username, password, host, port, and database.

### Port 8000 or 5173 is already used

Stop an older LaneShift BD Terminal with **Control+C**, then start the project again.

### Dashboard cannot reach the API

Open <http://127.0.0.1:8000/health>. If it fails, inspect the backend Terminal for the database error. If it works, refresh the dashboard.
