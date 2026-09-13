from __future__ import annotations

from typing import Any

import psycopg

from . import db
from .simulation import ScenarioConfig, SegmentConfig, evaluate_all_candidates


SCENARIO_SELECT = """
    SELECT scenario_id, scenario_code, name, description,
           inbound_rate_vph, outbound_rate_vph,
           inbound_surge_multiplier, outbound_surge_multiplier,
           surge_start_minute, incident_direction, incident_start_minute,
           incident_capacity_factor, weather_speed_factor,
           duration_minutes, active
    FROM traffic_scenarios
"""


def list_scenarios() -> list[dict[str, Any]]:
    return db.fetch_all(
        SCENARIO_SELECT
        + """
          WHERE active
          ORDER BY CASE scenario_code
              WHEN 'morning_peak' THEN 1
              WHEN 'evening_peak' THEN 2
              WHEN 'inbound_accident' THEN 3
              WHEN 'heavy_rain' THEN 4
              ELSE 5
          END, name
        """
    )


def _scenario(scenario_code: str) -> dict[str, Any] | None:
    return db.fetch_one(
        SCENARIO_SELECT + " WHERE scenario_code = %s AND active",
        (scenario_code,),
    )


def _segment(segment_id: int) -> dict[str, Any] | None:
    return db.fetch_one(
        """
        SELECT segment_id, segment_code, name, total_lanes,
               base_inbound_lanes, base_outbound_lanes,
               capacity_per_lane, speed_limit_kph
        FROM road_segments
        WHERE segment_id = %s AND active
        """,
        (segment_id,),
    )


def run_simulation(*, scenario_code: str, segment_id: int, seed: int) -> dict[str, Any]:
    scenario_record = _scenario(scenario_code)
    if scenario_record is None:
        raise LookupError(f"Active scenario '{scenario_code}' was not found")
    segment_record = _segment(segment_id)
    if segment_record is None:
        raise LookupError(f"Active road segment {segment_id} was not found")

    scenario = ScenarioConfig.from_record(scenario_record)
    segment = SegmentConfig.from_record(segment_record)
    run = db.fetch_one(
        """
        INSERT INTO simulation_runs(
            scenario_id, segment_id, random_seed, duration_minutes,
            baseline_inbound_lanes, baseline_outbound_lanes,
            execution_mode, algorithm_version
        ) VALUES (%s, %s, %s, %s, %s, %s, 'simulation', 'simpy-search-v1')
        RETURNING run_id
        """,
        (
            scenario.scenario_id,
            segment.segment_id,
            seed,
            scenario.duration_minutes,
            segment.baseline_inbound_lanes,
            segment.baseline_outbound_lanes,
        ),
    )
    if run is None:
        raise RuntimeError("PostgreSQL did not return the new simulation run")
    run_id = int(run["run_id"])
    db.execute("UPDATE simulation_runs SET status = 'running' WHERE run_id = %s", (run_id,))

    try:
        candidates = evaluate_all_candidates(
            segment=segment,
            scenario=scenario,
            seed=seed,
        )
        with db.connect() as connection:
            with connection.cursor() as cursor:
                for candidate in candidates:
                    cursor.execute(
                        """
                        INSERT INTO simulation_candidates(
                            run_id, inbound_lanes, outbound_lanes, is_baseline,
                            average_wait_seconds, p95_wait_seconds,
                            max_queue_vehicles, completed_vehicles,
                            unprocessed_vehicles, average_speed_kph,
                            throughput_vph, objective_score
                        ) VALUES (
                            %s, %s, %s, %s, %s, %s,
                            %s, %s, %s, %s, %s, %s
                        )
                        RETURNING candidate_id
                        """,
                        (
                            run_id,
                            candidate.inbound_lanes,
                            candidate.outbound_lanes,
                            candidate.is_baseline,
                            candidate.average_wait_seconds,
                            candidate.p95_wait_seconds,
                            candidate.max_queue_vehicles,
                            candidate.completed_vehicles,
                            candidate.unprocessed_vehicles,
                            candidate.average_speed_kph,
                            candidate.throughput_vph,
                            candidate.objective_score,
                        ),
                    )
                    candidate_id = int(cursor.fetchone()["candidate_id"])
                    cursor.executemany(
                        """
                        INSERT INTO simulation_samples(
                            candidate_id, simulated_minute,
                            inbound_queue, outbound_queue,
                            cumulative_completed,
                            inbound_average_wait_seconds,
                            outbound_average_wait_seconds,
                            inbound_speed_kph, outbound_speed_kph
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                        """,
                        [
                            (
                                candidate_id,
                                sample.simulated_minute,
                                sample.inbound_queue,
                                sample.outbound_queue,
                                sample.cumulative_completed,
                                sample.inbound_average_wait_seconds,
                                sample.outbound_average_wait_seconds,
                                sample.inbound_speed_kph,
                                sample.outbound_speed_kph,
                            )
                            for sample in candidate.samples
                        ],
                    )
                cursor.execute(
                    "SELECT finalize_simulation_run(%s) AS decision_id",
                    (run_id,),
                )
                cursor.fetchone()
    except Exception as exc:
        try:
            db.execute(
                """
                UPDATE simulation_runs
                SET status = 'failed', error_message = %s
                WHERE run_id = %s AND status = 'running'
                """,
                (str(exc)[:2000], run_id),
            )
        except psycopg.Error:
            pass
        raise

    detail = get_run(run_id)
    if detail is None:
        raise RuntimeError(f"Completed simulation run {run_id} could not be loaded")
    return detail


def list_runs(limit: int = 20) -> list[dict[str, Any]]:
    return db.fetch_all(
        """
        SELECT run_id, run_status, execution_mode, random_seed,
               duration_minutes, requested_at, completed_at,
               scenario_code, scenario_name,
               segment_id, segment_code, segment_name, total_lanes,
               baseline_inbound_lanes, baseline_outbound_lanes,
               baseline_wait_seconds, baseline_max_queue,
               selected_inbound_lanes, selected_outbound_lanes,
               selected_wait_seconds, selected_max_queue,
               decision_type, predicted_improvement_percent,
               decision_status, decision_reason
        FROM simulation_run_dashboard
        ORDER BY requested_at DESC, run_id DESC
        LIMIT %s
        """,
        (limit,),
    )


def get_run(run_id: int) -> dict[str, Any] | None:
    summary = db.fetch_one(
        """
        SELECT *
        FROM simulation_run_dashboard
        WHERE run_id = %s
        """,
        (run_id,),
    )
    if summary is None:
        return None
    summary["candidates"] = db.fetch_all(
        """
        SELECT candidate_id, inbound_lanes, outbound_lanes,
               is_baseline, is_selected, average_wait_seconds,
               p95_wait_seconds, max_queue_vehicles,
               completed_vehicles, unprocessed_vehicles,
               average_speed_kph, throughput_vph,
               objective_score, improvement_percent, performance_rank
        FROM simulation_candidate_comparison
        WHERE run_id = %s
        ORDER BY inbound_lanes
        """,
        (run_id,),
    )
    summary["samples"] = db.fetch_all(
        """
        SELECT ss.candidate_id, sc.inbound_lanes, sc.outbound_lanes,
               sc.is_baseline, sc.is_selected,
               ss.simulated_minute, ss.inbound_queue, ss.outbound_queue,
               ss.cumulative_completed,
               ss.inbound_average_wait_seconds,
               ss.outbound_average_wait_seconds,
               ss.inbound_speed_kph, ss.outbound_speed_kph
        FROM simulation_samples ss
        JOIN simulation_candidates sc USING (candidate_id)
        WHERE sc.run_id = %s
          AND (sc.is_baseline OR sc.is_selected)
        ORDER BY sc.is_baseline DESC, ss.simulated_minute
        """,
        (run_id,),
    )
    summary["events"] = db.fetch_all(
        """
        SELECT event_id, decision_id, event_type, message, details, created_at
        FROM automation_events
        WHERE run_id = %s
        ORDER BY event_id
        """,
        (run_id,),
    )
    return summary


def override_decision(*, run_id: int, operator: str, reason: str) -> dict[str, Any]:
    db.fetch_one(
        "SELECT override_automation_decision(%s, %s, %s) AS decision_id",
        (run_id, operator, reason),
    )
    detail = get_run(run_id)
    if detail is None:
        raise LookupError(f"Simulation run {run_id} was not found")
    return detail


def database_evidence() -> dict[str, Any]:
    counts = db.fetch_one(
        """
        SELECT
            (SELECT COUNT(*) FROM traffic_scenarios) AS traffic_scenarios,
            (SELECT COUNT(*) FROM simulation_runs) AS simulation_runs,
            (SELECT COUNT(*) FROM simulation_candidates) AS candidate_results,
            (SELECT COUNT(*) FROM simulation_samples) AS time_series_samples,
            (SELECT COUNT(*) FROM automation_decisions) AS automation_decisions,
            (SELECT COUNT(*) FROM automation_events) AS audit_events
        """
    ) or {}
    database_objects = db.fetch_one(
        """
        SELECT
            (SELECT COUNT(*) FROM information_schema.tables
             WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS tables,
            (SELECT COUNT(*) FROM information_schema.views
             WHERE table_schema = 'public') AS views,
            (SELECT COUNT(DISTINCT p.oid)
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             LEFT JOIN pg_depend dep
               ON dep.classid = 'pg_proc'::regclass
              AND dep.objid = p.oid
              AND dep.deptype = 'e'
             WHERE n.nspname = 'public'
               AND dep.objid IS NULL) AS functions_and_procedures,
            (SELECT COUNT(*) FROM information_schema.triggers
             WHERE trigger_schema = 'public') AS triggers,
            (SELECT COUNT(*) FROM pg_indexes
             WHERE schemaname = 'public') AS indexes
        """
    ) or {}
    return {
        "row_counts": counts,
        "database_objects": database_objects,
        "safeguards": [
            "Candidate and decision lane totals must match the selected road segment",
            "At least one lane remains open in each direction",
            "Exactly one baseline and one selected candidate are allowed per run",
            "Run status follows queued, running, then completed or failed",
            "Reversible-lane schedules cannot overlap for the same segment",
            "Every candidate, state transition, decision, and override is audited",
        ],
    }
