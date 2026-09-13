from __future__ import annotations

from datetime import date
from typing import Literal

import psycopg
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import db
from . import simulation_service


app = FastAPI(
    title="LaneShift BD API",
    version="2.0.0",
    description=(
        "Database-centered traffic simulation and automated reversible-lane "
        "optimization for Dhaka."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ApprovalRequest(BaseModel):
    approved_by: str = Field(min_length=2, max_length=100, examples=["traffic.operator"])


class RejectionRequest(BaseModel):
    rejected_by: str = Field(min_length=2, max_length=100)


class SimulationRunRequest(BaseModel):
    scenario_code: str = Field(min_length=2, max_length=30, examples=["morning_peak"])
    segment_id: int = Field(default=1, ge=1)
    seed: int = Field(default=4410, ge=1, le=2147483647)


class OverrideRequest(BaseModel):
    operator: str = Field(min_length=2, max_length=100, examples=["teacher.demo"])
    reason: str = Field(min_length=5, max_length=500)


@app.get("/")
def root() -> dict[str, str]:
    return {
        "name": "LaneShift BD Traffic Digital Twin API",
        "version": "2.0.0",
        "docs": "/docs",
        "health": "/health",
    }


@app.get("/health")
def health() -> dict[str, str]:
    try:
        result = db.fetch_one("SELECT current_database() AS database, now() AS checked_at")
    except psycopg.Error as exc:
        raise HTTPException(status_code=503, detail="Database connection failed") from exc
    return {
        "status": "ok",
        "database": str(result["database"]),
        "checked_at": result["checked_at"].isoformat(),
    }


@app.get("/api/dashboard/summary")
def dashboard_summary() -> dict:
    return db.fetch_one(
        """
        SELECT
            (SELECT COUNT(*) FROM road_segments WHERE active) AS active_segments,
            (SELECT COUNT(*) FROM reversible_lane_suggestions WHERE status = 'pending') AS pending_suggestions,
            (SELECT COUNT(*) FROM reversible_lane_schedules
                WHERE now() <@ active_window AND status IN ('scheduled', 'active')) AS active_reallocations,
            (SELECT COUNT(*) FROM enforcement_deployments
                WHERE now() <@ deployment_window AND status IN ('scheduled', 'dispatched')) AS active_deployments,
            COALESCE((SELECT ROUND(AVG(unfit_ratio) * 100, 1) FROM segment_performance), 0) AS average_unfit_percent,
            (SELECT COUNT(*) FROM simulation_runs) AS simulation_runs,
            COALESCE((
                SELECT predicted_improvement_percent
                FROM automation_decisions
                ORDER BY decided_at DESC, decision_id DESC
                LIMIT 1
            ), 0) AS latest_simulation_improvement
        """
    ) or {}


@app.get("/api/simulation/scenarios")
def simulation_scenarios() -> list[dict]:
    return simulation_service.list_scenarios()


@app.post("/api/simulation/runs", status_code=201)
def start_simulation(payload: SimulationRunRequest) -> dict:
    try:
        return simulation_service.run_simulation(
            scenario_code=payload.scenario_code,
            segment_id=payload.segment_id,
            seed=payload.seed,
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except psycopg.Error as exc:
        raise HTTPException(
            status_code=500,
            detail=f"PostgreSQL rejected the simulation workflow: {exc}",
        ) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Simulation failed: {exc}") from exc


@app.get("/api/simulation/runs")
def simulation_runs(limit: int = Query(default=20, ge=1, le=100)) -> list[dict]:
    return simulation_service.list_runs(limit)


@app.get("/api/simulation/runs/{run_id}")
def simulation_run_detail(run_id: int) -> dict:
    run = simulation_service.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Simulation run not found")
    return run


@app.post("/api/simulation/runs/{run_id}/override")
def override_simulation(run_id: int, payload: OverrideRequest) -> dict:
    try:
        return simulation_service.override_decision(
            run_id=run_id,
            operator=payload.operator,
            reason=payload.reason,
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except psycopg.Error as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.get("/api/database/evidence")
def database_evidence() -> dict:
    return simulation_service.database_evidence()


@app.get("/api/dashboard/corridors")
def corridor_dashboard() -> list[dict]:
    return db.fetch_all(
        """
        SELECT corridor_id, corridor_name, active_segments, average_speed_kph,
               unfit_vehicle_percent, worst_imbalance, worst_segment,
               pending_suggestions, active_reallocations
        FROM corridor_dashboard
        ORDER BY corridor_name
        """
    )


@app.get("/api/segments")
def segments() -> list[dict]:
    return db.fetch_all(
        """
        SELECT segment_id, segment_code, segment_name, corridor_name,
               inbound_label, outbound_label, total_lanes,
               latest_reading_at, inbound_vehicle_count, outbound_vehicle_count,
               avg_inbound_speed_kph, avg_outbound_speed_kph,
               imbalance_ratio, ROUND(unfit_ratio * 100, 1) AS unfit_percent,
               current_inbound_lanes, current_outbound_lanes,
               active_schedule_id, active_window::text AS active_window,
               pending_suggestions
        FROM segment_performance
        ORDER BY corridor_name, segment_code
        """
    )


@app.get("/api/segments/{segment_id}")
def segment_detail(segment_id: int) -> dict:
    item = db.fetch_one(
        """
        SELECT segment_id, segment_code, segment_name, corridor_name,
               inbound_label, outbound_label, total_lanes,
               latest_reading_at, inbound_vehicle_count, outbound_vehicle_count,
               avg_inbound_speed_kph, avg_outbound_speed_kph,
               imbalance_ratio, ROUND(unfit_ratio * 100, 1) AS unfit_percent,
               current_inbound_lanes, current_outbound_lanes,
               active_schedule_id, active_window::text AS active_window,
               pending_suggestions
        FROM segment_performance
        WHERE segment_id = %s
        """,
        (segment_id,),
    )
    if item is None:
        raise HTTPException(status_code=404, detail="Segment not found")
    return item


@app.get("/api/suggestions")
def suggestions(
    status: Literal["pending", "approved", "applied", "rejected"] | None = Query(default=None),
) -> list[dict]:
    where = "WHERE s.status = %s" if status else ""
    params = (status,) if status else None
    return db.fetch_all(
        f"""
        SELECT s.suggestion_id, s.segment_id, rs.segment_code,
               rs.name AS segment_name, c.name AS corridor_name,
               s.generated_at, s.evidence_window::text AS evidence_window,
               s.proposed_window::text AS proposed_window,
               s.measured_imbalance_ratio,
               ROUND(s.measured_unfit_ratio * 100, 1) AS unfit_percent,
               s.recommended_inbound_lanes, s.recommended_outbound_lanes,
               s.status, s.reason, s.approved_by, s.approved_at
        FROM reversible_lane_suggestions s
        JOIN road_segments rs USING (segment_id)
        JOIN corridors c USING (corridor_id)
        {where}
        ORDER BY s.generated_at DESC, s.suggestion_id DESC
        """,
        params,
    )


@app.patch("/api/suggestions/{suggestion_id}/approve")
def approve_suggestion(suggestion_id: int, payload: ApprovalRequest) -> dict:
    current = db.fetch_one(
        "SELECT status FROM reversible_lane_suggestions WHERE suggestion_id = %s",
        (suggestion_id,),
    )
    if current is None:
        raise HTTPException(status_code=404, detail="Suggestion not found")
    if current["status"] != "pending":
        raise HTTPException(status_code=409, detail="Only pending suggestions can be approved")
    try:
        db.execute(
            """
            UPDATE reversible_lane_suggestions
            SET status = 'approved', approved_by = %s
            WHERE suggestion_id = %s AND status = 'pending'
            """,
            (payload.approved_by, suggestion_id),
        )
    except psycopg.errors.ExclusionViolation as exc:
        raise HTTPException(
            status_code=409,
            detail="This schedule overlaps another lane schedule for the segment.",
        ) from exc
    return db.fetch_one(
        """SELECT suggestion_id, status, approved_by, approved_at
           FROM reversible_lane_suggestions WHERE suggestion_id = %s""",
        (suggestion_id,),
    ) or {}


@app.patch("/api/suggestions/{suggestion_id}/reject")
def reject_suggestion(suggestion_id: int, payload: RejectionRequest) -> dict:
    updated = db.fetch_one(
        """
        UPDATE reversible_lane_suggestions
        SET status = 'rejected', approved_by = %s, approved_at = now()
        WHERE suggestion_id = %s AND status = 'pending'
        RETURNING suggestion_id, status, approved_by, approved_at
        """,
        (payload.rejected_by, suggestion_id),
    )
    if updated is None:
        raise HTTPException(status_code=409, detail="Suggestion is missing or no longer pending")
    return updated


@app.get("/api/schedules")
def schedules(active_only: bool = True) -> list[dict]:
    active_filter = (
        "AND now() <@ s.active_window AND s.status IN ('scheduled', 'active')"
        if active_only else ""
    )
    return db.fetch_all(
        f"""
        SELECT s.schedule_id, s.suggestion_id, s.segment_id,
               rs.segment_code, rs.name AS segment_name,
               s.active_window::text AS active_window,
               s.inbound_lanes, s.outbound_lanes, s.status,
               s.created_by, s.created_at
        FROM reversible_lane_schedules s
        JOIN road_segments rs USING (segment_id)
        WHERE 1 = 1 {active_filter}
        ORDER BY lower(s.active_window) DESC
        """
    )


@app.post("/api/plans/{plan_date}/generate")
def generate_plan(plan_date: date) -> dict:
    db.execute("CALL generate_lane_reallocation_plan(%s)", (plan_date,))
    return plan_for_date(plan_date)


@app.get("/api/plans/{plan_date}")
def plan_for_date(plan_date: date) -> dict:
    plan = db.fetch_one(
        """SELECT plan_id, plan_date, status, generated_at, generated_by, notes
           FROM reallocation_plans WHERE plan_date = %s""",
        (plan_date,),
    )
    if plan is None:
        raise HTTPException(status_code=404, detail="Plan not found; generate it first")
    plan["items"] = db.fetch_all(
        """
        SELECT pi.plan_item_id, pi.segment_id, rs.segment_code,
               rs.name AS segment_name, c.name AS corridor_name,
               pi.recommended_inbound_lanes, pi.recommended_outbound_lanes,
               pi.action, ROUND(pi.unfit_ratio * 100, 1) AS unfit_percent,
               pi.rationale, et.team_name AS enforcement_team
        FROM plan_items pi
        JOIN road_segments rs USING (segment_id)
        JOIN corridors c USING (corridor_id)
        LEFT JOIN enforcement_deployments ed USING (plan_item_id)
        LEFT JOIN enforcement_teams et USING (team_id)
        WHERE pi.plan_id = %s
        ORDER BY c.name, rs.segment_code
        """,
        (plan["plan_id"],),
    )
    return plan
