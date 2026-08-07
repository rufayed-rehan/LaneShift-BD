\pset pager off
\echo 'Running LaneShift BD database verification...'

DO $$
DECLARE
    v_active_segments integer;
    v_plan_items integer;
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

    IF NOT EXISTS (SELECT 1 FROM reversible_lane_suggestions WHERE status = 'pending') THEN
        RAISE EXCEPTION 'Expected at least one pending suggestion';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM reversible_lane_schedules) THEN
        RAISE EXCEPTION 'Approval trigger did not create a schedule';
    END IF;
END;
$$;

SELECT 'corridors' AS item, COUNT(*) AS row_count FROM corridors
UNION ALL SELECT 'segments', COUNT(*) FROM road_segments
UNION ALL SELECT 'traffic readings', COUNT(*) FROM traffic_readings
UNION ALL SELECT 'ANPR detections', COUNT(*) FROM anpr_detections
UNION ALL SELECT 'suggestions', COUNT(*) FROM reversible_lane_suggestions
UNION ALL SELECT 'schedules', COUNT(*) FROM reversible_lane_schedules
UNION ALL SELECT 'plan items', COUNT(*) FROM plan_items;

SELECT corridor_name, active_segments, average_speed_kph,
       unfit_vehicle_percent, worst_imbalance, pending_suggestions
FROM corridor_dashboard
ORDER BY corridor_name;

\echo 'All database checks passed.'

