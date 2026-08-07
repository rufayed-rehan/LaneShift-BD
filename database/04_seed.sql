BEGIN;

INSERT INTO app_settings(setting_key, setting_value, description) VALUES
    ('imbalance_threshold', 1.50, 'Minimum directional ratio that counts as an imbalance'),
    ('unfit_vehicle_threshold', 0.25, 'Share of unfit detections that triggers enforcement'),
    ('low_speed_ratio', 0.45, 'Share of speed limit used by the slow-vehicle signature');

INSERT INTO corridors(name, description) VALUES
    ('Airport Road', 'Uttara to central Dhaka airport approach'),
    ('Mirpur Road', 'Mirpur to Dhanmondi and central Dhaka'),
    ('Pragati Sarani', 'Badda-Rampura north-south arterial');

INSERT INTO road_segments(
    corridor_id, segment_code, name, inbound_label, outbound_label,
    total_lanes, base_inbound_lanes, base_outbound_lanes,
    length_km, capacity_per_lane, speed_limit_kph
) VALUES
    (1, 'AIR-01', 'Airport to Khilkhet', 'Toward Banani', 'Toward Airport', 6, 3, 3, 3.20, 1800, 60),
    (1, 'AIR-02', 'Khilkhet to Banani', 'Toward Mohakhali', 'Toward Khilkhet', 4, 2, 2, 4.10, 1650, 50),
    (1, 'AIR-03', 'Banani to Mohakhali', 'Toward Mohakhali', 'Toward Banani', 6, 3, 3, 2.80, 1750, 50),
    (2, 'MIR-01', 'Gabtoli to Technical', 'Toward Dhanmondi', 'Toward Gabtoli', 6, 3, 3, 2.40, 1550, 45),
    (2, 'MIR-02', 'Technical to Shyamoli', 'Toward Dhanmondi', 'Toward Technical', 4, 2, 2, 2.10, 1500, 45),
    (3, 'PRA-01', 'Badda to Rampura', 'Toward Malibagh', 'Toward Badda', 6, 3, 3, 3.70, 1600, 50),
    (3, 'PRA-02', 'Rampura to Malibagh', 'Toward Malibagh', 'Toward Rampura', 4, 2, 2, 2.90, 1450, 45);

INSERT INTO anpr_cameras(segment_id, camera_code, location_description, monitored_direction) VALUES
    (1, 'CAM-AIR-01', 'Airport Road north gantry', 'both'),
    (2, 'CAM-AIR-02', 'Khilkhet footbridge', 'both'),
    (3, 'CAM-AIR-03', 'Banani rail crossing', 'both'),
    (4, 'CAM-MIR-01', 'Gabtoli bus terminal approach', 'both'),
    (5, 'CAM-MIR-02', 'Technical intersection', 'both'),
    (6, 'CAM-PRA-01', 'Badda link road', 'both'),
    (7, 'CAM-PRA-02', 'Rampura bridge approach', 'both');

INSERT INTO vehicles(plate_number, vehicle_type, registration_date, owner_district)
SELECT
    format('DHAKA-%s-%s',
        CASE WHEN n % 2 = 0 THEN 'METRO' ELSE 'CITY' END,
        LPAD((1000 + n)::text, 4, '0')
    ),
    (ARRAY['car', 'bus', 'truck', 'motorcycle', 'cng', 'microbus'])[(n % 6) + 1],
    current_date - (500 + n * 37),
    (ARRAY['Dhaka', 'Gazipur', 'Narayanganj', 'Savar'])[(n % 4) + 1]
FROM generate_series(1, 24) AS g(n);

INSERT INTO vehicle_fitness_status(
    vehicle_id, certificate_number, inspected_at, expiry_date, status, notes
)
SELECT
    vehicle_id,
    format('FIT-%s-%s', EXTRACT(YEAR FROM current_date)::integer, LPAD(vehicle_id::text, 5, '0')),
    current_date - 365,
    CASE
        WHEN vehicle_id % 4 = 0 THEN current_date - 30
        ELSE current_date + 180
    END,
    CASE
        WHEN vehicle_id % 7 = 0 THEN 'failed'
        WHEN vehicle_id % 4 = 0 THEN 'expired'
        ELSE 'valid'
    END,
    CASE
        WHEN vehicle_id % 7 = 0 THEN 'Failed brake or emission inspection'
        WHEN vehicle_id % 4 = 0 THEN 'Certificate renewal overdue'
        ELSE 'Certificate current'
    END
FROM vehicles;

INSERT INTO enforcement_teams(team_code, team_name, base_location, contact_number) VALUES
    ('DMP-TR-01', 'Traffic Enforcement North', 'Uttara', '+880-2-55000001'),
    ('DMP-TR-02', 'Traffic Enforcement West', 'Mirpur', '+880-2-55000002'),
    ('DMP-TR-03', 'Traffic Enforcement East', 'Badda', '+880-2-55000003');

ALTER TABLE traffic_readings DISABLE TRIGGER trg_detect_imbalance;

WITH hours AS (
    SELECT generate_series(
        date_trunc('hour', now()) - interval '35 hours',
        date_trunc('hour', now()),
        interval '1 hour'
    ) AS reading_hour
), base AS (
    SELECT
        rs.segment_id,
        h.reading_hour,
        EXTRACT(HOUR FROM h.reading_hour AT TIME ZONE 'Asia/Dhaka')::integer AS local_hour,
        150 + rs.segment_id * 18 AS base_volume
    FROM road_segments rs
    CROSS JOIN hours h
)
INSERT INTO traffic_readings(
    segment_id, recorded_at,
    inbound_vehicle_count, outbound_vehicle_count,
    avg_inbound_speed_kph, avg_outbound_speed_kph
)
SELECT
    segment_id,
    reading_hour,
    CASE
        WHEN local_hour BETWEEN 7 AND 10 THEN base_volume * 2 + segment_id * 11
        WHEN local_hour BETWEEN 17 AND 20 THEN (base_volume * 0.70)::integer
        ELSE base_volume + local_hour * 3
    END,
    CASE
        WHEN local_hour BETWEEN 7 AND 10 THEN (base_volume * 0.65)::integer
        WHEN local_hour BETWEEN 17 AND 20 THEN base_volume * 2 + segment_id * 9
        ELSE base_volume + (23 - local_hour) * 2
    END,
    CASE
        WHEN local_hour BETWEEN 7 AND 10 THEN 16 + segment_id
        ELSE 31 + (segment_id % 5)
    END,
    CASE
        WHEN local_hour BETWEEN 17 AND 20 THEN 15 + segment_id
        ELSE 32 + (segment_id % 4)
    END
FROM base
ORDER BY reading_hour, segment_id;

ALTER TABLE traffic_readings ENABLE TRIGGER trg_detect_imbalance;

WITH generated AS (
    SELECT
        c.camera_id,
        c.segment_id,
        hour_offset,
        occurrence,
        ((c.camera_id * 7 + hour_offset * 3 + occurrence) % 24) + 1 AS vehicle_id
    FROM anpr_cameras c
    CROSS JOIN generate_series(0, 23) AS h(hour_offset)
    CROSS JOIN generate_series(0, 3) AS o(occurrence)
)
INSERT INTO anpr_detections(
    camera_id, vehicle_id, segment_id, detected_at,
    travel_direction, observed_speed_kph, confidence
)
SELECT
    camera_id,
    vehicle_id,
    segment_id,
    date_trunc('hour', now()) - make_interval(hours => hour_offset)
        + make_interval(mins => (occurrence * 11 + segment_id)::integer),
    CASE WHEN occurrence % 2 = 0 THEN 'inbound' ELSE 'outbound' END,
    CASE WHEN vehicle_id % 4 = 0 OR vehicle_id % 7 = 0
        THEN 13 + (vehicle_id % 8)
        ELSE 29 + (vehicle_id % 16)
    END,
    0.930 + occurrence * 0.015
FROM generated;

INSERT INTO reversible_lane_suggestions(
    segment_id, evidence_window, proposed_window,
    measured_imbalance_ratio, measured_unfit_ratio,
    recommended_inbound_lanes, recommended_outbound_lanes,
    reason
) VALUES
    (
        1,
        tstzrange(date_trunc('hour', now()) - interval '2 hours', date_trunc('hour', now()), '[)'),
        tstzrange(date_trunc('day', now()) + interval '1 day 7 hours', date_trunc('day', now()) + interval '1 day 10 hours', '[)'),
        2.250, 0.2100, 4, 2,
        'Morning inbound demand is more than twice outbound demand.'
    ),
    (
        2,
        tstzrange(date_trunc('hour', now()) - interval '2 hours', date_trunc('hour', now()), '[)'),
        tstzrange(date_trunc('day', now()) + interval '1 day 7 hours', date_trunc('day', now()) + interval '1 day 10 hours', '[)'),
        2.100, 0.3300, 3, 1,
        'Morning imbalance plus a high unfit-vehicle share requires reallocation and enforcement.'
    ),
    (
        3,
        tstzrange(date_trunc('hour', now()) - interval '2 hours', date_trunc('hour', now()), '[)'),
        tstzrange(date_trunc('day', now()) + interval '1 day 17 hours', date_trunc('day', now()) + interval '1 day 20 hours', '[)'),
        2.320, 0.1800, 2, 4,
        'Evening outbound demand is dominant on the Banani approach.'
    ),
    (
        4,
        tstzrange(date_trunc('hour', now()) - interval '3 hours', date_trunc('hour', now()) - interval '1 hour', '[)'),
        tstzrange(date_trunc('hour', now()) - interval '30 minutes', date_trunc('hour', now()) + interval '2 hours', '[)'),
        1.880, 0.2900, 4, 2,
        'Approved demonstration reallocation currently active on Mirpur Road.'
    )
ON CONFLICT (segment_id, proposed_window) DO NOTHING;

UPDATE reversible_lane_suggestions
SET status = 'approved', approved_by = 'demo.operator'
WHERE segment_id = 4
  AND proposed_window @> now()
  AND status = 'pending';

CALL generate_lane_reallocation_plan(current_date);

COMMIT;
