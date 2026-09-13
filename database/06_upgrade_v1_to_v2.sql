\set ON_ERROR_STOP on
\echo 'Upgrading LaneShift BD v1 to the simulation-centered v2 schema...'

BEGIN;

CREATE TABLE IF NOT EXISTS traffic_scenarios (
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

CREATE TABLE IF NOT EXISTS simulation_runs (
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

CREATE INDEX IF NOT EXISTS idx_simulation_runs_requested
    ON simulation_runs(requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_simulation_runs_scenario
    ON simulation_runs(scenario_id, requested_at DESC);

CREATE TABLE IF NOT EXISTS simulation_candidates (
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

CREATE UNIQUE INDEX IF NOT EXISTS uq_simulation_one_baseline
    ON simulation_candidates(run_id) WHERE is_baseline;
CREATE UNIQUE INDEX IF NOT EXISTS uq_simulation_one_selected
    ON simulation_candidates(run_id) WHERE is_selected;
CREATE INDEX IF NOT EXISTS idx_simulation_candidates_score
    ON simulation_candidates(run_id, objective_score);

CREATE TABLE IF NOT EXISTS simulation_samples (
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

CREATE INDEX IF NOT EXISTS idx_simulation_samples_candidate_time
    ON simulation_samples(candidate_id, simulated_minute);

CREATE TABLE IF NOT EXISTS automation_decisions (
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

CREATE TABLE IF NOT EXISTS automation_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id bigint NOT NULL REFERENCES simulation_runs(run_id) ON DELETE CASCADE,
    decision_id bigint REFERENCES automation_decisions(decision_id) ON DELETE CASCADE,
    event_type varchar(40) NOT NULL,
    message text NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_automation_events_run_time
    ON automation_events(run_id, created_at, event_id);

INSERT INTO app_settings(setting_key, setting_value, description)
VALUES (
    'minimum_simulation_improvement_percent', 10.00,
    'Required simulated congestion improvement before automatic reallocation'
)
ON CONFLICT (setting_key) DO UPDATE
SET setting_value = EXCLUDED.setting_value,
    description = EXCLUDED.description;

INSERT INTO traffic_scenarios(
    scenario_code, name, description,
    inbound_rate_vph, outbound_rate_vph,
    inbound_surge_multiplier, outbound_surge_multiplier, surge_start_minute,
    incident_direction, incident_start_minute, incident_capacity_factor,
    weather_speed_factor, duration_minutes
) VALUES
    ('balanced', 'Balanced traffic',
     'Normal traffic with similar demand in both directions; the fixed split should remain suitable.',
     2100, 2000, 1.00, 1.00, NULL, NULL, NULL, 1.00, 1.00, 60),
    ('morning_peak', 'Morning inbound surge',
     'Inbound commuter demand rises after 20 minutes and creates sustained directional pressure.',
     4700, 1450, 1.28, 1.00, 20, NULL, NULL, 1.00, 1.00, 60),
    ('evening_peak', 'Evening outbound surge',
     'Outbound commuter demand rises after 20 minutes and reverses the morning pressure pattern.',
     1500, 4550, 1.00, 1.30, 20, NULL, NULL, 1.00, 1.00, 60),
    ('inbound_accident', 'Inbound accident',
     'An incident begins after 20 minutes and sharply reduces inbound lane capacity.',
     3900, 1500, 1.10, 1.00, 15, 'inbound', 20, 0.48, 0.82, 60),
    ('heavy_rain', 'Heavy rain',
     'Rain reduces traffic speed and effective capacity while inbound demand remains elevated.',
     3600, 1900, 1.18, 1.00, 25, 'both', 0, 0.72, 0.68, 60)
ON CONFLICT (scenario_code) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    inbound_rate_vph = EXCLUDED.inbound_rate_vph,
    outbound_rate_vph = EXCLUDED.outbound_rate_vph,
    inbound_surge_multiplier = EXCLUDED.inbound_surge_multiplier,
    outbound_surge_multiplier = EXCLUDED.outbound_surge_multiplier,
    surge_start_minute = EXCLUDED.surge_start_minute,
    incident_direction = EXCLUDED.incident_direction,
    incident_start_minute = EXCLUDED.incident_start_minute,
    incident_capacity_factor = EXCLUDED.incident_capacity_factor,
    weather_speed_factor = EXCLUDED.weather_speed_factor,
    duration_minutes = EXCLUDED.duration_minutes,
    active = true;

CREATE OR REPLACE FUNCTION validate_simulation_run_baseline()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_total_lanes smallint;
BEGIN
    SELECT total_lanes INTO v_total_lanes
    FROM road_segments WHERE segment_id = NEW.segment_id AND active;
    IF v_total_lanes IS NULL THEN
        RAISE EXCEPTION 'Active segment % not found', NEW.segment_id;
    END IF;
    IF NEW.baseline_inbound_lanes + NEW.baseline_outbound_lanes <> v_total_lanes THEN
        RAISE EXCEPTION 'Simulation baseline % + % must equal segment % total lanes (%)',
            NEW.baseline_inbound_lanes, NEW.baseline_outbound_lanes,
            NEW.segment_id, v_total_lanes;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION validate_simulation_candidate_split()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_total_lanes smallint;
    v_baseline_in smallint;
    v_baseline_out smallint;
BEGIN
    SELECT rs.total_lanes, sr.baseline_inbound_lanes, sr.baseline_outbound_lanes
    INTO v_total_lanes, v_baseline_in, v_baseline_out
    FROM simulation_runs sr
    JOIN road_segments rs USING (segment_id)
    WHERE sr.run_id = NEW.run_id;
    IF v_total_lanes IS NULL THEN
        RAISE EXCEPTION 'Simulation run % not found', NEW.run_id;
    END IF;
    IF NEW.inbound_lanes + NEW.outbound_lanes <> v_total_lanes THEN
        RAISE EXCEPTION 'Candidate lane split % + % must equal % lanes',
            NEW.inbound_lanes, NEW.outbound_lanes, v_total_lanes;
    END IF;
    IF NEW.is_baseline IS DISTINCT FROM (
        NEW.inbound_lanes = v_baseline_in AND NEW.outbound_lanes = v_baseline_out
    ) THEN
        RAISE EXCEPTION 'Run % baseline candidate must be exactly %/%',
            NEW.run_id, v_baseline_in, v_baseline_out;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION prepare_simulation_run_state()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.status = 'queued' AND NEW.status IN ('running', 'failed'))
        OR (OLD.status = 'running' AND NEW.status IN ('completed', 'failed'))
    ) THEN
        RAISE EXCEPTION 'Invalid simulation run transition: % to %', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'running' THEN
        NEW.started_at := COALESCE(NEW.started_at, now());
        NEW.error_message := NULL;
    ELSIF NEW.status IN ('completed', 'failed') THEN
        NEW.completed_at := COALESCE(NEW.completed_at, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION log_simulation_run_state()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_event_type text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_event_type := 'run_queued';
    ELSIF OLD.status = NEW.status THEN
        RETURN NEW;
    ELSE
        v_event_type := 'run_' || NEW.status;
    END IF;
    INSERT INTO automation_events(run_id, decision_id, event_type, message, details)
    VALUES (
        NEW.run_id,
        (SELECT decision_id FROM automation_decisions WHERE run_id = NEW.run_id),
        v_event_type,
        CASE NEW.status
            WHEN 'queued' THEN 'Simulation request stored in PostgreSQL'
            WHEN 'running' THEN 'Python simulation worker started candidate evaluation'
            WHEN 'completed' THEN 'Simulation and database decision workflow completed'
            ELSE 'Simulation failed; the database retained the diagnostic message'
        END,
        jsonb_build_object('status', NEW.status, 'algorithm_version', NEW.algorithm_version)
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION log_simulation_candidate()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO automation_events(run_id, event_type, message, details)
    VALUES (
        NEW.run_id,
        'candidate_evaluated',
        format('Evaluated %s inbound / %s outbound lanes', NEW.inbound_lanes, NEW.outbound_lanes),
        jsonb_build_object(
            'candidate_id', NEW.candidate_id,
            'objective_score', NEW.objective_score,
            'average_wait_seconds', NEW.average_wait_seconds,
            'max_queue_vehicles', NEW.max_queue_vehicles
        )
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION validate_automation_decision()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_total_lanes smallint;
    v_candidate_run bigint;
    v_candidate_in smallint;
    v_candidate_out smallint;
    v_candidate_selected boolean;
BEGIN
    SELECT rs.total_lanes INTO v_total_lanes
    FROM simulation_runs sr
    JOIN road_segments rs USING (segment_id)
    WHERE sr.run_id = NEW.run_id;
    SELECT run_id, inbound_lanes, outbound_lanes, is_selected
    INTO v_candidate_run, v_candidate_in, v_candidate_out, v_candidate_selected
    FROM simulation_candidates WHERE candidate_id = NEW.candidate_id;
    IF v_candidate_run IS DISTINCT FROM NEW.run_id THEN
        RAISE EXCEPTION 'Candidate % does not belong to run %', NEW.candidate_id, NEW.run_id;
    END IF;
    IF NEW.previous_inbound_lanes + NEW.previous_outbound_lanes <> v_total_lanes
       OR NEW.selected_inbound_lanes + NEW.selected_outbound_lanes <> v_total_lanes THEN
        RAISE EXCEPTION 'Automation decision lane totals must equal %', v_total_lanes;
    END IF;
    IF NEW.selected_inbound_lanes <> v_candidate_in
       OR NEW.selected_outbound_lanes <> v_candidate_out THEN
        RAISE EXCEPTION 'Decision split must match selected candidate %', NEW.candidate_id;
    END IF;
    IF NOT v_candidate_selected THEN
        RAISE EXCEPTION 'Automation decision candidate % must be marked selected', NEW.candidate_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION finalize_simulation_run(p_run_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_run simulation_runs%ROWTYPE;
    v_total_lanes smallint;
    v_baseline simulation_candidates%ROWTYPE;
    v_best simulation_candidates%ROWTYPE;
    v_selected simulation_candidates%ROWTYPE;
    v_threshold numeric := setting_numeric('minimum_simulation_improvement_percent', 10.0);
    v_improvement numeric;
    v_decision_id bigint;
    v_status varchar(20);
BEGIN
    SELECT * INTO v_run FROM simulation_runs WHERE run_id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Simulation run % not found', p_run_id;
    END IF;
    IF v_run.status <> 'running' THEN
        RAISE EXCEPTION 'Simulation run % must be running before finalization', p_run_id;
    END IF;
    SELECT total_lanes INTO v_total_lanes
    FROM road_segments WHERE segment_id = v_run.segment_id;
    IF (SELECT COUNT(*) FROM simulation_candidates WHERE run_id = p_run_id)
       <> v_total_lanes - 1 THEN
        RAISE EXCEPTION 'Run % requires % valid candidates before finalization',
            p_run_id, v_total_lanes - 1;
    END IF;
    SELECT * INTO v_baseline
    FROM simulation_candidates WHERE run_id = p_run_id AND is_baseline;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run % has no baseline candidate', p_run_id;
    END IF;
    UPDATE simulation_candidates
    SET improvement_percent = CASE
        WHEN v_baseline.objective_score = 0 THEN 0
        ELSE ROUND((v_baseline.objective_score - objective_score)
                   / v_baseline.objective_score * 100, 2)
    END
    WHERE run_id = p_run_id;
    SELECT * INTO v_best
    FROM simulation_candidates
    WHERE run_id = p_run_id
    ORDER BY objective_score,
             ABS(inbound_lanes - v_run.baseline_inbound_lanes), candidate_id
    LIMIT 1;
    v_improvement := COALESCE(v_best.improvement_percent, 0);
    IF v_best.candidate_id <> v_baseline.candidate_id AND v_improvement >= v_threshold THEN
        v_selected := v_best;
    ELSE
        v_selected := v_baseline;
        v_improvement := 0;
    END IF;
    UPDATE simulation_candidates
    SET is_selected = (candidate_id = v_selected.candidate_id)
    WHERE run_id = p_run_id;
    v_status := CASE WHEN v_run.execution_mode = 'simulation'
        THEN 'auto_applied' ELSE 'pending_confirmation' END;
    INSERT INTO automation_decisions(
        run_id, candidate_id, decision_type,
        previous_inbound_lanes, previous_outbound_lanes,
        selected_inbound_lanes, selected_outbound_lanes,
        predicted_improvement_percent, status, reason
    ) VALUES (
        p_run_id, v_selected.candidate_id,
        CASE WHEN v_selected.candidate_id = v_baseline.candidate_id
             THEN 'retain' ELSE 'reallocate' END,
        v_run.baseline_inbound_lanes, v_run.baseline_outbound_lanes,
        v_selected.inbound_lanes, v_selected.outbound_lanes,
        v_improvement, v_status,
        CASE WHEN v_selected.candidate_id = v_baseline.candidate_id THEN
            format('Retained the baseline because no candidate improved the objective by the required %s%%', v_threshold)
        ELSE
            format('Selected %s/%s after simulation reduced the congestion objective by %s%%',
                   v_selected.inbound_lanes, v_selected.outbound_lanes, v_improvement)
        END
    ) RETURNING decision_id INTO v_decision_id;
    INSERT INTO automation_events(run_id, decision_id, event_type, message, details)
    VALUES (
        p_run_id, v_decision_id,
        CASE WHEN v_selected.candidate_id = v_baseline.candidate_id
             THEN 'allocation_retained' ELSE 'allocation_selected' END,
        CASE WHEN v_selected.candidate_id = v_baseline.candidate_id
             THEN format('Database retained baseline %s/%s', v_selected.inbound_lanes, v_selected.outbound_lanes)
             ELSE format('Database selected and applied simulated allocation %s/%s', v_selected.inbound_lanes, v_selected.outbound_lanes)
        END,
        jsonb_build_object(
            'baseline_candidate_id', v_baseline.candidate_id,
            'selected_candidate_id', v_selected.candidate_id,
            'minimum_improvement_percent', v_threshold,
            'predicted_improvement_percent', v_improvement
        )
    );
    UPDATE simulation_runs SET status = 'completed' WHERE run_id = p_run_id;
    RETURN v_decision_id;
END;
$$;

CREATE OR REPLACE FUNCTION override_automation_decision(
    p_run_id bigint, p_operator varchar, p_reason text
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_decision_id bigint;
BEGIN
    IF length(trim(p_operator)) < 2 OR length(trim(p_reason)) < 5 THEN
        RAISE EXCEPTION 'Operator name and a meaningful override reason are required';
    END IF;
    UPDATE automation_decisions
    SET status = 'overridden', overridden_by = trim(p_operator),
        override_reason = trim(p_reason), overridden_at = now()
    WHERE run_id = p_run_id AND status <> 'overridden'
    RETURNING decision_id INTO v_decision_id;
    IF v_decision_id IS NULL THEN
        RAISE EXCEPTION 'Active automation decision for run % not found', p_run_id;
    END IF;
    INSERT INTO automation_events(run_id, decision_id, event_type, message, details)
    VALUES (
        p_run_id, v_decision_id, 'operator_override',
        format('Decision overridden by %s', trim(p_operator)),
        jsonb_build_object('reason', trim(p_reason))
    );
    RETURN v_decision_id;
END;
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_validate_simulation_run_baseline') THEN
        CREATE TRIGGER trg_validate_simulation_run_baseline
        BEFORE INSERT OR UPDATE OF segment_id, baseline_inbound_lanes, baseline_outbound_lanes
        ON simulation_runs
        FOR EACH ROW EXECUTE FUNCTION validate_simulation_run_baseline();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_validate_simulation_candidate_split') THEN
        CREATE TRIGGER trg_validate_simulation_candidate_split
        BEFORE INSERT OR UPDATE OF run_id, inbound_lanes, outbound_lanes, is_baseline
        ON simulation_candidates
        FOR EACH ROW EXECUTE FUNCTION validate_simulation_candidate_split();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_prepare_simulation_run_state') THEN
        CREATE TRIGGER trg_prepare_simulation_run_state
        BEFORE UPDATE OF status ON simulation_runs
        FOR EACH ROW EXECUTE FUNCTION prepare_simulation_run_state();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_log_simulation_run_insert') THEN
        CREATE TRIGGER trg_log_simulation_run_insert
        AFTER INSERT ON simulation_runs
        FOR EACH ROW EXECUTE FUNCTION log_simulation_run_state();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_log_simulation_run_update') THEN
        CREATE TRIGGER trg_log_simulation_run_update
        AFTER UPDATE OF status ON simulation_runs
        FOR EACH ROW EXECUTE FUNCTION log_simulation_run_state();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_log_simulation_candidate') THEN
        CREATE TRIGGER trg_log_simulation_candidate
        AFTER INSERT ON simulation_candidates
        FOR EACH ROW EXECUTE FUNCTION log_simulation_candidate();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_validate_automation_decision') THEN
        CREATE TRIGGER trg_validate_automation_decision
        BEFORE INSERT OR UPDATE OF run_id, candidate_id, selected_inbound_lanes, selected_outbound_lanes
        ON automation_decisions
        FOR EACH ROW EXECUTE FUNCTION validate_automation_decision();
    END IF;
END;
$$;

CREATE OR REPLACE VIEW simulation_candidate_comparison AS
SELECT
    sr.run_id, ts.scenario_code, ts.name AS scenario_name,
    rs.segment_code, rs.name AS segment_name,
    sc.candidate_id, sc.inbound_lanes, sc.outbound_lanes,
    sc.is_baseline, sc.is_selected,
    sc.average_wait_seconds, sc.p95_wait_seconds,
    sc.max_queue_vehicles, sc.completed_vehicles, sc.unprocessed_vehicles,
    sc.average_speed_kph, sc.throughput_vph,
    sc.objective_score, sc.improvement_percent,
    RANK() OVER (
        PARTITION BY sr.run_id ORDER BY sc.objective_score, sc.candidate_id
    ) AS performance_rank
FROM simulation_candidates sc
JOIN simulation_runs sr USING (run_id)
JOIN traffic_scenarios ts USING (scenario_id)
JOIN road_segments rs USING (segment_id);

CREATE OR REPLACE VIEW simulation_run_dashboard AS
SELECT
    sr.run_id, sr.status AS run_status, sr.execution_mode,
    sr.random_seed, sr.duration_minutes, sr.algorithm_version,
    sr.requested_at, sr.started_at, sr.completed_at,
    ts.scenario_code, ts.name AS scenario_name,
    ts.description AS scenario_description,
    rs.segment_id, rs.segment_code, rs.name AS segment_name, rs.total_lanes,
    sr.baseline_inbound_lanes, sr.baseline_outbound_lanes,
    baseline.average_wait_seconds AS baseline_wait_seconds,
    baseline.max_queue_vehicles AS baseline_max_queue,
    baseline.completed_vehicles AS baseline_completed_vehicles,
    baseline.average_speed_kph AS baseline_speed_kph,
    selected.inbound_lanes AS selected_inbound_lanes,
    selected.outbound_lanes AS selected_outbound_lanes,
    selected.average_wait_seconds AS selected_wait_seconds,
    selected.max_queue_vehicles AS selected_max_queue,
    selected.completed_vehicles AS selected_completed_vehicles,
    selected.average_speed_kph AS selected_speed_kph,
    selected.throughput_vph AS selected_throughput_vph,
    ad.decision_id, ad.decision_type,
    ad.predicted_improvement_percent,
    ad.status AS decision_status, ad.reason AS decision_reason,
    ad.decided_at, ad.overridden_by, ad.override_reason, ad.overridden_at
FROM simulation_runs sr
JOIN traffic_scenarios ts USING (scenario_id)
JOIN road_segments rs USING (segment_id)
LEFT JOIN simulation_candidates baseline
    ON baseline.run_id = sr.run_id AND baseline.is_baseline
LEFT JOIN simulation_candidates selected
    ON selected.run_id = sr.run_id AND selected.is_selected
LEFT JOIN automation_decisions ad ON ad.run_id = sr.run_id;

COMMIT;

\echo 'LaneShift BD v2 simulation extension installed without deleting v1 data.'
