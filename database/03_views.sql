BEGIN;

CREATE OR REPLACE VIEW sustained_imbalance_analysis AS
WITH hourly AS (
    SELECT
        tr.segment_id,
        tr.recorded_at,
        tr.inbound_vehicle_count,
        tr.outbound_vehicle_count,
        CASE
            WHEN tr.outbound_vehicle_count = 0 THEN 999::numeric
            ELSE ROUND(tr.inbound_vehicle_count::numeric / tr.outbound_vehicle_count, 3)
        END AS direction_ratio,
        LAG(tr.recorded_at) OVER (
            PARTITION BY tr.segment_id ORDER BY tr.recorded_at
        ) AS previous_hour,
        LAG(
            CASE
                WHEN tr.outbound_vehicle_count = 0 THEN 999::numeric
                ELSE tr.inbound_vehicle_count::numeric / tr.outbound_vehicle_count
            END
        ) OVER (PARTITION BY tr.segment_id ORDER BY tr.recorded_at) AS previous_ratio
    FROM traffic_readings tr
)
SELECT
    h.*,
    CASE
        WHEN h.previous_hour >= h.recorded_at - interval '2 hours'
         AND h.previous_ratio IS NOT NULL
         AND ((h.direction_ratio >= setting_numeric('imbalance_threshold', 1.5)
               AND h.previous_ratio >= setting_numeric('imbalance_threshold', 1.5))
              OR
              (h.direction_ratio <= 1 / setting_numeric('imbalance_threshold', 1.5)
               AND h.previous_ratio <= 1 / setting_numeric('imbalance_threshold', 1.5)))
        THEN true ELSE false
    END AS sustained_over_one_hour
FROM hourly h;

CREATE OR REPLACE VIEW slow_vehicle_signature AS
WITH segment_window AS (
    SELECT
        tr.segment_id,
        SUM(tr.inbound_vehicle_count + tr.outbound_vehicle_count) AS vehicle_volume,
        ROUND(AVG((tr.avg_inbound_speed_kph + tr.avg_outbound_speed_kph) / 2), 1) AS average_speed
    FROM traffic_readings tr
    WHERE tr.recorded_at >= now() - interval '24 hours'
    GROUP BY tr.segment_id
), volume_baseline AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY vehicle_volume) AS median_volume
    FROM segment_window
)
SELECT
    rs.segment_id,
    rs.segment_code,
    rs.name AS segment_name,
    sw.vehicle_volume,
    sw.average_speed,
    unfit_vehicle_ratio(
        rs.segment_id,
        tstzrange(now() - interval '24 hours', now(), '[)')
    ) AS unfit_ratio,
    (sw.vehicle_volume <= vb.median_volume AND sw.average_speed < rs.speed_limit_kph * 0.45) AS likely_slow_vehicle_cause
FROM segment_window sw
JOIN road_segments rs ON rs.segment_id = sw.segment_id
CROSS JOIN volume_baseline vb;

CREATE OR REPLACE VIEW segment_performance AS
SELECT
    rs.segment_id,
    rs.segment_code,
    rs.name AS segment_name,
    rs.inbound_label,
    rs.outbound_label,
    rs.total_lanes,
    c.corridor_id,
    c.name AS corridor_name,
    latest.recorded_at AS latest_reading_at,
    latest.inbound_vehicle_count,
    latest.outbound_vehicle_count,
    latest.avg_inbound_speed_kph,
    latest.avg_outbound_speed_kph,
    CASE
        WHEN latest.outbound_vehicle_count = 0 THEN 999::numeric
        ELSE ROUND(latest.inbound_vehicle_count::numeric / latest.outbound_vehicle_count, 3)
    END AS imbalance_ratio,
    unfit_vehicle_ratio(
        rs.segment_id,
        tstzrange(now() - interval '24 hours', now(), '[)')
    ) AS unfit_ratio,
    sch.schedule_id AS active_schedule_id,
    COALESCE(sch.inbound_lanes, rs.base_inbound_lanes) AS current_inbound_lanes,
    COALESCE(sch.outbound_lanes, rs.base_outbound_lanes) AS current_outbound_lanes,
    sch.active_window,
    (
        SELECT COUNT(*)
        FROM reversible_lane_suggestions s
        WHERE s.segment_id = rs.segment_id AND s.status = 'pending'
    ) AS pending_suggestions
FROM road_segments rs
JOIN corridors c ON c.corridor_id = rs.corridor_id
LEFT JOIN LATERAL (
    SELECT tr.*
    FROM traffic_readings tr
    WHERE tr.segment_id = rs.segment_id
    ORDER BY tr.recorded_at DESC
    LIMIT 1
) latest ON true
LEFT JOIN LATERAL (
    SELECT rls.*
    FROM reversible_lane_schedules rls
    WHERE rls.segment_id = rs.segment_id
      AND now() <@ rls.active_window
      AND rls.status IN ('scheduled', 'active')
    ORDER BY lower(rls.active_window)
    LIMIT 1
) sch ON true
WHERE rs.active;

CREATE OR REPLACE VIEW corridor_dashboard AS
WITH ranked AS (
    SELECT
        sp.*,
        RANK() OVER (
            PARTITION BY sp.corridor_id
            ORDER BY GREATEST(sp.imbalance_ratio, 1 / NULLIF(sp.imbalance_ratio, 0)) DESC NULLS LAST
        ) AS severity_rank
    FROM segment_performance sp
)
SELECT
    corridor_id,
    corridor_name,
    COUNT(*) AS active_segments,
    ROUND(AVG((avg_inbound_speed_kph + avg_outbound_speed_kph) / 2), 1) AS average_speed_kph,
    ROUND(AVG(unfit_ratio) * 100, 1) AS unfit_vehicle_percent,
    MAX(GREATEST(imbalance_ratio, 1 / NULLIF(imbalance_ratio, 0))) AS worst_imbalance,
    MAX(segment_name) FILTER (WHERE severity_rank = 1) AS worst_segment,
    SUM(pending_suggestions) AS pending_suggestions,
    COUNT(*) FILTER (WHERE active_schedule_id IS NOT NULL) AS active_reallocations
FROM ranked
GROUP BY corridor_id, corridor_name;

COMMIT;

