# Validation Record

The packaged project was checked before delivery.

| Check | Result |
| --- | --- |
| Full PostgreSQL schema execution with `btree_gist` loaded | Passed |
| PL/pgSQL functions and triggers creation | Passed |
| Seed transaction | Passed |
| Daily cursor procedure | Passed |
| `05_verification.sql` assertions | Passed |
| Invalid lane total rejection | Passed |
| Overlapping schedule rejection | Passed |
| Expected sample row counts | Passed |
| FastAPI application import and route registration | Passed |
| Python byte-code compilation | Passed |
| Shell-script syntax | Passed |
| Postman collection JSON syntax | Passed |
| React production build | Passed |

Validated sample counts: 3 corridors, 7 active segments, 252 traffic readings, 672 ANPR detections, 4 suggestions, 1 initial schedule, and 7 daily plan items.

