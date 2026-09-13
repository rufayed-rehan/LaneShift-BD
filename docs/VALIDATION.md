# Validation Record

Validated on **2026-09-13** using both a clean PostgreSQL database and the upgraded working `laneshift_bd` database with the project's own virtual environment.

## Completed checks

| Check | Result |
| --- | --- |
| Full schema creation with `btree_gist` | Passed |
| 21 application tables and foreign-key relationships | Passed |
| PL/pgSQL functions, procedures, and triggers | Passed |
| Five traffic-scenario seed records | Passed |
| Existing Dhaka road, sensor, ANPR, suggestion, and plan seed data | Passed |
| Invalid run-baseline rejection | Passed |
| Invalid candidate lane-total rejection | Passed |
| Invalid run-state transition rejection | Passed |
| Morning simulation persistence and database finalization | Passed |
| Balanced scenario baseline retention | Passed |
| Evening scenario reverse-direction allocation | Passed |
| Safety-override function and audit event | Passed |
| FastAPI application import and endpoint workflow | Passed |
| Python byte-code compilation | Passed |
| Pytest suite: 11 tests | Passed |
| Shell-script syntax | Passed |
| Postman collection JSON syntax | Passed |
| React production build | Passed |
| Browser load, data retrieval, experiment button, history, and DBMS view | Passed |
| Browser console errors or warnings | None |
| Repeatable full-suite run on an already-used database | Passed |

## Reproducible scenario results

All results below use the six-lane AIR-01 segment and seed `4410`.

| Scenario | Fixed allocation | Database selection | Decision |
| --- | ---: | ---: | --- |
| Morning inbound surge | 3/3 | 4/2 | Reallocate |
| Balanced traffic | 3/3 | 3/3 | Retain |
| Evening outbound surge | 3/3 | 2/4 | Reallocate |

For the morning run, PostgreSQL persisted:

- 1 simulation run
- 5 candidate allocations
- 65 five-minute time-series rows across candidates
- 1 automation decision
- 9 lifecycle and decision audit events

The database reported 21 tables, 6 views, 18 project functions/procedures, 21 triggers, and 53 indexes. Extension-owned PostgreSQL functions are excluded from the project-function count.

## Commands used

```bash
psql -v ON_ERROR_STOP=1 -d <clean_validation_database> -f database/setup.sql
.venv/bin/python -m pytest
npm run build --prefix frontend
./scripts/test_all_mac.sh
```

The application was also run locally with FastAPI and Vite. A browser-driven morning experiment completed successfully and displayed PostgreSQL's `4/2` selection with the candidate table, queue comparison, audit trail, run history, and DBMS evidence.
