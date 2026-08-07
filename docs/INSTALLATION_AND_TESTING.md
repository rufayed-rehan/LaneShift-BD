# LaneShift BD — macOS Installation and Testing Guide

This guide assumes no development tools are already installed. Follow the recommended column for the simplest setup. Alternatives are included so you can use software already familiar to you.

## 1. Applications to use

| Purpose | Recommended application | Other valid options | Why it is needed |
| --- | --- | --- | --- |
| Code editor | Visual Studio Code | PyCharm + WebStorm, Cursor, Sublime Text | Open and edit the project files |
| PostgreSQL server | Postgres.app | Homebrew PostgreSQL 16/17, EnterpriseDB installer | Runs the main database and all decision logic |
| Database GUI | pgAdmin 4 | DBeaver, TablePlus, Postico | Optional visual access to tables and queries |
| Python | Python 3.12 or newer from python.org | Homebrew Python | Runs FastAPI |
| JavaScript runtime | Node.js LTS from nodejs.org | Homebrew Node.js | Runs the React dashboard |
| API testing | FastAPI Swagger page | Postman, Bruno, Insomnia | Demonstrates and tests API endpoints |
| Browser | Chrome | Safari, Firefox, Edge | Opens the dashboard |
| ERD tool | dbdiagram.io | draw.io, DBeaver ERD | Opens `docs/ERD.dbml` as a diagram |

The simplest combination is **Postgres.app + VS Code + Python installer + Node.js LTS + Chrome**. pgAdmin and Postman are optional because the project already includes browser-based API documentation.

## 2. Install the applications

### Step 2.1 — Install PostgreSQL with Postgres.app

1. Visit <https://postgresapp.com/> and download the current stable version.
2. Move `Postgres.app` into the macOS **Applications** folder.
3. Open it and click **Initialize** if asked.
4. Keep Postgres.app running while using LaneShift BD.
5. Open Terminal and add the PostgreSQL commands to this Terminal session:

   ```bash
   export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
   ```

6. Make that setting permanent for future Terminal windows:

   ```bash
   echo 'export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

7. Confirm the installation:

   ```bash
   psql --version
   ```

Alternative: if you prefer Homebrew, install it from <https://brew.sh/>, then run:

```bash
brew install postgresql@16
brew services start postgresql@16
echo 'export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

On an Intel Mac, Homebrew may use `/usr/local/opt/postgresql@16/bin` instead of `/opt/homebrew/...`. `brew info postgresql@16` shows the correct line.

### Step 2.2 — Install Python

1. Visit <https://www.python.org/downloads/macos/>.
2. Download and install Python 3.12 or newer.
3. Confirm in Terminal:

   ```bash
   python3 --version
   ```

### Step 2.3 — Install Node.js

1. Visit <https://nodejs.org/>.
2. Download the **LTS** macOS installer, not the Current version.
3. Confirm in Terminal:

   ```bash
   node --version
   npm --version
   ```

### Step 2.4 — Install VS Code

1. Visit <https://code.visualstudio.com/> and install the macOS build.
2. Helpful optional extensions: **Python**, **SQLTools**, and **PostgreSQL**.

## 3. Open and set up the project

1. Unzip `LaneShift-BD.zip`.
2. Move the resulting `LaneShift-BD` folder to Documents or Desktop.
3. In Terminal, type `cd ` with a trailing space, drag the folder onto Terminal, and press Return. Example:

   ```bash
   cd ~/Documents/LaneShift-BD
   ```

4. Give the included scripts permission to run:

   ```bash
   chmod +x scripts/*.sh
   ```

5. Start Postgres.app.
6. Run the complete setup:

   ```bash
   ./scripts/setup_mac.sh
   ```

The script creates `laneshift_bd`, installs all SQL objects and sample data, creates a Python virtual environment, installs backend packages, and installs frontend packages. The final SQL check must say **All database checks passed.**

## 4. Start the project

From the project root, run:

```bash
./scripts/start_all_mac.sh
```

Keep that Terminal window open. Then open:

- Dashboard: <http://127.0.0.1:5173>
- API documentation: <http://127.0.0.1:8000/docs>
- API health check: <http://127.0.0.1:8000/health>

Press **Control+C** in Terminal to stop both applications.

### Alternative: use two Terminal windows

Terminal 1:

```bash
./scripts/run_backend_mac.sh
```

Terminal 2:

```bash
./scripts/run_frontend_mac.sh
```

This option is useful while editing code because the API and UI can be restarted separately.

## 5. Demonstration sequence

Use this exact order for a class demonstration:

1. Open the dashboard and explain the four summary cards.
2. Show **Network pressure**. Explain that `corridor_dashboard` uses a `RANK()` window function to identify the worst segment in each corridor.
3. Show the segment table. Explain that the unfit percentage comes from joining ANPR detections with each vehicle’s latest fitness record.
4. Open **Suggestions** and click **Approve & schedule** on one pending item.
5. Explain that the frontend only sends approval; PostgreSQL’s trigger validates the lane total, creates the schedule, blocks overlap, writes the audit log, and marks the suggestion applied.
6. Open **Daily plan**, choose today, and click **Generate complete plan**.
7. Explain that the cursor-driven stored procedure covers every active segment and assigns enforcement when the unfit ratio reaches 25%.
8. Open <http://127.0.0.1:8000/docs> and test `GET /api/segments` to prove the API is working.

## 6. Test the database directly

Open a new Terminal in the project folder.

### Run the automatic verification

```bash
psql -d laneshift_bd -f database/05_verification.sql
```

Expected starting data:

| Item | Expected rows |
| --- | ---: |
| Corridors | 3 |
| Road segments | 7 |
| Traffic readings | 252 |
| ANPR detections | 672 |
| Manual suggestions | 4 |
| Initial active schedules | 1 |
| Current daily plan items | 7 |

### Test the main functions

```bash
psql -d laneshift_bd
```

Then run:

```sql
SELECT calculate_direction_imbalance(1, date_trunc('hour', now()));

SELECT unfit_vehicle_ratio(
  1,
  tstzrange(now() - interval '24 hours', now(), '[)')
);

SELECT * FROM recommend_lane_split(1, current_date);

SELECT * FROM sustained_imbalance_analysis
WHERE sustained_over_one_hour
ORDER BY recorded_at DESC
LIMIT 10;

SELECT * FROM corridor_dashboard;
```

Type `\q` to leave `psql`.

### Prove the lane-total constraint

The following test is expected to fail because segment 1 has six lanes, not seven:

```sql
BEGIN;
INSERT INTO reversible_lane_schedules(
  segment_id, active_window, inbound_lanes, outbound_lanes
) VALUES (
  1,
  tstzrange(now() + interval '10 days', now() + interval '10 days 2 hours', '[)'),
  5,
  2
);
ROLLBACK;
```

The error proves the trigger protects the business rule. If `ROLLBACK` is skipped after an expected error, run it before any other command.

### Prove the overlap constraint

1. Run `SELECT * FROM reversible_lane_schedules;` and copy one segment and time window.
2. Try to insert another non-cancelled schedule for the same segment with an overlapping range.
3. PostgreSQL raises an exclusion-constraint error. This proves two lane configurations cannot be active for the same road space at the same time.

## 7. Test the API

The easiest option is Swagger:

1. Open <http://127.0.0.1:8000/docs>.
2. Expand an endpoint.
3. Click **Try it out**, then **Execute**.

Postman option:

1. Install Postman from <https://www.postman.com/downloads/>.
2. Click **Import**.
3. Select `docs/LaneShift-BD.postman_collection.json`.
4. Run the requests. Change the `suggestionId` collection variable to an ID currently shown by `GET Pending suggestions` before approving.

## 8. Reset the sample data

This removes LaneShift BD’s current demo data and recreates it. It does not delete the PostgreSQL database itself.

```bash
./scripts/reset_database_mac.sh
```

## 9. Common problems

### `psql: command not found`

PostgreSQL’s command folder is not on PATH. Repeat step 2.1.5, then close and reopen Terminal.

### `connection to server ... failed`

Open Postgres.app and confirm its server shows **Running**. Homebrew users should run `brew services start postgresql@16`.

### Backend says database connection failed

The recommended Postgres.app/Homebrew setup uses the macOS username and no local password. The included `.env` therefore uses:

```env
DATABASE_URL=postgresql:///laneshift_bd
```

If you installed PostgreSQL with a password-based `postgres` user, change it to:

```env
DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost:5432/laneshift_bd
```

If the password contains `@`, `:`, `/`, or spaces, URL-encode it or create a simpler project-only password.

### Port 8000 or 5173 is already in use

Stop an older LaneShift BD Terminal with Control+C. To find a process:

```bash
lsof -i :8000
lsof -i :5173
```

### Dashboard loads but shows a connection message

Confirm <http://127.0.0.1:8000/health> works. If it does, refresh the dashboard. If it does not, read the error in the Terminal running FastAPI.

## 10. What you still need to do

The project package implements the database, sample data, backend, dashboard, setup automation, and tests. Your remaining work is local and presentation-specific:

1. Install the applications on your Mac.
2. Run setup and confirm the verification passes.
3. Click through the demonstration sequence at least once.
4. Replace the demo operator name if your instructor wants your own name in the audit log.
5. Capture screenshots or a screen recording only if your instructor later requests them.

