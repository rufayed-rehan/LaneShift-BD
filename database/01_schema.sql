BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP VIEW IF EXISTS corridor_dashboard CASCADE;
DROP VIEW IF EXISTS segment_performance CASCADE;
DROP VIEW IF EXISTS slow_vehicle_signature CASCADE;
DROP VIEW IF EXISTS sustained_imbalance_analysis CASCADE;
DROP VIEW IF EXISTS simulation_run_dashboard CASCADE;
DROP VIEW IF EXISTS simulation_candidate_comparison CASCADE;

DROP TABLE IF EXISTS automation_events CASCADE;
DROP TABLE IF EXISTS automation_decisions CASCADE;
DROP TABLE IF EXISTS simulation_samples CASCADE;
DROP TABLE IF EXISTS simulation_candidates CASCADE;
DROP TABLE IF EXISTS simulation_runs CASCADE;
DROP TABLE IF EXISTS traffic_scenarios CASCADE;
DROP TABLE IF EXISTS enforcement_deployments CASCADE;
DROP TABLE IF EXISTS enforcement_teams CASCADE;
DROP TABLE IF EXISTS plan_items CASCADE;
DROP TABLE IF EXISTS reallocation_plans CASCADE;
DROP TABLE IF EXISTS lane_change_log CASCADE;
DROP TABLE IF EXISTS reversible_lane_schedules CASCADE;
DROP TABLE IF EXISTS reversible_lane_suggestions CASCADE;
DROP TABLE IF EXISTS anpr_detections CASCADE;
DROP TABLE IF EXISTS vehicle_fitness_status CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;
DROP TABLE IF EXISTS traffic_readings CASCADE;
DROP TABLE IF EXISTS anpr_cameras CASCADE;
DROP TABLE IF EXISTS road_segments CASCADE;
DROP TABLE IF EXISTS corridors CASCADE;
DROP TABLE IF EXISTS app_settings CASCADE;

CREATE TABLE app_settings (
    setting_key text PRIMARY KEY,
    setting_value numeric NOT NULL,
    description text NOT NULL
);

CREATE TABLE corridors (
    corridor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(100) NOT NULL UNIQUE,
    city varchar(80) NOT NULL DEFAULT 'Dhaka',
    description text,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE road_segments (
    segment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    corridor_id bigint NOT NULL REFERENCES corridors(corridor_id) ON DELETE RESTRICT,
    segment_code varchar(20) NOT NULL UNIQUE,
    name varchar(140) NOT NULL,
    inbound_label varchar(80) NOT NULL,
    outbound_label varchar(80) NOT NULL,
    total_lanes smallint NOT NULL CHECK (total_lanes BETWEEN 2 AND 12),
    base_inbound_lanes smallint NOT NULL CHECK (base_inbound_lanes > 0),
    base_outbound_lanes smallint NOT NULL CHECK (base_outbound_lanes > 0),
    length_km numeric(6,2) NOT NULL CHECK (length_km > 0),
    capacity_per_lane integer NOT NULL CHECK (capacity_per_lane > 0),
    speed_limit_kph numeric(5,1) NOT NULL CHECK (speed_limit_kph > 0),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_segment_base_lane_total
        CHECK (base_inbound_lanes + base_outbound_lanes = total_lanes)
);

CREATE INDEX idx_road_segments_corridor ON road_segments(corridor_id);

CREATE TABLE traffic_scenarios (
    scenario_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario_code varchar(30) NOT NULL UNIQUE,
    name varchar(100) NOT NULL,
    description text NOT NULL,
    inbound_rate_vph integer NOT NULL CHECK (inbound_rate_vph BETWEEN 0 AND 20000),
    outbound_rate_vph integer NOT NULL CHECK (outbound_rate_vph BETWEEN 0 AND 20000),
    inbound_surge_multiplier numeric(5,2) NOT NULL DEFAULT 1.00
        CHECK (inbound_surge_multiplier BETWEEN 0.10 AND 5.00),
    outbound_surge_multiplier numeric(5,2) NOT NULL DEFAULT 1.00
        CHECK (outbound_surge_multiplier BETWEEN 0.10 AND 5.00),
    surge_start_minute smallint CHECK (surge_start_minute BETWEEN 0 AND 239),
    incident_direction varchar(10)
        CHECK (incident_direction IN ('inbound', 'outbound', 'both')),
    incident_start_minute smallint CHECK (incident_start_minute BETWEEN 0 AND 239),
    incident_capacity_factor numeric(4,2) NOT NULL DEFAULT 1.00
        CHECK (incident_capacity_factor BETWEEN 0.10 AND 1.00),
    weather_speed_factor numeric(4,2) NOT NULL DEFAULT 1.00
        CHECK (weather_speed_factor BETWEEN 0.30 AND 1.00),
    duration_minutes smallint NOT NULL DEFAULT 60
        CHECK (duration_minutes BETWEEN 15 AND 240),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_scenario_incident_details CHECK (
        (incident_direction IS NULL AND incident_start_minute IS NULL)
        OR
        (incident_direction IS NOT NULL AND incident_start_minute IS NOT NULL)
    )
);

CREATE TABLE simulation_runs (
    run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario_id bigint NOT NULL REFERENCES traffic_scenarios(scenario_id) ON DELETE RESTRICT,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE RESTRICT,
    random_seed integer NOT NULL CHECK (random_seed BETWEEN 1 AND 2147483647),
    duration_minutes smallint NOT NULL CHECK (duration_minutes BETWEEN 15 AND 240),
    baseline_inbound_lanes smallint NOT NULL CHECK (baseline_inbound_lanes > 0),
    baseline_outbound_lanes smallint NOT NULL CHECK (baseline_outbound_lanes > 0),
    execution_mode varchar(15) NOT NULL DEFAULT 'simulation'
        CHECK (execution_mode IN ('simulation', 'advisory')),
    algorithm_version varchar(30) NOT NULL DEFAULT 'simpy-search-v1',
    status varchar(12) NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    error_message text,
    requested_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    CONSTRAINT ck_run_baseline_lane_total CHECK (
        baseline_inbound_lanes > 0 AND baseline_outbound_lanes > 0
    ),
    CONSTRAINT ck_run_timestamps CHECK (
        completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at
    )
);

CREATE INDEX idx_simulation_runs_requested
    ON simulation_runs(requested_at DESC);
CREATE INDEX idx_simulation_runs_scenario
    ON simulation_runs(scenario_id, requested_at DESC);

CREATE TABLE simulation_candidates (
    candidate_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint NOT NULL REFERENCES simulation_runs(run_id) ON DELETE CASCADE,
    inbound_lanes smallint NOT NULL CHECK (inbound_lanes > 0),
    outbound_lanes smallint NOT NULL CHECK (outbound_lanes > 0),
    is_baseline boolean NOT NULL DEFAULT false,
    average_wait_seconds numeric(12,2) NOT NULL CHECK (average_wait_seconds >= 0),
    p95_wait_seconds numeric(12,2) NOT NULL CHECK (p95_wait_seconds >= 0),
    max_queue_vehicles integer NOT NULL CHECK (max_queue_vehicles >= 0),
    completed_vehicles integer NOT NULL CHECK (completed_vehicles >= 0),
    unprocessed_vehicles integer NOT NULL CHECK (unprocessed_vehicles >= 0),
    average_speed_kph numeric(6,2) NOT NULL CHECK (average_speed_kph >= 0),
    throughput_vph numeric(10,2) NOT NULL CHECK (throughput_vph >= 0),
    objective_score numeric(14,4) NOT NULL CHECK (objective_score >= 0),
    improvement_percent numeric(8,2),
    is_selected boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, inbound_lanes, outbound_lanes)
);

CREATE UNIQUE INDEX uq_simulation_one_baseline
    ON simulation_candidates(run_id) WHERE is_baseline;
CREATE UNIQUE INDEX uq_simulation_one_selected
    ON simulation_candidates(run_id) WHERE is_selected;
CREATE INDEX idx_simulation_candidates_score
    ON simulation_candidates(run_id, objective_score);

CREATE TABLE simulation_samples (
    sample_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_id bigint NOT NULL REFERENCES simulation_candidates(candidate_id) ON DELETE CASCADE,
    simulated_minute smallint NOT NULL CHECK (simulated_minute BETWEEN 0 AND 240),
    inbound_queue integer NOT NULL CHECK (inbound_queue >= 0),
    outbound_queue integer NOT NULL CHECK (outbound_queue >= 0),
    cumulative_completed integer NOT NULL CHECK (cumulative_completed >= 0),
    inbound_average_wait_seconds numeric(12,2) NOT NULL CHECK (inbound_average_wait_seconds >= 0),
    outbound_average_wait_seconds numeric(12,2) NOT NULL CHECK (outbound_average_wait_seconds >= 0),
    inbound_speed_kph numeric(6,2) NOT NULL CHECK (inbound_speed_kph >= 0),
    outbound_speed_kph numeric(6,2) NOT NULL CHECK (outbound_speed_kph >= 0),
    UNIQUE (candidate_id, simulated_minute)
);

CREATE INDEX idx_simulation_samples_candidate_time
    ON simulation_samples(candidate_id, simulated_minute);

CREATE TABLE automation_decisions (
    decision_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint NOT NULL UNIQUE REFERENCES simulation_runs(run_id) ON DELETE CASCADE,
    candidate_id bigint NOT NULL REFERENCES simulation_candidates(candidate_id) ON DELETE RESTRICT,
    decision_type varchar(12) NOT NULL CHECK (decision_type IN ('retain', 'reallocate')),
    previous_inbound_lanes smallint NOT NULL CHECK (previous_inbound_lanes > 0),
    previous_outbound_lanes smallint NOT NULL CHECK (previous_outbound_lanes > 0),
    selected_inbound_lanes smallint NOT NULL CHECK (selected_inbound_lanes > 0),
    selected_outbound_lanes smallint NOT NULL CHECK (selected_outbound_lanes > 0),
    predicted_improvement_percent numeric(8,2) NOT NULL,
    status varchar(20) NOT NULL
        CHECK (status IN ('auto_applied', 'pending_confirmation', 'overridden')),
    reason text NOT NULL,
    decided_at timestamptz NOT NULL DEFAULT now(),
    overridden_by varchar(100),
    override_reason text,
    overridden_at timestamptz,
    CONSTRAINT ck_decision_override_fields CHECK (
        (status <> 'overridden' AND overridden_by IS NULL AND overridden_at IS NULL)
        OR
        (status = 'overridden' AND overridden_by IS NOT NULL
         AND override_reason IS NOT NULL AND overridden_at IS NOT NULL)
    )
);

CREATE TABLE automation_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint NOT NULL REFERENCES simulation_runs(run_id) ON DELETE CASCADE,
    decision_id bigint REFERENCES automation_decisions(decision_id) ON DELETE CASCADE,
    event_type varchar(40) NOT NULL,
    message text NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_automation_events_run_time
    ON automation_events(run_id, created_at, event_id);

CREATE TABLE anpr_cameras (
    camera_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    camera_code varchar(30) NOT NULL UNIQUE,
    location_description text NOT NULL,
    monitored_direction varchar(10) NOT NULL
        CHECK (monitored_direction IN ('inbound', 'outbound', 'both')),
    active boolean NOT NULL DEFAULT true,
    installed_at date NOT NULL DEFAULT current_date
);

CREATE INDEX idx_cameras_segment ON anpr_cameras(segment_id);

CREATE TABLE traffic_readings (
    reading_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    recorded_at timestamptz NOT NULL,
    inbound_vehicle_count integer NOT NULL CHECK (inbound_vehicle_count >= 0),
    outbound_vehicle_count integer NOT NULL CHECK (outbound_vehicle_count >= 0),
    avg_inbound_speed_kph numeric(5,1) NOT NULL CHECK (avg_inbound_speed_kph >= 0),
    avg_outbound_speed_kph numeric(5,1) NOT NULL CHECK (avg_outbound_speed_kph >= 0),
    source varchar(20) NOT NULL DEFAULT 'sensor' CHECK (source IN ('sensor', 'manual', 'import')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (segment_id, recorded_at)
);

CREATE INDEX idx_traffic_segment_time ON traffic_readings(segment_id, recorded_at DESC);

CREATE TABLE vehicles (
    vehicle_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plate_number varchar(30) NOT NULL UNIQUE,
    vehicle_type varchar(20) NOT NULL
        CHECK (vehicle_type IN ('car', 'bus', 'truck', 'motorcycle', 'cng', 'microbus')),
    registration_date date NOT NULL,
    owner_district varchar(80),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE vehicle_fitness_status (
    fitness_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id bigint NOT NULL REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    certificate_number varchar(40) NOT NULL UNIQUE,
    inspected_at date NOT NULL,
    expiry_date date NOT NULL,
    status varchar(10) NOT NULL CHECK (status IN ('valid', 'expired', 'failed')),
    notes text,
    CHECK (expiry_date >= inspected_at)
);

CREATE INDEX idx_fitness_vehicle_date
    ON vehicle_fitness_status(vehicle_id, inspected_at DESC);

CREATE TABLE anpr_detections (
    detection_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    camera_id bigint NOT NULL REFERENCES anpr_cameras(camera_id) ON DELETE CASCADE,
    vehicle_id bigint NOT NULL REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    detected_at timestamptz NOT NULL,
    travel_direction varchar(10) NOT NULL CHECK (travel_direction IN ('inbound', 'outbound')),
    observed_speed_kph numeric(5,1) CHECK (observed_speed_kph >= 0),
    confidence numeric(4,3) NOT NULL DEFAULT 0.950 CHECK (confidence BETWEEN 0 AND 1)
);

CREATE INDEX idx_detections_segment_time ON anpr_detections(segment_id, detected_at DESC);
CREATE INDEX idx_detections_vehicle_time ON anpr_detections(vehicle_id, detected_at DESC);

CREATE TABLE reversible_lane_suggestions (
    suggestion_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    generated_at timestamptz NOT NULL DEFAULT now(),
    evidence_window tstzrange NOT NULL,
    proposed_window tstzrange NOT NULL,
    measured_imbalance_ratio numeric(8,3) NOT NULL CHECK (measured_imbalance_ratio >= 0),
    measured_unfit_ratio numeric(6,4) NOT NULL DEFAULT 0 CHECK (measured_unfit_ratio BETWEEN 0 AND 1),
    recommended_inbound_lanes smallint NOT NULL CHECK (recommended_inbound_lanes > 0),
    recommended_outbound_lanes smallint NOT NULL CHECK (recommended_outbound_lanes > 0),
    status varchar(10) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'applied', 'rejected')),
    reason text NOT NULL,
    approved_by varchar(100),
    approved_at timestamptz,
    CONSTRAINT ck_suggestion_windows CHECK (
        NOT isempty(evidence_window)
        AND NOT isempty(proposed_window)
        AND lower_inc(evidence_window)
        AND NOT upper_inc(evidence_window)
        AND lower_inc(proposed_window)
        AND NOT upper_inc(proposed_window)
    ),
    CONSTRAINT uq_suggestion_segment_proposed UNIQUE (segment_id, proposed_window)
);

CREATE INDEX idx_suggestions_status_time
    ON reversible_lane_suggestions(status, generated_at DESC);

CREATE TABLE reversible_lane_schedules (
    schedule_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    suggestion_id bigint UNIQUE REFERENCES reversible_lane_suggestions(suggestion_id) ON DELETE SET NULL,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    active_window tstzrange NOT NULL,
    inbound_lanes smallint NOT NULL CHECK (inbound_lanes > 0),
    outbound_lanes smallint NOT NULL CHECK (outbound_lanes > 0),
    status varchar(10) NOT NULL DEFAULT 'scheduled'
        CHECK (status IN ('scheduled', 'active', 'completed', 'cancelled')),
    created_by varchar(100) NOT NULL DEFAULT current_user,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_schedule_window CHECK (
        NOT isempty(active_window)
        AND lower_inc(active_window)
        AND NOT upper_inc(active_window)
    ),
    CONSTRAINT ex_schedule_no_overlap
        EXCLUDE USING gist (segment_id WITH =, active_window WITH &&)
        WHERE (status <> 'cancelled')
);

CREATE INDEX idx_schedules_segment_window
    ON reversible_lane_schedules USING gist(segment_id, active_window);

CREATE TABLE lane_change_log (
    log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    suggestion_id bigint REFERENCES reversible_lane_suggestions(suggestion_id) ON DELETE SET NULL,
    schedule_id bigint REFERENCES reversible_lane_schedules(schedule_id) ON DELETE SET NULL,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE CASCADE,
    action varchar(30) NOT NULL,
    actor varchar(100) NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    logged_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE reallocation_plans (
    plan_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_date date NOT NULL UNIQUE,
    status varchar(10) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'ready', 'executed')),
    generated_at timestamptz NOT NULL DEFAULT now(),
    generated_by varchar(100) NOT NULL DEFAULT current_user,
    notes text
);

CREATE TABLE plan_items (
    plan_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_id bigint NOT NULL REFERENCES reallocation_plans(plan_id) ON DELETE CASCADE,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE RESTRICT,
    suggestion_id bigint REFERENCES reversible_lane_suggestions(suggestion_id) ON DELETE SET NULL,
    recommended_inbound_lanes smallint NOT NULL CHECK (recommended_inbound_lanes > 0),
    recommended_outbound_lanes smallint NOT NULL CHECK (recommended_outbound_lanes > 0),
    action varchar(30) NOT NULL
        CHECK (action IN ('monitor', 'reallocate', 'enforce', 'reallocate_and_enforce')),
    unfit_ratio numeric(6,4) NOT NULL DEFAULT 0 CHECK (unfit_ratio BETWEEN 0 AND 1),
    rationale text NOT NULL,
    UNIQUE (plan_id, segment_id)
);

CREATE TABLE enforcement_teams (
    team_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_code varchar(20) NOT NULL UNIQUE,
    team_name varchar(100) NOT NULL,
    base_location varchar(120) NOT NULL,
    active boolean NOT NULL DEFAULT true,
    contact_number varchar(30)
);

CREATE TABLE enforcement_deployments (
    deployment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_id bigint NOT NULL REFERENCES enforcement_teams(team_id) ON DELETE RESTRICT,
    segment_id bigint NOT NULL REFERENCES road_segments(segment_id) ON DELETE RESTRICT,
    plan_item_id bigint REFERENCES plan_items(plan_item_id) ON DELETE CASCADE,
    deployment_window tstzrange NOT NULL,
    status varchar(15) NOT NULL DEFAULT 'scheduled'
        CHECK (status IN ('scheduled', 'dispatched', 'completed', 'cancelled')),
    reason text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_deployment_window CHECK (NOT isempty(deployment_window))
);

CREATE INDEX idx_deployments_team_window
    ON enforcement_deployments USING gist(team_id, deployment_window);

COMMIT;
