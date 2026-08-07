BEGIN;

CREATE OR REPLACE FUNCTION setting_numeric(p_key text, p_default numeric)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT setting_value FROM app_settings WHERE setting_key = p_key),
        p_default
    );
$$;

CREATE OR REPLACE FUNCTION validate_segment_lane_split()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_lanes smallint;
    v_inbound smallint;
    v_outbound smallint;
BEGIN
    SELECT total_lanes INTO v_total_lanes
    FROM road_segments
    WHERE segment_id = NEW.segment_id;

    IF TG_TABLE_NAME = 'reversible_lane_suggestions' THEN
        v_inbound := NEW.recommended_inbound_lanes;
        v_outbound := NEW.recommended_outbound_lanes;
    ELSIF TG_TABLE_NAME = 'reversible_lane_schedules' THEN
        v_inbound := NEW.inbound_lanes;
        v_outbound := NEW.outbound_lanes;
    ELSE
        v_inbound := NEW.recommended_inbound_lanes;
        v_outbound := NEW.recommended_outbound_lanes;
    END IF;

    IF v_total_lanes IS NULL THEN
        RAISE EXCEPTION 'Unknown segment id %', NEW.segment_id;
    END IF;

    IF v_inbound + v_outbound <> v_total_lanes THEN
        RAISE EXCEPTION 'Lane split % + % must equal segment % total lanes (%)',
            v_inbound, v_outbound, NEW.segment_id, v_total_lanes;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_suggestion_lane_split
BEFORE INSERT OR UPDATE OF segment_id, recommended_inbound_lanes, recommended_outbound_lanes
ON reversible_lane_suggestions
FOR EACH ROW EXECUTE FUNCTION validate_segment_lane_split();

CREATE TRIGGER trg_validate_schedule_lane_split
BEFORE INSERT OR UPDATE OF segment_id, inbound_lanes, outbound_lanes
ON reversible_lane_schedules
FOR EACH ROW EXECUTE FUNCTION validate_segment_lane_split();

CREATE TRIGGER trg_validate_plan_item_lane_split
BEFORE INSERT OR UPDATE OF segment_id, recommended_inbound_lanes, recommended_outbound_lanes
ON plan_items
FOR EACH ROW EXECUTE FUNCTION validate_segment_lane_split();

CREATE OR REPLACE FUNCTION validate_detection_camera_segment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_camera_segment bigint;
    v_direction varchar(10);
BEGIN
    SELECT segment_id, monitored_direction
    INTO v_camera_segment, v_direction
    FROM anpr_cameras
    WHERE camera_id = NEW.camera_id;

    IF v_camera_segment IS DISTINCT FROM NEW.segment_id THEN
        RAISE EXCEPTION 'Camera % belongs to segment %, not segment %',
            NEW.camera_id, v_camera_segment, NEW.segment_id;
    END IF;

    IF v_direction <> 'both' AND v_direction <> NEW.travel_direction THEN
        RAISE EXCEPTION 'Camera % monitors %, not %',
            NEW.camera_id, v_direction, NEW.travel_direction;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_detection
BEFORE INSERT OR UPDATE OF camera_id, segment_id, travel_direction
ON anpr_detections
FOR EACH ROW EXECUTE FUNCTION validate_detection_camera_segment();

CREATE OR REPLACE FUNCTION calculate_direction_imbalance(
    p_segment_id bigint,
    p_hour timestamptz
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN COALESCE(SUM(outbound_vehicle_count), 0) = 0
            THEN CASE WHEN COALESCE(SUM(inbound_vehicle_count), 0) = 0 THEN 1.0 ELSE 999.0 END
        ELSE ROUND(
            SUM(inbound_vehicle_count)::numeric / NULLIF(SUM(outbound_vehicle_count), 0),
            3
        )
    END
    FROM traffic_readings
    WHERE segment_id = p_segment_id
      AND recorded_at >= date_trunc('hour', p_hour)
      AND recorded_at < date_trunc('hour', p_hour) + interval '1 hour';
$$;

CREATE OR REPLACE FUNCTION unfit_vehicle_ratio(
    p_segment_id bigint,
    p_window tstzrange
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    WITH detection_fitness AS (
        SELECT d.detection_id,
               CASE
                   WHEN f.status IN ('expired', 'failed') THEN true
                   WHEN f.expiry_date < d.detected_at::date THEN true
                   WHEN f.fitness_id IS NULL THEN true
                   ELSE false
               END AS is_unfit
        FROM anpr_detections d
        LEFT JOIN LATERAL (
            SELECT fs.fitness_id, fs.status, fs.expiry_date
            FROM vehicle_fitness_status fs
            WHERE fs.vehicle_id = d.vehicle_id
              AND fs.inspected_at <= d.detected_at::date
            ORDER BY fs.inspected_at DESC, fs.fitness_id DESC
            LIMIT 1
        ) f ON true
        WHERE d.segment_id = p_segment_id
          AND d.detected_at <@ p_window
    )
    SELECT COALESCE(
        ROUND(COUNT(*) FILTER (WHERE is_unfit)::numeric / NULLIF(COUNT(*), 0), 4),
        0
    )
    FROM detection_fitness;
$$;

CREATE OR REPLACE FUNCTION recommend_lane_split(
    p_segment_id bigint,
    p_date date
)
RETURNS TABLE (
    inbound_lanes smallint,
    outbound_lanes smallint,
    rationale text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total smallint;
    v_base_in smallint;
    v_base_out smallint;
    v_in_count numeric;
    v_out_count numeric;
    v_new_in integer;
BEGIN
    SELECT total_lanes, base_inbound_lanes, base_outbound_lanes
    INTO v_total, v_base_in, v_base_out
    FROM road_segments
    WHERE segment_id = p_segment_id AND active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active segment % not found', p_segment_id;
    END IF;

    SELECT inbound_vehicle_count, outbound_vehicle_count
    INTO v_in_count, v_out_count
    FROM traffic_readings
    WHERE segment_id = p_segment_id
      AND recorded_at >= p_date::timestamptz
      AND recorded_at < (p_date + 1)::timestamptz
    ORDER BY GREATEST(
        inbound_vehicle_count::numeric / NULLIF(outbound_vehicle_count, 0),
        outbound_vehicle_count::numeric / NULLIF(inbound_vehicle_count, 0)
    ) DESC NULLS LAST,
    (inbound_vehicle_count + outbound_vehicle_count) DESC
    LIMIT 1;

    IF v_in_count IS NULL OR (v_in_count + v_out_count) = 0 THEN
        RETURN QUERY SELECT v_base_in, v_base_out, 'No readings: retain the base lane split';
        RETURN;
    END IF;

    v_new_in := ROUND(v_total * v_in_count / (v_in_count + v_out_count));
    v_new_in := GREATEST(1, LEAST(v_total - 1, v_new_in));

    RETURN QUERY SELECT
        v_new_in::smallint,
        (v_total - v_new_in)::smallint,
        format(
            'Peak directional demand was %s inbound versus %s outbound vehicles',
            v_in_count::integer,
            v_out_count::integer
        );
END;
$$;

CREATE OR REPLACE FUNCTION detect_sustained_imbalance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_threshold numeric := setting_numeric('imbalance_threshold', 1.50);
    v_current_ratio numeric;
    v_current_direction text;
    v_previous traffic_readings%ROWTYPE;
    v_previous_ratio numeric;
    v_previous_direction text;
    v_split record;
    v_unfit numeric;
BEGIN
    v_current_ratio := CASE
        WHEN NEW.outbound_vehicle_count = 0 THEN 999
        ELSE NEW.inbound_vehicle_count::numeric / NEW.outbound_vehicle_count
    END;
    v_current_direction := CASE WHEN v_current_ratio >= 1 THEN 'inbound' ELSE 'outbound' END;

    IF GREATEST(v_current_ratio, 1 / NULLIF(v_current_ratio, 0)) < v_threshold THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_previous
    FROM traffic_readings
    WHERE segment_id = NEW.segment_id
      AND recorded_at <= NEW.recorded_at - interval '1 hour'
      AND recorded_at >= NEW.recorded_at - interval '2 hours'
    ORDER BY recorded_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    v_previous_ratio := CASE
        WHEN v_previous.outbound_vehicle_count = 0 THEN 999
        ELSE v_previous.inbound_vehicle_count::numeric / v_previous.outbound_vehicle_count
    END;
    v_previous_direction := CASE WHEN v_previous_ratio >= 1 THEN 'inbound' ELSE 'outbound' END;

    IF v_previous_direction <> v_current_direction
       OR GREATEST(v_previous_ratio, 1 / NULLIF(v_previous_ratio, 0)) < v_threshold THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_split FROM recommend_lane_split(NEW.segment_id, NEW.recorded_at::date);
    v_unfit := unfit_vehicle_ratio(
        NEW.segment_id,
        tstzrange(v_previous.recorded_at, NEW.recorded_at + interval '1 hour', '[)')
    );

    INSERT INTO reversible_lane_suggestions (
        segment_id, evidence_window, proposed_window,
        measured_imbalance_ratio, measured_unfit_ratio,
        recommended_inbound_lanes, recommended_outbound_lanes, reason
    ) VALUES (
        NEW.segment_id,
        tstzrange(v_previous.recorded_at, NEW.recorded_at + interval '1 hour', '[)'),
        tstzrange(NEW.recorded_at + interval '1 hour', NEW.recorded_at + interval '3 hours', '[)'),
        ROUND(GREATEST(v_current_ratio, 1 / NULLIF(v_current_ratio, 0)), 3),
        v_unfit,
        v_split.inbound_lanes,
        v_split.outbound_lanes,
        format(
            'Sustained %s pressure detected for at least one hour. %s',
            v_current_direction,
            v_split.rationale
        )
    ) ON CONFLICT (segment_id, proposed_window) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_detect_imbalance
AFTER INSERT ON traffic_readings
FOR EACH ROW EXECUTE FUNCTION detect_sustained_imbalance();

CREATE OR REPLACE FUNCTION prepare_suggestion_approval()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status <> 'approved' AND NEW.status = 'approved' THEN
        NEW.approved_at := COALESCE(NEW.approved_at, now());
        NEW.approved_by := COALESCE(NULLIF(NEW.approved_by, ''), current_user);
    ELSIF OLD.status IN ('approved', 'applied') AND NEW.status = 'pending' THEN
        RAISE EXCEPTION 'An approved/applied suggestion cannot return to pending';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prepare_suggestion_approval
BEFORE UPDATE OF status ON reversible_lane_suggestions
FOR EACH ROW EXECUTE FUNCTION prepare_suggestion_approval();

CREATE OR REPLACE FUNCTION apply_approved_suggestion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_schedule_id bigint;
BEGIN
    IF OLD.status <> 'approved' AND NEW.status = 'approved' THEN
        INSERT INTO reversible_lane_schedules (
            suggestion_id, segment_id, active_window,
            inbound_lanes, outbound_lanes, created_by
        ) VALUES (
            NEW.suggestion_id, NEW.segment_id, NEW.proposed_window,
            NEW.recommended_inbound_lanes, NEW.recommended_outbound_lanes,
            NEW.approved_by
        )
        RETURNING schedule_id INTO v_schedule_id;

        INSERT INTO lane_change_log (
            suggestion_id, schedule_id, segment_id, action, actor, details
        ) VALUES (
            NEW.suggestion_id,
            v_schedule_id,
            NEW.segment_id,
            'suggestion_approved',
            NEW.approved_by,
            jsonb_build_object(
                'inbound_lanes', NEW.recommended_inbound_lanes,
                'outbound_lanes', NEW.recommended_outbound_lanes,
                'window', NEW.proposed_window::text
            )
        );

        UPDATE reversible_lane_suggestions
        SET status = 'applied'
        WHERE suggestion_id = NEW.suggestion_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_suggestion
AFTER UPDATE OF status ON reversible_lane_suggestions
FOR EACH ROW EXECUTE FUNCTION apply_approved_suggestion();

CREATE OR REPLACE PROCEDURE generate_lane_reallocation_plan(p_plan_date date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan_id bigint;
    v_item_id bigint;
    v_segment record;
    v_split record;
    v_unfit numeric;
    v_threshold numeric := setting_numeric('unfit_vehicle_threshold', 0.25);
    v_action varchar(30);
    v_team_id bigint;
    v_suggestion_id bigint;
    segment_cursor CURSOR FOR
        SELECT segment_id, base_inbound_lanes, base_outbound_lanes
        FROM road_segments
        WHERE active
        ORDER BY segment_id;
BEGIN
    INSERT INTO reallocation_plans(plan_date, status, generated_at)
    VALUES (p_plan_date, 'draft', now())
    ON CONFLICT (plan_date) DO UPDATE
        SET status = 'draft', generated_at = now(), generated_by = current_user
    RETURNING plan_id INTO v_plan_id;

    DELETE FROM plan_items WHERE plan_id = v_plan_id;

    OPEN segment_cursor;
    LOOP
        FETCH segment_cursor INTO v_segment;
        EXIT WHEN NOT FOUND;

        SELECT * INTO v_split
        FROM recommend_lane_split(v_segment.segment_id, p_plan_date);

        v_unfit := unfit_vehicle_ratio(
            v_segment.segment_id,
            tstzrange(p_plan_date::timestamptz, (p_plan_date + 1)::timestamptz, '[)')
        );

        SELECT suggestion_id INTO v_suggestion_id
        FROM reversible_lane_suggestions
        WHERE segment_id = v_segment.segment_id
          AND status IN ('pending', 'approved', 'applied')
        ORDER BY generated_at DESC
        LIMIT 1;

        v_action := CASE
            WHEN (v_split.inbound_lanes <> v_segment.base_inbound_lanes
                  OR v_split.outbound_lanes <> v_segment.base_outbound_lanes)
                 AND v_unfit >= v_threshold THEN 'reallocate_and_enforce'
            WHEN v_split.inbound_lanes <> v_segment.base_inbound_lanes
                 OR v_split.outbound_lanes <> v_segment.base_outbound_lanes THEN 'reallocate'
            WHEN v_unfit >= v_threshold THEN 'enforce'
            ELSE 'monitor'
        END;

        INSERT INTO plan_items (
            plan_id, segment_id, suggestion_id,
            recommended_inbound_lanes, recommended_outbound_lanes,
            action, unfit_ratio, rationale
        ) VALUES (
            v_plan_id, v_segment.segment_id, v_suggestion_id,
            v_split.inbound_lanes, v_split.outbound_lanes,
            v_action, v_unfit,
            v_split.rationale || format('; unfit vehicle share is %s%%', ROUND(v_unfit * 100, 1))
        ) RETURNING plan_item_id INTO v_item_id;

        IF v_action IN ('enforce', 'reallocate_and_enforce') THEN
            SELECT t.team_id INTO v_team_id
            FROM enforcement_teams t
            WHERE t.active
            ORDER BY (
                SELECT COUNT(*)
                FROM enforcement_deployments d
                WHERE d.team_id = t.team_id
                  AND d.deployment_window && tstzrange(
                      p_plan_date::timestamptz + interval '7 hours',
                      p_plan_date::timestamptz + interval '10 hours',
                      '[)'
                  )
                  AND d.status <> 'cancelled'
            ), t.team_id
            LIMIT 1;

            IF v_team_id IS NOT NULL THEN
                INSERT INTO enforcement_deployments (
                    team_id, segment_id, plan_item_id, deployment_window, reason
                ) VALUES (
                    v_team_id,
                    v_segment.segment_id,
                    v_item_id,
                    tstzrange(
                        p_plan_date::timestamptz + interval '7 hours',
                        p_plan_date::timestamptz + interval '10 hours',
                        '[)'
                    ),
                    format('Unfit vehicle ratio %s%% exceeded threshold', ROUND(v_unfit * 100, 1))
                );
            END IF;
        END IF;
    END LOOP;
    CLOSE segment_cursor;

    IF (SELECT COUNT(*) FROM plan_items WHERE plan_id = v_plan_id)
       <> (SELECT COUNT(*) FROM road_segments WHERE active) THEN
        RAISE EXCEPTION 'Daily plan does not cover every active segment';
    END IF;

    UPDATE reallocation_plans
    SET status = 'ready'
    WHERE plan_id = v_plan_id;
END;
$$;

COMMIT;
