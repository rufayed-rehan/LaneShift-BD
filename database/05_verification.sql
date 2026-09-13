\pset pager off
\echo 'Running LaneShift BD database verification...'

CALL generate_lane_reallocation_plan(current_date);

DO $$
DECLARE
    v_active_segments integer;
    v_plan_items integer;
    v_scenarios integer;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM road_segments
        WHERE base_inbound_lanes + base_outbound_lanes <> total_lanes
    ) THEN
        RAISE EXCEPTION 'Base lane invariant failed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM reversible_lane_schedules s
        JOIN road_segments rs USING (segment_id)
        WHERE s.inbound_lanes + s.outbound_lanes <> rs.total_lanes
    ) THEN
        RAISE EXCEPTION 'Schedule lane invariant failed';
    END IF;

    SELECT COUNT(*) INTO v_active_segments FROM road_segments WHERE active;
    SELECT COUNT(*) INTO v_plan_items
    FROM plan_items pi
    JOIN reallocation_plans rp USING (plan_id)
    WHERE rp.plan_date = current_date;

    IF v_active_segments <> v_plan_items THEN
        RAISE EXCEPTION 'Plan coverage failed: % active segments, % items',
            v_active_segments, v_plan_items;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM reversible_lane_suggestions) THEN
        RAISE EXCEPTION 'Expected at least one generated lane suggestion';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM reversible_lane_suggestions
        WHERE status NOT IN ('pending', 'approved', 'applied', 'rejected')
    ) THEN
        RAISE EXCEPTION 'A lane suggestion has an invalid workflow status';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM reversible_lane_schedules) THEN
        RAISE EXCEPTION 'Approval trigger did not create a schedule';
    END IF;

    SELECT COUNT(*) INTO v_scenarios FROM traffic_scenarios WHERE active;
    IF v_scenarios < 5 THEN
        RAISE EXCEPTION 'Expected at least five active simulation scenarios, found %', v_scenarios;
    END IF;
END;
$$;

DO $$
DECLARE
    v_run_id bigint;
    v_rejected boolean;
BEGIN
    v_rejected := false;
    BEGIN
        INSERT INTO simulation_runs(
            scenario_id, segment_id, random_seed, duration_minutes,
            baseline_inbound_lanes, baseline_outbound_lanes
        ) VALUES (1, 1, 4410, 60, 4, 3);
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid simulation baseline lane total was accepted';
    END IF;

    INSERT INTO simulation_runs(
        scenario_id, segment_id, random_seed, duration_minutes,
        baseline_inbound_lanes, baseline_outbound_lanes
    ) VALUES (1, 1, 4410, 60, 3, 3)
    RETURNING run_id INTO v_run_id;

    v_rejected := false;
    BEGIN
        UPDATE simulation_runs SET status = 'completed' WHERE run_id = v_run_id;
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid queued-to-completed transition was accepted';
    END IF;

    UPDATE simulation_runs SET status = 'running' WHERE run_id = v_run_id;

    v_rejected := false;
    BEGIN
        INSERT INTO simulation_candidates(
            run_id, inbound_lanes, outbound_lanes, is_baseline,
            average_wait_seconds, p95_wait_seconds, max_queue_vehicles,
            completed_vehicles, unprocessed_vehicles, average_speed_kph,
            throughput_vph, objective_score
        ) VALUES (
            v_run_id, 5, 2, true,
            0, 0, 0, 100, 0, 40, 100, 0
        );
    EXCEPTION WHEN OTHERS THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid simulation candidate lane total was accepted';
    END IF;

    DELETE FROM simulation_runs WHERE run_id = v_run_id;
END;
$$;

SELECT 'corridors' AS item, COUNT(*) AS row_count FROM corridors
UNION ALL SELECT 'segments', COUNT(*) FROM road_segments
UNION ALL SELECT 'traffic scenarios', COUNT(*) FROM traffic_scenarios
UNION ALL SELECT 'traffic readings', COUNT(*) FROM traffic_readings
UNION ALL SELECT 'ANPR detections', COUNT(*) FROM anpr_detections
UNION ALL SELECT 'suggestions', COUNT(*) FROM reversible_lane_suggestions
UNION ALL SELECT 'schedules', COUNT(*) FROM reversible_lane_schedules
UNION ALL SELECT 'plan items', COUNT(*) FROM plan_items
UNION ALL SELECT 'simulation runs', COUNT(*) FROM simulation_runs;

SELECT corridor_name, active_segments, average_speed_kph,
       unfit_vehicle_percent, worst_imbalance, pending_suggestions
FROM corridor_dashboard
ORDER BY corridor_name;

\echo 'All database checks passed.'
