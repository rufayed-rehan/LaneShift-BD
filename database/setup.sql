\set ON_ERROR_STOP on
\echo '1/5 Creating schema...'
\ir 01_schema.sql
\echo '2/5 Creating functions, triggers, and procedure...'
\ir 02_logic.sql
\echo '3/5 Creating analytical views...'
\ir 03_views.sql
\echo '4/5 Loading realistic Dhaka sample data...'
\ir 04_seed.sql
\echo '5/5 Verifying database...'
\ir 05_verification.sql

